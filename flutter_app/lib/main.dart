import 'dart:async';
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
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(OpenTierApp(prefs: prefs));
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
  StreamSubscription? _scanSub;
  StreamSubscription? _connSub;
  StreamSubscription<String>? _dataSub;
  Timer? _pollTimer;

  String? _currentId;
  bool _connected = false;
  bool _autoConnect = true;
  String _connText = 'Disconnected';
  ScooterStatus? _status;

  SharedPreferences get prefs => widget.prefs;

  @override
  void initState() {
    super.initState();
    _startFlow();
  }

  Future<void> _startFlow() async {
    if (!await _ensurePermissions()) return;
    _dataSub = _ble.receivedData.listen(_onData);
    _startScan();
  }

  Future<bool> _ensurePermissions() async {
    final perms = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ];
    final results = await perms.request();
    return results.values.every((s) => s.isGranted || s.isLimited);
  }

  void _onData(String raw) {
    final parsed = MyTierProtocol.parseStatus(raw);
    if (parsed == null) return;
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
    final lastId = prefs.getString('last_mac');
    _scanSub?.cancel();
    _scanSub = _ble.scan().listen((r) {
      final d = r.device;
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
    _scanSub?.cancel();
    await _ble.stopScan();
    _currentId = device.remoteId.str;
    prefs.setString('last_mac', _currentId!);

    _connSub?.cancel();
    _connSub = _ble.connectionState(device).listen((s) {
      final connected = s == BluetoothConnectionState.connected;
      setState(() {
        _connected = connected;
        _connText = s.name;
      });
      if (connected) {
        _startPolling();
      } else {
        _pollTimer?.cancel();
      }
    });

    try {
      await _ble.connect(device);
    } catch (e) {
      setState(() => _connText = 'Failed: $e');
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _ble.sendCommand(MyTierProtocol.getStatus(_password));
    _pollTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _ble.sendCommand(MyTierProtocol.getStatus(_password));
    });
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
        child: _connected
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
                prefs: prefs,
                onTap: (d) {
                  _autoConnect = true;
                  _connectTo(d);
                },
              ),
      ),
    );
  }
}

class DeviceListScreen extends StatelessWidget {
  final List<BluetoothDevice> devices;
  final SharedPreferences prefs;
  final void Function(BluetoothDevice) onTap;
  const DeviceListScreen(
      {super.key,
      required this.devices,
      required this.prefs,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final savedIds = prefs
        .getKeys()
        .where((k) => k.startsWith('pass_'))
        .map((k) => k.substring(5))
        .toSet();
    final saved =
        devices.where((d) => savedIds.contains(d.remoteId.str)).toList();
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
        const Text('Searching for scooters...',
            style: TextStyle(color: _accent, fontSize: 14)),
        const SizedBox(height: 24),
        Expanded(
          child: ListView(children: [
            if (saved.isNotEmpty) ...[
              const _SectionLabel('YOUR SAVED SCOOTERS'),
              ...saved.map((d) => _DeviceCard(
                  d,
                  prefs.getString('name_${d.remoteId.str}') ??
                      (d.platformName.isEmpty ? 'Unknown' : d.platformName),
                  onTap)),
              const SizedBox(height: 24),
            ],
            if (fresh.isNotEmpty) ...[
              const _SectionLabel('DISCOVERED NEARBY'),
              ...fresh.map((d) => _DeviceCard(
                  d,
                  d.platformName.isEmpty ? 'New Scooter' : d.platformName,
                  onTap)),
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
  const _DeviceCard(this.device, this.name, this.onTap);
  @override
  Widget build(BuildContext context) {
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
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
              Text(device.remoteId.str,
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
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
              onPressed: () => setState(() => _passVisible = !_passVisible),
            ),
          ),
        ),
        const Spacer(),
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
