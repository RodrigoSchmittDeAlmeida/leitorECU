import 'dart:convert';
import 'dart:io';

import 'package:leitorecu_mobile/core/models/channel_def.dart';

/// Evento registrado na coluna `evento` / `Marker` de um log CSV.
class ReplayEvent {
  final double timeSec;
  final String text;

  const ReplayEvent({required this.timeSec, required this.text});
}

/// Conjunto de dados decodificado de um arquivo CSV (Desktop PC ou Mobile).
class ReplayDataset {
  final List<String> availableChannels;
  final List<double> times;
  final List<Map<String, double>> records;
  final List<ReplayEvent> events;
  final bool isTurboDetected;

  const ReplayDataset({
    required this.availableChannels,
    required this.times,
    required this.records,
    required this.events,
    required this.isTurboDetected,
  });

  bool get isEmpty => records.isEmpty;
  int get length => records.length;

  double get minTime => times.isEmpty ? 0.0 : times.first;
  double get maxTime => times.isEmpty ? 0.0 : times.last;
  double get durationSec =>
      times.length < 2 ? 0.0 : (times.last - times.first).clamp(0.0, double.infinity);

  /// Busca binária pelo índice mais próximo do instante [t].
  int indexForTime(double t) {
    if (times.isEmpty) return -1;
    if (t <= times.first) return 0;
    if (t >= times.last) return times.length - 1;
    var lo = 0;
    var hi = times.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final mt = times[mid];
      if (mt == t) return mid;
      if (mt < t) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (lo >= times.length) return times.length - 1;
    if (lo == 0) return 0;
    return (t - times[lo - 1]).abs() <= (times[lo] - t).abs() ? lo - 1 : lo;
  }
}

/// Parser unificado de logs CSV do `leitorECU` Desktop (PC) e Mobile.
///
/// Suporta UTF-8 com ou sem BOM (`\uFEFF`), delimitador `;` ou `,`,
/// decimais com vírgula ou ponto, cabeçalhos canônicos ou descritivos e coluna `evento`.
class CsvReplayParser {
  static final RegExp _vagBlockHeaderRe = RegExp(r'^bloco\s+(\d{3})\.(\d+)');

  static Future<ReplayDataset> parseFile(String path) async {
    final bytes = await File(path).readAsBytes();
    final content = utf8.decode(bytes, allowMalformed: true);
    return parseString(content);
  }

  static ReplayDataset parseFileSync(String path) {
    final bytes = File(path).readAsBytesSync();
    final content = utf8.decode(bytes, allowMalformed: true);
    return parseString(content);
  }

