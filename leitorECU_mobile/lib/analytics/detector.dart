import 'dart:collection';
import 'dart:math' as math;

/// Configuração dos limiares do detector de anomalias, Cut-Off e Turbo.
class DetectorConfig {
  final double rpmStart;
  final double rpmDrop;
  final double dropWindow;
  final double tpsMax;
  final double rpmEnd;
  final double lambdaRich;
  final double lambdaLeanOk;
  final double lambdaEqRich;
  final double lambdaEqLeanOk;
  final double advanceMin;
  final double overboostLimit;
  final double overboostDelta;
  final double underboostDelta;
  final double knockWarn;
  final double knockAlarm;
  final double trimDriftLimit;
  final double maxDuration;
  final double freshness;

  const DetectorConfig({
    this.rpmStart = 3000.0,
    this.rpmDrop = 400.0,
    this.dropWindow = 2.0,
    this.tpsMax = 15.0,
    this.rpmEnd = 1300.0,
    this.lambdaRich = 0.70,
    this.lambdaLeanOk = 0.20,
    this.lambdaEqRich = 0.85,
    this.lambdaEqLeanOk = 1.50,
    this.advanceMin = -5.0,
    this.overboostLimit = 1.80,
    this.overboostDelta = 0.25,
    this.underboostDelta = 0.40,
    this.knockWarn = 3.0,
    this.knockAlarm = 6.0,
    this.trimDriftLimit = 22.0,
    this.maxDuration = 12.0,
    this.freshness = 1.5,
  });
}

/// Evento de diagnóstico emitido pelo [DecelDetector].
class DiagnosticEvent {
  final double timeSec;
  final String level; // 'info' | 'warn' | 'alarm'
  final String message;

  const DiagnosticEvent(this.timeSec, this.level, this.message);

  @override
  String toString() =>
      '[${timeSec.toStringAsFixed(2)}s][$level] $message';
}

/// Detector automático de desaceleração / Cut-Off, anomalias e diagnósticos Turbo.
class DecelDetector {
  final DetectorConfig cfg;

  final Queue<({double t, double rpm})> rpmHist = Queue();
  bool inDecel = false;

  double _lastVacuumAlert = -1e9;
  double _lastAtdcAlert = -1e9;
  bool crankInProgress = false;
  double? minCrankVolt;
  double lastCrankEvent = -1e9;

  double? _overboostStart;
  double _lastOverboostAlert = -1e9;
  double? _underboostStart;
  double _lastUnderboostAlert = -1e9;
  double _lastKnockAlert = -1e9;
  double? _trimDriftStart;
  double _lastTrimDriftAlert = -1e9;

  // Monitor de Termostática & Eletroventilador
  double? _lastThermalT;
  double _warmupRunSec = 0.0;
  double? _lowThermostatStart;
  double _lastThermostatAlert = -1e9;
  double _peakEctCycle = 0.0;
  bool _fanCoolAlerted = false;
  double _lastFanCycleAlert = -1e9;
  double _lastOverheatAlert = -1e9;

  // Estado do episódio de desaceleração
  double _tStart = 0.0;
  double _rpmPeak = 0.0;
  double? _maxLambda;
  double? _minLambda;
  double? _maxLambdaEq;
  double? _minLambdaEq;
  double? _minAdv;
  bool _richAlerted = false;
  bool _advAlerted = false;

  DecelDetector({DetectorConfig? cfg}) : cfg = cfg ?? const DetectorConfig();

  void reset() {
    rpmHist.clear();
    inDecel = false;
    _lastVacuumAlert = -1e9;
    _lastAtdcAlert = -1e9;
    crankInProgress = false;
    minCrankVolt = null;
    lastCrankEvent = -1e9;
    _overboostStart = null;
    _lastOverboostAlert = -1e9;
    _underboostStart = null;
    _lastUnderboostAlert = -1e9;
    _lastKnockAlert = -1e9;
    _trimDriftStart = null;
    _lastTrimDriftAlert = -1e9;
    _lastThermalT = null;
    _warmupRunSec = 0.0;
    _lowThermostatStart = null;
    _lastThermostatAlert = -1e9;
    _peakEctCycle = 0.0;
    _fanCoolAlerted = false;
    _lastFanCycleAlert = -1e9;
    _lastOverheatAlert = -1e9;
    resetEpisode();
  }

  void resetEpisode() {
    _tStart = 0.0;
    _rpmPeak = 0.0;
    _maxLambda = null;
    _minLambda = null;
    _maxLambdaEq = null;
    _minLambdaEq = null;
    _minAdv = null;
    _richAlerted = false;
    _advAlerted = false;
  }

