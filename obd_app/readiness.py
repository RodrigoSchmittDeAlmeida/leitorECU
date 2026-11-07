"""Monitores de prontidão I/M Readiness (Modo 01 PID 01) e Freeze Frame (Modo 02).

Implementado conforme as normas SAE J1979 e ISO 15031-5.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple


@dataclass
class ReadinessMonitor:
    name: str
    supported: bool
    completed: bool


@dataclass
class ReadinessReport:
    mil_on: bool
    dtc_count: int
    is_diesel: bool
    monitors: List[ReadinessMonitor]

    @property
    def ready_count(self) -> int:
        return sum(1 for m in self.monitors if m.supported and m.completed)

    @property
    def supported_count(self) -> int:
        return sum(1 for m in self.monitors if m.supported)


def parse_readiness_pid01(data: bytes) -> ReadinessReport:
    """Decodifica os 4 bytes do PID 0101 (I/M Readiness / Status de Emissões)."""
    if len(data) < 4:
        data = data + b"\x00" * (4 - len(data))

    byte_a, byte_b, byte_c, byte_d = data[0], data[1], data[2], data[3]

    mil_on = bool(byte_a & 0x80)
    dtc_count = byte_a & 0x7F
    is_diesel = bool(byte_b & 0x08)

    monitors: List[ReadinessMonitor] = []

    # Monitores contínuos (Byte B)
    monitors.append(ReadinessMonitor(
        name="Falhas de Combustão (Misfire)",
        supported=bool(byte_b & 0x01),
        completed=not bool(byte_b & 0x10),  # bit 4: 0 = completo, 1 = incompleto
    ))
    monitors.append(ReadinessMonitor(
        name="Sistema de Combustível (Fuel System)",
        supported=bool(byte_b & 0x02),
        completed=not bool(byte_b & 0x20),
    ))
    monitors.append(ReadinessMonitor(
        name="Componentes Globais (Comprehensive)",
        supported=bool(byte_b & 0x04),
        completed=not bool(byte_b & 0x40),
    ))

    # Monitores não contínuos (Bytes C e D)
    if not is_diesel:
        # Ciclo Otto (Gasolina / Etanol / Flex)
        monitors.append(ReadinessMonitor(
            name="Eficiência do Catalisador",
            supported=bool(byte_c & 0x01),
            completed=not bool(byte_c & 0x10),
        ))
        monitors.append(ReadinessMonitor(
            name="Catalisador Aquecido",
            supported=bool(byte_c & 0x02),
            completed=not bool(byte_c & 0x20),
        ))
        monitors.append(ReadinessMonitor(
            name="Sistema Evaporativo (EVAP / Cânister)",
            supported=bool(byte_c & 0x04),
            completed=not bool(byte_c & 0x40),
        ))
        monitors.append(ReadinessMonitor(
            name="Sistema de Ar Secundário",
            supported=bool(byte_c & 0x08),
            completed=not bool(byte_c & 0x80),
        ))
        monitors.append(ReadinessMonitor(
            name="Refrigerante do A/C",
            supported=bool(byte_d & 0x01),
            completed=not bool(byte_d & 0x10),
        ))
        monitors.append(ReadinessMonitor(
            name="Sensores de Oxigênio (Sonda Lambda)",
            supported=bool(byte_d & 0x02),
            completed=not bool(byte_d & 0x20),
        ))
        monitors.append(ReadinessMonitor(
            name="Aquecedor da Sonda Lambda",
            supported=bool(byte_d & 0x04),
            completed=not bool(byte_d & 0x40),
        ))
        monitors.append(ReadinessMonitor(
            name="Sistema EGR / VVT",
            supported=bool(byte_d & 0x08),
            completed=not bool(byte_d & 0x80),
        ))
    else:
        # Ciclo Diesel
        monitors.append(ReadinessMonitor(
            name="Catalisador NMHC",
            supported=bool(byte_c & 0x01),
            completed=not bool(byte_c & 0x10),
        ))
        monitors.append(ReadinessMonitor(
            name="Pós-Tratamento NOx",
            supported=bool(byte_c & 0x02),
            completed=not bool(byte_c & 0x20),
        ))
        monitors.append(ReadinessMonitor(
            name="Pressão de Sobrealimentação (Turbo)",
            supported=bool(byte_c & 0x08),
            completed=not bool(byte_c & 0x80),
        ))
        monitors.append(ReadinessMonitor(
            name="Sensor de Gases de Escape",
            supported=bool(byte_d & 0x02),
            completed=not bool(byte_d & 0x20),
        ))
        monitors.append(ReadinessMonitor(
            name="Filtro de Partículas (DPF)",
            supported=bool(byte_d & 0x04),
            completed=not bool(byte_d & 0x40),
        ))
        monitors.append(ReadinessMonitor(
            name="Sistema EGR / VVT",
            supported=bool(byte_d & 0x08),
            completed=not bool(byte_d & 0x80),
        ))

    return ReadinessReport(
        mil_on=mil_on,
        dtc_count=dtc_count,
        is_diesel=is_diesel,
        monitors=monitors,
    )


@dataclass
class FreezeFrame:
    dtc: str
    params: Dict[str, Tuple[float, str]]  # {nome: (valor, unidade)}


def parse_freeze_frame(lines: List[str]) -> FreezeFrame:
    """Extrai DTC causador e sensores gravados no Modo 02."""
    from .dtc import decode_dtc

    dtc_code = "Nenhum"
    params: Dict[str, Tuple[float, str]] = {}

    for line in lines:
        clean = line.replace(" ", "").upper()
        # Modo 02 PID 02: DTC causador (resposta 42 02 XX XX)
        if "4202" in clean:
            idx = clean.find("4202") + 4
            hex_dtc = clean[idx:idx + 4]
            if len(hex_dtc) == 4 and hex_dtc != "0000":
                dtc_code = decode_dtc(hex_dtc)
        elif "420C" in clean:
            # RPM no freeze frame
            idx = clean.find("420C") + 4
            try:
                rpm = int(clean[idx:idx + 4], 16) / 4.0
                params["Rotação do Motor"] = (rpm, "rpm")
            except ValueError:
                pass
        elif "420D" in clean:
            # Velocidade
            idx = clean.find("420D") + 4
            try:
                spd = float(int(clean[idx:idx + 2], 16))
                params["Velocidade"] = (spd, "km/h")
            except ValueError:
                pass
        elif "4205" in clean:
            # Temperatura ECT
            idx = clean.find("4205") + 4
            try:
                ect = float(int(clean[idx:idx + 2], 16) - 40)
                params["Temperatura Motor (ECT)"] = (ect, "°C")
            except ValueError:
                pass
        elif "420B" in clean:
            # MAP
            idx = clean.find("420B") + 4
            try:
                kpa = float(int(clean[idx:idx + 2], 16))
                params["Pressão Coletor (MAP)"] = (kpa, "kPa")
            except ValueError:
                pass
        elif "4204" in clean:
            # Carga
            idx = clean.find("4204") + 4
            try:
                load = int(clean[idx:idx + 2], 16) * 100.0 / 255.0
                params["Carga do Motor"] = (round(load, 1), "%")
            except ValueError:
                pass

    return FreezeFrame(dtc=dtc_code, params=params)
