"""Detector automático de eventos de desaceleração / Cut-Off."""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from typing import Deque, Dict, List, Optional, Tuple


@dataclass
class DetectorConfig:
    rpm_start: float = 3000.0      # RPM mínimo antes da queda
    rpm_drop: float = 400.0        # queda mínima para caracterizar desaceleração
    drop_window: float = 2.0       # janela (s) para medir a queda
    tps_max: float = 15.0          # borboleta considerada "fechada"
    rpm_end: float = 1300.0        # fim do evento (reentrada de combustível / perto da lenta)
    lambda_rich: float = 0.70      # sonda acima disso = rico (falha de cut-off)
    lambda_lean_ok: float = 0.20   # sonda abaixo disso = cut-off atuou
    advance_min: float = -5.0      # avanço abaixo disso = anomalia
    max_duration: float = 12.0
    freshness: float = 1.5         # idade máxima (s) de um valor para ser considerado


@dataclass
class Event:
    t: float
    level: str  # 'info' | 'warn' | 'alarm' | 'ok'
    message: str


class DecelDetector:
    def __init__(self, cfg: DetectorConfig | None = None):
        self.cfg = cfg or DetectorConfig()
        self.rpm_hist: Deque[Tuple[float, float]] = deque()
        self.in_decel = False
        self._reset_episode()

    def _reset_episode(self):
        self.t_start = 0.0
        self.rpm_peak = 0.0
        self.max_lambda: Optional[float] = None
        self.min_lambda: Optional[float] = None
        self.min_adv: Optional[float] = None
        self.rich_alerted = False
        self.adv_alerted = False

    def update(self, t: float, latest: Dict[str, float], stamp: Dict[str, float]) -> List[Event]:
        c = self.cfg
        ev: List[Event] = []

        def fresh(k):
            return k in latest and t - stamp.get(k, -1e9) <= c.freshness

        if not fresh("rpm"):
            return ev
        rpm = latest["rpm"]
        tps = latest["tps"] if fresh("tps") else None
        if not self.rpm_hist or self.rpm_hist[-1][0] != stamp["rpm"]:
            self.rpm_hist.append((stamp["rpm"], rpm))
        while self.rpm_hist and t - self.rpm_hist[0][0] > c.drop_window:
            self.rpm_hist.popleft()

        if not self.in_decel:
            if tps is None or tps >= c.tps_max:
                return ev
            peak = max(r for _, r in self.rpm_hist)
            if peak >= c.rpm_start and rpm <= peak - c.rpm_drop:
                self.in_decel = True
                self._reset_episode()
                self.t_start, self.rpm_peak = t, peak
                ev.append(Event(t, "info", f"Desaceleração detectada: {peak:.0f} → {rpm:.0f} RPM, TPS {tps:.1f}%"))
            return ev

        # ---- dentro do episódio
        if fresh("lambda_v"):
            lv = latest["lambda_v"]
            self.max_lambda = lv if self.max_lambda is None else max(self.max_lambda, lv)
            self.min_lambda = lv if self.min_lambda is None else min(self.min_lambda, lv)
            if lv > c.lambda_rich and not self.rich_alerted:
                self.rich_alerted = True
                ev.append(Event(t, "alarm",
                                f"FALHA DE CUT-OFF: sonda em {lv:.2f} V (> {c.lambda_rich:.2f} V) com borboleta "
                                f"fechada a {rpm:.0f} RPM — excesso de combustível (pipocos no escape)"))
        if fresh("advance"):
            adv = latest["advance"]
            self.min_adv = adv if self.min_adv is None else min(self.min_adv, adv)
            if adv < c.advance_min and not self.adv_alerted:
                self.adv_alerted = True
                ev.append(Event(t, "alarm",
                                f"AVANÇO NEGATIVO em desaceleração: {adv:.1f}° (< {c.advance_min:.0f}°) "
                                f"a {rpm:.0f} RPM — retardo excessivo / combustão no escape"))

        reaccel = tps is not None and tps >= c.tps_max + 3
        if rpm <= c.rpm_end or reaccel or t - self.t_start > c.max_duration:
            dur = t - self.t_start
            why = "reaceleração" if reaccel else ("chegou à lenta" if rpm <= c.rpm_end else "tempo máximo")
            lam = f"sonda máx {self.max_lambda:.2f} V / mín {self.min_lambda:.2f} V" if self.max_lambda is not None else "sem leitura de sonda"
            adv = f"avanço mín {self.min_adv:.1f}°" if self.min_adv is not None else "sem leitura de avanço"
            if self.rich_alerted or self.adv_alerted:
                level, verdict = "warn", "COM ANOMALIAS"
            elif self.min_lambda is not None and self.min_lambda <= c.lambda_lean_ok:
                level, verdict = "ok", "Cut-Off OK"
            else:
                level, verdict = "info", "Cut-Off não confirmado"
            ev.append(Event(t, level, f"Fim da desaceleração ({why}, {dur:.1f}s): {verdict} — {lam}, {adv}"))
            self.in_decel = False
        return ev