  static ReplayDataset parseString(String content) {
    if (content.isEmpty) {
      return const ReplayDataset(
        availableChannels: [],
        times: [],
        records: [],
        events: [],
        isTurboDetected: false,
      );
    }

    var text = content;
    if (text.startsWith('\uFEFF')) {
      text = text.substring(1);
    }

    final lines = text
        .split(RegExp(r'\r\n|\n|\r'))
        .where((l) {
          final t = l.trim();
          return t.isNotEmpty && !t.startsWith('#');
        })
        .toList();

    if (lines.length < 2) {
      return const ReplayDataset(
        availableChannels: [],
        times: [],
        records: [],
        events: [],
        isTurboDetected: false,
      );
    }

    final delimiter = lines.first.contains(';') ? ';' : ',';
    final header = _splitCsvLine(lines.first, delimiter);
    final hNorm = header.map((c) => c.trim().toLowerCase()).toList();

    // Localiza coluna de tempo (tempo_s / time / t_s) e coluna de evento
    var tCol = -1;
    for (final cand in const ['tempo_s', 't_s', 'time_s', 'timestamp_s', 'time']) {
      final idx = hNorm.indexOf(cand);
      if (idx != -1) {
        tCol = idx;
        break;
      }
    }
    if (tCol == -1 && hNorm.length > 1) {
      tCol = 1;
    }

    var eventCol = -1;
    for (final cand in const ['evento', 'marker', 'event']) {
      final idx = hNorm.indexOf(cand);
      if (idx != -1) {
        eventCol = idx;
        break;
      }
    }

    final colKeys = _mapHeaderColumns(hNorm, tCol, eventCol);

    final times = <double>[];
    final records = <Map<String, double>>[];
    final events = <ReplayEvent>[];
    final presentChannels = <String>{};
    var maxMap = double.negativeInfinity;
    var maxBoostBar = double.negativeInfinity;
    var hasTurboSignal = false;

    for (var rowIdx = 1; rowIdx < lines.length; rowIdx++) {
      final row = _splitCsvLine(lines[rowIdx], delimiter);
      if (row.isEmpty || tCol < 0 || row.length <= tCol) continue;

      final tVal = _parseDouble(row[tCol]);
      if (tVal == null || !tVal.isFinite) continue;

      final record = <String, double>{};
      for (final entry in colKeys.entries) {
        final colIdx = entry.key;
        if (colIdx >= row.length) continue;
        final val = _parseDouble(row[colIdx]);
        if (val != null && val.isFinite) {
          record[entry.value] = val;
          presentChannels.add(entry.value);
        }
      }

      if (eventCol != -1 && eventCol < row.length) {
        final evText = row[eventCol].trim();
        if (evText.isNotEmpty) {
          events.add(ReplayEvent(timeSec: tVal, text: evText));
        }
      }

      final mapVal = record['map'];
      if (mapVal != null && mapVal > maxMap) maxMap = mapVal;
      final boostVal = record['boost_bar'];
      if (boostVal != null && boostVal > maxBoostBar) maxBoostBar = boostVal;
      if ((record['wastegate_pct'] ?? 0.0) > 0.0 ||
          (record['boost_target_bar'] ?? 0.0) > 0.05 ||
          (record['fuel_rail_bar'] ?? 0.0) > 10.0) {
        hasTurboSignal = true;
      }

      times.add(tVal);
      records.add(record);
    }

    final isTurboDetected =
        maxMap > 105.0 || maxBoostBar > 0.08 || hasTurboSignal;

    // Preserva a ordem canônica primeiro e depois canais dinâmicos presentes
    final orderedChannels = <String>[
      for (final k in coreChannels.keys)
        if (presentChannels.contains(k)) k,
      for (final k in presentChannels)
        if (!coreChannels.containsKey(k)) k,
    ];

    return ReplayDataset(
      availableChannels: orderedChannels,
      times: times,
      records: records,
      events: events,
      isTurboDetected: isTurboDetected,
    );
  }

