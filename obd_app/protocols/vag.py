"""Estratégia de comunicação VAG KWP2000 (VW Gol G5 ME7.5.30).

Encapsula handshake (ATSP4 + ATIIA01 + ATSH8110F1), blocos de medição Modo 21,
descoberta de grupos em background, cache local e DTCs via Serviço 18/14.
"""
from __future__ import annotations

import time
from typing import Any, Dict, List, Optional, Set, Tuple

from .. import dtc, vag
from ..elm327 import extract_payload
from ..pids import PIDS
from .base import BaseVehicleStrategy


class VagKwpStrategy(BaseVehicleStrategy):
    """Protocolo proprietário VAG KWP2000 para central Bosch ME7.5.30 (VW Gol G5)."""

    VAG_GROUPS = list(range(1, 256))

    def __init__(self):
        super().__init__("vw_gol_me75", "VW Gol G5 1.6 Flex (Bosch ME7.5.30)")
        self.ecu_id = ""
        self.vag_supported: Set[int] = set()
        self.vag_unsupported: Set[int] = set()
        self.vag_cells: Dict[str, Tuple[str, str]] = {}
        self._vag_queue: List[int] = []
        self._vag_pending_nodata: List[int] = []
        self._vag_fail: Dict[int, int] = {}
        self._vag_rot_idx = 0

        self.active_fast = [0x2103, 0x2121]  # Bloco 003 (RPM/MAP/TPS/Avanço) + Bloco 033 (Sonda/STFT)
        self.active_normal = [0x2103, 0x2121, 0x2120, 0x2104]  # + Bloco 032 (LTFT) + Bloco 004 (Bat/ECT/IAT)
        self.active_extra: List[int] = []

    def initialize(self, elm: Any, worker: Any) -> bool:
        """Inicializa VAG KWP2000 com 5-baud init no endereço 0x01."""
        worker.status.emit("connecting", "Inicializando protocolo VAG KWP2000 nativo (Bloco 033 Sonda Lambda)...")
        worker.log.emit("Inicializando VAG KWP2000 no endereço 01 (ATSP4 + ATIIA01 + ATSH8110F1)...")

        for attempt in range(1, 3):
            if not worker._running:
                return False
            elm.command("ATPC", 2.0)
            for _ in range(30):
                if not worker._running:
                    return False
                time.sleep(0.1)

            for cmd in ("ATAL", "ATSP4", "ATIB10", "ATKW0", "ATIIA01", "ATSH8110F1", "ATWM8110F13E"):
                elm.command(cmd, 2.0)

            r_init = elm.command("1089", 10.0)
            if r_init.error in ("UNABLE TO CONNECT", "ERROR", "BUS INIT: ERROR"):
                continue

            r_id = elm.command("1A9B", 2.5)
            if r_id.ok and r_id.data_lines():
                raw_id = "".join(r_id.data_lines())
                if raw_id.startswith("5A9B"):
                    try:
                        id_bytes = bytes.fromhex(raw_id[4:4 + (len(raw_id) - 4) // 2 * 2])
                    except ValueError:
                        id_bytes = b""
                    ascii_id = "".join(chr(b) if 32 <= b < 127 else " " for b in id_bytes).strip()
                    ecu_part = " ".join(ascii_id.split())
                    if ecu_part:
                        self.ecu_id = ecu_part.split()[0]
                    worker.log.emit(f"✔ ECU Identificada (VAG): {ecu_part}")

            # Testa Bloco 033 (Sonda Lambda + STFT)
            r_probe = elm.query_pid("2121")
            if r_probe.ok:
                self._setup_discovery(worker)
                worker.info.emit("Sonda Lambda e Fuel Trims ativos via VAG KWP2000 (Blocos 003, 032, 033)!")
                worker.status.emit("connected", "Conectado — VAG KWP2000 Nativo (Blocos 001..033 Sonda Ativa)")
                return True

        return False

    def _setup_discovery(self, worker: Any) -> None:
        cache = vag.load_cache(self.ecu_id or "desconhecida")
        self.vag_supported |= set(cache["supported"])
        self.vag_unsupported |= set(cache["unsupported"]) - self.vag_supported
        for k, v in cache["cells"].items():
            try:
                g = int(k[1:4])
                c = int(k.rsplit("_c", 1)[1])
                unit = v[1] if len(v) > 1 else ""
                self.vag_cells[k] = (vag.channel_label(g, c, unit), unit)
            except Exception:
                self.vag_cells.setdefault(k, v)
        known = self.vag_supported | self.vag_unsupported
        self._vag_queue = [g for g in self.VAG_GROUPS if g not in known]
        self._vag_pending_nodata = []
        self._vag_fail = {}
        if self.vag_cells:
            worker.channels.emit(dict(self.vag_cells))

    def _save_cache(self) -> None:
        vag.save_cache(self.ecu_id or "desconhecida", list(self.vag_supported),
                       list(self.vag_unsupported), self.vag_cells)

    def _mark_group(self, group: int, ok: bool) -> None:
        changed = False
        if ok and group not in self.vag_supported:
            self.vag_supported.add(group)
            self.vag_unsupported.discard(group)
            changed = True
        elif not ok and group not in self.vag_unsupported and group not in self.vag_supported:
            self.vag_unsupported.add(group)
            changed = True
        if group in self._vag_queue:
            self._vag_queue.remove(group)
        if group in self._vag_pending_nodata:
            self._vag_pending_nodata.remove(group)
        if changed:
            self._save_cache()

    def _confirm_pending(self) -> None:
        if self._vag_pending_nodata:
            for g in list(self._vag_pending_nodata):
                self._mark_group(g, False)

    def _decode_cells(self, resp, group: int, worker: Any) -> Optional[Dict[str, float]]:
        try:
            block = vag.extract_block(resp, group)
            if block is None:
                return None
            cells = vag.decode_block(group, block)
        except Exception:
            return None
        self._mark_group(group, True)
        new: Dict[str, Tuple[str, str]] = {}
        for k, (_, unit) in cells.items():
            cell = int(k.rsplit("_c", 1)[1])
            lbl = vag.channel_label(group, cell, unit)
            old = self.vag_cells.get(k)
            if old is None or old[1] != unit or old[0] != lbl:
                self.vag_cells[k] = new[k] = (lbl, unit)
        if new:
            worker.channels.emit(new)
            self._save_cache()
        return {k: v for k, (v, _) in cells.items()}

    def _probe_group(self, elm: Any, worker: Any, group: int) -> Optional[bool]:
        r = elm.command(f"21{group:02X}", 2.5)
        vals = self._decode_cells(r, group, worker)
        if vals is not None:
            pdef = PIDS.get(0x2100 | group)
            if pdef is not None and pdef.mode == 0x21:
                data = extract_payload(r, 0x21, group, pdef.nbytes)
                if data is not None:
                    try:
                        vals.update({k: v for k, v in pdef.decode(data).items() if v is not None})
                    except Exception:
                        pass
            if vals:
                worker._emit(vals)
            self._confirm_pending()
            return True
        if vag.is_negative(r):
            self._mark_group(group, False)
            return False
        if r.error == "NO DATA":
            if group in self._vag_queue:
                self._vag_queue.remove(group)
            if group not in self._vag_pending_nodata:
                self._vag_pending_nodata.append(group)
            return None
        n = self._vag_fail.get(group, 0) + 1
        self._vag_fail[group] = n
        if group in self._vag_queue:
            self._vag_queue.remove(group)
            if n < 3:
                self._vag_queue.append(group)
        return None

    def poll_cycle(self, elm: Any, worker: Any, cycle: int, decel_mode: bool) -> int:
        n_resp = 0
        read_extras = getattr(worker, "read_extras", True)
        if decel_mode or not read_extras:
            pids_to_query = list(self.active_fast)
        else:
            # Em todo ciclo lê os 2 blocos de alta velocidade (Bloco 003 + Bloco 033)
            # E intercala 1 dos 4 blocos complementares a cada ciclo:
            # 0: Bloco 002 (Inj/Carga/MAP), 1: Bloco 004 (ECT/IAT/Bat), 2: Bloco 005 (Vel/Cut-Off/Estado), 3: Bloco 032 (LTFT)
            interleaved = [0x2102, 0x2104, 0x2105, 0x2120]
            sec_block = interleaved[cycle % len(interleaved)]
            pids_to_query = list(self.active_fast) + [sec_block]

        for pcode in pids_to_query:
            if not worker._running:
                return n_resp
            pdef = PIDS.get(pcode)
            if pdef is None:
                continue
            resp = elm.query_pid(pdef.cmd)
            if resp.ok:
                data = extract_payload(resp, pdef.mode, pdef.pid, pdef.nbytes)
                if data is not None:
                    try:
                        vals = {k: v for k, v in pdef.decode(data).items() if v is not None}
                    except Exception:
                        vals = {}
                    if vals:
                        vals.update(self._decode_cells(resp, pdef.pid, worker) or {})
                        self._confirm_pending()
                        worker._emit(vals)
                        n_resp += 1

        # Sondagem de blocos adicionais DESCONHECIDOS em background somente se habilitado pelo usuário
        # e somente enquanto houver blocos na fila de descoberta (_vag_queue).
        # Não rotaciona continuamente pelos blocos secundários já conhecidos/em cache,
        # para preservar taxa de amostragem máxima (~3-4 Hz) no Bloco 003.
        if not decel_mode and getattr(worker, "background_scan_enabled", False):
            if self._vag_queue and cycle % 4 == 0:
                target_g = self._vag_queue[0]
                if self._probe_group(elm, worker, target_g) is True:
                    n_resp += 1

        return n_resp

    def read_dtcs(self, elm: Any, worker: Any) -> None:
        r = elm.command("1800FF00", 6.0)
        lines = r.data_lines()
        found = []
        if r.ok and lines:
            raw = "".join(lines)
            idx = raw.find("58")
            if idx != -1:
                hex_data = raw[idx + 2:]
                parsed = dtc.parse_kwp_dtcs_hex(hex_data)
                for code, desc in parsed:
                    found.append((f"{code} (KWP)", desc))
        worker.dtcs.emit(False, 0, found)

    def clear_dtcs(self, elm: Any, worker: Any) -> None:
        elm.command("14FF00", 6.0)
        self.read_dtcs(elm, worker)

    def scan_all(self, elm: Any, worker: Any) -> None:
        groups = [g for g in self.VAG_GROUPS if g not in self.vag_unsupported]
        n = len(groups)
        worker.log.emit(f"Varredura de blocos VAG: {n} blocos...")
        for i, g in enumerate(groups):
            if not worker._running:
                return
            if i % 8 == 0:
                worker.status.emit("connected", f"Varrendo blocos VAG: {g:03d} ({i + 1}/{n})...")
            res = self._probe_group(elm, worker, g)
            if (res is None and len(self._vag_pending_nodata) >= 8) or i % 8 == 7:
                if self._probe_group(elm, worker, 0x21) is not True:
                    worker.log.emit("Sessão VAG não respondeu durante a varredura — reinicializando...")
                    self._vag_pending_nodata.clear()
                    worker._reinit_bus()
        self._probe_group(elm, worker, 0x21)
        self._save_cache()
        worker.info.emit("Varredura de blocos VAG concluída com sucesso!")
        worker.status.emit("connected", "Conectado — VAG KWP2000 Nativo (Varredura Concluída)")

    def get_channels_info(self) -> Dict[str, Tuple[str, str]]:
        return dict(self.vag_cells)

