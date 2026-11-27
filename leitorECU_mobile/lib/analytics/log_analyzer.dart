import 'dart:math' as math;

import '../core/models/channel_def.dart';
import '../storage/csv_replay_parser.dart';
import 'fuel_estimator.dart';
import 'math_channels.dart';

/// Estatísticas descritivas completas para um canal numérico de telemetria.
class ChannelStatistics {
  final String key;
  final String label;
  final String unit;
  final int count;
  final double min;
  final double max;
  final double mean;
  final double median;
  final double mode;
  final double modeFrequencyPct;
  final double stdDev;
  final double p5;
  final double p25;
  final double p75;
  final double p95;
  final double first;
  final double last;

  const ChannelStatistics({
    required this.key,
    required this.label,
    required this.unit,
    required this.count,
    required this.min,
    required this.max,
    required this.mean,
    required this.median,
    required this.mode,
    required this.modeFrequencyPct,
    required this.stdDev,
    required this.p5,
    required this.p25,
    required this.p75,
    required this.p95,
    required this.first,
    required this.last,
  });
}

/// Achado determinístico gerado pelas regras de diagnóstico offline.
class DiagnosticFinding {
  /// `'ok' | 'info' | 'warn' | 'alarm'`
  final String severity;
  final String category;
  final String title;
  final String detail;

  const DiagnosticFinding({
    required this.severity,
    required this.category,
    required this.title,
    required this.detail,
  });
}

/// Ponto agregado de curva de potência e torque para o Dinamômetro Virtual.
class DynoPoint {
  final int rpmBin;
  final double powerHp;
  final double torqueKgfm;
  final int sampleCount;

  const DynoPoint({
    required this.rpmBin,
    required this.powerHp,
    required this.torqueKgfm,
    required this.sampleCount,
  });
}

/// Relatório analítico completo de um único arquivo de log CSV.
class LogAnalysisReport {
  final String fileName;
  final int sampleCount;
  final double durationSec;
  final double distanceKm;
  final double avgSampleRateHz;
  final int standbyGapCount;
  final double movingPct;
  final double idlePct;
  final double cutoffPct;
  final double fuelConsumedLiters;
  final List<ChannelStatistics> channelStats;
  final Map<String, ChannelStatistics> byKey;
  final List<DiagnosticFinding> findings;
  final List<ReplayEvent> events;
  final bool isTurboDetected;
  final List<DynoPoint> dynoCurve;
  final bool recalculated;

  const LogAnalysisReport({
    required this.fileName,
    required this.sampleCount,
    required this.durationSec,
    required this.distanceKm,
    required this.avgSampleRateHz,
    required this.standbyGapCount,
    required this.movingPct,
    required this.idlePct,
    required this.cutoffPct,
    this.fuelConsumedLiters = 0.0,
    required this.channelStats,
    required this.byKey,
    required this.findings,
    required this.events,
    required this.isTurboDetected,
    this.dynoCurve = const [],
    this.recalculated = false,
  });
}

/// Diferença estatística de um canal comum entre Log A e Log B.
class ChannelComparisonDelta {
  final String key;
  final String label;
  final String unit;
  final ChannelStatistics statA;
  final ChannelStatistics statB;
  final double deltaMean;
  final double? deltaMeanPct;
  final double deltaMedian;
  final double deltaMode;
  final double deltaMax;
  final double deltaMin;
  final bool isSignificant;

  const ChannelComparisonDelta({
    required this.key,
    required this.label,
    required this.unit,
    required this.statA,
    required this.statB,
    required this.deltaMean,
    required this.deltaMeanPct,
    required this.deltaMedian,
    required this.deltaMode,
    required this.deltaMax,
    required this.deltaMin,
    required this.isSignificant,
  });
}

/// Relatório comparativo entre dois logs analisados ([reportA] vs [reportB]).
class LogComparisonReport {
  final LogAnalysisReport reportA;
  final LogAnalysisReport reportB;
  final List<ChannelComparisonDelta> deltas;
  final List<String> onlyInA;
  final List<String> onlyInB;
  final List<String> summaryHighlights;

  const LogComparisonReport({
    required this.reportA,
    required this.reportB,
    required this.deltas,
    required this.onlyInA,
    required this.onlyInB,
    required this.summaryHighlights,
  });
}

/// Motor de análise estatística, integração de percurso e regras de diagnóstico offline.
class LogAnalyzer {
  LogAnalyzer._();

  static const double _standbyGapThresholdSec = 5.0;

