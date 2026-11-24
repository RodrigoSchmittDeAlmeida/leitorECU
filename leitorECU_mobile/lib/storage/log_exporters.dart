import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../core/models/channel_def.dart';
import 'csv_logger.dart';
import 'csv_replay_parser.dart';

/// Formatos de exportação disponíveis no aplicativo móvel.
enum LogExportFormat {
  xlsx(
    extension: 'xlsx',
    label: 'Excel (.xlsx)',
    subtitle: 'Planilha multi-abas (Resumo, Telemetria e Eventos)',
    mimeType:
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  ),
  html(
    extension: 'html',
    label: 'Relatório Web (.html)',
    subtitle: 'Painel escuro interativo com gráficos SVG para navegador',
    mimeType: 'text/html',
  ),
  pdf(
    extension: 'pdf',
    label: 'Relatório PDF (.pdf)',
    subtitle: 'Documento técnico com resumo, tabela de sensores e mini-gráficos',
    mimeType: 'application/pdf',
  ),
  json(
    extension: 'json',
    label: 'JSON (.json)',
    subtitle: 'Dados estruturados com metadados, estatísticas e amostras',
    mimeType: 'application/json',
  ),
  csv(
    extension: 'csv',
    label: 'CSV Original (.csv)',
    subtitle: 'Planilha com separador ponto-e-vírgula (padrão Excel pt-BR)',
    mimeType: 'text/csv',
  ),
  msl(
    extension: 'msl',
    label: 'MegaLogViewer (.msl)',
    subtitle: 'Log tabulado para ferramentas de calibração e tuning',
    mimeType: 'text/tab-separated-values',
  );

  const LogExportFormat({
    required this.extension,
    required this.label,
    required this.subtitle,
    required this.mimeType,
  });

  final String extension;
  final String label;
  final String subtitle;
  final String mimeType;
}

class _ChannelStat {
  const _ChannelStat({
    required this.key,
    required this.label,
    required this.unit,
    required this.count,
    required this.min,
    required this.max,
    required this.avg,
    required this.last,
  });

  final String key;
  final String label;
  final String unit;
  final int count;
  final double min;
  final double max;
  final double avg;
  final double last;
}

class _LogReportData {
  const _LogReportData({
    required this.dataset,
    required this.sourceName,
    required this.durationSec,
    required this.distanceKm,
    required this.stats,
    required this.activeKeys,
  });

  final ReplayDataset dataset;
  final String sourceName;
  final double durationSec;
  final double distanceKm;
  final List<_ChannelStat> stats;
  final List<String> activeKeys;

  _ChannelStat? statFor(String key) {
    for (final s in stats) {
      if (s.key == key) return s;
    }
    return null;
  }

  static _LogReportData build(ReplayDataset ds, String sourceName) {
    final activeKeys = <String>[];
    final stats = <_ChannelStat>[];

    for (final key in ds.availableChannels) {
      double? lo;
      double? hi;
      double sum = 0.0;
      double? last;
      int cnt = 0;
      for (final rec in ds.records) {
        final v = rec[key];
        if (v == null || v.isNaN || v.isInfinite) continue;
        cnt++;
        sum += v;
        last = v;
        if (lo == null || v < lo) lo = v;
        if (hi == null || v > hi) hi = v;
      }
      if (cnt > 0 && lo != null && hi != null && last != null) {
        final desc = describeChannel(key);
        activeKeys.add(key);
        stats.add(
          _ChannelStat(
            key: key,
            label: desc.label,
            unit: desc.unit,
            count: cnt,
            min: lo,
            max: hi,
            avg: sum / cnt,
            last: last,
          ),
        );
      }
    }

    // Integração trapezoidal segura de distância (ignora lacunas de standby > 5s)
    double integratedKm = 0.0;
    double? prevSpd;
    double? prevT;
    for (int i = 0; i < ds.records.length; i++) {
      final spd = ds.records[i]['speed'];
      final t = ds.times[i];
      if (spd == null || !spd.isFinite) continue;
      if (prevSpd != null && prevT != null) {
        final dt = t - prevT;
        if (dt > 0.0 && dt <= 5.0) {
          integratedKm += ((prevSpd + spd) * 0.5) * (dt / 3600.0);
        }
      }
      prevSpd = spd;
      prevT = t;
    }

    final durationSec = math.max(0.0, ds.maxTime - ds.minTime);

    return _LogReportData(
      dataset: ds,
      sourceName: sourceName,
      durationSec: durationSec,
      distanceKm: integratedKm,
      stats: stats,
      activeKeys: activeKeys,
    );
  }
}

/// Exporta logs de telemetria em formatos nativos fáceis de abrir no celular e PC:
/// `.xlsx`, `.html`, `.pdf`, `.json`, `.csv` e `.msl`.
class LogExporters {
  LogExporters._();

  static Future<File> exportToFile({
    required String csvPath,
    required LogExportFormat format,
    String? outputPath,
  }) async {
    final targetPath = outputPath ?? _defaultOutputPath(csvPath, format);
    if (format == LogExportFormat.csv) {
      if (targetPath == csvPath) return File(csvPath);
      return File(csvPath).copy(targetPath);
    }
    if (format == LogExportFormat.msl) {
      final ok = await MegaLogViewerExporter.exportFromCsv(csvPath, targetPath);
      if (!ok) {
        throw StateError('Falha ao gerar arquivo MegaLogViewer (.msl)');
      }
      return File(targetPath);
    }

    final ds = await CsvReplayParser.parseFile(csvPath);
    final sourceName = csvPath.split(Platform.pathSeparator).last;

    final bytes = switch (format) {
      LogExportFormat.xlsx => buildXlsxBytes(ds, sourceName: sourceName),
      LogExportFormat.html =>
        utf8.encode(buildHtmlString(ds, sourceName: sourceName)),
      LogExportFormat.pdf => buildPdfBytes(ds, sourceName: sourceName),
      LogExportFormat.json =>
        utf8.encode(buildJsonString(ds, sourceName: sourceName)),
      LogExportFormat.csv || LogExportFormat.msl => Uint8List(0),
    };

    final outFile = File(targetPath);
    await outFile.parent.create(recursive: true);
    await outFile.writeAsBytes(bytes, flush: true);
    return outFile;
  }

