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
from PyQt6.QtGui import QAction, QFont, QKeySequence, QShortcut
from PyQt6.QtWidgets import (QApplication, QCheckBox, QComboBox, QFileDialog, QFrame, QGridLayout, QGroupBox, QHBoxLayout,
                             QHeaderView, QLabel, QLineEdit, QMainWindow, QMessageBox, QPlainTextEdit,
                             QPushButton, QScrollArea, QSpinBox, QSplitter, QTableWidget, QTableWidgetItem, QTabWidget,
                             QVBoxLayout, QWidget)

from .. import ford
from ..ble_scan import BleScanWorker
from ..datalog import CsvLogger, SeriesBuffer
from ..detector import DecelDetector, Event
from ..pids import CHANNELS, DYNAMIC_INFO
from ..transports import BleTransport, MockTransport, TcpTransport
from ..worker import (PROFILE_FORD_KA, PROFILE_GENERIC, PROFILE_VW_GOL,
                      VEHICLE_PROFILES, ObdWorker)
from .plots import WINDOW_S, DualAxisPlot
from .style import COLORS, STYLE
from .widgets import ValueCard

MODE_BLE, MODE_WIFI, MODE_DEMO = 0, 1, 2
PLOTTED = ("rpm", "tps", "map", "lambda_v", "lambda2_v", "advance", "stft", "ltft")
STALE_S = 3.0
EVENT_COLORS = {"info": "#80d8ff", "warn": "#ffc107", "alarm": "#ff5252", "ok": "#69f0ae"}


