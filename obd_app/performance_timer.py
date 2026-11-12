"""Cronômetro de desempenho automotivo de alta precisão (Dragy / RaceChrono style).

Calcula arrancada (0-60, 0-100 km/h), retomadas (80-120 km/h, 100-200 km/h), frenagem (100-0 km/h)
e distâncias de pista (201m e 402m) com detecção automática de largada.
"""
from __future__ import annotations

import copy
from dataclasses import dataclass, field
from typing import Dict, List, Optional


@dataclass
class PerformanceRecord:
    time_0_60: Optional[float] = None
    time_0_100: Optional[float] = None
    time_80_120: Optional[float] = None
    time_100_200: Optional[float] = None
    time_100_0: Optional[float] = None
    time_201m: Optional[float] = None
    time_402m: Optional[float] = None
    speed_201m: Optional[float] = None
    speed_402m: Optional[float] = None
    max_speed: float = 0.0
    max_g: float = 0.0


class PerformanceTimer:
    """Máquina de estados para medição de arrancada, aceleração e frenagem."""

    def __init__(self):
        self.state: str = "ARMED"  # ARMED | RUNNING | FINISHED
        self.t_launch: Optional[float] = None
        self.t_80: Optional[float] = None
        self.t_100: Optional[float] = None
        self.t_100_brake: Optional[float] = None
        self._brake_prev_spd: Optional[float] = None
        self._saved_to_history: bool = False
        self.distance_m: float = 0.0
        self.last_t: Optional[float] = None
        self.last_spd_ms: float = 0.0
        self.record = PerformanceRecord()
        self.history: List[PerformanceRecord] = []

    def reset(self) -> None:
        """Reinicia o cronômetro para o estado inicial ARMED mantendo o histórico de medições."""
        self.state = "ARMED"
        self.t_launch = None
        self.t_80 = None
        self.t_100 = None
        self.t_100_brake = None
        self._brake_prev_spd = None
        self._saved_to_history = False
        self.distance_m = 0.0
        self.last_t = None
        self.last_spd_ms = 0.0
        self.record = PerformanceRecord()

    def clear_history(self) -> None:
        """Limpa o histórico de corridas armazenadas."""
        self.history.clear()

    def update(self, t: float, speed_kmh: float) -> Optional[str]:
        """Processa nova amostra de velocidade. Retorna mensagem de evento se completou um marco."""
        event_msg: Optional[str] = None
        spd_ms = max(0.0, speed_kmh / 3.6)

        # 1. Integração da distância percorrida
        if self.last_t is not None and t > self.last_t:
            dt = t - self.last_t
            # Integração trapezoidal
            self.distance_m += (spd_ms + self.last_spd_ms) * 0.5 * dt

            # Aceleração longitudinal em Gs
            accel_ms2 = (spd_ms - self.last_spd_ms) / dt if dt > 0 else 0.0
            g_force = accel_ms2 / 9.80665
            if g_force > self.record.max_g:
                self.record.max_g = round(g_force, 2)

        self.last_t = t
        self.last_spd_ms = spd_ms

        if speed_kmh > self.record.max_speed:
            self.record.max_speed = round(speed_kmh, 1)

        # 2. Máquina de Estados da Arrancada (0 -> 100 km/h)
        if self.state == "ARMED":
            if speed_kmh < 1.0:
                self.distance_m = 0.0
                self.t_launch = None
            elif speed_kmh >= 2.0:
                # Detectou largada!
                self.state = "RUNNING"
                self.t_launch = t
                self.distance_m = 0.0
                self._saved_to_history = False
                event_msg = "LARGADA DETECTADA! Cronômetro iniciado..."

        elif self.state == "RUNNING" and self.t_launch is not None:
            elapsed = t - self.t_launch

            # Marco: 0 a 60 km/h
            if speed_kmh >= 60.0 and self.record.time_0_60 is None:
                self.record.time_0_60 = round(elapsed, 2)
                event_msg = f"0 a 60 km/h: {self.record.time_0_60:.2f} s"

            # Marco: 0 a 100 km/h
            if speed_kmh >= 100.0 and self.record.time_0_100 is None:
                self.record.time_0_100 = round(elapsed, 2)
                event_msg = f"0 a 100 km/h: {self.record.time_0_100:.2f} s"

            # Marco: 201m (1/8 milha)
            if self.distance_m >= 201.16 and self.record.time_201m is None:
                self.record.time_201m = round(elapsed, 2)
                self.record.speed_201m = round(speed_kmh, 1)
                event_msg = f"201m (1/8 milha): {self.record.time_201m:.2f} s @ {speed_kmh:.1f} km/h"

            # Marco: 402m (1/4 milha)
            if self.distance_m >= 402.33 and self.record.time_402m is None:
                self.record.time_402m = round(elapsed, 2)
                self.record.speed_402m = round(speed_kmh, 1)
                self.state = "FINISHED"
                event_msg = f"402m (1/4 milha): {self.record.time_402m:.2f} s @ {speed_kmh:.1f} km/h"

            if self.state == "FINISHED" and not self._saved_to_history:
                self.history.append(copy.deepcopy(self.record))
                self._saved_to_history = True

            # Se parar o carro após a puxada, finaliza e salva no histórico se houver marcos
            if speed_kmh < 1.0 and elapsed > 3.0:
                if not self._saved_to_history and (
                    self.record.time_0_60 or self.record.time_0_100 or self.record.time_201m or self.record.time_402m
                ):
                    self.history.append(copy.deepcopy(self.record))
                    self._saved_to_history = True
                self.state = "ARMED"

        # 3. Retomada de 80 a 120 km/h
        if speed_kmh <= 80.0:
            self.t_80 = t
        elif speed_kmh >= 120.0 and self.t_80 is not None:
            retomada = t - self.t_80
            if 0.5 < retomada < 25.0:
                self.record.time_80_120 = round(retomada, 2)
                event_msg = f"Retomada 80 a 120 km/h: {self.record.time_80_120:.2f} s"
            self.t_80 = None

        # 4. Aceleração / Retomada de 100 a 200 km/h
        if speed_kmh <= 100.0:
            self.t_100 = t
        elif speed_kmh >= 200.0 and self.t_100 is not None:
            retomada_200 = t - self.t_100
            if 0.5 < retomada_200 < 60.0:
                self.record.time_100_200 = round(retomada_200, 2)
                event_msg = f"100 a 200 km/h: {self.record.time_100_200:.2f} s"
            self.t_100 = None

        # 5. Frenagem 100 a 0 km/h (com validação de desaceleração contínua sem aceleração espúria)
        if speed_kmh >= 100.0:
            self.t_100_brake = t
            self._brake_prev_spd = speed_kmh
        elif self.t_100_brake is not None:
            # Rejeita evento se houver reaceleração significativa (> 4.0 km/h) durante a frenagem
            if self._brake_prev_spd is not None and speed_kmh > self._brake_prev_spd + 4.0:
                self.t_100_brake = None
                self._brake_prev_spd = None
            elif t - self.t_100_brake > 15.0:
                self.t_100_brake = None
                self._brake_prev_spd = None
            elif speed_kmh <= 1.0:
                frenagem = t - self.t_100_brake
                if 0.4 < frenagem < 12.0:
                    self.record.time_100_0 = round(frenagem, 2)
                    event_msg = f"Frenagem 100 a 0 km/h: {self.record.time_100_0:.2f} s"
                self.t_100_brake = None
                self._brake_prev_spd = None
            else:
                self._brake_prev_spd = speed_kmh

        return event_msg
