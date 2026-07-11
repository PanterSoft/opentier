import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'ble.dart';
import 'protocol.dart';


const _bg = Color(0xFF0F1113);
const _surface = Color(0xFF1C1E21);
const _accent = Color(0xFF00F2FF);
const _danger = Color(0xFFFF4B4B);

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    final prefs = await SharedPreferences.getInstance();
    runApp(OpenTierApp(prefs: prefs));
  }, (error, stack) {
    // ponytail: last-resort net so a stray BLE/stream error (e.g. write
    // after disconnect) logs instead of silently killing the isolate.
    debugPrint('Uncaught error: $error\n$stack');
  });
}

class OpenTierApp extends StatelessWidget {
  final SharedPreferences prefs;
  const OpenTierApp({super.key, required this.prefs});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenTier',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(primary: _accent, surface: _surface),
        scaffoldBackgroundColor: _bg,
      ),
      home: Home(prefs: prefs),
    );
  }
}

class Home extends StatefulWidget {
  final SharedPreferences prefs;
  const Home({super.key, required this.prefs});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _ble = ScooterBle();
  final _devices = <BluetoothDevice>[];
  final _scanInfo = <String, ScanResult>{}; // debug: rssi/services per device
  StreamSubscription? _scanSub;
  StreamSubscription? _connSub;
  StreamSubscription<String>? _dataSub;
  Timer? _pollTimer;

  String? _currentId;
  bool _connected = false;
  bool _connecting = false;
  String? _connectingName;
  bool _autoConnect = true;
  String _connText = 'Disconnected';
  String? _bleBlocked; // non-null = why BLE can't run (simulator, denied, off)
  bool _showAll = false; // debug: raw scan instead of scooter filter
  ScooterStatus? _status;

  SharedPreferences get prefs => widget.prefs;

  @override
  void initState() {
    super.initState();
    _startFlow();
  }

  Future<void> _startFlow() async {
    if (!await FlutterBluePlus.isSupported) {
      if (!mounted) return;
      setState(() => _bleBlocked =
          'Bluetooth is not available on this device (iOS Simulator has no Bluetooth — use a real iPhone).');
      return;
    }
    if (!await _ensurePermissions()) {
      if (!mounted) return;
      setState(() => _bleBlocked =
          'Bluetooth permission denied. Enable it in Settings to find your scooter.');
      return;
    }
    // Starting a scan triggers the iOS system Bluetooth permission dialog
    // (NSBluetoothAlwaysUsageDescription); wait until the user answered it.
    final adapter = await FlutterBluePlus.adapterState
        .where((s) =>
            s == BluetoothAdapterState.on ||
            s == BluetoothAdapterState.off ||
            s == BluetoothAdapterState.unauthorized)
        .first;
    if (!mounted) return;
    if (adapter != BluetoothAdapterState.on) {
      setState(() => _bleBlocked = adapter == BluetoothAdapterState.unauthorized
          ? 'Bluetooth permission denied. Enable it in Settings > OpenTier.'
          : 'Bluetooth is turned off. Turn it on to find your scooter.');
      return;
    }
    setState(() => _bleBlocked = null);
    _dataSub = _ble.receivedData.listen(_onData);
    _startScan();
  }

  Future<bool> _ensurePermissions() async {
    // iOS shows its own Bluetooth dialog when scanning starts; only Android
    // needs explicit runtime permissions.
    if (Platform.isIOS) return true;
    final results = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return results.values.every((s) => s.isGranted || s.isLimited);
  }

  void _onData(String raw) {
    final parsed = MyTierProtocol.parseStatus(raw);
    if (parsed == null || !mounted) return;
    setState(() {
      // Keep prior battery reading if an ACK frame reports 0 (matches Kotlin).
      if (parsed.batteryPercentage == 0 && _status != null) {
        _status = parsed.copyWith(batteryPercentage: _status!.batteryPercentage);
      } else {
        _status = parsed;
      }
    });
  }

