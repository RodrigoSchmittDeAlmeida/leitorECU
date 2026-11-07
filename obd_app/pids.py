"""Definição dos canais (sensores), PIDs do Modo 01, blocos VW KWP2000 (Modo 21) e fórmulas.

A = primeiro byte de dados, B = segundo byte (após os bytes de confirmação ``41 XX`` ou ``61 XX``).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Dict, Optional, Tuple


@dataclass(frozen=True)
class Channel:
    key: str
    label: str
    unit: str
    fmt: str = "{:.0f}"
    card: bool = True  # se True, exibe card no topo; todos os canais são gravados no CSV


# Todos os canais exibidos/gravados (ordem = ordem das colunas do CSV)
CHANNELS: Dict[str, Channel] = {
    c.key: c
    for c in (
        # Linha 1 de Cards (Ar, Giro, Carga e Elétrica - 7 cards)
        Channel("rpm", "RPM", "rpm", "{:.0f}", card=True),
        Channel("map", "MAP", "kPa", "{:.0f}", card=True),
        Channel("advance", "Avanço", "°", "{:.1f}", card=True),
        Channel("tps", "Borboleta (TPS)", "%", "{:.1f}", card=True),
        Channel("load", "Carga Calculada", "%", "{:.1f}", card=True),
        Channel("speed", "Velocidade", "km/h", "{:.0f}", card=True),
        Channel("battery", "Bateria", "V", "{:.1f}", card=True),

        # Linha 2 de Cards (Sondas 1 e 2, Mistura e Temperaturas - 7 cards)
        Channel("lambda_v", "Sonda 1 (Pré)", "V", "{:.3f}", card=True),
        Channel("lambda2_v", "Sonda 2 (Pós)", "V", "{:.3f}", card=True),
        Channel("lambda_trim", "Correção Sonda", "%", "{:.1f}", card=True),
        Channel("stft", "STFT", "%", "{:.1f}", card=True),
        Channel("ltft", "LTFT", "%", "{:.1f}", card=True),
        Channel("ect", "Temp. Motor (ECT)", "°C", "{:.0f}", card=True),
        Channel("iat", "Temp. Ar (IAT)", "°C", "{:.0f}", card=True),

        # Canais adicionais reportados pela ECU (gravados no CSV continuamente)
        Channel("lambda2_trim", "Correção Sonda 2", "%", "{:.1f}", card=False),
        Channel("fuel_sys1", "Status Malha Comb. 1 (0103)", "cod", "{:.0f}", card=False),
        Channel("fuel_sys2", "Status Malha Comb. 2 (0103)", "cod", "{:.0f}", card=False),
        Channel("cat_temp", "Temp. Catalisador (013C)", "°C", "{:.0f}", card=False),
        Channel("ecu_volt", "Tensão Interna ECU", "V", "{:.2f}", card=False),
        Channel("obd_pin16_v", "Tensão Pino 16 OBD (ATRV)", "V", "{:.2f}", card=False),
        Channel("baro", "Pressão Barométrica (0133)", "kPa", "{:.0f}", card=False),
        Channel("fuel_rate", "Consumo Instantâneo (015E)", "L/h", "{:.1f}", card=False),
        Channel("fuel_rate_lph", "Consumo Instantâneo", "L/h", "{:.2f}", card=False),
        Channel("fuel_econ_kml", "Economia Combustível", "km/l", "{:.1f}", card=False),
        Channel("volumetric_eff", "Eficiência Volumétrica", "%", "{:.1f}", card=False),
        Channel("mil_on", "Luz Injeção (0101)", "0/1", "{:.0f}", card=False),
        Channel("dtc_count", "Qtd. DTCs (0101)", "un", "{:.0f}", card=False),
        Channel("o2_mask", "Máscara Sondas (0113)", "bit", "{:.0f}", card=False),
        Channel("obd_std", "Padrão OBD (011C)", "id", "{:.0f}", card=False),
        Channel("dist_mil", "Dist. c/ MIL (0121)", "km", "{:.0f}", card=False),
        Channel("fuel_type", "Tipo Combustível (0151)", "id", "{:.0f}", card=False),
        Channel("inj_ms", "Tempo de Injeção", "ms", "{:.2f}", card=False),
        Channel("flex_ethanol_pct", "Teor de Etanol Flex", "%", "{:.1f}", card=False),
        Channel("app_pedal_pct", "Pedal Acelerador (APP)", "%", "{:.1f}", card=False),
        Channel("power_hp", "Potência Estimada", "cv", "{:.1f}", card=False),
        Channel("torque_kgfm", "Torque Estimado", "kgfm", "{:.1f}", card=False),
        Channel("lambda_error_pct", "Desvio Mistura Lambda", "%", "{:+.1f}", card=False),
        Channel("trip_liters", "Combustível Viagem", "L", "{:.3f}", card=False),
        Channel("trip_cost_brl", "Custo Viagem", "R$", "{:.2f}", card=False),
        Channel("trip_avg_kml", "Consumo Médio Viagem", "km/l", "{:.1f}", card=False),
        Channel("trip_km", "Distância Viagem", "km", "{:.2f}", card=False),
    )
}


def _trim(a: int) -> float:
    return ((a - 128) * 100.0) / 128.0


def _dec_lambda_nb(d: bytes) -> Dict[str, Optional[float]]:
    """PID 0114: Sonda convencional B1S1 (A/200 Volts, B = STFT da sonda)."""
    a, b = d[0], d[1]
    out: Dict[str, Optional[float]] = {"lambda_v": a / 200.0, "lambda_trim": None}
    if b != 0xFF:
        t = _trim(b)
        out["lambda_trim"] = t
        out["stft"] = t
    return out


def _dec_lambda_nb2(d: bytes) -> Dict[str, Optional[float]]:
    """PID 0115: Sonda convencional B1S2 (pós-catalisador) (A/200 Volts, B = trim secundário)."""
    a, b = d[0], d[1]
    v = a / 200.0
    out: Dict[str, Optional[float]] = {"lambda2_v": v}
    if b != 0xFF:
        t = _trim(b)
        out["lambda2_trim"] = t
    return out


def _dec_lambda_wb_v(d: bytes) -> Dict[str, Optional[float]]:
    """PID 0124: 4 bytes (AB = Fator Lambda 0..2, CD = Tensão 0..8 V)."""
    eq = ((d[0] * 256) + d[1]) * 2.0 / 65536.0
    v = ((d[2] * 256) + d[3]) * 8.0 / 65536.0
    if 0.005 <= v <= 5.0:
        return {"lambda_v": v}
    return {"lambda_v": eq}


def _dec_lambda_wb_i(d: bytes) -> Dict[str, Optional[float]]:
    """PID 0134: 4 bytes (AB = Fator Lambda 0..2, CD = Corrente mA)."""
    eq = ((d[0] * 256) + d[1]) * 2.0 / 65536.0
    return {"lambda_v": eq}


from .vag import decode_cell


def decode_vag_cell(k: int, a: int, b: int) -> Tuple[Optional[float], str]:
    """Decodifica uma célula de 3 bytes (fórmula k, byte A, byte B) usando vag.py como fonte única."""
    r = decode_cell(k, a, b)
    if r is None:
        return None, ""
    return r


def _dec_vag_group33(d: bytes) -> Dict[str, Optional[float]]:
    """Bloco VW 033 (comando 2121): Célula 1 = Correção Sonda/STFT (%), Célula 2 = Tensão Sonda (V)."""
    out: Dict[str, Optional[float]] = {}
    v1, u1 = decode_vag_cell(d[0], d[1], d[2])
    v2, u2 = decode_vag_cell(d[3], d[4], d[5])
    if v1 is not None and u1 == "%":
        out["lambda_trim"] = v1
        out["stft"] = v1
    elif v1 is not None and u1 in ("V", "lambda", "λ"):
        out["lambda_v"] = v1
    if v2 is not None and u2 in ("V", "lambda", "λ"):
        out["lambda_v"] = v2
    elif v2 is not None and u2 == "%" and "stft" not in out:
        out["lambda_trim"] = v2
        out["stft"] = v2
    return out


def _dec_vag_group32(d: bytes) -> Dict[str, Optional[float]]:
    """Bloco VW 032 (comando 2120): Célula 1 = LTFT Lenta (%), Célula 2 = LTFT Parcial (%), Célula 4 = Tensão Ref (V)."""
    out: Dict[str, Optional[float]] = {}
    v1, u1 = decode_vag_cell(d[0], d[1], d[2])
    v2, u2 = decode_vag_cell(d[3], d[4], d[5])
    if v2 is not None and u2 == "%":
        out["ltft"] = v2
    elif v1 is not None and u1 == "%":
        out["ltft"] = v1
    if len(d) >= 12:
        v4, u4 = decode_vag_cell(d[9], d[10], d[11])
        if v4 is not None and u4 == "V" and 5.0 <= v4 <= 18.0:
            out["ecu_volt"] = v4
            out.setdefault("battery", v4)
    return out


def _dec_vag_group31(d: bytes) -> Dict[str, Optional[float]]:
    """Bloco VW 031 (comando 211F): Célula 1 = Sonda Lambda 1 (V), Célula 3 = Sonda 2."""
    v1, _ = decode_vag_cell(d[0], d[1], d[2])
    return {"lambda_v": v1} if v1 is not None else {}


def _dec_vag_group01(d: bytes) -> Dict[str, Optional[float]]:
    """Bloco VW 001 (comando 2101): Célula 1 = RPM, Célula 2 = ECT (°C), Célula 3 = Correção Lambda (%)."""
    out: Dict[str, Optional[float]] = {}
    if len(d) >= 9:
        v1, u1 = decode_vag_cell(d[0], d[1], d[2])
        v2, u2 = decode_vag_cell(d[3], d[4], d[5])
        v3, u3 = decode_vag_cell(d[6], d[7], d[8])
        if v1 is not None and u1 == "rpm":
            out["rpm"] = v1
        if v2 is not None and u2 in ("°C", "C"):
            out["ect"] = v2
        if v3 is not None and u3 == "%":
            out["lambda_trim"] = v3
            out["stft"] = v3
        elif v3 is not None and u3 in ("V", "lambda", "λ"):
            out["lambda_v"] = v3
    return out


def _dec_vag_group02(d: bytes) -> Dict[str, Optional[float]]:
    """Bloco VW 002 (comando 2102): C1 = RPM, C2 = Carga (%), C3 = Tempo Injeção (ms), C4 = MAP (mbar)."""
    out: Dict[str, Optional[float]] = {}
    if len(d) >= 12:
        v1, u1 = decode_vag_cell(d[0], d[1], d[2])
        v2, u2 = decode_vag_cell(d[3], d[4], d[5])
        v3, u3 = decode_vag_cell(d[6], d[7], d[8])
        v4, u4 = decode_vag_cell(d[9], d[10], d[11])
        if v1 is not None and u1 == "rpm":
            out["rpm"] = v1
        if v2 is not None and u2 == "%":
            out["load"] = v2
        if v3 is not None and "ms" in u3:
            out["inj_ms"] = v3
            out["inj_pulse_width"] = v3
        if v4 is not None and u4 == "mbar":
            out["map"] = v4 / 10.0  # mbar -> kPa
    return out


def _dec_vag_group03(d: bytes) -> Dict[str, Optional[float]]:
    """Bloco VW 003 (comando 2103): C1 = RPM, C2 = MAP (mbar), C3 = TPS (%), C4 = Avanço (°)."""
    out: Dict[str, Optional[float]] = {}
    if len(d) >= 12:
        v1, u1 = decode_vag_cell(d[0], d[1], d[2])
        v2, u2 = decode_vag_cell(d[3], d[4], d[5])
        v3, u3 = decode_vag_cell(d[6], d[7], d[8])
        v4, u4 = decode_vag_cell(d[9], d[10], d[11])
        if v1 is not None and u1 == "rpm":
            out["rpm"] = v1
        if v2 is not None and u2 == "mbar":
            out["map"] = v2 / 10.0  # mbar -> kPa
        if v3 is not None and u3 == "%":
            out["tps"] = v3
        if v4 is not None and u4 in ("°", "deg", "°KW"):
            out["advance"] = v4
    return out


def _dec_vag_group04(d: bytes) -> Dict[str, Optional[float]]:
    """Bloco VW 004 (comando 2104): C1 = RPM, C2 = Bateria (V), C3 = ECT (°C), C4 = IAT (°C)."""
    out: Dict[str, Optional[float]] = {}
    if len(d) >= 12:
        v1, u1 = decode_vag_cell(d[0], d[1], d[2])
        v2, u2 = decode_vag_cell(d[3], d[4], d[5])
        v3, u3 = decode_vag_cell(d[6], d[7], d[8])
        v4, u4 = decode_vag_cell(d[9], d[10], d[11])
        if v1 is not None and u1 == "rpm":
            out["rpm"] = v1
        elif v1 is not None and u1 == "V":
            out["battery"] = v1
            out["ecu_volt"] = v1
        if v2 is not None and u2 == "V":
            out["battery"] = v2
            out["ecu_volt"] = v2
        elif v2 is not None and u2 in ("°C", "C"):
            out["ect"] = v2
        if v3 is not None and u3 in ("°C", "C"):
            if "ect" not in out:
                out["ect"] = v3
            else:
                out["iat"] = v3
        if v4 is not None and u4 in ("°C", "C"):
            out["iat"] = v4
    return out


def _dec_vag_group05(d: bytes) -> Dict[str, Optional[float]]:
    """Bloco VW 005 (comando 2105): C1 = RPM, C2 = Carga (%), C3 = Velocidade (km/h), C4 = Estado de Operação."""
    out: Dict[str, Optional[float]] = {}
    if len(d) >= 9:
        v1, u1 = decode_vag_cell(d[0], d[1], d[2])
        v2, u2 = decode_vag_cell(d[3], d[4], d[5])
        v3, u3 = decode_vag_cell(d[6], d[7], d[8])
        if v1 is not None and u1 == "rpm":
            out["rpm"] = v1
        if v2 is not None and u2 == "%":
            out["load"] = v2
        if v3 is not None and u3 == "km/h":
            out["speed"] = v3
    if len(d) >= 12:
        # Célula 4: Estado de Operação da ME7.5 (bits de Lenta, Parcial, WOT, Cut-Off / Schubabschaltung)
        # Mapeamento para fuel_sys1 padrão SAE: Cut-Off = 1.0, Malha Fechada = 2.0, Enriquecimento/WOT = 4.0
        b4 = d[11]
        if (b4 & 0x08) or (b4 & 0x80):
            out["fuel_sys1"] = 1.0  # Cut-Off / Schubabschaltung
        elif b4 & 0x04:
            out["fuel_sys1"] = 4.0  # WOT / Enriquecimento Plena Carga
        else:
            out["fuel_sys1"] = 2.0  # Lenta / Parcial / Malha Fechada
    return out


def _dec_vag_group20(d: bytes) -> Dict[str, Optional[float]]:
    """Bloco VW 020 (comando 2114): Retardo de detonação Cilindros 1..4 (°KW)."""
    out: Dict[str, Optional[float]] = {}
    for idx, key in enumerate(("knock_ret_c1", "knock_ret_c2", "knock_ret_c3", "knock_ret_c4")):
        off = idx * 3
        if len(d) >= off + 3:
            v, _ = decode_vag_cell(d[off], d[off + 1], d[off + 2])
            if v is not None:
                out[key] = v
    return out


def _dec_vag_group26(d: bytes) -> Dict[str, Optional[float]]:
    """Bloco VW 026 (comando 211A): Tensão do sensor de detonação Cilindros 1..4 (V)."""
    out: Dict[str, Optional[float]] = {}
    for idx, key in enumerate(("knock_v_c1", "knock_v_c2", "knock_v_c3", "knock_v_c4")):
        off = idx * 3
        if len(d) >= off + 3:
            v, u = decode_vag_cell(d[off], d[off + 1], d[off + 2])
            if v is not None and u == "V":
                out[key] = v
    return out


def _dec_vag_group62(d: bytes) -> Dict[str, Optional[float]]:
    """Bloco VW 062 (comando 213E): C1 = TPS1 (%), C2 = TPS2 (%), C3 = Pedal APP1 (%), C4 = Pedal APP2 (%)."""
    out: Dict[str, Optional[float]] = {}
    if len(d) >= 12:
        v1, u1 = decode_vag_cell(d[0], d[1], d[2])
        v2, u2 = decode_vag_cell(d[3], d[4], d[5])
        v3, u3 = decode_vag_cell(d[6], d[7], d[8])
        v4, u4 = decode_vag_cell(d[9], d[10], d[11])
        if v1 is not None and u1 == "%":
            out["tps_track1"] = v1
        if v2 is not None and u2 == "%":
            out["tps_track2"] = v2
        if v3 is not None and u3 == "%":
            out["app_pedal_pct"] = v3
        if v4 is not None and u4 == "%":
            out["app_track2"] = v4
    return out


def _dec_vag_group103(d: bytes) -> Dict[str, Optional[float]]:
    """Bloco VW 103 (comando 2167): Adaptação de Combustível Flex (Teor de Etanol % em C1 ou C5)."""
    out: Dict[str, Optional[float]] = {}
    # Na ME7.5.30 (032906032AJ), C1..C4 podem ser vazios (00 00 00) e o Etanol % vir em C5 (offset 12)
    for cell_idx in (4, 0, 5, 1):
        off = cell_idx * 3
        if len(d) >= off + 3:
            v, u = decode_vag_cell(d[off], d[off + 1], d[off + 2])
            if v is not None and u == "%" and 0.0 <= v <= 100.0:
                out["flex_ethanol_pct"] = v
                out["ethanol"] = v
                break
    return out


@dataclass(frozen=True)
class PidDef:
    pid: int
    nbytes: int
    decode: Callable[[bytes], Dict[str, Optional[float]]]
    name: str
    mode: int = 0x01
    fast: bool = False   # lido também no modo "Prioridade de Desaceleração"
    extra: bool = False  # PID opcional / complementar
    slow: bool = False   # muda devagar: lido a cada N ciclos

    @property
    def key(self) -> int:
        return self.pid if self.mode == 0x01 else ((self.mode << 8) | self.pid)

    @property
    def cmd(self) -> str:
        return f"{self.mode:02X}{self.pid:02X}"


PIDS: Dict[int, PidDef] = {
    p.key: p
    for p in (
        PidDef(0x0C, 2, lambda d: {"rpm": ((d[0] * 256) + d[1]) / 4.0}, "RPM", fast=True),
        PidDef(0x0B, 1, lambda d: {"map": float(d[0])}, "MAP", fast=True),
        PidDef(0x0E, 1, lambda d: {"advance": (d[0] / 2.0) - 64.0}, "Avanço", fast=True),
        PidDef(0x11, 1, lambda d: {"tps": (d[0] * 100.0) / 255.0}, "TPS", fast=True),
        # Sondas Modo 01 (0114 B1S1, 0115 B1S2, 0116..011B bancos/sensores extras, 0124/0134 wideband)
        PidDef(0x14, 2, _dec_lambda_nb, "Sonda Lambda B1S1 (0114)", fast=True),
        PidDef(0x15, 2, _dec_lambda_nb2, "Sonda Lambda B1S2 (0115)", fast=True),
        PidDef(0x16, 2, _dec_lambda_nb, "Sonda Lambda B1S3 (0116)", fast=True),
        PidDef(0x17, 2, _dec_lambda_nb, "Sonda Lambda B1S4 (0117)", fast=True),
        PidDef(0x18, 2, _dec_lambda_nb, "Sonda Lambda B2S1 (0118)", fast=True),
        PidDef(0x19, 2, _dec_lambda_nb2, "Sonda Lambda B2S2 (0119)", fast=True),
        PidDef(0x24, 4, _dec_lambda_wb_v, "Sonda Lambda Eq/V (0124)", fast=True),
        PidDef(0x34, 4, _dec_lambda_wb_i, "Sonda Lambda Eq/mA (0134)", fast=True),
        # Fuel Trims e Temperatura Modo 01
        PidDef(0x06, 1, lambda d: {"stft": _trim(d[0])}, "STFT"),
        PidDef(0x07, 1, lambda d: {"ltft": _trim(d[0])}, "LTFT", slow=True),
        PidDef(0x05, 1, lambda d: {"ect": d[0] - 40.0}, "ECT", slow=True),
        # Blocos de Medição VW KWP2000 (Modo 21)
        PidDef(0x21, 6, _dec_vag_group33, "VW Bloco 033 Sonda+STFT (2121)", mode=0x21, fast=True),
        PidDef(0x20, 6, _dec_vag_group32, "VW Bloco 032 LTFT (2120)", mode=0x21, slow=True),
        PidDef(0x1F, 3, _dec_vag_group31, "VW Bloco 031 Sonda (211F)", mode=0x21, fast=True),
        PidDef(0x01, 9, _dec_vag_group01, "VW Bloco 001 RPM+ECT+STFT (2101)", mode=0x21),
        PidDef(0x02, 12, _dec_vag_group02, "VW Bloco 002 RPM+Carga+MAP (2102)", mode=0x21, extra=True),
        PidDef(0x03, 12, _dec_vag_group03, "VW Bloco 003 RPM+MAP+TPS+Avanço (2103)", mode=0x21, fast=True),
        PidDef(0x04, 12, _dec_vag_group04, "VW Bloco 004 RPM+Bat+ECT+IAT (2104)", mode=0x21, slow=True),
        PidDef(0x05, 9, _dec_vag_group05, "VW Bloco 005 RPM+Carga+Vel (2105)", mode=0x21, extra=True),
        PidDef(0x14, 12, _dec_vag_group20, "VW Bloco 020 Retardo Detonação (2114)", mode=0x21, extra=True),
        PidDef(0x1A, 12, _dec_vag_group26, "VW Bloco 026 Tensão Detonação (211A)", mode=0x21, extra=True),
        PidDef(0x3E, 12, _dec_vag_group62, "VW Bloco 062 Pistas TPS/APP (213E)", mode=0x21, extra=True),
        PidDef(0x67, 15, _dec_vag_group103, "VW Bloco 103 Adaptação Flex (2167)", mode=0x21, extra=True, slow=True),
        # Todos os demais PIDs que a sua ECU declarou no bitmap (01, 03, 04, 0D, 0F, 13, 1C, 21, 51)
        PidDef(0x04, 1, lambda d: {"load": (d[0] * 100.0) / 255.0}, "Carga", extra=True),
        PidDef(0x0D, 1, lambda d: {"speed": float(d[0])}, "Velocidade", extra=True),
        PidDef(0x0F, 1, lambda d: {"iat": d[0] - 40.0}, "IAT", extra=True, slow=True),
        PidDef(0x01, 4, lambda d: {"mil_on": 1.0 if (d[0] & 0x80) else 0.0, "dtc_count": float(d[0] & 0x7F)}, "Status Monitor (0101)", extra=True, slow=True),
        PidDef(0x03, 2, lambda d: {"fuel_sys1": float(d[0]), "fuel_sys2": float(d[1])}, "Status Malha Comb. (0103)", extra=True, slow=True),
        PidDef(0x13, 1, lambda d: {"o2_mask": float(d[0])}, "Sensores O2 Presentes (0113)", extra=True, slow=True),
        PidDef(0x1C, 1, lambda d: {"obd_std": float(d[0])}, "Padrão OBD (011C)", extra=True, slow=True),
        PidDef(0x21, 2, lambda d: {"dist_mil": float((d[0] * 256) + d[1])}, "Distância c/ MIL (0121)", extra=True, slow=True),
        PidDef(0x51, 1, lambda d: {"fuel_type": float(d[0])}, "Tipo Combustível (0151)", extra=True, slow=True),
        # PIDs SAE J1979 adicionais: só são lidos se a ECU declarar no bitmap (0100/0120/0140).
        # Na ME7.5.30 do Gol G5 nenhum deles existe; ficam para outros carros / modo OBD2 genérico.
        # As chaves abaixo NÃO estão em CHANNELS: entram no CSV como colunas dinâmicas (ver DYNAMIC_INFO).
        PidDef(0x08, 1, lambda d: {"stft_b2": _trim(d[0])}, "STFT Banco 2 (0108)", extra=True, slow=True),
        PidDef(0x09, 1, lambda d: {"ltft_b2": _trim(d[0])}, "LTFT Banco 2 (0109)", extra=True, slow=True),
        PidDef(0x0A, 1, lambda d: {"fuel_press": d[0] * 3.0}, "Pressão Combustível (010A)", extra=True, slow=True),
        PidDef(0x10, 2, lambda d: {"maf": ((d[0] * 256) + d[1]) / 100.0}, "MAF (0110)", extra=True),
        PidDef(0x1F, 2, lambda d: {"run_time": float((d[0] * 256) + d[1])}, "Tempo Motor Ligado (011F)", extra=True, slow=True),
        PidDef(0x2E, 1, lambda d: {"evap_purge": (d[0] * 100.0) / 255.0}, "Purga Cânister (012E)", extra=True, slow=True),
        PidDef(0x2F, 1, lambda d: {"fuel_level": (d[0] * 100.0) / 255.0}, "Nível Combustível (012F)", extra=True, slow=True),
        PidDef(0x30, 1, lambda d: {"warmups": float(d[0])}, "Aquecimentos desde Limpeza (0130)", extra=True, slow=True),
        PidDef(0x31, 2, lambda d: {"dist_clr": float((d[0] * 256) + d[1])}, "Distância desde Limpeza (0131)", extra=True, slow=True),
        PidDef(0x33, 1, lambda d: {"baro": float(d[0])}, "Pressão Barométrica (0133)", extra=True, slow=True),
        PidDef(0x3C, 2, lambda d: {"cat_temp": ((d[0] * 256) + d[1]) / 10.0 - 40.0}, "Temp. Catalisador B1S1 (013C)", extra=True, slow=True),
        PidDef(0x42, 2, lambda d: {"ecu_volt": ((d[0] * 256) + d[1]) / 1000.0, "battery": ((d[0] * 256) + d[1]) / 1000.0}, "Tensão Módulo (0142)", extra=True, slow=True),
        PidDef(0x43, 2, lambda d: {"abs_load": ((d[0] * 256) + d[1]) * 100.0 / 255.0}, "Carga Absoluta (0143)", extra=True),
        PidDef(0x44, 2, lambda d: {"cmd_lambda": ((d[0] * 256) + d[1]) * 2.0 / 65536.0}, "Lambda Comandado (0144)", extra=True),
        PidDef(0x45, 1, lambda d: {"rel_tps": (d[0] * 100.0) / 255.0}, "Borboleta Relativa (0145)", extra=True),
        PidDef(0x46, 1, lambda d: {"ambient": d[0] - 40.0}, "Temp. Ambiente (0146)", extra=True, slow=True),
        PidDef(0x47, 1, lambda d: {"tps_b": (d[0] * 100.0) / 255.0}, "Borboleta B (0147)", extra=True),
        PidDef(0x49, 1, lambda d: {"pedal_d": (d[0] * 100.0) / 255.0}, "Pedal D (0149)", extra=True),
        PidDef(0x4A, 1, lambda d: {"pedal_e": (d[0] * 100.0) / 255.0}, "Pedal E (014A)", extra=True),
        PidDef(0x4C, 1, lambda d: {"cmd_throttle": (d[0] * 100.0) / 255.0}, "Atuador Borboleta (014C)", extra=True),
        PidDef(0x4D, 2, lambda d: {"time_mil": float((d[0] * 256) + d[1])}, "Tempo c/ MIL (014D)", extra=True, slow=True),
        PidDef(0x4E, 2, lambda d: {"time_clr": float((d[0] * 256) + d[1])}, "Tempo desde Limpeza (014E)", extra=True, slow=True),
        PidDef(0x52, 1, lambda d: {"ethanol": (d[0] * 100.0) / 255.0, "flex_ethanol_pct": (d[0] * 100.0) / 255.0}, "% Etanol (0152)", extra=True, slow=True),
        PidDef(0x5C, 1, lambda d: {"oil_temp": d[0] - 40.0}, "Temp. Óleo (015C)", extra=True, slow=True),
        PidDef(0x5E, 2, lambda d: {"fuel_rate": ((d[0] * 256) + d[1]) / 20.0}, "Consumo (015E)", extra=True),
    )
}

# Rótulo/unidade dos canais dinâmicos do Modo 01 e KWP2000 (fora de CHANNELS) — usados no CSV e na aba "Canais"
DYNAMIC_INFO: Dict[str, Tuple[str, str]] = {
    "stft_b2": ("STFT Banco 2", "%"), "ltft_b2": ("LTFT Banco 2", "%"),
    "fuel_press": ("Pressão Combustível", "kPa"), "maf": ("MAF", "g/s"),
    "run_time": ("Tempo Motor Ligado", "s"), "evap_purge": ("Purga Cânister", "%"),
    "fuel_level": ("Nível Combustível", "%"), "warmups": ("Aquecimentos desde Limpeza", "un"),
    "dist_clr": ("Distância desde Limpeza", "km"), "baro": ("Pressão Barométrica", "kPa"),
    "cat_temp": ("Temp. Catalisador B1S1", "°C"), "ecu_volt": ("Tensão Interna ECU", "V"),
    "obd_pin16_v": ("Tensão Pino 16 OBD (ATRV)", "V"),
    "abs_load": ("Carga Absoluta", "%"), "cmd_lambda": ("Lambda Comandado", "λ"),
    "rel_tps": ("Borboleta Relativa", "%"), "ambient": ("Temp. Ambiente", "°C"),
    "tps_b": ("Borboleta B", "%"), "pedal_d": ("Pedal D", "%"), "pedal_e": ("Pedal E", "%"),
    "cmd_throttle": ("Atuador Borboleta", "%"), "time_mil": ("Tempo c/ MIL", "min"),
    "time_clr": ("Tempo desde Limpeza", "min"), "ethanol": ("% Etanol", "%"),
    "flex_ethanol_pct": ("Teor de Etanol Flex", "%"), "app_pedal_pct": ("Pedal Acelerador (APP)", "%"),
    "oil_temp": ("Temp. Óleo", "°C"), "fuel_rate": ("Consumo", "l/h"),
    "knock_ret_c1": ("Retardo Detonação Cil. 1", "°KW"),
    "knock_ret_c2": ("Retardo Detonação Cil. 2", "°KW"),
    "knock_ret_c3": ("Retardo Detonação Cil. 3", "°KW"),
    "knock_ret_c4": ("Retardo Detonação Cil. 4", "°KW"),
    "knock_v_c1": ("Tensão Sensor Detonação Cil. 1", "V"),
    "knock_v_c2": ("Tensão Sensor Detonação Cil. 2", "V"),
    "knock_v_c3": ("Tensão Sensor Detonação Cil. 3", "V"),
    "knock_v_c4": ("Tensão Sensor Detonação Cil. 4", "V"),
    "tps_track1": ("Pista 1 Borboleta EPC", "%"),
    "tps_track2": ("Pista 2 Borboleta EPC", "%"),
    "app_track2": ("Pista 2 Pedal Acelerador", "%"),
}

# Ordem padrão (a sonda será ajustada automaticamente pelo autodiscovery no handshake)
NORMAL_ORDER = [0x0C, 0x0B, 0x0E, 0x11, 0x14, 0x06, 0x07, 0x05]
FAST_ORDER = [0x0C, 0x0B, 0x0E, 0x11, 0x14]
EXTRA_ORDER = [0x04, 0x0D, 0x0F, 0x03, 0x01, 0x13, 0x1C, 0x21, 0x51]

# Candidatos de Sonda Lambda testados automaticamente na inicialização
LAMBDA_CANDIDATES = [0x14, 0x15, 0x24, 0x34]
STFT_CANDIDATES = [0x06]
LTFT_CANDIDATES = [0x07]


def parse_supported_bitmap(base_pid: int, data: bytes) -> set[int]:
    """Converte a resposta de 0100/0120/0140 (4 bytes) no conjunto de PIDs suportados."""
    value = int.from_bytes(data[:4], "big")
    return {base_pid + i + 1 for i in range(32) if value & (1 << (31 - i))}
