"""Janela principal: conexão, cards, gráficos sincronizados, eventos, DTCs e gravação CSV."""
from __future__ import annotations

import html
import os
import time
from datetime import datetime
from typing import Dict, List, Tuple

import numpy as np
import pyqtgraph as pg
from PyQt6.QtCore import QSettings, Qt, QThread, QTimer
from PyQt6.QtGui import QAction, QFont
from PyQt6.QtWidgets import (QCheckBox, QComboBox, QFileDialog, QGridLayout, QGroupBox, QHBoxLayout,
                             QHeaderView, QLabel, QLineEdit, QMainWindow, QMessageBox, QPlainTextEdit,
                             QPushButton, QSpinBox, QSplitter, QTableWidget, QTableWidgetItem, QTabWidget,
                             QVBoxLayout, QWidget)

from ..ble_scan import BleScanWorker
from ..datalog import CsvLogger, SeriesBuffer
from ..detector import DecelDetector, Event
from ..pids import CHANNELS
from ..transports import BleTransport, MockTransport, TcpTransport
from ..worker import ObdWorker
from .plots import WINDOW_S, DualAxisPlot
from .style import COLORS, STYLE
from .widgets import ValueCard

MODE_BLE, MODE_WIFI, MODE_DEMO = 0, 1, 2
PLOTTED = ("rpm", "tps", "map", "lambda_v", "advance", "stft", "ltft")
STALE_S = 3.0
EVENT_COLORS = {"info": "#80d8ff", "warn": "#ffc107", "alarm": "#ff5252", "ok": "#69f0ae"}


