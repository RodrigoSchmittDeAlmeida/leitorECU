import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'csv_logger.dart';
import 'log_exporters.dart';

/// Metadados resumidos de um arquivo de log `.csv` armazenado no dispositivo.
class LogFileEntry {
  final String name;
  final String path;
  final DateTime modified;
  final int sizeBytes;
  final int rowCount;
  final double? durationSec;

  const LogFileEntry({
    required this.name,
    required this.path,
    required this.modified,
    required this.sizeBytes,
    required this.rowCount,
    this.durationSec,
  });
}

/// Repositório local de gerenciamento, importação e compartilhamento de logs CSV / MSL.
class LogRepository {
  final Directory? directoryOverride;

  const LogRepository({this.directoryOverride});

  /// Resolve a pasta gravável `leitorECU_logs` dentro de `getApplicationDocumentsDirectory()`
  /// ou utiliza [directoryOverride] (ex.: em testes unitários).
  Future<Directory> resolveLogsDirectory() async {
    if (directoryOverride != null) {
      if (!await directoryOverride!.exists()) {
        await directoryOverride!.create(recursive: true);
      }
      return directoryOverride!;
    }
    final docs = await getApplicationDocumentsDirectory();
    final sep = Platform.pathSeparator;
    final dir = Directory('${docs.path}${sep}leitorECU_logs');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Cria caminho com carimbo de data/hora para um novo arquivo de log CSV.
  Future<String> createNewLogPath({String prefix = 'log'}) async {
    final dir = await resolveLogsDirectory();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final sep = Platform.pathSeparator;
    var candidate = '${dir.path}$sep${prefix}_$stamp.csv';
    var suffix = 1;
    while (await File(candidate).exists()) {
      candidate = '${dir.path}$sep${prefix}_${stamp}_$suffix.csv';
      suffix++;
    }
    return candidate;
  }

  /// Lista todos os `.csv` na pasta de logs ordenados do mais recente ao mais antigo.
  Future<List<LogFileEntry>> listLogs() async {
    final dir = await resolveLogsDirectory();
    if (!await dir.exists()) return [];

    final entries = <LogFileEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.csv')) continue;
      entries.add(await _inspectCsvFile(entity));
    }

    entries.sort((a, b) => b.modified.compareTo(a.modified));
    return entries;
  }

  Future<LogFileEntry> _inspectCsvFile(File file) async {
    final stat = await file.stat();
    final name = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : file.path.split(Platform.pathSeparator).last;

    var rowCount = 0;
    double? firstT;
    double? lastT;

    try {
      final stream = file
          .openRead()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter());

      var tCol = 1;
      var delim = ';';
      var isHeader = true;

      await for (final rawLine in stream) {
        if (rawLine.trim().isEmpty) continue;
        final line = rawLine.startsWith('\uFEFF') ? rawLine.substring(1) : rawLine;
        if (isHeader) {
          isHeader = false;
          delim = line.contains(';') ? ';' : ',';
          final cols =
              line.split(delim).map((c) => c.trim().toLowerCase()).toList();
          for (final cand in const ['tempo_s', 't_s', 'time_s', 'timestamp_s', 'time']) {
            final idx = cols.indexOf(cand);
            if (idx != -1) {
              tCol = idx;
              break;
            }
          }
          continue;
        }
        rowCount++;
        final cells = line.split(delim);
        if (tCol >= 0 && tCol < cells.length) {
          final parsed =
              double.tryParse(cells[tCol].trim().replaceAll(',', '.'));
          if (parsed != null && parsed.isFinite) {
            firstT ??= parsed;
            lastT = parsed;
          }
        }
      }
    } catch (_) {
      // Mantém metadados básicos mesmo se o arquivo estiver corrompido
    }

    final durationSec = (firstT != null && lastT != null && lastT >= firstT)
        ? lastT - firstT
        : null;