  /// Executa análise completa de um [ReplayDataset].
  static LogAnalysisReport analyze(
    ReplayDataset ds, {
    String fileName = 'log.csv',
    bool recalculateDerived = false,
    double displacementL = 1.6,
    double injectorCcMin = 275.0,
    double injectorDeadTimeMs = 0.85,
  }) {
    final n = ds.length;
    if (n == 0) {
      return LogAnalysisReport(
        fileName: fileName,
        sampleCount: 0,
        durationSec: 0.0,
        distanceKm: 0.0,
        avgSampleRateHz: 0.0,
        standbyGapCount: 0,
        movingPct: 0.0,
        idlePct: 0.0,
        cutoffPct: 0.0,
        channelStats: const [],
        byKey: const {},
        findings: const [
          DiagnosticFinding(
            severity: 'info',
            category: 'Dados',
            title: 'Log sem amostras válidas',
            detail: 'O arquivo CSV não contém linhas de telemetria válidas.',
          ),
        ],
        events: ds.events,
        isTurboDetected: ds.isTurboDetected,
        dynoCurve: const [],
        recalculated: recalculateDerived,
      );
    }

    final ReplayDataset effectiveDs;
    if (recalculateDerived) {
      final mathEngine = MathChannelsEngine(
        displacementL: displacementL,
        injectorCcMin: injectorCcMin,
        injectorDeadTimeMs: injectorDeadTimeMs,
      );
      final recalculatedRecords = <Map<String, double>>[];
      final discoveredKeys = <String>{...ds.availableChannels};
      for (var i = 0; i < n; i++) {
        final copy = Map<String, double>.from(ds.records[i]);
        // Em logs VAG antigos em que o Bloco 103.5 (bomba comb.) foi gravado em flex_ethanol_pct,
        // remove o valor falso antes de recalcular consumo e potência.
        if (copy.containsKey('g103_c5') || copy.containsKey('g103_c6')) {
          copy.remove('flex_ethanol_pct');
          copy.remove('ethanol');
          copy.remove('% Etanol [%]');
        }
        final t = i < ds.times.length ? ds.times[i] : i.toDouble();
        final fuelEst = FuelEstimator.estimateFuelMetrics(
          copy,
          displacementL: displacementL,
          injectorCcMin: injectorCcMin,
          deadTimeMs: injectorDeadTimeMs,
        );
        for (final key in const [
          'fuel_rate_lph',
          'fuel_econ_kml',
          'volumetric_eff',
        ]) {
          final val = fuelEst[key];
          if (val != null && val.isFinite) {
            copy[key] = val;
            discoveredKeys.add(key);
          }
        }
        final mathRes = mathEngine.compute(t, copy);
        for (final key in const [
          'fuel_rate_lph',
          'fuel_econ_kml',
          'volumetric_eff',
          'power_hp',
          'torque_kgfm',
          'trip_liters',
          'trip_km',
          'trip_avg_kml',
          'boost_bar',
          'boost_psi',
        ]) {
          final val = mathRes[key];
          if (val != null && val.isFinite) {
            copy[key] = val;
            discoveredKeys.add(key);
          }
        }
        recalculatedRecords.add(copy);
      }
      effectiveDs = ReplayDataset(
        availableChannels: discoveredKeys.toList(growable: false),
        times: ds.times,
        records: recalculatedRecords,
        events: ds.events,
        isTurboDetected: ds.isTurboDetected,
      );
    } else {
      effectiveDs = ds;
    }

    // 1. Coleta valores por canal preservando ordem temporal
    final channelValues = <String, List<double>>{};
    for (final k in effectiveDs.availableChannels) {
      channelValues[k] = <double>[];
    }

    var standbyGapCount = 0;
    var activeTimeSec = 0.0;
    var activeIntervals = 0;
    var distanceKm = 0.0;
    var fuelConsumedFromRateL = 0.0;
    var fuelConsumedFromKmlL = 0.0;

    double? lastSpeed = effectiveDs.records.first['speed'];
    if (lastSpeed != null && (!lastSpeed.isFinite || lastSpeed < 0.0)) {
      lastSpeed = null;
    }
    double? lastFuelRate = effectiveDs.records.first['fuel_rate_lph'] ??
        effectiveDs.records.first['fuel_rate'];
    if (lastFuelRate != null && (!lastFuelRate.isFinite || lastFuelRate < 0.0)) {
      lastFuelRate = null;
    }

    var movingCount = 0;
    var idleCount = 0;
    var cutoffCount = 0;

    for (var i = 0; i < n; i++) {
      final rec = effectiveDs.records[i];
      for (final entry in rec.entries) {
        final v = entry.value;
        if (!v.isFinite) continue;
        channelValues.putIfAbsent(entry.key, () => <double>[]).add(v);
      }

      // Classificação de regime de operação na amostra
      final spd = rec['speed'];
      final rpm = rec['rpm'];
      final tps = rec['tps'];
      final injMs = rec['inj_ms'] ?? rec['inj_pulse_width'];
      final lambdaV = rec['lambda_v'];
      final lambdaEq = rec['lambda_eq'];
      final fuelSys1 = rec['fuel_sys1'];

      if (spd != null && spd >= 2.0) {
        movingCount++;
      } else if (rpm != null &&
          rpm >= 450.0 &&
          rpm <= 1150.0 &&
          (tps == null || tps < 6.0)) {
        idleCount++;
      }

      final isCutoffBySys = fuelSys1 == 1.0 &&
          rpm != null &&
          rpm >= 1300.0 &&
          (tps == null || tps <= 6.0);
      final isCutoffByPhysics = rpm != null &&
          rpm >= 1400.0 &&
          (tps != null && tps <= 5.0) &&
          ((injMs != null && injMs <= 0.2) ||
              (lambdaV != null && lambdaV <= 0.15) ||
              (lambdaEq != null && lambdaEq >= 1.50));
      if (isCutoffBySys || isCutoffByPhysics) {
        cutoffCount++;
      }

      // Integração trapezoidal de distância e detecção de pausas (> 5.0s)
      if (i > 0) {
        final dt = ds.times[i] - ds.times[i - 1];
        if (dt.isFinite && dt > 0.0) {
          if (dt > _standbyGapThresholdSec) {
            standbyGapCount++;
          } else {
            activeTimeSec += dt;
            activeIntervals++;
            final rawCurSpeed = rec['speed'];
            final curSpeed = (rawCurSpeed != null && rawCurSpeed.isFinite)
                ? math.max(0.0, rawCurSpeed)
                : lastSpeed;
            if (lastSpeed != null && curSpeed != null) {
              final segDistKm = ((lastSpeed + curSpeed) * 0.5 / 3600.0) * dt;
              distanceKm += segDistKm;
              final kml = rec['fuel_econ_kml'];
              if (kml != null && kml.isFinite && kml > 0.5 && kml < 45.0) {
                fuelConsumedFromKmlL += segDistKm / kml;
              }
            }
            if (curSpeed != null) {
              lastSpeed = curSpeed;
            }
            final rawRate = rec['fuel_rate_lph'] ?? rec['fuel_rate'];
            final curRate = (rawRate != null && rawRate.isFinite)
                ? math.max(0.0, rawRate)
                : lastFuelRate;
            if (lastFuelRate != null && curRate != null) {
              fuelConsumedFromRateL += ((lastFuelRate + curRate) * 0.5 / 3600.0) * dt;
            }
            if (curRate != null) {
              lastFuelRate = curRate;
            }
          }
        }
        if (rec['speed'] != null && rec['speed']!.isFinite) {
          lastSpeed = math.max(0.0, rec['speed']!);
        }
      }
    }

    final avgSampleRateHz =
        activeTimeSec > 0.0 && activeIntervals > 0 ? activeIntervals / activeTimeSec : 0.0;
    final movingPct = (movingCount / n) * 100.0;
    final idlePct = (idleCount / n) * 100.0;
    final cutoffPct = (cutoffCount / n) * 100.0;

    // 2. Estatísticas por canal
    final orderedKeys = <String>[
      for (final k in effectiveDs.availableChannels)
        if ((channelValues[k]?.isNotEmpty ?? false)) k,
      for (final e in channelValues.entries)
        if (e.value.isNotEmpty && !effectiveDs.availableChannels.contains(e.key))
          e.key,
    ];

    final stats = <ChannelStatistics>[];
    final byKey = <String, ChannelStatistics>{};
    for (final key in orderedKeys) {
      final desc = describeChannel(key);
      if (_isUnlabeledRawBlockKey(key, desc.label)) {
        continue;
      }
      var values = channelValues[key]!;
      // Para consumo instantâneo (km/l), descarta sentinelas de veículo parado (0.0)
      // e Cut-Off (99.9 km/l) para não inflar artificialmente a média/mediana do log.
      if (key == 'fuel_econ_kml') {
        final movingValid = values.where((v) => v > 0.05 && v < 99.0).toList();
        if (movingValid.isNotEmpty) {
          values = movingValid;
        }
      }
      final stat = _computeChannelStats(key, values);
      stats.add(stat);
      byKey[key] = stat;
    }

    // Remove pressão de turbo em veículos aspirados sem sobrealimentação real
    final maxMap = byKey['map']?.max ?? 0.0;
    final maxBoostBar = byKey['boost_bar']?.max ?? 0.0;
    final effectiveIsTurbo =
        ds.isTurboDetected || (maxMap > 108.0 && maxBoostBar > 0.08);
    if (!effectiveIsTurbo) {
      stats.removeWhere((s) => s.key == 'boost_bar' || s.key == 'boost_psi');
      byKey.remove('boost_bar');
      byKey.remove('boost_psi');
    }

    final tripLitersStat = byKey['trip_liters'] ?? byKey['trip_fuel_liters'];
    final double fuelConsumedLiters;
    if (fuelConsumedFromRateL > 0.001) {
      fuelConsumedLiters = fuelConsumedFromRateL;
    } else if (tripLitersStat != null && tripLitersStat.max > 0.001) {
      final delta = tripLitersStat.max - tripLitersStat.min;
      fuelConsumedLiters = delta > 0.001 ? delta : tripLitersStat.last;
    } else {
      fuelConsumedLiters = fuelConsumedFromKmlL;
    }

    // 3. Regras de diagnóstico determinístico
    final findings = _evaluateFindings(
      ds: effectiveDs,
      byKey: byKey,
      durationSec: effectiveDs.durationSec,
      standbyGapCount: standbyGapCount,
    );

    // 4. Curva de Dinamômetro Virtual (plena carga em bins de 250 RPM)
    final dynoCurve = _extractDynoCurve(effectiveDs.records);

    return LogAnalysisReport(
      fileName: fileName,
      sampleCount: n,
      durationSec: effectiveDs.durationSec,
      distanceKm: distanceKm,
      avgSampleRateHz: avgSampleRateHz,
      standbyGapCount: standbyGapCount,
      movingPct: movingPct,
      idlePct: idlePct,
      cutoffPct: cutoffPct,
      fuelConsumedLiters: fuelConsumedLiters,
      channelStats: List<ChannelStatistics>.unmodifiable(stats),
      byKey: Map<String, ChannelStatistics>.unmodifiable(byKey),
      findings: List<DiagnosticFinding>.unmodifiable(findings),
      events: List<ReplayEvent>.unmodifiable(effectiveDs.events),
      isTurboDetected: effectiveIsTurbo,
      dynoCurve: dynoCurve,
      recalculated: recalculateDerived,
    );
  }

