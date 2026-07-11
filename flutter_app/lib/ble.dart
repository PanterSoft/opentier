import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// In-app debug console feed. ble.dart and main.dart both log here so the
/// user can watch scan/TX/RX traffic on the phone without a computer.
final ValueNotifier<List<String>> debugLog = ValueNotifier(const <String>[]);

void dlog(String msg) {
  debugPrint(msg);
  final ts = DateTime.now().toIso8601String().substring(11, 19);
  final l = List<String>.from(debugLog.value)..add('$ts $msg');
  // ponytail: cap at 300 lines, plenty for a debug session.
  if (l.length > 300) l.removeRange(0, l.length - 300);
  debugLog.value = l;
}

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
  final _rxBuffer = StringBuffer();

  final _received = StreamController<String>.broadcast();
  Stream<String> get receivedData => _received.stream;

  BluetoothDevice? _device;

  /// Scan for MyTier scooters. Same filter as the Kotlin app:
  /// name matches [A-Z]{2}[0-9]{6} or contains ES200, or advertises service 2C00.
  Stream<ScanResult> scan() {
    FlutterBluePlus.startScan(
      // ponytail: no withServices filter — iOS enforces that filter at the
      // radio level and drops adverts that put the service UUID in the scan
      // response instead of the primary packet. Client-side filter below
      // (name/service) does the real matching instead.
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
      // Guid.str shortens 16-bit UUIDs to e.g. "2c00"; str128 is always full.
      final byService = r.advertisementData.serviceUuids
          .any((u) => u.str128.toLowerCase().startsWith('00002c'));
      dlog(
          '[scan] name="$name" rssi=${r.rssi} services=${r.advertisementData.serviceUuids} match=${byName || byService}');
      return byName || byService;
    });
  }

  /// Debug-only: every advertisement iOS surfaces, unfiltered.
  Stream<ScanResult> scanAll() {
    FlutterBluePlus.startScan(
      androidScanMode: AndroidScanMode.lowLatency,
      continuousUpdates: true,
    );
    return FlutterBluePlus.scanResults.expand((results) => results);
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  Stream<BluetoothConnectionState> connectionState(BluetoothDevice d) =>
      d.connectionState;

  Future<void> connect(BluetoothDevice device) async {
    _device = device;
    await FlutterBluePlus.stopScan();
    dlog('[conn] connecting to ${device.remoteId.str}');
    await device.connect(
        timeout: const Duration(seconds: 15), license: License.nonprofit);

    final services = await device.discoverServices();
    dlog('[conn] services: ${services.map((s) => s.uuid.str).join(", ")}');
    final service = services.firstWhere(
      (s) => s.uuid.str128.toLowerCase().startsWith('00002c'),
      orElse: () => throw Exception('MyTier service not found'),
    );

    _write = service.characteristics.firstWhere((c) => c.uuid == charWrite);
    final notify =
        service.characteristics.firstWhere((c) => c.uuid == charNotify);

    await notify.setNotifyValue(true);
    _rxBuffer.clear();
    _notifySub = notify.onValueReceived.listen((bytes) {
      if (bytes.isEmpty) return;
      // ponytail: MTU chunks a response across multiple notify packets;
      // buffer until a full \r\n-terminated line shows up.
      _rxBuffer.write(String.fromCharCodes(bytes));
      final combined = _rxBuffer.toString();
      final lines = combined.split('\r\n');
      final incomplete = combined.endsWith('\r\n') ? '' : lines.removeLast();
      for (final line in lines) {
        if (line.isNotEmpty) {
          dlog('[rx] $line');
          _received.add('$line\r\n');
        }
      }
      _rxBuffer
        ..clear()
        ..write(incomplete);
    });
  }

  Future<void> disconnect() async {
    await _notifySub?.cancel();
    await _connSub?.cancel();
    await _device?.disconnect();
    _write = null;
    _rxBuffer.clear();
  }

  /// Write the command, chunked into 20-byte frames (default MTU), with-response.
  Future<void> sendCommand(String command) async {
    final w = _write;
    if (w == null) {
      dlog('[tx] dropped (not connected): ${command.trim()}');
      return;
    }
    dlog('[tx] ${command.trim()}');
    final full = command.endsWith('\r\n') ? command : '$command\r\n';
    final bytes = full.codeUnits;
    for (var i = 0; i < bytes.length; i += 20) {
      final chunk = bytes.sublist(i, i + 20 > bytes.length ? bytes.length : i + 20);
      await w.write(chunk, withoutResponse: false);
    }
  }
}
