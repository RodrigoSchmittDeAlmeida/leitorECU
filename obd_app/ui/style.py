"""Design system dark motorsport para a estação de diagnóstico."""

TOKENS = {
    "base": "#0D1015",
    "surface": "#151921",
    "elevated": "#1D232D",
    "plot": "#0A0C10",
    "border": "#2C3545",
    "text": "#E8EDF5",
    "muted": "#8B98AB",
    "stale": "#607088",
    "ok": "#00E676",
    "warning": "#FFB300",
    "alarm": "#FF3D71",
    "info": "#00D2FF",
}

COLORS = {
    "rpm": "#FF3D71",
    "tps": "#00D2FF",
    "map": "#A8FF60",
    "lambda_v": "#FFD740",
    "lambda2_v": "#FF72B6",
    "advance": "#B86BFF",
    "stft": "#00E676",
    "ltft": "#FFB300",
    "battery": "#65A7FF",
    "obd_pin16_v": "#57E2FF",
    "ecu_volt": "#65A7FF",
    "bcm_battery_v": "#00D2FF",
    "inj_ms": "#FFB300",
    "inj_pulse_width": "#FFB300",
    "ect": "#FF7043",
    "iat": "#84FFFF",
    "cht_temp": "#FF8A65",
    "cat_temp": "#FF3D71",
    "load": "#B86BFF",
    "speed": "#00E676",
    "flex_ethanol_pct": "#A8FF60",
    "ethanol": "#A8FF60",
    "app_pedal_pct": "#00D2FF",
    "ac_pressure_kpa": "#57E2FF",
    "wheel_speed_fl": "#00D2FF",
    "wheel_speed_fr": "#57E2FF",
    "wheel_speed_rl": "#82B1FF",
    "wheel_speed_rr": "#B86BFF",
    "steering_wheel_angle": "#FFD740",
    "knock_ret_c1": "#FF3D71",
    "knock_v_c1": "#FFB300",
    "lambda_trim": "#00E676",
}

