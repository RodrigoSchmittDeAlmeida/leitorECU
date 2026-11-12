"""Suite de testes para telemetria Turbo, estimador de combustível, canais matemáticos,

detector avançado, mock turbo e exportadores (ADR-004).
"""
import copy
import os
import tempfile
import time
import pytest

from obd_app.fuel_estimator import estimate_fuel_metrics, FuelConsumptionEstimator
from obd_app.math_channels import MathChannelsEngine
from obd_app.detector import DecelDetector, DetectorConfig, Event
from obd_app.mock_engine import MockEngine
from obd_app.audio_alerts import AudioAlertManager
from obd_app.performance_timer import PerformanceTimer, PerformanceRecord
from obd_app.datalog import CsvLogger, export_megalogviewer_csv


# ==============================================================================
# 1. TESTES DO FUEL ESTIMATOR (Correção do bug 60x, Turbo Speed-Density, km/l)
# ==============================================================================
def test_fuel_estimator_injector_pulse_width_60x_fix():
    """Garante que a estimativa via tempo de injeção (inj_ms) não está multiplicada por 60.

    Com bicos de 195 cc/min a 3000 RPM e pulso de 3.0 ms, o consumo real esperado fica em
    torno de 3.5 a 4.0 L/h, e JAMAIS acima de 150 L/h.
    """
    sample = {
        "rpm": 3000.0,
        "inj_ms": 3.0,
        "map": 50.0,
        "speed": 80.0,
        "tps": 20.0,
    }
    metrics = estimate_fuel_metrics(sample, displacement_l=1.6)
    lph = metrics["fuel_rate_lph"]
    assert 2.5 <= lph <= 5.5, f"Consumo {lph} L/h fora da faixa física esperada (~3.5 L/h)! Possível bug de 60x persistindo."
    assert "fuel_econ_kml" in metrics
    assert metrics["fuel_econ_kml"] > 0.0


def test_fuel_estimator_turbo_speed_density_and_volumetric_efficiency():
    """Garante que motores sobrealimentados (MAP > 100 kPa) calculam VE acima de 88% (até 135%) sem travar."""
    sample_turbo = {
        "rpm": 4500.0,
        "map": 200.0,  # 1.0 bar de pressão positiva de turbo
        "speed": 130.0,
        "tps": 90.0,
        "iat": 40.0,
    }
    metrics = estimate_fuel_metrics(sample_turbo, displacement_l=2.0)
    assert metrics["volumetric_eff"] > 100.0, f"VE {metrics['volumetric_eff']}% não refletiu sobrealimentação turbo!"
    assert metrics["volumetric_eff"] <= 135.0
    assert metrics["fuel_rate_lph"] > 15.0  # Consumo coerente com 2.0 Turbo em WOT


def test_fuel_estimator_fuel_econ_always_present():
    """Garante que a chave 'fuel_econ_kml' está SEMPRE presente no retorno (0.0 em marcha lenta/parado)."""
    stopped = {"rpm": 800.0, "map": 32.0, "speed": 0.0, "tps": 0.0}
    m_stopped = estimate_fuel_metrics(stopped)
    assert "fuel_econ_kml" in m_stopped
    assert m_stopped["fuel_econ_kml"] == 0.0

    slow = {"rpm": 850.0, "map": 35.0, "speed": 1.5, "tps": 2.0}
    m_slow = estimate_fuel_metrics(slow)
    assert "fuel_econ_kml" in m_slow
    assert m_slow["fuel_econ_kml"] == 0.0

    cutoff = {"rpm": 2500.0, "map": 20.0, "speed": 60.0, "tps": 0.0}
    m_cutoff = estimate_fuel_metrics(cutoff)
    assert "fuel_econ_kml" in m_cutoff
    assert m_cutoff["fuel_econ_kml"] == 99.9


