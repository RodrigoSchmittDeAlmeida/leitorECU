/// Definição de PIDs OBD-II Modo 01 e Blocos de Medição VW KWP2000 Modo 21.
library;

import 'dart:typed_data';

import 'vag_formulas.dart';

double _trim(int a) => ((a - 128) * 100.0) / 128.0;

double _roundTo(double v, int decimals) {
  final factor = switch (decimals) {
    1 => 10.0,
    2 => 100.0,
    3 => 1000.0,
    _ => 1.0,
  };
  return (v * factor).roundToDouble() / factor;
}

Map<String, double> decLambdaNb(Uint8List d) {
  final a = d[0];
  final b = d[1];
  final out = <String, double>{'lambda_v': a / 200.0};
  if (b != 0xFF) {
    final t = _trim(b);
    out['lambda_trim'] = t;
    out['stft'] = t;
  }
  return out;
}

Map<String, double> decLambdaNb2(Uint8List d) {
  final a = d[0];
  final b = d[1];
  final out = <String, double>{'lambda2_v': a / 200.0};
  if (b != 0xFF) {
    out['lambda2_trim'] = _trim(b);
  }
  return out;
}

Map<String, double> decLambdaWbV(Uint8List d) {
  final eq = ((d[0] * 256) + d[1]) * 2.0 / 65536.0;
  final v = ((d[2] * 256) + d[3]) * 8.0 / 65536.0;
  final out = <String, double>{'lambda_eq': eq};
  if (v >= 0.005 && v <= 5.0) {
    out['lambda_v'] = v;
  }
  return out;
}

Map<String, double> decLambdaWbI(Uint8List d) {
  final eq = ((d[0] * 256) + d[1]) * 2.0 / 65536.0;
  return {'lambda_eq': eq};
}

Map<String, double> decVagGroup33(Uint8List d) {
  final out = <String, double>{};
  final c1 = decodeVagCell(d[0], d[1], d[2]);
  final c2 = decodeVagCell(d[3], d[4], d[5]);
  if (c1 != null && c1.$2 == '%') {
    out['lambda_trim'] = c1.$1;
    out['stft'] = c1.$1;
  } else if (c1 != null && (c1.$2 == 'V' || c1.$2 == 'lambda' || c1.$2 == 'λ')) {
    out['lambda_v'] = c1.$1;
  }
  if (c2 != null && (c2.$2 == 'V' || c2.$2 == 'lambda' || c2.$2 == 'λ')) {
    out['lambda_v'] = c2.$1;
  } else if (c2 != null && c2.$2 == '%' && !out.containsKey('stft')) {
    out['lambda_trim'] = c2.$1;
    out['stft'] = c2.$1;
  }
  return out;
}

Map<String, double> decVagGroup32(Uint8List d) {
  final out = <String, double>{};
  final c1 = decodeVagCell(d[0], d[1], d[2]);
  final c2 = decodeVagCell(d[3], d[4], d[5]);
  if (c1 != null && c1.$2 == '%') {
    out['ltft_idle'] = c1.$1;
  }
  if (c2 != null && c2.$2 == '%') {
    out['ltft'] = c2.$1;
  } else if (c1 != null && c1.$2 == '%') {
    out['ltft'] = c1.$1;
  }
  if (d.length >= 12) {
    final c4 = decodeVagCell(d[9], d[10], d[11]);
    if (c4 != null && c4.$2 == 'V' && c4.$1 >= 5.0 && c4.$1 <= 18.0) {
      out['ecu_volt'] = c4.$1;
      out.putIfAbsent('battery', () => c4.$1);
    }
  }
  return out;
}

Map<String, double> decVagGroup31(Uint8List d) {
  final c1 = decodeVagCell(d[0], d[1], d[2]);
  return c1 != null ? {'lambda_v': c1.$1} : const {};
}

