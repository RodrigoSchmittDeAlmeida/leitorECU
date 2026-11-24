/// Protocolo ELM327: envio de comandos AT/OBD, leitura até '>', classificação de erros e extração de payload.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../transports/obd_transport.dart';

final RegExp _hexLineRegex = RegExp(r'^(?:[0-9A-Fa-f]{1,2}:)?[0-9A-Fa-f ]+$');
final RegExp _framePrefixRegex = RegExp(r'^[0-9A-Fa-f]{1,2}:\s*');

const List<(String cmd, Duration timeout)> elmInitSequence = [
  ('ATZ', Duration(seconds: 5)),
  ('ATE0', Duration(seconds: 2)),
  ('ATL0', Duration(seconds: 2)),
  ('ATS0', Duration(seconds: 2)),
  ('ATH0', Duration(seconds: 2)),
  ('ATAL', Duration(seconds: 2)),
  ('ATSP0', Duration(seconds: 2)),
];

class ElmResponse {
  final String command;
  final List<String> lines;
  final String? error;
  final String raw;

  const ElmResponse(
    this.command, {
    this.lines = const [],
    this.error,
    this.raw = '',
  });

  bool get ok => error == null;

  bool contains(String item) =>
      raw.contains(item) || lines.any((l) => l.contains(item));

  List<String> dataLines() {
    final cleaned = <String>[];
    for (final l in lines) {
      var s = l.trim();
      if (_hexLineRegex.hasMatch(s)) {
        s = s.replaceFirst(_framePrefixRegex, '');
        cleaned.add(s.replaceAll(' ', '').toUpperCase());
      }
    }
    return cleaned;
  }

  @override
  String toString() => raw;
}

String? classifyElmResponse(List<String> lines, {required bool prompt}) {
  final joined = lines.join(' ').toUpperCase();
  for (final l in lines) {
    final s = l.trim();
    if (_hexLineRegex.hasMatch(s)) {
      final clean = s
          .replaceFirst(_framePrefixRegex, '')
          .replaceAll(' ', '')
          .toUpperCase();
      if (clean.startsWith('7F') && clean.length >= 4) {
        final sid = clean.substring(2, 4);
        final nrc = clean.length >= 6 ? clean.substring(4, 6) : '';
        return 'NEGATIVE RESPONSE 7F $sid $nrc'.trim();
      }
    }
  }
  if (lines.any((l) => _hexLineRegex.hasMatch(l.trim()))) {
    return null;
  }
  const errorTokens = [
    'UNABLE TO CONNECT',
    'BUS INIT: ...ERROR',
    'BUS INIT:...ERROR',
    'BUS ERROR',
    'CAN ERROR',
    'FB ERROR',
    'DATA ERROR',
    'BUFFER FULL',
    'NO DATA',
    'STOPPED',
    'ERROR',
  ];
  for (final token in errorTokens) {
    if (joined.contains(token)) {
      return token.contains('BUS INIT') ? 'UNABLE TO CONNECT' : token;
    }
  }
  if (joined.contains('?')) {
    return '?';
  }
  if (!prompt) {
    return 'TIMEOUT';
  }
  final trimmed = joined.trim();
  if (trimmed.isEmpty ||
      trimmed == 'OK' ||
      trimmed.contains('ELM') ||
      trimmed.endsWith('V')) {
    return null;
  }
  return 'INVALID';
}

Uint8List? hexToBytes(String hex) {
  final clean = hex.replaceAll(' ', '');
  if (clean.length.isOdd) return null;
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final b = int.tryParse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    if (b == null) return null;
    out[i] = b;
  }
  return out;
}