  static List<DynoPoint> _extractDynoCurve(List<Map<String, double>> records) {
    final bins = <int, List<({double hp, double torque})>>{};
    for (final rec in records) {
      final rpm = rec['rpm'] ?? 0.0;
      final map = rec['map'] ?? 0.0;
      final tps = rec['tps'];
      final powerHp = rec['power_hp'] ?? 0.0;
      if (!rpm.isFinite || !map.isFinite || !powerHp.isFinite) continue;
      if (tps != null && !tps.isFinite) continue;

      final isFullLoad = (tps != null && tps >= 70.0) || map >= 88.0;
      if (!isFullLoad || rpm < 1200.0 || powerHp <= 0.0) continue;

      final rpmBin = (rpm / 250.0).round() * 250;
      if (rpmBin < 1250 || rpmBin > 6750) continue;

      final rawTorque = rec['torque_kgfm'];
      final torqueKgfm =
          (rawTorque != null && rawTorque.isFinite && rawTorque > 0.0)
              ? rawTorque
              : (powerHp * 716.2) / rpm;
      bins.putIfAbsent(rpmBin, () => <({double hp, double torque})>[]).add(
            (hp: powerHp, torque: torqueKgfm),
          );
    }

    final curve = <DynoPoint>[];
    final sortedBins = bins.keys.toList()..sort();
    for (final rpmBin in sortedBins) {
      final samples = bins[rpmBin]!;
      samples.sort((a, b) => b.hp.compareTo(a.hp));
      final topCount = math.max(1, (samples.length / 2.0).ceil());
      var sumHp = 0.0;
      var sumTorque = 0.0;
      for (var i = 0; i < topCount; i++) {
        sumHp += samples[i].hp;
        sumTorque += samples[i].torque;
      }
      curve.add(DynoPoint(
        rpmBin: rpmBin,
        powerHp: sumHp / topCount,
        torqueKgfm: sumTorque / topCount,
        sampleCount: samples.length,
      ));
    }
    return List<DynoPoint>.unmodifiable(curve);
  }