class MainWindow(QMainWindow):
    def __init__(self, demo: bool = False):
        super().__init__()
        self.setWindowTitle("Datalogger OBD2 — Bosch ME7.5.30 (VW Gol G5 1.6 Flex)")

        # Ajuste adaptativo para caber 100% na tela 1920x1080 (mesmo com escala do Windows de 125% ou 150%)
        screen = QApplication.primaryScreen()
        if screen:
            avail = screen.availableGeometry()
            target_w = min(1460, max(1000, int(avail.width() * 0.95)))
            target_h = min(780, max(560, int(avail.height() * 0.92)))
            self.resize(target_w, target_h)
            self.move(avail.x() + (avail.width() - target_w) // 2,
                      avail.y() + (avail.height() - target_h) // 2)
        else:
            self.resize(1280, 720)

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
        # canais fora de CHANNELS (blocos VAG gGGG_cN, PIDs extras): {chave: (descrição, unidade)}
        self.dyn_info: Dict[str, Tuple[str, str]] = {}
        self._ch_rows: Dict[str, int] = {}

        self._build_ui()
        self._load_settings()
        if demo:
            self.mode.setCurrentIndex(MODE_DEMO)

        self.render_timer = QTimer(self)
        self.render_timer.setTimerType(Qt.TimerType.PreciseTimer)
        self.render_timer.timeout.connect(self._render)
        self.render_timer.start(33)  # ~30 FPS

    # ================================================================== UI
    def _build_ford_tab(self) -> QWidget:
        tab = QWidget()
        main_lay = QVBoxLayout(tab)
        main_lay.setContentsMargins(2, 2, 2, 2)
        main_lay.setSpacing(4)

        # Barra de Ação Superior
        top_box = QHBoxLayout()
        self.ford_scan_btn = QPushButton("🔎 Varrer todos os módulos Ford (PCM, BCM, ABS, IPC, PSCM)")
        self.ford_scan_btn.setToolTip("Consulta todos os DIDs dos módulos Ford na rede HS-CAN 500k e grava tudo no CSV.")
        self.ford_scan_btn.clicked.connect(lambda: self._request("scan_ford"))
        top_box.addWidget(self.ford_scan_btn)
        top_box.addStretch()
        self.ford_net_lbl = QLabel("Rede: HS-CAN 500 kbps (11-bit)")
        self.ford_net_lbl.setStyleSheet("color:#40c4ff; font-weight:bold; font-size:8.5pt;")
        top_box.addWidget(self.ford_net_lbl)
        main_lay.addLayout(top_box)

        # ScrollArea responsivo para os módulos
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        container = QWidget()
        lay = QVBoxLayout(container)
        lay.setContentsMargins(2, 2, 2, 2)
        lay.setSpacing(6)

        # 1. Carroceria & Conforto (BCM 726)
        bcm_box = QGroupBox("Módulo de Carroceria & Conforto (BCM / GEM - 0x726)")
        bcm_lay = QVBoxLayout(bcm_box)
        bcm_lay.setContentsMargins(6, 4, 6, 6)
        bcm_lay.setSpacing(4)

        bcm_lay.addWidget(QLabel("<b>Status de Portas e Aberturas:</b>"))
        doors_grid = QGridLayout()
        doors_grid.setSpacing(4)
        self.b_door_fl = QLabel("DE: Fechada")
        self.b_door_fr = QLabel("DD: Fechada")
        self.b_door_rl = QLabel("TE: Fechada")
        self.b_door_rr = QLabel("TD: Fechada")
        self.b_door_trunk = QLabel("Porta-Malas: Fechado")
        self.b_door_hood = QLabel("Capô: Fechado")
        self.b_central_lock = QLabel("Travas: Destrancadas")
        self.b_alarm = QLabel("Alarme PATS: Desarmado")

        for lbl in (self.b_door_fl, self.b_door_fr, self.b_door_rl, self.b_door_rr,
                    self.b_door_trunk, self.b_door_hood, self.b_central_lock, self.b_alarm):
            lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            lbl.setStyleSheet("background:#1f242b; color:#9aa4b2; padding:3px; border-radius:3px; font-size:8pt;")

        doors_grid.addWidget(self.b_door_fl, 0, 0)
        doors_grid.addWidget(self.b_door_fr, 0, 1)
        doors_grid.addWidget(self.b_door_rl, 1, 0)
        doors_grid.addWidget(self.b_door_rr, 1, 1)
        doors_grid.addWidget(self.b_door_trunk, 2, 0)
        doors_grid.addWidget(self.b_door_hood, 2, 1)
        doors_grid.addWidget(self.b_central_lock, 3, 0)
        doors_grid.addWidget(self.b_alarm, 3, 1)
        bcm_lay.addLayout(doors_grid)

        bcm_lay.addWidget(QLabel("<b>Iluminação & Acessórios Elétricos:</b>"))
        lights_grid = QGridLayout()
        lights_grid.setSpacing(4)
        self.b_low_beam = QLabel("Farol Baixo: OFF")
        self.b_high_beam = QLabel("Farol Alto: OFF")
        self.b_fog_lights = QLabel("Faróis Neblina: OFF")
        self.b_parking_lights = QLabel("Lanternas: OFF")
        self.b_wiper = QLabel("Limpadores: Desligado")
        self.b_defrost = QLabel("Desembaçador: OFF")
        self.b_ignition = QLabel("Ignição: —")
        self.b_bcm_bat = QLabel("Bateria BCM: — V")

        for lbl in (self.b_low_beam, self.b_high_beam, self.b_fog_lights, self.b_parking_lights,
                    self.b_wiper, self.b_defrost, self.b_ignition, self.b_bcm_bat):
            lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            lbl.setStyleSheet("background:#1f242b; color:#9aa4b2; padding:3px; border-radius:3px; font-size:8pt;")

        lights_grid.addWidget(self.b_low_beam, 0, 0)
        lights_grid.addWidget(self.b_high_beam, 0, 1)
        lights_grid.addWidget(self.b_fog_lights, 1, 0)
        lights_grid.addWidget(self.b_parking_lights, 1, 1)
        lights_grid.addWidget(self.b_wiper, 2, 0)
        lights_grid.addWidget(self.b_defrost, 2, 1)
        lights_grid.addWidget(self.b_ignition, 3, 0)
        lights_grid.addWidget(self.b_bcm_bat, 3, 1)
        bcm_lay.addLayout(lights_grid)
        lay.addWidget(bcm_box)

        # 2. Freios ABS, ESC & Assistente de Rampa (ABS 760)
        abs_box = QGroupBox("Freios ABS, Controle de Estabilidade (ESC) & HLA (0x760)")
        abs_lay = QVBoxLayout(abs_box)
        abs_lay.setContentsMargins(6, 4, 6, 6)
        abs_lay.setSpacing(4)
        abs_lay.addWidget(QLabel("<b>Velocidade Individual das 4 Rodas (km/h):</b>"))
        wheels_grid = QGridLayout()
        wheels_grid.setSpacing(4)
        self.f_wheel_fl = QLabel("Diant. Esq: -- km/h")
        self.f_wheel_fr = QLabel("Diant. Dir: -- km/h")
        self.f_wheel_rl = QLabel("Tras. Esq: -- km/h")
        self.f_wheel_rr = QLabel("Tras. Dir: -- km/h")
        for lbl in (self.f_wheel_fl, self.f_wheel_fr, self.f_wheel_rl, self.f_wheel_rr):
            lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            lbl.setStyleSheet("background:#1f242b; color:#80d8ff; font-weight:bold; padding:3px; border-radius:3px; font-size:8.5pt;")
        wheels_grid.addWidget(self.f_wheel_fl, 0, 0)
        wheels_grid.addWidget(self.f_wheel_fr, 0, 1)
        wheels_grid.addWidget(self.f_wheel_rl, 1, 0)
        wheels_grid.addWidget(self.f_wheel_rr, 1, 1)
        abs_lay.addLayout(wheels_grid)

        dyn_grid = QGridLayout()
        dyn_grid.setSpacing(4)
        self.f_brake_press = QLabel("Pressão Freio: -- bar")
        self.f_brake_sw = QLabel("Pedal Freio: Livre")
        self.f_sas_angle = QLabel("Sensor SAS: --°")
        self.f_esc_state = QLabel("Status ESC: Normal")
        for lbl in (self.f_brake_press, self.f_brake_sw, self.f_sas_angle, self.f_esc_state):
            lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
            lbl.setStyleSheet("background:#1f242b; color:#e0e0e0; padding:3px; border-radius:3px; font-size:8pt;")
        dyn_grid.addWidget(self.f_brake_press, 0, 0)
        dyn_grid.addWidget(self.f_brake_sw, 0, 1)
        dyn_grid.addWidget(self.f_sas_angle, 1, 0)
        dyn_grid.addWidget(self.f_esc_state, 1, 1)
        abs_lay.addLayout(dyn_grid)
        lay.addWidget(abs_box)

        # 3. Motor Ford Sigma 1.5 16V Flex DOHC (PCM 7E0 - Comandos Fixos, sem VVT)
        pcm_box = QGroupBox("Motor Sigma 1.5 16V Flex DOHC (PCM - 0x7E0)")
        pcm_lay = QGridLayout(pcm_box)
        pcm_lay.setContentsMargins(6, 4, 6, 6)
        pcm_lay.setSpacing(4)

        self.f_sonda1 = QLabel("Sonda 1 (Pré-Cat): -- V")
        self.f_sonda2 = QLabel("Sonda 2 (Pós-Cat): -- V")
        self.f_cat_diag = QLabel("Catalisador: --")
        self.f_fuel_sys = QLabel("Injeção: --")
        self.f_cat_temp = QLabel("Temp. Catalisador: -- °C")
        self.f_iat = QLabel("Temp. Ar (IAT): -- °C")
        self.f_cht = QLabel("Temp. Cabeça Cilindro (CHT): -- °C")
        self.f_fan_duty = QLabel("Ventoinha Radiador: -- %")
        self.f_app_pedal = QLabel("Pedal Acelerador (APP): -- %")
        self.f_inj_pw = QLabel("Tempo de Injeção: -- ms")
        self.f_flex_eth = QLabel("Teor Etanol Tanque: -- %")
        self.f_baro = QLabel("Pressão Baro: -- kPa")
        self.f_ac_press = QLabel("Pressão A/C: -- kPa")
        self.f_ac_clutch = QLabel("Compressor A/C: --")

        pcm_labels = (
            self.f_sonda1, self.f_sonda2, self.f_cat_diag, self.f_fuel_sys,
            self.f_cat_temp, self.f_iat, self.f_cht, self.f_fan_duty,
            self.f_app_pedal, self.f_inj_pw, self.f_flex_eth, self.f_baro,
            self.f_ac_press, self.f_ac_clutch
        )
        for lbl in pcm_labels:
            lbl.setStyleSheet("background:#1f242b; color:#e0e0e0; padding:3px; border-radius:3px; font-size:8pt;")

        pcm_lay.addWidget(self.f_sonda1, 0, 0)
        pcm_lay.addWidget(self.f_sonda2, 0, 1)
        pcm_lay.addWidget(self.f_cat_diag, 1, 0)
        pcm_lay.addWidget(self.f_fuel_sys, 1, 1)
        pcm_lay.addWidget(self.f_cat_temp, 2, 0)
        pcm_lay.addWidget(self.f_iat, 2, 1)
        pcm_lay.addWidget(self.f_cht, 3, 0)
        pcm_lay.addWidget(self.f_fan_duty, 3, 1)
        pcm_lay.addWidget(self.f_app_pedal, 4, 0)
        pcm_lay.addWidget(self.f_inj_pw, 4, 1)
        pcm_lay.addWidget(self.f_flex_eth, 5, 0)
        pcm_lay.addWidget(self.f_baro, 5, 1)
        pcm_lay.addWidget(self.f_ac_press, 6, 0)
        pcm_lay.addWidget(self.f_ac_clutch, 6, 1)
        lay.addWidget(pcm_box)

        # 4. Painel de Instrumentos (IPC 720) & Direção Elétrica (PSCM 730)
        dash_box = QGroupBox("Painel de Instrumentos (IPC) & Direção Elétrica EPAS (PSCM)")
        dash_lay = QGridLayout(dash_box)
        dash_lay.setContentsMargins(6, 4, 6, 6)
        dash_lay.setSpacing(4)
        self.f_odometer = QLabel("Odômetro: -- km")
        self.f_fuel_pct = QLabel("Combustível: -- %")
        self.f_ext_temp = QLabel("Temp. Externa: -- °C")
        self.f_parking_brake = QLabel("Freio de Mão: --")
        self.f_seatbelt = QLabel("Cinto Segurança: --")
        self.f_epas_angle = QLabel("Ângulo Volante: --°")
        self.f_epas_torque = QLabel("Torque Direção: -- Nm")
        self.f_epas_current = QLabel("Corrente Direção: -- A")
        for lbl in (self.f_odometer, self.f_fuel_pct, self.f_ext_temp, self.f_parking_brake,
                    self.f_seatbelt, self.f_epas_angle, self.f_epas_torque, self.f_epas_current):
            lbl.setStyleSheet("background:#1f242b; color:#e0e0e0; padding:3px; border-radius:3px; font-size:8pt;")
        dash_lay.addWidget(self.f_odometer, 0, 0)
        dash_lay.addWidget(self.f_fuel_pct, 0, 1)
        dash_lay.addWidget(self.f_ext_temp, 1, 0)
        dash_lay.addWidget(self.f_parking_brake, 1, 1)
        dash_lay.addWidget(self.f_seatbelt, 2, 0)
        dash_lay.addWidget(self.f_epas_angle, 2, 1)
        dash_lay.addWidget(self.f_epas_torque, 3, 0)
        dash_lay.addWidget(self.f_epas_current, 3, 1)
        lay.addWidget(dash_box)

        lay.addStretch()
        scroll.setWidget(container)
        main_lay.addWidget(scroll, 1)
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
            lbl.setStyleSheet(f"background:{bg}; color:{color}; font-weight:bold; padding:3px; border-radius:3px; border:1px solid {border}; font-size:8pt;")

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
            _badge(self.b_door_trunk, latest["door_trunk"] > 0.5, "Porta-Malas: ABERTO", "Porta-Malas: Fechado", on_color="#ff5252", on_bg="#3d1418")
        if "door_hood" in latest:
            _badge(self.b_door_hood, latest["door_hood"] > 0.5, "Capô: ABERTO", "Capô: Fechado", on_color="#ff5252", on_bg="#3d1418")
        if "central_lock" in latest:
            _badge(self.b_central_lock, latest["central_lock"] > 0.5, "Travas: TRANCADAS", "Travas: Destrancadas", on_color="#ffab40", on_bg="#3a3214")
        if "alarm_armed" in latest:
            _badge(self.b_alarm, latest["alarm_armed"] > 0.5, "Alarme: ARMADO", "Alarme: Desarmado", on_color="#69f0ae", on_bg="#1b5e20")

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
            wp_map = {0: "Desligado", 1: "Intermitente", 2: "Vel. Baixa", 3: "Vel. Alta"}
            self.b_wiper.setText(f"Limpador: {wp_map.get(int(latest['wiper_status']), 'Ativo')}")
        if "rear_defrost" in latest:
            _badge(self.b_defrost, latest["rear_defrost"] > 0.5, "Desembaçador: ON", "Desembaçador: OFF", on_color="#ffab40", on_bg="#3a3214")
        if "ignition_pos" in latest:
            ig_map = {0: "Desligada", 1: "Acessório", 2: "Ligada (Run)", 3: "Partida (Crank)"}
            self.b_ignition.setText(f"Ignição: {ig_map.get(int(latest['ignition_pos']), str(int(latest['ignition_pos'])))}")
        if "bcm_battery_v" in latest:
            self.b_bcm_bat.setText(f"Bateria BCM: {latest['bcm_battery_v']:.2f} V")

        # ABS Rodas e Dinâmica
        if "wheel_speed_fl" in latest:
            self.f_wheel_fl.setText(f"Diant. Esq: {latest['wheel_speed_fl']:.1f} km/h")
        if "wheel_speed_fr" in latest:
            self.f_wheel_fr.setText(f"Diant. Dir: {latest['wheel_speed_fr']:.1f} km/h")
        if "wheel_speed_rl" in latest:
            self.f_wheel_rl.setText(f"Tras. Esq: {latest['wheel_speed_rl']:.1f} km/h")
        if "wheel_speed_rr" in latest:
            self.f_wheel_rr.setText(f"Tras. Dir: {latest['wheel_speed_rr']:.1f} km/h")
        if "brake_pressure" in latest:
            self.f_brake_press.setText(f"Pressão Freio: {latest['brake_pressure']:.1f} bar")
        if "brake_pedal_sw" in latest:
            self.f_brake_sw.setText("Pedal Freio: PRESSIONADO" if latest["brake_pedal_sw"] > 0.5 else "Pedal Freio: Livre")
        if "steering_angle_abs" in latest:
            self.f_sas_angle.setText(f"Sensor SAS: {latest['steering_angle_abs']:.1f}°")
        if "esc_active" in latest:
            self.f_esc_state.setText("ESC/HLA: INTERVINDO!" if latest["esc_active"] > 0.5 else "Status ESC: Normal")

        # PCM Motor Sigma 1.5 DOHC (comandos fixos, sem VVT)
        s1 = latest.get("lambda_v")
        if s1 is not None:
            self.f_sonda1.setText(f"Sonda 1 (Pré-Cat): {s1:.3f} V")
        s2 = latest.get("lambda2_v")
        if s2 is not None:
            self.f_sonda2.setText(f"Sonda 2 (Pós-Cat): {s2:.3f} V")

        # Avaliação do Catalisador (Sonda 1 vs Sonda 2)
        if s1 is not None and s2 is not None:
            temp_ref = latest.get("cht_temp") or latest.get("ect") or 0.0
            if temp_ref < 60.0:
                self.f_cat_diag.setText("Catalisador: AQUECENDO...")
                self.f_cat_diag.setStyleSheet("background:#1a2b3c; color:#80d8ff; padding:3px; border-radius:3px; font-size:8pt;")
            elif 0.50 <= s2 <= 0.82:
                self.f_cat_diag.setText("Catalisador: SAUDÁVEL (Eficiente)")
                self.f_cat_diag.setStyleSheet("background:#143820; color:#69f0ae; padding:3px; border-radius:3px; font-size:8pt; font-weight:bold;")
            elif s2 < 0.20:
                self.f_cat_diag.setText("Catalisador: MISTURA POBRE / AR")
                self.f_cat_diag.setStyleSheet("background:#3a2010; color:#ffab40; padding:3px; border-radius:3px; font-size:8pt;")
            else:
                self.f_cat_diag.setText("Catalisador: MONITORANDO...")
                self.f_cat_diag.setStyleSheet("background:#1f242b; color:#e0e0e0; padding:3px; border-radius:3px; font-size:8pt;")

        # Status do Sistema de Injeção (Malha Aberta / Fechada)
        fs = latest.get("fuel_sys1")
        if fs is not None:
            fs_int = int(fs)
            if fs_int == 2:
                self.f_fuel_sys.setText("Injeção: Malha Fechada (CL)")
            elif fs_int == 1:
                self.f_fuel_sys.setText("Injeção: Malha Aberta (Frio)")
            elif fs_int == 4:
                self.f_fuel_sys.setText("Injeção: Malha Aberta (WOT)")
            elif fs_int == 8:
                self.f_fuel_sys.setText("Injeção: Malha Aberta (Falha)")
            elif fs_int == 16:
                self.f_fuel_sys.setText("Injeção: CL c/ Falha Sensor")
            else:
                self.f_fuel_sys.setText(f"Injeção: Status {fs_int}")

        if "cat_temp" in latest:
            self.f_cat_temp.setText(f"Temp. Catalisador: {latest['cat_temp']:.0f} °C")
        if "iat" in latest:
            self.f_iat.setText(f"Temp. Ar (IAT): {latest['iat']:.0f} °C")
        if "cht_temp" in latest:
            self.f_cht.setText(f"Temp. Cabeça Cilindro (CHT): {latest['cht_temp']:.0f} °C")
        if "app_pedal_pct" in latest:
            self.f_app_pedal.setText(f"Pedal Acelerador (APP): {latest['app_pedal_pct']:.1f} %")
        if "fan_duty_pct" in latest:
            self.f_fan_duty.setText(f"Ventoinha Radiador: {latest['fan_duty_pct']:.0f} %")
        if "inj_pulse_width" in latest:
            self.f_inj_pw.setText(f"Tempo de Injeção: {latest['inj_pulse_width']:.2f} ms")
        if "baro" in latest:
            self.f_baro.setText(f"Pressão Baro: {latest['baro']:.0f} kPa")
        if "ac_pressure_kpa" in latest:
            self.f_ac_press.setText(f"Pressão A/C: {latest['ac_pressure_kpa']:.0f} kPa")
        if "ac_clutch" in latest:
            self.f_ac_clutch.setText("Compressor A/C: Ligado" if latest["ac_clutch"] > 0.5 else "Compressor A/C: Desligado")
        if "flex_ethanol_pct" in latest:
            self.f_flex_eth.setText(f"Teor Etanol Tanque: {latest['flex_ethanol_pct']:.0f} %")

        # IPC & PSCM
        if "odometer_km" in latest:
            self.f_odometer.setText(f"Odômetro: {latest['odometer_km']:,.0f} km".replace(",", "."))
        if "fuel_level_pct" in latest:
            self.f_fuel_pct.setText(f"Combustível: {latest['fuel_level_pct']:.1f} %")
        if "ext_temp" in latest:
            self.f_ext_temp.setText(f"Temp. Externa: {latest['ext_temp']:.1f} °C")
        if "parking_brake" in latest:
            self.f_parking_brake.setText("Freio de Mão: PUXADO" if latest["parking_brake"] > 0.5 else "Freio de Mão: Livre")
        if "seatbelt_warning" in latest:
            self.f_seatbelt.setText("Cinto: DESAFIVELADO" if latest["seatbelt_warning"] > 0.5 else "Cinto: Afivelado")
        if "steering_wheel_angle" in latest:
            self.f_epas_angle.setText(f"Ângulo Volante: {latest['steering_wheel_angle']:.1f}°")
        if "steering_driver_torque" in latest:
            self.f_epas_torque.setText(f"Torque Volante: {latest['steering_driver_torque']:.2f} Nm")
        if "steering_motor_current" in latest:
            self.f_epas_current.setText(f"Corrente Direção: {latest['steering_motor_current']:.1f} A")

    def _vehicle_changed(self, idx: int):
        titles = {
            0: "Datalogger OBD2 — Bosch ME7.5.30 (VW Gol G5 1.6 Flex)",
            1: "Datalogger OBD2 — Ford Ka+ 2016 SEL 1.5 Sigma Flex (HS-CAN / Conforto BCM)",
            2: "Datalogger OBD2 Universal",
        }
        self.setWindowTitle(titles.get(idx, "Datalogger OBD2"))
        if hasattr(self, "tabs") and hasattr(self, "ford_tab"):
            if idx == 1:
                self.tabs.setCurrentWidget(self.ford_tab)
            elif idx == 0:
                self.tabs.setCurrentWidget(self.ch_tab)

    def _build_ui(self):
        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(6, 4, 6, 4)
        root.setSpacing(4)
        self.setCentralWidget(central)

        # ---------------- conexão
        conn = QGroupBox("Conexão ELM327")
        cl = QHBoxLayout(conn)
        cl.setContentsMargins(6, 2, 6, 2)
        cl.setSpacing(6)

        self.vehicle_cb = QComboBox()
        self.vehicle_cb.addItems([
            "VW Gol G5 1.6 Flex (ME7.5.30)",
            "Ford Ka+ 2016 SEL 1.5 Sigma (HS-CAN)",
            "OBD2 Genérico / Automático",
        ])
        self.vehicle_cb.currentIndexChanged.connect(self._vehicle_changed)
        cl.addWidget(QLabel("Veículo:"))
        cl.addWidget(self.vehicle_cb)

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
        self.ble_dev.setMinimumWidth(180)
        self.ble_dev.lineEdit().setPlaceholderText("Clique em Procurar ou digite o endereço")
        self.ble_scan_btn = QPushButton("🔍 Procurar BLE")
        self.ble_scan_btn.clicked.connect(self._scan_ble)
        bl.addWidget(QLabel("Adaptador:"))
        bl.addWidget(self.ble_dev)
        bl.addWidget(self.ble_scan_btn)
        cl.addWidget(self.ble_box)

        self.connect_btn = QPushButton("Conectar", objectName="connect")
        self.connect_btn.setCheckable(True)
        self.connect_btn.setMinimumWidth(95)
        self.connect_btn.clicked.connect(self._toggle_connect)
        cl.addWidget(self.connect_btn)
        self.status_lbl = QLabel("Desconectado")
        self.status_lbl.setStyleSheet("color:#9aa4b2;")
        cl.addWidget(self.status_lbl, 1)
        root.addWidget(conn)

        # ---------------- controles
        ctl = QHBoxLayout()
        ctl.setContentsMargins(0, 0, 0, 0)
        ctl.setSpacing(6)
        self.decel_btn = QPushButton("⚡ Desaceleração", objectName="decel")
        self.decel_btn.setCheckable(True)
        self.decel_btn.setMinimumWidth(110)
        self.decel_btn.setToolTip("Lê apenas RPM, MAP, Avanço, TPS e Sonda (pausa ECT/STFT/LTFT)\n"
                                  "para aumentar a taxa de amostragem e capturar Cut-Off / Dashpot.")
        self.decel_btn.toggled.connect(self._decel_toggled)
        self.rec_btn = QPushButton("⏺ Gravar Log")
        self.rec_btn.setCheckable(True)
        self.rec_btn.toggled.connect(self._toggle_record)
        self.freeze_btn = QPushButton("⏸ Congelar")
        self.freeze_btn.setCheckable(True)
        clear_btn = QPushButton("Limpar")
        clear_btn.clicked.connect(self._clear_plots)
        self.extras_chk = QCheckBox("Todos os PIDs")
        self.extras_chk.setToolTip("Lê todos os PIDs da central (carga, velocidade, IAT, malha fechada, bateria)")
        self.extras_chk.setChecked(True)
        self.extras_chk.toggled.connect(self._apply_worker_flags)
        self.fast_chk = QCheckBox("Resposta rápida")
        self.fast_chk.setToolTip("Envia '010C1' em vez de '010C': o ELM327 não espera timeout após a resposta.\n"
                                 "Aumenta bastante a taxa; desative se o adaptador responder '?' ou NO DATA.")
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
        self.cadence_cb.setToolTip(
            "Controla a frequência de pacotes na Linha K.\n"
            "No Gol G5, a Linha K passa no chicote do som/painel e pode induzir um 'tic-tic-tic' (~5 Hz) no tweeter.\n"
            "Use 'Pausar Linha K' ou 'Suave' quando estiver parado e 'Máxima' quando for gravar o teste."
        )
        self.cadence_cb.currentIndexChanged.connect(self._apply_worker_flags)
        for w in (self.decel_btn, self.rec_btn, self.freeze_btn, clear_btn):
            ctl.addWidget(w)
        ctl.addSpacing(6)
        for w in (self.cadence_cb, self.extras_chk, self.fast_chk, self.raw_chk):
            ctl.addWidget(w)
        ctl.addStretch()
        self.rate_lbl = QLabel("0.0 resp/s | 0.0 ciclos/s")
        self.rate_lbl.setFont(QFont("Consolas", 10, QFont.Weight.Bold))
        self.rate_lbl.setStyleSheet("color:#40c4ff;")
        ctl.addWidget(self.rate_lbl)
        root.addLayout(ctl)

        # ---------------- cards
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
            "battery": "Tensão da bateria e alternador (V)\nIdeal com motor ligado: 13,8 V a 14,4 V.",
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
            "lambda_v": self.p2.add_curve("Sonda 1 (Pré)", COLORS["lambda_v"], width=2),
            "lambda2_v": self.p2.add_curve("Sonda 2 (Pós)", COLORS["lambda2_v"], width=1.8),
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
        # Ford Ka+ (Módulos & Conforto)
        self.ford_tab = self._build_ford_tab()
        tabs.addTab(self.ford_tab, "🚗 Ford Ka+ (Conforto & Módulos)")
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
        # todos os canais (tudo o que a central enviou, inclusive blocos VAG genéricos)
        self.ch_tab = QWidget()
        chl = QVBoxLayout(self.ch_tab)
        chl.setContentsMargins(4, 4, 4, 4)
        chb = QHBoxLayout()
        self.scan_btn = QPushButton("🔎 Varrer todos os blocos VAG (~1–2 min)")
        self.scan_btn.setToolTip("Lê os blocos de medição 001..255 da central (modo VAG KWP2000) e passa a gravar\n"
                                 "todos os campos encontrados no CSV. O resultado fica em cache para as próximas conexões.")
        self.scan_btn.clicked.connect(lambda: self._request("scan_vag"))
        self.ch_count_lbl = QLabel("0 canais")
        chb.addWidget(self.scan_btn)
        chb.addStretch()
        chb.addWidget(self.ch_count_lbl)
        chl.addLayout(chb)

        # Barra de busca/filtro instantâneo de canais (UX Design)
        self.ch_search = QLineEdit()
        self.ch_search.setPlaceholderText("🔍 Filtrar canais por nome, código ou descrição...")
        self.ch_search.setClearButtonEnabled(True)
        self.ch_search.textChanged.connect(self._filter_channels_table)
        chl.addWidget(self.ch_search)
        self.ch_table = QTableWidget(0, 4)
        self.ch_table.setHorizontalHeaderLabels(["Canal", "Descrição", "Valor", "Idade (s)"])
        self.ch_table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self.ch_table.setColumnWidth(0, 65)
        self.ch_table.setColumnWidth(2, 75)
        self.ch_table.setColumnWidth(3, 60)
        self.ch_table.verticalHeader().setVisible(False)
        self.ch_table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        chl.addWidget(self.ch_table, 1)
        tabs.addTab(self.ch_tab, "Todos os Canais")
        self.tabs = tabs
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
        split.setSizes([int(self.width() * 0.70), int(self.width() * 0.30)])
        split.setChildrenCollapsible(False)
        root.addWidget(split, 1)

        self.statusBar().showMessage("Pronto. Escolha o modo de conexão e clique em Conectar.")
        quit_act = QAction("Sair", self)
        quit_act.setShortcut("Ctrl+Q")
        quit_act.triggered.connect(self.close)
        self.addAction(quit_act)

        # Atalhos de teclado ergonômicos (UX Design Guidelines)
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
            transport._log = self.worker.log.emit  # sinal Qt: seguro entre threads
        self.worker.sample.connect(self._on_sample)
        self.worker.status.connect(self._on_status)
        self.worker.log.connect(self.console.appendPlainText)
        self.worker.rate.connect(self._on_rate)
        self.worker.dtc_result.connect(self._on_dtc)
        self.worker.info.connect(self._on_info)
        self.worker.channels.connect(self._on_channels)
        self.worker.finished.connect(self._worker_finished)
        self._apply_worker_flags()
        self.worker.decel_mode = self.decel_btn.isChecked()
        self.vehicle_cb.setEnabled(False)
        self.mode.setEnabled(False)
        self.wifi_box.setEnabled(False)
        self.ble_box.setEnabled(False)
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
        if self.frame % 3 == 0:
            self._update_ford_ui()
        if self.frame % 6 == 0:
            self._update_card_states(now)
            if self.logger.active:
                self.rec_btn.setText(f"⏹ Gravando ({self.logger.rows} linhas)")
        if self.frame % 15 == 0:
            self._update_channels_table(now)

    def _update_channels_table(self, now: float):
        # Atualiza a tabela com todos os canais conhecidos recebidos até o momento
        all_keys = list(CHANNELS.keys()) + [k for k in self.latest if k not in CHANNELS]
        total_keys = set(all_keys) | set(self.dyn_info.keys())
        self.ch_count_lbl.setText(f"{len(total_keys)} canais conhecidos ({len(self.latest)} ativos)")

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

        # Se houver filtro ativo, aplica às linhas atualizadas
        if hasattr(self, "ch_search") and self.ch_search.text().strip():
            self._filter_channels_table(self.ch_search.text())

    def _filter_channels_table(self, query: str):
        """Filtra as linhas da tabela de canais em tempo real (UX)."""
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
        self.ch_count_lbl.setText(f"{len(total_keys)} canais conhecidos ({len(self.latest)} ativos)")

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
            elif k == "lambda2_v":
                state, note = self._lambda2_state(now)
            elif k == "advance" and v < -5:
                state, note = "warn", "retardado"
            card.set_state(state, note)

    def _lambda_state(self, now: float) -> Tuple[str, str]:
        t, v = self.buffers["lambda_v"].window(now - 4.0)
        rpm = self.latest.get("rpm", 0)
        ect = self.latest.get("ect") or self.latest.get("cht_temp")
        if len(v) < 4 or rpm < 650 or self.detector.in_decel:
            return "normal", ""
        if ect is not None and ect < 65:
            return "normal", "malha aberta"
        if float(np.ptp(v)) < 0.06:
            m = float(np.mean(v))
            return "alarm", "TRAVADA " + ("RICA" if m > 0.6 else "POBRE" if m < 0.3 else "")
        return "normal", ""

    def _lambda2_state(self, now: float) -> Tuple[str, str]:
        t, v2 = self.buffers["lambda2_v"].window(now - 6.0)
        rpm = self.latest.get("rpm", 0)
        ect = self.latest.get("ect") or self.latest.get("cht_temp")
        if len(v2) < 4 or rpm < 650 or self.detector.in_decel:
            return "normal", ""
        if ect is not None and ect < 65:
            return "normal", "aquecendo"
        ptp2 = float(np.ptp(v2))
        m2 = float(np.mean(v2))
        _, v1 = self.buffers["lambda_v"].window(now - 6.0)
        if len(v1) >= 4 and float(np.ptp(v1)) > 0.35 and ptp2 > 0.30:
            return "alarm", "CATALISADOR?"
        if m2 < 0.15:
            return "warn", "POBRE/AR"
        return "normal", "CATAL. OK"

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
                extra_headers = {}
                for k in self.latest:
                    if k not in CHANNELS:
                        if k in self.dyn_info:
                            label, unit = self.dyn_info[k]
                            extra_headers[k] = f"{label} [{unit}]" if unit else label
                        elif k in DYNAMIC_INFO:
                            label, unit = DYNAMIC_INFO[k]
                            extra_headers[k] = f"{label} [{unit}]" if unit else label
                        else:
                            extra_headers[k] = k
                for k, (label, unit) in self.dyn_info.items():
                    if k not in CHANNELS and k not in extra_headers:
                        extra_headers[k] = f"{label} [{unit}]" if unit else label
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
            self.rec_btn.setText("⏺ Gravar Log")

    # ============================================================ DTC e Diagnóstico
    def _set_dtc_enabled(self, on: bool):
        self.dtc_read_btn.setEnabled(on)
        self.dtc_clear_btn.setEnabled(on)
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
