/// Estratégia de comunicação VAG KWP2000 (VW Gol G5 ME7.5.30 & VAG TSI KWP).
library;

import '../elm327/elm327_client.dart';
import '../models/vehicle_profile.dart';
import 'dtc_parser.dart';
import 'ecu_fingerprints.dart';
import 'pids.dart';
import 'vag_formulas.dart';
import 'vehicle_strategy.dart';

class VagBlockCacheData {
  final Set<int> supported;
  final Set<int> unsupported;
  final Map<String, (String, String)> cells;

  VagBlockCacheData({
    Set<int>? supported,
    Set<int>? unsupported,
    Map<String, (String, String)>? cells,
  })  : supported = supported ?? <int>{},
        unsupported = unsupported ?? <int>{},
        cells = cells ?? <String, (String, String)>{};
}

class VagKwpStrategy extends VehicleStrategy {
  static final List<int> vagGroups = List<int>.generate(255, (i) => i + 1);

  String ecuId = '';
  final Set<int> vagSupported = <int>{};
  final Set<int> vagUnsupported = <int>{};
  final Map<String, (String, String)> vagCells = <String, (String, String)>{};

  final List<int> _vagQueue = <int>[];
  final List<int> _vagPendingNoData = <int>[];
  final Map<int, int> _vagFail = <int, int>{};
  final VagBlockCacheData? cache;

  List<int> activeFast = [0x2103, 0x2121];
  List<int> activeNormal = [0x2103, 0x2121, 0x2120, 0x2104];
  List<int> activeExtra = [];

  VagKwpStrategy({this.cache});

  @override
  String get profileId => 'vw_gol_me75';

  @override
  String get displayName => 'VW Gol G5 1.6 Flex (Bosch ME7.5.30)';

  bool get _isAspiratedGol =>
      ecuId.toUpperCase().startsWith('032906032AJ');

