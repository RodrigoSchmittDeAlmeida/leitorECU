"""Testes unitários para fórmulas e PIDs Modo 01 (obd_app.pids)."""
import pytest
from obd_app.pids import (CHANNELS, PIDS, _dec_lambda_nb, _dec_lambda_nb2,
                          _trim, parse_supported_bitmap)


def test_trim_formula():
    """Fórmula de combustível: (A - 128) * 100 / 128."""
    assert _trim(128) == 0.0
    assert pytest.approx(_trim(255), rel=1e-2) == 99.21875
    assert pytest.approx(_trim(0), rel=1e-2) == -100.0


def test_lambda_sensors_independence():
    """Garante que a Sonda 1 (B1S1) e a Sonda 2 (B1S2) são estritamente independentes e não se sobrescrevem."""
    d1 = bytes([100, 128])  # 0.500 V, trim 0.0%
    d2 = bytes([140, 128])  # 0.700 V, trim 0.0%

    res1 = _dec_lambda_nb(d1)
    res2 = _dec_lambda_nb2(d2)

    assert "lambda_v" in res1
    assert "lambda2_v" not in res1
    assert res1["lambda_v"] == 0.5

    assert "lambda2_v" in res2
    assert "lambda_v" not in res2
    assert res2["lambda2_v"] == 0.7


def test_channels_14_cards():
    """Verifica se há exatamente 14 cards configurados no painel superior (2 linhas de 7)."""
    cards = [k for k, ch in CHANNELS.items() if getattr(ch, "card", True)]
    assert len(cards) == 14
    assert cards == [
        "rpm", "map", "advance", "tps", "load", "speed", "battery",
        "lambda_v", "lambda2_v", "lambda_trim", "stft", "ltft", "ect", "iat"
    ]


def test_bitmap_parser():
    """Testa parser do bitmap de PIDs suportados (0100)."""
    # Exemplo: bit 1 (0x01) e bit 3 (0x03) ativos
    payload = bytes([0b10100000, 0x00, 0x00, 0x00])
    supported = parse_supported_bitmap(0x00, payload)
    assert 0x01 in supported
    assert 0x03 in supported
    assert 0x02 not in supported


def test_mode01_pid_decoders():
    """Testa decodificadores dos PIDs críticos."""
    # RPM: ((A*256)+B)/4
    d_rpm = bytes([0x0D, 0x48])  # 3400 / 4 = 850 rpm
    assert PIDS[0x0C].decode(d_rpm)["rpm"] == 850.0

    # MAP: A kPa
    assert PIDS[0x0B].decode(bytes([35]))["map"] == 35.0

    # ECT: A - 40 °C
    assert PIDS[0x05].decode(bytes([130]))["ect"] == 90.0

    # TPS: A * 100 / 255 %
    assert pytest.approx(PIDS[0x11].decode(bytes([128]))["tps"], abs=0.5) == 50.19
