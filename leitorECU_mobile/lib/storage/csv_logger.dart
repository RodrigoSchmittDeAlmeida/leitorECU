import 'dart:convert';
import 'dart:io';

import 'package:leitorecu_mobile/core/models/channel_def.dart';

import 'csv_replay_parser.dart';

/// Gravador de logs CSV compatível com Excel pt-BR (UTF-8 com BOM `\uFEFF`, `;`, vírgula decimal)
/// e paridade de cabeçalho com o `leitorECU` Desktop.
class CsvLogger {
  static const List<String> _baseCols = ['timestamp_ms', 'tempo_s', 'atualizado'];

  /// Canais extras Ford HS-CAN pré-registrados para paridade com o formato PC.
  static const Map<String, (String, String)> fordExtraChannels = {
    'door_fl': ('Porta Diant. Esq. (Motorista)', '0/1'),
    'door_fr': ('Porta Diant. Dir. (Passageiro)', '0/1'),
    'door_rl': ('Porta Tras. Esq.', '0/1'),
    'door_rr': ('Porta Tras. Dir.', '0/1'),
    'door_trunk': ('Porta-Malas (Sedan)', '0/1'),
    'door_hood': ('Capô do Motor', '0/1'),
    'central_lock': ('Travas Elétricas (Trancado)', '0/1'),
    'low_beam': ('Farol Baixo', '0/1'),
    'high_beam': ('Farol Alto', '0/1'),
    'fog_lights': ('Faróis de Neblina', '0/1'),
    'parking_lights': ('Lanternas', '0/1'),
    'turn_left': ('Seta Esquerda', '0/1'),
    'turn_right': ('Seta Direita', '0/1'),
    'hazard_lights': ('Pisca-Alerta', '0/1'),
    'wiper_status': ('Limpador Para-brisa', 'modo'),
    'rear_defrost': ('Desembaçador Traseiro', '0/1'),
    'ignition_pos': ('Posição da Ignição', 'pos'),
    'alarm_armed': ('Alarme Perimétrico', '0/1'),
    'bcm_battery_v': ('Tensão Bateria (BCM)', 'V'),
    'wheel_speed_fl': ('Velocidade Roda Diant. Esq.', 'km/h'),
    'wheel_speed_fr': ('Velocidade Roda Diant. Dir.', 'km/h'),
    'wheel_speed_rl': ('Velocidade Roda Tras. Esq.', 'km/h'),
    'wheel_speed_rr': ('Velocidade Roda Tras. Dir.', 'km/h'),
    'brake_pressure': ('Pressão do Freio', 'bar'),
    'brake_pedal_sw': ('Interruptor Freio', '0/1'),
    'esc_active': ('Intervenção ESC/ABS', '0/1'),
    'steering_angle_abs': ('Ângulo Esterçamento (SAS)', '°'),
    'cht_temp': ('Temp. Cabeça Cilindro (CHT)', '°C'),
    'fan_duty_pct': ('Eletroventilador Radiador', '%'),
    'ac_pressure_kpa': ('Pressão Refrigerante A/C', 'kPa'),
    'ac_clutch': ('Embreagem Compressor A/C', '0/1'),
    'odometer_km': ('Odômetro Total', 'km'),
    'fuel_level_pct': ('Nível de Combustível', '%'),
    'ext_temp': ('Temperatura Externa', '°C'),
    'seatbelt_warning': ('Alerta Cinto Segurança', '0/1'),
    'parking_brake': ('Freio de Mão', '0/1'),
    'steering_wheel_angle': ('Ângulo Volante EPAS', '°'),
    'steering_driver_torque': ('Torque Aplicado Volante', 'Nm'),
    'steering_motor_current': ('Corrente Motor Direção', 'A'),
  };

  final bool decimalComma;
  final bool preRegisterKnownExtras;

  RandomAccessFile? _raf;
  String path = '';
  int rows = 0;
  DateTime _lastFlush = DateTime.fromMillisecondsSinceEpoch(0);
  final List<String> extraCols = [];
  final Map<String, String> extraLabels = {};

  CsvLogger({
    this.decimalComma = true,
    this.preRegisterKnownExtras = true,
  });

  bool get active => _raf != null;

