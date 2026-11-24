/// Blocos de Medição VAG (KWP2000 sobre linha K, serviço 21 = readDataByLocalIdentifier).
///
/// Port exato das fórmulas 0x01..0x46 e rótulos conhecidos de `obd_app/vag.py`.
library;

import 'dart:typed_data';

import '../elm327/elm327_client.dart';

typedef VagFormulaFn = double? Function(int a, int b);

final Map<int, (VagFormulaFn fn, String unit)> _vagFormulas = {
  0x01: ((a, b) => 0.2 * a * b, 'rpm'),
  0x02: ((a, b) => 0.002 * a * b, '%'),
  0x03: ((a, b) => 0.002 * a * b, '°'),
  0x04: ((a, b) => (b - 127).abs() * 0.01 * a * (b < 127 ? -1.0 : 1.0), '°'),
  0x05: ((a, b) => a * (b - 100) * 0.1, '°C'),
  0x06: ((a, b) => 0.001 * a * b, 'V'),
  0x07: ((a, b) => 0.01 * a * b, 'km/h'),
  0x08: ((a, b) => 0.1 * a * b, ''),
  0x09: ((a, b) => (b - 127) * 0.02 * a, '°'),
  0x0A: ((a, b) => b == 0 ? 0.0 : 1.0, '0=frio/1=quente'),
  0x0B: ((a, b) => 0.0001 * a * (b - 128) + 1.0, 'λ'),
  0x0C: ((a, b) => 0.001 * a * b, 'Ω'),
  0x0D: ((a, b) => (b - 127) * 0.001 * a, 'mm'),
  0x0E: ((a, b) => 0.005 * a * b, 'bar'),
  0x0F: ((a, b) => 0.01 * a * b, 'ms'),
  0x10: ((a, b) => a != 0 ? (b & a).toDouble() : b.toDouble(), 'bits'),
  0x11: ((a, b) => (a * 256 + b).toDouble(), 'txt'),
  0x12: ((a, b) => 0.04 * a * b, 'mbar'),
  0x13: ((a, b) => 0.01 * a * b, 'l'),
  0x14: ((a, b) => a * (b - 128) / 128.0, '%'),
  0x15: ((a, b) => 0.001 * a * b, 'V'),
  0x16: ((a, b) => 0.001 * a * b, 'ms'),
  0x17: ((a, b) => (b / 256.0) * a, '%'),
  0x18: ((a, b) => 0.001 * a * b, 'A'),
  0x19: ((a, b) => b * 1.421 + a / 182.0, 'g/s'),
  0x1A: ((a, b) => (b - a).toDouble(), '°C'),
  0x1B: ((a, b) => (b - 128) * 0.01 * a, '°'),
  0x1C: ((a, b) => (b - a).toDouble(), ''),
  0x1D: ((a, b) => b < a ? 1.0 : 2.0, 'mapa'),
  0x1E: ((a, b) => (b / 12.0) * a, '°KW'),
  0x1F: ((a, b) => (b / 2560.0) * a, '°C'),
  0x20: ((a, b) => (b > 128 ? b - 256 : b).toDouble(), ''),
  0x21: ((a, b) => a == 0 ? 100.0 * b : 100.0 * b / a, '%'),
  0x22: ((a, b) => (b - 128) * 0.01 * a, '°KW'),
  0x23: ((a, b) => 0.01 * a * b, 'l/h'),
  0x24: ((a, b) => (a * 2560 + b * 10).toDouble(), 'km'),
  0x25: ((a, b) => (a * 256 + b).toDouble(), 'cod'),
  0x26: ((a, b) => (b - 128) * 0.001 * a, '°KW'),
  0x27: ((a, b) => (b / 256.0) * a, 'mg/h'),
  0x28: ((a, b) => b * 0.1 + 25.5 * a - 400.0, 'A'),
  0x29: ((a, b) => (b + a * 255).toDouble(), 'Ah'),
  0x2A: ((a, b) => b * 0.1 + 25.5 * a - 400.0, 'kW'),
  0x2B: ((a, b) => b * 0.1 + 25.5 * a, 'V'),
  0x2C: ((a, b) => (a * 60 + b).toDouble(), 'min'),
  0x2D: ((a, b) => 0.1 * a * b / 100.0, ''),
  0x2E: ((a, b) => (a * b - 3200) * 0.0027, '°KW'),
  0x2F: ((a, b) => ((b - 128) * a).toDouble(), 'ms'),
  0x30: ((a, b) => (b + a * 255).toDouble(), ''),
  0x31: ((a, b) => (b / 4.0) * a * 0.1, 'mg/h'),
  0x32: ((a, b) => a == 0 ? null : (b - 128) / (0.01 * a), 'mbar'),
  0x33: ((a, b) => ((b - 128) / 255.0) * a, 'mg/h'),
  0x34: ((a, b) => b * 0.02 * a - a, 'Nm'),
  0x35: ((a, b) => (b - 128) * 1.4222 + 0.006 * a, 'g/s'),
  0x36: ((a, b) => (a * 256 + b).toDouble(), 'cont'),
  0x37: ((a, b) => a * b / 200.0, 's'),
  0x38: ((a, b) => (a * 256 + b).toDouble(), 'WSC'),
  0x39: ((a, b) => (a * 256 + b + 65536).toDouble(), 'WSC'),
  0x3A: ((a, b) => b > 128 ? 1.0225 * (b - 256) : 1.0225 * b, '/s'),
  0x3B: ((a, b) => (a * 256 + b) / 32768.0, 'λ'),
  0x3C: ((a, b) => (a * 256 + b) * 0.01, 's'),
  0x3D: ((a, b) => a == 0 ? null : (b - 128) / a, ''),
  0x3E: ((a, b) => 0.256 * a * b, 's'),
  0x3F: ((a, b) => (a * 256 + b).toDouble(), 'txt'),
  0x40: ((a, b) => (a + b).toDouble(), 'Ω'),
  0x41: ((a, b) => 0.01 * a * (b - 127), 'mm'),
  0x42: ((a, b) => a * b / 511.12, 'V'),
  0x43: ((a, b) => 640.0 * a + b * 2.5, '°'),
  0x44: ((a, b) => (256 * a + b) / 7.365, '°/s'),
  0x45: ((a, b) => (256 * a + b) * 0.3254, 'bar'),
  0x46: ((a, b) => (256 * a + b) * 0.192, 'm/s²'),
};

