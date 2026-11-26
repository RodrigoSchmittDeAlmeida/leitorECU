import 'package:material_ui/material_ui.dart';

import '../../state/telemetry_controller.dart';
import '../theme/motorsport_theme.dart';
import 'uniform_action_button.dart';

/// Card dedicado à saúde do sistema Flex / A/F na Bosch ME7.5.30 (Blocos 103, 032, 033 e Sonda 1).
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
        final flexFixed = latest['g103_c6'] ?? latest['flex_ethanol_pct'];
        final flexDynamic = latest['g103_c5'];
        final status1038 = latest['g103_c8'];
        final ltft = latest['ltft'];
        final stft = latest['stft'];
        final lambda1 = latest['lambda_v'];

        final ectOk = (latest['ect'] ?? 0.0) >= 80.0;
        final closedLoopOk = latest['fuel_sys1'] == 2.0;
        final block1038Unlocked = status1038 != null && status1038 < 0.5;
        final noDtcs = controller.dtcs.isEmpty;

        final isLockedOnEthanol = flexFixed != null &&
            flexFixed >= 90.0 &&
            ltft != null &&
            ltft <= -12.0 &&
            status1038 != null &&
            status1038 >= 0.5;
        final allConditionsOk =
            ectOk && closedLoopOk && block1038Unlocked && noDtcs;

        final cardAccent = isLockedOnEthanol
            ? MotorsportColors.warning
            : (allConditionsOk ? MotorsportColors.ok : tokens.accent);

        final (String statusText, Color statusColor) = status1038 == null
            ? ('--', tokens.stale)
            : (status1038 >= 0.5
                ? ('TRAVADO (1)', MotorsportColors.warning)
                : ('LIBERADO (0)', MotorsportColors.ok));

        String fmtPct(double? v, {bool signed = false}) {
          if (v == null) return '--';
          final sign = (signed && v >= 0) ? '+' : '';
          return '$sign${v.toStringAsFixed(1)}%';
        }

        final ltftColor = ltft == null
            ? tokens.stale
            : (ltft.abs() > 12.0
                ? MotorsportColors.warning
                : tokens.text);
        final stftColor = stft == null
            ? tokens.stale
            : (stft.abs() > 15.0
                ? MotorsportColors.warning
                : tokens.text);

        final metrics = <_FlexMetricItem>[
          _FlexMetricItem(
            label: 'Bloco 103.6 (Flex Fixa)',
            value: fmtPct(flexFixed),
            valueColor: flexFixed == null ? tokens.stale : tokens.text,
          ),
          _FlexMetricItem(
            label: 'Bloco 103.5 (Dinâmico)',
            value: fmtPct(flexDynamic),
            valueColor: flexDynamic == null ? tokens.stale : tokens.text,
          ),
          _FlexMetricItem(
            label: 'Bloco 103.8 (Status)',
            value: statusText,
            valueColor: statusColor,
          ),
          _FlexMetricItem(
            label: 'LTFT Parcial',
            value: fmtPct(ltft, signed: true),
            valueColor: ltftColor,
          ),
          _FlexMetricItem(
            label: 'STFT',
            value: fmtPct(stft, signed: true),
            valueColor: stftColor,
          ),
          _FlexMetricItem(
            label: 'Sonda 1',
            value: lambda1 == null ? '--' : '${lambda1.toStringAsFixed(3)} V',
            valueColor: lambda1 == null ? tokens.stale : tokens.text,
          ),
        ];

        return UniformSectionCard(
          title: 'Saúde Flex / A/F (Bosch ME7.5.30)',
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
                          child: _FlexMetricTile(item: m, tokens: tokens),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
              Text(
                'PRÉ-CONDIÇÕES DE APRENDIZADO',
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
                    label: '103.8 Liberado',
                    ok: block1038Unlocked,
                    tokens: tokens,
                  ),
                  _PreconditionChip(
                    label: 'Sem Falhas (DTC)',
                    ok: noDtcs,
                    tokens: tokens,
                  ),
                ],
              ),
              if (isLockedOnEthanol) ...[
                const SizedBox(height: 10),
                _ContextBanner(
                  icon: Icons.warning_amber_rounded,
                  color: MotorsportColors.warning,
                  bg: MotorsportColors.warnBg,
                  textColor: tokens.text,
                  message:
                      'A/F travado em Etanol (${ltft.toStringAsFixed(1)}% na gasolina). '
                      'Abasteça ≥ 12–15 L com a chave desligada para destravar o Bloco 103.8.',
                ),
              ] else if (allConditionsOk) ...[
                const SizedBox(height: 10),
                _ContextBanner(
                  icon: Icons.check_circle_outline,
                  color: MotorsportColors.ok,
                  bg: const Color(0xFF0A2E1E),
                  textColor: tokens.text,
                  message:
                      'Aprendizado Flex liberado: todas as pré-condições atendidas. '
                      'Conduza em regime de carga parcial para atualizar o A/F.',
                ),
              ] else if (flexFixed != null ||
                  ltft != null ||
                  status1038 != null) ...[
                const SizedBox(height: 10),
                _ContextBanner(
                  icon: Icons.info_outline,
                  color: tokens.accent,
                  bg: tokens.surfaceAlt,
                  textColor: tokens.muted,
                  message:
                      'Aguardando pré-condições completas (ECT ≥ 80°C, malha fechada, '
                      'sem DTCs e Bloco 103.8 liberado) para aprendizado de A/F.',
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _FlexMetricItem {
  const _FlexMetricItem({
    required this.label,
    required this.value,
    required this.valueColor,
  });

  final String label;
  final String value;
  final Color valueColor;
}

class _FlexMetricTile extends StatelessWidget {
  const _FlexMetricTile({
    required this.item,
    required this.tokens,
  });

  final _FlexMetricItem item;
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
              maxLines: 3,
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
