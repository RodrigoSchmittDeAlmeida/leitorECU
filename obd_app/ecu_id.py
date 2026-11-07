"""Módulo de identificação de ECU e parsing dinâmico de respostas de identificação."""
from __future__ import annotations

from .ecu_fingerprints import (PART_NUMBER_DATABASE, WMI_DATABASE, decode_ecu_part_number,
                               decode_wmi, identify_ecu)

__all__ = [
    "WMI_DATABASE",
    "PART_NUMBER_DATABASE",
    "decode_wmi",
    "decode_ecu_part_number",
    "identify_ecu",
]
