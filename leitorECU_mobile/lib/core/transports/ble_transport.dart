/// Transporte Bluetooth Low Energy (BLE) para ELM327 via `flutter_blue_plus`.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'obd_transport.dart';

/// Pares (serviço, característica notify/RX, característica write/TX) conhecidos.
const List<(String service, String rx, String tx)> knownBleUuids = [
  // Vgate iCar Pro BLE 4.0 / vLinker ("IOS-Vlink", "Android-Vlink")
  (
    'e7810a71-73ae-499d-8c15-faa9aef0c3f2',
    'bef8d6c9-9c21-4c9e-b632-bd58c1009f9f',
    'bef8d6c9-9c21-4c9e-b632-bd58c1009f9f',
  ),
  // Vgate iCar Pro BLE 4.0 (serviço secundário 18F0 presente em vários lotes)
  (
    '000018f0-0000-1000-8000-00805f9b34fb',
    '00002af0-0000-1000-8000-00805f9b34fb',
    '00002af1-0000-1000-8000-00805f9b34fb',
  ),
  // Clones ELM327 BLE genéricos (FFF0: RX=FFF1/TX=FFF2 ou vice-versa)
  (
    '0000fff0-0000-1000-8000-00805f9b34fb',
    '0000fff1-0000-1000-8000-00805f9b34fb',
    '0000fff2-0000-1000-8000-00805f9b34fb',
  ),
  (
    '0000fff0-0000-1000-8000-00805f9b34fb',
    '0000fff2-0000-1000-8000-00805f9b34fb',
    '0000fff1-0000-1000-8000-00805f9b34fb',
  ),
  (
    '0000ffe0-0000-1000-8000-00805f9b34fb',
    '0000ffe1-0000-1000-8000-00805f9b34fb',
    '0000ffe1-0000-1000-8000-00805f9b34fb',
  ),
  // Nordic UART
  (
    '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
    '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
    '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
  ),
];

const List<String> _stdBleServices = [
  '00001800-',
  '00001801-',
  '0000180a-',
  '0000180f-',
];

class BleDeviceInfo {
  final String id;
  final String name;
  final int rssi;
  final BluetoothDevice? device;

  const BleDeviceInfo({
    required this.id,
    required this.name,
    required this.rssi,
    this.device,
  });
}

