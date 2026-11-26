import 'dart:math' as math;

import 'fuel_estimator.dart';

/// Resultado estruturado da avaliação de bateria e alternador.
class BatteryHealthEvaluation {
  final double voltage;
  final String status;
  final bool isCharging;
  final bool crankingOk;
  final double? minCrankVolt;
  final String message;

  const BatteryHealthEvaluation({
    required this.voltage,
    required this.status,
    required this.isCharging,
    required this.crankingOk,
    required this.minCrankVolt,
    required this.message,
  });
}

/// Calculador de canais matemáticos em tempo real derivados da telemetria OBD.
///
/// Todos os valores retornados por [compute] são estritamente `double`
/// (nunca injeta Strings em mapas de canais nem em formatadores numéricos).
class MathChannelsEngine {
  double displacementL;
  double vehicleMassKg;
  double fuelPriceBrl;

  // Integradores de viagem
  double tripLiters = 0.0;
  double tripKm = 0.0;
  double? lastT;
  double? lastSpdT;
  double lastSpdMs = 0.0;
  double? minCrankVolt;

  /// Status textual da bateria mantido fora do mapa `Map<String, double>`.
  String lastBatteryStatus = 'unknown';
  String lastBatteryMessage = '';

  MathChannelsEngine({
    this.displacementL = 1.6,
    this.vehicleMassKg = 1050.0,
    this.fuelPriceBrl = 5.89,
  });

  static double _round1(double v) => (v * 10.0).roundToDouble() / 10.0;
  static double _round2(double v) => (v * 100.0).roundToDouble() / 100.0;
  static double _round3(double v) => (v * 1000.0).roundToDouble() / 1000.0;

  void resetTrip() {
    tripLiters = 0.0;
    tripKm = 0.0;
    lastT = null;
    lastSpdT = null;
    lastSpdMs = 0.0;
    minCrankVolt = null;
  }

  static BatteryHealthEvaluation evaluateBatteryHealth(
    double voltage, {
    double rpm = 0.0,
    double? minCrankVolt,
  }) {
    final isCharging = voltage >= 13.6 && rpm >= 600.0;
    final crankingOk = minCrankVolt == null || minCrankVolt >= 9.6;

    final String status;
    final String msg;

    if (minCrankVolt != null && minCrankVolt < 9.6) {
      status = 'cranking_warning';
      msg =
          'Queda excessiva na partida (${minCrankVolt.toStringAsFixed(2)} V < 9.6 V)';
    } else if (rpm >= 600.0) {
      if (voltage >= 13.6) {
        status = 'charging_ok';
        msg = 'Alternador operando normalmente (${voltage.toStringAsFixed(2)} V)';
      } else if (voltage < 12.8) {
        status = 'alternator_fault';
        msg =
            'Tensão baixa com motor ligado (${voltage.toStringAsFixed(2)} V) — alternador deficiente';
      } else {
        status = 'charging_low';
        msg = 'Carga de flutuação (${voltage.toStringAsFixed(2)} V)';
      }
    } else {
      if (voltage >= 12.4) {
        status = 'resting_ok';
        msg =
            'Bateria em repouso com boa carga (${voltage.toStringAsFixed(2)} V)';
      } else {
        status = 'resting_low';
        msg =
            'Bateria em repouso fraca (${voltage.toStringAsFixed(2)} V < 12.4 V)';
      }
    }

    return BatteryHealthEvaluation(
      voltage: _round2(voltage),
      status: status,
      isCharging: isCharging,
      crankingOk: crankingOk,
      minCrankVolt: minCrankVolt != null ? _round2(minCrankVolt) : null,
      message: msg,
    );
  }

