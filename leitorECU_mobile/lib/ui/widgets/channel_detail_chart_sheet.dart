import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/models/channel_def.dart';
import '../../state/telemetry_controller.dart';
import '../theme/motorsport_theme.dart';

class _RefLine {
  const _RefLine(this.value, this.label, this.color);

  final double value;
  final String label;
  final Color color;
}

/// Modal responsivo dedicado ao gráfico em alta resolução de um único parâmetro.
/// Permite inspeção ao vivo ou em Replay com janelas selecionáveis (15s, 30s, 60s, Tudo),
/// estatísticas (Atual / Mín / Méd / Máx), congelamento e Crosshair por toque/arrasto.
class ChannelDetailChartSheet extends StatefulWidget {
  const ChannelDetailChartSheet({
    super.key,
    required this.controller,
    required this.channelKey,
    this.onPinToCharts,
    this.onRemoveFromDashboard,
  });

  final TelemetryController controller;
  final String channelKey;
  final VoidCallback? onPinToCharts;
  final VoidCallback? onRemoveFromDashboard;

  static Future<void> show(
    BuildContext context, {
    required TelemetryController controller,
    required String channelKey,
    VoidCallback? onPinToCharts,
    VoidCallback? onRemoveFromDashboard,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChannelDetailChartSheet(
        controller: controller,
        channelKey: channelKey,
        onPinToCharts: onPinToCharts,
        onRemoveFromDashboard: onRemoveFromDashboard,
      ),
    );
  }

  @override
  State<ChannelDetailChartSheet> createState() =>
      _ChannelDetailChartSheetState();
}

class _ChannelDetailChartSheetState extends State<ChannelDetailChartSheet> {
  int? _windowSec = 60; // null = Tudo
  bool _frozen = false;
  double _frozenNow = 0.0;
  double? _crosshairT;

