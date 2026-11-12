"""Estimador universal de consumo instantâneo (L/h, km/l) e Eficiência Volumétrica (VE%).

Funciona em qualquer central automotiva (mesmo quando o PID 015E não for suportado),
utilizando medição de tempo de injeção (quando disponível) ou o método Speed-Density
combinando RPM, MAP, IAT e teor de etanol Flex.
"""
from __future__ import annotations

from typing import Dict, Optional, Tuple


def estimate_fuel_metrics(latest: Dict[str, float], displacement_l: float = 1.6) -> Dict[str, float]:
    """Calcula 'fuel_rate_lph', 'fuel_econ_kml' e 'volumetric_eff' a partir da telemetria."""
    rpm = latest.get("rpm", 0.0)
    map_kpa = latest.get("map", 0.0)
    speed = latest.get("speed", 0.0)
    iat = latest.get("iat", 30.0)
    inj_ms = latest.get("inj_ms") or latest.get("inj_pulse_width")
    ethanol_pct = latest.get("flex_ethanol_pct") or latest.get("ethanol") or 27.0
    tps = latest.get("tps", 0.0)

    # Motor parado
    if rpm < 50.0:
        return {
            "fuel_rate_lph": 0.0,
            "fuel_econ_kml": 0.0,
            "volumetric_eff": 0.0,
        }

    # Desaceleração / Cut-Off (borboleta fechada em giro alto ou pulso zero)
    if (inj_ms is not None and inj_ms <= 0.05) or (tps <= 0.5 and rpm > 1400.0 and map_kpa < 28.0):
        return {
            "fuel_rate_lph": 0.0,
            "fuel_econ_kml": 99.9 if speed > 5.0 else 0.0,
            "volumetric_eff": 20.0,
        }

    # Densidade e estequiometria estequiométrica Flex
    eth_ratio = min(1.0, max(0.0, ethanol_pct / 100.0))
    afr_target = 14.7 * (1.0 - eth_ratio) + 9.0 * eth_ratio
    fuel_density = 740.0 * (1.0 - eth_ratio) + 789.0 * eth_ratio  # g/L

    # 1. Estimativa via Tempo de Injeção real (mais precisa)
    if inj_ms is not None and inj_ms > 0.05:
        # Vazão típica de bico injetor (195 cc/min a 3.0 bar = ~2.40 g/s de gasolina por bico)
        injector_cc_min = 195.0
        # 4 cilindros, 2 injeções por volta do virabrequim (ciclo 4 tempos)
        # injector_cc_min / 60.0 converte cc/min para cc/s por bico a 100% de duty cycle
        total_cc_s = (rpm / 60.0) * 2.0 * (inj_ms / 1000.0) * (injector_cc_min / 60.0)
        fuel_lph = (total_cc_s * 3600.0) / 1000.0
    else:
        # 2. Estimativa via Speed-Density (RPM, MAP, IAT)
        # Eficiência volumétrica empírica de motores aspirados e sobrealimentados (Turbo/SC)
        norm_map = max(0.2, map_kpa / 100.0)
        if norm_map <= 1.0:
            ve = 0.75 + 0.15 * norm_map
        else:
            # Em motores turbo, o VE em relação ao deslocamento estático pode superar 100%
            ve = min(1.20, 0.90 + 0.10 * (norm_map - 1.0))
        t_kelvin = max(240.0, iat + 273.15)
        # Massa de ar em g/s = (RPM * MAP * Vd * VE * 1000) / (120 * R * T)
        air_mass_gs = (rpm * map_kpa * displacement_l * ve * 1000.0) / (120.0 * 287.05 * t_kelvin)
        fuel_mass_gs = air_mass_gs / afr_target
        fuel_lph = (fuel_mass_gs * 3600.0) / fuel_density

    fuel_lph = max(0.0, fuel_lph)

    # Volumetric Efficiency aproximada (permite até 135% em regimes sobrealimentados)
    ve_pct = min(135.0, max(15.0, (map_kpa / 100.0) * 88.0))

    metrics: Dict[str, float] = {
        "fuel_rate_lph": round(fuel_lph, 2),
        "volumetric_eff": round(ve_pct, 1),
    }

    # Economia de combustível em km/l - sempre presente de forma consistente
    if speed >= 3.0 and fuel_lph > 0.05:
        metrics["fuel_econ_kml"] = round(min(99.9, speed / fuel_lph), 1)
    else:
        metrics["fuel_econ_kml"] = 0.0

    return metrics


class FuelConsumptionEstimator:
    """Calculador orientado a objetos para estimativa de consumo instantâneo."""

    def __init__(self, displacement_l: float = 1.6):
        self.displacement_l = displacement_l

    def estimate_instant_consumption(
        self,
        rpm: float,
        map_kpa: float,
        iat_c: float = 30.0,
        speed_kmh: float = 0.0,
        inj_ms: Optional[float] = None,
        ethanol_pct: float = 27.0,
        tps: float = 0.0,
    ) -> Tuple[float, float, float]:
        """Retorna (fuel_rate_lph, fuel_econ_kml, volumetric_eff)."""
        sample = {
            "rpm": rpm,
            "map": map_kpa,
            "iat": iat_c,
            "speed": speed_kmh,
            "flex_ethanol_pct": ethanol_pct,
            "tps": tps,
        }
        if inj_ms is not None:
            sample["inj_ms"] = inj_ms
        res = estimate_fuel_metrics(sample, self.displacement_l)
        return (
            res.get("fuel_rate_lph", 0.0),
            res.get("fuel_econ_kml", 0.0),
            res.get("volumetric_eff", 0.0),
        )

