import 'dart:io';

import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';

import '../../analytics/log_analyzer.dart';
import '../../core/ai/llm_diagnostic_service.dart';
import '../../core/models/channel_def.dart';
import '../../core/settings/app_settings.dart';
import '../../state/telemetry_controller.dart';
import '../../storage/csv_replay_parser.dart';
import '../../storage/log_repository.dart';
import '../theme/motorsport_theme.dart';
import '../widgets/dyno_curve_chart.dart';
import '../widgets/uniform_action_button.dart';
import 'settings_screen.dart';

/// Tela de análise estatística de logs CSV, comparação entre 2 logs e parecer por IA.
class LogAnalysisScreen extends StatefulWidget {
  const LogAnalysisScreen({
    super.key,
    required this.controller,
    required this.settings,
    this.initialLogPath,
    this.startInCompareMode = false,
    this.llmService,
  });

  final TelemetryController controller;
  final AppSettingsController settings;
  final String? initialLogPath;
  final bool startInCompareMode;
  final LlmDiagnosticService? llmService;

  @override
  State<LogAnalysisScreen> createState() => _LogAnalysisScreenState();
}

class _LogAnalysisScreenState extends State<LogAnalysisScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  late final LlmDiagnosticService _llmService;

  bool _compareMode = false;
  bool _onlySignificant = false;
  bool _recalculateDerived = false;
  bool _loadingLogs = true;
  bool _analyzingFiles = false;
  String? _fileLoadError;

  List<LogFileEntry> _logs = const [];
  String? _selectedPathA;
  String? _selectedPathB;

  LogAnalysisReport? _reportA;
  LogComparisonReport? _comparison;

  bool _aiLoading = false;
  LlmDiagnosticResult? _aiResult;
  String? _aiError;

  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _compareMode = widget.startInCompareMode;
    _llmService = widget.llmService ?? const LlmDiagnosticService();
    widget.settings.addListener(_onSettingsChanged);
    _searchCtrl.addListener(() {
      if (!mounted) return;
      setState(() => _searchQuery = _searchCtrl.text.trim().toLowerCase());
    });
    _loadInitialData();
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _loadInitialData() async {
    setState(() {
      _loadingLogs = true;
      _fileLoadError = null;
    });

    try {
      final list = await widget.controller.logRepository.listLogs();
      if (!mounted) return;

      final items = List<LogFileEntry>.from(list);
      final initPath = widget.initialLogPath;
      if (initPath != null &&
          initPath.isNotEmpty &&
          !items.any((e) => e.path == initPath)) {
        final f = File(initPath);
        if (await f.exists()) {
          final stat = await f.stat();
          items.insert(
            0,
            LogFileEntry(
              name: _fileNameOf(initPath),
              path: initPath,
              modified: stat.modified,
              sizeBytes: stat.size,
              rowCount: 0,
            ),
          );
        }
      }

      String? pathA = initPath != null && items.any((e) => e.path == initPath)
          ? initPath
          : (items.isNotEmpty ? items.first.path : null);
      String? pathB;
      if (items.length >= 2) {
        pathB = items.firstWhere(
          (e) => e.path != pathA,
          orElse: () => items[1],
        ).path;
      } else if (items.isNotEmpty) {
        pathB = items.first.path;
      }

      setState(() {
        _logs = items;
        _selectedPathA = pathA;
        _selectedPathB = pathB;
        _loadingLogs = false;
      });

      await _reanalyzeSelected();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingLogs = false;
        _fileLoadError = 'Falha ao listar logs: $e';
      });
    }
  }

  Future<void> _reanalyzeSelected() async {
    final pathA = _selectedPathA;
    final pathB = _selectedPathB;
    if (pathA == null) {
      setState(() {
        _reportA = null;
        _comparison = null;
      });
      return;
    }

    setState(() {
      _analyzingFiles = true;
      _fileLoadError = null;
      _aiResult = null;
      _aiError = null;
    });

    try {
      final dsA = await CsvReplayParser.parseFile(pathA);
      final repA = LogAnalyzer.analyze(
        dsA,
        fileName: _labelForPath(pathA),
        recalculateDerived: _recalculateDerived,
        displacementL: widget.settings.engineDisplacementL,
        injectorCcMin: widget.settings.injectorCcMin,
        injectorDeadTimeMs: widget.settings.injectorDeadTimeMs,
      );

      LogAnalysisReport? repB;
      LogComparisonReport? comp;
      if (_compareMode && pathB != null) {
        final dsB = await CsvReplayParser.parseFile(pathB);
        repB = LogAnalyzer.analyze(
          dsB,
          fileName: _labelForPath(pathB),
          recalculateDerived: _recalculateDerived,
          displacementL: widget.settings.engineDisplacementL,
          injectorCcMin: widget.settings.injectorCcMin,
          injectorDeadTimeMs: widget.settings.injectorDeadTimeMs,
        );
        comp = LogAnalyzer.compare(repA, repB);
      }

      if (!mounted) return;
      setState(() {
        _reportA = repA;
        _comparison = comp;
        _analyzingFiles = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _analyzingFiles = false;
        _fileLoadError = 'Erro ao processar CSV: $e';
      });
    }
  }

  Future<void> _importCsv() async {
    final imported = await widget.controller.logRepository.importCsvFile();
    if (!mounted || imported == null) return;

    final refreshed = await widget.controller.logRepository.listLogs();
    if (!mounted) return;

    setState(() {
      _logs = refreshed;
      if (_compareMode && _selectedPathA != null) {
        _selectedPathB = imported.path;
      } else {
        _selectedPathA = imported.path;
      }
    });
    await _reanalyzeSelected();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Log importado: ${imported.name}')),
    );
  }

  Future<void> _onModeChanged(bool compare) async {
    if (_compareMode == compare) return;
    setState(() {
      _compareMode = compare;
      _aiResult = null;
      _aiError = null;
    });
    await _reanalyzeSelected();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(settings: widget.settings),
      ),
    );
    if (!mounted) return;
    if (_recalculateDerived) {
      await _reanalyzeSelected();
    } else {
      setState(() {});
    }
  }

  Future<void> _runAiAnalysis() async {
    if (_aiLoading) return;
    final settings = widget.settings;
    final key = (await settings.readApiKey())?.trim() ?? '';
    if (key.isEmpty) {
      if (!mounted) return;
      setState(() {
        _aiError =
            'Chave de API não encontrada. Configure uma chave válida nas Configurações.';
      });
      return;
    }

    final model = settings.aiModel.trim().isNotEmpty
        ? settings.aiModel.trim()
        : settings.aiProvider.defaultModel;

    setState(() {
      _aiLoading = true;
      _aiError = null;
    });

    try {
      final LlmDiagnosticResult result;
      if (_compareMode) {
        final comp = _comparison;
        if (comp == null) {
          throw const LlmDiagnosticException(
            'Selecione os dois logs (A e B) antes de comparar com a IA.',
          );
        }
        result = await _llmService.analyzeComparison(
          comparison: comp,
          provider: settings.aiProvider,
          model: model,
          apiKey: key,
          customBaseUrl: settings.aiCustomBaseUrl,
        );
      } else {
        final rep = _reportA;
        if (rep == null) {
          throw const LlmDiagnosticException(
            'Selecione um log válido antes de solicitar a análise por IA.',
          );
        }
        result = await _llmService.analyzeSingleLog(
          report: rep,
          provider: settings.aiProvider,
          model: model,
          apiKey: key,
          customBaseUrl: settings.aiCustomBaseUrl,
        );
      }

      if (!mounted) return;
      setState(() {
        _aiResult = result;
        _aiLoading = false;
      });
    } on LlmDiagnosticException catch (e) {
      if (!mounted) return;
      setState(() {
        _aiError = e.userMessage;
        _aiLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _aiError = 'Falha ao consultar a IA: $e';
        _aiLoading = false;
      });
    }
  }

  Future<void> _copyAiResult() async {
    final text = _aiResult?.analysisMarkdown;
    if (text == null || text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Parecer copiado para a área de transferência.'),
      ),
    );
  }

  String _fileNameOf(String path) =>
      path.split('/').last.split('\\').last;

  String _labelForPath(String path) {
    for (final item in _logs) {
      if (item.path == path) return item.name;
    }
    return _fileNameOf(path);
  }

  @override
  Widget build(BuildContext context) {
    final isTablet =
        MediaQuery.sizeOf(context).width >= MotorsportTheme.tabletBreakpoint;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Análise de Logs'),
        actions: [
          IconButton(
            tooltip: 'Configurações de IA',
            onPressed: _openSettings,
            icon: const Icon(Icons.tune),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _loadingLogs
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: EdgeInsets.all(isTablet ? 14 : 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildModeBar(),
                    const SizedBox(height: 10),
                    _buildFileSelectors(),
                    if (_fileLoadError != null) ...[
                      const SizedBox(height: 10),
                      _buildErrorBanner(_fileLoadError!),
                    ],
                    if (_analyzingFiles) ...[
                      const SizedBox(height: 12),
                      const LinearProgressIndicator(),
                    ],
                    if (_logs.isEmpty && _reportA == null) ...[
                      const SizedBox(height: 12),
                      _buildEmptyState(),
                    ] else if (!_compareMode && _reportA != null) ...[
                      const SizedBox(height: 12),
                      _buildSingleKpiSection(_reportA!),
                      const SizedBox(height: 12),
                      DynoCurveChart(
                        curveA: _reportA!.dynoCurve,
                        labelA: _reportA!.fileName,
                      ),
                      const SizedBox(height: 12),
                      _buildAiCard(),
                      const SizedBox(height: 12),
                      _buildFindingsSection(_reportA!.findings),
                      const SizedBox(height: 12),
                      _buildSingleStatsSection(_reportA!),
                    ] else if (_compareMode && _comparison != null) ...[
                      const SizedBox(height: 12),
                      _buildComparisonKpiSection(_comparison!),
                      const SizedBox(height: 12),
                      DynoCurveChart(
                        curveA: _comparison!.reportA.dynoCurve,
                        curveB: _comparison!.reportB.dynoCurve,
                        labelA: _comparison!.reportA.fileName,
                        labelB: _comparison!.reportB.fileName,
                      ),
                      const SizedBox(height: 12),
                      _buildAiCard(),
                      const SizedBox(height: 12),
                      _buildComparisonHighlights(_comparison!),
                      const SizedBox(height: 12),
                      _buildComparisonDeltasSection(_comparison!),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildModeBar() {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment<bool>(
            value: false,
            icon: Icon(Icons.analytics_outlined, size: 16),
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('Análise Individual', maxLines: 1),
            ),
          ),
          ButtonSegment<bool>(
            value: true,
            icon: Icon(Icons.compare_arrows, size: 16),
            label: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text('Comparar 2 Logs', maxLines: 1),
            ),
          ),
        ],
        selected: {_compareMode},
        onSelectionChanged: (sel) {
          if (sel.isNotEmpty) {
            _onModeChanged(sel.first);
          }
        },
      ),
    );
  }

  Widget _buildFileSelectors() {
    final tokens = MotorsportTheme.tokensOf(context);
    final ccStr = widget.settings.injectorCcMin.toStringAsFixed(0);
    final dispStr = widget.settings.engineDisplacementL.toStringAsFixed(1);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(
          color: tokens.borderSubtle,
          width: tokens.cardBorderWidth,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildLogDropdown(
            label: _compareMode ? 'Log A (Referência)' : 'Arquivo de Log',
            value: _selectedPathA,
            onChanged: (val) {
              if (val == null) return;
              setState(() => _selectedPathA = val);
              _reanalyzeSelected();
            },
          ),
          if (_compareMode) ...[
            const SizedBox(height: 10),
            _buildLogDropdown(
              label: 'Log B (Comparação)',
              value: _selectedPathB,
              onChanged: (val) {
                if (val == null) return;
                setState(() => _selectedPathB = val);
                _reanalyzeSelected();
              },
            ),
          ],
          const SizedBox(height: 10),
          UniformButtonGrid(
            columns: 2,
            tabletColumns: 3,
            children: [
              UniformActionButton(
                label: 'Importar CSV',
                icon: Icons.file_open_outlined,
                variant: UniformActionVariant.info,
                onTap: _importCsv,
              ),
              UniformActionButton(
                label: 'Atualizar Lista',
                icon: Icons.refresh,
                variant: UniformActionVariant.neutral,
                onTap: _loadInitialData,
              ),
              UniformActionButton(
                label: 'Recalcular Fórmula',
                icon: Icons.calculate_outlined,
                variant: UniformActionVariant.info,
                active: _recalculateDerived,
                tooltip:
                    'Reprocessa potência (Speed-Density), torque e consumo ($ccStr cc/min)',
                onTap: () {
                  setState(() => _recalculateDerived = !_recalculateDerived);
                  _reanalyzeSelected();
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Reprocessa potência (Speed-Density), torque e consumo ($ccStr cc/min)',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: tokens.muted, fontSize: 11),
          ),
          if (_recalculateDerived) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: tokens.accent.withValues(alpha: 0.14),
                border: Border.all(
                  color: tokens.accent.withValues(alpha: 0.65),
                  width: tokens.cardBorderWidth,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 15,
                    color: tokens.accent,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      'Recalculado com calibração atual (${dispStr}L · $ccStr cc/min)',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tokens.accent,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLogDropdown({
    required String label,
    required String? value,
    required ValueChanged<String?> onChanged,
  }) {
    final tokens = MotorsportTheme.tokensOf(context);
    final hasValue = value != null && _logs.any((e) => e.path == value);
    final effectiveValue = hasValue ? value : null;

    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: tokens.muted, fontSize: 12),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: effectiveValue,
          isExpanded: true,
          dropdownColor: tokens.elevated,
          hint: Text(
            'Selecione um log CSV',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: tokens.muted, fontSize: 13),
          ),
          items: [
            for (final entry in _logs)
              DropdownMenuItem<String>(
                value: entry.path,
                child: Text(
                  entry.durationSec != null
                      ? '${entry.name} (${_fmtDuration(entry.durationSec!)})'
                      : entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
          onChanged: _logs.isEmpty ? null : onChanged,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final tokens = MotorsportTheme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(
          color: tokens.borderSubtle,
          width: tokens.cardBorderWidth,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.analytics_outlined, color: tokens.muted, size: 38),
          const SizedBox(height: 10),
          Text(
            'Nenhum log disponível para análise',
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tokens.text,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Grave um log na aba Logs ou toque em "Importar CSV" acima para calcular estatísticas e obter parecer da IA.',
            textAlign: TextAlign.center,
            style: TextStyle(color: tokens.muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: UniformActionButton(
              label: 'Importar CSV',
              icon: Icons.file_open_outlined,
              variant: UniformActionVariant.info,
              onTap: _importCsv,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSingleKpiSection(LogAnalysisReport report) {
    final kpis = [
      _KpiData(
        title: 'Duração',
        value: _fmtDuration(report.durationSec),
        subtitle: report.standbyGapCount > 0
            ? '${report.standbyGapCount} pausa(s) >5s'
            : 'Sessão contínua',
        accent: MotorsportColors.info,
      ),
      _KpiData(
        title: 'Distância',
        value: '${report.distanceKm.toStringAsFixed(2)} km',
        subtitle: report.fuelConsumedLiters > 0.001
            ? 'Gasto est.: ${report.fuelConsumedLiters.toStringAsFixed(2)} L'
            : 'Integração trapezoidal',
        accent: MotorsportColors.ok,
      ),
      if (report.fuelConsumedLiters > 0.001)
        _KpiData(
          title: 'Combustível Gasto',
          value: '${report.fuelConsumedLiters.toStringAsFixed(2)} L',
          subtitle: report.distanceKm > 0.05
              ? 'Média ${(report.distanceKm / report.fuelConsumedLiters).toStringAsFixed(1)} km/l'
              : 'Consumo acumulado',
          accent: MotorsportColors.warning,
        ),
      _KpiData(
        title: 'Amostras',
        value: '${report.sampleCount}',
        subtitle: '${report.channelStats.length} canais',
        accent: MotorsportColors.text,
      ),
      _KpiData(
        title: 'Taxa Média',
        value: '${report.avgSampleRateHz.toStringAsFixed(1)} Hz',
        subtitle: report.isTurboDetected ? 'Perfil Turbo/GDI' : 'Perfil Aspirado',
        accent: MotorsportColors.info,
      ),
      _KpiData(
        title: 'Mov / Lenta / Cut-Off',
        value:
            '${report.movingPct.toStringAsFixed(0)}% / ${report.idlePct.toStringAsFixed(0)}% / ${report.cutoffPct.toStringAsFixed(0)}%',
        subtitle: 'Distribuição de regime',
        accent: MotorsportColors.warning,
      ),
      _KpiData(
        title: 'Eventos',
        value: '${report.events.length}',
        subtitle: '${report.findings.length} achado(s) offline',
        accent: report.findings.any((f) => f.severity == 'alarm')
            ? MotorsportColors.alarm
            : MotorsportColors.ok,
      ),
    ];

    return _buildKpiWrap(kpis);
  }

  Widget _buildComparisonKpiSection(LogComparisonReport comp) {
    final a = comp.reportA;
    final b = comp.reportB;
    final kpis = [
      _KpiData(
        title: 'Duração A → B',
        value: '${_fmtDuration(a.durationSec)} → ${_fmtDuration(b.durationSec)}',
        subtitle: '${a.sampleCount} → ${b.sampleCount} amostras',
        accent: MotorsportColors.info,
      ),
      _KpiData(
        title: 'Distância A → B',
        value:
            '${a.distanceKm.toStringAsFixed(2)} → ${b.distanceKm.toStringAsFixed(2)} km',
        subtitle: 'Δ ${_signed(b.distanceKm - a.distanceKm, 2)} km',
        accent: MotorsportColors.ok,
      ),
      _KpiData(
        title: 'Movimento A → B',
        value:
            '${a.movingPct.toStringAsFixed(0)}% → ${b.movingPct.toStringAsFixed(0)}%',
        subtitle:
            'Lenta ${a.idlePct.toStringAsFixed(0)}% → ${b.idlePct.toStringAsFixed(0)}%',
        accent: MotorsportColors.warning,
      ),
      _KpiData(
        title: 'Canais Comuns',
        value: '${comp.deltas.length}',
        subtitle:
            '${comp.deltas.where((d) => d.isSignificant).length} variação(ões) signif.',
        accent: MotorsportColors.info,
      ),
    ];

    return _buildKpiWrap(kpis);
  }

  Widget _buildKpiWrap(List<_KpiData> items) {
    final tokens = MotorsportTheme.tokensOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final w = constraints.maxWidth;
        final cols = w >= 900 ? 3 : 2;
        final cardW = (w - gap * (cols - 1)) / cols;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final item in items)
              SizedBox(
                width: cardW,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: tokens.surface,
                    border: Border.all(
                      color: tokens.borderSubtle,
                      width: tokens.cardBorderWidth,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tokens.muted,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          item.value,
                          maxLines: 1,
                          style: MotorsportTheme.tabularStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: item.accent,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tokens.stale,
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildAiCard() {
    final tokens = MotorsportTheme.tokensOf(context);
    final settings = widget.settings;
    final provider = settings.aiProvider;
    final model = settings.aiModel.trim().isNotEmpty
        ? settings.aiModel.trim()
        : provider.defaultModel;
    final hasKey = settings.hasApiKey;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(
          color: hasKey
              ? tokens.accent.withValues(alpha: 0.45)
              : tokens.border,
          width: tokens.cardBorderWidth,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, color: tokens.accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Diagnóstico por Inteligência Artificial',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Configurar Provedor / Chave',
                onPressed: _openSettings,
                icon: Icon(
                  Icons.settings_outlined,
                  size: 18,
                  color: tokens.muted,
                ),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _buildChipTag(provider.label, tokens.accent),
              _buildChipTag(model, tokens.muted),
            ],
          ),
          const SizedBox(height: 10),
          if (!hasKey) ...[
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: MotorsportColors.warnBg,
                border: Border.all(color: MotorsportColors.warnBorder),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Nenhuma chave de API configurada. Cadastre sua chave do Gemini, OpenAI ou endpoint compatível para gerar diagnósticos assistidos por IA.',
                style: TextStyle(color: tokens.text, fontSize: 12),
              ),
            ),
            const SizedBox(height: 10),
            UniformButtonGrid(
              columns: 1,
              tabletColumns: 2,
              children: [
                UniformActionButton(
                  label: 'Configurar Chave de API',
                  icon: Icons.vpn_key_outlined,
                  variant: UniformActionVariant.info,
                  onTap: _openSettings,
                ),
              ],
            ),
          ] else ...[
            UniformButtonGrid(
              columns: _aiResult != null ? 2 : 1,
              tabletColumns: 2,
              children: [
                UniformActionButton(
                  label: _aiLoading
                      ? 'Analisando...'
                      : (_compareMode ? 'Comparar com IA' : 'Analisar com IA'),
                  icon: Icons.psychology_outlined,
                  variant: UniformActionVariant.info,
                  active: _aiLoading,
                  onTap: (_aiLoading || _analyzingFiles) ? null : _runAiAnalysis,
                ),
                if (_aiResult != null)
                  UniformActionButton(
                    label: 'Copiar Parecer',
                    icon: Icons.copy,
                    variant: UniformActionVariant.neutral,
                    onTap: _copyAiResult,
                  ),
              ],
            ),
            if (_aiLoading) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
            if (_aiError != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: MotorsportColors.alarmBg,
                  border: Border.all(color: MotorsportColors.alarmBorder),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _aiError!,
                      style: TextStyle(color: tokens.text, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    UniformActionButton(
                      label: 'Tentar Novamente',
                      icon: Icons.refresh,
                      variant: UniformActionVariant.danger,
                      onTap: _runAiAnalysis,
                    ),
                  ],
                ),
              ),
            ],
            if (_aiResult != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: tokens.surfaceAlt,
                  border: Border.all(
                    color: tokens.border,
                    width: tokens.cardBorderWidth,
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Parecer · ${_aiResult!.providerLabel} (${_aiResult!.model})',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: tokens.accent,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      _aiResult!.analysisMarkdown,
                      style: TextStyle(
                        color: tokens.text,
                        fontSize: 12.5,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildFindingsSection(List<DiagnosticFinding> findings) {
    final tokens = MotorsportTheme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(
          color: tokens.borderSubtle,
          width: tokens.cardBorderWidth,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Diagnóstico Automático (Regras Offline)',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tokens.text,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < findings.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _buildFindingTile(findings[i]),
          ],
        ],
      ),
    );
  }

  Widget _buildFindingTile(DiagnosticFinding f) {
    final tokens = MotorsportTheme.tokensOf(context);
    final (Color accent, Color bg, Color border, String badgeText) = switch (f.severity) {
      'alarm' => (
          MotorsportColors.alarm,
          MotorsportColors.alarmBg,
          MotorsportColors.alarmBorder,
          'CRÍTICO',
        ),
      'warn' => (
          MotorsportColors.warning,
          MotorsportColors.warnBg,
          MotorsportColors.warnBorder,
          'ATENÇÃO',
        ),
      'ok' => (
          MotorsportColors.ok,
          const Color(0xFF0E2118),
          const Color(0xFF1A4F34),
          'OK',
        ),
      _ => (
          tokens.accent,
          tokens.surfaceAlt,
          tokens.border,
          'INFO',
        ),
    };

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: border, width: tokens.cardBorderWidth),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _buildChipTag(badgeText, accent),
              _buildChipTag(f.category, tokens.muted),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            f.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: accent == tokens.accent ? tokens.text : accent,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            f.detail,
            style: TextStyle(
              color: tokens.text,
              fontSize: 12,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComparisonHighlights(LogComparisonReport comp) {
    final tokens = MotorsportTheme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(
          color: tokens.borderSubtle,
          width: tokens.cardBorderWidth,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Resumo Comparativo (A vs B)',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tokens.text,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          for (final h in comp.summaryHighlights)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '• ',
                    style: TextStyle(
                      color: tokens.accent,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      h,
                      style: TextStyle(color: tokens.text, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
          if (comp.reportA.findings.isNotEmpty || comp.reportB.findings.isNotEmpty) ...[
            const SizedBox(height: 6),
            const Divider(height: 12),
            Text(
              'Alertas Log A: ${comp.reportA.findings.map((f) => '[${f.severity.toUpperCase()}] ${f.title}').join(' · ')}',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tokens.muted, fontSize: 11.5),
            ),
            const SizedBox(height: 4),
            Text(
              'Alertas Log B: ${comp.reportB.findings.map((f) => '[${f.severity.toUpperCase()}] ${f.title}').join(' · ')}',
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: tokens.muted, fontSize: 11.5),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSingleStatsSection(LogAnalysisReport report) {
    final filtered = report.channelStats.where((s) {
      if (_searchQuery.isEmpty) return true;
      return s.label.toLowerCase().contains(_searchQuery) ||
          s.key.toLowerCase().contains(_searchQuery) ||
          s.unit.toLowerCase().contains(_searchQuery);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildChannelSearchHeader(
          title: 'Estatísticas por Canal (${filtered.length})',
        ),
        const SizedBox(height: 8),
        if (filtered.isEmpty)
          _buildNoChannelMatch()
        else
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 10.0;
              final w = constraints.maxWidth;
              final cols = w >= 700 ? 2 : 1;
              final cardW = (w - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final stat in filtered)
                    SizedBox(
                      width: cardW,
                      child: _buildChannelStatCard(stat),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _buildComparisonDeltasSection(LogComparisonReport comp) {
    final tokens = MotorsportTheme.tokensOf(context);
    final filtered = comp.deltas.where((d) {
      if (_onlySignificant && !d.isSignificant) return false;
      if (_searchQuery.isEmpty) return true;
      return d.label.toLowerCase().contains(_searchQuery) ||
          d.key.toLowerCase().contains(_searchQuery) ||
          d.unit.toLowerCase().contains(_searchQuery);
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildChannelSearchHeader(
          title: 'Comparação por Canal (${filtered.length})',
          trailing: FilterChip(
            label: Text(
              'Apenas significativos',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: tokens.text),
            ),
            selected: _onlySignificant,
            onSelected: (v) => setState(() => _onlySignificant = v),
          ),
        ),
        const SizedBox(height: 8),
        if (filtered.isEmpty)
          _buildNoChannelMatch()
        else
          LayoutBuilder(
            builder: (context, constraints) {
              const gap = 10.0;
              final w = constraints.maxWidth;
              final cols = w >= 700 ? 2 : 1;
              final cardW = (w - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final d in filtered)
                    SizedBox(
                      width: cardW,
                      child: _buildComparisonDeltaCard(d),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _buildChannelSearchHeader({
    required String title,
    Widget? trailing,
  }) {
    final tokens = MotorsportTheme.tokensOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tokens.text,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            hintText: 'Filtrar canal por nome, chave ou unidade...',
            hintStyle: TextStyle(color: tokens.muted, fontSize: 12.5),
            prefixIcon: Icon(Icons.search, size: 18, color: tokens.muted),
            suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    onPressed: _searchCtrl.clear,
                    icon: Icon(Icons.clear, size: 17, color: tokens.muted),
                  )
                : null,
          ),
        ),
      ],
    );
  }

  Widget _buildNoChannelMatch() {
    final tokens = MotorsportTheme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(
          color: tokens.borderSubtle,
          width: tokens.cardBorderWidth,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'Nenhum canal encontrado com os filtros atuais.',
        textAlign: TextAlign.center,
        style: TextStyle(color: tokens.muted, fontSize: 12.5),
      ),
    );
  }

  Widget _buildChannelStatCard(ChannelStatistics s) {
    final tokens = MotorsportTheme.tokensOf(context);
    final color = MotorsportColors.colorForChannel(s.key);
    final unitSuffix = s.unit.isNotEmpty ? ' ${s.unit}' : '';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(
          color: tokens.borderSubtle,
          width: tokens.cardBorderWidth,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  s.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (s.unit.isNotEmpty) ...[
                const SizedBox(width: 6),
                _buildChipTag(s.unit, color),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${s.key} · ${s.count} amostras',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: tokens.stale, fontSize: 10.5),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, c) {
              const gap = 8.0;
              final cols = c.maxWidth >= 340 ? 3 : 2;
              final cellW = (c.maxWidth - gap * (cols - 1)) / cols;
              final isCumulative = const {
                'distance_km',
                'trip_km',
                'dist_mil',
                'dist_clr',
                'trip_liters',
                'trip_fuel_liters',
                'trip_cost_brl',
              }.contains(s.key);
              final isFuelChannel = const {
                'fuel_econ_kml',
                'fuel_rate_lph',
                'fuel_rate',
              }.contains(s.key);
              final totalDelta = (s.max - s.min).abs() > 1e-6 ? (s.max - s.min) : s.last;
              final fuelL = _reportA?.fuelConsumedLiters ?? 0.0;

              final metrics = isCumulative
                  ? [
                      ('Total', '${_fmtVal(s.key, totalDelta)}$unitSuffix'),
                      ('Inicial', '${_fmtVal(s.key, s.first)}$unitSuffix'),
                      ('Final', '${_fmtVal(s.key, s.last)}$unitSuffix'),
                      ('Amostras', '${s.count}'),
                    ]
                  : [
                      ('Média', '${_fmtVal(s.key, s.mean)}$unitSuffix'),
                      if (isFuelChannel && fuelL > 0.001)
                        ('Litros Gastos', '${fuelL.toStringAsFixed(2)} L'),
                      ('Mediana', '${_fmtVal(s.key, s.median)}$unitSuffix'),
                      (
                        'Moda (${s.modeFrequencyPct.toStringAsFixed(0)}%)',
                        '${_fmtVal(s.key, s.mode)}$unitSuffix',
                      ),
                      ('Mín', '${_fmtVal(s.key, s.min)}$unitSuffix'),
                      ('Máx', '${_fmtVal(s.key, s.max)}$unitSuffix'),
                      ('Desvio', _fmtVal(s.key, s.stdDev)),
                      ('P5', _fmtVal(s.key, s.p5)),
                      ('P95', _fmtVal(s.key, s.p95)),
                      ('Amostras', '${s.count}'),
                    ];

              return Wrap(
                spacing: gap,
                runSpacing: 6,
                children: [
                  for (final m in metrics)
                    SizedBox(
                      width: cellW,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
                        decoration: BoxDecoration(
                          color: tokens.surfaceAlt,
                          border: Border.all(
                            color: tokens.borderSubtle,
                            width: tokens.cardBorderWidth,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              m.$1,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: tokens.muted,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerLeft,
                              child: Text(
                                m.$2,
                                maxLines: 1,
                                style: MotorsportTheme.tabularStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: tokens.text,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildComparisonDeltaCard(ChannelComparisonDelta d) {
    final tokens = MotorsportTheme.tokensOf(context);
    final color = MotorsportColors.colorForChannel(d.key);
    final unitSuffix = d.unit.isNotEmpty ? ' ${d.unit}' : '';
    final dec = _decimalsFor(d.key);
    final pctStr = d.deltaMeanPct != null
        ? ' (${_signed(d.deltaMeanPct!, 1)}%)'
        : '';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(
          color: d.isSignificant
              ? MotorsportColors.warning.withValues(alpha: 0.7)
              : tokens.borderSubtle,
          width: tokens.cardBorderWidth,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  d.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (d.isSignificant) ...[
                const SizedBox(width: 6),
                _buildChipTag('SIGNIFICATIVO', MotorsportColors.warning),
              ],
            ],
          ),
          const SizedBox(height: 8),
          _buildCompareRow(
            label: 'Média A → B',
            value:
                '${d.statA.mean.toStringAsFixed(dec)} → ${d.statB.mean.toStringAsFixed(dec)}$unitSuffix',
            delta: '${_signed(d.deltaMean, dec)}$unitSuffix$pctStr',
            highlight: d.isSignificant,
          ),
          const SizedBox(height: 5),
          _buildCompareRow(
            label: 'Mediana A → B',
            value:
                '${d.statA.median.toStringAsFixed(dec)} → ${d.statB.median.toStringAsFixed(dec)}$unitSuffix',
            delta: _signed(d.deltaMedian, dec),
          ),
          const SizedBox(height: 5),
          _buildCompareRow(
            label: 'Moda A → B',
            value:
                '${d.statA.mode.toStringAsFixed(dec)} → ${d.statB.mode.toStringAsFixed(dec)}$unitSuffix',
            delta: _signed(d.deltaMode, dec),
          ),
          const SizedBox(height: 5),
          if (const {
            'distance_km',
            'trip_km',
            'dist_mil',
            'dist_clr',
            'trip_liters',
            'trip_fuel_liters',
            'trip_cost_brl',
          }.contains(d.key))
            _buildCompareRow(
              label: 'Total A vs B',
              value: 'A: ${d.statA.last.toStringAsFixed(dec)}$unitSuffix',
              delta: 'B: ${d.statB.last.toStringAsFixed(dec)}$unitSuffix',
            )
          else
            _buildCompareRow(
              label: 'Mín / Máx A vs B',
              value:
                  'A: ${d.statA.min.toStringAsFixed(dec)}..${d.statA.max.toStringAsFixed(dec)}',
              delta:
                  'B: ${d.statB.min.toStringAsFixed(dec)}..${d.statB.max.toStringAsFixed(dec)}',
            ),
        ],
      ),
    );
  }

  Widget _buildCompareRow({
    required String label,
    required String value,
    required String delta,
    bool highlight = false,
  }) {
    final tokens = MotorsportTheme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: tokens.surfaceAlt,
        border: Border.all(
          color: tokens.borderSubtle,
          width: tokens.cardBorderWidth,
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tokens.muted,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          LayoutBuilder(
            builder: (context, constraints) {
              return Wrap(
                spacing: 8,
                runSpacing: 2,
                alignment: WrapAlignment.spaceBetween,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        value,
                        maxLines: 1,
                        style: MotorsportTheme.tabularStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: tokens.text,
                        ),
                      ),
                    ),
                  ),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: constraints.maxWidth),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        delta,
                        maxLines: 1,
                        style: MotorsportTheme.tabularStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: highlight
                              ? MotorsportColors.warning
                              : tokens.accent,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildChipTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        border: Border.all(color: color.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildErrorBanner(String msg) {
    final tokens = MotorsportTheme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: MotorsportColors.alarmBg,
        border: Border.all(color: MotorsportColors.alarmBorder),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        msg,
        style: TextStyle(color: tokens.text, fontSize: 12),
      ),
    );
  }

  int _decimalsFor(String key) {
    final core = coreChannels[key];
    if (core != null) return core.decimals;
    if (key == 'inj_pulse_width' || key == 'accel_g') return 2;
    return 2;
  }

  String _fmtVal(String key, double val) {
    final core = coreChannels[key];
    if (core != null) return core.formatValue(val);
    return val.toStringAsFixed(_decimalsFor(key));
  }

  String _signed(double v, int decimals) {
    final prefix = v >= 0 ? '+' : '';
    return '$prefix${v.toStringAsFixed(decimals)}';
  }

  String _fmtDuration(double sec) {
    if (sec < 60.0) return '${sec.toStringAsFixed(1)}s';
    final mins = sec ~/ 60;
    final rem = sec - mins * 60;
    return '${mins}m${rem.toStringAsFixed(0).padLeft(2, '0')}s';
  }
}

class _KpiData {
  final String title;
  final String value;
  final String subtitle;
  final Color accent;

  const _KpiData({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.accent,
  });
}
