"""Design system dark motorsport para a estação de diagnóstico."""

import os
import sys

def _get_check_svg_path() -> str:
    if hasattr(sys, "_MEIPASS"):
        bundled = os.path.join(sys._MEIPASS, "obd_app", "ui", "check.svg")
        if os.path.exists(bundled):
            return bundled.replace("\\", "/")
    return os.path.join(os.path.dirname(__file__), "check.svg").replace("\\", "/")

CHECK_SVG_PATH = _get_check_svg_path()

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
QFrame#connectionBar { background: #13171F; border: 1px solid #1E2532; border-radius: 0px; }
QGroupBox {
    background: #13171F;
    border: 1px solid #1E2532;
    border-radius: 0px;
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
    background: #181E27;
    border: 1px solid #232B38;
    border-radius: 0px;
    padding: 1px 7px;
    selection-background-color: #00D2FF;
    selection-color: #0D1015;
}
QLineEdit:focus, QComboBox:focus, QSpinBox:focus { border-color: #00D2FF; }
QComboBox::drop-down { border: 0; width: 18px; }
QComboBox QAbstractItemView {
    background: #181E27;
    border: 1px solid #232B38;
    border-radius: 0px;
    selection-background-color: #263345;
    outline: 0;
}
QPushButton {
    min-height: 24px;
    background: #1B222C;
    border: 1px solid #283344;
    border-radius: 0px;
    padding: 1px 9px;
    font-weight: 600;
}
QPushButton:hover { background: #232C3A; border-color: #43546D; }
QPushButton:pressed { background: #10141B; }
QPushButton:disabled { color: #566174; border-color: #202734; }
QPushButton:checked { background: #47202C; border-color: #FF3D71; color: #FFF3F7; }
QPushButton#connect {
    min-width: 112px;
    background: #073B29;
    border: 1px solid #00E676;
    border-radius: 0px;
    color: #A9FFD3;
    font-weight: 800;
}
QPushButton#connect:hover { background: #09543A; }
QPushButton#connect:checked { background: #511D2B; border-color: #FF3D71; color: #FFD6E0; }
QPushButton#decel:checked { background: #493512; border-color: #FFB300; color: #FFE2A1; }
QPushButton#record:checked { background: #531426; border-color: #FF3D71; color: #FFD6E0; }
QCheckBox { spacing: 6px; color: #A4B1C4; font-size: 8pt; font-weight: 600; }
QCheckBox::indicator {
    width: 13px; height: 13px;
    border: 1px solid #323C4D;
    border-radius: 0px;
    background: #12161F;
}
QCheckBox::indicator:hover {
    border-color: #48566E;
}
QCheckBox::indicator:checked {
    background: #236B7A;
    border-color: #2E8194;
    image: url("__CHECK_SVG_PATH__");
}
QPlainTextEdit, QTableWidget {
    background: #0A0C10;
    alternate-background-color: #11151C;
    border: 1px solid #1E2532;
    border-radius: 0px;
    gridline-color: #1A212B;
    font-family: "JetBrains Mono", "Roboto Mono", Consolas, monospace;
    font-size: 8pt;
}
QTableWidget::item:selected {
    border: 2px solid #00D2FF;
    background-color: #162638;
}
QHeaderView::section {
    background: #181E27;
    color: #AEB9C8;
    border: 0;
    border-right: 1px solid #1E2532;
    border-bottom: 1px solid #1E2532;
    padding: 4px;
    font-family: "JetBrains Mono", Consolas, monospace;
    font-size: 8pt;
    font-weight: 700;
}
QTabWidget::pane {
    background: #13171F;
    border: 1px solid #1E2532;
    border-radius: 0px;
}
QTabBar { qproperty-drawBase: 0; }
QTabBar::tab {
    min-width: 70px;
    background: #13171F;
    color: #8B98AB;
    padding: 7px 10px;
    border: 1px solid transparent;
    border-bottom-color: #1E2532;
    border-radius: 0px;
    font-size: 8pt;
    font-weight: 700;
}
QTabBar::tab:hover { color: #E8EDF5; background: #1B222C; }
QTabBar::tab:selected {
    color: #00D2FF;
    background: #1B222C;
    border-color: #1E2532;
    border-bottom-color: #00D2FF;
}
QTabBar::scroller { width: 0px; }
QSplitter::handle { background: #0D1015; width: 5px; }
QScrollBar:vertical { width: 8px; background: #0D1015; }
QScrollBar::handle:vertical { background: #2E384A; border-radius: 0px; min-height: 28px; }
QScrollBar:horizontal { height: 8px; background: #0D1015; }
QScrollBar::handle:horizontal { background: #2E384A; border-radius: 0px; min-width: 28px; }
QStatusBar { background: #0A0C10; color: #8B98AB; border-top: 1px solid #1E2532; font-size: 8pt; }
QDialog { background: #0D1015; }
QToolTip {
    background: #181E27;
    color: #E8EDF5;
    border: 1px solid #2E384A;
    border-radius: 0px;
    padding: 3px 6px;
    font-family: Inter, "Segoe UI";
    font-size: 8pt;
}
QMenu {
    background: #181E27;
    border: 1px solid #232B38;
    border-radius: 0px;
    padding: 2px;
}
QMenu::item { padding: 4px 16px; border-radius: 0px; }
QMenu::item:selected { background: #232C3A; color: #00D2FF; }

QFrame#card {
    min-height: 67px;
    max-height: 76px;
    background: #151A22;
    border: 1px solid #1E2532;
    border-radius: 0px;
}
QFrame#card[state="normal"] { border-color: #242E3E; background: #151A22; }
QFrame#card[state="warn"] { border-color: #614612; background: #1D1A13; }
QFrame#card[state="alarm"] { border-color: #691C2F; background: #201317; }
QFrame#card[state="stale"] { border-color: #1A202A; background: #12151C; }
QLabel#cardTitle {
    color: #8B98AB; font-size: 7.5pt; font-weight: 700;
    background: transparent; border: none;
}
QLabel#cardValue {
    font-size: 16pt; font-weight: 800; background: transparent;
    font-family: "JetBrains Mono", "Roboto Mono", Consolas, monospace;
}
QLabel#cardUnit { color: #718096; font-size: 7.5pt; background: transparent; border: none; }
QLabel#cardNote {
    color: #8B98AB; background: transparent;
    padding: 1px 2px; font-size: 6.5pt; font-weight: 650;
}
QFrame#card[state="warn"] QLabel#cardNote { color: #FFB300; }
QFrame#card[state="alarm"] QLabel#cardNote { color: #FF8DA9; }
QFrame#card[state="stale"] QLabel#cardNote { color: #56657F; }
QLabel#cardPeaks {
    color: #607085; font-size: 6.5pt; background: transparent;
    font-family: "JetBrains Mono", "Roboto Mono", Consolas, monospace;
}
QLabel#protoBadge, QLabel#statusPill, QLabel#rateBadge {
    padding: 3px 8px; border-radius: 0px; font-weight: 800; font-size: 7.5pt;
}
QLabel#protoBadge[state="offline"], QLabel#protoBadge[state="standby"] {
    background: #161C24; color: #738294; border: 1px solid #222B38;
}
QLabel#protoBadge[fallback="true"] { background: #382A0B; color: #FFD26C; border: 1px solid #664E14; }
QLabel#protoBadge[fallback="false"] { background: #0E2E1F; color: #71FFB2; border: 1px solid #145939; }
QLabel#statusPill[state="offline"] { background: #38161E; color: #FF8DA9; border: 1px solid #631B2D; }
QLabel#statusPill[state="connecting"] { background: #352608; color: #FFD26C; border: 1px solid #6B4E10; }
QLabel#statusPill[state="connected"] { background: #0E2E1F; color: #71FFB2; border: 1px solid #145939; }
QLabel#rateBadge { background: #0E2530; color: #57E2FF; border: 1px solid #144959; font-family: "JetBrains Mono", Consolas, monospace; }
QLabel#sectionLabel {
    color: #7E8E9F; font-size: 7.5pt; font-weight: 800;
    text-transform: uppercase; background: transparent; border: none; padding: 0 2px;
}
QLabel#moduleMetric {
    background: #181E27; color: #C8D1DE; border: 1px solid #232B38;
    border-radius: 0px; padding: 3px 5px; font-size: 7.5pt;
}
QLabel#moduleSummary { color: #8B98AB; font-size: 8pt; font-weight: 600; }
QFrame#emptyState { background: #11151C; border: 1px dashed #232B38; border-radius: 0px; }
QLabel#emptyStateTitle { color: #C8D1DE; font-size: 11pt; font-weight: 650; }
QLabel#emptyStateBody { color: #718096; font-size: 8.5pt; line-height: 1.4; }
QFrame#eventRibbon { background: #13171F; border: 1px solid #1E2532; border-radius: 0px; }
QLabel#eventRibbonText { color: #8B98AB; font-size: 8pt; font-weight: 600; }
""".replace("__CHECK_SVG_PATH__", CHECK_SVG_PATH)