  void _startScan() {
    _devices.clear();
    _scanInfo.clear();
    final lastId = prefs.getString('last_mac');
    _scanSub?.cancel();
    _scanSub = (_showAll ? _ble.scanAll() : _ble.scan()).listen((r) {
      if (!mounted) return;
      final d = r.device;
      _scanInfo[d.remoteId.str] = r;
      if (_autoConnect && lastId != null && d.remoteId.str == lastId) {
        _connectTo(d);
        return;
      }
      if (_devices.every((x) => x.remoteId.str != d.remoteId.str)) {
        setState(() => _devices.add(d));
      }
    });
    setState(() {});
  }

  Future<void> _connectTo(BluetoothDevice device) async {
    if (_connecting) return; // scan events can race in before cancel lands
    _scanSub?.cancel();
    await _ble.stopScan();
    _currentId = device.remoteId.str;

    setState(() {
      _connecting = true;
      _connectingName = device.platformName.isEmpty
          ? device.remoteId.str
          : device.platformName;
    });

    _connSub?.cancel();
    _connSub = _ble.connectionState(device).listen((s) {
      if (!mounted) return;
      final connected = s == BluetoothConnectionState.connected;
      setState(() {
        _connected = connected;
        _connText = s.name;
        if (connected) _connecting = false;
      });
      if (connected) {
        prefs.setString('last_mac', device.remoteId.str);
        _startPolling();
      } else {
        _pollTimer?.cancel();
      }
    });

    try {
      await _ble.connect(device);
    } catch (e) {
      dlog('[conn] failed: $e');
      // Don't loop: a failed auto-connect must not immediately re-trigger.
      _autoConnect = false;
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _connText = 'Failed: $e';
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not connect to $_connectingName: $e'),
        backgroundColor: _danger,
      ));
      _startScan(); // let them try another device
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _poll();
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) => _poll());
  }

  void _poll() {
    // ponytail: scooter can disappear mid-poll (out of range, powered off);
    // swallow the write error instead of letting it kill the isolate.
    _ble.sendCommand(MyTierProtocol.getStatus(_password)).catchError((_) {});
  }

  String get _password => prefs.getString('pass_$_currentId') ?? '';
  String get _name => prefs.getString('name_$_currentId') ?? 'My Scooter';

  Future<void> _disconnect() async {
    _pollTimer?.cancel();
    _autoConnect = false;
    await _ble.disconnect();
    setState(() {
      _connected = false;
      _currentId = null;
    });
    _startScan();
  }

  Future<void> _deleteSaved(String id) async {
    await prefs.remove('pass_$id');
    await prefs.remove('name_$id');
    if (prefs.getString('last_mac') == id) await prefs.remove('last_mac');
    dlog('[prefs] deleted saved device $id');
    setState(() {});
  }

  Future<void> _forget() async {
    _pollTimer?.cancel();
    await _ble.disconnect();
    await prefs.remove('last_mac');
    await prefs.remove('pass_$_currentId');
    await prefs.remove('name_$_currentId');
    setState(() {
      _connected = false;
      _currentId = null;
    });
    _startScan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _connSub?.cancel();
    _dataSub?.cancel();
    _pollTimer?.cancel();
    _ble.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(children: [
          _connected
            ? DashboardScreen(
                name: _name,
                connText: _connText,
                status: _status,
                password: _password,
                onNameChange: (v) => prefs.setString('name_$_currentId', v),
                onPasswordChange: (v) {
                  if (v.isNotEmpty) prefs.setString('pass_$_currentId', v);
                  setState(() {});
                },
                onAction: () {
                  final pw = _password;
                  _ble.sendCommand((_status?.isLocked ?? true)
                      ? MyTierProtocol.unlock(pw)
                      : MyTierProtocol.lock(pw));
                },
                onSwitch: _disconnect,
                onForget: _forget,
              )
            : DeviceListScreen(
                devices: _devices,
                scanInfo: _scanInfo,
                prefs: prefs,
                blockedReason: _bleBlocked,
                showAll: _showAll,
                onToggleShowAll: (v) {
                  setState(() => _showAll = v);
                  _startScan();
                },
                onRetry: _startFlow,
                onDeleteSaved: _deleteSaved,
                onTap: (d) {
                  _autoConnect = true;
                  _connectTo(d);
                },
              ),
          if (_connecting)
            Container(
              color: Colors.black87,
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const CircularProgressIndicator(color: _accent),
                  const SizedBox(height: 16),
                  Text('Connecting to $_connectingName...',
                      style: const TextStyle(color: Colors.white)),
                ]),
              ),
            ),
        ]),
      ),
      floatingActionButton: FloatingActionButton.small(
        backgroundColor: _surface,
        foregroundColor: _accent,
        child: const Icon(Icons.terminal),
        onPressed: () => showModalBottomSheet(
          context: context,
          backgroundColor: _bg,
          isScrollControlled: true,
          builder: (_) => _DebugConsole(ble: _ble),
        ),
      ),
    );
  }
}

