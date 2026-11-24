/// Interface abstrata de transporte físico para comunicação com ELM327.
library;

import 'dart:async';

class TransportException implements Exception {
  final String message;
  const TransportException(this.message);

  @override
  String toString() => 'TransportException: $message';
}

abstract class ObdTransport {
  String get name;
  bool get isConnected;

  Future<void> open();
  Future<void> close();
  Future<void> write(List<int> data);

  /// Retorna os bytes disponíveis dentro de [timeout] (ou lista vazia em timeout).
  Future<List<int>> readSome(Duration timeout);

  Future<void> flushInput();

  /// Lê bytes até receber o prompt '>' (0x3E) do ELM327 ou expirar [timeout].
  Future<({List<int> data, bool promptReceived})> readUntilPrompt(
    Duration timeout,
  ) async {
    final buf = <int>[];
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        return (data: buf, promptReceived: false);
      }
      final step = remaining < const Duration(milliseconds: 250)
          ? remaining
          : const Duration(milliseconds: 250);
      final chunk = await readSome(step);
      if (chunk.isNotEmpty) {
        buf.addAll(chunk);
        if (chunk.contains(0x3E)) {
          return (data: buf, promptReceived: true);
        }
      }
    }
  }
}
