import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../analytics/log_analyzer.dart';
import '../theme/motorsport_theme.dart';
import 'uniform_action_button.dart';

/// Gráfico de Dinamômetro Virtual (`cv` e `kgfm` × `RPM`) para trechos de carga alta.
class DynoCurveChart extends StatelessWidget {
  const DynoCurveChart({
    super.key,
    required this.curveA,
    this.curveB,
    this.labelA,
    this.labelB,
    this.emptyMessage =
        'Sem trechos de carga alta (TPS >= 70% ou MAP >= 88 kPa) para traçar curva.',
  });

  final List<DynoPoint> curveA;
  final List<DynoPoint>? curveB;
  final String? labelA;
  final String? labelB;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    final tokens = MotorsportTheme.tokensOf(context);
    final hasB = curveB != null && curveB!.isNotEmpty;

    return UniformSectionCard(
      title: 'Dinamômetro Virtual (cv × kgfm × RPM)',
      icon: Icons.speed,
      child: curveA.isEmpty
          ? ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 76),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: tokens.surfaceAlt,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: tokens.borderSubtle,
                    width: tokens.cardBorderWidth,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  emptyMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: tokens.muted,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ),
            )
          : _buildChartContent(context, tokens, hasB),
    );
  }

  Widget _buildChartContent(
    BuildContext context,
    MotorsportVisualTokens tokens,
    bool hasB,
  ) {
    final peakPowerA = _peakPower(curveA);
    final peakTorqueA = _peakTorque(curveA);
    final peakPowerB = hasB ? _peakPower(curveB!) : null;
    final peakTorqueB = hasB ? _peakTorque(curveB!) : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: _PeakChip(
                    title: hasB ? 'Pico Potência (A)' : 'Pico Potência',
                    value:
                        '${_fmtComma(peakPowerA.powerHp)} cv @ ${peakPowerA.rpmBin} RPM',
                    color: tokens.accent,
                    tokens: tokens,
                  ),
                ),
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: _PeakChip(
                    title: hasB ? 'Pico Torque (A)' : 'Pico Torque',
                    value:
                        '${_fmtComma(peakTorqueA.torqueKgfm)} kgfm @ ${peakTorqueA.rpmBin} RPM',
                    color: MotorsportColors.warning,
                    tokens: tokens,
                  ),
                ),
                if (hasB && peakPowerB != null && peakTorqueB != null)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxW),
                    child: _PeakChip(
                      title: 'Log B',
                      value:
                          '${_fmtComma(peakPowerB.powerHp)} cv @ ${peakPowerB.rpmBin} · ${_fmtComma(peakTorqueB.torqueKgfm)} kgfm @ ${peakTorqueB.rpmBin}',
                      color: tokens.text,
                      tokens: tokens,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _LegendDot(
                  label: 'Potência (cv)',
                  color: tokens.accent,
                  tokens: tokens,
                ),
                _LegendDot(
                  label: 'Torque (kgfm)',
                  color: MotorsportColors.warning,
                  tokens: tokens,
                ),
                if (hasB)
                  Text(
                    'Sólido = Log A · Tracejado = Log B',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: tokens.muted,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            if (labelA != null && labelA!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 10,
                runSpacing: 2,
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxW),
                    child: Text(
                      hasB ? 'A: $labelA' : labelA!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tokens.stale, fontSize: 10.5),
                    ),
                  ),
                  if (hasB && labelB != null && labelB!.isNotEmpty)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxW),
                      child: Text(
                        'B: $labelB',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: tokens.stale, fontSize: 10.5),
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: tokens.plot,
                border: Border.all(
                  color: tokens.borderSubtle,
                  width: tokens.cardBorderWidth,
                ),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SizedBox(
                height: 210,
                child: LayoutBuilder(
                  builder: (context, chartConstraints) {
                    return CustomPaint(
                      size: Size(
                        chartConstraints.maxWidth,
                        chartConstraints.maxHeight,
                      ),
                      painter: _DynoPainter(
                        curveA: curveA,
                        curveB: hasB ? curveB! : const [],
                        tokens: tokens,
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  static DynoPoint _peakPower(List<DynoPoint> pts) {
    var best = pts.first;
    for (final p in pts) {
      if (p.powerHp > best.powerHp) best = p;
    }
    return best;
  }

  static DynoPoint _peakTorque(List<DynoPoint> pts) {
    var best = pts.first;
    for (final p in pts) {
      if (p.torqueKgfm > best.torqueKgfm) best = p;
    }
    return best;
  }

  static String _fmtComma(double v) =>
      v.toStringAsFixed(1).replaceAll('.', ',');
}

class _PeakChip extends StatelessWidget {
  const _PeakChip({
    required this.title,
    required this.value,
    required this.color,
    required this.tokens,
  });

  final String title;
  final String value;
  final Color color;
  final MotorsportVisualTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: tokens.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: color.withValues(alpha: tokens.highContrast ? 0.85 : 0.45),
          width: tokens.cardBorderWidth,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tokens.muted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: MotorsportTheme.tabularStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({
    required this.label,
    required this.color,
    required this.tokens,
  });

  final String label;
  final Color color;
  final MotorsportVisualTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 3,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: tokens.text,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _DynoPainter extends CustomPainter {
  const _DynoPainter({
    required this.curveA,
    required this.curveB,
    required this.tokens,
  });

  final List<DynoPoint> curveA;
  final List<DynoPoint> curveB;
  final MotorsportVisualTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    const double leftPad = 38.0;
    const double rightPad = 38.0;
    const double topPad = 14.0;
    const double bottomPad = 24.0;

    final plotRect = Rect.fromLTWH(
      leftPad,
      topPad,
      math.max(10.0, size.width - leftPad - rightPad),
      math.max(10.0, size.height - topPad - bottomPad),
    );

    final bgPaint = Paint()..color = tokens.plot;
    canvas.drawRect(plotRect, bgPaint);

    // Determina faixas X (RPM) e Y (cv e kgfm) combinando A e B
    final allPts = <DynoPoint>[...curveA, ...curveB];
    if (allPts.isEmpty) return;

    var minRpm = allPts.first.rpmBin.toDouble();
    var maxRpm = allPts.first.rpmBin.toDouble();
    var maxHp = 0.0;
    var maxTorque = 0.0;

    for (final p in allPts) {
      final rpm = p.rpmBin.toDouble();
      if (rpm < minRpm) minRpm = rpm;
      if (rpm > maxRpm) maxRpm = rpm;
      if (p.powerHp > maxHp) maxHp = p.powerHp;
      if (p.torqueKgfm > maxTorque) maxTorque = p.torqueKgfm;
    }

    if (maxRpm - minRpm < 500.0) {
      minRpm = math.max(500.0, minRpm - 500.0);
      maxRpm = maxRpm + 500.0;
    }
    final rpmSpan = math.max(250.0, maxRpm - minRpm);

    final double hpTop = _niceTop(maxHp * 1.12, minVal: 20.0, step: 10.0);
    final double torqueTop = _niceTop(
      maxTorque * 1.12,
      minVal: 6.0,
      step: 2.0,
    );

    // Grade horizontal + eixos Y (esquerda cv, direita kgfm)
    final gridPaint = Paint()
      ..color = tokens.muted.withValues(alpha: 0.15)
      ..strokeWidth = 1.0;

    const int hDivs = 4;
    for (var i = 0; i <= hDivs; i++) {
      final y = plotRect.top + (plotRect.height * i / hDivs);
      canvas.drawLine(
        Offset(plotRect.left, y),
        Offset(plotRect.right, y),
        gridPaint,
      );

      final hpVal = hpTop * (1.0 - i / hDivs);
      _drawAxisText(
        canvas,
        hpVal.toStringAsFixed(0),
        Offset(2, y - 6),
        width: leftPad - 6,
        align: TextAlign.right,
        color: tokens.accent,
      );

      final tqVal = torqueTop * (1.0 - i / hDivs);
      _drawAxisText(
        canvas,
        tqVal.toStringAsFixed(1),
        Offset(plotRect.right + 4, y - 6),
        width: rightPad - 6,
        align: TextAlign.left,
        color: MotorsportColors.warning,
      );
    }

    // Rótulos de unidade no topo dos eixos
    _drawAxisText(
      canvas,
      'cv',
      const Offset(2, 1),
      width: leftPad - 6,
      align: TextAlign.right,
      color: tokens.accent.withValues(alpha: 0.9),
    );
    _drawAxisText(
      canvas,
      'kgfm',
      Offset(plotRect.right + 4, 1),
      width: rightPad - 6,
      align: TextAlign.left,
      color: MotorsportColors.warning.withValues(alpha: 0.9),
    );

    // Grade vertical + rótulos de RPM no eixo X
    const int vDivs = 4;
    for (var i = 0; i <= vDivs; i++) {
      final x = plotRect.left + (plotRect.width * i / vDivs);
      canvas.drawLine(
        Offset(x, plotRect.top),
        Offset(x, plotRect.bottom),
        gridPaint,
      );
      final rpmVal = minRpm + rpmSpan * (i / vDivs);
      final rpmLabel = '${(rpmVal / 1000.0).toStringAsFixed(1)}k';
      _drawAxisText(
        canvas,
        rpmLabel,
        Offset(x - 18, plotRect.bottom + 4),
        width: 36,
        align: TextAlign.center,
        color: tokens.stale,
      );
    }

    final borderPaint = Paint()
      ..color = tokens.borderSubtle
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawRect(plotRect, borderPaint);

    canvas.save();
    canvas.clipRect(plotRect);

    // Curvas Log B (tracejadas, desenhadas antes para não encobrir Log A)
    if (curveB.isNotEmpty) {
      final torqueOffsetsB = _mapPoints(
        curveB,
        plotRect,
        minRpm,
        rpmSpan,
        torqueTop,
        usePower: false,
      );
      final powerOffsetsB = _mapPoints(
        curveB,
        plotRect,
        minRpm,
        rpmSpan,
        hpTop,
        usePower: true,
      );

      _drawDashedPolyline(
        canvas,
        torqueOffsetsB,
        Paint()
          ..color = MotorsportColors.warning.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..isAntiAlias = true,
      );
      _drawDashedPolyline(
        canvas,
        powerOffsetsB,
        Paint()
          ..color = tokens.accent.withValues(alpha: 0.85)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..isAntiAlias = true,
      );
      _drawMarkers(
        canvas,
        torqueOffsetsB,
        MotorsportColors.warning.withValues(alpha: 0.85),
        radius: 2.4,
        hollow: true,
      );
      _drawMarkers(
        canvas,
        powerOffsetsB,
        tokens.accent.withValues(alpha: 0.85),
        radius: 2.6,
        hollow: true,
      );
    }

    // Curvas Log A (sólidas + marcadores)
    final torqueOffsetsA = _mapPoints(
      curveA,
      plotRect,
      minRpm,
      rpmSpan,
      torqueTop,
      usePower: false,
    );
    final powerOffsetsA = _mapPoints(
      curveA,
      plotRect,
      minRpm,
      rpmSpan,
      hpTop,
      usePower: true,
    );

    _drawSolidPolyline(
      canvas,
      torqueOffsetsA,
      Paint()
        ..color = MotorsportColors.warning
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    _drawSolidPolyline(
      canvas,
      powerOffsetsA,
      Paint()
        ..color = tokens.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true,
    );
    _drawMarkers(canvas, torqueOffsetsA, MotorsportColors.warning, radius: 2.8);
    _drawMarkers(canvas, powerOffsetsA, tokens.accent, radius: 3.2);

    canvas.restore();
  }

  List<Offset> _mapPoints(
    List<DynoPoint> pts,
    Rect plotRect,
    double minRpm,
    double rpmSpan,
    double yTop, {
    required bool usePower,
  }) {
    final offsets = <Offset>[];
    for (final pt in pts) {
      final x = plotRect.left + ((pt.rpmBin - minRpm) / rpmSpan) * plotRect.width;
      final val = usePower ? pt.powerHp : pt.torqueKgfm;
      final normY = (val / math.max(0.001, yTop)).clamp(0.0, 1.0);
      final y = plotRect.bottom - normY * plotRect.height;
      offsets.add(Offset(x, y));
    }
    return offsets;
  }

  void _drawSolidPolyline(Canvas canvas, List<Offset> pts, Paint paint) {
    if (pts.isEmpty) return;
    if (pts.length == 1) return;
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    canvas.drawPath(path, paint);
  }

  void _drawDashedPolyline(
    Canvas canvas,
    List<Offset> pts,
    Paint paint, {
    double dash = 6.0,
    double gap = 4.0,
  }) {
    if (pts.length < 2) return;
    for (var i = 0; i < pts.length - 1; i++) {
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final total = (p2 - p1).distance;
      if (total <= 0.001) continue;
      final dir = (p2 - p1) / total;
      var d = 0.0;
      while (d < total) {
        final start = p1 + dir * d;
        final end = p1 + dir * math.min(d + dash, total);
        canvas.drawLine(start, end, paint);
        d += dash + gap;
      }
    }
  }

  void _drawMarkers(
    Canvas canvas,
    List<Offset> pts,
    Color color, {
    double radius = 3.0,
    bool hollow = false,
  }) {
    if (hollow) {
      final bg = Paint()
        ..color = tokens.plot
        ..style = PaintingStyle.fill;
      final stroke = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..isAntiAlias = true;
      for (final p in pts) {
        canvas.drawCircle(p, radius, bg);
        canvas.drawCircle(p, radius, stroke);
      }
      return;
    }

    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final ring = Paint()
      ..color = tokens.plot
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..isAntiAlias = true;
    for (final p in pts) {
      canvas.drawCircle(p, radius, fill);
      canvas.drawCircle(p, radius, ring);
    }
  }

  static double _niceTop(
    double raw, {
    required double minVal,
    required double step,
  }) {
    final safe = math.max(minVal, raw);
    return (safe / step).ceil() * step;
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
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: 1,
    )..layout(minWidth: width, maxWidth: width);
    tp.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _DynoPainter oldDelegate) {
    return oldDelegate.curveA != curveA ||
        oldDelegate.curveB != curveB ||
        oldDelegate.tokens != tokens;
  }
}