  static String formatExtraHeader(String label, String unit) {
    final l = label.trim();
    final u = unit.trim();
    if (u.isEmpty || l.endsWith('[$u]')) return l;
    return '$l [$u]';
  }

  static Map<String, String> defaultExtraHeaders() {
    final map = <String, String>{};
    for (final e in dynamicChannelInfo.entries) {
      if (!coreChannels.containsKey(e.key)) {
        map[e.key] = formatExtraHeader(e.value.$1, e.value.$2);
      }
    }
    for (final e in fordExtraChannels.entries) {
      if (!coreChannels.containsKey(e.key) && !map.containsKey(e.key)) {
        map[e.key] = formatExtraHeader(e.value.$1, e.value.$2);
      }
    }
    return map;
  }

  List<String> _header() {
    return [
      ..._baseCols,
      ...coreChannels.keys,
      for (final k in extraCols) extraLabels[k] ?? k,
      'evento',
    ];
  }

  /// Inicia gravação de um novo arquivo CSV (cria diretório pai se necessário).
  void start(String filePath, {Map<String, String>? extra}) {
    stop();
    extraCols.clear();
    extraLabels.clear();

    if (preRegisterKnownExtras) {
      for (final entry in defaultExtraHeaders().entries) {
        if (!coreChannels.containsKey(entry.key) &&
            !extraLabels.containsKey(entry.key)) {
          extraCols.add(entry.key);
          extraLabels[entry.key] = entry.value;
        }
      }
    }

    if (extra != null) {
      for (final entry in extra.entries) {
        if (coreChannels.containsKey(entry.key)) continue;
        if (!extraLabels.containsKey(entry.key)) {
          extraCols.add(entry.key);
        }
        extraLabels[entry.key] = entry.value;
      }
    }

    try {
      final file = File(filePath);
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      _raf = file.openSync(mode: FileMode.write);
      // BOM UTF-8 (\uFEFF) para abertura direta com acentos no Excel pt-BR
      _raf!.writeFromSync(const [0xEF, 0xBB, 0xBF]);
      _writeRowSync(_header());
      _raf!.flushSync();
      path = filePath;
      rows = 0;
      _lastFlush = DateTime.now();
    } catch (_) {
      _closeRafSafely();
    }
  }

  /// Registra colunas dinâmicas novas `{chave: cabeçalho}` durante ou antes da gravação.
  void addColumns(Map<String, String> cols) {
    final newCols = <String>[];
    var relabel = false;

    for (final entry in cols.entries) {
      final k = entry.key;
      final v = entry.value;
      if (coreChannels.containsKey(k)) continue;
      if (!extraLabels.containsKey(k)) {
        newCols.add(k);
        extraLabels[k] = v;
      } else if (extraLabels[k] != v) {
        extraLabels[k] = v;
        relabel = true;
      }
    }

    if (!active) {
      extraCols.addAll(newCols);
      return;
    }

    if (newCols.isNotEmpty || relabel) {
      _rewrite(newCols);
    }
  }

  void _rewrite(List<String> newCols) {
    if (_raf == null || path.isEmpty) return;
    try {
      _raf!.flushSync();
      _raf!.closeSync();
    } catch (_) {}
    _raf = null;

    final insertAt = _baseCols.length + coreChannels.length + extraCols.length;
    final tmpPath = '$path.tmp';

    try {
      final rawBytes = File(path).readAsBytesSync();
      var text = utf8.decode(rawBytes, allowMalformed: true);
      if (text.startsWith('\uFEFF')) {
        text = text.substring(1);
      }
      final lines = text
          .split(RegExp(r'\r\n|\n|\r'))
          .where((l) => l.isNotEmpty)
          .toList();

      extraCols.addAll(newCols);
      final pad = List<String>.filled(newCols.length, '');

      final tmpFile = File(tmpPath);
      final outRaf = tmpFile.openSync(mode: FileMode.write);
      try {
        outRaf.writeFromSync(const [0xEF, 0xBB, 0xBF]);
        outRaf.writeStringSync('${_encodeCsvRow(_header())}\r\n', encoding: utf8);
        for (var i = 1; i < lines.length; i++) {
          final cells = lines[i].split(';');
          final safeInsert = insertAt <= cells.length ? insertAt : cells.length;
          final updatedCells = <String>[
            ...cells.sublist(0, safeInsert),
            ...pad,
            ...cells.sublist(safeInsert),
          ];
          outRaf.writeStringSync('${updatedCells.join(';')}\r\n', encoding: utf8);
        }
        outRaf.flushSync();
      } finally {
        outRaf.closeSync();
      }

      _replaceFileSafely(tmpFile, File(path));
      _raf = File(path).openSync(mode: FileMode.append);
    } catch (_) {
      // Nunca deixa o gravador crashar; reabre em modo append se possível
      try {
        if (File(path).existsSync()) {
          _raf = File(path).openSync(mode: FileMode.append);
        }
      } catch (_) {}
    }
  }

