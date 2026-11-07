"""Decodificador Universal de Identificação de ECU, VIN e Part Number (Fingerprinting).

Permite à aplicação identificar a fabricante, modelo do veículo e família da injeção
eletrônica de forma 100% autônoma, sem necessidade de menus manuais de seleção.
"""
from __future__ import annotations

import re
from typing import Any, Dict, Optional

# WMI - World Manufacturer Identifier (3 primeiros caracteres do VIN/Chassi)
WMI_DATABASE = {
    "9BW": "Volkswagen do Brasil",
    "9BF": "Ford Brasil",
    "9BG": "General Motors do Brasil (Chevrolet)",
    "9BD": "Fiat Automóveis Brasil",
    "9BR": "Toyota do Brasil",
    "93H": "Honda Automóveis do Brasil",
    "93Y": "Renault do Brasil",
    "935": "Citroën do Brasil",
    "936": "Peugeot do Brasil",
    "9BH": "Hyundai Motor Brasil",
    "9BM": "Mercedes-Benz Brasil",
    "9BS": "Scania Brasil",
    "9BV": "Volvo do Brasil",
    "WVW": "Volkswagen (Alemanha)",
    "WAU": "Audi (Alemanha)",
    "WBA": "BMW (Alemanha)",
    "WDB": "Mercedes-Benz (Alemanha)",
    "WP0": "Porsche (Alemanha)",
    "1FA": "Ford Motor Company (EUA)",
    "1FD": "Ford Motor Company (EUA)",
    "1FM": "Ford Motor Company (EUA)",
    "1GC": "Chevrolet / General Motors (EUA)",
    "1G1": "Chevrolet (EUA)",
    "2G1": "Chevrolet (Canadá)",
    "3VW": "Volkswagen de México",
    "8AW": "Volkswagen Argentina",
    "8AF": "Ford Argentina",
    "8AG": "General Motors Argentina",
    "8AD": "Fiat Argentina",
    "8AP": "Peugeot Argentina",
}

# Banco de dados de Part Numbers conhecidos de centrais sul-americanas e globais
PART_NUMBER_DATABASE = [
    # VW Bosch Motronic ME7.5.30 (EA111 1.6 / 1.0 Total Flex)
    ("032906032AJ", "VW Gol/Voyage G5 1.6 Flex — Bosch ME7.5.30"),
    ("032906032", "VW EA111 1.6 Flex — Bosch ME7.5.30"),
    ("030906034", "VW EA111 1.0 Flex — Bosch ME7.5.20 / ME7.5.30"),
    ("030906032", "VW EA111 1.0 Gasolina — Bosch ME7.5.10"),
    ("036906034", "VW EA111 1.4/1.6 — Bosch ME7.5.10"),
    ("06A906032", "VW EA113 1.8T 20V / 2.0 — Bosch ME7.5"),
    
    # VW Kombi e Gol/Parati Bosch MP9.0 (KW1281 / Linha K)
    ("237906021", "VW Kombi 1.6 Ar Injetada — Bosch Motronic MP9.0"),
    ("026906021", "VW Gol/Parati AP 1.6/1.8 — Bosch Motronic MP9.0"),
    ("027906021", "VW Santana/Quantum AP 2.0 — Bosch Motronic MP9.0"),
    ("048906021", "VW Polo Classic 1.8 — Bosch Motronic MP9.0"),

    # Magneti Marelli
    ("IAW 4GV", "VW EA111 1.0/1.6 Flex — Magneti Marelli IAW 4GV"),
    ("4GV", "VW/Fiat Magneti Marelli IAW 4GV"),
    ("IAW 4AVP", "VW AP 1.6/1.8 Total Flex — Magneti Marelli IAW 4AVP"),
    ("4AVP", "VW AP Total Flex — Magneti Marelli 4AVP"),
    ("IAW 4BV", "VW Fox/Polo 1.0/1.6 — Magneti Marelli 4BV"),
    ("IAW 1AVP", "VW Gol/Parati AP Mi — Magneti Marelli 1AVP"),
    ("1AVP", "VW AP Mi — Magneti Marelli 1AVP"),
    ("IAW 1AVB", "VW Gol AP Mi — Magneti Marelli 1AVB"),

    # Ford Continental / Visteon (HS-CAN 500k / UDS)
    ("EMS2211", "Ford Ka/Fiesta 1.5 Sigma 16V Flex — Continental EMS2211"),
    ("EMS2204", "Ford Focus/EcoSport 1.6/2.0 Sigma Flex — Continental EMS2204"),
    ("EMS2212", "Ford Ka 1.0 Ti-VCT 3 Cilindros — Continental EMS2212"),
    ("FOMOCO", "Ford Motor Company (PCM UDS)"),
]


