"""Blocos de Medição VAG (KWP2000 sobre linha K, serviço 21 = readDataByLocalIdentifier).

Cada resposta positiva tem o formato ``61 GG`` + N células de 3 bytes ``[fórmula k, A, B]``
(na ME7.5.30 do Gol G5: sempre 8 células = 24 bytes; células vazias são ``25 00 00`` ou ``00 00 00``).

Este módulo é GENÉRICO: decodifica qualquer célula de qualquer bloco usando a tabela pública de
fórmulas VAG (a mesma usada por ferramentas como VAG-Blocks / kw1281test / documentação KWP1281),
e mantém um cache por ECU com os blocos que existem ou não (para não varrer de novo a cada conexão).

Os decodificadores "semânticos" (RPM, MAP, Sonda, STFT...) continuam em ``pids.py`` —
este módulo só ACRESCENTA canais ``gGGG_cN`` (bloco GGG, campo N) para gravar TUDO no CSV.
"""
from __future__ import annotations

import json
import os
import re
from typing import Callable, Dict, List, Optional, Tuple

CACHE_DIR = "cache"

# --------------------------------------------------------------------------- fórmulas
# k -> (função(a, b) -> valor, unidade). Valores "texto" (bits, estados, caracteres) viram números/códigos.
_F: Dict[int, Tuple[Callable[[int, int], Optional[float]], str]] = {
    0x01: (lambda a, b: 0.2 * a * b, "rpm"),
    0x02: (lambda a, b: 0.002 * a * b, "%"),
    0x03: (lambda a, b: 0.002 * a * b, "°"),
    0x04: (lambda a, b: abs(b - 127) * 0.01 * a * (-1.0 if b < 127 else 1.0), "°"),
    0x05: (lambda a, b: a * (b - 100) * 0.1, "°C"),
    0x06: (lambda a, b: 0.001 * a * b, "V"),
    0x07: (lambda a, b: 0.01 * a * b, "km/h"),
    0x08: (lambda a, b: 0.1 * a * b, ""),
    0x09: (lambda a, b: (b - 127) * 0.02 * a, "°"),
    0x0A: (lambda a, b: 0.0 if b == 0 else 1.0, "0=frio/1=quente"),
    0x0B: (lambda a, b: 0.0001 * a * (b - 128) + 1.0, "λ"),
    0x0C: (lambda a, b: 0.001 * a * b, "Ω"),
    0x0D: (lambda a, b: (b - 127) * 0.001 * a, "mm"),
    0x0E: (lambda a, b: 0.005 * a * b, "bar"),
    0x0F: (lambda a, b: 0.01 * a * b, "ms"),
    0x10: (lambda a, b: float(b & a) if a else float(b), "bits"),
    0x11: (lambda a, b: float(a * 256 + b), "txt"),
    0x12: (lambda a, b: 0.04 * a * b, "mbar"),
    0x13: (lambda a, b: 0.01 * a * b, "l"),
    0x14: (lambda a, b: a * (b - 128) / 128.0, "%"),
    0x15: (lambda a, b: 0.001 * a * b, "V"),
    0x16: (lambda a, b: 0.001 * a * b, "ms"),
    0x17: (lambda a, b: (b / 256.0) * a, "%"),
    0x18: (lambda a, b: 0.001 * a * b, "A"),
    0x19: (lambda a, b: b * 1.421 + a / 182.0, "g/s"),
    0x1A: (lambda a, b: float(b - a), "°C"),
    0x1B: (lambda a, b: (b - 128) * 0.01 * a, "°"),
    0x1C: (lambda a, b: float(b - a), ""),
    0x1D: (lambda a, b: 1.0 if b < a else 2.0, "mapa"),
    0x1E: (lambda a, b: (b / 12.0) * a, "°KW"),
    0x1F: (lambda a, b: (b / 2560.0) * a, "°C"),
    0x20: (lambda a, b: float(b - 256 if b > 128 else b), ""),
    0x21: (lambda a, b: 100.0 * b if a == 0 else 100.0 * b / a, "%"),
    0x22: (lambda a, b: (b - 128) * 0.01 * a, "°KW"),
    0x23: (lambda a, b: 0.01 * a * b, "l/h"),
    0x24: (lambda a, b: float(a * 2560 + b * 10), "km"),
    0x25: (lambda a, b: float(a * 256 + b), "cod"),
    0x26: (lambda a, b: (b - 128) * 0.001 * a, "°KW"),
    0x27: (lambda a, b: (b / 256.0) * a, "mg/h"),
    0x28: (lambda a, b: b * 0.1 + 25.5 * a - 400.0, "A"),
    0x29: (lambda a, b: float(b + a * 255), "Ah"),
    0x2A: (lambda a, b: b * 0.1 + 25.5 * a - 400.0, "kW"),
    0x2B: (lambda a, b: b * 0.1 + 25.5 * a, "V"),
    0x2C: (lambda a, b: float(a * 60 + b), "min"),
    0x2D: (lambda a, b: 0.1 * a * b / 100.0, ""),
    0x2E: (lambda a, b: (a * b - 3200) * 0.0027, "°KW"),
    0x2F: (lambda a, b: float((b - 128) * a), "ms"),
    0x30: (lambda a, b: float(b + a * 255), ""),
    0x31: (lambda a, b: (b / 4.0) * a * 0.1, "mg/h"),
    0x32: (lambda a, b: None if a == 0 else (b - 128) / (0.01 * a), "mbar"),
    0x33: (lambda a, b: ((b - 128) / 255.0) * a, "mg/h"),
    0x34: (lambda a, b: b * 0.02 * a - a, "Nm"),
    0x35: (lambda a, b: (b - 128) * 1.4222 + 0.006 * a, "g/s"),
    0x36: (lambda a, b: float(a * 256 + b), "cont"),
    0x37: (lambda a, b: a * b / 200.0, "s"),
    0x38: (lambda a, b: float(a * 256 + b), "WSC"),
    0x39: (lambda a, b: float(a * 256 + b + 65536), "WSC"),
    0x3A: (lambda a, b: 1.0225 * (b - 256) if b > 128 else 1.0225 * b, "/s"),
    0x3B: (lambda a, b: (a * 256 + b) / 32768.0, "λ"),
    0x3C: (lambda a, b: (a * 256 + b) * 0.01, "s"),
    0x3D: (lambda a, b: None if a == 0 else (b - 128) / a, ""),
    0x3E: (lambda a, b: 0.256 * a * b, "s"),
    0x3F: (lambda a, b: float(a * 256 + b), "txt"),
    0x40: (lambda a, b: float(a + b), "Ω"),
    0x41: (lambda a, b: 0.01 * a * (b - 127), "mm"),
    0x42: (lambda a, b: a * b / 511.12, "V"),
    0x43: (lambda a, b: 640.0 * a + b * 2.5, "°"),
    0x44: (lambda a, b: (256 * a + b) / 7.365, "°/s"),
    0x45: (lambda a, b: (256 * a + b) * 0.3254, "bar"),
    0x46: (lambda a, b: (256 * a + b) * 0.192, "m/s²"),
}