# ==============================================================================
# 2. TESTES DE CANAIS MATEMÁTICOS (Boost, Knock Max, Potência Turbo, Bateria)
# ==============================================================================
def test_math_channels_boost_bar_and_psi():
    """Garante que boost_bar e boost_psi são computados com Baro customizado ou fallback de 101.325 kPa."""
    engine = MathChannelsEngine()

    # Amostra com MAP 220 kPa e Baro medido 100.0 kPa
    s1 = {"rpm": 4000.0, "map": 220.0, "baro": 100.0, "speed": 100.0}
    m1 = engine.compute(t=1.0, latest=s1)
    assert "boost_bar" in m1
    assert "boost_psi" in m1
    assert m1["boost_bar"] == 1.200
    assert abs(m1["boost_psi"] - 17.40) < 0.1

    # Amostra em vácuo (MAP 30.0 kPa, sem PID Baro -> usa fallback 101.325)
    s2 = {"rpm": 900.0, "map": 30.0, "speed": 0.0}
    m2 = engine.compute(t=2.0, latest=s2)
    assert m2["boost_bar"] < 0.0  # Vácuo relativo
    assert abs(m2["boost_bar"] - ((30.0 - 101.325) / 100.0)) < 0.001


def test_math_channels_knock_retard_max_aggregation():
    """Garante agregação correta do retardo máximo entre os cilindros 1..4."""
    engine = MathChannelsEngine()
    latest = {
        "rpm": 3500.0,
        "map": 150.0,
        "knock_ret_c1": 1.5,
        "knock_ret_c2": 4.5,
        "knock_ret_c3": 0.0,
        "knock_ret_c4": 3.0,
    }
    m = engine.compute(t=1.0, latest=latest)
    assert "knock_retard_max" in m
    assert m["knock_retard_max"] == 4.5


def test_math_channels_turbo_power_above_220hp_and_ethanol_density():
    """Garante que motores potentes (Turbo/GDI) não sofrem teto de 220 cv e ajustam estequiometria pelo etanol."""
    engine = MathChannelsEngine()
    # 110 L/h de consumo com 85% de etanol (E85) a 6000 RPM sob 210 kPa de MAP
    sample = {
        "rpm": 6000.0,
        "map": 210.0,
        "fuel_rate_lph": 110.0,
        "flex_ethanol_pct": 85.0,
    }
    m = engine.compute(t=1.0, latest=sample)
    assert m["power_hp"] > 220.0, f"Potência {m['power_hp']} cv foi limitada artificialmente a 220 cv!"
    assert m["power_hp"] < 900.0
    assert m["torque_kgfm"] > 20.0


def test_math_channels_battery_and_alternator_health():
    """Garante avaliação de saúde da bateria em repouso, queda na partida (< 9.6V) e alternador (> 13.6V)."""
    engine = MathChannelsEngine()

    # 1. Repouso saudável
    h_rest = engine.evaluate_battery_health(voltage=12.6, rpm=0.0)
    assert h_rest["status"] == "resting_ok"
    assert not h_rest["is_charging"]

    # 2. Partida com queda crítica (< 9.6V)
    h_crank = engine.evaluate_battery_health(voltage=8.9, rpm=200.0, min_crank_volt=8.9)
    assert h_crank["status"] == "cranking_warning"
    assert h_crank["cranking_ok"] is False

    # 3. Motor funcionando com alternador carregando (> 13.6V)
    h_run = engine.evaluate_battery_health(voltage=14.1, rpm=900.0)
    assert h_run["status"] == "charging_ok"
    assert h_run["is_charging"] is True


# ==============================================================================
# 3. TESTES DO DETECTOR (Overboost, Underboost, Knock, Drift A/F, Wideband)
# ==============================================================================
def test_detector_load_conflict_tolerance_expanded():
    """Garante que tolerância síncrona < 0.25s permite detecção de anomalia de carga mesmo com delay de 0.15s (Ford/OBD)."""
    det = DecelDetector()
    t = 10.0
    latest = {"rpm": 1100.0, "tps": 3.0, "map": 75.0}
    # MAP e TPS com 0.15s de diferença (antes era rejeitado por tolerância de 0.05s)
    stamp = {"rpm": 10.0, "map": 10.0, "tps": 9.85}
    evs = det.update(t, latest, stamp)
    alarms = [e for e in evs if "CARGA ANORMAL" in e.message]
    assert len(alarms) == 1, "Tolerância < 0.25s deveria ter aceitado time-skew de 0.15s!"


