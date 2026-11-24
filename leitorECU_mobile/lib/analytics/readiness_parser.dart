import 'package:leitorecu_mobile/core/models/vehicle_profile.dart';

import 'dtc_parser.dart';

/// Decodifica os 4 bytes do PID 0101 (I/M Readiness / Status de Emissões SAE J1979).
ReadinessReport parseReadinessPid01(List<int> data) {
  final b = List<int>.from(data);
  while (b.length < 4) {
    b.add(0);
  }

  final byteA = b[0];
  final byteB = b[1];
  final byteC = b[2];
  final byteD = b[3];

  final milOn = (byteA & 0x80) != 0;
  final dtcCount = byteA & 0x7F;
  final isCompression = (byteB & 0x08) != 0;

  final monitors = <ReadinessItem>[
    // Monitores contínuos (Byte B)
    ReadinessItem(
      name: 'Falhas de Combustão (Misfire)',
      supported: (byteB & 0x01) != 0,
      completed: (byteB & 0x10) == 0,
    ),
    ReadinessItem(
      name: 'Sistema de Combustível (Fuel System)',
      supported: (byteB & 0x02) != 0,
      completed: (byteB & 0x20) == 0,
    ),
    ReadinessItem(
      name: 'Componentes Globais (Comprehensive)',
      supported: (byteB & 0x04) != 0,
      completed: (byteB & 0x40) == 0,
    ),
  ];

  if (!isCompression) {
    // Ciclo Otto (Gasolina / Etanol / Flex)
    monitors.addAll([
      ReadinessItem(
        name: 'Eficiência do Catalisador',
        supported: (byteC & 0x01) != 0,
        completed: (byteC & 0x10) == 0,
      ),
      ReadinessItem(
        name: 'Catalisador Aquecido',
        supported: (byteC & 0x02) != 0,
        completed: (byteC & 0x20) == 0,
      ),
      ReadinessItem(
        name: 'Sistema Evaporativo (EVAP / Cânister)',
        supported: (byteC & 0x04) != 0,
        completed: (byteC & 0x40) == 0,
      ),
      ReadinessItem(
        name: 'Sistema de Ar Secundário',
        supported: (byteC & 0x08) != 0,
        completed: (byteC & 0x80) == 0,
      ),
      ReadinessItem(
        name: 'Refrigerante do A/C',
        supported: (byteD & 0x01) != 0,
        completed: (byteD & 0x10) == 0,
      ),
      ReadinessItem(
        name: 'Sensores de Oxigênio (Sonda Lambda)',
        supported: (byteD & 0x02) != 0,
        completed: (byteD & 0x20) == 0,
      ),
      ReadinessItem(
        name: 'Aquecedor da Sonda Lambda',
        supported: (byteD & 0x04) != 0,
        completed: (byteD & 0x40) == 0,
      ),
      ReadinessItem(
        name: 'Sistema EGR / VVT',
        supported: (byteD & 0x08) != 0,
        completed: (byteD & 0x80) == 0,
      ),
    ]);
  } else {
    // Ciclo Diesel
    monitors.addAll([
      ReadinessItem(
        name: 'Catalisador NMHC',
        supported: (byteC & 0x01) != 0,
        completed: (byteC & 0x10) == 0,
      ),
      ReadinessItem(
        name: 'Pós-Tratamento NOx',
        supported: (byteC & 0x02) != 0,
        completed: (byteC & 0x20) == 0,
      ),
      ReadinessItem(
        name: 'Pressão de Sobrealimentação (Turbo)',
        supported: (byteC & 0x08) != 0,
        completed: (byteC & 0x80) == 0,
      ),
      ReadinessItem(
        name: 'Sensor de Gases de Escape',
        supported: (byteD & 0x02) != 0,
        completed: (byteD & 0x20) == 0,
      ),
      ReadinessItem(
        name: 'Filtro de Partículas (DPF)',
        supported: (byteD & 0x04) != 0,
        completed: (byteD & 0x40) == 0,
      ),
      ReadinessItem(
        name: 'Sistema EGR / VVT',
        supported: (byteD & 0x08) != 0,
        completed: (byteD & 0x80) == 0,
      ),
    ]);
  }

  final readyCount =
      monitors.where((m) => m.supported && m.completed).length;
  final supportedCount = monitors.where((m) => m.supported).length;

  return ReadinessReport(
    milOn: milOn,
    isCompression: isCompression,
    dtcCount: dtcCount,
    readyCount: readyCount,
    supportedCount: supportedCount,
    monitors: monitors,
  );
}

/// Extrai DTC causador e sensores gravados no Freeze Frame (Modo 02).
FreezeFrameData parseFreezeFrame(List<String> lines) {
  var dtcCode = 'Nenhum';
  final values = <String, double>{};

  for (final line in lines) {
    final clean = line.replaceAll(' ', '').toUpperCase();
    if (clean.contains('4202')) {
      final idx = clean.indexOf('4202') + 4;
      if (idx + 4 <= clean.length) {
        final hexDtc = clean.substring(idx, idx + 4);
        if (hexDtc != '0000') {
          dtcCode = decodeDtc(hexDtc);
        }
      }
    } else if (clean.contains('420C')) {
      final idx = clean.indexOf('420C') + 4;
      if (idx + 4 <= clean.length) {
        final raw = int.tryParse(clean.substring(idx, idx + 4), radix: 16);
        if (raw != null) values['rpm'] = raw / 4.0;
      }
    } else if (clean.contains('420D')) {
      final idx = clean.indexOf('420D') + 4;
      if (idx + 2 <= clean.length) {
        final raw = int.tryParse(clean.substring(idx, idx + 2), radix: 16);
        if (raw != null) values['speed'] = raw.toDouble();
      }
    } else if (clean.contains('4205')) {
      final idx = clean.indexOf('4205') + 4;
      if (idx + 2 <= clean.length) {
        final raw = int.tryParse(clean.substring(idx, idx + 2), radix: 16);
        if (raw != null) values['ect'] = (raw - 40).toDouble();
      }
    } else if (clean.contains('420B')) {
      final idx = clean.indexOf('420B') + 4;
      if (idx + 2 <= clean.length) {
        final raw = int.tryParse(clean.substring(idx, idx + 2), radix: 16);
        if (raw != null) values['map'] = raw.toDouble();
      }
    } else if (clean.contains('4204')) {
      final idx = clean.indexOf('4204') + 4;
      if (idx + 2 <= clean.length) {
        final raw = int.tryParse(clean.substring(idx, idx + 2), radix: 16);
        if (raw != null) {
          values['load'] = ((raw * 100.0 / 255.0) * 10.0).roundToDouble() / 10.0;
        }
      }
    }
  }

  return FreezeFrameData(dtc: dtcCode, values: values);
}