def decode_wmi(vin: str) -> Optional[str]:
    """Decodifica a fabricante do veículo a partir dos 3 primeiros dígitos do VIN/Chassi."""
    if not vin or len(vin) < 3:
        return None
    wmi = vin[:3].upper()
    return WMI_DATABASE.get(wmi)


def decode_ecu_part_number(raw_id: str) -> Optional[str]:
    """Identifica o modelo e família da ECU a partir da string bruta de identificação."""
    if not raw_id:
        return None
    cleaned = raw_id.upper().replace(" ", "").replace("-", "").replace(".", "")
    for pattern, name in PART_NUMBER_DATABASE:
        pattern_clean = pattern.upper().replace(" ", "").replace("-", "").replace(".", "")
        if pattern_clean in cleaned:
            return name
    return None


def identify_ecu(
    raw_id: str = "",
    vin: str = "",
    protocol_name: str = "",
    can_modules_found: Optional[list[str]] = None,
) -> Dict[str, Any]:
    """Gera um perfil descritivo completo da ECU e veículo detectados."""
    can_modules_found = can_modules_found or []
    manufacturer = decode_wmi(vin)
    part_match = decode_ecu_part_number(raw_id)

    # Identificação por heurística e palavras-chave
    is_mp90 = "237906021" in raw_id or "MP9.0" in raw_id.upper() or "KW1281" in protocol_name
    is_me75 = "ME7.5" in raw_id.upper() or "032906032" in raw_id or "030906032" in raw_id
    is_ford_can = "EMS22" in raw_id.upper() or "FOMOCO" in raw_id.upper() or bool(can_modules_found)

    if part_match:
        display_title = part_match
    elif manufacturer and raw_id:
        display_title = f"{manufacturer} — {raw_id.strip()}"
    elif manufacturer:
        display_title = f"{manufacturer} ({protocol_name or 'OBD-II'})"
    elif raw_id.strip():
        display_title = f"ECU {raw_id.strip()} ({protocol_name or 'OBD-II'})"
    else:
        display_title = f"ECU Universal ({protocol_name or 'OBD-II'})"

    # Determina família da injeção e motorização
    if is_mp90:
        ecu_family = "Bosch Motronic MP9.0"
        engine = "VW Boxer 1.6 Ar / AP 1.6-1.8 Mi"
    elif is_me75:
        ecu_family = "Bosch Motronic ME7.5.30"
        engine = "VW EA111 1.0/1.6 8V Total Flex"
    elif is_ford_can:
        ecu_family = "Continental EMS (Ford HS-CAN)"
        engine = "Ford Sigma 1.5 DOHC 16V Flex"
    elif "4GV" in raw_id:
        ecu_family = "Magneti Marelli IAW 4GV"
        engine = "VW EA111 1.0/1.6 8V Total Flex"
    else:
        ecu_family = "OBD-II Universal"
        engine = "Genérico Universal"

    is_can = bool(can_modules_found) or "CAN" in protocol_name.upper()

    return {
        "display_title": display_title,
        "manufacturer": manufacturer or "Fabricante não identificado",
        "ecu_family": ecu_family,
        "engine": engine,
        "raw_id": raw_id.strip(),
        "vin": vin.strip(),
        "protocol": protocol_name,
        "is_mp90": is_mp90,
        "is_can": is_can,
        "has_can_modules": bool(can_modules_found),
        "can_modules": can_modules_found,
    }
