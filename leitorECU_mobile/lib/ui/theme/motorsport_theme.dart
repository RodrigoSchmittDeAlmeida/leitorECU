import 'package:material_ui/material_ui.dart';

import '../../core/settings/app_settings.dart';

/// Design tokens and colors matching the desktop Dark Motorsport theme.
class MotorsportColors {
  MotorsportColors._();

  static const Color base = Color(0xFF0D1015);
  static const Color surface = Color(0xFF151921);
  static const Color surfaceAlt = Color(0xFF13171F);
  static const Color elevated = Color(0xFF1D232D);
  static const Color plot = Color(0xFF0A0C10);
  static const Color border = Color(0xFF2C3545);
  static const Color borderSubtle = Color(0xFF1E2532);

  static const Color text = Color(0xFFE8EDF5);
  static const Color muted = Color(0xFF8B98AB);
  static const Color stale = Color(0xFF607088);

  static const Color ok = Color(0xFF00E676);
  static const Color warning = Color(0xFFFFB300);
  static const Color alarm = Color(0xFFFF3D71);
  static const Color info = Color(0xFF00D2FF);

  static const Color warnBg = Color(0xFF1D1A13);
  static const Color warnBorder = Color(0xFF614612);
  static const Color alarmBg = Color(0xFF201317);
  static const Color alarmBorder = Color(0xFF691C2F);
  static const Color staleBg = Color(0xFF12151C);
  static const Color staleBorder = Color(0xFF1A202A);
  static const Color normalBorder = Color(0xFF242E3E);

  static const Map<String, Color> channelColors = {
    'rpm': Color(0xFFFF3D71),
    'tps': Color(0xFF00D2FF),
    'map': Color(0xFFA8FF60),
    'lambda_v': Color(0xFFFFD740),
    'lambda2_v': Color(0xFFFF72B6),
    'advance': Color(0xFFB86BFF),
    'stft': Color(0xFF00E676),
    'ltft': Color(0xFFFFB300),
    'ltft_idle': Color(0xFFFFB300),
    'battery': Color(0xFF65A7FF),
    'obd_pin16_v': Color(0xFF57E2FF),
    'ecu_volt': Color(0xFF65A7FF),
    'bcm_battery_v': Color(0xFF00D2FF),
    'inj_ms': Color(0xFFFFB300),
    'inj_pulse_width': Color(0xFFFFB300),
    'ect': Color(0xFFFF7043),
    'iat': Color(0xFF84FFFF),
    'cht_temp': Color(0xFFFF8A65),
    'cat_temp': Color(0xFFFF3D71),
    'load': Color(0xFFB86BFF),
    'speed': Color(0xFF00E676),
    'flex_ethanol_pct': Color(0xFFA8FF60),
    'ethanol': Color(0xFFA8FF60),
    'app_pedal_pct': Color(0xFF00D2FF),
    'ac_pressure_kpa': Color(0xFF57E2FF),
    'wheel_speed_fl': Color(0xFF00D2FF),
    'wheel_speed_fr': Color(0xFF57E2FF),
    'wheel_speed_rl': Color(0xFF82B1FF),
    'wheel_speed_rr': Color(0xFFB86BFF),
    'steering_wheel_angle': Color(0xFFFFD740),
    'knock_ret_c1': Color(0xFFFF3D71),
    'knock_v_c1': Color(0xFFFFB300),
    'lambda_trim': Color(0xFF00E676),
    'boost_bar': Color(0xFF00D2FF),
    'boost_psi': Color(0xFF00E5FF),
    'boost_target_bar': Color(0xFFFFD740),
    'wastegate_pct': Color(0xFFFF7043),
    'lambda_eq': Color(0xFFFFD740),
    'fuel_rail_bar': Color(0xFFB86BFF),
    'cac_temp_c': Color(0xFF84FFFF),
    'oil_temp': Color(0xFFFF8A65),
    'knock_retard_max': Color(0xFFFF3D71),
    'fuel_rate_lph': Color(0xFF57E2FF),
    'fuel_econ_kml': Color(0xFF00E676),
  };

  static Color colorForChannel(String key) {
    return channelColors[key] ?? info;
  }
}

@immutable
class MotorsportVisualTokens extends ThemeExtension<MotorsportVisualTokens> {
  const MotorsportVisualTokens({
    required this.base,
    required this.surface,
    required this.surfaceAlt,
    required this.elevated,
    required this.plot,
    required this.border,
    required this.borderSubtle,
    required this.text,
    required this.muted,
    required this.stale,
    required this.accent,
    required this.highContrast,
    required this.cardBorderWidth,
  });

