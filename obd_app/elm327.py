"""Protocolo ELM327: envio de comandos, leitura até o prompt '>', classificação de erros e parsing."""
from __future__ import annotations

import re
import time
from dataclasses import dataclass, field
from typing import Callable, List, Optional

from .transports import Transport, TransportError

_HEX_LINE = re.compile(r"^(?:[0-9A-Fa-f]{1,2}:)?[0-9A-Fa-f ]+$")

# Sequência de handshake para Bosch ME7.5.30 (K-Line, KWP2000 VAG / ISO 9141-2)
INIT_SEQUENCE = [
    ("ATZ", 5.0),    # Reset
    ("ATE0", 2.0),   # Echo off
    ("ATL0", 2.0),   # Linefeeds off
    ("ATS0", 2.0),   # Spaces off (o parser também trata espaços)
    ("ATH0", 2.0),   # Headers off
    ("ATAL", 2.0),   # Allow Long messages (> 7 bytes, essencial para KWP2000 Mode 21)
    ("ATSP0", 2.0),  # Protocolo 0: Auto-detecção inicial
]


@dataclass
class ElmResponse:
    command: str
    lines: List[str] = field(default_factory=list)
    error: Optional[str] = None  # None | 'NO DATA' | 'STOPPED' | 'UNABLE TO CONNECT' | '?' | 'TIMEOUT' | ...
    raw: str = ""

    @property
    def ok(self) -> bool:
        return self.error is None

    def __contains__(self, item: str) -> bool:
        if not isinstance(item, str):
            return False
        return item in self.raw or any(item in l for l in self.lines)

    def __str__(self) -> str:
        return self.raw

    def data_lines(self) -> List[str]:
        cleaned: List[str] = []
        for l in self.lines:
            s = l.strip()
            if _HEX_LINE.match(s):
                s = re.sub(r"^[0-9A-Fa-f]{1,2}:\s*", "", s)
                cleaned.append(s.replace(" ", "").upper())
        return cleaned


def classify(lines: List[str], prompt: bool) -> Optional[str]:
    joined = " ".join(lines).upper()
    if any(_HEX_LINE.match(l) for l in lines):
        return None
    for token in ("UNABLE TO CONNECT", "BUS INIT: ...ERROR", "BUS INIT:...ERROR", "BUS ERROR",
                  "CAN ERROR", "FB ERROR", "DATA ERROR", "BUFFER FULL", "NO DATA", "STOPPED", "ERROR"):
        if token in joined:
            return "UNABLE TO CONNECT" if "BUS INIT" in token else token
    if "?" in joined:
        return "?"
    if not prompt:
        return "TIMEOUT"
    if joined.strip() in ("", "OK") or "ELM" in joined or joined.endswith("V"):
        return None
    return "INVALID"


def extract_payload(resp: ElmResponse, mode: int, pid: int, nbytes: int) -> Optional[bytes]:
    """Procura '4X PP' (ou '61 PP' no modo 21) na resposta e retorna ``nbytes`` de dados."""
    header = f"{mode + 0x40:02X}{pid:02X}"
    dlines = resp.data_lines()
    for i, s in enumerate(dlines):
        idx = s.find(header)
        while idx != -1 and idx % 2:  # garante alinhamento em byte
            idx = s.find(header, idx + 1)
        if idx == -1:
            continue
        tail = s[idx + 4:]
        # Se a resposta KWP2000 quebrou em múltiplas linhas, concatena as linhas seguintes
        for extra in dlines[i + 1:]:
            if len(tail) >= 2 * nbytes:
                break
            if extra.startswith(header):
                tail += extra[4:]
            else:
                tail += extra
        hexdata = tail[: 2 * nbytes]
        if len(hexdata) == 2 * nbytes:
            return bytes.fromhex(hexdata)
    return None


class ELM327:
    def __init__(self, transport: Transport, log: Callable[[str], None] | None = None,
                 timeout: float = 2.0):
        self.t = transport
        self.timeout = timeout
        self.log = log or (lambda m: None)
        self.raw_log = False
        self.version = ""
        self.fast_reply = False  # sufixo '1' => ELM retorna após a 1ª resposta (mais rápido)

    @property
    def transport(self) -> Transport:
        return self.t

    def command(self, cmd: str, timeout: float | None = None) -> ElmResponse:
        self.t.flush_input()
        self.t.write((cmd + "\r").encode("ascii"))
        raw, prompt = self.t.read_until_prompt(timeout or self.timeout)
        text = raw.decode("ascii", "ignore").replace(">", "").replace("\x00", "")
        lines = [l.strip() for l in re.split(r"[\r\n]+", text) if l.strip()]
        # Remove eco do próprio comando e mensagens informativas do Fast Init
        cleaned: List[str] = []
        cmd_norm = cmd.replace(" ", "").upper()
        for l in lines:
            u = l.replace(" ", "").upper()
            if u == cmd_norm:
                continue
            if u.startswith("SEARCHING"):
                continue
            if "BUSINIT" in u and "ERROR" not in u:
                continue
            cleaned.append(l)
        resp = ElmResponse(cmd, cleaned, classify(cleaned, prompt), text)
        if self.raw_log:
            self.log(f"TX {cmd} | RX {' / '.join(lines) or '-'}" + (f"  [{resp.error}]" if resp.error else ""))
        return resp

    def initialize_adapter(self, stop: Callable[[], bool] = lambda: False) -> None:
        """Executa apenas os comandos AT básicos de configuração do adaptador ELM327."""
        for cmd, tmo in INIT_SEQUENCE:
            if stop():
                raise TransportError("Cancelado")
            r = self.command(cmd, tmo)
            self.log(f"> {cmd:<6} -> {' / '.join(r.lines) or '(vazio)'}")
            if cmd == "ATZ":
                self.version = next((l for l in r.lines if "ELM" in l.upper()), "")
                time.sleep(0.5)
                self.t.flush_input()
                self.command("ATE0", 2.0)  # garante Echo Off caso ATZ tenha atrasado o prompt '>'
            elif r.error == "TIMEOUT":
                raise TransportError(f"Adaptador não respondeu a {cmd}")

    def initialize(self, stop: Callable[[], bool] = lambda: False) -> ElmResponse:
        self.initialize_adapter(stop=stop)
        # 0100 inicializa o barramento (Fast Init / Slow Init pode levar alguns segundos)
        r = self.command("0100", 12.0)
        self.log(f"> 0100   -> {' / '.join(r.lines) or '(vazio)'}" + (f"  [{r.error}]" if r.error else ""))
        return r

    def query_pid(self, cmd: str) -> ElmResponse:
        return self.command(cmd + ("1" if self.fast_reply else ""))

    def battery_voltage(self) -> Optional[float]:
        r = self.command("ATRV", 1.5)
        for l in r.lines:
            m = re.search(r"(\d+(?:\.\d+)?)\s*V", l.upper())
            if m:
                return float(m.group(1))
        return None
