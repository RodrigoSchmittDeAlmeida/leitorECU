"""Canais matemáticos em tempo real (HP Tuners / MegaLogViewer style).

Calcula potência estimada (cv), torque estimado (kgfm), desvio de mistura Lambda (%),
pressão relativa de turbo (boost_bar e boost_psi), retardo de ignição consolidado (knock_retard_max),
saúde da bateria/alternador e computador de bordo cumulativo (litros consumidos, km percorridos, custo R$ e km/l médio).
"""
from __future__ import annotations

from typing import Any, Dict, Optional


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
        self.min_crank_volt: Optional[float] = None

    def reset_trip(self) -> None:
        """Zera os acumuladores de viagem."""
        self.trip_liters = 0.0
        self.trip_km = 0.0
        self.last_t = None
        self.last_spd_ms = 0.0
        self.min_crank_volt = None

    @staticmethod
    def evaluate_battery_health(voltage: float, rpm: float = 0.0, min_crank_volt: Optional[float] = None) -> Dict[str, Any]:
        """Avalia a saúde da bateria, queda na partida (< 9.6 V) e sistema de carga do alternador (> 13.6 V)."""
        is_charging = voltage >= 13.6 and rpm >= 600.0
        cranking_ok = True if min_crank_volt is None else (min_crank_volt >= 9.6)

        if min_crank_volt is not None and min_crank_volt < 9.6:
            status = "cranking_warning"
            msg = f"Queda excessiva na partida ({min_crank_volt:.2f} V < 9.6 V)"
        elif rpm >= 600.0:
            if voltage >= 13.6:
                status = "charging_ok"
                msg = f"Alternador operando normalmente ({voltage:.2f} V)"
            elif voltage < 12.8:
                status = "alternator_fault"
                msg = f"Tensão baixa com motor ligado ({voltage:.2f} V) — alternador deficiente"
            else:
                status = "charging_low"
                msg = f"Carga de flutuação ({voltage:.2f} V)"
        else:
            if voltage >= 12.4:
                status = "resting_ok"
                msg = f"Bateria em repouso com boa carga ({voltage:.2f} V)"
            else:
                status = "resting_low"
                msg = f"Bateria em repouso fraca ({voltage:.2f} V < 12.4 V)"

        return {
            "voltage": round(voltage, 2),
            "status": status,
            "is_charging": is_charging,
            "cranking_ok": cranking_ok,
            "min_crank_volt": round(min_crank_volt, 2) if min_crank_volt is not None else None,
            "message": msg,
        }

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

        # 1. Integração temporal da viagem e aceleração longitudinal
        if self.last_t is not None and t > self.last_t:
            dt = t - self.last_t
            # Litros consumidos
            self.trip_liters += (fuel_lph / 3600.0) * dt
            # Quilômetros percorridos
            self.trip_km += (speed / 3600.0) * dt
            # Aceleração longitudinal em Gs via derivada de last_spd_ms
            spd_ms = speed / 3.6
            if dt > 0:
                accel_g = ((spd_ms - self.last_spd_ms) / dt) / 9.80665
                res["accel_g"] = round(accel_g, 2)
            self.last_spd_ms = spd_ms
        else:
            self.last_spd_ms = speed / 3.6

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

        # 3. Telemetria de Pressão Relativa de Turbo / Sobrealimentação (Boost Bar & Boost PSI)
        if "map" in latest and latest["map"] is not None:
            baro_kpa = latest.get("baro") or 101.325
            boost_bar = (latest["map"] - baro_kpa) / 100.0
            res["boost_bar"] = round(boost_bar, 3)
            res["boost_psi"] = round(boost_bar * 14.50377, 2)

        # 4. Retardo de Ignição por Detonação Máximo (Knock Retard Max)
        if "knock_retard_max" in latest and latest["knock_retard_max"] is not None:
            res["knock_retard_max"] = round(float(latest["knock_retard_max"]), 2)
        else:
            cyl_retards = [
                float(latest[k]) for k in (
                    "knock_ret_c1", "knock_ret_c2", "knock_ret_c3", "knock_ret_c4",
                    "knock_c1", "knock_c2", "knock_c3", "knock_c4",
                    "g020_c1", "g020_c2", "g020_c3", "g020_c4"
                ) if k in latest and latest[k] is not None
            ]
            if cyl_retards:
                res["knock_retard_max"] = round(max(0.0, max(cyl_retards)), 2)

        # 5. Potência (cv) e Torque (kgfm) Estimados (sem teto artificial de 220 cv, ajustado para Flex/Turbo até 900 cv)
        if rpm > 600.0 and map_kpa > 20.0:
            ethanol_pct = latest.get("flex_ethanol_pct") or latest.get("ethanol") or 27.0
            eth_ratio = min(1.0, max(0.0, ethanol_pct / 100.0))
            # Ajuste estequiométrico e densidade pelo teor de etanol
            fuel_density = 740.0 * (1.0 - eth_ratio) + 789.0 * eth_ratio  # g/L
            # Fator térmico de conversão cv por g/s
            eff_factor = 15.2 * (1.0 - eth_ratio) + 12.0 * eth_ratio
            fuel_gs = (fuel_lph * fuel_density) / 3600.0
            hp_est = fuel_gs * eff_factor
            # Limite ampliado para comportar motores aspirados preparados, turbo e GDI de alta potência
            hp_est = max(0.0, min(900.0, hp_est))
            torque_kgfm = (hp_est * 716.2) / rpm if rpm > 0 else 0.0

            res["power_hp"] = round(hp_est, 1)
            res["torque_kgfm"] = round(torque_kgfm, 1)
        else:
            res["power_hp"] = 0.0
            res["torque_kgfm"] = 0.0

        # 6. Avaliação de Tensão da Bateria / Alternador / Queda na Partida
        volt = latest.get("battery") or latest.get("battery_v") or latest.get("ecu_volt")
        if volt is not None:
            if 50.0 <= rpm <= 500.0:
                if self.min_crank_volt is None or volt < self.min_crank_volt:
                    self.min_crank_volt = volt
            bat_eval = self.evaluate_battery_health(volt, rpm=rpm, min_crank_volt=self.min_crank_volt)
            res["battery_status"] = bat_eval["status"]
            res["battery_charging"] = 1.0 if bat_eval["is_charging"] else 0.0

        return res