def test_detector_wideband_no_false_rich_alarm_on_cut_off():
    """Garante que em modo Wideband (lambda_eq presente), tensão > 0.70V não gera falso alarme de cut-off."""
    det = DecelDetector()
    # Inicia desaceleração de 3500 -> 2500 RPM
    det.update(10.0, {"rpm": 3500.0, "tps": 2.0}, {"rpm": 10.0, "tps": 10.0})
    det.update(10.5, {"rpm": 2500.0, "tps": 2.0}, {"rpm": 10.5, "tps": 10.5})
    assert det.in_decel

    # Em sonda wideband Bosch LSU 4.9, lambda_v pode ser 2.50V (ou 0.90V) enquanto lambda_eq é 1.95 (ar puro em cut-off)
    evs = det.update(
        11.0,
        {"rpm": 2200.0, "tps": 1.0, "lambda_v": 2.45, "lambda_eq": 1.95},
        {"rpm": 11.0, "tps": 11.0, "lambda_v": 11.0, "lambda_eq": 11.0},
    )
    rich_alarms = [e for e in evs if "FALHA DE CUT-OFF" in e.message]
    assert len(rich_alarms) == 0, f"Disparou falso alarme de cut-off rico em sonda wideband: {rich_alarms}"


def test_detector_overboost_and_underboost_alerts():
    """Testa detecção sustentada de Overboost crítico e Underboost (vazamento de pressurização)."""
    det = DecelDetector()

    # 1. Teste de Overboost: boost 1.6 bar com alvo de 1.1 bar (delta 0.5 bar > 0.25 bar) sustentado por 0.5s
    det.update(1.0, {"boost_bar": 1.60, "boost_target_bar": 1.10}, {"boost_bar": 1.0, "boost_target_bar": 1.0})
    evs_over = det.update(1.5, {"boost_bar": 1.65, "boost_target_bar": 1.10}, {"boost_bar": 1.5, "boost_target_bar": 1.5})
    over_alarms = [e for e in evs_over if "OVERBOOST CRÍTICO" in e.message]
    assert len(over_alarms) == 1, "Deveria ter disparado alerta de overboost sustentado!"

    # 2. Teste de Underboost / Boost Leak: TPS 95%, RPM 4200, alvo 1.4 bar mas gerando apenas 0.8 bar por >= 1.5s
    det.reset()
    stamps = lambda t_now: {"rpm": t_now, "tps": t_now, "boost_bar": t_now, "boost_target_bar": t_now}
    det.update(10.0, {"rpm": 4200.0, "tps": 95.0, "boost_bar": 0.80, "boost_target_bar": 1.40}, stamps(10.0))
    det.update(11.0, {"rpm": 4500.0, "tps": 95.0, "boost_bar": 0.82, "boost_target_bar": 1.40}, stamps(11.0))
    evs_under = det.update(11.6, {"rpm": 4800.0, "tps": 95.0, "boost_bar": 0.85, "boost_target_bar": 1.40}, stamps(11.6))
    under_warns = [e for e in evs_under if "UNDERBOOST" in e.message]
    assert len(under_warns) == 1, "Deveria ter disparado alerta de underboost após 1.6s sustentado!"


def test_detector_knock_and_fuel_trim_drift():
    """Testa alertas de detonação severa (Knock Retard >= 6.0°) e desvio de mistura (|STFT+LTFT| > 22%)."""
    det = DecelDetector()
    stamps = lambda t_now: {"rpm": t_now, "tps": t_now, "knock_retard_max": t_now, "stft": t_now, "ltft": t_now}

    # Knock crítico
    evs_knock = det.update(5.0, {"knock_retard_max": 6.8}, {"knock_retard_max": 5.0})
    knock_alarms = [e for e in evs_knock if "DETONAÇÃO CRÍTICA" in e.message]
    assert len(knock_alarms) == 1

    # Desvio severo de mistura sustentado (+14% STFT + 12% LTFT = +26% total)
    det.update(10.0, {"rpm": 850.0, "tps": 0.0, "stft": 14.0, "ltft": 12.0}, stamps(10.0))
    evs_drift = det.update(12.2, {"rpm": 850.0, "tps": 0.0, "stft": 13.5, "ltft": 12.0}, stamps(12.2))
    drift_warns = [e for e in evs_drift if "DESVIO SEVERO DE MISTURA" in e.message]
    assert len(drift_warns) == 1


