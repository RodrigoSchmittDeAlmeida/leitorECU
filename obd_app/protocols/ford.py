"""Estratégia de comunicação Ford HS-CAN 500k (Ford Ka+ 2016 SEL 1.5 Sigma Sedan).

Encapsula barramento ISO 15765-4 (CAN 11/500k), modo UDS 22 para BCM Conforto,
ABS/ESC, IPC Painel, PSCM Direção Elétrica, PCM Sigma 1.5 DOHC com dupla sonda lambda,
temperatura CHT, catalisador e DTCs multimodulares.
"""
from __future__ import annotations

import time
from typing import Any, Callable, Dict, List, Optional, Tuple

from .. import dtc, ford
from ..elm327 import extract_payload
from ..pids import PIDS
from .base import BaseVehicleStrategy


class FordHsCanStrategy(BaseVehicleStrategy):
    """Protocolo Ford HS-CAN 500k multimodular para Ford Ka+ 2016 SEL 1.5 Sigma."""

    def __init__(self):
        super().__init__("ford_ka_2016_sigma", "Ford Ka+ 2016 SEL 1.5 Sigma Flex (HS-CAN)")
        self._curr_header = "7E0"

    def initialize(self, elm: Any, worker: Any) -> bool:
        """Inicializa HS-CAN 500k nos pinos 6 e 14 do OBD2."""
        worker.status.emit("connecting", "Inicializando barramento Ford HS-CAN 500k (PCM, BCM, ABS, IPC)...")
        worker.log.emit("Configurando ATSP6 (ISO 15765-4 CAN 11/500k) + ATSH7E0...")

        elm.command("ATPC", 1.0)
        for cmd in ("ATSP6", "ATAL", "ATCAF1", "ATC1", "ATSH7E0"):
            elm.command(cmd, 1.5)
        self._curr_header = "7E0"

        # Confirma comunicação com o PCM (PID 0100)
        r0 = elm.command("0100", 3.0)
        if r0.ok:
            worker.log.emit("✔ PCM Motor Ford (0x7E0) respondeu ao handshake!")
            # Registra canais Ford conhecidos
            worker.channels.emit(dict(ford.FORD_CHANNELS_INFO))
            worker.info.emit("Ford Ka+ conectado: Barramento HS-CAN 500k ativo com PCM, BCM Conforto, ABS, IPC e EPAS!")
            worker.status.emit("connected", "Conectado — Ford Ka+ 2016 SEL 1.5 Sigma (HS-CAN 500k Ativo)")
            return True

        worker.log.emit("PCM não respondeu no ATSP6. Tentando autodetecção ATSP0...")
        elm.command("ATSP0", 2.0)
        r_auto = elm.command("0100", 5.0)
        if r_auto.ok:
            worker.channels.emit(dict(ford.FORD_CHANNELS_INFO))
            worker.status.emit("connected", "Conectado — Ford Ka+ (CAN Auto)")
            return True

        return False

    def _query_did(self, elm: Any, worker: Any, module_tx: str, did: str,
                   decode_fn: Callable[[bytes], Dict[str, float]]) -> Optional[Dict[str, float]]:
        """Executa consulta a um DID UDS Modo 22 em um módulo específico."""
        if self._curr_header != module_tx:
            elm.command(f"ATSH{module_tx}")
            self._curr_header = module_tx

        resp = elm.command(f"22{did}", 1.8)
        if resp.ok and resp.data_lines():
            raw = "".join(resp.data_lines()).replace(" ", "").upper()
            if "NODATA" in raw:
                return None
            prefix = "62" + did.upper()
            idx = raw.find(prefix)
            if idx != -1:
                hex_data = raw[idx + len(prefix):]
                try:
                    raw_bytes = bytes.fromhex(hex_data[:(len(hex_data) // 2) * 2])
                    vals = decode_fn(raw_bytes)
                    if vals:
                        worker._emit(vals)
                        return vals
                except Exception:
                    pass
        return None

    def poll_cycle(self, elm: Any, worker: Any, cycle: int, decel_mode: bool) -> int:
        n_resp = 0

        # Garante header no PCM
        if self._curr_header != "7E0":
            elm.command("ATSH7E0")
            self._curr_header = "7E0"

        # 1. PIDs rápidos do Motor Sigma 1.5 (todo ciclo)
        # Sonda 1 (0114) e Sonda 2 (0115) ambas consultadas em alta taxa
        fast_pids = [0x0C, 0x0B, 0x0E, 0x11, 0x14, 0x15]
        if not decel_mode:
            fast_pids.extend([0x04, 0x0D])  # Carga, Velocidade

        for pid_code in fast_pids:
            if not worker._running:
                return n_resp
            pdef = PIDS[pid_code]
            resp = elm.query_pid(pdef.cmd)
            if resp.ok:
                data = extract_payload(resp, pdef.mode, pdef.pid, pdef.nbytes)
                if data is not None:
                    try:
                        vals = {k: v for k, v in pdef.decode(data).items() if v is not None}
                        if vals:
                            worker._emit(vals)
                            n_resp += 1
                    except Exception:
                        pass

        # Se prioridade de desaceleração ativada, foca 100% no motor Sigma
        if decel_mode:
            return n_resp

        # 2. PIDs normais do PCM (intercalados)
        if cycle % 2 == 0:
            for pid_code in (0x06, 0x07, 0x05, 0x0F):  # STFT, LTFT, ECT, IAT
                if not worker._running:
                    return n_resp
                pdef = PIDS[pid_code]
                resp = elm.query_pid(pdef.cmd)
                if resp.ok:
                    data = extract_payload(resp, pdef.mode, pdef.pid, pdef.nbytes)
                    if data is not None:
                        try:
                            vals = {k: v for k, v in pdef.decode(data).items() if v is not None}
                            if vals:
                                worker._emit(vals)
                                n_resp += 1
                        except Exception:
                            pass

        if cycle % 4 == 2:
            for pid_code in (0x03, 0x3C, 0x42, 0x33):  # Malha Injeção, Temp Catalisador, Tensão PCM, Baro
                if not worker._running:
                    return n_resp
                pdef = PIDS[pid_code]
                resp = elm.query_pid(pdef.cmd)
                if resp.ok:
                    data = extract_payload(resp, pdef.mode, pdef.pid, pdef.nbytes)
                    if data is not None:
                        try:
                            vals = {k: v for k, v in pdef.decode(data).items() if v is not None}
                            if vals:
                                worker._emit(vals)
                                n_resp += 1
                        except Exception:
                            pass

        # DIDs Ford PCM: CHT Temp, Pedal APP e Eletroventilador
        if cycle % 2 == 1:
            if self._query_did(elm, worker, "7E0", "1624", ford._dec_pcm_cht):
                n_resp += 1
            if self._query_did(elm, worker, "7E0", "032B", ford._dec_pcm_pedal):
                n_resp += 1
            if cycle % 4 == 1 and self._query_did(elm, worker, "7E0", "0332", ford._dec_pcm_fan):
                n_resp += 1

        # DIDs Ford PCM: Tempo de Injeção, Pressão A/C, Etanol Flex, Catalisador e Baro
        if cycle % 4 == 0:
            if self._query_did(elm, worker, "7E0", "1125", ford._dec_pcm_injection):
                n_resp += 1
            if self._query_did(elm, worker, "7E0", "1101", ford._dec_pcm_ac):
                n_resp += 1
            if self._query_did(elm, worker, "7E0", "1608", ford._dec_pcm_flex):
                n_resp += 1
            if self._query_did(elm, worker, "7E0", "1627", ford._dec_pcm_cat_temp):
                n_resp += 1
            if self._query_did(elm, worker, "7E0", "0320", ford._dec_pcm_baro):
                n_resp += 1

        # 3. Módulo de CONFORTO & CARROCERIA (BCM 726)
        if cycle % 2 == 0:
            if self._query_did(elm, worker, "726", "404C", ford._dec_bcm_doors):
                n_resp += 1
            if self._query_did(elm, worker, "726", "4050", ford._dec_bcm_lighting):
                n_resp += 1
            if cycle % 6 == 0:
                if self._query_did(elm, worker, "726", "4060", ford._dec_bcm_accessories):
                    n_resp += 1
                if self._query_did(elm, worker, "726", "4001", ford._dec_bcm_voltage):
                    n_resp += 1

        # 4. Módulo de FREIOS ABS & ESTABILIDADE (ABS 760)
        if cycle % 2 == 1:
            if self._query_did(elm, worker, "760", "2B00", ford._dec_abs_wheels):
                n_resp += 1
            if self._query_did(elm, worker, "760", "2B01", ford._dec_abs_dynamics):
                n_resp += 1

        # 5. Módulo do PAINEL DE INSTRUMENTOS (IPC 720)
        if cycle % 5 == 0:
            if self._query_did(elm, worker, "720", "DD01", ford._dec_ipc_odometer):
                n_resp += 1
            if self._query_did(elm, worker, "720", "2416", ford._dec_ipc_dashboard):
                n_resp += 1

        # 6. Módulo da DIREÇÃO ELÉTRICA EPAS (PSCM 730)
        if cycle % 3 == 0:
            if self._query_did(elm, worker, "730", "3300", ford._dec_pscm_steering):
                n_resp += 1

        if self._curr_header != "7E0":
            elm.command("ATSH7E0")
            self._curr_header = "7E0"

        return n_resp

    def read_dtcs(self, elm: Any, worker: Any) -> None:
        """Lê DTCs de múltiplos módulos Ford (PCM, BCM, ABS, IPC, PSCM, RCM)."""
        all_found = []
        mil_on_any = False
        dtc_count_total = 0

        for mod_key, mod in ford.FORD_MODULES.items():
            if not worker._running:
                return
            elm.command(f"ATSH{mod.tx_id}", 1.0)
            self._curr_header = mod.tx_id

            if mod_key == "pcm":
                r1 = elm.command("0101", 1.5)
                if r1.ok and r1.data_lines():
                    try:
                        raw = "".join(r1.data_lines()).replace(" ", "")
                        b = int(raw[4:6], 16) if len(raw) >= 6 else 0
                        if b & 0x80:
                            mil_on_any = True
                    except Exception:
                        pass

            r3 = elm.command("03", 2.0)
            lines = r3.data_lines()
            if r3.ok and lines:
                raw = "".join(lines).replace(" ", "")
                parsed = dtc.parse_dtcs_hex(raw)
                for code, desc in parsed:
                    all_found.append((f"[{mod.name}] {code}", desc))
                    dtc_count_total += 1

        elm.command("ATSH7E0", 1.0)
        self._curr_header = "7E0"
        worker.dtcs.emit(mil_on_any, dtc_count_total, all_found)

    def clear_dtcs(self, elm: Any, worker: Any) -> None:
        for mod_key, mod in ford.FORD_MODULES.items():
            elm.command(f"ATSH{mod.tx_id}", 1.0)
            elm.command("04", 2.0)
        elm.command("ATSH7E0", 1.0)
        self._curr_header = "7E0"
        self.read_dtcs(elm, worker)

    def scan_all(self, elm: Any, worker: Any) -> None:
        worker.log.emit("Varredura de todos os módulos Ford (PCM, BCM Conforto, ABS, IPC, PSCM, RCM)...")
        worker.status.emit("connected", "Varrendo todos os módulos Ford Ka+...")
        found = 0
        for did_key, fdid in ford.FORD_DIDS.items():
            if not worker._running:
                return
            mod = ford.FORD_MODULES.get(fdid.module_key)
            if not mod:
                continue
            did_num = fdid.did[2:] if fdid.did.startswith("22") else fdid.did
            res = self._query_did(elm, worker, mod.tx_id, did_num, fdid.decode_fn)
            if res:
                found += 1
                worker.log.emit(f"✔ [{mod.name}] {fdid.label}: {res}")
            time.sleep(0.04)
        elm.command("ATSH7E0")
        self._curr_header = "7E0"
        worker.info.emit(f"Varredura Ford concluída: {found} grupos de sensores lidos com sucesso.")
        worker.status.emit("connected", "Conectado — Ford Ka+ 2016 HS-CAN (Varredura Concluída)")

    def get_channels_info(self) -> Dict[str, Tuple[str, str]]:
        return dict(ford.FORD_CHANNELS_INFO)

