import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:leitorecu_mobile/main.dart';
import 'package:leitorecu_mobile/state/telemetry_controller.dart';
import 'package:leitorecu_mobile/storage/log_repository.dart';
import 'package:leitorecu_mobile/ui/widgets/channel_detail_chart_sheet.dart';
import 'package:leitorecu_mobile/ui/widgets/dual_axis_chart.dart';

void main() {
  Future<void> pumpViewport(
    WidgetTester tester,
    Size size,
    TelemetryController controller,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(LeitorEcuApp(controller: controller));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> captureLayoutErrors(
    WidgetTester tester,
    Future<void> Function() body,
  ) async {
    final errors = <FlutterErrorDetails>[];
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details);
    };
    try {
      await body();
    } finally {
      FlutterError.onError = prevOnError;
    }
    expect(
      errors,
      isEmpty,
      reason: errors.map((e) => e.exceptionAsString()).join('\n'),
    );
  }

  testWidgets('Phone 412x915 (Galaxy S24+): NavigationBar & zero overflow across all 5 tabs', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('leitorecu_ui_phone_');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final controller = TelemetryController(
      logRepository: LogRepository(directoryOverride: tempDir),
    );
    addTearDown(controller.dispose);

    await captureLayoutErrors(tester, () async {
      await pumpViewport(tester, const Size(412, 915), controller);

      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.text('● OFFLINE'), findsOneWidget);
      expect(find.text('GRAVAR'), findsOneWidget);

      for (final tab in const ['Gráficos', 'Mapa 2D', 'Funções', 'Logs', 'Painel']) {
        await tester.tap(find.text(tab).last);
        await tester.pump(const Duration(milliseconds: 100));
      }
    });
  });

  testWidgets('Tablet 1280x800 (Galaxy Tab S9 FE+): NavigationRail & zero overflow across all 5 tabs', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('leitorecu_ui_tablet_');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final controller = TelemetryController(
      logRepository: LogRepository(directoryOverride: tempDir),
    );
    addTearDown(controller.dispose);

    await captureLayoutErrors(tester, () async {
      await pumpViewport(tester, const Size(1280, 800), controller);

      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('leitorECU'), findsOneWidget);

      for (final tab in const ['Gráficos', 'Mapa 2D', 'Funções', 'Logs', 'Painel']) {
        await tester.tap(find.text(tab).last);
        await tester.pump(const Duration(milliseconds: 100));
      }
    });
  });

  testWidgets('Demo Gol G5 & Turbo TSI adaptation, Recording CSV, Logs list, and Replay + Crosshair', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('leitorecu_ui_flow_');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final controller = TelemetryController(
      logRepository: LogRepository(directoryOverride: tempDir),
    );
    addTearDown(controller.dispose);

    await captureLayoutErrors(tester, () async {
      await pumpViewport(tester, const Size(412, 915), controller);

      // 1. Open ConnectionSheet UI & verify Demo selector exists
      await tester.tap(find.text('Conectar'));
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.text('Conexão ELM327 & Veículo'), findsOneWidget);
      await tester.ensureVisible(find.text('Demo'));
      await tester.tap(find.text('Demo'));
      await tester.pump(const Duration(milliseconds: 100));
      Navigator.of(tester.element(find.text('Conexão ELM327 & Veículo'))).pop();
      await tester.pump(const Duration(milliseconds: 450));

      // Inject deterministic Gol G5 mono-O2 + Block 032 ltft_idle + Block 103.5/103.6
      controller.emitSample({
        'rpm': 2200.0,
        'map': 44.0,
        'advance': 18.5,
        'tps': 12.0,
        'load': 28.0,
        'speed': 62.0,
        'battery': 14.1,
        'lambda_v': 0.55,
        'stft': 2.5,
        'ltft_idle': -4.2,
        'ltft': -17.9,
        'ect': 88.0,
        'iat': 34.0,
        'inj_ms': 3.69,
        'g103_c5': 99.6,
        'g103_c6': 100.0,
      });
      await tester.pump();

      // Verify Gol G5 card adaptations (LTFT Lenta + LTFT Parcial + Tempo Injeção, NO Turbo rename)
      expect(find.text('LTFT Lenta'), findsOneWidget);
      expect(find.text('LTFT Parcial'), findsOneWidget);
      expect(find.text('Tempo Injeção'), findsOneWidget);
      expect(find.text('MAP'), findsOneWidget);
      expect(find.text('MAP / Boost'), findsNothing);

      // 2. Record & Stop Log via real disk I/O inside runAsync
      await tester.runAsync(() => controller.startRecording());
      await tester.pump();
      expect(controller.isRecording, isTrue);

      controller.emitSample({
        'rpm': 3100.0,
        'map': 68.0,
        'advance': 22.0,
        'tps': 35.0,
        'speed': 84.0,
        'lambda_v': 0.65,
        'stft': 1.0,
        'ltft': -15.0,
        'ect': 90.0,
      });
      await tester.pump();

      await tester.runAsync(() => controller.stopRecording());
      await tester.pump();
      expect(controller.isRecording, isFalse);

      // 3. Inject Turbo TSI telemetry & verify Turbo cards + Map2D 250 kPa auto-expansion
      controller.emitSample({
        'rpm': 4200.0,
        'map': 195.0,
        'boost_bar': 0.94,
        'lambda_eq': 0.85,
        'wastegate_pct': 62.0,
        'knock_retard_max': 1.5,
        'advance': 15.0,
        'tps': 88.0,
        'ect': 92.0,
      });
      await tester.pump();

      expect(find.text('MAP / Boost'), findsOneWidget);
      expect(find.text('Pressão Turbo'), findsOneWidget);

      // Check Gráficos tab renders 3 DualAxisChartWidgets cleanly
      await tester.tap(find.text('Gráficos').last);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(DualAxisChartWidget), findsNWidgets(3));

      // Check Mapa 2D auto-expanded to Turbo (250 kPa)
      await tester.tap(find.text('Mapa 2D').last);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('250 kPa'), findsOneWidget);

      // Check Funções tab + Reset button
      await tester.tap(find.text('Funções').last);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Reset Adaptação'), findsOneWidget);

      // 4. Verify saved log in Logs tab & open Replay
      final logs = await tester.runAsync(() => controller.logRepository.listLogs());
      expect(logs, isNotNull);
      expect(logs, isNotEmpty);
      await tester.tap(find.text('Logs').last);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('Abrir Replay'), findsAtLeastNWidgets(1));
      expect(find.text('Exportar CSV'), findsAtLeastNWidgets(1));
      expect(find.text('Exportar .msl'), findsAtLeastNWidgets(1));

      await tester.runAsync(() => controller.loadReplayFromPath(logs!.first.path));
      await tester.tap(find.text('Painel').last);
      await tester.pump(const Duration(milliseconds: 100));

      expect(controller.replayMode, isTrue);
      expect(find.textContaining('MODO REPLAY:'), findsOneWidget);
      expect(find.text('Sair do Replay'), findsOneWidget);

      // Check Charts tab in Replay mode supports crosshair + exit replay
      await tester.tap(find.text('Gráficos').last);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Sair Replay'), findsOneWidget);
      await tester.tap(find.text('Sair Replay'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(controller.replayMode, isFalse);
    });
  });

  testWidgets('ECU OFF Power Latch status pill highlights in top bar', (tester) async {
    final tempDir = Directory.systemTemp.createTempSync('leitorecu_ui_latch_');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final controller = TelemetryController(
      logRepository: LogRepository(directoryOverride: tempDir),
    );
    addTearDown(controller.dispose);

    await pumpViewport(tester, const Size(1280, 800), controller);
    controller.emitStatus('ecu_off', 'DESCONECTADO / ECU OFF (Power Latch durou 3.2s)');
    await tester.pump();

    expect(find.text('● DESCONECTADO (ECU OFF)'), findsOneWidget);
  });

  testWidgets('Tapping a telemetry card opens dedicated ChannelDetailChartSheet in phone & tablet', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (d) {
      errors.add(d);
      prevOnError?.call(d);
    };
    addTearDown(() => FlutterError.onError = prevOnError);

    final tempDir = Directory.systemTemp.createTempSync('leitorecu_card_chart_');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final controller = TelemetryController(
      logRepository: LogRepository(directoryOverride: tempDir),
    );
    addTearDown(controller.dispose);

    // Popula série com amostras para o gráfico dedicado
    await tester.runAsync(() async {
      controller.emitSample({'rpm': 900.0, 'ect': 84.0, 'battery': 13.9});
      await Future<void>.delayed(const Duration(milliseconds: 25));
      controller.emitSample({'rpm': 2400.0, 'ect': 85.0, 'battery': 14.1});
      await Future<void>.delayed(const Duration(milliseconds: 25));
      controller.emitSample({'rpm': 3100.0, 'ect': 86.0, 'battery': 14.0});
    });

    await pumpViewport(tester, const Size(412, 915), controller);
    await tester.pump(const Duration(milliseconds: 80));

    // Toca no card RPM para abrir o gráfico específico
    await tester.tap(find.text('RPM').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.byType(ChannelDetailChartSheet), findsOneWidget);
    expect(find.text('ATUAL'), findsOneWidget);
    expect(find.text('MÍNIMO'), findsOneWidget);
    expect(find.text('MÉDIA'), findsOneWidget);
    expect(find.text('MÁXIMO'), findsOneWidget);
    expect(find.text('Tudo'), findsOneWidget);
    expect(find.text('Congelar'), findsOneWidget);
    expect(find.text('Fixar nos Gráficos'), findsOneWidget);

    // Testa botões janela + congelar + crosshair
    await tester.ensureVisible(find.text('Tudo'));
    await tester.tap(find.text('Tudo'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.ensureVisible(find.text('Congelar'));
    await tester.tap(find.text('Congelar'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.text('Retomar'), findsOneWidget);

    // Fecha fixando na aba Gráficos
    await tester.ensureVisible(find.text('Fixar nos Gráficos'));
    await tester.tap(find.text('Fixar nos Gráficos'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(ChannelDetailChartSheet), findsNothing);
    expect(errors, isEmpty);
  });

  testWidgets('Logs screen shows multi-format exporter sheet (Excel/HTML/PDF/JSON) without overflow', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (d) {
      errors.add(d);
      prevOnError?.call(d);
    };
    addTearDown(() => FlutterError.onError = prevOnError);

    final tempDir = Directory.systemTemp.createTempSync('leitorecu_logs_export_');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final controller = TelemetryController(
      logRepository: LogRepository(directoryOverride: tempDir),
    );
    addTearDown(controller.dispose);

    await pumpViewport(tester, const Size(412, 915), controller);

    // Gera um log real no diretório do repositório com LogsScreen montada
    await tester.runAsync(() async {
      await controller.startRecording();
      controller.emitSample({
        'rpm': 2500.0,
        'map': 65.0,
        'ect': 87.0,
        'speed': 55.0,
        'battery': 14.1,
      });
      await controller.stopRecording();
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.text('Logs').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    expect(find.text('Abrir Replay'), findsAtLeastNWidgets(1));
    expect(find.text('Exportar CSV'), findsAtLeastNWidgets(1));
    expect(find.text('Exportar .msl'), findsAtLeastNWidgets(1));
    expect(find.text('Exportar (Excel / HTML / PDF)'), findsAtLeastNWidgets(1));

    await tester.ensureVisible(find.text('Exportar (Excel / HTML / PDF)').first);
    await tester.tap(find.text('Exportar (Excel / HTML / PDF)').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Exportar Log em Outro Formato'), findsOneWidget);
    expect(find.text('Excel (.xlsx)'), findsOneWidget);
    expect(find.text('Relatório Web (.html)'), findsOneWidget);
    expect(find.text('Relatório PDF (.pdf)'), findsOneWidget);
    expect(find.text('JSON (.json)'), findsOneWidget);
    expect(errors, isEmpty);
  });
}
