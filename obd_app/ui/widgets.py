"""Cards numéricos do painel superior."""
from __future__ import annotations

from PyQt6.QtCore import Qt
from typing import Optional

from PyQt6.QtWidgets import QFrame, QHBoxLayout, QLabel, QVBoxLayout

from ..pids import Channel


class ValueCard(QFrame):
    def __init__(self, ch: Channel, color: str | None = None, parent=None):
        super().__init__(parent)
        self.ch = ch
        self.setObjectName("card")
        self.setProperty("state", "stale")
        self.setMinimumWidth(96)
        self.min_val: Optional[float] = None
        self.max_val: Optional[float] = None

        lay = QVBoxLayout(self)
        lay.setContentsMargins(7, 4, 7, 4)
        lay.setSpacing(0)

        top = QHBoxLayout()
        top.setContentsMargins(0, 0, 0, 0)
        self.title = QLabel(ch.label, objectName="cardTitle")
        self.note = QLabel("sem sinal", objectName="cardNote")
        top.addWidget(self.title)
        top.addStretch()
        top.addWidget(self.note)
        lay.addLayout(top)

        val_box = QHBoxLayout()
        val_box.setContentsMargins(0, 0, 0, 0)
        val_box.setSpacing(3)
        self.value = QLabel("--", objectName="cardValue")
        self.value.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
        if color:
            self.value.setStyleSheet(f"color: {color};")
        val_box.addWidget(self.value)

        self.unit = QLabel(ch.unit, objectName="cardUnit")
        self.unit.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignBottom)
        val_box.addWidget(self.unit)
        lay.addLayout(val_box)

        self.peaks_label = QLabel("mín --  |  máx --", objectName="cardPeaks")
        self.peaks_label.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignBottom)
        lay.addWidget(self.peaks_label)

        self._state = "stale"

    def set_value(self, v: float) -> None:
        self.value.setText(self.ch.fmt.format(v))
        if self.min_val is None or v < self.min_val:
            self.min_val = v
        if self.max_val is None or v > self.max_val:
            self.max_val = v
        self._update_peaks_text()

    def _update_peaks_text(self) -> None:
        if self.min_val is not None and self.max_val is not None:
            f = self.ch.fmt
            self.peaks_label.setText(f"mín {f.format(self.min_val)} | máx {f.format(self.max_val)}")

    def reset_peaks(self) -> None:
        self.min_val = None
        self.max_val = None
        self.peaks_label.setText("")

    def set_state(self, state: str, note: str = "") -> None:
        """state: normal | warn | alarm | stale"""
        display_note = note if note else ("sem sinal" if state == "stale" else "")
        if display_note != self.note.text():
            self.note.setText(display_note)
        self.note.setVisible(bool(display_note))
        if state != self._state:
            self._state = state
            self.setProperty("state", state)
            self.style().unpolish(self)
            self.style().polish(self)
