import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../state/telemetry_controller.dart';
import '../theme/motorsport_theme.dart';

class _MapMetricSpec {
  const _MapMetricSpec({
    required this.label,
    required this.key,
    required this.decimals,
    required this.signed,
    required this.unitSuffix,
  });

  final String label;
  final String key;
  final int decimals;
  final bool signed;
  final String unitSuffix;

  String format(double v) {
    final s = v.toStringAsFixed(decimals);
    final sign = (signed && v >= 0) ? '+' : '';
    return '$sign$s$unitSuffix';
  }
}

/// Aba Mapa 2D: grade térmica RPM × MAP (100 kPa aspirado ou 250 kPa turbo).
class Map2DScreen extends StatefulWidget {
  const Map2DScreen({
    super.key,
    required this.controller,
  });

  final TelemetryController controller;

  @override
  State<Map2DScreen> createState() => _Map2DScreenState();
}

class _Map2DScreenState extends State<Map2DScreen> {
  static const List<_MapMetricSpec> _metrics = [
    _MapMetricSpec(label: 'Avanço (°)', key: 'advance', decimals: 1, signed: false, unitSuffix: '°'),
    _MapMetricSpec(label: 'STFT (%)', key: 'stft', decimals: 1, signed: true, unitSuffix: '%'),
    _MapMetricSpec(label: 'Sonda 1 (V)', key: 'lambda_v', decimals: 3, signed: false, unitSuffix: 'V'),
    _MapMetricSpec(label: 'Boost (bar)', key: 'boost_bar', decimals: 2, signed: true, unitSuffix: 'b'),
    _MapMetricSpec(label: 'Wastegate (%)', key: 'wastegate_pct', decimals: 1, signed: false, unitSuffix: '%'),
    _MapMetricSpec(label: 'Knock (°)', key: 'knock_retard_max', decimals: 1, signed: false, unitSuffix: '°'),
    _MapMetricSpec(label: 'Lambda (λ)', key: 'lambda_eq', decimals: 3, signed: false, unitSuffix: 'λ'),
    _MapMetricSpec(label: 'Temp. Motor (°C)', key: 'ect', decimals: 0, signed: false, unitSuffix: '°'),
    _MapMetricSpec(label: 'Temp. Ar (°C)', key: 'iat', decimals: 0, signed: false, unitSuffix: '°'),
  ];

  int _metricIdx = 0;
  Map2dStat _stat = Map2dStat.mean;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final map2d = widget.controller.map2d;
        final metric = _metrics[_metricIdx];
        final rpmBins = map2d.rpmBins;
        final mapBins = map2d.mapBins;
        final activeCell = map2d.lastActiveCell;

        final latestRpm = widget.controller.latest['rpm'];
        final latestMap = widget.controller.latest['map'];
        String activeText = 'Ponto de Operação: -- (aguardando > 400 RPM)';
        if (activeCell != null && latestRpm != null && latestMap != null) {
          final v = map2d.cellValue(activeCell.$1, activeCell.$2, metric.key, _stat);
          final vText = v == null
              ? '--'
              : (_stat == Map2dStat.count ? '${v.toInt()}' : metric.format(v));
          activeText =
              'Ponto: ${latestRpm.toStringAsFixed(0)} RPM × ${latestMap.toStringAsFixed(0)} kPa | Célula: $vText';
        }

        return Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildControlsBar(context, map2d, metric),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: MotorsportColors.surfaceAlt,
                  border: Border.all(color: MotorsportColors.borderSubtle),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  activeText,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: MotorsportTheme.tabularStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: MotorsportColors.warning,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '▲ EIXO VERTICAL: CARGA / MAP (kPa)   │   ► EIXO HORIZONTAL: ROTAÇÃO (RPM)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: MotorsportColors.muted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    const rowHeaderW = 64.0;
                    final availW = constraints.maxWidth - rowHeaderW;
                    final colW = math.max(54.0, availW / rpmBins.length);
                    final totalTableW = rowHeaderW + colW * rpmBins.length;
                    final rowH = math.max(
                      30.0,
                      (constraints.maxHeight - 32.0) / mapBins.length,
                    );

