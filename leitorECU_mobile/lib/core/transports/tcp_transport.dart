/// Transporte TCP/Wi-Fi nativo via `dart:io` Socket para adaptadores ELM327 Wi-Fi.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'obd_transport.dart';

class TcpTransport extends ObdTransport {
  final String host;
  final int port;
  final Duration timeout;

  Socket? _socket;
  StreamSubscription<List<int>>? _sub;
  final Queue<int> _buffer = Queue<int>();
  Completer<void>? _waiter;
  bool _connected = false;
  Object? _streamError;

  TcpTransport({
    this.host = '192.168.0.10',
    this.port = 35000,
    this.timeout = const Duration(seconds: 2),
  });

  @override
  String get name => 'Wi-Fi';

  @override
  bool get isConnected => _connected && _socket != null;

  @override
  Future<void> open() async {
    _buffer.clear();
    _streamError = null;
    try {
      final sock = await Socket.connect(host, port, timeout: timeout);
      try {
        sock.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      _socket = sock;
      _connected = true;
      _sub = sock.listen(
        (chunk) {
          _buffer.addAll(chunk);
          _notifyWaiter();
        },
        onError: (Object err) {
          _streamError = err;
          _connected = false;
          _notifyWaiter();
        },
        onDone: () {
          _connected = false;
          _notifyWaiter();
        },
        cancelOnError: false,
      );
    } on SocketException catch (e) {
      throw TransportException('Não foi possível conectar em $host:$port (${e.message})');
    } catch (e) {
      throw TransportException('Não foi possível conectar em $host:$port ($e)');
    }
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
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      _socket?.destroy();
    } catch (_) {}
    _socket = null;
    _buffer.clear();
  }

  @override
  Future<void> write(List<int> data) async {
    final sock = _socket;
    if (sock == null || !_connected) {
      throw const TransportException('Socket fechado');
    }
    try {
      sock.add(data);
      await sock.flush();
    } on SocketException catch (e) {
      _connected = false;
      throw TransportException('Erro de envio TCP: ${e.message}');
    } catch (e) {
      throw TransportException('Erro de envio TCP: $e');
    }
  }

  @override
  Future<void> flushInput() async {
    _buffer.clear();
    _streamError = null;
  }

  List<int> _drainBuffer() {
    if (_buffer.isEmpty) return const [];
    final out = _buffer.toList(growable: false);
    _buffer.clear();
    return out;
  }

  @override
  Future<List<int>> readSome(Duration timeout) async {
    if (_buffer.isNotEmpty) {
      return _drainBuffer();
    }
    if (_streamError != null) {
      final err = _streamError;
      _streamError = null;
      throw TransportException('Erro de leitura TCP: $err');
    }
    if (!_connected || _socket == null) {
      throw const TransportException('Conexão encerrada pelo adaptador');
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

    if (_buffer.isNotEmpty) {
      return _drainBuffer();
    }
    if (_streamError != null) {
      final err = _streamError;
      _streamError = null;
      throw TransportException('Erro de leitura TCP: $err');
    }
    if (!_connected) {
      throw const TransportException('Conexão encerrada pelo adaptador');
    }
    return const [];
  }
}
