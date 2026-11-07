"""Tema escuro da aplicação."""

COLORS = {
    "rpm": "#ff5252",
    "tps": "#40c4ff",
    "map": "#b2ff59",
    "lambda_v": "#ffd740",
    "lambda2_v": "#ff80ab",
    "advance": "#e040fb",
    "stft": "#69f0ae",
    "ltft": "#ff9100",
    "battery": "#00e5ff",
    "obd_pin16_v": "#80d8ff",
    "ecu_volt": "#18ffff",
    "bcm_battery_v": "#40c4ff",
    "inj_ms": "#ffab40",
    "inj_pulse_width": "#ffab40",
    "ect": "#ff6e40",
    "iat": "#84ffff",
    "cht_temp": "#ff8a65",
    "cat_temp": "#ff5252",
    "load": "#b388ff",
    "speed": "#64ffda",
    "flex_ethanol_pct": "#aeea00",
    "ethanol": "#aeea00",
    "app_pedal_pct": "#40c4ff",
    "ac_pressure_kpa": "#00b0ff",
    "wheel_speed_fl": "#80d8ff",
    "wheel_speed_fr": "#40c4ff",
    "wheel_speed_rl": "#82b1ff",
    "wheel_speed_rr": "#b388ff",
    "steering_wheel_angle": "#ffd740",
    "knock_ret_c1": "#ff1744",
    "knock_v_c1": "#ff9100",
}

STYLE = """
QWidget { background: #15181d; color: #e6e6e6; font-family: 'Segoe UI'; font-size: 8.5pt; }
QGroupBox { border: 1px solid #2c323b; border-radius: 5px; margin-top: 7px; padding-top: 3px; }
QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 4px; color: #9aa4b2; font-size: 8pt; font-weight: bold; }
QLineEdit, QComboBox, QSpinBox { background: #1f242b; border: 1px solid #343b46; border-radius: 4px; padding: 1px 5px; font-size: 8pt; }
QPushButton { background: #252b34; border: 1px solid #3a424e; border-radius: 4px; padding: 2px 8px; font-size: 8pt; }
QPushButton:hover { background: #2f3742; }
QPushButton:disabled { color: #666; }
QPushButton:checked { background: #b71c1c; border-color: #ff5252; color: white; font-weight: bold; }
QPushButton#connect { background: #1b5e20; border-color: #43a047; font-weight: bold; }
QPushButton#connect:checked { background: #7f1d1d; border-color: #ef5350; }
QPushButton#decel:checked { background: #e65100; border-color: #ffab40; }
QPushButton#mapGuideBtn { background: #1c2027; border: 1px solid #2c323b; border-radius: 4px; padding: 2px 4px; color: #9aa4b2; font-size: 8pt; font-weight: bold; }
QPushButton#mapGuideBtn:hover { background: #252b34; color: #ffffff; }
QPushButton#mapGuideBtn:checked { background: #0d47a1; border: 1px solid #40c4ff; color: #ffffff; font-weight: bold; }
QPlainTextEdit, QTableWidget { background: #0f1115; border: 1px solid #2c323b; font-family: Consolas; font-size: 8pt; }
QHeaderView::section { background: #1f242b; border: none; padding: 2px; font-size: 7.5pt; font-weight: bold; color: #b0bec5; }
QTabWidget::pane { border: 1px solid #2c323b; }
QTabBar::tab { background: #1c2027; padding: 4px 8px; border: 1px solid #2c323b; border-bottom: none; border-top-left-radius: 4px; border-top-right-radius: 4px; font-size: 8pt; font-weight: bold; color: #9aa4b2; margin-right: 1px; }
QTabBar::tab:selected { background: #2c323b; color: #ffffff; border-top: 2px solid #40c4ff; }
QStatusBar { background: #0f1115; font-size: 8pt; }
QFrame#card { background: #1c2027; border: 1.5px solid #2c323b; border-radius: 5px; }
QFrame#card[state="warn"] { border-color: #ffc107; background: #3a3214; }
QFrame#card[state="alarm"] { border-color: #ff1744; background: #3d1418; }
QFrame#card[state="stale"] { border-color: #2c323b; background: #17191d; }
QLabel#cardTitle { color: #9aa4b2; font-size: 8pt; font-weight: bold; background: transparent; }
QLabel#cardValue { font-size: 13.5pt; font-weight: bold; background: transparent; font-family: 'Consolas', 'JetBrains Mono', 'Courier New', monospace; }
QLabel#cardUnit { color: #78909c; font-size: 7.5pt; margin-bottom: 1px; background: transparent; }
QLabel#cardNote { color: #ffab40; font-size: 7pt; font-weight: bold; background: transparent; }
QLabel#cardPeaks { color: #78909c; font-size: 7pt; background: transparent; font-family: 'Consolas', 'JetBrains Mono', monospace; }
QLabel#protoBadge { padding: 2px 6px; border-radius: 4px; font-weight: bold; font-size: 8pt; }
QLabel#protoBadge[fallback="true"] { background: #e65100; color: #ffffff; }
QLabel#protoBadge[fallback="false"] { background: #1b5e20; color: #a5d6a7; border: 1px solid #2e7d32; }
"""
