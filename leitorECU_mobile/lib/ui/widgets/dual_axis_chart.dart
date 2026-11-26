import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import '../theme/motorsport_theme.dart';

class ChartPoint {
  const ChartPoint(this.t, this.v);
  final double t;
  final double v;
}

class ChartHLine {
  const ChartHLine({
    required this.value,
    required this.color,
    this.rightAxis = false,
    this.dashed = true,
    this.label,
  });

  final double value;
  final Color color;
  final bool rightAxis;
  final bool dashed;
  final String? label;
}

class ChartMarker {
  const ChartMarker({
    required this.t,
    required this.color,
    this.label,
  });

  final double t;
  final Color color;
  final String? label;
}

class ChartChannelOption {
  const ChartChannelOption({
    required this.key,
    required this.label,
    required this.unit,
  });

  final String key;
  final String label;
  final String unit;
}

class ChartTraceConfig {
  const ChartTraceConfig({
    required this.slotLabel,
    required this.channelKey,
    required this.points,
    required this.readout,
    this.isRightAxis = false,
  });

  final String slotLabel;
  final String channelKey;
  final List<ChartPoint> points;
  final String readout;
  final bool isRightAxis;
}

/// High-performance CustomPainter Dual-Axis oscilloscope matching desktop DualAxisPlot.
class DualAxisChartWidget extends StatelessWidget {
  const DualAxisChartWidget({
    super.key,
    required this.title,
    required this.traces,
    required this.channelOptions,
    required this.leftRange,
    required this.rightRange,
    required this.xMin,
    required this.xMax,
    required this.onSelectChannel,
    this.hlines = const [],
    this.markers = const [],
    this.crosshairT,
    this.onCrosshairMoved,
    this.windowLabel = '30s',
    this.height = 195,
  });

