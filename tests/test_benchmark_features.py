"""Testes automatizados das funcionalidades de ponta (Benchmark / Concorrentes).

Cobre:
- I/M Readiness (Modo 01 PID 01) e Freeze Frame (Modo 02)
- Canais Matemáticos (Potência, Torque, Erro Lambda, Integrador de Viagem)
- Cronômetro de Desempenho (Estilo Dragy / RaceChrono)
- Catálogo de Labels VAG (MP9.0 e ME7.5)
- Estatísticas do Mapa 2D e Exportação de Grade
- Gerador de Laudos Técnicos (HTML e PDF)
- Gerenciador de Alertas Sonoros (Shift Light e Sobreaquecimento)
"""
from __future__ import annotations

import os
import tempfile
import pytest
from PyQt6.QtWidgets import QApplication

from obd_app.audio_alerts import AudioAlertManager
from obd_app.math_channels import MathChannelsEngine
from obd_app.performance_timer import PerformanceTimer
from obd_app.readiness import FreezeFrame, ReadinessReport, parse_freeze_frame, parse_readiness_pid01
from obd_app.report_generator import export_report_to_pdf, generate_html_report
from obd_app.ui.map2d import Map2DWidget
from obd_app.vag_labels import MP90_LABELS, get_vag_group_label


@pytest.fixture(scope="session")
def qapp():
    app = QApplication.instance()
    if app is None:
        app = QApplication([])
    return app


def test_readiness_otto_and_diesel():
    # Byte A: MIL ON (0x80) + 3 DTCs (0x03) -> 0x83
    # Byte B: Otto (bit 3 = 0), Misfire sup & ok (0x01, bit 4=0), Fuel sup & ok (0x02, bit 5=0), Comp sup & ok (0x04, bit 6=0) -> 0x07
    # Byte C: Catalisador sup & incompleto (0x01 | 0x10 -> 0x11), EVAP sup & ok (0x04, bit 6=0) -> 0x15
    # Byte D: O2 sensor sup & ok (0x02, bit 5=0), O2 heater sup & ok (0x04, bit 6=0) -> 0x06
    raw_otto = bytes([0x83, 0x07, 0x15, 0x06])
    rep_otto = parse_readiness_pid01(raw_otto)

    assert rep_otto.mil_on is True
    assert rep_otto.dtc_count == 3
    assert rep_otto.is_diesel is False

    # Catalisador deve estar incompleto
    cat_mon = next(m for m in rep_otto.monitors if "Catalisador" in m.name and "Aquecido" not in m.name)
    assert cat_mon.supported is True
    assert cat_mon.completed is False

    # EVAP deve estar concluído
    evap_mon = next(m for m in rep_otto.monitors if "EVAP" in m.name)
    assert evap_mon.supported is True
    assert evap_mon.completed is True

    # Teste Diesel (Byte B bit 3 = 1 -> 0x08)
    raw_diesel = bytes([0x00, 0x08, 0x01, 0x04])
    rep_diesel = parse_readiness_pid01(raw_diesel)
    assert rep_diesel.is_diesel is True
    dpf_mon = next(m for m in rep_diesel.monitors if "DPF" in m.name)
    assert dpf_mon.supported is True


def test_freeze_frame_parsing():
    lines = [
        "42 02 01 71",        # DTC P0171 causador
        "42 0C 1F 40",        # RPM = 2000 RPM (0x1F40 / 4 = 2000)
        "42 0B 32",           # MAP = 50 kPa
        "42 05 78",           # ECT = 80 °C (120 - 40)
        "42 0D 3C",           # Speed = 60 km/h
        "42 04 66",           # Load = 40.0 % (102 * 100 / 255)
    ]
    ff = parse_freeze_frame(lines)
    assert ff.dtc == "P0171"
    assert "Rotação do Motor" in ff.params
    assert ff.params["Rotação do Motor"][0] == 2000.0
    assert ff.params["Pressão Coletor (MAP)"][0] == 50.0
    assert ff.params["Temperatura Motor (ECT)"][0] == 80.0
    assert ff.params["Velocidade"][0] == 60.0
    assert abs(ff.params["Carga do Motor"][0] - 40.0) < 0.5


def test_performance_timer_drags_and_braking():
    timer = PerformanceTimer()
    events = []

    # 1. Parado em 0 km/h -> Armar
    t = 0.0
    ev = timer.update(t, speed_kmh=0.0)
    if ev:
        events.append(ev)
    assert timer.state == "ARMED"

    # 2. Arrancada (0 a 100 km/h em 8 segundos com aceleração linear)
    for step in range(1, 91):  # 9.0 segundos a cada 0.1s
        t = step * 0.1
        spd = min(110.0, step * (100.0 / 80.0))  # atinge 100 km/h no step 80 (t=8.0s)
        ev = timer.update(t, speed_kmh=spd)
        if ev:
            events.append(ev)

    rec = timer.record
    assert rec.time_0_60 is not None
    assert rec.time_0_100 is not None
    assert 4.5 < rec.time_0_60 < 5.2
    assert 7.5 < rec.time_0_100 < 8.5
    assert rec.max_g > 0.0
    assert rec.max_speed >= 100.0

    # 3. Retomada 80 a 120 km/h
    timer.reset()
    timer.state = "RUNNING"
    timer.t_start = 10.0
    timer.v_start = 75.0
    timer.update(10.0, speed_kmh=75.0)
    timer.update(11.0, speed_kmh=80.0)  # marca entrada 80
    timer.update(15.0, speed_kmh=120.0)  # marca saida 120
    assert timer.record.time_80_120 == 4.0

    # 4. Frenagem 100 a 0 km/h
    timer.reset()
    timer.state = "RUNNING"
    timer.t_start = 20.0
    timer.update(20.0, speed_kmh=100.0)
    timer.update(23.0, speed_kmh=0.0)
    assert timer.record.time_100_0 == 3.0


