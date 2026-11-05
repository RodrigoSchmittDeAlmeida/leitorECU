"""Motor simulado (Modo Demo) que responde aos comandos como ELM327 + ECU ME7.5.30 ou Ford Ka+ 2016 SEL HS-CAN.

Suporta:
- Ciclo de motor (marcha lenta, aceleração, cruzeiro, desaceleração com cut-off)
- Protocolo VAG KWP2000 (endereço 01, blocos 003, 004, 005, 020, 031, 032, 033)
- Protocolo Ford HS-CAN 500k (PCM 7E0, BCM 726 conforto, ABS 760, IPC 720, PSCM 730, RCM 737)
- Modo 22 Ford UDS (DIDs de portas, faróis, limpadores, velocidades das 4 rodas, CHT, pedal APP, PWM ventoinha, etc.)
"""
from __future__ import annotations

import math
import random
import time

from .pids import PIDS

CYCLE = 24.0
SUPPORTED = {0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x13, 0x14, 0x15, 0x1C, 0x20, 0x2F, 0x33, 0x3C, 0x40, 0x42, 0x44, 0x5C}


def _clamp(v, lo, hi):
    return max(lo, min(hi, v))


class MockEngine:
    def __init__(self):
        self.t0 = time.monotonic()
        self.protocol_ready = False
        self.dtcs_cleared = False
        self.header = "7E0"
        self.protocol = "6"  # ISO 15765-4 (CAN 11/500) por padrão no mock
        self.vag_mode = False

    # ------------------------------------------------------------------ estado
    def state(self) -> dict:
        t = time.monotonic() - self.t0
        cyc = int(t // CYCLE)
        ph = t % CYCLE
        fault = cyc % 2 == 1
        osc = math.sin(2 * math.pi * 1.1 * t)

        if ph < 6:  # marcha lenta
            rpm = 850 + 25 * math.sin(t * 3)
            tps, mp, adv = 0.0, 32 + 2 * math.sin(t), 10 + 2 * math.sin(t * 2.3)
            lam = 0.45 + 0.38 * osc
            lam2 = 0.65 + 0.02 * math.sin(t * 0.4)
            fuel_sys = 2  # Closed Loop
        elif ph < 9:  # aceleração
            k = (ph - 6) / 3
            rpm = 850 + (4200 - 850) * k
            tps, mp, adv = 15 + 45 * k, 55 + 35 * k, 18 + 8 * k
            lam = 0.82 + 0.03 * osc
            lam2 = 0.76 + 0.04 * k
            fuel_sys = 4 if tps > 50 else 2  # Open Loop WOT
        elif ph < 12:  # cruzeiro alto
            rpm = 4200 + 60 * math.sin(t * 4)
            tps, mp, adv = 35.0, 62.0, 30 + math.sin(t)
            lam = 0.45 + 0.4 * osc
            lam2 = 0.68 + 0.02 * math.sin(t * 0.3)
            fuel_sys = 2  # Closed Loop
        elif ph < 16:  # desaceleração
            k = ph - 12
            rpm = 1000 + 3200 * math.exp(-k * 1.1)
            tps, mp = 0.0, 20 + 3 * k
            if fault:
                lam = 0.82 + 0.03 * osc
                lam2 = 0.45 + 0.35 * osc  # catalisador ineficiente simulado: oscila com a Sonda 1!
                adv = 4 - 4 * k
                fuel_sys = 2
            else:
                lam = 0.06 if rpm > 1250 else 0.45 + 0.38 * osc
                lam2 = 0.08 if rpm > 1250 else 0.64 + 0.02 * math.sin(t * 0.5)
                adv = 6 - k
                fuel_sys = 1 if rpm > 1250 else 2  # Open Loop desaceleração
        else:  # dashpot
            k = ph - 16
            rpm = 850 + 150 * math.exp(-k)
            tps, mp, adv = 0.0, 33.0, 10 + 2 * math.sin(t * 2.3)
            lam = 0.45 + 0.38 * osc
            lam2 = 0.65 + 0.02 * math.sin(t * 0.4)
            fuel_sys = 2

        ect = _clamp(70 + t * 0.4, 70, 92)
        stft = 6 * -osc + (3 if fault else 0)
        ltft = 12.5 if fault else 3.1
        load = _clamp(mp * 1.1, 0, 100)
        speed = _clamp((rpm - 800) / 45, 0, 140)
        cat_temp = _clamp(480.0 + (rpm / 4200.0) * 190.0 + 10.0 * math.sin(t * 0.1), 380.0, 720.0)
        bat = 13.9 + 0.1 * math.sin(t * 0.5)
        return dict(rpm=rpm, tps=tps, map=mp, adv=adv, lam=_clamp(lam, 0.02, 1.0),
                    lam2=_clamp(lam2, 0.02, 1.0), ect=ect, stft=stft, ltft=ltft,
                    load=load, speed=speed, iat=32.0, t=t, ph=ph, fuel_sys=fuel_sys,
                    cat_temp=cat_temp, bat=bat, baro=98.0)

    # ---------------------------------------------------------------- respostas
    def respond(self, cmd: str, kline: float) -> tuple[str, float]:
        cmd_clean = cmd.strip().upper()
        if cmd_clean.startswith("AT"):
            return self._at(cmd_clean)
        if not self.protocol_ready:
            self.protocol_ready = True
            return "SEARCHING...\rBUS INIT: ...OK\r" + self._obd(cmd_clean), 0.1
        if random.random() < 0.005:
            return "NO DATA", kline
        return self._obd(cmd_clean), 0.02

    def _at(self, cmd: str) -> tuple[str, float]:
        if cmd == "ATZ":
            self.protocol_ready = False
            return "\r\rELM327 v1.5", 0.05
        if cmd == "ATI":
            return "ELM327 v1.5", 0.01
        if cmd == "ATRV":
            return f"{13.9 + random.uniform(-0.1, 0.1):.1f}V", 0.01
        if cmd == "ATDP":
            if self.protocol == "6":
                return "ISO 15765-4 (CAN 11/500)", 0.01
            return "ISO 14230-4 (KWP FAST)", 0.01
        if cmd.startswith("ATSH"):
            self.header = cmd[4:].strip()
            return "OK", 0.01
        if cmd.startswith("ATSP"):
            self.protocol = cmd[4:].strip()
            return "OK", 0.01
        if cmd == "ATIIA01":
            self.vag_mode = True
            return "OK", 0.01
        return "OK", 0.01

    def _obd(self, cmd: str) -> str:
        s = self.state()

        # VAG KWP2000
        if cmd == "1089":
            return "5089"
        if cmd == "1A9B":
            return "5A9B303332393036303332414A204D45372E352E3330"  # 032906032AJ ME7.5.30
        if cmd == "1800FF00":
            return "5800000000" if self.dtcs_cleared else "580201330300"
        if cmd == "14FF00":
            self.dtcs_cleared = True
            return "54"

        # VAG Modo 21 (Blocos de Medição)
        if cmd.startswith("21") and len(cmd) == 4 and self.header in ("8110F1", "01", ""):
            try:
                g = int(cmd[2:], 16)
            except ValueError:
                g = 0
            if g == 0x03:  # Bloco 003: RPM, MAP, TPS, Avanço
                rpm_w = int(s["rpm"] / 0.2)
                map_b = int(s["map"] / 0.04)
                tps_b = int(s["tps"] / 0.002)
                adv_b = int(s["adv"] / 0.01 + 128)
                return f"610301{rpm_w >> 8:02X}{rpm_w & 0xFF:02X}1201{map_b & 0xFF:02X}0301{tps_b & 0xFF:02X}1B01{adv_b & 0xFF:02X}"
            if g == 0x21:  # Bloco 033: STFT %, Tensão Sonda V
                trim_b = int(s["stft"] * 128.0 / 100.0 + 128)
                lam_w = int(s["lam"] * 1000.0)
                return f"61211401{trim_b & 0xFF:02X}06{lam_w >> 8:02X}{lam_w & 0xFF:02X}010000010000"
            if g == 0x20:  # Bloco 032: LTFT
                ltft_b = int(s["ltft"] * 128.0 / 100.0 + 128)
                return f"61201401{ltft_b & 0xFF:02X}1401{ltft_b & 0xFF:02X}010000010000"
            if g == 0x04:  # Bloco 004: Bateria, ECT, IAT
                return "610415037C05016E05015A010000"
            if g == 0x05:  # Bloco 005: Carga, Velocidade
                return f"61050201{int(s['load'] * 50):02X}0701{int(s['speed'] * 100):02X}010000010000"

        # DTCs padrão (Modo 03 / 04)
        if cmd.startswith("03"):
            if self.dtcs_cleared:
                return "43000000000000"
            if self.header == "7E0":
                return "43013303000000"  # P0133, P0300
            elif self.header == "726":
                return "43B0A200000000"  # B10A2 (Farol de neblina)
            elif self.header == "760":
                return "43000000000000"  # ABS sem falhas
            return "43000000000000"
        if cmd.startswith("04"):
            self.dtcs_cleared = True
            return "44"

        # Ford Modo 22 (UDS ReadDataByIdentifier)
        if cmd.startswith("22"):
            did = cmd[2:6]
            # BCM 726 (Conforto & Carroceria)
            if self.header == "726":
                if did == "404C":  # Portas e Travas
                    door_open = 0x01 if (s["ph"] > 21 and s["speed"] < 1) else 0x00
                    return f"62404C{door_open:02X}01"
                if did == "4050":  # Iluminação
                    return "6240500300"
                if did == "4060":  # Acessórios
                    return "6240600020"
                if did == "4001":  # Tensão BCM
                    return "624001056E"

            # ABS 760 (Freios ABS / ESC)
            if self.header == "760":
                if did == "2B00":  # Velocidade 4 rodas
                    spd = s["speed"]
                    fl = int(spd * 100)
                    fr = int((spd + 0.1) * 100)
                    rl = int(spd * 100)
                    rr = int((spd + 0.1) * 100)
                    return f"622B00{fl:04X}{fr:04X}{rl:04X}{rr:04X}"
                if did == "2B01":  # Pressão freio & SAS
                    press = int((35.0 if s["ph"] >= 12 and s["ph"] < 14 else 0.0) * 10)
                    pedal = 0x01 if press > 0 else 0x00
                    return f"622B01{press:04X}{pedal:02X}0000"

            # PCM 7E0 (Motor Sigma 1.5 16V Flex DOHC - sem VVT)
            if self.header == "7E0":
                if did == "1624":  # CHT Temp
                    raw_cht = int((s["ect"] + 4.0 + 40.0) * 10)
                    return f"621624{raw_cht:04X}"
                if did == "032B":  # Posição do pedal APP
                    app_b = int(s["tps"] * 2.55)
                    return f"62032B{app_b:02X}"
                if did == "0332":  # Eletroventilador
                    fan_pct = int(65 if s["ect"] > 88 else 0)
                    return f"620332{int(fan_pct * 2.55):02X}"
                if did == "1125":  # Tempo de injeção
                    pw = int((2.8 + (s["load"] / 100.0) * 8.5) * 1000)
                    return f"621125{pw:04X}"
                if did == "1101":  # Ar condicionado
                    return "62110104BE01"
                if did == "1608":  # Etanol flex virtual
                    return "62160855"
                if did == "1627":  # Temp Catalisador
                    return f"621627{int((s['cat_temp'] + 40.0) * 10):04X}"
                if did == "0320":  # Pressão barométrica
                    return f"620320{int(s['baro']):02X}"

            # IPC 720 (Painel de Instrumentos)
            if self.header == "720":
                if did == "DD01":  # Odômetro (84.321 km)
                    return "62DD01014961"
                if did == "2416":  # Combustível e Temp Ext
                    return "622416AD4200"

            # PSCM 730 (Direção Elétrica EPAS)
            if self.header == "730":
                if did == "3300":
                    ang = int(random.uniform(-5, 5) * 10) & 0xFFFF
                    trq = int(random.uniform(0.5, 2.0) * 100) & 0xFFFF
                    curr = int(random.uniform(2.0, 5.0) / 0.5)
                    return f"623300{ang:04X}{trq:04X}{curr:02X}"

            return "62" + did + "0000"

        # Modo 01 OBD2 Padrão
        cmd4 = cmd[:4]
        if not cmd4.startswith("01"):
            return "?"
        try:
            pid = int(cmd4[2:], 16)
        except ValueError:
            return "?"
        if pid in (0x00, 0x20, 0x40):
            bits = 0
            for p in SUPPORTED:
                if pid < p <= pid + 32:
                    bits |= 1 << (31 - (p - pid - 1))
            return f"41{pid:02X}{bits:08X}"
        if pid == 0x01:
            n = 0 if self.dtcs_cleared else 2
            return f"4101{(0x80 if n else 0) | n:02X}076500"
        enc = {
            0x0C: lambda: f"{int(s['rpm'] * 4):04X}",
            0x0B: lambda: f"{int(s['map']):02X}",
            0x0E: lambda: f"{int(_clamp((s['adv'] + 64) * 2, 0, 255)):02X}",
            0x11: lambda: f"{int(s['tps'] * 255 / 100):02X}",
            0x14: lambda: f"{int(s['lam'] * 200):02X}{int(_clamp(128 + s['stft'] * 1.28, 0, 254)):02X}",
            0x15: lambda: f"{int(s['lam2'] * 200):02X}{int(_clamp(128 + s['stft'] * 0.2, 0, 254)):02X}",
            0x03: lambda: f"{s['fuel_sys']:02X}00",
            0x06: lambda: f"{int(_clamp(128 + s['stft'] * 1.28, 0, 255)):02X}",
            0x07: lambda: f"{int(_clamp(128 + s['ltft'] * 1.28, 0, 255)):02X}",
            0x05: lambda: f"{int(s['ect'] + 40):02X}",
            0x04: lambda: f"{int(s['load'] * 255 / 100):02X}",
            0x0D: lambda: f"{int(s['speed']):02X}",
            0x0F: lambda: f"{int(s['iat'] + 40):02X}",
            0x2F: lambda: "AD",  # 68% combustível
            0x33: lambda: f"{int(s['baro']):02X}",  # kPa
            0x3C: lambda: f"{int((s['cat_temp'] + 40.0) * 10):04X}",  # Temp Catalisador
            0x42: lambda: f"{int(s['bat'] * 1000):04X}",  # Tensão PCM
            0x44: lambda: f"{int(s['lam'] * 32768):04X}",
            0x5C: lambda: f"{int(s['ect'] + 35):02X}",
            0x5E: lambda: f"{int((s['load'] / 100.0) * 8.0 * 20):04X}",  # Fuel Rate
        }
        if pid not in enc or pid not in SUPPORTED:
            return "NO DATA"
        return f"41{pid:02X}{enc[pid]()}"
