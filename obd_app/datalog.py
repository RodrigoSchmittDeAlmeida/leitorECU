"""Gravação de logs CSV e buffers circulares para os gráficos."""
from __future__ import annotations

import csv
import time
from typing import Dict, Optional, TextIO

import numpy as np

from .pids import CHANNELS


class CsvLogger:
    """Uma linha por amostra recebida, com timestamp em ms e o último valor de todos os canais."""

    def __init__(self, decimal_comma: bool = True):
        # vírgula decimal + ';' => abre direto no Excel em português
        self.decimal_comma = decimal_comma
        self._fh: Optional[TextIO] = None
        self._w = None
        self.path = ""
        self.rows = 0
        self._last_flush = 0.0

    @property
    def active(self) -> bool:
        return self._fh is not None

    def start(self, path: str) -> None:
        self.stop()
        self._fh = open(path, "w", newline="", encoding="utf-8")
        self._w = csv.writer(self._fh, delimiter=";")
        self._w.writerow(["timestamp_ms", "tempo_s", "atualizado"] + list(CHANNELS.keys()) + ["evento"])
        self.path, self.rows = path, 0

    def write(self, wall_ms: float, t_rel: float, updated: str, latest: Dict[str, float], event: str = "") -> None:
        if not self._w:
            return
        num = (lambda x: f"{x:.3f}".replace(".", ",")) if self.decimal_comma else (lambda x: f"{x:.3f}")
        row = [f"{wall_ms:.0f}", num(t_rel), updated]
        for k in CHANNELS:
            v = latest.get(k)
            row.append("" if v is None else num(v))
        row.append(event)
        self._w.writerow(row)
        self.rows += 1
        now = time.monotonic()
        if now - self._last_flush > 0.5:
            self._fh.flush()
            self._last_flush = now

    def stop(self) -> None:
        if self._fh:
            self._fh.close()
        self._fh, self._w = None, None


class SeriesBuffer:
    """Buffer circular simples (numpy) com busca por janela de tempo."""

    def __init__(self, capacity: int = 40000):
        self.t = np.empty(capacity, dtype=np.float64)
        self.v = np.empty(capacity, dtype=np.float64)
        self.n = 0

    def append(self, t: float, v: float) -> None:
        if self.n >= len(self.t):
            keep = len(self.t) // 2
            self.t[:keep] = self.t[self.n - keep:self.n]
            self.v[:keep] = self.v[self.n - keep:self.n]
            self.n = keep
        self.t[self.n] = t
        self.v[self.n] = v
        self.n += 1

    def window(self, t_from: float):
        t = self.t[:self.n]
        i = int(np.searchsorted(t, t_from))
        return t[i:], self.v[i:self.n]

    def clear(self) -> None:
        self.n = 0
