/// Transporte simulado (Demo) que responde como ELM327 + ECU real.
library;

import 'dart:async';
import 'dart:convert';

import '../models/vehicle_profile.dart';
import 'mock_engine.dart';
import 'obd_transport.dart';

class MockTransport extends ObdTransport {
  final MockEngine engine;
  final Duration klineLatency;

  List<int> _pending = const [];
  DateTime _readyAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _open = false;

  MockTransport({
    DemoProfile profile = DemoProfile.golMe75,
    bool turboMode = false,
    this.klineLatency = const Duration(milliseconds: 5),
    MockEngine? engine,
  }) : engine = engine ?? MockEngine(profile: profile, turboMode: turboMode);

  @override
  String get name => 'Demo';

  @override
  bool get isConnected => _open;

  @override
  Future<void> open() async {
    _open = true;
    _pending = const [];
  }

  @override
  Future<void> close() async {
    _open = false;
    _pending = const [];
  }

  @override
  Future<void> write(List<int> data) async {
    if (!_open) {
      throw const TransportException('Mock fechado');
    }
    final cmd = ascii.decode(data, allowInvalid: true).trim().toUpperCase().replaceAll(' ', '');
    final (:response, :latencySec) = engine.respond(
      cmd,
      klineLatency.inMicroseconds / 1e6,
    );
    _pending = ascii.encode('$response\r\r>');
    _readyAt = DateTime.now().add(
      Duration(microseconds: (latencySec * 1e6).round()),
    );
  }

  @override
  Future<List<int>> readSome(Duration timeout) async {
    if (_pending.isEmpty) {
      if (timeout > Duration.zero) {
        final step = timeout < const Duration(milliseconds: 20)
            ? timeout
            : const Duration(milliseconds: 20);
        await Future<void>.delayed(step);
      }
      return const [];
    }
    final wait = _readyAt.difference(DateTime.now());
    if (wait > Duration.zero) {
      if (wait > timeout) {
        if (timeout > Duration.zero) {
          await Future<void>.delayed(timeout);
        }
        return const [];
      }
      await Future<void>.delayed(wait);
    }
    final data = _pending;
    _pending = const [];
    return data;
  }

  @override
  Future<void> flushInput() async {
    _pending = const [];
  }
}
