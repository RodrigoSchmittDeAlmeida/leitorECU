"""Testes unitários para o módulo VAG KWP2000 (obd_app.vag)."""
import pytest
from obd_app.vag import decode_block, decode_cell, extract_block


def test_vag_formula_01_rpm():
    """Fórmula 0x01: 0.2 * A * B (RPM)."""
    # Ex: A=10, B=20 -> 0.2 * 10 * 20 = 40.0 rpm
    val, unit = decode_cell(0x01, 10, 20)
    assert val == 40.0
    assert unit == "rpm"


def test_vag_formula_05_temp():
    """Fórmula 0x05: 0.1 * A * (B - 100) (°C)."""
    # Ex: A=10, B=190 -> 0.1 * 10 * 90 = 90.0 °C
    val, unit = decode_cell(0x05, 10, 190)
    assert val == 90.0
    assert unit == "°C"


def test_vag_formula_06_lambda():
    """Fórmula 0x06: 0.001 * A * B (V)."""
    # Ex: A=1, B=450 -> 0.450 V
    val, unit = decode_cell(0x06, 1, 194)
    # 0.001 * 1 * 194 = 0.194 V
    assert pytest.approx(val, abs=1e-3) == 0.194
    assert unit == "V"


def test_vag_formula_14_trim():
    """Fórmula 0x14: A * (B - 128) / 128 (%) (STFT/LTFT)."""
    val, unit = decode_cell(0x14, 1, 128)
    assert val == 0.0
    assert unit == "%"


def test_vag_formula_1b_advance():
    """Fórmula 0x1B: 0.01 * A * (B - 128) (Avanço na Bosch ME7.5.30)."""
    # Ex: A=100, B=140 -> 0.01 * 100 * 12 = 12.0°
    val, unit = decode_cell(0x1B, 100, 140)
    assert val == 12.0
    assert unit == "°"


def test_extract_block():
    """Testa extração de bloco '61 GG' de uma resposta ELM327."""
    class DummyResp:
        ok = True
        def data_lines(self):
            return ["61 03 01 0D 48 12 01 20 03 01 80 1B 01 A0"]

    block = extract_block(DummyResp(), 3)
    assert block is not None
    assert len(block) >= 12