# ==============================================================================
# 4. TESTES DO MOCK ENGINE (0x5E, 0x13, 0x1C, Modo Turbo TSI e Blocos VAG 114/115/118)
# ==============================================================================
def test_mock_engine_supported_pids_and_encoders():
    """Garante que PIDs 015E, 0113 e 011C são suportados e decodificados sem 'NO DATA'."""
    engine = MockEngine()
    engine.protocol_ready = True

    # PID 0113 (O2 sensor mask)
    resp_13, _ = engine.respond("0113", kline=0.0)
    assert resp_13.startswith("4113")

    # PID 011C (OBD requirements)
    resp_1c, _ = engine.respond("011C", kline=0.0)
    assert resp_1c.startswith("411C")

    # PID 015E (Fuel Rate)
    resp_5e, _ = engine.respond("015E", kline=0.0)
    assert resp_5e.startswith("415E")


def test_mock_engine_turbo_mode_and_vag_blocks():
    """Garante simulação de boost até 220 kPa, PIDs Turbo (0123, 0124, 0170, 0177) e Blocos 020/114/115/118."""
    engine = MockEngine(turbo_mode=True)
    engine.protocol_ready = True
    engine.vag_mode = True
    engine.header = "8110F1"

    # Avança tempo para simular fase de aceleração WOT
    engine.t0 = time.monotonic() - 7.5  # ph = 7.5 (meio da aceleração WOT)
    s = engine.state()
    assert s["map"] > 140.0, f"MAP {s['map']} kPa deveria estar sobrealimentado!"
    assert s["boost_bar"] > 0.40
    assert s["lambda_eq"] < 0.95

    # Bloco VAG 115 (Pressão Turbo Especificada vs Real)
    resp_115, _ = engine.respond("2173", kline=0.0)
    assert resp_115.startswith("6173")

    # Bloco VAG 114 (N75 Wastegate Duty)
    resp_114, _ = engine.respond("2172", kline=0.0)
    assert resp_114.startswith("6172")

    # Bloco VAG 118 (IAT, N75, Pressão Turbo)
    resp_118, _ = engine.respond("2176", kline=0.0)
    assert resp_118.startswith("6176")

    # Bloco VAG 020 (Retardo de Detonação com picos sob carga)
    resp_020, _ = engine.respond("2114", kline=0.0)
    assert resp_020.startswith("6114")


def test_mock_engine_turbo_pids_and_vag_roundtrip():
    """Valida round-trip completo entre MockEngine(turbo_mode=True) e decodificadores reais de PIDS.

    Alimenta respostas de 0170, 2172 (Bloco 114), 2173 (Bloco 115) e 2176 (Bloco 118)
    diretamente nos decodificadores de pids.py e valida RPM, Boost, Wastegate e Target.
    """
    from obd_app.pids import PIDS

    eng = MockEngine(turbo_mode=True)
    eng.protocol_ready = True
    eng.vag_mode = True
    eng.header = "8110F1"

    # Fase de aceleração WOT (ph = 7.5s)
    eng.t0 = time.monotonic() - 7.5

    # 1. PID 0170 (Controle Boost / Wastegate - 10 bytes)
    resp_70, _ = eng.respond("0170", kline=0.0)
    assert resp_70.startswith("4170")
    payload_70 = bytes.fromhex(resp_70[4:])
    assert len(payload_70) == 10
    d_70 = PIDS[0x70].decode(payload_70)
    assert "boost_target_bar" in d_70
    assert "boost_bar" in d_70
    assert "wastegate_pct" in d_70
    assert d_70["boost_target_bar"] > 0.8
    assert d_70["boost_bar"] > 0.3
    assert d_70["wastegate_pct"] > 50.0

    # 2. VAG Bloco 115 (2173: RPM, Carga, Pressão Turbo Especificada vs Real)
    resp_115, _ = eng.respond("2173", kline=0.0)
    assert resp_115.startswith("6173")
    payload_115 = bytes.fromhex(resp_115[4:])
    assert len(payload_115) == 12
    d_115 = PIDS[(0x21 << 8) | 0x73].decode(payload_115)
    assert "rpm" in d_115
    assert "load" in d_115
    assert "boost_target_bar" in d_115
    assert "boost_bar" in d_115
    assert "map" in d_115
    assert d_115["rpm"] > 1000.0
    assert d_115["load"] > 20.0
    assert d_115["boost_target_bar"] > 0.8
    assert d_115["map"] > 130.0  # MAP sobrealimentado

    # 3. VAG Bloco 114 (2172: Carga especificada, Carga real, N75 Wastegate %)
    resp_114, _ = eng.respond("2172", kline=0.0)
    assert resp_114.startswith("6172")
    payload_114 = bytes.fromhex(resp_114[4:])
    assert len(payload_114) == 12
    d_114 = PIDS[(0x21 << 8) | 0x72].decode(payload_114)
    assert "wastegate_pct" in d_114
    assert d_114["wastegate_pct"] > 50.0

    # 4. VAG Bloco 118 (2176: RPM, IAT, N75 %, Pressão Real)
    resp_118, _ = eng.respond("2176", kline=0.0)
    assert resp_118.startswith("6176")
    payload_118 = bytes.fromhex(resp_118[4:])
    assert len(payload_118) == 12
    d_118 = PIDS[(0x21 << 8) | 0x76].decode(payload_118)
    assert "rpm" in d_118
    assert "iat" in d_118
    assert "wastegate_pct" in d_118
    assert "boost_bar" in d_118
    assert d_118["wastegate_pct"] > 50.0


