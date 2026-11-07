"""Janela principal: conexão, cards, gráficos sincronizados, eventos, DTCs e gravação CSV."""
from __future__ import annotations

import csv
import html
import os
import time
from bisect import bisect_left
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

import numpy as np
import pyqtgraph as pg
from PyQt6.QtCore import QSettings, Qt, QThread, QTimer
from PyQt6.QtGui import QAction, QFont, QKeySequence, QShortcut
from PyQt6.QtWidgets import (QApplication, QCheckBox, QComboBox, QDialog, QFileDialog, QFrame, QGridLayout, QGroupBox, QHBoxLayout,
                             QHeaderView, QLabel, QLineEdit, QMainWindow, QMessageBox, QPlainTextEdit,
                             QPushButton, QScrollArea, QSpinBox, QSplitter, QTableWidget, QTableWidgetItem, QTabWidget,
                             QVBoxLayout, QWidget)

from .. import ford, vag
from ..audio_alerts import AudioAlertManager
from ..ble_scan import BleScanWorker
from ..datalog import CsvLogger, SeriesBuffer
from ..detector import DecelDetector, Event
from ..ford import FORD_CHANNELS_INFO
from ..pids import CHANNELS, DYNAMIC_INFO
from ..readiness import FreezeFrame, ReadinessReport
from ..report_generator import export_report_to_pdf, generate_html_report
from ..transports import BleTransport, KklSerialTransport, MockTransport, TcpTransport
from ..worker import PROFILE_AUTO, ObdWorker
from .map2d import Map2DWidget
from .plots import WINDOW_S, DualAxisPlot
from .style import COLORS, STYLE
from .widgets import ValueCard

MODE_BLE, MODE_WIFI, MODE_SERIAL, MODE_DEMO = 0, 1, 2, 3
PLOTTED = ("rpm", "tps", "map", "lambda_v", "lambda2_v", "advance", "stft", "ltft", "battery")
STALE_S = 3.0
EVENT_COLORS = {"info": "#80d8ff", "warn": "#ffc107", "alarm": "#ff5252", "ok": "#69f0ae"}


