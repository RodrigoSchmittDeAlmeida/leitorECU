import 'package:material_ui/material_ui.dart';

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

class MotorsportTheme {
  MotorsportTheme._();

  static const double tabletBreakpoint = 840.0;

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

  static ThemeData darkTheme() {
    const scheme = ColorScheme.dark(
      surface: MotorsportColors.surface,
      primary: MotorsportColors.info,
      onPrimary: MotorsportColors.base,
      secondary: MotorsportColors.ok,
      onSecondary: MotorsportColors.base,
      error: MotorsportColors.alarm,
      onError: Colors.white,
      onSurface: MotorsportColors.text,
      outline: MotorsportColors.border,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: MotorsportColors.base,
      canvasColor: MotorsportColors.surface,
      cardColor: MotorsportColors.surface,
      dividerColor: MotorsportColors.borderSubtle,
      appBarTheme: const AppBarTheme(
        backgroundColor: MotorsportColors.surfaceAlt,
        foregroundColor: MotorsportColors.text,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: MotorsportColors.surfaceAlt,
        indicatorColor: MotorsportColors.info.withValues(alpha: 0.16),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 11,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? MotorsportColors.info : MotorsportColors.muted,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? MotorsportColors.info : MotorsportColors.muted,
            size: 22,
          );
        }),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: MotorsportColors.surfaceAlt,
        indicatorColor: MotorsportColors.info.withValues(alpha: 0.16),
        selectedIconTheme: const IconThemeData(color: MotorsportColors.info, size: 22),
        unselectedIconTheme: const IconThemeData(color: MotorsportColors.muted, size: 22),
        selectedLabelTextStyle: const TextStyle(
          color: MotorsportColors.info,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: const TextStyle(
          color: MotorsportColors.muted,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: MotorsportColors.elevated,
          foregroundColor: MotorsportColors.text,
          side: const BorderSide(color: MotorsportColors.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: MotorsportColors.text,
          side: const BorderSide(color: MotorsportColors.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: MotorsportColors.elevated,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: MotorsportColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: MotorsportColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: const BorderSide(color: MotorsportColors.info),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: MotorsportColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: const BorderSide(color: MotorsportColors.border),
        ),
      ),
    );
  }
}
