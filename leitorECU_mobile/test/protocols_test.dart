import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:leitorecu_mobile/core/elm327/elm327_client.dart';
import 'package:leitorecu_mobile/core/models/channel_def.dart';
import 'package:leitorecu_mobile/core/models/vehicle_profile.dart';
import 'package:leitorecu_mobile/core/protocols/autodiscovery.dart';
import 'package:leitorecu_mobile/core/protocols/dtc_parser.dart';
import 'package:leitorecu_mobile/core/protocols/ecu_fingerprints.dart';
import 'package:leitorecu_mobile/core/protocols/ford_dids.dart';
import 'package:leitorecu_mobile/core/protocols/ford_hscan_strategy.dart';
import 'package:leitorecu_mobile/core/protocols/generic_obd_strategy.dart';
import 'package:leitorecu_mobile/core/protocols/pids.dart';
import 'package:leitorecu_mobile/core/protocols/readiness_parser.dart';
import 'package:leitorecu_mobile/core/protocols/vag_formulas.dart';
import 'package:leitorecu_mobile/core/protocols/vag_kwp_strategy.dart';
import 'package:leitorecu_mobile/core/protocols/vehicle_strategy.dart';
import 'package:leitorecu_mobile/core/transports/ble_transport.dart';
import 'package:leitorecu_mobile/core/transports/mock_engine.dart';
import 'package:leitorecu_mobile/core/transports/mock_transport.dart';
import 'package:leitorecu_mobile/core/transports/obd_transport.dart';
import 'package:leitorecu_mobile/core/transports/tcp_transport.dart';

class _DummyStrategyContext implements StrategyContext {
  @override
  bool isRunning = true;

  @override
  bool readExtras = true;

  @override
  bool backgroundScanEnabled = false;

  final List<Map<String, double>> samples = [];
  final List<(String, String)> statuses = [];
  final List<String> logs = [];
  final List<String> infos = [];
  final Map<String, (String, String)> channels = {};
  final List<(bool, int, List<DtcItem>)> dtcs = [];

  @override
  void emitSample(Map<String, double> values) => samples.add(values);

  @override
  void emitStatus(String state, String message) => statuses.add((state, message));

  @override
  void emitLog(String message) => logs.add(message);

  @override
  void emitInfo(String message) => infos.add(message);

  @override
  void emitChannels(Map<String, (String, String)> cols) => channels.addAll(cols);

  @override
  void emitDtcs(bool milOn, int count, List<DtcItem> list) =>
      dtcs.add((milOn, count, list));

  @override
  void emitProtocolMode(String modeName, {bool isFallback = false}) {}

  @override
  Future<void> reinitBus() async {}
}

class _ScriptedTransport extends ObdTransport {
  final String Function(String cmd) responder;
  final List<String> sentCommands = [];
  List<int> _pending = const [];
  bool _open = false;

  _ScriptedTransport(this.responder);

  @override
  String get name => 'Scripted';

  @override
  bool get isConnected => _open;

  @override
  Future<void> open() async => _open = true;

  @override
  Future<void> close() async => _open = false;

  @override
  Future<void> flushInput() async => _pending = const [];

  @override
  Future<List<int>> readSome(Duration timeout) async {
    final out = _pending;
    _pending = const [];
    return out;
  }

  @override
  Future<void> write(List<int> data) async {
    final cmd = ascii.decode(data).trim();
    sentCommands.add(cmd);
    final resp = responder(cmd);
    _pending = ascii.encode('$resp\r\r>');
  }
}