                    return Container(
                      decoration: BoxDecoration(
                        color: MotorsportColors.plot,
                        border: Border.all(color: MotorsportColors.borderSubtle),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: totalTableW,
                          child: Column(
                            children: [
                              _buildHeaderRow(rpmBins, rowHeaderW, colW),
                              Expanded(
                                child: SingleChildScrollView(
                                  child: Column(
                                    children: [
                                      for (var r = 0; r < mapBins.length; r++)
                                        _buildDataRow(
                                          map2d,
                                          r,
                                          mapBins[r],
                                          rpmBins.length,
                                          rowHeaderW,
                                          colW,
                                          rowH,
                                          metric,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 6),
              _buildLegend(metric.key),
            ],
          ),
        );
      },
    );
  }

  Widget _buildControlsBar(
    BuildContext context,
    Map2dAggregator map2d,
    _MapMetricSpec metric,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _LabeledDropdown<int>(
          label: 'MÉTRICA',
          value: _metricIdx,
          items: [
            for (var i = 0; i < _metrics.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text(_metrics[i].label, style: const TextStyle(fontSize: 12)),
              ),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _metricIdx = v);
          },
        ),
        _LabeledDropdown<Map2dStat>(
          label: 'MODO',
          value: _stat,
          items: const [
            DropdownMenuItem(value: Map2dStat.mean, child: Text('Média', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: Map2dStat.max, child: Text('Máximo', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: Map2dStat.min, child: Text('Mínimo', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: Map2dStat.count, child: Text('Amostras', style: TextStyle(fontSize: 12))),
          ],
          onChanged: (v) {
            if (v != null) setState(() => _stat = v);
          },
        ),
        _LabeledDropdown<bool>(
          label: 'ESCALA',
          value: map2d.isTurboScale,
          items: const [
            DropdownMenuItem(value: false, child: Text('Aspirado (100 kPa)', style: TextStyle(fontSize: 12))),
            DropdownMenuItem(value: true, child: Text('Turbo (250 kPa)', style: TextStyle(fontSize: 12))),
          ],
          onChanged: (v) {
            if (v != null) {
              setState(() => map2d.setScale(v));
            }
          },
        ),
        OutlinedButton.icon(
          onPressed: () async {
            final csv = map2d.toCsv(metric: metric.key, stat: _stat);
            await Clipboard.setData(ClipboardData(text: csv));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Matriz 2D copiada em CSV.')),
              );
            }
          },
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('Copiar CSV'),
        ),
        OutlinedButton.icon(
          onPressed: () async {
            final csv = map2d.toCsv(metric: metric.key, stat: _stat);
            try {
              await SharePlus.instance.share(
                ShareParams(text: csv, subject: 'Mapa 2D leitorECU (${metric.label})'),
              );
            } catch (_) {
              await Clipboard.setData(ClipboardData(text: csv));
            }
          },
          icon: const Icon(Icons.share, size: 16),
          label: const Text('Compartilhar'),
        ),
        OutlinedButton.icon(
          onPressed: () {
            setState(() => map2d.clear());
          },
          icon: const Icon(Icons.delete_outline, size: 16),
          label: const Text('Limpar'),
        ),
      ],
    );
  }