# Nomes conhecidos (best-effort) dos campos na ME7.5 / ME7.5.30 (VW 1.6 8V Flex). Os demais ficam genéricos.
KNOWN_LABELS: Dict[Tuple[int, int], str] = {
    (1, 1): "RPM", (1, 2): "Temp. motor", (1, 3): "Correção lambda", (1, 4): "Cond. ajuste básico",
    (2, 1): "RPM", (2, 2): "Carga", (2, 3): "Tempo injeção", (2, 4): "Pressão coletor",
    (3, 1): "RPM", (3, 2): "Pressão coletor", (3, 3): "Borboleta", (3, 4): "Avanço",
    (4, 1): "RPM", (4, 2): "Bateria", (4, 3): "Temp. motor", (4, 4): "Temp. ar",
    (5, 1): "RPM", (5, 2): "Carga", (5, 3): "Velocidade", (5, 4): "Estado operação",
    (6, 1): "RPM", (6, 2): "Carga", (6, 3): "Temp. ar", (6, 4): "Correção altitude",
    (10, 1): "RPM", (10, 2): "Carga", (10, 3): "Borboleta", (10, 4): "Avanço",
    (14, 1): "RPM", (14, 2): "Carga", (14, 3): "Falhas combustão total",
    (15, 1): "Falhas cil. 1", (15, 2): "Falhas cil. 2", (15, 3): "Falhas cil. 3",
    (16, 1): "Falhas cil. 4",
    (20, 1): "Retardo detonação cil. 1", (20, 2): "Retardo detonação cil. 2",
    (20, 3): "Retardo detonação cil. 3", (20, 4): "Retardo detonação cil. 4",
    (22, 1): "RPM", (22, 2): "Carga", (22, 3): "Retardo cil. 1", (22, 4): "Retardo cil. 2",
    (23, 1): "RPM", (23, 2): "Carga", (23, 3): "Retardo cil. 3", (23, 4): "Retardo cil. 4",
    (26, 1): "Sensor detonação cil. 1", (26, 2): "Sensor detonação cil. 2",
    (26, 3): "Sensor detonação cil. 3", (26, 4): "Sensor detonação cil. 4",
    (28, 1): "RPM", (28, 2): "Carga", (28, 3): "Temp. motor", (28, 4): "Teste sensor detonação",
    (31, 1): "Sonda 1 (tensão)", (31, 2): "Lambda especificado",
    (32, 1): "Adaptação lambda lenta", (32, 2): "Adaptação lambda parcial",
    (32, 3): "Fator adaptação mistura", (32, 4): "Tensão referência ECU",
    (33, 1): "Correção sonda (STFT)", (33, 2): "Sonda 1 (tensão)",
    (34, 1): "RPM", (34, 2): "Temp. catalisador (modelo)",
    (36, 1): "Sonda 2 pós-cat (tensão)", (36, 2): "Temp. sonda 2", (36, 3): "Fator lambda 2", (36, 4): "Status sonda 2",
    (37, 1): "Carga", (37, 2): "Sonda 2 (tensão)", (37, 3): "Delta lambda", (37, 4): "Status diagnose cat.",
    (50, 1): "RPM real", (50, 2): "RPM especificada", (50, 3): "Solicitação A/C", (50, 4): "Compressor A/C",
    (54, 1): "RPM", (54, 2): "Estado operação", (54, 3): "Pedal acelerador", (54, 4): "Borboleta",
    (57, 1): "RPM real", (57, 2): "RPM especificada", (57, 3): "Compressor A/C", (57, 4): "Pressão/Torque A/C",
    (58, 1): "Carga", (58, 2): "Pressão A/C", (58, 3): "Temp. motor", (58, 4): "Status A/C",
    (60, 1): "Borboleta sensor 1", (60, 2): "Borboleta sensor 2", (60, 3): "Passo adaptação EPC", (60, 4): "Status adaptação EPC",
    (62, 1): "Borboleta sensor 1", (62, 2): "Borboleta sensor 2",
    (62, 3): "Pedal sensor 1", (62, 4): "Pedal sensor 2",
    (64, 1): "Tensão mín. TPS 1", (64, 2): "Tensão mín. TPS 2", (64, 3): "Tensão emergência TPS 1", (64, 4): "Tensão emergência TPS 2",
    (70, 1): "Válvula EVAP (purga)", (70, 2): "Desvio reg. lambda EVAP",
    (70, 3): "Fator reg. EVAP", (70, 4): "Status teste EVAP",
    (86, 1): "Readiness Bits 1", (86, 2): "Readiness Bits 2",
    (86, 3): "Readiness Bits 3", (86, 4): "Readiness Bits 4",
    (99, 1): "RPM", (99, 2): "Temp. motor",
    (99, 3): "Correção lambda (STFT)", (99, 4): "Status regulação lambda",
    (100, 1): "Bits diagnóstico 1", (100, 2): "Temp. motor",
    (100, 3): "Tempo ciclo", (100, 4): "Bits diagnóstico 2",
    (101, 1): "RPM", (101, 2): "Carga",
    (101, 3): "Tempo injeção", (101, 4): "Pressão coletor",
    (103, 1): "Teor Etanol Flex (C1)", (103, 2): "Adaptação Flex (C2)",
    (103, 5): "Teor Etanol Flex", (103, 6): "Adaptação Mistura Flex",
    (103, 7): "Correção Partida Flex", (103, 8): "Status Reconhecimento Flex",
    (107, 1): "RPM", (107, 2): "Correção lambda",
    (107, 3): "Adaptação mistura", (107, 4): "Status regulação",
    (110, 1): "RPM", (110, 2): "Temp. motor",
    (110, 3): "Tempo injeção", (110, 4): "Correção carga / AF Álcool",
    (120, 1): "RPM", (120, 2): "Torque especificado",
    (120, 3): "Torque real motor", (120, 4): "Status ASR/Torque",
}