# ==============================================================================
# 5. TESTES DE ALERTAS SONOROS (Histerese, Threading Seguro, Overboost)
# ==============================================================================
def test_audio_alerts_hysteresis_and_turbo_hooks():
    """Testa que os gatilhos resetam com histerese e verificam overboost/knock."""
    alerts = AudioAlertManager(shift_rpm=6000.0, max_ect_c=105.0)

    # Dispara Shift Light
    alerts.check(rpm=6200.0, ect=90.0)
    assert alerts.shift_triggered is True

    # RPM cai para 5800 (ainda dentro da histerese de 300 RPM -> permanece True)
    alerts.check(rpm=5800.0, ect=90.0)
    assert alerts.shift_triggered is True

    # RPM cai abaixo de 5700 (sai da histerese -> reseta para False)
    alerts.check(rpm=5600.0, ect=90.0)
    assert alerts.shift_triggered is False

    # Dispara Overboost
    alerts._last_beep_t = 0.0
    alerts.check(rpm=4000.0, ect=90.0, boost_bar=1.95, overboost_limit=1.80)
    assert alerts.overboost_triggered is True


# ==============================================================================
# 6. TESTES DO PERFORMANCE TIMER (History, 100-200 km/h, Frenagem Contínua)
# ==============================================================================
def test_performance_timer_history_and_100_200():
    """Garante população de self.history em puxada completa e medição de 100-200 km/h."""
    timer = PerformanceTimer()

    # 1. Puxada de 0 a 100 km/h e até 402m
    timer.update(1.0, speed_kmh=0.0)
    timer.update(1.2, speed_kmh=5.0)  # largada
    timer.update(5.0, speed_kmh=60.0)
    timer.update(8.5, speed_kmh=100.0)
    # Simula chegada aos 402 metros
    timer.distance_m = 405.0
    timer.update(14.0, speed_kmh=160.0)

    assert timer.state == "FINISHED"
    assert len(timer.history) == 1
    assert timer.history[0].time_0_100 is not None

    # 2. Retomada 100 a 200 km/h
    timer.reset()
    timer.update(20.0, speed_kmh=98.0)
    timer.update(21.0, speed_kmh=100.0)  # início 100
    timer.update(28.0, speed_kmh=202.0)  # fim 200
    assert timer.record.time_100_200 == 7.0

    # 3. Frenagem 100-0 contínua (rejeita se o motorista acelerou no meio)
    timer.reset()
    timer.update(30.0, speed_kmh=102.0)
    timer.update(31.0, speed_kmh=80.0)
    timer.update(32.0, speed_kmh=90.0)  # acelerou de novo (+10 km/h) -> deve cancelar medição de frenagem
    timer.update(33.0, speed_kmh=0.0)
    assert timer.record.time_100_0 is None, "Frenagem deveria ter sido cancelada por aceleração no meio!"


