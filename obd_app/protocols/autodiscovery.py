"""Motor de Auto-Fingerprinting Universal em Cascata (UniversalAutoDiscovery).

Elimina a necessidade de menus manuais de seleção de veículos. Ao conectar, testa os
barramentos em ordem decrescente de velocidade (CAN 500k -> KWP2000 Fast Init ->
5-Baud K-Line / KW1281 -> OBD-II Genérico), descobre os módulos ativos, lê VIN/Part Number
e instancia a estratégia ótima automaticamente.
"""
from __future__ import annotations

import time
from typing import Any, Dict, Optional, Tuple

from ..ecu_fingerprints import identify_ecu
from ..interfaces import IVehicleStrategy
from .base import BaseVehicleStrategy
from .ford import FordHsCanStrategy
from .generic import GenericObdStrategy
from .kw1281 import Kw1281Strategy
from .vag import VagKwpStrategy


def _clean_resp(resp: Any) -> str:
    """Limpa quebras de linha e prompts residuais."""
    raw = getattr(resp, "raw", str(resp))
    return raw.replace("\r", " ").replace("\n", " ").replace(">", "").strip()


def _hex_to_ascii(hex_str: Any) -> str:
    """Converte bytes hexadecimais espaçados em string ASCII legível."""
    raw = getattr(hex_str, "raw", str(hex_str))
    cleaned = raw.replace(" ", "").replace("\r", "").replace("\n", "").strip()
    chars = []
    for i in range(0, len(cleaned) - 1, 2):
        byte_str = cleaned[i:i+2]
        try:
            val = int(byte_str, 16)
            if 32 <= val <= 126:
                chars.append(chr(val))
        except ValueError:
            pass
    return "".join(chars).strip()


