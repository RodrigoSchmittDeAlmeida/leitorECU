import 'package:material_ui/material_ui.dart';

import '../theme/motorsport_theme.dart';

enum UniformActionVariant { primary, neutral, warn, danger, info }

/// Botão de ação uniforme com altura fixa, bordas consistentes e texto autoajustável
/// para garantir alinhamento simétrico e zero overflow até em 360dp / 1.30x fontScale.
class UniformActionButton extends StatelessWidget {
  const UniformActionButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.variant = UniformActionVariant.neutral,
    this.active = false,
    this.height = 40.0,
    this.tooltip,
    this.customBg,
    this.customFg,
    this.customBorder,
    this.customIconColor,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final UniformActionVariant variant;
  final bool active;
  final double height;
  final String? tooltip;
  final Color? customBg;
  final Color? customFg;
  final Color? customBorder;
  final Color? customIconColor;

  @override
  Widget build(BuildContext context) {
    final tokens = MotorsportTheme.tokensOf(context);
    final enabled = onTap != null;

    final (bg, fg, border, iconCol) = _resolvePalette(tokens, enabled);

    final content = SizedBox(
      height: height,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: border,
            width: tokens.highContrast ? 1.5 : 1.0,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 15, color: iconCol),
                  const SizedBox(width: 5),
                ],
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      style: TextStyle(
                        color: fg,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (tooltip != null && tooltip!.isNotEmpty) {
      return Tooltip(message: tooltip!, child: content);
    }
    return content;
  }

  (Color, Color, Color, Color) _resolvePalette(
    MotorsportVisualTokens tokens,
    bool enabled,
  ) {
    if (!enabled) {
      return (
        tokens.surfaceAlt,
        tokens.stale,
        tokens.borderSubtle,
        tokens.stale,
      );
    }
    if (customBg != null || customFg != null || customBorder != null) {
      final bg = customBg ?? tokens.elevated;
      final fg = customFg ?? tokens.text;
      final br = customBorder ?? tokens.border;
      return (bg, fg, br, customIconColor ?? fg);
    }

    switch (variant) {
      case UniformActionVariant.primary:
        return (
          active ? const Color(0xFF0A4D36) : const Color(0xFF073B29),
          const Color(0xFFA9FFD3),
          MotorsportColors.ok,
          customIconColor ?? MotorsportColors.ok,
        );
      case UniformActionVariant.info:
        return (
          active
              ? tokens.accent.withValues(alpha: 0.22)
              : const Color(0xFF0E2530),
          tokens.accent,
          tokens.accent,
          customIconColor ?? tokens.accent,
        );
      case UniformActionVariant.warn:
        return (
          active ? const Color(0xFF493512) : MotorsportColors.warnBg,
          const Color(0xFFFFE2A1),
          MotorsportColors.warning,
          customIconColor ?? MotorsportColors.warning,
        );
      case UniformActionVariant.danger:
        return (
          active ? const Color(0xFF531426) : MotorsportColors.alarmBg,
          const Color(0xFFFFD6E0),
          MotorsportColors.alarm,
          customIconColor ?? MotorsportColors.alarm,
        );
      case UniformActionVariant.neutral:
        if (active) {
          return (
            tokens.accent.withValues(alpha: 0.16),
            tokens.accent,
            tokens.accent,
            customIconColor ?? tokens.accent,
          );
        }
        return (
          tokens.elevated,
          tokens.text,
          tokens.border,
          customIconColor ?? tokens.muted,
        );
    }
  }
}

/// Grid responsivo uniforme de 2 colunas (ou N colunas) para organizar botões
/// sem desalinhamentos ou quebras feias de Wrap.
class UniformButtonGrid extends StatelessWidget {
  const UniformButtonGrid({
    super.key,
    required this.children,
    this.columns = 2,
    this.tabletColumns,
    this.spacing = 8.0,
  });

  final List<Widget> children;
  final int columns;
  final int? tabletColumns;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final isTablet =
            constraints.maxWidth >= MotorsportTheme.tabletBreakpoint;
        final cols = isTablet ? (tabletColumns ?? columns) : columns;
        final safeCols = cols < 1 ? 1 : cols;
        final itemW =
            (constraints.maxWidth - spacing * (safeCols - 1)) / safeCols;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children)
              SizedBox(width: itemW, child: child),
          ],
        );
      },
    );
  }
}

/// Card de seção padronizado usando MotorsportVisualTokens (suporta Alto Contraste).
class UniformSectionCard extends StatelessWidget {
  const UniformSectionCard({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
    this.accent,
    this.trailing,
  });

  final String title;
  final IconData icon;
  final Widget child;
  final Color? accent;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = MotorsportTheme.tokensOf(context);
    final barColor = accent ?? tokens.accent;

    return Material(
      color: tokens.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: tokens.borderSubtle,
          width: tokens.cardBorderWidth,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 3,
            decoration: BoxDecoration(
              color: barColor,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(7)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 17, color: barColor),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tokens.text,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 8),
                      trailing!,
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                child,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
