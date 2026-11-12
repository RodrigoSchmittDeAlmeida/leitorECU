"""Gerenciador de avisos sonoros e Shift Light (winsound / thread não-bloqueante)."""
from __future__ import annotations

import sys
import threading
import time
from typing import Optional


class AudioAlertManager:
    """Dispara bipes sonoros de alta e baixa frequência sem travar a thread de renderização."""

    def __init__(
        self,
        shift_rpm: float = 6000.0,
        max_ect_c: float = 105.0,
        rpm_hysteresis: float = 300.0,
        ect_hysteresis: float = 3.0,
    ):
        self.shift_rpm = shift_rpm
        self.max_ect_c = max_ect_c
        self.rpm_hysteresis = rpm_hysteresis
        self.ect_hysteresis = ect_hysteresis
        self.enabled = True
        self._last_beep_t = 0.0
        self.shift_triggered = False
        self.overheat_triggered = False
        self.overboost_triggered = False
        self.knock_triggered = False
        self._beep_lock = threading.Lock()

    def check(
        self,
        rpm: float,
        ect: Optional[float] = None,
        boost_bar: Optional[float] = None,
        overboost_limit: float = 1.80,
        knock_retard_max: Optional[float] = None,
    ) -> bool:
        """Verifica se os limites operacionais foram ultrapassados e dispara bipe com histerese."""
        if not self.enabled:
            return False

        # Reset de gatilhos via histerese quando as variáveis retornam à faixa normal
        if self.shift_triggered and rpm < (self.shift_rpm - self.rpm_hysteresis):
            self.shift_triggered = False

        if self.overheat_triggered and (ect is not None and ect < (self.max_ect_c - self.ect_hysteresis)):
            self.overheat_triggered = False

        if self.overboost_triggered and (boost_bar is not None and boost_bar < (overboost_limit - 0.20)):
            self.overboost_triggered = False

        if self.knock_triggered and (knock_retard_max is not None and knock_retard_max < 2.0):
            self.knock_triggered = False

        now = time.monotonic()
        # Cooldown: não dispara bipes consecutivos em menos de 0.6s
        if now - self._last_beep_t < 0.6:
            return False

        # Prioridade 1: Alerta de Overboost Crítico
        if boost_bar is not None and boost_bar >= overboost_limit:
            self._last_beep_t = now
            self.overboost_triggered = True
            self._async_beep(frequency=2200, duration_ms=160)
            return True

        # Prioridade 2: Alerta de Detonação Severa (Knock)
        if knock_retard_max is not None and knock_retard_max >= 6.0:
            self._last_beep_t = now
            self.knock_triggered = True
            self._async_beep(frequency=1250, duration_ms=200)
            return True

        # Prioridade 3: Shift Light (RPM Máximo)
        if rpm >= self.shift_rpm:
            self._last_beep_t = now
            self.shift_triggered = True
            self._async_beep(frequency=1750, duration_ms=120)  # Bipe agudo (Shift Light)
            return True

        # Prioridade 4: Sobreaquecimento Térmico (ECT)
        if ect is not None and ect >= self.max_ect_c:
            self._last_beep_t = now
            self.overheat_triggered = True
            self._async_beep(frequency=850, duration_ms=250)   # Bipe grave (Alerta térmico)
            return True

        return False

    def _async_beep(self, frequency: int, duration_ms: int) -> None:
        if sys.platform != "win32":
            return

        # Previne acúmulo ilimitado de threads: só despacha se não houver bipe em execução
        if not self._beep_lock.acquire(blocking=False):
            return

        def _worker():
            try:
                import winsound
                winsound.Beep(frequency, duration_ms)
            except Exception:
                pass
            finally:
                self._beep_lock.release()

        threading.Thread(target=_worker, daemon=True).start()
