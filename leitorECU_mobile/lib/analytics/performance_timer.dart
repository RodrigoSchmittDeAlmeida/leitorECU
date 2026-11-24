/// Registro de desempenho de uma puxada / medição automotiva.
class PerformanceRecord {
  double? time0to60;
  double? time0to100;
  double? time80to120;
  double? time100to200;
  double? braking100to0;
  double? time201m;
  double? time402m;
  double? speed201m;
  double? speed402m;
  double maxSpeed;
  double maxG;
  DateTime timestamp;

  PerformanceRecord({
    this.time0to60,
    this.time0to100,
    this.time80to120,
    this.time100to200,
    this.braking100to0,
    this.time201m,
    this.time402m,
    this.speed201m,
    this.speed402m,
    this.maxSpeed = 0.0,
    this.maxG = 0.0,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  PerformanceRecord clone() {
    return PerformanceRecord(
      time0to60: time0to60,
      time0to100: time0to100,
      time80to120: time80to120,
      time100to200: time100to200,
      braking100to0: braking100to0,
      time201m: time201m,
      time402m: time402m,
      speed201m: speed201m,
      speed402m: speed402m,
      maxSpeed: maxSpeed,
      maxG: maxG,
      timestamp: timestamp,
    );
  }
}

/// Máquina de estados para medição de arrancada (0-60, 0-100, 201m, 402m),
/// retomadas (80-120, 100-200) e frenagem contínua (100-0 km/h).
class PerformanceTimer {
  String state = 'ARMED'; // ARMED | RUNNING | FINISHED
  double? tLaunch;
  double? t80;
  double? t100;
  double? t100Brake;
  double? _brakePrevSpd;
  bool _savedToHistory = false;
  double distanceM = 0.0;
  double? lastT;
  double lastSpdMs = 0.0;
  PerformanceRecord record = PerformanceRecord();
  final List<PerformanceRecord> history = [];

  static double _round1(double v) => (v * 10.0).roundToDouble() / 10.0;
  static double _round2(double v) => (v * 100.0).roundToDouble() / 100.0;

  void reset() {
    state = 'ARMED';
    tLaunch = null;
    t80 = null;
    t100 = null;
    t100Brake = null;
    _brakePrevSpd = null;
    _savedToHistory = false;
    distanceM = 0.0;
    lastT = null;
    lastSpdMs = 0.0;
    record = PerformanceRecord();
  }

  void clearHistory() {
    history.clear();
  }

  /// Processa nova amostra de velocidade. Retorna mensagem de evento se completou um marco.
  String? update(double t, double speedKmh, {DateTime? now}) {
    String? eventMsg;
    final spdMs = speedKmh > 0.0 ? speedKmh / 3.6 : 0.0;

    // 1. Integração da distância percorrida (trapezoidal) e força G
    if (lastT != null && t > lastT!) {
      final dt = t - lastT!;
      distanceM += (spdMs + lastSpdMs) * 0.5 * dt;
      final accelMs2 = dt > 0.0 ? (spdMs - lastSpdMs) / dt : 0.0;
      final gForce = accelMs2 / 9.80665;
      if (gForce > record.maxG) {
        record.maxG = _round2(gForce);
      }
    }

    lastT = t;
    lastSpdMs = spdMs;

    if (speedKmh > record.maxSpeed) {
      record.maxSpeed = _round1(speedKmh);
    }

    // 2. Máquina de estados da arrancada
    if (state == 'ARMED') {
      if (speedKmh < 1.0) {
        distanceM = 0.0;
        tLaunch = null;
      } else if (speedKmh >= 2.0) {
        state = 'RUNNING';
        tLaunch = t;
        distanceM = 0.0;
        _savedToHistory = false;
        record.timestamp = now ?? DateTime.now();
        eventMsg = 'LARGADA DETECTADA! Cronômetro iniciado...';
      }
    } else if (state == 'RUNNING' && tLaunch != null) {
      final elapsed = t - tLaunch!;

      if (speedKmh >= 60.0 && record.time0to60 == null) {
        record.time0to60 = _round2(elapsed);
        eventMsg = '0 a 60 km/h: ${record.time0to60!.toStringAsFixed(2)} s';
      }

      if (speedKmh >= 100.0 && record.time0to100 == null) {
        record.time0to100 = _round2(elapsed);
        eventMsg = '0 a 100 km/h: ${record.time0to100!.toStringAsFixed(2)} s';
      }

      if (distanceM >= 201.16 && record.time201m == null) {
        record.time201m = _round2(elapsed);
        record.speed201m = _round1(speedKmh);
        eventMsg =
            '201m (1/8 milha): ${record.time201m!.toStringAsFixed(2)} s @ ${speedKmh.toStringAsFixed(1)} km/h';
      }

      if (distanceM >= 402.33 && record.time402m == null) {
        record.time402m = _round2(elapsed);
        record.speed402m = _round1(speedKmh);
        state = 'FINISHED';
        eventMsg =
            '402m (1/4 milha): ${record.time402m!.toStringAsFixed(2)} s @ ${speedKmh.toStringAsFixed(1)} km/h';
      }

      if (state == 'FINISHED' && !_savedToHistory) {
        record.timestamp = now ?? record.timestamp;
        history.add(record.clone());
        _savedToHistory = true;
      }

      if (speedKmh < 1.0 && elapsed > 3.0) {
        if (!_savedToHistory &&
            (record.time0to60 != null ||
                record.time0to100 != null ||
                record.time201m != null ||
                record.time402m != null)) {
          record.timestamp = now ?? record.timestamp;
          history.add(record.clone());
          _savedToHistory = true;
        }
        state = 'ARMED';
      }
    }

    // 3. Retomada de 80 a 120 km/h
    if (speedKmh <= 80.0) {
      t80 = t;
    } else if (speedKmh >= 120.0 && t80 != null) {
      final retomada = t - t80!;
      if (retomada > 0.5 && retomada < 25.0) {
        record.time80to120 = _round2(retomada);
        eventMsg =
            'Retomada 80 a 120 km/h: ${record.time80to120!.toStringAsFixed(2)} s';
      }
      t80 = null;
    }

    // 4. Aceleração / Retomada de 100 a 200 km/h
    if (speedKmh <= 100.0) {
      t100 = t;
    } else if (speedKmh >= 200.0 && t100 != null) {
      final retomada200 = t - t100!;
      if (retomada200 > 0.5 && retomada200 < 60.0) {
        record.time100to200 = _round2(retomada200);
        eventMsg =
            '100 a 200 km/h: ${record.time100to200!.toStringAsFixed(2)} s';
      }
      t100 = null;
    }

    // 5. Frenagem 100 a 0 km/h (com validação de desaceleração contínua)
    if (speedKmh >= 100.0) {
      t100Brake = t;
      _brakePrevSpd = speedKmh;
    } else if (t100Brake != null) {
      if (_brakePrevSpd != null && speedKmh > _brakePrevSpd! + 4.0) {
        // Rejeita evento se houver reaceleração significativa (> 4.0 km/h)
        t100Brake = null;
        _brakePrevSpd = null;
      } else if (t - t100Brake! > 15.0) {
        t100Brake = null;
        _brakePrevSpd = null;
      } else if (speedKmh <= 1.0) {
        final frenagem = t - t100Brake!;
        if (frenagem > 0.4 && frenagem < 12.0) {
          record.braking100to0 = _round2(frenagem);
          eventMsg =
              'Frenagem 100 a 0 km/h: ${record.braking100to0!.toStringAsFixed(2)} s';
        }
        t100Brake = null;
        _brakePrevSpd = null;
      } else {
        _brakePrevSpd = speedKmh;
      }
    }

    return eventMsg;
  }
}