# ==============================================================================
# 7. TESTES DE DATALOG & MEGALOGVIEWER (BOM UTF-8, Colunas Turbo)
# ==============================================================================
def test_datalog_and_megalogviewer_turbo_export():
    """Garante que export_megalogviewer_csv mapeia colunas de Boost, Baro, N75 e Knock."""
    with tempfile.NamedTemporaryFile(suffix=".csv", mode="w", delete=False, encoding="utf-8-sig") as f_src:
        f_src.write("timestamp_ms;tempo_s;atualizado;rpm;map;boost_bar;boost_psi;baro;wastegate_pct;fuel_rail_bar;knock_retard_max;evento\n")
        f_src.write("1000;1,000;rpm+map;4500;220,0;1,200;17,40;100,0;75,5;145,0;3,5;WOT_Boost\n")
        src_path = f_src.name

    with tempfile.NamedTemporaryFile(suffix=".msl", delete=False) as f_dst:
        dst_path = f_dst.name

    try:
        ok = export_megalogviewer_csv(src_path, dst_path)
        assert ok is True
        assert os.path.exists(dst_path)

        with open(dst_path, "r", encoding="utf-8") as f:
            lines = f.readlines()

        header = lines[0].strip().split("\t")
        assert "Boost" in header
        assert "Boost_psi" in header
        assert "Baro" in header
        assert "Wastegate_Duty" in header
        assert "Fuel_Rail_Pressure" in header
        assert "Knock_Retard" in header

        row1 = lines[1].strip().split("\t")
        assert "1.200" in row1
        assert "17.40" in row1
    finally:
        if os.path.exists(src_path):
            os.remove(src_path)
        if os.path.exists(dst_path):
            os.remove(dst_path)


def test_mock_engine_aspirated_mode_rejects_turbo_pids_and_blocks():
    """Garante que no modo aspirado (turbo_mode=False) a MockEngine não responde nem anuncia PIDs/blocos turbo."""
    # 1. Modo Aspirado (Gol G5 ME7.5.30)
    asp = MockEngine(turbo_mode=False)
    asp.protocol_ready = True
    asp.vag_mode = True
    asp.header = "8110F1"

    # Blocos VAG 114, 115 e 118 devem retornar NO DATA
    assert asp.respond("2172", kline=0.0)[0] == "NO DATA"
    assert asp.respond("2173", kline=0.0)[0] == "NO DATA"
    assert asp.respond("2176", kline=0.0)[0] == "NO DATA"

    # PIDs Modo 01 específicos de Turbo / Wideband devem retornar NO DATA
    assert asp.respond("0170", kline=0.0)[0] == "NO DATA"
    assert asp.respond("0177", kline=0.0)[0] == "NO DATA"
    assert asp.respond("0123", kline=0.0)[0] == "NO DATA"
    assert asp.respond("0124", kline=0.0)[0] == "NO DATA"
    assert asp.respond("0160", kline=0.0)[0] == "NO DATA"

    # PIDs base devem continuar funcionando normalmente
    assert asp.respond("010C", kline=0.0)[0].startswith("410C")
    assert asp.respond("0113", kline=0.0)[0].startswith("4113")
    assert asp.respond("011C", kline=0.0)[0].startswith("411C")
    assert asp.respond("015E", kline=0.0)[0].startswith("415E")

    # Identificação da ECU e VIN devem refletir ME7.5.30 / Gol G5
    r_1a9b = asp.respond("1A9B", kline=0.0)[0]
    assert "032906032AJ" in bytes.fromhex(r_1a9b[4:]).decode("latin1")
    r_vin = asp.respond("0902", kline=0.0)[0]
    assert "9BWZZZ5UZBP123456" in bytes.fromhex(r_vin[6:]).decode("ascii")

    # 2. Modo Turbo (TSI / MED17.5)
    turbo = MockEngine(turbo_mode=True)
    turbo.protocol_ready = True
    turbo.vag_mode = True
    turbo.header = "8110F1"

    assert turbo.respond("2172", kline=0.0)[0].startswith("6172")
    assert turbo.respond("2173", kline=0.0)[0].startswith("6173")
    assert turbo.respond("2176", kline=0.0)[0].startswith("6176")
    assert turbo.respond("0170", kline=0.0)[0].startswith("4170")
    assert turbo.respond("0177", kline=0.0)[0].startswith("4177")
    assert turbo.respond("0123", kline=0.0)[0].startswith("4123")
    assert turbo.respond("0124", kline=0.0)[0].startswith("4124")
    assert turbo.respond("0160", kline=0.0)[0].startswith("4160")

    # Identificação da ECU e VIN devem refletir MED17.5 / TSI
    r_t_1a9b = turbo.respond("1A9B", kline=0.0)[0]
    assert "5G0906259" in bytes.fromhex(r_t_1a9b[4:]).decode("latin1")
    r_t_vin = turbo.respond("0902", kline=0.0)[0]
    assert "WVWZZZAUZHP123456" in bytes.fromhex(r_t_vin[6:]).decode("ascii")

