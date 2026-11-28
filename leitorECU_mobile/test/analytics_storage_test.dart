import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:leitorecu_mobile/analytics/detector.dart';
import 'package:leitorecu_mobile/analytics/dtc_parser.dart';
import 'package:leitorecu_mobile/analytics/fuel_estimator.dart';
import 'package:leitorecu_mobile/analytics/log_analyzer.dart';
import 'package:leitorecu_mobile/analytics/math_channels.dart';
import 'package:leitorecu_mobile/analytics/performance_timer.dart';
import 'package:leitorecu_mobile/analytics/readiness_parser.dart';
import 'package:leitorecu_mobile/core/ai/llm_diagnostic_service.dart';
import 'package:leitorecu_mobile/core/models/channel_def.dart';
import 'package:leitorecu_mobile/core/models/vehicle_profile.dart';
import 'package:leitorecu_mobile/core/platform/secure_storage.dart';
import 'package:leitorecu_mobile/core/settings/app_settings.dart';
import 'package:leitorecu_mobile/state/telemetry_controller.dart';
import 'package:leitorecu_mobile/storage/csv_logger.dart';
import 'package:leitorecu_mobile/storage/csv_replay_parser.dart';
import 'package:leitorecu_mobile/storage/log_exporters.dart';
import 'package:leitorecu_mobile/storage/log_repository.dart';

