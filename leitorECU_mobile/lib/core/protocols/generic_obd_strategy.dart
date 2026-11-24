/// Estratégia de comunicação OBD-II Genérico Padrão (Modo 01 / Modo 03 / Modo 04).
library;

import '../elm327/elm327_client.dart';
import '../models/vehicle_profile.dart';
import 'dtc_parser.dart';
import 'pids.dart';
import 'vehicle_strategy.dart';

class GenericObdStrategy extends VehicleStrategy {
  final Set<int> supported = <int>{};
  final List<int> activeFast = <int>[];
  final List<int> activeNormal = <int>[];
  final List<int> activeExtra = <int>[];
  final Map<int, int> _noDataStreak = <int, int>{};

  @override
  String get profileId => 'generic_obd';

  @override
  String get displayName => 'OBD2 Genérico / Automático';

  @override
  Future<bool> initialize(Elm327Client elm, StrategyContext ctx) async {
    ctx.emitStatus('connecting', 'Detectando protocolo OBD-II padrão (ATSP0)...');
    await elm.command('ATSP0', timeout: const Duration(seconds: 3));

    var r0 = await elm.command('0100', timeout: const Duration(seconds: 12));
    if (!r0.ok) {
      for (final proto in const ['ATSP6', 'ATSP3', 'ATSP5', 'ATSP4']) {
        if (!ctx.isRunning) return false;
        await elm.command(proto, timeout: const Duration(seconds: 2));
        final r = await elm.command('0100', timeout: const Duration(seconds: 4));
        if (r.ok) {
          r0 = r;
          break;
        }
      }
    }
    if (!r0.ok) return false;

    ctx.emitStatus('connecting', 'Mapeando PIDs suportados pela ECU...');
    await _probeBitmaps(elm);
    await _discoverSensors(elm, ctx);
    ctx.emitStatus('connected', 'Conectado — OBD-II Genérico (Modo 01 Ativo)');
    return true;
  }

  Future<void> _probeBitmaps(Elm327Client elm) async {
    supported.clear();
    for (final basePid in const [0x00, 0x20, 0x40, 0x60]) {
      if (basePid != 0 && !supported.contains(basePid)) break;
      final cmd = '01${basePid.toRadixString(16).toUpperCase().padLeft(2, '0')}';
      final resp = await elm.command(cmd, timeout: const Duration(seconds: 3));
      final data = extractPayload(resp, 0x01, basePid, 4);
      if (data != null && data.length == 4) {
        supported.addAll(parseSupportedBitmap(basePid, data));
      }
    }
  }

  Future<void> _discoverSensors(Elm327Client elm, StrategyContext ctx) async {
    final lambdaKeys = <int>[];
    for (final cand in lambdaCandidates) {
      if (supported.isEmpty || supported.contains(cand)) {
        final p = obdPids[cand]!;
        final r = await elm.queryPid(p.cmd);
        if (r.ok && extractPayload(r, 1, cand, p.nbytes) != null) {
          lambdaKeys.add(cand);
        }
      }
    }

    int? stftKey;
    for (final cand in stftCandidates) {
      if (supported.isEmpty || supported.contains(cand)) {
        final p = obdPids[cand]!;
        final r = await elm.queryPid(p.cmd);
        if (r.ok && extractPayload(r, 1, cand, p.nbytes) != null) {
          stftKey = cand;
          break;
        }
      }
    }

    int? ltftKey;
    for (final cand in ltftCandidates) {
      if (supported.isEmpty || supported.contains(cand)) {
        final p = obdPids[cand]!;
        final r = await elm.queryPid(p.cmd);
        if (r.ok && extractPayload(r, 1, cand, p.nbytes) != null) {
          ltftKey = cand;
          break;
        }
      }
    }

    final baseFast = <int>[
      for (final p in const [0x0C, 0x0B, 0x0E, 0x11])
        if (supported.isEmpty || supported.contains(p)) p,
    ];
    for (final lk in lambdaKeys) {
      if (!baseFast.contains(lk)) baseFast.add(lk);
    }

    final baseNormal = List<int>.from(baseFast);
    if (stftKey != null && !baseNormal.contains(stftKey)) {
      baseNormal.add(stftKey);
    }
    if (ltftKey != null && !baseNormal.contains(ltftKey)) {
      baseNormal.add(ltftKey);
    }
    if (supported.isEmpty || supported.contains(0x05)) {
      if (!baseNormal.contains(0x05)) baseNormal.add(0x05);
    }

    final extras = <int>[
      for (final p in extraOrder)
        if (supported.isEmpty || supported.contains(p)) p,
    ];

    activeFast
      ..clear()
      ..addAll(baseFast);
    activeNormal
      ..clear()
      ..addAll(baseNormal);
    activeExtra
      ..clear()
      ..addAll(extras);

    if (lambdaKeys.isNotEmpty) {
      final names = lambdaKeys
          .map((k) => '${obdPids[k]!.cmd} (${obdPids[k]!.name})')
          .join(', ');
      ctx.emitInfo('Sonda Lambda ativa: $names');
    }
  }

