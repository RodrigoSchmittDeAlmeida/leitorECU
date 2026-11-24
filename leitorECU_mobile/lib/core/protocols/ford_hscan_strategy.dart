/// Estratégia de comunicação Ford HS-CAN 500k (Ford Ka+ 2016 SEL 1.5 Sigma + EcoBoost).
library;

import 'dart:typed_data';

import '../elm327/elm327_client.dart';
import '../models/vehicle_profile.dart';
import 'dtc_parser.dart';
import 'ford_dids.dart';
import 'pids.dart';
import 'vehicle_strategy.dart';

class FordHsCanStrategy extends VehicleStrategy {
  String _currHeader = '7E0';
  String _currFilter = '7E8';

  late final Map<String, String> _txToRx = {
    for (final m in fordModules.values) m.txId: m.rxId,
  };
  late final Map<String, String> _txToKey = {
    for (final m in fordModules.values) m.txId: m.key,
  };

  final Map<String, int> _didFailures = <String, int>{};
  final Set<String> _unsupportedDids = <String>{};
  final Map<String, bool> _moduleOffline = <String, bool>{};
  final Set<String> _moduleEverResponded = <String>{'pcm'};

  @override
  String get profileId => 'ford_ka_2016_sigma';

  @override
  String get displayName => 'Ford Ka+ 2016 SEL 1.5 Sigma Flex (HS-CAN)';

  Future<void> _setTarget(
    Elm327Client elm,
    String txId, [
    String? rxId,
  ]) async {
    final targetRx = rxId ?? _txToRx[txId] ?? '7E8';
    if (_currHeader == txId && _currFilter == targetRx) return;
    await elm.command('ATSH$txId');
    await elm.command('ATCRA$targetRx');
    await elm.command('ATFCSH$txId');
    _currHeader = txId;
    _currFilter = targetRx;
  }

  @override
  Future<bool> initialize(Elm327Client elm, StrategyContext ctx) async {
    ctx.emitStatus(
      'connecting',
      'Inicializando barramento Ford HS-CAN 500k (PCM, BCM, ABS, IPC)...',
    );
    ctx.emitLog(
      'Configurando ATSP6 (ISO 15765-4 CAN 11/500k) + ATSH7E0 + ATCRA7E8...',
    );

    await elm.command('ATPC', timeout: const Duration(seconds: 1));
    for (final cmd in const [
      'ATSP6',
      'ATAL',
      'ATCAF1',
      'ATST64',
      'ATSH7E0',
      'ATCRA7E8',
      'ATFCSH7E0',
    ]) {
      await elm.command(cmd, timeout: const Duration(milliseconds: 1500));
    }
    _currHeader = '7E0';
    _currFilter = '7E8';
    _didFailures.clear();
    _unsupportedDids.clear();
    _moduleOffline.clear();
    _moduleEverResponded
      ..clear()
      ..add('pcm');

    final r0 = await elm.command('0100', timeout: const Duration(seconds: 3));
    if (r0.ok) {
      ctx.emitLog('✔ PCM Motor Ford (0x7E0) respondeu ao handshake!');
      ctx.emitChannels(Map<String, (String, String)>.from(fordChannelsInfo));
      ctx.emitInfo(
        'Ford Ka+ conectado: Barramento HS-CAN 500k ativo com PCM, ABS, IPC e EPAS!',
      );
      ctx.emitStatus(
        'connected',
        'Conectado — Ford Ka+ 2016 SEL 1.5 Sigma (HS-CAN 500k Ativo)',
      );
      return true;
    }

    ctx.emitLog('PCM não respondeu no ATSP6. Tentando autodetecção ATSP0...');
    await elm.command('ATSP0', timeout: const Duration(seconds: 2));
    final rAuto = await elm.command('0100', timeout: const Duration(seconds: 5));
    if (rAuto.ok) {
      await elm.command('ATCAF1');
      await elm.command('ATST64');
      await elm.command('ATSH7E0');
      await elm.command('ATCRA7E8');
      _currHeader = '7E0';
      _currFilter = '7E8';
      ctx.emitChannels(Map<String, (String, String)>.from(fordChannelsInfo));
      ctx.emitStatus('connected', 'Conectado — Ford Ka+ (CAN Auto)');
      return true;
    }

    return false;
  }

