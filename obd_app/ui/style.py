"""Tema escuro da aplicação."""

COLORS = {
    "rpm": "#ff5252",
    "tps": "#40c4ff",
    "map": "#b2ff59",
    "lambda_v": "#ffd740",
    "advance": "#e040fb",
    "stft": "#69f0ae",
    "ltft": "#ff9100",
}

STYLE = """
QWidget { background: #15181d; color: #e6e6e6; font-family: 'Segoe UI'; font-size: 10pt; }
QGroupBox { border: 1px solid #2c323b; border-radius: 6px; margin-top: 10px; padding-top: 6px; }
QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 4px; color: #9aa4b2; }
QLineEdit, QComboBox, QSpinBox { background: #1f242b; border: 1px solid #343b46; border-radius: 4px; padding: 3px 6px; }
QPushButton { background: #252b34; border: 1px solid #3a424e; border-radius: 5px; padding: 5px 12px; }
QPushButton:hover { background: #2f3742; }
QPushButton:disabled { color: #666; }
QPushButton:checked { background: #b71c1c; border-color: #ff5252; color: white; font-weight: bold; }
QPushButton#connect { background: #1b5e20; border-color: #43a047; font-weight: bold; }
QPushButton#connect:checked { background: #7f1d1d; border-color: #ef5350; }
QPushButton#decel:checked { background: #e65100; border-color: #ffab40; }
QPlainTextEdit, QTableWidget { background: #0f1115; border: 1px solid #2c323b; font-family: Consolas; font-size: 9pt; }
QHeaderView::section { background: #1f242b; border: none; padding: 4px; }
QTabWidget::pane { border: 1px solid #2c323b; }
QTabBar::tab { background: #1f242b; padding: 6px 12px; border-top-left-radius: 4px; border-top-right-radius: 4px; }
QTabBar::tab:selected { background: #2c323b; }
QStatusBar { background: #0f1115; }
QFrame#card { background: #1c2027; border: 2px solid #2c323b; border-radius: 8px; }
QFrame#card[state="warn"] { border-color: #ffc107; background: #3a3214; }
QFrame#card[state="alarm"] { border-color: #ff1744; background: #3d1418; }
QFrame#card[state="stale"] { border-color: #2c323b; background: #17191d; }
QLabel#cardTitle { color: #9aa4b2; font-size: 9pt; background: transparent; }
QLabel#cardValue { font-size: 24pt; font-weight: bold; background: transparent; }
QLabel#cardUnit { color: #9aa4b2; font-size: 9pt; background: transparent; }
QLabel#cardNote { color: #ffab40; font-size: 8pt; font-weight: bold; background: transparent; }
"""
