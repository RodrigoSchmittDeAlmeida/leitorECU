"""Aba de Mapa 2D de Calibração e Diagnóstico (RPM × MAP).

Matriz interativa que acumula a média de Avanço (°), STFT (%) ou Sonda (V) em cada
faixa de rotação e carga, permitindo visualizar com precisão buracos de retardo (-19°)
ou desvios de malha de combustível tanto em tempo real quanto em replay de CSV.
"""
from __future__ import annotations

from typing import Dict, List, Optional, Tuple
from PyQt6.QtCore import QSize, Qt
from PyQt6.QtGui import QColor, QFont
from PyQt6.QtWidgets import (QComboBox, QFrame, QHBoxLayout, QHeaderView, QLabel,
                             QPushButton, QSizePolicy, QTableWidget, QTableWidgetItem, QVBoxLayout, QWidget)

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
    """Retorna (QColor fundo, QColor texto) em gradiente térmico dessaturado profissional."""
    if metric == "advance":
        # Avanço de Ignição
        if v < -8.0:
            return QColor("#880e4f"), QColor("#ffffff")  # Retardo extremo (-19°), magenta escuro
        elif v < -0.5:
            return QColor("#8a1c1c"), QColor("#ffffff")  # Retardo ATDC (rubi escuro)
        elif v < 10.0:
            return QColor("#8c4611"), QColor("#ffffff")  # Baixo avanço (castanho âmbar)
        elif v < 22.0:
            return QColor("#665914"), QColor("#ffffff")  # Avanço moderado (oliva escuro)
        elif v < 35.0:
            return QColor("#1b5e20"), QColor("#ffffff")  # Avanço típico (verde escuro)
        else:
            return QColor("#005c51"), QColor("#ffffff")  # Alto avanço (teal escuro)

    elif metric == "stft":
        # Short Term Fuel Trim (%)
        if v < -10.0:
            return QColor("#163254"), QColor("#CFE5FF")  # Mistura muito rica sendo corrigida
        elif v < -3.0:
            return QColor("#124357"), QColor("#BEEBF7")  # Leve correção negativa
        elif v <= 3.0:
            return QColor("#173E28"), QColor("#C6F7D7")  # Quase estequiométrico 0%
        elif v <= 10.0:
            return QColor("#4C3912"), QColor("#FFE4A8")  # Leve enriquecimento
        else:
            return QColor("#5A1D23"), QColor("#FFD8DC")  # Mistura pobre extrema (+15%..+25%)

    elif metric == "lambda_v":
        # Sonda Lambda (V)
        if v < 0.20:
            return QColor("#163254"), QColor("#CFE5FF")  # Pobre / Cut-off (< 0.2 V)
        elif v < 0.45:
            return QColor("#124357"), QColor("#BEEBF7")
        elif v < 0.70:
            return QColor("#173E28"), QColor("#C6F7D7")  # Janela estequiométrica
        else:
            return QColor("#5A1D23"), QColor("#FFD8DC")  # Rica (> 0.7 V)
    elif metric == "battery":
        if v < 12.0 or v > 15.0:
            return QColor("#521B27"), QColor("#FFD3DE")
        if v < 13.2:
            return QColor("#4D3B12"), QColor("#FFE6B3")
        return QColor("#173E28"), QColor("#C6F7D7")
    elif metric == "flex_ethanol_pct":
        if v < 30.0:
            return QColor("#163254"), QColor("#CFE5FF")
        if v < 70.0:
            return QColor("#173E28"), QColor("#C6F7D7")
        return QColor("#4D3B12"), QColor("#FFE6B3")
    else:
        return QColor("#181E27"), QColor("#8B98AB")