  final Color base;
  final Color surface;
  final Color surfaceAlt;
  final Color elevated;
  final Color plot;
  final Color border;
  final Color borderSubtle;
  final Color text;
  final Color muted;
  final Color stale;
  final Color accent;
  final bool highContrast;
  final double cardBorderWidth;

  static const MotorsportVisualTokens standard = MotorsportVisualTokens(
    base: MotorsportColors.base,
    surface: MotorsportColors.surface,
    surfaceAlt: MotorsportColors.surfaceAlt,
    elevated: MotorsportColors.elevated,
    plot: MotorsportColors.plot,
    border: MotorsportColors.border,
    borderSubtle: MotorsportColors.borderSubtle,
    text: MotorsportColors.text,
    muted: MotorsportColors.muted,
    stale: MotorsportColors.stale,
    accent: MotorsportColors.info,
    highContrast: false,
    cardBorderWidth: 1.0,
  );

  static MotorsportVisualTokens of(BuildContext context) {
    return Theme.of(context).extension<MotorsportVisualTokens>() ?? standard;
  }

  @override
  MotorsportVisualTokens copyWith({
    Color? base,
    Color? surface,
    Color? surfaceAlt,
    Color? elevated,
    Color? plot,
    Color? border,
    Color? borderSubtle,
    Color? text,
    Color? muted,
    Color? stale,
    Color? accent,
    bool? highContrast,
    double? cardBorderWidth,
  }) {
    return MotorsportVisualTokens(
      base: base ?? this.base,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      elevated: elevated ?? this.elevated,
      plot: plot ?? this.plot,
      border: border ?? this.border,
      borderSubtle: borderSubtle ?? this.borderSubtle,
      text: text ?? this.text,
      muted: muted ?? this.muted,
      stale: stale ?? this.stale,
      accent: accent ?? this.accent,
      highContrast: highContrast ?? this.highContrast,
      cardBorderWidth: cardBorderWidth ?? this.cardBorderWidth,
    );
  }

  @override
  MotorsportVisualTokens lerp(
    covariant ThemeExtension<MotorsportVisualTokens>? other,
    double t,
  ) {
    if (other is! MotorsportVisualTokens) return this;
    return MotorsportVisualTokens(
      base: Color.lerp(base, other.base, t) ?? base,
      surface: Color.lerp(surface, other.surface, t) ?? surface,
      surfaceAlt: Color.lerp(surfaceAlt, other.surfaceAlt, t) ?? surfaceAlt,
      elevated: Color.lerp(elevated, other.elevated, t) ?? elevated,
      plot: Color.lerp(plot, other.plot, t) ?? plot,
      border: Color.lerp(border, other.border, t) ?? border,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t) ?? borderSubtle,
      text: Color.lerp(text, other.text, t) ?? text,
      muted: Color.lerp(muted, other.muted, t) ?? muted,
      stale: Color.lerp(stale, other.stale, t) ?? stale,
      accent: Color.lerp(accent, other.accent, t) ?? accent,
      highContrast: t < 0.5 ? highContrast : other.highContrast,
      cardBorderWidth:
          cardBorderWidth + (other.cardBorderWidth - cardBorderWidth) * t,
    );
  }
}

class MotorsportTheme {
  MotorsportTheme._();

  static const double tabletBreakpoint = 840.0;

  static MotorsportVisualTokens tokensOf(BuildContext context) {
    return MotorsportVisualTokens.of(context);
  }

  static TextStyle tabularStyle({
    double fontSize = 20,
    FontWeight fontWeight = FontWeight.w800,
    Color color = MotorsportColors.text,
  }) {
    return TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['JetBrains Mono', 'Roboto Mono', 'Consolas'],
      fontSize: fontSize,
      fontWeight: fontWeight,
      color: color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }

  static ThemeData darkTheme() => buildTheme();

