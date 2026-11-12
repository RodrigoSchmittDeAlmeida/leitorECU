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
        self._curr_filter = "7E8"
        self._tx_to_rx = {mod.tx_id: mod.rx_id for mod in ford.FORD_MODULES.values()}
        self._tx_to_key = {mod.tx_id: mod.key for mod in ford.FORD_MODULES.values()}
        self._did_failures: Dict[str, int] = {}
        self._unsupported_dids: set[str] = set()
        self._module_offline: Dict[str, bool] = {}
        self._module_ever_responded: set[str] = {"pcm"}

    def _set_target(self, elm: Any, tx_id: str, rx_id: Optional[str] = None) -> None:
        """Configura header de transmissão (ATSH) e filtro de recepção CAN (ATCRA)."""
        if rx_id is None:
            rx_id = self._tx_to_rx.get(tx_id, "7E8")
        if self._curr_header == tx_id and self._curr_filter == rx_id:
            return
        elm.command(f"ATSH{tx_id}")
        elm.command(f"ATCRA{rx_id}")
        elm.command(f"ATFCSH{tx_id}")
        self._curr_header = tx_id
        self._curr_filter = rx_id

    def initialize(self, elm: Any, worker: Any) -> bool:
        """Inicializa HS-CAN 500k nos pinos 6 e 14 do OBD2."""
        worker.status.emit("connecting", "Inicializando barramento Ford HS-CAN 500k (PCM, BCM, ABS, IPC)...")
        worker.log.emit("Configurando ATSP6 (ISO 15765-4 CAN 11/500k) + ATSH7E0 + ATCRA7E8...")

        elm.command("ATPC", 1.0)
        # ATSP6: ISO 15765-4 CAN 11/500k
        # ATAL: Allow Long frames (> 7 bytes)
        # ATCAF1: CAN Auto Formatting (monta quadros ISO-TP multi-frame)
        # ATST64: Timeout de resposta CAN ~400ms (evita espera desnecessária em módulos ausentes)
        for cmd in ("ATSP6", "ATAL", "ATCAF1", "ATST64", "ATSH7E0", "ATCRA7E8", "ATFCSH7E0"):
            elm.command(cmd, 1.5)
        self._curr_header = "7E0"
        self._curr_filter = "7E8"
        self._did_failures.clear()
        self._unsupported_dids.clear()
        self._module_offline.clear()
        self._module_ever_responded = {"pcm"}

        # Confirma comunicação com o PCM (PID 0100)
        r0 = elm.command("0100", 3.0)
        if r0.ok:
            worker.log.emit("✔ PCM Motor Ford (0x7E0) respondeu ao handshake!")
            # Registra canais Ford conhecidos
            worker.channels.emit(dict(ford.FORD_CHANNELS_INFO))
            worker.info.emit("Ford Ka+ conectado: Barramento HS-CAN 500k ativo com PCM, ABS, IPC e EPAS!")
            worker.status.emit("connected", "Conectado — Ford Ka+ 2016 SEL 1.5 Sigma (HS-CAN 500k Ativo)")
            return True

        worker.log.emit("PCM não respondeu no ATSP6. Tentando autodetecção ATSP0...")
        elm.command("ATSP0", 2.0)
        r_auto = elm.command("0100", 5.0)
        if r_auto.ok:
            elm.command("ATCAF1")
            elm.command("ATST64")
            elm.command("ATSH7E0")
            elm.command("ATCRA7E8")
            self._curr_header = "7E0"
            self._curr_filter = "7E8"
            worker.channels.emit(dict(ford.FORD_CHANNELS_INFO))
            worker.status.emit("connected", "Conectado — Ford Ka+ (CAN Auto)")
            return True

        return False

    def _query_did(self, elm: Any, worker: Any, module_tx: str, did: str,
                   decode_fn: Callable[[bytes], Dict[str, float]],
                   module_rx: Optional[str] = None) -> Optional[Dict[str, float]]:
        """Executa consulta a um DID UDS Modo 22 em um módulo específico."""
        mod_key = self._tx_to_key.get(module_tx, module_tx)
        if self._module_offline.get(mod_key, False):
            return None

        did_key = f"{module_tx}:{did}"
        if did_key in self._unsupported_dids:
            return None

        self._set_target(elm, module_tx, module_rx)

        resp = elm.command(f"22{did}", 1.5)
        raw = "".join(resp.data_lines()).replace(" ", "").upper()
        if "7F22" in raw or (resp.error and "7F22" in resp.error.replace(" ", "").upper()):
            # Módulo respondeu com NRC UDS (está vivo no barramento, mas não suporta este DID específico)
            self._module_ever_responded.add(mod_key)
            self._unsupported_dids.add(did_key)
            return None
        if resp.ok and resp.data_lines():
            if "NODATA" not in raw and "ERROR" not in raw:
                prefix = "62" + did.upper()
                idx = raw.find(prefix)
                if idx != -1:
                    hex_data = raw[idx + len(prefix):]
                    try:
                        raw_bytes = bytes.fromhex(hex_data[:(len(hex_data) // 2) * 2])
                        vals = decode_fn(raw_bytes)
                        if vals:
                            worker._emit(vals)
                            self._module_ever_responded.add(mod_key)
                            self._did_failures[did_key] = 0
                            return vals
                    except Exception:
                        pass

        # Registra falha para este DID específico
        fails = self._did_failures.get(did_key, 0) + 1
        self._did_failures[did_key] = fails
        if fails >= 3:
            self._unsupported_dids.add(did_key)

            # Se o módulo NUNCA respondeu a nenhum comando (ex: BCM no MS-CAN em adaptador comum),
            # marca o módulo como offline para poupar ciclos e não travar o barramento
            if mod_key not in self._module_ever_responded:
                self._module_offline[mod_key] = True
                if mod_key == "bcm":
                    worker.log.emit(
                        "ℹ️ Módulo BCM (Conforto 0x726) não respondeu no barramento HS-CAN (Pinos 6 e 14).\n"
                        "   No Ford Ka+, o BCM comunica via MS-CAN (Pinos 3 e 11).\n"
                        "   Para ler status de portas e travas, é necessário adaptador com chave HS/MS CAN (padrão FORScan).\n"
                        "   Otimizando ciclo: focando nos módulos HS-CAN ativos (PCM, ABS, Painel IPC e Direção Elétrica EPAS)."
                    )
                else:
                    mod_name = ford.FORD_MODULES[mod_key].name if mod_key in ford.FORD_MODULES else mod_key
                    worker.log.emit(f"ℹ️ Módulo {mod_name} (0x{module_tx}) sem resposta no barramento.")
        return None

    def poll_cycle(self, elm: Any, worker: Any, cycle: int, decel_mode: bool) -> int:
        n_resp = 0

        # Periodicamente reavalia módulos offline caso o usuário alterne a chave HS/MS CAN
        if cycle % 60 == 0 and (self._module_offline or self._unsupported_dids):
            self._module_offline.clear()
            self._did_failures.clear()
            self._unsupported_dids.clear()

        # Garante header e filtro no PCM 7E0 / 7E8
        self._set_target(elm, "7E0", "7E8")

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
            # Ar condicionado: tenta DID 0323 (Pressão A/C Ford) / 0325 ou DID composto 1101
            if self._query_did(elm, worker, "7E0", "0323", ford._dec_pcm_ac_press):
                n_resp += 1
            elif self._query_did(elm, worker, "7E0", "1101", ford._dec_pcm_ac):
                n_resp += 1
            if self._query_did(elm, worker, "7E0", "0325", ford._dec_pcm_ac_clutch):
                n_resp += 1
            if self._query_did(elm, worker, "7E0", "1608", ford._dec_pcm_flex):
                n_resp += 1
            if self._query_did(elm, worker, "7E0", "1627", ford._dec_pcm_cat_temp):
                n_resp += 1
            if self._query_did(elm, worker, "7E0", "0320", ford._dec_pcm_baro):
                n_resp += 1

        # DIDs Ford EcoBoost Turbo (Boost Target, Wastegate, CAC Temp, Flauta GDI, TIP)
        # Sondados de forma segura; se a ECU for Sigma 1.5 aspirada, o retorno NRC 7F22 suspende estes DIDs imediatamente
        if cycle % 4 == 3:
            if self._query_did(elm, worker, "7E0", "0462", ford._dec_pcm_boost_target):
                n_resp += 1
            if self._query_did(elm, worker, "7E0", "0333", ford._dec_pcm_wastegate):
                n_resp += 1
            if self._query_did(elm, worker, "7E0", "03A0", ford._dec_pcm_cac_temp):
                n_resp += 1
            if self._query_did(elm, worker, "7E0", "03E7", ford._dec_pcm_fuel_rail):
                n_resp += 1
            if self._query_did(elm, worker, "7E0", "04FE", ford._dec_pcm_turbo_inlet):
                n_resp += 1

        # 3. Módulo de CONFORTO & CARROCERIA (BCM 726 -> RX 72E)
        # No Ford Ka, o BCM comunica via MS-CAN (Pinos 3 e 11).
        # Se estiver em cabo padrão HS-CAN, será detectado e suspenso automaticamente após 3 tentativas.
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

        # 4. Módulo de FREIOS ABS & ESTABILIDADE (ABS 760 -> RX 768)
        if cycle % 2 == 1:
            if self._query_did(elm, worker, "760", "2B00", ford._dec_abs_wheels):
                n_resp += 1
            if self._query_did(elm, worker, "760", "2B01", ford._dec_abs_dynamics):
                n_resp += 1

        # 5. Módulo do PAINEL DE INSTRUMENTOS (IPC 720 -> RX 728)
        if cycle % 5 == 0:
            if self._query_did(elm, worker, "720", "DD01", ford._dec_ipc_odometer):
                n_resp += 1
            if self._query_did(elm, worker, "720", "2416", ford._dec_ipc_dashboard):
                n_resp += 1

        # 6. Módulo da DIREÇÃO ELÉTRICA EPAS (PSCM 730 -> RX 738)
        # Tenta DID 3300 (composto) ou DIDs específicos da plataforma Ford B-car (3301 ângulo / 3200 torque)
        if cycle % 3 == 0:
            got_steering = self._query_did(elm, worker, "730", "3300", ford._dec_pscm_steering)
            if got_steering:
                n_resp += 1
            else:
                if self._query_did(elm, worker, "730", "3301", ford._dec_pscm_angle):
                    n_resp += 1
                if self._query_did(elm, worker, "730", "3200", ford._dec_pscm_torque):
                    n_resp += 1

        # Restaura para PCM ao final do ciclo
        self._set_target(elm, "7E0", "7E8")

        # Leitura periódica da tensão no Pino 16 da tomada OBD2 via ELM327 (ATRV)
        if cycle % 6 == 0 and hasattr(elm, "battery_voltage"):
            try:
                v_pin16 = elm.battery_voltage()
                if v_pin16 is not None and 5.0 <= v_pin16 <= 20.0:
                    worker._emit({"obd_pin16_v": v_pin16})
            except Exception:
                pass

        return n_resp

    def read_dtcs(self, elm: Any, worker: Any) -> None:
        """Lê DTCs de múltiplos módulos Ford (PCM, BCM, ABS, IPC, PSCM, RCM)."""
        all_found = []
        mil_on_any = False
        dtc_count_total = 0

        for mod_key, mod in ford.FORD_MODULES.items():
            if not worker._running:
                return
            if self._module_offline.get(mod_key, False):
                continue

            self._set_target(elm, mod.tx_id, mod.rx_id)

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
                    full_code = f"[{mod.name}] {code}"
                    all_found.append((full_code, desc))
                    dtc_count_total += 1
                    worker.log.emit(f"⚠ DTC detectado: {full_code} — {desc}")

        self._set_target(elm, "7E0", "7E8")
        worker.dtcs.emit(mil_on_any, dtc_count_total, all_found)

    def clear_dtcs(self, elm: Any, worker: Any) -> None:
        for mod_key, mod in ford.FORD_MODULES.items():
            if self._module_offline.get(mod_key, False):
                continue
            self._set_target(elm, mod.tx_id, mod.rx_id)
            elm.command("04", 2.0)
        self._set_target(elm, "7E0", "7E8")
        self.read_dtcs(elm, worker)

    def scan_all(self, elm: Any, worker: Any) -> None:
        self._module_offline.clear()
        self._did_failures.clear()
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
            res = self._query_did(elm, worker, mod.tx_id, did_num, fdid.decode_fn, mod.rx_id)
            if res:
                found += 1
                worker.log.emit(f"✔ [{mod.name}] {fdid.label}: {res}")
            time.sleep(0.04)
        self._set_target(elm, "7E0", "7E8")
        worker.info.emit(f"Varredura Ford concluída: {found} grupos de sensores lidos com sucesso.")
        worker.status.emit("connected", "Conectado — Ford Ka+ 2016 HS-CAN (Varredura Concluída)")

    def get_channels_info(self) -> Dict[str, Tuple[str, str]]:
        return dict(ford.FORD_CHANNELS_INFO)