const Map<(int, int), String> vagKnownLabels = {
  (1, 1): 'RPM',
  (1, 2): 'Temp. motor',
  (1, 3): 'Correção lambda',
  (1, 4): 'Cond. ajuste básico',
  (2, 1): 'RPM',
  (2, 2): 'Carga',
  (2, 3): 'Tempo injeção',
  (2, 4): 'Pressão coletor',
  (3, 1): 'RPM',
  (3, 2): 'Pressão coletor',
  (3, 3): 'Borboleta',
  (3, 4): 'Avanço',
  (4, 1): 'RPM',
  (4, 2): 'Bateria',
  (4, 3): 'Temp. motor',
  (4, 4): 'Temp. ar',
  (5, 1): 'RPM',
  (5, 2): 'Carga',
  (5, 3): 'Velocidade',
  (5, 4): 'Estado operação',
  (6, 1): 'RPM',
  (6, 2): 'Carga',
  (6, 3): 'Temp. ar',
  (6, 4): 'Correção altitude',
  (10, 1): 'RPM',
  (10, 2): 'Carga',
  (10, 3): 'Borboleta',
  (10, 4): 'Avanço',
  (14, 1): 'RPM',
  (14, 2): 'Carga',
  (14, 3): 'Falhas combustão total',
  (15, 1): 'Falhas cil. 1',
  (15, 2): 'Falhas cil. 2',
  (15, 3): 'Falhas cil. 3',
  (16, 1): 'Falhas cil. 4',
  (20, 1): 'Retardo detonação cil. 1',
  (20, 2): 'Retardo detonação cil. 2',
  (20, 3): 'Retardo detonação cil. 3',
  (20, 4): 'Retardo detonação cil. 4',
  (22, 1): 'RPM',
  (22, 2): 'Carga',
  (22, 3): 'Retardo cil. 1',
  (22, 4): 'Retardo cil. 2',
  (23, 1): 'RPM',
  (23, 2): 'Carga',
  (23, 3): 'Retardo cil. 3',
  (23, 4): 'Retardo cil. 4',
  (26, 1): 'Sensor detonação cil. 1',
  (26, 2): 'Sensor detonação cil. 2',
  (26, 3): 'Sensor detonação cil. 3',
  (26, 4): 'Sensor detonação cil. 4',
  (28, 1): 'RPM',
  (28, 2): 'Carga',
  (28, 3): 'Temp. motor',
  (28, 4): 'Teste sensor detonação',
  (31, 1): 'Sonda 1 (tensão)',
  (31, 2): 'Lambda especificado',
  (32, 1): 'Adaptação lambda lenta',
  (32, 2): 'Adaptação lambda parcial',
  (32, 3): 'Fator adaptação mistura',
  (32, 4): 'Tensão referência ECU',
  (33, 1): 'Correção sonda (STFT)',
  (33, 2): 'Sonda 1 (tensão)',
  (34, 1): 'RPM',
  (34, 2): 'Temp. catalisador (modelo)',
  (36, 1): 'Sonda 2 pós-cat (tensão)',
  (36, 2): 'Temp. sonda 2',
  (36, 3): 'Fator lambda 2',
  (36, 4): 'Status sonda 2',
  (37, 1): 'Carga',
  (37, 2): 'Sonda 2 (tensão)',
  (37, 3): 'Delta lambda',
  (37, 4): 'Status diagnose cat.',
  (50, 1): 'RPM real',
  (50, 2): 'RPM especificada',
  (50, 3): 'Solicitação A/C',
  (50, 4): 'Compressor A/C',
  (54, 1): 'RPM',
  (54, 2): 'Estado operação',
  (54, 3): 'Pedal acelerador',
  (54, 4): 'Borboleta',
  (57, 1): 'RPM real',
  (57, 2): 'RPM especificada',
  (57, 3): 'Compressor A/C',
  (57, 4): 'Pressão/Torque A/C',
  (58, 1): 'Carga',
  (58, 2): 'Pressão A/C',
  (58, 3): 'Temp. motor',
  (58, 4): 'Status A/C',
  (60, 1): 'Borboleta sensor 1',
  (60, 2): 'Borboleta sensor 2',
  (60, 3): 'Passo adaptação EPC',
  (60, 4): 'Status adaptação EPC',
  (62, 1): 'Borboleta sensor 1',
  (62, 2): 'Borboleta sensor 2',
  (62, 3): 'Pedal sensor 1',
  (62, 4): 'Pedal sensor 2',
  (64, 1): 'Tensão mín. TPS 1',
  (64, 2): 'Tensão mín. TPS 2',
  (64, 3): 'Tensão emergência TPS 1',
  (64, 4): 'Tensão emergência TPS 2',
  (70, 1): 'Válvula EVAP (purga)',
  (70, 2): 'Desvio reg. lambda EVAP',
  (70, 3): 'Fator reg. EVAP',
  (70, 4): 'Status teste EVAP',
  (86, 1): 'Readiness Bits 1',
  (86, 2): 'Readiness Bits 2',
  (86, 3): 'Readiness Bits 3',
  (86, 4): 'Readiness Bits 4',
  (99, 1): 'RPM',
  (99, 2): 'Temp. motor',
  (99, 3): 'Correção lambda (STFT)',
  (99, 4): 'Status regulação lambda',
  (100, 1): 'Bits diagnóstico 1',
  (100, 2): 'Temp. motor',
  (100, 3): 'Tempo ciclo',
  (100, 4): 'Bits diagnóstico 2',
  (101, 1): 'RPM',
  (101, 2): 'Carga',
  (101, 3): 'Tempo injeção',
  (101, 4): 'Pressão coletor',
  (103, 1): 'Teor Etanol Flex (C1)',
  (103, 2): 'Adaptação Flex (C2)',
  (103, 5): 'Fator Carga / Etanol Dinâmico',
  (103, 6): 'Adaptação Flex Fixa',
  (103, 7): 'Correção Partida Flex',
  (103, 8): 'Status Reconhecimento Flex',
  (107, 1): 'RPM',
  (107, 2): 'Correção lambda',
  (107, 3): 'Adaptação mistura',
  (107, 4): 'Status regulação',
  (110, 1): 'RPM',
  (110, 2): 'Temp. motor',
  (110, 3): 'Tempo injeção',
  (110, 4): 'Correção carga / AF Álcool',
  (114, 1): 'Carga especificada',
  (114, 2): 'Carga corrigida',
  (114, 3): 'Carga real',
  (114, 4): 'Wastegate / N75 Duty Cycle',
  (115, 1): 'RPM',
  (115, 2): 'Carga do motor',
  (115, 3): 'Pressão turbo especificada',
  (115, 4): 'Pressão turbo real',
  (118, 1): 'RPM',
  (118, 2): 'Temp. ar admissão (IAT)',
  (118, 3): 'Wastegate / N75 Duty Cycle',
  (118, 4): 'Pressão turbo real',
  (120, 1): 'RPM',
  (120, 2): 'Torque especificado',
  (120, 3): 'Torque real motor',
  (120, 4): 'Status ASR/Torque',
};

