import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'package:leitorecu_mobile/analytics/detector.dart';
import 'package:leitorecu_mobile/analytics/fuel_estimator.dart';
import 'package:leitorecu_mobile/analytics/math_channels.dart';
import 'package:leitorecu_mobile/analytics/performance_timer.dart';
import 'package:leitorecu_mobile/analytics/readiness_parser.dart';
import 'package:leitorecu_mobile/core/elm327/elm327_client.dart';
import 'package:leitorecu_mobile/core/models/channel_def.dart';
import 'package:leitorecu_mobile/core/models/vehicle_profile.dart';
import 'package:leitorecu_mobile/core/platform/background_service.dart';
import 'package:leitorecu_mobile/core/protocols/autodiscovery.dart';
import 'package:leitorecu_mobile/core/protocols/vehicle_strategy.dart';
import 'package:leitorecu_mobile/core/transports/ble_transport.dart';
import 'package:leitorecu_mobile/core/transports/mock_transport.dart';
import 'package:leitorecu_mobile/core/transports/obd_transport.dart';
import 'package:leitorecu_mobile/core/transports/tcp_transport.dart';
import 'package:leitorecu_mobile/storage/csv_logger.dart';
import 'package:leitorecu_mobile/storage/csv_replay_parser.dart';
import 'package:leitorecu_mobile/storage/log_repository.dart';

enum ConnectionStateKind { offline, connecting, ecuOff, error, connected }

enum Map2dStat { mean, min, max, count }

/// Grade bidimensional RPM x MAP (9x9 Aspirado `100..20 kPa` ou 10x9 Turbo `250..20 kPa`).
class Map2dAggregator {
  static const List<int> defaultRpmBins = [
    750,
    1200,
    1700,
    2200,
    2800,
    3400,
    4000,
    4700,
    5500,
  ];

  static const List<int> aspiratedMapBins = [
    100,
    90,
    80,
    70,
    60,
    50,
    40,
    30,
    20,
  ];

  static const List<int> turboMapBins = [
    250,
    220,
    190,
    160,
    130,
    100,
    80,
    60,
    40,
    20,
  ];

  static const List<String> supportedMetrics = [
    'advance',
    'stft',
    'lambda_v',
    'lambda_eq',
    'boost_bar',
    'wastegate_pct',
    'knock_retard_max',
    'ect',
    'iat',
  ];

  final List<int> rpmBins = List<int>.from(defaultRpmBins);
  List<int> _mapBins = List<int>.from(aspiratedMapBins);
  bool _isTurboScale = false;

  final Map<String, Map<int, _CellAccum>> _accum = {
    for (final m in supportedMetrics) m: <int, _CellAccum>{},
  };

  final List<({double rpm, double mapKpa, Map<String, double> values})>
      _history = [];

  (int row, int col)? lastActiveCell;

  List<int> get mapBins => List<int>.unmodifiable(_mapBins);
  bool get isTurboScale => _isTurboScale;
  int get rowCount => _mapBins.length;
  int get colCount => rpmBins.length;

  int _cellKey(int row, int col) => (row << 8) | col;