void main() {
  group('FuelEstimator', () {
    test('injector pulse width calculation has no 60x bug', () {
      final metrics = FuelEstimator.estimateFuelMetrics({
        'rpm': 3000.0,
        'inj_ms': 3.0,
        'map': 50.0,
        'speed': 80.0,
        'tps': 20.0,
      }, displacementL: 1.6);

      final lph = metrics['fuel_rate_lph']!;
      expect(lph, inInclusiveRange(2.5, 5.5));
      expect(metrics['fuel_econ_kml']!, greaterThan(0.0));
    });

    test('turbo speed-density computes VE above 100% up to 135%', () {
      final metrics = FuelEstimator.estimateFuelMetrics({
        'rpm': 4500.0,
        'map': 200.0,
        'speed': 130.0,
        'tps': 90.0,
        'iat': 40.0,
      }, displacementL: 2.0);

      expect(metrics['volumetric_eff']!, greaterThan(100.0));
      expect(metrics['volumetric_eff']!, lessThanOrEqualTo(135.0));
      expect(metrics['fuel_rate_lph']!, greaterThan(15.0));
    });

    test('fuel_econ_kml is consistent: 0.0 when stopped/slow, 99.9 in cut-off', () {
      final stopped = FuelEstimator.estimateFuelMetrics({
        'rpm': 800.0,
        'map': 32.0,
        'speed': 0.0,
        'tps': 0.0,
      });
      expect(stopped['fuel_econ_kml'], 0.0);

      final slow = FuelEstimator.estimateFuelMetrics({
        'rpm': 850.0,
        'map': 35.0,
        'speed': 1.5,
        'tps': 2.0,
      });
      expect(slow['fuel_econ_kml'], 0.0);

      final cutoff = FuelEstimator.estimateFuelMetrics({
        'rpm': 2500.0,
        'map': 20.0,
        'speed': 60.0,
        'tps': 0.0,
      });
      expect(cutoff['fuel_econ_kml'], 99.9);
      expect(cutoff['fuel_rate_lph'], 0.0);
    });
  });

  group('MathChannelsEngine', () {
    test('computes boost_bar, boost_psi, knock_retard_max, power up to 900hp, and only double values', () {
      final engine = MathChannelsEngine();

      final m1 = engine.compute(1.0, {
        'rpm': 6000.0,
        'map': 220.0,
        'baro': 100.0,
        'speed': 100.0,
        'fuel_rate_lph': 110.0,
        'flex_ethanol_pct': 85.0,
        'knock_ret_c1': 1.5,
        'knock_ret_c2': 4.5,
        'knock_ret_c3': 0.0,
        'knock_ret_c4': 3.0,
        'battery': 14.1,
        'lambda_v': 0.45,
      });

      expect(m1['boost_bar'], 1.2);
      expect((m1['boost_psi']! - 17.40).abs(), lessThan(0.1));
      expect(m1['knock_retard_max'], 4.5);
      expect(m1['power_hp']!, greaterThan(220.0));
      expect(m1['power_hp']!, lessThanOrEqualTo(900.0));
      expect(m1['torque_kgfm']!, greaterThan(20.0));
      expect(m1['battery_charging'], 1.0);
      expect(engine.lastBatteryStatus, 'charging_ok');
      expect(m1.containsKey('battery_status'), isFalse);

      // Every value in returned map must be double (enforced statically & checked at runtime)
      for (final val in m1.values) {
        expect(val, isA<double>());
        expect(val.isFinite, isTrue);
      }

      // Trip accumulation and accel_g on second sample
      final m2 = engine.compute(2.0, {
        'rpm': 6200.0,
        'map': 220.0,
        'speed': 118.0,
        'fuel_rate_lph': 110.0,
        'battery': 12.2,
      });
      expect(m2['trip_liters']!, greaterThan(0.0));
      expect(m2['trip_km']!, greaterThan(0.0));
      expect(m2['trip_cost_brl']!, greaterThan(0.0));
      expect(m2['trip_avg_kml']!, greaterThan(0.0));
      expect(m2['accel_g']!, greaterThan(0.0));
      expect(m2['battery_charging'], 0.0);
      expect(engine.lastBatteryStatus, 'alternator_fault');
    });

    test('evaluates cranking drop below 9.6V', () {
      final eval = MathChannelsEngine.evaluateBatteryHealth(
        8.9,
        rpm: 200.0,
        minCrankVolt: 8.9,
      );
      expect(eval.status, 'cranking_warning');
      expect(eval.crankingOk, isFalse);
      expect(eval.isCharging, isFalse);
    });

    test('computes realistic VW 1.6 EA111 WOT power/torque immune to stale inj_ms and 100% flex', () {
      final engine = MathChannelsEngine(displacementL: 1.6);

      final mTq = engine.compute(1.0, {
        'rpm': 2500.0,
        'map': 99.0,
        'iat': 35.0,
        'tps': 85.0,
        'inj_ms': 12.5,
        'flex_ethanol_pct': 100.0,
      });
      expect(mTq['torque_kgfm']!, inInclusiveRange(14.5, 16.0));
      expect(mTq['power_hp']!, inInclusiveRange(50.0, 58.0));

      final mHp = engine.compute(2.0, {
        'rpm': 5250.0,
        'map': 98.0,
        'iat': 35.0,
        'tps': 90.0,
        'inj_ms': 6.5,
        'flex_ethanol_pct': 100.0,
      });
      expect(mHp['power_hp']!, inInclusiveRange(96.0, 108.0));
      expect(mHp['torque_kgfm']!, inInclusiveRange(13.0, 14.8));

      // Em 6000 RPM aspirado (E27), roll-off de VE evita passar de 105 cv no EA111 1.6
      final m6000 = engine.compute(2.5, {
        'rpm': 6000.0,
        'map': 102.0,
        'iat': 38.0,
        'tps': 100.0,
        'inj_ms': 11.48,
      });
      expect(m6000['power_hp']!, inInclusiveRange(96.0, 105.0));

      final mCut = engine.compute(3.0, {
        'rpm': 2800.0,
        'map': 22.0,
        'iat': 35.0,
        'tps': 0.0,
        'inj_ms': 0.0,
      });
      expect(mCut['power_hp'], 0.0);
      expect(mCut['torque_kgfm'], 0.0);
    });
  });

  group('DecelDetector', () {
    test('detects cut-off episode and is wideband-safe', () {
      final det = DecelDetector();
      // 1. Acceleration
      var evs = det.update(
        1.0,
        {'rpm': 3500.0, 'tps': 30.0, 'map': 60.0, 'lambda_v': 0.85, 'advance': 22.0},
        {'rpm': 1.0, 'tps': 1.0, 'map': 1.0, 'lambda_v': 1.0, 'advance': 1.0},
      );
      expect(evs, isEmpty);
      expect(det.inDecel, isFalse);

      // 2. Throttle closed + RPM drop
      evs = det.update(
        1.3,
        {'rpm': 2900.0, 'tps': 0.0, 'map': 22.0, 'lambda_v': 0.85, 'advance': 10.0},
        {'rpm': 1.3, 'tps': 1.3, 'map': 1.3, 'lambda_v': 1.3, 'advance': 1.3},
      );
      expect(det.inDecel, isTrue);

      // 3. Wideband lambda_eq = 1.95 with high voltage lambda_v = 2.45 must NOT false-alarm
      evs = det.update(
        1.8,
        {'rpm': 2400.0, 'tps': 0.0, 'map': 20.0, 'lambda_v': 2.45, 'lambda_eq': 1.95},
        {'rpm': 1.8, 'tps': 1.8, 'map': 1.8, 'lambda_v': 1.8, 'lambda_eq': 1.8},
      );
      expect(evs.where((e) => e.message.contains('FALHA DE CUT-OFF')), isEmpty);

      // 4. Reaccel ends decel with info Cut-Off OK
      evs = det.update(
        2.5,
        {'rpm': 2200.0, 'tps': 25.0, 'map': 50.0, 'lambda_eq': 1.0},
        {'rpm': 2.5, 'tps': 2.5, 'map': 2.5, 'lambda_eq': 2.5},
      );
      expect(det.inDecel, isFalse);
      expect(evs, isNotEmpty);
      expect(evs.last.level, 'info');
      expect(evs.last.message, contains('Cut-Off OK'));
    });

    test('detects load conflict (<0.25s skew), ATDC retard, overboost, underboost, knock, trim drift, cranking', () {
      final det = DecelDetector();

      // Load conflict with 0.15s skew
      final evLoad = det.update(
        10.0,
        {'rpm': 1100.0, 'tps': 3.0, 'map': 75.0, 'advance': -12.0},
        {'rpm': 10.0, 'map': 10.0, 'tps': 9.85, 'advance': 10.0},
      );
      expect(evLoad.any((e) => e.message.contains('CARGA ANORMAL') && e.level == 'alarm'), isTrue);
      expect(evLoad.any((e) => e.message.contains('RETARDO CRÍTICO ATDC') && e.level == 'alarm'), isTrue);

      // Overboost
      det.update(1.0, {'boost_bar': 1.60, 'boost_target_bar': 1.10}, {'boost_bar': 1.0, 'boost_target_bar': 1.0});
      final evOver = det.update(1.5, {'boost_bar': 1.65, 'boost_target_bar': 1.10}, {'boost_bar': 1.5, 'boost_target_bar': 1.5});
      expect(evOver.any((e) => e.message.contains('OVERBOOST') && e.level == 'alarm'), isTrue);

      // Underboost
      det.reset();
      Map<String, double> stamps(double t) => {
            'rpm': t,
            'tps': t,
            'boost_bar': t,
            'boost_target_bar': t,
            'knock_retard_max': t,
            'stft': t,
            'ltft': t,
          };
      det.update(10.0, {'rpm': 4200.0, 'tps': 95.0, 'boost_bar': 0.80, 'boost_target_bar': 1.40}, stamps(10.0));
      final evUnder = det.update(11.6, {'rpm': 4800.0, 'tps': 95.0, 'boost_bar': 0.85, 'boost_target_bar': 1.40}, stamps(11.6));
      expect(evUnder.any((e) => e.message.contains('UNDERBOOST') && e.level == 'warn'), isTrue);

      // Knock warn & alarm
      final evKnockWarn = det.update(12.0, {'knock_retard_max': 3.5}, stamps(12.0));
      expect(evKnockWarn.any((e) => e.level == 'warn' && e.message.contains('DETONAÇÃO MODERADA')), isTrue);
      final evKnockAlarm = det.update(15.5, {'knock_retard_max': 6.8}, stamps(15.5));
      expect(evKnockAlarm.any((e) => e.level == 'alarm' && e.message.contains('DETONAÇÃO CRÍTICA')), isTrue);

      // Fuel trim drift
      det.update(20.0, {'rpm': 850.0, 'tps': 0.0, 'stft': 14.0, 'ltft': 12.0}, stamps(20.0));
      final evDrift = det.update(22.2, {'rpm': 850.0, 'tps': 0.0, 'stft': 13.5, 'ltft': 12.0}, stamps(22.2));
      expect(evDrift.any((e) => e.level == 'warn' && e.message.contains('DESVIO SEVERO DE MISTURA')), isTrue);

      // Cranking drop
      det.reset();
      det.update(1.0, {'rpm': 220.0, 'battery': 8.3}, {'rpm': 1.0, 'battery': 1.0});
      final evCrank = det.update(2.0, {'rpm': 900.0, 'battery': 14.1}, {'rpm': 2.0, 'battery': 2.0});
      expect(evCrank.any((e) => e.level == 'alarm' && e.message.contains('Queda severa')), isTrue);
    });
  });

  group('PerformanceTimer', () {
    test('records 0-60, 0-100, 100-200, 402m, history and rejects discontinuous braking', () {
      final timer = PerformanceTimer();
      timer.update(1.0, 0.0);
      timer.update(1.2, 5.0);
      timer.update(5.0, 60.0);
      timer.update(8.5, 100.0);
      timer.distanceM = 405.0;
      timer.update(14.0, 160.0);

      expect(timer.state, 'FINISHED');
      expect(timer.history.length, 1);
      expect(timer.history.first.time0to60, isNotNull);
      expect(timer.history.first.time0to100, isNotNull);
      expect(timer.history.first.time402m, isNotNull);

      timer.reset();
      timer.update(20.0, 98.0);
      timer.update(21.0, 100.0);
      timer.update(28.0, 202.0);
      expect(timer.record.time100to200, 7.0);

      // Discontinuous braking must be rejected
      timer.reset();
      timer.update(30.0, 102.0);
      timer.update(31.0, 80.0);
      timer.update(32.0, 90.0);
      timer.update(33.0, 0.0);
      expect(timer.record.braking100to0, isNull);

      // Continuous braking succeeds
      timer.reset();
      timer.update(40.0, 100.0);
      timer.update(41.5, 50.0);
      timer.update(43.2, 0.0);
      expect(timer.record.braking100to0, 3.2);
    });
  });

  group('DTC & Readiness Parsers', () {
    test('parses Mode 03, KWP Service 18, Readiness PID 0101 and Freeze Frame', () {
      final m03 = parseDtcsHex('4301330300');
      expect(m03.map((e) => e.code).toList(), ['P0133', 'P0300']);
      expect(describeDtc('[ABS] C0031').toLowerCase(), contains('velocidade'));

      final kwp = parseKwpDtcsHex('5802013300030000');
      expect(kwp.map((e) => e.code).toList(), ['P0133', 'P0300']);

      final rd = parseReadinessPid01([0x82, 0x07, 0x01, 0x02]);
      expect(rd.milOn, isTrue);
      expect(rd.dtcCount, 2);
      expect(rd.isCompression, isFalse);
      expect(rd.supportedCount, 5);
      expect(rd.readyCount, 5);

      final ff = parseFreezeFrame(['42 02 01 33', '42 0C 0D AC', '42 05 7D', '42 0B 32']);
      expect(ff.dtc, 'P0133');
      expect(ff.values['rpm'], 875.0);
      expect(ff.values['ect'], 85.0);
      expect(ff.values['map'], 50.0);
    });
  });

  group('Storage: CsvLogger, MegaLogViewerExporter, CsvReplayParser, SeriesBuffer & LogRepository', () {
    test('SeriesBuffer window returns correct binary-searched slice', () {
      final buf = SeriesBuffer(capacity: 100);
      for (var i = 0; i < 10; i++) {
        buf.append(i.toDouble(), i * 10.0);
      }
      final w = buf.window(5.0);
      expect(w.times, [5.0, 6.0, 7.0, 8.0, 9.0]);
      expect(w.values, [50.0, 60.0, 70.0, 80.0, 90.0]);
    });

    test('CsvLogger writes UTF-8 BOM, ; delimiter, comma decimals and expands dynamic columns safely', () async {
      final tmpDir = await Directory.systemTemp.createTemp('leitorecu_csv_test_');
      try {
        final csvPath = '${tmpDir.path}${Platform.pathSeparator}test_log.csv';
        final logger = CsvLogger(decimalComma: true);
        logger.start(csvPath);

        logger.write(1000.0, 1.234, 'rpm+lambda_v', {
          'rpm': 850.0,
          'lambda_v': 0.450,
          'lambda2_v': 0.655,
          'map': 32.5,
        }, event: 'CUT_OFF');

        logger.addColumns({'g099_c1': 'Bloco 099.1 RPM [rpm]'});
        logger.write(2000.0, 2.500, 'g099_c1', {
          'rpm': 2100.0,
          'g099_c1': 2100.0,
          'custom_dyn_x': 42.125,
        });
        logger.stop();

        final bytes = await File(csvPath).readAsBytes();
        expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);

        final text = utf8.decode(bytes.sublist(3));
        final lines = text.trim().split(RegExp(r'\r\n|\n'));
        expect(lines.length, 3);
        expect(lines[0], contains('Bloco 099.1 RPM [rpm]'));
        expect(lines[0], contains('custom_dyn_x'));
        expect(lines[0].endsWith(';evento'), isTrue);
        expect(lines[1], contains('1,234'));
        expect(lines[1], contains('0,450'));
        expect(lines[1].endsWith(';CUT_OFF'), isTrue);

        // MegaLogViewer export
        final mslPath = '${tmpDir.path}${Platform.pathSeparator}out.msl';
        final ok = await MegaLogViewerExporter.exportFromCsv(csvPath, mslPath);
        expect(ok, isTrue);
        final mslLines = await File(mslPath).readAsLines();
        expect(mslLines.first.split('\t'), containsAll(['Time', 'RPM', 'MAP', 'Boost', 'Knock_Retard', 'Marker']));
        expect(mslLines[1], contains('1.234'));

        // CsvReplayParser parses our own mobile CSV and desktop PC CSV format
        final ds = await CsvReplayParser.parseFile(csvPath);
        expect(ds.length, 2);
        expect(ds.isTurboDetected, isFalse);
        expect(ds.events.length, 1);
        expect(ds.events.first.text, 'CUT_OFF');
        expect(ds.records[0]['lambda2_v'], closeTo(0.655, 0.001));
        expect(ds.records[1]['custom_dyn_x'], closeTo(42.125, 0.001));
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    test('CsvReplayParser handles desktop PC CSV header with BOM, VAG blocks and detects turbo logs', () {
      const desktopCsv = '\uFEFFtimestamp_ms;tempo_s;atualizado;rpm;map;advance;tps;boost_bar;Bloco 003.1 RPM [rpm] [rpm];evento\r\n'
          '1795389012976;35,869;rpm+map;800,000;41,000;6,000;4,314;-0,603;800,000;\r\n'
          '1795389013546;36,439;rpm+map;4500,000;210,000;14,500;95,000;1,100;4500,000;WOT\r\n';

      final ds = CsvReplayParser.parseString(desktopCsv);
      expect(ds.length, 2);
      expect(ds.times, [35.869, 36.439]);
      expect(ds.records[0]['rpm'], 800.0);
      expect(ds.records[0]['g003_c1'], 800.0);
      expect(ds.records[1]['map'], 210.0);
      expect(ds.isTurboDetected, isTrue);
      expect(ds.events.length, 1);
      expect(ds.events.first.text, 'WOT');
      expect(ds.indexForTime(36.3), 1);
    });

    test('LogRepository lists newest-first, imports, exports MSL, renames and deletes', () async {
      final tmpDir = await Directory.systemTemp.createTemp('leitorecu_repo_test_');
      final externalDir = await Directory.systemTemp.createTemp('leitorecu_ext_test_');
      try {
        final repo = LogRepository(directoryOverride: tmpDir);
        final extPath = '${externalDir.path}${Platform.pathSeparator}pc_gol.csv';
        await File(extPath).writeAsString(
          '\uFEFFtimestamp_ms;tempo_s;atualizado;rpm;map;evento\r\n'
          '1000;0,000;rpm;850,000;35,000;\r\n'
          '2000;2,500;rpm;1200,000;45,000;OK\r\n',
        );

        final imported = await repo.importCsvFile(sourcePath: extPath);
        expect(imported, isNotNull);
        expect(imported!.rowCount, 2);
        expect(imported.durationSec, closeTo(2.5, 0.001));

        final createdPath = await repo.createNewLogPath(prefix: 'run');
        final logger = CsvLogger();
        logger.start(createdPath);
        logger.write(1000, 0.0, 'rpm', {'rpm': 900});
        logger.stop();

        final logs = await repo.listLogs();
        expect(logs.length, 2);

        final mslPath = await repo.exportMslFile(imported.path);
        expect(mslPath, isNotNull);
        expect(await File(mslPath!).exists(), isTrue);

        final renamed = await repo.renameLog(imported.path, 'gol_g5_rua');
        expect(renamed, isNotNull);
        expect(renamed!.name, 'gol_g5_rua.csv');

        expect(await repo.deleteLog(renamed.path), isTrue);
        expect((await repo.listLogs()).length, 1);
      } finally {
        await tmpDir.delete(recursive: true);
        await externalDir.delete(recursive: true);
      }
    });
  });

  group('Map2dAggregator & TelemetryController', () {
    test('Map2dAggregator starts 9x9 aspirated, auto-expands to 10x9 turbo on map > 105, computes stats & CSV', () {
      final map2d = Map2dAggregator();
      expect(map2d.rowCount, 9);
      expect(map2d.colCount, 9);
      expect(map2d.isTurboScale, isFalse);

      map2d.addSample(2200.0, 50.0, {'advance': 24.0, 'stft': -2.0});
      map2d.addSample(2200.0, 50.0, {'advance': 26.0, 'stft': 2.0});

      final active = map2d.lastActiveCell!;
      expect(map2d.cellValue(active.$1, active.$2, 'advance', Map2dStat.mean), 25.0);
      expect(map2d.cellValue(active.$1, active.$2, 'advance', Map2dStat.min), 24.0);
      expect(map2d.cellValue(active.$1, active.$2, 'advance', Map2dStat.max), 26.0);
      expect(map2d.cellCount(active.$1, active.$2, 'advance'), 2);

      // Boost sample triggers 10x9 Turbo auto-expansion and recomputes history
      map2d.addSample(4000.0, 190.0, {'advance': 12.0, 'boost_bar': 0.90});
      expect(map2d.isTurboScale, isTrue);
      expect(map2d.rowCount, 10);
      expect(map2d.colCount, 9);

      final csv = map2d.toCsv(metric: 'advance', stat: Map2dStat.mean);
      expect(csv, contains('MAP_kPa / RPM;'));
      expect(csv, contains('250 kPa'));
      expect(csv, contains('25,00'));
    });

    test('TelemetryController connects in Demo mode, records CSV, reads DTC/Readiness/FreezeFrame, detects ECU OFF Power Latch, and replays CSV', () async {
      final tmpDir = await Directory.systemTemp.createTemp('leitorecu_ctrl_test_');
      try {
        final ctrl = TelemetryController(
          logRepository: LogRepository(directoryOverride: tmpDir),
        );

        // Settings persistence must not throw in headless unit tests
        await ctrl.loadSettings();
        await ctrl.saveSettings();

        ctrl.setTransportConfig(
          kind: TransportKind.demo,
          demo: DemoProfile.golMe75,
          profile: VehicleProfileId.auto,
        );

        await ctrl.connect();

        // Wait briefly for demo handshake + live polling cycles
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline) &&
            (ctrl.connectionState != ConnectionStateKind.connected ||
                !ctrl.latest.containsKey('rpm'))) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        expect(ctrl.connectionState, ConnectionStateKind.connected);
        expect(ctrl.latest['rpm'], isNotNull);
        expect(ctrl.peakMax['rpm'], isNotNull);
        expect(ctrl.buffers['rpm']!.isNotEmpty, isTrue);

        // Start recording and wait for rows
        final recPath = await ctrl.startRecording(prefix: 'demo');
        expect(recPath, isNotNull);
        expect(ctrl.isRecording, isTrue);

        ctrl.requestReadDtcs();
        ctrl.requestReadiness();
        ctrl.requestFreezeFrame();

        final cmdDeadline = DateTime.now().add(const Duration(seconds: 3));
        while (DateTime.now().isBefore(cmdDeadline) &&
            (ctrl.readinessReport == null ||
                ctrl.freezeFrameData == null ||
                ctrl.recordingRows < 2)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        expect(ctrl.readinessReport, isNotNull);
        expect(ctrl.freezeFrameData, isNotNull);
        expect(ctrl.recordingRows, greaterThanOrEqualTo(2));

        await ctrl.stopRecording();
        expect(ctrl.isRecording, isFalse);

        // Clear peaks
        ctrl.clearPeaks();
        expect(ctrl.peakMax, isEmpty);

        // Pause background Demo polling before deterministic ECU OFF / Power Latch simulation
        ctrl.pollDelayMs = -1;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        ctrl.emitSample({'rpm': 900.0, 'map': 35.0});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        ctrl.emitSample({'rpm': 0.0, 'map': 100.0});
        await Future<void>.delayed(const Duration(milliseconds: 30));
        ctrl.emitSample({'map': 100.0});
        ctrl.notifyMissedPollCycleForTest(consecutiveMissed: 2);
        expect(ctrl.connectionState, ConnectionStateKind.ecuOff);
        expect(ctrl.lastPowerLatchDurationSec, isNotNull);

        await ctrl.disconnect();
        expect(ctrl.connectionState, ConnectionStateKind.offline);

        // Replay the recorded CSV
        final loaded = await ctrl.loadReplayFromPath(recPath!);
        expect(loaded, isTrue);
        expect(ctrl.replayMode, isTrue);
        expect(ctrl.replayDataset, isNotNull);
        ctrl.scrubReplay(ctrl.replayDataset!.maxTime);
        expect(ctrl.replayValues, isNotEmpty);

        ctrl.exitReplayMode();
        expect(ctrl.replayMode, isFalse);
        ctrl.dispose();
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });
  });

  group('Bug Fixes & Multi-Format Log Exporters', () {
    test('MathChannelsEngine guards standby gaps, partial frames & duplicate keys', () {
      final mathEngine = MathChannelsEngine();

      // Amostra inicial a 100 km/h
      final m0 = mathEngine.compute(0.0, {
        'rpm': 3000.0,
        'map': 60.0,
        'iat': 30.0,
        'speed': 100.0,
        'inj_ms': 4.0,
      }, speedUpdated: true);
      expect(m0.containsKey('trip_fuel_liters'), isFalse);

      // Pacote parcial VAG (Bloco 003 sem velocidade): não gera pico negativo de accel_g
      final m1 = mathEngine.compute(0.25, {
        'rpm': 3050.0,
        'map': 62.0,
        'iat': 30.0,
        'speed': 100.0,
        'inj_ms': 4.1,
      }, speedUpdated: false);
      expect(m1['accel_g'], isNull);
      expect(m1['trip_km']!, greaterThan(0.005));

      // Novo pacote com velocidade mantida em 100 km/h após 1.0s
      final m2 = mathEngine.compute(1.0, {
        'rpm': 3100.0,
        'map': 64.0,
        'iat': 30.0,
        'speed': 100.0,
        'inj_ms': 4.2,
      }, speedUpdated: true);
      expect(m2['accel_g'], closeTo(0.0, 0.05));
      // Distância acumulada ~ 100 km/h * 1s / 3600 = 0.02778 km
      expect(m2['trip_km']!, closeTo(100.0 / 3600.0, 0.003));

      // Pausa de App Standby de 360s: distância e combustível NÃO devem inflar
      final tripBeforeGap = m2['trip_km']!;
      final mAfterGap = mathEngine.compute(361.0, {
        'rpm': 850.0,
        'map': 32.0,
        'iat': 35.0,
        'speed': 0.0,
        'inj_ms': 2.5,
      }, speedUpdated: true);
      expect(mAfterGap['trip_km']!, closeTo(tripBeforeGap, 1e-6));
      expect(mAfterGap['accel_g'], equals(0.0));
    });

    test('TelemetryController merges partial frames and avoids duplicate [unit] headers', () async {
      final tmpDir = await Directory.systemTemp.createTemp('leitorecu_partial_');
      try {
        expect(
          CsvLogger.formatExtraHeader('Bloco 003.1 RPM [rpm]', 'rpm'),
          equals('Bloco 003.1 RPM [rpm]'),
        );
        expect(
          CsvLogger.formatExtraHeader('Carga VAG', '%'),
          equals('Carga VAG [%]'),
        );

        final ctrl = TelemetryController(
          logRepository: LogRepository(directoryOverride: tmpDir),
        );
        final recPath = await ctrl.startRecording();
        expect(recPath, isNotNull);
        ctrl.emitChannels({
          'g003_c1': ('Bloco 003.1 RPM [rpm]', 'rpm'),
        });

        // Primeiro pacote completo com injeção e RPM
        ctrl.emitSample({
          'rpm': 2800.0,
          'map': 58.0,
          'iat': 32.0,
          'inj_ms': 4.2,
          'speed': 72.0,
          'g003_c1': 2800.0,
        });
        final fuel1 = ctrl.latest['fuel_rate_lph'];
        final ve1 = ctrl.latest['volumetric_eff'];
        expect(fuel1, isNotNull);
        expect(fuel1!, greaterThan(0.5));
        expect(ve1, isNotNull);
        expect(ve1!, greaterThan(10.0));

        // Pacote parcial (apenas velocidade): métricas derivadas NÃO zeram
        ctrl.emitSample({'speed': 72.0});
        expect(ctrl.latest['fuel_rate_lph']!, greaterThan(0.5));
        expect(ctrl.latest['volumetric_eff']!, greaterThan(10.0));

        await ctrl.stopRecording();
        final csvContent = await File(recPath!).readAsString();
        expect(csvContent, contains('Bloco 003.1 RPM [rpm]'));
        expect(csvContent.contains('[rpm] [rpm]'), isFalse);

        ctrl.dispose();
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    test('LogRepository & LogExporters generate valid XLSX, HTML, PDF, JSON and MSL', () async {
      final tmpDir = await Directory.systemTemp.createTemp('leitorecu_exports_');
      try {
        final csvFile = File('${tmpDir.path}${Platform.pathSeparator}viagem_teste.csv');
        await csvFile.writeAsString(
          [
            '# leitorECU Demo',
            'timestamp_ms;tempo_s;atualizado;rpm;map;advance;tps;lambda_v;stft;ltft;ect;load;speed;iat;battery;evento',
            '1000;0,00;rpm;850;32,0;10,5;2,5;0,450;-1,5;-3,0;88;24;0;32;14,1;',
            '1200;0,50;speed;2200;54,0;21,0;18,0;0,720;-2,0;-3,0;89;48;42;33;14,2;Troca 2a marcha',
            '1400;1,00;rpm;3100;68,0;24,5;30,0;0,810;1,2;-3,0;90;64;78;33;14,1;',
            '1600;1,50;speed;1800;22,0;16,0;0,0;0,050;0,0;-3,0;90;15;60;34;14,0;Cut-off ativo',
          ].join('\n'),
        );

        final repo = LogRepository(directoryOverride: tmpDir);

        // 1. Excel .xlsx (PKZIP + DEFLATE + OpenXML)
        final xlsxPath = await repo.exportFormattedFile(
          csvFile.path,
          LogExportFormat.xlsx,
        );
        expect(xlsxPath, isNotNull);
        final xlsxBytes = await File(xlsxPath!).readAsBytes();
        expect(xlsxBytes.length, greaterThan(1000));
        // Local File Header signature: PK\x03\x04
        expect(xlsxBytes.sublist(0, 4), equals([0x50, 0x4B, 0x03, 0x04]));
        // Contém assinaturas de ZIP central directory
        expect(
          String.fromCharCodes(xlsxBytes).contains('xl/worksheets/sheet1.xml'),
          isTrue,
        );

        // 2. Relatório Web .html com SVG interativo
        final htmlPath = await repo.exportFormattedFile(
          csvFile.path,
          LogExportFormat.html,
        );
        expect(htmlPath, isNotNull);
        final htmlText = await File(htmlPath!).readAsString();
        expect(htmlText, contains('<html'));
        expect(htmlText, contains('<svg'));
        expect(htmlText, contains('leitorECU'));
        expect(htmlText, contains('Cut-off ativo'));

        // 3. Relatório PDF vetorial
        final pdfPath = await repo.exportFormattedFile(
          csvFile.path,
          LogExportFormat.pdf,
        );
        expect(pdfPath, isNotNull);
        final pdfBytes = await File(pdfPath!).readAsBytes();
        final pdfStr = latin1.decode(pdfBytes);
        expect(pdfStr.startsWith('%PDF-1.4'), isTrue);
        expect(pdfStr, contains('/Type /Pages'));
        expect(pdfStr, contains('xref'));
        expect(pdfStr.trimRight(), endsWith('%%EOF'));

        // 4. JSON estruturado
        final jsonPath = await repo.exportFormattedFile(
          csvFile.path,
          LogExportFormat.json,
        );
        expect(jsonPath, isNotNull);
        final decoded = jsonDecode(await File(jsonPath!).readAsString())
            as Map<String, dynamic>;
        final meta = decoded['metadata'] as Map<String, dynamic>;
        expect(meta['sampleCount'], equals(4));
        final channels = decoded['channels'] as Map<String, dynamic>;
        expect((channels['rpm'] as Map)['max'], equals(3100.0));
        expect((decoded['events'] as List).length, equals(2));

        // 5. MegaLogViewer .msl
        final mslPath = await repo.exportFormattedFile(
          csvFile.path,
          LogExportFormat.msl,
        );
        expect(mslPath, isNotNull);
        expect(await File(mslPath!).readAsString(), contains('Time\t'));
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });
  });

  group('LogAnalyzer, Comparison, LLM Service, AppSettings & Replay Playback', () {
    test('LogAnalyzer computes exact Mean, Median, Mode, StdDev, Percentiles & DiagnosticFindings', () {
      // RPM: [1000, 1000, 1000, 2000, 3000, 4000, 5000] -> mean=2428.57, median=2000, mode=1000
      final ds = ReplayDataset(
        availableChannels: const ['rpm', 'speed', 'ect', 'ltft', 'stft', 'lambda_v', 'battery', 'advance', 'cht_temp'],
        times: const [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 210.0],
        records: const [
          {'rpm': 1000.0, 'speed': 0.0, 'ect': 65.0, 'ltft': -19.0, 'stft': -4.0, 'lambda_v': 0.12, 'battery': 14.1, 'advance': 12.0, 'cht_temp': 70.0},
          {'rpm': 1000.0, 'speed': 0.0, 'ect': 66.0, 'ltft': -19.0, 'stft': -3.0, 'lambda_v': 0.14, 'battery': 14.1, 'advance': 14.0, 'cht_temp': 71.0},
          {'rpm': 1000.0, 'speed': 0.0, 'ect': 67.0, 'ltft': -19.0, 'stft': -5.0, 'lambda_v': 0.13, 'battery': 14.0, 'advance': 15.0, 'cht_temp': 72.0},
          {'rpm': 2000.0, 'speed': 40.0, 'ect': 68.0, 'ltft': -19.0, 'stft': -2.0, 'lambda_v': 0.15, 'battery': 14.2, 'advance': 20.0, 'cht_temp': 73.0},
          {'rpm': 3000.0, 'speed': 60.0, 'ect': 70.0, 'ltft': -19.0, 'stft': -3.0, 'lambda_v': 0.16, 'battery': 14.2, 'advance': -10.0, 'cht_temp': 74.0},
          {'rpm': 4000.0, 'speed': 80.0, 'ect': 71.0, 'ltft': -19.0, 'stft': -2.0, 'lambda_v': 0.15, 'battery': 11.8, 'advance': 26.0, 'cht_temp': 75.0},
          {'rpm': 5000.0, 'speed': 100.0, 'ect': 72.0, 'ltft': -19.0, 'stft': -1.0, 'lambda_v': 0.14, 'battery': 14.1, 'advance': 28.0, 'cht_temp': 76.0},
        ],
        events: const [ReplayEvent(timeSec: 4.0, text: 'Retardo ATDC')],
        isTurboDetected: false,
      );

      final report = LogAnalyzer.analyze(ds, fileName: 'corrida_a.csv');
      expect(report.sampleCount, equals(7));
      expect(report.standbyGapCount, equals(1)); // 5.0 -> 210.0 (> 5.0s)

      final rpmStat = report.byKey['rpm']!;
      expect(rpmStat.mean, closeTo(17000.0 / 7.0, 0.2));
      expect(rpmStat.median, closeTo(2000.0, 0.01));
      expect(rpmStat.mode, closeTo(1000.0, 50.0));
      expect(rpmStat.min, equals(1000.0));
      expect(rpmStat.max, equals(5000.0));
      expect(rpmStat.p5, greaterThanOrEqualTo(1000.0));
      expect(rpmStat.p95, lessThanOrEqualTo(5000.0));
      expect(rpmStat.stdDev, greaterThan(1000.0));

      // Distância deve ignorar a lacuna de 205s de standby (entre 5s e 210s)
      expect(report.distanceKm, lessThan(0.15));

      // Findings determinísticos: LTFT severo, ECT abaixo de 75°C após >180s, ATDC, bateria baixa, standby
      expect(report.findings.any((f) => f.category == 'Mistura' && f.severity == 'alarm'), isTrue);
      expect(report.findings.any((f) => f.category == 'Arrefecimento' && f.severity == 'warn'), isTrue);
      expect(report.findings.any((f) => f.category == 'Ignição' && f.severity == 'alarm'), isTrue);
      expect(report.findings.any((f) => f.category == 'Elétrica' && f.severity == 'alarm'), isTrue);
      expect(report.findings.any((f) => f.category == 'Sessão'), isTrue);

      // Comparação A vs B
      final dsB = ReplayDataset(
        availableChannels: const ['rpm', 'ect', 'ltft'],
        times: const [0.0, 1.0, 2.0],
        records: const [
          {'rpm': 1500.0, 'ect': 88.0, 'ltft': -2.0},
          {'rpm': 2000.0, 'ect': 90.0, 'ltft': -1.0},
          {'rpm': 2500.0, 'ect': 91.0, 'ltft': 0.0},
        ],
        events: const [],
        isTurboDetected: false,
      );
      final reportB = LogAnalyzer.analyze(dsB, fileName: 'corrida_b.csv');
      final cmp = LogAnalyzer.compare(report, reportB);
      expect(cmp.onlyInA, contains('speed'));
      final ectDelta = cmp.deltas.firstWhere((d) => d.key == 'ect');
      expect(ectDelta.deltaMean, greaterThan(18.0));
      expect(ectDelta.isSignificant, isTrue);
      expect(cmp.summaryHighlights, isNotEmpty);
    });

    test('LlmDiagnosticService handles Gemini, OpenAI, HTTPS security and key sanitization', () async {
      final ds = ReplayDataset(
        availableChannels: const ['rpm', 'ect', 'ltft'],
        times: const [0.0, 1.0],
        records: const [
          {'rpm': 900.0, 'ect': 88.0, 'ltft': -3.0},
          {'rpm': 2500.0, 'ect': 90.0, 'ltft': -2.5},
        ],
        events: const [],
        isTurboDetected: false,
      );
      final report = LogAnalyzer.analyze(ds, fileName: 'amostra.csv');

      Uri? capturedUri;
      Map<String, String>? capturedHeaders;
      final geminiSvc = LlmDiagnosticService(
        transport: ({required uri, required headers, required body, required timeout}) async {
          capturedUri = uri;
          capturedHeaders = headers;
          return LlmHttpResponse(
            200,
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': '## Diagnóstico Geral\nMotor operando em faixa saudável.'}
                    ]
                  }
                }
              ]
            }),
          );
        },
      );

      const secret = 'AIzaSyTestSecretKey12345';
      final res = await geminiSvc.analyzeSingleLog(
        report: report,
        provider: AiProviderKind.gemini,
        model: 'gemini-2.5-flash',
        apiKey: secret,
      );
      expect(res.analysisMarkdown, contains('Diagnóstico Geral'));
      expect(capturedUri.toString(), contains('generativelanguage.googleapis.com'));
      expect(capturedUri.toString().contains(secret), isFalse); // chave nunca na URL
      expect(capturedHeaders?['x-goog-api-key'], equals(secret));

      // Rejeita custom endpoint HTTP inseguro (não-localhost)
      await expectLater(
        () => geminiSvc.analyzeSingleLog(
          report: report,
          provider: AiProviderKind.customOpenAi,
          model: 'gpt-4o-mini',
          apiKey: secret,
          customBaseUrl: 'http://example.com/v1',
        ),
        throwsA(isA<LlmDiagnosticException>()),
      );

      // Erro HTTP 401 sanitiza a API key
      final errSvc = LlmDiagnosticService(
        transport: ({required uri, required headers, required body, required timeout}) async {
          return LlmHttpResponse(401, 'Unauthorized key $secret');
        },
      );
      try {
        await errSvc.analyzeSingleLog(
          report: report,
          provider: AiProviderKind.openai,
          model: 'gpt-4o-mini',
          apiKey: secret,
        );
        fail('Expected LlmDiagnosticException');
      } on LlmDiagnosticException catch (e) {
        expect(e.userMessage.contains(secret), isFalse);
        expect(e.userMessage, contains('401'));
      }
    });

    test('AppSettingsController & SecureKeyStorage persist preferences, cards & API keys safely', () async {
      final storage = SecureKeyStorage();
      final settings = AppSettingsController(secureStorage: storage);
      await settings.load();

      expect(settings.dashboardCardKeys.length, equals(cardChannelKeys.length));
      await settings.setFontScale(1.5); // clamped to 1.35
      expect(settings.fontScale, equals(1.35));
      await settings.setHighContrast(true);
      await settings.setAccentPreset(AccentPreset.emerald);
      expect(settings.highContrast, isTrue);

      await settings.replaceCard(0, 'oil_temp');
      expect(settings.dashboardCardKeys.first, equals('oil_temp'));
      await settings.moveCard(0, 2);
      expect(settings.dashboardCardKeys[2], equals('oil_temp'));
      final removed = await settings.removeCardAt(2);
      expect(removed, equals('oil_temp'));
      await settings.insertCardAt(2, removed!);
      expect(settings.dashboardCardKeys[2], equals('oil_temp'));
      await settings.resetDashboardCards();
      expect(settings.dashboardCardKeys.first, equals(cardChannelKeys.first));

      final savedOk = await settings.saveApiKey('sk-test-secret-999');
      expect(savedOk, isTrue);
      expect(settings.hasApiKey, isTrue);
      expect(settings.toString().contains('sk-test-secret-999'), isFalse);
      expect(await settings.readApiKey(), equals('sk-test-secret-999'));
      await settings.clearApiKey();
      expect(settings.hasApiKey, isFalse);
      expect(await settings.readApiKey(), isNull);
    });

    test('MathChannelsEngine wideband lambda_error_pct, cht_temp & TelemetryController Replay Playback + carry-forward', () async {
      expect(describeChannel('cht_temp').label, equals('Temp. Cabeçote (CHT)'));

      final mathEngine = MathChannelsEngine();
      final outWb = mathEngine.compute(0.0, {
        'rpm': 3000.0,
        'map': 120.0,
        'lambda_eq': 0.85,
        'lambda_v': 0.2,
      });
      expect(outWb['lambda_error_pct'], closeTo(-15.0, 0.2));

      final tmpDir = await Directory.systemTemp.createTemp('leitorecu_replay_play_');
      try {
        final csvFile = File('${tmpDir.path}${Platform.pathSeparator}esparso.csv');
        await csvFile.writeAsString(
          'timestamp_ms;tempo_s;atualizado;rpm;map;ect;speed;battery;evento\n'
          '1000;0,0;rpm;900;35;85;0;14,1;\n'
          '2000;1,0;speed;;;86;45;;Acelerando\n'
          '3000;2,0;rpm;3100;72;;80;14,2;\n',
        );

        final ctrl = TelemetryController(
          logRepository: LogRepository(directoryOverride: tmpDir),
        );
        final ok = await ctrl.loadReplayFromPath(csvFile.path);
        expect(ok, isTrue);
        expect(ctrl.replayTotalSamples, equals(3));

        // Carry-forward: linha t=1.0s só atualizou ect e speed, mas rpm e map continuam preenchidos!
        ctrl.scrubReplay(1.0);
        expect(ctrl.replayCurrentIndex, equals(1));
        expect(ctrl.replayValues['speed'], equals(45.0));
        expect(ctrl.replayValues['rpm'], equals(900.0));
        expect(ctrl.replayValues['map'], equals(35.0));
        expect(ctrl.replayActiveEventText, contains('Acelerando'));

        ctrl.stepReplaySamples(1);
        expect(ctrl.replayCurrentIndex, equals(2));
        expect(ctrl.replayValues['rpm'], equals(3100.0));

        ctrl.stepReplaySeconds(-1.0);
        expect(ctrl.replayScrubTime, closeTo(1.0, 0.1));

        ctrl.setReplaySpeed(2.0);
        expect(ctrl.replaySpeed, equals(2.0));
        ctrl.toggleReplayPlay();
        expect(ctrl.replayPlaying, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        ctrl.pauseReplay();
        expect(ctrl.replayPlaying, isFalse);

        ctrl.exitReplayMode();
        expect(ctrl.replayMode, isFalse);
        ctrl.dispose();
      } finally {
        await tmpDir.delete(recursive: true);
      }
    });

    test('EnginePreset calibration, Thermostat/Fan detector, LogAnalyzer recalculateDerived & DynoCurve', () async {
      // 1. EnginePreset persistence & custom fallback
      final settings = AppSettingsController(secureStorage: SecureKeyStorage());
      await settings.load();
      await settings.selectEnginePreset(EnginePreset.fordKa15Sigma);
      expect(settings.engineDisplacementL, equals(1.5));
      expect(settings.injectorCcMin, equals(240.0));
      await settings.setEngineCalibration(injectorCcMin: 310.0);
      expect(settings.enginePreset, equals(EnginePreset.custom));
      expect(settings.injectorCcMin, equals(310.0));

      // Configurable injector flow changes fuel_rate_lph proportionally
      final mDefault = FuelEstimator.estimateFuelMetrics(
        {'rpm': 3000.0, 'inj_ms': 4.0, 'map': 65.0, 'tps': 30.0},
        injectorCcMin: 275.0,
        deadTimeMs: 0.85,
      );
      final mBig = FuelEstimator.estimateFuelMetrics(
        {'rpm': 3000.0, 'inj_ms': 4.0, 'map': 65.0, 'tps': 30.0},
        injectorCcMin: 440.0,
        deadTimeMs: 0.75,
      );
      expect(mBig['fuel_rate_lph']!, greaterThan(mDefault['fuel_rate_lph']!));

      // 2. DecelDetector Thermostat stuck-open, Fan cycle OK & Overheat
      final det = DecelDetector();
      // Accumulate >= 360s running at >= 650 rpm (using <=5s steps so _warmupRunSec advances)
      for (var s = 0.0; s <= 370.0; s += 4.0) {
        det.update(
          s,
          {'rpm': 2200.0, 'speed': 70.0, 'ect': 86.0},
          {'rpm': s, 'speed': s, 'ect': s},
        );
      }
      // Now drop ECT < 75C while cruising >= 40 km/h for >= 20s -> Thermostat warning
      final thermoEvents = <DiagnosticEvent>[];
      for (var s = 374.0; s <= 402.0; s += 4.0) {
        thermoEvents.addAll(det.update(
          s,
          {'rpm': 2200.0, 'speed': 75.0, 'ect': 69.0},
          {'rpm': s, 'speed': s, 'ect': s},
        ));
      }
      expect(
        thermoEvents.any((e) => e.level == 'warn' && e.message.contains('TERMOSTÁTICA POSSIVELMENTE ABERTA')),
        isTrue,
      );

      // Fan cycle OK (98C -> 91C) and Overheat (>= 108C)
      det.reset();
      det.update(10.0, {'rpm': 900.0, 'ect': 98.0}, {'rpm': 10.0, 'ect': 10.0});
      final fanEvs = det.update(45.0, {'rpm': 900.0, 'ect': 91.0}, {'rpm': 45.0, 'ect': 45.0});
      expect(fanEvs.any((e) => e.level == 'info' && e.message.contains('Ciclo do eletroventilador OK')), isTrue);

      final hotEvs = det.update(60.0, {'rpm': 900.0, 'ect': 109.0}, {'rpm': 60.0, 'ect': 60.0});
      expect(hotEvs.any((e) => e.level == 'alarm' && e.message.contains('SUPERAQUECIMENTO CRÍTICO')), isTrue);

      // 3. LogAnalyzer recalculateDerived + DynoCurve + cooling findings
      final dsWot = ReplayDataset(
        availableChannels: const ['rpm', 'map', 'tps', 'iat', 'ect', 'speed', 'inj_ms', 'power_hp', 'torque_kgfm', 'fuel_econ_kml'],
        times: const [0.0, 2.0, 4.0, 6.0],
        records: const [
          {'rpm': 2500.0, 'map': 99.0, 'tps': 85.0, 'iat': 35.0, 'ect': 90.0, 'speed': 60.0, 'inj_ms': 8.0, 'power_hp': 20.0, 'torque_kgfm': 6.0, 'fuel_econ_kml': 99.9},
          {'rpm': 3500.0, 'map': 99.0, 'tps': 90.0, 'iat': 35.0, 'ect': 98.0, 'speed': 85.0, 'inj_ms': 9.0, 'power_hp': 40.0, 'torque_kgfm': 8.0, 'fuel_econ_kml': 11.5},
          {'rpm': 5250.0, 'map': 98.0, 'tps': 95.0, 'iat': 35.0, 'ect': 92.0, 'speed': 130.0, 'inj_ms': 10.5, 'power_hp': 60.0, 'torque_kgfm': 8.2, 'fuel_econ_kml': 10.5},
          {'rpm': 2200.0, 'map': 24.0, 'tps': 0.0, 'iat': 35.0, 'ect': 91.0, 'speed': 80.0, 'inj_ms': 0.0, 'power_hp': 0.0, 'torque_kgfm': 0.0, 'fuel_econ_kml': 99.9},
        ],
        events: const [],
        isTurboDetected: false,
      );
      final rep = LogAnalyzer.analyze(dsWot, fileName: 'wot.csv', recalculateDerived: true, displacementL: 1.6);
      expect(rep.recalculated, isTrue);
      expect(rep.dynoCurve.length, equals(3));
      expect(rep.dynoCurve.last.rpmBin, equals(5250));
      expect(rep.dynoCurve.last.powerHp, greaterThan(90.0));
      expect(rep.byKey['fuel_econ_kml']!.mean, lessThan(20.0));
      expect(
        rep.findings.any((f) => f.category == 'Arrefecimento' && f.title.contains('Ciclo de Eletroventilador')),
        isTrue,
      );

      // 4. Bosch ME7.5.30 TotalFlex: -20.31% em 032.2 (Canal 59 Gasolina) e -23.25° em dashpot (TPS <= 6.5%, MAP <= 58 kPa) NÃO disparam falso alarme
      final dsMe75 = ReplayDataset(
        availableChannels: const ['rpm', 'map', 'tps', 'advance', 'ect', 'speed', 'inj_ms', 'stft', 'ltft', 'ltft_idle', 'lambda_v', 'battery'],
        times: const [0.0, 1.0, 2.0, 3.0],
        records: const [
          {'rpm': 760.0, 'map': 30.5, 'tps': 2.6, 'advance': 2.5, 'ect': 81.0, 'speed': 0.0, 'inj_ms': 2.30, 'stft': 0.5, 'ltft': -20.31, 'ltft_idle': 0.0, 'lambda_v': 0.12, 'battery': 14.1},
          {'rpm': 1900.0, 'map': 26.0, 'tps': 6.0, 'advance': 21.0, 'ect': 81.0, 'speed': 0.0, 'inj_ms': 2.46, 'stft': -1.0, 'ltft': -20.31, 'ltft_idle': 0.0, 'lambda_v': 0.68, 'battery': 14.1},
          {'rpm': 1320.0, 'map': 54.0, 'tps': 3.5, 'advance': -23.25, 'ect': 81.0, 'speed': 0.0, 'inj_ms': 2.46, 'stft': 0.0, 'ltft': -20.31, 'ltft_idle': 0.0, 'lambda_v': 0.06, 'battery': 14.1},
          {'rpm': 760.0, 'map': 30.0, 'tps': 2.4, 'advance': 3.0, 'ect': 81.0, 'speed': 0.0, 'inj_ms': 2.30, 'stft': 0.8, 'ltft': -20.31, 'ltft_idle': 0.0, 'lambda_v': 0.65, 'battery': 14.1},
        ],
        events: const [],
        isTurboDetected: false,
      );
      final repMe75 = LogAnalyzer.analyze(dsMe75, fileName: 'logLenta-20%.csv');
      expect(repMe75.findings.where((f) => f.severity == 'alarm' || f.severity == 'warn'), isEmpty);
      expect(
        repMe75.findings.any((f) => f.category == 'Mistura' && f.detail.contains('Gasolina reconhecida')),
        isTrue,
      );
    });
  });
}