Map<String, double> decVagGroup01(Uint8List d) {
  final out = <String, double>{};
  if (d.length >= 9) {
    final c1 = decodeVagCell(d[0], d[1], d[2]);
    final c2 = decodeVagCell(d[3], d[4], d[5]);
    final c3 = decodeVagCell(d[6], d[7], d[8]);
    if (c1 != null && c1.$2 == 'rpm') out['rpm'] = c1.$1;
    if (c2 != null && (c2.$2 == '°C' || c2.$2 == 'C')) out['ect'] = c2.$1;
    if (c3 != null && c3.$2 == '%') {
      out['lambda_trim'] = c3.$1;
      out['stft'] = c3.$1;
    } else if (c3 != null && (c3.$2 == 'V' || c3.$2 == 'lambda' || c3.$2 == 'λ')) {
      out['lambda_v'] = c3.$1;
    }
  }
  return out;
}

Map<String, double> decVagGroup02(Uint8List d) {
  final out = <String, double>{};
  if (d.length >= 12) {
    final c1 = decodeVagCell(d[0], d[1], d[2]);
    final c2 = decodeVagCell(d[3], d[4], d[5]);
    final c3 = decodeVagCell(d[6], d[7], d[8]);
    final c4 = decodeVagCell(d[9], d[10], d[11]);
    if (c1 != null && c1.$2 == 'rpm') out['rpm'] = c1.$1;
    if (c2 != null && c2.$2 == '%') out['load'] = c2.$1;
    if (c3 != null && c3.$2.contains('ms')) {
      out['inj_ms'] = c3.$1;
      out['inj_pulse_width'] = c3.$1;
    }
    if (c4 != null && c4.$2 == 'mbar') {
      out['map'] = c4.$1 / 10.0;
    }
  }
  return out;
}

Map<String, double> decVagGroup03(Uint8List d) {
  final out = <String, double>{};
  if (d.length >= 12) {
    final c1 = decodeVagCell(d[0], d[1], d[2]);
    final c2 = decodeVagCell(d[3], d[4], d[5]);
    final c3 = decodeVagCell(d[6], d[7], d[8]);
    final c4 = decodeVagCell(d[9], d[10], d[11]);
    if (c1 != null && c1.$2 == 'rpm') out['rpm'] = c1.$1;
    if (c2 != null && c2.$2 == 'mbar') out['map'] = c2.$1 / 10.0;
    if (c3 != null && c3.$2 == '%') out['tps'] = c3.$1;
    if (c4 != null && (c4.$2 == '°' || c4.$2 == 'deg' || c4.$2 == '°KW')) {
      out['advance'] = c4.$1;
    }
  }
  return out;
}

Map<String, double> decVagGroup04(Uint8List d) {
  final out = <String, double>{};
  if (d.length >= 12) {
    final c1 = decodeVagCell(d[0], d[1], d[2]);
    final c2 = decodeVagCell(d[3], d[4], d[5]);
    final c3 = decodeVagCell(d[6], d[7], d[8]);
    final c4 = decodeVagCell(d[9], d[10], d[11]);
    if (c1 != null && c1.$2 == 'rpm') {
      out['rpm'] = c1.$1;
    } else if (c1 != null && c1.$2 == 'V') {
      out['battery'] = c1.$1;
      out['ecu_volt'] = c1.$1;
    }
    if (c2 != null && c2.$2 == 'V') {
      out['battery'] = c2.$1;
      out['ecu_volt'] = c2.$1;
    } else if (c2 != null && (c2.$2 == '°C' || c2.$2 == 'C')) {
      out['ect'] = c2.$1;
    }
    if (c3 != null && (c3.$2 == '°C' || c3.$2 == 'C')) {
      if (!out.containsKey('ect')) {
        out['ect'] = c3.$1;
      } else {
        out['iat'] = c3.$1;
      }
    }
    if (c4 != null && (c4.$2 == '°C' || c4.$2 == 'C')) {
      out['iat'] = c4.$1;
    }
  }
  return out;
}