class UniversalAutoDiscovery:
    """Executa a descoberta automática da ECU em cascata."""

    @classmethod
    def discover(cls, elm: Any, worker: Any) -> Tuple[IVehicleStrategy, Dict[str, Any]]:
        """Realiza o probe em cascata e retorna (estratégia, metadados_identificação)."""
        worker.status.emit("connecting", "Auto-Discovery: Identificando barramento e central...")
        transport = getattr(elm, "transport", None) or getattr(elm, "t", None) or getattr(worker, "transport", None)

        # Se o transporte for USB KKL Serial direto, tenta KW1281 de imediato
        if transport and hasattr(transport, "send_5baud_init"):
            worker.log.emit("Transporte USB KKL detectado: testando protocolo VAG KW1281 / KWP...")
            strategy_kkl = Kw1281Strategy()
            if strategy_kkl.initialize(elm, worker):
                meta = identify_ecu(raw_id=strategy_kkl.ecu_id_string, protocol_name="VAG KW1281")
                return strategy_kkl, meta

        # Se for Demo / MockTransport, ativa o perfil do simulador imediatamente
        if transport and (getattr(transport, "name", "") == "Demo" or hasattr(transport, "engine")):
            engine = getattr(transport, "engine", None)
            is_turbo = bool(getattr(engine, "turbo_mode", False))
            raw_id = "5G0906259 MED17.5 EA888 TSI" if is_turbo else "032906032AJ ME7.5.30"
            worker.log.emit(f"Modo Demo / Simulador ativo ({'Turbo' if is_turbo else 'Aspirado'}): inicializando central simulada...")
            strat_vag = VagKwpStrategy()
            if strat_vag.initialize(elm, worker):
                meta = identify_ecu(raw_id=raw_id, vin="9BWCA05X9CP000000", protocol_name="VAG KWP2000 (Demo)")
                return strat_vag, meta
            strat_gen = GenericObdStrategy()
            strat_gen.initialize(elm, worker)
            meta = identify_ecu(raw_id=raw_id if is_turbo else "SIMULADOR", protocol_name="OBD-II Universal (Demo)")
            return strat_gen, meta

        # ======================================================================
        # ESTÁGIO 1: Barramento CAN (500k / 250k - ATSP6) [~0.3 s]
        # ======================================================================
        worker.status.emit("connecting", "Auto-Discovery: Sondando barramento CAN 500 kbps (ATSP6)...")
        worker.log.emit(">> Auto-Discovery: Testando ISO 15765-4 CAN 11-bit 500k (ATSP6)...")
        try:
            elm.command("ATSP6", 0.6)
            elm.command("ATCRA 7E8", 0.4)
            r_can = elm.command("0100", 1.2)
            if "41 00" in r_can or "4100" in r_can:
                worker.log.emit("<< Resposta CAN 500k recebida no cabeçalho 7E8!")
                # Lê VIN e identificadores UDS
                vin_resp = elm.command("0902", 1.8)
                vin = _hex_to_ascii(vin_resp) if "49 02" in vin_resp else ""

                uds_pn = elm.command("22F187", 1.2)
                pn_str = _hex_to_ascii(uds_pn) if "62 F1 87" in uds_pn else ""

                # Sonda módulos adicionais na rede CAN (BCM, ABS, IPC, PSCM)
                can_modules = []
                # BCM Conforto (TX 726, RX 72E) - DID 224001 ou 22404C
                elm.command("ATSH 726", 0.4)
                elm.command("ATCRA 72E", 0.4)
                r_bcm = elm.command("224001", 0.6)
                if "62 40 01" in r_bcm or "624001" in r_bcm or "7F 22" in r_bcm or "7F22" in r_bcm:
                    can_modules.append("BCM")
                elif "NO DATA" not in str(r_bcm) and "ERROR" not in str(r_bcm):
                    r_bcm_alt = elm.command("22404C", 0.6)
                    if "62 40 4C" in r_bcm_alt or "62404C" in r_bcm_alt or "7F 22" in r_bcm_alt or "7F22" in r_bcm_alt:
                        can_modules.append("BCM")

                # ABS / ESC (TX 760, RX 768) - DID 222B00
                elm.command("ATSH 760", 0.4)
                elm.command("ATCRA 768", 0.4)
                r_abs = elm.command("222B00", 0.6)
                if "62 2B 00" in r_abs or "622B00" in r_abs or "7F 22" in r_abs or "7F22" in r_abs:
                    can_modules.append("ABS")

                # IPC Painel (TX 720, RX 728) - DID 22DD01 (Odômetro)
                elm.command("ATSH 720", 0.4)
                elm.command("ATCRA 728", 0.4)
                r_ipc = elm.command("22DD01", 0.6)
                if "62 DD 01" in r_ipc or "62DD01" in r_ipc or "7F 22" in r_ipc or "7F22" in r_ipc:
                    can_modules.append("IPC")

                # PSCM Direção Elétrica (TX 730, RX 738) - DID 223300
                elm.command("ATSH 730", 0.4)
                elm.command("ATCRA 738", 0.4)
                r_pscm = elm.command("223300", 0.6)
                if "62 33 00" in r_pscm or "623300" in r_pscm or "7F 22" in r_pscm or "7F22" in r_pscm:
                    can_modules.append("PSCM")

                elm.command("ATSH 7E0", 0.4)
                elm.command("ATCRA", 0.4)

                meta = identify_ecu(raw_id=pn_str or "CAN PCM", vin=vin, protocol_name="Ford HS-CAN 500k" if can_modules else "CAN 500k", can_modules_found=can_modules)
                if can_modules:
                    worker.log.emit(f"Rede multimodular CAN identificada com {len(can_modules)} módulos secundários ({', '.join(can_modules)})!")
                    strategy_ford = FordHsCanStrategy()
                    strategy_ford.initialize(elm, worker)
                    return strategy_ford, meta
                else:
                    worker.log.emit("Central CAN mono-módulo identificada. Ativando OBD-II rápido.")
                    strategy_gen = GenericObdStrategy()
                    strategy_gen.initialize(elm, worker)
                    return strategy_gen, meta
        except Exception as e:
            worker.log.emit(f"CAN probe falhou: {e}")

        # ======================================================================
        # ESTÁGIO 2: Linha K Fast Init VAG KWP2000 (ATSP5) [~1.5 s]
        # ======================================================================
        worker.status.emit("connecting", "Auto-Discovery: Sondando Linha K VAG KWP2000 (Fast Init)...")
        worker.log.emit(">> Auto-Discovery: Testando VAG KWP2000 Fast Init (ATSP5 + ATSH 81 10 F1)...")
        try:
            elm.command("ATSP5", 0.8)
            elm.command("ATSH 81 10 F1", 0.5)
            r_kwp = elm.command("1089", 2.0)
            if "50" in r_kwp or "5A" in r_kwp or "OK" in r_kwp:
                worker.log.emit("<< Sessão KWP2000 aberta com sucesso!")
                r_id = elm.command("1A9B", 2.0)
                raw_ascii = _hex_to_ascii(r_id) if "5A 9B" in r_id else ""
                strategy_vag = VagKwpStrategy()
                strategy_vag.initialize(elm, worker)
                meta = identify_ecu(raw_id=raw_ascii or "ME7.5.30", protocol_name="VAG KWP2000")
                return strategy_vag, meta
        except Exception as e:
            worker.log.emit(f"KWP2000 fast init probe falhou: {e}")

        # ======================================================================
        # ESTÁGIO 3: Linha K 5-Baud Init / KW1281 (ATSP4 / ATSP3) [~3.5 s]
        # ======================================================================
        worker.status.emit("connecting", "Auto-Discovery: Sondando Linha K 5-Baud (VAG KW1281 / MP9.0)...")
        worker.log.emit(">> Auto-Discovery: Testando 5-Baud Init (ATSP4 + ATIIA 01)...")
        try:
            elm.command("ATSP4", 0.8)
            elm.command("ATIIA 01", 0.5)
            # Dispara 5-baud init com 1089 para acordar a ECU e capturar os KeyBytes
            r_init = elm.command("1089", 3.0)
            # Lê KeyBytes retornados pelo adaptador após o pulso 5-baud
            r_kw = elm.command("ATKW", 1.2)
            if "01 8A" in r_kw or "8A" in r_kw:
                worker.log.emit("<< KeyBytes 01 8A detectados! Central identificada como Bosch MP9.0 (KW1281).")
                strategy_kw = Kw1281Strategy()
                strategy_kw.initialize(elm, worker)
                meta = identify_ecu(raw_id="237906021 (Bosch MP9.0 Kombi 1.6 Ar)", protocol_name="VAG KW1281")
                return strategy_kw, meta

            if "50" in r_init or "5A" in r_init or r_init.ok:
                r_id = elm.command("1A9B", 2.0)
                raw_ascii = _hex_to_ascii(r_id) if "5A 9B" in r_id else ""
                strategy_vag = VagKwpStrategy()
                strategy_vag.initialize(elm, worker)
                meta = identify_ecu(raw_id=raw_ascii or "VAG KWP", protocol_name="VAG KWP2000")
                return strategy_vag, meta
        except Exception as e:
            worker.log.emit(f"5-baud probe falhou: {e}")

        # ======================================================================
        # ESTÁGIO 4: Fallback Universal OBD-II (ATSP0)
        # ======================================================================
        worker.status.emit("connecting", "Auto-Discovery: Acionando Fallback Universal OBD-II (ATSP0)...")
        worker.log.emit(">> Auto-Discovery: Executando busca automática de protocolo OBD-II (ATSP0)...")
        elm.command("ATSP0", 0.8)
        elm.command("0100", 2.5)

        vin_resp = elm.command("0902", 2.0)
        vin = _hex_to_ascii(vin_resp) if "49 02" in vin_resp else ""

        strategy_gen = GenericObdStrategy()
        strategy_gen.initialize(elm, worker)
        meta = identify_ecu(raw_id="OBD2 Universal", vin=vin, protocol_name="OBD-II Universal")
        return strategy_gen, meta