    return LogFileEntry(
      name: name,
      path: file.path,
      modified: stat.modified,
      sizeBytes: stat.size,
      rowCount: rowCount,
      durationSec: durationSec,
    );
  }

  /// Importa um CSV externo (via [sourcePath] direto ou diálogo nativo `file_picker`)
  /// copiando-o para a pasta de logs do aplicativo.
  Future<LogFileEntry?> importCsvFile({String? sourcePath}) async {
    String? pickedPath = sourcePath;
    if (pickedPath == null) {
      try {
        final picked = await FilePicker.pickFile(
          dialogTitle: 'Importar Log CSV',
          type: FileType.custom,
          allowedExtensions: const ['csv'],
        );
        pickedPath = picked?.path;
      } catch (_) {
        return null;
      }
    }

    if (pickedPath == null || pickedPath.isEmpty) return null;
    final src = File(pickedPath);
    if (!await src.exists()) return null;

    final dir = await resolveLogsDirectory();
    final sep = Platform.pathSeparator;
    final baseName = src.uri.pathSegments.isNotEmpty
        ? src.uri.pathSegments.last
        : pickedPath.split(sep).last;

    var dstPath = '${dir.path}$sep$baseName';
    if (src.absolute.path != File(dstPath).absolute.path) {
      if (await File(dstPath).exists()) {
        final dot = baseName.lastIndexOf('.');
        final stem = dot > 0 ? baseName.substring(0, dot) : baseName;
        final ext = dot > 0 ? baseName.substring(dot) : '.csv';
        final stamp = DateTime.now().millisecondsSinceEpoch;
        dstPath = '${dir.path}$sep${stem}_$stamp$ext';
      }
      await src.copy(dstPath);
    }

    return _inspectCsvFile(File(dstPath));
  }

  /// Exporta um CSV para `.msl` (MegaLogViewer) e retorna o caminho do arquivo gerado.
  Future<String?> exportMslFile(String csvPath) async {
    final src = File(csvPath);
    if (!await src.exists()) return null;
    final dstPath = csvPath.toLowerCase().endsWith('.csv')
        ? '${csvPath.substring(0, csvPath.length - 4)}.msl'
        : '$csvPath.msl';
    final ok = await MegaLogViewerExporter.exportFromCsv(csvPath, dstPath);
    return ok ? dstPath : null;
  }

  /// Compartilha um arquivo `.csv` ou `.msl` via `share_plus`.
  Future<bool> shareLogFile(String filePath, {bool asMsl = false}) async {
    try {
      String targetPath = filePath;
      if (asMsl) {
        final msl = await exportMslFile(filePath);
        if (msl == null) return false;
        targetPath = msl;
      }
      final file = File(targetPath);
      if (!await file.exists()) return false;

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(targetPath)],
          subject: 'Log de Telemetria leitorECU',
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Exporta um CSV salvo para `.xlsx`, `.html`, `.pdf`, `.json`, `.csv` ou `.msl`.
  Future<String?> exportFormattedFile(
    String csvPath,
    LogExportFormat format,
  ) async {
    final src = File(csvPath);
    if (!await src.exists()) return null;
    try {
      final out = await LogExporters.exportToFile(
        csvPath: csvPath,
        format: format,
      );
      return out.path;
    } catch (_) {
      return null;
    }
  }

  /// Exporta e abre o menu de compartilhamento nativo no formato escolhido.
  Future<bool> shareLogFileAs(
    String csvPath,
    LogExportFormat format,
  ) async {
    try {
      final exportedPath = format == LogExportFormat.csv
          ? csvPath
          : await exportFormattedFile(csvPath, format);
      if (exportedPath == null) return false;
      final file = File(exportedPath);
      if (!await file.exists()) return false;

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(exportedPath, mimeType: format.mimeType)],
          subject: 'Telemetria leitorECU (${format.label})',
        ),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Exclui um log `.csv` (e eventual `.msl` irmão) com segurança.
  Future<bool> deleteLog(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Renomeia um arquivo de log mantendo extensão `.csv`.
  Future<LogFileEntry?> renameLog(String oldPath, String newName) async {
    try {
      final oldFile = File(oldPath);
      if (!await oldFile.exists()) return null;
      var sanitized = newName.trim().replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      if (sanitized.isEmpty) return null;
      if (!sanitized.toLowerCase().endsWith('.csv')) {
        sanitized = '$sanitized.csv';
      }
      final sep = Platform.pathSeparator;
      final newPath = '${oldFile.parent.path}$sep$sanitized';
      if (newPath == oldPath) {
        return await _inspectCsvFile(oldFile);
      }
      if (await File(newPath).exists()) return null;
      final renamed = await oldFile.rename(newPath);
      return await _inspectCsvFile(renamed);
    } catch (_) {
      return null;
    }
  }
}