  @override
  Future<int> pollCycle(
    Elm327Client elm,
    StrategyContext ctx,
    int cycle, {
    bool decelMode = false,
  }) async {
    var nResp = 0;
    final List<int> pids;
    if (decelMode) {
      pids = List<int>.from(activeFast);
    } else if (cycle % 4 == 3 && activeExtra.isNotEmpty) {
      pids = [...activeNormal, activeExtra[cycle % activeExtra.length]];
    } else {
      pids = List<int>.from(activeNormal);
    }

    for (final pcode in pids) {
      if (!ctx.isRunning) return nResp;
      final pdef = obdPids[pcode];
      if (pdef == null) continue;
      final resp = await elm.queryPid(pdef.cmd);
      if (resp.ok) {
        final data = extractPayload(resp, pdef.mode, pdef.pid, pdef.nbytes);
        if (data != null) {
          try {
            final vals = pdef.decode(data);
            if (vals.isNotEmpty) {
              ctx.emitSample(vals);
              nResp++;
              _noDataStreak[pcode] = 0;
            }
          } catch (_) {}
        }
      } else if (resp.error == 'NO DATA' || resp.error == '?') {
        final streak = (_noDataStreak[pcode] ?? 0) + 1;
        _noDataStreak[pcode] = streak;
        if (streak >= 3 && !supported.contains(pcode)) {
          activeFast.remove(pcode);
          activeNormal.remove(pcode);
          activeExtra.remove(pcode);
        }
      }
    }

    if (!decelMode && cycle % 5 == 0) {
      try {
        final vPin16 = await elm.batteryVoltage();
        if (vPin16 != null && vPin16 >= 5.0 && vPin16 <= 20.0) {
          ctx.emitSample({'obd_pin16_v': vPin16, 'battery': vPin16});
        }
      } catch (_) {}
    }

    return nResp;
  }

  @override
  Future<void> readDtcs(Elm327Client elm, StrategyContext ctx) async {
    final r1 = await elm.command('0101', timeout: const Duration(seconds: 2));
    var milOn = false;
    var nDtc = 0;
    if (r1.ok && r1.dataLines().isNotEmpty) {
      final raw = r1.dataLines().join('').replaceAll(' ', '');
      if (raw.length >= 6) {
        final b = int.tryParse(raw.substring(4, 6), radix: 16) ?? 0;
        milOn = (b & 0x80) != 0;
        nDtc = b & 0x7F;
      }
    }

    final r3 = await elm.command('03', timeout: const Duration(seconds: 4));
    var found = <DtcItem>[];
    if (r3.ok && r3.dataLines().isNotEmpty) {
      final raw = r3.dataLines().join('').replaceAll(' ', '');
      found = parseDtcsHex(raw);
    }

    ctx.emitDtcs(milOn, nDtc, found);
  }

  @override
  Future<void> clearDtcs(Elm327Client elm, StrategyContext ctx) async {
    await elm.command('04', timeout: const Duration(seconds: 4));
    await readDtcs(elm, ctx);
  }
}