  List<DiagnosticEvent> update(
    double t,
    Map<String, double> latest,
    Map<String, double> stamp,
  ) {
    final c = cfg;
    final ev = <DiagnosticEvent>[];

    bool fresh(String k) =>
        latest.containsKey(k) && (t - (stamp[k] ?? -1e9)) <= c.freshness;

    // 1. Conflito de Carga / Vácuo Baixo / Ar Falso (tolerância < 0.25s)
    if (fresh('rpm') &&
        fresh('map') &&
        (fresh('tps') || latest.containsKey('tps')) &&
        ((stamp['map'] ?? 0.0) - (stamp['tps'] ?? -99.0)).abs() < 0.25) {
      final rpmVal = latest['rpm']!;
      final tpsVal = latest['tps'] ?? 0.0;
      final mapVal = latest['map']!;
      // Somente com motor em funcionamento (>= 450 RPM); em KOEO (0 RPM) MAP ~101 kPa é normal.
      if (rpmVal >= 450.0 && rpmVal < 1900.0 && tpsVal < 8.0 && mapVal > 60.0) {
        if (t - _lastVacuumAlert >= 2.0) {
          _lastVacuumAlert = t;
          ev.add(DiagnosticEvent(
            t,
            'alarm',
            'CARGA ANORMAL COM BORBOLETA FECHADA: MAP em ${mapVal.toStringAsFixed(1)} kPa '
            'com TPS ${tpsVal.toStringAsFixed(1)}% a ${rpmVal.toStringAsFixed(0)} RPM',
          ));
        }
      }
    }

    // 2. Retardo Crítico ATDC (< -8.0°) — somente com motor funcionando
    if (fresh('advance') && (!fresh('rpm') || latest['rpm']! >= 450.0)) {
      final advVal = latest['advance']!;
      if (advVal < -8.0) {
        if (t - _lastAtdcAlert >= 2.0) {
          _lastAtdcAlert = t;
          final fSys = latest['fuel_sys1'];
          final lv = latest['lambda_v'];
          final String malhaStr;
          if (fSys == 2.0 || (lv != null && lv > 0.35)) {
            malhaStr = 'malha fechada sem Cut-Off';
          } else if (fSys == 1.0 || (lv != null && lv <= 0.15)) {
            malhaStr = 'Cut-Off ativo / Open Loop';
          } else {
            malhaStr = 'malha não confirmada';
          }
          final mapStr =
              fresh('map') ? ', MAP ${latest['map']!.toStringAsFixed(1)} kPa' : '';
          final rpmStr =
              fresh('rpm') ? ' a ${latest['rpm']!.toStringAsFixed(0)} RPM' : '';
          ev.add(DiagnosticEvent(
            t,
            'alarm',
            'RETARDO CRÍTICO ATDC: avanço em ${advVal.toStringAsFixed(1)}°$mapStr$rpmStr '
            '— $malhaStr (risco de pipoco e vibração)',
          ));
        }
      }
    }

    // 3. Teste de Queda de Tensão na Partida (Cranking Voltage Drop)
    if (fresh('rpm')) {
      final rpmCur = latest['rpm']!;
      final volt =
          latest['battery'] ?? latest['obd_pin16_v'] ?? latest['ecu_volt'];
      if (rpmCur >= 50.0 && rpmCur <= 450.0) {
        if (!crankInProgress) {
          crankInProgress = true;
          minCrankVolt = volt;
        } else if (volt != null) {
          minCrankVolt =
              minCrankVolt == null ? volt : math.min(minCrankVolt!, volt);
        }
      } else if (rpmCur >= 650.0) {
        if (crankInProgress && (t - lastCrankEvent >= 5.0)) {
          crankInProgress = false;
          lastCrankEvent = t;
          final vMin = minCrankVolt;
          if (vMin != null) {
            if (vMin >= 10.2) {
              ev.add(DiagnosticEvent(
                t,
                'info',
                'Partida do motor concluída: tensão mínima ${vMin.toStringAsFixed(2)} V — Bateria e arranque EXCELENTES',
              ));
            } else if (vMin >= 9.6) {
              ev.add(DiagnosticEvent(
                t,
                'info',
                'Partida do motor: tensão mínima ${vMin.toStringAsFixed(2)} V — Bateria NORMAL',
              ));
            } else if (vMin >= 8.5) {
              ev.add(DiagnosticEvent(
                t,
                'warn',
                'ATENÇÃO: Queda moderada de tensão na partida (${vMin.toStringAsFixed(2)} V) — Bateria com carga baixa',
              ));
            } else {
              ev.add(DiagnosticEvent(
                t,
                'alarm',
                'ALERTA: Queda severa de tensão na partida (${vMin.toStringAsFixed(2)} V < 9.6 V) — Bateria fraca ou aterramento deficiente!',
              ));
            }
          }
        }
      } else if (rpmCur < 40.0) {
        crankInProgress = false;
      }
    }

    // 4. Overboost Crítico
    final boostBar = latest['boost_bar'];
    final targetBoost = latest['boost_target_bar'];
    if (boostBar != null) {
      final bool isOverboost;
      if (targetBoost != null && targetBoost > 0.10) {
        isOverboost = boostBar > (targetBoost + c.overboostDelta);
      } else {
        isOverboost = boostBar > c.overboostLimit;
      }

      if (isOverboost) {
        if (_overboostStart == null) {
          _overboostStart = t;
        } else if ((t - _overboostStart! >= 0.4) &&
            (t - _lastOverboostAlert >= 2.5)) {
          _lastOverboostAlert = t;
          final alvoMsg = targetBoost != null
              ? ' (alvo: ${targetBoost.toStringAsFixed(2)} bar)'
              : ' (> ${c.overboostLimit.toStringAsFixed(2)} bar)';
          ev.add(DiagnosticEvent(
            t,
            'alarm',
            'OVERBOOST CRÍTICO: pressão em ${boostBar.toStringAsFixed(2)} bar$alvoMsg — '
            'risco iminente de rompimento de mangueiras/turbina',
          ));
        }
      } else {
        _overboostStart = null;
      }
    }

    // 5. Underboost / Vazamento de Pressão
    if (fresh('rpm') &&
        (fresh('tps') || latest.containsKey('tps')) &&
        boostBar != null &&
        targetBoost != null) {
      final rpmVal = latest['rpm']!;
      final tpsVal = latest['tps'] ?? 0.0;
      if (tpsVal > 80.0 &&
          rpmVal > 3000.0 &&
          targetBoost >= 0.50 &&
          (boostBar < targetBoost - c.underboostDelta)) {
        if (_underboostStart == null) {
          _underboostStart = t;
        } else if ((t - _underboostStart! >= 1.5) &&
            (t - _lastUnderboostAlert >= 4.0)) {
          _lastUnderboostAlert = t;
          ev.add(DiagnosticEvent(
            t,
            'warn',
            'UNDERBOOST / VAZAMENTO DE PRESSÃO: ${boostBar.toStringAsFixed(2)} bar com alvo em ${targetBoost.toStringAsFixed(2)} bar '
            'a ${rpmVal.toStringAsFixed(0)} RPM e TPS ${tpsVal.toStringAsFixed(0)}%',
          ));
        }
      } else {
        _underboostStart = null;
      }
    } else {
      _underboostStart = null;
    }

    // 6. Retardo de Ignição por Detonação (Knock Retard)
    final knockMax = latest['knock_retard_max'];
    if (knockMax != null) {
      if (knockMax >= c.knockAlarm) {
        if (t - _lastKnockAlert >= 2.0) {
          _lastKnockAlert = t;
          ev.add(DiagnosticEvent(
            t,
            'alarm',
            'DETONAÇÃO CRÍTICA (KNOCK): retardo em ${knockMax.toStringAsFixed(1)}°KW (>= ${c.knockAlarm.toStringAsFixed(1)}°) — '
            'risco imediato de danos aos pistões!',
          ));
        }
      } else if (knockMax >= c.knockWarn) {
        if (t - _lastKnockAlert >= 3.0) {
          _lastKnockAlert = t;
          ev.add(DiagnosticEvent(
            t,
            'warn',
            'DETONAÇÃO MODERADA: retardo de ignição em ${knockMax.toStringAsFixed(1)}°KW (>= ${c.knockWarn.toStringAsFixed(1)}°)',
          ));
        }
      }
    }

    // 7. Desvio Severo de Mistura (|STFT + LTFT| > 22% sustentado)
    final stft = latest['stft'];
    final ltft = latest['ltft'];
    if (stft != null && ltft != null && fresh('rpm')) {
      final rpmVal = latest['rpm']!;
      final tpsVal = latest['tps'] ?? 0.0;
      if (rpmVal >= 650.0 && rpmVal <= 3800.0 && tpsVal <= 50.0) {
        final totalTrim = stft + ltft;
        if (totalTrim.abs() > c.trimDriftLimit) {
          if (_trimDriftStart == null) {
            _trimDriftStart = t;
          } else if ((t - _trimDriftStart! >= 2.0) &&
              (t - _lastTrimDriftAlert >= 5.0)) {
            _lastTrimDriftAlert = t;
            final dirStr = totalTrim > 0
                ? 'POSITIVO (mistura pobre / ar falso / bicos sujos)'
                : 'NEGATIVO (mistura rica / bico gotejando / excesso de etanol)';
            final sign = totalTrim >= 0 ? '+' : '';
            ev.add(DiagnosticEvent(
              t,
              'warn',
              'DESVIO SEVERO DE MISTURA (A/F DRIFT): Correção Total $sign${totalTrim.toStringAsFixed(1)}% '
              'em regime estável — $dirStr',
            ));
          }
        } else {
          _trimDriftStart = null;
        }
      } else {
        _trimDriftStart = null;
      }
    }

    // 7b. Monitor de Termostática & Eletroventilador
    if (_lastThermalT != null) {
      final dt = t - _lastThermalT!;
      if (dt > 0.0 && dt <= 5.0 && fresh('rpm') && latest['rpm']! >= 650.0) {
        _warmupRunSec += dt;
      }
    }
    _lastThermalT = t;

    if (fresh('ect') && fresh('rpm') && latest['rpm']! >= 650.0) {
      final ect = latest['ect']!;
      final spd = latest['speed'] ?? 0.0;
      if (_warmupRunSec >= 360.0 && spd >= 40.0 && ect < 75.0) {
        if (_lowThermostatStart == null) {
          _lowThermostatStart = t;
        } else if ((t - _lowThermostatStart! >= 20.0) &&
            (t - _lastThermostatAlert >= 60.0)) {
          _lastThermostatAlert = t;
          ev.add(DiagnosticEvent(
            t,
            'warn',
            'TERMOSTÁTICA POSSIVELMENTE ABERTA: ECT em ${ect.toStringAsFixed(1)} °C em movimento após aquecimento (< 75 °C)',
          ));
        }
      } else {
        _lowThermostatStart = null;
      }
    } else {
      _lowThermostatStart = null;
    }

    if (fresh('ect')) {
      final ect = latest['ect']!;
      if (ect >= 108.0) {
        if (t - _lastOverheatAlert >= 10.0) {
          _lastOverheatAlert = t;
          ev.add(DiagnosticEvent(
            t,
            'alarm',
            'SUPERAQUECIMENTO CRÍTICO: ECT em ${ect.toStringAsFixed(1)} °C — pare o veículo e verifique o arrefecimento!',
          ));
        }
      } else if (ect >= 103.0) {
        if (t - _lastOverheatAlert >= 20.0) {
          _lastOverheatAlert = t;
          ev.add(DiagnosticEvent(
            t,
            'warn',
            'TEMPERATURA ELEVADA: ECT em ${ect.toStringAsFixed(1)} °C — monitore o eletroventilador',
          ));
        }
      }

      if (ect >= 96.0) {
        _peakEctCycle = math.max(_peakEctCycle, ect);
        _fanCoolAlerted = false;
      }
      if (_peakEctCycle >= 96.0 &&
          !_fanCoolAlerted &&
          ect <= _peakEctCycle - 5.0 &&
          (t - _lastFanCycleAlert >= 45.0)) {
        _lastFanCycleAlert = t;
        ev.add(DiagnosticEvent(
          t,
          'info',
          'Ciclo do eletroventilador OK: ECT resfriou de ${_peakEctCycle.toStringAsFixed(0)} °C para ${ect.toStringAsFixed(0)} °C',
        ));
        _fanCoolAlerted = true;
        _peakEctCycle = ect;
      }
    }

    // 8. Detector de Desaceleração / Cut-Off
    if (!fresh('rpm')) {
      return ev;
    }

    final rpm = latest['rpm']!;
    final tps = fresh('tps') ? latest['tps'] : null;
    final rpmStamp = stamp['rpm'] ?? t;
    if (rpmHist.isEmpty || rpmHist.last.t != rpmStamp) {
      rpmHist.addLast((t: rpmStamp, rpm: rpm));
    }
    while (rpmHist.isNotEmpty && (t - rpmHist.first.t) > c.dropWindow) {
      rpmHist.removeFirst();
    }

    if (!inDecel) {
      if (tps == null || tps >= c.tpsMax) {
        return ev;
      }
      var peak = rpm;
      for (final item in rpmHist) {
        if (item.rpm > peak) peak = item.rpm;
      }
      if (peak >= c.rpmStart && rpm <= peak - c.rpmDrop) {
        inDecel = true;
        resetEpisode();
        _tStart = t;
        _rpmPeak = peak;
        ev.add(DiagnosticEvent(
          t,
          'info',
          'Desaceleração detectada: ${_rpmPeak.toStringAsFixed(0)} → ${rpm.toStringAsFixed(0)} RPM, TPS ${tps.toStringAsFixed(1)}%',
        ));
      }
      return ev;
    }

    // Dentro do episódio de desaceleração
    final reaccel = tps != null && tps > c.tpsMax;
    if (reaccel) {
      ev.add(_buildDecelEndEvent(t, 'reaceleração', t - _tStart));
      inDecel = false;
      return ev;
    }

    // Análise de Sonda Lambda durante Cut-Off (Wideband-safe)
    final hasWideband = fresh('lambda_eq') || latest.containsKey('lambda_eq');
    if (hasWideband && (tps == null || tps <= c.tpsMax)) {
      final leq = latest['lambda_eq']!;
      _maxLambdaEq =
          _maxLambdaEq == null ? leq : math.max(_maxLambdaEq!, leq);
      _minLambdaEq =
          _minLambdaEq == null ? leq : math.min(_minLambdaEq!, leq);
      if (leq < c.lambdaEqRich && !_richAlerted) {
        _richAlerted = true;
        ev.add(DiagnosticEvent(
          t,
          'alarm',
          'FALHA DE CUT-OFF: lambda em ${leq.toStringAsFixed(2)} (< ${c.lambdaEqRich.toStringAsFixed(2)}) com borboleta '
          'fechada a ${rpm.toStringAsFixed(0)} RPM — excesso de combustível (pipocos no escape)',
        ));
      }
    } else if (fresh('lambda_v') && (tps == null || tps <= c.tpsMax)) {
      final lv = latest['lambda_v']!;
      _maxLambda = _maxLambda == null ? lv : math.max(_maxLambda!, lv);
      _minLambda = _minLambda == null ? lv : math.min(_minLambda!, lv);
      if (lv > c.lambdaRich && !_richAlerted) {
        _richAlerted = true;
        ev.add(DiagnosticEvent(
          t,
          'alarm',
          'FALHA DE CUT-OFF: sonda em ${lv.toStringAsFixed(2)} V (> ${c.lambdaRich.toStringAsFixed(2)} V) com borboleta '
          'fechada a ${rpm.toStringAsFixed(0)} RPM — excesso de combustível (pipocos no escape)',
        ));
      }
    }

    if (fresh('advance')) {
      final adv = latest['advance']!;
      _minAdv = _minAdv == null ? adv : math.min(_minAdv!, adv);
      if (adv < c.advanceMin && !_advAlerted) {
        _advAlerted = true;
        ev.add(DiagnosticEvent(
          t,
          'alarm',
          'AVANÇO NEGATIVO em desaceleração: ${adv.toStringAsFixed(1)}° (< ${c.advanceMin.toStringAsFixed(0)}°) '
          'a ${rpm.toStringAsFixed(0)} RPM — retardo excessivo / combustão no escape',
        ));
      }
    }

    if (rpm <= c.rpmEnd || (t - _tStart) > c.maxDuration) {
      final why = rpm <= c.rpmEnd ? 'chegou à lenta' : 'tempo máximo';
      ev.add(_buildDecelEndEvent(t, why, t - _tStart));
      inDecel = false;
    }

    return ev;
  }

