"""Aba de Mapa 2D de Calibração e Diagnóstico (RPM × MAP).

Matriz interativa que acumula a média de Avanço (°), STFT (%) ou Sonda (V) em cada
faixa de rotação e carga, permitindo visualizar com precisão buracos de retardo (-19°)
ou desvios de malha de combustível tanto em tempo real quanto em replay de CSV.
"""
from __future__ import annotations

from typing import Dict, List, Optional, Tuple
from PyQt6.QtCore import Qt
from PyQt6.QtGui import QColor, QFont
from PyQt6.QtWidgets import (QComboBox, QFrame, QHBoxLayout, QHeaderView, QLabel,
                             QPushButton, QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget)

RPM_BINS = [700, 1000, 1400, 1800, 2200, 2600, 3000, 3500, 4000, 4500, 5000, 5500]
MAP_BINS = [100, 90, 80, 70, 60, 50, 40, 30, 20]  # WOT (100) no topo, Vácuo máx (20) na base


def _find_bin(val: float, bins: List[float]) -> int:
    """Retorna o índice do bin mais próximo."""
    best_i = 0
    best_d = abs(val - bins[0])
    for i, b in enumerate(bins):
        d = abs(val - b)
        if d < best_d:
            best_d = d
            best_i = i
    return best_i


def _color_for_value(metric: str, v: float) -> Tuple[QColor, QColor]:
    """Retorna (QColor fundo, QColor texto) em gradiente térmico."""
    if metric == "advance":
        # Avanço de Ignição
        if v < -8.0:
            return QColor("#880e4f"), QColor("#ffffff")  # Retardo extremo (-19°), alerta roxo/magenta
        elif v < -0.5:
            return QColor("#b71c1c"), QColor("#ffffff")  # Retardo ATDC (vermelho)
        elif v < 10.0:
            return QColor("#e65100"), QColor("#ffffff")  # Baixo avanço (laranja)
        elif v < 22.0:
            return QColor("#f57f17"), QColor("#15181d")  # Avanço moderado (âmbar)
        elif v < 35.0:
            return QColor("#1b5e20"), QColor("#ffffff")  # Avanço típico (verde)
        else:
            return QColor("#00695c"), QColor("#ffffff")  # Alto avanço (azul esverdeado)

    elif metric == "stft":
        # Short Term Fuel Trim (%)
        if v < -10.0:
            return QColor("#0d47a1"), QColor("#ffffff")  # Mistura muito rica sendo corrigida (azul)
        elif v < -3.0:
            return QColor("#0288d1"), QColor("#ffffff")  # Leve correção negativa (ciano)
        elif v <= 3.0:
            return QColor("#1b5e20"), QColor("#ffffff")  # Quase estequiométrico 0% (verde)
        elif v <= 10.0:
            return QColor("#f57f17"), QColor("#15181d")  # Leve enriquecimento (âmbar)
        else:
            return QColor("#b71c1c"), QColor("#ffffff")  # Mistura pobre extrema (+15%..+25%) (vermelho)

    else:
        # Sonda Lambda (V)
        if v < 0.20:
            return QColor("#0d47a1"), QColor("#ffffff")  # Pobre / Cut-off (< 0.2 V)
        elif v < 0.45:
            return QColor("#00838f"), QColor("#ffffff")
        elif v < 0.70:
            return QColor("#2e7d32"), QColor("#ffffff")  # Janela estequiométrica
        else:
            return QColor("#c62828"), QColor("#ffffff")  # Rica (> 0.7 V)