def test_math_channels_engine():
    engine = MathChannelsEngine(displacement_l=1.6, fuel_price_brl=5.89)

    # Amostra a 3000 RPM, MAP 80 kPa, Speed 60 km/h, TPS 40%
    s1 = {"rpm": 3000.0, "map": 80.0, "speed": 60.0, "tps": 40.0, "lambda_v": 0.85}
    m1 = engine.compute(t=1.0, latest=s1)

    assert "power_hp" in m1
    assert "torque_kgfm" in m1
    assert m1["power_hp"] > 0.0
    assert m1["torque_kgfm"] > 0.0
    assert "volumetric_eff" in m1
    assert 70.0 < m1["volumetric_eff"] < 90.0

    # Teste de integração de viagem após 10 segundos
    s2 = {"rpm": 3000.0, "map": 80.0, "speed": 60.0, "tps": 40.0, "fuel_rate_lph": 6.0}
    m2 = engine.compute(t=11.0, latest=s2)

    assert "trip_fuel_liters" in m2
    assert "trip_km" in m2
    assert "trip_cost_brl" in m2
    assert "trip_avg_kml" in m2
    # 6 L/h por 10s = 6 * (10 / 3600) = 0.01667 L
    assert abs(m2["trip_fuel_liters"] - 0.0167) < 0.002
    # 60 km/h por 10s = 60 * (10 / 3600) = 0.1667 km
    assert abs(m2["trip_km"] - 0.1667) < 0.005
    assert m2["trip_cost_brl"] > 0.0


def test_vag_labels_catalog():
    # Kombi MP9.0 Bloco 001
    l_mp90 = get_vag_group_label(is_mp90=True, group=1, cell=1)
    assert "RPM" in l_mp90

    l_mp90_cell2 = get_vag_group_label(is_mp90=True, group=1, cell=2)
    assert "Temp" in l_mp90_cell2

    # ME7.5 Bloco 003
    l_me75 = get_vag_group_label(is_mp90=False, group=3, cell=3)
    assert "Borboleta" in l_me75 or "TPS" in l_me75


def test_report_generation_and_pdf(qapp):
    ecu_meta = {
        "display_title": "VW EA111 1.6 Flex — Bosch ME7.5.30",
        "manufacturer": "Volkswagen Brasil",
        "vin": "9BWZZZ5UZBP123456",
        "protocol": "ISO 14230-4 KWP2000 (Linha K)",
    }
    dtcs = [("P0300", "Falha de combustão múltipla / aleatória detectada")]
    rep = ReadinessReport(mil_on=True, dtc_count=1, is_diesel=False, monitors=[])
    ff = FreezeFrame(dtc="P0300", params={"Rotação (RPM)": (2500.0, "RPM")})

    html = generate_html_report(
        ecu_meta=ecu_meta,
        dtcs=dtcs,
        mil_status="ACESA (1 código)",
        readiness=rep,
        freeze_frame=ff,
        card_peaks={"rpm": (800.0, 5800.0), "map": (35.0, 98.0)},
        battery_test="Queda de partida normal: 10.4 V (Bateria Saudável)",
    )

    assert "Bosch ME7.5.30" in html
    assert "P0300" in html
    assert "Queda de partida normal" in html

    # Exportação para PDF
    with tempfile.NamedTemporaryFile(suffix=".pdf", delete=False) as tmp:
        tmp_path = tmp.name
    try:
        ok = export_report_to_pdf(html, tmp_path)
        assert ok is True
        assert os.path.exists(tmp_path)
        assert os.path.getsize(tmp_path) > 1000  # PDF não vazio
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)


def test_map2d_statistical_modes_and_copy(qapp):
    map_w = Map2DWidget()
    # Adiciona 2 amostras no mesmo bin (ex: 1000 RPM x 40 kPa) com valores diferentes de lambda (1.0 e 0.8)
    map_w.add_sample(1000.0, 40.0, {"lambda_v": 1.0})
    map_w.add_sample(1000.0, 40.0, {"lambda_v": 0.8})

    assert len(map_w._counts["lambda_v"]) == 1
    coord = list(map_w._counts["lambda_v"].keys())[0]

    # Teste Contagem
    assert map_w._counts["lambda_v"][coord] == 2

    # Teste Média
    val_mean = map_w._sums["lambda_v"][coord] / map_w._counts["lambda_v"][coord]
    assert abs(val_mean - 0.9) < 1e-4

    # Teste Máximo
    assert map_w._maxs["lambda_v"][coord] == 1.0

    # Teste Mínimo
    assert map_w._mins["lambda_v"][coord] == 0.8

    # Teste Exportação TSV / Grade
    map_w.set_stat_mode("Média")
    tsv = map_w.export_grid_tsv()
    assert "RPM / MAP" in tsv
    assert "1000" in tsv


def test_audio_alerts_non_blocking():
    # Testa gatilho de RPM e ECT sem travar a thread
    alerts = AudioAlertManager(shift_rpm=6000.0, max_ect_c=105.0)

    # Estado normal
    alerts.check(rpm=3000.0, ect=90.0)
    assert alerts.shift_triggered is False
    assert alerts.overheat_triggered is False

    # Shift RPM atingido
    alerts.check(rpm=6200.0, ect=90.0)
    assert alerts.shift_triggered is True

    # Reseta debounce para teste de sobreaquecimento imediato
    alerts._last_beep_t = 0.0

    # Overheat atingido
    alerts.check(rpm=3000.0, ect=108.0)
    assert alerts.overheat_triggered is True