def decode_cell(k: int, a: int, b: int) -> Optional[Tuple[float, str]]:
    """Decodifica uma célula. Retorna None para células vazias; fórmula desconhecida => valor bruto A*256+B."""
    if k == 0x00 or (k == 0x25 and a == 0 and b == 0):
        return None
    f = _F.get(k)
    if f is None:
        return float(a * 256 + b), f"raw{k:02X}"
    try:
        v = f[0](a, b)
    except Exception:
        return None
    if v is None:
        return None
    return float(v), f[1]


def extract_block(resp, group: int) -> Optional[bytes]:
    """Procura ``61 GG`` na resposta do ELM e devolve TODAS as células completas,
    removendo prefixos de frame (ex: 0:, 1:) e repetições de cabeçalho 61 GG em multi-frame KWP2000."""
    header = f"61{group:02X}"
    dlines = resp.data_lines()
    payload_hex = ""
    found = False

    for raw_line in dlines:
        line_clean = raw_line.replace(" ", "").upper()
        # Remove eventuais prefixos de linha/frame como "0:", "1:", "01:"
        line_clean = re.sub(r"^[0-9A-F]{1,2}:", "", line_clean)
        if not found:
            idx = line_clean.find(header)
            while idx != -1 and idx % 2:
                idx = line_clean.find(header, idx + 1)
            if idx != -1:
                found = True
                payload_hex += line_clean[idx + 4:]
        else:
            # Em multi-frame KWP2000, linhas subsequentes podem repetir o cabeçalho 61 GG
            if line_clean.startswith(header):
                payload_hex += line_clean[len(header):]
            else:
                payload_hex += line_clean

    if not found or not payload_hex:
        return None

    # Cada célula VAG tem exatamente 3 bytes = 6 dígitos hexadecimais
    n = (len(payload_hex) // 6) * 6
    if n == 0:
        return None
    try:
        return bytes.fromhex(payload_hex[:n])
    except ValueError:
        return None


def is_negative(resp, service: int = 0x21) -> bool:
    """True se a ECU respondeu ``7F 21 xx`` (bloco inexistente / serviço recusado)."""
    tag = f"7F{service:02X}"
    return any(tag in l for l in resp.data_lines())


def channel_key(group: int, cell: int) -> str:
    return f"g{group:03d}_c{cell}"


def channel_label(group: int, cell: int, unit: str) -> str:
    name = KNOWN_LABELS.get((group, cell))
    base = f"Bloco {group:03d}.{cell}" + (f" {name}" if name else "")
    return f"{base} [{unit}]" if unit else base


def decode_block(group: int, data: bytes) -> Dict[str, Tuple[float, str]]:
    """{chave_canal: (valor, unidade)} para todas as células não vazias do bloco."""
    out: Dict[str, Tuple[float, str]] = {}
    for i in range(0, len(data) - 2, 3):
        r = decode_cell(data[i], data[i + 1], data[i + 2])
        if r is not None:
            out[channel_key(group, i // 3 + 1)] = r
    return out


# --------------------------------------------------------------------------- cache por ECU
def _cache_path(ecu_id: str) -> str:
    safe = re.sub(r"[^0-9A-Za-z_.-]+", "_", ecu_id.strip()) or "desconhecida"
    return os.path.join(CACHE_DIR, f"vag_blocos_{safe}.json")


def load_cache(ecu_id: str) -> dict:
    try:
        with open(_cache_path(ecu_id), encoding="utf-8") as f:
            d = json.load(f)
        return {
            "supported": [int(g) for g in d.get("supported", [])],
            "unsupported": [int(g) for g in d.get("unsupported", [])],
            "cells": {k: (v[0], v[1]) for k, v in d.get("cells", {}).items()},
        }
    except (OSError, ValueError, TypeError, KeyError, IndexError):
        return {"supported": [], "unsupported": [], "cells": {}}


def save_cache(ecu_id: str, supported: List[int], unsupported: List[int],
               cells: Dict[str, Tuple[str, str]]) -> None:
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = _cache_path(ecu_id) + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"ecu": ecu_id, "supported": sorted(supported), "unsupported": sorted(unsupported),
                       "cells": {k: list(v) for k, v in sorted(cells.items())}}, f, ensure_ascii=False, indent=1)
        os.replace(tmp, _cache_path(ecu_id))
    except OSError:
        pass