class MainWindow(QMainWindow):
    def __init__(self, demo: bool = False):
        super().__init__()
        self.setWindowTitle("Datalogger OBD2 — Bosch ME7.5.30 (VW Gol G5 1.6 Flex)")
        self.resize(1500, 950)
        self.setStyleSheet(STYLE)
        pg.setConfigOptions(antialias=False, foreground="#9aa4b2")

        self.settings = QSettings("leitorECU", "DataloggerME75")
        self.worker: ObdWorker | None = None
        self.scan_worker: BleScanWorker | None = None
        self.t0 = time.monotonic()
        self.latest: Dict[str, float] = {}
        self.stamp: Dict[str, float] = {}
        self.dirty: set[str] = set()
        self.buffers = {k: SeriesBuffer() for k in PLOTTED}
        self.detector = DecelDetector()
        self.logger = CsvLogger()
        self.markers: List[Tuple[float, list]] = []
        self.frame = 0
        self.n_events = 0

        self._build_ui()
        self._load_settings()
        if demo:
            self.mode.setCurrentIndex(MODE_DEMO)

        self.render_timer = QTimer(self)
        self.render_timer.setTimerType(Qt.TimerType.PreciseTimer)
        self.render_timer.timeout.connect(self._render)
        self.render_timer.start(33)  # ~30 FPS

    # ================================================================== UI
    def _build_ui(self):
        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(8, 6, 8, 6)
        root.setSpacing(6)
        self.setCentralWidget(central)

        # ---------------- conexão
        conn = QGroupBox("Conexão ELM327")
        cl = QHBoxLayout(conn)
        self.mode = QComboBox()
        self.mode.addItems(["Bluetooth BLE (Vgate iCar Pro)", "Wi-Fi (TCP)", "Demo / Simulador"])
        self.mode.currentIndexChanged.connect(self._mode_changed)
        cl.addWidget(QLabel("Modo:"))
        cl.addWidget(self.mode)

        self.wifi_box = QWidget()
        wl = QHBoxLayout(self.wifi_box)
        wl.setContentsMargins(0, 0, 0, 0)
        self.ip = QLineEdit("192.168.0.10")
        self.ip.setFixedWidth(120)
        self.port = QSpinBox()
        self.port.setRange(1, 65535)
        self.port.setValue(35000)
        wl.addWidget(QLabel("IP:"))
        wl.addWidget(self.ip)
        wl.addWidget(QLabel("Porta:"))
        wl.addWidget(self.port)
        cl.addWidget(self.wifi_box)

        self.ble_box = QWidget()
        bl = QHBoxLayout(self.ble_box)
        bl.setContentsMargins(0, 0, 0, 0)
        self.ble_dev = QComboBox()
        self.ble_dev.setEditable(True)
        self.ble_dev.setMinimumWidth(300)
        self.ble_dev.lineEdit().setPlaceholderText("Clique em Procurar ou digite o endereço")
        self.ble_scan_btn = QPushButton("🔍 Procurar BLE")
        self.ble_scan_btn.clicked.connect(self._scan_ble)
        bl.addWidget(QLabel("Adaptador:"))
        bl.addWidget(self.ble_dev)
        bl.addWidget(self.ble_scan_btn)
        cl.addWidget(self.ble_box)

        self.connect_btn = QPushButton("Conectar", objectName="connect")
        self.connect_btn.setCheckable(True)
        self.connect_btn.setMinimumWidth(120)
        self.connect_btn.clicked.connect(self._toggle_connect)
        cl.addWidget(self.connect_btn)
        self.status_lbl = QLabel("Desconectado")
        self.status_lbl.setStyleSheet("color:#9aa4b2;")
        cl.addWidget(self.status_lbl, 1)
        root.addWidget(conn)

        # ---------------- controles
        ctl = QHBoxLayout()
        self.decel_btn = QPushButton("⚡ Prioridade de Desaceleração", objectName="decel")
        self.decel_btn.setCheckable(True)
        self.decel_btn.setMinimumWidth(250)
        self.decel_btn.setToolTip("Lê apenas RPM, MAP, Avanço, TPS e Sonda (pausa ECT/STFT/LTFT)\n"
                                  "para aumentar a taxa de amostragem e capturar Cut-Off / Dashpot.")
        self.decel_btn.toggled.connect(self._decel_toggled)
        self.rec_btn = QPushButton("⏺ Gravar Log")
        self.rec_btn.setCheckable(True)
        self.rec_btn.toggled.connect(self._toggle_record)
        self.freeze_btn = QPushButton("⏸ Congelar gráficos")
        self.freeze_btn.setCheckable(True)
        clear_btn = QPushButton("Limpar gráficos")
        clear_btn.clicked.connect(self._clear_plots)
        self.extras_chk = QCheckBox("Ler todos os PIDs da central (carga, velocidade, IAT, malha, bateria)")
        self.extras_chk.setChecked(True)
        self.extras_chk.toggled.connect(self._apply_worker_flags)
        self.fast_chk = QCheckBox("Resposta rápida (sufixo 1)")
        self.fast_chk.setToolTip("Envia '010C1' em vez de '010C': o ELM327 não espera timeout após a resposta.\n"
                                 "Aumenta bastante a taxa; desative se o adaptador responder '?' ou NO DATA.")
        self.fast_chk.toggled.connect(self._apply_worker_flags)
        self.raw_chk = QCheckBox("Console bruto")
        self.raw_chk.toggled.connect(self._apply_worker_flags)
        self.cadence_cb = QComboBox()
        self.cadence_cb.addItems([
            "Taxa: Máxima",
            "Taxa: Suave (reduz ruído K-Line)",
            "Taxa: Silenciosa (1 Hz)",
            "Pausar Linha K (Mudo)",
        ])
        self.cadence_cb.setToolTip(
            "Controla a frequência de pacotes na Linha K.\n"
            "No Gol G5, a Linha K passa no chicote do som/painel e pode induzir um 'tic-tic-tic' (~5 Hz) no tweeter.\n"
            "Use 'Pausar Linha K' ou 'Suave' quando estiver parado e 'Máxima' quando for gravar o teste."
        )
        self.cadence_cb.currentIndexChanged.connect(self._apply_worker_flags)
        for w in (self.decel_btn, self.rec_btn, self.freeze_btn, clear_btn):
            ctl.addWidget(w)
        ctl.addSpacing(8)
        for w in (self.cadence_cb, self.extras_chk, self.fast_chk, self.raw_chk):
            ctl.addWidget(w)
        ctl.addStretch()
        self.rate_lbl = QLabel("0.0 resp/s | 0.0 ciclos/s")
        self.rate_lbl.setFont(QFont("Consolas", 11, QFont.Weight.Bold))
        self.rate_lbl.setStyleSheet("color:#40c4ff;")
        ctl.addWidget(self.rate_lbl)
        root.addLayout(ctl)

        # ---------------- cards
        cards = QGridLayout()
        cards.setSpacing(6)
        self.cards: Dict[str, ValueCard] = {}
        card_channels = [(k, ch) for k, ch in CHANNELS.items() if getattr(ch, "card", True)]
        for i, (k, ch) in enumerate(card_channels):
            card = ValueCard(ch, COLORS.get(k))
            self.cards[k] = card
            cards.addWidget(card, i // 7, i % 7)
        root.addLayout(cards)

        # ---------------- gráficos + painel lateral
        split = QSplitter(Qt.Orientation.Horizontal)
        plots_w = QWidget()
        pl = QVBoxLayout(plots_w)
        pl.setContentsMargins(0, 0, 0, 0)
        pl.setSpacing(2)

        self.p1 = DualAxisPlot("Dinâmica de Ar e Giro", "RPM", (0, 7000), "TPS % / MAP kPa", (0, 105))
        self.p2 = DualAxisPlot("Combustão e Mistura", "Sonda (V)", (0, 1.3), "Avanço (°)", (-20, 50))
        self.p3 = DualAxisPlot("Correção da Injeção", "Fuel Trim (%)", (-30, 30))
        self.p2.setXLink(self.p1)
        self.p3.setXLink(self.p1)
        self.p3.pi.setLabel("bottom", "Tempo (s)")

        self.curves = {
            "rpm": self.p1.add_curve("RPM", COLORS["rpm"], width=2),
            "tps": self.p1.add_curve("TPS %", COLORS["tps"], right=True),
            "map": self.p1.add_curve("MAP kPa", COLORS["map"], right=True),
            "lambda_v": self.p2.add_curve("Sonda V", COLORS["lambda_v"], width=2),
            "advance": self.p2.add_curve("Avanço °", COLORS["advance"], right=True),
            "stft": self.p3.add_curve("STFT %", COLORS["stft"], width=2),
            "ltft": self.p3.add_curve("LTFT %", COLORS["ltft"], width=2),
        }
        self.p2.add_hline(0.45, "#ffffff", label="0,45 V")
        self.p2.add_hline(0.70, "#ff5252", style=Qt.PenStyle.DotLine, label="0,70 V cut-off")
        self.p2.add_hline(-5, "#e040fb", right=True, style=Qt.PenStyle.DotLine)
        self.p3.add_hline(0, "#607d8b", style=Qt.PenStyle.SolidLine)
        self.p3.add_hline(10, "#ffc107", label="+10%")
        self.p3.add_hline(-10, "#ffc107", label="-10%")
        for p in (self.p1, self.p2, self.p3):
            pl.addWidget(p)
        split.addWidget(plots_w)

        tabs = QTabWidget()
        # eventos
        ev_w = QWidget()
        evl = QVBoxLayout(ev_w)
        evl.setContentsMargins(4, 4, 4, 4)
        self.events = QPlainTextEdit(readOnly=True)
        self.events.setMaximumBlockCount(2000)
        ev_clear = QPushButton("Limpar eventos")
        ev_clear.clicked.connect(self.events.clear)
        evl.addWidget(QLabel("Detector de Desaceleração / Cut-Off  (RPM > 3000 → queda com TPS < 15%)"))
        evl.addWidget(self.events, 1)
        evl.addWidget(ev_clear)
        tabs.addTab(ev_w, "Eventos")
        # DTC
        dtc_w = QWidget()
        dl = QVBoxLayout(dtc_w)
        dl.setContentsMargins(4, 4, 4, 4)
        hb = QHBoxLayout()
        self.dtc_read_btn = QPushButton("Ler DTCs (03)")
        self.dtc_read_btn.clicked.connect(lambda: self._request("read_dtc"))
        self.dtc_clear_btn = QPushButton("Apagar DTCs (04)")
        self.dtc_clear_btn.clicked.connect(self._clear_dtc)
        hb.addWidget(self.dtc_read_btn)
        hb.addWidget(self.dtc_clear_btn)
        dl.addLayout(hb)
        self.mil_lbl = QLabel("Luz de injeção (MIL): —")
        dl.addWidget(self.mil_lbl)
        self.dtc_table = QTableWidget(0, 2)
        self.dtc_table.setHorizontalHeaderLabels(["Código", "Descrição"])
        self.dtc_table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self.dtc_table.verticalHeader().setVisible(False)
        dl.addWidget(self.dtc_table, 1)
        tabs.addTab(dtc_w, "Códigos de Falha")
        # console
        self.console = QPlainTextEdit(readOnly=True)
        self.console.setMaximumBlockCount(3000)
        tabs.addTab(self.console, "Console ELM327")
        split.addWidget(tabs)
        split.setStretchFactor(0, 4)
        split.setStretchFactor(1, 1)
        split.setSizes([1100, 400])
        root.addWidget(split, 1)

        self.statusBar().showMessage("Pronto. Escolha o modo de conexão e clique em Conectar.")
        quit_act = QAction("Sair", self)
        quit_act.setShortcut("Ctrl+Q")
        quit_act.triggered.connect(self.close)
        self.addAction(quit_act)
        self._mode_changed(self.mode.currentIndex())
        self._set_dtc_enabled(False)

    # ============================================================ settings
    def _load_settings(self):
        s = self.settings
        self.ip.setText(s.value("ip", "192.168.0.10"))
        self.port.setValue(int(s.value("port", 35000)))
        self.mode.setCurrentIndex(int(s.value("mode", MODE_BLE)))
        addr = s.value("ble_addr", "")
        name = s.value("ble_name", "")
        if addr:
            self.ble_dev.addItem(f"{name}  [{addr}]" if name else addr, addr)
        self.extras_chk.setChecked(s.value("extras", "true") == "true")
        self.fast_chk.setChecked(s.value("fast", "false") == "true")

    def _save_settings(self):
        s = self.settings
        s.setValue("ip", self.ip.text().strip())
        s.setValue("port", self.port.value())
        s.setValue("mode", self.mode.currentIndex())
        s.setValue("ble_addr", self._ble_address())
        s.setValue("ble_name", self.ble_dev.currentText().split("  [")[0] if self.ble_dev.currentData() else "")
        s.setValue("extras", "true" if self.extras_chk.isChecked() else "false")
        s.setValue("fast", "true" if self.fast_chk.isChecked() else "false")

    # ============================================================ conexão
    def _mode_changed(self, idx: int):
        self.wifi_box.setVisible(idx == MODE_WIFI)
        self.ble_box.setVisible(idx == MODE_BLE)

    def _ble_address(self) -> str:
        data = self.ble_dev.currentData()
        if data and self.ble_dev.currentText() == self.ble_dev.itemText(self.ble_dev.currentIndex()):
            return data
        return self.ble_dev.currentText().strip()

    def _scan_ble(self):
        if self.scan_worker and self.scan_worker.isRunning():
            return
        self.ble_scan_btn.setEnabled(False)
        self.ble_scan_btn.setText("Procurando...")
        self.statusBar().showMessage("Procurando adaptadores BLE por 6 s (o iCar Pro aparece como 'IOS-Vlink')...")
        self.scan_worker = BleScanWorker(6.0, self)
        self.scan_worker.found.connect(self._ble_found)
        self.scan_worker.failed.connect(self._ble_failed)
        self.scan_worker.finished.connect(self._ble_scan_done)
        self.scan_worker.start()

    def _ble_found(self, devices):
        self.ble_dev.clear()
        for name, addr, rssi, likely in devices:
            self.ble_dev.addItem(f"{'★ ' if likely else ''}{name}  [{addr}]  {rssi} dBm", addr)
        self.statusBar().showMessage(f"{len(devices)} dispositivo(s) BLE encontrado(s). ★ = provável adaptador OBD.")
        if not devices:
            QMessageBox.information(self, "BLE", "Nenhum dispositivo encontrado.\nLigue a ignição do carro "
                                                 "(o adaptador precisa estar energizado) e tente de novo.")

    def _ble_failed(self, msg):
        QMessageBox.warning(self, "Bluetooth", msg)

    def _ble_scan_done(self):
        self.ble_scan_btn.setEnabled(True)
        self.ble_scan_btn.setText("🔍 Procurar BLE")

    def _toggle_connect(self, checked: bool):
        if checked:
            self._start_worker()
        else:
            self._stop_worker()

    def _start_worker(self):
        mode = self.mode.currentIndex()
        if mode == MODE_WIFI:
            transport = TcpTransport(self.ip.text().strip(), self.port.value(), timeout=2.0)
        elif mode == MODE_BLE:
            addr = self._ble_address()
            if not addr:
                QMessageBox.warning(self, "BLE", "Selecione o adaptador BLE (clique em 'Procurar BLE').")
                self.connect_btn.setChecked(False)
                return
            transport = BleTransport(addr, timeout=2.0)
        else:
            transport = MockTransport()
        self._save_settings()
        self._clear_plots()
        self.latest.clear()
        self.stamp.clear()
        self.dirty.clear()
        self.detector = DecelDetector()
        for card in self.cards.values():
            card.value.setText("--")
            card.set_state("stale", "")
        self.t0 = time.monotonic()
        self.worker = ObdWorker(transport, self.t0, self)
        if isinstance(transport, BleTransport):
            transport._log = self.worker.log.emit  # sinal Qt: seguro entre threads
        self.worker.sample.connect(self._on_sample)
        self.worker.status.connect(self._on_status)
        self.worker.log.connect(self.console.appendPlainText)
        self.worker.rate.connect(self._on_rate)
        self.worker.dtc_result.connect(self._on_dtc)
        self.worker.info.connect(self._on_info)
        self.worker.finished.connect(self._worker_finished)
        self._apply_worker_flags()
        self.worker.decel_mode = self.decel_btn.isChecked()
        self.mode.setEnabled(False)
        self.wifi_box.setEnabled(False)
        self.ble_box.setEnabled(False)
        self.connect_btn.setText("Desconectar")
        self.console.appendPlainText(f"===== {datetime.now():%H:%M:%S} conectando ({transport.name}) =====")
        self.worker.start(QThread.Priority.HighPriority)

    def _stop_worker(self):
        if self.worker:
            self.connect_btn.setEnabled(False)
            self.connect_btn.setText("Desconectando...")
            self.worker.stop()

    def _worker_finished(self):
        self.worker = None
        self.connect_btn.setEnabled(True)
        self.connect_btn.setChecked(False)
        self.connect_btn.setText("Conectar")
        self.mode.setEnabled(True)
        self.wifi_box.setEnabled(True)
        self.ble_box.setEnabled(True)
        self._set_dtc_enabled(False)
        self.rate_lbl.setText("0.0 resp/s | 0.0 ciclos/s")

    def _on_status(self, state: str, msg: str):
        color = {"connected": "#69f0ae", "connecting": "#ffc107", "error": "#ff5252"}.get(state, "#9aa4b2")
        self.status_lbl.setStyleSheet(f"color:{color}; font-weight:bold;")
        self.status_lbl.setText(msg)
        self._set_dtc_enabled(state == "connected")

    def _on_info(self, msg: str):
        self.statusBar().showMessage(msg, 10000)
        self.console.appendPlainText(f"ℹ {msg}")

    def _on_rate(self, resp: float, cycles: float):
        self.rate_lbl.setText(f"{resp:4.1f} resp/s | {cycles:4.1f} ciclos/s")

    def _apply_worker_flags(self):
        if self.worker:
            self.worker.read_extras = self.extras_chk.isChecked()
            self.worker.fast_reply = self.fast_chk.isChecked()
            self.worker.raw_log = self.raw_chk.isChecked()
            idx = self.cadence_cb.currentIndex()
            self.worker.poll_delay = {0: 0.0, 1: 0.25, 2: 0.80, 3: -1.0}.get(idx, 0.0)

    def _decel_toggled(self, on: bool):
        if self.worker:
            self.worker.decel_mode = on
        self.statusBar().showMessage("Modo Prioridade de Desaceleração " +
                                     ("ATIVADO: lendo só RPM/MAP/Avanço/TPS/Sonda" if on else "desativado"), 6000)

    # ============================================================ dados
    def _on_sample(self, t: float, wall_ms: float, values: dict):
        for k, v in values.items():
            self.latest[k] = v
            self.stamp[k] = t
            self.dirty.add(k)
            buf = self.buffers.get(k)
            if buf is not None:
                buf.append(t, v)
        events = self.detector.update(t, self.latest, self.stamp)
        ev_text = " | ".join(e.message for e in events)
        if self.logger.active:
            self.logger.write(wall_ms, t, "+".join(values.keys()), self.latest, ev_text)
        for e in events:
            self._add_event(e)

    def _add_event(self, e: Event):
        self.n_events += 1
        color = EVENT_COLORS.get(e.level, "#e6e6e6")
        ts = datetime.now().strftime("%H:%M:%S")
        self.events.appendHtml(f'<span style="color:#78909c">[{ts} | t={e.t:7.2f}s]</span> '
                               f'<span style="color:{color}">{html.escape(e.message)}</span>')
        if e.level in ("alarm", "info") and "Fim" not in e.message:
            mcolor = "#ff1744" if e.level == "alarm" else "#80d8ff"
            self.markers.append((e.t, [p.add_marker(mcolor) for p in (self.p1, self.p2, self.p3)]))
        if e.level == "alarm":
            self.statusBar().showMessage("⚠ " + e.message, 15000)

    def _clear_plots(self):
        for b in self.buffers.values():
            b.clear()
        for c in self.curves.values():
            c.setData([], [])
        for _, lines in self.markers:
            for p, ln in zip((self.p1, self.p2, self.p3), lines):
                p.pi.removeItem(ln)
        self.markers.clear()

    # ============================================================ render 30 FPS
    def _render(self):
        self.frame += 1
        now = time.monotonic() - self.t0
        if not self.freeze_btn.isChecked():
            t_from = now - WINDOW_S - 1
            for k, curve in self.curves.items():
                t, v = self.buffers[k].window(t_from)
                curve.setData(t - now, v)
            keep = []
            for tm, lines in self.markers:
                if now - tm > WINDOW_S + 1:
                    for p, ln in zip((self.p1, self.p2, self.p3), lines):
                        p.pi.removeItem(ln)
                else:
                    for ln in lines:
                        ln.setPos(tm - now)
                    keep.append((tm, lines))
            self.markers = keep

        for k in self.dirty:
            if k in self.cards:
                self.cards[k].set_value(self.latest[k])
        self.dirty.clear()
        if self.frame % 6 == 0:
            self._update_card_states(now)
            if self.logger.active:
                self.rec_btn.setText(f"⏹ Gravando ({self.logger.rows} linhas)")

    def _update_card_states(self, now: float):
        decel = self.decel_btn.isChecked()
        for k, card in self.cards.items():
            max_age = 40.0 if k == "battery" else (12.0 if k in ("ect", "ltft", "speed", "iat") else STALE_S)
            if k not in self.stamp or now - self.stamp[k] > max_age:
                note = "pausado" if decel and k in ("ect", "ltft", "stft", "load", "speed", "iat", "battery") \
                    and k in self.stamp else ""
                card.set_state("stale", note)
                continue
            v = self.latest[k]
            state, note = "normal", ""
            if k in ("stft", "ltft", "lambda_trim"):
                if abs(v) > 20:
                    state, note = "alarm", "RICA" if v < 0 else "POBRE"
                elif abs(v) > 10:
                    state, note = "warn", "corrigindo -" if v < 0 else "corrigindo +"
            elif k == "ect":
                if v >= 108:
                    state, note = "alarm", "SUPERAQUEC."
                elif v < 70:
                    state, note = "warn", "frio"
            elif k == "battery":
                if v < 12.0 or v > 15.0:
                    state, note = "alarm", "baixa" if v < 12 else "alta"
                elif v < 13.0:
                    state, note = "warn", "sem carga?"
            elif k == "lambda_v":
                state, note = self._lambda_state(now)
            elif k == "advance" and v < -5:
                state, note = "warn", "retardado"
            card.set_state(state, note)

    def _lambda_state(self, now: float) -> Tuple[str, str]:
        t, v = self.buffers["lambda_v"].window(now - 4.0)
        rpm = self.latest.get("rpm", 0)
        ect = self.latest.get("ect")
        if len(v) < 4 or rpm < 650 or self.detector.in_decel:
            return "normal", ""
        if ect is not None and ect < 65:
            return "normal", "malha aberta"
        if float(np.ptp(v)) < 0.06:
            m = float(np.mean(v))
            return "alarm", "TRAVADA " + ("RICA" if m > 0.6 else "POBRE" if m < 0.3 else "")
        return "normal", ""

    # ============================================================ log CSV
    def _toggle_record(self, on: bool):
        if on:
            os.makedirs("logs", exist_ok=True)
            default = os.path.join("logs", f"gol_me75_{datetime.now():%Y%m%d_%H%M%S}.csv")
            path, _ = QFileDialog.getSaveFileName(self, "Salvar log CSV", default, "CSV (*.csv)")
            if not path:
                self.rec_btn.blockSignals(True)
                self.rec_btn.setChecked(False)
                self.rec_btn.blockSignals(False)
                return
            try:
                self.logger.start(path)
            except OSError as e:
                QMessageBox.critical(self, "Log", f"Não foi possível criar o arquivo:\n{e}")
                self.rec_btn.setChecked(False)
                return
            self.statusBar().showMessage(f"Gravando em {path}")
        else:
            if self.logger.active:
                rows, path = self.logger.rows, self.logger.path
                self.logger.stop()
                self.statusBar().showMessage(f"Log salvo: {path} ({rows} linhas)", 10000)
            self.rec_btn.setText("⏺ Gravar Log")

    # ============================================================ DTC
    def _set_dtc_enabled(self, on: bool):
        self.dtc_read_btn.setEnabled(on)
        self.dtc_clear_btn.setEnabled(on)

    def _request(self, cmd: str):
        if self.worker:
            self.worker.request(cmd)
            self.statusBar().showMessage("Comando enviado à ECU...", 3000)

    def _clear_dtc(self):
        r = QMessageBox.question(self, "Apagar DTCs",
                                 "Apagar todos os códigos de falha e zerar as adaptações de diagnóstico?\n"
                                 "Faça com a ignição LIGADA e o motor DESLIGADO.")
        if r == QMessageBox.StandardButton.Yes:
            self._request("clear_dtc")

    def _on_dtc(self, codes: list, mil):
        self.dtc_table.setRowCount(0)
        for code, desc in codes:
            row = self.dtc_table.rowCount()
            self.dtc_table.insertRow(row)
            self.dtc_table.setItem(row, 0, QTableWidgetItem(code))
            self.dtc_table.setItem(row, 1, QTableWidgetItem(desc))
        if mil is not None:
            on, n = mil
            self.mil_lbl.setText(f"Luz de injeção (MIL): {'ACESA' if on else 'apagada'} — {n} código(s) armazenado(s)")
            self.mil_lbl.setStyleSheet(f"color:{'#ff5252' if on else '#69f0ae'}; font-weight:bold;")
        if not codes:
            self.statusBar().showMessage("Nenhum código de falha armazenado.", 8000)

    # ============================================================ fechar
    def closeEvent(self, ev):
        self._save_settings()
        self.render_timer.stop()
        if self.worker:
            self.worker.stop()
            self.worker.wait(6000)
        if self.scan_worker:
            self.scan_worker.wait(7000)
        self.logger.stop()
        super().closeEvent(ev)