  static final RegExp _rawVagKeyRe = RegExp(r'^g\d{3}_c\d+$', caseSensitive: false);
  static final RegExp _rawVagLabelRe = RegExp(r'^Bloco\s+\d{3}\.\d+$', caseSensitive: false);

  static bool _isUnlabeledRawBlockKey(String key, String label) {
    final trimmed = label.trim();
    if (trimmed.isEmpty) return true;
    if (_rawVagKeyRe.hasMatch(key) && (trimmed == key || _rawVagKeyRe.hasMatch(trimmed))) {
      return true;
    }
    if (_rawVagLabelRe.hasMatch(trimmed)) {
      return true;
    }
    return false;
  }

  /// Compara dois relatórios analisados ([a] como referência e [b] como comparação).
  static LogComparisonReport compare(LogAnalysisReport a, LogAnalysisReport b) {
    final deltas = <ChannelComparisonDelta>[];
    final onlyInA = <String>[];
    final onlyInB = <String>[];

    for (final statA in a.channelStats) {
      final statB = b.byKey[statA.key];
      if (statB == null) {
        onlyInA.add(statA.key);
        continue;
      }
      final deltaMean = statB.mean - statA.mean;
      final double? deltaMeanPct = statA.mean.abs() > 1e-6
          ? (deltaMean / statA.mean.abs()) * 100.0
          : null;
      final deltaMedian = statB.median - statA.median;
      final deltaMode = statB.mode - statA.mode;
      final deltaMax = statB.max - statA.max;
      final deltaMin = statB.min - statA.min;
      final significant = _isDeltaSignificant(
        key: statA.key,
        deltaMean: deltaMean,
        deltaMeanPct: deltaMeanPct,
        deltaMax: deltaMax,
      );

      deltas.add(
        ChannelComparisonDelta(
          key: statA.key,
          label: statA.label,
          unit: statA.unit,
          statA: statA,
          statB: statB,
          deltaMean: deltaMean,
          deltaMeanPct: deltaMeanPct,
          deltaMedian: deltaMedian,
          deltaMode: deltaMode,
          deltaMax: deltaMax,
          deltaMin: deltaMin,
          isSignificant: significant,
        ),
      );
    }

    for (final statB in b.channelStats) {
      if (!a.byKey.containsKey(statB.key)) {
        onlyInB.add(statB.key);
      }
    }

    final highlights = _buildComparisonHighlights(
      a: a,
      b: b,
      deltas: deltas,
      onlyInA: onlyInA,
      onlyInB: onlyInB,
    );

    return LogComparisonReport(
      reportA: a,
      reportB: b,
      deltas: List<ChannelComparisonDelta>.unmodifiable(deltas),
      onlyInA: List<String>.unmodifiable(onlyInA),
      onlyInB: List<String>.unmodifiable(onlyInB),
      summaryHighlights: List<String>.unmodifiable(highlights),
    );
  }

