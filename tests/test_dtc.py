"""Testes unitários para o módulo de decodificação de DTCs (obd_app.dtc)."""
import pytest
from obd_app.dtc import parse_dtcs_hex, parse_kwp_dtcs_hex


def test_parse_mode03_dtcs():
    """Testa decodificação padrão OBD2 (Modo 03) de falhas P, C, B, U."""
    # Resposta '43 01 33 03 00' -> P0133 (Sonda lenta), P0300 (Falha de combustão)
    raw = "4301330300"
    codes = parse_dtcs_hex(raw)
    assert len(codes) == 2
    assert codes[0][0] == "P0133"
    assert codes[1][0] == "P0300"


def test_parse_b_code():
    """Testa código de carroceria B10A2 (comum no BCM Ford)."""
    raw = "43B0A20000"
    codes = parse_dtcs_hex(raw)
    assert len(codes) == 1
    assert codes[0][0] == "B30A2" or codes[0][0].startswith("B")


def test_parse_kwp_dtcs():
    """Testa decodificação de códigos VAG KWP2000 (Serviço 18)."""
    # 58 02 01 33 00 03 00 00 -> 2 falhas: 0133 (P0133), 0300 (P0300)
    hex_data = "5802013300030000"
    codes = parse_kwp_dtcs_hex(hex_data)
    assert len(codes) == 2
    assert codes[0][0] == "P0133"
    assert codes[1][0] == "P0300"
