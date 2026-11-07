"""Testes para o motor de Auto-Discovery universal, Kombi MP9.0 KW1281, cálculo de consumo e teste de partida."""
import pytest
from obd_app.ecu_fingerprints import identify_ecu, PART_NUMBER_DATABASE, WMI_DATABASE
from obd_app.protocols.kw1281 import Kw1281Strategy, decode_kw1281_cell, PROFILE_KW1281
from obd_app.protocols.autodiscovery import UniversalAutoDiscovery
from obd_app.fuel_estimator import FuelConsumptionEstimator
from obd_app.detector import DecelDetector
from obd_app.transports import MockTransport, KklSerialTransport
from obd_app.ui.main_window import MainWindow
from PyQt6.QtWidgets import QApplication
import sys

app = QApplication.instance() or QApplication(sys.argv)


def test_ecu_fingerprints_decoder():
    """Testa identificação inteligente de central via Part Number e VIN WMI."""
    # 1. Bosch ME7.5.30 (Gol G5)
    meta_gol = identify_ecu(raw_id="032906032AJ ME7.5.30", vin="9BWCA05X9CP000000", protocol_name="VAG KWP2000")
    assert "ME7.5.30" in meta_gol["display_title"]
    assert meta_gol["manufacturer"] == "Volkswagen do Brasil"
    assert "VW EA111" in meta_gol["engine"]

    # 2. Bosch MP9.0 (Kombi 1.6 Ar)
    meta_kombi = identify_ecu(raw_id="2379060211 MP9.0 KOMBI 1.6", protocol_name="VAG KW1281")
    assert "MP9.0" in meta_kombi["display_title"]
    assert "Kombi" in meta_kombi["display_title"]
    assert "1.6" in meta_kombi["engine"]

    # 3. Ford Continental EMS2211
    meta_ford = identify_ecu(raw_id="EMS2211", vin="9BFBT55X9G8000000", protocol_name="ISO 15765-4 CAN")
    assert "EMS2211" in meta_ford["display_title"]
    assert meta_ford["manufacturer"] == "Ford Brasil"
    assert meta_ford["is_can"] is True


def test_kw1281_cell_decoding():
    """Testa decodificação de células de medição KW1281 da Bosch MP9.0."""
    # Fórmula 1: RPM (n = 0.2 * a * b) -> com a=20, b=220 -> 880 RPM
    val_rpm, unit_rpm, desc_rpm = decode_kw1281_cell(1, 20, 220)
    assert val_rpm == pytest.approx(880.0, 0.1)
    assert unit_rpm == "rpm"

    # Fórmula 5: ECT / Óleo (°C = a * (b - 100) * 0.1)
    val_temp, unit_temp, _ = decode_kw1281_cell(5, 1, 192)
    assert val_temp == pytest.approx(9.2, 0.1)
    assert unit_temp == "°C"

    # Fórmula 6: Tensão de Sonda (V = 0.001 * a * b)
    val_lambda, unit_l, _ = decode_kw1281_cell(6, 1, 450)
    assert val_lambda == pytest.approx(0.450, 0.001)
    assert unit_l == "V"


def test_kw1281_strategy_groups():
    """Testa parse de blocos de medição da Bosch MP9.0."""
    strat = Kw1281Strategy()
    assert strat.profile_id == PROFILE_KW1281
    assert "Kombi" in strat.display_name

    # Simula pacote KW1281 Bloco 001: [len, counter, title 0xE7, cell1, cell2, cell3, cell4, 0x03]
    # Cell 1: Form 1 (RPM), 20, 220 -> 880 RPM
    # Cell 2: Form 5 (ECT), 1, 190 -> 9.0 °C
    # Cell 3: Form 6 (Lambda), 1, 200 -> 0.200 V
    # Cell 4: Form 20 (TPS), 0, 0 -> 0%
    data = bytes([15, 1, 0xE7, 1, 20, 220, 5, 1, 190, 6, 1, 200, 20, 0, 0, 0x03])
    sample = strat._parse_kw1281_group(1, data)
    assert sample["rpm"] == pytest.approx(880.0, 0.1)
    assert sample["ect"] == pytest.approx(9.0, 0.1)
    assert sample["lambda_v"] == pytest.approx(0.200, 0.01)