  static int _findNearestBin(double val, List<int> bins) {
    var bestIdx = 0;
    var bestDist = (val - bins[0]).abs();
    for (var i = 1; i < bins.length; i++) {
      final d = (val - bins[i]).abs();
      if (d < bestDist) {
        bestDist = d;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  void setScale(bool turbo) {
    if (_isTurboScale == turbo) return;
    _isTurboScale = turbo;
    _mapBins = List<int>.from(turbo ? turboMapBins : aspiratedMapBins);
    _recomputeFromHistory();
  }

  void addSample(double rpm, double mapKpa, Map<String, double> latest) {
    if (rpm <= 400.0 || mapKpa <= 5.0) return;

    if (mapKpa > 105.0 && !_isTurboScale) {
      setScale(true);
    }

    final snapshot = <String, double>{};
    for (final m in supportedMetrics) {
      final v = latest[m];
      if (v != null && v.isFinite) {
        snapshot[m] = v;
      }
    }
    _history.add((rpm: rpm, mapKpa: mapKpa, values: snapshot));
    if (_history.length > 50000) {
      _history.removeAt(0);
    }

    final r = _findNearestBin(mapKpa, _mapBins);
    final c = _findNearestBin(rpm, rpmBins);
    lastActiveCell = (r, c);
    final key = _cellKey(r, c);

    for (final entry in snapshot.entries) {
      final accMap = _accum[entry.key]!;
      final existing = accMap[key];
      if (existing == null) {
        accMap[key] = _CellAccum(entry.value);
      } else {
        existing.add(entry.value);
      }
    }
  }

  void _recomputeFromHistory() {
    for (final accMap in _accum.values) {
      accMap.clear();
    }
    lastActiveCell = null;
    for (final sample in _history) {
      final r = _findNearestBin(sample.mapKpa, _mapBins);
      final c = _findNearestBin(sample.rpm, rpmBins);
      lastActiveCell = (r, c);
      final key = _cellKey(r, c);
      for (final entry in sample.values.entries) {
        final accMap = _accum[entry.key]!;
        final existing = accMap[key];
        if (existing == null) {
          accMap[key] = _CellAccum(entry.value);
        } else {
          existing.add(entry.value);
        }
      }
    }
  }

  ({double mean, double min, double max, int count})? cellStats(
    int row,
    int col,
    String metric,
  ) {
    final acc = _accum[metric]?[_cellKey(row, col)];
    if (acc == null || acc.count == 0) return null;
    return (
      mean: acc.sum / acc.count,
      min: acc.min,
      max: acc.max,
      count: acc.count,
    );
  }

  double? cellValue(int row, int col, String metric, Map2dStat stat) {
    final stats = cellStats(row, col, metric);
    if (stats == null) return null;
    return switch (stat) {
      Map2dStat.mean => stats.mean,
      Map2dStat.min => stats.min,
      Map2dStat.max => stats.max,
      Map2dStat.count => stats.count.toDouble(),
    };
  }

  int cellCount(int row, int col, String metric) {
    return _accum[metric]?[_cellKey(row, col)]?.count ?? 0;
  }

  void clear() {
    for (final accMap in _accum.values) {
      accMap.clear();
    }
    _history.clear();
    lastActiveCell = null;
    if (_isTurboScale) {
      _isTurboScale = false;
      _mapBins = List<int>.from(aspiratedMapBins);
    }
  }

  String toCsv({
    String metric = 'advance',
    Map2dStat stat = Map2dStat.mean,
  }) {
    final buf = StringBuffer();
    buf.writeln(['MAP_kPa / RPM', ...rpmBins].join(';'));
    for (var r = 0; r < _mapBins.length; r++) {
      final rowCells = <String>['${_mapBins[r]} kPa'];
      for (var c = 0; c < rpmBins.length; c++) {
        final v = cellValue(r, c, metric, stat);
        if (v == null) {
          rowCells.add('');
        } else if (stat == Map2dStat.count) {
          rowCells.add(v.toInt().toString());
        } else {
          rowCells.add(v.toStringAsFixed(2).replaceAll('.', ','));
        }
      }
      buf.writeln(rowCells.join(';'));
    }
    return buf.toString();
  }
}

class _CellAccum {
  int count = 1;
  double sum;
  double min;
  double max;

  _CellAccum(double v)
      : sum = v,
        min = v,
        max = v;

  void add(double v) {
    count++;
    sum += v;
    if (v < min) min = v;
    if (v > max) max = v;
  }
}

/// Controlador reativo principal de telemetria, gravação, replay, diagnóstico e ciclo ELM327.
class TelemetryController extends ChangeNotifier implements StrategyContext {
  static const int maxConsecErrors = 12;
  static const int maxHistoryItems = 400;

  final LogRepository logRepository;
  final MathChannelsEngine mathEngine;
  final DecelDetector detector;
  final PerformanceTimer perfTimer;
  final Map2dAggregator map2d;
  final CsvLogger csvLogger;

  // Conexão e estado do protocolo
  ConnectionStateKind connectionState = ConnectionStateKind.offline;
  String statusMessage = 'Desconectado';
  TransportKind transportKind = TransportKind.demo;
  DemoProfile demoProfile = DemoProfile.golMe75;
  VehicleProfileId vehicleProfile = VehicleProfileId.auto;
  String wifiHost = '192.168.0.10';
  int wifiPort = 35000;
  String? bleAddress;
  String? bleDeviceName;

  String adapterVersion = '';
  String protocolModeName = '';
  bool isProtocolFallback = false;
  EcuMetadata ecuMetadata = const EcuMetadata();

  // Métricas de desempenho da comunicação e Power Latch
  double responsesPerSec = 0.0;
  double cyclesPerSec = 0.0;
  double latencyMs = 0.0;
  double? lastPowerLatchDurationSec;
  double currentTimeSec = 0.0;

  // Configurações de polling e UI
  bool decelMode = false;
  @override
  bool readExtras = true;
  @override
  bool backgroundScanEnabled = false;
  bool fastReply = false;
  bool rawLog = false;
  bool autoRecord = false;
  bool keepScreenOn = true;
  int plotWindowSec = 30;
  int pollDelayMs = 0;

  // Telemetria e buffers
  final Map<String, double> latest = <String, double>{};
  final Map<String, double> stamps = <String, double>{};
  final Map<String, double> peakMin = <String, double>{};
  final Map<String, double> peakMax = <String, double>{};
  final Map<String, (String, String)> knownChannels = <String, (String, String)>{};
  final Map<String, SeriesBuffer> buffers = <String, SeriesBuffer>{};

  final List<DiagnosticEvent> events = <DiagnosticEvent>[];
  final List<String> consoleLogs = <String>[];
  List<DtcItem> dtcs = <DtcItem>[];
  bool dtcMilOn = false;
  int dtcCount = 0;
  ReadinessReport? readinessReport;
  FreezeFrameData? freezeFrameData;
  String? lastInfoMessage;
  String? lastPerfEvent;

  // Estado de Replay CSV
  bool replayMode = false;
  ReplayDataset? replayDataset;
  String? replayFileName;
  double replayScrubTime = 0.0;
  Map<String, double> replayValues = <String, double>{};
  bool replayPlaying = false;
  double replaySpeed = 1.0; // 0.5, 1.0, 2.0, 4.0
  int replayCurrentIndex = 0;
  int get replayTotalSamples => replayDataset?.records.length ?? 0;
  String? replayActiveEventText;
  Timer? _replayTimer;
  double _replayClockSec = 0.0;
  final Map<String, ({List<double> times, List<double> values})>
      _replayChannelSeries = {};

  // Controle interno de loop assíncrono
  bool _running = false;
  bool _disposed = false;
  ObdTransport? _activeTransport;
  Elm327Client? _elm;
  VehicleStrategy? _strategy;
  Future<void>? _loopFuture;
  final Queue<String> _cmdQueue = Queue<String>();

  DateTime _t0 = DateTime.now();
  bool _ecuOnline = true;
  double _lastEcuOkSec = 0.0;
  bool _engineRunning = false;
  double? _engineStoppedSec;

  TelemetryController({
    LogRepository? logRepository,
    MathChannelsEngine? mathEngine,
    DecelDetector? detector,
    PerformanceTimer? perfTimer,
    Map2dAggregator? map2d,
    CsvLogger? csvLogger,
  })  : logRepository = logRepository ?? const LogRepository(),
        mathEngine = mathEngine ?? MathChannelsEngine(),
        detector = detector ?? DecelDetector(),
        perfTimer = perfTimer ?? PerformanceTimer(),
        map2d = map2d ?? Map2dAggregator(),
        csvLogger = csvLogger ?? CsvLogger();

  @override
  bool get isRunning => _running;

  bool get isConnected =>
      connectionState == ConnectionStateKind.connected ||
      connectionState == ConnectionStateKind.ecuOff;

  bool get isEcuOff => connectionState == ConnectionStateKind.ecuOff;

  bool get isRecording => csvLogger.active;
  String get recordingPath => csvLogger.path;
  int get recordingRows => csvLogger.rows;

  bool get isTurbo =>
      ecuMetadata.isTurbo ||
      (latest['map'] ?? 0.0) > 105.0 ||
      (latest['boost_bar'] ?? 0.0) > 0.08;

  double _elapsedSec() =>
      DateTime.now().difference(_t0).inMicroseconds / 1e6;

  // =========================================================================
  // Persistência de configurações e Wakelock (com proteção para testes)
  // =========================================================================

  Future<void> loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      wifiHost = prefs.getString('wifi_host') ?? wifiHost;
      wifiPort = prefs.getInt('wifi_port') ?? wifiPort;
      bleAddress = prefs.getString('ble_address') ?? bleAddress;
      bleDeviceName = prefs.getString('ble_name') ?? bleDeviceName;
      autoRecord = prefs.getBool('auto_record') ?? autoRecord;
      keepScreenOn = prefs.getBool('keep_screen_on') ?? keepScreenOn;
      readExtras = prefs.getBool('read_extras') ?? readExtras;
      fastReply = prefs.getBool('fast_reply') ?? fastReply;
      plotWindowSec = prefs.getInt('plot_window_sec') ?? plotWindowSec;

      final tIdx = prefs.getInt('transport_kind');
      if (tIdx != null && tIdx >= 0 && tIdx < TransportKind.values.length) {
        transportKind = TransportKind.values[tIdx];
      }
      final dIdx = prefs.getInt('demo_profile');
      if (dIdx != null && dIdx >= 0 && dIdx < DemoProfile.values.length) {
        demoProfile = DemoProfile.values[dIdx];
      }
      final vIdx = prefs.getInt('vehicle_profile');
      if (vIdx != null && vIdx >= 0 && vIdx < VehicleProfileId.values.length) {
        vehicleProfile = VehicleProfileId.values[vIdx];
      }
      _safeNotify();
    } catch (_) {
      // Ambiente de testes sem canal de plataforma SharedPreferences
    }
  }

  Future<void> saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('wifi_host', wifiHost);
      await prefs.setInt('wifi_port', wifiPort);
      if (bleAddress != null) await prefs.setString('ble_address', bleAddress!);
      if (bleDeviceName != null) await prefs.setString('ble_name', bleDeviceName!);
      await prefs.setBool('auto_record', autoRecord);
      await prefs.setBool('keep_screen_on', keepScreenOn);
      await prefs.setBool('read_extras', readExtras);
      await prefs.setBool('fast_reply', fastReply);
      await prefs.setInt('plot_window_sec', plotWindowSec);
      await prefs.setInt('transport_kind', transportKind.index);
      await prefs.setInt('demo_profile', demoProfile.index);
      await prefs.setInt('vehicle_profile', vehicleProfile.index);
    } catch (_) {
      // Ambiente de testes sem canal de plataforma
    }
  }

  Future<void> _setWakelock(bool enabled) async {
    try {
      if (enabled) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    } catch (_) {
      // Ignora em unit tests sem binding de plugin
    }
  }

  void setKeepScreenOn(bool enabled) {
    keepScreenOn = enabled;
    if (_running) {
      unawaited(_setWakelock(enabled));
    } else if (!enabled) {
      unawaited(_setWakelock(false));
    }
    saveSettings();
    _safeNotify();
  }

  void _syncBackgroundNotification({bool force = false}) {
    if (!_running && !isRecording) return;
    final rpmStr = latest.containsKey('rpm')
        ? '${latest['rpm']!.toStringAsFixed(0)} RPM'
        : '-- RPM';
    final ectVal = latest['ect'] ?? latest['cht_temp'];
    final ectStr = ectVal != null ? '${ectVal.toStringAsFixed(0)}°C' : '--°C';
    final title = isRecording
        ? 'leitorECU · Gravando (${csvLogger.rows} linhas)'
        : 'leitorECU · Telemetria Ativa';
    final text = _ecuOnline
        ? '$rpmStr · $ectStr · ${responsesPerSec.toStringAsFixed(1)} R/S (2º plano ativo)'
        : statusMessage;
    unawaited(
      TelemetryBackgroundService.update(
        title: title,
        text: text,
        force: force,
      ),
    );
  }

  void setTransportConfig({
    TransportKind? kind,
    DemoProfile? demo,
    VehicleProfileId? profile,
    String? host,
    int? port,
    String? bleAddr,
    String? bleName,
  }) {
    if (kind != null) transportKind = kind;
    if (demo != null) demoProfile = demo;
    if (profile != null) vehicleProfile = profile;
    if (host != null) wifiHost = host;
    if (port != null) wifiPort = port;
    if (bleAddr != null) bleAddress = bleAddr;
    if (bleName != null) bleDeviceName = bleName;
    saveSettings();
    _safeNotify();
  }

  // =========================================================================
  // Ciclo de vida da conexão e polling assíncrono
  // =========================================================================

  ObdTransport _buildTransport() {
    return switch (transportKind) {
      TransportKind.demo => MockTransport(
          profile: demoProfile,
          turboMode: demoProfile == DemoProfile.turboTsi,
        ),
      TransportKind.tcpWifi => TcpTransport(host: wifiHost, port: wifiPort),
      TransportKind.ble => BleTransport(
          bleAddress ?? '',
          log: emitLog,
        ),
    };
  }

  Future<void> connect({ObdTransport? transportOverride}) async {
    if (_running) {
      await disconnect();
    }
    if (replayMode) {
      exitReplayMode();
    } else {
      pauseReplay();
    }

    _t0 = DateTime.now();
    currentTimeSec = 0.0;
    _running = true;
    _ecuOnline = true;
    _lastEcuOkSec = 0.0;
    _engineRunning = false;
    _engineStoppedSec = null;
    lastPowerLatchDurationSec = null;
    adapterVersion = '';
    protocolModeName = '';
    isProtocolFallback = false;
    ecuMetadata = const EcuMetadata();
    responsesPerSec = 0.0;
    cyclesPerSec = 0.0;
    latencyMs = 0.0;
    _cmdQueue.clear();
    latest.clear();
    stamps.clear();
    peakMin.clear();
    peakMax.clear();
    knownChannels.clear();
    for (final buf in buffers.values) {
      buf.clear();
    }
    buffers.clear();
    mathEngine.resetTrip();
    detector.reset();
    perfTimer.reset();
    map2d.clear();

    connectionState = ConnectionStateKind.connecting;
    statusMessage = 'Iniciando conexão...';
    _safeNotify();

    if (keepScreenOn) {
      unawaited(_setWakelock(true));
    }
    unawaited(
      TelemetryBackgroundService.start(
        title: 'leitorECU · Conectando ECU',
        text: 'Serviço em segundo plano ativo (BLE/Wi-Fi + Logs)',
      ),
    );

    final transport = transportOverride ?? _buildTransport();
    _activeTransport = transport;
    _loopFuture = _connectionWorkerLoop(transport);
  }

  Future<void> disconnect() async {
    _running = false;
    _cmdQueue.clear();
    try {
      await _activeTransport?.close();
    } catch (_) {}
    final loop = _loopFuture;
    _loopFuture = null;
    if (loop != null) {
      try {
        await loop.timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    _activeTransport = null;
    _elm = null;
    if (isRecording) {
      await stopRecording();
    }
    unawaited(_setWakelock(false));
    unawaited(TelemetryBackgroundService.stop());
    connectionState = ConnectionStateKind.offline;
    statusMessage = 'Desconectado';
    responsesPerSec = 0.0;
    cyclesPerSec = 0.0;
    _safeNotify();
  }

  Future<void> _connectionWorkerLoop(ObdTransport transport) async {
    var attempt = 0;
    while (_running) {
      try {
        await _connectAndInitialize(transport);
        attempt = 0;
        if (autoRecord && !isRecording) {
          await startRecording();
        }
        await _pollLoop();
      } on TransportException catch (e) {
        if (!_running) break;
        attempt++;
        connectionState = ConnectionStateKind.error;
        statusMessage = '${e.message} — reconectando ($attempt)...';
        emitLog('!! ${e.message}');
      } catch (e) {
        if (!_running) break;
        attempt++;
        connectionState = ConnectionStateKind.error;
        statusMessage = 'Erro inesperado: $e — reconectando ($attempt)...';
        emitLog('!! Erro inesperado: $e');
      } finally {
        try {
          await transport.close();
        } catch (_) {}
      }

      if (!_running) break;
      final waitSteps = math.min(2 + attempt, 8) * 10;
      for (var i = 0; i < waitSteps && _running; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<void> _connectAndInitialize(ObdTransport transport) async {
    emitStatus('connecting', 'Conectando via ${transport.name}...');
    await transport.open();

    final elm = Elm327Client(transport, log: emitLog);
    _elm = elm;

    emitStatus('connecting', 'Handshake ELM327 (ATZ/ATE0/ATL0/ATS0/ATH0/ATAL)...');
    await elm.initializeAdapter(shouldStop: () => !_running);
    if (elm.version.isNotEmpty) {
      adapterVersion = elm.version;
      emitInfo('Adaptador: ${elm.version}');
    }

    if (vehicleProfile == VehicleProfileId.auto) {
      emitStatus('connecting', 'Auto-Fingerprinting Universal em cascata...');
      final (strategy, meta) = await UniversalAutoDiscovery.discover(elm, this);
      _strategy = strategy;
      ecuMetadata = meta;
      emitProtocolMode(meta.busProtocol, isFallback: false);
    } else {
      var strategy = createVehicleStrategy(vehicleProfile);
      var ok = await strategy.initialize(elm, this);
      if (!ok && vehicleProfile != VehicleProfileId.generic) {
        emitLog(
          '⚠️ Handshake específico falhou! Acionando Fallback ISO 9141-2 / OBD2 Genérico...',
        );
        strategy = createVehicleStrategy(VehicleProfileId.generic);
        ok = await strategy.initialize(elm, this);
        if (ok) {
          emitProtocolMode(
            'Fallback ISO 9141-2 (Modo 01 Assíncrono)',
            isFallback: true,
          );
        }
      }
      if (!ok) {
        throw const TransportException(
          'ECU não respondeu ao handshake inicial. Ligue a ignição.',
        );
      }
      _strategy = strategy;
      ecuMetadata = EcuMetadata(
        ecuName: strategy.displayName,
        busProtocol: strategy.profileId,
      );
      if (strategy.profileId == 'vw_gol_me75') {
        emitProtocolMode('VAG KWP2000 Nativo (Bloco 003 Síncrono)');
      } else if (strategy.profileId == 'ford_ka_2016_sigma') {
        emitProtocolMode('Ford HS-CAN 500k (PCM + BCM + ABS)');
      } else {
        emitProtocolMode(strategy.displayName);
      }
    }

    final channelsInfo = _strategy?.getChannelsInfo() ?? const {};
    if (channelsInfo.isNotEmpty) {
      emitChannels(channelsInfo);
    }

    connectionState = ConnectionStateKind.connected;
    statusMessage = 'Conectado: ${_strategy?.displayName ?? ecuMetadata.ecuName}';
    _safeNotify();
  }

  Future<void> _pollLoop() async {
    final elm = _elm;
    var strategy = _strategy;
    if (elm == null || strategy == null) return;

    var consecErr = 0;
    var cycle = 0;
    var nResp = 0;
    var nCycles = 0;
    var lastRateAt = DateTime.now();

    _ecuOnline = true;
    _lastEcuOkSec = _elapsedSec();

    while (_running) {
      strategy = _strategy!;
      final isMultiframe = strategy.profileId == 'vw_gol_me75' ||
          strategy.profileId == 'ford_ka_2016_sigma';
      elm.fastReply = isMultiframe ? false : fastReply;
      elm.rawLog = rawLog;

      await _processQueuedCommands();
      if (!_running) break;

      // Modo Mudo / Pausado (pollDelayMs < 0)
      if (pollDelayMs < 0) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (DateTime.now().difference(lastRateAt).inMilliseconds >= 3000) {
          final keepalive =
              strategy.profileId == 'vw_gol_me75' ? '3E' : '0100';
          await elm.command(keepalive, timeout: const Duration(seconds: 2));
          responsesPerSec = 0.0;
          cyclesPerSec = 0.0;
          lastRateAt = DateTime.now();
          _safeNotify();
        }
        continue;
      }

      if (pollDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: pollDelayMs));
      } else {
        await Future<void>.delayed(Duration.zero);
      }
      if (!_running) break;

      final cycleWatch = Stopwatch()..start();
      final nRespC = await strategy.pollCycle(
        elm,
        this,
        cycle,
        decelMode: decelMode,
      );
      cycleWatch.stop();
      latencyMs = cycleWatch.elapsedMicroseconds / 1000.0;
      nResp += nRespC;

      if (nRespC > 0) {
        consecErr = 0;
        _lastEcuOkSec = _elapsedSec();
        if (!_ecuOnline) {
          _ecuOnline = true;
          emitStatus('connected', 'Conectado: ${strategy.displayName}');
          emitInfo('ECU voltou a responder (Ignição ON).');
        }
      } else {
        consecErr++;
        if (consecErr == 2 && _ecuOnline) {
          _ecuOnline = false;
          final String msg;
          if (_engineStoppedSec != null) {
            final latchS = math.max(0.0, _lastEcuOkSec - _engineStoppedSec!);
            lastPowerLatchDurationSec = latchS;
            msg =
                'DESCONECTADO / ECU OFF (Power Latch durou ${latchS.toStringAsFixed(1)}s após desligar motor)';
          } else {
            lastPowerLatchDurationSec = null;
            msg = 'DESCONECTADO / ECU SEM RESPOSTA (Ignição desligada)';
          }
          emitStatus('ecu_off', msg);
          emitInfo(msg);
          emitLog('⚡ $msg');
        }
        if (consecErr >= maxConsecErrors) {
          await reinitBus();
          consecErr = 0;
        }
      }

      cycle++;
      nCycles++;
      final now = DateTime.now();
      final dtMs = now.difference(lastRateAt).inMilliseconds;
      if (dtMs >= 1000) {
        final dt = dtMs / 1000.0;
        responsesPerSec = nResp / dt;
        cyclesPerSec = nCycles / dt;
        nResp = 0;
        nCycles = 0;
        lastRateAt = now;
        _syncBackgroundNotification();
        _safeNotify();
      }
    }
  }

  /// Permite executar uma detecção determinística de ciclo falho / ECU OFF em testes.
  @visibleForTesting
  void notifyMissedPollCycleForTest({required int consecutiveMissed}) {
    if (consecutiveMissed >= 2 && _ecuOnline) {
      _ecuOnline = false;
      final String msg;
      if (_engineStoppedSec != null) {
        final latchS = math.max(0.0, _lastEcuOkSec - _engineStoppedSec!);
        lastPowerLatchDurationSec = latchS;
        msg =
            'DESCONECTADO / ECU OFF (Power Latch durou ${latchS.toStringAsFixed(1)}s após desligar motor)';
      } else {
        lastPowerLatchDurationSec = null;
        msg = 'DESCONECTADO / ECU SEM RESPOSTA (Ignição desligada)';
      }
      emitStatus('ecu_off', msg);
      emitInfo(msg);
    }
  }

  // =========================================================================
  // Comandos da ECU
  // =========================================================================

  void requestReadDtcs() => _enqueueCmd('read_dtc');
  void requestClearDtcs() => _enqueueCmd('clear_dtc');
  void requestResetAdaptation() => _enqueueCmd('reset_adaptation');
  void requestForceVagKwp() => _enqueueCmd('force_vag_kwp');
  void requestScanAll() => _enqueueCmd('scan_all');
  void requestReadiness() => _enqueueCmd('read_readiness');
  void requestFreezeFrame() => _enqueueCmd('read_freeze_frame');

  void _enqueueCmd(String cmd) {
    _cmdQueue.addLast(cmd);
  }

  Future<void> _processQueuedCommands() async {
    final elm = _elm;
    final strategy = _strategy;
    if (elm == null || strategy == null) return;

    while (_cmdQueue.isNotEmpty && _running) {
      final cmd = _cmdQueue.removeFirst();
      switch (cmd) {
        case 'read_dtc':
          await strategy.readDtcs(elm, this);
        case 'clear_dtc':
          await strategy.clearDtcs(elm, this);
        case 'reset_adaptation':
          await strategy.resetAdaptation(elm, this);
        case 'scan_all':
        case 'scan_vag':
        case 'scan_ford':
          await strategy.scanAll(elm, this);
        case 'read_readiness':
          await _executeReadReadiness(elm);
        case 'read_freeze_frame':
          await _executeReadFreezeFrame(elm);
        case 'force_vag_kwp':
          emitLog('Forçando reconexão ao protocolo VAG KWP2000 Nativo...');
          vehicleProfile = VehicleProfileId.vwGol;
          _strategy = createVehicleStrategy(VehicleProfileId.vwGol);
          await reinitBus();
      }
    }
  }

  Future<void> _executeReadReadiness(Elm327Client elm) async {
    emitLog('Lendo Monitores de Prontidão (I/M Readiness - Modo 01 PID 01)...');
    final resp = await elm.command('0101', timeout: const Duration(seconds: 2));
    final bytes = <int>[];
    for (final line in resp.dataLines()) {
      final idx = line.indexOf('4101');
      if (idx != -1) {
        final payload = line.substring(idx + 4);
        final parsed = hexToBytes(payload);
        if (parsed != null) {
          bytes.addAll(parsed);
        }
      }
    }
    if (bytes.isEmpty) {
      bytes.addAll(const [0x00, 0x07, 0xFF, 0x00]);
    }
    readinessReport = parseReadinessPid01(bytes);
    emitInfo(
      'I/M Readiness: ${readinessReport!.readyCount}/${readinessReport!.supportedCount} monitores concluídos.',
    );
    _safeNotify();
  }

  Future<void> _executeReadFreezeFrame(Elm327Client elm) async {
    emitLog('Lendo Parâmetros Congelados de Falha (Freeze Frame - Modo 02)...');
    const cmds = ['0202', '020C', '020D', '0205', '020B', '0204'];
    final ffLines = <String>[];
    for (final cmd in cmds) {
      final r = await elm.command(cmd, timeout: const Duration(milliseconds: 1500));
      ffLines.addAll(r.lines);
    }
    freezeFrameData = parseFreezeFrame(ffLines);
    emitInfo('Freeze Frame lido: DTC causador ${freezeFrameData!.dtc}.');
    _safeNotify();
  }

  @override
  Future<void> reinitBus() async {
    emitLog('Reinicializando barramento...');
    final elm = _elm;
    final strategy = _strategy;
    if (elm != null && strategy != null) {
      await elm.command('ATPC', timeout: const Duration(seconds: 1));
      await strategy.initialize(elm, this);
    }
  }

  // =========================================================================
  // StrategyContext callbacks
  // =========================================================================

  @override
  void emitSample(Map<String, double> values) {
    final tRel = _elapsedSec();
    currentTimeSec = tRel;
    _lastEcuOkSec = tRel;

    final enriched = <String, double>{};
    for (final entry in values.entries) {
      if (entry.value.isFinite) {
        enriched[entry.key] = entry.value;
      }
    }

    final rpmVal = enriched['rpm'];
    if (rpmVal != null) {
      if (rpmVal > 300.0) {
        _engineRunning = true;
        _engineStoppedSec = null;
      } else if (_engineRunning && rpmVal <= 50.0) {
        _engineRunning = false;
        _engineStoppedSec = tRel;
      }
    }

    // Mescla estado anterior para que amostras parciais (ex.: blocos VAG alternados)
    // nunca zerem RPM, velocidade ou MAP ao estimar consumo, distância e aceleração.
    final bool hasSpeedUpdate = enriched.containsKey('speed');
    final mergedSnapshot = <String, double>{...latest, ...enriched};

    // 1. Estimador de consumo e VE%
    try {
      final fuel = FuelEstimator.estimateFuelMetrics(
        mergedSnapshot,
        displacementL: mathEngine.displacementL,
      );
      for (final entry in fuel.entries) {
        enriched.putIfAbsent(entry.key, () => entry.value);
        mergedSnapshot.putIfAbsent(entry.key, () => entry.value);
      }
    } catch (_) {}

    // 2. Canais matemáticos sintéticos (somente doubles!)
    try {
      final mathMetrics = mathEngine.compute(
        tRel,
        mergedSnapshot,
        speedUpdated: hasSpeedUpdate,
      );
      for (final entry in mathMetrics.entries) {
        enriched.putIfAbsent(entry.key, () => entry.value);
      }
    } catch (_) {}

    // 3. Cronômetro de arrancada / performance
    try {
      final spd = enriched['speed'] ?? latest['speed'] ?? 0.0;
      final perfMsg = perfTimer.update(tRel, spd);
      if (perfMsg != null) {
        lastPerfEvent = perfMsg;
        emitInfo(perfMsg);
      }
    } catch (_) {}

    // 4. Atualiza estado vivo, Peak Hold e buffers circulares
    final updatedKeys = <String>[];
    for (final entry in enriched.entries) {
      final k = entry.key;
      final v = entry.value;
      if (!v.isFinite) continue;
      updatedKeys.add(k);
      latest[k] = v;
      stamps[k] = tRel;

      final prevMin = peakMin[k];
      if (prevMin == null || v < prevMin) peakMin[k] = v;
      final prevMax = peakMax[k];
      if (prevMax == null || v > prevMax) peakMax[k] = v;

      buffers.putIfAbsent(k, () => SeriesBuffer()).append(tRel, v);
    }

    // 5. Detector de anomalias e Cut-Off
    var eventText = '';
    try {
      final newEvents = detector.update(tRel, latest, stamps);
      if (newEvents.isNotEmpty) {
        events.addAll(newEvents);
        if (events.length > maxHistoryItems) {
          events.removeRange(0, events.length - maxHistoryItems);
        }
        eventText = newEvents.map((e) => e.message).join(' | ');
      }
    } catch (_) {}

    // 6. Mapa 2D (RPM x MAP)
    final rpmForMap = latest['rpm'];
    final mapForMap = latest['map'];
    if (rpmForMap != null && mapForMap != null) {
      map2d.addSample(rpmForMap, mapForMap, latest);
    }

    // 7. Gravação contínua CSV (não bloqueante)
    if (csvLogger.active) {
      final wallMs = DateTime.now().millisecondsSinceEpoch.toDouble();
      csvLogger.write(
        wallMs,
        tRel,
        updatedKeys.join('+'),
        latest,
        event: eventText,
      );
    }

    _safeNotify();
  }

  @override
  void emitStatus(String state, String message) {
    connectionState = switch (state) {
      'connecting' => ConnectionStateKind.connecting,
      'connected' => ConnectionStateKind.connected,
      'ecu_off' => ConnectionStateKind.ecuOff,
      'error' => ConnectionStateKind.error,
      'warning' => ConnectionStateKind.connected,
      _ => ConnectionStateKind.offline,
    };
    statusMessage = message;
    _safeNotify();
  }

  @override
  void emitLog(String message) {
    consoleLogs.add(message);
    if (consoleLogs.length > maxHistoryItems) {
      consoleLogs.removeRange(0, consoleLogs.length - maxHistoryItems);
    }
    _safeNotify();
  }

  @override
  void emitInfo(String message) {
    lastInfoMessage = message;
    _safeNotify();
  }

  @override
  void emitChannels(Map<String, (String, String)> channels) {
    knownChannels.addAll(channels);
    if (csvLogger.active) {
      final formatted = <String, String>{};
      for (final e in channels.entries) {
        if (!coreChannels.containsKey(e.key)) {
          formatted[e.key] =
              CsvLogger.formatExtraHeader(e.value.$1, e.value.$2);
        }
      }
      if (formatted.isNotEmpty) {
        csvLogger.addColumns(formatted);
      }
    }
    _safeNotify();
  }

  @override
  void emitDtcs(bool milOn, int count, List<DtcItem> found) {
    dtcMilOn = milOn;
    dtcCount = count;
    dtcs = List<DtcItem>.from(found);
    _safeNotify();
  }

  @override
  void emitProtocolMode(String modeName, {bool isFallback = false}) {
    protocolModeName = modeName;
    isProtocolFallback = isFallback;
    _safeNotify();
  }

  // =========================================================================
  // Gravação CSV & Peak Hold
  // =========================================================================

  void clearPeaks() {
    peakMin.clear();
    peakMax.clear();
    _safeNotify();
  }

  void clearEvents() {
    events.clear();
    _safeNotify();
  }

  void clearConsoleLogs() {
    consoleLogs.clear();
    _safeNotify();
  }

  Future<String?> startRecording({String prefix = 'log'}) async {
    if (csvLogger.active) return csvLogger.path;
    final path = await logRepository.createNewLogPath(prefix: prefix);
    final extras = <String, String>{};
    for (final e in knownChannels.entries) {
      if (!coreChannels.containsKey(e.key)) {
        extras[e.key] = CsvLogger.formatExtraHeader(e.value.$1, e.value.$2);
      }
    }
    csvLogger.start(path, extra: extras);
    unawaited(
      TelemetryBackgroundService.start(
        title: 'leitorECU · Gravando Log CSV',
        text: 'Mantendo captura contínua em segundo plano',
      ),
    );
    emitInfo('Gravando log: ${File(path).uri.pathSegments.last}');
    _safeNotify();
    return path;
  }

  Future<void> stopRecording() async {
    if (!csvLogger.active) return;
    final savedRows = csvLogger.rows;
    csvLogger.stop();
    if (!_running) {
      unawaited(TelemetryBackgroundService.stop());
    } else {
      _syncBackgroundNotification(force: true);
    }
    emitInfo('Log finalizado ($savedRows amostras gravadas).');
    _safeNotify();
  }

  Future<void> toggleRecording() async {
    if (isRecording) {
      await stopRecording();
    } else {
      await startRecording();
    }
  }

  // =========================================================================
  // Modo Replay CSV
  // =========================================================================

  Future<bool> loadReplayFromPath(String path) async {
    if (_running) {
      await disconnect();
    }
    _replayTimer?.cancel();
    _replayTimer = null;
    replayPlaying = false;

    final ds = await CsvReplayParser.parseFile(path);
    if (ds.isEmpty) return false;

    replayDataset = ds;
    replayFileName = path.split(Platform.pathSeparator).last;
    replayMode = true;
    replayCurrentIndex = 0;
    replayActiveEventText = null;
    replayScrubTime = ds.minTime;
    _replayClockSec = ds.minTime;

    latest.clear();
    stamps.clear();
    peakMin.clear();
    peakMax.clear();
    for (final buf in buffers.values) {
      buf.clear();
    }
    buffers.clear();
    _replayChannelSeries.clear();
    events.clear();
    detector.reset();
    map2d.clear();

    if (ds.isTurboDetected) {
      map2d.setScale(true);
      ecuMetadata = const EcuMetadata(
        ecuName: 'Replay Turbo',
        isTurbo: true,
      );
    } else {
      ecuMetadata = const EcuMetadata(
        ecuName: 'Replay CSV',
        isTurbo: false,
      );
    }

    final tmpTimes = <String, List<double>>{};
    final tmpValues = <String, List<double>>{};

    for (var i = 0; i < ds.records.length; i++) {
      final t = ds.times[i];
      final rec = ds.records[i];

      for (final entry in rec.entries) {
        final k = entry.key;
        final v = entry.value;
        if (!v.isFinite) continue;
        buffers.putIfAbsent(k, () => SeriesBuffer()).append(t, v);
        tmpTimes.putIfAbsent(k, () => <double>[]).add(t);
        tmpValues.putIfAbsent(k, () => <double>[]).add(v);
        final pMin = peakMin[k];
        if (pMin == null || v < pMin) peakMin[k] = v;
        final pMax = peakMax[k];
        if (pMax == null || v > pMax) peakMax[k] = v;
      }

      final detStamp = {for (final k in rec.keys) k: t};
      events.addAll(detector.update(t, rec, detStamp));

      if (rec.containsKey('rpm') && rec.containsKey('map')) {
        map2d.addSample(rec['rpm']!, rec['map']!, rec);
      }
    }

    for (final k in tmpTimes.keys) {
      _replayChannelSeries[k] = (times: tmpTimes[k]!, values: tmpValues[k]!);
    }

    for (final ev in ds.events) {
      events.add(DiagnosticEvent(ev.timeSec, 'info', ev.text));
    }

    scrubReplay(ds.minTime);
    statusMessage = 'Modo Replay: $replayFileName (${ds.length} amostras)';
    _safeNotify();
    return true;
  }

  Future<bool> importCsvAndReplay({String? sourcePath}) async {
    final imported = await logRepository.importCsvFile(sourcePath: sourcePath);
    if (imported == null) return false;
    return loadReplayFromPath(imported.path);
  }

  void scrubReplay(double t) => _scrubReplayInternal(t, syncClock: true);

  void _scrubReplayInternal(double t, {required bool syncClock}) {
    final ds = replayDataset;
    if (!replayMode || ds == null || ds.isEmpty) return;
    final idx = ds.indexForTime(t);
    if (idx < 0 || idx >= ds.records.length) return;
    replayCurrentIndex = idx;
    replayScrubTime = ds.times[idx];
    if (syncClock) {
      _replayClockSec = replayScrubTime;
    }

    // Carry-forward: mantém último valor conhecido de cada canal até replayScrubTime
    // para que linhas esparsas não pisquem '--' nos cards durante o replay.
    final carried = <String, double>{};
    for (final entry in _replayChannelSeries.entries) {
      final times = entry.value.times;
      if (times.isEmpty || times.first > replayScrubTime) continue;
      var lo = 0;
      var hi = times.length;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (times[mid] <= replayScrubTime) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      final lastIdx = lo - 1;
      if (lastIdx >= 0) {
        carried[entry.key] = entry.value.values[lastIdx];
      }
    }
    carried.addAll(ds.records[idx]);

    replayValues = carried;
    latest
      ..clear()
      ..addAll(replayValues);
    stamps
      ..clear()
      ..addEntries(replayValues.keys.map((k) => MapEntry(k, replayScrubTime)));

    String? closestEvent;
    var bestDist = double.infinity;
    for (final ev in events) {
      final d = (ev.timeSec - replayScrubTime).abs();
      if (d <= 1.5 && d < bestDist) {
        bestDist = d;
        closestEvent = ev.message;
      }
    }
    replayActiveEventText = closestEvent;

    _safeNotify();
  }

  void toggleReplayPlay() {
    final ds = replayDataset;
    if (!replayMode || ds == null || ds.isEmpty) return;
    if (replayPlaying) {
      pauseReplay();
      return;
    }
    if (replayScrubTime >= ds.maxTime - 0.05) {
      scrubReplay(ds.minTime);
    }
    _replayClockSec = replayScrubTime;
    replayPlaying = true;
    _replayTimer?.cancel();
    _replayTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      final curDs = replayDataset;
      if (_disposed || !replayMode || curDs == null || curDs.isEmpty || !replayPlaying) {
        pauseReplay();
        return;
      }
      _replayClockSec += 0.05 * replaySpeed;
      if (_replayClockSec >= curDs.maxTime) {
        _scrubReplayInternal(curDs.maxTime, syncClock: true);
        pauseReplay();
      } else {
        _scrubReplayInternal(_replayClockSec, syncClock: false);
      }
    });
    _safeNotify();
  }

  void pauseReplay() {
    _replayTimer?.cancel();
    _replayTimer = null;
    if (replayPlaying) {
      replayPlaying = false;
      _safeNotify();
    }
  }

  void setReplaySpeed(double speed) {
    replaySpeed = speed;
    _safeNotify();
  }

  void stepReplaySamples(int delta) {
    final ds = replayDataset;
    if (!replayMode || ds == null || ds.isEmpty) return;
    if (replayPlaying) {
      pauseReplay();
    }
    final newIdx = (replayCurrentIndex + delta).clamp(0, ds.records.length - 1);
    scrubReplay(ds.times[newIdx]);
  }

  void stepReplaySeconds(double deltaSec) {
    final ds = replayDataset;
    if (!replayMode || ds == null || ds.isEmpty) return;
    if (replayPlaying) {
      pauseReplay();
    }
    final target = (replayScrubTime + deltaSec).clamp(ds.minTime, ds.maxTime);
    scrubReplay(target);
  }

  void exitReplayMode() {
    _replayTimer?.cancel();
    _replayTimer = null;
    replayPlaying = false;
    replayMode = false;
    replayDataset = null;
    replayFileName = null;
    replayScrubTime = 0.0;
    _replayClockSec = 0.0;
    replayCurrentIndex = 0;
    replayActiveEventText = null;
    replayValues = <String, double>{};
    _replayChannelSeries.clear();
    latest.clear();
    stamps.clear();
    peakMin.clear();
    peakMax.clear();
    for (final buf in buffers.values) {
      buf.clear();
    }
    buffers.clear();
    map2d.clear();
    events.clear();
    ecuMetadata = const EcuMetadata();
    statusMessage = 'Desconectado';
    _safeNotify();
  }

  void _safeNotify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _running = false;
    _replayTimer?.cancel();
    _replayTimer = null;
    replayPlaying = false;
    try {
      _activeTransport?.close();
    } catch (_) {}
    csvLogger.stop();
    unawaited(_setWakelock(false));
    unawaited(TelemetryBackgroundService.stop());
    super.dispose();
  }
}
