"""Gravação de logs CSV e buffers circulares para os gráficos."""
from __future__ import annotations

import csv
import os
import time
from typing import Dict, List, Optional, TextIO

import numpy as np

from .pids import CHANNELS

_BASE_COLS = ["timestamp_ms", "tempo_s", "atualizado"]


class CsvLogger:
    """Uma linha por amostra recebida, com timestamp em ms e o último valor de todos os canais.

    Colunas: as fixas de ``CHANNELS`` (sempre, na mesma ordem de antes) + colunas DINÂMICAS
    (blocos VAG ``gGGG_cN``, PIDs extras do Modo 01...) + ``evento`` no final.
    Se um canal novo aparecer no meio da gravação, o arquivo é reescrito com o cabeçalho ampliado
    (as linhas antigas ficam com a nova coluna vazia).
    """

    def __init__(self, decimal_comma: bool = True):
        # vírgula decimal + ';' => abre direto no Excel em português
        self.decimal_comma = decimal_comma
        self._fh: Optional[TextIO] = None
        self._w = None
        self.path = ""
        self.rows = 0
        self._last_flush = 0.0
        self.extra_cols: List[str] = []
        self.extra_labels: Dict[str, str] = {}

    @property
    def active(self) -> bool:
        return self._fh is not None

    def _header(self) -> List[str]:
        return (_BASE_COLS + list(CHANNELS.keys())
                + [self.extra_labels.get(k, k) for k in self.extra_cols] + ["evento"])

    def start(self, path: str, extra: Optional[Dict[str, str]] = None) -> None:
        """``extra``: {chave: cabeçalho} dos canais dinâmicos já conhecidos (evita reescrever o arquivo depois)."""
        self.stop()
        self.extra_cols = [k for k in (extra or {}) if k not in CHANNELS]
        self.extra_labels = {k: v for k, v in (extra or {}).items() if k not in CHANNELS}
        self._fh = open(path, "w", newline="", encoding="utf-8")
        self._w = csv.writer(self._fh, delimiter=";")
        self._w.writerow(self._header())
        self.path, self.rows = path, 0

    def add_columns(self, cols: Dict[str, str]) -> None:
        """Registra canais dinâmicos novos {chave: cabeçalho}. Durante a gravação, amplia o arquivo."""
        new = [k for k in cols if k not in CHANNELS and k not in self.extra_labels]
        relabel = any(k in self.extra_labels and self.extra_labels[k] != v for k, v in cols.items())
        for k, v in cols.items():
            if k not in CHANNELS:
                self.extra_labels[k] = v
        if not self.active:
            return
        if new or relabel:
            self._rewrite(new)

    def _rewrite(self, new: List[str]) -> None:
        """Reescreve o CSV com o cabeçalho ampliado, inserindo colunas vazias antes de 'evento'."""
        assert self._fh is not None
        self._fh.close()
        insert_at = len(_BASE_COLS) + len(CHANNELS) + len(self.extra_cols)
        with open(self.path, newline="", encoding="utf-8") as f:
            rows = list(csv.reader(f, delimiter=";"))
        self.extra_cols += new
        tmp = self.path + ".tmp"
        with open(tmp, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f, delimiter=";")
            w.writerow(self._header())
            pad = [""] * len(new)
            for r in rows[1:]:
                w.writerow(r[:insert_at] + pad + r[insert_at:])
        os.replace(tmp, self.path)
        self._fh = open(self.path, "a", newline="", encoding="utf-8")
        self._w = csv.writer(self._fh, delimiter=";")

    def write(self, wall_ms: float, t_rel: float, updated: str, latest: Dict[str, float], event: str = "") -> None:
        if not self._w:
            return
        unknown = [k for k in latest if k not in CHANNELS and k not in self.extra_labels]
        if unknown:
            self.add_columns({k: k for k in unknown})
        num = (lambda x: f"{x:.3f}".replace(".", ",")) if self.decimal_comma else (lambda x: f"{x:.3f}")
        row = [f"{wall_ms:.0f}", num(t_rel), updated]
        for k in CHANNELS:
            v = latest.get(k)
            row.append("" if v is None else num(v))
        for k in self.extra_cols:
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


def export_megalogviewer_csv(src_csv_path: str, dst_msl_path: str) -> bool:
    """Converte um log gravado para o formato padrão do MegaLogViewer HD / TunerStudio.

    Gera arquivo delimitado por tabulação com ponto decimal (.) e mapeia nomes
    canônicos de colunas (Time, RPM, MAP, TPS, Advance, CLT, MAT, Batt_V, etc.).
    """
    try:
        with open(src_csv_path, "r", encoding="utf-8") as f_in:
            reader = csv.reader(f_in, delimiter=";")
            header = next(reader)

            mlv_map = {
                "tempo_s": "Time",
                "rpm": "RPM",
                "map": "MAP",
                "tps": "TPS",
                "advance": "Advance",
                "lambda_v": "O2_Volts",
                "lambda2_v": "O2_Volts_Post",
                "stft": "Fuel_Trim_Short",
                "ltft": "Fuel_Trim_Long",
                "ect": "CLT",
                "iat": "MAT",
                "speed": "Speed_kmh",
                "battery": "Batt_V",
                "power_hp": "Power_HP",
                "torque_kgfm": "Torque_kgfm",
                "fuel_rate_lph": "Fuel_Flow_LPH",
                "trip_liters": "Trip_Fuel_Liters",
                "trip_km": "Trip_Distance_km",
                "volumetric_eff": "VE",
                "evento": "Marker",
            }

            out_header = [mlv_map.get(col, col) for col in header]

            with open(dst_msl_path, "w", newline="", encoding="utf-8") as f_out:
                writer = csv.writer(f_out, delimiter="\t")
                writer.writerow(out_header)
                for row in reader:
                    out_row = [val.replace(",", ".") for val in row]
                    writer.writerow(out_row)
        return True
    except Exception:
        return False
