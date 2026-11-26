import 'package:material_ui/material_ui.dart';

import '../../core/settings/app_settings.dart';
import '../../state/telemetry_controller.dart';
import '../../storage/log_exporters.dart';
import '../../storage/log_repository.dart';
import '../theme/motorsport_theme.dart';
import '../widgets/uniform_action_button.dart';
import 'log_analysis_screen.dart';

/// Aba Logs: gerenciamento, gravação, importação, Replay, análise IA, compartilhamento CSV e exportação .msl.
class LogsScreen extends StatefulWidget {
  const LogsScreen({
    super.key,
    required this.controller,
    this.settings,
    this.onReplayLoaded,
  });

  final TelemetryController controller;
  final AppSettingsController? settings;
  final VoidCallback? onReplayLoaded;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  List<LogFileEntry> _entries = const [];
  bool _loading = true;
  bool _lastRecording = false;

  @override
  void initState() {
    super.initState();
    _lastRecording = widget.controller.isRecording;
    widget.controller.addListener(_onControllerChanged);
    _refreshLogs();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final rec = widget.controller.isRecording;
    if (rec != _lastRecording) {
      _lastRecording = rec;
      _refreshLogs();
    }
  }

  Future<void> _refreshLogs() async {
    try {
      final list = await widget.controller.logRepository.listLogs();
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _toggleRecord() async {
    await widget.controller.toggleRecording();
    await _refreshLogs();
  }

  Future<void> _importCsv() async {
    final ok = await widget.controller.importCsvAndReplay();
    await _refreshLogs();
    if (!mounted) return;
    if (ok) {
      widget.onReplayLoaded?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('CSV importado e carregado em Modo Replay.')),
      );
    }
  }

