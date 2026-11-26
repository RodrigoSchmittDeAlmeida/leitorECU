/// Simulador de motor e rede OBD/VAG/Ford HS-CAN para Modo Demo e testes.
library;

import 'dart:math' as math;

import '../models/vehicle_profile.dart';

const double mockCycleSeconds = 24.0;

const Set<int> baseSupportedPids = {
  0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
  0x11, 0x13, 0x14, 0x15, 0x1C, 0x20, 0x2F, 0x33, 0x3C, 0x40, 0x42, 0x44, 0x5C, 0x5E,
};

const Set<int> turboExtraPids = {0x23, 0x24, 0x70, 0x77};

int _clampInt(num v, int lo, int hi) => v.round().clamp(lo, hi);
double _clampD(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

String _hex2(int v) => (v & 0xFF).toRadixString(16).toUpperCase().padLeft(2, '0');
String _hex4(int v) => (v & 0xFFFF).toRadixString(16).toUpperCase().padLeft(4, '0');
String _hex8(int v) => (v & 0xFFFFFFFF).toRadixString(16).toUpperCase().padLeft(8, '0');
String _asciiHex(String s) =>
    s.codeUnits.map((c) => _hex2(c)).join();

class MockEngine {
  DemoProfile profile;
  bool protocolReady = false;
  bool dtcsCleared = false;
  String header = '7E0';
  String protocol = '6';
  bool vagMode = false;
  String _targetAddr = '01';
  bool enableRandomDrops = false;

  final DateTime _t0;
  final math.Random _rng = math.Random(42);
  double? simulatedElapsedSeconds;

  MockEngine({
    this.profile = DemoProfile.golMe75,
    bool turboMode = false,
  }) : _t0 = DateTime.now() {
    if (turboMode) {
      profile = DemoProfile.turboTsi;
    }
  }

  bool get isTurbo => profile == DemoProfile.turboTsi;

  Set<int> supportedPids() {
    final pids = Set<int>.from(baseSupportedPids);
    if (isTurbo) {
      pids
        ..addAll(turboExtraPids)
        ..add(0x60);
    }
    return pids;
  }

  Map<String, double> state() {
    final t = simulatedElapsedSeconds ??
        DateTime.now().difference(_t0).inMicroseconds / 1e6;
    final cyc = (t ~/ mockCycleSeconds);
    final ph = t % mockCycleSeconds;
    final fault = (cyc % 2) == 1;
    final osc = math.sin(2 * math.pi * 1.1 * t);

    if (!isTurbo) {
      late double rpm, tps, mp, adv, lam, lam2;
      late int fuelSys;
      if (ph < 6) {
        rpm = 850 + 25 * math.sin(t * 3);
        tps = 0.0;
        mp = 32 + 2 * math.sin(t);
        adv = 10 + 2 * math.sin(t * 2.3);
        lam = 0.45 + 0.38 * osc;
        lam2 = 0.65 + 0.02 * math.sin(t * 0.4);
        fuelSys = 2;
      } else if (ph < 9) {
        final k = (ph - 6) / 3;
        rpm = 850 + (4200 - 850) * k;
        tps = 15 + 45 * k;
        mp = 55 + 35 * k;
        adv = 18 + 8 * k;
        lam = 0.82 + 0.03 * osc;
        lam2 = 0.76 + 0.04 * k;
        fuelSys = tps > 50 ? 4 : 2;
      } else if (ph < 12) {
        rpm = 4200 + 60 * math.sin(t * 4);
        tps = 35.0;
        mp = 62.0;
        adv = 30 + math.sin(t);
        lam = 0.45 + 0.4 * osc;
        lam2 = 0.68 + 0.02 * math.sin(t * 0.3);
        fuelSys = 2;
      } else if (ph < 16) {
        final k = ph - 12;
        rpm = 1000 + 3200 * math.exp(-k * 1.1);
        tps = 0.0;
        mp = 20 + 3 * k;
        if (fault) {
          lam = 0.82 + 0.03 * osc;
          lam2 = 0.45 + 0.35 * osc;
          adv = 4 - 4 * k;
          fuelSys = 2;
        } else {
          lam = rpm > 1250 ? 0.06 : 0.45 + 0.38 * osc;
          lam2 = rpm > 1250 ? 0.08 : 0.64 + 0.02 * math.sin(t * 0.5);
          adv = 6 - k;
          fuelSys = rpm > 1250 ? 1 : 2;
        }
      } else {
        final k = ph - 16;
        rpm = 850 + 150 * math.exp(-k);
        tps = 0.0;
        mp = 33.0;
        adv = 10 + 2 * math.sin(t * 2.3);
        lam = 0.45 + 0.38 * osc;
        lam2 = 0.65 + 0.02 * math.sin(t * 0.4);
        fuelSys = 2;
      }

      final ect = _clampD(70 + t * 0.4, 70, 92);
      final stft = 6 * -osc + (fault ? 3 : 0);
      final ltft = fault ? 12.5 : 3.1;
      final ltftIdle = fault ? -4.7 : -1.6;
      final load = _clampD(mp * 1.1, 0, 100);
      final speed = _clampD((rpm - 800) / 45, 0, 140);
      final catTemp = _clampD(
        480.0 + (rpm / 4200.0) * 190.0 + 10.0 * math.sin(t * 0.1),
        380.0,
        720.0,
      );
      final bat = 13.9 + 0.1 * math.sin(t * 0.5);
      const baro = 98.0;

      return {
        'rpm': rpm,
        'tps': tps,
        'map': mp,
        'adv': adv,
        'lam': _clampD(lam, 0.02, 1.0),
        'lam2': _clampD(lam2, 0.02, 1.0),
        'ect': ect,
        'stft': stft,
        'ltft': ltft,
        'ltft_idle': ltftIdle,
        'load': load,
        'speed': speed,
        'iat': 32.0,
        't': t,
        'ph': ph,
        'fuel_sys': fuelSys.toDouble(),
        'cat_temp': catTemp,
        'bat': bat,
        'baro': baro,
        'lambda_eq': 1.00,
        'boost_bar': (mp - baro) / 100.0,
        'boost_target_bar': 0.0,
        'wastegate': 0.0,
        'fuel_rail_bar': 40.0,
        'cac_temp': 32.0,
        'knock_retard': 0.0,
      };
    }

    // Perfil Turbo TSI (EA888 MED17.5)
    late double rpm, tps, mp, adv, lam, lam2, lambdaEq;
    late double boostTarget, wastegate, fuelRailBar, cacTemp, knockRet;
    late int fuelSys;
    if (ph < 6) {
      rpm = 800 + 20 * math.sin(t * 3);
      tps = 0.0;
      mp = 32 + 2 * math.sin(t);
      adv = 8 + 2 * math.sin(t * 2.3);
      lam = 0.45 + 0.38 * osc;
      lam2 = 0.65;
      lambdaEq = 1.00;
      fuelSys = 2;
      boostTarget = 0.0;
      wastegate = 0.0;
      fuelRailBar = 45.0;
      cacTemp = 30.0;
      knockRet = 0.0;
    } else if (ph < 9) {
      final k = (ph - 6) / 3;
      rpm = 1200 + (5800 - 1200) * k;
      tps = 20.0 + 80.0 * k;
      mp = 80.0 + 140.0 * k; // até 220 kPa (1.2 bar boost)
      adv = 14.0 - 4.0 * k;
      lam = 0.88 + 0.02 * osc;
      lam2 = 0.76;
      lambdaEq = 1.00 - 0.18 * k;
      fuelSys = tps > 50 ? 4 : 2;
      boostTarget = 1.20;
      wastegate = 55.0 + 30.0 * k;
      fuelRailBar = 50.0 + 100.0 * k;
      cacTemp = 32.0 + 16.0 * k;
      knockRet = k > 0.70 ? 3.6 * k : 0.0;
    } else if (ph < 12) {
      rpm = 3200 + 40 * math.sin(t * 4);
      tps = 28.0;
      mp = 75.0;
      adv = 26 + math.sin(t);
      lam = 0.45 + 0.4 * osc;
      lam2 = 0.68;
      lambdaEq = 1.00 + 0.01 * osc;
      fuelSys = 2;
      boostTarget = 0.0;
      wastegate = 15.0;
      fuelRailBar = 70.0;
      cacTemp = 36.0;
      knockRet = 0.0;
    } else if (ph < 16) {
      final k = ph - 12;
      rpm = 1000 + 3000 * math.exp(-k * 1.1);
      tps = 0.0;
      mp = 20 + 2 * k;
      lam = rpm > 1250 ? 0.05 : 0.45 + 0.38 * osc;
      lam2 = rpm > 1250 ? 0.08 : 0.65;
      lambdaEq = rpm > 1250 ? 1.99 : 1.00;
      adv = 8 - k;
      fuelSys = rpm > 1250 ? 1 : 2;
      boostTarget = 0.0;
      wastegate = 0.0;
      fuelRailBar = 40.0;
      cacTemp = 34.0;
      knockRet = 0.0;
    } else {
      final k = ph - 16;
      rpm = 800 + 150 * math.exp(-k);
      tps = 0.0;
      mp = 33.0;
      adv = 9 + 2 * math.sin(t * 2.3);
      lam = 0.45 + 0.38 * osc;
      lam2 = 0.65;
      lambdaEq = 1.00;
      fuelSys = 2;
      boostTarget = 0.0;
      wastegate = 0.0;
      fuelRailBar = 45.0;
      cacTemp = 32.0;
      knockRet = 0.0;
    }

    final ect = _clampD(75 + t * 0.4, 75, 96);
    final stft = 5 * -osc;
    const ltft = 2.5;
    const ltftIdle = 0.8;
    final load = _clampD((mp / 220.0) * 100.0, 0, 100);
    final speed = _clampD((rpm - 750) / 40, 0, 190);
    final catTemp = _clampD(520.0 + (rpm / 5500.0) * 260.0, 400.0, 850.0);
    final bat = 13.9 + 0.1 * math.sin(t * 0.5);
    const baro = 100.0;

    return {
      'rpm': rpm,
      'tps': tps,
      'map': mp,
      'adv': adv,
      'lam': _clampD(lam, 0.02, 1.0),
      'lam2': _clampD(lam2, 0.02, 1.0),
      'ect': ect,
      'stft': stft,
      'ltft': ltft,
      'ltft_idle': ltftIdle,
      'load': load,
      'speed': speed,
      'iat': 32.0,
      't': t,
      'ph': ph,
      'fuel_sys': fuelSys.toDouble(),
      'cat_temp': catTemp,
      'bat': bat,
      'baro': baro,
      'lambda_eq': lambdaEq,
      'boost_bar': (mp - baro) / 100.0,
      'boost_target_bar': boostTarget,
      'wastegate': wastegate,
      'fuel_rail_bar': fuelRailBar,
      'cac_temp': cacTemp,
      'knock_retard': knockRet,
    };
  }

  ({String response, double latencySec}) respond(String cmd, double klineLatency) {
    final cmdClean = cmd.trim().toUpperCase();
    if (cmdClean.startsWith('AT')) {
      return _at(cmdClean);
    }
    if (!protocolReady) {
      protocolReady = true;
      return (
        response: 'SEARCHING...\rBUS INIT: ...OK\r${_obd(cmdClean)}',
        latencySec: 0.02,
      );
    }
    if (enableRandomDrops && _rng.nextDouble() < 0.005) {
      return (response: 'NO DATA', latencySec: klineLatency);
    }
    return (response: _obd(cmdClean), latencySec: 0.005);
  }

  ({String response, double latencySec}) _at(String cmd) {
    if (cmd == 'ATZ') {
      protocolReady = false;
      _targetAddr = '01';
      return (response: '\r\rELM327 v1.5', latencySec: 0.01);
    }
    if (cmd == 'ATI') {
      return (response: 'ELM327 v1.5', latencySec: 0.002);
    }
    if (cmd == 'ATRV') {
      final v = 13.9 + (_rng.nextDouble() * 0.2 - 0.1);
      return (response: '${v.toStringAsFixed(1)}V', latencySec: 0.002);
    }
    if (cmd == 'ATDP') {
      if (protocol == '6' || profile == DemoProfile.kaSigma) {
        return (response: 'ISO 15765-4 (CAN 11/500)', latencySec: 0.002);
      }
      return (response: 'ISO 14230-4 (KWP FAST)', latencySec: 0.002);
    }
    if (cmd.startsWith('ATSH')) {
      header = cmd.substring(4).trim().replaceAll(' ', '');
      if (header == '8117F1') {
        _targetAddr = '17';
      } else if (header == '8110F1') {
        _targetAddr = '01';
      }
      return (response: 'OK', latencySec: 0.002);
    }
    if (cmd.startsWith('ATSP')) {
      protocol = cmd.substring(4).trim();
      return (response: 'OK', latencySec: 0.002);
    }
    if (cmd == 'ATIIA17') {
      _targetAddr = '17';
      return (response: 'OK', latencySec: 0.002);
    }
    if (cmd == 'ATIIA01') {
      _targetAddr = '01';
      if (profile == DemoProfile.kaSigma) {
        return (response: 'OK', latencySec: 0.002);
      }
      vagMode = true;
      return (response: 'OK', latencySec: 0.002);
    }
    return (response: 'OK', latencySec: 0.002);
  }

  String _obd(String cmd) {
    final s = state();

    // Remove sufixo fast-reply '1' em comandos de modo 01/21 se não for header/DID de tamanho par
    final cmdNorm = cmd.replaceAll(' ', '');

    // VAG KWP2000 (desativado no perfil Ford Ka Sigma HS-CAN)
    if (profile != DemoProfile.kaSigma) {
      if (_targetAddr == '17') {
        if (cmdNorm == '1089') return '5089';
        if (cmdNorm.startsWith('21') && (cmdNorm.length == 4 || cmdNorm.length == 5)) {
          final g = int.tryParse(cmdNorm.substring(2, 4), radix: 16) ?? 0;
          if (g == 0x02) {
            // Bloco 002 do Painel (0x17):
            // C1 (0x24: 2E 45) -> 118450 km
            // C2 (0x13: 64 22) -> 34.0 l
            // C3 (0x40: 00 8E) -> 142 Ω
            return '6102242E4513642240008E';
          }
          return 'NO DATA';
        }
      }
      if (cmdNorm == '1089') return '5089';
      if (cmdNorm == '1A9B') {
        final txt = isTurbo
            ? '5G0906259 MED17.5 EA888 TSI'
            : '032906032AJ ME7.5.30';
        return '5A9B${_asciiHex(txt)}';
      }
      if (cmdNorm == '1800FF00') {
        return dtcsCleared ? '5800000000' : '580201330300';
      }
      if (cmdNorm == '14FF00') {
        dtcsCleared = true;
        return '54';
      }
      if (cmdNorm == '31010000') {
        return '71010000';
      }

      // VAG Modo 21 (Blocos de Medição)
      if (cmdNorm.startsWith('21') &&
          (cmdNorm.length == 4 || cmdNorm.length == 5) &&
          (vagMode || header == '8110F1' || header == '01' || header.isEmpty || header.contains('8110F1'))) {
        final g = int.tryParse(cmdNorm.substring(2, 4), radix: 16) ?? 0;
        if ((g == 0x72 || g == 0x73 || g == 0x76) && !isTurbo) {
          return 'NO DATA';
        }
        return _vagGroupResponse(g, s);
      }
    } else {
      // Ka Sigma não responde KWP2000 Linha K
      if (cmdNorm == '1089' || cmdNorm == '1A9B' || cmdNorm.startsWith('21')) {
        return 'NO DATA';
      }
    }

    // DTCs padrão (Modo 03 / 04)
    if (cmdNorm.startsWith('03')) {
      if (dtcsCleared) return '43000000000000';
      if (header == '7E0') return '43013303000000'; // P0133, P0300
      if (header == '726') return '43B0A200000000'; // B10A2
      if (header == '760') return '43000000000000';
      return '43000000000000';
    }
    if (cmdNorm.startsWith('04')) {
      dtcsCleared = true;
      return '44';
    }

    // UDS Modo 22 (Ford HS-CAN / VAG DIDs)
    if (cmdNorm.startsWith('22') && cmdNorm.length >= 6) {
      final did = cmdNorm.substring(2, 6);
      if (header == '726') {
        if (did == '404C') {
          final doorOpen = (s['ph']! > 21 && s['speed']! < 1) ? 0x01 : 0x00;
          return '62404C${_hex2(doorOpen)}01';
        }
        if (did == '4050') return '6240500300';
        if (did == '4060') return '6240600020';
        if (did == '4001') return '624001056E';
      }
      if (header == '760') {
        if (did == '2B00') {
          final spd = s['speed']!;
          final fl = (spd * 100).round();
          final fr = ((spd + 0.1) * 100).round();
          return '622B00${_hex4(fl)}${_hex4(fr)}${_hex4(fl)}${_hex4(fr)}';
        }
        if (did == '2B01') {
          final press = (s['ph']! >= 12 && s['ph']! < 14) ? 350 : 0;
          final pedal = press > 0 ? 0x01 : 0x00;
          return '622B01${_hex4(press)}${_hex2(pedal)}0000';
        }
      }
      if (header == '7E0') {
        if (did == '1624') {
          final rawCht = ((s['ect']! + 4.0 + 40.0) * 10).round();
          return '621624${_hex4(rawCht)}';
        }
        if (did == '032B') {
          final appB = _clampInt(s['tps']! * 2.55, 0, 255);
          return '62032B${_hex2(appB)}';
        }
        if (did == '0332') {
          final fanPct = s['ect']! > 88 ? 65 : 0;
          return '620332${_hex2(_clampInt(fanPct * 2.55, 0, 255))}';
        }
        if (did == '1125') {
          final pw = ((2.8 + (s['load']! / 100.0) * 8.5) * 1000).round();
          return '621125${_hex4(pw)}';
        }
        if (did == '1101') return '62110104BE01';
        if (did == '0323') return '62032304BE';
        if (did == '0325') return '62032501';
        if (did == '1608') return '62160855';
        if (did == '1627') {
          return '621627${_hex4(((s['cat_temp']! + 40.0) * 10).round())}';
        }
        if (did == '0320') return '620320${_hex2(s['baro']!.round())}';
        // EcoBoost DIDs: ausentes no Sigma 1.5 aspirado (NRC 7F 22 31)
        if (const {'0462', '0333', '03A0', '03E7', '04FE'}.contains(did) &&
            !isTurbo) {
          return '7F2231';
        }
      }
      if (header == '720') {
        if (did == 'DD01') return '62DD01014961';
        if (did == '2416') return '622416AD4200';
      }
      if (header == '730') {
        if (did == '3300') {
          final ang = ((_rng.nextDouble() * 10 - 5) * 10).round() & 0xFFFF;
          final trq = ((0.5 + _rng.nextDouble() * 1.5) * 100).round() & 0xFFFF;
          final curr = ((2.0 + _rng.nextDouble() * 3.0) / 0.5).round();
          return '623300${_hex4(ang)}${_hex4(trq)}${_hex2(curr)}';
        }
      }
      if (did == 'F190') {
        final vin = switch (profile) {
          DemoProfile.turboTsi => 'WVWZZZAUZHP123456',
          DemoProfile.kaSigma => '9BFZZZ54ZG8123456',
          DemoProfile.golMe75 => '9BWZZZ5UZBP123456',
        };
        return '62F190${_asciiHex(vin)}';
      }
      if (did == 'F187') {
        final pn = switch (profile) {
          DemoProfile.turboTsi => '5G0906259',
          DemoProfile.kaSigma => 'EMS2211',
          DemoProfile.golMe75 => '032906032AJ',
        };
        return '62F187${_asciiHex(pn)}';
      }
      return '62${did}0000';
    }

    // Modo 09 (VIN)
    if (cmdNorm == '0902') {
      final vin = switch (profile) {
        DemoProfile.turboTsi => 'WVWZZZAUZHP123456',
        DemoProfile.kaSigma => '9BFZZZ54ZG8123456',
        DemoProfile.golMe75 => '9BWZZZ5UZBP123456',
      };
      return '490201${_asciiHex(vin)}';
    }

    // Modo 02 (Freeze Frame)
    if (cmdNorm.startsWith('02') && cmdNorm.length >= 4) {
      final pid = cmdNorm.substring(2, 4);
      if (pid == '02') return dtcsCleared ? '42020000' : '42020133';
      if (pid == '0C') return '420C0FA0'; // 1000 rpm
      if (pid == '0D') return '420D3C';   // 60 km/h
      if (pid == '05') return '420582';   // 90 °C
      if (pid == '0B') return '420B32';   // 50 kPa
      if (pid == '04') return '420480';   // ~50.2%
      return 'NO DATA';
    }

    // Modo 01 OBD2 Padrão
    if (cmdNorm.length < 4 || !cmdNorm.startsWith('01')) {
      return '?';
    }
    final pid = int.tryParse(cmdNorm.substring(2, 4), radix: 16);
    if (pid == null) return '?';

    final activeSupported = supportedPids();
    if (pid == 0x00 || pid == 0x20 || pid == 0x40 || pid == 0x60) {
      if (pid != 0x00 && !activeSupported.contains(pid)) {
        return 'NO DATA';
      }
      var bits = 0;
      for (final p in activeSupported) {
        if (p > pid && p <= pid + 32) {
          bits |= 1 << (31 - (p - pid - 1));
        }
      }
      return '41${_hex2(pid)}${_hex8(bits)}';
    }
    if (pid == 0x01) {
      final n = dtcsCleared ? 0 : 2;
      return '4101${_hex2((n > 0 ? 0x80 : 0) | n)}076500';
    }
    if (!activeSupported.contains(pid)) {
      return 'NO DATA';
    }

    final payload = switch (pid) {
      0x0C => _hex4((s['rpm']! * 4).round()),
      0x0B => _hex2(_clampInt(s['map']!, 0, 255)),
      0x0E => _hex2(_clampInt((s['adv']! + 64) * 2, 0, 255)),
      0x11 => _hex2(_clampInt(s['tps']! * 255 / 100, 0, 255)),
      0x13 => '03',
      0x14 =>
        '${_hex2(_clampInt(s['lam']! * 200, 0, 255))}${_hex2(_clampInt(128 + s['stft']! * 1.28, 0, 254))}',
      0x15 =>
        '${_hex2(_clampInt(s['lam2']! * 200, 0, 255))}${_hex2(_clampInt(128 + s['stft']! * 0.2, 0, 254))}',
      0x1C => '01',
      0x03 => '${_hex2(s['fuel_sys']!.round())}00',
      0x06 => _hex2(_clampInt(128 + s['stft']! * 1.28, 0, 255)),
      0x07 => _hex2(_clampInt(128 + s['ltft']! * 1.28, 0, 255)),
      0x05 => _hex2(_clampInt(s['ect']! + 40, 0, 255)),
      0x04 => _hex2(_clampInt(s['load']! * 255 / 100, 0, 255)),
      0x0D => _hex2(_clampInt(s['speed']!, 0, 255)),
      0x0F => _hex2(_clampInt(s['iat']! + 40, 0, 255)),
      0x23 => _hex4(_clampInt(s['fuel_rail_bar']! * 100.0 / 10.0, 0, 65535)),
      0x24 =>
        '${_hex4(_clampInt(s['lambda_eq']! * 32768, 0, 65535))}${_hex4(_clampInt(s['lam']! * 8192, 0, 65535))}',
      0x2F => 'AD',
      0x33 => _hex2(_clampInt(s['baro']!, 0, 255)),
      0x3C => _hex4(_clampInt((s['cat_temp']! + 40.0) * 10, 0, 65535)),
      0x42 => _hex4(_clampInt(s['bat']! * 1000, 0, 65535)),
      0x44 => _hex4(_clampInt(s['lambda_eq']! * 32768, 0, 65535)),
      0x5C => _hex2(_clampInt(s['ect']! + 35, 0, 255)),
      0x5E => _hex4(_clampInt((s['load']! / 100.0) * 8.0 * 20, 0, 65535)),
      0x70 => '03'
          '${_hex4(_clampInt((101.325 + s['boost_target_bar']! * 100.0) / 0.03125, 0, 65535))}'
          '${_hex4(_clampInt(s['map']! / 0.03125, 0, 65535))}'
          '00000000'
          '${_hex2(_clampInt(s['wastegate']! * 255.0 / 100.0, 0, 255))}',
      0x77 =>
        '${_hex2(_clampInt(s['cac_temp']! + 40, 0, 255))}${_hex2(_clampInt(s['cac_temp']! + 40, 0, 255))}',
      _ => null,
    };

    if (payload == null) return 'NO DATA';
    return '41${_hex2(pid)}$payload';
  }

  String _vagGroupResponse(int g, Map<String, double> s) {
    final rpmB = _clampInt(s['rpm']! / 40.0, 0, 255); // 0x01: 0.2 * 200 * B = 40 * B rpm
    final loadB = _clampInt(s['load']! * 2.0, 0, 255); // 0x02: 0.002 * 250 * B = 0.5 * B %
    final tpsB = _clampInt(s['tps']! * 2.0, 0, 255);   // 0x03: 0.002 * 250 * B = 0.5 * B °/%
    final mapB = _clampInt(s['map']!, 0, 255);         // 0x12: 0.04 * 250 * B = 10 * B mbar = B kPa
    final batB = _clampInt(s['bat']! * 10.0, 0, 255);  // 0x06/0x15: 0.001 * 100 * B = 0.1 * B V
    final lamB = _clampInt(s['lam']! * 100.0, 0, 255); // 0x06: 0.001 * 10 * B = 0.01 * B V

    if (g == 0x02) {
      final injMs = 2.4 + (s['load']! / 100.0) * 6.5;
      final injB = _clampInt(injMs * 10.0, 0, 255); // 0x0F: 0.01 * 10 * B = 0.1 * B ms
      return '6102'
          '01C8${_hex2(rpmB)}'
          '02FA${_hex2(loadB)}'
          '0F0A${_hex2(injB)}'
          '12FA${_hex2(mapB)}';
    }
    if (g == 0x03) {
      final advB = _clampInt(s['adv']! + 128, 0, 255); // 0x1B: 0.01 * 100 * (B - 128)
      return '610301C8${_hex2(rpmB)}12FA${_hex2(mapB)}02FA${_hex2(tpsB)}1B64${_hex2(advB)}';
    }
    if (g == 0x21) {
      final trimB = _clampInt(s['stft']! * 128.0 / 100.0 + 128, 0, 255);
      return '61211464${_hex2(trimB)}060A${_hex2(lamB)}010000010000';
    }
    if (g == 0x20) {
      final ltftIdleB = _clampInt(s['ltft_idle']! * 128.0 / 100.0 + 128, 0, 255);
      final ltftB = _clampInt(s['ltft']! * 128.0 / 100.0 + 128, 0, 255);
      return '61201464${_hex2(ltftIdleB)}1464${_hex2(ltftB)}1464800664${_hex2(batB)}';
    }
    if (g == 0x1F) {
      return '611F060A${_hex2(lamB)}0B0180060000';
    }
    if (g == 0x04) {
      final ectB = _clampInt(s['ect']! + 100, 0, 255);
      final iatB = _clampInt(s['iat']! + 100, 0, 255);
      return '610401C8${_hex2(rpmB)}1564${_hex2(batB)}050A${_hex2(ectB)}050A${_hex2(iatB)}';
    }
    if (g == 0x05) {
      final spdB = _clampInt(s['speed']!, 0, 255); // 0x07: 0.01 * 100 * B = B km/h
      final fs = s['fuel_sys']!.round();
      final b4 = fs == 1 ? 0x08 : (fs == 4 ? 0x04 : 0x01);
      return '610501C8${_hex2(rpmB)}02FA${_hex2(loadB)}0764${_hex2(spdB)}2500${_hex2(b4)}';
    }
    if (g == 0x14) {
      if (isTurbo && s['knock_retard']! > 0.0) {
        final kRet = s['knock_retard']!;
        final b1 = _clampInt(128 + kRet * 10, 0, 255);
        final b2 = _clampInt(128 + (kRet * 0.5) * 10, 0, 255);
        return '6114220A${_hex2(b1)}220A${_hex2(b2)}220A80220A80';
      }
      return '6114220180220180220180220180';
    }
    if (g == 0x1A) return '611A06019006019506018C060192';
    if (g == 0x3E) {
      final tps2B = _clampInt((100.0 - s['tps']!) * 2.0, 0, 255);
      return '613E02FA${_hex2(tpsB)}02FA${_hex2(tps2B)}02FA${_hex2(tpsB)}02FA${_hex2(tpsB)}';
    }
    if (g == 0x67) {
      // Bloco 103: C1..C4 vazios, C5 (103.5) = 27.0% (0x21 0x64 0x1B), C6 (103.6) = 100.0% (0x21 0x64 0x64)
      return '616700000000000000000000000021641B216464216400100001';
    }
    if (g == 0x72) {
      final bWg = _clampInt(s['wastegate']! * 2.0, 0, 255);
      return '617202FA${_hex2(loadB)}02FA${_hex2(loadB)}02FA${_hex2(loadB)}02FA${_hex2(bWg)}';
    }
    if (g == 0x73) {
      final mbarSpec = (101.325 + s['boost_target_bar']! * 100.0) * 10.0;
      final bPspec = _clampInt(mbarSpec / 10.0, 0, 255);
      return '617301C8${_hex2(rpmB)}02FA${_hex2(loadB)}12FA${_hex2(bPspec)}12FA${_hex2(mapB)}';
    }
    if (g == 0x76) {
      final bIat = _clampInt(s['iat']! + 100, 0, 255);
      final bWg = _clampInt(s['wastegate']! * 2.0, 0, 255);
      return '617601C8${_hex2(rpmB)}050A${_hex2(bIat)}02FA${_hex2(bWg)}12FA${_hex2(mapB)}';
    }
    return 'NO DATA';
  }
}