Map<String, double> decVagGroup05(Uint8List d) {
  final out = <String, double>{};
  if (d.length >= 9) {
    final c1 = decodeVagCell(d[0], d[1], d[2]);
    final c2 = decodeVagCell(d[3], d[4], d[5]);
    final c3 = decodeVagCell(d[6], d[7], d[8]);
    if (c1 != null && c1.$2 == 'rpm') out['rpm'] = c1.$1;
    if (c2 != null && c2.$2 == '%') out['load'] = c2.$1;
    if (c3 != null && c3.$2 == 'km/h') out['speed'] = c3.$1;
  }
  if (d.length >= 12) {
    final b4 = d[11];
    if ((b4 & 0x08) != 0 || (b4 & 0x80) != 0) {
      out['fuel_sys1'] = 1.0; // Cut-Off / Schubabschaltung
    } else if ((b4 & 0x04) != 0) {
      out['fuel_sys1'] = 4.0; // WOT
    } else {
      out['fuel_sys1'] = 2.0; // Malha Fechada
    }
  }
  return out;
}

Map<String, double> decVagGroup20(Uint8List d) {
  final out = <String, double>{};
  final rets = <double>[];
  const keys = ['knock_ret_c1', 'knock_ret_c2', 'knock_ret_c3', 'knock_ret_c4'];
  for (var idx = 0; idx < keys.length; idx++) {
    final off = idx * 3;
    if (d.length >= off + 3) {
      final c = decodeVagCell(d[off], d[off + 1], d[off + 2]);
      if (c != null) {
        out[keys[idx]] = c.$1;
        rets.add(c.$1.abs());
      }
    }
  }
  if (rets.isNotEmpty) {
    out['knock_retard_max'] = rets.reduce((a, b) => a > b ? a : b);
  }
  return out;
}

Map<String, double> decVagGroup26(Uint8List d) {
  final out = <String, double>{};
  const keys = ['knock_v_c1', 'knock_v_c2', 'knock_v_c3', 'knock_v_c4'];
  for (var idx = 0; idx < keys.length; idx++) {
    final off = idx * 3;
    if (d.length >= off + 3) {
      final c = decodeVagCell(d[off], d[off + 1], d[off + 2]);
      if (c != null && c.$2 == 'V') {
        out[keys[idx]] = c.$1;
      }
    }
  }
  return out;
}

Map<String, double> decVagGroup62(Uint8List d) {
  final out = <String, double>{};
  if (d.length >= 12) {
    final c1 = decodeVagCell(d[0], d[1], d[2]);
    final c2 = decodeVagCell(d[3], d[4], d[5]);
    final c3 = decodeVagCell(d[6], d[7], d[8]);
    final c4 = decodeVagCell(d[9], d[10], d[11]);
    if (c1 != null && c1.$2 == '%') out['tps_track1'] = c1.$1;
    if (c2 != null && c2.$2 == '%') out['tps_track2'] = c2.$1;
    if (c3 != null && c3.$2 == '%') out['app_pedal_pct'] = c3.$1;
    if (c4 != null && c4.$2 == '%') out['app_track2'] = c4.$1;
  }
  return out;
}

Map<String, double> decVagGroup103(Uint8List d) {
  final out = <String, double>{};
  for (final cellIdx in const [4, 0, 5, 1]) {
    final off = cellIdx * 3;
    if (d.length >= off + 3) {
      final c = decodeVagCell(d[off], d[off + 1], d[off + 2]);
      if (c != null && c.$2 == '%' && c.$1 >= 0.0 && c.$1 <= 100.0) {
        out['flex_ethanol_pct'] = c.$1;
        out['ethanol'] = c.$1;
        break;
      }
    }
  }
  return out;
}

Map<String, double> decVagGroup114(Uint8List d) {
  final out = <String, double>{};
  if (d.length >= 12) {
    final c3 = decodeVagCell(d[6], d[7], d[8]);
    final c4 = decodeVagCell(d[9], d[10], d[11]);
    if (c3 != null && c3.$2 == '%') out['load'] = c3.$1;
    if (c4 != null && c4.$2 == '%') out['wastegate_pct'] = c4.$1;
  }
  return out;
}