class Map2DWidget(QWidget):
    """Grid bidimensional RPM × MAP com células térmicas acumuladas."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.metrics = [
            ("Avanço de Ignição (°)", "advance", "{:.1f}°"),
            ("Correção STFT (%)", "stft", "{:+.1f}%"),
            ("Sonda Lambda 1 (V)", "lambda_v", "{:.3f}V"),
            ("Tempo de Injeção (ms)", "inj_ms", "{:.2f}ms"),
        ]
        self.cur_metric_idx = 0
        self._counts: Dict[str, Dict[Tuple[int, int], int]] = {m[1]: {} for m in self.metrics}
        self._sums: Dict[str, Dict[Tuple[int, int], float]] = {m[1]: {} for m in self.metrics}
        self._last_active_cell: Optional[Tuple[int, int]] = None

        self._build_ui()

    def _build_ui(self):
        vlay = QVBoxLayout(self)
        vlay.setContentsMargins(4, 4, 4, 4)
        vlay.setSpacing(4)

        # Barra de ferramentas superior
        top_bar = QHBoxLayout()
        top_bar.setContentsMargins(0, 0, 0, 0)

        lbl = QLabel("Parâmetro do Mapa:")
        lbl.setStyleSheet("font-weight: bold; color: #cfd8dc;")
        top_bar.addWidget(lbl)

        self.cb_metric = QComboBox()
        for label, _, _ in self.metrics:
            self.cb_metric.addItem(label)
        self.cb_metric.currentIndexChanged.connect(self._on_metric_changed)
        top_bar.addWidget(self.cb_metric)

        self.active_info = QLabel("Ponto de Operação: --")
        self.active_info.setStyleSheet("color: #ffd54f; font-weight: bold; margin-left: 12px;")
        top_bar.addWidget(self.active_info)

        top_bar.addStretch()

        self.btn_clear = QPushButton("⚡ Limpar Matriz")
        self.btn_clear.clicked.connect(self.clear_data)
        top_bar.addWidget(self.btn_clear)

        vlay.addLayout(top_bar)

        # Grade QTableWidget
        self.table = QTableWidget(len(MAP_BINS), len(RPM_BINS))
        self.table.setHorizontalHeaderLabels([f"{r} rpm" for r in RPM_BINS])
        self.table.setVerticalHeaderLabels([f"{m} kPa" for m in MAP_BINS])

        hh = self.table.horizontalHeader()
        hh.setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        vh = self.table.verticalHeader()
        vh.setSectionResizeMode(QHeaderView.ResizeMode.Stretch)

        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.table.setSelectionMode(QTableWidget.SelectionMode.NoSelection)

        # Inicializa células vazias
        for r in range(len(MAP_BINS)):
            for c in range(len(RPM_BINS)):
                item = QTableWidgetItem("--")
                item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
                item.setForeground(QColor("#546e7a"))
                item.setBackground(QColor("#13161b"))
                self.table.setItem(r, c, item)

        vlay.addWidget(self.table)

    def _on_metric_changed(self, idx: int):
        self.cur_metric_idx = idx
        self._refresh_all_cells()

    def clear_data(self):
        for m in self.metrics:
            k = m[1]
            self._counts[k].clear()
            self._sums[k].clear()
        self._last_active_cell = None
        self.active_info.setText("Ponto de Operação: --")
        self._refresh_all_cells()

    def add_sample(self, rpm: float, map_kpa: float, latest: Dict[str, float]) -> None:
        """Registra um ponto de telemetria na matriz."""
        if rpm <= 400 or map_kpa <= 5:
            return

        c = _find_bin(rpm, RPM_BINS)
        r = _find_bin(map_kpa, MAP_BINS)
        coord = (r, c)

        for _, key, _ in self.metrics:
            if key in latest and latest[key] is not None:
                val = latest[key]
                self._counts[key][coord] = self._counts[key].get(coord, 0) + 1
                self._sums[key][coord] = self._sums[key].get(coord, 0.0) + val

        cur_key = self.metrics[self.cur_metric_idx][1]
        cur_fmt = self.metrics[self.cur_metric_idx][2]
        val_str = cur_fmt.format(latest[cur_key]) if cur_key in latest else "--"
        self.active_info.setText(f"Ponto: {rpm:.0f} RPM × {map_kpa:.0f} kPa | Atual: {val_str}")

        self._update_cell(r, c)
        self._last_active_cell = coord

    def _update_cell(self, r: int, c: int):
        coord = (r, c)
        cur_key = self.metrics[self.cur_metric_idx][1]
        cur_fmt = self.metrics[self.cur_metric_idx][2]
        cnt = self._counts[cur_key].get(coord, 0)

        item = self.table.item(r, c)
        if not item:
            item = QTableWidgetItem()
            self.table.setItem(r, c, item)

        if cnt > 0:
            avg = self._sums[cur_key][coord] / cnt
            bg, fg = _color_for_value(cur_key, avg)
            item.setText(cur_fmt.format(avg))
            item.setForeground(fg)
            item.setBackground(bg)
            font = QFont("Consolas", 8, QFont.Weight.Bold)
            item.setFont(font)
        else:
            item.setText("--")
            item.setForeground(QColor("#546e7a"))
            item.setBackground(QColor("#13161b"))

    def _refresh_all_cells(self):
        for r in range(len(MAP_BINS)):
            for c in range(len(RPM_BINS)):
                self._update_cell(r, c)