  @override
  Future<bool> initialize(Elm327Client elm, StrategyContext ctx) async {
    ctx.emitStatus(
      'connecting',
      'Inicializando protocolo VAG KWP2000 nativo (Bloco 033 Sonda Lambda)...',
    );
    ctx.emitLog(
      'Inicializando VAG KWP2000 no endereço 01 (ATSP4 + ATIIA01 + ATSH8110F1)...',
    );

    final isDemo = elm.transport.name == 'Demo';

    for (var attempt = 1; attempt <= 2; attempt++) {
      if (!ctx.isRunning) return false;
      await elm.command('ATPC', timeout: const Duration(seconds: 2));
      if (!isDemo) {
        for (var i = 0; i < 30; i++) {
          if (!ctx.isRunning) return false;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }

      for (final cmd in const [
        'ATAL',
        'ATSP4',
        'ATIB10',
        'ATKW0',
        'ATIIA01',
        'ATSH8110F1',
        'ATWM8110F13E',
      ]) {
        await elm.command(cmd, timeout: const Duration(seconds: 2));
      }

      final rInit = await elm.command(
        '1089',
        timeout: const Duration(seconds: 10),
      );
      if (rInit.error == 'UNABLE TO CONNECT' ||
          rInit.error == 'ERROR' ||
          rInit.error == 'BUS INIT: ERROR') {
        continue;
      }

      final rId = await elm.command(
        '1A9B',
        timeout: const Duration(milliseconds: 2500),
      );
      if (rId.ok && rId.dataLines().isNotEmpty) {
        final rawId = rId.dataLines().join('');
        if (rawId.startsWith('5A9B')) {
          final hexPart = rawId.substring(4);
          final evenLen = (hexPart.length ~/ 2) * 2;
          final bytes = hexToBytes(hexPart.substring(0, evenLen));
          if (bytes != null) {
            final asciiId = String.fromCharCodes(
              bytes.map((b) => (b >= 32 && b < 127) ? b : 32),
            ).trim();
            final ecuPart = asciiId.split(RegExp(r'\s+')).join(' ');
            if (ecuPart.isNotEmpty) {
              ecuId = ecuPart.split(' ').first;
            }
            ctx.emitLog('✔ ECU Identificada (VAG): $ecuPart');
          }
        }
      }

      final rProbe = await elm.queryPid('2121');
      if (rProbe.ok && !isVagNegative(rProbe)) {
        setupDiscovery(ctx);
        ctx.emitInfo(
          'Sonda Lambda e Fuel Trims ativos via VAG KWP2000 (Blocos 003, 032, 033)!',
        );
        ctx.emitStatus(
          'connected',
          'Conectado — VAG KWP2000 Nativo (Blocos 001..033 Sonda Ativa)',
        );
        return true;
      }
    }
    return false;
  }

  void setupDiscovery(StrategyContext ctx) {
    final c = cache;
    if (c != null) {
      vagSupported.addAll(c.supported);
      vagUnsupported
        ..addAll(c.unsupported)
        ..removeAll(vagSupported);
      c.cells.forEach((k, v) {
        try {
          final g = int.parse(k.substring(1, 4));
          final cell = int.parse(k.split('_c').last);
          vagCells[k] = (vagChannelLabel(g, cell, v.$2), v.$2);
        } catch (_) {
          vagCells.putIfAbsent(k, () => v);
        }
      });
    }

    final known = {...vagSupported, ...vagUnsupported};
    _vagQueue
      ..clear()
      ..addAll(vagGroups.where((g) => !known.contains(g)));
    _vagPendingNoData.clear();
    _vagFail.clear();

    final hasPressure115 = vagCells.entries.any((e) {
      if (!e.key.startsWith('g115_')) return false;
      final combined = '${e.value.$1} ${e.value.$2}'.toLowerCase();
      return combined.contains('mbar') ||
          combined.contains('bar') ||
          combined.contains('kpa') ||
          combined.contains('boost') ||
          combined.contains('pressão') ||
          combined.contains('pressao');
    });

    final meta = identifyEcu(rawId: ecuId, protocolName: 'VAG KWP2000');
    final isTurboEcu = meta.isTurbo;

    // Nunca promove Bloco 115 para activeFast na central aspirada 032906032AJ
    if (vagSupported.contains(115) &&
        !_isAspiratedGol &&
        (hasPressure115 || isTurboEcu)) {
      if (!activeFast.contains(0x2173)) {
        activeFast.add(0x2173);
      }
    } else if (isTurboEcu && !_isAspiratedGol) {
      // Para ECUs turbo reconhecidas, registra blocos turbo para descoberta imediata
      vagSupported.addAll(const [114, 115, 118]);
      if (!activeFast.contains(0x2173)) {
        activeFast.add(0x2173);
      }
    }

    if (vagCells.isNotEmpty) {
      ctx.emitChannels(Map<String, (String, String)>.from(vagCells));
    }
  }

  void _syncCache() {
    final c = cache;
    if (c == null) return;
    c.supported
      ..clear()
      ..addAll(vagSupported);
    c.unsupported
      ..clear()
      ..addAll(vagUnsupported);
    c.cells
      ..clear()
      ..addAll(vagCells);
  }

  void _markGroup(int group, bool ok) {
    var changed = false;
    if (ok && !vagSupported.contains(group)) {
      vagSupported.add(group);
      vagUnsupported.remove(group);
      changed = true;
    } else if (!ok &&
        !vagUnsupported.contains(group) &&
        !vagSupported.contains(group)) {
      vagUnsupported.add(group);
      changed = true;
    }
    _vagQueue.remove(group);
    _vagPendingNoData.remove(group);
    if (changed) _syncCache();
  }

  void _confirmPending() {
    if (_vagPendingNoData.isEmpty) return;
    for (final g in List<int>.from(_vagPendingNoData)) {
      _markGroup(g, false);
    }
  }

  Map<String, double>? _decodeCells(
    ElmResponse resp,
    int group,
    StrategyContext ctx,
  ) {
    final block = extractVagBlock(resp, group);
    if (block == null) return null;
    final cells = decodeVagBlock(group, block);
    _markGroup(group, true);

    final newCols = <String, (String, String)>{};
    cells.forEach((k, valUnit) {
      final cellIdx = int.parse(k.split('_c').last);
      final lbl = vagChannelLabel(group, cellIdx, valUnit.$2);
      final old = vagCells[k];
      if (old == null || old.$2 != valUnit.$2 || old.$1 != lbl) {
        vagCells[k] = (lbl, valUnit.$2);
        newCols[k] = (lbl, valUnit.$2);
      }
    });
    if (newCols.isNotEmpty) {
      ctx.emitChannels(newCols);
      _syncCache();
    }
    return {for (final e in cells.entries) e.key: e.value.$1};
  }

  Future<bool?> _probeGroup(
    Elm327Client elm,
    StrategyContext ctx,
    int group,
  ) async {
    final cmd = '21${group.toRadixString(16).toUpperCase().padLeft(2, '0')}';
    final r = await elm.command(cmd, timeout: const Duration(milliseconds: 2500));
    final vals = _decodeCells(r, group, ctx);
    if (vals != null) {
      final pdef = obdPids[0x2100 | group];
      if (pdef != null && pdef.mode == 0x21) {
        final data = extractPayload(r, 0x21, group, pdef.nbytes);
        if (data != null) {
          try {
            vals.addAll(pdef.decode(data));
          } catch (_) {}
        }
      }
      if (vals.isNotEmpty) {
        ctx.emitSample(vals);
      }
      _confirmPending();
      return true;
    }
    if (isVagNegative(r)) {
      _markGroup(group, false);
      return false;
    }
    if (r.error == 'NO DATA') {
      _vagQueue.remove(group);
      if (!_vagPendingNoData.contains(group)) {
        _vagPendingNoData.add(group);
      }
      return null;
    }
    final n = (_vagFail[group] ?? 0) + 1;
    _vagFail[group] = n;
    _vagQueue.remove(group);
    if (n < 3) {
      _vagQueue.add(group);
    }
    return null;
  }

  @override
  Future<int> pollCycle(
    Elm327Client elm,
    StrategyContext ctx,
    int cycle, {
    bool decelMode = false,
  }) async {
    var nResp = 0;
    final List<int> pidsToQuery;
    if (decelMode || !ctx.readExtras) {
      pidsToQuery = List<int>.from(activeFast);
    } else {
      // Prioriza Bloco 005 (0x2105) a cada 2 ciclos na Linha K
      final interleaved = <int>[
        0x2105, 0x2102, 0x2105, 0x2104,
        0x2105, 0x2120, 0x2105, 0x2167,
        0x2105, 0x2114, 0x2105, 0x213E,
      ];
      if (!_isAspiratedGol) {
        if (vagSupported.contains(114) && !interleaved.contains(0x2172)) {
          interleaved.add(0x2172);
        }
        if (vagSupported.contains(115) &&
            !activeFast.contains(0x2173) &&
            !interleaved.contains(0x2173)) {
          interleaved.add(0x2173);
        }
        if (vagSupported.contains(118) && !interleaved.contains(0x2176)) {
          interleaved.add(0x2176);
        }
      }
      final secBlock = interleaved[cycle % interleaved.length];
      pidsToQuery = [...activeFast, secBlock];
    }

    for (final pcode in pidsToQuery) {
      if (!ctx.isRunning) return nResp;
      final pdef = obdPids[pcode];
      if (pdef == null) continue;
      final resp = await elm.queryPid(pdef.cmd);
      if (resp.ok) {
        final data = extractPayload(resp, pdef.mode, pdef.pid, pdef.nbytes);
        if (data != null) {
          Map<String, double> vals;
          try {
            vals = Map<String, double>.from(pdef.decode(data));
          } catch (_) {
            vals = <String, double>{};
          }
          if (vals.isNotEmpty) {
            final cellVals = _decodeCells(resp, pdef.pid, ctx);
            if (cellVals != null) vals.addAll(cellVals);
            _confirmPending();
            ctx.emitSample(vals);
            nResp++;
          }
        } else {
          final cellVals = _decodeCells(resp, pdef.pid, ctx);
          if (cellVals != null && cellVals.isNotEmpty) {
            _confirmPending();
            ctx.emitSample(cellVals);
            nResp++;
          }
        }
      }
    }

    if (!decelMode && cycle % 6 == 0) {
      try {
        final vPin16 = await elm.batteryVoltage();
        if (vPin16 != null && vPin16 >= 5.0 && vPin16 <= 20.0) {
          ctx.emitSample({'obd_pin16_v': vPin16});
        }
      } catch (_) {}
    }

    if (!decelMode && ctx.backgroundScanEnabled) {
      if (_vagQueue.isNotEmpty && cycle % 4 == 0) {
        final targetG = _vagQueue.first;
        if (await _probeGroup(elm, ctx, targetG) == true) {
          nResp++;
        }
      }
    }

    return nResp;
  }

  @override
  Future<void> readDtcs(Elm327Client elm, StrategyContext ctx) async {
    final r = await elm.command('1800FF00', timeout: const Duration(seconds: 6));
    final lines = r.dataLines();
    final found = <DtcItem>[];
    if (r.ok && lines.isNotEmpty) {
      final raw = lines.join('');
      final idx = raw.indexOf('58');
      if (idx != -1) {
        final parsed = parseKwpDtcsHex(raw.substring(idx + 2));
        for (final item in parsed) {
          found.add(DtcItem('${item.code} (KWP)', item.description));
        }
      }
    }
    ctx.emitDtcs(false, found.length, found);
  }

  @override
  Future<void> clearDtcs(Elm327Client elm, StrategyContext ctx) async {
    await elm.command('14FF00', timeout: const Duration(seconds: 6));
    await readDtcs(elm, ctx);
  }

  void _parseClusterBlock(
    ElmResponse resp,
    int group,
    Map<String, double> out,
  ) {
    final block = extractVagBlock(resp, group);
    if (block == null) return;
    for (var i = 0; i + 2 < block.length; i += 3) {
      final cellIdx = i ~/ 3;
      final decoded = decodeVagCell(block[i], block[i + 1], block[i + 2]);
      if (decoded == null) continue;
      final val = decoded.$1;
      final rawUnit = decoded.$2;
      final u = rawUnit.toLowerCase().trim();

      if ((u.contains('l') && !u.contains('km') && !u.contains('/')) ||
          (cellIdx == 1 && (rawUnit == 'l' || rawUnit == 'L'))) {
        out.putIfAbsent('cluster_fuel_liters', () => val);
      } else if (u.contains('ohm') || u.contains('ω')) {
        out.putIfAbsent('cluster_fuel_ohms', () => val);
      } else if (u == 'km' || u == '10*km') {
        out.putIfAbsent('odometer_km', () => val);
      } else if ((u == '°c' || u == 'c') && (group == 2 && cellIdx == 3)) {
        out.putIfAbsent('ambient_temp', () => val);
      }
    }
  }

  @override
  Future<Map<String, double>> readInstrumentCluster(
    Elm327Client elm,
    StrategyContext ctx,
  ) async {
    ctx.emitLog('Consultando Painel de Instrumentos (0x17) via KWP2000...');
    ctx.emitStatus('connecting', 'Consultando Painel de Instrumentos (0x17)...');

    final out = <String, double>{};
    String? errDetail;

    try {
      for (final cmd in const [
        'ATIIA17',
        'ATSH 81 17 F1',
        'ATWM 81 17 F1 3E',
      ]) {
        await elm.command(cmd, timeout: const Duration(seconds: 2));
      }

      final rSess = await elm.command('1089', timeout: const Duration(seconds: 6));
      if (rSess.error == 'UNABLE TO CONNECT' ||
          rSess.error == 'BUS INIT: ERROR') {
        errDetail = rSess.error;
      } else {
        final r2102 = await elm.command(
          '2102',
          timeout: const Duration(milliseconds: 2500),
        );
        if (r2102.ok && !isVagNegative(r2102)) {
          _parseClusterBlock(r2102, 2, out);
        } else {
          errDetail = r2102.error ?? 'Resposta negativa em 2102';
        }

        if (ctx.isRunning) {
          final r2101 = await elm.command(
            '2101',
            timeout: const Duration(milliseconds: 2500),
          );
          if (r2101.ok && !isVagNegative(r2101)) {
            _parseClusterBlock(r2101, 1, out);
          }
        }
      }

      if (out.isNotEmpty) {
        if (out.containsKey('ambient_temp')) {
          ctx.emitChannels({'ambient_temp': ('Temp. Externa (Painel)', '°C')});
        }
        ctx.emitSample(out);
        final parts = <String>[
          if (out.containsKey('cluster_fuel_liters'))
            'Tanque ${out['cluster_fuel_liters']!.toStringAsFixed(1)} L',
          if (out.containsKey('cluster_fuel_ohms'))
            'Boia ${out['cluster_fuel_ohms']!.toStringAsFixed(0)} Ω',
          if (out.containsKey('odometer_km'))
            'Odômetro ${out['odometer_km']!.toStringAsFixed(0)} km',
          if (out.containsKey('ambient_temp'))
            'Temp. Ext ${out['ambient_temp']!.toStringAsFixed(1)} °C',
        ];
        final msg = 'Painel (0x17) lido: ${parts.join(' · ')}';
        ctx.emitLog('✔ $msg');
        ctx.emitInfo(msg);
      } else {
        final reason = errDetail ?? 'NO DATA';
        final msg =
            'Painel de Instrumentos (0x17) sem resposta ($reason). '
            'O painel pode operar em protocolo KW1281 ou estar inacessível na Linha K.';
        ctx.emitLog('⚠️ $msg');
        ctx.emitInfo(msg);
      }
    } finally {
      for (final cmd in const [
        'ATIIA01',
        'ATSH 81 10 F1',
        'ATWM 81 10 F1 3E',
      ]) {
        await elm.command(cmd, timeout: const Duration(seconds: 2));
      }
      await elm.command('1089', timeout: const Duration(seconds: 4));
      final rRestore = await elm.queryPid('2103');
      if (!rRestore.ok || isVagNegative(rRestore)) {
        await ctx.reinitBus();
      } else {
        ctx.emitStatus(
          'connected',
          'Conectado — VAG KWP2000 Nativo (Blocos 001..033 Sonda Ativa)',
        );
      }
    }

    return out;
  }

  static String _decodeKwpNrc(int nrc) {
    return switch (nrc) {
      0x10 => 'Rejeição geral (0x10)',
      0x11 => 'Serviço não suportado (0x11)',
      0x12 => 'Subfunção/formato não suportado (0x12)',
      0x21 => 'ECU ocupada (0x21)',
      0x22 => 'Condições incorretas — motor ligado ou temperatura/tensão fora da janela (0x22)',
      0x31 => 'Canal fora de faixa (0x31)',
      0x33 => 'Acesso de segurança / Seed-Key Bosch exigido (0x33)',
      0x35 => 'Chave de segurança inválida (0x35)',
      0x78 => 'Processando (0x78)',
      _ => 'NRC 0x${nrc.toRadixString(16).toUpperCase().padLeft(2, '0')}',
    };
  }

  static ({bool accepted, bool pending, int? nrc, String summary}) _evaluateKwpResp(
    ElmResponse resp,
    String expectedPosHex,
  ) {
    final allRaw = '${resp.lines.join('')} ${resp.error ?? ''}'
        .replaceAll(RegExp(r'\s+'), '')
        .toUpperCase();
    final hasPending78 = RegExp(r'7F[0-9A-F]{2}78').hasMatch(allRaw);
    // Remove frames intermediários 7F xx 78 (ResponsePending) antes de checar positivo/erro real
    final cleaned = allRaw.replaceAll(RegExp(r'7F[0-9A-F]{2}78'), '');
    final posHex = expectedPosHex.toUpperCase();
    if (cleaned.contains(posHex)) {
      return (accepted: true, pending: hasPending78, nrc: null, summary: 'ACEITO ($cleaned)');
    }
    final negMatch = RegExp(r'7F[0-9A-F]{2}([0-9A-F]{2})').firstMatch(cleaned);
    if (negMatch != null) {
      final nrc = int.tryParse(negMatch.group(1)!, radix: 16);
      return (
        accepted: false,
        pending: false,
        nrc: nrc,
        summary: 'REJEITADO: ${nrc != null ? _decodeKwpNrc(nrc) : cleaned}',
      );
    }
    if (hasPending78) {
      return (
        accepted: true,
        pending: true,
        nrc: 0x78,
        summary: 'ACEITO (Processando 0x78 — ECU executando comando)',
      );
    }
    final raw = resp.dataLines().join('').replaceAll(RegExp(r'\s+'), '').toUpperCase();
    if (!resp.ok || raw.isEmpty) {
      return (accepted: false, pending: false, nrc: null, summary: resp.error ?? 'SEM RESPOSTA');
    }
    if (raw.contains(posHex)) {
      return (accepted: true, pending: false, nrc: null, summary: 'ACEITO ($raw)');
    }
    return (accepted: false, pending: false, nrc: null, summary: 'INESPERADO ($raw)');
  }

  Future<Map<String, double>> _readBlockNow(
    Elm327Client elm,
    StrategyContext ctx,
    int pcode,
  ) async {
    final pdef = obdPids[pcode];
    if (pdef == null) return const {};
    final r = await elm.queryPid(pdef.cmd);
    if (!r.ok || isVagNegative(r)) return const {};
    final out = <String, double>{};
    final data = extractPayload(r, pdef.mode, pdef.pid, pdef.nbytes);
    if (data != null) {
      try {
        out.addAll(pdef.decode(data));
      } catch (_) {}
    }
    final cellVals = _decodeCells(r, pdef.pid, ctx);
    if (cellVals != null) out.addAll(cellVals);
    if (out.isNotEmpty) {
      ctx.emitSample(out);
    }
    return out;
  }

  @override
  Future<void> resetAdaptation(Elm327Client elm, StrategyContext ctx) async {
    ctx.emitLog('Iniciando Reset de Adaptação / Flex KWP2000 VAG (Bosch ME7.5.30)...');
    ctx.emitStatus('connecting', 'Executando Reset de Adaptação KWP2000 (Canal 00)...');

    // 1. Leitura ANTES do reset (Bloco 032 LTFT + Bloco 103 Flex Fixa)
    final before32 = await _readBlockNow(elm, ctx, 0x2120);
    final before103 = await _readBlockNow(elm, ctx, 0x2167);
    final ltftBefore = before32['ltft'];
    final flexBefore = before103['g103_c6'];

    // 2. Garante sessão diagnóstica estendida VAG KWP2000 (10 89)
    final rSess = await elm.command('1089', timeout: const Duration(seconds: 4));
    final evalSess = _evaluateKwpResp(rSess, '50');
    ctx.emitLog('> 1089 (Sessão VAG KWP2000) -> ${evalSess.summary}');

    // 3. Limpa DTCs / RAM (14 FF 00) — aguarda conclusão se ECU responder 0x78 (ResponsePending)
    final rClear = await elm.command('14FF00', timeout: const Duration(seconds: 6));
    final evalClear = _evaluateKwpResp(rClear, '54');
    ctx.emitLog('> 14FF00 (Limpar DTCs / RAM) -> ${evalClear.summary}');
    if (evalClear.pending) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }

    // 4. VAG KWP2000 Basic Setting Grupo 000 (31 B8 00 — NUNCA enviar 2800!)
    final rBasic = await elm.command('31B800', timeout: const Duration(seconds: 5));
    final evalBasic = _evaluateKwpResp(rBasic, '71');
    ctx.emitLog('> 31B800 (Basic Setting Grupo 000) -> ${evalBasic.summary}');
    if (evalBasic.pending) {
      await Future<void>.delayed(const Duration(milliseconds: 1000));
    }

    // 5. VAG KWP2000 Adaptation Channel 00 = 0000 (3B 00 00 00 — Factory Reset)
    final rAdapt = await elm.command('3B000000', timeout: const Duration(seconds: 5));
    final evalAdapt = _evaluateKwpResp(rAdapt, '7B');
    ctx.emitLog('> 3B000000 (Adaptação Canal 00 = 0) -> ${evalAdapt.summary}');

    await Future<void>.delayed(const Duration(milliseconds: 450));

    // 6. Releitura DEPOIS do reset para comprovação real
    final after32 = await _readBlockNow(elm, ctx, 0x2120);
    final after103 = await _readBlockNow(elm, ctx, 0x2167);
    final ltftAfter = after32['ltft'];
    final flexAfter = after103['g103_c6'];

    final ltftChanged = ltftBefore != null &&
        ltftAfter != null &&
        (ltftAfter - ltftBefore).abs() > 0.5;
    final flexChanged = flexBefore != null &&
        flexAfter != null &&
        (flexAfter - flexBefore).abs() > 1.0;
    final kwpAccepted = evalBasic.accepted || evalAdapt.accepted;

    final nrcs = <int>[
      if (evalBasic.nrc != null) evalBasic.nrc!,
      if (evalAdapt.nrc != null) evalAdapt.nrc!,
    ];

    if (kwpAccepted || ltftChanged || flexChanged) {
      final deltaParts = <String>[
        if (ltftBefore != null && ltftAfter != null)
          'LTFT ${ltftBefore.toStringAsFixed(1)}% → ${ltftAfter.toStringAsFixed(1)}%',
        if (flexBefore != null && flexAfter != null)
          'Flex(103.6) ${flexBefore.toStringAsFixed(0)}% → ${flexAfter.toStringAsFixed(0)}%',
      ];
      final detail = deltaParts.isNotEmpty ? ' (${deltaParts.join(' · ')})' : '';
      ctx.emitInfo('Reset KWP2000 aceito pela ECU!$detail');
      ctx.emitStatus('connected', 'Conectado — Reset KWP2000 confirmado');
    } else if (nrcs.contains(0x33)) {
      ctx.emitInfo(
        'ECU bloqueou o reset por Segurança (NRC 0x33 — Seed-Key Bosch exigido). '
        'Para destravar o Flex (103.6), abasteça ≥12 L com chave desligada ou use scanner VAG com login.',
      );
      ctx.emitStatus('connected', 'Conectado — Reset bloqueado pela ECU (NRC 0x33)');
    } else if (nrcs.contains(0x22)) {
      ctx.emitInfo(
        'ECU recusou o reset (NRC 0x22 — Condições incorretas). '
        'Desligue o motor mantendo apenas a ignição ligada e tente novamente.',
      );
      ctx.emitStatus('connected', 'Conectado — Reset recusado (NRC 0x22)');
    } else {
      final reason = !evalAdapt.accepted ? evalAdapt.summary : evalBasic.summary;
      ctx.emitInfo(
        'DTCs limpos, mas a ECU não zerou a EEPROM de LTFT/Flex ($reason). '
        'Abasteça ≥12 L com a chave desligada ou use scanner VAG Canal 00/Flex.',
      );
      ctx.emitStatus('connected', 'Conectado — EEPROM LTFT/Flex mantida pela ECU');
    }

    await readDtcs(elm, ctx);
  }

