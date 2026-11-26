import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/models/channel_def.dart';
import '../../state/telemetry_controller.dart';
import '../theme/motorsport_theme.dart';
import '../widgets/dual_axis_chart.dart';
import '../widgets/replay_player_bar.dart';

/// Aba Gráficos: osciloscópio separado com 3 gráficos Dual-Axis, auto-escala turbo e Crosshair em Replay.
class ChartsScreen extends StatefulWidget {
  const ChartsScreen({
    super.key,
    required this.controller,
    this.pinnedChannelNotifier,
  });

  final TelemetryController controller;
  final ValueNotifier<String?>? pinnedChannelNotifier;

  @override
  State<ChartsScreen> createState() => _ChartsScreenState();
}

class _ChartsScreenState extends State<ChartsScreen> {
  bool _frozen = false;

  // [left1, left2, right] para cada um dos 3 gráficos
  final List<List<String>> _bindings = [
    ['rpm', 'tps', 'map'],
    ['lambda_v', 'lambda2_v', 'advance'],
    ['stft', 'ltft', 'battery'],
  ];

  @override
  void initState() {
    super.initState();
    widget.pinnedChannelNotifier?.addListener(_handlePinnedChannel);
    _handlePinnedChannel();
  }

  @override
  void didUpdateWidget(covariant ChartsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pinnedChannelNotifier != widget.pinnedChannelNotifier) {
      oldWidget.pinnedChannelNotifier?.removeListener(_handlePinnedChannel);
      widget.pinnedChannelNotifier?.addListener(_handlePinnedChannel);
      _handlePinnedChannel();
    }
  }

  @override
  void dispose() {
    widget.pinnedChannelNotifier?.removeListener(_handlePinnedChannel);
    super.dispose();
  }

  void _handlePinnedChannel() {
    final notifier = widget.pinnedChannelNotifier;
    if (notifier == null) return;
    final key = notifier.value;
    if (key == null || key.isEmpty) return;
    notifier.value = null;
    if (!_bindings[0].contains(key)) {
      if (mounted) {
        setState(() {
          _bindings[0][0] = key;
        });
      } else {
        _bindings[0][0] = key;
      }
    }
  }

  // Snapshot congelado quando _frozen == true
  double _frozenNow = 0.0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final isTablet = MediaQuery.sizeOf(context).width >= MotorsportTheme.tabletBreakpoint;
        final options = _buildChannelOptions(c);

        final bool replay = c.replayMode && c.replayDataset != null;
        final double xMin;
        final double xMax;
        if (replay) {
          xMin = c.replayDataset!.minTime;
          xMax = math.max(xMin + 1.0, c.replayDataset!.maxTime);
        } else {
          final now = _frozen ? _frozenNow : c.currentTimeSec;
          final win = c.plotWindowSec.toDouble();
          xMax = math.max(win, now);
          xMin = xMax - win;
        }

        final markers = [
          for (final ev in c.events)
            if (ev.level == 'alarm' || ev.level == 'info')
              ChartMarker(
                t: ev.timeSec,
                color: ev.level == 'alarm' ? MotorsportColors.alarm : MotorsportColors.info,
                label: ev.level == 'alarm' ? 'Falha' : null,
              ),
        ];

        final plotHeight = isTablet ? 200.0 : 180.0;

        return Column(
          children: [
            _buildToolbar(context, c, replay),
            if (replay)
              Padding(
                padding: EdgeInsets.fromLTRB(isTablet ? 12 : 8, 6, isTablet ? 12 : 8, 0),
                child: ReplayPlayerBar(
                  controller: c,
                  compact: true,
                  exitLabel: 'Sair Replay',
                ),
              ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(isTablet ? 12 : 8),
                children: [
                  _buildPlot(
                    c,
                    plotIdx: 0,
                    title: '01 • AR E GIRO',
                    options: options,
                    xMin: xMin,
                    xMax: xMax,
                    markers: markers,
                    replay: replay,
                    height: plotHeight,
                    defaultLeftRange: (0.0, 7000.0),
                    defaultRightRange: (0.0, _computeMapMaxY(c)),
                  ),
                  const SizedBox(height: 10),
                  _buildPlot(
                    c,
                    plotIdx: 1,
                    title: '02 • COMBUSTÃO E IGNIÇÃO',
                    options: options,
                    xMin: xMin,
                    xMax: xMax,
                    markers: markers,
                    replay: replay,
                    height: plotHeight,
                    defaultLeftRange: (0.0, 1.3),
                    defaultRightRange: (-20.0, 50.0),
                    hlines: const [
                      ChartHLine(value: 0.45, color: Colors.white70, label: '0,45 V'),
                      ChartHLine(value: 0.70, color: MotorsportColors.alarm, label: '0,70 V'),
                      ChartHLine(value: -5.0, color: Color(0xFFE040FB), rightAxis: true),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buildPlot(
                    c,
                    plotIdx: 2,
                    title: '03 • FUEL TRIMS E ELÉTRICA',
                    options: options,
                    xMin: xMin,
                    xMax: xMax,
                    markers: markers,
                    replay: replay,
                    height: plotHeight,
                    defaultLeftRange: (-30.0, 30.0),
                    defaultRightRange: (10.0, 16.0),
                    hlines: const [
                      ChartHLine(value: 0.0, color: Color(0xFF607D8B), dashed: false),
                      ChartHLine(value: 10.0, color: MotorsportColors.warning, label: '+10%'),
                      ChartHLine(value: -10.0, color: MotorsportColors.warning, label: '-10%'),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildToolbar(BuildContext context, TelemetryController c, bool replay) {
    final tokens = MotorsportTheme.tokensOf(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tokens.surfaceAlt,
        border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ElevatedButton.icon(
            onPressed: replay
                ? null
                : () {
                    setState(() {
                      _frozen = !_frozen;
                      if (_frozen) {
                        _frozenNow = c.currentTimeSec;
                      }
                    });
                  },
            style: ElevatedButton.styleFrom(
              backgroundColor: _frozen ? const Color(0xFF493512) : tokens.elevated,
              foregroundColor: _frozen ? const Color(0xFFFFE2A1) : tokens.text,
              side: BorderSide(
                color: _frozen ? MotorsportColors.warning : tokens.border,
              ),
            ),
            icon: Icon(_frozen ? Icons.play_arrow : Icons.pause, size: 16),
            label: Text(_frozen ? 'Retomar' : 'Congelar'),
          ),
          OutlinedButton.icon(
            onPressed: replay
                ? null
                : () {
                    for (final b in c.buffers.values) {
                      b.clear();
                    }
                    c.clearEvents();
                  },
            icon: const Icon(Icons.cleaning_services_outlined, size: 16),
            label: const Text('Limpar'),
          ),
          Text(
            replay
                ? 'Arraste nos gráficos para mover o Crosshair sincronizado'
                : 'Janela ao vivo: ${c.plotWindowSec}s · 3 eixos duplos',
            style: TextStyle(
              color: tokens.muted,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlot(
    TelemetryController c, {
    required int plotIdx,
    required String title,
    required List<ChartChannelOption> options,
    required double xMin,
    required double xMax,
    required List<ChartMarker> markers,
    required bool replay,
    required double height,
    required (double, double) defaultLeftRange,
    required (double, double) defaultRightRange,
    List<ChartHLine> hlines = const [],
  }) {
    final keys = _bindings[plotIdx];
    final traces = <ChartTraceConfig>[];
    const slotLabels = ['Esq.1', 'Esq.2', 'Dir.'];

    for (var i = 0; i < 3; i++) {
      final k = keys[i];
      final buf = c.buffers[k];
      final points = <ChartPoint>[];
      if (buf != null && buf.isNotEmpty) {
        final slice = buf.window(xMin);
        final times = slice.times;
        final values = slice.values;
        // Downsample leve se houver > 600 pontos na janela
        final step = math.max(1, times.length ~/ 600);
        for (var idx = 0; idx < times.length; idx += step) {
          points.add(ChartPoint(times[idx], values[idx]));
        }
      }
      final val = c.latest[k];
      final readout = val != null ? _formatReadout(k, val) : '--';
      traces.add(
        ChartTraceConfig(
          slotLabel: slotLabels[i],
          channelKey: k,
          points: points,
          readout: readout,
          isRightAxis: i == 2,
        ),
      );
    }

    final leftRange = _rangeForKeys([keys[0], keys[1]], defaultLeftRange, c);
    final rightRange = _rangeForKeys([keys[2]], defaultRightRange, c);

    return DualAxisChartWidget(
      title: title,
      traces: traces,
      channelOptions: options,
      leftRange: leftRange,
      rightRange: rightRange,
      xMin: xMin,
      xMax: xMax,
      hlines: hlines,
      markers: markers,
      crosshairT: replay ? c.replayScrubTime : null,
      onCrosshairMoved: replay ? c.scrubReplay : null,
      windowLabel: replay ? '${(xMax - xMin).toStringAsFixed(0)}s' : '${c.plotWindowSec}s',
      height: height,
      onSelectChannel: (traceIndex, newKey) {
        setState(() {
          _bindings[plotIdx][traceIndex] = newKey;
        });
      },
    );
  }

  double _computeMapMaxY(TelemetryController c) {
    final buf = c.buffers['map'];
    double maxVal = c.latest['map'] ?? 0.0;
    if (buf != null && buf.isNotEmpty) {
      for (final v in buf.values) {
        if (v > maxVal) maxVal = v;
      }
    }
    if (maxVal > 105.0 || c.isTurbo) {
      final rounded = ((maxVal.ceil() + 19) ~/ 20) * 20;
      return math.min(260.0, math.max(140.0, rounded.toDouble()));
    }
    return 105.0;
  }

  (double, double) _rangeForKeys(
    List<String> keys,
    (double, double) fallback,
    TelemetryController c,
  ) {
    if (keys.contains('rpm')) return (0.0, 7000.0);
    if (keys.contains('map')) return (0.0, _computeMapMaxY(c));
    if (keys.contains('boost_bar')) return (-1.0, 2.0);
    if (keys.contains('boost_psi')) return (-15.0, 30.0);
    if (keys.contains('lambda_v') || keys.contains('lambda2_v')) return (0.0, 1.3);
    if (keys.contains('lambda_eq')) return (0.6, 1.6);
    if (keys.contains('advance')) return (-20.0, 50.0);
    if (keys.contains('stft') || keys.contains('ltft') || keys.contains('ltft_idle')) {
      return (-30.0, 30.0);
    }
    if (keys.contains('battery')) return (10.0, 16.0);
    if (keys.contains('ect') || keys.contains('iat')) return (0.0, 130.0);
    if (keys.contains('speed')) return (0.0, 220.0);
    if (keys.contains('tps') || keys.contains('load') || keys.contains('wastegate_pct')) {
      return (0.0, 105.0);
    }
    return fallback;
  }

  String _formatReadout(String key, double val) {
    final def = coreChannels[key];
    if (def != null) {
      return def.formatValue(val);
    }
    if (key.contains('boost') || key.contains('bar')) {
      return val.toStringAsFixed(2);
    }
    if (key == 'lambda_eq') {
      return val.toStringAsFixed(3);
    }
    return val.toStringAsFixed(1);
  }

  List<ChartChannelOption> _buildChannelOptions(TelemetryController c) {
    final seen = <String>{};
    final out = <ChartChannelOption>[];

    void addKey(String key) {
      if (seen.contains(key)) return;
      seen.add(key);
      final info = describeChannel(key, c.knownChannels);
      out.add(ChartChannelOption(key: key, label: info.label, unit: info.unit));
    }

    for (final k in coreChannels.keys) {
      addKey(k);
    }
    for (final k in c.knownChannels.keys) {
      addKey(k);
    }
    for (final k in c.latest.keys) {
      addKey(k);
    }
    return out;
  }
}
