import 'package:material_ui/material_ui.dart';
import '../theme/motorsport_theme.dart';

enum CardAlertState { normal, warn, alarm, stale }

/// High-legibility motorsport numeric card with tabular value, unit, Peak Hold and alert state.
class ValueCard extends StatelessWidget {
  const ValueCard({
    super.key,
    required this.channelKey,
    required this.title,
    required this.unit,
    required this.formattedValue,
    this.accentColor,
    this.alertState = CardAlertState.stale,
    this.note = '',
    this.minFormatted,
    this.maxFormatted,
    this.compact = false,
    this.onTap,
    this.editMode = false,
    this.onMovePrev,
    this.onMoveNext,
    this.onChangeParameter,
    this.onRemove,
  });

  final String channelKey;
  final String title;
  final String unit;
  final String formattedValue;
  final Color? accentColor;
  final CardAlertState alertState;
  final String note;
  final String? minFormatted;
  final String? maxFormatted;
  final bool compact;
  final VoidCallback? onTap;
  final bool editMode;
  final VoidCallback? onMovePrev;
  final VoidCallback? onMoveNext;
  final VoidCallback? onChangeParameter;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final tokens = MotorsportTheme.tokensOf(context);
    final color = accentColor ?? MotorsportColors.colorForChannel(channelKey);
    final (bgColor, baseBorderColor, noteColor) = switch (alertState) {
      CardAlertState.normal => (
          tokens.surface,
          tokens.highContrast ? tokens.border : MotorsportColors.normalBorder,
          tokens.muted,
        ),
      CardAlertState.warn => (
          MotorsportColors.warnBg,
          MotorsportColors.warnBorder,
          MotorsportColors.warning,
        ),
      CardAlertState.alarm => (
          MotorsportColors.alarmBg,
          MotorsportColors.alarmBorder,
          MotorsportColors.alarm,
        ),
      CardAlertState.stale => (
          tokens.highContrast ? tokens.surface : MotorsportColors.staleBg,
          tokens.highContrast ? tokens.borderSubtle : MotorsportColors.staleBorder,
          tokens.stale,
        ),
    };

    final borderColor = editMode ? tokens.accent.withValues(alpha: 0.85) : baseBorderColor;
    final borderWidth = editMode
        ? (tokens.highContrast ? 2.2 : 1.5)
        : (alertState == CardAlertState.alarm
            ? (tokens.cardBorderWidth + 0.5)
            : tokens.cardBorderWidth);

    final stateBarColor = editMode
        ? tokens.accent
        : switch (alertState) {
            CardAlertState.normal => color,
            CardAlertState.warn => MotorsportColors.warning,
            CardAlertState.alarm => MotorsportColors.alarm,
            CardAlertState.stale => tokens.stale.withValues(alpha: 0.45),
          };

    final isPlaceholder = formattedValue == '--';
    final valueColor = isPlaceholder ? tokens.stale : color;
    final hasPeaks = minFormatted != null && maxFormatted != null;

    return Material(
      color: bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: borderColor, width: borderWidth),
      ),
      child: InkWell(
        onTap: editMode ? onChangeParameter : onTap,
        borderRadius: BorderRadius.circular(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 3,
              decoration: BoxDecoration(
                color: stateBarColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
              ),
            ),
            if (editMode)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: tokens.accent.withValues(alpha: 0.10),
                  border: Border(
                    bottom: BorderSide(
                      color: tokens.accent.withValues(alpha: 0.25),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    _EditControlButton(
                      icon: Icons.chevron_left,
                      tooltip: 'Mover para trás',
                      color: tokens.text,
                      disabledColor: tokens.stale.withValues(alpha: 0.4),
                      onTap: onMovePrev,
                    ),
                    _EditControlButton(
                      icon: Icons.chevron_right,
                      tooltip: 'Mover para frente',
                      color: tokens.text,
                      disabledColor: tokens.stale.withValues(alpha: 0.4),
                      onTap: onMoveNext,
                    ),
                    Expanded(
                      child: Tooltip(
                        message: 'Trocar parâmetro',
                        child: InkWell(
                          onTap: onChangeParameter,
                          borderRadius: BorderRadius.circular(4),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 3,
                              vertical: 3,
                            ),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.swap_horiz,
                                    size: 14,
                                    color: tokens.accent,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    'Trocar',
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: tokens.accent,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    _EditControlButton(
                      icon: Icons.delete_outline,
                      tooltip: 'Remover card',
                      color: MotorsportColors.alarm,
                      disabledColor: tokens.stale.withValues(alpha: 0.4),
                      onTap: onRemove,
                    ),
                  ],
                ),
              ),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 8 : 10,
                vertical: compact ? 6 : 8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        margin: const EdgeInsets.only(right: 5),
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tokens.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                      if (!editMode && onTap != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: Icon(
                            Icons.show_chart_rounded,
                            size: 12,
                            color: tokens.muted,
                          ),
                        ),
                      if (note.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Flexible(
                          flex: 2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: noteColor.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(2),
                            ),
                            child: Text(
                              note,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: noteColor,
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: compact ? 4 : 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Expanded(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            formattedValue,
                            maxLines: 1,
                            style: MotorsportTheme.tabularStyle(
                              fontSize: compact ? 22 : 26,
                              fontWeight: FontWeight.w800,
                              color: valueColor,
                            ),
                          ),
                        ),
                      ),
                      if (unit.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Text(
                          unit,
                          style: TextStyle(
                            color: tokens.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                  SizedBox(height: compact ? 2 : 4),
                  Text(
                    hasPeaks ? 'mín $minFormatted | máx $maxFormatted' : 'mín -- | máx --',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MotorsportTheme.tabularStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: hasPeaks ? tokens.stale : tokens.stale.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditControlButton extends StatelessWidget {
  const _EditControlButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.disabledColor,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final Color disabledColor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: Icon(
            icon,
            size: 16,
            color: onTap != null ? color : disabledColor,
          ),
        ),
      ),
    );
  }
}
