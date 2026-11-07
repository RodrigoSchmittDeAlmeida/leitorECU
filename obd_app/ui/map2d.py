"""Aba de Mapa 2D de Calibração e Diagnóstico (RPM × MAP).

Matriz interativa que acumula a média de Avanço (°), STFT (%), Sonda (V), Injeção (ms),
Bateria (V) ou Etanol (%) em cada faixa de rotação e carga, com seleção direta por guias
visíveis na tela (sem setas de rolagem) e ajuste integral dentro do container.
"""
from __future__ import annotations

from typing import Dict, List, Optional, Tuple
from PyQt6.QtCore import Qt
from PyQt6.QtGui import QColor, QFont
from PyQt6.QtWidgets import (QButtonGroup, QComboBox, QHBoxLayout, QHeaderView, QLabel,
                             QPushButton, QSizePolicy, QTableWidget, QTableWidgetItem,
                             QVBoxLayout, QWidget)

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

    elif metric == "battery":
        if v < 12.0:
            return QColor("#b71c1c"), QColor("#ffffff")  # Queda severa (< 12.0 V)
        elif v < 13.2:
            return QColor("#f57f17"), QColor("#15181d")  # Alternador baixo / sem carga
        elif v <= 14.6:
            return QColor("#1b5e20"), QColor("#ffffff")  # Carga ideal (13.2 - 14.6 V)
        else:
            return QColor("#880e4f"), QColor("#ffffff")  # Sobretensão (> 14.6 V)

    elif metric == "inj_ms":
        if v < 1.5:
            return QColor("#0d47a1"), QColor("#ffffff")  # Cut-off / pulso mínimo
        elif v < 4.5:
            return QColor("#1b5e20"), QColor("#ffffff")  # Lenta / cruzeiro leve
        elif v < 9.0:
            return QColor("#f57f17"), QColor("#15181d")  # Carga média
        else:
            return QColor("#b71c1c"), QColor("#ffffff")  # Plena carga / enriquecimento

    elif metric == "flex_ethanol_pct":
        if v < 30.0:
            return QColor("#e65100"), QColor("#ffffff")  # Gasolina E27
        elif v < 70.0:
            return QColor("#f57f17"), QColor("#15181d")  # Mistura Flex intermediária
        else:
            return QColor("#1b5e20"), QColor("#ffffff")  # Etanol E100

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
    """Grid bidimensional RPM × MAP com guias diretas de parâmetros e ajuste fixo sem scroll."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        self.metrics = [
            ("Avanço (°)", "advance", "{:.1f}°"),
            ("STFT (%)", "stft", "{:+.1f}%"),
            ("Sonda 1 (V)", "lambda_v", "{:.3f}V"),
            ("Injeção (ms)", "inj_ms", "{:.2f}ms"),
            ("Bateria (V)", "battery", "{:.2f}V"),
            ("Etanol (%)", "flex_ethanol_pct", "{:.0f}%"),
        ]
        self.cur_metric_idx = 0
        self._counts: Dict[str, Dict[Tuple[int, int], int]] = {m[1]: {} for m in self.metrics}
        self._sums: Dict[str, Dict[Tuple[int, int], float]] = {m[1]: {} for m in self.metrics}
        self._last_active_cell: Optional[Tuple[int, int]] = None
        self.metric_buttons: List[QPushButton] = []

        self._build_ui()

    def _build_ui(self):
        vlay = QVBoxLayout(self)
        vlay.setContentsMargins(3, 3, 3, 3)
        vlay.setSpacing(3)

        # Linha 1: Guias visíveis lado a lado para todos os parâmetros do Mapa 2D (sem setas/dropdown)
        guides_bar = QHBoxLayout()
        guides_bar.setContentsMargins(0, 0, 0, 0)
        guides_bar.setSpacing(3)

        self.btn_group = QButtonGroup(self)
        self.btn_group.setExclusive(True)

        # Mantém cb_metric oculto e sincronizado para compatibilidade com testes/chamadores externos
        self.cb_metric = QComboBox(self)
        self.cb_metric.setVisible(False)

        for idx, (label, _, _) in enumerate(self.metrics):
            self.cb_metric.addItem(label)
            btn = QPushButton(label)
            btn.setCheckable(True)
            btn.setObjectName("mapGuideBtn")
            btn.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
            btn.setFixedHeight(24)
            if idx == 0:
                btn.setChecked(True)
            self.btn_group.addButton(btn, idx)
            guides_bar.addWidget(btn)
            self.metric_buttons.append(btn)

        self.btn_group.idClicked.connect(self._on_guide_clicked)
        self.cb_metric.currentIndexChanged.connect(self._on_metric_changed)
        vlay.addLayout(guides_bar)

        # Linha 2: Ponto de operação atual + botão limpar
        info_bar = QHBoxLayout()
        info_bar.setContentsMargins(0, 0, 0, 0)
        info_bar.setSpacing(6)

        self.active_info = QLabel("Ponto de Operação: --")
        self.active_info.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)
        self.active_info.setFixedHeight(22)
        self.active_info.setStyleSheet("color: #ffd54f; font-weight: bold; font-size: 8.5pt;")
        info_bar.addWidget(self.active_info, 1)

        self.btn_clear = QPushButton("Limpar Matriz")
        self.btn_clear.setFixedHeight(22)
        self.btn_clear.clicked.connect(self.clear_data)
        info_bar.addWidget(self.btn_clear)
        vlay.addLayout(info_bar)

        # Grade QTableWidget 100% ajustada sem barras de rolagem
        self.table = QTableWidget(len(MAP_BINS), len(RPM_BINS))
        self.table.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Ignored)
        self.table.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.table.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.table.setHorizontalHeaderLabels([f"{r}" for r in RPM_BINS])
        self.table.setVerticalHeaderLabels([f"{m} kPa" for m in MAP_BINS])

        hh = self.table.horizontalHeader()
        hh.setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        hh.setMinimumSectionSize(24)
        hh.setFixedHeight(22)
        vh = self.table.verticalHeader()
        vh.setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        vh.setMinimumSectionSize(18)
        vh.setFixedWidth(48)

        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.table.setSelectionMode(QTableWidget.SelectionMode.NoSelection)
        self.table.setFocusPolicy(Qt.FocusPolicy.NoFocus)

        for r in range(len(MAP_BINS)):
            for c in range(len(RPM_BINS)):
                item = QTableWidgetItem("--")
                item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
                item.setForeground(QColor("#546e7a"))
                item.setBackground(QColor("#13161b"))
                self.table.setItem(r, c, item)

        vlay.addWidget(self.table, 1)

    def _on_guide_clicked(self, idx: int):
        if 0 <= idx < len(self.metrics):
            self.cur_metric_idx = idx
            self.cb_metric.blockSignals(True)
            self.cb_metric.setCurrentIndex(idx)
            self.cb_metric.blockSignals(False)
            self._refresh_all_cells()

    def _on_metric_changed(self, idx: int):
        if 0 <= idx < len(self.metrics):
            self.cur_metric_idx = idx
            if idx < len(self.metric_buttons):
                self.metric_buttons[idx].setChecked(True)
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
        val_str = cur_fmt.format(latest[cur_key]) if cur_key in latest and latest[cur_key] is not None else "--"
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
            font = QFont("Consolas", 7, QFont.Weight.Bold)
            item.setFont(font)
        else:
            item.setText("--")
            item.setForeground(QColor("#546e7a"))
            item.setBackground(QColor("#13161b"))

    def _refresh_all_cells(self):
        for r in range(len(MAP_BINS)):
            for c in range(len(RPM_BINS)):
                self._update_cell(r, c)
