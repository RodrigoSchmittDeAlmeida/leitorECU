"""Detector automático de eventos de desaceleração / Cut-Off, anomalias e diagnósticos Turbo."""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from typing import Deque, Dict, List, Optional, Tuple


@dataclass
class DetectorConfig:
    rpm_start: float = 3000.0        # RPM mínimo antes da queda
    rpm_drop: float = 400.0          # queda mínima para caracterizar desaceleração
    drop_window: float = 2.0         # janela (s) para medir a queda
    tps_max: float = 15.0            # borboleta considerada "fechada"
    rpm_end: float = 1300.0          # fim do evento (reentrada de combustível / perto da lenta)
    lambda_rich: float = 0.70        # sonda narrowband acima disso = rico (falha de cut-off)
    lambda_lean_ok: float = 0.20     # sonda narrowband abaixo disso = cut-off atuou
    lambda_eq_rich: float = 0.85     # wideband lambda abaixo disso = rico (falha de cut-off)
    lambda_eq_lean_ok: float = 1.50  # wideband lambda acima disso = cut-off atuou
    advance_min: float = -5.0        # avanço abaixo disso = anomalia
    overboost_limit: float = 1.80    # limite estático de boost (bar)
    overboost_delta: float = 0.25    # desvio acima do alvo (bar)
    underboost_delta: float = 0.40   # desvio abaixo do alvo (bar)
    knock_warn: float = 3.0          # retardo de detonação para aviso (°KW)
    knock_alarm: float = 6.0         # retardo de detonação para alarme (°KW)
    trim_drift_limit: float = 22.0   # soma STFT + LTFT (%) para alerta de desvio
    max_duration: float = 12.0
    freshness: float = 1.5           # idade máxima (s) de um valor para ser considerado


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
        self._last_vacuum_alert: float = -1e9
        self._last_atdc_alert: float = -1e9
        self.crank_in_progress: bool = False
        self.min_crank_volt: Optional[float] = None
        self.last_crank_event: float = -1e9

        # Estados diagnósticos adicionais (Turbo & Combustível)
        self._overboost_start: Optional[float] = None
        self._last_overboost_alert: float = -1e9
        self._underboost_start: Optional[float] = None
        self._last_underboost_alert: float = -1e9
        self._last_knock_alert: float = -1e9
        self._trim_drift_start: Optional[float] = None
        self._last_trim_drift_alert: float = -1e9

        self._reset_episode()

    def reset(self) -> None:
        self.rpm_hist.clear()
        self.in_decel = False
        self._last_vacuum_alert = -1e9
        self._last_atdc_alert = -1e9
        self.crank_in_progress = False
        self.min_crank_volt = None
        self.last_crank_event = -1e9
        self._overboost_start = None
        self._last_overboost_alert = -1e9
        self._underboost_start = None
        self._last_underboost_alert = -1e9
        self._last_knock_alert = -1e9
        self._trim_drift_start = None
        self._last_trim_drift_alert = -1e9
        self._reset_episode()

    def _reset_episode(self):
        self.t_start = 0.0
        self.rpm_peak = 0.0
        self.max_lambda: Optional[float] = None
        self.min_lambda: Optional[float] = None
        self.max_lambda_eq: Optional[float] = None
        self.min_lambda_eq: Optional[float] = None
        self.min_adv: Optional[float] = None
        self.rich_alerted = False
        self.adv_alerted = False

    def update(self, t: float, latest: Dict[str, float], stamp: Dict[str, float]) -> List[Event]:
        c = self.cfg
        ev: List[Event] = []

        def fresh(k):
            return k in latest and t - stamp.get(k, -1e9) <= c.freshness

        # --- Diagnóstico Contínuo 1: Conflito de Carga / Vácuo Baixo / Ar Falso (ME7.5.30 Baixa RPM)
        # Tolerância < 0.25s permite suporte robusto a Ford & Generic OBD sem falsos positivos de time-skew
        if (fresh("rpm") and fresh("map") and (fresh("tps") or "tps" in latest)
                and abs(stamp.get("map", 0.0) - stamp.get("tps", -99.0)) < 0.25):
            rpm_val = latest["rpm"]
            tps_val = latest.get("tps", 0.0)
            map_val = latest["map"]
            if rpm_val < 1900.0 and tps_val < 8.0 and map_val > 60.0:
                if t - self._last_vacuum_alert >= 2.0:
                    self._last_vacuum_alert = t
                    ev.append(Event(t, "alarm",
                                    f"CARGA ANORMAL COM BORBOLETA FECHADA: MAP em {map_val:.1f} kPa "
                                    f"com TPS {tps_val:.1f}% a {rpm_val:.0f} RPM"))

        # --- Diagnóstico Contínuo 2: Retardo Crítico ATDC (Avanço Negativo / Pipoco no Escape)
        if fresh("advance"):
            adv_val = latest["advance"]
            if adv_val < -8.0:
                if t - self._last_atdc_alert >= 2.0:
                    self._last_atdc_alert = t
                    f_sys = latest.get("fuel_sys1")
                    lv = latest.get("lambda_v")
                    if f_sys == 2.0 or (lv is not None and lv > 0.35):
                        malha_str = "malha fechada sem Cut-Off"
                    elif f_sys == 1.0 or (lv is not None and lv <= 0.15):
                        malha_str = "Cut-Off ativo / Open Loop"
                    else:
                        malha_str = "malha não confirmada"
                    map_str = f", MAP {latest['map']:.1f} kPa" if fresh("map") else ""
                    rpm_str = f" a {latest['rpm']:.0f} RPM" if fresh("rpm") else ""
                    ev.append(Event(t, "alarm",
                                    f"RETARDO CRÍTICO ATDC: avanço em {adv_val:.1f}°{map_str}{rpm_str} "
                                    f"— {malha_str} (risco de pipoco e vibração)"))

        # --- Diagnóstico Contínuo 3: Teste de Queda de Tensão na Partida (Cranking Voltage Drop)
        if fresh("rpm"):
            rpm_cur = latest["rpm"]
            volt = latest.get("battery") or latest.get("obd_pin16_v") or latest.get("ecu_volt")
            if 50.0 <= rpm_cur <= 450.0:
                if not self.crank_in_progress:
                    self.crank_in_progress = True
                    self.min_crank_volt = volt
                elif volt is not None:
                    self.min_crank_volt = volt if self.min_crank_volt is None else min(self.min_crank_volt, volt)
            elif rpm_cur >= 650.0:
                if self.crank_in_progress and (t - self.last_crank_event >= 5.0):
                    self.crank_in_progress = False
                    self.last_crank_event = t
                    if self.min_crank_volt is not None:
                        v_min = self.min_crank_volt
                        if v_min >= 10.2:
                            ev.append(Event(t, "ok", f"Partida do motor concluída: tensão mínima {v_min:.2f} V — Bateria e arranque EXCELENTES"))
                        elif v_min >= 9.6:
                            ev.append(Event(t, "info", f"Partida do motor: tensão mínima {v_min:.2f} V — Bateria NORMAL"))
                        elif v_min >= 8.5:
                            ev.append(Event(t, "warn", f"ATENÇÃO: Queda moderada de tensão na partida ({v_min:.2f} V) — Bateria com carga baixa"))
                        else:
                            ev.append(Event(t, "alarm", f"ALERTA: Queda severa de tensão na partida ({v_min:.2f} V < 9.6 V) — Bateria fraca ou aterramento deficiente!"))
            elif rpm_cur < 40.0:
                self.crank_in_progress = False

        # --- Diagnóstico Turbo 1: Overboost Crítico
        boost_bar = latest.get("boost_bar")
        target_boost = latest.get("boost_target_bar")
        if boost_bar is not None:
            if target_boost is not None and target_boost > 0.10:
                is_overboost = boost_bar > (target_boost + c.overboost_delta)
            else:
                is_overboost = boost_bar > c.overboost_limit

            if is_overboost:
                if self._overboost_start is None:
                    self._overboost_start = t
                elif (t - self._overboost_start >= 0.4) and (t - self._last_overboost_alert >= 2.5):
                    self._last_overboost_alert = t
                    alvo_msg = f" (alvo: {target_boost:.2f} bar)" if target_boost is not None else f" (> {c.overboost_limit:.2f} bar)"
                    ev.append(Event(t, "alarm",
                                    f"OVERBOOST CRÍTICO: pressão em {boost_bar:.2f} bar{alvo_msg} — "
                                    f"risco iminente de rompimento de mangueiras/turbina"))
            else:
                self._overboost_start = None

        # --- Diagnóstico Turbo 2: Underboost / Vazamento de Pressão
        if fresh("rpm") and (fresh("tps") or "tps" in latest) and boost_bar is not None and target_boost is not None:
            rpm_val = latest["rpm"]
            tps_val = latest.get("tps", 0.0)
            if tps_val > 80.0 and rpm_val > 3000.0 and target_boost >= 0.50 and (boost_bar < target_boost - c.underboost_delta):
                if self._underboost_start is None:
                    self._underboost_start = t
                elif (t - self._underboost_start >= 1.5) and (t - self._last_underboost_alert >= 4.0):
                    self._last_underboost_alert = t
                    ev.append(Event(t, "warn",
                                    f"UNDERBOOST / VAZAMENTO DE PRESSÃO: {boost_bar:.2f} bar com alvo em {target_boost:.2f} bar "
                                    f"a {rpm_val:.0f} RPM e TPS {tps_val:.0f}%"))
            else:
                self._underboost_start = None
        else:
            self._underboost_start = None

        # --- Diagnóstico Turbo 3: Retardo de Ignição por Detonação (Knock Retard)
        knock_max = latest.get("knock_retard_max")
        if knock_max is not None:
            if knock_max >= c.knock_alarm:
                if t - self._last_knock_alert >= 2.0:
                    self._last_knock_alert = t
                    ev.append(Event(t, "alarm",
                                    f"DETONAÇÃO CRÍTICA (KNOCK): retardo em {knock_max:.1f}°KW (>= {c.knock_alarm:.1f}°) — "
                                    f"risco imediato de danos aos pistões!"))
            elif knock_max >= c.knock_warn:
                if t - self._last_knock_alert >= 3.0:
                    self._last_knock_alert = t
                    ev.append(Event(t, "warn",
                                    f"DETONAÇÃO MODERADA: retardo de ignição em {knock_max:.1f}°KW (>= {c.knock_warn:.1f}°)"))

        # --- Diagnóstico Combustível 4: Desvio Severo de Mistura / Inconsistência de Etanol
        stft = latest.get("stft")
        ltft = latest.get("ltft")
        if stft is not None and ltft is not None and fresh("rpm"):
            rpm_val = latest["rpm"]
            tps_val = latest.get("tps", 0.0)
            if 650.0 <= rpm_val <= 3800.0 and tps_val <= 50.0:
                total_trim = stft + ltft
                if abs(total_trim) > c.trim_drift_limit:
                    if self._trim_drift_start is None:
                        self._trim_drift_start = t
                    elif (t - self._trim_drift_start >= 2.0) and (t - self._last_trim_drift_alert >= 5.0):
                        self._last_trim_drift_alert = t
                        dir_str = "POSITIVO (mistura pobre / ar falso / bicos sujos)" if total_trim > 0 else "NEGATIVO (mistura rica / bico gotejando / excesso de etanol)"
                        ev.append(Event(t, "warn",
                                        f"DESVIO SEVERO DE MISTURA (A/F DRIFT): Correção Total {total_trim:+.1f}% "
                                        f"em regime estável — {dir_str}"))
                else:
                    self._trim_drift_start = None
            else:
                self._trim_drift_start = None

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
        reaccel = tps is not None and tps > c.tps_max
        if reaccel:
            dur = t - self.t_start
            if self.max_lambda_eq is not None:
                lam = f"lambda máx {self.max_lambda_eq:.2f} / mín {self.min_lambda_eq:.2f}"
            elif self.max_lambda is not None:
                lam = f"sonda máx {self.max_lambda:.2f} V / mín {self.min_lambda:.2f} V"
            else:
                lam = "sem leitura de sonda"
            adv = f"avanço mín {self.min_adv:.1f}°" if self.min_adv is not None else "sem leitura de avanço"

            if self.rich_alerted or self.adv_alerted:
                level, verdict = "warn", "COM ANOMALIAS"
            elif (self.max_lambda_eq is not None and self.max_lambda_eq >= c.lambda_eq_lean_ok) or (self.min_lambda is not None and self.min_lambda <= c.lambda_lean_ok):
                level, verdict = "ok", "Cut-Off OK"
            else:
                level, verdict = "info", "Cut-Off não confirmado"
            ev.append(Event(t, level, f"Fim da desaceleração (reaceleração, {dur:.1f}s): {verdict} — {lam}, {adv}"))
            self.in_decel = False
            return ev

        # Análise de Sonda Lambda durante Cut-Off
        has_wideband = fresh("lambda_eq") or "lambda_eq" in latest
        if has_wideband and (tps is None or tps <= c.tps_max):
            leq = latest["lambda_eq"]
            self.max_lambda_eq = leq if self.max_lambda_eq is None else max(self.max_lambda_eq, leq)
            self.min_lambda_eq = leq if self.min_lambda_eq is None else min(self.min_lambda_eq, leq)
            if leq < c.lambda_eq_rich and not self.rich_alerted:
                self.rich_alerted = True
                ev.append(Event(t, "alarm",
                                f"FALHA DE CUT-OFF: lambda em {leq:.2f} (< {c.lambda_eq_rich:.2f}) com borboleta "
                                f"fechada a {rpm:.0f} RPM — excesso de combustível (pipocos no escape)"))
        elif fresh("lambda_v") and (tps is None or tps <= c.tps_max):
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

        if rpm <= c.rpm_end or t - self.t_start > c.max_duration:
            dur = t - self.t_start
            why = "chegou à lenta" if rpm <= c.rpm_end else "tempo máximo"
            if self.max_lambda_eq is not None:
                lam = f"lambda máx {self.max_lambda_eq:.2f} / mín {self.min_lambda_eq:.2f}"
            elif self.max_lambda is not None:
                lam = f"sonda máx {self.max_lambda:.2f} V / mín {self.min_lambda:.2f} V"
            else:
                lam = "sem leitura de sonda"
            adv = f"avanço mín {self.min_adv:.1f}°" if self.min_adv is not None else "sem leitura de avanço"

            if self.rich_alerted or self.adv_alerted:
                level, verdict = "warn", "COM ANOMALIAS"
            elif (self.max_lambda_eq is not None and self.max_lambda_eq >= c.lambda_eq_lean_ok) or (self.min_lambda is not None and self.min_lambda <= c.lambda_lean_ok):
                level, verdict = "ok", "Cut-Off OK"
            else:
                level, verdict = "info", "Cut-Off não confirmado"
            ev.append(Event(t, level, f"Fim da desaceleração ({why}, {dur:.1f}s): {verdict} — {lam}, {adv}"))
            self.in_decel = False
        return ev