class MainWindow(QMainWindow):
    def __init__(self, demo: bool = False):
        super().__init__()
        self.setWindowTitle("leitorECU — Scanner & Datalogger Universal")

        # Ajuste adaptativo para caber 100% na tela 1920x1080 (mesmo com escala do Windows de 125% ou 150%)
        screen = QApplication.primaryScreen()
        if screen:
            avail = screen.availableGeometry()
            target_w = min(1920, max(1180, int(avail.width() * 0.98)))
            target_h = min(1080, max(760, int(avail.height() * 0.96)))
            self.resize(target_w, target_h)
            self.move(avail.x() + (avail.width() - target_w) // 2,
                      avail.y() + (avail.height() - target_h) // 2)
        else:
            self.resize(1440, 900)

        self.setStyleSheet(STYLE)
        pg.setConfigOptions(antialias=True, foreground="#8B98AB")

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
        self._replay_mode = False
        self._replay_times: List[float] = []
        self._replay_records: List[Dict[str, float]] = []
        # canais fora de CHANNELS (blocos VAG gGGG_cN, PIDs extras): {chave: (descrição, unidade)}
        self.dyn_info: Dict[str, Tuple[str, str]] = {}
        self._ch_rows: Dict[str, int] = {}

        self.audio_alerts = AudioAlertManager(shift_rpm=6000.0, max_ect_c=105.0)
        self.last_readiness: Optional[ReadinessReport] = None
        self.last_freeze_frame: Optional[FreezeFrame] = None
        self.last_ecu_meta: Dict[str, Any] = {}
        self.power_peak: float = 0.0
        self.torque_peak: float = 0.0
        self.last_battery_test: str = "Tensão estável dentro dos padrões operacionais"

        self._build_ui()
        self._load_settings()
        if demo:
            self.mode.setCurrentIndex(MODE_DEMO)

        self.render_timer = QTimer(self)
        self.render_timer.setTimerType(Qt.TimerType.PreciseTimer)
        self.render_timer.timeout.connect(self._render)
        self.render_timer.start(33)  # ~30 FPS

    # ================================================================== UI
    def _build_functions_tab(self) -> QWidget:
        """Funções descobertas por módulo, independentes do perfil do veículo."""
        tab = QWidget()
        root = QVBoxLayout(tab)
        root.setContentsMargins(5, 5, 5, 5)
        root.setSpacing(5)

        header = QHBoxLayout()
        self.functions_scan_btn = QPushButton("Identificar módulos")
        self.functions_scan_btn.setToolTip(
            "Executa a varredura suportada pela estratégia ativa e organiza as funções encontradas por módulo."
        )
        self.functions_scan_btn.clicked.connect(self._scan_vehicle_functions)
        self.ford_scan_btn = self.functions_scan_btn  # compatibilidade interna
        header.addWidget(self.functions_scan_btn)
        header.addStretch()
        self.functions_summary = QLabel("Nenhum módulo identificado")
        self.functions_summary.setObjectName("moduleSummary")
        self.ford_net_lbl = self.functions_summary
        header.addWidget(self.functions_summary)
        root.addLayout(header)

        self.functions_empty = QFrame(objectName="emptyState")
        empty_lay = QVBoxLayout(self.functions_empty)
        empty_lay.setContentsMargins(24, 24, 24, 24)
        empty_lay.addStretch()
        empty_title = QLabel("Aguardando identificação dos módulos")
        empty_title.setObjectName("emptyStateTitle")
        empty_title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        empty_body = QLabel(
            "Conecte ao veículo e use “Identificar módulos”.\n"
            "As funções disponíveis serão agrupadas conforme as respostas da ECU e da rede."
        )
        empty_body.setObjectName("emptyStateBody")
        empty_body.setAlignment(Qt.AlignmentFlag.AlignCenter)
        empty_lay.addWidget(empty_title)
        empty_lay.addWidget(empty_body)
        empty_lay.addStretch()
        root.addWidget(self.functions_empty, 1)

        grid = QGridLayout()
        grid.setContentsMargins(0, 0, 0, 0)
        grid.setHorizontalSpacing(5)
        grid.setVerticalSpacing(5)

        def module_box(title: str, labels: list[QLabel], columns: int = 2) -> QGroupBox:
            box = QGroupBox(title)
            lay = QGridLayout(box)
            lay.setContentsMargins(5, 5, 5, 5)
            lay.setSpacing(3)
            for i, label in enumerate(labels):
                label.setObjectName("moduleMetric")
                label.setAlignment(Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft)
                lay.addWidget(label, i // columns, i % columns)
            return box

        # PCM
        self.f_sonda1 = QLabel("Sonda 1 Pré-Cat   -- V")
        self.f_sonda2 = QLabel("Sonda 2 Pós-Cat  -- V")
        self.f_cat_diag = QLabel("Catalisador      --")
        self.f_fuel_sys = QLabel("Malha injeção    --")
        self.f_cat_temp = QLabel("Catalisador      -- °C")
        self.f_iat = QLabel("Ar admissão      -- °C")
        self.f_cht = QLabel("Cabeçote CHT     -- °C")
        self.f_fan_duty = QLabel("Ventoinha        -- %")
        self.f_app_pedal = QLabel("Pedal APP        -- %")
        self.f_inj_pw = QLabel("Pulso injeção    -- ms")
        self.f_flex_eth = QLabel("Etanol flex      -- %")
        self.f_baro = QLabel("Barométrica      -- kPa")
        self.f_ac_press = QLabel("Pressão A/C      -- kPa")
        self.f_ac_clutch = QLabel("Compressor A/C   --")
        pcm_labels = [self.f_sonda1, self.f_sonda2, self.f_cat_diag, self.f_fuel_sys,
                      self.f_cht, self.f_fan_duty, self.f_inj_pw, self.f_flex_eth,
                      self.f_cat_temp, self.f_iat, self.f_app_pedal, self.f_baro,
                      self.f_ac_press, self.f_ac_clutch]
        self.engine_module_box = module_box("Motor / Powertrain", pcm_labels)
        grid.addWidget(self.engine_module_box, 0, 0)

        # BCM
        self.b_door_fl = QLabel("Porta DE        FECHADA")
        self.b_door_fr = QLabel("Porta DD        FECHADA")
        self.b_door_rl = QLabel("Porta TE        FECHADA")
        self.b_door_rr = QLabel("Porta TD        FECHADA")
        self.b_door_trunk = QLabel("Porta-malas     FECHADO")
        self.b_door_hood = QLabel("Capô            FECHADO")
        self.b_central_lock = QLabel("Travas          DESTRANC.")
        self.b_alarm = QLabel("PATS            DESARMADO")
        self.b_low_beam = QLabel("Farol baixo     OFF")
        self.b_high_beam = QLabel("Farol alto      OFF")
        self.b_fog_lights = QLabel("Neblina         OFF")
        self.b_parking_lights = QLabel("Lanternas       OFF")
        self.b_wiper = QLabel("Limpador        OFF")
        self.b_defrost = QLabel("Desembaçador    OFF")
        self.b_ignition = QLabel("Ignição         --")
        self.b_bcm_bat = QLabel("Bateria BCM     -- V")
        bcm_labels = [self.b_door_fl, self.b_door_fr, self.b_door_rl, self.b_door_rr,
                      self.b_door_trunk, self.b_door_hood, self.b_central_lock, self.b_alarm,
                      self.b_low_beam, self.b_high_beam, self.b_fog_lights, self.b_parking_lights,
                      self.b_wiper, self.b_defrost, self.b_ignition, self.b_bcm_bat]
        self.body_module_box = module_box("Carroceria / Conforto", bcm_labels)
        grid.addWidget(self.body_module_box, 0, 1)

        # ABS / ESC
        self.f_wheel_fl = QLabel("Roda FL         -- km/h")
        self.f_wheel_fr = QLabel("Roda FR         -- km/h")
        self.f_wheel_rl = QLabel("Roda RL         -- km/h")
        self.f_wheel_rr = QLabel("Roda RR         -- km/h")
        self.f_brake_press = QLabel("Pressão freio   -- bar")
        self.f_brake_sw = QLabel("Pedal freio     LIVRE")
        self.f_sas_angle = QLabel("Ângulo SAS      --°")
        self.f_esc_state = QLabel("ESC / HLA       NORMAL")
        self.chassis_module_box = module_box(
            "Freios / Dinâmica",
            [self.f_wheel_fl, self.f_wheel_fr, self.f_wheel_rl, self.f_wheel_rr,
             self.f_brake_press, self.f_brake_sw, self.f_sas_angle, self.f_esc_state],
        )
        grid.addWidget(self.chassis_module_box, 1, 0)

        # IPC / PSCM
        self.f_odometer = QLabel("Odômetro        -- km")
        self.f_fuel_pct = QLabel("Combustível     -- %")
        self.f_ext_temp = QLabel("Temp. externa   -- °C")
        self.f_parking_brake = QLabel("Freio mão       --")
        self.f_seatbelt = QLabel("Cinto           --")
        self.f_epas_angle = QLabel("Volante         --°")
        self.f_epas_torque = QLabel("Torque EPAS     -- Nm")
        self.f_epas_current = QLabel("Corrente EPAS   -- A")
        self.cockpit_module_box = module_box(
            "Painel / Direção",
            [self.f_odometer, self.f_fuel_pct, self.f_ext_temp, self.f_parking_brake,
             self.f_seatbelt, self.f_epas_angle, self.f_epas_torque, self.f_epas_current],
        )
        grid.addWidget(self.cockpit_module_box, 1, 1)

        grid.setColumnStretch(0, 1)
        grid.setColumnStretch(1, 1)
        grid.setRowStretch(0, 1)
        grid.setRowStretch(1, 1)
        self.functions_grid_widget = QWidget()
        self.functions_grid_widget.setLayout(grid)
        root.addWidget(self.functions_grid_widget, 1)
        self._function_module_specs = {
            "Motor": (
                self.engine_module_box,
                {"rpm", "map", "advance", "tps", "load", "lambda_v", "lambda2_v", "stft", "ltft",
                 "ect", "iat", "battery", "inj_ms", "inj_pulse_width", "cht_temp", "cat_temp",
                 "fan_duty_pct", "app_pedal_pct", "flex_ethanol_pct", "baro", "ac_pressure_kpa"},
            ),
            "Carroceria": (
                self.body_module_box,
                {"door_fl", "door_fr", "door_rl", "door_rr", "door_trunk", "door_hood", "central_lock",
                 "alarm_armed", "low_beam", "high_beam", "fog_lights", "parking_lights", "wiper_status",
                 "rear_defrost", "ignition_pos", "bcm_battery_v"},
            ),
            "Freios": (
                self.chassis_module_box,
                {"wheel_speed_fl", "wheel_speed_fr", "wheel_speed_rl", "wheel_speed_rr", "brake_pressure",
                 "brake_pedal_sw", "steering_angle_abs", "esc_active"},
            ),
            "Painel / Direção": (
                self.cockpit_module_box,
                {"odometer_km", "fuel_level_pct", "ext_temp", "parking_brake", "seatbelt_warning",
                 "steering_wheel_angle", "steering_driver_torque", "steering_motor_current"},
            ),
        }
        self._refresh_function_modules()
        return tab

    def _build_performance_tab(self) -> QWidget:
        """Aba de cronômetro de aceleração (0-100, 402m), potência e viagem (Dragy style)."""
        tab = QWidget()
        lay = QVBoxLayout(tab)
        lay.setContentsMargins(6, 6, 6, 6)
        lay.setSpacing(6)

        # Barra superior com status e botão de reset
        top = QHBoxLayout()
        self.perf_status_lbl = QLabel("Cronômetro Pronto — Aguardando largada (0 km/h)")
        self.perf_status_lbl.setStyleSheet("color:#69F0AE; font-weight:bold; font-size:9pt;")
        top.addWidget(self.perf_status_lbl)
        top.addStretch()

        self.btn_reset_perf = QPushButton("Zerar Cronômetro & Viagem")
        self.btn_reset_perf.setToolTip("Reinicia as medições de 0-100, tempos de pista e integradores da viagem.")
        self.btn_reset_perf.clicked.connect(self._reset_perf_and_trip)
        top.addWidget(self.btn_reset_perf)
        lay.addLayout(top)

        grid = QGridLayout()
        grid.setSpacing(6)

        def make_box(title: str, labels: list[tuple[str, QLabel]]) -> QGroupBox:
            box = QGroupBox(title)
            bl = QGridLayout(box)
            bl.setContentsMargins(6, 6, 6, 6)
            bl.setSpacing(4)
            for i, (name, val_lbl) in enumerate(labels):
                lbl_name = QLabel(name)
                lbl_name.setStyleSheet("color:#8B98AB; font-size:8pt;")
                val_lbl.setStyleSheet("color:#E0E6ED; font-family:'Consolas','JetBrains Mono'; font-weight:bold; font-size:9pt;")
                bl.addWidget(lbl_name, i, 0)
                bl.addWidget(val_lbl, i, 1, Qt.AlignmentFlag.AlignRight)
            return box

        # 1. Arrancada e Aceleração (Dragy style)
        self.lbl_p_0_60 = QLabel("-- s")
        self.lbl_p_0_100 = QLabel("-- s")
        self.lbl_p_80_120 = QLabel("-- s")
        self.lbl_p_100_0 = QLabel("-- s")
        self.lbl_p_201m = QLabel("-- s")
        self.lbl_p_402m = QLabel("-- s")
        self.lbl_p_g_max = QLabel("0.00 G")
        self.lbl_p_v_max = QLabel("0.0 km/h")
        accel_labels = [
            ("0 a 60 km/h:", self.lbl_p_0_60),
            ("0 a 100 km/h:", self.lbl_p_0_100),
            ("80 a 120 km/h (Retomada):", self.lbl_p_80_120),
            ("100 a 0 km/h (Frenagem):", self.lbl_p_100_0),
            ("201m (1/8 milha):", self.lbl_p_201m),
            ("402m (1/4 milha):", self.lbl_p_402m),
            ("Aceleração Máx (G):", self.lbl_p_g_max),
            ("Velocidade Máxima:", self.lbl_p_v_max),
        ]
        grid.addWidget(make_box("Cronômetro de Desempenho & Aceleração", accel_labels), 0, 0)

        # 2. Dinamômetro & Potência Instantânea
        self.lbl_p_power = QLabel("-- cv")
        self.lbl_p_power_peak = QLabel("-- cv")
        self.lbl_p_torque = QLabel("-- kgfm")
        self.lbl_p_torque_peak = QLabel("-- kgfm")
        self.lbl_p_lambda_err = QLabel("-- %")
        self.lbl_p_ve = QLabel("-- %")
        dyno_labels = [
            ("Potência Instantânea:", self.lbl_p_power),
            ("Pico de Potência:", self.lbl_p_power_peak),
            ("Torque Instantâneo:", self.lbl_p_torque),
            ("Pico de Torque:", self.lbl_p_torque_peak),
            ("Desvio de Mistura (Lambda):", self.lbl_p_lambda_err),
            ("Eficiência Volumétrica (VE):", self.lbl_p_ve),
        ]
        grid.addWidget(make_box("Estimador de Potência & Dinamômetro", dyno_labels), 0, 1)

        # 3. Computador de Bordo e Custos
        self.lbl_trip_fuel = QLabel("0.000 L")
        self.lbl_trip_dist = QLabel("0.00 km")
        self.lbl_trip_cost = QLabel("R$ 0.00")
        self.lbl_trip_avg = QLabel("-- km/l")
        trip_labels = [
            ("Combustível Consumido:", self.lbl_trip_fuel),
            ("Distância Percorrida:", self.lbl_trip_dist),
            ("Custo Estimado (R$ 5,89/L):", self.lbl_trip_cost),
            ("Média Geral da Viagem:", self.lbl_trip_avg),
        ]
        grid.addWidget(make_box("Computador de Bordo da Viagem", trip_labels), 1, 0, 1, 2)

        lay.addLayout(grid)
        return tab

    def _reset_perf_and_trip(self):
        if self.worker:
            self.worker.perf_timer.reset()
            self.worker.math_engine.reset_trip()
        self.power_peak = 0.0
        self.torque_peak = 0.0
        self.lbl_p_0_60.setText("-- s")
        self.lbl_p_0_100.setText("-- s")
        self.lbl_p_80_120.setText("-- s")
        self.lbl_p_100_0.setText("-- s")
        self.lbl_p_201m.setText("-- s")
        self.lbl_p_402m.setText("-- s")
        self.lbl_p_g_max.setText("0.00 G")
        self.lbl_p_v_max.setText("0.0 km/h")
        self.lbl_p_power_peak.setText("-- cv")
        self.lbl_p_torque_peak.setText("-- kgfm")
        self.lbl_trip_fuel.setText("0.000 L")
        self.lbl_trip_dist.setText("0.00 km")
        self.lbl_trip_cost.setText("R$ 0.00")
        self.lbl_trip_avg.setText("-- km/l")
        self.perf_status_lbl.setText("Cronômetro e Viagem Zerados — Pronto!")
        self.statusBar().showMessage("Cronômetro de desempenho e integradores da viagem foram reiniciados.", 4000)

    def _update_performance_ui(self):
        latest = self.latest
        if not latest:
            return

        if self.worker:
            rec = self.worker.perf_timer.record
            if rec.time_0_60 is not None:
                self.lbl_p_0_60.setText(f"{rec.time_0_60:.2f} s")
            if rec.time_0_100 is not None:
                self.lbl_p_0_100.setText(f"{rec.time_0_100:.2f} s")
            if rec.time_80_120 is not None:
                self.lbl_p_80_120.setText(f"{rec.time_80_120:.2f} s")
            if rec.time_100_0 is not None:
                self.lbl_p_100_0.setText(f"{rec.time_100_0:.2f} s")
            if rec.time_201m is not None:
                spd = f" @ {rec.speed_201m:.0f} km/h" if rec.speed_201m else ""
                self.lbl_p_201m.setText(f"{rec.time_201m:.2f} s{spd}")
            if rec.time_402m is not None:
                spd = f" @ {rec.speed_402m:.0f} km/h" if rec.speed_402m else ""
                self.lbl_p_402m.setText(f"{rec.time_402m:.2f} s{spd}")
            self.lbl_p_g_max.setText(f"{rec.max_g:.2f} G")
            self.lbl_p_v_max.setText(f"{rec.max_speed:.1f} km/h")

        # Dinamômetro
        if "power_hp" in latest:
            pwr = latest["power_hp"]
            self.lbl_p_power.setText(f"{pwr:.1f} cv")
            if pwr > self.power_peak:
                self.power_peak = pwr
                self.lbl_p_power_peak.setText(f"{self.power_peak:.1f} cv")

        if "torque_kgfm" in latest:
            tq = latest["torque_kgfm"]
            self.lbl_p_torque.setText(f"{tq:.1f} kgfm")
            if tq > self.torque_peak:
                self.torque_peak = tq
                self.lbl_p_torque_peak.setText(f"{self.torque_peak:.1f} kgfm")

        if "lambda_error_pct" in latest:
            self.lbl_p_lambda_err.setText(f"{latest['lambda_error_pct']:+.1f} %")
        if "volumetric_eff" in latest:
            self.lbl_p_ve.setText(f"{latest['volumetric_eff']:.1f} %")

        # Viagem
        if "trip_fuel_liters" in latest:
            self.lbl_trip_fuel.setText(f"{latest['trip_fuel_liters']:.3f} L")
        if "trip_km" in latest:
            self.lbl_trip_dist.setText(f"{latest['trip_km']:.2f} km")
        if "trip_cost_brl" in latest:
            self.lbl_trip_cost.setText(f"R$ {latest['trip_cost_brl']:.2f}")
        if "trip_avg_kml" in latest:
            kml = latest["trip_avg_kml"]
            self.lbl_trip_avg.setText(f"{kml:.1f} km/l" if kml > 0 else "-- km/l")

    def _scan_vehicle_functions(self):
        if not self.worker:
            self.statusBar().showMessage("Conecte ao veículo antes de identificar os módulos.", 5000)
            return
        self.functions_summary.setText("Identificando módulos…")
        self._request("scan_all")

    def _refresh_function_modules(self):
        if not hasattr(self, "_function_module_specs"):
            return
        available = set(self.latest) | set(self.dyn_info)
        visible_names = []
        for name, (box, channel_keys) in self._function_module_specs.items():
            visible = bool(available & channel_keys)
            box.setVisible(visible)
            if visible:
                visible_names.append(name)
        self.functions_grid_widget.setVisible(bool(visible_names))
        self.functions_empty.setVisible(not visible_names)
        if visible_names:
            self.functions_summary.setText(
                f"{len(visible_names)} módulo{'s' if len(visible_names) != 1 else ''}: " + " · ".join(visible_names)
            )
        else:
            self.functions_summary.setText("Nenhum módulo identificado")

    def _update_function_ui(self):
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
            spd_fl = latest['wheel_speed_fl']
            spd_fr = latest.get('wheel_speed_fr', spd_fl)
            spd_rl = latest.get('wheel_speed_rl', spd_fl)
            spd_rr = latest.get('wheel_speed_rr', spd_fl)
            self.f_wheel_fl.setText(f"Diant. Esq: {spd_fl:.1f} km/h" + (" (Parado)" if spd_fl < 0.5 else ""))
            self.f_wheel_fr.setText(f"Diant. Dir: {spd_fr:.1f} km/h" + (" (Parado)" if spd_fr < 0.5 else ""))
            self.f_wheel_rl.setText(f"Tras. Esq: {spd_rl:.1f} km/h" + (" (Parado)" if spd_rl < 0.5 else ""))
            self.f_wheel_rr.setText(f"Tras. Dir: {spd_rr:.1f} km/h" + (" (Parado)" if spd_rr < 0.5 else ""))
            if "brake_pressure" not in latest:
                self.f_brake_press.setText("Pressão Freio: N/D (Sem sensor analógico)")
            if "esc_active" not in latest:
                self.f_esc_state.setText("Status ESC: Ativo (Monitorando)")
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

    def _on_ecu_detected(self, meta: dict):
        self.last_ecu_meta = meta
        display_title = meta.get("display_title", "ECU Detectada")
        protocol = meta.get("protocol", "OBD2")
        self.setWindowTitle(f"leitorECU — {display_title}")
        self.proto_badge.setText(protocol)
        self.proto_badge.setProperty("fallback", "false")
        self.proto_badge.style().unpolish(self.proto_badge)
        self.proto_badge.style().polish(self.proto_badge)
        self.event_severity.setText("● INFO")
        self.event_severity.setStyleSheet("color:#00D2FF; font-size:7.5pt; font-weight:800;")
        self.event_ribbon_text.setText(f"Central conectada: {display_title} ({protocol})")

        # Adaptação dinâmica de abas conforme capacidades descobertas
        if meta.get("is_can"):
            idx_fn = self.tabs.indexOf(self.functions_tab)
            if idx_fn >= 0:
                self.tabs.setTabText(idx_fn, "Módulos CAN (ABS / Carroceria)")
            idx_ch = self.tabs.indexOf(self.ch_tab)
            if idx_ch >= 0:
                self.tabs.setTabText(idx_ch, "Canais")
                self.scan_btn.setText("Varrer PIDs CAN")
        else:
            idx_fn = self.tabs.indexOf(self.functions_tab)
            if idx_fn >= 0:
                self.tabs.setTabText(idx_fn, "Diagnóstico Motor")
            idx_ch = self.tabs.indexOf(self.ch_tab)
            if idx_ch >= 0:
                self.tabs.setTabText(idx_ch, "Blocos de Medição (001..255)")
                self.scan_btn.setText("Varrer Blocos (001..255)")

    def _build_ui(self):
        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(7, 6, 7, 5)
        root.setSpacing(5)
        self.setCentralWidget(central)

        # ---------------- conexão
        conn = QFrame(objectName="connectionBar")
        cl = QHBoxLayout(conn)
        cl.setContentsMargins(8, 4, 8, 4)
        cl.setSpacing(7)

        self.mode = QComboBox()
        self.mode.addItems([
            "Bluetooth BLE (Vgate iCar Pro)",
            "Wi-Fi (TCP)",
            "USB Serial / KKL (COM)",
            "Demo / Simulador",
        ])
        self.mode.setFixedWidth(175)
        self.mode.currentIndexChanged.connect(self._mode_changed)
        mode_lbl = QLabel("LINK")
        mode_lbl.setStyleSheet("color:#607088; font-size:7pt; font-weight:800;")
        cl.addWidget(mode_lbl)
        cl.addWidget(self.mode)

        self.wifi_box = QWidget()
        wl = QHBoxLayout(self.wifi_box)
        wl.setContentsMargins(0, 0, 0, 0)
        self.ip = QLineEdit("192.168.0.10")
        self.ip.setFixedWidth(88)
        self.port = QSpinBox()
        self.port.setRange(1, 65535)
        self.port.setValue(35000)
        self.port.setFixedWidth(70)
        wl.addWidget(QLabel("IP"))
        wl.addWidget(self.ip)
        wl.addWidget(QLabel("TCP"))
        wl.addWidget(self.port)
        cl.addWidget(self.wifi_box)

        self.ble_box = QWidget()
        bl = QHBoxLayout(self.ble_box)
        bl.setContentsMargins(0, 0, 0, 0)
        self.ble_dev = QComboBox()
        self.ble_dev.setEditable(True)
        self.ble_dev.setFixedWidth(110)
        self.ble_dev.lineEdit().setPlaceholderText("Clique em Procurar ou digite o endereço")
        self.ble_scan_btn = QPushButton("Buscar")
        self.ble_scan_btn.setFixedWidth(72)
        self.ble_scan_btn.clicked.connect(self._scan_ble)
        bl.addWidget(QLabel("BLE"))
        bl.addWidget(self.ble_dev)
        bl.addWidget(self.ble_scan_btn)
        cl.addWidget(self.ble_box)

        self.serial_box = QWidget()
        sl = QHBoxLayout(self.serial_box)
        sl.setContentsMargins(0, 0, 0, 0)
        sl.setSpacing(4)
        self.serial_port_cb = QComboBox()
        self.serial_port_cb.setEditable(True)
        self.serial_port_cb.setFixedWidth(115)
        ports = KklSerialTransport.list_ports()
        if ports:
            for dev, desc in ports:
                label = f"{dev} ({desc})" if desc and desc != "n/a" else dev
                self.serial_port_cb.addItem(label, dev)
        else:
            self.serial_port_cb.addItem("COM1", "COM1")
        self.serial_baud_cb = QComboBox()
        self.serial_baud_cb.addItems([
            "9600 (KKL / KW1281)",
            "10400 (K-Line)",
            "38400 (ELM327 USB)",
            "115200 (ELM327 Rápido)",
        ])
        self.serial_baud_cb.setFixedWidth(125)
        sl.addWidget(QLabel("COM"))
        sl.addWidget(self.serial_port_cb)
        sl.addWidget(QLabel("BAUD"))
        sl.addWidget(self.serial_baud_cb)
        cl.addWidget(self.serial_box)

        self.connect_btn = QPushButton("Conectar", objectName="connect")
        self.connect_btn.setCheckable(True)
        self.connect_btn.setFixedWidth(105)
        self.connect_btn.clicked.connect(self._toggle_connect)
        cl.addWidget(self.connect_btn)

        self.connection_pill = QLabel("● OFFLINE", objectName="statusPill")
        self.connection_pill.setProperty("state", "offline")
        self.connection_pill.setFixedWidth(82)
        cl.addWidget(self.connection_pill)

        self.proto_badge = QLabel("AGUARDANDO CONEXÃO", objectName="protoBadge")
        self.proto_badge.setProperty("fallback", "false")
        self.proto_badge.setFixedWidth(150)
        cl.addWidget(self.proto_badge)

        self.btn_reconnect_vag = QPushButton("Forçar K-Line")
        self.btn_reconnect_vag.setToolTip("Força a tentativa de reconexão pelo protocolo K-Line (KWP2000 / KW1281)")
        self.btn_reconnect_vag.setEnabled(False)
        self.btn_reconnect_vag.setFixedWidth(105)
        self.btn_reconnect_vag.clicked.connect(self._force_reconnect_vag)
        cl.addWidget(self.btn_reconnect_vag)

        cl.addStretch()
        self.rate_lbl = QLabel("0.0 R/S  |  0.0 C/S  |  -- ms", objectName="rateBadge")
        self.rate_lbl.setFont(QFont("JetBrains Mono", 8, QFont.Weight.Bold))
        self.rate_lbl.setFixedWidth(205)
        cl.addWidget(self.rate_lbl)
        self.latency_lbl = QLabel("LATÊNCIA  -- ms")
        self.latency_lbl.setStyleSheet("color:#8B98AB; font-family:'JetBrains Mono'; font-size:7.5pt; font-weight:700;")
        self.latency_lbl.setVisible(False)
        cl.addWidget(self.latency_lbl)
        self.status_lbl = QLabel("Pronto para conectar")
        self.status_lbl.setStyleSheet("color:#8B98AB; font-size:8pt;")
        self.status_lbl.setMaximumWidth(115)
        self.status_lbl.setVisible(False)
        cl.addWidget(self.status_lbl, 1)
        root.addWidget(conn)

        # ---------------- controles
        ctl = QHBoxLayout()
        ctl.setContentsMargins(0, 0, 0, 0)
        ctl.setSpacing(5)
        self.btn_open_csv = QPushButton("Abrir Log CSV")
        self.btn_open_csv.setToolTip("Carrega um arquivo CSV gravado para replay e análise ponto a ponto.")
        self.btn_open_csv.clicked.connect(self._open_csv_replay)

        self.btn_clear_peaks = QPushButton("Limpar Picos")
        self.btn_clear_peaks.setToolTip("Zera os valores de pico (Mínimo e Máximo) de todos os cards.")
        self.btn_clear_peaks.clicked.connect(self._clear_all_peaks)

        self.decel_btn = QPushButton("Desaceleração", objectName="decel")
        self.decel_btn.setCheckable(True)
        self.decel_btn.setMinimumWidth(100)
        self.decel_btn.setToolTip("Lê apenas RPM, MAP, Avanço, TPS e Sonda (pausa ECT/STFT/LTFT)\n"
                                  "para aumentar a taxa de amostragem e capturar Cut-Off / Dashpot.")
        self.decel_btn.toggled.connect(self._decel_toggled)
        self.rec_btn = QPushButton("●  Gravar Log", objectName="record")
        self.rec_btn.setCheckable(True)
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
        self.bg_scan_chk.setToolTip("Varre blocos e DIDs desconhecidos em segundo plano.\n"
                                    "Mantenha desmarcado para taxa máxima de amostragem (~3 Hz) nos canais primários.")
        self.bg_scan_chk.setChecked(False)
        self.bg_scan_chk.toggled.connect(self._bg_scan_toggled)
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
        for w in (self.btn_open_csv, self.btn_clear_peaks, self.decel_btn, self.rec_btn, self.freeze_btn, clear_btn):
            ctl.addWidget(w)
        ctl.addSpacing(4)
        for w in (self.cadence_cb, self.extras_chk, self.bg_scan_chk, self.fast_chk, self.raw_chk):
            ctl.addWidget(w)
        ctl.addStretch()
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

        self.p1 = DualAxisPlot("01  Dinâmica de Ar e Giro", "RPM", (0, 7000), "TPS % / MAP kPa", (0, 105))
        self.p2 = DualAxisPlot("02  Combustão e Ignição", "Sonda (V)", (0, 1.3), "Avanço (°)", (-20, 50))
        self.p3 = DualAxisPlot("03  Fuel Trims e Elétrica", "Fuel Trim (%)", (-30, 30), "Bateria (V)", (10, 16))
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
            "battery": self.p3.add_curve("Bateria V", COLORS["battery"], right=True, width=1.8),
        }
        self.plot_bindings = [
            [self.p1, self.curves["rpm"], "rpm", "Esq.1"],
            [self.p1, self.curves["tps"], "tps", "Esq.2"],
            [self.p1, self.curves["map"], "map", "Dir."],
            [self.p2, self.curves["lambda_v"], "lambda_v", "Esq.1"],
            [self.p2, self.curves["lambda2_v"], "lambda2_v", "Esq.2"],
            [self.p2, self.curves["advance"], "advance", "Dir."],
            [self.p3, self.curves["stft"], "stft", "Esq.1"],
            [self.p3, self.curves["ltft"], "ltft", "Esq.2"],
            [self.p3, self.curves["battery"], "battery", "Dir."],
        ]
        self.p2.add_hline(0.45, "#ffffff", label="0,45 V")
        self.p2.add_hline(0.70, "#ff5252", style=Qt.PenStyle.DotLine, label="0,70 V cut-off")
        self.p2.add_hline(-5, "#e040fb", right=True, style=Qt.PenStyle.DotLine)
        self.p3.add_hline(0, "#607d8b", style=Qt.PenStyle.SolidLine)
        self.p3.add_hline(10, "#ffc107", label="+10%")
        self.p3.add_hline(-10, "#ffc107", label="-10%")
        channel_keys = list(CHANNELS.keys()) + [k for k in DYNAMIC_INFO if k not in CHANNELS]

        def plot_panel(plot, binding_slice):
            panel = QFrame()
            panel.setStyleSheet("QFrame { background:#0A0C10; border:1px solid #2C3545; border-radius:5px; }")
            panel_lay = QVBoxLayout(panel)
            panel_lay.setContentsMargins(3, 3, 3, 3)
            panel_lay.setSpacing(2)
            selector_row = QHBoxLayout()
            selector_row.setContentsMargins(3, 0, 3, 0)
            selector_row.addWidget(QLabel("CANAIS"))
            for binding in binding_slice:
                combo = QComboBox()
                combo.setMinimumWidth(105)
                for key in channel_keys:
                    label = CHANNELS[key].label if key in CHANNELS else DYNAMIC_INFO[key][0]
                    combo.addItem(f"{binding[3]}  {label}", key)
                combo.setCurrentIndex(max(0, combo.findData(binding[2])))
                combo.currentIndexChanged.connect(
                    lambda _idx, cb=combo, target=binding: target.__setitem__(2, cb.currentData())
                )
                selector_row.addWidget(combo)
            selector_row.addStretch()
            window_lbl = QLabel("JANELA 30 s")
            window_lbl.setStyleSheet("color:#607088; font-family:'JetBrains Mono'; font-size:7pt; font-weight:700;")
            selector_row.addWidget(window_lbl)
            panel_lay.addLayout(selector_row)
            panel_lay.addWidget(plot, 1)
            return panel

        pl.addWidget(plot_panel(self.p1, self.plot_bindings[0:3]), 1)
        pl.addWidget(plot_panel(self.p2, self.plot_bindings[3:6]), 1)
        pl.addWidget(plot_panel(self.p3, self.plot_bindings[6:9]), 1)

        self.crosshair_p1 = self.p1.add_crosshair("#ffffff")
        self.crosshair_p2 = self.p2.add_crosshair("#ffffff")
        self.crosshair_p3 = self.p3.add_crosshair("#ffffff")
        for ch in (self.crosshair_p1, self.crosshair_p2, self.crosshair_p3):
            ch.setVisible(False)

        self.p1.scene().sigMouseMoved.connect(self._on_plot_mouse_moved)
        self.p2.scene().sigMouseMoved.connect(self._on_plot_mouse_moved)
        self.p3.scene().sigMouseMoved.connect(self._on_plot_mouse_moved)

        split.addWidget(plots_w)

        tabs = QTabWidget()
        # Mapa 2D RPM x MAP (Análise Térmica / Calibração)
        self.map2d = Map2DWidget()
        tabs.addTab(self.map2d, "Mapa 2D")
        self.perf_tab = self._build_performance_tab()
        tabs.addTab(self.perf_tab, "Desempenho")
        # Funções encontradas por módulo, sem acoplamento ao modelo selecionado
        self.functions_tab = self._build_functions_tab()
        self.ford_tab = self.functions_tab  # compatibilidade com integrações existentes
        tabs.addTab(self.functions_tab, "Funções")
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
        # todos os canais (tudo o que a central enviou, inclusive blocos VAG genéricos)
        self.ch_tab = QWidget()
        chl = QVBoxLayout(self.ch_tab)
        chl.setContentsMargins(4, 4, 4, 4)
        chb = QHBoxLayout()
        self.scan_btn = QPushButton("Varrer blocos VAG")
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
        self.ch_search.setPlaceholderText("Filtrar canais por nome, código ou descrição...")
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
        tabs.addTab(self.ch_tab, "Canais")
        self.tabs = tabs
        # DTC
        dtc_w = QWidget()
        dl = QVBoxLayout(dtc_w)
        dl.setContentsMargins(4, 4, 4, 4)
        dl.setSpacing(4)
        hb1 = QHBoxLayout()
        hb1.setSpacing(4)
        self.dtc_read_btn = QPushButton("Ler DTCs (03)")
        self.dtc_read_btn.clicked.connect(lambda: self._request("read_dtc"))
        self.dtc_clear_btn = QPushButton("Apagar DTCs (04)")
        self.dtc_clear_btn.clicked.connect(self._clear_dtc)
        self.btn_reset_adaptation = QPushButton("Reset Adaptação / Flex")
        self.btn_reset_adaptation.setToolTip(
            "Restaura valores de adaptação de fábrica na EEPROM (Canal 00 / Basic Setting 000).\n"
            "Zera o Bloco 032 e força o descarte do aprendizado antigo de combustível (Bloco 103 Flex).\n"
            "Execute com o motor aquecido (> 80 °C), ignição LIGADA e motor DESLIGADO."
        )
        self.btn_reset_adaptation.clicked.connect(self._reset_adaptation_dialog)
        hb1.addWidget(self.dtc_read_btn)
        hb1.addWidget(self.dtc_clear_btn)
        hb1.addWidget(self.btn_reset_adaptation)
        dl.addLayout(hb1)

        hb2 = QHBoxLayout()
        hb2.setSpacing(4)
        self.btn_readiness = QPushButton("Monitores I/M (01)")
        self.btn_readiness.setToolTip("Lê o status dos monitores de emissões I/M Readiness (Modo 01 PID 01).")
        self.btn_readiness.clicked.connect(lambda: self._request("read_readiness"))
        self.btn_freeze_frame = QPushButton("Freeze Frame (02)")
        self.btn_freeze_frame.setToolTip("Lê os parâmetros do motor congelados no momento da falha (Modo 02).")
        self.btn_freeze_frame.clicked.connect(lambda: self._request("read_freeze_frame"))
        self.btn_export_report = QPushButton("Exportar Laudo (PDF)")
        self.btn_export_report.setToolTip("Gera laudo técnico completo em PDF / HTML com DTCs, Monitores, Teste de Bateria e Telemetria.")
        self.btn_export_report.clicked.connect(self._export_pdf_report)
        hb2.addWidget(self.btn_readiness)
        hb2.addWidget(self.btn_freeze_frame)
        hb2.addWidget(self.btn_export_report)
        dl.addLayout(hb2)
        self.mil_lbl = QLabel("Luz de injeção (MIL): —")
        dl.addWidget(self.mil_lbl)
        self.dtc_table = QTableWidget(0, 2)
        self.dtc_table.setHorizontalHeaderLabels(["Código", "Descrição"])
        self.dtc_table.horizontalHeader().setSectionResizeMode(1, QHeaderView.ResizeMode.Stretch)
        self.dtc_table.verticalHeader().setVisible(False)
        dl.addWidget(self.dtc_table, 1)
        tabs.addTab(dtc_w, "Falhas (DTC)")
        tabs.addTab(ev_w, "Eventos")
        # console
        self.console = QPlainTextEdit(readOnly=True)
        self.console.setMaximumBlockCount(3000)
        tabs.addTab(self.console, "Console")
        split.addWidget(tabs)
        split.setStretchFactor(0, 1)
        split.setStretchFactor(1, 1)
        split.setSizes([int(self.width() * 0.50), int(self.width() * 0.50)])
        split.setChildrenCollapsible(False)
        root.addWidget(split, 1)

        event_ribbon = QFrame(objectName="eventRibbon")
        event_lay = QHBoxLayout(event_ribbon)
        event_lay.setContentsMargins(8, 3, 8, 3)
        event_lay.setSpacing(7)
        self.event_severity = QLabel("● INFO")
        self.event_severity.setStyleSheet("color:#00D2FF; font-size:7.5pt; font-weight:800;")
        self.event_ribbon_text = QLabel("Sistema pronto — aguardando conexão com a ECU", objectName="eventRibbonText")
        self.event_ribbon_text.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        event_lay.addWidget(self.event_severity)
        event_lay.addWidget(self.event_ribbon_text, 1)
        root.addWidget(event_ribbon)

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
        saved_com = s.value("serial_port", "")
        if saved_com:
            self.serial_port_cb.setCurrentText(saved_com)
        saved_baud_idx = int(s.value("serial_baud_idx", 0))
        if 0 <= saved_baud_idx < self.serial_baud_cb.count():
            self.serial_baud_cb.setCurrentIndex(saved_baud_idx)
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
        s.setValue("serial_port", self.serial_port_cb.currentText().strip())
        s.setValue("serial_baud_idx", self.serial_baud_cb.currentIndex())
        s.setValue("ble_addr", self._ble_address())
        s.setValue("ble_name", self.ble_dev.currentText().split("  [")[0] if self.ble_dev.currentData() else "")
        s.setValue("extras", "true" if self.extras_chk.isChecked() else "false")
        s.setValue("bg_scan", "true" if self.bg_scan_chk.isChecked() else "false")
        s.setValue("fast", "true" if self.fast_chk.isChecked() else "false")

    # ============================================================ conexão
    def _mode_changed(self, idx: int):
        self.wifi_box.setVisible(idx == MODE_WIFI)
        self.ble_box.setVisible(idx == MODE_BLE)
        self.serial_box.setVisible(idx == MODE_SERIAL)

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
        self.ble_scan_btn.setText("Buscar")

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
                QMessageBox.warning(self, "BLE", "Selecione o adaptador BLE (clique em 'Buscar').")
                self.connect_btn.setChecked(False)
                return
            transport = BleTransport(addr, timeout=2.0)
        elif mode == MODE_SERIAL:
            port = self.serial_port_cb.currentData() or self.serial_port_cb.currentText().split()[0].strip()
            baud_str = self.serial_baud_cb.currentText().split()[0].strip()
            try:
                baud = int(baud_str)
            except ValueError:
                baud = 9600
            transport = KklSerialTransport(port=port, baudrate=baud, timeout=2.0)
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
        self.worker = ObdWorker(transport, self.t0, vehicle_profile=PROFILE_AUTO, parent=self)
        if isinstance(transport, BleTransport):
            transport._log = self.worker.log.emit  # sinal Qt: seguro entre threads
        self.worker.sample.connect(self._on_sample)
        self.worker.status.connect(self._on_status)
        self.worker.log.connect(self.console.appendPlainText)
        self.worker.rate.connect(self._on_rate)
        self.worker.dtc_result.connect(self._on_dtc)
        self.worker.info.connect(self._on_info)
        self.worker.channels.connect(self._on_channels)
        self.worker.protocol_mode_changed.connect(self._on_protocol_mode_changed)
        self.worker.ecu_detected.connect(self._on_ecu_detected)
        self.worker.readiness_result.connect(self._on_readiness_result)
        self.worker.freeze_frame_result.connect(self._on_freeze_frame_result)
        self.worker.perf_event.connect(self._on_perf_event)
        self.worker.finished.connect(self._worker_finished)
        self._apply_worker_flags()
        self.worker.decel_mode = self.decel_btn.isChecked()
        self.mode.setEnabled(False)
        self.wifi_box.setEnabled(False)
        self.ble_box.setEnabled(False)
        self.serial_box.setEnabled(False)
        self.btn_reconnect_vag.setEnabled(True)
        self.connect_btn.setText("Desconectar")
        self.console.appendPlainText(f"===== {datetime.now():%H:%M:%S} conectando ({transport.name} — Auto-Discovery) =====")
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
        self.serial_box.setEnabled(True)
        self.btn_reconnect_vag.setEnabled(False)
        self.proto_badge.setText("Desconectado")
        self.proto_badge.setProperty("fallback", "false")
        self.proto_badge.style().unpolish(self.proto_badge)
        self.proto_badge.style().polish(self.proto_badge)
        self.connection_pill.setText("● OFFLINE")
        self.connection_pill.setProperty("state", "offline")
        self.connection_pill.style().unpolish(self.connection_pill)
        self.connection_pill.style().polish(self.connection_pill)
        self._set_dtc_enabled(False)
        self.rate_lbl.setText("0.0 R/S  |  0.0 C/S  |  -- ms")
        self.latency_lbl.setText("LATÊNCIA  -- ms")

    def _on_status(self, state: str, msg: str):
        color = {"connected": "#00E676", "connecting": "#FFB300", "error": "#FF3D71", "warning": "#FFB300"}.get(state, "#8B98AB")
        self.status_lbl.setStyleSheet(f"color:{color}; font-weight:bold;")
        self.status_lbl.setText(msg)
        pill_state = "connected" if state == "connected" else "connecting" if state == "connecting" else "offline"
        pill_text = "● ONLINE" if state == "connected" else "● CONECTANDO" if state == "connecting" else "● OFFLINE"
        self.connection_pill.setText(pill_text)
        self.connection_pill.setProperty("state", pill_state)
        self.connection_pill.style().unpolish(self.connection_pill)
        self.connection_pill.style().polish(self.connection_pill)
        self._set_dtc_enabled(state == "connected")

    def _on_protocol_mode_changed(self, mode_name: str, is_fallback: bool):
        self.proto_badge.setText(mode_name)
        self.proto_badge.setProperty("fallback", "true" if is_fallback else "false")
        self.proto_badge.style().unpolish(self.proto_badge)
        self.proto_badge.style().polish(self.proto_badge)
        self.btn_reconnect_vag.setEnabled(is_fallback)

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
        self.console.appendPlainText(f"INFO  {msg}")
        self.event_severity.setText("● INFO")
        self.event_severity.setStyleSheet("color:#00D2FF; font-size:7.5pt; font-weight:800;")
        self.event_ribbon_text.setText(msg)

    def _on_rate(self, resp: float, cycles: float):
        latency = f"{1000.0 / resp:4.0f} ms" if resp > 0 else "-- ms"
        self.rate_lbl.setText(f"{resp:4.1f} R/S  |  {cycles:4.1f} C/S  |  {latency}")
        self.latency_lbl.setText(f"LATÊNCIA  {latency}")

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
            self.latest[k] = v
            self.stamp[k] = t
            self.dirty.add(k)
            if k not in self.buffers:
                self.buffers[k] = SeriesBuffer()
            self.buffers[k].append(t, v)
        if "rpm" in self.latest and "map" in self.latest:
            self.map2d.add_sample(self.latest["rpm"], self.latest["map"], self.latest)
        self.audio_alerts.check(self.latest.get("rpm", 0.0), self.latest.get("ect"))
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
        labels = {"alarm": "● ALARME", "warn": "▲ ATENÇÃO", "info": "● INFO", "ok": "● NORMAL"}
        ribbon_colors = {"alarm": "#FF3D71", "warn": "#FFB300", "info": "#00D2FF", "ok": "#00E676"}
        self.event_severity.setText(labels.get(e.level, "● EVENTO"))
        self.event_severity.setStyleSheet(
            f"color:{ribbon_colors.get(e.level, '#8B98AB')}; font-size:7.5pt; font-weight:800;"
        )
        self.event_ribbon_text.setText(e.message)

    def _clear_plots(self):
        for b in self.buffers.values():
            b.clear()
        for c in self.curves.values():
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
            for _, curve, k, _ in self.plot_bindings:
                buf = self.buffers.get(k)
                if buf is None:
                    curve.setData([], [])
                    continue
                t, v = buf.window(t_from)
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
        # Se o veículo possui apenas 1 sonda lambda, adapta dinamicamente o card lambda2_v
        if "lambda2_v" not in self.latest and "lambda2_v" in self.cards:
            c2 = self.cards["lambda2_v"]
            if "inj_ms" in self.latest:
                if c2.title.text() != "Tempo Injeção":
                    c2.title.setText("Tempo Injeção")
                    c2.unit.setText("ms")
                c2.set_value(self.latest["inj_ms"])
                c2.set_state("normal")
            elif "inj_pulse_width" in self.latest:
                if c2.title.text() != "Tempo Injeção":
                    c2.title.setText("Tempo Injeção")
                    c2.unit.setText("ms")
                c2.set_value(self.latest["inj_pulse_width"])
                c2.set_state("normal")
            elif "fuel_rate_lph" in self.latest:
                if c2.title.text() != "Consumo Inst.":
                    c2.title.setText("Consumo Inst.")
                    c2.unit.setText("L/h")
                c2.set_value(self.latest["fuel_rate_lph"])
                c2.set_state("normal")
        self.dirty.clear()
        if self.frame % 3 == 0:
            self._update_function_ui()
            self._refresh_function_modules()
            self._update_performance_ui()
        if self.frame % 6 == 0:
            self._update_card_states(now)
            if self.logger.active:
                self.rec_btn.setText(f"●  Gravando  {self.logger.rows}")
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
        self._refresh_function_modules()

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
                card2 = self.cards.get("lambda2_v")
                if card2 and (k not in self.stamp or now - self.stamp[k] > 4.0) and self.latest.get("rpm", 0) > 450:
                    if "inj_ms" in self.latest:
                        card2.title.setText("Tempo Injeção")
                        card2.unit.setText("ms")
                        card2.set_value(self.latest["inj_ms"])
                        card2.set_state("normal", "")
                        continue
                    elif "inj_pulse_width" in self.latest:
                        card2.title.setText("Tempo Injeção")
                        card2.unit.setText("ms")
                        card2.set_value(self.latest["inj_pulse_width"])
                        card2.set_state("normal", "")
                        continue
                    elif "fuel_rate_lph" in self.latest:
                        card2.title.setText("Consumo Inst.")
                        card2.unit.setText("L/h")
                        card2.set_value(self.latest["fuel_rate_lph"])
                        card2.set_state("normal", "")
                        continue
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
                extra_headers: Dict[str, str] = {}
                # 1. Pré-registra canais dinâmicos do Modo 01 (SAE J1979)
                for k, (label, unit) in DYNAMIC_INFO.items():
                    if k not in CHANNELS:
                        extra_headers[k] = f"{label} [{unit}]" if unit else label

                # 2. Pré-registra todos os canais do Ford HS-CAN / UDS
                for k, (label, unit) in FORD_CHANNELS_INFO.items():
                    if k not in CHANNELS and k not in extra_headers:
                        extra_headers[k] = f"{label} [{unit}]" if unit else label

                # 3. Pré-registra blocos VAG KWP2000 do cache JSON da ME7.5.30
                try:
                    ecu_id = getattr(self.worker.strategy, "ecu_id", "") if self.worker else ""
                    cached = vag.load_cache(ecu_id or "032906032AJ")
                    for k, (label, unit) in cached.get("cells", {}).items():
                        if k not in CHANNELS and k not in extra_headers:
                            extra_headers[k] = f"{label} [{unit}]" if unit else label
                except Exception:
                    pass

                # 4. Metadados da estratégia ativa e canais conhecidos
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
            self.rec_btn.setText("●  Gravar Log")

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

        t_data: Dict[str, List[float]] = {k: [] for k in PLOTTED}
        v_data: Dict[str, List[float]] = {k: [] for k in PLOTTED}

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

            for k in PLOTTED:
                if k in record:
                    t_data[k].append(t_val)
                    v_data[k].append(record[k])

            events = self.detector.update(t_val, record, {k: t_val for k in record})
            for e in events:
                self._add_event(e)
                if e.level == "alarm":
                    self.p1.add_marker(e.t, "#ff1744", label="Falha")
                    self.p2.add_marker(e.t, "#ff1744", label="Falha")
                    self.p3.add_marker(e.t, "#ff1744")

            if "rpm" in record and "map" in record:
                self.map2d.add_sample(record["rpm"], record["map"], record)

        for k in PLOTTED:
            if t_data[k]:
                self.curves[k].setData(t_data[k], v_data[k])

        max_t = self._replay_times[-1] if self._replay_times else 30.0
        self.p1.pi.setXRange(0, max_t, padding=0.01)
        self.p2.pi.setXRange(0, max_t, padding=0.01)
        self.p3.pi.setXRange(0, max_t, padding=0.01)

        filename = os.path.basename(path)
        self.statusBar().showMessage(f"Replay CSV: {filename} carregado ({len(self._replay_records)} amostras, 0 a {max_t:.1f}s). Arraste o mouse sobre os gráficos para inspecionar.", 15000)
        self.status_lbl.setText(f"Modo Replay: {filename}")
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
        self.btn_readiness.setEnabled(on)
        self.btn_freeze_frame.setEnabled(on)
        self.btn_export_report.setEnabled(True)
        self.scan_btn.setEnabled(on)
        self.functions_scan_btn.setEnabled(on)

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

    def _on_readiness_result(self, report: ReadinessReport):
        self.last_readiness = report
        dlg = QDialog(self)
        dlg.setWindowTitle("Monitores de Prontidão (I/M Readiness — Modo 01)")
        dlg.resize(520, 480)
        lay = QVBoxLayout(dlg)

        info_lbl = QLabel(
            f"Luz de Injeção (MIL): {'ACESA (Falha)' if report.mil_on else 'Apagada (OK)'}  |  "
            f"DTCs Gravados: {report.dtc_count}  |  "
            f"Monitores Prontos: {report.ready_count}/{report.supported_count}"
        )
        info_lbl.setStyleSheet("font-weight:bold; font-size:10pt; color:#E6EDF3; padding:4px;")
        lay.addWidget(info_lbl)

        table = QTableWidget(len(report.monitors), 2)
        table.setHorizontalHeaderLabels(["Monitor / Sistema", "Estado"])
        table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        table.setColumnWidth(1, 150)
        table.verticalHeader().setVisible(False)
        table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)

        for r, m in enumerate(report.monitors):
            item_name = QTableWidgetItem(m.name)
            table.setItem(r, 0, item_name)
            if not m.supported:
                status_text = "Não Suportado"
                color = "#8B98AB"
            elif m.completed:
                status_text = "✔ Concluído (OK)"
                color = "#00E676"
            else:
                status_text = "✖ Incompleto"
                color = "#FF9100"
            item_status = QTableWidgetItem(status_text)
            item_status.setForeground(pg.mkColor(color))
            item_status.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
            table.setItem(r, 1, item_status)

        lay.addWidget(table, 1)
        btn_close = QPushButton("Fechar")
        btn_close.clicked.connect(dlg.accept)
        lay.addWidget(btn_close)
        dlg.exec()

    def _on_freeze_frame_result(self, ff: FreezeFrame):
        self.last_freeze_frame = ff
        dlg = QDialog(self)
        dlg.setWindowTitle("Dados Congelados da Falha (Freeze Frame — Modo 02)")
        dlg.resize(500, 420)
        lay = QVBoxLayout(dlg)

        info_lbl = QLabel(f"DTC Causador do Congelamento: {ff.dtc}")
        info_lbl.setStyleSheet("font-weight:bold; font-size:11pt; color:#FF5252; padding:4px;")
        lay.addWidget(info_lbl)

        table = QTableWidget(len(ff.params), 3)
        table.setHorizontalHeaderLabels(["Sensor / Parâmetro", "Valor Congelado", "Unidade"])
        table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        table.verticalHeader().setVisible(False)
        table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)

        for r, (p_name, (val, unit)) in enumerate(ff.params.items()):
            table.setItem(r, 0, QTableWidgetItem(p_name))
            table.setItem(r, 1, QTableWidgetItem(f"{val:.1f}"))
            table.setItem(r, 2, QTableWidgetItem(unit))

        lay.addWidget(table, 1)
        btn_close = QPushButton("Fechar")
        btn_close.clicked.connect(dlg.accept)
        lay.addWidget(btn_close)
        dlg.exec()

    def _export_pdf_report(self):
        dtcs = []
        for row in range(self.dtc_table.rowCount()):
            c_item = self.dtc_table.item(row, 0)
            d_item = self.dtc_table.item(row, 1)
            if c_item and d_item:
                dtcs.append((c_item.text(), d_item.text()))

        mil_text = self.mil_lbl.text()

        # Picos dos cards
        card_peaks = {}
        for k, card in self.cards.items():
            card_peaks[k] = (card.peak_min, card.peak_max)

        default_name = f"Laudo_Diagnostico_{datetime.now():%Y%m%d_%H%M%S}.pdf"
        file_path, _ = QFileDialog.getSaveFileName(
            self,
            "Salvar Laudo de Diagnóstico Técnico",
            default_name,
            "Documento PDF (*.pdf);;Arquivo HTML (*.html)"
        )
        if not file_path:
            return

        html_code = generate_html_report(
            ecu_meta=self.last_ecu_meta,
            dtcs=dtcs,
            mil_status=mil_text,
            readiness=self.last_readiness,
            freeze_frame=self.last_freeze_frame,
            card_peaks=card_peaks,
            battery_test=self.last_battery_test,
        )

        if file_path.lower().endswith(".html"):
            try:
                with open(file_path, "w", encoding="utf-8") as f:
                    f.write(html_code)
                QMessageBox.information(self, "Laudo Salvo", f"Laudo HTML salvo com sucesso em:\n{file_path}")
            except Exception as e:
                QMessageBox.critical(self, "Erro ao Salvar", f"Não foi possível salvar o arquivo:\n{e}")
        else:
            ok = export_report_to_pdf(html_code, file_path)
            if ok:
                QMessageBox.information(self, "Laudo PDF Gerado", f"Laudo PDF exportado com sucesso em:\n{file_path}")
            else:
                QMessageBox.critical(self, "Erro", "Falha ao gerar o PDF com QTextDocument.")

    def _on_perf_event(self, msg: str):
        if hasattr(self, "perf_status_lbl"):
            self.perf_status_lbl.setText(msg)
        self.event_severity.setText("● PERF")
        self.event_severity.setStyleSheet("color:#FFD700; font-size:7.5pt; font-weight:800;")
        self.event_ribbon_text.setText(f"[Dragy/Desempenho] {msg}")
        self.statusBar().showMessage(f"[Desempenho] {msg}", 5000)

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
