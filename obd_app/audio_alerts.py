"""Gerenciador de avisos sonoros e Shift Light (winsound / thread não-bloqueante)."""
from __future__ import annotations

import sys
import threading
import time
from typing import Optional


class AudioAlertManager:
    """Dispara bipes sonoros de alta e baixa frequência sem travar a thread de renderização."""

    def __init__(self, shift_rpm: float = 6000.0, max_ect_c: float = 105.0):
        self.shift_rpm = shift_rpm
        self.max_ect_c = max_ect_c
        self.enabled = True
        self._last_beep_t = 0.0
        self.shift_triggered = False
        self.overheat_triggered = False

    def check(self, rpm: float, ect: Optional[float] = None) -> bool:
        """Verifica se os limites operacionais foram ultrapassados e dispara bipe."""
        if not self.enabled:
            return False

        now = time.monotonic()
        # Não dispara bipes consecutivos em menos de 0.6s
        if now - self._last_beep_t < 0.6:
            return False

        if rpm >= self.shift_rpm:
            self._last_beep_t = now
            self.shift_triggered = True
            self._async_beep(frequency=1750, duration_ms=120)  # Bipe agudo (Shift Light)
            return True
        elif ect is not None and ect >= self.max_ect_c:
            self._last_beep_t = now
            self.overheat_triggered = True
            self._async_beep(frequency=850, duration_ms=250)   # Bipe grave (Alerta térmico)
            return True
        return False

    def _async_beep(self, frequency: int, duration_ms: int) -> None:
        if sys.platform != "win32":
            return

        def _worker():
            try:
                import winsound
                winsound.Beep(frequency, duration_ms)
            except Exception:
                pass

        threading.Thread(target=_worker, daemon=True).start()