  Widget _buildHeaderRow(List<int> rpmBins, double rowHeaderW, double colW) {
    return Container(
      height: 30,
      color: MotorsportColors.elevated,
      child: Row(
        children: [
          Container(
            width: rowHeaderW,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              border: Border(
                right: BorderSide(color: MotorsportColors.borderSubtle),
                bottom: BorderSide(color: MotorsportColors.borderSubtle),
              ),
            ),
            child: const Text(
              'MAP\\RPM',
              style: TextStyle(
                color: MotorsportColors.muted,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          for (final rpm in rpmBins)
            Container(
              width: colW,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                border: Border(
                  right: BorderSide(color: MotorsportColors.borderSubtle),
                  bottom: BorderSide(color: MotorsportColors.borderSubtle),
                ),
              ),
              child: Text(
                '$rpm',
                style: MotorsportTheme.tabularStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: MotorsportColors.text,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDataRow(
    Map2dAggregator map2d,
    int r,
    int mapKpa,
    int numCols,
    double rowHeaderW,
    double colW,
    double rowH,
    _MapMetricSpec metric,
  ) {
    return SizedBox(
      height: rowH,
      child: Row(
        children: [
          Container(
            width: rowHeaderW,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: MotorsportColors.elevated,
              border: Border(
                right: BorderSide(color: MotorsportColors.borderSubtle),
                bottom: BorderSide(color: MotorsportColors.borderSubtle),
              ),
            ),
            child: Text(
              '$mapKpa kPa',
              style: MotorsportTheme.tabularStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: MotorsportColors.muted,
              ),
            ),
          ),
          for (var c = 0; c < numCols; c++)
            _buildCell(map2d, r, c, colW, rowH, metric),
        ],
      ),
    );
  }

  Widget _buildCell(
    Map2dAggregator map2d,
    int r,
    int c,
    double colW,
    double rowH,
    _MapMetricSpec metric,
  ) {
    final val = map2d.cellValue(r, c, metric.key, _stat);
    final isActive = map2d.lastActiveCell == (r, c);

    Color bg = const Color(0xFF11151C);
    Color fg = const Color(0xFF546E7A);
    String txt = '--';

    if (val != null) {
      if (_stat == Map2dStat.count) {
        txt = '${val.toInt()}';
        final pair = _colorForValue(metric.key, val * 2.0);
        bg = pair.$1;
        fg = pair.$2;
      } else {
        txt = metric.format(val);
        final pair = _colorForValue(metric.key, val);
        bg = pair.$1;
        fg = pair.$2;
      }
    }

    return Container(
      width: colW,
      height: rowH,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isActive && val == null ? const Color(0xFF162638) : bg,
        border: isActive
            ? Border.all(color: MotorsportColors.info, width: 2)
            : const Border(
                right: BorderSide(color: MotorsportColors.borderSubtle),
                bottom: BorderSide(color: MotorsportColors.borderSubtle),
              ),
      ),
      child: Text(
        txt,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: MotorsportTheme.tabularStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }

  static (Color bg, Color fg) _colorForValue(String metricKey, double v) {
    switch (metricKey) {
      case 'advance':
        if (v < -8.0) return (const Color(0xFF880E4F), Colors.white);
        if (v < -0.5) return (const Color(0xFF8A1C1C), Colors.white);
        if (v < 10.0) return (const Color(0xFF8C4611), Colors.white);
        if (v < 22.0) return (const Color(0xFF665914), Colors.white);
        if (v < 35.0) return (const Color(0xFF1B5E20), Colors.white);
        return (const Color(0xFF005C51), Colors.white);
      case 'stft':
        if (v < -10.0) return (const Color(0xFF163254), const Color(0xFFCFE5FF));
        if (v < -3.0) return (const Color(0xFF124357), const Color(0xFFBEEBF7));
        if (v <= 3.0) return (const Color(0xFF173E28), const Color(0xFFC6F7D7));
        if (v <= 10.0) return (const Color(0xFF4C3912), const Color(0xFFFFE4A8));
        return (const Color(0xFF5A1D23), const Color(0xFFFFD8DC));
      case 'lambda_v':
        if (v < 0.20) return (const Color(0xFF163254), const Color(0xFFCFE5FF));
        if (v < 0.45) return (const Color(0xFF124357), const Color(0xFFBEEBF7));
        if (v < 0.70) return (const Color(0xFF173E28), const Color(0xFFC6F7D7));
        return (const Color(0xFF5A1D23), const Color(0xFFFFD8DC));
      case 'boost_bar':
        if (v < 0.0) return (const Color(0xFF163254), const Color(0xFFCFE5FF));
        if (v < 0.4) return (const Color(0xFF173E28), const Color(0xFFC6F7D7));
        if (v < 1.0) return (const Color(0xFF005C51), Colors.white);
        if (v < 1.5) return (const Color(0xFF665914), const Color(0xFFFFE4A8));
        return (const Color(0xFF880E4F), Colors.white);
      case 'wastegate_pct':
        if (v < 20.0) return (const Color(0xFF163254), const Color(0xFFCFE5FF));
        if (v < 60.0) return (const Color(0xFF173E28), const Color(0xFFC6F7D7));
        if (v < 85.0) return (const Color(0xFF4C3912), const Color(0xFFFFE4A8));
        return (const Color(0xFF5A1D23), const Color(0xFFFFD8DC));
      case 'knock_retard_max':
        if (v <= 0.0) return (const Color(0xFF173E28), const Color(0xFFC6F7D7));
        if (v <= 2.5) return (const Color(0xFF665914), const Color(0xFFFFE4A8));
        if (v <= 5.0) return (const Color(0xFF8A1C1C), Colors.white);
        return (const Color(0xFF880E4F), Colors.white);
      case 'lambda_eq':
        if (v > 1.30) return (const Color(0xFF163254), const Color(0xFFCFE5FF));
        if (v > 1.08) return (const Color(0xFF5A1D23), const Color(0xFFFFD8DC));
        if (v >= 0.95) return (const Color(0xFF173E28), const Color(0xFFC6F7D7));
        if (v >= 0.82) return (const Color(0xFF005C51), Colors.white);
        return (const Color(0xFF124357), const Color(0xFFBEEBF7));
      case 'ect':
        if (v < 70.0) return (const Color(0xFF163254), const Color(0xFFCFE5FF));
        if (v <= 102.0) return (const Color(0xFF173E28), const Color(0xFFC6F7D7));
        return (const Color(0xFF5A1D23), const Color(0xFFFFD8DC));
      default:
        return (const Color(0xFF181E27), const Color(0xFFC8D1DE));
    }
  }

  Widget _buildLegend(String metricKey) {
    final swatches = switch (metricKey) {
      'advance' => const [
          ('−20° RET.', Color(0xFF880E4F)),
          ('−8°', Color(0xFF8A1C1C)),
          ('0°', Color(0xFF8C4611)),
          ('+10°', Color(0xFF665914)),
          ('+22° ALVO', Color(0xFF1B5E20)),
          ('+45° AVANÇO', Color(0xFF005C51)),
        ],
      'boost_bar' => const [
          ('VÁCUO', Color(0xFF163254)),
          ('0.0–0.4b', Color(0xFF173E28)),
          ('0.4–1.0b', Color(0xFF005C51)),
          ('1.0–1.5b', Color(0xFF665914)),
          ('>1.5b ALERTA', Color(0xFF880E4F)),
        ],
      _ => const [
          ('BAIXO / RICO', Color(0xFF163254)),
          ('IDEAL', Color(0xFF173E28)),
          ('ATENÇÃO', Color(0xFF4C3912)),
          ('CRÍTICO', Color(0xFF5A1D23)),
        ],
    };

    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final (text, color) in swatches)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }
}

class _LabeledDropdown<T> extends StatelessWidget {
  const _LabeledDropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: MotorsportColors.surface,
        border: Border.all(color: MotorsportColors.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(
              color: MotorsportColors.muted,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
            ),
          ),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              isDense: true,
              dropdownColor: MotorsportColors.elevated,
              items: items,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