  Future<Map<String, double>?> _queryDid(
    Elm327Client elm,
    StrategyContext ctx,
    String moduleTx,
    String did,
    Map<String, double> Function(Uint8List data) decodeFn, {
    String? moduleRx,
  }) async {
    final modKey = _txToKey[moduleTx] ?? moduleTx;
    if (_moduleOffline[modKey] == true) return null;

    final didKey = '$moduleTx:$did';
    if (_unsupportedDids.contains(didKey)) return null;

    await _setTarget(elm, moduleTx, moduleRx);

    final resp = await elm.command(
      '22$did',
      timeout: const Duration(milliseconds: 1500),
    );
    final raw = resp.dataLines().join('').replaceAll(' ', '').toUpperCase();
    final errClean = resp.error?.replaceAll(' ', '').toUpperCase() ?? '';
    if (raw.contains('7F22') || errClean.contains('7F22')) {
      _moduleEverResponded.add(modKey);
      _unsupportedDids.add(didKey);
      return null;
    }

    if (resp.ok && resp.dataLines().isNotEmpty) {
      if (!raw.contains('NODATA') && !raw.contains('ERROR')) {
        final prefix = '62${did.toUpperCase()}';
        final idx = raw.indexOf(prefix);
        if (idx != -1) {
          final hexData = raw.substring(idx + prefix.length);
          final evenLen = (hexData.length ~/ 2) * 2;
          final rawBytes = hexToBytes(hexData.substring(0, evenLen));
          if (rawBytes != null) {
            try {
              final vals = decodeFn(rawBytes);
              if (vals.isNotEmpty) {
                ctx.emitSample(vals);
                _moduleEverResponded.add(modKey);
                _didFailures[didKey] = 0;
                return vals;
              }
            } catch (_) {}
          }
        }
      }
    }

    final fails = (_didFailures[didKey] ?? 0) + 1;
    _didFailures[didKey] = fails;
    if (fails >= 3) {
      _unsupportedDids.add(didKey);
      if (!_moduleEverResponded.contains(modKey)) {
        _moduleOffline[modKey] = true;
        if (modKey == 'bcm') {
          ctx.emitLog(
            'ℹ️ Módulo BCM (Conforto 0x726) não respondeu no barramento HS-CAN (Pinos 6 e 14).\n'
            '   No Ford Ka+, o BCM comunica via MS-CAN (Pinos 3 e 11).\n'
            '   Otimizando ciclo: focando nos módulos HS-CAN ativos (PCM, ABS, Painel IPC e Direção Elétrica EPAS).',
          );
        } else {
          final modName = fordModules[modKey]?.name ?? modKey;
          ctx.emitLog('ℹ️ Módulo $modName (0x$moduleTx) sem resposta no barramento.');
        }
      }
    }
    return null;
  }

  Future<int> _queryMode01List(
    Elm327Client elm,
    StrategyContext ctx,
    List<int> pidCodes,
  ) async {
    var count = 0;
    for (final pidCode in pidCodes) {
      if (!ctx.isRunning) return count;
      final pdef = obdPids[pidCode];
      if (pdef == null) continue;
      final resp = await elm.queryPid(pdef.cmd);
      if (resp.ok) {
        final data = extractPayload(resp, pdef.mode, pdef.pid, pdef.nbytes);
        if (data != null) {
          try {
            final vals = pdef.decode(data);
            if (vals.isNotEmpty) {
              ctx.emitSample(vals);
              count++;
            }
          } catch (_) {}
        }
      }
    }
    return count;
  }