/// Live scan/TX/RX log + raw command sender, viewable on the phone.
class _DebugConsole extends StatefulWidget {
  final ScooterBle ble;
  const _DebugConsole({required this.ble});
  @override
  State<_DebugConsole> createState() => _DebugConsoleState();
}

class _DebugConsoleState extends State<_DebugConsole> {
  final _cmdCtl = TextEditingController();

  @override
  void dispose() {
    _cmdCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // keep the command field above the keyboard
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            Row(children: [
              const Text('Debug Console',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.grey),
                onPressed: () => debugLog.value = const [],
              ),
            ]),
            Expanded(
              child: ValueListenableBuilder<List<String>>(
                valueListenable: debugLog,
                builder: (_, lines, child) => ListView.builder(
                  reverse: true, // newest at the bottom, autoscrolls
                  itemCount: lines.length,
                  itemBuilder: (_, i) => Text(
                    lines[lines.length - 1 - i],
                    style: const TextStyle(
                        color: Colors.greenAccent,
                        fontSize: 11,
                        fontFamily: 'Menlo'),
                  ),
                ),
              ),
            ),
            TextField(
              controller: _cmdCtl,
              style: const TextStyle(
                  color: Colors.white, fontFamily: 'Menlo', fontSize: 13),
              decoration: const InputDecoration(
                hintText: 'raw command (sent with \\r\\n)',
                hintStyle: TextStyle(color: Colors.grey, fontSize: 13),
              ),
              onSubmitted: (v) {
                if (v.isNotEmpty) {
                  widget.ble.sendCommand(v).catchError((e) => dlog('[tx] $e'));
                }
                _cmdCtl.clear();
              },
            ),
          ]),
        ),
      ),
    );
  }
}