  DiagnosticEvent _buildDecelEndEvent(double t, String why, double dur) {
    final c = cfg;
    final String lam;
    if (_maxLambdaEq != null) {
      lam =
          'lambda máx ${_maxLambdaEq!.toStringAsFixed(2)} / mín ${_minLambdaEq!.toStringAsFixed(2)}';
    } else if (_maxLambda != null) {
      lam =
          'sonda máx ${_maxLambda!.toStringAsFixed(2)} V / mín ${_minLambda!.toStringAsFixed(2)} V';
    } else {
      lam = 'sem leitura de sonda';
    }
    final adv = _minAdv != null
        ? 'avanço mín ${_minAdv!.toStringAsFixed(1)}°'
        : 'sem leitura de avanço';

    final String level;
    final String verdict;
    if (_richAlerted || _advAlerted) {
      level = 'warn';
      verdict = 'COM ANOMALIAS';
    } else if ((_maxLambdaEq != null && _maxLambdaEq! >= c.lambdaEqLeanOk) ||
        (_minLambda != null && _minLambda! <= c.lambdaLeanOk)) {
      level = 'info';
      verdict = 'Cut-Off OK';
    } else {
      level = 'info';
      verdict = 'Cut-Off não confirmado';
    }

    return DiagnosticEvent(
      t,
      level,
      'Fim da desaceleração ($why, ${dur.toStringAsFixed(1)}s): $verdict — $lam, $adv',
    );
  }
}