  void _replaceFileSafely(File tmpFile, File targetFile) {
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        tmpFile.renameSync(targetFile.path);
        return;
      } catch (_) {
        if (attempt == 4) {
          try {
            tmpFile.copySync(targetFile.path);
            tmpFile.deleteSync();
          } catch (_) {}
          return;
        }
        sleep(const Duration(milliseconds: 25));
      }
    }
  }

  /// Grava uma linha de telemetria contendo exclusivamente valores numéricos `double`.
  void write(
    double wallMs,
    double tRel,
    String updated,
    Map<String, double> latest, {
    String event = '',
  }) {
    if (_raf == null) return;

    try {
      final unknown = <String, String>{};
      for (final k in latest.keys) {
        if (!coreChannels.containsKey(k) && !extraLabels.containsKey(k)) {
          unknown[k] = k;
        }
      }
      if (unknown.isNotEmpty) {
        addColumns(unknown);
      }
      if (_raf == null) return;

      final row = <String>[
        wallMs.isFinite ? wallMs.toStringAsFixed(0) : '0',
        _formatNum(tRel),
        _sanitizeCell(updated),
      ];

      for (final k in coreChannels.keys) {
        final v = latest[k];
        row.add(v == null ? '' : _formatNum(v));
      }
      for (final k in extraCols) {
        final v = latest[k];
        row.add(v == null ? '' : _formatNum(v));
      }
      row.add(_sanitizeCell(event));

      _writeRowSync(row);
      rows++;

      final now = DateTime.now();
      if (now.difference(_lastFlush).inMilliseconds >= 500) {
        _raf!.flushSync();
        _lastFlush = now;
      }
    } catch (_) {
      // Nunca propaga exceção de I/O durante aquisição contínua
    }
  }

  void stop() {
    _closeRafSafely();
  }

  void _closeRafSafely() {
    if (_raf != null) {
      try {
        _raf!.flushSync();
      } catch (_) {}
      try {
        _raf!.closeSync();
      } catch (_) {}
    }
    _raf = null;
  }

  String _formatNum(double x) {
    if (!x.isFinite) return '';
    final s = x.toStringAsFixed(3);
    return decimalComma ? s.replaceAll('.', ',') : s;
  }

  static String _sanitizeCell(String s) {
    if (s.isEmpty) return '';
    return s
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ')
        .replaceAll(';', ',');
  }

  String _encodeCsvRow(List<String> cells) =>
      cells.map(_sanitizeCell).join(';');

  void _writeRowSync(List<String> cells) {
    _raf?.writeStringSync('${_encodeCsvRow(cells)}\r\n', encoding: utf8);
  }
}

/// Buffer circular de séries temporais com busca binária por janela de tempo.
class SeriesBuffer {
  final int capacity;
  final List<double> _times = [];
  final List<double> _values = [];

  SeriesBuffer({this.capacity = 40000});

  int get length => _times.length;
  bool get isEmpty => _times.isEmpty;
  bool get isNotEmpty => _times.isNotEmpty;

  List<double> get times => List.unmodifiable(_times);
  List<double> get values => List.unmodifiable(_values);

  void append(double t, double v) {
    if (!t.isFinite || !v.isFinite) return;
    if (_times.length >= capacity) {
      final keep = capacity ~/ 2;
      _times.removeRange(0, _times.length - keep);
      _values.removeRange(0, _values.length - keep);
    }
    _times.add(t);
    _values.add(v);
  }