bool _isPressureUnit(String u) =>
    u == 'mbar' || u == 'bar' || u == 'kPa' || u == 'kpa';

double _toKpa(double v, String u) {
  if (u == 'mbar') return v / 10.0;
  if (u == 'bar') return v * 100.0;
  return v;
}

Map<String, double> decVagGroup115(Uint8List d) {
  final out = <String, double>{};
  if (d.length >= 12) {
    final c1 = decodeVagCell(d[0], d[1], d[2]);
    final c2 = decodeVagCell(d[3], d[4], d[5]);
    final c3 = decodeVagCell(d[6], d[7], d[8]);
    final c4 = decodeVagCell(d[9], d[10], d[11]);
    if (c1 != null && c1.$2 == 'rpm') out['rpm'] = c1.$1;
    if (c2 != null && c2.$2 == '%') out['load'] = c2.$1;
    if (c3 != null && _isPressureUnit(c3.$2)) {
      final targetKpa = _toKpa(c3.$1, c3.$2);
      out['boost_target_abs_kpa'] = _roundTo(targetKpa, 1);
      out['boost_target_bar'] = _roundTo((targetKpa - 101.3) / 100.0, 3);
    }
    if (c4 != null && _isPressureUnit(c4.$2)) {
      final actualKpa = _toKpa(c4.$1, c4.$2);
      out['map'] = _roundTo(actualKpa, 1);
      out['boost_abs_kpa'] = _roundTo(actualKpa, 1);
      final relBar = (actualKpa - 101.3) / 100.0;
      out['boost_bar'] = _roundTo(relBar, 3);
      out['boost_psi'] = _roundTo(relBar * 14.5038, 2);
    }
  }
  return out;
}

Map<String, double> decVagGroup118(Uint8List d) {
  final out = <String, double>{};
  if (d.length >= 12) {
    final c1 = decodeVagCell(d[0], d[1], d[2]);
    final c2 = decodeVagCell(d[3], d[4], d[5]);
    final c3 = decodeVagCell(d[6], d[7], d[8]);
    final c4 = decodeVagCell(d[9], d[10], d[11]);
    if (c1 != null && c1.$2 == 'rpm') out['rpm'] = c1.$1;
    if (c2 != null && (c2.$2 == '°C' || c2.$2 == 'C')) out['iat'] = c2.$1;
    if (c3 != null && c3.$2 == '%') out['wastegate_pct'] = c3.$1;
    if (c4 != null && _isPressureUnit(c4.$2)) {
      final actualKpa = _toKpa(c4.$1, c4.$2);
      out['map'] = _roundTo(actualKpa, 1);
      final relBar = (actualKpa - 101.3) / 100.0;
      out['boost_bar'] = _roundTo(relBar, 3);
      out['boost_psi'] = _roundTo(relBar * 14.5038, 2);
    }
  }
  return out;
}

Map<String, double> decPid6E(Uint8List d) {
  if (d.isEmpty) return const {};
  final double p;
  if (d.length >= 5) {
    if ((d[0] & 0x01) != 0 || d[0] == 0) {
      p = d[1].toDouble();
    } else if ((d[0] & 0x02) != 0) {
      p = d[2].toDouble();
    } else {
      p = d[1].toDouble();
    }
  } else if (d.length >= 2) {
    p = (d[0] < 0x10 ? d[1] : d[0]).toDouble();
  } else {
    p = d[0].toDouble();
  }
  if (p >= 0.0 && p <= 500.0) {
    return {'turbo_inlet_kpa': p};
  }
  return const {};
}

