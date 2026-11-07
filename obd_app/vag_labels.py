"""Catálogo de rótulos oficiais VAG (VCDS style) para Bosch ME7.5.30 e Bosch MP9.0."""
from __future__ import annotations

from typing import Dict, Tuple

# Rótulos para Bosch MP9.0 (Kombi 1.6 Ar / Gol Mi 1.6-1.8)
MP90_LABELS: Dict[Tuple[int, int], str] = {
    (1, 1): "RPM Motor",
    (1, 2): "Temp. Cabeçote / Óleo",
    (1, 3): "Sonda Lambda 1 (Pré)",
    (1, 4): "Condições de Ajuste",
    (2, 1): "RPM Motor",
    (2, 2): "Tempo de Injeção",
    (2, 3): "Tensão da Bateria",
    (2, 4): "Temperatura do Ar (IAT)",
    (3, 1): "RPM Motor",
    (3, 2): "Posição Borboleta (TPS)",
    (3, 3): "Avanço de Ignição",
    (3, 4): "Status de Operação",
    (4, 1): "RPM Motor",
    (4, 2): "Carga do Motor",
    (4, 3): "Velocidade",
    (4, 4): "Modo Marcha Lenta",
    (5, 1): "RPM Motor",
    (5, 2): "Temperatura Motor",
    (5, 3): "Tempo de Injeção",
    (5, 4): "Avanço de Ignição",
    (6, 1): "RPM Motor",
    (6, 2): "Avanço de Ignição",
    (6, 3): "Regulação Lambda",
    (6, 4): "Válvula Purga Cânister",
    (7, 1): "RPM Motor",
    (7, 2): "Carga do Motor",
    (7, 3): "Contador Falhas",
    (7, 4): "Status Sensor Fase",
    (8, 1): "RPM Motor",
    (8, 2): "Tempo de Injeção",
    (8, 3): "Sonda Lambda",
    (8, 4): "Tensão Alternador",
}


def get_vag_group_label(group: int, cell: int, is_mp90: bool = False) -> str:
    """Retorna o rótulo descritivo oficial de uma célula de bloco VAG."""
    if is_mp90 and (group, cell) in MP90_LABELS:
        return MP90_LABELS[(group, cell)]

    from .vag import KNOWN_LABELS
    if (group, cell) in KNOWN_LABELS:
        return KNOWN_LABELS[(group, cell)]

    return f"Bloco {group:03d} Campo {cell}"