/// Procura '4X PP' (ou '61 PP' no modo 21 / '62 PP PP' no modo 22) e retorna [nbytes] de dados.
Uint8List? extractPayload(ElmResponse resp, int mode, int pid, int nbytes) {
  final modeHex = (mode + 0x40).toRadixString(16).toUpperCase().padLeft(2, '0');
  final pidHex = (mode == 0x22 || pid > 0xFF)
      ? pid.toRadixString(16).toUpperCase().padLeft(4, '0')
      : pid.toRadixString(16).toUpperCase().padLeft(2, '0');
  final header = '$modeHex$pidHex';
  final hlen = header.length;

  final dlines = resp.dataLines();
  for (var i = 0; i < dlines.length; i++) {
    final s = dlines[i];
    var idx = s.indexOf(header);
    while (idx != -1 && idx.isOdd) {
      idx = s.indexOf(header, idx + 1);
    }
    if (idx == -1) continue;

    final tailBuf = StringBuffer(s.substring(idx + hlen));
    for (var j = i + 1; j < dlines.length; j++) {
      if (tailBuf.length >= 2 * nbytes) break;
      final extra = dlines[j];
      if (extra.startsWith(header)) {
        tailBuf.write(extra.substring(hlen));
      } else {
        tailBuf.write(extra);
      }
    }
    final tail = tailBuf.toString();
    if (tail.length >= 2 * nbytes) {
      return hexToBytes(tail.substring(0, 2 * nbytes));
    }
  }
  return null;
}

class Elm327Client {
  final ObdTransport transport;
  final Duration defaultTimeout;
  final void Function(String message)? log;

  bool rawLog = false;
  String version = '';
  bool fastReply = false;

  Elm327Client(
    this.transport, {
    this.defaultTimeout = const Duration(seconds: 2),
    this.log,
  });

  Future<ElmResponse> command(String cmd, {Duration? timeout}) async {
    await transport.flushInput();
    await transport.write(ascii.encode('$cmd\r'));
    final (:data, :promptReceived) =
        await transport.readUntilPrompt(timeout ?? defaultTimeout);

    final text = ascii
        .decode(data, allowInvalid: true)
        .replaceAll('>', '')
        .replaceAll('\x00', '');
    final lines = text
        .split(RegExp(r'[\r\n]+'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    final cmdNorm = cmd.replaceAll(' ', '').toUpperCase();
    final cleaned = <String>[];
    for (final l in lines) {
      final u = l.replaceAll(' ', '').toUpperCase();
      if (u == cmdNorm) continue;
      if (u.startsWith('SEARCHING')) continue;
      if (u.contains('BUSINIT') && !u.contains('ERROR')) continue;
      cleaned.add(l);
    }

    final resp = ElmResponse(
      cmd,
      lines: cleaned,
      error: classifyElmResponse(cleaned, prompt: promptReceived),
      raw: text,
    );
    if (rawLog) {
      final rx = lines.isNotEmpty ? lines.join(' / ') : '-';
      log?.call('TX $cmd | RX $rx${resp.error != null ? "  [${resp.error}]" : ""}');
    }
    return resp;
  }

  Future<void> initializeAdapter({bool Function()? shouldStop}) async {
    final isDemo = transport.name == 'Demo';
    for (final (cmd, tmo) in elmInitSequence) {
      if (shouldStop != null && shouldStop()) {
        throw const TransportException('Cancelado');
      }
      final r = await command(cmd, timeout: tmo);
      log?.call('> ${cmd.padRight(6)} -> ${r.lines.isNotEmpty ? r.lines.join(" / ") : "(vazio)"}');
      if (cmd == 'ATZ') {
        version = r.lines.firstWhere(
          (l) => l.toUpperCase().contains('ELM'),
          orElse: () => '',
        );
        if (!isDemo) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
        await transport.flushInput();
        await command('ATE0', timeout: const Duration(seconds: 2));
      } else if (r.error == 'TIMEOUT') {
        throw TransportException('Adaptador não respondeu a $cmd');
      }
    }
  }

  Future<ElmResponse> initialize({bool Function()? shouldStop}) async {
    await initializeAdapter(shouldStop: shouldStop);
    final r = await command('0100', timeout: const Duration(seconds: 12));
    log?.call(
      '> 0100   -> ${r.lines.isNotEmpty ? r.lines.join(" / ") : "(vazio)"}'
      '${r.error != null ? "  [${r.error}]" : ""}',
    );
    return r;
  }

  Future<ElmResponse> queryPid(String cmd, {Duration? timeout}) =>
      command('$cmd${fastReply ? "1" : ""}', timeout: timeout);

  Future<double?> batteryVoltage() async {
    final r = await command('ATRV', timeout: const Duration(milliseconds: 1500));
    final re = RegExp(r'(\d+(?:\.\d+)?)\s*V');
    for (final l in r.lines) {
      final m = re.firstMatch(l.toUpperCase());
      if (m != null) {
        return double.tryParse(m.group(1)!);
      }
    }
    return null;
  }
}
