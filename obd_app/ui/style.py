"""Tema escuro da aplicação."""

COLORS = {
    "rpm": "#ff5252",
    "tps": "#40c4ff",
    "map": "#b2ff59",
    "lambda_v": "#ffd740",
    "lambda2_v": "#ff80ab",  # Sonda 2 pós-catalisador (rosa/magenta suave para contraste com Sonda 1)
    "advance": "#e040fb",
    "stft": "#69f0ae",
    "ltft": "#ff9100",
}

STYLE = """
QWidget { background: #15181d; color: #e6e6e6; font-family: 'Segoe UI'; font-size: 9pt; }
QGroupBox { border: 1px solid #2c323b; border-radius: 5px; margin-top: 8px; padding-top: 4px; }
QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 4px; color: #9aa4b2; font-size: 8.5pt; font-weight: bold; }
QLineEdit, QComboBox, QSpinBox { background: #1f242b; border: 1px solid #343b46; border-radius: 4px; padding: 2px 6px; }
QPushButton { background: #252b34; border: 1px solid #3a424e; border-radius: 4px; padding: 3px 10px; }
QPushButton:hover { background: #2f3742; }
QPushButton:disabled { color: #666; }
QPushButton:checked { background: #b71c1c; border-color: #ff5252; color: white; font-weight: bold; }
QPushButton#connect { background: #1b5e20; border-color: #43a047; font-weight: bold; }
QPushButton#connect:checked { background: #7f1d1d; border-color: #ef5350; }
QPushButton#decel:checked { background: #e65100; border-color: #ffab40; }
QPlainTextEdit, QTableWidget { background: #0f1115; border: 1px solid #2c323b; font-family: Consolas; font-size: 8.5pt; }
QHeaderView::section { background: #1f242b; border: none; padding: 3px; font-size: 8.5pt; }
QTabWidget::pane { border: 1px solid #2c323b; }
QTabBar::tab { background: #1f242b; padding: 4px 10px; border-top-left-radius: 4px; border-top-right-radius: 4px; font-size: 8.5pt; }
QTabBar::tab:selected { background: #2c323b; }
QStatusBar { background: #0f1115; font-size: 8.5pt; }
QFrame#card { background: #1c2027; border: 1.5px solid #2c323b; border-radius: 6px; }
QFrame#card[state="warn"] { border-color: #ffc107; background: #3a3214; }
QFrame#card[state="alarm"] { border-color: #ff1744; background: #3d1418; }
QFrame#card[state="stale"] { border-color: #2c323b; background: #17191d; }
QLabel#cardTitle { color: #9aa4b2; font-size: 8.5pt; font-weight: bold; background: transparent; }
QLabel#cardValue { font-size: 15pt; font-weight: bold; background: transparent; font-family: 'Consolas', 'JetBrains Mono', monospace; font-variant-numeric: tabular-nums; }
QLabel#cardUnit { color: #78909c; font-size: 8pt; margin-bottom: 2px; background: transparent; }
QLabel#cardNote { color: #ffab40; font-size: 7.5pt; font-weight: bold; background: transparent; }
QLabel#cardPeaks { color: #78909c; font-size: 7.5pt; background: transparent; font-family: 'Consolas', 'JetBrains Mono', monospace; }
QLabel#protoBadge { padding: 2px 8px; border-radius: 4px; font-weight: bold; font-size: 8pt; }
QLabel#protoBadge[fallback="true"] { background: #e65100; color: #ffffff; }
QLabel#protoBadge[fallback="false"] { background: #1b5e20; color: #a5d6a7; border: 1px solid #2e7d32; }

"""