class Map2DWidget(QWidget):
    """Grid bidimensional RPM × MAP com células térmicas acumuladas."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.metrics = [
            ("Avanço (°)", "advance", "{:.1f}°"),
            ("STFT (%)", "stft", "{:+.1f}%"),
            ("Sonda 1 (V)", "lambda_v", "{:.3f}V"),
            ("Injeção (ms)", "inj_ms", "{:.2f}ms"),
            ("Bateria (V)", "battery", "{:.2f}V"),
            ("Etanol (%)", "flex_ethanol_pct", "{:.0f}%"),
        ]
        self.cur_metric_idx = 0
        self.cur_stat_idx = 0  # 0: Média, 1: Máximo, 2: Mínimo, 3: Contagem
        self._counts: Dict[str, Dict[Tuple[int, int], int]] = {m[1]: {} for m in self.metrics}
        self._sums: Dict[str, Dict[Tuple[int, int], float]] = {m[1]: {} for m in self.metrics}
        self._mins: Dict[str, Dict[Tuple[int, int], float]] = {m[1]: {} for m in self.metrics}
        self._maxs: Dict[str, Dict[Tuple[int, int], float]] = {m[1]: {} for m in self.metrics}
        self._last_active_cell: Optional[Tuple[int, int]] = None

        self._build_ui()

    def _build_ui(self):
        vlay = QVBoxLayout(self)
        vlay.setContentsMargins(4, 4, 4, 4)
        vlay.setSpacing(3)

        # Linha 1: Controles de Métrica, Modo estatístico e Ações
        top_bar = QHBoxLayout()
        top_bar.setContentsMargins(0, 0, 0, 0)
        top_bar.setSpacing(6)

        lbl = QLabel("MÉTRICA", objectName="sectionLabel")
        top_bar.addWidget(lbl)

        self.cb_metric = QComboBox()
        for label, _, _ in self.metrics:
            self.cb_metric.addItem(label)
        self.cb_metric.currentIndexChanged.connect(self._on_metric_changed)
        top_bar.addWidget(self.cb_metric)

        lbl_stat = QLabel("MODO", objectName="sectionLabel")
        top_bar.addWidget(lbl_stat)

        self.cb_stat = QComboBox()
        self.cb_stat.addItems(["Média", "Máximo", "Mínimo", "Contagem (Hits)"])
        self.cb_stat.currentIndexChanged.connect(self._on_stat_changed)
        top_bar.addWidget(self.cb_stat)

        top_bar.addStretch()

        self.btn_copy = QPushButton("Copiar Grade")
        self.btn_copy.setToolTip("Copia os dados da tabela no formato tabulado para colar no Excel ou TunerStudio.")
        self.btn_copy.clicked.connect(self._copy_grid_to_clipboard)
        top_bar.addWidget(self.btn_copy)

        self.btn_clear = QPushButton("Limpar matriz")
        self.btn_clear.clicked.connect(self.clear_data)
        top_bar.addWidget(self.btn_clear)

        vlay.addLayout(top_bar)

        # Linha 2: Ponto de Operação Ativo (sub-barra dedicada; largura desacoplada para não empurrar os gráficos)
        info_bar = QHBoxLayout()
        info_bar.setContentsMargins(0, 0, 0, 0)
        self.active_info = QLabel("Ponto de Operação: --")
        self.active_info.setStyleSheet(
            "color: #ffd54f; font-weight: bold; font-size: 8.5pt; "
            "background: #12161E; border: 1px solid #1E2532; border-radius: 0px; padding: 2px 6px;"
        )
        self.active_info.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)
        self.active_info.setMinimumWidth(0)
        info_bar.addWidget(self.active_info, 1)
        vlay.addLayout(info_bar)

        # Guia visual dos eixos da matriz (RPM horizontal × MAP vertical)
        axis_banner = QLabel("▲ EIXO VERTICAL: CARGA / MAP (kPa)    │    ► EIXO HORIZONTAL: ROTAÇÃO DO MOTOR (RPM)")
        axis_banner.setStyleSheet("color: #718096; font-size: 7.5pt; font-weight: 700; background: transparent; padding: 2px 0;")
        vlay.addWidget(axis_banner)

        # Grade QTableWidget
        self.table = QTableWidget(len(MAP_BINS), len(RPM_BINS))
        self.table.setHorizontalHeaderLabels([str(r) for r in RPM_BINS])
        self.table.setVerticalHeaderLabels([f"{m} kPa" for m in MAP_BINS])

        hh = self.table.horizontalHeader()
        hh.setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        hh.setMinimumSectionSize(22)
        vh = self.table.verticalHeader()
        vh.setSectionResizeMode(QHeaderView.ResizeMode.Stretch)
        vh.setMinimumSectionSize(16)

        self.table.setEditTriggers(QTableWidget.EditTrigger.NoEditTriggers)
        self.table.setSelectionMode(QTableWidget.SelectionMode.SingleSelection)
        self.table.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        self.setMinimumWidth(0)

        # Inicializa células vazias
        for r in range(len(MAP_BINS)):
            for c in range(len(RPM_BINS)):
                item = QTableWidgetItem("--")
                item.setTextAlignment(Qt.AlignmentFlag.AlignCenter)
                item.setForeground(QColor("#455263"))
                item.setBackground(QColor("#11151C"))
                self.table.setItem(r, c, item)

        vlay.addWidget(self.table, 1)

        legend = QHBoxLayout()
        legend.setSpacing(1)
        for text, color in (
            ("−20° RETARDO", "#880e4f"), ("−8°", "#8a1c1c"), ("0°", "#8c4611"),
            ("+10°", "#665914"), ("+22° ALVO", "#1b5e20"), ("+45° AVANÇO", "#005c51"),
        ):
            swatch = QLabel(text)
            swatch.setAlignment(Qt.AlignmentFlag.AlignCenter)
            swatch.setStyleSheet(
                f"background:{color}; color:#F5F7FA; padding:2px; font-size:7pt; font-weight:bold; border-radius:0px;"
            )
            swatch.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)
            swatch.setMinimumWidth(0)
            legend.addWidget(swatch, 1)
        vlay.addLayout(legend)

    def minimumSizeHint(self) -> QSize:
        return QSize(280, 140)

    def _on_metric_changed(self, idx: int):
        self.cur_metric_idx = idx
        self._refresh_all_cells()

    def _on_stat_changed(self, idx: int):
        self.cur_stat_idx = idx
        self._refresh_all_cells()

    def set_stat_mode(self, mode_name: str):
        idx = self.cb_stat.findText(mode_name)
        if idx >= 0:
            self.cb_stat.setCurrentIndex(idx)
            self._on_stat_changed(idx)

    def export_grid_tsv(self) -> str:
        """Retorna os dados da tabela em formato tabulado (TSV) compatível com Excel / TunerStudio."""
        lines = []
        lines.append("RPM / MAP\t" + "\t".join(str(r) for r in RPM_BINS))
        for r, map_val in enumerate(MAP_BINS):
            row_items = [f"{map_val} kPa"]
            for c in range(len(RPM_BINS)):
                item = self.table.item(r, c)
                row_items.append(item.text() if item else "--")
            lines.append("\t".join(row_items))
        return "\n".join(lines)

    def _copy_grid_to_clipboard(self):
        """Copia os dados da tabela em formato tabulado (TSV) para a área de transferência."""
        from PyQt6.QtWidgets import QApplication
        text = self.export_grid_tsv()
        QApplication.clipboard().setText(text)
        self.active_info.setText("Tabela copiada para a área de transferência!")

    def clear_data(self):
        for m in self.metrics:
            k = m[1]
            self._counts[k].clear()
            self._sums[k].clear()
            self._mins[k].clear()
            self._maxs[k].clear()
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
                if coord not in self._mins[key] or val < self._mins[key][coord]:
                    self._mins[key][coord] = val
                if coord not in self._maxs[key] or val > self._maxs[key][coord]:
                    self._maxs[key][coord] = val

        cur_key = self.metrics[self.cur_metric_idx][1]
        cur_fmt = self.metrics[self.cur_metric_idx][2]
        val_str = cur_fmt.format(latest[cur_key]) if cur_key in latest else "--"
        stat_name = self.cb_stat.currentText().split()[0]
        self.active_info.setText(f"Ponto: {rpm:.0f} RPM × {map_kpa:.0f} kPa | Atual: {val_str} | Modo: {stat_name}")

        self._update_cell(r, c)
        self._last_active_cell = coord
        self.table.setCurrentCell(r, c)

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
            if self.cur_stat_idx == 0:
                # Média
                disp_val = self._sums[cur_key][coord] / cnt
                txt = cur_fmt.format(disp_val)
            elif self.cur_stat_idx == 1:
                # Máximo
                disp_val = self._maxs[cur_key][coord]
                txt = cur_fmt.format(disp_val)
            elif self.cur_stat_idx == 2:
                # Mínimo
                disp_val = self._mins[cur_key][coord]
                txt = cur_fmt.format(disp_val)
            else:
                # Contagem (Hits)
                disp_val = float(cnt)
                txt = str(cnt)

            bg, fg = _color_for_value(cur_key, disp_val if self.cur_stat_idx != 3 else (disp_val * 2.0))
            item.setText(txt)
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
