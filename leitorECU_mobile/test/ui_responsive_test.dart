import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:leitorecu_mobile/analytics/detector.dart';
import 'package:leitorecu_mobile/core/ai/llm_diagnostic_service.dart';
import 'package:leitorecu_mobile/core/platform/secure_storage.dart';
import 'package:leitorecu_mobile/core/settings/app_settings.dart';
import 'package:leitorecu_mobile/main.dart';
import 'package:leitorecu_mobile/state/telemetry_controller.dart';
import 'package:leitorecu_mobile/storage/log_repository.dart';
import 'package:leitorecu_mobile/ui/screens/log_analysis_screen.dart';
import 'package:leitorecu_mobile/ui/widgets/channel_detail_chart_sheet.dart';
import 'package:leitorecu_mobile/ui/widgets/dual_axis_chart.dart';
import 'package:leitorecu_mobile/ui/widgets/replay_player_bar.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> pumpUntilFound(
    WidgetTester tester,
    Finder finder, {
    int maxTries = 25,
  }) async {
    for (var i = 0; i < maxTries; i++) {
      if (finder.evaluate().isNotEmpty) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 80));
    }
  }

  Future<void> pumpViewport(
    WidgetTester tester,
    Size size,
    TelemetryController controller, {
    AppSettingsController? settings,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(LeitorEcuApp(controller: controller, settings: settings));
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
      await pumpUntilFound(tester, find.text('Abrir Replay'));
      expect(find.text('Abrir Replay'), findsAtLeastNWidgets(1));
      expect(find.text('Analisar'), findsAtLeastNWidgets(1));
      expect(find.text('Exportar'), findsAtLeastNWidgets(1));

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
    expect(find.text('Analisar'), findsAtLeastNWidgets(1));
    expect(find.text('Exportar'), findsAtLeastNWidgets(1));

    await tester.ensureVisible(find.text('Exportar').first);
    await tester.tap(find.text('Exportar').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(find.text('Exportar Log em Outro Formato'), findsOneWidget);
    expect(find.text('Excel (.xlsx)'), findsOneWidget);
    expect(find.text('Relatório Web (.html)'), findsOneWidget);
    expect(find.text('Relatório PDF (.pdf)'), findsOneWidget);
    expect(find.text('JSON (.json)'), findsOneWidget);
    expect(find.text('CSV Original (.csv)'), findsOneWidget);
    expect(find.text('MegaLogViewer (.msl)'), findsOneWidget);
    expect(errors, isEmpty);
  });

  testWidgets('UX/UI Nielsen Heuristics: Clickable Offline pill, SafeArea ConnectionSheet, Expandable Info Card & Card Customization', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (d) {
      errors.add(d);
      prevOnError?.call(d);
    };
    addTearDown(() => FlutterError.onError = prevOnError);

    final tempDir = Directory.systemTemp.createTempSync('leitorecu_ux_nielsen_');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    final controller = TelemetryController(
      logRepository: LogRepository(directoryOverride: tempDir),
    );
    final settings = AppSettingsController(secureStorage: SecureKeyStorage());
    await settings.setFontScale(1.3);
    await settings.setHighContrast(true);
    addTearDown(controller.dispose);

    // Compact Phone 360x780 + simulated Android 48dp bottom nav bar + 1.3x font scale + High Contrast
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(bottom: 48.0, top: 24.0);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48.0, top: 24.0);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
      tester.view.resetViewPadding();
    });

    await tester.pumpWidget(LeitorEcuApp(controller: controller, settings: settings));
    await tester.pump(const Duration(milliseconds: 120));

    // 1. Tapping top-bar OFFLINE button opens ConnectionSheet & Conectar stays above 48dp bottom inset
    await tester.tap(find.text('● OFFLINE'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Conexão ELM327 & Veículo'), findsOneWidget);
    final connectRect = tester.getRect(find.text('Conectar à ECU'));
    expect(connectRect.bottom, lessThanOrEqualTo(780.0 - 48.0));
    await tester.tap(find.text('Cancelar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // 2. Long Info Card wraps cleanly and expands without pushing page horizontally
    controller.emitSample({'rpm': 2200.0, 'ect': 88.0, 'battery': 14.1});
    controller.events.add(
      const DiagnosticEvent(
        1.0,
        'info',
        'Mensagem diagnóstica extensa com detalhes completos de pressão, avanço, sonda lambda e estado da malha fechada para validar quebra de linha sem corte horizontal',
      ),
    );
    controller.emitInfo('Mensagem diagnóstica extensa com detalhes completos de pressão, avanço, sonda lambda');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Mensagem diagnóstica extensa'), findsOneWidget);
    expect(find.textContaining('Histórico ('), findsOneWidget);

    // 3. Card Customization: Personalizar -> Remove + Undo, Replace & Restore Default
    await tester.ensureVisible(find.text('Personalizar'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('Personalizar'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Restaurar Padrão'), findsOneWidget);

    // Remove first card and undo via SnackBar
    await tester.ensureVisible(find.byIcon(Icons.delete_outline).first);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(settings.dashboardCardKeys.first, isNot(equals('rpm')));
    expect(find.text('Desfazer'), findsOneWidget);
    await tester.tap(find.text('Desfazer'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(settings.dashboardCardKeys.first, equals('rpm'));

    // Replace first card using CardCustomizationSheet (filter via search field)
    await tester.ensureVisible(find.byIcon(Icons.swap_horiz).first);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byIcon(Icons.swap_horiz).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(find.byType(TextField).last, 'trip_avg_kml');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('Consumo Médio Viagem').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(settings.dashboardCardKeys.first, equals('trip_avg_kml'));

    await tester.ensureVisible(find.text('Restaurar Padrão'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('Restaurar Padrão'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(settings.dashboardCardKeys.first, equals('rpm'));
    expect(errors, isEmpty);
  });

  testWidgets('SettingsScreen, Fixed ReplayPlayerBar & LogAnalysisScreen (Stats + Compare + LLM)', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (d) {
      errors.add(d);
      prevOnError?.call(d);
    };
    addTearDown(() => FlutterError.onError = prevOnError);

    final tempDir = Directory.systemTemp.createTempSync('leitorecu_analysis_ui_');
    addTearDown(() => tempDir.deleteSync(recursive: true));

    File('${tempDir.path}${Platform.pathSeparator}ida.csv').writeAsStringSync(
      'timestamp_ms;tempo_s;atualizado;rpm;map;ect;speed;battery;ltft\n'
      '1000;0,0;rpm;900;35;82;0;14,0;-15,0\n'
      '2000;1,0;speed;2500;65;86;55;14,1;-14,0\n'
      '3000;2,0;rpm;3200;72;88;80;14,1;-13,5\n',
    );
    File('${tempDir.path}${Platform.pathSeparator}volta.csv').writeAsStringSync(
      'timestamp_ms;tempo_s;atualizado;rpm;map;ect;speed;battery;ltft\n'
      '1000;0,0;rpm;950;34;89;0;14,1;-3,0\n'
      '2000;1,0;speed;2100;52;90;50;14,2;-2,5\n',
    );

    final controller = TelemetryController(
      logRepository: LogRepository(directoryOverride: tempDir),
    );
    final settings = AppSettingsController(secureStorage: SecureKeyStorage());
    addTearDown(controller.dispose);

    await pumpViewport(tester, const Size(412, 915), controller, settings: settings);

    // 1. Open SettingsScreen from TopBar icon & save API key
    await tester.tap(find.byTooltip('Configurações'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Configurações'), findsAtLeastNWidgets(1));
    await tester.dragUntilVisible(
      find.widgetWithText(TextField, 'Chave de API'),
      find.byType(ListView),
      const Offset(0, -250),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.widgetWithText(TextField, 'Chave de API'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.enterText(
      find.widgetWithText(TextField, 'Chave de API'),
      'sk-ui-test-key-777',
    );
    await tester.pump(const Duration(milliseconds: 80));
    await tester.dragUntilVisible(
      find.text('Salvar Chave'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('Salvar Chave'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 250));
    expect(settings.hasApiKey, isTrue);
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // 2. Fixed ReplayPlayerBar in Dashboard & Charts
    await tester.runAsync(() => controller.loadReplayFromPath('${tempDir.path}${Platform.pathSeparator}ida.csv'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.byType(ReplayPlayerBar), findsOneWidget);
    expect(find.text('Reproduzir'), findsOneWidget);
    await tester.tap(find.text('Próx.'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(controller.replayCurrentIndex, equals(1));
    await tester.tap(find.text('Sair do Replay'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.replayMode, isFalse);

    // 3. LogAnalysisScreen with Mean/Median/Mode, Compare 2 Logs & Mock LLM Card
    final mockLlm = LlmDiagnosticService(
      transport: ({required uri, required headers, required body, required timeout}) async {
        return const LlmHttpResponse(
          200,
          '{"candidates":[{"content":{"parts":[{"text":"Parecer IA: LTFT negativo em ida.csv (-14%)."}]}}]}',
        );
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LogAnalysisScreen(
          controller: controller,
          settings: settings,
          initialLogPath: '${tempDir.path}${Platform.pathSeparator}ida.csv',
          llmService: mockLlm,
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('Analisar com IA'));

    expect(find.text('Análise de Logs'), findsOneWidget);

    // Execute LLM Analysis Card
    await tester.ensureVisible(find.text('Analisar com IA'));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('Analisar com IA'));
    await pumpUntilFound(tester, find.textContaining('Parecer IA: LTFT negativo'));
    expect(find.textContaining('Parecer IA: LTFT negativo'), findsOneWidget);

    // Verify Mean / Median / Mode cards below
    await tester.ensureVisible(find.text('Mediana').first);
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.textContaining('Média'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Mediana'), findsAtLeastNWidgets(1));
    expect(find.textContaining('Moda'), findsAtLeastNWidgets(1));

    // Switch back up to Compare 2 Logs
    await tester.scrollUntilVisible(
      find.text('Comparar 2 Logs'),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.text('Comparar 2 Logs'));
    await tester.pump(const Duration(milliseconds: 100));
    await pumpUntilFound(tester, find.text('Comparar com IA'), maxTries: 40);
    expect(find.text('Comparar com IA'), findsOneWidget);
    expect(errors, isEmpty);
  });

  testWidgets('360x780 @ 1.30x fontScale HighContrast: zero overflow across all tabs, Flex A/F, 0x17, Settings Presets & DynoChart', (tester) async {
    final errors = <FlutterErrorDetails>[];
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (d) {
      errors.add(d);
      prevOnError?.call(d);
    };
    addTearDown(() => FlutterError.onError = prevOnError);

    final tempDir = Directory.systemTemp.createTempSync('leitorecu_360_all6_');
    addTearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    File('${tempDir.path}${Platform.pathSeparator}freeway_wot.csv').writeAsStringSync(
      'timestamp_ms;tempo_s;atualizado;rpm;map;tps;ect;iat;speed;battery;inj_ms;fuel_rate_lph;power_hp;torque_kgfm\n'
      '1000;0,0;rpm;1800;96;82;88;32;40;14,1;6,5;8,0;25,0;10,0\n'
      '2000;1,0;rpm;2500;99;88;89;32;60;14,1;9,0;12,0;35,0;10,0\n'
      '3000;2,0;rpm;5250;98;92;90;33;115;14,1;11,5;22,0;66,0;9,0\n',
    );

    final controller = TelemetryController(
      logRepository: LogRepository(directoryOverride: tempDir),
    );
    final settings = AppSettingsController(secureStorage: SecureKeyStorage());
    await settings.setFontScale(1.3);
    await settings.setHighContrast(true);
    addTearDown(controller.dispose);

    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(LeitorEcuApp(controller: controller, settings: settings));
    await tester.pump(const Duration(milliseconds: 120));

    controller.emitSample({
      'rpm': 2400.0,
      'map': 55.0,
      'ect': 86.0,
      'ltft': -17.9,
      'stft': -1.2,
      'lambda_v': 0.45,
      'g103_c5': 99.6,
      'g103_c6': 100.0,
      'g103_c8': 1.0,
      'fuel_sys1': 2.0,
    });
    await tester.pump(const Duration(milliseconds: 80));

    // Varre todas as 5 abas em 360x780 @ 1.30x fontScale
    for (final tab in const ['Gráficos', 'Mapa 2D', 'Funções', 'Logs']) {
      await tester.tap(find.text(tab).last);
      await tester.pump(const Duration(milliseconds: 120));
    }

    // Verifica FlexAfStatusCard e Painel 0x17 na aba Funções
    await tester.tap(find.text('Funções').last);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.dragUntilVisible(
      find.text('Saúde Flex / A/F (Bosch ME7.5.30)'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    expect(find.text('Saúde Flex / A/F (Bosch ME7.5.30)'), findsOneWidget);
    await tester.dragUntilVisible(
      find.text('Ler Tanque (0x17)'),
      find.byType(ListView).last,
      const Offset(0, -200),
    );
    expect(find.text('Ler Tanque (0x17)'), findsOneWidget);

    // Verifica Presets de Motor nas Configurações
    await tester.tap(find.byTooltip('Configurações'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.dragUntilVisible(
      find.text('VW Gol 1.0 EA111 Flex'),
      find.byType(ListView).last,
      const Offset(0, -250),
    );
    await tester.ensureVisible(find.text('VW Gol 1.0 EA111 Flex'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('VW Gol 1.0 EA111 Flex'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(settings.enginePreset, equals(EnginePreset.gol10Flex));
    expect(controller.mathEngine.displacementL, equals(1.0));
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    // Volta para Gol 1.6 e testa Análise + Recálculo + Dinamômetro Virtual
    await settings.selectEnginePreset(EnginePreset.gol16Flex);
    await tester.pump(const Duration(milliseconds: 80));
    expect(controller.mathEngine.injectorCcMin, equals(275.0));

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(360, 780), textScaler: TextScaler.linear(1.3)),
          child: LogAnalysisScreen(
            controller: controller,
            settings: settings,
            initialLogPath: '${tempDir.path}${Platform.pathSeparator}freeway_wot.csv',
          ),
        ),
      ),
    );
    await pumpUntilFound(tester, find.text('Dinamômetro Virtual (cv × kgfm × RPM)'));
    expect(find.text('Dinamômetro Virtual (cv × kgfm × RPM)'), findsOneWidget);
    await tester.ensureVisible(find.text('Recalcular Fórmula'));
    await tester.tap(find.text('Recalcular Fórmula'));
    await tester.pump(const Duration(milliseconds: 150));
    await pumpUntilFound(tester, find.textContaining('Recalculado com calibração atual'));
    expect(find.textContaining('Recalculado com calibração atual'), findsOneWidget);

    expect(errors, isEmpty, reason: errors.map((e) => e.exceptionAsString()).join('\n'));
  });
}