class BleScanner {
  /// Solicita permissões BLE em tempo de execução (Android / iOS).
  static Future<bool> ensurePermissions() async {
    try {
      if (Platform.isAndroid) {
        final statuses = await [
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.locationWhenInUse,
        ].request();
        final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? false;
        final connOk = statuses[Permission.bluetoothConnect]?.isGranted ?? false;
        if (scanOk && connOk) return true;
        // Android <= 11 pode conceder apenas locationWhenInUse
        return statuses[Permission.locationWhenInUse]?.isGranted ?? false;
      }
      if (Platform.isIOS) {
        final st = await Permission.bluetooth.request();
        return st.isGranted;
      }
      return true;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Verifica se o hardware BLE está suportado e ligado.
  static Future<bool> isBleAvailable() async {
    try {
      final supported = await FlutterBluePlus.isSupported;
      if (!supported) return false;
      final state = await FlutterBluePlus.adapterState.first.timeout(
        const Duration(seconds: 2),
        onTimeout: () => BluetoothAdapterState.unknown,
      );
      return state == BluetoothAdapterState.on;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Realiza varredura de dispositivos BLE próximos.
  static Future<List<BleDeviceInfo>> scan({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    await ensurePermissions();
    final found = <String, BleDeviceInfo>{};
    StreamSubscription<List<ScanResult>>? sub;

    try {
      final supported = await FlutterBluePlus.isSupported;
      if (!supported) return const [];

      sub = FlutterBluePlus.scanResults.listen((results) {
        for (final r in results) {
          final id = r.device.remoteId.str;
          final rawName = r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : r.device.platformName;
          final name = rawName.isNotEmpty ? rawName : 'Dispositivo BLE ($id)';
          found[id] = BleDeviceInfo(
            id: id,
            name: name,
            rssi: r.rssi,
            device: r.device,
          );
        }
      });

      await FlutterBluePlus.startScan(timeout: timeout);
      await Future<void>.delayed(timeout);
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    } catch (_) {
      return found.values.toList();
    } finally {
      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await sub?.cancel();
    }

    final list = found.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }
}

class BleTransport extends ObdTransport {
  final String address;
  final Duration timeout;
  final void Function(String message)? log;
  final BluetoothDevice? _providedDevice;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxChar;
  BluetoothCharacteristic? _txChar;
  bool _txWithoutResponse = true;
  int _chunk = 20;
  bool _connected = false;

  final Queue<int> _rxQueue = Queue<int>();
  Completer<void>? _waiter;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  BleTransport(
    this.address, {
    this.timeout = const Duration(seconds: 2),
    this.log,
    BluetoothDevice? device,
  }) : _providedDevice = device;

  @override
  String get name => 'BLE';

  @override
  bool get isConnected => _connected;

  int get chunkSize => _chunk;

  /// Calcula o tamanho máximo de chunk respeitando o limite de 180 bytes e mínimo 20.
  static int computeChunkSize(int mtu) => math.max(20, math.min(mtu - 3, 180));

  @override
  Future<void> open() async {
    _rxQueue.clear();
    await BleScanner.ensurePermissions();

    try {
      final supported = await FlutterBluePlus.isSupported;
      if (!supported) {
        throw const TransportException('Bluetooth Low Energy não suportado neste dispositivo');
      }
    } on MissingPluginException {
      throw const TransportException('Plugin BLE indisponível neste ambiente');
    } on PlatformException catch (e) {
      throw TransportException('Falha BLE ao verificar adaptador: ${e.message}');
    }

    final dev = _providedDevice ?? BluetoothDevice.fromId(address);
    _device = dev;

    try {
      await _connSub?.cancel();
      _connSub = null;
      await _notifySub?.cancel();
      _notifySub = null;

      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 250));

      _connSub = dev.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _connected = false;
          _notifyWaiter();
        }
      });

      // Retry silencioso para erros transitórios do stack HCI Android (147, 133, 8, 22, 257)
      Object? lastConnectErr;
      var connectOk = false;
      for (var attempt = 1; attempt <= 3; attempt++) {
        try {
          await dev.connect(timeout: const Duration(seconds: 20), mtu: 512);
          connectOk = true;
          break;
        } catch (e) {
          lastConnectErr = e;
          final msg = e.toString().toUpperCase();
          final isTransientHci = msg.contains('147') ||
              msg.contains('133') ||
              msg.contains('257') ||
              msg.contains('UNKNOWN_HCI_ERROR') ||
              msg.contains('GATT_ERROR') ||
              msg.contains('ANDROID-CODE: 8') ||
              msg.contains('ANDROID-CODE: 22');
          if (!isTransientHci || attempt == 3) {
            rethrow;
          }
          try {
            await dev.disconnect();
          } catch (_) {}
          await Future<void>.delayed(Duration(milliseconds: 600 * attempt));
        }
      }
      if (!connectOk && lastConnectErr != null) {
        throw lastConnectErr;
      }
      _connected = true;

      final services = await dev.discoverServices();
      final picked = pickCharacteristics(services);
      if (picked == null) {
        await close();
        throw const TransportException(
          'Não encontrei características BLE de UART (notify/write) no adaptador',
        );
      }

      _rxChar = picked.rx;
      _txChar = picked.tx;
      _txWithoutResponse = picked.tx.properties.writeWithoutResponse;

      int mtu = 23;
      try {
        mtu = dev.mtuNow;
      } catch (_) {}
      _chunk = computeChunkSize(mtu);

      log?.call(
        'BLE: RX=${picked.rx.uuid} TX=${picked.tx.uuid} '
        '(write ${_txWithoutResponse ? "sem" : "com"} resposta, MTU=$mtu, chunk=$_chunk)',
      );

      _notifySub = picked.rx.onValueReceived.listen((bytes) {
        _rxQueue.addAll(bytes);
        _notifyWaiter();
      });
      await picked.rx.setNotifyValue(true);
    } on TransportException {
      rethrow;
    } on MissingPluginException {
      await close();
      throw const TransportException('Plugin BLE indisponível neste ambiente');
    } on PlatformException catch (e) {
      await close();
      throw TransportException('Falha BLE: ${e.message ?? e.code}');
    } catch (e) {
      await close();
      throw TransportException('Falha BLE: $e');
    }
  }