  /// Calcula canais derivados com base na amostra mesclada recebida.
  /// Retorna exclusivamente valores `double`.
  Map<String, double> compute(
    double t,
    Map<String, double> latest, {
    bool? speedUpdated,
  }) {
    final res = <String, double>{};

    final rpm = latest['rpm'] ?? 0.0;
    final speed = latest['speed'] ?? 0.0;
    var fuelLph = latest['fuel_rate_lph'] ?? latest['fuel_flow_lph'] ?? 0.0;
    final lambdaV = latest['lambda_v'];
    final mapKpa = latest['map'] ?? 0.0;

    // Se a ECU não informou consumo direto (015E), estima via injeção ou Speed-Density
    if (fuelLph <= 0.0) {
      final est = FuelEstimator.estimateFuelMetrics(
        latest,
        displacementL: displacementL,
      );
      fuelLph = est['fuel_rate_lph'] ?? 0.0;
      if (!latest.containsKey('fuel_rate_lph') &&
          !latest.containsKey('fuel_flow_lph')) {
        res['fuel_rate_lph'] = fuelLph;
      }
      if (!latest.containsKey('fuel_econ_kml') &&
          est.containsKey('fuel_econ_kml')) {
        res['fuel_econ_kml'] = est['fuel_econ_kml']!;
      }
      if (!latest.containsKey('volumetric_eff') &&
          est.containsKey('volumetric_eff') &&
          rpm > 600.0 &&
          mapKpa > 20.0) {
        res['volumetric_eff'] = est['volumetric_eff']!;
      }
    } else if (!latest.containsKey('fuel_econ_kml')) {
      res['fuel_econ_kml'] = (speed >= 3.0 && fuelLph > 0.05)
          ? _round1(math.min(99.9, speed / fuelLph))
          : 0.0;
    }

    // 1. Integração temporal da viagem e aceleração longitudinal
    if (lastT != null && t > lastT!) {
      final dt = t - lastT!;
      // Ignora pausas longas (>5s) de segundo plano / reconexão para não distorcer distância nem consumo
      if (dt <= 5.0) {
        tripLiters += (fuelLph / 3600.0) * dt;
        tripKm += (speed / 3600.0) * dt;
      }
    }
    lastT = t;

    final hasSpdSample = speedUpdated ?? latest.containsKey('speed');
    if (hasSpdSample) {
      final spdMs = speed / 3.6;
      if (lastSpdT != null && t > lastSpdT!) {
        final spdDt = t - lastSpdT!;
        if (spdDt >= 0.08 && spdDt <= 3.5) {
          final rawG = ((spdMs - lastSpdMs) / spdDt) / 9.80665;
          res['accel_g'] = _round2(rawG.clamp(-2.50, 2.50));
        } else if (spdDt > 3.5) {
          res['accel_g'] = 0.0;
        }
      }
      lastSpdMs = spdMs;
      lastSpdT = t;
    }

    // Métricas de Viagem
    res['trip_liters'] = _round3(tripLiters);
    res['trip_km'] = _round2(tripKm);
    res['trip_cost_brl'] = _round2(tripLiters * fuelPriceBrl);
    if (tripLiters > 0.01 && tripKm > 0.02) {
      res['trip_avg_kml'] = _round1(math.min(99.9, tripKm / tripLiters));
    } else {
      res['trip_avg_kml'] = 0.0;
    }

    // 2. Desvio da Mistura Lambda Error (%)
    final lambdaEq = latest['lambda_eq'];
    if (lambdaEq != null && lambdaEq > 0.1) {
      res['lambda_error_pct'] = _round1((lambdaEq - 1.0) * 100.0);
    } else if (lambdaV != null && lambdaV > 0.02) {
      final lambdaEst = 1.0 - (lambdaV - 0.45) * 0.35;
      res['lambda_error_pct'] = _round1((lambdaEst - 1.0) * 100.0);
    }

    // 3. Pressão Relativa de Turbo / Sobrealimentação (Boost Bar & Boost PSI)
    final rawMap = latest['map'];
    if (rawMap != null) {
      final baroRaw = latest['baro'];
      final baroKpa = (baroRaw != null && baroRaw > 0.0) ? baroRaw : 101.325;
      final boostBar = (rawMap - baroKpa) / 100.0;
      res['boost_bar'] = _round3(boostBar);
      res['boost_psi'] = _round2(boostBar * 14.50377);
    }

    // 4. Retardo de Ignição por Detonação Máximo (Knock Retard Max)
    final existingKnock = latest['knock_retard_max'];
    if (existingKnock != null) {
      res['knock_retard_max'] = _round2(existingKnock);
    } else {
      const knockKeys = [
        'knock_ret_c1',
        'knock_ret_c2',
        'knock_ret_c3',
        'knock_ret_c4',
        'knock_c1',
        'knock_c2',
        'knock_c3',
        'knock_c4',
        'g020_c1',
        'g020_c2',
        'g020_c3',
        'g020_c4',
      ];
      double? maxRet;
      for (final k in knockKeys) {
        final v = latest[k];
        if (v != null) {
          maxRet = maxRet == null ? v : math.max(maxRet, v);
        }
      }
      if (maxRet != null) {
        res['knock_retard_max'] = _round2(math.max(0.0, maxRet));
      }
    }

    // 5. Potência (cv) e Torque (kgfm) Estimados via Massa de Ar (Speed-Density)
    // Usa RPM + MAP + IAT (síncronos no mesmo frame), imune a inj_ms defasado
    // em Linha K e ao Bloco 103.5 (etanol dinâmico) travado em 100%.
    final tps = latest['tps'];
    final injMs = latest['inj_ms'] ?? latest['inj_pulse_width'];
    final isCutOff = (injMs != null && injMs <= 0.05) ||
        (tps != null && tps <= 0.5 && rpm > 1400.0 && mapKpa < 28.0);
    if (rpm > 600.0 && mapKpa > 20.0 && !isCutOff) {
      final ethanolPct =
          latest['flex_ethanol_pct'] ?? latest['ethanol'] ?? 27.0;
      final ethRatio = (ethanolPct / 100.0).clamp(0.0, 1.0);
      final iat = latest['iat'] ?? 30.0;

      final normMap = math.max(0.2, mapKpa / 100.0);
      final double ve;
      if (normMap <= 1.0) {
        final double rpmVe;
        if (rpm < 2000.0) {
          rpmVe = 0.88 + 0.12 * (rpm / 2000.0);
        } else if (rpm > 4200.0) {
          rpmVe = math.max(0.84, 1.0 - 0.06 * ((rpm - 4200.0) / 1500.0));
        } else {
          rpmVe = 1.0;
        }
        ve = (0.72 + 0.25 * normMap) * rpmVe;
      } else {
        ve = math.min(1.18, 0.97 + 0.08 * (normMap - 1.0));
      }

      final tKelvin = math.max(240.0, iat + 273.15);
      final airGs =
          (rpm * mapKpa * displacementL * ve * 1000.0) /
              (120.0 * 287.05 * tKelvin);

      // Energia térmica por g/s de ar (~2.96 kW/(g/s)) é praticamente idêntica
      // entre gasolina e etanol (+3% rendimento térmico no etanol).
      final cvPerAirGs = 1.54 * (1.0 + 0.03 * ethRatio);
      final hpGross = airGs * cvPerAirGs;

      // Perdas mecânicas (FMEP) + bombeamento em vácuo (PMEP)
      final fmepKpa = 85.0 + 0.014 * rpm + math.max(0.0, (100.0 - mapKpa) * 0.60);
      final hpLoss = (fmepKpa * displacementL * rpm / 120000.0) * 1.35962;

      final hpEst = (hpGross - hpLoss).clamp(0.0, 900.0);
      final torqueKgfm = rpm > 0.0 ? (hpEst * 716.2) / rpm : 0.0;

      res['power_hp'] = _round1(hpEst);
      res['torque_kgfm'] = _round1(torqueKgfm);
    } else {
      res['power_hp'] = 0.0;
      res['torque_kgfm'] = 0.0;
    }

    // 6. Avaliação de Tensão da Bateria / Alternador / Queda na Partida
    final volt = latest['battery'] ?? latest['battery_v'] ?? latest['ecu_volt'];
    if (volt != null) {
      if (rpm >= 50.0 && rpm <= 500.0) {
        if (minCrankVolt == null || volt < minCrankVolt!) {
          minCrankVolt = volt;
        }
      }
      final batEval = evaluateBatteryHealth(
        volt,
        rpm: rpm,
        minCrankVolt: minCrankVolt,
      );
      lastBatteryStatus = batEval.status;
      lastBatteryMessage = batEval.message;
      res['battery_charging'] = batEval.isCharging ? 1.0 : 0.0;
    }

    return res;
  }
}
