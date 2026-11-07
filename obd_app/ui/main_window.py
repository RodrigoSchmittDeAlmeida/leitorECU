"""Janela principal: conexão, cards, gráficos customizáveis, eventos, DTCs e gravação CSV."""
from __future__ import annotations

import csv
import html
import os
import time
from bisect import bisect_left
from collections import defaultdict
from datetime import datetime
from typing import Dict, List, Optional, Tuple

import numpy as np
import pyqtgraph as pg
from PyQt6.QtCore import QSettings, Qt, QThread, QTimer
from PyQt6.QtGui import QAction, QFont, QKeySequence, QShortcut
from PyQt6.QtWidgets import (QApplication, QCheckBox, QComboBox, QFileDialog, QFrame, QGridLayout, QGroupBox, QHBoxLayout,
                             QHeaderView, QLabel, QLineEdit, QMainWindow, QMessageBox, QPlainTextEdit,
                             QPushButton, QSizePolicy, QSpinBox, QSplitter, QTableWidget, QTableWidgetItem, QTabWidget,
                             QVBoxLayout, QWidget)

from .. import ford, vag
from ..ble_scan import BleScanWorker
from ..datalog import CsvLogger, SeriesBuffer
from ..detector import DecelDetector, Event
from ..ford import FORD_CHANNELS_INFO
from ..pids import CHANNELS, DYNAMIC_INFO
from ..transports import BleTransport, MockTransport, TcpTransport
from ..worker import (PROFILE_FORD_KA, PROFILE_GENERIC, PROFILE_VW_GOL,
                      VEHICLE_PROFILES, ObdWorker)
from .map2d import Map2DWidget
from .plots import WINDOW_S, DualAxisPlot
from .style import COLORS, STYLE
from .widgets import ValueCard

MODE_BLE, MODE_WIFI, MODE_DEMO = 0, 1, 2
PLOTTED = ("rpm", "tps", "map", "lambda_v", "lambda2_v", "advance", "stft", "ltft")
STALE_S = 3.0
EVENT_COLORS = {"info": "#80d8ff", "warn": "#ffc107", "alarm": "#ff5252", "ok": "#69f0ae"}

# Catálogo de canais selecionáveis nos 3 gráficos do osciloscópio:
# (chave, rótulo_exibição, unidade_eixo, faixa_y, cor_padrao)
PLOT_CHANNEL_CATALOG: List[Tuple[str, str, str, Tuple[float, float], str]] = [
    ("", "(Nenhum)", "", (0.0, 100.0), "#78909c"),
    ("rpm", "RPM Motor", "RPM", (0.0, 7000.0), COLORS["rpm"]),
    ("map", "MAP (kPa)", "kPa", (0.0, 105.0), COLORS["map"]),
    ("tps", "TPS Borboleta (%)", "%", (0.0, 105.0), COLORS["tps"]),
    ("app_pedal_pct", "Pedal APP (%)", "%", (0.0, 105.0), COLORS["app_pedal_pct"]),
    ("advance", "Avanço Ignição (°)", "°", (-20.0, 50.0), COLORS["advance"]),
    ("lambda_v", "Sonda 1 Pré-Cat (V)", "V", (0.0, 1.3), COLORS["lambda_v"]),
    ("lambda2_v", "Sonda 2 Pós-Cat (V)", "V", (0.0, 1.3), COLORS["lambda2_v"]),
    ("stft", "STFT Curto Prazo (%)", "%", (-30.0, 30.0), COLORS["stft"]),
    ("ltft", "LTFT Longo Prazo (%)", "%", (-30.0, 30.0), COLORS["ltft"]),
    ("lambda_trim", "Correção Sonda (%)", "%", (-30.0, 30.0), "#00e676"),
    ("battery", "Bateria / Alternador (V)", "V", (9.0, 16.0), COLORS["battery"]),
    ("obd_pin16_v", "Pino 16 OBD ATRV (V)", "V", (9.0, 16.0), COLORS["obd_pin16_v"]),
    ("ecu_volt", "Tensão Interna ECU (V)", "V", (9.0, 16.0), COLORS["ecu_volt"]),
    ("bcm_battery_v", "Tensão Módulo BCM (V)", "V", (9.0, 16.0), COLORS["bcm_battery_v"]),
    ("inj_ms", "Tempo Injeção (ms)", "ms", (0.0, 20.0), COLORS["inj_ms"]),
    ("ect", "Temp. Água ECT (°C)", "°C", (0.0, 125.0), COLORS["ect"]),
    ("iat", "Temp. Ar IAT (°C)", "°C", (0.0, 90.0), COLORS["iat"]),
    ("cht_temp", "Temp. Cabeçote CHT (°C)", "°C", (0.0, 130.0), COLORS["cht_temp"]),
    ("cat_temp", "Temp. Catalisador (°C)", "°C", (0.0, 950.0), COLORS["cat_temp"]),
    ("load", "Carga Motor (%)", "%", (0.0, 105.0), COLORS["load"]),
    ("speed", "Velocidade (km/h)", "km/h", (0.0, 180.0), COLORS["speed"]),
    ("flex_ethanol_pct", "Teor Etanol Flex (%)", "%", (0.0, 105.0), COLORS["flex_ethanol_pct"]),
    ("ac_pressure_kpa", "Pressão A/C (kPa)", "kPa", (0.0, 2500.0), COLORS["ac_pressure_kpa"]),
    ("wheel_speed_fl", "Roda Diant. Esq (km/h)", "km/h", (0.0, 180.0), COLORS["wheel_speed_fl"]),
    ("wheel_speed_fr", "Roda Diant. Dir (km/h)", "km/h", (0.0, 180.0), COLORS["wheel_speed_fr"]),
    ("steering_wheel_angle", "Ângulo Direção EPAS (°)", "°", (-540.0, 540.0), COLORS["steering_wheel_angle"]),
    ("knock_ret_c1", "Retardo Detonação Cil.1 (°)", "°", (-15.0, 2.0), COLORS["knock_ret_c1"]),
    ("knock_v_c1", "Sensor Detonação Cil.1 (V)", "V", (0.0, 5.0), COLORS["knock_v_c1"]),
]

PLOT_CATALOG_MAP: Dict[str, Tuple[str, str, Tuple[float, float], str]] = {
    k: (label, unit, yrange, color)
    for k, label, unit, yrange, color in PLOT_CHANNEL_CATALOG
}