  static const List<int?> _windows = [15, 30, 60, null];

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.sizeOf(context);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final sheetHeight = math.min(media.height * 0.86, 620.0);
    final accent = MotorsportColors.colorForChannel(widget.channelKey);

    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 780),
          child: Container(
            height: sheetHeight + bottomInset * 0.3,
            decoration: BoxDecoration(
              color: MotorsportColors.surface,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(18)),
              border: Border.all(color: MotorsportColors.border),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black54,
                  blurRadius: 24,
                  offset: Offset(0, -6),
                ),
              ],
            ),
            child: ListenableBuilder(
              listenable: widget.controller,
              builder: (context, _) {
                final c = widget.controller;
                final desc = describeChannel(widget.channelKey, c.knownChannels);
                final replay = c.replayMode && c.replayDataset != null;
                final buf = c.buffers[widget.channelKey];

                double xMin;
                double xMax;
                if (replay) {
                  final ds = c.replayDataset!;
                  xMax = ds.maxTime;
                  if (_windowSec == null) {
                    xMin = ds.minTime;
                  } else {
                    final anchor = c.replayScrubTime.clamp(
                      ds.minTime,
                      math.max(ds.minTime + 1.0, ds.maxTime),
                    );
                    final half = _windowSec! / 2.0;
                    xMin = math.max(ds.minTime, anchor - half);
                    xMax = math.min(ds.maxTime, xMin + _windowSec!);
                    if (xMax - xMin < _windowSec!) {
                      xMin = math.max(ds.minTime, xMax - _windowSec!);
                    }
                  }
                  if (xMax <= xMin) xMax = xMin + 1.0;
                } else {
                  final now = _frozen ? _frozenNow : c.currentTimeSec;
                  if (_windowSec == null) {
                    xMin = (buf != null && buf.times.isNotEmpty)
                        ? buf.times.first
                        : 0.0;
                    xMax = math.max(xMin + 1.0, now);
                  } else {
                    xMax = math.max(now, _windowSec!.toDouble());
                    xMin = math.max(0.0, xMax - _windowSec!);
                  }
                }

                final slice = buf == null
                    ? (times: <double>[], values: <double>[])
                    : buf.window(xMin);

                final visibleTimes = <double>[];
                final visibleValues = <double>[];
                for (int i = 0; i < slice.times.length; i++) {
                  final t = slice.times[i];
                  if (t <= xMax + 0.001) {
                    visibleTimes.add(t);
                    visibleValues.add(slice.values[i]);
                  }
                }

                double? currentVal =
                    replay ? c.replayValues[widget.channelKey] : c.latest[widget.channelKey];
                double? minVal;
                double? maxVal;
                double? avgVal;
                if (visibleValues.isNotEmpty) {
                  double lo = visibleValues.first;
                  double hi = visibleValues.first;
                  double sum = 0.0;
                  for (final v in visibleValues) {
                    if (v < lo) lo = v;
                    if (v > hi) hi = v;
                    sum += v;
                  }
                  minVal = lo;
                  maxVal = hi;
                  if (widget.channelKey == 'fuel_econ_kml') {
                    final movingValid =
                        visibleValues.where((v) => v > 0.05 && v < 99.0).toList();
                    avgVal = movingValid.isNotEmpty
                        ? movingValid.reduce((a, b) => a + b) / movingValid.length
                        : sum / visibleValues.length;
                  } else {
                    avgVal = sum / visibleValues.length;
                  }
                }

                // Se usuário tocou/arrastou crosshair, encontra o ponto real mais próximo
                ({double t, double v})? snapped;
                final activeCrossT =
                    _crosshairT ?? (replay ? c.replayScrubTime : null);
                if (activeCrossT != null && visibleTimes.isNotEmpty) {
                  snapped = _nearestSample(
                    visibleTimes,
                    visibleValues,
                    activeCrossT,
                  );
                }

                final hlines = _referenceLines(widget.channelKey);
                final (yMin, yMax) = _computeYRange(
                  widget.channelKey,
                  visibleValues,
                  hlines,
                );

                final eventTimes = <double>[];
                final eventColors = <Color>[];
                for (final ev in c.events) {
                  if (ev.timeSec >= xMin && ev.timeSec <= xMax) {
                    eventTimes.add(ev.timeSec);
                    eventColors.add(
                      ev.level == 'alarm'
                          ? MotorsportColors.alarm
                          : (ev.level == 'warn'
                              ? MotorsportColors.warning
                              : MotorsportColors.info),
                    );
                  }
                }

                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    12,
                    10,
                    12,
                    10 + bottomInset * 0.4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Alça visual superior
                      Center(
                        child: Container(
                          width: 38,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: MotorsportColors.border,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      // Cabeçalho
                      _buildHeader(
                        label: desc.label,
                        unit: desc.unit,
                        accent: accent,
                        replay: replay,
                      ),
                      const SizedBox(height: 8),
                      // Controles: Janela + Congelar + Fixar nos Gráficos
                      _buildToolbar(c, replay, accent),
                      const SizedBox(height: 8),
                      // Estatísticas do canal / cursor
                      _buildStatsRow(
                        unit: desc.unit,
                        accent: accent,
                        currentVal: snapped?.v ?? currentVal,
                        isCursorActive: snapped != null,
                        cursorTime: snapped?.t,
                        minVal: minVal,
                        avgVal: avgVal,
                        maxVal: maxVal,
                      ),
                      const SizedBox(height: 8),
                      // Gráfico interativo ocupando o restante do modal
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            color: MotorsportColors.plot,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: MotorsportColors.borderSubtle,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              if (visibleTimes.isEmpty) {
                                return Center(
                                  child: Text(
                                    'Sem amostras para ${desc.label} nesta janela.\n'
                                    'Aguarde novos pacotes da ECU ou mude a janela para "Tudo".',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: MotorsportColors.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                );
                              }
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapDown: (d) => _updateCrosshair(
                                  d.localPosition.dx,
                                  constraints.maxWidth,
                                  xMin,
                                  xMax,
                                  replay,
                                  c,
                                ),
                                onHorizontalDragStart: (d) => _updateCrosshair(
                                  d.localPosition.dx,
                                  constraints.maxWidth,
                                  xMin,
                                  xMax,
                                  replay,
                                  c,
                                ),
                                onHorizontalDragUpdate: (d) => _updateCrosshair(
                                  d.localPosition.dx,
                                  constraints.maxWidth,
                                  xMin,
                                  xMax,
                                  replay,
                                  c,
                                ),
                                onDoubleTap: () =>
                                    setState(() => _crosshairT = null),
                                child: CustomPaint(
                                  size: Size(
                                    constraints.maxWidth,
                                    constraints.maxHeight,
                                  ),
                                  painter: _SingleChannelPainter(
                                    times: visibleTimes,
                                    values: visibleValues,
                                    xMin: xMin,
                                    xMax: xMax,
                                    yMin: yMin,
                                    yMax: yMax,
                                    color: accent,
                                    unit: desc.unit,
                                    hlines: hlines,
                                    eventTimes: eventTimes,
                                    eventColors: eventColors,
                                    snappedSample: snapped,
                                    formatter: (v) =>
                                        _formatValue(widget.channelKey, v),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Arraste no gráfico para inspecionar • Toque duplo limpa cursor',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: MotorsportColors.muted,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${visibleTimes.length} amostras',
                            style: MotorsportTheme.tabularStyle(
                              fontSize: 10.5,
                              color: MotorsportColors.stale,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader({
    required String label,
    required String unit,
    required Color accent,
    required bool replay,
  }) {
    final badgeText = replay
        ? 'REPLAY'
        : (_frozen ? 'CONGELADO' : 'AO VIVO');
    final badgeColor = replay
        ? MotorsportColors.info
        : (_frozen ? MotorsportColors.warning : MotorsportColors.ok);

    return Row(
      children: [
        Container(
          width: 4,
          height: 28,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: MotorsportColors.text,
                      ),
                    ),
                  ),
                  if (unit.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Text(
                      '[$unit]',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: MotorsportColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
              Text(
                'Canal: ${widget.channelKey}',
                style: MotorsportTheme.tabularStyle(
                  fontSize: 10.5,
                  color: MotorsportColors.stale,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: badgeColor.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: badgeColor.withValues(alpha: 0.6)),
          ),
          child: Text(
            badgeText,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              color: badgeColor,
              letterSpacing: 0.5,
            ),
          ),
        ),
        if (widget.onRemoveFromDashboard != null) ...[
          const SizedBox(width: 4),
          IconButton(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onRemoveFromDashboard!();
            },
            icon: const Icon(
              Icons.delete_outline,
              size: 20,
              color: MotorsportColors.alarm,
            ),
            tooltip: 'Remover card da tela inicial',
            visualDensity: VisualDensity.compact,
          ),
        ],
        const SizedBox(width: 4),
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close, size: 20),
          tooltip: 'Fechar',
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _buildToolbar(TelemetryController c, bool replay, Color accent) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final w in _windows)
          ChoiceChip(
            label: Text(
              w == null ? 'Tudo' : '${w}s',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
            selected: _windowSec == w,
            visualDensity: VisualDensity.compact,
            selectedColor: accent.withValues(alpha: 0.22),
            onSelected: (_) => setState(() => _windowSec = w),
          ),
        if (!replay)
          OutlinedButton.icon(
            onPressed: () {
              setState(() {
                _frozen = !_frozen;
                if (_frozen) {
                  _frozenNow = c.currentTimeSec;
                } else {
                  _crosshairT = null;
                }
              });
            },
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              side: BorderSide(
                color: _frozen
                    ? MotorsportColors.warning
                    : MotorsportColors.border,
              ),
            ),
            icon: Icon(
              _frozen ? Icons.play_arrow_rounded : Icons.pause_rounded,
              size: 16,
              color: _frozen ? MotorsportColors.warning : MotorsportColors.text,
            ),
            label: Text(
              _frozen ? 'Retomar' : 'Congelar',
              style: TextStyle(
                fontSize: 11,
                color:
                    _frozen ? MotorsportColors.warning : MotorsportColors.text,
              ),
            ),
          ),
        if (_crosshairT != null)
          OutlinedButton.icon(
            onPressed: () => setState(() => _crosshairT = null),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
            icon: const Icon(Icons.gps_off, size: 14),
            label: const Text('Limpar Cursor', style: TextStyle(fontSize: 11)),
          ),
        if (widget.onPinToCharts != null)
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              widget.onPinToCharts!();
            },
            style: ElevatedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              backgroundColor: accent.withValues(alpha: 0.18),
              foregroundColor: MotorsportColors.text,
              side: BorderSide(color: accent.withValues(alpha: 0.65)),
            ),
            icon: const Icon(Icons.push_pin_outlined, size: 14),
            label: const Text(
              'Fixar nos Gráficos',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }

  Widget _buildStatsRow({
    required String unit,
    required Color accent,
    required double? currentVal,
    required bool isCursorActive,
    required double? cursorTime,
    required double? minVal,
    required double? avgVal,
    required double? maxVal,
  }) {
    String fmt(double? v) => v == null ? '--' : _formatValue(widget.channelKey, v);

    return Row(
      children: [
        Expanded(
          child: _StatPill(
            label: isCursorActive && cursorTime != null
                ? 't=${cursorTime.toStringAsFixed(1)}s'
                : 'ATUAL',
            value: fmt(currentVal),
            unit: unit,
            highlight: accent,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _StatPill(
            label: 'MÍNIMO',
            value: fmt(minVal),
            unit: unit,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _StatPill(
            label: 'MÉDIA',
            value: fmt(avgVal),
            unit: unit,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: _StatPill(
            label: 'MÁXIMO',
            value: fmt(maxVal),
            unit: unit,
          ),
        ),
      ],
    );
  }

  void _updateCrosshair(
    double dx,
    double totalWidth,
    double xMin,
    double xMax,
    bool replay,
    TelemetryController c,
  ) {
    const leftPad = 48.0;
    const rightPad = 14.0;
    final plotW = math.max(1.0, totalWidth - leftPad - rightPad);
    final ratio = ((dx - leftPad) / plotW).clamp(0.0, 1.0);
    final t = xMin + ratio * (xMax - xMin);
    setState(() => _crosshairT = t);
    if (replay) {
      c.scrubReplay(t);
    }
  }

  ({double t, double v}) _nearestSample(
    List<double> times,
    List<double> values,
    double targetT,
  ) {
    int lo = 0;
    int hi = times.length - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (times[mid] < targetT) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    int best = lo;
    if (lo > 0 && (targetT - times[lo - 1]).abs() < (times[lo] - targetT).abs()) {
      best = lo - 1;
    }
    return (t: times[best], v: values[best]);
  }

  List<_RefLine> _referenceLines(String key) {
    switch (key) {
      case 'lambda_v':
      case 'lambda2_v':
        return [
          _RefLine(0.45, 'Estequiom. 0.45V', MotorsportColors.warning),
        ];
      case 'stft':
      case 'ltft':
      case 'lambda_trim':
      case 'ltft_idle':
        return [
          _RefLine(0.0, '0%', MotorsportColors.ok),
          _RefLine(-15.0, '-15%', MotorsportColors.warning),
          _RefLine(15.0, '+15%', MotorsportColors.warning),
        ];
      case 'ect':
      case 'cht_temp':
      case 'cht_c':
        return [
          _RefLine(80.0, '80°C', MotorsportColors.ok),
          _RefLine(105.0, '105°C', MotorsportColors.alarm),
        ];
      case 'advance':
        return [
          _RefLine(0.0, '0° PMS', MotorsportColors.warning),
          _RefLine(-8.0, '-8° Retardo', MotorsportColors.alarm),
        ];
      case 'battery':
        return [
          _RefLine(12.6, '12.6V', MotorsportColors.warning),
          _RefLine(13.8, '13.8V', MotorsportColors.ok),
        ];
      case 'map':
        return [
          _RefLine(100.0, '100 kPa Atm', MotorsportColors.info),
        ];
      case 'boost_bar':
      case 'boost_psi':
      case 'accel_g':
        return [
          _RefLine(0.0, '0', MotorsportColors.info),
        ];
      case 'knock_retard_max':
      case 'knock_ret_c1':
      case 'knock_ret_c2':
      case 'knock_ret_c3':
      case 'knock_ret_c4':
        return [
          _RefLine(-3.0, '-3°KW', MotorsportColors.warning),
        ];
      default:
        return const [];
    }
  }

  (double, double) _computeYRange(
    String key,
    List<double> values,
    List<_RefLine> hlines,
  ) {
    if (values.isEmpty) {
      return switch (key) {
        'rpm' => (0.0, 6500.0),
        'lambda_v' || 'lambda2_v' => (0.0, 1.0),
        'stft' || 'ltft' || 'lambda_trim' => (-25.0, 25.0),
        'ect' || 'cht_temp' || 'cht_c' || 'iat' => (20.0, 115.0),
        'battery' => (10.0, 15.5),
        'tps' || 'load' => (0.0, 100.0),
        _ => (0.0, 100.0),
      };
    }
    double lo = values.first;
    double hi = values.first;
    for (final v in values) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    if (key == 'lambda_v' || key == 'lambda2_v') {
      lo = math.min(lo, 0.0);
      hi = math.max(hi, 0.95);
    }
    if ((hi - lo).abs() < 1e-4) {
      final pad = lo.abs() < 1.0 ? 1.0 : lo.abs() * 0.15;
      return (lo - pad, hi + pad);
    }
    final margin = (hi - lo) * 0.12;
    return (lo - margin, hi + margin);
  }

  String _formatValue(String key, double v) {
    switch (key) {
      case 'rpm':
      case 'ect':
      case 'iat':
      case 'cht_temp':
      case 'cht_c':
      case 'ambient':
      case 'oil_temp':
      case 'speed':
      case 'map':
        return v.toStringAsFixed(0);
      case 'lambda_v':
      case 'lambda2_v':
      case 'lambda_eq':
      case 'cmd_lambda':
        return v.toStringAsFixed(3);
      case 'battery':
      case 'inj_ms':
      case 'inj_pulse_width':
      case 'boost_bar':
      case 'accel_g':
      case 'trip_km':
      case 'trip_fuel_l':
        return v.toStringAsFixed(2);
      default:
        return v.toStringAsFixed(1);
    }
  }
}

class _StatPill extends StatelessWidget {
  const _StatPill({
    required this.label,
    required this.value,
    required this.unit,
    this.highlight,
  });

  final String label;
  final String value;
  final String unit;
  final Color? highlight;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: MotorsportColors.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: highlight?.withValues(alpha: 0.45) ??
              MotorsportColors.borderSubtle,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              color: highlight ?? MotorsportColors.muted,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              unit.isEmpty ? value : '$value $unit',
              style: MotorsportTheme.tabularStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: MotorsportColors.text,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SingleChannelPainter extends CustomPainter {
  const _SingleChannelPainter({
    required this.times,
    required this.values,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
    required this.color,
    required this.unit,
    required this.hlines,
    required this.eventTimes,
    required this.eventColors,
    required this.snappedSample,
    required this.formatter,
  });

  final List<double> times;
  final List<double> values;
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;
  final Color color;
  final String unit;
  final List<_RefLine> hlines;
  final List<double> eventTimes;
  final List<Color> eventColors;
  final ({double t, double v})? snappedSample;
  final String Function(double) formatter;

  @override
  void paint(Canvas canvas, Size size) {
    const leftPad = 48.0;
    const rightPad = 14.0;
    const topPad = 14.0;
    const bottomPad = 24.0;

    final plotRect = Rect.fromLTWH(
      leftPad,
      topPad,
      math.max(10.0, size.width - leftPad - rightPad),
      math.max(10.0, size.height - topPad - bottomPad),
    );

    final xSpan = math.max(0.1, xMax - xMin);
    final ySpan = math.max(1e-4, yMax - yMin);

    double mapX(double t) =>
        plotRect.left + ((t - xMin) / xSpan) * plotRect.width;
    double mapY(double v) =>
        plotRect.bottom - ((v - yMin) / ySpan) * plotRect.height;

    final gridPaint = Paint()
      ..color = MotorsportColors.borderSubtle
      ..strokeWidth = 0.8;

    // Grid horizontal + rótulos eixo Y
    const yTicks = 4;
    for (int i = 0; i <= yTicks; i++) {
      final frac = i / yTicks;
      final val = yMin + frac * ySpan;
      final py = mapY(val);
      canvas.drawLine(
        Offset(plotRect.left, py),
        Offset(plotRect.right, py),
        gridPaint,
      );
      _drawText(
        canvas,
        formatter(val),
        Offset(4, py - 6),
        width: leftPad - 8,
        align: TextAlign.right,
        color: MotorsportColors.muted,
        fontSize: 9.5,
      );
    }

    // Grid vertical + rótulos eixo X (tempo)
    const xTicks = 4;
    for (int i = 0; i <= xTicks; i++) {
      final frac = i / xTicks;
      final t = xMin + frac * xSpan;
      final px = mapX(t);
      canvas.drawLine(
        Offset(px, plotRect.top),
        Offset(px, plotRect.bottom),
        gridPaint,
      );
      final label = '${t.toStringAsFixed(xSpan < 20 ? 1 : 0)}s';
      _drawText(
        canvas,
        label,
        Offset(px - 22, plotRect.bottom + 5),
        width: 44,
        align: TextAlign.center,
        color: MotorsportColors.muted,
        fontSize: 9.5,
      );
    }

    canvas.save();
    canvas.clipRect(plotRect);

    // Linhas de referência semânticas (tracejadas)
    for (final line in hlines) {
      if (line.value < yMin || line.value > yMax) continue;
      final py = mapY(line.value);
      _drawDashedHLine(
        canvas,
        plotRect.left,
        plotRect.right,
        py,
        Paint()
          ..color = line.color.withValues(alpha: 0.65)
          ..strokeWidth = 1.0,
      );
      _drawText(
        canvas,
        line.label,
        Offset(plotRect.right - 108, py - 12),
        width: 104,
        align: TextAlign.right,
        color: line.color.withValues(alpha: 0.9),
        fontSize: 9,
      );
    }

    // Marcadores de eventos diagnósticos
    for (int i = 0; i < eventTimes.length; i++) {
      final px = mapX(eventTimes[i]);
      _drawDashedVLine(
        canvas,
        px,
        plotRect.top,
        plotRect.bottom,
        Paint()
          ..color = eventColors[i].withValues(alpha: 0.45)
          ..strokeWidth = 1.0,
      );
    }

    // Curva principal + preenchimento translúcido
    if (times.isNotEmpty) {
      final linePath = Path();
      final fillPath = Path();
      final firstX = mapX(times.first);
      final firstY = mapY(values.first).clamp(plotRect.top, plotRect.bottom);
      linePath.moveTo(firstX, firstY);
      fillPath.moveTo(firstX, plotRect.bottom);
      fillPath.lineTo(firstX, firstY);

      double lastX = firstX;
      for (int i = 1; i < times.length; i++) {
        final px = mapX(times[i]);
        final py = mapY(values[i]).clamp(plotRect.top, plotRect.bottom);
        // Quebra visual se houve lacuna > 6s no log (ex.: standby antigo)
        if (times[i] - times[i - 1] > 6.0) {
          fillPath.lineTo(lastX, plotRect.bottom);
          fillPath.moveTo(px, plotRect.bottom);
          fillPath.lineTo(px, py);
          linePath.moveTo(px, py);
        } else {
          linePath.lineTo(px, py);
          fillPath.lineTo(px, py);
        }
        lastX = px;
      }
      fillPath.lineTo(lastX, plotRect.bottom);
      fillPath.close();

      canvas.drawPath(
        fillPath,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0.28),
              color.withValues(alpha: 0.02),
            ],
          ).createShader(plotRect),
      );

      canvas.drawPath(
        linePath,
        Paint()
          ..color = color
          ..strokeWidth = 2.0
          ..style = PaintingStyle.stroke
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );

      // Pontos discretos quando zoom tem poucas amostras
      if (times.length <= 45) {
        final dotPaint = Paint()..color = color;
        for (int i = 0; i < times.length; i++) {
          final px = mapX(times[i]);
          final py = mapY(values[i]).clamp(plotRect.top, plotRect.bottom);
          canvas.drawCircle(Offset(px, py), 2.4, dotPaint);
        }
      }
    }

    // Crosshair interativo
    final snap = snappedSample;
    if (snap != null) {
      final px = mapX(snap.t);
      final py = mapY(snap.v).clamp(plotRect.top, plotRect.bottom);
      canvas.drawLine(
        Offset(px, plotRect.top),
        Offset(px, plotRect.bottom),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.65)
          ..strokeWidth = 1.2,
      );
      canvas.drawLine(
        Offset(plotRect.left, py),
        Offset(plotRect.right, py),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.25)
          ..strokeWidth = 0.8,
      );
      canvas.drawCircle(
        Offset(px, py),
        5.5,
        Paint()..color = color,
      );
      canvas.drawCircle(
        Offset(px, py),
        5.5,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );

      final tipText =
          '${formatter(snap.v)}${unit.isEmpty ? '' : ' $unit'} @ ${snap.t.toStringAsFixed(1)}s';
      const tipW = 128.0;
      const tipH = 22.0;
      final tipX = (px + 8 + tipW > plotRect.right)
          ? math.max(plotRect.left + 4, px - tipW - 8)
          : px + 8;
      final tipY = math.max(plotRect.top + 4, py - tipH - 6);
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(tipX, tipY, tipW, tipH),
        const Radius.circular(4),
      );
      canvas.drawRRect(
        rrect,
        Paint()..color = MotorsportColors.elevated.withValues(alpha: 0.94),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
      _drawText(
        canvas,
        tipText,
        Offset(tipX + 4, tipY + 4),
        width: tipW - 8,
        align: TextAlign.center,
        color: MotorsportColors.text,
        fontSize: 10,
        fontWeight: FontWeight.w700,
      );
    }

    canvas.restore();
  }

  void _drawDashedHLine(
    Canvas canvas,
    double x1,
    double x2,
    double y,
    Paint paint,
  ) {
    double x = x1;
    const dash = 5.0;
    const gap = 4.0;
    while (x < x2) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + dash, x2), y),
        paint,
      );
      x += dash + gap;
    }
  }

  void _drawDashedVLine(
    Canvas canvas,
    double x,
    double y1,
    double y2,
    Paint paint,
  ) {
    double y = y1;
    const dash = 4.0;
    const gap = 4.0;
    while (y < y2) {
      canvas.drawLine(
        Offset(x, y),
        Offset(x, math.min(y + dash, y2)),
        paint,
      );
      y += dash + gap;
    }
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset, {
    required double width,
    required TextAlign align,
    required Color color,
    required double fontSize,
    FontWeight fontWeight = FontWeight.w500,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      textAlign: align,
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(minWidth: width, maxWidth: width);
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _SingleChannelPainter oldDelegate) =>
      oldDelegate.times != times ||
      oldDelegate.values != values ||
      oldDelegate.xMin != xMin ||
      oldDelegate.xMax != xMax ||
      oldDelegate.yMin != yMin ||
      oldDelegate.yMax != yMax ||
      oldDelegate.snappedSample != snappedSample ||
      oldDelegate.color != color;
}
