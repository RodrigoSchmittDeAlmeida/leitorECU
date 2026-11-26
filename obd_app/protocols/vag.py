"""Estratégia de comunicação VAG KWP2000 (VW Gol G5 ME7.5.30).

Encapsula handshake (ATSP4 + ATIIA01 + ATSH8110F1), blocos de medição Modo 21,
descoberta de grupos em background, cache local e DTCs via Serviço 18/14.
"""
from __future__ import annotations

import re
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

        transport = getattr(elm, "transport", None) or getattr(elm, "t", None)
        is_demo = getattr(transport, "name", "") == "Demo"

        for attempt in range(1, 3):
            if not worker._running:
                return False
            elm.command("ATPC", 2.0)
            if not is_demo:
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
            if r_probe.ok and not vag.is_negative(r_probe):
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
        # Promove Bloco 115 para active_fast SOMENTE se não for a central aspirada 032906032AJ
        # e contiver células de pressão, ou se a central for identificada como turbo
        is_asp_gol = bool(self.ecu_id and self.ecu_id.upper().startswith("032906032AJ"))
        has_pressure_115 = any(
            k.startswith("g115_") and any(term in (v[0] + " " + v[1]).lower() for term in ("mbar", "bar", "kpa", "boost", "pressão", "pressao"))
            for k, v in self.vag_cells.items()
        )
        is_turbo_ecu = False
        try:
            from ..ecu_fingerprints import identify_ecu
            meta = identify_ecu(raw_id=self.ecu_id or "", protocol_name="VAG KWP2000")
            is_turbo_ecu = bool(meta.get("is_turbo", False))
        except Exception:
            pass

        if 115 in self.vag_supported and not is_asp_gol and (has_pressure_115 or is_turbo_ecu):
            if 0x2173 not in self.active_fast:
                self.active_fast.append(0x2173)
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
            # E intercala o Bloco 005 (Velocidade/Carga/Cut-Off) a cada 2 ciclos (~1,5s)
            # alternando com os demais blocos complementares:
            # 002 (Inj/Carga/MAP), 004 (Bat/ECT/IAT), 032 (LTFT Lenta+Parcial),
            # 103 (Flex), 020 (Retardo Detonação), 062 (TPS/APP)
            interleaved = [
                0x2105, 0x2102, 0x2105, 0x2104,
                0x2105, 0x2120, 0x2105, 0x2167,
                0x2105, 0x2114, 0x2105, 0x213E,
            ]
            is_asp_gol = bool(self.ecu_id and self.ecu_id.upper().startswith("032906032AJ"))
            if not is_asp_gol:
                if 114 in self.vag_supported and 0x2172 not in interleaved:
                    interleaved.append(0x2172)
                if 115 in self.vag_supported and 0x2173 not in self.active_fast and 0x2173 not in interleaved:
                    interleaved.append(0x2173)
                if 118 in self.vag_supported and 0x2176 not in interleaved:
                    interleaved.append(0x2176)
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
                else:
                    # Mesmo se o tamanho for maior/menor que nbytes, tenta decodificar células genéricas
                    cell_vals = self._decode_cells(resp, pdef.pid, worker)
                    if cell_vals:
                        self._confirm_pending()
                        worker._emit(cell_vals)
                        n_resp += 1

        # Leitura periódica da tensão física no Pino 16 OBD2 via conversor A/D do ELM327 (ATRV)
        if not decel_mode and cycle % 6 == 0 and hasattr(elm, "battery_voltage"):
            try:
                v_pin16 = elm.battery_voltage()
                if v_pin16 is not None and 5.0 <= v_pin16 <= 20.0:
                    worker._emit({"obd_pin16_v": v_pin16})
            except Exception:
                pass

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

    @staticmethod
    def _decode_kwp_nrc(nrc: int) -> str:
        return {
            0x10: "Rejeição geral (0x10)",
            0x11: "Serviço não suportado (0x11)",
            0x12: "Subfunção/formato não suportado (0x12)",
            0x21: "ECU ocupada (0x21)",
            0x22: "Condições incorretas — motor ligado ou temperatura/tensão fora da janela (0x22)",
            0x31: "Canal fora de faixa (0x31)",
            0x33: "Acesso de segurança / Seed-Key Bosch exigido (0x33)",
            0x35: "Chave de segurança inválida (0x35)",
            0x78: "Processando (0x78)",
        }.get(nrc, f"NRC 0x{nrc:02X}")

    @classmethod
    def _evaluate_kwp_resp(cls, resp: Any, expected_pos_hex: str) -> Tuple[bool, bool, Optional[int], str]:
        lines = getattr(resp, "lines", None) or []
        err = getattr(resp, "error", None) or ""
        all_raw = re.sub(r"\s+", "", f"{''.join(lines)} {err}").upper()
        has_pending_78 = bool(re.search(r"7F[0-9A-F]{2}78", all_raw))
        cleaned = re.sub(r"7F[0-9A-F]{2}78", "", all_raw)
        pos_hex = expected_pos_hex.upper()
        if pos_hex in cleaned:
            return True, has_pending_78, None, f"ACEITO ({cleaned})"
        neg = re.search(r"7F[0-9A-F]{2}([0-9A-F]{2})", cleaned)
        if neg:
            nrc = int(neg.group(1), 16)
            return False, False, nrc, f"REJEITADO: {cls._decode_kwp_nrc(nrc)}"
        if has_pending_78:
            return True, True, 0x78, "ACEITO (Processando 0x78 — ECU executando comando)"
        data_lines = resp.data_lines() if hasattr(resp, "data_lines") else lines
        raw = re.sub(r"\s+", "", "".join(data_lines)).upper()
        if not getattr(resp, "ok", False) or not raw:
            return False, False, None, err or "SEM RESPOSTA"
        if pos_hex in raw:
            return True, False, None, f"ACEITO ({raw})"
        return False, False, None, f"INESPERADO ({raw})"

    def _read_block_now(self, elm: Any, worker: Any, pcode: int) -> Dict[str, float]:
        pdef = PIDS.get(pcode)
        if not pdef:
            return {}
        r = elm.query_pid(pdef.cmd)
        if not r.ok or vag.is_negative(r):
            return {}
        out: Dict[str, float] = {}
        data = extract_payload(r, pdef.mode, pdef.pid, pdef.nbytes)
        if data:
            try:
                out.update(pdef.decode(data))
            except Exception:
                pass
        cell_vals = self._decode_cells(r, pdef.pid, worker)
        if cell_vals:
            out.update(cell_vals)
        if out:
            worker._emit(out)
        return out

    def reset_adaptation(self, elm: Any, worker: Any) -> None:
        """Reset de Adaptação / Flex KWP2000 VAG (Bosch ME7.5.30) com validação real de NRC."""
        worker.log.emit("Iniciando Reset de Adaptação / Flex KWP2000 VAG (Bosch ME7.5.30)...")
        worker.status.emit("connecting", "Executando Reset de Adaptação KWP2000 (Canal 00)...")

        # 1. Leitura ANTES do reset (Bloco 032 LTFT + Bloco 103 Flex Fixa)
        before32 = self._read_block_now(elm, worker, 0x2120)
        before103 = self._read_block_now(elm, worker, 0x2167)
        ltft_before = before32.get("ltft")
        flex_before = before103.get("g103_c6")

        # 2. Garante sessão diagnóstica estendida VAG KWP2000 (10 89)
        r_sess = elm.command("1089", 4.0)
        _, _, _, sess_sum = self._evaluate_kwp_resp(r_sess, "50")
        worker.log.emit(f"> 1089 (Sessão VAG KWP2000) -> {sess_sum}")

        # 3. Limpa códigos de falha e RAM (14 FF 00) — aguarda se ECU responder 0x78 (ResponsePending)
        r_clear = elm.command("14FF00", 6.0)
        _, clear_pending, _, clear_sum = self._evaluate_kwp_resp(r_clear, "54")
        worker.log.emit(f"> 14FF00 (Limpar DTCs / RAM) -> {clear_sum}")
        if clear_pending:
            time.sleep(1.2)

        # 4. VAG KWP2000 Basic Setting Grupo 000 (31 B8 00 — NUNCA enviar 2800!)
        r_basic = elm.command("31B800", 5.0)
        basic_ok, basic_pending, basic_nrc, basic_sum = self._evaluate_kwp_resp(r_basic, "71")
        worker.log.emit(f"> 31B800 (Basic Setting Grupo 000) -> {basic_sum}")
        if basic_pending:
            time.sleep(1.0)

        # 5. VAG KWP2000 Adaptation Channel 00 = 0000 (3B 00 00 00 — Factory Reset)
        r_adapt = elm.command("3B000000", 5.0)
        adapt_ok, _, adapt_nrc, adapt_sum = self._evaluate_kwp_resp(r_adapt, "7B")
        worker.log.emit(f"> 3B000000 (Adaptação Canal 00 = 0) -> {adapt_sum}")

        # 6. Releitura DEPOIS do reset para comprovação real
        time.sleep(0.45)
        after32 = self._read_block_now(elm, worker, 0x2120)
        after103 = self._read_block_now(elm, worker, 0x2167)
        ltft_after = after32.get("ltft")
        flex_after = after103.get("g103_c6")

        ltft_changed = (
            ltft_before is not None
            and ltft_after is not None
            and abs(ltft_after - ltft_before) > 0.5
        )
        flex_changed = (
            flex_before is not None
            and flex_after is not None
            and abs(flex_after - flex_before) > 1.0
        )
        kwp_accepted = basic_ok or adapt_ok
        nrcs = [n for n in (basic_nrc, adapt_nrc) if n is not None]

        if kwp_accepted or ltft_changed or flex_changed:
            parts = []
            if ltft_before is not None and ltft_after is not None:
                parts.append(f"LTFT {ltft_before:.1f}% → {ltft_after:.1f}%")
            if flex_before is not None and flex_after is not None:
                parts.append(f"Flex(103.6) {flex_before:.0f}% → {flex_after:.0f}%")
            detail = f" ({' · '.join(parts)})" if parts else ""
            worker.info.emit(f"Reset KWP2000 aceito pela ECU!{detail}")
            worker.status.emit("connected", "Conectado — Reset KWP2000 confirmado")
        elif 0x33 in nrcs:
            worker.info.emit(
                "ECU bloqueou o reset por Segurança (NRC 0x33 — Seed-Key Bosch exigido). "
                "Para destravar o Flex (103.6), abasteça ≥12 L com chave desligada ou use scanner VAG com login."
            )
            worker.status.emit("connected", "Conectado — Reset bloqueado pela ECU (NRC 0x33)")
        elif 0x22 in nrcs:
            worker.info.emit(
                "ECU recusou o reset (NRC 0x22 — Condições incorretas). "
                "Desligue o motor mantendo apenas a ignição ligada e tente novamente."
            )
            worker.status.emit("connected", "Conectado — Reset recusado (NRC 0x22)")
        else:
            reason = adapt_sum if not adapt_ok else basic_sum
            worker.info.emit(
                f"DTCs limpos, mas a ECU não zerou a EEPROM de LTFT/Flex ({reason}). "
                "Abasteça ≥12 L com a chave desligada ou use scanner VAG Canal 00/Flex."
            )
            worker.status.emit("connected", "Conectado — EEPROM LTFT/Flex mantida pela ECU")

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