class MainWindow(QMainWindow):
    def __init__(self, demo: bool = False):
        super().__init__()
        self.setWindowTitle("Datalogger OBD2 — Bosch ME7.5.30 (VW Gol G5 1.6 Flex)")
        self.setStyleSheet(STYLE)
        pg.setConfigOptions(antialias=False, foreground="#9aa4b2")

        self.settings = QSettings("leitorECU", "DataloggerME75")
        self.worker: ObdWorker | None = None
        self.scan_worker: BleScanWorker | None = None
        self.t0 = time.monotonic()
        self.latest: Dict[str, float] = {}
        self.stamp: Dict[str, float] = {}
        self.dirty: set[str] = set()
        self.buffers: Dict[str, SeriesBuffer] = defaultdict(SeriesBuffer)
        for k in PLOTTED:
            _ = self.buffers[k]
        self.detector = DecelDetector()
        self.logger = CsvLogger()
        self.markers: List[Tuple[float, list]] = []
        self.frame = 0
        self.n_events = 0
        self._replay_mode = False
        self._replay_times: List[float] = []
        self._replay_records: List[Dict[str, float]] = []
        self.dyn_info: Dict[str, Tuple[str, str]] = {}
        self._ch_rows: Dict[str, int] = {}

        # Slots configuráveis para os 3 gráficos (p1, p2, p3)
        self.plot_selectors: Dict[int, Dict[str, QComboBox]] = {}
        self.slot_curves: Dict[Tuple[int, str], pg.PlotDataItem] = {}
        self.slot_keys: Dict[Tuple[int, str], str] = {}
        self.curves: Dict[str, pg.PlotDataItem] = {}

        self._build_ui()
        self._load_settings()
        if demo:
            self.mode.setCurrentIndex(MODE_DEMO)

        self._fit_to_screen()

        self.render_timer = QTimer(self)
        self.render_timer.setTimerType(Qt.TimerType.PreciseTimer)
        self.render_timer.timeout.connect(self._render)
        self.render_timer.start(33)  # ~30 FPS

    def _fit_to_screen(self):
        """Garante que a janela caiba 100% dentro da área útil do monitor sem sair pela direita."""
        self.setMinimumSize(940, 560)
        screen = QApplication.primaryScreen()
        if screen:
            avail = screen.availableGeometry()
            target_w = min(1420, avail.width() - 16)
            target_h = min(800, avail.height() - 24)
            self.resize(target_w, target_h)
            x = avail.x() + max(0, (avail.width() - target_w) // 2)
            y = avail.y() + max(0, (avail.height() - target_h) // 2)
            self.move(x, y)
        else:
            self.resize(1280, 720)

    # ================================================================== UI
    def _build_ford_tab(self) -> QWidget:
        """Painel completo dos módulos Ford Ka+ em grade 2x2 fixa que cabe 100% na tela sem scroll."""
        tab = QWidget()
        tab.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        main_lay = QVBoxLayout(tab)
        main_lay.setContentsMargins(4, 4, 4, 4)
        main_lay.setSpacing(4)

        # Barra de Ação Superior
        top_box = QHBoxLayout()
        top_box.setContentsMargins(0, 0, 0, 0)
        self.ford_scan_btn = QPushButton("Varrer Módulos Ford (PCM, BCM, ABS, IPC, PSCM)")
        self.ford_scan_btn.setToolTip("Consulta todos os DIDs dos módulos Ford na rede HS-CAN 500k e grava tudo no CSV.")
        self.ford_scan_btn.clicked.connect(lambda: self._request("scan_ford"))
        top_box.addWidget(self.ford_scan_btn)
        self.ford_net_lbl = QLabel("Rede: HS-CAN 500 kbps (11-bit)")
        self.ford_net_lbl.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        self.ford_net_lbl.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        self.ford_net_lbl.setStyleSheet("color:#40c4ff; font-weight:bold; font-size:8pt;")
        top_box.addWidget(self.ford_net_lbl, 1)
        main_lay.addLayout(top_box)

        # Grade 2x2 sem barra de rolagem (tudo visível simultaneamente no mesmo container)
        grid_2x2 = QGridLayout()
        grid_2x2.setContentsMargins(0, 0, 0, 0)
        grid_2x2.setSpacing(4)

        # 1. Motor Ford Sigma 1.5 16V Flex DOHC (PCM 7E0)
        pcm_box = QGroupBox("Motor Sigma 1.5 16V Flex (PCM - 0x7E0)")
        pcm_box.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        pcm_lay = QGridLayout(pcm_box)
        pcm_lay.setContentsMargins(4, 3, 4, 3)
        pcm_lay.setSpacing(3)

        self.f_sonda1 = QLabel("Sonda 1 (Pré): -- V")
        self.f_sonda2 = QLabel("Sonda 2 (Pós): -- V")
        self.f_cat_diag = QLabel("Catalisador: --")
        self.f_fuel_sys = QLabel("Injeção: --")
        self.f_cat_temp = QLabel("Temp. Cat: -- °C")
        self.f_iat = QLabel("Temp. Ar (IAT): -- °C")
        self.f_cht = QLabel("Temp. CHT: -- °C")
        self.f_fan_duty = QLabel("Ventoinha: -- %")
        self.f_app_pedal = QLabel("Pedal APP: -- %")
        self.f_inj_pw = QLabel("Injeção: -- ms")
        self.f_flex_eth = QLabel("Etanol Flex: -- %")
        self.f_baro = QLabel("Baro: -- kPa")
        self.f_ac_press = QLabel("Pressão A/C: -- kPa")
        self.f_ac_clutch = QLabel("Comp. A/C: --")
        self.f_pcm_volt = QLabel("Tensão PCM: -- V")
        self.f_obd_pin16 = QLabel("Pino 16 OBD: -- V")

        pcm_labels = (
            self.f_sonda1, self.f_sonda2, self.f_cat_diag, self.f_fuel_sys,
            self.f_cat_temp, self.f_iat, self.f_cht, self.f_fan_duty,
            self.f_app_pedal, self.f_inj_pw, self.f_flex_eth, self.f_baro,
            self.f_ac_press, self.f_ac_clutch, self.f_pcm_volt, self.f_obd_pin16,
        )
        for idx_l, lbl in enumerate(pcm_labels):
            lbl.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
            lbl.setStyleSheet("background:#1f242b; color:#e0e0e0; padding:2px 4px; border-radius:3px; font-size:7.5pt;")
            pcm_lay.addWidget(lbl, idx_l // 2, idx_l % 2)

        grid_2x2.addWidget(pcm_box, 0, 0)

        # 2. Carroceria & Conforto (BCM 726)
        bcm_box = QGroupBox("Carroceria & Conforto (BCM - 0x726)")
        bcm_box.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        bcm_lay = QGridLayout(bcm_box)
        bcm_lay.setContentsMargins(4, 3, 4, 3)
        bcm_lay.setSpacing(3)

        self.b_door_fl = QLabel("DE: Fechada")
        self.b_door_fr = QLabel("DD: Fechada")
        self.b_door_rl = QLabel("TE: Fechada")
        self.b_door_rr = QLabel("TD: Fechada")
        self.b_door_trunk = QLabel("Mala: Fechada")
        self.b_door_hood = QLabel("Capô: Fechado")
        self.b_central_lock = QLabel("Travas: Destranc.")
        self.b_alarm = QLabel("Alarme: Desarm.")
        self.b_low_beam = QLabel("Farol Baixo: OFF")
        self.b_high_beam = QLabel("Farol Alto: OFF")
        self.b_fog_lights = QLabel("Neblina: OFF")
        self.b_parking_lights = QLabel("Lanternas: OFF")
        self.b_wiper = QLabel("Limpador: OFF")
        self.b_defrost = QLabel("Desemb.: OFF")
        self.b_ignition = QLabel("Ignição: —")
        self.b_bcm_bat = QLabel("Bateria BCM: — V")

        bcm_labels = (
            self.b_door_fl, self.b_door_fr, self.b_door_rl, self.b_door_rr,
            self.b_door_trunk, self.b_door_hood, self.b_central_lock, self.b_alarm,
            self.b_low_beam, self.b_high_beam, self.b_fog_lights, self.b_parking_lights,
            self.b_wiper, self.b_defrost, self.b_ignition, self.b_bcm_bat,
        )
        for idx_l, lbl in enumerate(bcm_labels):
            lbl.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
            lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            lbl.setStyleSheet("background:#1f242b; color:#9aa4b2; padding:2px 3px; border-radius:3px; font-size:7.5pt;")
            bcm_lay.addWidget(lbl, idx_l // 2, idx_l % 2)

        grid_2x2.addWidget(bcm_box, 0, 1)

        # 3. Freios ABS, ESC & Assistente de Rampa (ABS 760)
        abs_box = QGroupBox("Freios ABS, Estabilidade (ESC) & HLA (0x760)")
        abs_box.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        abs_lay = QGridLayout(abs_box)
        abs_lay.setContentsMargins(4, 3, 4, 3)
        abs_lay.setSpacing(3)

        self.f_wheel_fl = QLabel("Roda DE: -- km/h")
        self.f_wheel_fr = QLabel("Roda DD: -- km/h")
        self.f_wheel_rl = QLabel("Roda TE: -- km/h")
        self.f_wheel_rr = QLabel("Roda TD: -- km/h")
        self.f_brake_press = QLabel("Pressão Freio: -- bar")
        self.f_brake_sw = QLabel("Pedal Freio: Livre")
        self.f_sas_angle = QLabel("Sensor SAS: --°")
        self.f_esc_state = QLabel("Status ESC: Normal")

        for idx_l, lbl in enumerate((self.f_wheel_fl, self.f_wheel_fr, self.f_wheel_rl, self.f_wheel_rr)):
            lbl.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
            lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            lbl.setStyleSheet("background:#1f242b; color:#80d8ff; font-weight:bold; padding:2px 4px; border-radius:3px; font-size:7.5pt;")
            abs_lay.addWidget(lbl, idx_l // 2, idx_l % 2)

        for idx_l, lbl in enumerate((self.f_brake_press, self.f_brake_sw, self.f_sas_angle, self.f_esc_state), start=4):
            lbl.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
            lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            lbl.setStyleSheet("background:#1f242b; color:#e0e0e0; padding:2px 4px; border-radius:3px; font-size:7.5pt;")
            abs_lay.addWidget(lbl, idx_l // 2, idx_l % 2)

        grid_2x2.addWidget(abs_box, 1, 0)

        # 4. Painel de Instrumentos (IPC 720) & Direção Elétrica (PSCM 730)
        dash_box = QGroupBox("Painel (IPC - 0x720) & Direção EPAS (PSCM - 0x730)")
        dash_box.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        dash_lay = QGridLayout(dash_box)
        dash_lay.setContentsMargins(4, 3, 4, 3)
        dash_lay.setSpacing(3)

        self.f_odometer = QLabel("Odômetro: -- km")
        self.f_fuel_pct = QLabel("Combustível: -- %")
        self.f_ext_temp = QLabel("Temp. Externa: -- °C")
        self.f_parking_brake = QLabel("Freio de Mão: --")
        self.f_seatbelt = QLabel("Cinto Seg.: --")
        self.f_epas_angle = QLabel("Ângulo Volante: --°")
        self.f_epas_torque = QLabel("Torque Direção: -- Nm")
        self.f_epas_current = QLabel("Corrente EPAS: -- A")

        for idx_l, lbl in enumerate((self.f_odometer, self.f_fuel_pct, self.f_ext_temp, self.f_parking_brake,
                                     self.f_seatbelt, self.f_epas_angle, self.f_epas_torque, self.f_epas_current)):
            lbl.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
            lbl.setStyleSheet("background:#1f242b; color:#e0e0e0; padding:2px 4px; border-radius:3px; font-size:7.5pt;")
            dash_lay.addWidget(lbl, idx_l // 2, idx_l % 2)

        grid_2x2.addWidget(dash_box, 1, 1)
        grid_2x2.setRowStretch(0, 5)
        grid_2x2.setRowStretch(1, 3)
        grid_2x2.setColumnStretch(0, 1)
        grid_2x2.setColumnStretch(1, 1)

        main_lay.addLayout(grid_2x2, 1)
        return tab

    def _update_ford_ui(self):
        latest = self.latest
        if not latest:
            return

        def _badge(lbl, is_active, txt_on, txt_off, on_color="#69f0ae", off_color="#9aa4b2", on_bg="#1b5e20", off_bg="#1f242b"):
            lbl.setText(txt_on if is_active else txt_off)
            bg = on_bg if is_active else off_bg
            color = on_color if is_active else off_color
            border = on_color if is_active else "#343b46"
            lbl.setStyleSheet(f"background:{bg}; color:{color}; font-weight:bold; padding:2px 3px; border-radius:3px; border:1px solid {border}; font-size:7.5pt;")

        # BCM Portas
        if "door_fl" in latest:
            _badge(self.b_door_fl, latest["door_fl"] > 0.5, "DE: ABERTA", "DE: Fechada", on_color="#ff5252", on_bg="#3d1418")
        if "door_fr" in latest:
            _badge(self.b_door_fr, latest["door_fr"] > 0.5, "DD: ABERTA", "DD: Fechada", on_color="#ff5252", on_bg="#3d1418")
        if "door_rl" in latest:
            _badge(self.b_door_rl, latest["door_rl"] > 0.5, "TE: ABERTA", "TE: Fechada", on_color="#ff5252", on_bg="#3d1418")
        if "door_rr" in latest:
            _badge(self.b_door_rr, latest["door_rr"] > 0.5, "TD: ABERTA", "TD: Fechada", on_color="#ff5252", on_bg="#3d1418")
        if "door_trunk" in latest:
            _badge(self.b_door_trunk, latest["door_trunk"] > 0.5, "Mala: ABERTA", "Mala: Fechada", on_color="#ff5252", on_bg="#3d1418")
        if "door_hood" in latest:
            _badge(self.b_door_hood, latest["door_hood"] > 0.5, "Capô: ABERTO", "Capô: Fechado", on_color="#ff5252", on_bg="#3d1418")
        if "central_lock" in latest:
            _badge(self.b_central_lock, latest["central_lock"] > 0.5, "Travas: TRANC.", "Travas: Destranc.", on_color="#ffab40", on_bg="#3a3214")
        if "alarm_armed" in latest:
            _badge(self.b_alarm, latest["alarm_armed"] > 0.5, "Alarme: ARMADO", "Alarme: Desarm.", on_color="#69f0ae", on_bg="#1b5e20")

        # BCM Iluminação e Elétrica
        if "low_beam" in latest:
            _badge(self.b_low_beam, latest["low_beam"] > 0.5, "Farol Baixo: ON", "Farol Baixo: OFF", on_color="#40c4ff", on_bg="#0d47a1")
        if "high_beam" in latest:
            _badge(self.b_high_beam, latest["high_beam"] > 0.5, "Farol Alto: ON", "Farol Alto: OFF", on_color="#00e5ff", on_bg="#006064")
        if "fog_lights" in latest:
            _badge(self.b_fog_lights, latest["fog_lights"] > 0.5, "Neblina: ON", "Neblina: OFF", on_color="#69f0ae", on_bg="#1b5e20")
        if "parking_lights" in latest:
            _badge(self.b_parking_lights, latest["parking_lights"] > 0.5, "Lanternas: ON", "Lanternas: OFF", on_color="#ffc107", on_bg="#3a3214")
        if "wiper_status" in latest:
            wp_map = {0: "OFF", 1: "Interm.", 2: "Baixa", 3: "Alta"}
            self.b_wiper.setText(f"Limpador: {wp_map.get(int(latest['wiper_status']), 'Ativo')}")
        if "rear_defrost" in latest:
            _badge(self.b_defrost, latest["rear_defrost"] > 0.5, "Desemb.: ON", "Desemb.: OFF", on_color="#ffab40", on_bg="#3a3214")
        if "ignition_pos" in latest:
            ig_map = {0: "OFF", 1: "ACC", 2: "RUN", 3: "CRANK"}
            self.b_ignition.setText(f"Ignição: {ig_map.get(int(latest['ignition_pos']), str(int(latest['ignition_pos'])))}")
        if "bcm_battery_v" in latest:
            self.b_bcm_bat.setText(f"Bateria BCM: {latest['bcm_battery_v']:.2f} V")
        elif "battery" in latest:
            self.b_bcm_bat.setText(f"Bateria: {latest['battery']:.2f} V")

        # ABS Rodas e Dinâmica
        if "wheel_speed_fl" in latest:
            spd_fl = latest["wheel_speed_fl"]
            spd_fr = latest.get("wheel_speed_fr", spd_fl)
            spd_rl = latest.get("wheel_speed_rl", spd_fl)
            spd_rr = latest.get("wheel_speed_rr", spd_fl)
            self.f_wheel_fl.setText(f"Roda DE: {spd_fl:.1f} km/h")
            self.f_wheel_fr.setText(f"Roda DD: {spd_fr:.1f} km/h")
            self.f_wheel_rl.setText(f"Roda TE: {spd_rl:.1f} km/h")
            self.f_wheel_rr.setText(f"Roda TD: {spd_rr:.1f} km/h")
            if "brake_pressure" not in latest:
                self.f_brake_press.setText("Pressão Freio: N/D")
            if "esc_active" not in latest:
                self.f_esc_state.setText("Status ESC: Monitorando")
        if "brake_pressure" in latest:
            self.f_brake_press.setText(f"Pressão Freio: {latest['brake_pressure']:.1f} bar")
        if "brake_pedal_sw" in latest:
            self.f_brake_sw.setText("Pedal Freio: ACIONADO" if latest["brake_pedal_sw"] > 0.5 else "Pedal Freio: Livre")
        if "steering_angle_abs" in latest:
            self.f_sas_angle.setText(f"Sensor SAS: {latest['steering_angle_abs']:.1f}°")
        if "esc_active" in latest:
            self.f_esc_state.setText("ESC/HLA: ATIVO!" if latest["esc_active"] > 0.5 else "Status ESC: Normal")

        # PCM Motor Sigma 1.5 DOHC
        s1 = latest.get("lambda_v")
        if s1 is not None:
            self.f_sonda1.setText(f"Sonda 1 (Pré): {s1:.3f} V")
        s2 = latest.get("lambda2_v")
        if s2 is not None:
            self.f_sonda2.setText(f"Sonda 2 (Pós): {s2:.3f} V")

        if s1 is not None and s2 is not None:
            temp_ref = latest.get("cht_temp") or latest.get("ect") or 0.0
            if temp_ref < 60.0:
                self.f_cat_diag.setText("Catalisador: AQUECENDO")
                self.f_cat_diag.setStyleSheet("background:#1a2b3c; color:#80d8ff; padding:2px 4px; border-radius:3px; font-size:7.5pt;")
            elif 0.50 <= s2 <= 0.82:
                self.f_cat_diag.setText("Catalisador: SAUDÁVEL")
                self.f_cat_diag.setStyleSheet("background:#143820; color:#69f0ae; padding:2px 4px; border-radius:3px; font-size:7.5pt; font-weight:bold;")
            elif s2 < 0.20:
                self.f_cat_diag.setText("Catalisador: POBRE/AR")
                self.f_cat_diag.setStyleSheet("background:#3a2010; color:#ffab40; padding:2px 4px; border-radius:3px; font-size:7.5pt;")
            else:
                self.f_cat_diag.setText("Catalisador: MONITOR.")
                self.f_cat_diag.setStyleSheet("background:#1f242b; color:#e0e0e0; padding:2px 4px; border-radius:3px; font-size:7.5pt;")

        fs = latest.get("fuel_sys1")
        if fs is not None:
            fs_int = int(fs)
            fs_map = {1: "Malha Aberta (Frio)", 2: "Malha Fechada (CL)", 4: "Malha Aberta (WOT)", 8: "Aberta (Falha)", 16: "CL c/ Falha"}
            self.f_fuel_sys.setText(f"Injeção: {fs_map.get(fs_int, f'Status {fs_int}')}")

        if "cat_temp" in latest:
            self.f_cat_temp.setText(f"Temp. Cat: {latest['cat_temp']:.0f} °C")
        if "iat" in latest:
            self.f_iat.setText(f"Temp. Ar (IAT): {latest['iat']:.0f} °C")
        if "cht_temp" in latest:
            self.f_cht.setText(f"Temp. CHT: {latest['cht_temp']:.0f} °C")
        if "app_pedal_pct" in latest:
            self.f_app_pedal.setText(f"Pedal APP: {latest['app_pedal_pct']:.1f} %")
        if "fan_duty_pct" in latest:
            self.f_fan_duty.setText(f"Ventoinha: {latest['fan_duty_pct']:.0f} %")
        if "inj_pulse_width" in latest or "inj_ms" in latest:
            pw = latest.get("inj_pulse_width", latest.get("inj_ms", 0.0))
            self.f_inj_pw.setText(f"Injeção: {pw:.2f} ms")
        if "baro" in latest:
            self.f_baro.setText(f"Baro: {latest['baro']:.0f} kPa")
        if "ac_pressure_kpa" in latest:
            self.f_ac_press.setText(f"Pressão A/C: {latest['ac_pressure_kpa']:.0f} kPa")
        if "ac_clutch" in latest:
            self.f_ac_clutch.setText("Comp. A/C: ON" if latest["ac_clutch"] > 0.5 else "Comp. A/C: OFF")
        if "flex_ethanol_pct" in latest:
            self.f_flex_eth.setText(f"Etanol Flex: {latest['flex_ethanol_pct']:.0f} %")
        if "ecu_volt" in latest or "battery" in latest:
            v_ecu = latest.get("ecu_volt", latest.get("battery", 0.0))
            self.f_pcm_volt.setText(f"Tensão PCM: {v_ecu:.2f} V")
        if "obd_pin16_v" in latest:
            self.f_obd_pin16.setText(f"Pino 16 OBD: {latest['obd_pin16_v']:.2f} V")

        # IPC & PSCM
        if "odometer_km" in latest:
            self.f_odometer.setText(f"Odômetro: {latest['odometer_km']:,.0f} km".replace(",", "."))
        if "fuel_level_pct" in latest:
            self.f_fuel_pct.setText(f"Combustível: {latest['fuel_level_pct']:.1f} %")
        if "ext_temp" in latest:
            self.f_ext_temp.setText(f"Temp. Externa: {latest['ext_temp']:.1f} °C")
        if "parking_brake" in latest:
            self.f_parking_brake.setText("Freio Mão: PUXADO" if latest["parking_brake"] > 0.5 else "Freio Mão: Livre")
        if "seatbelt_warning" in latest:
            self.f_seatbelt.setText("Cinto: SOLTO" if latest["seatbelt_warning"] > 0.5 else "Cinto: OK")
        if "steering_wheel_angle" in latest:
            self.f_epas_angle.setText(f"Ângulo Volante: {latest['steering_wheel_angle']:.1f}°")
        if "steering_driver_torque" in latest:
            self.f_epas_torque.setText(f"Torque Direção: {latest['steering_driver_torque']:.2f} Nm")
        if "steering_motor_current" in latest:
            self.f_epas_current.setText(f"Corrente EPAS: {latest['steering_motor_current']:.1f} A")

    def _vehicle_changed(self, idx: int):
        """Atualiza apenas o título da janela ao trocar de veículo, mantendo toda a interface fixa."""
        titles = {
            0: "Datalogger OBD2 — Bosch ME7.5.30 (VW Gol G5 1.6 Flex)",
            1: "Datalogger OBD2 — Ford Ka+ 2016 SEL 1.5 Sigma Flex (HS-CAN / Conforto BCM)",
            2: "Datalogger OBD2 Universal",
        }
        self.setWindowTitle(titles.get(idx, "Datalogger OBD2"))

    def _create_plot_selector_bar(self, plot_idx: int, title: str,
                                  default_l1: str, default_l2: str, default_r1: str) -> QHBoxLayout:
        """Cria barra compacta acima do gráfico permitindo escolher qualquer canal para cada curva."""
        bar = QHBoxLayout()
        bar.setContentsMargins(2, 0, 2, 0)
        bar.setSpacing(4)

        lbl_title = QLabel(f"G{plot_idx} ({title}):")
        lbl_title.setStyleSheet("color: #9aa4b2; font-weight: bold; font-size: 7.5pt;")
        bar.addWidget(lbl_title)

        self.plot_selectors[plot_idx] = {}
        slots = [("L1", "Esq.1:", default_l1), ("L2", "Esq.2:", default_l2), ("R1", "Dir.:", default_r1)]

        for slot_id, slot_lbl, def_key in slots:
            s_lbl = QLabel(slot_lbl)
            s_lbl.setStyleSheet("color: #78909c; font-size: 7.5pt;")
            bar.addWidget(s_lbl)

            cb = QComboBox()
            cb.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
            cb.setMinimumWidth(85)
            cb.setFixedHeight(20)
            sel_idx = 0
            for i, (ch_key, ch_label, _, _, _) in enumerate(PLOT_CHANNEL_CATALOG):
                cb.addItem(ch_label, ch_key)
                if ch_key == def_key:
                    sel_idx = i
            cb.setCurrentIndex(sel_idx)
            cb.currentIndexChanged.connect(lambda _idx, p=plot_idx: self._on_plot_channel_changed(p))
            bar.addWidget(cb, 1)
            self.plot_selectors[plot_idx][slot_id] = cb

        return bar

    def _on_plot_channel_changed(self, plot_idx: int):
        """Reconfigura dinamicamente as curvas, legendas, cores e escalas Y do gráfico selecionado."""
        plot_widget = {1: self.p1, 2: self.p2, 3: self.p3}[plot_idx]
        sels = self.plot_selectors[plot_idx]

        k_l1 = sels["L1"].currentData() or ""
        k_l2 = sels["L2"].currentData() or ""
        k_r1 = sels["R1"].currentData() or ""

        # Atualiza mapeamentos de slots
        self.slot_keys[(plot_idx, "L1")] = k_l1
        self.slot_keys[(plot_idx, "L2")] = k_l2
        self.slot_keys[(plot_idx, "R1")] = k_r1

        # Reconstrói legenda do gráfico
        plot_widget.legend.clear()

        for slot_id, ch_key in (("L1", k_l1), ("L2", k_l2), ("R1", k_r1)):
            curve = self.slot_curves[(plot_idx, slot_id)]
            if ch_key and ch_key in PLOT_CATALOG_MAP:
                label, _unit, _yrange, color = PLOT_CATALOG_MAP[ch_key]
                width = 2.0 if slot_id in ("L1", "R1") else 1.7
                curve.setPen(pg.mkPen(color, width=width))
                plot_widget.legend.addItem(curve, label)
            else:
                curve.setData([], [])

        # Calcula rótulo e faixa Y do eixo esquerdo (combina L1 e L2)
        left_keys = [k for k in (k_l1, k_l2) if k and k in PLOT_CATALOG_MAP]
        if left_keys:
            l_units = []
            y_min, y_max = 1e9, -1e9
            for k in left_keys:
                lbl, unit, (ymn, ymx), _ = PLOT_CATALOG_MAP[k]
                tag = unit if unit else lbl.split(" ")[0]
                if tag not in l_units:
                    l_units.append(tag)
                y_min = min(y_min, ymn)
                y_max = max(y_max, ymx)
            if len(left_keys) == 1:
                lbl0, unit0, _, _ = PLOT_CATALOG_MAP[left_keys[0]]
                left_label = lbl0
            else:
                left_label = " / ".join(PLOT_CATALOG_MAP[k][0].split(" ")[0] for k in left_keys) + f" ({'/'.join(l_units)})"
            left_range = (y_min, y_max)
        else:
            left_label = "—"
            left_range = (0.0, 100.0)

        # Calcula rótulo e faixa Y do eixo direito (R1)
        if k_r1 and k_r1 in PLOT_CATALOG_MAP:
            r_lbl, _r_unit, right_range, _ = PLOT_CATALOG_MAP[k_r1]
            right_label: Optional[str] = r_lbl
        else:
            right_label = None
            right_range = None

        plot_widget.configure_axes(left_label, left_range, right_label, right_range)

        # Sincroniza dicionário self.curves por chave de canal para compatibilidade e acesso rápido
        for (p_i, s_id), key in self.slot_keys.items():
            if key:
                self.curves[key] = self.slot_curves[(p_i, s_id)]

        # Se estiver em modo Replay ou ao vivo, redesenha imediatamente os dados do buffer
        if self._replay_mode and self._replay_times:
            self._replot_replay_curves()
        else:
            now = time.monotonic() - self.t0
            t_from = now - WINDOW_S - 1
            for slot_id in ("L1", "L2", "R1"):
                key = self.slot_keys[(plot_idx, slot_id)]
                curve = self.slot_curves[(plot_idx, slot_id)]
                if key:
                    t, v = self.buffers[key].window(t_from)
                    curve.setData(t - now, v)

    def _build_ui(self):
        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(6, 4, 6, 4)
        root.setSpacing(3)
        self.setCentralWidget(central)

        # ---------------- conexão (altura e larguras travadas para nunca deslocar)
        conn = QGroupBox("Conexão ELM327")
        conn.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        cl = QHBoxLayout(conn)
        cl.setContentsMargins(6, 2, 6, 2)
        cl.setSpacing(5)

        self.vehicle_cb = QComboBox()
        self.vehicle_cb.addItems([
            "VW Gol G5 1.6 Flex (ME7.5.30)",
            "Ford Ka+ 2016 SEL 1.5 Sigma (HS-CAN)",
            "OBD2 Genérico / Automático",
        ])
        self.vehicle_cb.setMaximumWidth(220)
        self.vehicle_cb.currentIndexChanged.connect(self._vehicle_changed)
        cl.addWidget(QLabel("Veículo:"))
        cl.addWidget(self.vehicle_cb)

        self.mode = QComboBox()
        self.mode.addItems(["Bluetooth BLE (Vgate iCar Pro)", "Wi-Fi (TCP)", "Demo / Simulador"])
        self.mode.setMaximumWidth(195)
        self.mode.currentIndexChanged.connect(self._mode_changed)
        cl.addWidget(QLabel("Modo:"))
        cl.addWidget(self.mode)

        self.wifi_box = QWidget()
        wl = QHBoxLayout(self.wifi_box)
        wl.setContentsMargins(0, 0, 0, 0)
        wl.setSpacing(4)
        self.ip = QLineEdit("192.168.0.10")
        self.ip.setFixedWidth(105)
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
        bl.setSpacing(4)
        self.ble_dev = QComboBox()
        self.ble_dev.setEditable(True)
        self.ble_dev.setFixedWidth(155)
        self.ble_dev.lineEdit().setPlaceholderText("Endereço ou Procurar")
        self.ble_scan_btn = QPushButton("Procurar BLE")
        self.ble_scan_btn.setFixedWidth(92)
        self.ble_scan_btn.clicked.connect(self._scan_ble)
        bl.addWidget(QLabel("BLE:"))
        bl.addWidget(self.ble_dev)
        bl.addWidget(self.ble_scan_btn)
        cl.addWidget(self.ble_box)

        self.connect_btn = QPushButton("Conectar", objectName="connect")
        self.connect_btn.setCheckable(True)
        self.connect_btn.setFixedWidth(95)
        self.connect_btn.clicked.connect(self._toggle_connect)
        cl.addWidget(self.connect_btn)

        self.proto_badge = QLabel("VAG KWP2000 Nativo", objectName="protoBadge")
        self.proto_badge.setProperty("fallback", "false")
        self.proto_badge.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.proto_badge.setFixedWidth(145)
        cl.addWidget(self.proto_badge)

        self.btn_reconnect_vag = QPushButton("Forçar VAG KWP")
        self.btn_reconnect_vag.setToolTip("Força a reconexão pelo protocolo VAG KWP2000 Nativo (Bloco 003 Síncrono)")
        self.btn_reconnect_vag.setEnabled(False)
        self.btn_reconnect_vag.setFixedWidth(105)
        self.btn_reconnect_vag.clicked.connect(self._force_reconnect_vag)
        cl.addWidget(self.btn_reconnect_vag)

        self.status_lbl = QLabel("Desconectado")
        self.status_lbl.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        self.status_lbl.setMinimumWidth(80)
        self.status_lbl.setStyleSheet("color:#9aa4b2;")
        cl.addWidget(self.status_lbl, 1)
        root.addWidget(conn)

        # ---------------- controles
        ctl = QHBoxLayout()
        ctl.setContentsMargins(0, 0, 0, 0)
        ctl.setSpacing(4)
        self.btn_open_csv = QPushButton("Abrir Log CSV")
        self.btn_open_csv.setToolTip("Carrega um arquivo CSV gravado para replay e análise ponto a ponto.")
        self.btn_open_csv.clicked.connect(self._open_csv_replay)

        self.btn_clear_peaks = QPushButton("Limpar Picos")
        self.btn_clear_peaks.setToolTip("Zera os valores de pico (Mínimo e Máximo) de todos os cards.")
        self.btn_clear_peaks.clicked.connect(self._clear_all_peaks)

        self.decel_btn = QPushButton("Desaceleração", objectName="decel")
        self.decel_btn.setCheckable(True)
        self.decel_btn.setToolTip("Lê apenas RPM, MAP, Avanço, TPS e Sonda para capturar Cut-Off / Dashpot.")
        self.decel_btn.toggled.connect(self._decel_toggled)

        self.rec_btn = QPushButton("Gravar Log")
        self.rec_btn.setCheckable(True)
        self.rec_btn.setMinimumWidth(95)
        self.rec_btn.toggled.connect(self._toggle_record)

        self.freeze_btn = QPushButton("Congelar")
        self.freeze_btn.setCheckable(True)

        clear_btn = QPushButton("Limpar")
        clear_btn.clicked.connect(self._clear_plots)

        self.extras_chk = QCheckBox("Todos os PIDs")
        self.extras_chk.setToolTip("Lê todos os PIDs da central (carga, velocidade, IAT, malha fechada, bateria)")
        self.extras_chk.setChecked(True)
        self.extras_chk.toggled.connect(self._apply_worker_flags)

        self.bg_scan_chk = QCheckBox("Varredura Extras")
        self.bg_scan_chk.setToolTip("Varre blocos e DIDs adicionais em segundo plano.")
        self.bg_scan_chk.setChecked(False)
        self.bg_scan_chk.toggled.connect(self._bg_scan_toggled)

        self.fast_chk = QCheckBox("Resp. rápida")
        self.fast_chk.setToolTip("Envia '010C1' para que o ELM327 retorne imediatamente após a 1ª resposta.")
        self.fast_chk.toggled.connect(self._apply_worker_flags)

        self.raw_chk = QCheckBox("Console bruto")
        self.raw_chk.toggled.connect(self._apply_worker_flags)

        self.cadence_cb = QComboBox()
        self.cadence_cb.addItems([
            "Taxa: Máxima",
            "Taxa: Suave (som)",
            "Taxa: 1 Hz",
            "Pausar Linha K",
        ])
        self.cadence_cb.setToolTip("Controla a frequência de pacotes na Linha K.")
        self.cadence_cb.currentIndexChanged.connect(self._apply_worker_flags)

        for w in (self.btn_open_csv, self.btn_clear_peaks, self.decel_btn, self.rec_btn, self.freeze_btn, clear_btn):
            ctl.addWidget(w)
        ctl.addSpacing(2)
        for w in (self.cadence_cb, self.extras_chk, self.bg_scan_chk, self.fast_chk, self.raw_chk):
            ctl.addWidget(w)
        ctl.addStretch()

        self.rate_lbl = QLabel("0.0 resp/s | 0.0 ciclos/s")
        self.rate_lbl.setFont(QFont("Consolas", 9, QFont.Weight.Bold))
        self.rate_lbl.setFixedWidth(185)
        self.rate_lbl.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        self.rate_lbl.setStyleSheet("color:#40c4ff;")
        ctl.addWidget(self.rate_lbl)
        root.addLayout(ctl)

        # ---------------- cards (grade 2x7 com larguras uniformes e políticas fixas)
        cards = QGridLayout()
        cards.setContentsMargins(0, 0, 0, 0)
        cards.setSpacing(4)
        self.cards: Dict[str, ValueCard] = {}
        card_channels = [(k, ch) for k, ch in CHANNELS.items() if getattr(ch, "card", True)]

        card_tooltips = {
            "rpm": "Rotações por minuto do motor (RPM)\nNormal em lenta: 800 - 950 rpm.",
            "map": "Pressão absoluta no coletor de admissão (MAP em kPa)\nVácuo em lenta: 28 - 38 kPa | Plena carga (WOT): ~95 - 101 kPa.",
            "advance": "Ponto de avanço de ignição em graus (°APMT)\nValores negativos indicam retardo por detonação.",
            "tps": "Posição angular da borboleta de aceleração (%)\n0% em marcha lenta | 100% em aceleração total.",
            "load": "Carga calculada do motor (%)\nProporcional ao fluxo de ar e esforço exigido.",
            "speed": "Velocidade instantânea do veículo reportada pela ECU (km/h).",
            "battery": "Tensão da bateria e alternador (V)\nLida via ECU (Bloco 004/032, DID F442/DD01) e Pino 16 OBD (ATRV).\nIdeal com motor ligado: 13,5 V a 14,5 V.",
            "lambda_v": "Tensão da Sonda Lambda 1 (Pré-Catalisador)\nDeve oscilar entre 0,1 V e 0,9 V em malha fechada (Closed Loop).",
            "lambda2_v": "Tensão da Sonda Lambda 2 (Pós-Catalisador)\nDeve permanecer estável entre 0,60 V e 0,75 V se o catalisador estiver eficiente.",
            "lambda_trim": "Correção instantânea da mistura pela sonda (%).",
            "stft": "Ajuste de combustível de curto prazo (Short Term Fuel Trim)\nOscila em torno de 0% (faixa normal: ±5%).",
            "ltft": "Ajuste de combustível de longo prazo (Long Term Fuel Trim)\nAdaptação contínua da injeção (faixa normal: -10% a +10%).",
            "ect": "Temperatura do líquido de arrefecimento do motor (°C)\nFaixa ideal de trabalho: 85 °C a 100 °C.",
            "iat": "Temperatura do ar admitido no coletor (°C)\nMedido pelo sensor T-MAP.",
        }

        for i, (k, ch) in enumerate(card_channels):
            card = ValueCard(ch, COLORS.get(k))
            card.setToolTip(card_tooltips.get(k, ch.label))
            self.cards[k] = card
            cards.addWidget(card, i // 7, i % 7)
        for col_i in range(7):
            cards.setColumnStretch(col_i, 1)
        root.addLayout(cards)

        # ---------------- gráficos + painel lateral (proporção 50/50 travada)
        self.main_splitter = QSplitter(Qt.Orientation.Horizontal)
        self.main_splitter.setChildrenCollapsible(False)
        self.main_splitter.setHandleWidth(4)

        plots_w = QWidget()
        plots_w.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        pl = QVBoxLayout(plots_w)
        pl.setContentsMargins(0, 0, 0, 0)
        pl.setSpacing(2)

        self.p1 = DualAxisPlot("Gráfico 1 — Dinâmica e Giro", "RPM", (0, 7000), "TPS % / MAP kPa", (0, 105))
        self.p2 = DualAxisPlot("Gráfico 2 — Combustão e Mistura", "Sonda (V)", (0, 1.3), "Avanço (°)", (-20, 50))
        self.p3 = DualAxisPlot("Gráfico 3 — Correção e Elétrica", "Fuel Trim (%)", (-30, 30))
        self.p2.setXLink(self.p1)
        self.p3.setXLink(self.p1)
        self.p3.pi.setLabel("bottom", "Tempo (s)")

        # Barras de seleção de canais acima de cada gráfico
        bar1 = self._create_plot_selector_bar(1, "Superior", "rpm", "", "map")
        # Para manter os 3 canais originais no Gráfico 1 por padrão (RPM na esq, TPS e MAP na dir/esq):
        # Na verdade, colocando RPM em L1, TPS em L2 ou R1: vamos criar também curvas dedicadas para os slots
        # e garantir que todas as 8 curvas padrão estejam ativas inicialmente!
        pl.addLayout(bar1)
        pl.addWidget(self.p1, 1)

        bar2 = self._create_plot_selector_bar(2, "Central", "lambda_v", "lambda2_v", "advance")
        pl.addLayout(bar2)
        pl.addWidget(self.p2, 1)

        bar3 = self._create_plot_selector_bar(3, "Inferior", "stft", "ltft", "battery")
        pl.addLayout(bar3)
        pl.addWidget(self.p3, 1)

        # Inicializa os PlotDataItems para cada slot (L1, L2, R1) nos 3 gráficos
        for p_idx, p_widget in ((1, self.p1), (2, self.p2), (3, self.p3)):
            self.slot_curves[(p_idx, "L1")] = p_widget.add_curve("L1", "#ff5252", right=False, width=2.0)
            self.slot_curves[(p_idx, "L2")] = p_widget.add_curve("L2", "#40c4ff", right=False, width=1.7)
            self.slot_curves[(p_idx, "R1")] = p_widget.add_curve("R1", "#b2ff59", right=True, width=1.8)

        # No gráfico 1, deixamos L1=rpm, L2=tps, R1=map para exibir simultaneamente RPM, TPS e MAP
        self.plot_selectors[1]["L2"].blockSignals(True)
        for idx_c, (ch_k, _, _, _, _) in enumerate(PLOT_CHANNEL_CATALOG):
            if ch_k == "tps":
                self.plot_selectors[1]["L2"].setCurrentIndex(idx_c)
                break
        self.plot_selectors[1]["L2"].blockSignals(False)

        # Aplica configuração inicial dos 3 gráficos e preenche self.curves
        for p_idx in (1, 2, 3):
            self._on_plot_channel_changed(p_idx)

        self.p2.add_hline(0.45, "#ffffff", label="0,45 V")
        self.p2.add_hline(0.70, "#ff5252", style=Qt.PenStyle.DotLine, label="0,70 V")
        self.p3.add_hline(0, "#607d8b", style=Qt.PenStyle.SolidLine)

        self.crosshair_p1 = self.p1.add_crosshair("#ffffff")
        self.crosshair_p2 = self.p2.add_crosshair("#ffffff")
        self.crosshair_p3 = self.p3.add_crosshair("#ffffff")
        for ch in (self.crosshair_p1, self.crosshair_p2, self.crosshair_p3):
            ch.setVisible(False)

        self.p1.scene().sigMouseMoved.connect(self._on_plot_mouse_moved)
        self.p2.scene().sigMouseMoved.connect(self._on_plot_mouse_moved)
        self.p3.scene().sigMouseMoved.connect(self._on_plot_mouse_moved)

        self.main_splitter.addWidget(plots_w)

        # ---------------- Abas direitas (TODAS visíveis lado a lado sem setas de scroll, container idêntico)
        tabs = QTabWidget()
        tabs.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        tabs.tabBar().setUsesScrollButtons(False)
        tabs.tabBar().setExpanding(False)

        # 1. Mapa 2D RPM x MAP
        self.map2d = Map2DWidget()
        tabs.addTab(self.map2d, "Mapa 2D")

        # 2. Ford Ka+ (Módulos & Conforto)
        self.ford_tab = self._build_ford_tab()
        tabs.addTab(self.ford_tab, "Ford Ka+")

        # 3. Todos os Canais
        self.ch_tab = QWidget()
        self.ch_tab.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        chl = QVBoxLayout(self.ch_tab)
        chl.setContentsMargins(4, 4, 4, 4)
        chl.setSpacing(4)
        chb = QHBoxLayout()
        self.scan_btn = QPushButton("Varrer Blocos VAG (001..255)")
        self.scan_btn.setToolTip("Lê os blocos de medição 001..255 da central (modo VAG KWP2000) e grava no CSV.")
        self.scan_btn.clicked.connect(lambda: self._request("scan_vag"))
        self.ch_count_lbl = QLabel("0 canais")
        self.ch_count_lbl.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        self.ch_count_lbl.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        chb.addWidget(self.scan_btn)
        chb.addWidget(self.ch_count_lbl, 1)
        chl.addLayout(chb)

        self.ch_search = QLineEdit()
        self.ch_search.setPlaceholderText("Filtrar canais por nome, código ou descrição (ex: bateria, sonda, 032)...")
        self.ch_search.setClearButtonEnabled(True)
        self.ch_search.textChanged.connect(self._filter_channels_table)
        chl.addWidget(self.ch_search)

        self.ch_table = QTableWidget(0, 4)
        self.ch_table.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        self.ch_table.setHorizontalHeaderLabels(["Canal", "Descrição", "Valor", "Idade (s)"])
        self.ch_table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self.ch_table.setColumnWidth(0, 85)
        self.ch_table.setColumnWidth(2, 75)
        self.ch_table.setColumnWidth(3, 58)
        self.ch_table.verticalHeader().setVisible(False)
        self.ch_table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        chl.addWidget(self.ch_table, 1)
        tabs.addTab(self.ch_tab, "Canais")

        # 4. DTC (Códigos de Falha)
        dtc_w = QWidget()
        dtc_w.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        dl = QVBoxLayout(dtc_w)
        dl.setContentsMargins(4, 4, 4, 4)
        dl.setSpacing(4)
        hb = QHBoxLayout()
        self.dtc_read_btn = QPushButton("Ler DTCs (03)")
        self.dtc_read_btn.clicked.connect(lambda: self._request("read_dtc"))
        self.dtc_clear_btn = QPushButton("Apagar DTCs (04)")
        self.dtc_clear_btn.clicked.connect(self._clear_dtc)
        self.btn_reset_adaptation = QPushButton("Reset Adaptação Flex (Canal 00)")
        self.btn_reset_adaptation.setToolTip(
            "Restaura valores de adaptação de fábrica na EEPROM (Canal 00 / Basic Setting 000).\n"
            "Zera o Bloco 032 e força o descarte do aprendizado antigo de combustível (Bloco 103 Flex)."
        )
        self.btn_reset_adaptation.clicked.connect(self._reset_adaptation_dialog)
        hb.addWidget(self.dtc_read_btn)
        hb.addWidget(self.dtc_clear_btn)
        hb.addWidget(self.btn_reset_adaptation)
        dl.addLayout(hb)
        self.mil_lbl = QLabel("Luz de injeção (MIL): —")
        self.mil_lbl.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        dl.addWidget(self.mil_lbl)
        self.dtc_table = QTableWidget(0, 2)
        self.dtc_table.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        self.dtc_table.setHorizontalHeaderLabels(["Código", "Descrição"])
        self.dtc_table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self.dtc_table.verticalHeader().setVisible(False)
        dl.addWidget(self.dtc_table, 1)
        tabs.addTab(dtc_w, "Falhas (DTC)")

        # 5. Eventos
        ev_w = QWidget()
        ev_w.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        evl = QVBoxLayout(ev_w)
        evl.setContentsMargins(4, 4, 4, 4)
        evl.setSpacing(4)
        self.events = QPlainTextEdit(readOnly=True)
        self.events.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        self.events.setMaximumBlockCount(2000)
        ev_clear = QPushButton("Limpar eventos")
        ev_clear.clicked.connect(self.events.clear)
        evl.addWidget(QLabel("Detector de Desaceleração / Cut-Off (RPM > 3000 → queda com TPS < 15%)"))
        evl.addWidget(self.events, 1)
        evl.addWidget(ev_clear)
        tabs.addTab(ev_w, "Eventos")

        # 6. Console
        self.console = QPlainTextEdit(readOnly=True)
        self.console.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        self.console.setMaximumBlockCount(3000)
        tabs.addTab(self.console, "Console")

        self.tabs = tabs
        self.main_splitter.addWidget(tabs)
        self.main_splitter.setStretchFactor(0, 5)
        self.main_splitter.setStretchFactor(1, 5)
        self.main_splitter.setSizes([700, 700])
        root.addWidget(self.main_splitter, 1)

        self.statusBar().showMessage("Pronto. Escolha o modo de conexão e clique em Conectar.")
        quit_act = QAction("Sair", self)
        quit_act.setShortcut("Ctrl+Q")
        quit_act.triggered.connect(self.close)
        self.addAction(quit_act)

        QShortcut(QKeySequence(Qt.Key.Key_Space), self, activated=self.freeze_btn.toggle)
        QShortcut(QKeySequence("Ctrl+R"), self, activated=self.rec_btn.toggle)
        QShortcut(QKeySequence("Ctrl+D"), self, activated=self.decel_btn.toggle)
        QShortcut(QKeySequence("Ctrl+L"), self, activated=self._clear_plots)
        QShortcut(QKeySequence("F5"), self, activated=lambda: self._request("read_dtc"))

        self._mode_changed(self.mode.currentIndex())
        self._set_dtc_enabled(False)

    # ============================================================ settings
    def _load_settings(self):
        s = self.settings
        self.ip.setText(s.value("ip", "192.168.0.10"))
        self.port.setValue(int(s.value("port", 35000)))
        self.mode.setCurrentIndex(int(s.value("mode", MODE_BLE)))
        veh_idx = int(s.value("vehicle_idx", 0))
        self.vehicle_cb.setCurrentIndex(veh_idx)
        self._vehicle_changed(veh_idx)
        addr = s.value("ble_addr", "")
        name = s.value("ble_name", "")
        if addr:
            self.ble_dev.addItem(f"{name}  [{addr}]" if name else addr, addr)
        self.extras_chk.setChecked(s.value("extras", "true") == "true")
        self.bg_scan_chk.setChecked(s.value("bg_scan", "false") == "true")
        self.fast_chk.setChecked(s.value("fast", "false") == "true")

    def _save_settings(self):
        s = self.settings
        s.setValue("ip", self.ip.text().strip())
        s.setValue("port", self.port.value())
        s.setValue("mode", self.mode.currentIndex())
        s.setValue("vehicle_idx", self.vehicle_cb.currentIndex())
        s.setValue("ble_addr", self._ble_address())
        s.setValue("ble_name", self.ble_dev.currentText().split("  [")[0] if self.ble_dev.currentData() else "")
        s.setValue("extras", "true" if self.extras_chk.isChecked() else "false")
        s.setValue("bg_scan", "true" if self.bg_scan_chk.isChecked() else "false")
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
            self.ble_dev.addItem(f"{'* ' if likely else ''}{name}  [{addr}]  {rssi} dBm", addr)
        self.statusBar().showMessage(f"{len(devices)} dispositivo(s) BLE encontrado(s).")
        if not devices:
            QMessageBox.information(self, "BLE", "Nenhum dispositivo encontrado.\nLigue a ignição do carro "
                                                 "(o adaptador precisa estar energizado) e tente de novo.")

    def _ble_failed(self, msg):
        QMessageBox.warning(self, "Bluetooth", msg)

    def _ble_scan_done(self):
        self.ble_scan_btn.setEnabled(True)
        self.ble_scan_btn.setText("Procurar BLE")

    def _toggle_connect(self, checked: bool):
        if checked:
            self._start_worker()
        else:
            self._stop_worker()

    def _start_worker(self):
        if self._replay_mode:
            self._exit_replay_mode()
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
        self.ch_table.setRowCount(0)
        self._ch_rows.clear()
        self.detector = DecelDetector()
        for card in self.cards.values():
            card.value.setText("--")
            card.set_state("stale", "")
        self.t0 = time.monotonic()
        veh_map = {0: PROFILE_VW_GOL, 1: PROFILE_FORD_KA, 2: PROFILE_GENERIC}
        veh_profile = veh_map.get(self.vehicle_cb.currentIndex(), PROFILE_VW_GOL)
        self.worker = ObdWorker(transport, self.t0, vehicle_profile=veh_profile, parent=self)
        if isinstance(transport, BleTransport):
            transport._log = self.worker.log.emit
        self.worker.sample.connect(self._on_sample)
        self.worker.status.connect(self._on_status)
        self.worker.log.connect(self.console.appendPlainText)
        self.worker.rate.connect(self._on_rate)
        self.worker.dtc_result.connect(self._on_dtc)
        self.worker.info.connect(self._on_info)
        self.worker.channels.connect(self._on_channels)
        self.worker.protocol_mode_changed.connect(self._on_protocol_mode_changed)
        self.worker.finished.connect(self._worker_finished)
        self._apply_worker_flags()
        self.worker.decel_mode = self.decel_btn.isChecked()
        self.vehicle_cb.setEnabled(False)
        self.mode.setEnabled(False)
        self.wifi_box.setEnabled(False)
        self.ble_box.setEnabled(False)
        self.btn_reconnect_vag.setEnabled(True)
        self.connect_btn.setText("Desconectar")
        self.console.appendPlainText(f"===== {datetime.now():%H:%M:%S} conectando ({transport.name} - {VEHICLE_PROFILES.get(veh_profile)}) =====")
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
        self.vehicle_cb.setEnabled(True)
        self.mode.setEnabled(True)
        self.wifi_box.setEnabled(True)
        self.ble_box.setEnabled(True)
        self.btn_reconnect_vag.setEnabled(False)
        self.proto_badge.setText("Desconectado")
        self.proto_badge.setProperty("fallback", "false")
        self.proto_badge.style().unpolish(self.proto_badge)
        self.proto_badge.style().polish(self.proto_badge)
        self._set_dtc_enabled(False)
        self.rate_lbl.setText("0.0 resp/s | 0.0 ciclos/s")

    def _on_status(self, state: str, msg: str):
        color = {"connected": "#69f0ae", "connecting": "#ffc107", "error": "#ff5252", "warning": "#ff9100"}.get(state, "#9aa4b2")
        self.status_lbl.setStyleSheet(f"color:{color}; font-weight:bold;")
        self.status_lbl.setText(msg)
        self.status_lbl.setToolTip(msg)
        self._set_dtc_enabled(state == "connected")

    def _on_protocol_mode_changed(self, mode_name: str, is_fallback: bool):
        self.proto_badge.setText(mode_name)
        self.proto_badge.setProperty("fallback", "true" if is_fallback else "false")
        self.proto_badge.style().unpolish(self.proto_badge)
        self.proto_badge.style().polish(self.proto_badge)
        self.btn_reconnect_vag.setEnabled(is_fallback or self.vehicle_cb.currentIndex() == 0)

    def _force_reconnect_vag(self):
        if self.worker:
            self.statusBar().showMessage("Forçando reconexão ao protocolo VAG KWP2000 Nativo...", 8000)
            self.worker.request("force_vag_kwp")

    def _bg_scan_toggled(self, checked: bool):
        if self.worker:
            self.worker.background_scan_enabled = checked

    def _clear_all_peaks(self):
        for card in self.cards.values():
            card.reset_peaks()
        self.statusBar().showMessage("Picos (Mínimo/Máximo) de todos os cards foram redefinidos.", 4000)

    def _on_info(self, msg: str):
        self.statusBar().showMessage(msg, 10000)
        self.console.appendPlainText(f"[INFO] {msg}")

    def _on_rate(self, resp: float, cycles: float):
        self.rate_lbl.setText(f"{resp:4.1f} resp/s | {cycles:4.1f} ciclos/s")

    def _apply_worker_flags(self):
        if self.worker:
            self.worker.read_extras = self.extras_chk.isChecked()
            self.worker.background_scan_enabled = self.bg_scan_chk.isChecked()
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
            if v is None:
                continue
            self.latest[k] = v
            self.stamp[k] = t
            self.dirty.add(k)
            self.buffers[k].append(t, v)
        if "rpm" in self.latest and "map" in self.latest:
            self.map2d.add_sample(self.latest["rpm"], self.latest["map"], self.latest)
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
            self.statusBar().showMessage("ALERTA: " + e.message, 15000)

    def _clear_plots(self):
        for b in self.buffers.values():
            b.clear()
        for c in self.slot_curves.values():
            c.setData([], [])
        for _, lines in self.markers:
            for p, ln in zip((self.p1, self.p2, self.p3), lines):
                try:
                    p.pi.removeItem(ln)
                except Exception:
                    pass
        self.markers.clear()

    # ============================================================ render 30 FPS
    def _render(self):
        if self._replay_mode:
            return
        self.frame += 1
        now = time.monotonic() - self.t0
        if not self.freeze_btn.isChecked():
            t_from = now - WINDOW_S - 1
            for (p_idx, s_id), curve in self.slot_curves.items():
                key = self.slot_keys.get((p_idx, s_id), "")
                if key:
                    t, v = self.buffers[key].window(t_from)
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
        if self.frame % 3 == 0:
            self._update_ford_ui()
        if self.frame % 6 == 0:
            self._update_card_states(now)
            if self.logger.active:
                self.rec_btn.setText(f"Gravando ({self.logger.rows})")
        if self.frame % 15 == 0:
            self._update_channels_table(now)

    def _update_channels_table(self, now: float):
        all_keys = list(CHANNELS.keys()) + [k for k in self.latest if k not in CHANNELS]
        total_keys = set(all_keys) | set(self.dyn_info.keys())
        self.ch_count_lbl.setText(f"{len(total_keys)} canais ({len(self.latest)} ativos)")

        for k in all_keys:
            val = self.latest.get(k)
            t_sample = self.stamp.get(k)
            age_str = f"{now - t_sample:.1f}s" if t_sample is not None else "—"

            if k in CHANNELS:
                ch = CHANNELS[k]
                desc = f"{ch.label} [{ch.unit}]" if ch.unit else ch.label
                val_str = ch.fmt.format(val) if val is not None else "--"
            elif k in self.dyn_info:
                label, unit = self.dyn_info[k]
                desc = f"{label} [{unit}]" if unit else label
                val_str = f"{val:.3f}" if val is not None else "--"
            elif k in DYNAMIC_INFO:
                label, unit = DYNAMIC_INFO[k]
                desc = f"{label} [{unit}]" if unit else label
                val_str = f"{val:.3f}" if val is not None else "--"
            elif k in FORD_CHANNELS_INFO:
                label, unit = FORD_CHANNELS_INFO[k]
                desc = f"{label} [{unit}]" if unit else label
                val_str = f"{val:.3f}" if val is not None else "--"
            else:
                desc = k
                val_str = f"{val:.3f}" if val is not None else "--"

            row = self._ch_rows.get(k)
            if row is None:
                row = self.ch_table.rowCount()
                self._ch_rows[k] = row
                self.ch_table.insertRow(row)
                self.ch_table.setItem(row, 0, QTableWidgetItem(k))
                self.ch_table.setItem(row, 1, QTableWidgetItem(desc))
                self.ch_table.setItem(row, 2, QTableWidgetItem(val_str))
                self.ch_table.setItem(row, 3, QTableWidgetItem(age_str))
            else:
                item_desc = self.ch_table.item(row, 1)
                if item_desc and item_desc.text() != desc:
                    item_desc.setText(desc)
                item_val = self.ch_table.item(row, 2)
                if item_val and item_val.text() != val_str:
                    item_val.setText(val_str)
                item_age = self.ch_table.item(row, 3)
                if item_age:
                    item_age.setText(age_str)

        if hasattr(self, "ch_search") and self.ch_search.text().strip():
            self._filter_channels_table(self.ch_search.text())

    def _filter_channels_table(self, query: str):
        q = query.strip().lower()
        for r in range(self.ch_table.rowCount()):
            if not q:
                self.ch_table.setRowHidden(r, False)
                continue
            item_k = self.ch_table.item(r, 0)
            item_desc = self.ch_table.item(r, 1)
            t_k = item_k.text().lower() if item_k else ""
            t_desc = item_desc.text().lower() if item_desc else ""
            match = (q in t_k) or (q in t_desc)
            self.ch_table.setRowHidden(r, not match)

    def _on_channels(self, new_channels: dict):
        self.dyn_info.update(new_channels)
        extra_headers = {k: f"{desc} [{unit}]" if unit else desc for k, (desc, unit) in new_channels.items()}
        self.logger.add_columns(extra_headers)
        total_keys = set(CHANNELS.keys()) | set(self.dyn_info.keys()) | set(self.latest.keys())
        self.ch_count_lbl.setText(f"{len(total_keys)} canais ({len(self.latest)} ativos)")

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
                    state, note = "warn", "corr.-" if v < 0 else "corr.+"
            elif k == "ect":
                if v >= 108:
                    state, note = "alarm", "QUENTE"
                elif v < 70:
                    state, note = "warn", "frio"
            elif k == "battery":
                if v < 12.0 or v > 15.0:
                    state, note = "alarm", "baixa" if v < 12 else "alta"
                elif v < 13.2:
                    state, note = "warn", "s/carga"
            elif k == "lambda_v":
                state, note = self._lambda_state(now)
            elif k == "lambda2_v":
                state, note = self._lambda2_state(now)
            elif k == "advance" and v < -5:
                state, note = "warn", "retardo"
            card.set_state(state, note)

    def _lambda_state(self, now: float) -> Tuple[str, str]:
        t, v = self.buffers["lambda_v"].window(now - 4.0)
        rpm = self.latest.get("rpm", 0)
        ect = self.latest.get("ect") or self.latest.get("cht_temp")
        if len(v) < 4 or rpm < 650 or self.detector.in_decel:
            return "normal", ""
        if ect is not None and ect < 65:
            return "normal", "aberta"
        if float(np.ptp(v)) < 0.06:
            m = float(np.mean(v))
            return "alarm", "TRAV." + ("RICA" if m > 0.6 else "POBRE" if m < 0.3 else "")
        return "normal", ""

    def _lambda2_state(self, now: float) -> Tuple[str, str]:
        t, v2 = self.buffers["lambda2_v"].window(now - 6.0)
        rpm = self.latest.get("rpm", 0)
        ect = self.latest.get("ect") or self.latest.get("cht_temp")
        if len(v2) < 4 or rpm < 650 or self.detector.in_decel:
            return "normal", ""
        if ect is not None and ect < 65:
            return "normal", "aquec."
        ptp2 = float(np.ptp(v2))
        m2 = float(np.mean(v2))
        _, v1 = self.buffers["lambda_v"].window(now - 6.0)
        if len(v1) >= 4 and float(np.ptp(v1)) > 0.35 and ptp2 > 0.30:
            return "alarm", "CATAL.?"
        if m2 < 0.15:
            return "warn", "POBRE"
        return "normal", "CAT.OK"

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
                extra_headers: Dict[str, str] = {}
                for k, (label, unit) in DYNAMIC_INFO.items():
                    if k not in CHANNELS:
                        extra_headers[k] = f"{label} [{unit}]" if unit else label

                for k, (label, unit) in FORD_CHANNELS_INFO.items():
                    if k not in CHANNELS and k not in extra_headers:
                        extra_headers[k] = f"{label} [{unit}]" if unit else label

                try:
                    ecu_id = getattr(self.worker.strategy, "ecu_id", "") if self.worker else ""
                    cached = vag.load_cache(ecu_id or "032906032AJ")
                    for k, (label, unit) in cached.get("cells", {}).items():
                        if k not in CHANNELS and k not in extra_headers:
                            extra_headers[k] = f"{label} [{unit}]" if unit else label
                except Exception:
                    pass

                if self.worker and hasattr(self.worker, "strategy"):
                    for k, (label, unit) in self.worker.strategy.get_channels_info().items():
                        if k not in CHANNELS and k not in extra_headers:
                            extra_headers[k] = f"{label} [{unit}]" if unit else label

                for k, (label, unit) in self.dyn_info.items():
                    if k not in CHANNELS and k not in extra_headers:
                        extra_headers[k] = f"{label} [{unit}]" if unit else label

                for k in self.latest:
                    if k not in CHANNELS and k not in extra_headers:
                        extra_headers[k] = k

                self.logger.start(path, extra=extra_headers)
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
            self.rec_btn.setText("Gravar Log")

    # ============================================================ Replay & Análise CSV
    def _exit_replay_mode(self):
        self._replay_mode = False
        self.p1.set_replay_mode(False)
        self.p2.set_replay_mode(False)
        self.p3.set_replay_mode(False)
        self.crosshair_p1.setVisible(False)
        self.crosshair_p2.setVisible(False)
        self.crosshair_p3.setVisible(False)
        self.p1.clear_markers()
        self.p2.clear_markers()
        self.p3.clear_markers()
        self._clear_plots()

    def _open_csv_replay(self):
        path, _ = QFileDialog.getOpenFileName(self, "Abrir Log CSV para Replay e Análise", "logs", "CSV (*.csv)")
        if not path:
            return
        self._load_csv_file(path)

    def _replot_replay_curves(self):
        """Redesenha os canais selecionados nos 3 gráficos durante o modo Replay CSV."""
        if not self._replay_times or not self._replay_records:
            return
        for (p_idx, s_id), curve in self.slot_curves.items():
            key = self.slot_keys.get((p_idx, s_id), "")
            if not key:
                curve.setData([], [])
                continue
            ts = []
            vs = []
            for t_val, rec in zip(self._replay_times, self._replay_records):
                if key in rec:
                    ts.append(t_val)
                    vs.append(rec[key])
            curve.setData(ts, vs)

    def _load_csv_file(self, path: str):
        if self.connect_btn.isChecked():
            self.connect_btn.setChecked(False)
            self._toggle_connect(False)

        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                first_lines = [f.readline() for _ in range(5)]
                if not first_lines:
                    return
                delim = ";" if ";" in first_lines[0] else ","
                f.seek(0)
                reader = csv.reader(f, delimiter=delim)
                header = next(reader)
                rows = list(reader)
        except Exception as e:
            QMessageBox.critical(self, "Erro ao abrir CSV", f"Falha ao ler arquivo CSV:\n{e}")
            return

        if not rows:
            QMessageBox.warning(self, "CSV Vazio", "O arquivo selecionado não contém dados de telemetria.")
            return

        h_norm = [c.strip().lower() for c in header]
        t_col = -1
        for cand in ("tempo_s", "t_s", "time_s", "timestamp_s"):
            if cand in h_norm:
                t_col = h_norm.index(cand)
                break
        if t_col == -1 and len(h_norm) > 1:
            t_col = 1

        col_keys = {}
        for idx, col in enumerate(h_norm):
            clean_k = col.split("[")[0].split("(")[0].strip()
            if clean_k in CHANNELS:
                col_keys[idx] = clean_k
            elif "rpm" in clean_k:
                col_keys[idx] = "rpm"
            elif "map" in clean_k:
                col_keys[idx] = "map"
            elif "avanço" in clean_k or "adv" in clean_k:
                col_keys[idx] = "advance"
            elif "tps" in clean_k or "borboleta" in clean_k:
                col_keys[idx] = "tps"
            elif "sonda 1" in clean_k or clean_k == "lambda_v":
                col_keys[idx] = "lambda_v"
            elif "sonda 2" in clean_k or clean_k == "lambda2_v":
                col_keys[idx] = "lambda2_v"
            elif "stft" in clean_k:
                col_keys[idx] = "stft"
            elif "ltft" in clean_k:
                col_keys[idx] = "ltft"
            elif "ect" in clean_k:
                col_keys[idx] = "ect"
            elif "iat" in clean_k:
                col_keys[idx] = "iat"
            elif "carga" in clean_k or "load" in clean_k:
                col_keys[idx] = "load"
            elif "velocidade" in clean_k or "speed" in clean_k:
                col_keys[idx] = "speed"
            elif "bateria" in clean_k or "battery" in clean_k:
                col_keys[idx] = "battery"
            elif "injeção" in clean_k or "inj_ms" in clean_k:
                col_keys[idx] = "inj_ms"
            else:
                col_keys[idx] = clean_k

        self._clear_plots()
        self.map2d.clear_data()
        self._clear_all_peaks()
        self.detector.reset()

        self._replay_times.clear()
        self._replay_records.clear()

        self._replay_mode = True
        self.p1.set_replay_mode(True)
        self.p2.set_replay_mode(True)
        self.p3.set_replay_mode(True)
        self.crosshair_p1.setVisible(True)
        self.crosshair_p2.setVisible(True)
        self.crosshair_p3.setVisible(True)

        for row in rows:
            if not row or len(row) <= t_col:
                continue
            try:
                t_str = row[t_col].replace(",", ".")
                t_val = float(t_str)
            except ValueError:
                continue

            record = {}
            for col_idx, key in col_keys.items():
                if col_idx < len(row):
                    cell = row[col_idx].strip().replace(",", ".")
                    if cell:
                        try:
                            record[key] = float(cell)
                        except ValueError:
                            pass

            self._replay_times.append(t_val)
            self._replay_records.append(record)

            events = self.detector.update(t_val, record, {k: t_val for k in record})
            for e in events:
                self._add_event(e)
                if e.level == "alarm":
                    self.p1.add_marker(e.t, "#ff1744", label="Falha")
                    self.p2.add_marker(e.t, "#ff1744", label="Falha")
                    self.p3.add_marker(e.t, "#ff1744")

            if "rpm" in record and "map" in record:
                self.map2d.add_sample(record["rpm"], record["map"], record)

        self._replot_replay_curves()

        max_t = self._replay_times[-1] if self._replay_times else 30.0
        self.p1.pi.setXRange(0, max_t, padding=0.01)
        self.p2.pi.setXRange(0, max_t, padding=0.01)
        self.p3.pi.setXRange(0, max_t, padding=0.01)

        filename = os.path.basename(path)
        self.statusBar().showMessage(f"Replay CSV: {filename} carregado ({len(self._replay_records)} amostras, 0 a {max_t:.1f}s). Arraste o mouse sobre os gráficos.", 15000)
        self.status_lbl.setText(f"Replay: {filename}")
        self.status_lbl.setStyleSheet("color: #40c4ff; font-weight: bold;")
        self.tabs.setCurrentWidget(self.map2d)

        if self._replay_records:
            self._update_replay_cards(self._replay_times[0])

    def _on_plot_mouse_moved(self, pos):
        if not self._replay_mode or not self._replay_times:
            return
        mouse_point = self.p1.pi.vb.mapSceneToView(pos)
        t_cur = mouse_point.x()
        self.crosshair_p1.setPos(t_cur)
        self.crosshair_p2.setPos(t_cur)
        self.crosshair_p3.setPos(t_cur)
        self._update_replay_cards(t_cur)

    def _update_replay_cards(self, t_cur: float):
        if not self._replay_times:
            return
        idx = bisect_left(self._replay_times, t_cur)
        if idx >= len(self._replay_records):
            idx = len(self._replay_records) - 1
        elif idx > 0 and abs(self._replay_times[idx - 1] - t_cur) < abs(self._replay_times[idx] - t_cur):
            idx = idx - 1

        rec = self._replay_records[idx]
        actual_t = self._replay_times[idx]

        for k, card in self.cards.items():
            if k in rec:
                card.set_value(rec[k])
                card.set_state("normal")
            else:
                card.set_state("stale")

        if "rpm" in rec and "map" in rec:
            cur_key = self.map2d.metrics[self.map2d.cur_metric_idx][1]
            cur_fmt = self.map2d.metrics[self.map2d.cur_metric_idx][2]
            v_str = cur_fmt.format(rec[cur_key]) if cur_key in rec else "--"
            self.map2d.active_info.setText(f"Ponto: {rec['rpm']:.0f} RPM × {rec['map']:.0f} kPa | Valor: {v_str} (t={actual_t:.2f}s)")

        self.statusBar().showMessage(f"Replay CSV: t = {actual_t:.2f} s | Registro {idx + 1}/{len(self._replay_records)}")

    # ============================================================ DTC e Diagnóstico
    def _set_dtc_enabled(self, on: bool):
        self.dtc_read_btn.setEnabled(on)
        self.dtc_clear_btn.setEnabled(on)
        self.btn_reset_adaptation.setEnabled(on)
        self.scan_btn.setEnabled(on)

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

    def _reset_adaptation_dialog(self):
        r = QMessageBox.question(
            self,
            "Reset de Adaptação / Flex (Canal 00)",
            "Deseja enviar o comando de Reset de Adaptação (Canal 00 / Basic Settings)?\n\n"
            "Isso força a central Bosch ME7.5.30 a restaurar os parâmetros de fábrica de combustível "
            "e zerar as correções aprendidas da EEPROM (Blocos 032 e 103).\n\n"
            "Recomendado: motor aquecido (> 80 °C), ignição LIGADA e motor PARADO.\n"
            "Após o comando, desligue a ignição por 60 segundos antes de dar a partida.",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
        )
        if r == QMessageBox.StandardButton.Yes:
            self._request("reset_adaptation")

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
