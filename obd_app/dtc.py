"""Leitura/decodificação de códigos de falha (Modo 03) e status MIL (PID 0101)."""
from __future__ import annotations

from typing import List, Tuple

from .elm327 import ElmResponse

DTC_DESCRIPTIONS = {
    # ------------------------------------------------ Motor / Injeção (P0xxx genéricos)
    "P0010": "Atuador do comando de válvulas (VVT) - circuito",
    "P0011": "Posição do comando de válvulas - avanço excessivo",
    "P0012": "Posição do comando de válvulas - retardo excessivo",
    "P0100": "Sensor de fluxo de ar (MAF) - falha de circuito",
    "P0101": "Sensor MAF - faixa/desempenho",
    "P0102": "Sensor MAF - sinal baixo",
    "P0103": "Sensor MAF - sinal alto",
    "P0105": "Sensor de pressão absoluta do coletor (MAP) - circuito",
    "P0106": "Sensor MAP - faixa/desempenho",
    "P0107": "Sensor MAP - sinal baixo",
    "P0108": "Sensor MAP - sinal alto",
    "P0110": "Sensor de temperatura do ar de admissão (IAT) - circuito",
    "P0111": "Sensor IAT - faixa/desempenho",
    "P0112": "Sensor IAT - sinal baixo",
    "P0113": "Sensor IAT - sinal alto",
    "P0115": "Sensor de temperatura do motor (ECT) - circuito",
    "P0116": "Sensor ECT - faixa/desempenho",
    "P0117": "Sensor ECT - sinal baixo",
    "P0118": "Sensor ECT - sinal alto",
    "P0120": "Sensor de posição da borboleta (TPS) - circuito",
    "P0121": "Sensor TPS - faixa/desempenho",
    "P0122": "Sensor TPS - sinal baixo",
    "P0123": "Sensor TPS - sinal alto",
    "P0128": "Válvula termostática - temperatura abaixo da faixa de operação",
    "P0130": "Sonda lambda B1S1 (Pré-Cat) - falha de circuito",
    "P0131": "Sonda lambda B1S1 - tensão baixa (mistura pobre)",
    "P0132": "Sonda lambda B1S1 - tensão alta (mistura rica)",
    "P0133": "Sonda lambda B1S1 - resposta lenta",
    "P0134": "Sonda lambda B1S1 - sem atividade detectada",
    "P0135": "Aquecedor da sonda lambda B1S1 - circuito defeituoso",
    "P0136": "Sonda lambda B1S2 (Pós-Cat) - circuito",
    "P0137": "Sonda lambda B1S2 - tensão baixa",
    "P0138": "Sonda lambda B1S2 - tensão alta",
    "P0141": "Aquecedor da sonda lambda B1S2 - circuito defeituoso",
    "P0170": "Ajuste de combustível (Trim) - mau funcionamento",
    "P0171": "Mistura excessivamente pobre (Banco 1)",
    "P0172": "Mistura excessivamente rica (Banco 1)",
    "P0201": "Injetor cilindro 1 - falha de circuito",
    "P0202": "Injetor cilindro 2 - falha de circuito",
    "P0203": "Injetor cilindro 3 - falha de circuito",
    "P0204": "Injetor cilindro 4 - falha de circuito",
    "P0300": "Falha de combustão aleatória / múltiplos cilindros (Misfire)",
    "P0301": "Falha de combustão detectada - Cilindro 1",
    "P0302": "Falha de combustão detectada - Cilindro 2",
    "P0303": "Falha de combustão detectada - Cilindro 3",
    "P0304": "Falha de combustão detectada - Cilindro 4",
    "P0320": "Circuito de entrada de rotação do distribuidor / ignição",
    "P0322": "Sensor de rotação (CKP / G28) - sem sinal",
    "P0325": "Sensor de detonação (Knock Sensor) - circuito",
    "P0335": "Sensor de rotação da árvore de manivelas (CKP) - circuito",
    "P0336": "Sensor CKP - faixa/desempenho",
    "P0340": "Sensor de fase do comando de válvulas (CMP) - circuito",
    "P0341": "Sensor CMP - faixa/desempenho",
    "P0420": "Eficiência do catalisador abaixo do limite (Banco 1)",
    "P0441": "Sistema EVAP (cânister) - fluxo de purga incorreto",
    "P0442": "Sistema EVAP - pequeno vazamento detectado",
    "P0443": "Válvula de purga do cânister (EVAP) - falha de circuito",
    "P0455": "Sistema EVAP - grande vazamento detectado",
    "P0500": "Sensor de velocidade do veículo (VSS) - circuito",
    "P0505": "Sistema de controle de marcha lenta - mau funcionamento",
    "P0506": "Controle de marcha lenta - RPM inferior ao esperado",
    "P0507": "Controle de marcha lenta - RPM superior ao esperado",
    "P0560": "Tensão do sistema elétrico incorreta",
    "P0562": "Tensão do sistema elétrico baixa",
    "P0563": "Tensão do sistema elétrico alta",
    "P0601": "Módulo de controle do motor (ECU) - erro de checksum de memória",
    "P0602": "Módulo de controle do motor (ECU) - erro de programação",
    "P0606": "Processador do módulo de controle (ECU) - falha interna",
    "P0638": "Controle do atuador da borboleta - faixa/desempenho",
    "P0685": "Relé principal de controle da ECU/PCM - circuito aberto / Power-Latch",
    "P0686": "Relé principal de controle da ECU/PCM - circuito baixo",
    "P0687": "Relé principal de controle da ECU/PCM - circuito alto",
    "P0689": "Linha de monitoramento do relé da ECU - tensão baixa",
    "P0690": "Linha de monitoramento do relé da ECU - tensão alta",
    "P2101": "Motor do atuador da borboleta (TAC) - faixa/desempenho",
    "P2135": "Correlação de tensão entre os sensores 1 e 2 da borboleta (TPS)",
    "P2138": "Correlação de tensão entre os sensores 1 e 2 do pedal acelerador (APP)",

    # ------------------------------------------------ Ar Condicionado (A/C)
    "P0530": "Sensor de pressão do refrigerante A/C - falha de circuito",
    "P0531": "Sensor de pressão do A/C - faixa/desempenho",
    "P0532": "Sensor de pressão do refrigerante A/C - sinal baixo (possível falta de gás)",
    "P0533": "Sensor de pressão do refrigerante A/C - sinal alto",
    "P0645": "Relé da embreagem do compressor do ar condicionado - circuito",
    "P0646": "Relé da embreagem do ar condicionado - sinal baixo / curto ao terra",
    "P0647": "Relé da embreagem do ar condicionado - sinal alto / curto ao positivo",

    # ------------------------------------------------ Ford Específicos (P1xxx)
    "P1000": "Monitores de prontidão OBD-II incompletos (ciclo de condução não finalizado)",
    "P1100": "Sensor MAF - intermitente no teste de fluxo",
    "P1120": "Sensor TPS - fora da faixa no teste de retorno",
    "P1260": "Tentativa de partida impedida pelo imobilizador antifurto PATS",
    "P1288": "Sensor de temperatura do cabeçote (CHT) - fora da faixa autoteste",
    "P1289": "Sensor CHT - entrada alta",
    "P1290": "Sensor CHT - entrada baixa",
    "P1460": "Relé de corte do A/C em aceleração plena (WOT) - circuito",
    "P1632": "Falha no sensor inteligente do alternador / sistema Smart Charge Ford",
    "P1633": "Tensão da bateria permanentemente baixa na alimentação de memória da ECU (KAM)",
    "P1700": "Transmissão - sistema de intertravamento da marcha à ré",

    # ------------------------------------------------ Rede de Comunicação CAN (U0xxx / U1xxx)
    "U0001": "Barramento CAN de alta velocidade (HS-CAN) - falha de comunicação",
    "U0002": "Desempenho do barramento CAN de alta velocidade",
    "U0073": "Barramento CAN do módulo desligado (CAN Bus-Off)",
    "U0100": "Perda de comunicação com o Módulo de Controle do Motor (PCM)",
    "U0101": "Perda de comunicação com o Módulo da Transmissão (TCM)",
    "U0121": "Perda de comunicação com o Módulo de Freios ABS / ESC",
    "U0129": "Perda de comunicação com o Sistema de Controle de Freios",
    "U0140": "Perda de comunicação com o Módulo de Carroceria e Conforto (BCM / GEM)",
    "U0155": "Perda de comunicação com o Painel de Instrumentos (IPC)",
    "U0164": "Perda de comunicação com o Módulo de Controle de Climatização / Ar Condicionado",
    "U0401": "Dados inválidos recebidos do Módulo do Motor (PCM)",
    "U0415": "Dados inválidos recebidos do Módulo de Freios ABS / ESC",
    "U0420": "Dados inválidos recebidos da Direção Elétrica Progressiva (PSCM / EPAS)",
    "U0422": "Dados inválidos recebidos do Módulo de Conforto (BCM)",
    "U0423": "Dados inválidos recebidos do Painel de Instrumentos (IPC)",
    "U0428": "Dados inválidos recebidos do Sensor de Ângulo do Volante (SAS)",

    # ------------------------------------------------ Chassi / Freios ABS / Direção (C0xxx / C1xxx)
    "C0031": "Sensor de velocidade da roda dianteira esquerda - circuito",
    "C0032": "Sensor de velocidade da roda dianteira esquerda - faixa/desempenho",
    "C0034": "Sensor de velocidade da roda dianteira direita - circuito",
    "C0035": "Sensor de velocidade da roda dianteira direita - faixa/desempenho",
    "C0037": "Sensor de velocidade da roda traseira esquerda - circuito",
    "C0038": "Sensor de velocidade da roda traseira esquerda - faixa/desempenho",
    "C003A": "Sensor de velocidade da roda traseira direita - circuito",
    "C003B": "Sensor de velocidade da roda traseira direita - faixa/desempenho",
    "C0040": "Interruptor do pedal de freio 'A' - circuito",
    "C0041": "Interruptor do pedal de freio 'A' - desempenho",
    "C0051": "Sensor de posição/ângulo do volante (SAS) - circuito",
    "C0061": "Sensor de aceleração lateral - circuito",
    "C0062": "Sensor de aceleração longitudinal - circuito",
    "C0063": "Sensor de taxa de guinada (Yaw Rate) - circuito",
    "C1000": "Interruptor do freio de estacionamento (freio de mão)",
    "C1099": "Motor da Direção Elétrica (EPAS) - circuito/falha mecânica",
    "C109A": "Módulo da Direção Elétrica (PSCM) - mau funcionamento interno",
    "C1145": "Sensor de velocidade da roda dianteira direita - falha de entrada",
    "C1155": "Sensor de velocidade da roda dianteira esquerda - falha de entrada",
    "C1165": "Sensor de velocidade da roda traseira direita - falha de entrada",
    "C1175": "Sensor de velocidade da roda traseira esquerda - falha de entrada",

    # ------------------------------------------------ Carroceria / Conforto / BCM (B0xxx / B1xxx)
    "B10A2": "Entrada de impacto do módulo de airbag / status de colisão no BCM",
    "B10EA": "Interruptor do aquecedor / ventilação do ventilador interno",
    "B1131": "Módulo do motor do limpador de para-brisa - sem resposta",
    "B1202": "Sensor de nível de combustível do tanque - circuito aberto",
    "B1A84": "Dados de configuração do veículo inválidos ou não programados",
    "B1B70": "Atuador da portinhola de recirculação do ar condicionado - falha de circuito",
    "B1D00": "Farol baixo esquerdo - circuito aberto ou em curto",
    "B1D01": "Farol baixo direito - circuito aberto ou em curto",
    "B1D02": "Farol alto esquerdo - circuito aberto ou em curto",
    "B1D03": "Farol alto direito - circuito aberto ou em curto",
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
    # Remove prefixo de módulo se existir, ex: "[ABS] C0031" -> "C0031"
    clean_code = code.split("]")[-1].strip() if "]" in code else code.strip()
    if clean_code in DTC_DESCRIPTIONS:
        return DTC_DESCRIPTIONS[clean_code]

    # Heurística inteligente baseada no padrão SAE J2012 / ISO 15031-6
    if len(clean_code) >= 2:
        prefix = clean_code[:2].upper()
        if prefix.startswith("U"):
            return "Rede CAN / Barramento: Perda de comunicação ou dados inválidos entre módulos"
        elif prefix.startswith("C"):
            return "Chassi / Freios ABS / Direção Elétrica EPAS: Falha em sensor ou atuador"
        elif prefix.startswith("B"):
            return "Carroceria / BCM / Conforto: Falha em circuito elétrico, iluminação ou travas"
        elif prefix in ("P1", "P2"):
            return "Trem de Força / Injeção: Falha específica do fabricante (Ford)"
        elif prefix == "P0":
            return "Trem de Força / Injeção: Falha padronizada de emissões/motor (ISO/SAE)"

    return "Descrição não cadastrada (consulte o manual)"


def parse_dtcs_hex(raw_hex: str) -> List[Tuple[str, str]]:
    """Decodifica string hexadecimal no formato Modo 03 em [(código, descrição)]."""
    codes = []
    clean = raw_hex.replace(" ", "").upper()
    idx = clean.find("43")
    payload = clean[idx + 2:] if idx != -1 else clean
    for i in range(0, len(payload) - 3, 4):
        c = payload[i:i + 4]
        if len(c) == 4 and c != "0000":
            code = decode_dtc(c)
            if code not in [k for k, _ in codes]:
                codes.append((code, describe(code)))
    return codes


def parse_kwp_dtcs_hex(raw_hex: str) -> List[Tuple[str, str]]:
    """Decodifica string hexadecimal no formato VAG KWP2000 Serviço 18 em [(código, descrição)]."""
    codes = []
    clean = raw_hex.replace(" ", "").upper()
    idx = clean.find("58")
    payload = clean[idx + 2:] if idx != -1 else clean
    if len(payload) >= 2:
        try:
            n_dtcs = int(payload[:2], 16)
        except ValueError:
            n_dtcs = len(payload[2:]) // 6
        data = payload[2:]
        for i in range(n_dtcs):
            chunk = data[i * 6: i * 6 + 4]
            if len(chunk) == 4 and chunk != "0000":
                code = decode_dtc(chunk)
                if code not in [k for k, _ in codes]:
                    codes.append((code, describe(code)))
    return codes


def parse_mil(data: bytes) -> Tuple[bool, int]:
    """PID 0101: byte A bit7 = MIL (luz de injeção), bits 0-6 = qtde de DTCs."""
    return bool(data[0] & 0x80), data[0] & 0x7F