STYLE = """
QWidget {
    background: #0D1015;
    color: #E8EDF5;
    font-family: Inter, "SF Pro Display", "Segoe UI";
    font-size: 9pt;
}
QMainWindow { background: #0D1015; }
QFrame#connectionBar { background: #151921; border: 1px solid #2C3545; border-radius: 6px; }
QGroupBox {
    background: #151921;
    border: 1px solid #2C3545;
    border-radius: 6px;
    margin-top: 9px;
    padding-top: 5px;
    font-weight: 600;
}
QGroupBox::title {
    subcontrol-origin: margin;
    left: 9px;
    padding: 0 5px;
    color: #8B98AB;
    font-size: 8pt;
    font-weight: 700;
}
QLineEdit, QComboBox, QSpinBox {
    min-height: 24px;
    background: #1D232D;
    border: 1px solid #2C3545;
    border-radius: 5px;
    padding: 1px 7px;
    selection-background-color: #00D2FF;
    selection-color: #0D1015;
}
QLineEdit:focus, QComboBox:focus, QSpinBox:focus { border-color: #00D2FF; }
QComboBox::drop-down { border: 0; width: 18px; }
QComboBox QAbstractItemView {
    background: #1D232D;
    border: 1px solid #2C3545;
    selection-background-color: #2C3545;
    outline: 0;
}
QPushButton {
    min-height: 24px;
    background: #1D232D;
    border: 1px solid #364258;
    border-radius: 5px;
    padding: 1px 9px;
    font-weight: 600;
}
QPushButton:hover { background: #252E3A; border-color: #607088; }
QPushButton:pressed { background: #11151C; }
QPushButton:disabled { color: #566174; border-color: #252D3A; }
QPushButton:checked { background: #47202C; border-color: #FF3D71; color: #FFF3F7; }
QPushButton#connect {
    min-width: 112px;
    background: #073B29;
    border: 1px solid #00E676;
    color: #A9FFD3;
    font-weight: 800;
}
QPushButton#connect:hover { background: #09543A; }
QPushButton#connect:checked { background: #511D2B; border-color: #FF3D71; color: #FFD6E0; }
QPushButton#decel:checked { background: #493512; border-color: #FFB300; color: #FFE2A1; }
QPushButton#record:checked { background: #531426; border-color: #FF3D71; color: #FFD6E0; }
QCheckBox { spacing: 5px; color: #B8C2D0; }
QCheckBox::indicator {
    width: 13px; height: 13px;
    border: 1px solid #607088;
    border-radius: 3px;
    background: #151921;
}
QCheckBox::indicator:checked { background: #00D2FF; border-color: #00D2FF; }
QPlainTextEdit, QTableWidget {
    background: #0A0C10;
    alternate-background-color: #11151C;
    border: 1px solid #2C3545;
    border-radius: 5px;
    gridline-color: #222A36;
    font-family: "JetBrains Mono", "Roboto Mono", Consolas;
    font-size: 8pt;
}
QHeaderView::section {
    background: #1D232D;
    color: #AEB9C8;
    border: 0;
    border-right: 1px solid #2C3545;
    border-bottom: 1px solid #2C3545;
    padding: 4px;
    font-size: 8pt;
    font-weight: 700;
}
QTabWidget::pane {
    background: #151921;
    border: 1px solid #2C3545;
    border-radius: 0 0 6px 6px;
}
QTabBar { qproperty-drawBase: 0; }
QTabBar::tab {
    min-width: 70px;
    background: #151921;
    color: #8B98AB;
    padding: 7px 10px;
    border: 1px solid transparent;
    border-bottom-color: #2C3545;
    font-size: 8pt;
    font-weight: 700;
}
QTabBar::tab:hover { color: #E8EDF5; background: #1D232D; }
QTabBar::tab:selected {
    color: #00D2FF;
    background: #1D232D;
    border-color: #2C3545;
    border-bottom-color: #00D2FF;
}
QTabBar::scroller { width: 0px; }
QSplitter::handle { background: #0D1015; width: 5px; }
QScrollBar:vertical { width: 8px; background: #0D1015; }
QScrollBar::handle:vertical { background: #364258; border-radius: 4px; min-height: 28px; }
QStatusBar { background: #0A0C10; color: #8B98AB; border-top: 1px solid #2C3545; font-size: 8pt; }

QFrame#card {
    min-height: 67px;
    max-height: 76px;
    background: #1D232D;
    border: 1px solid #2C3545;
    border-radius: 6px;
}
QFrame#card[state="normal"] { border-color: #344052; }
QFrame#card[state="warn"] { border-color: #8A6817; background: #211E16; }
QFrame#card[state="alarm"] { border-color: #8E2845; background: #24161B; }
QFrame#card[state="stale"] { border-color: #252E3B; background: #151921; }
QLabel#cardTitle {
    color: #AEB9C8; font-size: 7.5pt; font-weight: 650;
    background: transparent;
}
QLabel#cardValue {
    font-size: 17pt; font-weight: 800; background: transparent;
    font-family: "JetBrains Mono", "Roboto Mono", Consolas;
}
QLabel#cardUnit { color: #8B98AB; font-size: 7.5pt; background: transparent; }
QLabel#cardNote {
    color: #8B98AB; background: transparent;
    padding: 1px 2px; font-size: 6.5pt; font-weight: 650;
}
QFrame#card[state="warn"] QLabel#cardNote { color: #FFB300; }
QFrame#card[state="alarm"] QLabel#cardNote { color: #FF8DA9; }
QFrame#card[state="stale"] QLabel#cardNote { color: #607088; }
QLabel#cardPeaks {
    color: #718096; font-size: 6.5pt; background: transparent;
    font-family: "JetBrains Mono", "Roboto Mono", Consolas;
}
QLabel#protoBadge, QLabel#statusPill, QLabel#rateBadge {
    padding: 3px 8px; border-radius: 5px; font-weight: 800; font-size: 7.5pt;
}
QLabel#protoBadge[fallback="true"] { background: #493512; color: #FFD26C; border: 1px solid #8A6817; }
QLabel#protoBadge[fallback="false"] { background: #103524; color: #71FFB2; border: 1px solid #176B45; }
QLabel#statusPill[state="offline"] { background: #421723; color: #FF8DA9; border: 1px solid #8E2845; }
QLabel#statusPill[state="connecting"] { background: #3C2E0E; color: #FFD26C; border: 1px solid #785B13; }
QLabel#statusPill[state="connected"] { background: #103524; color: #71FFB2; border: 1px solid #176B45; }
QLabel#rateBadge { background: #102E3A; color: #57E2FF; border: 1px solid #17576A; font-family: "JetBrains Mono", Consolas; }
QLabel#moduleMetric {
    background: #1D232D; color: #C8D1DE; border: 1px solid #2C3545;
    border-radius: 4px; padding: 3px 5px; font-size: 7.5pt;
}
QLabel#moduleSummary { color: #8B98AB; font-size: 8pt; font-weight: 600; }
QFrame#emptyState { background: #11151C; border: 1px dashed #2C3545; border-radius: 6px; }
QLabel#emptyStateTitle { color: #C8D1DE; font-size: 11pt; font-weight: 650; }
QLabel#emptyStateBody { color: #718096; font-size: 8.5pt; line-height: 1.4; }
QFrame#eventRibbon { background: #151921; border: 1px solid #2C3545; border-radius: 5px; }
QLabel#eventRibbonText { color: #8B98AB; font-size: 8pt; font-weight: 600; }
"""