  static ChannelStatistics _computeChannelStats(
    String key,
    List<double> values,
  ) {
    final desc = describeChannel(key);
    final count = values.length;
    final first = values.first;
    final last = values.last;

    var sum = 0.0;
    var minVal = values.first;
    var maxVal = values.first;
    for (final v in values) {
      sum += v;
      if (v < minVal) minVal = v;
      if (v > maxVal) maxVal = v;
    }
    final mean = sum / count;

    var sumSq = 0.0;
    for (final v in values) {
      final d = v - mean;
      sumSq += d * d;
    }
    final stdDev = count > 1 ? math.sqrt(math.max(0.0, sumSq / (count - 1))) : 0.0;

    final sorted = List<double>.from(values)..sort();
    final p5 = _percentile(sorted, 0.05);
    final p25 = _percentile(sorted, 0.25);
    final median = _percentile(sorted, 0.50);
    final p75 = _percentile(sorted, 0.75);
    final p95 = _percentile(sorted, 0.95);

    final (:mode, :modeFrequencyPct) = _computeMode(
      key: key,
      values: values,
      min: minVal,
      max: maxVal,
      median: median,
    );

    return ChannelStatistics(
      key: key,
      label: desc.label,
      unit: desc.unit,
      count: count,
      min: minVal,
      max: maxVal,
      mean: mean,
      median: median,
      mode: mode,
      modeFrequencyPct: modeFrequencyPct,
      stdDev: stdDev,
      p5: p5,
      p25: p25,
      p75: p75,
      p95: p95,
      first: first,
      last: last,
    );
  }

  static double _percentile(List<double> sorted, double p) {
    final n = sorted.length;
    if (n == 0) return 0.0;
    if (n == 1) return sorted.first;
    final pos = p.clamp(0.0, 1.0) * (n - 1);
    final lo = pos.floor();
    final hi = pos.ceil();
    if (lo == hi) return sorted[lo];
    final frac = pos - lo;
    return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
  }

  static double _binWidthForChannel(String key, double min, double max) {
    return switch (key) {
      'rpm' => 50.0,
      'speed' ||
      'ect' ||
      'cht_temp' ||
      'cht_c' ||
      'iat' ||
      'map' ||
      'cat_temp' =>
        1.0,
      'lambda_v' ||
      'lambda2_v' ||
      'lambda_eq' ||
      'boost_bar' ||
      'accel_g' =>
        0.05,
      'battery' || 'inj_ms' || 'inj_pulse_width' => 0.1,
      'stft' ||
      'ltft' ||
      'ltft_idle' ||
      'lambda_trim' ||
      'advance' ||
      'tps' ||
      'load' ||
      'volumetric_eff' =>
        0.5,
      _ => math.max(0.01, (max - min) / 20.0),
    };
  }

  static ({double mode, double modeFrequencyPct}) _computeMode({
    required String key,
    required List<double> values,
    required double min,
    required double max,
    required double median,
  }) {
    final count = values.length;
    if (count == 0) return (mode: 0.0, modeFrequencyPct: 0.0);
    if ((max - min).abs() < 1e-12) {
      return (mode: min, modeFrequencyPct: 100.0);
    }

    final width = _binWidthForChannel(key, min, max);
    final bins = <int, int>{};

    for (final v in values) {
      final scaled = v / width;
      if (!scaled.isFinite || scaled.abs() > 1e12) {
        return (mode: median, modeFrequencyPct: 0.0);
      }
      final idx = scaled.round();
      bins[idx] = (bins[idx] ?? 0) + 1;
    }

    var bestIdx = 0;
    var bestCount = -1;
    var bestDist = double.infinity;

    for (final entry in bins.entries) {
      final binIdx = entry.key;
      final binCount = entry.value;
      final center = binIdx * width;
      final distToMedian = (center - median).abs();

      if (binCount > bestCount) {
        bestCount = binCount;
        bestIdx = binIdx;
        bestDist = distToMedian;
      } else if (binCount == bestCount) {
        if (distToMedian < bestDist - 1e-12 ||
            ((distToMedian - bestDist).abs() <= 1e-12 &&
                center < bestIdx * width)) {
          bestIdx = binIdx;
          bestDist = distToMedian;
        }
      }
    }

    final modeVal = bestIdx * width;
    final freqPct = (bestCount / count) * 100.0;
    return (mode: modeVal, modeFrequencyPct: freqPct);
  }

