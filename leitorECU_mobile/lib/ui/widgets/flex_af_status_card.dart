import 'package:material_ui/material_ui.dart';

import '../../state/telemetry_controller.dart';
import '../theme/motorsport_theme.dart';
import 'uniform_action_button.dart';

/// Card dedicado à saúde real da mistura estequiométrica e adaptação A/F na Bosch ME7.5.30
/// utilizando exclusivamente canais verificados (Blocos 032, 033, 002.3 e 005.4).
class FlexAfStatusCard extends StatelessWidget {
  const FlexAfStatusCard({
    super.key,
    required this.controller,
  });

  final TelemetryController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = MotorsportTheme.tokensOf(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final latest = controller.latest;
        final ltftIdle = latest['ltft_idle'];
        final ltft = latest['ltft'];
        final stft = latest['stft'];
        final lambda1 = latest['lambda_v'];
        final injMs = latest['inj_ms'] ?? latest['inj_pulse_width'];
        final rpm = latest['rpm'];
        final ect = latest['ect'];
        final tps = latest['tps'];
        final speed = latest['speed'];
        final fuelSys1 = latest['fuel_sys1'];
        final g005c4 = latest['g005_c4'];

        final ectOk = (ect ?? 0.0) >= 80.0;
        final closedLoopOk =
            fuelSys1 == 2.0 || g005c4 == 5.0 || g005c4 == 6.0;
        final lambdaActiveOk = lambda1 != null && lambda1 >= 0.01;
        final noDtcs = controller.dtcs.isEmpty;

        final isWarmIdle = rpm != null &&
            rpm >= 680.0 &&
            rpm <= 960.0 &&
            ectOk &&
            (tps == null || tps < 6.5) &&
            (speed == null || speed < 2.0);

        final isSevereRich = ltft != null && ltft <= -12.0;
        final isSevereLean = ltft != null && ltft >= 12.0;
        final isHealthyMixture = ltft != null &&
            ltft.abs() <= 10.0 &&
            (ltftIdle == null || ltftIdle.abs() <= 6.0);
        final allPreconditionsOk =
            ectOk && closedLoopOk && lambdaActiveOk && noDtcs;

        final Color cardAccent;
        if (isSevereRich || isSevereLean) {
          cardAccent = ltft.abs() > 20.0
              ? MotorsportColors.alarm
              : MotorsportColors.warning;
        } else if (isHealthyMixture && allPreconditionsOk) {
          cardAccent = MotorsportColors.ok;
        } else {
          cardAccent = tokens.accent;
        }

        String fmtPct(double? v, {bool signed = false}) {
          if (v == null) return '--';
          final sign = (signed && v >= 0) ? '+' : '';
          return '$sign${v.toStringAsFixed(1)}%';
        }

        final (String loopText, Color loopColor) = switch (fuelSys1) {
          2.0 => ('Malha Fechada', MotorsportColors.ok),
          1.0 => ('Cut-Off', tokens.accent),
          4.0 => ('Enriq. WOT', MotorsportColors.warning),
          _ => g005c4 == 5.0 || g005c4 == 6.0
              ? ('Malha Fechada', MotorsportColors.ok)
              : ('--', tokens.stale),
        };

        final ltftIdleColor = ltftIdle == null
            ? tokens.stale
            : (ltftIdle.abs() > 8.0 ? MotorsportColors.warning : tokens.text);
        final ltftColor = ltft == null
            ? tokens.stale
            : (ltft.abs() > 20.0
                ? MotorsportColors.alarm
                : (ltft.abs() > 12.0 ? MotorsportColors.warning : tokens.text));
        final stftColor = stft == null
            ? tokens.stale
            : (stft.abs() > 15.0 ? MotorsportColors.warning : tokens.text);

        final Color injColor;
        if (injMs == null) {
          injColor = tokens.stale;
        } else if (isWarmIdle && injMs >= 3.0) {
          injColor = MotorsportColors.warning;
        } else {
          injColor = tokens.text;
        }

        final metrics = <_MixtureMetricItem>[
          _MixtureMetricItem(
            label: 'LTFT Lenta (032.1)',
            value: fmtPct(ltftIdle, signed: true),
            valueColor: ltftIdleColor,
          ),
          _MixtureMetricItem(
            label: 'LTFT Parcial (032.2)',
            value: fmtPct(ltft, signed: true),
            valueColor: ltftColor,
          ),
          _MixtureMetricItem(
            label: 'STFT (033.1)',
            value: fmtPct(stft, signed: true),
            valueColor: stftColor,
          ),
          _MixtureMetricItem(
            label: isWarmIdle ? 'Pulso Lenta Quente' : 'Pulso Injeção (002.3)',
            value: injMs == null ? '--' : '${injMs.toStringAsFixed(2)} ms',
            valueColor: injColor,
          ),
          _MixtureMetricItem(
            label: 'Sonda 1 (033.2)',
            value: lambda1 == null ? '--' : '${lambda1.toStringAsFixed(3)} V',
            valueColor: lambda1 == null ? tokens.stale : tokens.text,
          ),
          _MixtureMetricItem(
            label: 'Operação (005.4)',
            value: loopText,
            valueColor: loopColor,
          ),
        ];

        return UniformSectionCard(
          title: 'Saúde da Mistura & A/F (Bosch ME7.5.30)',
          icon: Icons.local_gas_station_outlined,
          accent: cardAccent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final cols = constraints.maxWidth >= 480 ? 3 : 2;
                  const gap = 8.0;
                  final itemW = (constraints.maxWidth - gap * (cols - 1)) / cols;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final m in metrics)
                        SizedBox(
                          width: itemW,
                          child: _MixtureMetricTile(item: m, tokens: tokens),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 6),
              Text(
                'Ref. lenta quente (800 rpm): ~2,1–2,6 ms Gasolina · ~3,1–3,6 ms Etanol',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tokens.muted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'CONDIÇÕES DE ADAPTAÇÃO DE MISTURA',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tokens.muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _PreconditionChip(
                    label: 'ECT ≥ 80°C',
                    ok: ectOk,
                    tokens: tokens,
                  ),
                  _PreconditionChip(
                    label: 'Malha Fechada',
                    ok: closedLoopOk,
                    tokens: tokens,
                  ),
                  _PreconditionChip(
                    label: 'Sonda Ativa',
                    ok: lambdaActiveOk,
                    tokens: tokens,
                  ),
                  _PreconditionChip(
                    label: 'Sem Falhas (DTC)',
                    ok: noDtcs,
                    tokens: tokens,
                  ),
                ],
              ),
              if (isSevereRich) ...[
                const SizedBox(height: 10),
                _ContextBanner(
                  icon: Icons.warning_amber_rounded,
                  color: MotorsportColors.warning,
                  bg: MotorsportColors.warnBg,
                  textColor: tokens.text,
                  message:
                      'Mistura rica em carga parcial (LTFT ${fmtPct(ltft, signed: true)}): '
                      'A/F aprendido em Etanol na EEPROM (faça Reset Canal 00 via VCDS) ou '
                      'excesso físico na linha (pressão > 4,2 bar, cânister N80 ou bicos).',
                ),
              ] else if (isSevereLean) ...[
                const SizedBox(height: 10),
                _ContextBanner(
                  icon: Icons.warning_amber_rounded,
                  color: MotorsportColors.warning,
                  bg: MotorsportColors.warnBg,
                  textColor: tokens.text,
                  message:
                      'Mistura pobre em carga parcial (LTFT ${fmtPct(ltft, signed: true)}): '
                      'verifique entrada de ar falso, pressão baixa da bomba/filtro ou bicos sujos.',
                ),
              ] else if (isHealthyMixture && allPreconditionsOk) ...[
                const SizedBox(height: 10),
                _ContextBanner(
                  icon: Icons.check_circle_outline,
                  color: MotorsportColors.ok,
                  bg: const Color(0xFF0A2E1E),
                  textColor: tokens.text,
                  message:
                      'Mistura estequiométrica saudável: correções LTFT Lenta e Parcial dentro da janela ideal (±10%).',
                ),
              ] else if (ltft != null || stft != null || lambda1 != null) ...[
                const SizedBox(height: 10),
                _ContextBanner(
                  icon: Icons.info_outline,
                  color: tokens.accent,
                  bg: tokens.surfaceAlt,
                  textColor: tokens.muted,
                  message:
                      'Aguardando aquecimento completo (ECT ≥ 80°C) e malha fechada estável para aprendizado de longo prazo.',
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _MixtureMetricItem {
  const _MixtureMetricItem({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;
}

class _MixtureMetricTile extends StatelessWidget {
  const _MixtureMetricTile({
    required this.item,
    required this.tokens,
  });

  final _MixtureMetricItem item;
  final MotorsportVisualTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: tokens.plot,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: tokens.borderSubtle,
          width: tokens.cardBorderWidth,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: tokens.muted,
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              item.value,
              maxLines: 1,
              softWrap: false,
              style: MotorsportTheme.tabularStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w800,
                color: item.valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreconditionChip extends StatelessWidget {
  const _PreconditionChip({
    required this.label,
    required this.ok,
    required this.tokens,
  });

  final String label;
  final bool ok;
  final MotorsportVisualTokens tokens;

  @override
  Widget build(BuildContext context) {
    final fg = ok ? MotorsportColors.ok : tokens.muted;
    final bg = ok ? const Color(0xFF103322) : tokens.surfaceAlt;
    final br = ok ? MotorsportColors.ok : tokens.borderSubtle;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: br, width: tokens.cardBorderWidth),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 13,
            color: fg,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: ok ? tokens.text : tokens.muted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ContextBanner extends StatelessWidget {
  const _ContextBanner({
    required this.icon,
    required this.color,
    required this.bg,
    required this.textColor,
    required this.message,
  });

  final IconData icon;
  final Color color;
  final Color bg;
  final Color textColor;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: textColor,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
