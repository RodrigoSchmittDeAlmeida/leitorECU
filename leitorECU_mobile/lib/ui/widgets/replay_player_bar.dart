import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../state/telemetry_controller.dart';
import '../theme/motorsport_theme.dart';

/// Barra de controle completa para o Modo Replay CSV (Play/Pause, passo por amostra/tempo,
/// velocidade de reprodução, linha do tempo sincronizada e leitura instantânea do ponto).
class ReplayPlayerBar extends StatelessWidget {
  const ReplayPlayerBar({
    super.key,
    required this.controller,
    this.compact = false,
    this.exitLabel = 'Sair do Replay',
  });

  final TelemetryController controller;
  final bool compact;
  final String exitLabel;

  static const List<double> _speeds = [0.5, 1.0, 2.0, 4.0];

  double _nextSpeed(double current) {
    for (var i = 0; i < _speeds.length; i++) {
      if ((current - _speeds[i]).abs() < 0.05) {
        return _speeds[(i + 1) % _speeds.length];
      }
    }
    return 1.0;
  }

  static String _formatClock(double sec) {
    final safe = sec.isFinite && sec > 0.0 ? sec : 0.0;
    final tenths = (safe * 10.0).round();
    final totalSec = tenths ~/ 10;
    final d = tenths % 10;
    final min = totalSec ~/ 60;
    final remSec = totalSec % 60;
    return '${min.toString().padLeft(2, '0')}:${remSec.toString().padLeft(2, '0')}.$d';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final c = controller;
        final ds = c.replayDataset;
        final minT = ds?.minTime ?? 0.0;
        final rawMaxT = ds?.maxTime ?? 1.0;
        final maxT = rawMaxT > minT ? rawMaxT : minT + 0.1;
        final val = c.replayScrubTime.clamp(minT, maxT);

        final elapsed = math.max(0.0, val - minT);
        final totalDur = math.max(0.0, rawMaxT - minT);
        final totalSamples = c.replayTotalSamples;
        final sampleLabel = totalSamples == 0
            ? '0/0'
            : '${c.replayCurrentIndex + 1}/$totalSamples';
        final speedLabel = c.replaySpeed == 0.5
            ? '0.5x'
            : '${c.replaySpeed.toStringAsFixed(0)}x';
        final hasSamples = ds != null && !ds.isEmpty;

        return Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: compact ? 6 : 8,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF0E2530),
            border: Border.all(color: MotorsportColors.info),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1. Cabeçalho de status claro + contador + sair
              Row(
                children: [
                  const Icon(
                    Icons.replay,
                    color: MotorsportColors.info,
                    size: 18,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'MODO REPLAY: ${c.replayFileName ?? "CSV"}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: MotorsportTheme.tabularStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: MotorsportColors.info,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: MotorsportColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: MotorsportColors.border),
                    ),
                    child: Text(
                      sampleLabel,
                      style: MotorsportTheme.tabularStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: MotorsportColors.text,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton.icon(
                    onPressed: c.exitReplayMode,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: MotorsportColors.alarm,
                      side: const BorderSide(color: MotorsportColors.alarm),
                      minimumSize: const Size(0, 40),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                    ),
                    icon: const Icon(Icons.close, size: 15),
                    label: Text(
                      exitLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: compact ? 4 : 6),

              // 2. Controles de reprodução responsivos (Wrap evita overflow em 360dp)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _ReplayStepButton(
                    label: '-5s',
                    tooltip: 'Voltar 5 segundos',
                    onPressed:
                        hasSamples ? () => c.stepReplaySeconds(-5.0) : null,
                  ),
                  _ReplayStepButton(
                    icon: Icons.skip_previous,
                    label: 'Ant.',
                    tooltip: 'Amostra anterior',
                    onPressed:
                        hasSamples ? () => c.stepReplaySamples(-1) : null,
                  ),
                  ElevatedButton.icon(
                    onPressed: hasSamples ? c.toggleReplayPlay : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: c.replayPlaying
                          ? MotorsportColors.warning
                          : MotorsportColors.info,
                      foregroundColor: MotorsportColors.base,
                      side: BorderSide.none,
                      minimumSize: const Size(40, 40),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    icon: Icon(
                      c.replayPlaying ? Icons.pause : Icons.play_arrow,
                      size: 18,
                    ),
                    label: Text(
                      c.replayPlaying ? 'Pausar' : 'Reproduzir',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  _ReplayStepButton(
                    icon: Icons.skip_next,
                    label: 'Próx.',
                    tooltip: 'Próxima amostra',
                    onPressed: hasSamples ? () => c.stepReplaySamples(1) : null,
                  ),
                  _ReplayStepButton(
                    label: '+5s',
                    tooltip: 'Avançar 5 segundos',
                    onPressed:
                        hasSamples ? () => c.stepReplaySeconds(5.0) : null,
                  ),
                  Tooltip(
                    message: 'Velocidade de reprodução',
                    child: OutlinedButton(
                      onPressed: hasSamples
                          ? () => c.setReplaySpeed(_nextSpeed(c.replaySpeed))
                          : null,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: MotorsportColors.info,
                        side: BorderSide(
                          color: MotorsportColors.info.withValues(alpha: 0.65),
                        ),
                        backgroundColor:
                            MotorsportColors.info.withValues(alpha: 0.10),
                        minimumSize: const Size(40, 40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                      child: Text(
                        speedLabel,
                        style: MotorsportTheme.tabularStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: MotorsportColors.info,
                        ),
                      ),
                    ),
                  ),
                  Container(
                    constraints: const BoxConstraints(minHeight: 40),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: MotorsportColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: MotorsportColors.border),
                    ),
                    child: Text(
                      '${_formatClock(elapsed)} / ${_formatClock(totalDur)}',
                      style: MotorsportTheme.tabularStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: MotorsportColors.text,
                      ),
                    ),
                  ),
                ],
              ),

              // 3. Linha do tempo (Scrubber)
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                ),
                child: Slider(
                  value: val,
                  min: minT,
                  max: maxT,
                  activeColor: MotorsportColors.info,
                  inactiveColor: MotorsportColors.border,
                  onChangeStart: (_) => c.pauseReplay(),
                  onChanged: c.scrubReplay,
                ),
              ),

              // 4. Faixa de feedback instantâneo (telemetria no ponto + evento ativo)
              _InstantFeedbackStrip(
                values: c.replayValues,
                activeEventText: c.replayActiveEventText,
                compact: compact,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ReplayStepButton extends StatelessWidget {
  const _ReplayStepButton({
    this.icon,
    required this.label,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData? icon;
  final String label;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final style = OutlinedButton.styleFrom(
      foregroundColor: MotorsportColors.text,
      backgroundColor: MotorsportColors.surfaceAlt,
      side: const BorderSide(color: MotorsportColors.border),
      minimumSize: const Size(40, 40),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
    );

    final child = icon == null
        ? OutlinedButton(
            onPressed: onPressed,
            style: style,
            child: Text(
              label,
              style: MotorsportTheme.tabularStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: MotorsportColors.text,
              ),
            ),
          )
        : OutlinedButton.icon(
            onPressed: onPressed,
            style: style,
            icon: Icon(icon, size: 16),
            label: Text(
              label,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          );

    return Tooltip(message: tooltip, child: child);
  }
}

class _InstantFeedbackStrip extends StatelessWidget {
  const _InstantFeedbackStrip({
    required this.values,
    required this.activeEventText,
    required this.compact,
  });

  final Map<String, double> values;
  final String? activeEventText;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final rpm = values['rpm'];
    final speed = values['speed'];
    final ect = values['ect'];
    final cht = values['cht_temp'] ?? values['cht_c'];
    final stft = values['stft'] ?? values['lambda_trim'];

    final pills = <({String text, Color color})>[
      if (rpm != null)
        (
          text: 'RPM ${rpm.toStringAsFixed(0)}',
          color: MotorsportColors.colorForChannel('rpm'),
        ),
      if (speed != null)
        (
          text: 'Vel. ${speed.toStringAsFixed(0)} km/h',
          color: MotorsportColors.colorForChannel('speed'),
        ),
      if (ect != null)
        (
          text: 'ECT ${ect.toStringAsFixed(0)}°C',
          color: MotorsportColors.colorForChannel('ect'),
        )
      else if (cht != null)
        (
          text: 'CHT ${cht.toStringAsFixed(0)}°C',
          color: MotorsportColors.colorForChannel('cht_temp'),
        ),
      if (stft != null)
        (
          text: 'STFT ${stft >= 0 ? "+" : ""}${stft.toStringAsFixed(1)}%',
          color: MotorsportColors.colorForChannel('stft'),
        ),
    ];

    final hasEvent = activeEventText != null && activeEventText!.isNotEmpty;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 8,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: hasEvent
            ? MotorsportColors.warnBg
            : MotorsportColors.surfaceAlt.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: hasEvent
              ? MotorsportColors.warnBorder
              : MotorsportColors.borderSubtle,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pills.isNotEmpty)
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                for (final p in pills)
                  Text(
                    p.text,
                    style: MotorsportTheme.tabularStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: p.color,
                    ),
                  ),
              ],
            ),
          if (pills.isNotEmpty) SizedBox(height: compact ? 3 : 4),
          Row(
            children: [
              Icon(
                hasEvent ? Icons.warning_amber_rounded : Icons.touch_app,
                size: 14,
                color: hasEvent
                    ? MotorsportColors.warning
                    : MotorsportColors.muted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  hasEvent
                      ? activeEventText!
                      : 'Toque em Reproduzir ou arraste a barra para inspecionar ponto a ponto',
                  maxLines: compact ? 1 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: hasEvent ? FontWeight.w700 : FontWeight.w500,
                    color: hasEvent
                        ? MotorsportColors.warning
                        : MotorsportColors.muted,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