  final String title;
  final List<ChartTraceConfig> traces;
  final List<ChartChannelOption> channelOptions;
  final (double, double) leftRange;
  final (double, double) rightRange;
  final double xMin;
  final double xMax;
  final void Function(int traceIndex, String newChannelKey) onSelectChannel;
  final List<ChartHLine> hlines;
  final List<ChartMarker> markers;
  final double? crosshairT;
  final ValueChanged<double>? onCrosshairMoved;
  final String windowLabel;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: MotorsportColors.plot,
        border: Border.all(color: MotorsportColors.borderSubtle),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(context),
          SizedBox(
            height: height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: onCrosshairMoved == null
                      ? null
                      : (details) => _emitCrosshair(details.localPosition.dx, constraints.maxWidth),
                  onHorizontalDragUpdate: onCrosshairMoved == null
                      ? null
                      : (details) => _emitCrosshair(details.localPosition.dx, constraints.maxWidth),
                  child: CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: _DualAxisPainter(
                      traces: traces,
                      leftRange: leftRange,
                      rightRange: rightRange,
                      xMin: xMin,
                      xMax: xMax,
                      hlines: hlines,
                      markers: markers,
                      crosshairT: crosshairT,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _emitCrosshair(double dx, double totalWidth) {
    if (onCrosshairMoved == null) return;
    const leftPad = 42.0;
    const rightPad = 42.0;
    final plotW = math.max(1.0, totalWidth - leftPad - rightPad);
    final ratio = ((dx - leftPad) / plotW).clamp(0.0, 1.0);
    final t = xMin + ratio * (xMax - xMin);
    onCrosshairMoved!(t);
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: const BoxDecoration(
        color: MotorsportColors.surfaceAlt,
        border: Border(bottom: BorderSide(color: MotorsportColors.borderSubtle)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: MotorsportColors.muted,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
          for (int i = 0; i < traces.length; i++) _buildTraceSelector(context, i, traces[i]),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: MotorsportColors.elevated,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              windowLabel,
              style: MotorsportTheme.tabularStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: MotorsportColors.stale,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTraceSelector(BuildContext context, int index, ChartTraceConfig trace) {
    final color = MotorsportColors.colorForChannel(trace.channelKey);
    final optionExists = channelOptions.any((o) => o.key == trace.channelKey);
    final currentOption = optionExists
        ? channelOptions.firstWhere((o) => o.key == trace.channelKey)
        : ChartChannelOption(key: trace.channelKey, label: trace.channelKey, unit: '');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: MotorsportColors.surface,
        border: Border.all(color: MotorsportColors.borderSubtle),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: PopupMenuButton<String>(
              tooltip: 'Selecionar canal (${trace.slotLabel})',
              padding: EdgeInsets.zero,
              color: MotorsportColors.elevated,
              onSelected: (val) => onSelectChannel(index, val),
              itemBuilder: (ctx) => channelOptions
                  .map(
                    (opt) => PopupMenuItem<String>(
                      value: opt.key,
                      height: 34,
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            margin: const EdgeInsets.only(right: 8),
                            decoration: BoxDecoration(
                              color: MotorsportColors.colorForChannel(opt.key),
                              shape: BoxShape.circle,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              opt.unit.isNotEmpty ? '${opt.label} [${opt.unit}]' : opt.label,
                              style: const TextStyle(fontSize: 12, color: MotorsportColors.text),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      '${trace.slotLabel} ${currentOption.label}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: MotorsportColors.text,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Icon(Icons.arrow_drop_down, size: 14, color: MotorsportColors.muted),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            trace.readout,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: MotorsportTheme.tabularStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _DualAxisPainter extends CustomPainter {
  const _DualAxisPainter({
    required this.traces,
    required this.leftRange,
    required this.rightRange,
    required this.xMin,
    required this.xMax,
    required this.hlines,
    required this.markers,
    required this.crosshairT,
  });

  final List<ChartTraceConfig> traces;
  final (double, double) leftRange;
  final (double, double) rightRange;
  final double xMin;
  final double xMax;
  final List<ChartHLine> hlines;
  final List<ChartMarker> markers;
  final double? crosshairT;

  @override
  void paint(Canvas canvas, Size size) {
    const double leftPad = 42.0;
    const double rightPad = 42.0;
    const double topPad = 8.0;
    const double bottomPad = 20.0;

    final plotRect = Rect.fromLTWH(
      leftPad,
      topPad,
      math.max(10.0, size.width - leftPad - rightPad),
      math.max(10.0, size.height - topPad - bottomPad),
    );

    final bgPaint = Paint()..color = MotorsportColors.plot;
    canvas.drawRect(plotRect, bgPaint);

    // Grid lines (4 horizontal, 5 vertical)
    final gridPaint = Paint()
      ..color = MotorsportColors.muted.withValues(alpha: 0.14)
      ..strokeWidth = 1.0;

    const int hDivs = 4;
    for (int i = 0; i <= hDivs; i++) {
      final y = plotRect.top + (plotRect.height * i / hDivs);
      canvas.drawLine(Offset(plotRect.left, y), Offset(plotRect.right, y), gridPaint);

      final leftVal = leftRange.$2 - (leftRange.$2 - leftRange.$1) * (i / hDivs);
      _drawAxisText(
        canvas,
        _fmtAxis(leftVal),
        Offset(2, y - 6),
        width: leftPad - 6,
        align: TextAlign.right,
        color: MotorsportColors.muted,
      );

      final rightVal = rightRange.$2 - (rightRange.$2 - rightRange.$1) * (i / hDivs);
      _drawAxisText(
        canvas,
        _fmtAxis(rightVal),
        Offset(plotRect.right + 4, y - 6),
        width: rightPad - 6,
        align: TextAlign.left,
        color: MotorsportColors.muted,
      );
    }

    const int vDivs = 5;
    final xSpan = math.max(0.001, xMax - xMin);
    for (int i = 0; i <= vDivs; i++) {
      final x = plotRect.left + (plotRect.width * i / vDivs);
      canvas.drawLine(Offset(x, plotRect.top), Offset(x, plotRect.bottom), gridPaint);

      final tVal = xMin + xSpan * (i / vDivs);
      _drawAxisText(
        canvas,
        '${tVal.toStringAsFixed(0)}s',
        Offset(x - 18, plotRect.bottom + 3),
        width: 36,
        align: TextAlign.center,
        color: MotorsportColors.stale,
      );
    }

    // Border around plot
    final borderPaint = Paint()
      ..color = MotorsportColors.borderSubtle
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawRect(plotRect, borderPaint);

    canvas.save();
    canvas.clipRect(plotRect);

    // Horizontal reference lines
    for (final hl in hlines) {
      final (minY, maxY) = hl.rightAxis ? rightRange : leftRange;
      final ySpan = math.max(0.0001, maxY - minY);
      final normY = (hl.value - minY) / ySpan;
      final py = plotRect.bottom - normY * plotRect.height;
      if (py >= plotRect.top && py <= plotRect.bottom) {
        final p = Paint()
          ..color = hl.color.withValues(alpha: 0.6)
          ..strokeWidth = 1.0;
        if (hl.dashed) {
          _drawDashedLine(canvas, Offset(plotRect.left, py), Offset(plotRect.right, py), p);
        } else {
          canvas.drawLine(Offset(plotRect.left, py), Offset(plotRect.right, py), p);
        }
        if (hl.label != null && hl.label!.isNotEmpty) {
          _drawAxisText(
            canvas,
            hl.label!,
            Offset(plotRect.left + 4, py - 11),
            width: 110,
            align: TextAlign.left,
            color: hl.color.withValues(alpha: 0.85),
          );
        }
      }
    }

    // Data curves
    for (final trace in traces) {
      if (trace.points.isEmpty) continue;
      final (minY, maxY) = trace.isRightAxis ? rightRange : leftRange;
      final ySpan = math.max(0.0001, maxY - minY);
      final color = MotorsportColors.colorForChannel(trace.channelKey);

      final path = Path();
      bool started = false;
      for (final pt in trace.points) {
        if (pt.t < xMin - xSpan * 0.05 || pt.t > xMax + xSpan * 0.05) continue;
        final px = plotRect.left + ((pt.t - xMin) / xSpan) * plotRect.width;
        final py = plotRect.bottom - ((pt.v - minY) / ySpan) * plotRect.height;
        if (!started) {
          path.moveTo(px, py);
          started = true;
        } else {
          path.lineTo(px, py);
        }
      }

      if (started) {
        final linePaint = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.75
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true;
        canvas.drawPath(path, linePaint);
      }
    }

    // Event markers
    for (final mk in markers) {
      if (mk.t < xMin || mk.t > xMax) continue;
      final px = plotRect.left + ((mk.t - xMin) / xSpan) * plotRect.width;
      final mp = Paint()
        ..color = mk.color.withValues(alpha: 0.85)
        ..strokeWidth = 1.3;
      _drawDashedLine(canvas, Offset(px, plotRect.top), Offset(px, plotRect.bottom), mp, dash: 3, gap: 3);
      if (mk.label != null && mk.label!.isNotEmpty) {
        _drawAxisText(
          canvas,
          mk.label!,
          Offset(px + 3, plotRect.top + 3),
          width: 70,
          align: TextAlign.left,
          color: mk.color,
        );
      }
    }

    // Synchronized Replay Crosshair
    if (crosshairT != null && crosshairT! >= xMin && crosshairT! <= xMax) {
      final px = plotRect.left + ((crosshairT! - xMin) / xSpan) * plotRect.width;
      final chPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.9)
        ..strokeWidth = 1.4;
      _drawDashedLine(canvas, Offset(px, plotRect.top), Offset(px, plotRect.bottom), chPaint, dash: 5, gap: 3);
    }

    canvas.restore();
  }

  String _fmtAxis(double v) {
    if (v.abs() >= 100) return v.toStringAsFixed(0);
    if (v.abs() >= 10) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }

  void _drawAxisText(
    Canvas canvas,
    String text,
    Offset offset, {
    required double width,
    required TextAlign align,
    required Color color,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 1,
    )..layout(minWidth: width, maxWidth: width);
    tp.paint(canvas, offset);
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint, {double dash = 4, double gap = 4}) {
    final total = (p2 - p1).distance;
    if (total <= 0) return;
    final dir = (p2 - p1) / total;
    double d = 0;
    while (d < total) {
      final start = p1 + dir * d;
      final end = p1 + dir * math.min(d + dash, total);
      canvas.drawLine(start, end, paint);
      d += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DualAxisPainter oldDelegate) {
    return true;
  }
}
