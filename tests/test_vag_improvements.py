"""Testes para as melhorias críticas do protocolo VAG KWP2000 e decodificadores."""
import pytest
from obd_app.pids import _dec_vag_group02, _dec_vag_group05, decode_vag_cell
from obd_app.vag import decode_cell, extract_block


class MockElmMultiFrameResp:
    def __init__(self, lines):
        self.lines = lines
        self.ok = True

    def data_lines(self):
        import re
        out = []
        for l in self.lines:
            s = l.strip()
            s = re.sub(r"^[0-9A-Fa-f]{1,2}:\s*", "", s)
            if re.match(r"^[0-9A-Fa-f ]+$", s):
                out.append(s.replace(" ", "").upper())
        return out


def test_extract_block_multiframe_repeated_header():
    """Garante que respostas KWP2000 multi-frame com 61 GG repetido não causam deslocamento de células."""
    # Bloco 004:
    # Frame 1: 61 04 + Célula 1 (RPM: 01 0A 14 = 40 rpm) + Célula 2 (Bateria: 06 36 B0 = 14.0 V)
    # Frame 2: 61 04 + Célula 3 (ECT: 05 0A C8 = 100 °C) + Célula 4 (IAT: 05 0A BE = 90 °C)
    lines = [
        "61 04 01 0A 14 06 36 B0",
        "61 04 05 0A C8 05 0A BE",
    ]
    resp = MockElmMultiFrameResp(lines)
    data = extract_block(resp, 4)
    assert data is not None
    # 4 células * 3 bytes = 12 bytes
    assert len(data) == 12

    # Verifica as células sem corrupção
    # C1: RPM (k=0x01)
    v1, u1 = decode_cell(data[0], data[1], data[2])
    assert v1 == 40.0
    assert u1 == "rpm"

    # C2: Bateria (k=0x06: 0.001 * 0x36(54) * 0xB0(176) = 9.504 V)
    v2, u2 = decode_cell(data[3], data[4], data[5])
    assert pytest.approx(v2, abs=1e-3) == 9.504
    assert u2 == "V"

    # C3: ECT (k=0x05)
    v3, u3 = decode_cell(data[6], data[7], data[8])
    assert v3 == 100.0
    assert u3 == "°C"

    # C4: IAT (k=0x05)
    v4, u4 = decode_cell(data[9], data[10], data[11])
    assert v4 == 90.0
    assert u4 == "°C"


def test_extract_block_with_frame_index_prefixes():
    """Garante que prefixos de frame '0:', '1:' são removidos sem quebrar o alinhamento."""
    lines = [
        "0: 61 03 01 0D 48 12 01",
        "1: 20 03 01 80 1B 01 A0",
    ]
    resp = MockElmMultiFrameResp(lines)
    data = extract_block(resp, 3)
    assert data is not None
    assert len(data) == 12
    v1, u1 = decode_cell(data[0], data[1], data[2])
    assert pytest.approx(v1, abs=0.1) == 187.2
    assert u1 == "rpm"


def test_vag_group02_injection_time_extraction():
    """Garante que Bloco 002 extrai inj_ms (Tempo de Injeção) da Célula 3."""
    # Bloco 002 ME7.5.30:
    # C1: RPM (k=0x01, 10, 20 -> 40 rpm)
    # C2: Carga (k=0x02, 10, 10 -> 0.2%)
    # C3: Tempo Injeção (k=0x0F, 10, 35 -> 0.01 * 10 * 35 = 3.5 ms)
    # C4: MAP (k=0x12, 10, 85 -> 0.04 * 10 * 85 = 34.0 mbar -> 3.4 kPa)
    payload = bytes([
        0x01, 10, 20,
        0x02, 10, 10,
        0x0F, 10, 35,
        0x12, 10, 85,
    ])
    dec = _dec_vag_group02(payload)
    assert "rpm" in dec
    assert "load" in dec
    assert "inj_ms" in dec
    assert dec["inj_ms"] == pytest.approx(3.5, abs=0.01)
    assert "map" in dec


def test_vag_group05_fuel_sys1_operating_states():
    """Garante que Bloco 005 Célula 4 mapeia o Estado de Operação para fuel_sys1 padrão SAE."""
    # C1: RPM, C2: Carga, C3: Velocidade (0x07, 10, 50 -> 50 km/h)
    # Célula 4: Estado de Operação

    # 1. Cut-Off / Schubabschaltung (bit 3 / 0x08 ativo) -> fuel_sys1 = 1.0
    p_cutoff = bytes([
        0x01, 10, 20,
        0x02, 10, 10,
        0x07, 10, 50,
        0x10, 0, 0x08,
    ])
    res_cutoff = _dec_vag_group05(p_cutoff)
    assert res_cutoff["fuel_sys1"] == 1.0
    assert res_cutoff["speed"] == 5.0

    # 2. Plena Carga / WOT / Enriquecimento (bit 2 / 0x04 ativo) -> fuel_sys1 = 4.0
    p_wot = bytes([
        0x01, 10, 20,
        0x02, 10, 10,
        0x07, 10, 50,
        0x10, 0, 0x04,
    ])
    res_wot = _dec_vag_group05(p_wot)
    assert res_wot["fuel_sys1"] == 4.0

    # 3. Lenta / Parcial / Malha Fechada (0x01 ou 0x02) -> fuel_sys1 = 2.0
    p_closed = bytes([
        0x01, 10, 20,
        0x02, 10, 10,
        0x07, 10, 50,
        0x10, 0, 0x01,
    ])
    res_closed = _dec_vag_group05(p_closed)
    assert res_closed["fuel_sys1"] == 2.0


def test_decode_vag_cell_unification():
    """Garante que decode_vag_cell utiliza vag.decode_cell diretamente sem duplicação."""
    val1, u1 = decode_vag_cell(0x01, 10, 20)
    val2, u2 = decode_cell(0x01, 10, 20)
    assert val1 == val2 == 40.0
    assert u1 == u2 == "rpm"
