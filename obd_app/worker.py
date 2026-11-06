"""QThread de orquestração de comunicação veicular (SOLID: SRP, OCP, DIP).

Esta classe atua estritamente como orquestradora:
- Gerencia o ciclo de vida da thread (start, stop, reconexão resiliente)
- Configura o adaptador ELM327 através da abstração ITransport
- Delega a lógica de protocolo para a estratégia IVehicleStrategy correspondente
- Emite sinais Qt para a interface gráfica de forma thread-safe
"""
from __future__ import annotations

import os
import queue
import time
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

from PyQt6.QtCore import QThread, pyqtSignal

from .elm327 import ELM327
from .interfaces import ITransport, IVehicleStrategy
from .protocols import (PROFILE_FORD_KA, PROFILE_GENERIC, PROFILE_VW_GOL,
                        VEHICLE_STRATEGIES, get_vehicle_strategy)
from .transports import Transport, TransportError

VEHICLE_PROFILES = {
    PROFILE_VW_GOL: "VW Gol G5 1.6 Flex (Bosch ME7.5.30 / KWP2000)",
    PROFILE_FORD_KA: "Ford Ka+ 2016 SEL 1.5 Sigma (HS-CAN / Conforto BCM)",
    PROFILE_GENERIC: "OBD2 Padrão / Automático",
}


