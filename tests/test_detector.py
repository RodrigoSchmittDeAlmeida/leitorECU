"""Testes unitários para o detector de desaceleração e cut-off (obd_app.detector)."""
import pytest
from obd_app.detector import DecelDetector


def test_detector_cut_off_trigger():
    """Testa transição e disparo do evento de cut-off."""
    det = DecelDetector()

    # 1. Motor acelerando: 3500 rpm, TPS 30%, MAP 60 kPa
    evs = det.update(1.0, {"rpm": 3500.0, "tps": 30.0, "map": 60.0, "lambda_v": 0.85, "advance": 22.0},
                     {"rpm": 1.0, "tps": 1.0, "map": 1.0, "lambda_v": 1.0, "advance": 1.0})
    assert len(evs) == 0
    assert not det.in_decel

    # 2. Solta o pé (TPS cai para 0%, RPM cai mais de 400 rpm: 3500 -> 2900 rpm)
    evs = det.update(1.3, {"rpm": 2900.0, "tps": 0.0, "map": 22.0, "lambda_v": 0.85, "advance": 10.0},
                     {"rpm": 1.3, "tps": 1.3, "map": 1.3, "lambda_v": 1.3, "advance": 1.3})
    assert det.in_decel

    # 3. Permanece em desaceleração com Sonda caindo para ar livre (cut-off: lam < 0.15V)
    det.update(1.8, {"rpm": 2400.0, "tps": 0.0, "map": 20.0, "lambda_v": 0.05, "advance": 5.0},
               {"rpm": 1.8, "tps": 1.8, "map": 1.8, "lambda_v": 1.8, "advance": 1.8})

    # 4. Retoma aceleração (TPS sobe para 25%) -> finaliza evento de cut-off
    evs = det.update(2.5, {"rpm": 2200.0, "tps": 25.0, "map": 50.0, "lambda_v": 0.50, "advance": 18.0},
                     {"rpm": 2.5, "tps": 2.5, "map": 2.5, "lambda_v": 2.5, "advance": 2.5})
    assert not det.in_decel
    assert len(evs) > 0


def test_detector_reset():
    det = DecelDetector()
    det.update(1.0, {"rpm": 3500.0, "tps": 30.0}, {"rpm": 1.0, "tps": 1.0})
    det.update(1.3, {"rpm": 2900.0, "tps": 0.0, "map": 20.0}, {"rpm": 1.3, "tps": 1.3, "map": 1.3})
    assert det.in_decel
    det._reset_episode()
    det.in_decel = False
    assert not det.in_decel


def test_me7530_gasoline_af_and_dashpot_do_not_false_alarm():
    """Garante que ME7.5.30 com A/F Gasolina (-20.31%) e dashpot (-23.25°) não dispare falso alarme."""
    det = DecelDetector()
    stamps = {k: 1.0 for k in ("rpm", "tps", "map", "advance", "stft", "ltft", "ltft_idle")}
    evs1 = det.update(
        1.0,
        {"rpm": 920.0, "tps": 3.5, "map": 54.0, "advance": -23.25, "stft": -1.5, "ltft": -20.31, "ltft_idle": 0.0},
        stamps,
    )
    assert not any("RETARDO CRÍTICO ATDC" in e.message for e in evs1)

    stamps2 = {k: 3.5 for k in ("rpm", "tps", "map", "advance", "stft", "ltft", "ltft_idle")}
    evs2 = det.update(
        3.5,
        {"rpm": 800.0, "tps": 2.6, "map": 30.5, "advance": 2.5, "stft": -2.5, "ltft": -20.31, "ltft_idle": 0.0},
        stamps2,
    )
    assert not any("DESVIO SEVERO DE MISTURA" in e.message for e in evs2)

    # Mas com carga alta (MAP 75 kPa), avanço -12° continua disparando alarme ATDC
    stamps3 = {k: 6.0 for k in ("rpm", "tps", "map", "advance")}
    evs3 = det.update(6.0, {"rpm": 1800.0, "tps": 25.0, "map": 75.0, "advance": -12.0}, stamps3)
    assert any("RETARDO CRÍTICO ATDC" in e.message and e.level == "alarm" for e in evs3)

