"""Testes unitários para o módulo Ford HS-CAN (obd_app.ford)."""
import pytest
from obd_app.ford import (FORD_CHANNELS_INFO, FORD_DIDS, FORD_MODULES,
                          _dec_abs_dynamics, _dec_abs_wheels,
                          _dec_bcm_accessories, _dec_bcm_doors,
                          _dec_bcm_lighting, _dec_bcm_voltage,
                          _dec_ipc_dashboard, _dec_ipc_odometer, _dec_pcm_ac,
                          _dec_pcm_cht, _dec_pcm_fan, _dec_pcm_flex,
                          _dec_pcm_injection, _dec_pcm_pedal,
                          _dec_pscm_steering)


def test_ford_modules_defined():
    """Garante que todos os módulos do Ka+ estão mapeados com endereços CAN corretos."""
    assert "pcm" in FORD_MODULES and FORD_MODULES["pcm"].tx_id == "7E0"
    assert "bcm" in FORD_MODULES and FORD_MODULES["bcm"].tx_id == "726"
    assert "abs" in FORD_MODULES and FORD_MODULES["abs"].tx_id == "760"
    assert "ipc" in FORD_MODULES and FORD_MODULES["ipc"].tx_id == "720"
    assert "pscm" in FORD_MODULES and FORD_MODULES["pscm"].tx_id == "730"
    assert "rcm" in FORD_MODULES and FORD_MODULES["rcm"].tx_id == "737"


def test_bcm_doors_decoder():
    """Testa status de portas e porta-malas do Ka+ Sedan."""
    # Byte 0: bit 0 (DE), bit 4 (Porta-malas)
    d = bytes([0b00010001, 0x01])  # DE aberta, porta-malas aberto, travado
    res = _dec_bcm_doors(d)
    assert res["door_fl"] == 1.0
    assert res["door_fr"] == 0.0
    assert res["door_trunk"] == 1.0
    assert res["central_lock"] == 1.0


def test_abs_wheels_decoder():
    """Testa leitura individual das 4 rodas do Ka+."""
    # Cada roda = 2 bytes (big endian) * 0.01 km/h
    # 50 km/h = 5000 = 0x1388
    d = bytes([0x13, 0x88, 0x13, 0x88, 0x13, 0x88, 0x13, 0x88])
    res = _dec_abs_wheels(d)
    assert res["wheel_speed_fl"] == 50.0
    assert res["wheel_speed_fr"] == 50.0
    assert res["wheel_speed_rl"] == 50.0
    assert res["wheel_speed_rr"] == 50.0


def test_pcm_sigma_sensors():
    """Testa sensores específicos do motor Sigma 1.5 DOHC (comandos fixos, sem VVT)."""
    # CHT: ((A*256)+B)/10 - 40 °C
    # 90 °C -> (90+40)*10 = 1300 = 0x0514
    res_cht = _dec_pcm_cht(bytes([0x05, 0x14]))
    assert res_cht["cht_temp"] == 90.0

    # Pedal APP: A * 100 / 255
    res_pedal = _dec_pcm_pedal(bytes([128]))
    assert pytest.approx(res_pedal["app_pedal_pct"], abs=0.5) == 50.19

    # Fan duty cycle: A * 100 / 255
    res_fan = _dec_pcm_fan(bytes([255]))
    assert res_fan["fan_duty_pct"] == 100.0

    # Tempo de injeção: ((A*256)+B)/1000 ms
    # 3.5 ms = 3500 = 0x0DAC
    res_inj = _dec_pcm_injection(bytes([0x0D, 0xAC]))
    assert res_inj["inj_pulse_width"] == 3.5

    # Etanol flex virtual: A %
    res_flex = _dec_pcm_flex(bytes([85]))
    assert res_flex["flex_ethanol_pct"] == 85.0


def test_pscm_epas_steering():
    """Testa decodificador da direção elétrica progressiva EPAS."""
    # Ângulo: 15.0° = 150 = 0x0096
    # Torque: 1.50 Nm = 150 = 0x0096
    # Corrente: 4.0 A -> 4.0 / 0.5 = 8 = 0x08
    d = bytes([0x00, 0x96, 0x00, 0x96, 0x08])
    res = _dec_pscm_steering(d)
    assert res["steering_wheel_angle"] == 15.0
    assert res["steering_driver_torque"] == 1.50
    assert res["steering_motor_current"] == 4.0
