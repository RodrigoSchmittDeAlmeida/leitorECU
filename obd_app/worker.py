"""QThread de comunicação: conexão, handshake, autodiscovery de Sonda/PIDs, polling e DTC."""
from __future__ import annotations

import os
import queue
import time
from datetime import datetime
from typing import Dict, List, Optional, Tuple

from PyQt6.QtCore import QThread, pyqtSignal

from . import dtc as dtcmod
from . import vag
from .elm327 import ELM327, extract_payload
from .pids import (EXTRA_ORDER, LAMBDA_CANDIDATES, LTFT_CANDIDATES, PIDS,
                   STFT_CANDIDATES, parse_supported_bitmap)
from .transports import Transport, TransportError


class ObdWorker(QThread):
    # t_rel (s desde t0 monotônico), timestamp de parede em ms, {canal: valor}
    sample = pyqtSignal(float, float, dict)
    status = pyqtSignal(str, str)          # (estado, mensagem) estado: connecting|connected|error|stopped
    log = pyqtSignal(str)                  # console ELM
    rate = pyqtSignal(float, float)        # respostas/s, ciclos/s
    dtc_result = pyqtSignal(list, object)  # [(código, descrição)], (mil, count) | None
    info = pyqtSignal(str)
    channels = pyqtSignal(dict)            # canais dinâmicos descobertos {chave: (rótulo, unidade)}

    MAX_CONSEC_ERRORS = 12
    BITMAP_PIDS = {0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0, 0xE0}
    VAG_GROUPS = range(1, 256)             # blocos de medição possíveis (21 01 .. 21 FF)

    def __init__(self, transport: Transport, t0: float, parent=None):
        super().__init__(parent)
        self.transport = transport
        self.t0 = t0
        self._running = True
        self.decel_mode = False
        self.read_extras = True  # lê tudo o que a ECU envia por padrão
        self.fast_reply = False
        self.raw_log = False
        self.poll_delay = 0.0  # atraso opcional entre leituras (para reduzir ruído na linha K)
        self._cmds: "queue.Queue[str]" = queue.Queue()
        self.supported: set[int] = set()
        self.vag_kwp_mode: bool = False
        self.active_fast: List[int] = [0x0C, 0x0B, 0x0E, 0x11, 0x14]
        self.active_normal: List[int] = [0x0C, 0x0B, 0x0E, 0x11, 0x14, 0x06, 0x07, 0x05]
        self.active_extra: List[int] = list(EXTRA_ORDER)
        self.elm: Optional[ELM327] = None
        # --- descoberta/rodízio de TODOS os blocos de medição VAG (gravação completa no CSV)
        self.ecu_id = ""
        self.vag_supported: set[int] = set()
        self.vag_unsupported: set[int] = set()
        self.vag_cells: Dict[str, Tuple[str, str]] = {}
        self._vag_queue: List[int] = []          # blocos ainda não testados
        self._vag_pending_nodata: List[int] = [] # NO DATA aguardando confirmação de que a sessão está viva
        self._vag_fail: Dict[int, int] = {}
        self._vag_rot_idx = 0

    # ---------------------------------------------------------------- API (GUI)
    def stop(self) -> None:
        self._running = False

    def request(self, cmd: str) -> None:
        """'read_dtc' | 'clear_dtc' | 'scan_vag'"""
        self._cmds.put(cmd)

    # ------------------------------------------------------------------- thread
    def run(self) -> None:
        attempt = 0
        while self._running:
            try:
                self._connect_and_init()
                attempt = 0
                self._poll_loop()
            except TransportError as e:
                if not self._running:
                    break
                attempt += 1
                self.status.emit("error", f"{e} — reconectando ({attempt})...")
                self.log.emit(f"!! {e}")
            except Exception as e:  # nunca derrubar a thread por erro inesperado
                if not self._running:
                    break
                attempt += 1
                self.status.emit("error", f"Erro inesperado: {e!r} — reconectando ({attempt})...")
                self.log.emit(f"!! Erro inesperado: {e!r}")
            finally:
                try:
                    self.transport.close()
                except Exception:
                    pass
            # espera antes de reconectar (interrompível)
            for _ in range(int(min(2 + attempt, 8) * 10)):
                if not self._running:
                    break
                time.sleep(0.1)
        self.status.emit("stopped", "Desconectado")

    def _connect_and_init(self) -> None:
        self.status.emit("connecting", f"Conectando via {self.transport.name}...")
        self.transport.open()
        self.elm = ELM327(self.transport, log=self.log.emit)
        self.status.emit("connecting", "Handshake ELM327 (ATZ/ATE0/ATL0/ATS0/ATH0/ATAL)...")
        self.elm.initialize_adapter(stop=lambda: not self._running)
        if self.elm.version:
            self.info.emit(f"Adaptador: {self.elm.version}")

        diag_lines = [
            f"=== Diagnóstico de Handshake ({datetime.now():%Y-%m-%d %H:%M:%S}) ===",
            f"Transporte: {self.transport.name} | Versão ELM: {self.elm.version}",
        ]

        # 1. Tenta PRIMEIRO inicializar direto em VAG KWP2000 nativo (endereço 01, header 81 10 F1),
        # que na Bosch ME7.5.30 (VW Gol G5) habilita imediatamente a Sonda Lambda, STFT, LTFT e todos os sensores!
        self.vag_kwp_mode = False
        self.supported = set()
        if self.transport.name != "Demo" and self._init_vag_kwp2000(diag_lines, wait_close=False):
            self.vag_kwp_mode = True
            self.active_fast = [0x2103, 0x2121]
            self.active_normal = [0x2103, 0x2121, 0x2120, 0x2104]
            self.active_extra = [0x2105]
            self._vag_setup_discovery(diag_lines)
            for vk in (0x2103, 0x2120, 0x2104, 0x2105):
                if not self._running:
                    raise TransportError("Cancelado")
                self._try_pid(vk, diag_lines)
            self._emit({"fuel_sys1": 2.0, "o2_mask": 1.0})
            self._save_diag_log(diag_lines)
            self.info.emit("Sonda Lambda e Fuel Trims ativos via VAG KWP2000 (Blocos 003, 032, 033)!")
            if self._vag_queue:
                self.info.emit(f"Descobrindo os demais blocos de medição em segundo plano ({len(self._vag_queue)} "
                               "a testar). Para descobrir tudo de uma vez: aba 'Todos os Canais' → Varrer blocos.")
            self.status.emit("connected", "Conectado — VAG KWP2000 Nativo (Blocos 001..033 Sonda Ativa)")
            return

        # 2. Fallback OBD2 padrão (ISO 9141-2 / KWP / CAN / Simulador Demo)
        if self.transport.name != "Demo":
            self.elm.command("ATPC", 2.0)
            time.sleep(2.0)
            self.elm.command("ATSP0", 2.0)
        r = self.elm.command("0100", 12.0)
        self.log.emit(f"> 0100   -> {' / '.join(r.lines) or '(vazio)'}" + (f"  [{r.error}]" if r.error else ""))
        tries = 0
        payload = extract_payload(r, 1, 0x00, 4) if r.ok else None
        while (not r.ok or payload is None) and self._running:
            tries += 1
            if tries == 2:
                self.log.emit("Tentando ISO 9141-2 (ATSP3)...")
                self.elm.command("ATSP3", 2.0)
            elif tries == 4:
                self.log.emit("Tentando KWP 5-baud init (ATSP4)...")
                self.elm.command("ATSP4", 2.0)
            elif tries == 6:
                self.log.emit("Tentando detecção automática de protocolo (ATSP0)...")
                self.elm.command("ATSP0", 2.0)
            self.status.emit("connecting", f"ECU não respondeu ({r.error or 'sem dados'}). Ligue a ignição. Tentativa {tries}...")
            for _ in range(15):
                if not self._running:
                    break
                time.sleep(0.1)
            if not self._running:
                break
            r = self.elm.command("0100", 12.0)
            self.log.emit(f"> 0100   -> {' / '.join(r.lines) or '(vazio)'}" + (f"  [{r.error}]" if r.error else ""))
            payload = extract_payload(r, 1, 0x00, 4) if r.ok else None
        if not self._running:
            raise TransportError("Cancelado")

        dp = self.elm.command("ATDP")
        proto_str = " / ".join(dp.lines)
        diag_lines.append(f"Protocolo ativo (ATDP): {proto_str}")
        diag_lines.append(f"0100 RX: {' / '.join(r.lines)} (err={r.error})")

        if payload:
            self.supported |= parse_supported_bitmap(0x00, payload)
            # Consulta 0120 (PIDs 21-40) e 0140 (PIDs 41-60)
            for base_pid, cmd_sup in ((0x20, "0120"), (0x40, "0140")):
                if base_pid in self.supported:
                    rs = self.elm.command(cmd_sup, 2.5)
                    diag_lines.append(f"{cmd_sup} RX: {' / '.join(rs.lines)} (err={rs.error})")
                    pl = extract_payload(rs, 1, base_pid, 4) if rs.ok else None
                    if pl:
                        self.supported |= parse_supported_bitmap(base_pid, pl)
            names = ", ".join(f"{p:02X}" for p in sorted(self.supported))
            self.log.emit(f"PIDs no bitmap da ECU: {names}")

        self.status.emit("connecting", "Detectando sensores e Sonda Lambda na ECU...")
        self._probe_sensors(diag_lines)

        self._save_diag_log(diag_lines)
        self.status.emit("connected", f"Conectado — {proto_str or 'ISO 9141-2 / KWP'}")

    def _try_pid(self, key: int, diag_lines: List[str]) -> bool:
        """Testa um PID uma vez sem alterar o header do protocolo. Retorna True se a ECU respondeu dados válidos."""
        assert self.elm is not None
        if key not in PIDS:
            return False
        pdef = PIDS[key]
        r = self.elm.command(pdef.cmd, 2.5)
        diag_lines.append(f"PROBE {pdef.cmd} ({pdef.name}) -> {' / '.join(r.lines) or '-'} (err={r.error})")
        if not r.ok:
            return False
        data = extract_payload(r, pdef.mode, pdef.pid, pdef.nbytes)
        if data is None:
            return False
        try:
            vals = {k: v for k, v in pdef.decode(data).items() if v is not None}
        except Exception:
            return False
        if not vals:
            return False
        if pdef.mode == 0x21:
            # Além dos canais semânticos (rpm, lambda_v...), grava TODAS as células do bloco (gGGG_cN)
            vals.update(self._vag_cells(r, pdef.pid) or {})
        self._emit(vals)
        self.log.emit(f"✔ {pdef.cmd} ({pdef.name}) ativo: {vals}")
        return True

    def _init_vag_kwp2000(self, diag_lines: List[str], wait_close: bool = True) -> bool:
        """Inicializa o protocolo nativo VAG KWP2000 (ISO 14230-4 5-baud init no endereço 0x01, header 81 10 F1).
        
        Na Bosch ME7.5.30 Flex (Gol G5), o Modo 01 ISO 9141-2 bloqueia 0114/0106/0107,
        mas ao inicializar via endereço 01 (KeyBytes EF 8F) a ECU abre todos os Blocos de Medição
        (Modo 21: Grupos 001, 002, 003, 004, 005, 031, 032, 033) com Sonda Lambda, STFT e LTFT em alta velocidade!
        """
        assert self.elm is not None
        self.status.emit("connecting", "Inicializando protocolo VAG KWP2000 nativo (Bloco 033 Sonda Lambda)...")
        self.log.emit("Inicializando VAG KWP2000 no endereço 01 (ATSP4 + ATIIA01 + ATSH8110F1)...")
        diag_lines.append("--- Inicializando VAG KWP2000 (ATSP4 + ATIIA01 + ATSH8110F1) ---")

        for attempt in range(1, 3):
            if not self._running:
                return False
            if wait_close or attempt > 1:
                self.elm.command("ATPC", 2.0)
                for _ in range(30):
                    if not self._running:
                        return False
                    time.sleep(0.1)
            for cmd in ("ATAL", "ATSP4", "ATIB10", "ATKW0", "ATIIA01", "ATSH8110F1", "ATWM8110F13E"):
                self.elm.command(cmd, 2.0)

            # O 1º comando dispara o 5-baud init (~3s) e já pode retornar BUS INIT: ...OK
            r_init = self.elm.command("1089", 10.0)
            diag_lines.append(f"VAG INIT attempt {attempt} (1089) -> {' / '.join(r_init.lines) or '-'} (err={r_init.error})")
            if r_init.error in ("UNABLE TO CONNECT", "ERROR", "BUS INIT: ERROR"):
                continue
            r_id = self.elm.command("1A9B", 2.5)
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
                        self.ecu_id = ecu_part.split()[0]  # ex.: 032906032AJ (usado no cache de blocos)
                    self.log.emit(f"✔ ECU Identificada (VAG): {ecu_part}")
                    diag_lines.append(f"VAG ECU ID (1A9B): {ecu_part}")
            if self._try_pid(0x2121, diag_lines):
                return True
        return False

    # ------------------------------------------------- blocos VAG genéricos (todos os campos no CSV)
    def _vag_setup_discovery(self, diag_lines: List[str]) -> None:
        """Carrega o cache de blocos desta ECU e monta a fila de blocos ainda não testados."""
        cache = vag.load_cache(self.ecu_id or "desconhecida")
        self.vag_supported |= set(cache["supported"])
        self.vag_unsupported |= set(cache["unsupported"]) - self.vag_supported
        for k, v in cache["cells"].items():
            self.vag_cells.setdefault(k, v)
        known = self.vag_supported | self.vag_unsupported
        self._vag_queue = [g for g in self.VAG_GROUPS if g not in known]
        self._vag_pending_nodata = []
        self._vag_fail = {}
        if self.vag_cells:
            self.channels.emit(dict(self.vag_cells))
        diag_lines.append(f"Cache de blocos VAG ({self.ecu_id or 'desconhecida'}): {len(self.vag_supported)} com dados, "
                          f"{len(self.vag_unsupported)} inexistentes, {len(self._vag_queue)} a testar")

    def _vag_save(self) -> None:
        vag.save_cache(self.ecu_id or "desconhecida", list(self.vag_supported),
                       list(self.vag_unsupported), self.vag_cells)

    def _vag_mark(self, group: int, ok: bool) -> None:
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
            self._vag_save()

    def _vag_confirm_pending(self) -> None:
        """Uma leitura válida DEPOIS de um NO DATA prova que a sessão está viva => o bloco não existe mesmo."""
        if self._vag_pending_nodata:
            for g in list(self._vag_pending_nodata):
                self._vag_mark(g, False)

    def _vag_cells(self, resp, group: int) -> Optional[Dict[str, float]]:
        """Decodifica todas as células do bloco ``group``. None se a resposta não contém ``61 GG``."""
        try:
            block = vag.extract_block(resp, group)
            if block is None:
                return None
            cells = vag.decode_block(group, block)
        except Exception:
            return None
        self._vag_mark(group, True)
        new: Dict[str, Tuple[str, str]] = {}
        for k, (_, unit) in cells.items():
            old = self.vag_cells.get(k)
            if old is None or old[1] != unit:
                cell = int(k.rsplit("_c", 1)[1])
                self.vag_cells[k] = new[k] = (vag.channel_label(group, cell, unit), unit)
        if new:
            self.channels.emit(new)
            self._vag_save()
        return {k: v for k, (v, _) in cells.items()}

    def _probe_vag_group(self, group: int) -> Optional[bool]:
        """Lê um bloco qualquer (descoberta ou rodízio). True = dados; False = inexistente; None = indeterminado."""
        assert self.elm is not None
        r = self.elm.command(f"21{group:02X}", 2.5)
        vals = self._vag_cells(r, group)
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
                self._emit(vals)
            self._vag_confirm_pending()
            return True
        if vag.is_negative(r):          # 7F 21 xx: a ECU disse explicitamente que o bloco não existe
            self._vag_mark(group, False)
            return False
        if r.error == "NO DATA":        # pode ser bloco inexistente OU sessão caída: confirma depois
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
                self._vag_queue.append(group)  # tenta de novo no fim da fila
        return None

    def _next_vag_item(self, cycle: int):
        """1 bloco extra por ciclo: descoberta (3 de 4 ciclos enquanto houver fila) ou rodízio dos conhecidos."""
        active = {k & 0xFF for k in (self.active_fast + self.active_normal + self.active_extra)
                  if isinstance(k, int) and (k >> 8) == 0x21}
        rot = sorted(self.vag_supported - active)
        if self._vag_queue and (cycle % 4 != 3 or not rot):
            return ("vag", self._vag_queue[0])
        if rot:
            g = rot[self._vag_rot_idx % len(rot)]
            self._vag_rot_idx += 1
            return ("vag", g)
        return None

    def _scan_all_vag(self) -> None:
        """Varredura completa (botão da GUI): lê todos os blocos não marcados como inexistentes (~1-2 min)."""
        assert self.elm is not None
        groups = [g for g in self.VAG_GROUPS if g not in self.vag_unsupported]
        n = len(groups)
        self.log.emit(f"Varredura de blocos VAG: {n} blocos...")
        for i, g in enumerate(groups):
            if not self._running:
                return
            if i % 8 == 0:
                self.status.emit("connected", f"Varrendo blocos VAG: {g:03d} ({i + 1}/{n})...")
            res = self._probe_vag_group(g)
            # a cada 8 blocos (ou NO DATA acumulado) faz um "heartbeat" no bloco 033 para validar a sessão
            if (res is None and len(self._vag_pending_nodata) >= 8) or i % 8 == 7:
                if self._probe_vag_group(0x21) is not True:
                    self.log.emit("Sessão VAG não respondeu durante a varredura — reinicializando...")
                    self._vag_pending_nodata.clear()
                    self._reinit_bus()
        self._probe_vag_group(0x21)
        self._vag_save()
        msg = (f"Varredura concluída: {len(self.vag_supported)} blocos com dados, "
               f"{len(self.vag_unsupported)} inexistentes, {len(self.vag_cells)} campos gravados no CSV.")
        self.info.emit(msg)
        self.status.emit("connected", "Conectado — VAG KWP2000 Nativo (todos os blocos)")

    def _probe_sensors(self, diag_lines: List[str]) -> None:
        """Descobre automaticamente os sensores de Sonda Lambda, STFT, LTFT no Modo 01 (fallback/Demo)."""
        assert self.elm is not None
        o2_candidates: List[int] = []
        if 0x13 in self.supported:
            r13 = self.elm.command("0113", 2.5)
            diag_lines.append(f"PROBE 0113 (Máscara Sondas O2) -> {' / '.join(r13.lines) or '-'} (err={r13.error})")
            d13 = extract_payload(r13, 1, 0x13, 1) if r13.ok else None
            if d13:
                mask = d13[0]
                self._emit({"o2_mask": float(mask)})
                self.log.emit(f"✔ 0113 (Máscara de Sondas O2) = 0x{mask:02X} (bits={mask:08b})")
                diag_lines.append(f"0113 mask = 0x{mask:02X} (bits={mask:08b})")
                for bit in range(8):
                    if mask & (1 << bit):
                        pid_o2 = 0x14 + bit
                        if pid_o2 in PIDS:
                            o2_candidates.append(pid_o2)

        for cand in LAMBDA_CANDIDATES:
            if cand not in o2_candidates:
                o2_candidates.append(cand)

        lambda_keys: List[int] = []
        for cand in o2_candidates:
            if not self._running:
                return
            if self._try_pid(cand, diag_lines):
                lambda_keys.append(cand)

        stft_key: Optional[int] = None
        for cand in STFT_CANDIDATES:
            if not self._running:
                return
            if self._try_pid(cand, diag_lines):
                stft_key = cand
                break

        ltft_key: Optional[int] = None
        for cand in LTFT_CANDIDATES:
            if not self._running:
                return
            if self._try_pid(cand, diag_lines):
                ltft_key = cand
                break

        for p in [0x05, 0x04, 0x0D, 0x0F, 0x03, 0x01, 0x1C, 0x21, 0x51]:
            if not self._running:
                return
            if p in self.supported and p in PIDS:
                self._try_pid(p, diag_lines)
        v_bat = self.elm.battery_voltage()
        if v_bat is not None:
            self._emit({"battery": v_bat})

        # 4. Monta as listas ativas de polling no Modo 01 (caso a ECU suporte no Modo 01 ou no Simulador Demo)
        base_fast = [p for p in (0x0C, 0x0B, 0x0E, 0x11) if not self.supported or p in self.supported]
        for lk in lambda_keys:
            if lk not in base_fast:
                base_fast.append(lk)

        base_normal = list(base_fast)
        if stft_key is not None and stft_key not in base_normal:
            base_normal.append(stft_key)
        if ltft_key is not None and ltft_key not in base_normal:
            base_normal.append(ltft_key)
        if not self.supported or 0x05 in self.supported:
            base_normal.append(0x05)

        extras = [p for p in EXTRA_ORDER if not self.supported or p in self.supported]
        for p in sorted(self.supported - self.BITMAP_PIDS):
            if p in PIDS and p not in base_normal and p not in extras:
                extras.append(p)

        self.active_fast = base_fast
        self.active_normal = base_normal
        self.active_extra = extras

        if lambda_keys:
            names = ", ".join(f"{PIDS[k].cmd} ({PIDS[k].name})" for k in lambda_keys)
            self.info.emit(f"Sonda Lambda ativa: {names}")
        else:
            self.info.emit("ECU conectada (sonda lambda não exposta no Modo 01 desta calibração)")

    def _save_diag_log(self, lines: List[str]) -> None:
        try:
            os.makedirs("logs", exist_ok=True)
            with open(os.path.join("logs", "ultimo_handshake.txt"), "w", encoding="utf-8") as f:
                f.write("\n".join(lines) + "\n")
        except OSError:
            pass

    def _pid_list(self, cycle: int) -> List:
        if self.decel_mode:
            return list(self.active_fast)
        order: List = []
        for p in self.active_normal:
            if not PIDS[p].slow or cycle % 5 == 0:
                order.append(p)
        if self.read_extras:
            # Sensores rápidos extras (ex: carga 04, velocidade 0D) entram todo ciclo;
            # Sensores lentos extras (IAT, 0103, 0101, 0121, 0151...) entram em rodízio (1 por ciclo)
            slow_extras = []
            for p in self.active_extra:
                if not PIDS[p].slow:
                    order.append(p)
                else:
                    slow_extras.append(p)
            if slow_extras:
                order.append(slow_extras[cycle % len(slow_extras)])
            if self.vag_kwp_mode:
                # +1 bloco VAG por ciclo (descoberta automática / rodízio de todos os blocos com dados)
                extra_block = self._next_vag_item(cycle)
                if extra_block is not None:
                    order.append(extra_block)
            if cycle % 10 == 0:
                order.append("ATRV")
        return order

    def _poll_loop(self) -> None:
        assert self.elm is not None
        consec_err = 0
        no_data_streak: Dict[int, int] = {}
        cycle = 0
        n_resp, n_cycles = 0, 0
        last_rate = time.monotonic()
        while self._running:
            # Em modo VAG KWP2000 (Modo 21), cada resposta é multi-frame (29 bytes),
            # então não devemos usar o sufixo '1' (fast_reply), senão o ELM327 corta no 1º frame de 7 bytes!
            self.elm.fast_reply = False if self.vag_kwp_mode else self.fast_reply
            self.elm.raw_log = self.raw_log
            self._process_commands()

            # Modo Mudo/Pausado: mantém sessão viva com 1 pacote a cada 3s sem metralhar a Linha K
            if self.poll_delay < 0:
                time.sleep(0.1)
                if time.monotonic() - last_rate >= 3.0:
                    self.elm.command("3E" if self.vag_kwp_mode else "0100", 2.0)
                    self.rate.emit(0.0, 0.0)
                    last_rate = time.monotonic()
                continue

            for item in self._pid_list(cycle):
                if not self._running or self.poll_delay < 0:
                    break
                if self.poll_delay > 0:
                    time.sleep(self.poll_delay)
                if item == "ATRV":
                    v = self.elm.battery_voltage()
                    if v is not None:
                        self._emit({"battery": v})
                    continue
                if isinstance(item, tuple):  # ("vag", grupo): bloco de medição genérico
                    res = self._probe_vag_group(item[1])
                    if res is True:
                        n_resp += 1
                        consec_err = 0
                    elif res is None:
                        consec_err += 1
                        if consec_err >= self.MAX_CONSEC_ERRORS:
                            self._reinit_bus()
                            consec_err = 0
                            no_data_streak.clear()
                            break
                    continue
                pdef = PIDS[item]
                resp = self.elm.query_pid(pdef.cmd)
                if resp.ok:
                    data = extract_payload(resp, pdef.mode, pdef.pid, pdef.nbytes)
                    if data is not None:
                        try:
                            values = {k: v for k, v in pdef.decode(data).items() if v is not None}
                        except Exception:
                            values = {}
                        if values:
                            if pdef.mode == 0x21:
                                values.update(self._vag_cells(resp, pdef.pid) or {})
                                self._vag_confirm_pending()
                            self._emit(values)
                            n_resp += 1
                            consec_err = 0
                            no_data_streak[item] = 0
                            continue
                    resp.error = "INVALID"

                # Se um PID específico que NÃO estava no bitmap da ECU (nem é bloco VAG confirmado) der NO DATA 3x seguidas, remove-o.
                if resp.error in ("NO DATA", "?"):
                    no_data_streak[item] = no_data_streak.get(item, 0) + 1
                    if not self.vag_kwp_mode and item not in self.supported and no_data_streak[item] >= 3:
                        self.log.emit(f"PID {pdef.cmd} sem suporte ({resp.error}) — removido do loop.")
                        for lst in (self.active_fast, self.active_normal, self.active_extra):
                            if item in lst:
                                lst.remove(item)
                        continue

                # ------ tratamento de erros sem derrubar a thread
                consec_err += 1
                if resp.error in ("STOPPED", "TIMEOUT"):
                    time.sleep(0.05)
                    self.transport.flush_input()
                if not self.raw_log and resp.error not in ("NO DATA",):
                    self.log.emit(f"{pdef.cmd}: {resp.error} ({' / '.join(resp.lines) or '-'})")
                if resp.error == "UNABLE TO CONNECT" or consec_err >= self.MAX_CONSEC_ERRORS:
                    self._reinit_bus()
                    consec_err = 0
                    no_data_streak.clear()
                    break

            cycle += 1
            n_cycles += 1
            now = time.monotonic()
            if now - last_rate >= 1.0:
                dt = now - last_rate
                self.rate.emit(n_resp / dt, n_cycles / dt)
                n_resp, n_cycles, last_rate = 0, 0, now

    def _reinit_bus(self) -> None:
        self.status.emit("connecting", "Comunicação com a ECU perdida — reinicializando barramento...")
        assert self.elm is not None
        if self.vag_kwp_mode:
            self.log.emit("Reinicializando barramento VAG KWP2000 (ATPC + ATSP4 + ATIIA01 + 2121)")
            while self._running:
                if self._init_vag_kwp2000([]):
                    self.status.emit("connected", "Conectado — VAG KWP2000 reinicializado")
                    return
                for _ in range(15):
                    if not self._running:
                        return
                    time.sleep(0.1)
            return

        self.log.emit("Reinicializando barramento (ATPC + ATSP0 + 0100)")
        self.elm.command("ATPC")
        self.elm.command("ATSP0", 2.0)
        while self._running:
            r = self.elm.command("0100", 12.0)
            payload = extract_payload(r, 1, 0x00, 4) if r.ok else None
            if r.ok and payload is not None:
                self.status.emit("connected", "Conectado — barramento reinicializado")
                return
            if r.error == "TIMEOUT" and not r.lines:
                raise TransportError("Adaptador não responde")
            self.status.emit("connecting", f"ECU sem resposta ({r.error or 'sem dados'}) — tentando novamente...")
            for _ in range(15):
                if not self._running:
                    return
                time.sleep(0.1)

    def _emit(self, values: Dict[str, float]) -> None:
        now = time.monotonic()
        self.sample.emit(now - self.t0, time.time() * 1000.0, values)

    # ------------------------------------------------------------ DTC (Modo 03/04 ou KWP2000 18/14)
    def _process_commands(self) -> None:
        while True:
            try:
                cmd = self._cmds.get_nowait()
            except queue.Empty:
                return
            assert self.elm is not None
            if cmd == "read_dtc":
                if self.vag_kwp_mode:
                    r = self.elm.command("1800FF00", 5.0)
                    self.log.emit(f"> 1800FF00 -> {' / '.join(r.lines) or '-'}")
                    codes = dtcmod.parse_dtcs(r) if r.ok else []
                    if r.error and r.error != "NO DATA":
                        self.info.emit(f"Leitura de DTC falhou: {r.error}")
                    mil = (len(codes) > 0, len(codes))
                    self.dtc_result.emit([(c, dtcmod.describe(c)) for c in codes], mil)
                else:
                    mil = None
                    r = self.elm.command("0101", 3.0)
                    d = extract_payload(r, 1, 0x01, 4)
                    if d:
                        mil = dtcmod.parse_mil(d)
                    r = self.elm.command("03", 5.0)
                    self.log.emit(f"> 03 -> {' / '.join(r.lines) or '-'}")
                    codes = dtcmod.parse_dtcs(r) if r.ok else []
                    if r.error and r.error != "NO DATA":
                        self.info.emit(f"Leitura de DTC falhou: {r.error}")
                    self.dtc_result.emit([(c, dtcmod.describe(c)) for c in codes], mil)
            elif cmd == "clear_dtc":
                if self.vag_kwp_mode:
                    r = self.elm.command("14FF00", 5.0)
                    self.log.emit(f"> 14FF00 -> {' / '.join(r.lines) or '-'}")
                    ok = any(l.startswith("54") for l in r.data_lines())
                else:
                    r = self.elm.command("04", 5.0)
                    self.log.emit(f"> 04 -> {' / '.join(r.lines) or '-'}")
                    ok = any(l.startswith("44") for l in r.data_lines())
                self.info.emit("Códigos de falha apagados." if ok else f"Falha ao apagar DTCs: {r.error or r.lines}")
                self._cmds.put("read_dtc")
                return
            elif cmd == "scan_vag":
                if self.vag_kwp_mode:
                    self._scan_all_vag()
                else:
                    self.info.emit("Varredura de blocos disponível só no modo VAG KWP2000 (ECU VW/Bosch ME7). "
                                   "No modo OBD2 todos os PIDs do bitmap já são lidos automaticamente.")
