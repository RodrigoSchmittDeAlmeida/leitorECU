"""Canais matemáticos em tempo real (HP Tuners / MegaLogViewer style).

Calcula potência estimada (cv), torque estimado (kgfm), desvio de mistura Lambda (%)
e computador de bordo cumulativo (litros consumidos, km percorridos, custo R$ e km/l médio).
"""
from __future__ import annotations

from typing import Dict, Optional


class MathChannelsEngine:
    """Calculador de canais sintéticos derivados da telemetria OBD."""

    def __init__(self, displacement_l: float = 1.6, vehicle_mass_kg: float = 1050.0, fuel_price_brl: float = 5.89):
        self.displacement_l = displacement_l
        self.vehicle_mass_kg = vehicle_mass_kg
        self.fuel_price_brl = fuel_price_brl

        # Integradores de viagem
        self.trip_liters: float = 0.0
        self.trip_km: float = 0.0
        self.last_t: Optional[float] = None
        self.last_spd_ms: float = 0.0

    def reset_trip(self) -> None:
        """Zera os acumuladores de viagem."""
        self.trip_liters = 0.0
        self.trip_km = 0.0
        self.last_t = None
        self.last_spd_ms = 0.0

    def compute(self, t: float, latest: Dict[str, float]) -> Dict[str, float]:
        """Calcula canais adicionais com base na amostra recebida."""
        res: Dict[str, float] = {}

        rpm = latest.get("rpm", 0.0)
        speed = latest.get("speed", 0.0)
        fuel_lph = latest.get("fuel_rate_lph") or latest.get("fuel_flow_lph") or 0.0
        lambda_v = latest.get("lambda_v")
        map_kpa = latest.get("map", 0.0)

        # Se a ECU não tem PID de consumo (015E), calcula via Speed-Density
        if fuel_lph <= 0.0 and rpm > 600.0 and map_kpa > 20.0:
            from .fuel_estimator import estimate_fuel_metrics
            est = estimate_fuel_metrics(latest, displacement_l=self.displacement_l)
            fuel_lph = est.get("fuel_rate_lph", 0.0)
            if "volumetric_eff" in est:
                res["volumetric_eff"] = est["volumetric_eff"]

        # 1. Integração temporal da viagem
        if self.last_t is not None and t > self.last_t:
            dt = t - self.last_t
            # Litros consumidos
            self.trip_liters += (fuel_lph / 3600.0) * dt
            # Quilômetros percorridos
            self.trip_km += (speed / 3600.0) * dt

        self.last_t = t

        # Métricas de Viagem
        res["trip_liters"] = round(self.trip_liters, 3)
        res["trip_fuel_liters"] = res["trip_liters"]
        res["trip_km"] = round(self.trip_km, 2)
        res["trip_cost_brl"] = round(self.trip_liters * self.fuel_price_brl, 2)

        if self.trip_liters > 0.01 and self.trip_km > 0.02:
            res["trip_avg_kml"] = round(min(99.9, self.trip_km / self.trip_liters), 1)
        else:
            res["trip_avg_kml"] = 0.0

        # 2. Desvio da Mistura Lambda Error (%)
        if lambda_v is not None and lambda_v > 0.02:
            # Em banda estreita, 0.450 V = estequiométrico (λ = 1.00)
            # Acima de 0.45 V = rica (desvio negativo de ar), abaixo = pobre
            lambda_est = 1.0 - (lambda_v - 0.45) * 0.35
            res["lambda_error_pct"] = round((lambda_est - 1.0) * 100.0, 1)

        # 3. Potência (cv) e Torque (kgfm) Estimados
        # Estimativa física baseada na queima do fluxo de ar/combustível e carga
        if rpm > 600.0 and map_kpa > 20.0:
            # Vazão mássica de combustível em g/s
            fuel_density = 750.0  # g/L
            fuel_gs = (fuel_lph * fuel_density) / 3600.0
            # Poder calorífico da queima e eficiência térmica de ~30%
            # Cada 1 g/s de gasolina com rendimento térmico do motor EA111 / Sigma gera ~14 a 16 cv no virabrequim
            hp_est = fuel_gs * 15.2
            # Limitadores de plausibilidade física
            hp_est = max(0.0, min(220.0, hp_est))
            torque_kgfm = (hp_est * 716.2) / rpm if rpm > 0 else 0.0

            res["power_hp"] = round(hp_est, 1)
            res["torque_kgfm"] = round(torque_kgfm, 1)
        else:
            res["power_hp"] = 0.0
            res["torque_kgfm"] = 0.0

        return res
