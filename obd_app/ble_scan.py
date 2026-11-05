"""Busca de adaptadores BLE (QThread) usando bleak."""
from __future__ import annotations

import asyncio

from PyQt6.QtCore import QThread, pyqtSignal

OBD_HINTS = ("VLINK", "VGATE", "ICAR", "OBD", "ELM", "V-LINK", "KONNWEI", "VEEPEAK", "CAR")


class BleScanWorker(QThread):
    found = pyqtSignal(list)  # [(nome, endereço, rssi, provavel_obd)]
    failed = pyqtSignal(str)

    def __init__(self, seconds: float = 6.0, parent=None):
        super().__init__(parent)
        self.seconds = seconds

    def run(self) -> None:
        try:
            from bleak import BleakScanner
        except ImportError:
            self.failed.emit("Biblioteca 'bleak' não instalada. Rode: pip install bleak")
            return
        try:
            result = asyncio.run(BleakScanner.discover(timeout=self.seconds, return_adv=True))
        except Exception as e:
            self.failed.emit(f"Falha ao procurar BLE: {e}\nVerifique se o Bluetooth do PC está ligado.")
            return
        devices = []
        for addr, (dev, adv) in result.items():
            name = adv.local_name or dev.name or "(sem nome)"
            likely = any(h in name.upper() for h in OBD_HINTS)
            rssi = adv.rssi if adv.rssi is not None else -100
            devices.append((name, addr, rssi, likely))
        devices.sort(key=lambda d: (not d[3], d[0] == "(sem nome)", -d[2]))
        self.found.emit(devices)
