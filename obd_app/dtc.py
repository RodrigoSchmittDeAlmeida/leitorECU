"""Leitura/decodificação de códigos de falha (Modo 03) e status MIL (PID 0101)."""
from __future__ import annotations

from typing import List, Tuple

from .elm327 import ElmResponse

DTC_DESCRIPTIONS = {
    "P0010": "Atuador do comando de válvulas - circuito",
    "P0105": "Sensor MAP - circuito",
    "P0106": "Sensor MAP - faixa/desempenho",
    "P0107": "Sensor MAP - sinal baixo",
    "P0108": "Sensor MAP - sinal alto",
    "P0112": "Sensor de temperatura do ar (IAT) - sinal baixo",
    "P0113": "Sensor de temperatura do ar (IAT) - sinal alto",
    "P0115": "Sensor de temperatura do motor (ECT) - circuito",
    "P0117": "Sensor ECT - sinal baixo",
    "P0118": "Sensor ECT - sinal alto",
    "P0120": "Sensor de posição da borboleta (TPS) - circuito",
    "P0121": "TPS - faixa/desempenho",
    "P0130": "Sonda lambda B1S1 - circuito",
    "P0131": "Sonda lambda B1S1 - tensão baixa",
    "P0132": "Sonda lambda B1S1 - tensão alta",
    "P0133": "Sonda lambda B1S1 - resposta lenta",
    "P0134": "Sonda lambda B1S1 - sem atividade",
    "P0135": "Aquecimento da sonda B1S1 - circuito",
    "P0171": "Mistura muito pobre (banco 1)",
    "P0172": "Mistura muito rica (banco 1)",
    "P0201": "Injetor cilindro 1 - circuito",
    "P0202": "Injetor cilindro 2 - circuito",
    "P0203": "Injetor cilindro 3 - circuito",
    "P0204": "Injetor cilindro 4 - circuito",
    "P0300": "Falha de combustão aleatória/múltipla",
    "P0301": "Falha de combustão - cilindro 1",
    "P0302": "Falha de combustão - cilindro 2",
    "P0303": "Falha de combustão - cilindro 3",
    "P0304": "Falha de combustão - cilindro 4",
    "P0322": "Sensor de rotação (G28) - sem sinal",
    "P0325": "Sensor de detonação - circuito",
    "P0335": "Sensor de rotação (CKP) - circuito",
    "P0340": "Sensor de fase (CMP) - circuito",
    "P0420": "Eficiência do catalisador abaixo do limite",
    "P0441": "Sistema EVAP (cânister) - fluxo incorreto",
    "P0443": "Válvula do cânister - circuito",
    "P0505": "Controle de marcha lenta - mau funcionamento",
    "P0560": "Tensão do sistema",
    "P0562": "Tensão do sistema baixa",
    "P0563": "Tensão do sistema alta",
    "P0601": "ECU - erro de checksum de memória",
    "P0638": "Corpo de borboleta (atuador) - faixa/desempenho",
    "P1545": "Corpo de borboleta - controle de posição (VW)",
    "P2101": "Motor da borboleta - faixa/desempenho",
}


def decode_dtc(code4: str) -> str:
    b = int(code4[0], 16)
    return f"{'PCBU'[b >> 2]}{b & 3}{code4[1:].upper()}"


def parse_dtcs(resp: ElmResponse) -> List[str]:
    """Decodifica códigos de falha do Modo 03 (OBD2) ou Serviço 18 (VAG KWP2000).
    
    - Modo 03 (ISO 9141-2 / KWP2000): inicia com '43' seguido de blocos de 2 bytes (4 hex).
    - Serviço 1800FF00 (KWP2000 VAG): inicia com '58' + qtd_dtcs (1 byte) + blocos de 3 bytes
      (2 bytes DTC + 1 byte status).
    """
    codes: List[str] = []
    joined = "".join(resp.data_lines())
    if joined.startswith("58") and len(joined) >= 4:
        n_dtcs = int(joined[2:4], 16)
        payload = joined[4:]
        for i in range(n_dtcs):
            chunk = payload[i * 6: i * 6 + 4]
            if len(chunk) == 4 and chunk != "0000":
                code = decode_dtc(chunk)
                if code not in codes:
                    codes.append(code)
        return codes

    for s in resp.data_lines():
        idx = s.find("43")
        if idx == -1 or idx % 2:
            continue
        payload = s[idx + 2:]
        if not payload:
            continue

        # Decodifica blocos de 2 bytes (4 hex chars). Ex: 0133 -> P0133, 0300 -> P0300
        for i in range(0, len(payload) - 3, 4):
            c = payload[i:i + 4]
            if len(c) == 4 and c != "0000":
                code = decode_dtc(c)
                if code not in codes:
                    codes.append(code)
    return codes


def describe(code: str) -> str:
    return DTC_DESCRIPTIONS.get(code, "Descrição não cadastrada (consulte o manual)")


def parse_mil(data: bytes) -> Tuple[bool, int]:
    """PID 0101: byte A bit7 = MIL (luz de injeção), bits 0-6 = qtde de DTCs."""
    return bool(data[0] & 0x80), data[0] & 0x7F
