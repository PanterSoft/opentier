import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Port of ScooterBleManager.kt onto flutter_blue_plus.
/// remoteId == MAC on Android, opaque UUID on iOS — used as the storage key.
class ScooterBle {
  static final Guid serviceUuid =
      Guid('00002C00-0000-1000-8000-00805f9b34fb');
  static final Guid charWrite = Guid('00002C01-0000-1000-8000-00805f9b34fb');
  static final Guid charNotify = Guid('00002C10-0000-1000-8000-00805f9b34fb');

  BluetoothCharacteristic? _write;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  final _received = StreamController<String>.broadcast();
  Stream<String> get receivedData => _received.stream;

  BluetoothDevice? _device;

  /// Scan for MyTier scooters. Same filter as the Kotlin app:
  /// name matches [A-Z]{2}[0-9]{6} or contains ES200, or advertises service 2C00.
  Stream<ScanResult> scan() {
    FlutterBluePlus.startScan(
      withServices: [serviceUuid], // iOS needs this to surface the device
      androidScanMode: AndroidScanMode.lowLatency,
      continuousUpdates: true,
    );
    final nameRe = RegExp(r'^[A-Z]{2}[0-9]{6}$');
    return FlutterBluePlus.scanResults.expand((results) => results).where((r) {
      final name = r.device.platformName.isNotEmpty
          ? r.device.platformName
          : r.advertisementData.advName;
      final byName =
          name.isNotEmpty && (nameRe.hasMatch(name) || name.contains('ES200'));
      final byService = r.advertisementData.serviceUuids
          .any((u) => u.str.toLowerCase().startsWith('00002c'));
      return byName || byService;
    });
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  Stream<BluetoothConnectionState> connectionState(BluetoothDevice d) =>
      d.connectionState;

  Future<void> connect(BluetoothDevice device) async {
    _device = device;
    await FlutterBluePlus.stopScan();
    await device.connect(
        timeout: const Duration(seconds: 15), license: License.nonprofit);

    final services = await device.discoverServices();
    final service = services.firstWhere(
      (s) => s.uuid.str.toLowerCase().startsWith('00002c'),
      orElse: () => throw Exception('MyTier service not found'),
    );

    _write = service.characteristics.firstWhere((c) => c.uuid == charWrite);
    final notify =
        service.characteristics.firstWhere((c) => c.uuid == charNotify);

    await notify.setNotifyValue(true);
    _notifySub = notify.onValueReceived.listen((bytes) {
      if (bytes.isNotEmpty) _received.add(String.fromCharCodes(bytes));
    });
  }

  Future<void> disconnect() async {
    await _notifySub?.cancel();
    await _connSub?.cancel();
    await _device?.disconnect();
    _write = null;
  }

  /// Write the command, chunked into 20-byte frames (default MTU), with-response.
  Future<void> sendCommand(String command) async {
    final w = _write;
    if (w == null) return;
    final full = command.endsWith('\r\n') ? command : '$command\r\n';
    final bytes = full.codeUnits;
    for (var i = 0; i < bytes.length; i += 20) {
      final chunk = bytes.sublist(i, i + 20 > bytes.length ? bytes.length : i + 20);
      await w.write(chunk, withoutResponse: false);
    }
  }
}