class DeviceListScreen extends StatelessWidget {
  final List<BluetoothDevice> devices;
  final Map<String, ScanResult> scanInfo;
  final SharedPreferences prefs;
  final String? blockedReason;
  final bool showAll;
  final void Function(bool) onToggleShowAll;
  final VoidCallback onRetry;
  final void Function(String) onDeleteSaved;
  final void Function(BluetoothDevice) onTap;
  const DeviceListScreen(
      {super.key,
      required this.devices,
      required this.scanInfo,
      required this.prefs,
      this.blockedReason,
      required this.showAll,
      required this.onToggleShowAll,
      required this.onRetry,
      required this.onDeleteSaved,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Saved devices come from prefs so they're listed (and deletable) even
    // when out of range. last_mac counts too: it can be saved without a
    // password if a connect succeeded but no password was ever entered.
    final savedIds = prefs
        .getKeys()
        .where((k) => k.startsWith('pass_') || k.startsWith('name_'))
        .map((k) => k.substring(5))
        .toSet();
    final lastMac = prefs.getString('last_mac');
    if (lastMac != null) savedIds.add(lastMac);
    final fresh =
        devices.where((d) => !savedIds.contains(d.remoteId.str)).toList();

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('OpenTier Garage',
            style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold)),
        Text(
            blockedReason ??
                (showAll
                    ? 'Showing all nearby BLE devices (${devices.length})'
                    : 'Searching for scooters...'),
            style: TextStyle(
                color: blockedReason == null ? _accent : _danger,
                fontSize: 14)),
        if (blockedReason != null)
          TextButton(
              onPressed: onRetry,
              child: const Text('Retry', style: TextStyle(color: _accent))),
        Row(children: [
          const Text('Show all devices',
              style: TextStyle(color: Colors.grey, fontSize: 13)),
          Switch(
              value: showAll,
              activeThumbColor: _accent,
              onChanged: onToggleShowAll),
        ]),
        const SizedBox(height: 24),
        Expanded(
          child: ListView(children: [
            if (savedIds.isNotEmpty) ...[
              const _SectionLabel('YOUR SAVED SCOOTERS'),
              ...savedIds.map((id) {
                final inRange = devices.any((d) => d.remoteId.str == id);
                final device = inRange
                    ? devices.firstWhere((d) => d.remoteId.str == id)
                    : BluetoothDevice.fromId(id); // iOS can connect by UUID
                final name = prefs.getString('name_$id') ??
                    (device.platformName.isEmpty
                        ? 'Unknown'
                        : device.platformName);
                return _DeviceCard(
                    device,
                    inRange ? name : '$name (not in range)',
                    onTap,
                    scanInfo[id],
                    () => onDeleteSaved(id));
              }),
              const SizedBox(height: 24),
            ],
            if (fresh.isNotEmpty) ...[
              const _SectionLabel('DISCOVERED NEARBY'),
              ...fresh.map((d) {
                // iOS: platformName is often empty pre-connect; the advertised
                // name is the one that identifies the scooter.
                final adv =
                    scanInfo[d.remoteId.str]?.advertisementData.advName ?? '';
                final label = d.platformName.isNotEmpty
                    ? d.platformName
                    : (adv.isNotEmpty ? adv : '(no name)');
                return _DeviceCard(d, label, onTap, scanInfo[d.remoteId.str]);
              }),
            ],
          ]),
        ),
      ]),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(text,
            style: const TextStyle(
                color: Colors.grey,
                fontSize: 12,
                fontWeight: FontWeight.bold)),
      );
}