  static List<DiagnosticFinding> _evaluateFindings({
    required ReplayDataset ds,
    required Map<String, ChannelStatistics> byKey,
    required double durationSec,
    required int standbyGapCount,
  }) {
    final alarms = <DiagnosticFinding>[];
    final warns = <DiagnosticFinding>[];
    final infos = <DiagnosticFinding>[];

    // 1. LTFT / LTFT Lenta
    for (final key in const ['ltft', 'ltft_idle']) {
      final stat = byKey[key];
      if (stat == null) continue;
      final absMean = stat.mean.abs();
      final dir = stat.mean >= 0 ? 'positiva (tende a mistura pobre)' : 'negativa (tende a mistura rica)';
      if (absMean > 18.0) {
        alarms.add(DiagnosticFinding(
          severity: 'alarm',
          category: 'Mistura',
          title: '${stat.label} crítica (${_signed(stat.mean, 1)}%)',
          detail:
              'Adaptação de longo prazo média em ${_signed(stat.mean, 1)}% ($dir), acima do limite crítico de ±18%.',
        ));
      } else if (absMean > 10.0) {
        warns.add(DiagnosticFinding(
          severity: 'warn',
          category: 'Mistura',
          title: '${stat.label} elevada (${_signed(stat.mean, 1)}%)',
          detail:
              'Adaptação de longo prazo média em ${_signed(stat.mean, 1)}% ($dir), fora da faixa ideal de ±10%.',
        ));
      }
    }

    // 2. Soma STFT + LTFT > 20%
    final stftStat = byKey['stft'];
    final ltftStat = byKey['ltft'];
    if (stftStat != null && ltftStat != null) {
      var sumCombined = 0.0;
      var combinedCount = 0;
      for (final rec in ds.records) {
        final s = rec['stft'];
        final l = rec['ltft'];
        if (s != null && l != null && s.isFinite && l.isFinite) {
          sumCombined += s + l;
          combinedCount++;
        }
      }
      final combinedMean = combinedCount > 0
          ? sumCombined / combinedCount
          : stftStat.mean + ltftStat.mean;
      if (combinedMean.abs() > 20.0) {
        alarms.add(DiagnosticFinding(
          severity: 'alarm',
          category: 'Mistura',
          title: 'Correção combinada STFT + LTFT crítica (${_signed(combinedMean, 1)}%)',
          detail:
              'Soma média STFT (${_signed(stftStat.mean, 1)}%) + LTFT (${_signed(ltftStat.mean, 1)}%) excede ±20%, indicando desvio severo de combustível/ar falso.',
        ));
      }
    }

    // 3. Temperatura do motor (ECT / CHT)
    final tempStat = byKey['ect'] ?? byKey['cht_temp'] ?? byKey['cht_c'];
    if (tempStat != null) {
      if (tempStat.max >= 105.0) {
        alarms.add(DiagnosticFinding(
          severity: 'alarm',
          category: 'Arrefecimento',
          title: 'Superaquecimento detectado (${tempStat.max.toStringAsFixed(0)} °C)',
          detail:
              '${tempStat.label} atingiu máxima de ${tempStat.max.toStringAsFixed(1)} °C (>= 105 °C). Verifique eletroventilador, nível e termostática.',
        ));
      } else if (tempStat.max >= 103.0) {
        warns.add(DiagnosticFinding(
          severity: 'warn',
          category: 'Arrefecimento',
          title: 'Temperatura elevada detectada (${tempStat.max.toStringAsFixed(0)} °C)',
          detail:
              '${tempStat.label} atingiu máxima de ${tempStat.max.toStringAsFixed(1)} °C (>= 103 °C). Monitore o acionamento do eletroventilador.',
        ));
      }

      if (tempStat.max >= 96.0) {
        var fanCycleConfirmed = tempStat.last <= tempStat.max - 4.0;
        double? peakHot;
        double? cooledTo;
        for (final rec in ds.records) {
          final tv = rec[tempStat.key];
          if (tv == null || !tv.isFinite) continue;
          if (tv >= 96.0 && (peakHot == null || tv > peakHot)) {
            peakHot = tv;
          }
          if (peakHot != null && tv <= peakHot - 4.0) {
            fanCycleConfirmed = true;
            cooledTo = tv;
            break;
          }
        }
        if (fanCycleConfirmed) {
          final peakVal = peakHot ?? tempStat.max;
          final coolVal = cooledTo ?? tempStat.last;
          infos.add(DiagnosticFinding(
            severity: 'ok',
            category: 'Arrefecimento',
            title: 'Ciclo de Eletroventilador Confirmado',
            detail:
                '${tempStat.label} atingiu ${peakVal.toStringAsFixed(1)} °C e resfriou para ${coolVal.toStringAsFixed(1)} °C, confirmando atuação do eletroventilador.',
          ));
        }
      }

      final avgSpeed = byKey['speed']?.mean ?? 0.0;
      if (durationSec >= 360.0 && avgSpeed >= 30.0 && tempStat.median < 75.0) {
        warns.add(DiagnosticFinding(
          severity: 'warn',
          category: 'Arrefecimento',
          title: 'Termostática Possivelmente Travada Aberta',
          detail:
              'Em percurso de ${(durationSec / 60.0).toStringAsFixed(1)} min com velocidade média de ${avgSpeed.toStringAsFixed(1)} km/h, ${tempStat.label} manteve mediana de ${tempStat.median.toStringAsFixed(1)} °C (< 75 °C).',
        ));
      } else if (durationSec >= 180.0 && tempStat.median < 75.0) {
        warns.add(DiagnosticFinding(
          severity: 'warn',
          category: 'Arrefecimento',
          title: 'Temperatura de trabalho baixa (mediana ${tempStat.median.toStringAsFixed(0)} °C)',
          detail:
              'Em log de ${(durationSec / 60.0).toStringAsFixed(1)} min, ${tempStat.label} manteve mediana de ${tempStat.median.toStringAsFixed(1)} °C (< 75 °C) — possível termostática travada aberta ou aquecimento lento.',
        ));
      }
    }

    // 4. Sonda Lambda estreita travada/lenta com motor quente
    final lambdaStat = byKey['lambda_v'];
    final warmMaxTemp = tempStat?.max;
    if (lambdaStat != null && warmMaxTemp != null && warmMaxTemp >= 70.0) {
      final span = lambdaStat.max - lambdaStat.min;
      if (span < 0.15) {
        warns.add(DiagnosticFinding(
          severity: 'warn',
          category: 'Sonda Lambda',
          title: 'Sonda 1 com baixa oscilação (Δ ${span.toStringAsFixed(3)} V)',
          detail:
              'Com motor aquecido (${warmMaxTemp.toStringAsFixed(0)} °C), Sonda 1 variou apenas de ${lambdaStat.min.toStringAsFixed(3)} V a ${lambdaStat.max.toStringAsFixed(3)} V (< 0,15 V) — possível sensor lento/travado.',
        ));
      }
    }

    // 5. Avanço de ignição crítico ATDC
    final advStat = byKey['advance'];
    if (advStat != null && advStat.min < -8.0) {
      alarms.add(DiagnosticFinding(
        severity: 'alarm',
        category: 'Ignição',
        title: 'Retardo crítico de ignição ATDC (${advStat.min.toStringAsFixed(1)}°)',
        detail:
            'Avanço mínimo caiu para ${advStat.min.toStringAsFixed(1)}° (< -8,0° ATDC), elevando risco de combustão no escape e superaquecimento.',
      ));
    }

    // 6. Retardo por detonação (Knock)
    final knockStat = byKey['knock_retard_max'];
    if (knockStat != null) {
      if (knockStat.max >= 6.0) {
        alarms.add(DiagnosticFinding(
          severity: 'alarm',
          category: 'Detonação',
          title: 'Detonação severa (${knockStat.max.toStringAsFixed(1)} °KW)',
          detail:
              'Retardo máximo por knock atingiu ${knockStat.max.toStringAsFixed(1)} °KW (>= 6,0°). Verifique octanagem do combustível, velas e mistura.',
        ));
      } else if (knockStat.max >= 3.0) {
        warns.add(DiagnosticFinding(
          severity: 'warn',
          category: 'Detonação',
          title: 'Detonação moderada (${knockStat.max.toStringAsFixed(1)} °KW)',
          detail:
              'Retardo máximo por knock atingiu ${knockStat.max.toStringAsFixed(1)} °KW (>= 3,0°).',
        ));
      }
    }

    // 7. Sistema elétrico (Bateria / Alternador)
    final battStat = byKey['battery'];
    if (battStat != null) {
      double? minRunningBatt;
      final hasRpm = byKey.containsKey('rpm');
      if (hasRpm) {
        for (final rec in ds.records) {
          final b = rec['battery'];
          final r = rec['rpm'];
          if (b != null && r != null && b.isFinite && r >= 550.0) {
            minRunningBatt = minRunningBatt == null ? b : math.min(minRunningBatt, b);
          }
        }
      }
      if (minRunningBatt != null && minRunningBatt < 12.2) {
        alarms.add(DiagnosticFinding(
          severity: 'alarm',
          category: 'Elétrica',
          title: 'Subtensão com motor ligado (${minRunningBatt.toStringAsFixed(2)} V)',
          detail:
              'Tensão da bateria caiu para ${minRunningBatt.toStringAsFixed(2)} V (< 12,2 V) com motor em funcionamento — possível falha no alternador ou regulador.',
        ));
      }
      if (battStat.max > 15.0) {
        alarms.add(DiagnosticFinding(
          severity: 'alarm',
          category: 'Elétrica',
          title: 'Sobretensão detectada (${battStat.max.toStringAsFixed(2)} V)',
          detail:
              'Tensão máxima atingiu ${battStat.max.toStringAsFixed(2)} V (> 15,0 V) — risco de dano à ECU por falha do regulador de voltagem.',
        ));
      }
    }

    // 8. Pausas de standby
    if (standbyGapCount > 0) {
      infos.add(DiagnosticFinding(
        severity: 'info',
        category: 'Sessão',
        title: '$standbyGapCount pausa(s) de standby detectada(s)',
        detail:
            'Intervalos maiores que 5,0s entre amostras foram ignorados na integração de distância e taxa média para evitar distorções.',
      ));
    }

    // 9. Saudável se não houver avisos nem alarmes
    if (alarms.isEmpty && warns.isEmpty) {
      final rpmStr = byKey['rpm'] != null
          ? 'RPM méd. ${byKey['rpm']!.mean.toStringAsFixed(0)}'
          : '${ds.length} amostras';
      final tempStr = tempStat != null
          ? ', ${tempStat.label} máx ${tempStat.max.toStringAsFixed(0)} °C'
          : '';
      return [
        DiagnosticFinding(
          severity: 'ok',
          category: 'Geral',
          title: 'Operação saudável dentro dos limites nominais',
          detail:
              'Nenhuma anomalia crítica ou alerta de mistura, arrefecimento, ignição ou carga elétrica ($rpmStr$tempStr).',
        ),
        ...infos,
      ];
    }

    return [...alarms, ...warns, ...infos];
  }

