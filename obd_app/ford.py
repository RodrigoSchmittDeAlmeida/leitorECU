"""Módulo de diagnóstico Ford HS-CAN (ISO 15765-4 / UDS ISO 14229) para Ford Ka+ 2016 SEL 1.5 Sigma.

Plataforma Ford B562 (Ka 3ª geração).
Motor: Ford Sigma 1.5 16V DOHC Flex 4 cilindros (comandos de válvulas fixos, SEM VVT / SEM Ti-VCT).
(Nota: O motor Sigma 1.5 do Ka não possui comando variável. Não confundir com o Sigma 1.6 Ti-VCT do Fiesta ou o motor Dragon 1.5 de 3 cilindros).

Barramento de alta velocidade HS-CAN a 500 kbps (pinos 6 e 14 do conector OBD2):
- PCM  (0x7E0 / 0x7E8): Módulo do Motor Sigma 1.5 16V Flex DOHC (comandos fixos)
- BCM  (0x726 / 0x72E): Módulo de Carroceria e Conforto (portas, travas, vidros, faróis, limpadores)
- ABS  (0x760 / 0x768): Freios ABS, Controle de Estabilidade (ESC) e Assistente de Partida em Rampa (HLA)
- IPC  (0x720 / 0x728): Painel de Instrumentos (odômetro, combustível, temp externa, alertas)
- PSCM (0x730 / 0x738): Módulo da Direção Elétrica Progressiva (EPAS)
- RCM  (0x737 / 0x73F): Módulo de Airbags e Pré-tensionadores
- ACM  (0x727 / 0x72F): Módulo de Áudio e Conectividade SYNC
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Dict, List, Optional, Tuple


@dataclass(frozen=True)
class FordModule:
    key: str
    name: str
    tx_id: str
    rx_id: str
    desc: str


# Módulos presentes no barramento HS-CAN (500 kbps) do Ford Ka+ 2016 SEL
FORD_MODULES: Dict[str, FordModule] = {
    "pcm": FordModule("pcm", "PCM", "7E0", "7E8", "Módulo do Motor Sigma 1.5 16V Flex DOHC"),
    "bcm": FordModule("bcm", "BCM", "726", "72E", "Módulo de Carroceria e Conforto (GEM)"),
    "abs": FordModule("abs", "ABS/ESC", "760", "768", "Sistema de Freios ABS, ESC e HLA"),
    "ipc": FordModule("ipc", "IPC", "720", "728", "Painel de Instrumentos e Odômetro"),
    "pscm": FordModule("pscm", "PSCM", "730", "738", "Direção Elétrica Progressiva (EPAS)"),
    "rcm": FordModule("rcm", "RCM", "737", "73F", "Módulo de Airbags e Retenção"),
}


@dataclass(frozen=True)
class FordDid:
    key: str
    module_key: str
    did: str
    label: str
    unit: str
    fmt: str
    decode_fn: Callable[[bytes], Dict[str, float]]
    fast: bool = False  # se True, lê com maior frequência


# ----------------------------------------------------------- Decodificadores
def _dec_bcm_doors(d: bytes) -> Dict[str, float]:
    """Status de portas, capô e porta-malas (BCM DID 22404C ou 22404D)."""
    # Byte 0/1: bits de interruptores de porta
    b0 = d[0] if len(d) > 0 else 0
    b1 = d[1] if len(d) > 1 else 0
    return {
        "door_fl": 1.0 if (b0 & 0x01) else 0.0,      # Dianteira Esquerda (Motorista)
        "door_fr": 1.0 if (b0 & 0x02) else 0.0,      # Dianteira Direita (Passageiro)
        "door_rl": 1.0 if (b0 & 0x04) else 0.0,      # Traseira Esquerda
        "door_rr": 1.0 if (b0 & 0x08) else 0.0,      # Traseira Direita
        "door_trunk": 1.0 if (b0 & 0x10) else 0.0,   # Porta-malas (Sedan)
        "door_hood": 1.0 if (b0 & 0x20) else 0.0,    # Capô do motor
        "central_lock": 1.0 if (b1 & 0x01) else 0.0, # Travas Trancadas = 1, Destrancadas = 0
    }


def _dec_bcm_lighting(d: bytes) -> Dict[str, float]:
    """Status de iluminação externa e interna (BCM DID 224050)."""
    b0 = d[0] if len(d) > 0 else 0
    b1 = d[1] if len(d) > 1 else 0
    return {
        "parking_lights": 1.0 if (b0 & 0x01) else 0.0,  # Lanternas
        "low_beam": 1.0 if (b0 & 0x02) else 0.0,        # Farol Baixo
        "high_beam": 1.0 if (b0 & 0x04) else 0.0,       # Farol Alto
        "fog_lights": 1.0 if (b0 & 0x08) else 0.0,      # Faróis de Neblina dianteiros
        "turn_left": 1.0 if (b1 & 0x01) else 0.0,       # Seta Esquerda
        "turn_right": 1.0 if (b1 & 0x02) else 0.0,      # Seta Direita
        "hazard_lights": 1.0 if (b1 & 0x04) else 0.0,   # Pisca-Alerta
    }


def _dec_bcm_accessories(d: bytes) -> Dict[str, float]:
    """Status de acessórios: limpadores, desembaçador, ignição (BCM DID 224060)."""
    b0 = d[0] if len(d) > 0 else 0
    b1 = d[1] if len(d) > 1 else 0
    return {
        "wiper_status": float(b0 & 0x07),               # 0=Desl, 1=Intermitente, 2=Lento, 3=Rápido
        "rear_defrost": 1.0 if (b0 & 0x08) else 0.0,    # Desembaçador Traseiro
        "ignition_pos": float((b1 >> 4) & 0x0F),        # 0=Off, 1=Acc, 2=Run, 3=Crank
        "alarm_armed": 1.0 if (b1 & 0x01) else 0.0,     # Alarme Perimétrico/Volumétrico
    }


def _dec_bcm_voltage(d: bytes) -> Dict[str, float]:
    """Tensão da bateria medida pelo módulo de conforto BCM (DID 224001)."""
    if len(d) >= 2:
        val = ((d[0] << 8) | d[1]) / 100.0 if len(d) >= 2 else (d[0] * 0.1)
    else:
        val = d[0] * 0.1
    return {"bcm_battery_v": val}


def _dec_abs_wheels(d: bytes) -> Dict[str, float]:
    """Velocidade individual das 4 rodas (ABS/ESC DID 222B00)."""
    # 4 palavras de 16 bits em 0.01 km/h ou km/h
    res = {}
    if len(d) >= 8:
        fl = ((d[0] << 8) | d[1]) * 0.01
        fr = ((d[2] << 8) | d[3]) * 0.01
        rl = ((d[4] << 8) | d[5]) * 0.01
        rr = ((d[6] << 8) | d[7]) * 0.01
    elif len(d) >= 4:
        fl = float(d[0])
        fr = float(d[1])
        rl = float(d[2])
        rr = float(d[3])
    else:
        return {}
    res["wheel_speed_fl"] = fl
    res["wheel_speed_fr"] = fr
    res["wheel_speed_rl"] = rl
    res["wheel_speed_rr"] = rr
    return res


def _dec_abs_dynamics(d: bytes) -> Dict[str, float]:
    """Dinâmica de freio e estabilidade (ABS DID 222B01): pressão de freio, pedal, SAS."""
    res = {}
    if len(d) >= 2:
        # Pressão no cilindro mestre de freio (bar)
        press = ((d[0] << 8) | d[1]) * 0.1
        res["brake_pressure"] = press
    if len(d) >= 3:
        res["brake_pedal_sw"] = 1.0 if (d[2] & 0x01) else 0.0
        res["esc_active"] = 1.0 if (d[2] & 0x04) else 0.0
    if len(d) >= 5:
        # Ângulo do sensor de esterçamento SAS (-720 a +720 graus)
        raw_angle = (d[3] << 8) | d[4]
        if raw_angle > 32767:
            raw_angle -= 65536
        res["steering_angle_abs"] = raw_angle * 0.1
    return res


def _dec_pcm_cht(d: bytes) -> Dict[str, float]:
    """Temperatura da Cabeça do Cilindro CHT - motor Sigma 1.5 16V (DID 221624)."""
    if len(d) >= 2:
        val = ((d[0] << 8) | d[1]) * 0.1 - 40.0
    elif len(d) == 1:
        val = float(d[0] - 40)
    else:
        return {}
    return {"cht_temp": val}


def _dec_pcm_pedal(d: bytes) -> Dict[str, float]:
    """Posição do pedal do acelerador eletrônico APP (DID 22032B)."""
    if len(d) >= 1:
        return {"app_pedal_pct": float(d[0] * 100.0 / 255.0)}
    return {}


def _dec_pcm_fan(d: bytes) -> Dict[str, float]:
    """Controle PWM do eletroventilador do radiador (DID 220332)."""
    if len(d) >= 1:
        return {"fan_duty_pct": float(d[0] * 100.0 / 255.0)}
    return {}


def _dec_pcm_injection(d: bytes) -> Dict[str, float]:
    """Tempo de injeção dos bicos injetores (DID 221125)."""
    if len(d) >= 2:
        pw = ((d[0] << 8) | d[1]) * 0.001  # ms
        return {"inj_pulse_width": pw}
    return {}


def _dec_pcm_ac(d: bytes) -> Dict[str, float]:
    """Pressão do sistema de ar condicionado e embreagem do compressor (DID 221101)."""
    res = {}
    if len(d) >= 2:
        kpa = float((d[0] << 8) | d[1])
        res["ac_pressure_kpa"] = kpa
    if len(d) >= 3:
        res["ac_clutch"] = 1.0 if (d[2] & 0x01) else 0.0
    return res


def _dec_pcm_flex(d: bytes) -> Dict[str, float]:
    """Porcentagem calculada de etanol no tanque de combustível (DID 221608)."""
    if len(d) >= 1:
        return {"flex_ethanol_pct": float(d[0])}
    return {}


def _dec_pcm_cat_temp(d: bytes) -> Dict[str, float]:
    """Temperatura estimada do catalisador (PCM DID 221627)."""
    if len(d) >= 2:
        raw = (d[0] << 8) | d[1]
        return {"cat_temp": (raw / 10.0) - 40.0}
    return {}


def _dec_pcm_baro(d: bytes) -> Dict[str, float]:
    """Pressão barométrica absoluta (PCM DID 220320)."""
    if len(d) >= 1:
        return {"baro": float(d[0])}
    return {}


def _dec_ipc_odometer(d: bytes) -> Dict[str, float]:
    """Odômetro total em km (IPC DID 22DD01)."""
    if len(d) >= 3:
        km = float((d[0] << 16) | (d[1] << 8) | d[2])
        return {"odometer_km": km}
    elif len(d) >= 4:
        km = float((d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3]) / 10.0
        return {"odometer_km": km}
    return {}


def _dec_ipc_dashboard(d: bytes) -> Dict[str, float]:
    """Nível de combustível, temp externa, alertas de cinto e freio de mão (IPC DID 222416)."""
    res = {}
    if len(d) >= 1:
        res["fuel_level_pct"] = float(d[0] * 100.0 / 255.0)
    if len(d) >= 2:
        res["ext_temp"] = float(d[1] - 40)
    if len(d) >= 3:
        res["seatbelt_warning"] = 1.0 if (d[2] & 0x01) else 0.0
        res["parking_brake"] = 1.0 if (d[2] & 0x02) else 0.0
    return res


def _dec_pscm_steering(d: bytes) -> Dict[str, float]:
    """Direção elétrica EPAS: ângulo do volante, torque e corrente (PSCM DID 223300)."""
    res = {}
    if len(d) >= 2:
        ang = (d[0] << 8) | d[1]
        if ang > 32767:
            ang -= 65536
        res["steering_wheel_angle"] = ang * 0.1
    if len(d) >= 4:
        trq = (d[2] << 8) | d[3]
        if trq > 32767:
            trq -= 65536
        res["steering_driver_torque"] = trq * 0.01  # Nm
    if len(d) >= 5:
        res["steering_motor_current"] = float(d[4]) * 0.5  # Amperes
    return res


# Dicionário de DIDs Ford suportados
FORD_DIDS: Dict[str, FordDid] = {
    # Módulo de Conforto (BCM 726)
    "bcm_doors": FordDid("bcm_doors", "bcm", "22404C", "Status Portas & Travas", "", "", _dec_bcm_doors),
    "bcm_lighting": FordDid("bcm_lighting", "bcm", "224050", "Status de Iluminação", "", "", _dec_bcm_lighting),
    "bcm_accessories": FordDid("bcm_accessories", "bcm", "224060", "Limpadores & Ignição", "", "", _dec_bcm_accessories),
    "bcm_voltage": FordDid("bcm_voltage", "bcm", "224001", "Tensão Bateria BCM", "V", "{:.1f}", _dec_bcm_voltage),

    # Freios ABS / ESC (ABS 760)
    "abs_wheels": FordDid("abs_wheels", "abs", "222B00", "Velocidade 4 Rodas", "km/h", "{:.1f}", _dec_abs_wheels, fast=True),
    "abs_dynamics": FordDid("abs_dynamics", "abs", "222B01", "Pressão Freio & SAS", "bar", "{:.1f}", _dec_abs_dynamics),

    # Motor Sigma 1.5 16V Flex DOHC (comandos fixos, sem VVT)
    "pcm_cht": FordDid("pcm_cht", "pcm", "221624", "Temp. Cabeça Cilindro (CHT)", "°C", "{:.0f}", _dec_pcm_cht),
    "pcm_pedal": FordDid("pcm_pedal", "pcm", "22032B", "Pedal Acelerador (APP)", "%", "{:.1f}", _dec_pcm_pedal),
    "pcm_fan": FordDid("pcm_fan", "pcm", "220332", "Eletroventilador Radiador", "%", "{:.0f}", _dec_pcm_fan),
    "pcm_injection": FordDid("pcm_injection", "pcm", "221125", "Tempo de Injeção", "ms", "{:.2f}", _dec_pcm_injection),
    "pcm_ac": FordDid("pcm_ac", "pcm", "221101", "Pressão A/C", "kPa", "{:.0f}", _dec_pcm_ac),
    "pcm_flex": FordDid("pcm_flex", "pcm", "221608", "Etanol Flex no Tanque", "%", "{:.0f}", _dec_pcm_flex),
    "pcm_cat_temp": FordDid("pcm_cat_temp", "pcm", "221627", "Temp. Catalisador", "°C", "{:.0f}", _dec_pcm_cat_temp),
    "pcm_baro": FordDid("pcm_baro", "pcm", "220320", "Pressão Barométrica", "kPa", "{:.0f}", _dec_pcm_baro),

    # Painel de Instrumentos (IPC 720)
    "ipc_odometer": FordDid("ipc_odometer", "ipc", "22DD01", "Odômetro Total", "km", "{:.0f}", _dec_ipc_odometer),
    "ipc_dashboard": FordDid("ipc_dashboard", "ipc", "222416", "Painel (Comb./Temp. Ext.)", "", "", _dec_ipc_dashboard),

    # Direção Elétrica (PSCM 730)
    "pscm_steering": FordDid("pscm_steering", "pscm", "223300", "Direção Elétrica EPAS", "", "", _dec_pscm_steering),
}


# Canais Ford individuais exportados para a telemetria e CSV
FORD_CHANNELS_INFO: Dict[str, Tuple[str, str]] = {
    # BCM Conforto
    "door_fl": ("Porta Diant. Esq. (Motorista)", "0/1"),
    "door_fr": ("Porta Diant. Dir. (Passageiro)", "0/1"),
    "door_rl": ("Porta Tras. Esq.", "0/1"),
    "door_rr": ("Porta Tras. Dir.", "0/1"),
    "door_trunk": ("Porta-Malas (Sedan)", "0/1"),
    "door_hood": ("Capô do Motor", "0/1"),
    "central_lock": ("Travas Elétricas (Trancado)", "0/1"),
    "low_beam": ("Farol Baixo", "0/1"),
    "high_beam": ("Farol Alto", "0/1"),
    "fog_lights": ("Faróis de Neblina", "0/1"),
    "parking_lights": ("Lanternas", "0/1"),
    "turn_left": ("Seta Esquerda", "0/1"),
    "turn_right": ("Seta Direita", "0/1"),
    "hazard_lights": ("Pisca-Alerta", "0/1"),
    "wiper_status": ("Limpador Para-brisa", "modo"),
    "rear_defrost": ("Desembaçador Traseiro", "0/1"),
    "ignition_pos": ("Posição da Ignição", "pos"),
    "alarm_armed": ("Alarme Perimétrico", "0/1"),
    "bcm_battery_v": ("Tensão Bateria (BCM)", "V"),

    # ABS & Estabilidade
    "wheel_speed_fl": ("Velocidade Roda Diant. Esq.", "km/h"),
    "wheel_speed_fr": ("Velocidade Roda Diant. Dir.", "km/h"),
    "wheel_speed_rl": ("Velocidade Roda Tras. Esq.", "km/h"),
    "wheel_speed_rr": ("Velocidade Roda Tras. Dir.", "km/h"),
    "brake_pressure": ("Pressão do Freio", "bar"),
    "brake_pedal_sw": ("Interruptor Freio", "0/1"),
    "esc_active": ("Intervenção ESC/ABS", "0/1"),
    "steering_angle_abs": ("Ângulo Esterçamento (SAS)", "°"),

    # Motor Sigma 1.5 16V Flex DOHC (comandos fixos, sem VVT)
    "cht_temp": ("Temp. Cabeça Cilindro (CHT)", "°C"),
    "app_pedal_pct": ("Pedal Acelerador (APP)", "%"),
    "fan_duty_pct": ("Eletroventilador Radiador", "%"),
    "inj_pulse_width": ("Tempo de Injeção", "ms"),
    "ac_pressure_kpa": ("Pressão Refrigerante A/C", "kPa"),
    "ac_clutch": ("Embreagem Compressor A/C", "0/1"),
    "flex_ethanol_pct": ("Teor de Etanol Tanque", "%"),
    "cat_temp": ("Temp. Catalisador (UDS)", "°C"),
    "baro": ("Pressão Barométrica (UDS)", "kPa"),

    # Painel & Direção
    "odometer_km": ("Odômetro Total", "km"),
    "fuel_level_pct": ("Nível de Combustível", "%"),
    "ext_temp": ("Temperatura Externa", "°C"),
    "seatbelt_warning": ("Alerta Cinto Segurança", "0/1"),
    "parking_brake": ("Freio de Mão", "0/1"),
    "steering_wheel_angle": ("Ângulo Volante EPAS", "°"),
    "steering_driver_torque": ("Torque Aplicado Volante", "Nm"),
    "steering_motor_current": ("Corrente Motor Direção", "A"),
}

