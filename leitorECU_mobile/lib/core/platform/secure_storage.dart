import 'package:flutter/services.dart';

/// Armazenamento seguro de chaves sensíveis (API Key de IA) usando Android Keystore
/// via MethodChannel, com fallback em memória para desktop e testes automatizados.
class SecureKeyStorage {
  SecureKeyStorage({
    this.readOverride,
    this.writeOverride,
    this.deleteOverride,
  });

  static const MethodChannel _channel =
      MethodChannel('com.leitorecu.mobile/secure_storage');

  final Future<String?> Function(String)? readOverride;
  final Future<bool> Function(String, String)? writeOverride;
  final Future<bool> Function(String)? deleteOverride;

  final Map<String, String> _memoryFallback = <String, String>{};

  Future<bool> write(String key, String value) async {
    final cleanKey = key.trim();
    if (cleanKey.isEmpty) return false;

    final override = writeOverride;
    if (override != null) {
      return override(cleanKey, value);
    }

    try {
      final result = await _channel.invokeMethod<bool>('write', {
        'key': cleanKey,
        'value': value,
      });
      return result ?? false;
    } on MissingPluginException {
      _memoryFallback[cleanKey] = value;
      return true;
    } on PlatformException {
      _memoryFallback[cleanKey] = value;
      return true;
    } catch (_) {
      _memoryFallback[cleanKey] = value;
      return true;
    }
  }

  Future<String?> read(String key) async {
    final cleanKey = key.trim();
    if (cleanKey.isEmpty) return null;

    final override = readOverride;
    if (override != null) {
      return override(cleanKey);
    }

    try {
      return await _channel.invokeMethod<String>('read', {
        'key': cleanKey,
      });
    } on MissingPluginException {
      return _memoryFallback[cleanKey];
    } on PlatformException {
      return _memoryFallback[cleanKey];
    } catch (_) {
      return _memoryFallback[cleanKey];
    }
  }

  Future<bool> delete(String key) async {
    final cleanKey = key.trim();
    if (cleanKey.isEmpty) return false;

    final override = deleteOverride;
    if (override != null) {
      return override(cleanKey);
    }

    try {
      final result = await _channel.invokeMethod<bool>('delete', {
        'key': cleanKey,
      });
      _memoryFallback.remove(cleanKey);
      return result ?? false;
    } on MissingPluginException {
      _memoryFallback.remove(cleanKey);
      return true;
    } on PlatformException {
      _memoryFallback.remove(cleanKey);
      return true;
    } catch (_) {
      _memoryFallback.remove(cleanKey);
      return true;
    }
  }

  Future<bool> hasKey(String key) async {
    final value = await read(key);
    return value != null && value.trim().isNotEmpty;
  }
}
