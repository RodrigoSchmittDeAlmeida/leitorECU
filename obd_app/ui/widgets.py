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
        self.setMinimumWidth(118)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(8, 4, 8, 4)
        lay.setSpacing(0)
        top = QHBoxLayout()
        self.title = QLabel(ch.label, objectName="cardTitle")
        self.note = QLabel("", objectName="cardNote")
        top.addWidget(self.title)
        top.addStretch()
        top.addWidget(self.note)
        lay.addLayout(top)
        self.value = QLabel("--", objectName="cardValue")
        self.value.setAlignment(Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter)
        if color:
            self.value.setStyleSheet(f"color: {color};")
        lay.addWidget(self.value)
        self.unit = QLabel(ch.unit, objectName="cardUnit")
        self.unit.setAlignment(Qt.AlignmentFlag.AlignRight)
        lay.addWidget(self.unit)
        self._state = "stale"

    def set_value(self, v: float) -> None:
        self.value.setText(self.ch.fmt.format(v))

    def set_state(self, state: str, note: str = "") -> None:
        """state: normal | warn | alarm | stale"""
        if note != self.note.text():
            self.note.setText(note)
        if state != self._state:
            self._state = state
            self.setProperty("state", state)
            self.style().unpolish(self)
            self.style().polish(self)