def test_fuel_consumption_estimator():
    """Testa estimativa de consumo instantâneo (L/h e km/l) e eficiência volumétrica."""
    estimator = FuelConsumptionEstimator(displacement_l=1.6)

    # 1. Marcha lenta (850 RPM, 35 kPa, 30°C, 0 km/h)
    lph, kml, ve = estimator.estimate_instant_consumption(
        rpm=850, map_kpa=35.0, iat_c=30.0, speed_kmh=0.0
    )
    assert 0.6 <= lph <= 1.4  # Consumo típico em marcha lenta de motor 1.6
    assert kml == 0.0  # Parado = 0 km/l
    assert 25.0 <= ve <= 45.0  # Em lenta com borboleta fechada, VE é em torno de 30%

    # 2. Desaceleração / Cut-Off (2500 RPM, MAP 18 kPa, inj_ms = 0.0)
    lph_cutoff, kml_cutoff, _ = estimator.estimate_instant_consumption(
        rpm=2500, map_kpa=18.0, iat_c=25.0, speed_kmh=60.0, inj_ms=0.0
    )
    assert lph_cutoff == 0.0
    assert kml_cutoff == 99.9  # Teto de economia em cut-off

    # 3. Cruzeiro em rodovia (2500 RPM, MAP 50 kPa, 90 km/h)
    lph_cruise, kml_cruise, _ = estimator.estimate_instant_consumption(
        rpm=2500, map_kpa=50.0, iat_c=25.0, speed_kmh=90.0
    )
    assert 4.0 <= lph_cruise <= 8.5
    assert 10.0 <= kml_cruise <= 22.0


def test_cranking_voltage_drop_analyzer():
    """Testa detecção e análise de queda de tensão da bateria durante a partida."""
    detector = DecelDetector()

    # T=0s: Motor desligado, tensão de repouso
    events = detector.update(0.0, {"rpm": 0.0, "battery": 12.6, "tps": 0.0}, {"rpm": 0.0})
    assert len(events) == 0

    # T=0.5s: Motor acionando motor de arranque (180 RPM, tensão cai para 9.8V)
    events = detector.update(0.5, {"rpm": 180.0, "battery": 9.8, "tps": 0.0}, {"rpm": 0.5})
    assert detector.crank_in_progress is True
    assert detector.min_crank_volt == 9.8

    # T=0.8s: Queda máxima do arranque (220 RPM, tensão atinge 9.3V)
    events = detector.update(0.8, {"rpm": 220.0, "battery": 9.3, "tps": 0.0}, {"rpm": 0.8})
    assert detector.min_crank_volt == 9.3

    # T=1.2s: Motor pega e entra em marcha lenta (> 600 RPM, alternador sobe para 13.8V)
    events = detector.update(1.2, {"rpm": 850.0, "battery": 13.8, "tps": 0.0}, {"rpm": 1.2})
    assert detector.crank_in_progress is False
    # Deve emitir alerta sobre a tensão de partida (9.3V < 9.6V -> bateria fraca ou cabo massa)
    crank_events = [e for e in events if "partida" in e.message.lower()]
    assert len(crank_events) >= 1
    assert crank_events[0].level in ("alarm", "warn")
    assert "9.3" in crank_events[0].message


def test_ui_single_lambda_adaptation():
    """Testa adaptação dinâmica do card lambda2_v quando o veículo só possui 1 sonda lambda."""
    win = MainWindow(demo=True)
    win.show()

    # Inicialmente, o card lambda2_v tem título padrão
    c2 = win.cards["lambda2_v"]
    assert "Sonda 2" in c2.title.text() or "lambda2" in c2.ch.key

    # Simula amostra onde NÃO há lambda2_v, mas há inj_ms de 3.65 ms (ex: Kombi MP9.0)
    win.latest.clear()
    win.latest["rpm"] = 880.0
    win.latest["lambda_v"] = 0.45
    win.latest["inj_ms"] = 3.65
    win.latest["fuel_rate_lph"] = 1.15
    win.dirty.add("rpm")
    win.dirty.add("lambda_v")

    # Renderiza um frame
    win._render()

    # O card lambda2_v deve ter sido adaptado para Tempo de Injeção
    assert c2.title.text() == "Tempo Injeção"
    assert c2.unit.text() == "ms"
    assert "3.65" in c2.value.text()

    win.close()