  static bool _isDeltaSignificant({
    required String key,
    required double deltaMean,
    required double? deltaMeanPct,
    required double deltaMax,
  }) {
    final domainSignificant = switch (key) {
      'stft' || 'ltft' || 'ltft_idle' || 'lambda_trim' => deltaMean.abs() >= 3.0,
      'ect' ||
      'cht_temp' ||
      'cht_c' ||
      'iat' ||
      'cat_temp' ||
      'oil_temp' =>
        deltaMean.abs() >= 5.0,
      'battery' || 'ecu_volt' || 'obd_pin16_v' => deltaMean.abs() >= 0.4,
      'rpm' => deltaMean.abs() >= 200.0,
      'advance' => deltaMean.abs() >= 2.0,
      'lambda_v' || 'lambda2_v' || 'lambda_eq' => deltaMean.abs() >= 0.05,
      'boost_bar' => deltaMean.abs() >= 0.08,
      'knock_retard_max' => deltaMax.abs() >= 1.5 || deltaMean.abs() >= 0.5,
      _ => false,
    };
    if (domainSignificant) return true;
    if (deltaMeanPct != null &&
        deltaMeanPct.abs() >= 10.0 &&
        deltaMean.abs() >= 0.05) {
      return true;
    }
    return false;
  }

  static List<String> _buildComparisonHighlights({
    required LogAnalysisReport a,
    required LogAnalysisReport b,
    required List<ChannelComparisonDelta> deltas,
    required List<String> onlyInA,
    required List<String> onlyInB,
  }) {
    final highlights = <String>[
      'Duração: ${_fmtDuration(a.durationSec)} → ${_fmtDuration(b.durationSec)} '
          '(${a.sampleCount} → ${b.sampleCount} amostras)',
    ];

    if (a.distanceKm > 0.01 || b.distanceKm > 0.01) {
      highlights.add(
        'Distância percorrida: ${a.distanceKm.toStringAsFixed(2)} km → ${b.distanceKm.toStringAsFixed(2)} km',
      );
    }

    final sigDeltas = deltas.where((d) => d.isSignificant).toList()
      ..sort(
        (x, y) => (y.deltaMeanPct?.abs() ?? 0.0)
            .compareTo(x.deltaMeanPct?.abs() ?? 0.0),
      );

    for (final d in sigDeltas.take(5)) {
      final dec = coreChannels[d.key]?.decimals ?? 1;
      final pctStr = d.deltaMeanPct != null
          ? ' (${_signed(d.deltaMeanPct!, 1)}%)'
          : '';
      final unitStr = d.unit.isNotEmpty ? ' ${d.unit}' : '';
      highlights.add(
        '${d.label}: média ${d.statA.mean.toStringAsFixed(dec)} → '
        '${d.statB.mean.toStringAsFixed(dec)}$unitStr '
        '(${_signed(d.deltaMean, dec)}$unitStr$pctStr)',
      );
    }

    final alarmsA = a.findings.where((f) => f.severity == 'alarm').length;
    final alarmsB = b.findings.where((f) => f.severity == 'alarm').length;
    final warnsA = a.findings.where((f) => f.severity == 'warn').length;
    final warnsB = b.findings.where((f) => f.severity == 'warn').length;
    if (alarmsA > 0 || alarmsB > 0 || warnsA > 0 || warnsB > 0) {
      highlights.add(
        'Alertas automáticos: Log A ($alarmsA críticos, $warnsA avisos) vs '
        'Log B ($alarmsB críticos, $warnsB avisos)',
      );
    }

    if (onlyInA.isNotEmpty) {
      highlights.add('Canais exclusivos do Log A: ${onlyInA.join(', ')}');
    }
    if (onlyInB.isNotEmpty) {
      highlights.add('Canais exclusivos do Log B: ${onlyInB.join(', ')}');
    }

    return highlights;
  }

  static String _signed(double v, int decimals) {
    final prefix = v >= 0 ? '+' : '';
    return '$prefix${v.toStringAsFixed(decimals)}';
  }

  static String _fmtDuration(double sec) {
    if (sec < 60.0) return '${sec.toStringAsFixed(1)}s';
    final mins = sec ~/ 60;
    final rem = sec - mins * 60;
    return '${mins}m${rem.toStringAsFixed(0).padLeft(2, '0')}s';
  }
}