class ObdWorker(QThread):
    """Orquestrador assíncrono de comunicação OBD (QThread)."""

    # Sinais Qt thread-safe para a UI
    sample = pyqtSignal(float, float, dict)        # t_rel, timestamp_wall_ms, {canal: valor}
    status = pyqtSignal(str, str)                  # (estado, mensagem) estado: connecting|connected|error|stopped
    log = pyqtSignal(str)                          # log do console ELM
    rate = pyqtSignal(float, float)                # respostas/s, ciclos/s
    dtcs = pyqtSignal(bool, int, list)             # mil_on, n_dtcs, [(código, descrição)]
    dtc_result = pyqtSignal(list, object)          # compatibilidade legada: [(código, desc)], (mil, count)
    info = pyqtSignal(str)                         # notificações humanas na status bar
    channels = pyqtSignal(dict)                    # canais conhecidos {chave: (rótulo, unidade)}
    protocol_mode_changed = pyqtSignal(str, bool)  # (modo_descritivo, is_fallback)

    MAX_CONSEC_ERRORS = 12

    def __init__(self, transport: Transport, t0: float, vehicle_profile: str = PROFILE_VW_GOL, parent=None):
        super().__init__(parent)
        self.transport = transport
        self.t0 = t0
        self.vehicle_profile = vehicle_profile

        # Injeção de dependência da estratégia veicular (SOLID: DIP & OCP)
        self.strategy: IVehicleStrategy = get_vehicle_strategy(vehicle_profile)

        self._running = True
        self.decel_mode = False
        self.background_scan_enabled = False
        self.read_extras = True
        self.fast_reply = False
        self.raw_log = False
        self.poll_delay = 0.0
        self._cmds: "queue.Queue[str]" = queue.Queue()
        self.elm: Optional[ELM327] = None

        # Redireciona sinal dtcs para dtc_result para total compatibilidade retroativa
        self.dtcs.connect(self._on_dtcs_emitted)

    def _on_dtcs_emitted(self, mil: bool, count: int, found: list):
        self.dtc_result.emit(found, (mil, count))

    # ---------------------------------------------------------------- API Pública
    def stop(self) -> None:
        """Sinaliza parada limpa da thread."""
        self._running = False

    def request(self, cmd: str) -> None:
        """Enfileira comando para a thread: 'read_dtc' | 'clear_dtc' | 'scan_vag' | 'scan_ford'"""
        self._cmds.put(cmd)

    # ---------------------------------------------------------------- Ciclo de Vida da Thread
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
            except Exception as e:
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

            # Pausa resiliente antes da reconexão
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

        # Inicializa a estratégia veicular selecionada
        ok = self.strategy.initialize(self.elm, self)
        if not ok:
            # Fallback automático para OBD2 Genérico se a estratégia específica falhar
            if self.vehicle_profile != PROFILE_GENERIC:
                self.log.emit("⚠️ Handshake específico falhou! Acionando Fallback ISO 9141-2 / OBD2 Genérico...")
                self.strategy = get_vehicle_strategy(PROFILE_GENERIC)
                ok = self.strategy.initialize(self.elm, self)
                if ok:
                    self.protocol_mode_changed.emit("Fallback ISO 9141-2 (Modo 01 Assíncrono)", True)
                    self.status.emit("warning", "Fallback ISO 9141-2 (Modo 01 Assíncrono) — VAG KWP2000 falhou")
            if not ok:
                raise TransportError("ECU não respondeu ao handshake inicial. Ligue a ignição.")
        else:
            if self.strategy.profile_id == PROFILE_VW_GOL:
                self.protocol_mode_changed.emit("VAG KWP2000 Nativo (Bloco 003 Síncrono)", False)
            elif self.strategy.profile_id == PROFILE_FORD_KA:
                self.protocol_mode_changed.emit("Ford HS-CAN 500k (PCM + BCM + ABS)", False)
            else:
                self.protocol_mode_changed.emit(self.strategy.display_name, False)

        # Emite metadados de canais iniciais da estratégia
        info_channels = self.strategy.get_channels_info()
        if info_channels:
            self.channels.emit(info_channels)

    def _poll_loop(self) -> None:
        assert self.elm is not None
        consec_err = 0
        cycle = 0
        n_resp, n_cycles = 0, 0
        last_rate = time.monotonic()

        while self._running:
            # Em protocolos que retornam respostas multi-frame, fast_reply ('1') deve ficar desligado
            is_multiframe = self.strategy.profile_id in (PROFILE_VW_GOL, PROFILE_FORD_KA)
            self.elm.fast_reply = False if is_multiframe else self.fast_reply
            self.elm.raw_log = self.raw_log
            self._process_commands()

            # Modo Mudo/Pausado (para não induzir ruído de chicote no som do carro parado)
            if self.poll_delay < 0:
                time.sleep(0.1)
                if time.monotonic() - last_rate >= 3.0:
                    keepalive = "3E" if self.strategy.profile_id == PROFILE_VW_GOL else "0100"
                    self.elm.command(keepalive, 2.0)
                    self.rate.emit(0.0, 0.0)
                    last_rate = time.monotonic()
                continue

            if self.poll_delay > 0:
                time.sleep(self.poll_delay)

            # Executa ciclo de leitura da estratégia
            n_resp_c = self.strategy.poll_cycle(self.elm, self, cycle, self.decel_mode)
            n_resp += n_resp_c

            if n_resp_c > 0:
                consec_err = 0
            else:
                consec_err += 1
                if consec_err >= self.MAX_CONSEC_ERRORS:
                    self._reinit_bus()
                    consec_err = 0

            cycle += 1
            n_cycles += 1
            now = time.monotonic()
            if now - last_rate >= 1.0:
                dt = now - last_rate
                self.rate.emit(n_resp / dt, n_cycles / dt)
                n_resp, n_cycles, last_rate = 0, 0, now

    def _process_commands(self) -> None:
        while not self._cmds.empty() and self._running:
            cmd = self._cmds.get_nowait()
            if cmd == "read_dtc":
                self.strategy.read_dtcs(self.elm, self)
            elif cmd == "clear_dtc":
                self.strategy.clear_dtcs(self.elm, self)
            elif cmd == "reset_adaptation":
                self.strategy.reset_adaptation(self.elm, self)
            elif cmd in ("scan_vag", "scan_ford", "scan_all"):
                self.strategy.scan_all(self.elm, self)
            elif cmd in ("reconnect_vag", "force_vag_kwp"):
                self.log.emit("Forçando reconexão ao protocolo VAG KWP2000 Nativo...")
                self.vehicle_profile = PROFILE_VW_GOL
                self.strategy = get_vehicle_strategy(PROFILE_VW_GOL)
                self._reinit_bus()

    def _reinit_bus(self) -> None:
        self.log.emit("Muitos erros consecutivos — reinicializando barramento...")
        if self.elm:
            self.elm.command("ATPC", 1.0)
            self.strategy.initialize(self.elm, self)

    def _emit(self, values: Dict[str, float]) -> None:
        now = time.monotonic()
        t_rel = now - self.t0
        wall_ms = time.time() * 1000.0
        self.sample.emit(t_rel, wall_ms, values)
