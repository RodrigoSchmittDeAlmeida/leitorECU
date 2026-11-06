"""Testes para o detector avançado de anomalias (Vácuo / Dashpot / Retardo ATDC) e interfaces SOLID."""
import pytest
from obd_app.detector import DecelDetector
from obd_app.datalog import CsvLogger
from obd_app.interfaces import IDataLogger, IDetector, ITransport
from obd_app.transports import MockTransport


def test_interfaces_solid_protocols_compliance():
    """Garante que Transport, DecelDetector e CsvLogger cumprem estritamente os protocolos ITransport, IDetector e IDataLogger."""
    transport = MockTransport()
    detector = DecelDetector()
    logger = CsvLogger()

    assert isinstance(transport, ITransport)
    assert isinstance(detector, IDetector)
    assert isinstance(logger, IDataLogger)


def test_detector_vacuum_anomaly_low_rpm():
    """Garante que conflito de carga (MAP > 60 kPa, TPS < 8%, RPM < 1900) gera alerta de anomalia."""
    det = DecelDetector()
    t = 10.0
    latest = {
        "rpm": 1200.0,
        "tps": 4.5,
        "map": 72.0,
    }
    stamp = {k: t for k in latest}

    events = det.update(t, latest, stamp)
    assert len(events) >= 1
    alarm = next((e for e in events if e.level == "alarm"), None)
    assert alarm is not None
    assert "CARGA ANORMAL COM BORBOLETA FECHADA" in alarm.message
    assert "72.0" in alarm.message
    assert "1200" in alarm.message

    # Teste de cooldown: chamada imediata em t+0.5s não deve duplicar o alerta
    events_cooldown = det.update(t + 0.5, latest, {k: t + 0.5 for k in latest})
    alarms_cd = [e for e in events_cooldown if "CARGA ANORMAL" in e.message]
    assert len(alarms_cd) == 0

    # Após 2.5s (expirou cooldown), o alerta pode ser emitido novamente se a anomalia persistir
    events_after = det.update(t + 2.5, latest, {k: t + 2.5 for k in latest})
    alarms_after = [e for e in events_after if "CARGA ANORMAL" in e.message]
    assert len(alarms_after) == 1


def test_detector_critical_retard_atdc_alert():
    """Garante que avanço negativo extremo (< -8.0°, ex: -19.0°) gera alerta de retardo crítico ATDC."""
    det = DecelDetector()
    t = 20.0
    latest = {
        "rpm": 1400.0,
        "map": 55.0,
        "advance": -19.0,  # Defeito típico observado nos logs da ME7.5.30
        "fuel_sys1": 2.0,  # Malha fechada sem Cut-off
        "lambda_v": 0.65,
    }
    stamp = {k: t for k in latest}

    events = det.update(t, latest, stamp)
    assert len(events) >= 1
    alarm = next((e for e in events if e.level == "alarm"), None)
    assert alarm is not None
    assert "RETARDO CRÍTICO ATDC" in alarm.message
    assert "-19.0°" in alarm.message
    assert "malha fechada sem Cut-Off" in alarm.message
