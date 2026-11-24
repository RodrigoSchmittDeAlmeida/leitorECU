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

  @override
  Widget build(BuildContext context) {
    final color = accentColor ?? MotorsportColors.colorForChannel(channelKey);
    final (bgColor, borderColor, noteColor) = switch (alertState) {
      CardAlertState.normal => (
        MotorsportColors.surface,
        MotorsportColors.normalBorder,
        MotorsportColors.muted,
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
        MotorsportColors.staleBg,
        MotorsportColors.staleBorder,
        MotorsportColors.stale,
      ),
    };

    final stateBarColor = switch (alertState) {
      CardAlertState.normal => color,
      CardAlertState.warn => MotorsportColors.warning,
      CardAlertState.alarm => MotorsportColors.alarm,
      CardAlertState.stale => MotorsportColors.stale.withValues(alpha: 0.4),
    };

    final isPlaceholder = formattedValue == '--';
    final valueColor = isPlaceholder ? MotorsportColors.stale : color;
    final hasPeaks = minFormatted != null && maxFormatted != null;

    return Material(
      color: bgColor,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
        side: BorderSide(color: borderColor, width: alertState == CardAlertState.alarm ? 1.5 : 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 3,
              decoration: BoxDecoration(
                color: stateBarColor,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
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
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: MotorsportColors.muted,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                      if (onTap != null)
                        const Padding(
                          padding: EdgeInsets.only(right: 4),
                          child: Icon(
                            Icons.show_chart_rounded,
                            size: 12,
                            color: MotorsportColors.muted,
                          ),
                        ),
                      if (note.isNotEmpty) ...[
                        const SizedBox(width: 4),
                        Flexible(
                          flex: 0,
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
                          style: const TextStyle(
                            color: MotorsportColors.muted,
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
                      color: hasPeaks ? MotorsportColors.stale : MotorsportColors.stale.withValues(alpha: 0.55),
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