  static Map<int, String> _mapHeaderColumns(
    List<String> hNorm,
    int tCol,
    int eventCol,
  ) {
    final colKeys = <int, String>{};
    final claimedCanonical = <String>{};

    // Constrói índice reverso de dynamicChannelInfo (rótulo -> chave)
    final dynamicByLabel = <String, String>{};
    for (final e in dynamicChannelInfo.entries) {
      dynamicByLabel[e.value.$1.toLowerCase().trim()] = e.key;
    }

    // Passo 1: chaves exatas (coreChannels, dynamicChannelInfo, gGGG_cN) e blocos VAG
    for (var i = 0; i < hNorm.length; i++) {
      if (i == tCol || i == eventCol) continue;
      final col = hNorm[i];
      if (col == 'timestamp_ms' || col == 'atualizado') continue;

      final cleanK = col.split('[').first.split('(').first.trim();
      if (coreChannels.containsKey(cleanK) ||
          dynamicChannelInfo.containsKey(cleanK) ||
          RegExp(r'^g\d{3}_c\d+$').hasMatch(cleanK)) {
        colKeys[i] = cleanK;
        claimedCanonical.add(cleanK);
        continue;
      }

      final blockMatch = _vagBlockHeaderRe.firstMatch(col);
      if (blockMatch != null) {
        final key = 'g${blockMatch.group(1)}_c${blockMatch.group(2)}';
        colKeys[i] = key;
        claimedCanonical.add(key);
        continue;
      }
    }

    // Passo 2: fallback para cabeçalhos descritivos (ex.: logs exportados / editados)
    for (var i = 0; i < hNorm.length; i++) {
      if (i == tCol || i == eventCol || colKeys.containsKey(i)) continue;
      final col = hNorm[i];
      if (col == 'timestamp_ms' || col == 'atualizado') continue;

      final beforeBracket = col.split('[').first.trim();
      final cleanK = beforeBracket.split('(').first.trim();

      final byDynLabel = dynamicByLabel[beforeBracket] ?? dynamicByLabel[cleanK];
      if (byDynLabel != null && !claimedCanonical.contains(byDynLabel)) {
        colKeys[i] = byDynLabel;
        claimedCanonical.add(byDynLabel);
        continue;
      }

      String? mapped;
      if (cleanK == 'rpm' || (cleanK.contains('rpm') && !claimedCanonical.contains('rpm'))) {
        mapped = 'rpm';
      } else if (cleanK == 'map' || (cleanK.contains('map') && !claimedCanonical.contains('map'))) {
        mapped = 'map';
      } else if (cleanK.contains('avanço') || cleanK.contains('avanco') || cleanK == 'advance') {
        mapped = 'advance';
      } else if (cleanK.contains('tps') || cleanK.contains('borboleta')) {
        mapped = 'tps';
      } else if (cleanK.contains('sonda 1') || cleanK == 'lambda_v' || cleanK == 'o2_volts') {
        mapped = 'lambda_v';
      } else if (cleanK.contains('sonda 2') || cleanK == 'lambda2_v' || cleanK == 'o2_volts_post') {
        mapped = 'lambda2_v';
      } else if (cleanK == 'stft' || cleanK == 'fuel_trim_short') {
        mapped = 'stft';
      } else if (cleanK == 'ltft' || cleanK == 'fuel_trim_long') {
        mapped = 'ltft';
      } else if (cleanK == 'ect' || cleanK == 'clt' || cleanK.contains('temp. motor')) {
        mapped = 'ect';
      } else if (cleanK == 'iat' || cleanK == 'mat' || cleanK.contains('temp. ar')) {
        mapped = 'iat';
      } else if (cleanK.contains('carga') || cleanK == 'load') {
        mapped = 'load';
      } else if (cleanK.contains('velocidade') || cleanK == 'speed' || cleanK == 'speed_kmh') {
        mapped = 'speed';
      } else if (cleanK.contains('bateria') || cleanK == 'battery' || cleanK == 'batt_v') {
        mapped = 'battery';
      } else if (cleanK == 'boost_bar' ||
          cleanK == 'boost' ||
          cleanK.contains('pressao turbo') ||
          cleanK.contains('pressão turbo')) {
        mapped = 'boost_bar';
      } else if (cleanK == 'boost_psi') {
        mapped = 'boost_psi';
      } else if (cleanK.contains('boost_target')) {
        mapped = 'boost_target_bar';
      } else if (cleanK.contains('wastegate') || cleanK.contains('n75')) {
        mapped = 'wastegate_pct';
      } else if (cleanK == 'lambda_eq' || cleanK.contains('wideband') || cleanK == 'lambda') {
        mapped = 'lambda_eq';
      } else if (cleanK.contains('fuel_rail') ||
          cleanK.contains('rail_bar') ||
          cleanK.contains('pressao rail') ||
          cleanK.contains('pressão rail')) {
        mapped = 'fuel_rail_bar';
      } else if (cleanK.contains('knock_retard') ||
          cleanK.contains('knock_ret') ||
          cleanK.contains('retardo detonacao') ||
          cleanK.contains('retardo detonação')) {
        mapped = 'knock_retard_max';
      } else if (cleanK.contains('cac_temp') || cleanK.contains('intercooler')) {
        mapped = 'cac_temp_c';
      } else if (cleanK.contains('oil_temp') ||
          cleanK.contains('temp. oleo') ||
          cleanK.contains('temp. óleo')) {
        mapped = 'oil_temp';
      } else if (cleanK.contains('tempo de injeção') || cleanK.contains('tempo de injecao')) {
        mapped = 'inj_ms';
      }

      if (mapped != null && !claimedCanonical.contains(mapped)) {
        colKeys[i] = mapped;
        claimedCanonical.add(mapped);
      } else {
        final fallback = cleanK.isEmpty ? 'col_$i' : cleanK;
        if (!claimedCanonical.contains(fallback)) {
          colKeys[i] = fallback;
          claimedCanonical.add(fallback);
        }
      }
    }

    return colKeys;
  }

  static double? _parseDouble(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return null;
    if (s.contains(',')) {
      s = s.replaceAll(',', '.');
    }
    return double.tryParse(s);
  }

  static List<String> _splitCsvLine(String line, String delimiter) {
    if (!line.contains('"')) {
      return line.split(delimiter);
    }
    final out = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == delimiter && !inQuotes) {
        out.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    out.add(buf.toString());
    return out;
  }
}