  /// Seleciona o par (RX notify/indicate, TX write/writeWithoutResponse) a partir dos serviços GATT.
  static ({BluetoothCharacteristic rx, BluetoothCharacteristic tx})?
      pickCharacteristics(List<BluetoothService> services) {
    for (final (svcUuid, rxUuid, txUuid) in knownBleUuids) {
      final targetSvc = Guid(svcUuid);
      final targetRx = Guid(rxUuid);
      final targetTx = Guid(txUuid);

      BluetoothService? svc;
      for (final s in services) {
        if (s.uuid == targetSvc) {
          svc = s;
          break;
        }
      }
      if (svc == null) continue;

      BluetoothCharacteristic? rx;
      BluetoothCharacteristic? tx;
      for (final c in svc.characteristics) {
        if (c.uuid == targetRx &&
            (c.properties.notify || c.properties.indicate)) {
          rx = c;
        }
        if (c.uuid == targetTx &&
            (c.properties.write || c.properties.writeWithoutResponse)) {
          tx = c;
        }
      }
      if (rx != null && tx != null) {
        return (rx: rx, tx: tx);
      }
    }

    // Busca genérica: serviço não padrão com notify/indicate + write
    for (final svc in services) {
      final uuid128 = svc.uuid.str128.toLowerCase();
      if (_stdBleServices.any((prefix) => uuid128.startsWith(prefix))) {
        continue;
      }
      BluetoothCharacteristic? rx;
      BluetoothCharacteristic? tx;
      for (final c in svc.characteristics) {
        if (rx == null && (c.properties.notify || c.properties.indicate)) {
          rx = c;
        }
        if (tx == null &&
            (c.properties.write || c.properties.writeWithoutResponse)) {
          tx = c;
        }
      }
      if (rx != null && tx != null) {
        return (rx: rx, tx: tx);
      }
    }
    return null;
  }

  void _notifyWaiter() {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete();
    }
  }

  @override
  Future<void> close() async {
    _connected = false;
    _notifyWaiter();
    try {
      await _notifySub?.cancel();
    } catch (_) {}
    _notifySub = null;
    try {
      await _connSub?.cancel();
    } catch (_) {}
    _connSub = null;

    final rx = _rxChar;
    if (rx != null && (_device?.isConnected ?? false)) {
      try {
        await rx.setNotifyValue(false);
      } catch (_) {}
    }

    final dev = _device;
    if (dev != null) {
      try {
        if (dev.isConnected) {
          await dev.disconnect();
        }
      } catch (_) {}
    }
    _rxChar = null;
    _txChar = null;
    _device = null;
    _rxQueue.clear();
  }

  @override
  Future<void> write(List<int> data) async {
    final tx = _txChar;
    if (!_connected || tx == null) {
      throw const TransportException('Adaptador BLE desconectado');
    }
    for (var i = 0; i < data.length; i += _chunk) {
      final end = math.min(i + _chunk, data.length);
      final chunk = data.sublist(i, end);
      try {
        await tx.write(chunk, withoutResponse: _txWithoutResponse);
      } catch (_) {
        // Alterna entre write com e sem resposta antes de falhar
        try {
          _txWithoutResponse = !_txWithoutResponse;
          await tx.write(chunk, withoutResponse: _txWithoutResponse);
        } catch (e) {
          throw TransportException('Erro de escrita BLE: $e');
        }
      }
    }
  }

  @override
  Future<void> flushInput() async {
    _rxQueue.clear();
  }

  List<int> _drainQueue() {
    if (_rxQueue.isEmpty) return const [];
    final out = _rxQueue.toList(growable: false);
    _rxQueue.clear();
    return out;
  }

  @override
  Future<List<int>> readSome(Duration timeout) async {
    if (_rxQueue.isNotEmpty) {
      return _drainQueue();
    }
    if (!_connected) {
      throw const TransportException('Adaptador BLE desconectado');
    }
    if (timeout <= Duration.zero) {
      return const [];
    }

    final c = Completer<void>();
    _waiter = c;
    try {
      await c.future.timeout(timeout);
    } on TimeoutException {
      if (identical(_waiter, c)) {
        _waiter = null;
      }
      return const [];
    }

    if (_rxQueue.isNotEmpty) {
      return _drainQueue();
    }
    if (!_connected) {
      throw const TransportException('Adaptador BLE desconectado');
    }
    return const [];
  }
}