  @override
  Future<int> pollCycle(
    Elm327Client elm,
    StrategyContext ctx,
    int cycle, {
    bool decelMode = false,
  }) async {
    var nResp = 0;

    if (cycle % 60 == 0 &&
        (_moduleOffline.isNotEmpty || _unsupportedDids.isNotEmpty)) {
      _moduleOffline.clear();
      _didFailures.clear();
      _unsupportedDids.clear();
    }

    await _setTarget(elm, '7E0', '7E8');

    final fastPids = <int>[0x0C, 0x0B, 0x0E, 0x11, 0x14, 0x15];
    if (!decelMode) {
      fastPids.addAll(const [0x04, 0x0D]);
    }
    nResp += await _queryMode01List(elm, ctx, fastPids);

    if (decelMode) return nResp;

    if (cycle % 2 == 0) {
      nResp += await _queryMode01List(elm, ctx, const [0x06, 0x07, 0x05, 0x0F]);
    }
    if (cycle % 4 == 2) {
      nResp += await _queryMode01List(elm, ctx, const [0x03, 0x3C, 0x42, 0x33]);
    }

    // DIDs Ford PCM (Sigma 1.5)
    if (cycle % 2 == 1) {
      if (await _queryDid(elm, ctx, '7E0', '1624', decPcmCht) != null) nResp++;
      if (await _queryDid(elm, ctx, '7E0', '032B', decPcmPedal) != null) nResp++;
      if (cycle % 4 == 1 &&
          await _queryDid(elm, ctx, '7E0', '0332', decPcmFan) != null) {
        nResp++;
      }
    }

    if (cycle % 4 == 0) {
      if (await _queryDid(elm, ctx, '7E0', '1125', decPcmInjection) != null) {
        nResp++;
      }
      if (await _queryDid(elm, ctx, '7E0', '0323', decPcmAcPress) != null) {
        nResp++;
      } else if (await _queryDid(elm, ctx, '7E0', '1101', decPcmAc) != null) {
        nResp++;
      }
      if (await _queryDid(elm, ctx, '7E0', '0325', decPcmAcClutch) != null) {
        nResp++;
      }
      if (await _queryDid(elm, ctx, '7E0', '1608', decPcmFlex) != null) nResp++;
      if (await _queryDid(elm, ctx, '7E0', '1627', decPcmCatTemp) != null) {
        nResp++;
      }
      if (await _queryDid(elm, ctx, '7E0', '0320', decPcmBaro) != null) nResp++;
    }

    // DIDs EcoBoost Turbo (suspensos via NRC 7F22 no Sigma 1.5 aspirado)
    if (cycle % 4 == 3) {
      if (await _queryDid(elm, ctx, '7E0', '0462', decPcmBoostTarget) != null) {
        nResp++;
      }
      if (await _queryDid(elm, ctx, '7E0', '0333', decPcmWastegate) != null) {
        nResp++;
      }
      if (await _queryDid(elm, ctx, '7E0', '03A0', decPcmCacTemp) != null) {
        nResp++;
      }
      if (await _queryDid(elm, ctx, '7E0', '03E7', decPcmFuelRail) != null) {
        nResp++;
      }
      if (await _queryDid(elm, ctx, '7E0', '04FE', decPcmTurboInlet) != null) {
        nResp++;
      }
    }

    // BCM 726
    if (cycle % 2 == 0) {
      if (await _queryDid(elm, ctx, '726', '404C', decBcmDoors) != null) nResp++;
      if (await _queryDid(elm, ctx, '726', '4050', decBcmLighting) != null) {
        nResp++;
      }
      if (cycle % 6 == 0) {
        if (await _queryDid(elm, ctx, '726', '4060', decBcmAccessories) != null) {
          nResp++;
        }
        if (await _queryDid(elm, ctx, '726', '4001', decBcmVoltage) != null) {
          nResp++;
        }
      }
    }

    // ABS 760
    if (cycle % 2 == 1) {
      if (await _queryDid(elm, ctx, '760', '2B00', decAbsWheels) != null) {
        nResp++;
      }
      if (await _queryDid(elm, ctx, '760', '2B01', decAbsDynamics) != null) {
        nResp++;
      }
    }

    // IPC 720
    if (cycle % 5 == 0) {
      if (await _queryDid(elm, ctx, '720', 'DD01', decIpcOdometer) != null) {
        nResp++;
      }
      if (await _queryDid(elm, ctx, '720', '2416', decIpcDashboard) != null) {
        nResp++;
      }
    }

    // PSCM 730
    if (cycle % 3 == 0) {
      final gotSteering =
          await _queryDid(elm, ctx, '730', '3300', decPscmSteering);
      if (gotSteering != null) {
        nResp++;
      } else {
        if (await _queryDid(elm, ctx, '730', '3301', decPscmAngle) != null) {
          nResp++;
        }
        if (await _queryDid(elm, ctx, '730', '3200', decPscmTorque) != null) {
          nResp++;
        }
      }
    }

    await _setTarget(elm, '7E0', '7E8');

    if (cycle % 6 == 0) {
      try {
        final vPin16 = await elm.batteryVoltage();
        if (vPin16 != null && vPin16 >= 5.0 && vPin16 <= 20.0) {
          ctx.emitSample({'obd_pin16_v': vPin16});
        }
      } catch (_) {}
    }

    return nResp;
  }