(double, String)? decodeVagCell(int k, int a, int b) {
  if (k == 0x00 || (k == 0x25 && a == 0 && b == 0)) {
    return null;
  }
  final entry = _vagFormulas[k];
  if (entry == null) {
    final raw = (a * 256 + b).toDouble();
    final hexK = k.toRadixString(16).toUpperCase().padLeft(2, '0');
    return (raw, 'raw$hexK');
  }
  final val = entry.$1(a, b);
  if (val == null || val.isNaN || val.isInfinite) {
    return null;
  }
  return (val, entry.$2);
}

final RegExp _linePrefixRe = RegExp(r'^[0-9A-F]{1,2}:');

/// Extrai todas as células completas (múltiplos de 3 bytes) de uma resposta `61 GG ...`.
Uint8List? extractVagBlock(ElmResponse resp, int group) {
  final header = '61${group.toRadixString(16).toUpperCase().padLeft(2, '0')}';
  final dlines = resp.dataLines();
  final buf = StringBuffer();
  var found = false;

  for (final rawLine in dlines) {
    var lineClean = rawLine.replaceAll(' ', '').toUpperCase();
    lineClean = lineClean.replaceFirst(_linePrefixRe, '');
    if (!found) {
      var idx = lineClean.indexOf(header);
      while (idx != -1 && idx.isOdd) {
        idx = lineClean.indexOf(header, idx + 1);
      }
      if (idx != -1) {
        found = true;
        buf.write(lineClean.substring(idx + 4));
      }
    } else {
      if (lineClean.startsWith(header)) {
        buf.write(lineClean.substring(header.length));
      } else {
        buf.write(lineClean);
      }
    }
  }

  final payloadHex = buf.toString();
  if (!found || payloadHex.isEmpty) return null;

  final n = (payloadHex.length ~/ 6) * 6;
  if (n == 0) return null;
  return hexToBytes(payloadHex.substring(0, n));
}

bool isVagNegative(ElmResponse resp, {int service = 0x21}) {
  final tag = '7F${service.toRadixString(16).toUpperCase().padLeft(2, '0')}';
  if (resp.error != null &&
      resp.error!.replaceAll(' ', '').toUpperCase().contains(tag)) {
    return true;
  }
  return resp
      .dataLines()
      .any((l) => l.replaceAll(' ', '').toUpperCase().contains(tag));
}

String vagChannelKey(int group, int cell) =>
    'g${group.toString().padLeft(3, '0')}_c$cell';

String vagChannelLabel(int group, int cell, String unit) {
  final name = vagKnownLabels[(group, cell)];
  final base =
      'Bloco ${group.toString().padLeft(3, '0')}.$cell${name != null ? " $name" : ""}';
  return unit.isNotEmpty ? '$base [$unit]' : base;
}

Map<String, (double, String)> decodeVagBlock(int group, Uint8List data) {
  final out = <String, (double, String)>{};
  for (var i = 0; i + 2 < data.length; i += 3) {
    final decoded = decodeVagCell(data[i], data[i + 1], data[i + 2]);
    if (decoded != null) {
      out[vagChannelKey(group, (i ~/ 3) + 1)] = decoded;
    }
  }
  return out;
}
