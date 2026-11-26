import 'dart:math' as math;

/// Estimador universal de consumo instantâneo (L/h, km/l) e Eficiência Volumétrica (VE%).
///
/// Funciona em qualquer central automotiva (mesmo quando o PID 015E não for suportado),
/// utilizando medição de tempo de injeção (quando disponível) ou o método Speed-Density
/// combinando RPM, MAP, IAT e teor de etanol Flex.
class FuelEstimator {
  final double displacementL;

  const FuelEstimator({this.displacementL = 1.6});

  static double _round1(double v) => (v * 10.0).roundToDouble() / 10.0;
  static double _round2(double v) => (v * 100.0).roundToDouble() / 100.0;

  /// Calcula `fuel_rate_lph`, `fuel_econ_kml` e `volumetric_eff` a partir da telemetria.
  static Map<String, double> estimateFuelMetrics(
    Map<String, double> latest, {
    double displacementL = 1.6,
  }) {
    final rpm = latest['rpm'] ?? 0.0;
    final mapKpa = latest['map'] ?? 0.0;
    final speed = latest['speed'] ?? 0.0;
    final iat = latest['iat'] ?? 30.0;
    final injMs = latest['inj_ms'] ?? latest['inj_pulse_width'];
    final ethanolPct =
        latest['flex_ethanol_pct'] ?? latest['ethanol'] ?? 27.0;
    final tps = latest['tps'] ?? 0.0;

    // Motor parado
    if (rpm < 50.0) {
      return {
        'fuel_rate_lph': 0.0,
        'fuel_econ_kml': 0.0,
        'volumetric_eff': 0.0,
      };
    }

    // Desaceleração / Cut-Off (borboleta fechada em giro alto ou pulso zero)
    if ((injMs != null && injMs <= 0.05) ||
        (tps <= 0.5 && rpm > 1400.0 && mapKpa < 28.0)) {
      return {
        'fuel_rate_lph': 0.0,
        'fuel_econ_kml': speed > 5.0 ? 99.9 : 0.0,
        'volumetric_eff': 20.0,
      };
    }

    // Densidade e estequiometria Flex
    final ethRatio = (ethanolPct / 100.0).clamp(0.0, 1.0);
    final afrTarget = 14.7 * (1.0 - ethRatio) + 9.0 * ethRatio;
    final fuelDensity = 740.0 * (1.0 - ethRatio) + 789.0 * ethRatio; // g/L

    double fuelLph;
    // 1. Estimativa via Tempo de Injeção real (mais precisa)
    if (injMs != null && injMs > 0.05) {
      // Bico Flex a ~4.0 bar (ex.: VW EA111 1.6 TotalFlex ~275 cc/min) com dead-time ~0.85 ms
      const injectorCcMin = 275.0;
      const deadTimeMs = 0.85;
      final effInjMs = math.max(0.0, injMs - deadTimeMs);
      // 4 cilindros, 2 injeções por volta do virabrequim (ciclo 4 tempos)
      // injectorCcMin / 60.0 converte cc/min para cc/s por bico a 100% duty cycle
      final totalCcS = (rpm / 60.0) *
          2.0 *
          (effInjMs / 1000.0) *
          (injectorCcMin / 60.0);
      fuelLph = (totalCcS * 3600.0) / 1000.0;
    } else {
      // 2. Estimativa via Speed-Density (RPM, MAP, IAT)
      final normMap = math.max(0.2, mapKpa / 100.0);
      final double ve;
      if (normMap <= 1.0) {
        ve = 0.75 + 0.15 * normMap;
      } else {
        // Em motores turbo, a VE em relação ao deslocamento estático pode superar 100%
        ve = math.min(1.20, 0.90 + 0.10 * (normMap - 1.0));
      }
      final tKelvin = math.max(240.0, iat + 273.15);
      // Massa de ar em g/s = (RPM * MAP * Vd * VE * 1000) / (120 * R * T)
      final airMassGs =
          (rpm * mapKpa * displacementL * ve * 1000.0) /
              (120.0 * 287.05 * tKelvin);
      final fuelMassGs = airMassGs / afrTarget;
      fuelLph = (fuelMassGs * 3600.0) / fuelDensity;
    }

    fuelLph = math.max(0.0, fuelLph);

    // Volumetric Efficiency aproximada (permite até 135% em regimes sobrealimentados)
    final vePct = math.min(135.0, math.max(15.0, (mapKpa / 100.0) * 88.0));

    final fuelEconKml = (speed >= 3.0 && fuelLph > 0.05)
        ? _round1(math.min(99.9, speed / fuelLph))
        : 0.0;

    return {
      'fuel_rate_lph': _round2(fuelLph),
      'volumetric_eff': _round1(vePct),
      'fuel_econ_kml': fuelEconKml,
    };
  }

  Map<String, double> estimate(Map<String, double> latest) {
    return estimateFuelMetrics(latest, displacementL: displacementL);
  }

  ({double fuelRateLph, double fuelEconKml, double volumetricEff})
      estimateInstantConsumption({
    required double rpm,
    required double mapKpa,
    double iatC = 30.0,
    double speedKmh = 0.0,
    double? injMs,
    double ethanolPct = 27.0,
    double tps = 0.0,
  }) {
    final sample = <String, double>{
      'rpm': rpm,
      'map': mapKpa,
      'iat': iatC,
      'speed': speedKmh,
      'flex_ethanol_pct': ethanolPct,
      'tps': tps,
      'inj_ms': ?injMs,
    };
    final res = estimateFuelMetrics(sample, displacementL: displacementL);
    return (
      fuelRateLph: res['fuel_rate_lph'] ?? 0.0,
      fuelEconKml: res['fuel_econ_kml'] ?? 0.0,
      volumetricEff: res['volumetric_eff'] ?? 0.0,
    );
  }
}