  /// Retorna fatia a partir de [tFrom] usando busca binária.
  ({List<double> times, List<double> values}) window(double tFrom) {
    if (_times.isEmpty) {
      return (times: const [], values: const []);
    }
    var lo = 0;
    var hi = _times.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_times[mid] < tFrom) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return (
      times: _times.sublist(lo),
      values: _values.sublist(lo),
    );
  }

  void clear() {
    _times.clear();
    _values.clear();
  }
}

/// Exportador para o formato padrão `.msl` do MegaLogViewer HD / TunerStudio
/// (delimitado por tabulação `\t` e ponto decimal `.`).
class MegaLogViewerExporter {
  static const Map<String, String> mlvColumnMap = {
    'tempo_s': 'Time',
    'rpm': 'RPM',
    'map': 'MAP',
    'tps': 'TPS',
    'advance': 'Advance',
    'lambda_v': 'O2_Volts',
    'lambda2_v': 'O2_Volts_Post',
    'lambda_eq': 'Lambda',
    'stft': 'Fuel_Trim_Short',
    'ltft': 'Fuel_Trim_Long',
    'ect': 'CLT',
    'iat': 'MAT',
    'speed': 'Speed_kmh',
    'battery': 'Batt_V',
    'power_hp': 'Power_HP',
    'torque_kgfm': 'Torque_kgfm',
    'fuel_rate_lph': 'Fuel_Flow_LPH',
    'trip_liters': 'Trip_Fuel_Liters',
    'trip_km': 'Trip_Distance_km',
    'volumetric_eff': 'VE',
    'boost_bar': 'Boost',
    'boost_psi': 'Boost_psi',
    'baro': 'Baro',
    'wastegate_pct': 'Wastegate_Duty',
    'fuel_rail_bar': 'Fuel_Rail_Pressure',
    'knock_retard_max': 'Knock_Retard',
    'cac_temp_c': 'CAC_Temp',
    'oil_temp': 'Oil_Temp',
    'evento': 'Marker',
  };

  static Future<bool> exportFromCsv(String srcCsvPath, String dstMslPath) async {
    return exportFromCsvSync(srcCsvPath, dstMslPath);
  }

  static bool exportFromCsvSync(String srcCsvPath, String dstMslPath) {
    try {
      final bytes = File(srcCsvPath).readAsBytesSync();
      var text = utf8.decode(bytes, allowMalformed: true);
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
      if (lines.isEmpty) return false;

      final delim = lines.first.contains(';') ? ';' : ',';
      final rawHeader = lines.first.split(delim);
      final outHeader =
          rawHeader.map((col) => mlvColumnMap[col.trim()] ?? col.trim()).toList();

      final outBuf = StringBuffer()..writeln(outHeader.join('\t'));
      for (var i = 1; i < lines.length; i++) {
        final cells = lines[i].split(delim);
        final converted = cells.map((c) => c.replaceAll(',', '.')).join('\t');
        outBuf.writeln(converted);
      }

      final outFile = File(dstMslPath);
      if (!outFile.parent.existsSync()) {
        outFile.parent.createSync(recursive: true);
      }
      outFile.writeAsStringSync(outBuf.toString(), encoding: utf8);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> exportFromReplayDataset(
    ReplayDataset dataset,
    String dstMslPath,
  ) async {
    try {
      final cols = dataset.availableChannels;
      final outHeader = [
        'Time',
        for (final c in cols) mlvColumnMap[c] ?? c,
        'Marker',
      ];
      final eventsByTime = <double, List<String>>{};
      for (final ev in dataset.events) {
        eventsByTime.putIfAbsent(ev.timeSec, () => []).add(ev.text);
      }

      final outBuf = StringBuffer()..writeln(outHeader.join('\t'));
      for (var i = 0; i < dataset.records.length; i++) {
        final t = dataset.times[i];
        final rec = dataset.records[i];
        final row = <String>[
          t.toStringAsFixed(3),
          for (final c in cols)
            rec[c] != null ? rec[c]!.toStringAsFixed(3) : '',
          (eventsByTime[t] ?? const []).join(' | '),
        ];
        outBuf.writeln(row.join('\t'));
      }

      final outFile = File(dstMslPath);
      if (!outFile.parent.existsSync()) {
        outFile.parent.createSync(recursive: true);
      }
      outFile.writeAsStringSync(outBuf.toString(), encoding: utf8);
      return true;
    } catch (_) {
      return false;
    }
  }
}
