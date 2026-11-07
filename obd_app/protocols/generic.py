"""Estratégia de comunicação OBD-II Genérico Padrão (ISO 15765-4 / ISO 9141-2 / ISO 14230-4).

Encapsula autodetecção de protocolo (ATSP0), sondagem de bitmaps de PIDs (0100, 0120, 0140),
autodiscovery de sondas lambda e fuel trims, e leitura padrão de DTCs Modo 03/04.
"""
from __future__ import annotations

import time
from typing import Any, Dict, List, Optional, Set, Tuple

from .. import dtc
from ..elm327 import extract_payload
from ..pids import (EXTRA_ORDER, FAST_ORDER, LAMBDA_CANDIDATES,
                    LTFT_CANDIDATES, NORMAL_ORDER, PIDS, STFT_CANDIDATES)
from .base import BaseVehicleStrategy


class GenericObdStrategy(BaseVehicleStrategy):
    """Protocolo OBD-II padrão aplicável a qualquer veículo com tomada de 16 pinos."""

    BITMAP_PIDS = {0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0}

    def __init__(self):
        super().__init__("generic_obd", "OBD2 Genérico / Automático")
        self.supported: Set[int] = set()
        self.active_fast: List[int] = []
        self.active_normal: List[int] = []
        self.active_extra: List[int] = []
        self._no_data_streak: Dict[int, int] = {}

    def initialize(self, elm: Any, worker: Any) -> bool:
        worker.status.emit("connecting", "Detectando protocolo OBD-II padrão (ATSP0)...")
        elm.command("ATSP0", 3.0)

        # Dispara 0100 com timeout para permitir Fast Init na Linha K ou CAN
        r0 = elm.command("0100", 12.0)
        if not r0.ok:
            # Fallback explícito para protocolos comuns
            for proto in ("ATSP6", "ATSP3", "ATSP5", "ATSP4"):
                if not worker._running:
                    return False
                elm.command(proto, 2.0)
                r = elm.command("0100", 4.0)
                if r.ok:
                    r0 = r
                    break

        if not r0.ok:
            return False

        worker.status.emit("connecting", "Mapeando PIDs suportados pela ECU...")
        self._probe_bitmaps(elm, worker)
        self._discover_sensors(elm, worker)
        worker.status.emit("connected", "Conectado — OBD-II Genérico (Modo 01 Ativo)")
        return True

    def _probe_bitmaps(self, elm: Any, worker: Any) -> None:
        self.supported.clear()
        for base_pid in (0x00, 0x20, 0x40):
            if base_pid != 0 and base_pid not in self.supported:
                break
            resp = elm.command(f"01{base_pid:02X}", 3.0)
            data = extract_payload(resp, 0x01, base_pid, 4)
            if data and len(data) == 4:
                mask = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3]
                for bit in range(32):
                    if mask & (1 << (31 - bit)):
                        self.supported.add(base_pid + 1 + bit)

    def _discover_sensors(self, elm: Any, worker: Any) -> None:
        lambda_keys: List[int] = []
        for cand in LAMBDA_CANDIDATES:
            if not self.supported or cand in self.supported:
                r = elm.query_pid(PIDS[cand].cmd)
                if r.ok and extract_payload(r, 1, cand, PIDS[cand].nbytes):
                    lambda_keys.append(cand)

        stft_key = None
        for cand in STFT_CANDIDATES:
            if not self.supported or cand in self.supported:
                r = elm.query_pid(PIDS[cand].cmd)
                if r.ok and extract_payload(r, 1, cand, PIDS[cand].nbytes):
                    stft_key = cand
                    break

        ltft_key = None
        for cand in LTFT_CANDIDATES:
            if not self.supported or cand in self.supported:
                r = elm.query_pid(PIDS[cand].cmd)
                if r.ok and extract_payload(r, 1, cand, PIDS[cand].nbytes):
                    ltft_key = cand
                    break

        base_fast = [p for p in (0x0C, 0x0B, 0x0E, 0x11) if not self.supported or p in self.supported]
        for lk in lambda_keys:
            if lk not in base_fast:
                base_fast.append(lk)

        base_normal = list(base_fast)
        if stft_key and stft_key not in base_normal:
            base_normal.append(stft_key)
        if ltft_key and ltft_key not in base_normal:
            base_normal.append(ltft_key)
        if not self.supported or 0x05 in self.supported:
            base_normal.append(0x05)

        extras = [p for p in EXTRA_ORDER if not self.supported or p in self.supported]
        self.active_fast = base_fast
        self.active_normal = base_normal
        self.active_extra = extras

        if lambda_keys:
            names = ", ".join(f"{PIDS[k].cmd} ({PIDS[k].name})" for k in lambda_keys)
            worker.info.emit(f"Sonda Lambda ativa: {names}")

    def poll_cycle(self, elm: Any, worker: Any, cycle: int, decel_mode: bool) -> int:
        n_resp = 0
        if decel_mode:
            pids = list(self.active_fast)
        elif cycle % 4 == 3 and self.active_extra:
            pids = list(self.active_normal) + [self.active_extra[cycle % len(self.active_extra)]]
        else:
            pids = list(self.active_normal)

        for pcode in pids:
            if not worker._running:
                return n_resp
            pdef = PIDS[pcode]
            resp = elm.query_pid(pdef.cmd)
            if resp.ok:
                data = extract_payload(resp, pdef.mode, pdef.pid, pdef.nbytes)
                if data is not None:
                    try:
                        vals = {k: v for k, v in pdef.decode(data).items() if v is not None}
                        if vals:
                            worker._emit(vals)
                            n_resp += 1
                            self._no_data_streak[pcode] = 0
                    except Exception:
                        pass
            elif resp.error in ("NO DATA", "?"):
                streak = self._no_data_streak.get(pcode, 0) + 1
                self._no_data_streak[pcode] = streak
                if streak >= 3 and pcode not in self.supported:
                    for lst in (self.active_fast, self.active_normal, self.active_extra):
                        if pcode in lst:
                            lst.remove(pcode)

        if not decel_mode and cycle % 5 == 0 and hasattr(elm, "battery_voltage"):
            try:
                v_pin16 = elm.battery_voltage()
                if v_pin16 is not None and 5.0 <= v_pin16 <= 20.0:
                    worker._emit({"obd_pin16_v": v_pin16, "battery": v_pin16})
            except Exception:
                pass

        return n_resp

    def read_dtcs(self, elm: Any, worker: Any) -> None:
        r1 = elm.command("0101", 2.0)
        mil_on, n_dtc = False, 0
        if r1.ok and r1.data_lines():
            raw = "".join(r1.data_lines()).replace(" ", "")
            try:
                b = int(raw[4:6], 16) if len(raw) >= 6 else 0
                mil_on = bool(b & 0x80)
                n_dtc = b & 0x7F
            except Exception:
                pass

        r3 = elm.command("03", 4.0)
        found = []
        if r3.ok and r3.data_lines():
            raw = "".join(r3.data_lines()).replace(" ", "")
            found = dtc.parse_dtcs_hex(raw)

        worker.dtcs.emit(mil_on, n_dtc, found)

    def clear_dtcs(self, elm: Any, worker: Any) -> None:
        elm.command("04", 4.0)
        self.read_dtcs(elm, worker)

