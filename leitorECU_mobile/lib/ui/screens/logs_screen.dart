import 'package:material_ui/material_ui.dart';

import '../../state/telemetry_controller.dart';
import '../../storage/log_exporters.dart';
import '../../storage/log_repository.dart';
import '../theme/motorsport_theme.dart';

/// Aba Logs: gerenciamento, gravação, importação, Replay, compartilhamento CSV e exportação .msl.
class LogsScreen extends StatefulWidget {
  const LogsScreen({
    super.key,
    required this.controller,
    this.onReplayLoaded,
  });

  final TelemetryController controller;
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

  Future<void> _shareCsv(LogFileEntry entry) async {
    final ok = await widget.controller.logRepository.shareLogFile(entry.path, asMsl: false);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CSV pronto em: ${entry.path}')),
      );
    }
  }

  Future<void> _exportMsl(LogFileEntry entry) async {
    final ok = await widget.controller.logRepository.shareLogFile(entry.path, asMsl: true);
    if (!mounted) return;
    if (!ok) {
      final msl = await widget.controller.logRepository.exportMslFile(entry.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            msl != null ? 'Arquivo .msl gerado em: $msl' : 'Falha ao exportar arquivo .msl',
          ),
        ),
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
    final chosen = await showModalBottomSheet<LogExportFormat>(
      context: context,
      backgroundColor: MotorsportColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Exportar Log em Outro Formato',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: MotorsportColors.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                entry.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: MotorsportColors.muted,
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
                          color: MotorsportColors.info,
                        ),
                        title: Text(
                          fmt.label,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: MotorsportColors.text,
                          ),
                        ),
                        subtitle: Text(
                          fmt.subtitle,
                          style: const TextStyle(
                            fontSize: 11,
                            color: MotorsportColors.muted,
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
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ElevatedButton.icon(
          onPressed: _toggleRecord,
          style: ElevatedButton.styleFrom(
            backgroundColor: c.isRecording ? const Color(0xFF531426) : const Color(0xFF073B29),
            foregroundColor: c.isRecording ? const Color(0xFFFFD6E0) : const Color(0xFFA9FFD3),
            side: BorderSide(color: c.isRecording ? MotorsportColors.alarm : MotorsportColors.ok),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
          icon: Icon(
            c.isRecording ? Icons.stop : Icons.fiber_manual_record,
            size: 18,
            color: c.isRecording ? MotorsportColors.alarm : MotorsportColors.alarm,
          ),
          label: Text(
            c.isRecording
                ? '■ Parar Gravação (${c.recordingRows} linhas)'
                : '● Gravar Novo Log',
          ),
        ),
        OutlinedButton.icon(
          onPressed: _importCsv,
          icon: const Icon(Icons.file_open_outlined, size: 18),
          label: const Text('Importar CSV'),
        ),
        OutlinedButton.icon(
          onPressed: _refreshLogs,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Atualizar'),
        ),
      ],
    );
  }

  Widget _buildActiveRecordingBanner(TelemetryController c) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: MotorsportColors.alarmBg,
        border: Border.all(color: MotorsportColors.alarm),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          const Icon(Icons.fiber_manual_record, color: MotorsportColors.alarm, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Gravando em tempo real: ${c.recordingRows} amostras · ${c.recordingPath.split('/').last.split('\\').last}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: MotorsportColors.text,
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
    return Container(
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: MotorsportColors.surface,
        border: Border.all(color: MotorsportColors.borderSubtle),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.folder_open, color: MotorsportColors.muted, size: 40),
          SizedBox(height: 10),
          Text(
            'Nenhum log CSV salvo no dispositivo',
            style: TextStyle(color: MotorsportColors.text, fontSize: 14, fontWeight: FontWeight.w700),
          ),
          SizedBox(height: 6),
          Text(
            'Toque em "● Gravar Novo Log" ou "Importar CSV" para abrir logs do PC e inspecionar em Replay.',
            textAlign: TextAlign.center,
            style: TextStyle(color: MotorsportColors.muted, fontSize: 12),
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
    final durStr = entry.durationSec != null
        ? '${entry.durationSec!.toStringAsFixed(1)}s'
        : '--';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: MotorsportColors.surface,
        border: Border.all(color: MotorsportColors.borderSubtle),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.description_outlined, color: MotorsportColors.info, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: MotorsportColors.text,
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
              color: MotorsportColors.muted,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ElevatedButton.icon(
                onPressed: () => _openReplay(entry),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0E2530),
                  foregroundColor: MotorsportColors.info,
                  side: const BorderSide(color: MotorsportColors.info),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                ),
                icon: const Icon(Icons.play_arrow, size: 15),
                label: const Text('Abrir Replay'),
              ),
              OutlinedButton.icon(
                onPressed: () => _showExportFormatSheet(entry),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  side: const BorderSide(color: MotorsportColors.info),
                  foregroundColor: MotorsportColors.info,
                ),
                icon: const Icon(Icons.file_download_outlined, size: 15),
                label: const Text('Exportar (Excel / HTML / PDF)'),
              ),
              OutlinedButton.icon(
                onPressed: () => _shareCsv(entry),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                ),
                icon: const Icon(Icons.share, size: 15),
                label: const Text('Exportar CSV'),
              ),
              OutlinedButton.icon(
                onPressed: () => _exportMsl(entry),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                ),
                icon: const Icon(Icons.transform, size: 15),
                label: const Text('Exportar .msl'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
