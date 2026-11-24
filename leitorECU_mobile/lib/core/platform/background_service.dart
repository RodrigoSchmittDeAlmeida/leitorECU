import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Integração com Foreground Service Android (WakeLock + WifiLock + notificação contínua)
/// para manter coleta OBD-II e gravação de logs ativas em segundo plano e tela apagada.
class TelemetryBackgroundService {
  static const MethodChannel _channel =
      MethodChannel('com.leitorecu.mobile/background');

  TelemetryBackgroundService._();

  static bool _active = false;
  static DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  static bool get isActive => _active;

  static Future<void> _ensureNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.notification.status;
      if (!status.isGranted && !status.isPermanentlyDenied) {
        await Permission.notification.request();
      }
    } on MissingPluginException {
      // Ignorado em ambiente de testes
    } on PlatformException {
      // Ignorado caso indisponível
    } catch (_) {}
  }

  static Future<bool> start({
    String title = 'leitorECU · Telemetria Ativa',
    String text = 'Conexão e datalogger ativos em segundo plano',
  }) async {
    if (!Platform.isAndroid) return false;
    await _ensureNotificationPermission();
    try {
      final ok = await _channel.invokeMethod<bool>('startService', {
        'title': title,
        'text': text,
      });
      _active = ok ?? false;
      _lastUpdate = DateTime.now();
      return _active;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> update({
    required String title,
    required String text,
    bool force = false,
  }) async {
    if (!Platform.isAndroid || !_active) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastUpdate).inMilliseconds < 2000) return;
    _lastUpdate = now;
    try {
      await _channel.invokeMethod<bool>('updateService', {
        'title': title,
        'text': text,
      });
    } catch (_) {}
  }

  static Future<void> stop() async {
    _active = false;
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('stopService');
    } catch (_) {}
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>(
        'isIgnoringBatteryOptimizations',
      );
      return res ?? true;
    } on MissingPluginException {
      return true;
    } catch (_) {
      return true;
    }
  }

  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>(
        'requestIgnoreBatteryOptimizations',
      );
      return res ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
