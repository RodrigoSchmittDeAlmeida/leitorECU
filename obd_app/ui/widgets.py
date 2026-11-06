"""Cards numéricos do painel superior."""
from __future__ import annotations

from PyQt6.QtCore import Qt
from PyQt6.QtWidgets import QFrame, QHBoxLayout, QLabel, QVBoxLayout

from ..pids import Channel


class ValueCard(QFrame):
    def __init__(self, ch: Channel, color: str | None = None, parent=None):
        super().__init__(parent)
        self.ch = ch
        self.setObjectName("card")
        self.setProperty("state", "stale")
        self.setMinimumWidth(100)
        self.min_val: Optional[float] = None
        self.max_val: Optional[float] = None

        lay = QVBoxLayout(self)
        lay.setContentsMargins(6, 3, 6, 3)
        lay.setSpacing(1)

        top = QHBoxLayout()
        top.setContentsMargins(0, 0, 0, 0)
        self.title = QLabel(ch.label, objectName="cardTitle")
        self.note = QLabel("", objectName="cardNote")
        top.addWidget(self.title)
        top.addStretch()
        top.addWidget(self.note)
        lay.addLayout(top)

        val_box = QHBoxLayout()
        val_box.setContentsMargins(0, 0, 0, 0)
        val_box.setSpacing(3)
        self.peaks_label = QLabel("", objectName="cardPeaks")
        self.peaks_label.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignBottom)
        val_box.addWidget(self.peaks_label)
        val_box.addStretch()
        self.value = QLabel("--", objectName="cardValue")
        self.value.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        if color:
            self.value.setStyleSheet(f"color: {color};")
        val_box.addWidget(self.value)

        self.unit = QLabel(ch.unit, objectName="cardUnit")
        self.unit.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignBottom)
        val_box.addWidget(self.unit)
        lay.addLayout(val_box)

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
        if note != self.note.text():
            self.note.setText(note)
        if state != self._state:
            self._state = state
            self.setProperty("state", state)
            self.style().unpolish(self)
            self.style().polish(self)