  static ThemeData buildTheme({
    AccentPreset accent = AccentPreset.cyan,
    bool highContrast = false,
  }) {
    final accentColor = accent.primaryColor;
    final tokens = highContrast
        ? MotorsportVisualTokens(
            base: const Color(0xFF000000),
            surface: const Color(0xFF0B0E14),
            surfaceAlt: const Color(0xFF111827),
            elevated: const Color(0xFF182232),
            plot: const Color(0xFF000000),
            border: const Color(0xFF64748B),
            borderSubtle: const Color(0xFF334155),
            text: const Color(0xFFFFFFFF),
            muted: const Color(0xFFCBD5E1),
            stale: const Color(0xFF94A3B8),
            accent: accentColor,
            highContrast: true,
            cardBorderWidth: 1.5,
          )
        : MotorsportVisualTokens(
            base: MotorsportColors.base,
            surface: MotorsportColors.surface,
            surfaceAlt: MotorsportColors.surfaceAlt,
            elevated: MotorsportColors.elevated,
            plot: MotorsportColors.plot,
            border: MotorsportColors.border,
            borderSubtle: MotorsportColors.borderSubtle,
            text: MotorsportColors.text,
            muted: MotorsportColors.muted,
            stale: MotorsportColors.stale,
            accent: accentColor,
            highContrast: false,
            cardBorderWidth: 1.0,
          );

    final onPrimary =
        ThemeData.estimateBrightnessForColor(accentColor) == Brightness.dark
            ? Colors.white
            : tokens.base;

    final scheme = ColorScheme.dark(
      surface: tokens.surface,
      primary: accentColor,
      onPrimary: onPrimary,
      secondary: MotorsportColors.ok,
      onSecondary: tokens.base,
      error: MotorsportColors.alarm,
      onError: Colors.white,
      onSurface: tokens.text,
      outline: tokens.border,
    );

    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
    );
    const buttonMinSize = Size(44, 42);
    const buttonPadding = EdgeInsets.symmetric(horizontal: 14, vertical: 10);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: tokens.base,
      canvasColor: tokens.surface,
      cardColor: tokens.surface,
      dividerColor: tokens.borderSubtle,
      extensions: <ThemeExtension<dynamic>>[tokens],
      appBarTheme: AppBarTheme(
        backgroundColor: tokens.surfaceAlt,
        foregroundColor: tokens.text,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: tokens.surfaceAlt,
        indicatorColor: accentColor.withValues(alpha: highContrast ? 0.26 : 0.16),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? accentColor : tokens.muted,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? accentColor : tokens.muted,
            size: 22,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: tokens.surfaceAlt,
        indicatorColor: accentColor.withValues(alpha: highContrast ? 0.26 : 0.16),
        selectedIconTheme: IconThemeData(color: accentColor, size: 22),
        unselectedIconTheme: IconThemeData(color: tokens.muted, size: 22),
        selectedLabelTextStyle: TextStyle(
          color: accentColor,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(
          color: tokens.muted,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: tokens.elevated,
          foregroundColor: tokens.text,
          side: BorderSide(color: tokens.border, width: tokens.cardBorderWidth),
          shape: buttonShape,
          minimumSize: buttonMinSize,
          padding: buttonPadding,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accentColor,
          foregroundColor: onPrimary,
          shape: buttonShape,
          minimumSize: buttonMinSize,
          padding: buttonPadding,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: tokens.text,
          side: BorderSide(color: tokens.border, width: tokens.cardBorderWidth),
          shape: buttonShape,
          minimumSize: buttonMinSize,
          padding: buttonPadding,
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accentColor,
          shape: buttonShape,
          minimumSize: buttonMinSize,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: tokens.text,
          minimumSize: buttonMinSize,
          shape: buttonShape,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: accentColor,
        inactiveTrackColor: tokens.border,
        thumbColor: accentColor,
        overlayColor: accentColor.withValues(alpha: 0.2),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return onPrimary;
          return tokens.muted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return accentColor;
          return tokens.elevated;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return accentColor;
          return tokens.border;
        }),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: tokens.elevated,
        selectedColor: accentColor.withValues(alpha: highContrast ? 0.28 : 0.18),
        labelStyle: TextStyle(
          color: tokens.text,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        secondaryLabelStyle: TextStyle(
          color: accentColor,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
        side: BorderSide(color: tokens.border, width: tokens.cardBorderWidth),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: tokens.elevated,
        labelStyle: TextStyle(color: tokens.muted),
        hintStyle: TextStyle(color: tokens.stale),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: tokens.border,
            width: tokens.cardBorderWidth,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: tokens.border,
            width: tokens.cardBorderWidth,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(
            color: accentColor,
            width: highContrast ? 2.0 : 1.5,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: tokens.elevated,
        contentTextStyle: TextStyle(color: tokens.text, fontSize: 13),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: tokens.border, width: tokens.cardBorderWidth),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: tokens.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: tokens.border, width: tokens.cardBorderWidth),
        ),
      ),
    );
  }
}