  @override
  Future<void> readDtcs(Elm327Client elm, StrategyContext ctx) async {
    final allFound = <DtcItem>[];
    var milOnAny = false;
    var dtcCountTotal = 0;

    for (final entry in fordModules.entries) {
      if (!ctx.isRunning) return;
      final modKey = entry.key;
      final mod = entry.value;
      if (_moduleOffline[modKey] == true) continue;

      await _setTarget(elm, mod.txId, mod.rxId);

      if (modKey == 'pcm') {
        final r1 = await elm.command(
          '0101',
          timeout: const Duration(milliseconds: 1500),
        );
        if (r1.ok && r1.dataLines().isNotEmpty) {
          final raw = r1.dataLines().join('').replaceAll(' ', '');
          if (raw.length >= 6) {
            final b = int.tryParse(raw.substring(4, 6), radix: 16) ?? 0;
            if ((b & 0x80) != 0) milOnAny = true;
          }
        }
      }

      final r3 = await elm.command('03', timeout: const Duration(seconds: 2));
      final lines = r3.dataLines();
      if (r3.ok && lines.isNotEmpty) {
        final raw = lines.join('').replaceAll(' ', '');
        final parsed = parseDtcsHex(raw);
        for (final item in parsed) {
          final fullCode = '[${mod.name}] ${item.code}';
          allFound.add(DtcItem(fullCode, item.description));
          dtcCountTotal++;
          ctx.emitLog('⚠ DTC detectado: $fullCode — ${item.description}');
        }
      }
    }

    await _setTarget(elm, '7E0', '7E8');
    ctx.emitDtcs(milOnAny, dtcCountTotal, allFound);
  }

  @override
  Future<void> clearDtcs(Elm327Client elm, StrategyContext ctx) async {
    for (final entry in fordModules.entries) {
      if (_moduleOffline[entry.key] == true) continue;
      await _setTarget(elm, entry.value.txId, entry.value.rxId);
      await elm.command('04', timeout: const Duration(seconds: 2));
    }
    await _setTarget(elm, '7E0', '7E8');
    await readDtcs(elm, ctx);
  }

  @override
  Future<void> scanAll(Elm327Client elm, StrategyContext ctx) async {
    _moduleOffline.clear();
    _didFailures.clear();
    _unsupportedDids.clear();
    ctx.emitLog(
      'Varredura de todos os módulos Ford (PCM, BCM Conforto, ABS, IPC, PSCM, RCM)...',
    );
    ctx.emitStatus('connected', 'Varrendo todos os módulos Ford Ka+...');
    var found = 0;
    for (final fdid in fordDids.values) {
      if (!ctx.isRunning) return;
      final mod = fordModules[fdid.moduleKey];
      if (mod == null) continue;
      final didNum = fdid.did.startsWith('22') ? fdid.did.substring(2) : fdid.did;
      final res = await _queryDid(
        elm,
        ctx,
        mod.txId,
        didNum,
        fdid.decode,
        moduleRx: mod.rxId,
      );
      if (res != null) {
        found++;
        ctx.emitLog('✔ [${mod.name}] ${fdid.label}: $res');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await _setTarget(elm, '7E0', '7E8');
    ctx.emitInfo('Varredura Ford concluída: $found grupos de sensores lidos com sucesso.');
    ctx.emitStatus('connected', 'Conectado — Ford Ka+ 2016 HS-CAN (Varredura Concluída)');
  }

  @override
  Map<String, (String, String)> getChannelsInfo() =>
      Map<String, (String, String)>.from(fordChannelsInfo);
}