  Future<void> _openReplay(LogFileEntry entry) async {
    final ok = await widget.controller.loadReplayFromPath(entry.path);
    if (!mounted) return;
    if (ok) {
      widget.onReplayLoaded?.call();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Replay carregado: ${entry.name}')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Arquivo CSV vazio ou inválido para Replay.')),
      );
    }
  }

  Future<void> _exportWithFormat(
    LogFileEntry entry,
    LogExportFormat format,
  ) async {
    final repo = widget.controller.logRepository;
    final exportedPath = format == LogExportFormat.csv
        ? entry.path
        : await repo.exportFormattedFile(entry.path, format);
    if (!mounted) return;
    if (exportedPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao gerar ${format.label}.')),
      );
      return;
    }
    final shared = await repo.shareLogFileAs(entry.path, format);
    if (!mounted) return;
    if (!shared) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${format.label} salvo em: $exportedPath')),
      );
    }
  }

  Future<void> _showExportFormatSheet(LogFileEntry entry) async {
    final tokens = MotorsportTheme.tokensOf(context);
    final chosen = await showModalBottomSheet<LogExportFormat>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: tokens.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Exportar Log em Outro Formato',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: tokens.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11.5,
                  color: tokens.muted,
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final fmt in LogExportFormat.values)
                      ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        leading: Icon(
                          _iconForFormat(fmt),
                          color: tokens.accent,
                        ),
                        title: Text(
                          fmt.label,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: tokens.text,
                          ),
                        ),
                        subtitle: Text(
                          fmt.subtitle,
                          style: TextStyle(
                            fontSize: 11,
                            color: tokens.muted,
                          ),
                        ),
                        onTap: () => Navigator.of(ctx).pop(fmt),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen != null && mounted) {
      await _exportWithFormat(entry, chosen);
    }
  }

  void _openAnalysis({
    String? initialLogPath,
    bool startInCompareMode = false,
  }) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LogAnalysisScreen(
          controller: widget.controller,
          settings: widget.settings ?? AppSettingsController(),
          initialLogPath: initialLogPath,
          startInCompareMode: startInCompareMode,
        ),
      ),
    );
  }

  IconData _iconForFormat(LogExportFormat fmt) => switch (fmt) {
        LogExportFormat.xlsx => Icons.table_chart_outlined,
        LogExportFormat.html => Icons.public_outlined,
        LogExportFormat.pdf => Icons.picture_as_pdf_outlined,
        LogExportFormat.json => Icons.data_object_outlined,
        LogExportFormat.csv => Icons.description_outlined,
        LogExportFormat.msl => Icons.transform_outlined,
      };

  Future<void> _confirmDelete(LogFileEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir Log CSV?'),
        content: Text('Deseja remover permanentemente "${entry.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: MotorsportColors.alarmBg,
              foregroundColor: MotorsportColors.alarm,
              side: const BorderSide(color: MotorsportColors.alarm),
            ),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.controller.logRepository.deleteLog(entry.path);
      await _refreshLogs();
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _formatDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final isTablet = MediaQuery.sizeOf(context).width >= MotorsportTheme.tabletBreakpoint;

        return Padding(
          padding: EdgeInsets.all(isTablet ? 12 : 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTopActions(c),
              const SizedBox(height: 10),
              if (c.isRecording) ...[
                _buildActiveRecordingBanner(c),
                const SizedBox(height: 10),
              ],
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _entries.isEmpty
                        ? _buildEmptyState()
                        : RefreshIndicator(
                            onRefresh: _refreshLogs,
                            child: isTablet ? _buildTabletGrid() : _buildPhoneList(),
                          ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildTopActions(TelemetryController c) {
    return UniformButtonGrid(
      columns: 2,
      tabletColumns: 4,
      children: [
        UniformActionButton(
          label: c.isRecording
              ? '■ Parar Gravação (${c.recordingRows} linhas)'
              : '● Gravar Novo Log',
          icon: c.isRecording ? Icons.stop : Icons.fiber_manual_record,
          variant: c.isRecording
              ? UniformActionVariant.danger
              : UniformActionVariant.primary,
          active: c.isRecording,
          customIconColor: MotorsportColors.alarm,
          onTap: _toggleRecord,
        ),
        UniformActionButton(
          label: 'Importar CSV',
          icon: Icons.file_open_outlined,
          variant: UniformActionVariant.neutral,
          onTap: _importCsv,
        ),
        UniformActionButton(
          label: 'Comparar 2 Logs',
          icon: Icons.compare_arrows,
          variant: UniformActionVariant.neutral,
          onTap: () => _openAnalysis(startInCompareMode: true),
        ),
        UniformActionButton(
          label: 'Atualizar',
          icon: Icons.refresh,
          variant: UniformActionVariant.neutral,
          onTap: _refreshLogs,
        ),
      ],
    );
  }

  Widget _buildActiveRecordingBanner(TelemetryController c) {
    final tokens = MotorsportTheme.tokensOf(context);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: MotorsportColors.alarmBg,
        border: Border.all(color: MotorsportColors.alarm),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.fiber_manual_record,
            color: MotorsportColors.alarm,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Gravando em tempo real: ${c.recordingRows} amostras · ${c.recordingPath.split('/').last.split('\\').last}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: tokens.text,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    final tokens = MotorsportTheme.tokensOf(context);
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
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
          Icon(Icons.folder_open, color: tokens.muted, size: 40),
          const SizedBox(height: 10),
          Text(
            'Nenhum log CSV salvo no dispositivo',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: tokens.text,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Toque em "● Gravar Novo Log" ou "Importar CSV" para abrir logs do PC e inspecionar em Replay.',
            textAlign: TextAlign.center,
            style: TextStyle(color: tokens.muted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildPhoneList() {
    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _buildLogCard(_entries[i]),
    );
  }

  Widget _buildTabletGrid() {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 10.0;
        final colW = (constraints.maxWidth - gap) / 2;
        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final entry in _entries)
                SizedBox(
                  width: colW,
                  child: _buildLogCard(entry),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLogCard(LogFileEntry entry) {
    final tokens = MotorsportTheme.tokensOf(context);
    final durStr = entry.durationSec != null
        ? '${entry.durationSec!.toStringAsFixed(1)}s'
        : '--';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tokens.surface,
        border: Border.all(color: tokens.borderSubtle, width: tokens.cardBorderWidth),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.description_outlined, color: tokens.accent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Excluir Log',
                onPressed: () => _confirmDelete(entry),
                icon: const Icon(Icons.delete_outline, color: MotorsportColors.alarm, size: 18),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${_formatDate(entry.modified)}  ·  ${_formatSize(entry.sizeBytes)}  ·  ${entry.rowCount} linhas  ·  $durStr',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MotorsportTheme.tabularStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: tokens.muted,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: UniformActionButton(
                  label: 'Abrir Replay',
                  icon: Icons.play_arrow,
                  variant: UniformActionVariant.info,
                  height: 38,
                  onTap: () => _openReplay(entry),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: UniformActionButton(
                  label: 'Analisar',
                  icon: Icons.analytics_outlined,
                  variant: UniformActionVariant.neutral,
                  height: 38,
                  onTap: () => _openAnalysis(initialLogPath: entry.path),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: UniformActionButton(
                  label: 'Exportar',
                  icon: Icons.file_download_outlined,
                  variant: UniformActionVariant.primary,
                  height: 38,
                  onTap: () => _showExportFormatSheet(entry),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