Map<String, double> decPid6F(Uint8List d) {
  final out = <String, double>{};
  if (d.length >= 3) {
    final tgtKpa = ((d[1] * 256) + d[2]) * 0.03125;
    if (tgtKpa >= 0.0 && tgtKpa <= 600.0) {
      final rel = (tgtKpa - 101.325) / 100.0;
      out['boost_target_bar'] = _roundTo(rel < 0 ? 0.0 : rel, 3);
    }
  }
  if (d.length >= 2 && !out.containsKey('boost_target_bar')) {
    final wg = (d[1] * 100.0) / 255.0;
    if (wg >= 0.0 && wg <= 100.0) {
      out['wastegate_pct'] = _roundTo(wg, 1);
    }
  }
  return out;
}

Map<String, double> decPid70(Uint8List d) {
  final out = <String, double>{};
  if (d.isEmpty) return out;
  final support = d[0];
  if (d.length >= 3 && ((support & 0x01) != 0 || support == 0)) {
    final tgtKpa = ((d[1] * 256) + d[2]) * 0.03125;
    if (tgtKpa >= 0.0 && tgtKpa <= 600.0) {
      final rel = (tgtKpa - 101.325) / 100.0;
      out['boost_target_bar'] = _roundTo(rel < 0 ? 0.0 : rel, 3);
    }
  }
  if (d.length >= 5 && ((support & 0x02) != 0 || d.length >= 5)) {
    final actKpa = ((d[3] * 256) + d[4]) * 0.03125;
    if (actKpa >= 0.0 && actKpa <= 600.0) {
      final actBar = (actKpa - 101.325) / 100.0;
      out['boost_bar'] = _roundTo(actBar, 3);
      out['boost_psi'] = _roundTo(actBar * 14.5038, 2);
    }
  }
  if (d.length >= 10) {
    final wg = (d[9] * 100.0) / 255.0;
    if (wg >= 0.0 && wg <= 100.0) {
      out['wastegate_pct'] = _roundTo(wg, 1);
    }
  } else if (d.length >= 8) {
    final wg = (d[7] * 100.0) / 255.0;
    if (wg >= 0.0 && wg <= 100.0) {
      out['wastegate_pct'] = _roundTo(wg, 1);
    }
  }
  return out;
}

Map<String, double> decPid77(Uint8List d) {
  if (d.isEmpty) return const {};
  final double t;
  if (d.length >= 3 && (d[0] == 0x01 || d[0] == 0x02 || d[0] == 0x03)) {
    t = (d[1] - 40).toDouble();
  } else if (d.length >= 2 && d[0] < 0x10) {
    t = (d[1] - 40).toDouble();
  } else {
    t = (d[0] - 40).toDouble();
  }
  if (t >= -40.0 && t <= 215.0) {
    return {'cac_temp_c': t};
  }
  return const {};
}

class PidDef {
  final int pid;
  final int nbytes;
  final Map<String, double> Function(Uint8List data) decode;
  final String name;
  final int mode;
  final bool fast;
  final bool extra;
  final bool slow;

  const PidDef(
    this.pid,
    this.nbytes,
    this.decode,
    this.name, {
    this.mode = 0x01,
    this.fast = false,
    this.extra = false,
    this.slow = false,
  });

  int get key => mode == 0x01 ? pid : ((mode << 8) | pid);

  String get cmd =>
      '${mode.toRadixString(16).toUpperCase().padLeft(2, '0')}'
      '${pid.toRadixString(16).toUpperCase().padLeft(2, '0')}';
}

