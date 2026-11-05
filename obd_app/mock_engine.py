"""Motor simulado (Modo Demo) que responde aos comandos como ELM327 + ECU ME7.5.30.

Ciclo de 24 s: marcha lenta -> aceleração -> cruzeiro -> desaceleração (cut-off) -> lenta.
Em ciclos ímpares é injetada uma FALHA de cut-off (sonda rica + avanço negativo)
para testar o detector de eventos.
"""
from __future__ import annotations

import math
import random
import time

from .pids import PIDS

CYCLE = 24.0
SUPPORTED = {0x01, 0x03, 0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x11, 0x13, 0x14, 0x1C}


def _clamp(v, lo, hi):
    return max(lo, min(hi, v))


class MockEngine:
    def __init__(self):
        self.t0 = time.monotonic()
        self.protocol_ready = False
        self.dtcs_cleared = False

    # ------------------------------------------------------------------ estado
    def state(self) -> dict:
        t = time.monotonic() - self.t0
        cyc = int(t // CYCLE)
        ph = t % CYCLE
        fault = cyc % 2 == 1
        osc = math.sin(2 * math.pi * 1.1 * t)  # oscilação da sonda em malha fechada

        if ph < 6:  # marcha lenta
            rpm = 850 + 25 * math.sin(t * 3)
            tps, mp, adv = 0.0, 32 + 2 * math.sin(t), 10 + 2 * math.sin(t * 2.3)
            lam = 0.45 + 0.38 * osc
        elif ph < 9:  # aceleração
            k = (ph - 6) / 3
            rpm = 850 + (4200 - 850) * k
            tps, mp, adv = 15 + 45 * k, 55 + 35 * k, 18 + 8 * k
            lam = 0.82 + 0.03 * osc  # enriquecimento
        elif ph < 12:  # cruzeiro alto
            rpm = 4200 + 60 * math.sin(t * 4)
            tps, mp, adv = 35.0, 62.0, 30 + math.sin(t)
            lam = 0.45 + 0.4 * osc
        elif ph < 16:  # desaceleração (borboleta fechada)
            k = ph - 12
            rpm = 1000 + 3200 * math.exp(-k * 1.1)
            tps, mp = 0.0, 20 + 3 * k
            if fault:
                lam = 0.82 + 0.03 * osc
                adv = 4 - 4 * k  # chega a -12°
            else:
                lam = 0.06 if rpm > 1250 else 0.45 + 0.38 * osc  # cut-off -> sonda pobre até a reentrada
                adv = 6 - k
        else:  # retorno à lenta (dashpot)
            k = ph - 16
            rpm = 850 + 150 * math.exp(-k)
            tps, mp, adv = 0.0, 33.0, 10 + 2 * math.sin(t * 2.3)
            lam = 0.45 + 0.38 * osc

        ect = _clamp(70 + t * 0.4, 70, 92)
        stft = 6 * -osc + (3 if fault else 0)
        ltft = 12.5 if fault else 3.1
        load = _clamp(mp * 1.1, 0, 100)
        speed = _clamp((rpm - 800) / 45, 0, 140)
        return dict(rpm=rpm, tps=tps, map=mp, adv=adv, lam=_clamp(lam, 0.02, 1.0), ect=ect,
                    stft=stft, ltft=ltft, load=load, speed=speed, iat=35.0)

    # ---------------------------------------------------------------- respostas
    def respond(self, cmd: str, kline: float) -> tuple[str, float]:
        if cmd.startswith("AT"):
            return self._at(cmd)
        if not self.protocol_ready:
            self.protocol_ready = True
            return "SEARCHING...\rBUS INIT: ...OK\r" + self._obd(cmd), 2.5
        if random.random() < 0.01:
            return "NO DATA", kline * 2
        return self._obd(cmd), kline * random.uniform(0.85, 1.25)

    def _at(self, cmd: str) -> tuple[str, float]:
        if cmd == "ATZ":
            self.protocol_ready = False
            return "\r\rELM327 v1.5", 0.8
        if cmd == "ATI":
            return "ELM327 v1.5", 0.01
        if cmd == "ATRV":
            return f"{13.9 + random.uniform(-0.1, 0.1):.1f}V", 0.02
        if cmd == "ATDP":
            return "ISO 14230-4 (KWP FAST)", 0.01
        return "OK", 0.01

    def _obd(self, cmd: str) -> str:
        cmd = cmd[:4]
        if cmd == "03":
            if self.dtcs_cleared:
                return "43000000000000"
            return "43013303000000"  # P0133, P0300
        if cmd == "04":
            self.dtcs_cleared = True
            return "44"
        if len(cmd) != 4 or not cmd.startswith("01"):
            return "?"
        try:
            pid = int(cmd[2:], 16)
        except ValueError:
            return "?"
        if pid in (0x00, 0x20, 0x40):
            bits = 0
            for p in SUPPORTED:
                if pid < p <= pid + 32:
                    bits |= 1 << (31 - (p - pid - 1))
            return f"41{pid:02X}{bits:08X}" if pid == 0 else "NO DATA"
        s = self.state()
        if pid == 0x01:
            n = 0 if self.dtcs_cleared else 2
            return f"4101{(0x80 if n else 0) | n:02X}076500"
        enc = {
            0x0C: lambda: f"{int(s['rpm'] * 4):04X}",
            0x0B: lambda: f"{int(s['map']):02X}",
            0x0E: lambda: f"{int(_clamp((s['adv'] + 64) * 2, 0, 255)):02X}",
            0x11: lambda: f"{int(s['tps'] * 255 / 100):02X}",
            0x14: lambda: f"{int(s['lam'] * 200):02X}{int(_clamp(128 + s['stft'] * 1.28, 0, 254)):02X}",
            0x06: lambda: f"{int(_clamp(128 + s['stft'] * 1.28, 0, 255)):02X}",
            0x07: lambda: f"{int(_clamp(128 + s['ltft'] * 1.28, 0, 255)):02X}",
            0x05: lambda: f"{int(s['ect'] + 40):02X}",
            0x04: lambda: f"{int(s['load'] * 255 / 100):02X}",
            0x0D: lambda: f"{int(s['speed']):02X}",
            0x0F: lambda: f"{int(s['iat'] + 40):02X}",
        }
        if pid not in enc or pid not in PIDS:
            return "NO DATA"
        return f"41{pid:02X}{enc[pid]()}"