  @override
  Future<void> scanAll(Elm327Client elm, StrategyContext ctx) async {
    final groups = vagGroups.where((g) => !vagUnsupported.contains(g)).toList();
    final n = groups.length;
    ctx.emitLog('Varredura de blocos VAG: $n blocos...');
    for (var i = 0; i < groups.length; i++) {
      if (!ctx.isRunning) return;
      final g = groups[i];
      if (i % 8 == 0) {
        ctx.emitStatus(
          'connected',
          'Varrendo blocos VAG: ${g.toString().padLeft(3, '0')} (${i + 1}/$n)...',
        );
      }
      final res = await _probeGroup(elm, ctx, g);
      if ((res == null && _vagPendingNoData.length >= 8) || i % 8 == 7) {
        if (await _probeGroup(elm, ctx, 0x21) != true) {
          ctx.emitLog('Sessão VAG não respondeu durante a varredura — reinicializando...');
          _vagPendingNoData.clear();
          await ctx.reinitBus();
        }
      }
    }
    await _probeGroup(elm, ctx, 0x21);
    _syncCache();
    ctx.emitInfo('Varredura de blocos VAG concluída com sucesso!');
    ctx.emitStatus('connected', 'Conectado — VAG KWP2000 Nativo (Varredura Concluída)');
  }

  @override
  Map<String, (String, String)> getChannelsInfo() =>
      Map<String, (String, String)>.from(vagCells);
}