  static String _defaultOutputPath(String csvPath, LogExportFormat format) {
    final lower = csvPath.toLowerCase();
    final stem = lower.endsWith('.csv')
        ? csvPath.substring(0, csvPath.length - 4)
        : csvPath;
    return '$stem.${format.extension}';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 1. JSON ESTRUTURADO
  // ═══════════════════════════════════════════════════════════════════════════
  static String buildJsonString(
    ReplayDataset ds, {
    String sourceName = 'log.csv',
  }) {
    final report = _LogReportData.build(ds, sourceName);
    final channelsMap = <String, Map<String, dynamic>>{};
    for (final s in report.stats) {
      channelsMap[s.key] = {
        'label': s.label,
        'unit': s.unit,
        'samples': s.count,
        'min': _round4(s.min),
        'avg': _round4(s.avg),
        'max': _round4(s.max),
        'last': _round4(s.last),
      };
    }

    final samplesList = <Map<String, dynamic>>[];
    for (int i = 0; i < ds.records.length; i++) {
      final row = <String, dynamic>{
        'tempo_s': _round4(ds.times[i]),
      };
      for (final key in report.activeKeys) {
        final v = ds.records[i][key];
        if (v != null && v.isFinite) {
          row[key] = _round4(v);
        }
      }
      samplesList.add(row);
    }

    final payload = {
      'metadata': {
        'generator': 'leitorECU Mobile',
        'sourceFile': sourceName,
        'exportedAt': DateTime.now().toIso8601String(),
        'durationSec': _round4(report.durationSec),
        'distanceKm': _round4(report.distanceKm),
        'sampleCount': ds.records.length,
        'activeChannelCount': report.activeKeys.length,
        'isTurboDetected': ds.isTurboDetected,
      },
      'channels': channelsMap,
      'events': [
        for (final ev in ds.events)
          {
            'tempo_s': _round4(ev.timeSec),
            'message': ev.text,
          },
      ],
      'samples': samplesList,
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 2. RELATÓRIO HTML INTERATIVO COM GRÁFICOS SVG
  // ═══════════════════════════════════════════════════════════════════════════
  static String buildHtmlString(
    ReplayDataset ds, {
    String sourceName = 'log.csv',
  }) {
    final report = _LogReportData.build(ds, sourceName);
    final rpmStat = report.statFor('rpm');
    final spdStat = report.statFor('speed');
    final ectStat = report.statFor('ect') ?? report.statFor('cht_c');
    final stftStat = report.statFor('stft') ?? report.statFor('lambda_trim');
    final ltftStat = report.statFor('ltft') ?? report.statFor('ltft_idle');
    final batStat = report.statFor('battery');

    const chartPriority = [
      'rpm',
      'speed',
      'map',
      'ect',
      'cht_c',
      'lambda_v',
      'stft',
      'lambda_trim',
      'advance',
      'battery',
      'boost_bar',
      'tps',
    ];
    final chartKeys = <String>[];
    for (final k in chartPriority) {
      if (report.activeKeys.contains(k) && !chartKeys.contains(k)) {
        chartKeys.add(k);
        if (chartKeys.length >= 6) break;
      }
    }
    if (chartKeys.isEmpty) {
      chartKeys.addAll(report.activeKeys.take(4));
    }

    final chartCards = StringBuffer();
    for (final key in chartKeys) {
      final s = report.statFor(key);
      if (s == null) continue;
      final svg = _buildHtmlSvgChart(ds, key, s);
      chartCards.writeln('''
      <section class="card chart-card">
        <div class="chart-head">
          <div>
            <h3>${_escHtml(s.label)}</h3>
            <span class="mono muted">${_escHtml(key)} ${s.unit.isEmpty ? '' : '[${_escHtml(s.unit)}]'}</span>
          </div>
          <div class="chart-pills mono">
            <span>Mín: ${_fmtNum(s.min)}</span>
            <span>Méd: ${_fmtNum(s.avg)}</span>
            <span>Máx: ${_fmtNum(s.max)}</span>
          </div>
        </div>
        $svg
      </section>''');
    }

    final statRows = StringBuffer();
    for (final s in report.stats) {
      statRows.writeln(
        '<tr>'
        '<td><strong>${_escHtml(s.label)}</strong><div class="muted small mono">${_escHtml(s.key)}</div></td>'
        '<td class="mono">${_escHtml(s.unit.isEmpty ? '-' : s.unit)}</td>'
        '<td class="mono right">${_fmtNum(s.min)}</td>'
        '<td class="mono right">${_fmtNum(s.avg)}</td>'
        '<td class="mono right">${_fmtNum(s.max)}</td>'
        '<td class="mono right">${_fmtNum(s.last)}</td>'
        '<td class="mono right">${s.count}</td>'
        '</tr>',
      );
    }

    final eventRows = StringBuffer();
    if (ds.events.isEmpty) {
      eventRows.writeln(
        '<tr><td colspan="2" class="muted">Nenhum evento diagnóstico registrado neste log.</td></tr>',
      );
    } else {
      for (final ev in ds.events) {
        eventRows.writeln(
          '<tr>'
          '<td class="mono">${ev.timeSec.toStringAsFixed(2)} s</td>'
          '<td>${_escHtml(ev.text)}</td>'
          '</tr>',
        );
      }
    }

    return '''<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>leitorECU · ${_escHtml(sourceName)}</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #0e1117;
      --card: #151921;
      --alt: #1a202c;
      --border: #2c3545;
      --text: #e8edf5;
      --muted: #8b98ab;
      --cyan: #00d2ff;
      --green: #00e676;
      --amber: #ffb300;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      padding: 16px;
      background: var(--bg);
      color: var(--text);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      line-height: 1.45;
    }
    .wrap { max-width: 1080px; margin: 0 auto; }
    header {
      display: flex;
      flex-wrap: wrap;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
      margin-bottom: 16px;
      padding: 14px 16px;
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 12px;
    }
    h1 { margin: 0; font-size: 1.15rem; }
    h2 { margin: 20px 0 10px; font-size: 1rem; color: var(--cyan); }
    h3 { margin: 0; font-size: 0.95rem; }
    .muted { color: var(--muted); }
    .small { font-size: 0.78rem; }
    .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-variant-numeric: tabular-nums; }
    .right { text-align: right; }
    .kpis {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(145px, 1fr));
      gap: 10px;
      margin-bottom: 16px;
    }
    .kpi, .card {
      background: var(--card);
      border: 1px solid var(--border);
      border-radius: 10px;
      padding: 12px;
    }
    .kpi-label { font-size: 0.75rem; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; }
    .kpi-val { font-size: 1.25rem; font-weight: 800; margin-top: 4px; }
    .charts-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(310px, 1fr));
      gap: 12px;
    }
    .chart-head {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 8px;
      margin-bottom: 8px;
    }
    .chart-pills {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      font-size: 0.75rem;
      color: var(--muted);
    }
    svg { width: 100%; height: auto; display: block; background: #0a0c10; border-radius: 8px; }
    .search {
      width: 100%;
      max-width: 340px;
      padding: 8px 10px;
      margin-bottom: 10px;
      border-radius: 8px;
      border: 1px solid var(--border);
      background: var(--alt);
      color: var(--text);
      font-size: 0.9rem;
    }
    .table-wrap { overflow-x: auto; }
    table { width: 100%; border-collapse: collapse; font-size: 0.86rem; }
    th, td { padding: 8px 10px; border-bottom: 1px solid var(--border); text-align: left; }
    th { background: var(--alt); color: var(--muted); font-size: 0.76rem; text-transform: uppercase; }
  </style>
</head>
<body>
  <div class="wrap">
    <header>
      <div>
        <h1>leitorECU · Relatório de Telemetria</h1>
        <div class="muted small mono">${_escHtml(sourceName)} • ${ds.records.length} amostras • ${report.activeKeys.length} canais ativos</div>
      </div>
      <div class="small mono muted">Duração: ${_fmtDuration(report.durationSec)}</div>
    </header>

    <div class="kpis">
      <div class="kpi"><div class="kpi-label">Distância</div><div class="kpi-val mono">${report.distanceKm.toStringAsFixed(2)} km</div></div>
      <div class="kpi"><div class="kpi-label">Vel. Máxima</div><div class="kpi-val mono">${spdStat == null ? '--' : '${spdStat.max.toStringAsFixed(0)} km/h'}</div></div>
      <div class="kpi"><div class="kpi-label">RPM Máximo</div><div class="kpi-val mono">${rpmStat == null ? '--' : '${rpmStat.max.toStringAsFixed(0)} rpm'}</div></div>
      <div class="kpi"><div class="kpi-label">Temp. Motor Máx</div><div class="kpi-val mono">${ectStat == null ? '--' : '${ectStat.max.toStringAsFixed(0)} °C'}</div></div>
      <div class="kpi"><div class="kpi-label">STFT Médio</div><div class="kpi-val mono">${stftStat == null ? '--' : '${stftStat.avg.toStringAsFixed(1)} %'}</div></div>
      <div class="kpi"><div class="kpi-label">LTFT Médio</div><div class="kpi-val mono">${ltftStat == null ? '--' : '${ltftStat.avg.toStringAsFixed(1)} %'}</div></div>
      <div class="kpi"><div class="kpi-label">Bateria (Mín/Máx)</div><div class="kpi-val mono">${batStat == null ? '--' : '${batStat.min.toStringAsFixed(1)}–${batStat.max.toStringAsFixed(1)}V'}</div></div>
    </div>

    <h2>Gráficos dos Principais Parâmetros</h2>
    <div class="charts-grid">
      $chartCards
    </div>

    <h2>Estatísticas por Canal (${report.stats.length})</h2>
    <div class="card">
      <input id="filterInput" class="search" type="search" placeholder="Filtrar sensor ou canal..." oninput="filterTable()">
      <div class="table-wrap">
        <table id="statsTable">
          <thead>
            <tr>
              <th>Canal</th>
              <th>Unid.</th>
              <th class="right">Mín</th>
              <th class="right">Média</th>
              <th class="right">Máx</th>
              <th class="right">Último</th>
              <th class="right">Amostras</th>
            </tr>
          </thead>
          <tbody>$statRows</tbody>
        </table>
      </div>
    </div>

    <h2>Eventos e Anomalias (${ds.events.length})</h2>
    <div class="card table-wrap">
      <table>
        <thead><tr><th>Tempo</th><th>Descrição</th></tr></thead>
        <tbody>$eventRows</tbody>
      </table>
    </div>
  </div>
  <script>
    function filterTable() {
      const q = document.getElementById('filterInput').value.toLowerCase();
      const rows = document.querySelectorAll('#statsTable tbody tr');
      for (const r of rows) {
        r.style.display = r.textContent.toLowerCase().includes(q) ? '' : 'none';
      }
    }
  </script>
</body>
</html>''';
  }

  static String _buildHtmlSvgChart(
    ReplayDataset ds,
    String key,
    _ChannelStat stat,
  ) {
    final pts = <({double t, double v})>[];
    for (int i = 0; i < ds.records.length; i++) {
      final v = ds.records[i][key];
      if (v != null && v.isFinite) {
        pts.add((t: ds.times[i], v: v));
      }
    }
    if (pts.isEmpty) return '<svg viewBox="0 0 600 170"></svg>';

    // Downsample LTTB-simples por bucket caso muito grande para HTML leve no celular
    final sampled = _downsamplePoints(pts, 260);
    const w = 600.0;
    const h = 170.0;
    const padL = 44.0;
    const padR = 12.0;
    const padT = 12.0;
    const padB = 22.0;
    final plotW = w - padL - padR;
    final plotH = h - padT - padB;

    final tMin = ds.minTime;
    final tSpan = math.max(0.1, ds.maxTime - tMin);
    final vRange = stat.max - stat.min;
    final yLo = vRange.abs() < 1e-4 ? stat.min - 1.0 : stat.min - vRange * 0.08;
    final yHi = vRange.abs() < 1e-4 ? stat.max + 1.0 : stat.max + vRange * 0.08;
    final ySpan = math.max(1e-4, yHi - yLo);

    final poly = StringBuffer();
    for (int i = 0; i < sampled.length; i++) {
      final px = padL + ((sampled[i].t - tMin) / tSpan) * plotW;
      final py = padT + plotH - ((sampled[i].v - yLo) / ySpan) * plotH;
      if (i > 0) poly.write(' ');
      poly.write('${px.toStringAsFixed(1)},${py.toStringAsFixed(1)}');
    }

    final colorHex = _svgColorForKey(key);
    return '''<svg viewBox="0 0 600 170" xmlns="http://www.w3.org/2000/svg">
  <line x1="$padL" y1="$padT" x2="$padL" y2="${padT + plotH}" stroke="#242e3e" stroke-width="1"/>
  <line x1="$padL" y1="${padT + plotH}" x2="${w - padR}" y2="${padT + plotH}" stroke="#242e3e" stroke-width="1"/>
  <line x1="$padL" y1="$padT" x2="${w - padR}" y2="$padT" stroke="#1e2532" stroke-dasharray="3 3"/>
  <line x1="$padL" y1="${padT + plotH / 2}" x2="${w - padR}" y2="${padT + plotH / 2}" stroke="#1e2532" stroke-dasharray="3 3"/>
  <text x="${padL - 4}" y="${padT + 9}" fill="#8b98ab" font-size="10" text-anchor="end">${_fmtNum(yHi)}</text>
  <text x="${padL - 4}" y="${padT + plotH}" fill="#8b98ab" font-size="10" text-anchor="end">${_fmtNum(yLo)}</text>
  <text x="$padL" y="${h - 5}" fill="#8b98ab" font-size="10">${tMin.toStringAsFixed(0)}s</text>
  <text x="${w - padR}" y="${h - 5}" fill="#8b98ab" font-size="10" text-anchor="end">${ds.maxTime.toStringAsFixed(0)}s</text>
  <polyline fill="none" stroke="$colorHex" stroke-width="2" points="$poly"/>
</svg>''';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 3. PLANILHA EXCEL NATIVA (.XLSX OPENXML + ZIP DEFLATE PURE-DART)
  // ═══════════════════════════════════════════════════════════════════════════
  static Uint8List buildXlsxBytes(
    ReplayDataset ds, {
    String sourceName = 'log.csv',
  }) {
    final report = _LogReportData.build(ds, sourceName);

    final summarySheet = _buildXlsxSummarySheet(report);
    final telemetrySheet = _buildXlsxTelemetrySheet(report);
    final eventsSheet = _buildXlsxEventsSheet(report);

    final files = <({String name, List<int> data})>[
      (
        name: '[Content_Types].xml',
        data: utf8.encode('''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/xl/worksheets/sheet3.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>'''),
      ),
      (
        name: '_rels/.rels',
        data: utf8.encode('''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>'''),
      ),
      (
        name: 'xl/workbook.xml',
        data: utf8.encode('''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    <sheet name="Resumo" sheetId="1" r:id="rId1"/>
    <sheet name="Telemetria" sheetId="2" r:id="rId2"/>
    <sheet name="Eventos" sheetId="3" r:id="rId3"/>
  </sheets>
</workbook>'''),
      ),
      (
        name: 'xl/_rels/workbook.xml.rels',
        data: utf8.encode('''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet3.xml"/>
  <Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>'''),
      ),
      (
        name: 'xl/styles.xml',
        data: utf8.encode('''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="3">
    <font><sz val="11"/><name val="Calibri"/></font>
    <font><b/><sz val="12"/><name val="Calibri"/></font>
    <font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/></font>
  </fonts>
  <fills count="3">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF151921"/></patternFill></fill>
  </fills>
  <borders count="2">
    <border><left/><right/><top/><bottom/><diagonal/></border>
    <border>
      <left style="thin"><color rgb="FFD0D7DE"/></left>
      <right style="thin"><color rgb="FFD0D7DE"/></right>
      <top style="thin"><color rgb="FFD0D7DE"/></top>
      <bottom style="thin"><color rgb="FFD0D7DE"/></bottom>
    </border>
  </borders>
  <cellStyleXfs count="1">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
  </cellStyleXfs>
  <cellXfs count="4">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
    <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
    <xf numFmtId="0" fontId="2" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1"/>
    <xf numFmtId="2" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1" applyBorder="1"/>
  </cellXfs>
</styleSheet>'''),
      ),
      (name: 'xl/worksheets/sheet1.xml', data: utf8.encode(summarySheet)),
      (name: 'xl/worksheets/sheet2.xml', data: utf8.encode(telemetrySheet)),
      (name: 'xl/worksheets/sheet3.xml', data: utf8.encode(eventsSheet)),
    ];

    return _ZipWriter.build(files);
  }

  static String _buildXlsxSummarySheet(_LogReportData report) {
    final ds = report.dataset;
    final rows = StringBuffer();
    int r = 1;

    void addTitle(String text) {
      rows.write('<row r="$r">${_xlsxStrCell(0, r, text, style: 1)}</row>');
      r++;
    }

    void addKv(String key, dynamic val, {int numStyle = 3}) {
      rows.write(
        '<row r="$r">'
        '${_xlsxStrCell(0, r, key)}'
        '${val is num ? _xlsxNumCell(1, r, val.toDouble(), style: numStyle) : _xlsxStrCell(1, r, val.toString())}'
        '</row>',
      );
      r++;
    }

    addTitle('leitorECU Mobile — Resumo da Viagem e Estatísticas');
    addKv('Arquivo de Origem', report.sourceName);
    addKv('Duração (s)', report.durationSec);
    addKv('Distância Calculada (km)', report.distanceKm);
    addKv('Total de Amostras', ds.records.length, numStyle: 0);
    addKv('Canais Ativos', report.activeKeys.length, numStyle: 0);
    addKv('Eventos Diagnósticos', ds.events.length, numStyle: 0);
    r++;

    final headers = [
      'Canal',
      'Identificador',
      'Unidade',
      'Mínimo',
      'Média',
      'Máximo',
      'Último',
      'Amostras',
    ];
    rows.write('<row r="$r">');
    for (int c = 0; c < headers.length; c++) {
      rows.write(_xlsxStrCell(c, r, headers[c], style: 2));
    }
    rows.write('</row>');
    r++;

    for (final s in report.stats) {
      rows.write(
        '<row r="$r">'
        '${_xlsxStrCell(0, r, s.label)}'
        '${_xlsxStrCell(1, r, s.key)}'
        '${_xlsxStrCell(2, r, s.unit)}'
        '${_xlsxNumCell(3, r, s.min, style: 3)}'
        '${_xlsxNumCell(4, r, s.avg, style: 3)}'
        '${_xlsxNumCell(5, r, s.max, style: 3)}'
        '${_xlsxNumCell(6, r, s.last, style: 3)}'
        '${_xlsxNumCell(7, r, s.count.toDouble(), style: 0)}'
        '</row>',
      );
      r++;
    }

    return _wrapWorksheet(
      colsXml:
          '<cols>'
          '<col min="1" max="1" width="32" customWidth="1"/>'
          '<col min="2" max="2" width="20" customWidth="1"/>'
          '<col min="3" max="8" width="13" customWidth="1"/>'
          '</cols>',
      sheetData: rows.toString(),
    );
  }

  static String _buildXlsxTelemetrySheet(_LogReportData report) {
    final ds = report.dataset;
    final rows = StringBuffer();

    // Linha 1: Cabeçalhos legíveis sem duplicar unidade
    rows.write('<row r="1">');
    rows.write(_xlsxStrCell(0, 1, 'tempo_s', style: 2));
    for (int c = 0; c < report.activeKeys.length; c++) {
      final key = report.activeKeys[c];
      final desc = describeChannel(key);
      final title = CsvLogger.formatExtraHeader(desc.label, desc.unit);
      rows.write(_xlsxStrCell(c + 1, 1, title, style: 2));
    }
    rows.write('</row>');

    // Demais linhas com valores numéricos IEEE nativos
    for (int i = 0; i < ds.records.length; i++) {
      final rowIdx = i + 2;
      final rec = ds.records[i];
      rows.write('<row r="$rowIdx">');
      rows.write(_xlsxNumCell(0, rowIdx, ds.times[i], style: 3));
      for (int c = 0; c < report.activeKeys.length; c++) {
        final v = rec[report.activeKeys[c]];
        if (v != null && v.isFinite) {
          rows.write(_xlsxNumCell(c + 1, rowIdx, v));
        }
      }
      rows.write('</row>');
    }

    return _wrapWorksheet(
      colsXml:
          '<cols><col min="1" max="${report.activeKeys.length + 1}" width="16" customWidth="1"/></cols>',
      sheetData: rows.toString(),
    );
  }

  static String _buildXlsxEventsSheet(_LogReportData report) {
    final ds = report.dataset;
    final rows = StringBuffer();
    rows.write(
      '<row r="1">'
      '${_xlsxStrCell(0, 1, 'Tempo (s)', style: 2)}'
      '${_xlsxStrCell(1, 1, 'Evento / Alerta Diagnóstico', style: 2)}'
      '</row>',
    );
    if (ds.events.isEmpty) {
      rows.write(
        '<row r="2">'
        '${_xlsxNumCell(0, 2, 0.0, style: 3)}'
        '${_xlsxStrCell(1, 2, 'Nenhum evento registrado neste log.')}'
        '</row>',
      );
    } else {
      for (int i = 0; i < ds.events.length; i++) {
        final r = i + 2;
        final ev = ds.events[i];
        rows.write(
          '<row r="$r">'
          '${_xlsxNumCell(0, r, ev.timeSec, style: 3)}'
          '${_xlsxStrCell(1, r, ev.text)}'
          '</row>',
        );
      }
    }
    return _wrapWorksheet(
      colsXml:
          '<cols>'
          '<col min="1" max="1" width="14" customWidth="1"/>'
          '<col min="2" max="2" width="68" customWidth="1"/>'
          '</cols>',
      sheetData: rows.toString(),
    );
  }

  static String _wrapWorksheet({
    required String colsXml,
    required String sheetData,
  }) {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '$colsXml'
        '<sheetData>$sheetData</sheetData>'
        '</worksheet>';
  }

  static String _xlsxColName(int zeroBasedCol) {
    int n = zeroBasedCol + 1;
    final buf = StringBuffer();
    while (n > 0) {
      final rem = (n - 1) % 26;
      buf.writeCharCode(65 + rem);
      n = (n - 1) ~/ 26;
    }
    return buf.toString().split('').reversed.join();
  }

  static String _xlsxStrCell(
    int col,
    int row,
    String text, {
    int style = 0,
  }) {
    final ref = '${_xlsxColName(col)}$row';
    return '<c r="$ref" t="inlineStr" s="$style"><is><t>${_escXml(text)}</t></is></c>';
  }

  static String _xlsxNumCell(
    int col,
    int row,
    double value, {
    int style = 0,
  }) {
    final ref = '${_xlsxColName(col)}$row';
    final sAttr = style == 0 ? '' : ' s="$style"';
    return '<c r="$ref"$sAttr><v>${value.toStringAsFixed(4).replaceAll(RegExp(r'\.?0+$'), '').isEmpty ? '0' : value}</v></c>';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // 4. RELATÓRIO PDF VETORIAL PURE-DART (PDF 1.4 A4 COM SPARKLINES & TABELAS)
  // ═══════════════════════════════════════════════════════════════════════════
  static Uint8List buildPdfBytes(
    ReplayDataset ds, {
    String sourceName = 'log.csv',
  }) {
    final report = _LogReportData.build(ds, sourceName);
    final pages = <String>[];
    final current = StringBuffer();
    double y = 795.0; // A4: 595 x 842 pt, origem embaixo à esquerda

    void newPage() {
      if (current.isNotEmpty) {
        pages.add(current.toString());
        current.clear();
      }
      y = 795.0;
    }

    void drawText(
      double x,
      double yy,
      String text, {
      double size = 10,
      bool bold = false,
      String rgb = '0.10 0.14 0.20',
    }) {
      final font = bold ? 'F2' : 'F1';
      current.writeln(
        'BT /$font $size Tf $rgb rg ${x.toStringAsFixed(1)} ${yy.toStringAsFixed(1)} Td (${_pdfEsc(text)}) Tj ET',
      );
    }

    void drawLine(double x1, double y1, double x2, double y2, {String rgb = '0.82 0.85 0.90', double width = 0.6}) {
      current.writeln(
        '$width w $rgb RG ${x1.toStringAsFixed(1)} ${y1.toStringAsFixed(1)} m ${x2.toStringAsFixed(1)} ${y2.toStringAsFixed(1)} l S',
      );
    }

    void fillRect(double x, double yy, double w, double h, String rgb) {
      current.writeln(
        '$rgb rg ${x.toStringAsFixed(1)} ${yy.toStringAsFixed(1)} ${w.toStringAsFixed(1)} ${h.toStringAsFixed(1)} re f',
      );
    }

    // Cabeçalho página 1
    fillRect(36, 758, 523, 52, '0.08 0.11 0.16');
    drawText(48, 788, 'leitorECU Mobile - Relatorio de Telemetria', size: 15, bold: true, rgb: '1 1 1');
    drawText(
      48,
      770,
      'Arquivo: $sourceName  |  Amostras: ${ds.records.length}  |  Duracao: ${_fmtDuration(report.durationSec)}  |  Dist.: ${report.distanceKm.toStringAsFixed(2)} km',
      size: 9,
      rgb: '0.72 0.82 0.94',
    );
    y = 740.0;

    // Bloco KPIs rápidos
    final rpmStat = report.statFor('rpm');
    final spdStat = report.statFor('speed');
    final ectStat = report.statFor('ect') ?? report.statFor('cht_c');
    final stftStat = report.statFor('stft') ?? report.statFor('lambda_trim');
    final ltftStat = report.statFor('ltft') ?? report.statFor('ltft_idle');
    final batStat = report.statFor('battery');

    drawText(36, y, 'Resumo Executivo', size: 11.5, bold: true, rgb: '0.05 0.35 0.58');
    y -= 14;
    final kpis = [
      'RPM Max: ${rpmStat == null ? '--' : '${rpmStat.max.toStringAsFixed(0)} rpm'}',
      'Vel. Max: ${spdStat == null ? '--' : '${spdStat.max.toStringAsFixed(0)} km/h'}',
      'ECT Max: ${ectStat == null ? '--' : '${ectStat.max.toStringAsFixed(0)} °C'}',
      'STFT Med: ${stftStat == null ? '--' : '${stftStat.avg.toStringAsFixed(1)}%'}',
      'LTFT Med: ${ltftStat == null ? '--' : '${ltftStat.avg.toStringAsFixed(1)}%'}',
      'Bateria: ${batStat == null ? '--' : '${batStat.min.toStringAsFixed(1)}-${batStat.max.toStringAsFixed(1)}V'}',
    ];
    fillRect(36, y - 22, 523, 28, '0.95 0.96 0.98');
    drawText(44, y - 12, kpis.join('   |   '), size: 8.8, bold: true);
    y -= 38;

    // Mini-gráficos vetoriais dos principais canais
    const sparkKeys = ['rpm', 'speed', 'ect', 'lambda_v', 'stft', 'advance'];
    final availableSparks = sparkKeys.where(report.activeKeys.contains).take(4).toList();
    if (availableSparks.isNotEmpty) {
      drawText(36, y, 'Curvas Principais no Tempo', size: 11.5, bold: true, rgb: '0.05 0.35 0.58');
      y -= 10;
      const boxW = 254.0;
      const boxH = 56.0;
      for (int idx = 0; idx < availableSparks.length; idx++) {
        final col = idx % 2;
        if (idx > 0 && col == 0) y -= boxH + 10;
        final x0 = 36.0 + col * (boxW + 15);
        final y0 = y - boxH;
        final key = availableSparks[idx];
        final st = report.statFor(key)!;
        fillRect(x0, y0, boxW, boxH, '0.97 0.98 0.99');
        drawLine(x0, y0, x0 + boxW, y0);
        drawLine(x0, y0 + boxH, x0 + boxW, y0 + boxH);
        drawText(
          x0 + 6,
          y0 + boxH - 11,
          '${st.label} (${_fmtNum(st.min)} .. ${_fmtNum(st.max)} ${st.unit})',
          size: 8.2,
          bold: true,
        );

        final pts = <({double t, double v})>[];
        for (int i = 0; i < ds.records.length; i++) {
          final v = ds.records[i][key];
          if (v != null && v.isFinite) pts.add((t: ds.times[i], v: v));
        }
        final down = _downsamplePoints(pts, 90);
        if (down.length >= 2) {
          final tSpan = math.max(0.1, ds.maxTime - ds.minTime);
          final vSpan = math.max(1e-4, st.max - st.min);
          final path = StringBuffer();
          for (int j = 0; j < down.length; j++) {
            final px = x0 + 6 + ((down[j].t - ds.minTime) / tSpan) * (boxW - 12);
            final py = y0 + 6 + ((down[j].v - st.min) / vSpan) * (boxH - 22);
            path.write(
              '${px.toStringAsFixed(1)} ${py.toStringAsFixed(1)} ${j == 0 ? 'm' : 'l'} ',
            );
          }
          current.writeln('1.1 w 0.05 0.45 0.72 RG $path S');
        }
      }
      y -= boxH + 22;
    }

    // Tabela de estatísticas por canal com paginação automática
    void drawStatsHeader() {
      drawText(36, y, 'Estatisticas por Canal', size: 11.5, bold: true, rgb: '0.05 0.35 0.58');
      y -= 14;
      fillRect(36, y - 4, 523, 16, '0.12 0.16 0.23');
      drawText(42, y, 'Canal', size: 8.5, bold: true, rgb: '1 1 1');
      drawText(235, y, 'Unid', size: 8.5, bold: true, rgb: '1 1 1');
      drawText(290, y, 'Minimo', size: 8.5, bold: true, rgb: '1 1 1');
      drawText(360, y, 'Media', size: 8.5, bold: true, rgb: '1 1 1');
      drawText(430, y, 'Maximo', size: 8.5, bold: true, rgb: '1 1 1');
      drawText(500, y, 'Ultimo', size: 8.5, bold: true, rgb: '1 1 1');
      y -= 16;
    }

    drawStatsHeader();
    for (int i = 0; i < report.stats.length; i++) {
      if (y < 60) {
        newPage();
        drawStatsHeader();
      }
      final s = report.stats[i];
      if (i.isOdd) fillRect(36, y - 3, 523, 13, '0.96 0.97 0.98');
      final shortLabel = s.label.length > 34 ? '${s.label.substring(0, 32)}..' : s.label;
      drawText(42, y, shortLabel, size: 8.5);
      drawText(235, y, s.unit.isEmpty ? '-' : s.unit, size: 8.5);
      drawText(290, y, _fmtNum(s.min), size: 8.5);
      drawText(360, y, _fmtNum(s.avg), size: 8.5);
      drawText(430, y, _fmtNum(s.max), size: 8.5);
      drawText(500, y, _fmtNum(s.last), size: 8.5);
      drawLine(36, y - 3, 559, y - 3, width: 0.3);
      y -= 14;
    }

    // Eventos diagnósticos
    y -= 10;
    if (y < 90) newPage();
    drawText(36, y, 'Eventos e Anomalias (${ds.events.length})', size: 11.5, bold: true, rgb: '0.05 0.35 0.58');
    y -= 15;
    if (ds.events.isEmpty) {
      drawText(42, y, 'Nenhum evento diagnostico registrado.', size: 9);
    } else {
      for (final ev in ds.events) {
        if (y < 52) newPage();
        final line = '${ev.timeSec.toStringAsFixed(2)}s  -  ${ev.text}';
        drawText(
          42,
          y,
          line.length > 92 ? '${line.substring(0, 90)}..' : line,
          size: 8.5,
        );
        y -= 13;
      }
    }

    if (current.isNotEmpty) {
      pages.add(current.toString());
    }

    return _PdfBuilder.build(pages);
  }

  // Helpers compartillhados ---------------------------------------------------
  static List<({double t, double v})> _downsamplePoints(
    List<({double t, double v})> pts,
    int maxPoints,
  ) {
    if (pts.length <= maxPoints) return pts;
    final out = <({double t, double v})>[pts.first];
    final step = (pts.length - 2) / (maxPoints - 2);
    for (int i = 1; i < maxPoints - 1; i++) {
      final idx = (i * step).round().clamp(1, pts.length - 2);
      out.add(pts[idx]);
    }
    out.add(pts.last);
    return out;
  }

  static double _round4(double v) => (v * 10000.0).roundToDouble() / 10000.0;

  static String _fmtNum(double v) {
    if (v.abs() >= 1000) return v.toStringAsFixed(0);
    if (v.abs() >= 100) return v.toStringAsFixed(1);
    return v.toStringAsFixed(2);
  }

  static String _fmtDuration(double sec) {
    final s = sec.round();
    final min = s ~/ 60;
    final rem = s % 60;
    return min > 0 ? '${min}m ${rem.toString().padLeft(2, '0')}s' : '${rem}s';
  }

  static String _svgColorForKey(String key) => switch (key) {
        'rpm' => '#00D2FF',
        'speed' => '#38BDF8',
        'map' || 'boost_bar' => '#F97316',
        'ect' || 'cht_c' => '#FF5252',
        'lambda_v' || 'lambda2_v' => '#00E676',
        'stft' || 'ltft' || 'lambda_trim' => '#FFB300',
        'advance' => '#A855F7',
        'battery' => '#FACC15',
        _ => '#00D2FF',
      };

  static String _escHtml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');

  static String _escXml(String s) {
    final clean = StringBuffer();
    for (final code in s.runes) {
      if (code == 0x09 ||
          code == 0x0A ||
          code == 0x0D ||
          (code >= 0x20 && code <= 0xD7FF) ||
          (code >= 0xE000 && code <= 0xFFFD)) {
        switch (code) {
          case 0x26:
            clean.write('&amp;');
          case 0x3C:
            clean.write('&lt;');
          case 0x3E:
            clean.write('&gt;');
          case 0x22:
            clean.write('&quot;');
          case 0x27:
            clean.write('&apos;');
          default:
            clean.writeCharCode(code);
        }
      }
    }
    return clean.toString();
  }

  static String _pdfEsc(String s) {
    final buf = StringBuffer();
    for (final rune in s.runes) {
      int code = rune;
      if (code > 255) {
        code = 0x3F; // '?' fallback para caracteres fora de Latin-1 WinAnsi
      }
      if (code == 0x28 || code == 0x29 || code == 0x5C) {
        buf.write('\\');
        buf.writeCharCode(code);
      } else if (code >= 0x20 && code <= 0x7E) {
        buf.writeCharCode(code);
      } else if (code >= 0xA0 && code <= 0xFF) {
        buf.write('\\${code.toRadixString(8).padLeft(3, '0')}');
      }
    }
    return buf.toString();
  }
}

/// Construtor ZIP compatível com PKZIP 2.0 usando DEFLATE bruto (RFC-1951).
class _ZipWriter {
  static final List<int> _crcTable = _makeCrcTable();

  static List<int> _makeCrcTable() {
    final table = List<int>.filled(256, 0);
    for (int n = 0; n < 256; n++) {
      int c = n;
      for (int k = 0; k < 8; k++) {
        c = ((c & 1) != 0) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[n] = c & 0xFFFFFFFF;
    }
    return table;
  }

  static int _crc32(List<int> data) {
    int crc = 0xFFFFFFFF;
    for (final b in data) {
      crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }

  static Uint8List build(List<({String name, List<int> data})> entries) {
    final out = BytesBuilder(copy: false);
    final central = BytesBuilder(copy: false);
    final deflate = ZLibCodec(raw: true);

    for (final entry in entries) {
      final nameBytes = utf8.encode(entry.name);
      final raw = entry.data;
      final compressed = deflate.encode(raw);
      final crc = _crc32(raw);
      final offset = out.length;

      // Local File Header (30 bytes + name)
      out.add(_u32(0x04034B50));
      out.add(_u16(20)); // version needed 2.0
      out.add(_u16(0x0800)); // UTF-8 filename flag
      out.add(_u16(8)); // DEFLATE
      out.add(_u16(0)); // mod time
      out.add(_u16(0)); // mod date
      out.add(_u32(crc));
      out.add(_u32(compressed.length));
      out.add(_u32(raw.length));
      out.add(_u16(nameBytes.length));
      out.add(_u16(0)); // extra len
      out.add(nameBytes);
      out.add(compressed);

      // Central Directory Header (46 bytes + name)
      central.add(_u32(0x02014B50));
      central.add(_u16(20));
      central.add(_u16(20));
      central.add(_u16(0x0800));
      central.add(_u16(8));
      central.add(_u16(0));
      central.add(_u16(0));
      central.add(_u32(crc));
      central.add(_u32(compressed.length));
      central.add(_u32(raw.length));
      central.add(_u16(nameBytes.length));
      central.add(_u16(0));
      central.add(_u16(0));
      central.add(_u16(0));
      central.add(_u16(0));
      central.add(_u32(0));
      central.add(_u32(offset));
      central.add(nameBytes);
    }

    final cdOffset = out.length;
    final cdBytes = central.toBytes();
    out.add(cdBytes);

    // End of Central Directory Record (22 bytes)
    out.add(_u32(0x06054B50));
    out.add(_u16(0));
    out.add(_u16(0));
    out.add(_u16(entries.length));
    out.add(_u16(entries.length));
    out.add(_u32(cdBytes.length));
    out.add(_u32(cdOffset));
    out.add(_u16(0));

    return out.toBytes();
  }

  static Uint8List _u16(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);

  static Uint8List _u32(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
}

/// Construtor mínimo PDF 1.4 multi-página com xref exato.
class _PdfBuilder {
  static Uint8List build(List<String> pageContents) {
    final objs = <int, String>{};
    // 1: Catalog, 2: Pages, 3: F1 Helvetica, 4: F2 Helvetica-Bold
    final pageIds = <int>[];
    int nextId = 5;
    for (int i = 0; i < pageContents.length; i++) {
      final contentId = nextId++;
      final pageId = nextId++;
      pageIds.add(pageId);
      final stream = pageContents[i];
      final streamBytes = latin1.encode(stream);
      objs[contentId] =
          '<< /Length ${streamBytes.length} >>\nstream\n$stream\nendstream';
      objs[pageId] =
          '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
          '/Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> '
          '/Contents $contentId 0 R >>';
    }

    objs[1] = '<< /Type /Catalog /Pages 2 0 R >>';
    objs[2] =
        '<< /Type /Pages /Kids [${pageIds.map((id) => '$id 0 R').join(' ')}] /Count ${pageIds.length} >>';
    objs[3] =
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>';
    objs[4] =
        '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>';

    final maxId = nextId - 1;
    final out = BytesBuilder(copy: false);
    out.add(latin1.encode('%PDF-1.4\n%\xE2\xE3\xCF\xD3\n'));

    final offsets = List<int>.filled(maxId + 1, 0);
    for (int id = 1; id <= maxId; id++) {
      offsets[id] = out.length;
      out.add(latin1.encode('$id 0 obj\n${objs[id]}\nendobj\n'));
    }

    final xrefOffset = out.length;
    final xref = StringBuffer();
    xref.writeln('xref');
    xref.writeln('0 ${maxId + 1}');
    xref.writeln('0000000000 65535 f ');
    for (int id = 1; id <= maxId; id++) {
      xref.writeln('${offsets[id].toString().padLeft(10, '0')} 00000 n ');
    }
    xref.writeln('trailer');
    xref.writeln('<< /Size ${maxId + 1} /Root 1 0 R >>');
    xref.writeln('startxref');
    xref.writeln('$xrefOffset');
    xref.writeln('%%EOF');
    out.add(latin1.encode(xref.toString()));

    return out.toBytes();
  }
}
