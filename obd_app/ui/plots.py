"""Gráficos (osciloscópio) com PyQtGraph: eixo duplo (esquerdo/direito) e eixo X compartilhado."""
from __future__ import annotations

import pyqtgraph as pg
from PyQt6.QtCore import Qt

WINDOW_S = 30.0


class DualAxisPlot(pg.PlotWidget):
    def __init__(self, title: str, left_label: str, left_range, right_label: str | None = None,
                 right_range=None, parent=None):
        super().__init__(parent=parent, background="#0A0C10")
        self.setMinimumHeight(112)
        self.pi = self.getPlotItem()
        self.plot_title = title
        self.pi.showGrid(x=True, y=True, alpha=0.15)
        self.pi.setLabel("left", left_label)
        self.pi.setXRange(-WINDOW_S, 0, padding=0)
        self.pi.setYRange(*left_range, padding=0.02)
        self.pi.enableAutoRange(x=False, y=False)
        self.pi.setMouseEnabled(x=False, y=True)
        self.pi.setClipToView(True)
        self.pi.hideButtons()
        self.vb2 = None
        self._markers = []
        if right_label:
            self.vb2 = pg.ViewBox()
            self.pi.showAxis("right")
            self.pi.scene().addItem(self.vb2)
            self.pi.getAxis("right").linkToView(self.vb2)
            self.pi.getAxis("right").setLabel(right_label)
            self.vb2.setXLink(self.pi)
            self.vb2.setYRange(*right_range, padding=0.02)
            self.vb2.enableAutoRange(x=False, y=False)
            self.vb2.setMouseEnabled(x=False, y=True)
            self.pi.vb.sigResized.connect(self._sync_views)

    def _sync_views(self):
        self.vb2.setGeometry(self.pi.vb.sceneBoundingRect())
        self.vb2.linkedViewChanged(self.pi.vb, self.vb2.XAxis)

    def set_right_range(self, min_y: float, max_y: float, padding: float = 0.02) -> None:
        if self.vb2 is not None:
            self.vb2.setYRange(min_y, max_y, padding=padding)

    def set_left_range(self, min_y: float, max_y: float, padding: float = 0.02) -> None:
        self.pi.setYRange(min_y, max_y, padding=padding)

    def update_right_scale_for_map(self, max_val: float) -> None:
        """Ajusta dinamicamente a escala do eixo direito de 105 kPa até 260 kPa para motores turbo."""
        if self.vb2 is None:
            return
        if max_val > 105.0:
            target = min(260.0, max(120.0, float(((int(max_val) + 19) // 20) * 20)))
        else:
            target = 105.0
        self.vb2.setYRange(0.0, target, padding=0.02)

    def add_curve(self, name: str, color: str, right: bool = False, width: float = 1.6) -> pg.PlotDataItem:
        pen = pg.mkPen(color, width=width)
        if right and self.vb2 is not None:
            c = pg.PlotDataItem(pen=pen, name=name)
            self.vb2.addItem(c)
        else:
            c = self.pi.plot(pen=pen, name=name)
        c.setDownsampling(auto=True, method="peak")
        return c

    def add_hline(self, y: float, color: str, right: bool = False, style=Qt.PenStyle.DashLine,
                  label: str | None = None) -> pg.InfiniteLine:
        line = pg.InfiniteLine(pos=y, angle=0, movable=False, pen=pg.mkPen(color, width=1, style=style),
                               label=label, labelOpts={"color": color, "position": 0.05})
        (self.vb2 if right and self.vb2 is not None else self.pi).addItem(line)
        return line

    def add_marker(self, x: float | str = 0.0, color: str = "#ff5252", label: str | None = None) -> pg.InfiniteLine:
        if isinstance(x, str):
            color = x
            x = 0.0
        line = pg.InfiniteLine(pos=x, angle=90, movable=False,
                               pen=pg.mkPen(color, width=1.5, style=Qt.PenStyle.DotLine),
                               label=label, labelOpts={"color": color, "position": 0.85, "rotateAxis": (1, 0)})
        self.pi.addItem(line)
        self._markers.append(line)
        return line

    def add_crosshair(self, color: str = "#ffffff") -> pg.InfiniteLine:
        line = pg.InfiniteLine(angle=90, movable=False,
                               pen=pg.mkPen(color, width=1.2, style=Qt.PenStyle.DashLine))
        self.pi.addItem(line)
        return line

    def clear_markers(self) -> None:
        for m in self._markers:
            try:
                self.pi.removeItem(m)
            except Exception:
                pass
        self._markers.clear()

    def set_replay_mode(self, enabled: bool) -> None:
        self.pi.setMouseEnabled(x=enabled, y=True)
        if self.vb2 is not None:
            self.vb2.setMouseEnabled(x=enabled, y=True)