class _DeviceCard extends StatelessWidget {
  final BluetoothDevice device;
  final String name;
  final void Function(BluetoothDevice) onTap;
  final ScanResult? scan;
  final VoidCallback? onDelete;
  const _DeviceCard(this.device, this.name, this.onTap,
      [this.scan, this.onDelete]);
  @override
  Widget build(BuildContext context) {
    final services = scan?.advertisementData.serviceUuids ?? const [];
    return Card(
      color: _surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: () => onTap(device),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(children: [
            const Icon(Icons.bluetooth, color: _accent),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name,
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                    Text(device.remoteId.str,
                        style:
                            const TextStyle(color: Colors.grey, fontSize: 12)),
                    if (scan != null) ...[
                      Text('rssi: ${scan!.rssi}',
                          style: const TextStyle(
                              color: Colors.grey, fontSize: 11)),
                      if (services.isNotEmpty)
                        Text('services: ${services.join(", ")}',
                            style: const TextStyle(
                                color: Colors.grey, fontSize: 11)),
                    ],
                  ]),
            ),
            if (onDelete != null)
              IconButton(
                icon: const Icon(Icons.delete_outline, color: _danger),
                onPressed: onDelete,
              ),
          ]),
        ),
      ),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  final String name;
  final String connText;
  final ScooterStatus? status;
  final String password;
  final void Function(String) onNameChange;
  final void Function(String) onPasswordChange;
  final VoidCallback onAction;
  final VoidCallback onSwitch;
  final VoidCallback onForget;

  const DashboardScreen({
    super.key,
    required this.name,
    required this.connText,
    required this.status,
    required this.password,
    required this.onNameChange,
    required this.onPasswordChange,
    required this.onAction,
    required this.onSwitch,
    required this.onForget,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late final TextEditingController _nameCtl =
      TextEditingController(text: widget.name);
  late final TextEditingController _passCtl =
      TextEditingController(text: widget.password);
  bool _passVisible = false;

  @override
  void dispose() {
    _nameCtl.dispose();
    _passCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final locked = status?.isLocked ?? true;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Expanded(
            child: Text(widget.name,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold)),
          ),
          Row(children: [
            TextButton(
                onPressed: widget.onSwitch,
                child: const Text('Switch', style: TextStyle(color: _accent))),
            TextButton(
                onPressed: widget.onForget,
                child:
                    const Text('Forget', style: TextStyle(color: _danger))),
          ]),
        ]),
        Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
                color: _surface, borderRadius: BorderRadius.circular(16)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.bluetooth_searching, color: _accent, size: 16),
              const SizedBox(width: 8),
              Text(widget.connText,
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
          ),
        ),
        const SizedBox(height: 24),
        // ponytail: Expanded+ScrollView so the focused field auto-scrolls
        // above the keyboard instead of being hidden behind it.
        Expanded(
          child: SingleChildScrollView(
            child: Column(children: [
              _StatusCard(status),
              const SizedBox(height: 24),
              TextField(
                controller: _nameCtl,
                onChanged: widget.onNameChange,
                style: const TextStyle(color: Colors.white),
                decoration: _fieldDecoration('Scooter Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passCtl,
                onChanged: widget.onPasswordChange,
                obscureText: !_passVisible,
                style: const TextStyle(color: Colors.white),
                decoration: _fieldDecoration('Scooter Password').copyWith(
                  suffixIcon: IconButton(
                    icon: Icon(_passVisible ? Icons.lock_open : Icons.lock,
                        color: Colors.grey),
                    onPressed: () =>
                        setState(() => _passVisible = !_passVisible),
                  ),
                ),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 80,
          child: ElevatedButton.icon(
            onPressed: widget.onAction,
            style: ElevatedButton.styleFrom(
              backgroundColor: locked ? _accent : _danger,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(24)),
            ),
            icon: Icon(locked ? Icons.lock_open : Icons.lock),
            label: Text(locked ? 'UNLOCK' : 'LOCK',
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.bold)),
          ),
        ),
        const SizedBox(height: 32),
      ]),
    );
  }

  InputDecoration _fieldDecoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.grey),
        enabledBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: Colors.grey),
            borderRadius: BorderRadius.circular(8)),
        focusedBorder: OutlineInputBorder(
            borderSide: const BorderSide(color: _accent),
            borderRadius: BorderRadius.circular(8)),
      );
}

class _StatusCard extends StatelessWidget {
  final ScooterStatus? status;
  const _StatusCard(this.status);
  @override
  Widget build(BuildContext context) {
    final battery = status?.batteryPercentage;
    return Card(
      color: _surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
      child: SizedBox(
        width: double.infinity,
        height: 300,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(
            width: 200,
            height: 200,
            child: CircularProgressIndicator(
              value: (battery ?? 0) / 100,
              strokeWidth: 12,
              color: _accent,
              backgroundColor: const Color(0xFF2C2F33),
            ),
          ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${battery ?? "--"}%',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 48,
                    fontWeight: FontWeight.w900)),
            const Text('Battery',
                style: TextStyle(color: Colors.grey, fontSize: 16)),
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('${status!.estimatedRange.toStringAsFixed(1)} km',
                    style: const TextStyle(
                        color: _accent,
                        fontSize: 14,
                        fontWeight: FontWeight.bold)),
              ),
          ]),
        ]),
      ),
    );
  }
}
