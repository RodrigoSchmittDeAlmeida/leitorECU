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
BASE_SUPPORTED = {
    0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
    0x11, 0x13, 0x14, 0x15, 0x1C, 0x20, 0x2F, 0x33, 0x3C, 0x40, 0x42, 0x44, 0x5C, 0x5E
}
TURBO_EXTRA_PIDS = {0x23, 0x24, 0x70, 0x77}
SUPPORTED = BASE_SUPPORTED  # Compatibilidade retroativa


def _clamp(v, lo, hi):
    return max(lo, min(hi, v))


class MockEngine:
    def __init__(self, turbo_mode: bool = False, profile: str = "gol_me75"):
        self.t0 = time.monotonic()
        self.protocol_ready = False
        self.dtcs_cleared = False
        self.header = "7E0"
        self.protocol = "6"  # ISO 15765-4 (CAN 11/500) por padrão no mock
        self.vag_mode = False
        self.turbo_mode = turbo_mode or (profile in ("turbo", "turbo_tsi"))
        self.profile = "turbo_tsi" if self.turbo_mode else profile

    def supported_pids(self) -> set[int]:
        """Conjunto dinâmico de PIDs suportados conforme o perfil veicular ativo."""
        pids = set(BASE_SUPPORTED)
        if self.turbo_mode:
            pids |= TURBO_EXTRA_PIDS | {0x60}
        return pids

    # ------------------------------------------------------------------ estado
    def state(self) -> dict:
        t = time.monotonic() - self.t0
        cyc = int(t // CYCLE)
        ph = t % CYCLE
        fault = cyc % 2 == 1
        osc = math.sin(2 * math.pi * 1.1 * t)

        if not self.turbo_mode:
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
            baro = 98.0
            return dict(rpm=rpm, tps=tps, map=mp, adv=adv, lam=_clamp(lam, 0.02, 1.0),
                        lam2=_clamp(lam2, 0.02, 1.0), ect=ect, stft=stft, ltft=ltft,
                        load=load, speed=speed, iat=32.0, t=t, ph=ph, fuel_sys=fuel_sys,
                        cat_temp=cat_temp, bat=bat, baro=baro, lambda_eq=1.00,
                        boost_bar=(mp - baro) / 100.0, boost_target_bar=0.0,
                        wastegate=0.0, fuel_rail_bar=40.0, cac_temp=32.0, knock_retard=0.0)

        # Perfil Turbo TSI
        if ph < 6:  # marcha lenta turbo
            rpm = 800 + 20 * math.sin(t * 3)
            tps, mp, adv = 0.0, 32 + 2 * math.sin(t), 8 + 2 * math.sin(t * 2.3)
            lam = 0.45 + 0.38 * osc
            lam2 = 0.65
            lambda_eq = 1.00
            fuel_sys = 2
            boost_target = 0.0
            wastegate = 0.0
            fuel_rail_bar = 45.0
            cac_temp = 30.0
            knock_ret = 0.0
        elif ph < 9:  # aceleração com sobrealimentação (até 220 kPa / 1.2 bar boost)
            k = (ph - 6) / 3
            rpm = 1200 + (5800 - 1200) * k
            tps = 20.0 + 80.0 * k
            mp = 80.0 + 140.0 * k  # sobe até 220 kPa
            adv = 14.0 - 4.0 * k
            lam = 0.88 + 0.02 * osc
            lam2 = 0.76
            lambda_eq = 1.00 - 0.18 * k  # desce até 0.82 em WOT
            fuel_sys = 4 if tps > 50 else 2
            boost_target = 1.20
            wastegate = 55.0 + 30.0 * k  # duty da wastegate N75 até 85%
            fuel_rail_bar = 50.0 + 100.0 * k  # injeção direta GDI até 150 bar
            cac_temp = 32.0 + 16.0 * k
            knock_ret = 3.6 * k if k > 0.70 else 0.0  # pico de detonação em plena carga
        elif ph < 12:  # cruzeiro turbo
            rpm = 3200 + 40 * math.sin(t * 4)
            tps, mp, adv = 28.0, 75.0, 26 + math.sin(t)
            lam = 0.45 + 0.4 * osc
            lam2 = 0.68
            lambda_eq = 1.00 + 0.01 * osc
            fuel_sys = 2
            boost_target = 0.0
            wastegate = 15.0
            fuel_rail_bar = 70.0
            cac_temp = 36.0
            knock_ret = 0.0
        elif ph < 16:  # desaceleração / cut-off turbo
            k = ph - 12
            rpm = 1000 + 3000 * math.exp(-k * 1.1)
            tps, mp = 0.0, 20 + 2 * k
            lam = 0.05 if rpm > 1250 else 0.45 + 0.38 * osc
            lam2 = 0.08 if rpm > 1250 else 0.65
            lambda_eq = 1.99 if rpm > 1250 else 1.00
            adv = 8 - k
            fuel_sys = 1 if rpm > 1250 else 2
            boost_target = 0.0
            wastegate = 0.0
            fuel_rail_bar = 40.0
            cac_temp = 34.0
            knock_ret = 0.0
        else:  # dashpot
            k = ph - 16
            rpm = 800 + 150 * math.exp(-k)
            tps, mp, adv = 0.0, 33.0, 9 + 2 * math.sin(t * 2.3)
            lam = 0.45 + 0.38 * osc
            lam2 = 0.65
            lambda_eq = 1.00
            fuel_sys = 2
            boost_target = 0.0
            wastegate = 0.0
            fuel_rail_bar = 45.0
            cac_temp = 32.0
            knock_ret = 0.0

        ect = _clamp(75 + t * 0.4, 75, 96)
        stft = 5 * -osc
        ltft = 2.5
        load = _clamp((mp / 220.0) * 100.0, 0, 100)
        speed = _clamp((rpm - 750) / 40, 0, 190)
        cat_temp = _clamp(520.0 + (rpm / 5500.0) * 260.0, 400.0, 850.0)
        bat = 13.9 + 0.1 * math.sin(t * 0.5)
        baro = 100.0
        boost_bar = (mp - baro) / 100.0

        return dict(rpm=rpm, tps=tps, map=mp, adv=adv, lam=_clamp(lam, 0.02, 1.0),
                    lam2=_clamp(lam2, 0.02, 1.0), ect=ect, stft=stft, ltft=ltft,
                    load=load, speed=speed, iat=32.0, t=t, ph=ph, fuel_sys=fuel_sys,
                    cat_temp=cat_temp, bat=bat, baro=baro, lambda_eq=lambda_eq,
                    boost_bar=boost_bar, boost_target_bar=boost_target,
                    wastegate=wastegate, fuel_rail_bar=fuel_rail_bar,
                    cac_temp=cac_temp, knock_retard=knock_ret)

    # ---------------------------------------------------------------- respostas
    def respond(self, cmd: str, kline: float) -> tuple[str, float]:
        cmd_clean = cmd.strip().upper()
        if cmd_clean.startswith("AT"):
            return self._at(cmd_clean)
        if not self.protocol_ready:
            self.protocol_ready = True
            return "SEARCHING...\rBUS INIT: ...OK\r" + self._obd(cmd_clean), 0.1
        if getattr(self, "enable_random_drops", False) and random.random() < 0.005:
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
            self.header = cmd[4:].strip().replace(" ", "")
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
            if self.turbo_mode:
                txt = "5G0906259 MED17.5 EA888 TSI"
                return "5A9B" + txt.encode("latin1").hex().upper()
            return "5A9B303332393036303332414A204D45372E352E3330"  # 032906032AJ ME7.5.30
        if cmd == "1800FF00":
            return "5800000000" if self.dtcs_cleared else "580201330300"
        if cmd == "14FF00":
            self.dtcs_cleared = True
            return "54"

        # VAG Modo 21 (Blocos de Medição)
        if cmd.startswith("21") and len(cmd) == 4 and (self.vag_mode or self.header in ("8110F1", "01", "") or "8110F1" in self.header):
            try:
                g = int(cmd[2:], 16)
            except ValueError:
                g = 0
            if g in (0x72, 0x73, 0x76) and not self.turbo_mode:
                return "NO DATA"
            if g == 0x02:  # Bloco 002: RPM, Carga %, Tempo Injeção ms, MAP mbar
                rpm_w = int(s["rpm"] / 0.2)
                load_w = int(s["load"] / 0.002)
                inj_ms = 2.4 + (s["load"] / 100.0) * 6.5
                inj_w = int(inj_ms / 0.01)
                map_w = int((s["map"] * 10.0) / 0.04)
                return (
                    f"610201{rpm_w >> 8:02X}{rpm_w & 0xFF:02X}"
                    f"02{load_w >> 8:02X}{load_w & 0xFF:02X}"
                    f"0F{inj_w >> 8:02X}{inj_w & 0xFF:02X}"
                    f"12{map_w >> 8:02X}{map_w & 0xFF:02X}"
                )
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
            if g == 0x20:  # Bloco 032: LTFT Lenta, LTFT Parcial, Fator, Tensão ECU
                ltft_b = int(s["ltft"] * 128.0 / 100.0 + 128)
                bat_w = int(s["bat"] * 1000.0)
                return f"61201401{ltft_b & 0xFF:02X}1401{ltft_b & 0xFF:02X}14018006{bat_w >> 8:02X}{bat_w & 0xFF:02X}"
            if g == 0x04:  # Bloco 004: C1=RPM, C2=Bateria (V), C3=ECT (°C), C4=IAT (°C)
                rpm_w = int(s["rpm"] / 0.2)
                bat_w = int(s["bat"] * 1000.0)
                ect_b = int(s["ect"] * 10.0 / 1.0 + 100)
                iat_b = int(s["iat"] * 10.0 / 1.0 + 100)
                return (
                    f"610401{rpm_w >> 8:02X}{rpm_w & 0xFF:02X}"
                    f"15{bat_w >> 8:02X}{bat_w & 0xFF:02X}"
                    f"0501{ect_b & 0xFF:02X}"
                    f"0501{iat_b & 0xFF:02X}"
                )
            if g == 0x05:  # Bloco 005: RPM, Carga, Velocidade, Estado
                rpm_w = int(s["rpm"] / 0.2)
                return f"610501{rpm_w >> 8:02X}{rpm_w & 0xFF:02X}0201{int(s['load'] * 50):02X}0701{int(s['speed'] * 100):02X}250001"
            if g == 0x14:  # Bloco 020: Retardo detonação Cil 1..4
                if self.turbo_mode and s.get("knock_retard", 0.0) > 0.0:
                    k_ret = s["knock_retard"]
                    # Fórmula 0x22: (b - 128) * 0.01 * a. Com a=10 (0x0A): retardo = (b - 128) * 0.1
                    b1 = 128 + int(k_ret * 10)
                    b2 = 128 + int((k_ret * 0.5) * 10)
                    return f"6114220A{b1:02X}220A{b2:02X}220A80220A80"
                return "6114220180220180220180220180"
            if g == 0x1A:  # Bloco 026: Tensão sensor detonação Cil 1..4 (V)
                return "611A06019006019506018C060192"
            if g == 0x3E:  # Bloco 062: TPS1, TPS2, APP1, APP2
                tps_w = int(s["tps"] / 0.002)
                tps2_w = int((100.0 - s["tps"]) / 0.002)
                return (
                    f"613E02{tps_w >> 8:02X}{tps_w & 0xFF:02X}"
                    f"02{tps2_w >> 8:02X}{tps2_w & 0xFF:02X}"
                    f"02{tps_w >> 8:02X}{tps_w & 0xFF:02X}"
                    f"02{tps_w >> 8:02X}{tps_w & 0xFF:02X}"
                )
            if g == 0x67:  # Bloco 103: Etanol Flex % (em C5)
                return "616700000000000000000000000021011B210100210100100001"
            if g == 0x72:  # Bloco 114: Carga especificada, Carga corrigida, Carga real, N75 Wastegate %
                b_load_spec = _clamp(int(round(s["load"] * 2.0)), 0, 255)
                b_load_corr = _clamp(int(round(s["load"] * 2.0)), 0, 255)
                b_load_act = _clamp(int(round(s["load"] * 2.0)), 0, 255)
                b_wg = _clamp(int(round(s.get("wastegate", 0.0) * 2.0)), 0, 255)
                return (
                    f"6172"
                    f"02FA{b_load_spec:02X}"
                    f"02FA{b_load_corr:02X}"
                    f"02FA{b_load_act:02X}"
                    f"02FA{b_wg:02X}"
                )
            if g == 0x73:  # Bloco 115: RPM, Carga %, Pressão Turbo Especificada mbar, Pressão Turbo Real mbar
                b_rpm = _clamp(int(round(s["rpm"] / 40.0)), 0, 255)
                b_load = _clamp(int(round(s["load"] * 2.0)), 0, 255)
                mbar_spec = (101.325 + s.get("boost_target_bar", 0.0) * 100.0) * 10.0
                mbar_act = s["map"] * 10.0
                b_pspec = _clamp(int(round(mbar_spec / 10.0)), 0, 255)
                b_pact = _clamp(int(round(mbar_act / 10.0)), 0, 255)
                return (
                    f"6173"
                    f"01C8{b_rpm:02X}"
                    f"02FA{b_load:02X}"
                    f"12FA{b_pspec:02X}"
                    f"12FA{b_pact:02X}"
                )
            if g == 0x76:  # Bloco 118: RPM, Temp Ar IAT, N75 %, Pressão Turbo Real mbar
                b_rpm = _clamp(int(round(s["rpm"] / 40.0)), 0, 255)
                b_iat = _clamp(int(round(s["iat"] + 100)), 0, 255)
                b_wg = _clamp(int(round(s.get("wastegate", 0.0) * 2.0)), 0, 255)
                mbar_act = s["map"] * 10.0
                b_pact = _clamp(int(round(mbar_act / 10.0)), 0, 255)
                return (
                    f"6176"
                    f"01C8{b_rpm:02X}"
                    f"050A{b_iat:02X}"
                    f"02FA{b_wg:02X}"
                    f"12FA{b_pact:02X}"
                )
            return "NO DATA"

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

            if did == "F190":  # VIN
                vin = "WVWZZZAUZHP123456" if self.turbo_mode else "9BWZZZ5UZBP123456"
                return f"62F190{vin.encode('ascii').hex().upper()}"
            if did == "F187":  # Part Number
                pn = "5G0906259" if self.turbo_mode else "032906032AJ"
                return f"62F187{pn.encode('ascii').hex().upper()}"

            return "62" + did + "0000"

        # Modo 09 (Vehicle Information)
        if cmd == "0902":
            vin = "WVWZZZAUZHP123456" if self.turbo_mode else "9BWZZZ5UZBP123456"
            return f"490201{vin.encode('ascii').hex().upper()}"

        # Modo 01 OBD2 Padrão
        cmd4 = cmd[:4]
        if not cmd4.startswith("01"):
            return "?"
        try:
            pid = int(cmd4[2:], 16)
        except ValueError:
            return "?"
        active_supported = self.supported_pids()
        if pid in (0x00, 0x20, 0x40, 0x60):
            if pid != 0x00 and pid not in active_supported:
                return "NO DATA"
            bits = 0
            for p in active_supported:
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
            0x13: lambda: "03",  # Sensores presentes B1S1 e B1S2
            0x14: lambda: f"{int(s['lam'] * 200):02X}{int(_clamp(128 + s['stft'] * 1.28, 0, 254)):02X}",
            0x15: lambda: f"{int(s['lam2'] * 200):02X}{int(_clamp(128 + s['stft'] * 0.2, 0, 254)):02X}",
            0x1C: lambda: "01",  # Padrão OBD-II (CARB/EPA)
            0x03: lambda: f"{s['fuel_sys']:02X}00",
            0x06: lambda: f"{int(_clamp(128 + s['stft'] * 1.28, 0, 255)):02X}",
            0x07: lambda: f"{int(_clamp(128 + s['ltft'] * 1.28, 0, 255)):02X}",
            0x05: lambda: f"{int(s['ect'] + 40):02X}",
            0x04: lambda: f"{int(s['load'] * 255 / 100):02X}",
            0x0D: lambda: f"{int(s['speed']):02X}",
            0x0F: lambda: f"{int(s['iat'] + 40):02X}",
            0x23: lambda: f"{int(s.get('fuel_rail_bar', 40.0) * 100.0 / 10.0):04X}",  # Pressão Rail Combustível GDI (10 kPa/bit)
            0x24: lambda: f"{int(s.get('lambda_eq', 1.0) * 32768):04X}{int(s['lam'] * 8192):04X}",  # Sonda Wideband Eq + V
            0x2F: lambda: "AD",  # 68% combustível
            0x33: lambda: f"{int(s['baro']):02X}",  # kPa
            0x3C: lambda: f"{int((s['cat_temp'] + 40.0) * 10):04X}",  # Temp Catalisador
            0x42: lambda: f"{int(s['bat'] * 1000):04X}",  # Tensão PCM
            0x44: lambda: f"{int(s.get('lambda_eq', 1.0) * 32768):04X}",
            0x5C: lambda: f"{int(s['ect'] + 35):02X}",
            0x5E: lambda: f"{int((s['load'] / 100.0) * 8.0 * 20):04X}",  # Fuel Rate
            0x70: lambda: (
                f"03"
                f"{_clamp(int(round((101.325 + s.get('boost_target_bar', 0.0) * 100.0) / 0.03125)), 0, 65535):04X}"
                f"{_clamp(int(round(s['map'] / 0.03125)), 0, 65535):04X}"
                f"00000000"
                f"{_clamp(int(round(s.get('wastegate', 0.0) * 255.0 / 100.0)), 0, 255):02X}"
            ),
            0x77: lambda: f"{int(s.get('cac_temp', 35.0) + 40):02X}{int(s.get('cac_temp', 35.0) + 40):02X}",  # CAC Temp
        }
        if pid not in enc or pid not in active_supported:
            return "NO DATA"
        return f"41{pid:02X}{enc[pid]()}"