final Map<int, PidDef> obdPids = {
  for (final p in <PidDef>[
    PidDef(0x0C, 2, (d) => {'rpm': ((d[0] * 256) + d[1]) / 4.0}, 'RPM', fast: true),
    PidDef(0x0B, 1, (d) => {'map': d[0].toDouble()}, 'MAP', fast: true),
    PidDef(0x0E, 1, (d) => {'advance': (d[0] / 2.0) - 64.0}, 'Avanço', fast: true),
    PidDef(0x11, 1, (d) => {'tps': (d[0] * 100.0) / 255.0}, 'TPS', fast: true),
    // Sondas Modo 01
    PidDef(0x14, 2, decLambdaNb, 'Sonda Lambda B1S1 (0114)', fast: true),
    PidDef(0x15, 2, decLambdaNb2, 'Sonda Lambda B1S2 (0115)', fast: true),
    PidDef(0x16, 2, decLambdaNb, 'Sonda Lambda B1S3 (0116)', fast: true),
    PidDef(0x17, 2, decLambdaNb, 'Sonda Lambda B1S4 (0117)', fast: true),
    PidDef(0x18, 2, decLambdaNb, 'Sonda Lambda B2S1 (0118)', fast: true),
    PidDef(0x19, 2, decLambdaNb2, 'Sonda Lambda B2S2 (0119)', fast: true),
    PidDef(0x24, 4, decLambdaWbV, 'Sonda Lambda Eq/V (0124)', fast: true),
    PidDef(0x34, 4, decLambdaWbI, 'Sonda Lambda Eq/mA (0134)', fast: true),
    // Trims e ECT Modo 01
    PidDef(0x06, 1, (d) => {'stft': _trim(d[0])}, 'STFT'),
    PidDef(0x07, 1, (d) => {'ltft': _trim(d[0])}, 'LTFT', slow: true),
    PidDef(0x05, 1, (d) => {'ect': d[0] - 40.0}, 'ECT', slow: true),
    // Blocos VW KWP2000 (Modo 21)
    PidDef(0x21, 6, decVagGroup33, 'VW Bloco 033 Sonda+STFT (2121)', mode: 0x21, fast: true),
    PidDef(0x20, 6, decVagGroup32, 'VW Bloco 032 LTFT (2120)', mode: 0x21, slow: true),
    PidDef(0x1F, 3, decVagGroup31, 'VW Bloco 031 Sonda (211F)', mode: 0x21, fast: true),
    PidDef(0x01, 9, decVagGroup01, 'VW Bloco 001 RPM+ECT+STFT (2101)', mode: 0x21),
    PidDef(0x02, 12, decVagGroup02, 'VW Bloco 002 RPM+Carga+MAP (2102)', mode: 0x21, extra: true),
    PidDef(0x03, 12, decVagGroup03, 'VW Bloco 003 RPM+MAP+TPS+Avanço (2103)', mode: 0x21, fast: true),
    PidDef(0x04, 12, decVagGroup04, 'VW Bloco 004 RPM+Bat+ECT+IAT (2104)', mode: 0x21, slow: true),
    PidDef(0x05, 9, decVagGroup05, 'VW Bloco 005 RPM+Carga+Vel (2105)', mode: 0x21, extra: true),
    PidDef(0x14, 12, decVagGroup20, 'VW Bloco 020 Retardo Detonação (2114)', mode: 0x21, extra: true),
    PidDef(0x1A, 12, decVagGroup26, 'VW Bloco 026 Tensão Detonação (211A)', mode: 0x21, extra: true),
    PidDef(0x3E, 12, decVagGroup62, 'VW Bloco 062 Pistas TPS/APP (213E)', mode: 0x21, extra: true),
    PidDef(0x67, 15, decVagGroup103, 'VW Bloco 103 Adaptação Flex (2167)', mode: 0x21, extra: true, slow: true),
    PidDef(0x72, 12, decVagGroup114, 'VW Bloco 114 Carga+N75 (2172)', mode: 0x21, extra: true),
    PidDef(0x73, 12, decVagGroup115, 'VW Bloco 115 Pressão Turbo (2173)', mode: 0x21, fast: true),
    PidDef(0x76, 12, decVagGroup118, 'VW Bloco 118 IAT+N75+Boost (2176)', mode: 0x21, extra: true),
    // PIDs extras SAE J1979
    PidDef(0x04, 1, (d) => {'load': (d[0] * 100.0) / 255.0}, 'Carga', extra: true),
    PidDef(0x0D, 1, (d) => {'speed': d[0].toDouble()}, 'Velocidade', extra: true),
    PidDef(0x0F, 1, (d) => {'iat': d[0] - 40.0}, 'IAT', extra: true, slow: true),
    PidDef(
      0x01,
      4,
      (d) => {
        'mil_on': (d[0] & 0x80) != 0 ? 1.0 : 0.0,
        'dtc_count': (d[0] & 0x7F).toDouble(),
      },
      'Status Monitor (0101)',
      extra: true,
      slow: true,
    ),
    PidDef(
      0x03,
      2,
      (d) => {'fuel_sys1': d[0].toDouble(), 'fuel_sys2': d[1].toDouble()},
      'Status Malha Comb. (0103)',
      extra: true,
      slow: true,
    ),
    PidDef(0x13, 1, (d) => {'o2_mask': d[0].toDouble()}, 'Sensores O2 Presentes (0113)', extra: true, slow: true),
    PidDef(0x1C, 1, (d) => {'obd_std': d[0].toDouble()}, 'Padrão OBD (011C)', extra: true, slow: true),
    PidDef(0x21, 2, (d) => {'dist_mil': ((d[0] * 256) + d[1]).toDouble()}, 'Distância c/ MIL (0121)', extra: true, slow: true),
    PidDef(0x51, 1, (d) => {'fuel_type': d[0].toDouble()}, 'Tipo Combustível (0151)', extra: true, slow: true),
    PidDef(0x08, 1, (d) => {'stft_b2': _trim(d[0])}, 'STFT Banco 2 (0108)', extra: true, slow: true),
    PidDef(0x09, 1, (d) => {'ltft_b2': _trim(d[0])}, 'LTFT Banco 2 (0109)', extra: true, slow: true),
    PidDef(0x0A, 1, (d) => {'fuel_press': d[0] * 3.0}, 'Pressão Combustível (010A)', extra: true, slow: true),
    PidDef(0x10, 2, (d) => {'maf': ((d[0] * 256) + d[1]) / 100.0}, 'MAF (0110)', extra: true),
    PidDef(0x1F, 2, (d) => {'run_time': ((d[0] * 256) + d[1]).toDouble()}, 'Tempo Motor Ligado (011F)', extra: true, slow: true),
    PidDef(0x2E, 1, (d) => {'evap_purge': (d[0] * 100.0) / 255.0}, 'Purga Cânister (012E)', extra: true, slow: true),
    PidDef(0x2F, 1, (d) => {'fuel_level': (d[0] * 100.0) / 255.0}, 'Nível Combustível (012F)', extra: true, slow: true),
    PidDef(0x30, 1, (d) => {'warmups': d[0].toDouble()}, 'Aquecimentos desde Limpeza (0130)', extra: true, slow: true),
    PidDef(0x31, 2, (d) => {'dist_clr': ((d[0] * 256) + d[1]).toDouble()}, 'Distância desde Limpeza (0131)', extra: true, slow: true),
    PidDef(0x33, 1, (d) => {'baro': d[0].toDouble()}, 'Pressão Barométrica (0133)', extra: true, slow: true),
    PidDef(0x3C, 2, (d) => {'cat_temp': ((d[0] * 256) + d[1]) / 10.0 - 40.0}, 'Temp. Catalisador B1S1 (013C)', extra: true, slow: true),
    PidDef(
      0x42,
      2,
      (d) {
        final v = ((d[0] * 256) + d[1]) / 1000.0;
        return {'ecu_volt': v, 'battery': v};
      },
      'Tensão Módulo (0142)',
      extra: true,
      slow: true,
    ),
    PidDef(0x43, 2, (d) => {'abs_load': ((d[0] * 256) + d[1]) * 100.0 / 255.0}, 'Carga Absoluta (0143)', extra: true),
    PidDef(0x44, 2, (d) => {'cmd_lambda': ((d[0] * 256) + d[1]) * 2.0 / 65536.0}, 'Lambda Comandado (0144)', extra: true),
    PidDef(0x45, 1, (d) => {'rel_tps': (d[0] * 100.0) / 255.0}, 'Borboleta Relativa (0145)', extra: true),
    PidDef(0x46, 1, (d) => {'ambient': d[0] - 40.0}, 'Temp. Ambiente (0146)', extra: true, slow: true),
    PidDef(0x47, 1, (d) => {'tps_b': (d[0] * 100.0) / 255.0}, 'Borboleta B (0147)', extra: true),
    PidDef(0x49, 1, (d) => {'pedal_d': (d[0] * 100.0) / 255.0}, 'Pedal D (0149)', extra: true),
    PidDef(0x4A, 1, (d) => {'pedal_e': (d[0] * 100.0) / 255.0}, 'Pedal E (014A)', extra: true),
    PidDef(0x4C, 1, (d) => {'cmd_throttle': (d[0] * 100.0) / 255.0}, 'Atuador Borboleta (014C)', extra: true),
    PidDef(0x4D, 2, (d) => {'time_mil': ((d[0] * 256) + d[1]).toDouble()}, 'Tempo c/ MIL (014D)', extra: true, slow: true),
    PidDef(0x4E, 2, (d) => {'time_clr': ((d[0] * 256) + d[1]).toDouble()}, 'Tempo desde Limpeza (014E)', extra: true, slow: true),
    PidDef(
      0x52,
      1,
      (d) {
        final pct = (d[0] * 100.0) / 255.0;
        return {'ethanol': pct, 'flex_ethanol_pct': pct};
      },
      '% Etanol (0152)',
      extra: true,
      slow: true,
    ),
    PidDef(0x5C, 1, (d) => {'oil_temp': d[0] - 40.0}, 'Temp. Óleo (015C)', extra: true, slow: true),
    PidDef(0x5E, 2, (d) => {'fuel_rate': ((d[0] * 256) + d[1]) / 20.0}, 'Consumo (015E)', extra: true),
    // PIDs Turbo / GDI / Intercooler SAE J1979
    PidDef(0x22, 2, (d) => {'fuel_rail_bar': (((d[0] * 256) + d[1]) * 0.079) / 100.0}, 'Pressão Flauta Relativa (0122)', extra: true, slow: true),
    PidDef(0x23, 2, (d) => {'fuel_rail_bar': (((d[0] * 256) + d[1]) * 10.0) / 100.0}, 'Pressão Flauta GDI (0123)', extra: true, slow: true),
    PidDef(0x6E, 5, decPid6E, 'Pressão Entrada Compressor (016E)', extra: true, slow: true),
    PidDef(0x6F, 3, decPid6F, 'Controle Pressão Turbo (016F)', extra: true),
    PidDef(0x70, 10, decPid70, 'Controle Boost/Wastegate (0170)', extra: true, fast: true),
    PidDef(0x77, 5, decPid77, 'Temp. Intercooler CAC (0177)', extra: true, slow: true),
  ])
    p.key: p,
};

const List<int> normalOrder = [0x0C, 0x0B, 0x0E, 0x11, 0x14, 0x06, 0x07, 0x05];
const List<int> fastOrder = [0x0C, 0x0B, 0x0E, 0x11, 0x14];
const List<int> extraOrder = [
  0x04, 0x0D, 0x0F, 0x03, 0x01, 0x13, 0x1C, 0x21, 0x51,
  0x23, 0x6E, 0x6F, 0x70, 0x77,
];

const List<int> lambdaCandidates = [0x14, 0x15, 0x24, 0x34];
const List<int> stftCandidates = [0x06];
const List<int> ltftCandidates = [0x07];

Set<int> parseSupportedBitmap(int basePid, Uint8List data) {
  if (data.length < 4) return const {};
  final value = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
  final out = <int>{};
  for (var i = 0; i < 32; i++) {
    if ((value & (1 << (31 - i))) != 0) {
      out.add(basePid + i + 1);
    }
  }
  return out;
}