void main() {
  group('Models & ChannelDef', () {
    test('cardChannelKeys has 14 canonical cards and coreChannels contains all', () {
      expect(cardChannelKeys.length, 14);
      for (final k in cardChannelKeys) {
        final def = coreChannels[k];
        expect(def, isNotNull, reason: 'Missing coreChannel for $k');
        expect(def!.isCard, isTrue);
      }
      expect(coreChannels['ltft_idle']?.isCard, isFalse);
      expect(coreChannels['battery_charging']?.isCard, isFalse);
      expect(coreChannels['boost_bar']?.unit, 'bar');
      expect(coreChannels['lambda_error_pct']!.formatValue(2.5), '+2.5');
      expect(coreChannels['lambda_error_pct']!.formatValue(-1.2), '-1.2');
      expect(coreChannels['rpm']!.formatValue(852.4), '852');
    });

    test('describeChannel resolves core, extra, dynamic and unknown keys', () {
      expect(describeChannel('rpm'), (label: 'RPM', unit: 'rpm'));
      expect(
        describeChannel('g103_c5', {'g103_c5': ('Bloco 103.5 Etanol [%]', '%')}),
        (label: 'Bloco 103.5 Etanol [%]', unit: '%'),
      );
      expect(describeChannel('knock_ret_c1'), (label: 'Retardo Detonação Cil. 1', unit: '°KW'));
      expect(describeChannel('unknown_xyz'), (label: 'unknown_xyz', unit: ''));
    });

    test('profileDisplayName & demoProfileLabel', () {
      expect(profileDisplayName(VehicleProfileId.vwGol), contains('ME7.5.30'));
      expect(profileDisplayName(VehicleProfileId.fordKa), contains('Sigma'));
      expect(demoProfileLabel(DemoProfile.turboTsi), contains('TSI'));
    });
  });

  group('ELM327 Client', () {
    test('classify recognizes NRC 7F as error and valid hex as ok', () {
      final err1 = classifyElmResponse(['7F 21 11'], prompt: true);
      expect(err1, isNotNull);
      expect(err1, contains('NEGATIVE RESPONSE'));
      expect(err1, contains('21'));
      expect(err1, contains('11'));

      final err2 = classifyElmResponse(['7F 22 31'], prompt: true);
      expect(err2, contains('NEGATIVE RESPONSE'));
      expect(err2, contains('22'));
      expect(err2, contains('31'));

      expect(classifyElmResponse(['41 00 BE 3F A8 13'], prompt: true), isNull);
      expect(classifyElmResponse(['NO DATA'], prompt: true), 'NO DATA');
      expect(classifyElmResponse([], prompt: false), 'TIMEOUT');
    });

    test('extractPayload handles Mode 22 multi-frame with 6-char header', () {
      const resp = ElmResponse(
        '22404C',
        lines: [
          '0: 62 40 4C 01 02',
          '1: 03 04 05 06 07',
        ],
      );
      final payload = extractPayload(resp, 0x22, 0x404C, 7);
      expect(payload, isNotNull);
      expect(payload, equals([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07]));
    });
  });

  group('VAG Formulas & Mode 01/21 PIDs', () {
    test('vagKnownLabels has 103.5/103.6 and turbo blocks 114/115/118', () {
      expect(vagKnownLabels[(103, 5)], 'Fator Carga / Etanol Dinâmico');
      expect(vagKnownLabels[(103, 6)], 'Adaptação Flex Fixa');
      expect(vagKnownLabels[(114, 4)], contains('Wastegate'));
      expect(vagKnownLabels[(115, 3)]!.toLowerCase(), contains('turbo'));
      expect(vagKnownLabels[(118, 3)], isNotNull);
    });

    test('decodeVagCell covers key formulas and safe zero-division guards', () {
      expect(decodeVagCell(0x01, 100, 50), (1000.0, 'rpm'));
      expect(decodeVagCell(0x05, 10, 190), (90.0, '°C'));
      expect(decodeVagCell(0x12, 250, 100), (1000.0, 'mbar'));
      expect(decodeVagCell(0x1B, 1, 138)?.$1, closeTo(0.1, 0.001));
      expect(decodeVagCell(0x21, 100, 27), (27.0, '%'));
      expect(decodeVagCell(0x32, 0, 128), isNull);
      expect(decodeVagCell(0x3D, 0, 128), isNull);
      expect(decodeVagCell(0x00, 1, 2), isNull);
      expect(decodeVagCell(0x25, 0, 0), isNull);
    });

    test('extractVagBlock strips frame prefixes and repeated 61 GG headers', () {
      const resp = ElmResponse(
        '2167',
        lines: [
          '0: 61 67 00 00 00 00 00 00',
          '1: 61 67 00 00 00 00 00 00 21 64 1B 21 64 64',
        ],
      );
      final block = extractVagBlock(resp, 0x67);
      expect(block, isNotNull);
      expect(block!.length, 18);
      final decoded = decVagGroup103(block);
      expect(decoded['flex_ethanol_pct'], 27.0);
    });

    test('decVagGroup32 separates ltft_idle and ltft', () {
      final d = Uint8List.fromList([
        0x14, 0x64, 0x70, // C1: 100*(112-128)/128 = -12.5% -> ltft_idle
        0x14, 0x64, 0x90, // C2: 100*(144-128)/128 = +12.5% -> ltft
        0x14, 0x64, 0x80,
        0x06, 0x64, 0x8C, // C4: 0.001 * 100 * 140 = 14.000 V
      ]);
      final res = decVagGroup32(d);
      expect(res['ltft_idle'], closeTo(-12.5, 0.01));
      expect(res['ltft'], closeTo(12.5, 0.01));
      expect(res['ecu_volt'], closeTo(14.0, 0.01));
    });

    test('decVagGroup05 decodes Cut-Off, WOT and Closed Loop in C4', () {
      final base = [0x01, 100, 100, 0x02, 100, 100, 0x07, 100, 50];
      expect(
        decVagGroup05(Uint8List.fromList([...base, 0x25, 0x00, 0x08]))['fuel_sys1'],
        1.0,
      );
      expect(
        decVagGroup05(Uint8List.fromList([...base, 0x25, 0x00, 0x04]))['fuel_sys1'],
        4.0,
      );
      expect(
        decVagGroup05(Uint8List.fromList([...base, 0x25, 0x00, 0x01]))['fuel_sys1'],
        2.0,
      );
    });

    test('wideband 0124/0134 and turbo PIDs 0x22, 0x23, 0x6E, 0x6F, 0x70, 0x77', () {
      final wbV = decLambdaWbV(Uint8List.fromList([0x80, 0x00, 0x20, 0x00]));
      expect(wbV['lambda_eq'], closeTo(1.0, 0.001));
      expect(wbV['lambda_v'], closeTo(1.0, 0.001));

      final wbVLow = decLambdaWbV(Uint8List.fromList([0x80, 0x00, 0x00, 0x00]));
      expect(wbVLow['lambda_eq'], closeTo(1.0, 0.001));
      expect(wbVLow.containsKey('lambda_v'), isFalse);

      final wbI = decLambdaWbI(Uint8List.fromList([0x80, 0x00, 0x80, 0x00]));
      expect(wbI['lambda_eq'], closeTo(1.0, 0.001));
      expect(wbI.containsKey('lambda_v'), isFalse);

      expect(
        obdPids[0x22]!.decode(Uint8List.fromList([10, 0]))['fuel_rail_bar'],
        closeTo(2.0224, 0.01),
      );
      expect(
        obdPids[0x23]!.decode(Uint8List.fromList([0x05, 0xDC]))['fuel_rail_bar'],
        150.0,
      );
      expect(
        decPid6E(Uint8List.fromList([0x01, 101, 0, 0, 0]))['turbo_inlet_kpa'],
        101.0,
      );
      expect(
        decPid6F(Uint8List.fromList([0x01, 0x19, 0x00]))['boost_target_bar'],
        closeTo(0.99, 0.02),
      );
      final res70 = decPid70(
        Uint8List.fromList([0x03, 0x19, 0x00, 0x1B, 0x80, 0, 0, 153, 0, 153]),
      );
      expect(res70['boost_target_bar'], closeTo(0.99, 0.02));
      expect(res70['boost_bar'], closeTo(1.19, 0.02));
      expect(res70['wastegate_pct'], closeTo(60.0, 1.0));
      expect(
        decPid77(Uint8List.fromList([0x01, 75, 0]))['cac_temp_c'],
        35.0,
      );
    });

    test('VAG blocks 020, 114, 115, 118 and strict pressure unit rejection', () {
      final res20 = decVagGroup20(Uint8List.fromList([
        0x22, 100, 125,
        0x22, 100, 128,
        0x22, 100, 122,
        0x22, 100, 127,
      ]));
      expect(res20['knock_ret_c1'], -3.0);
      expect(res20['knock_ret_c3'], -6.0);
      expect(res20['knock_retard_max'], 6.0);

      final res114 = decVagGroup114(Uint8List.fromList([
        0x02, 100, 250,
        0x02, 100, 250,
        0x02, 200, 175,
        0x02, 250, 150,
      ]));
      expect(res114['load'], 70.0);
      expect(res114['wastegate_pct'], 75.0);

      final res115 = decVagGroup115(Uint8List.fromList([
        0x01, 100, 150,
        0x02, 200, 200,
        0x12, 250, 200,
        0x12, 250, 210,
      ]));
      expect(res115['rpm'], 3000.0);
      expect(res115['boost_target_abs_kpa'], 200.0);
      expect(res115['map'], 210.0);
      expect(res115['boost_bar'], closeTo(1.087, 0.01));

      // Non-pressure units (°C) MUST NOT emit map/boost_*
      final res115NonTurbo = decVagGroup115(Uint8List.fromList([
        0x01, 100, 150,
        0x02, 200, 200,
        0x05, 10, 190,
        0x05, 10, 195,
      ]));
      expect(res115NonTurbo.containsKey('map'), isFalse);
      expect(res115NonTurbo.containsKey('boost_bar'), isFalse);
      expect(res115NonTurbo.containsKey('boost_target_bar'), isFalse);

      final res118NonTurbo = decVagGroup118(Uint8List.fromList([
        0x01, 100, 150,
        0x05, 10, 135,
        0x02, 250, 130,
        0x05, 10, 190,
      ]));
      expect(res118NonTurbo['iat'], 35.0);
      expect(res118NonTurbo['wastegate_pct'], 65.0);
      expect(res118NonTurbo.containsKey('map'), isFalse);
      expect(res118NonTurbo.containsKey('boost_bar'), isFalse);
    });
  });

  group('VagKwpStrategy', () {
    test('does not promote Bloco 115 on 032906032AJ aspirated Gol', () {
      final strat = VagKwpStrategy();
      strat.ecuId = '032906032AJ';
      strat.vagSupported.add(115);
      final ctx = _DummyStrategyContext();
      strat.setupDiscovery(ctx);
      expect(strat.activeFast.contains(0x2173), isFalse);
    });

    test('prioritizes Bloco 005 every 2 cycles and resetAdaptation sends 14FF00 + 31010000 (never 2800)', () async {
      final t = _ScriptedTransport((cmd) {
        if (cmd == '2103') {
          return '61030110681201640301001B018A';
        }
        if (cmd == '2121') {
          return '61211401800601C2';
        }
        if (cmd == '2105') {
          return '6105011068020164070150250001';
        }
        if (cmd == '14FF00') return '54';
        if (cmd == '31010000') return '71010000';
        if (cmd == '2120') return '61201401801401801401800636B0';
        if (cmd == '1800FF00') return '5800000000';
        return 'NO DATA';
      });
      await t.open();
      final elm = Elm327Client(t);
      final strat = VagKwpStrategy();
      final ctx = _DummyStrategyContext();

      // Cycles 0, 2, 4 must query 2105
      for (final c in [0, 2, 4]) {
        t.sentCommands.clear();
        await strat.pollCycle(elm, ctx, c);
        expect(t.sentCommands, contains('2105'));
      }

      t.sentCommands.clear();
      await strat.resetAdaptation(elm, ctx);
      expect(t.sentCommands, contains('14FF00'));
      expect(t.sentCommands, contains('31010000'));
      expect(t.sentCommands.any((c) => c.contains('2800')), isFalse);
      await t.close();
    });
  });

  group('Ford DIDs & FordHsCanStrategy', () {
    test('EcoBoost DIDs decode correctly', () {
      expect(
        decPcmBoostTarget(Uint8List.fromList([0x00, 200]))['boost_target_bar'],
        closeTo(0.99, 0.02),
      );
      expect(
        decPcmWastegate(Uint8List.fromList([166]))['wastegate_pct'],
        closeTo(65.1, 0.5),
      );
      expect(
        decPcmCacTemp(Uint8List.fromList([80]))['cac_temp_c'],
        40.0,
      );
      expect(
        decPcmFuelRail(Uint8List.fromList([0x00, 150]))['fuel_rail_bar'],
        150.0,
      );
      expect(
        decPcmTurboInlet(Uint8List.fromList([0x00, 102]))['turbo_inlet_kpa'],
        102.0,
      );
    });

    test('FordHsCanStrategy.scanAll completes cleanly without crash', () async {
      final t = _ScriptedTransport((cmd) {
        if (cmd.startsWith('22')) return 'NO DATA';
        return 'OK';
      });
      await t.open();
      final elm = Elm327Client(t);
      final strat = FordHsCanStrategy();
      final ctx = _DummyStrategyContext();

      await strat.scanAll(elm, ctx);
      expect(ctx.logs, isNotEmpty);
      await t.close();
    });
  });

  group('DTCs, Readiness & Fingerprints', () {
    test('DTC Mode 03 and VAG KWP Service 18 parsing', () {
      final m03 = parseDtcsHex('43013303000000');
      expect(m03.map((e) => e.code).toList(), ['P0133', 'P0300']);

      final kwp = parseKwpDtcsHex('5802013300030000');
      expect(kwp.map((e) => e.code).toList(), ['P0133', 'P0300']);
    });

    test('Readiness PID 0101 and Freeze Frame Mode 02', () {
      final rep = parseReadinessPid01(Uint8List.fromList([0x82, 0x07, 0x65, 0x00]));
      expect(rep.milOn, isTrue);
      expect(rep.dtcCount, 2);
      expect(rep.isCompression, isFalse);
      expect(rep.supportedCount, greaterThan(0));

      final ff = parseFreezeFrameLines(['42020133', '420C0FA0', '420D3C']);
      expect(ff.dtc, 'P0133');
      expect(ff.values['rpm'], 1000.0);
      expect(ff.values['speed'], 60.0);
    });

    test('identifyEcu detects Turbo vs Aspirated accurately', () {
      expect(identifyEcu(rawId: '06K907425 Simos 18').isTurbo, isTrue);
      expect(identifyEcu(rawId: '5G0906259 MED17.5 EA888 TSI').isTurbo, isTrue);
      expect(identifyEcu(rawId: 'MG1CS032 GSE T270').isTurbo, isTrue);
      expect(identifyEcu(rawId: 'DELCO E84 CSS PRIME').isTurbo, isTrue);

      expect(identifyEcu(rawId: '032906032AJ ME7.5.30').isTurbo, isFalse);
      expect(identifyEcu(rawId: '2379060211 MP9.0').isTurbo, isFalse);
      expect(identifyEcu(rawId: 'EMS2211').isTurbo, isFalse);
    });
  });

  group('Transports, MockEngine & UniversalAutoDiscovery', () {
    test('TcpTransport communicates over loopback Socket with TCP_NODELAY', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      server.listen((client) {
        client.listen((data) {
          final cmd = ascii.decode(data).trim();
          if (cmd == 'ATZ') {
            client.add(ascii.encode('ELM327 v1.5\r\r>'));
          } else if (cmd == '010C') {
            client.add(ascii.encode('410C0FA0\r\r>'));
          }
        });
      });

      final tcp = TcpTransport(host: '127.0.0.1', port: server.port);
      await tcp.open();
      expect(tcp.isConnected, isTrue);

      final elm = Elm327Client(tcp);
      final r1 = await elm.command('ATZ');
      expect(r1.ok, isTrue);
      expect(r1.lines.join(' '), contains('ELM327'));

      final r2 = await elm.command('010C');
      final rpmBytes = extractPayload(r2, 0x01, 0x0C, 2);
      expect(rpmBytes, isNotNull);
      expect(obdPids[0x0C]!.decode(rpmBytes!)['rpm'], 1000.0);

      await tcp.close();
      expect(tcp.isConnected, isFalse);
    });

    test('BleTransport UUID table & MTU chunk sizing', () async {
      expect(knownBleUuids.length, 6);
      expect(BleTransport.computeChunkSize(23), 20);
      expect(BleTransport.computeChunkSize(185), 180);
      expect(BleTransport.computeChunkSize(512), 180);
      // Guarded check on desktop/test environment without native BLE plugin
      expect(await BleScanner.isBleAvailable(), isFalse);
    });

    test('UniversalAutoDiscovery + MockTransport for all 3 DemoProfiles', () async {
      // 1. Gol ME7.5.30 Aspirado
      final tGol = MockTransport(profile: DemoProfile.golMe75);
      await tGol.open();
      final elmGol = Elm327Client(tGol);
      final ctxGol = _DummyStrategyContext();
      final (stratGol, metaGol) =
          await UniversalAutoDiscovery.discover(elmGol, ctxGol);
      expect(stratGol, isA<VagKwpStrategy>());
      expect(metaGol.isTurbo, isFalse);
      expect(metaGol.rawId, contains('032906032AJ'));
      expect((await elmGol.command('2173')).error, 'NO DATA');
      expect((await elmGol.command('0170')).error, 'NO DATA');
      final r103 = await elmGol.command('2167');
      final b103 = extractVagBlock(r103, 103);
      expect(b103, isNotNull);
      expect(decVagGroup103(b103!)['flex_ethanol_pct'], 27.0);

      // Verify VAG blocks 003, 033, 005, 004, 032 decode realistic physical values
      tGol.engine.simulatedElapsedSeconds = 7.5; // acceleration phase
      for (var c = 0; c < 6; c++) {
        await stratGol.pollCycle(elmGol, ctxGol, c);
      }
      final mergedGol = <String, double>{};
      for (final s in ctxGol.samples) {
        mergedGol.addAll(s);
      }
      expect(mergedGol['rpm'], inInclusiveRange(1500.0, 4000.0));
      expect(mergedGol['map'], inInclusiveRange(50.0, 100.0));
      expect(mergedGol['tps'], inInclusiveRange(10.0, 65.0));
      expect(mergedGol['battery'], inInclusiveRange(13.0, 14.5));
      expect(mergedGol['ect'], inInclusiveRange(65.0, 95.0));
      expect(mergedGol.containsKey('ltft_idle'), isTrue);
      expect(mergedGol.containsKey('ltft'), isTrue);
      await tGol.close();

      // 2. Ford Ka+ 1.5 Sigma HS-CAN
      final tKa = MockTransport(profile: DemoProfile.kaSigma);
      await tKa.open();
      final elmKa = Elm327Client(tKa);
      final ctxKa = _DummyStrategyContext();
      final (stratKa, metaKa) =
          await UniversalAutoDiscovery.discover(elmKa, ctxKa);
      expect(stratKa, isA<FordHsCanStrategy>());
      expect(metaKa.isTurbo, isFalse);
      expect(metaKa.canModules, containsAll(['BCM', 'ABS', 'IPC', 'PSCM']));
      final cyclesKa = await stratKa.pollCycle(elmKa, ctxKa, 0);
      expect(cyclesKa, greaterThan(0));
      // EcoBoost DIDs must return negative response on Ka Sigma
      expect((await elmKa.command('220462')).error, contains('NEGATIVE RESPONSE'));
      await tKa.close();

      // 3. EA888 Turbo TSI (wideband, GDI, boost 220 kPa, knock spike in Bloco 020)
      final engineTurbo = MockEngine(profile: DemoProfile.turboTsi);
      engineTurbo.simulatedElapsedSeconds = 8.7; // ph = 8.7 -> k = 0.9 (> 0.70 knock spike + ~206 kPa)
      final tTurbo = MockTransport(engine: engineTurbo);
      await tTurbo.open();
      final elmTurbo = Elm327Client(tTurbo);
      final ctxTurbo = _DummyStrategyContext();
      final (stratTurbo, metaTurbo) =
          await UniversalAutoDiscovery.discover(elmTurbo, ctxTurbo);
      expect(stratTurbo, isA<VagKwpStrategy>());
      expect(metaTurbo.isTurbo, isTrue);
      expect(metaTurbo.rawId, contains('MED17'));

      final r115 = await elmTurbo.command('2173');
      final b115 = extractPayload(r115, 0x21, 0x73, 12);
      expect(b115, isNotNull);
      final dec115 = decVagGroup115(b115!);
      expect(dec115['map']!, greaterThan(180.0));
      expect(dec115['boost_bar']!, greaterThan(0.8));

      final r20 = await elmTurbo.command('2114');
      final b20 = extractPayload(r20, 0x21, 0x14, 12);
      expect(b20, isNotNull);
      expect(decVagGroup20(b20!)['knock_retard_max']!, greaterThan(0.0));

      final r70 = await elmTurbo.command('0170');
      final b70 = extractPayload(r70, 0x01, 0x70, 10);
      expect(b70, isNotNull);
      expect(decPid70(b70!)['boost_bar']!, greaterThan(0.8));

      final r24 = await elmTurbo.command('0124');
      final b24 = extractPayload(r24, 0x01, 0x24, 4);
      expect(b24, isNotNull);
      expect(decLambdaWbV(b24!)['lambda_eq']!, lessThan(0.95));

      await tTurbo.close();
    });

    test('UniversalAutoDiscovery sets ATCRA filter per CAN module', () async {
      final t = _ScriptedTransport((cmd) {
        if (cmd.startsWith('0100')) return '41 00 BE 3F A8 13';
        if (cmd.startsWith('224001')) return '62 40 01 0D 80';
        if (cmd.startsWith('222B00')) return '62 2B 00 13 88 13 88 13 88 13 88';
        return 'OK';
      });
      await t.open();
      final elm = Elm327Client(t);
      final ctx = _DummyStrategyContext();

      final (strat, meta) = await UniversalAutoDiscovery.discover(elm, ctx);
      expect(strat, isA<FordHsCanStrategy>());
      expect(meta.canModules, containsAll(['BCM', 'ABS']));

      final joined = t.sentCommands.join(' ');
      expect(joined, contains('ATCRA 72E'));
      expect(joined, contains('ATCRA 768'));
      expect(joined, contains('ATCRA 728'));
      expect(joined, contains('ATCRA 738'));
      await t.close();
    });

    test('GenericObdStrategy probes 0160 bitmap for turbo PIDs', () async {
      final tTurbo = MockTransport(profile: DemoProfile.turboTsi);
      await tTurbo.open();
      final elm = Elm327Client(tTurbo);
      final ctx = _DummyStrategyContext();
      final strat = GenericObdStrategy();
      expect(await strat.initialize(elm, ctx), isTrue);
      expect(strat.supported, containsAll([0x23, 0x24, 0x70, 0x77]));
      await tTurbo.close();
    });
  });
}
