"""Canais matemáticos em tempo real (HP Tuners / MegaLogViewer style).

Calcula potência estimada (cv), torque estimado (kgfm), desvio de mistura Lambda (%),
pressão relativa de turbo (boost_bar e boost_psi), retardo de ignição consolidado (knock_retard_max),
saúde da bateria/alternador e computador de bordo cumulativo (litros consumidos, km percorridos, custo R$ e km/l médio).
"""
from __future__ import annotations

from typing import Any, Dict, Optional


class MathChannelsEngine:
    """Calculador de canais sintéticos derivados da telemetria OBD."""

    def __init__(
        self,
        displacement_l: float = 1.6,
        vehicle_mass_kg: float = 1050.0,
        fuel_price_brl: float = 5.89,
        injector_cc_min: float = 275.0,
        dead_time_ms: float = 0.85,
    ):
        self.displacement_l = displacement_l
        self.vehicle_mass_kg = vehicle_mass_kg
        self.fuel_price_brl = fuel_price_brl
        self.injector_cc_min = injector_cc_min
        self.dead_time_ms = dead_time_ms

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
            est = estimate_fuel_metrics(
                latest,
                displacement_l=self.displacement_l,
                injector_cc_min=self.injector_cc_min,
                dead_time_ms=self.dead_time_ms,
            )
            fuel_lph = est.get("fuel_rate_lph", 0.0)
            if "volumetric_eff" in est:
                res["volumetric_eff"] = est["volumetric_eff"]

        # 1. Integração temporal da viagem e aceleração longitudinal
        if self.last_t is not None and t > self.last_t:
            dt = t - self.last_t
            # Ignora pausas longas (>15s) de segundo plano / reconexão para não distorcer distância nem consumo
            if dt <= 15.0:
                self.trip_liters += (fuel_lph / 3600.0) * dt
                self.trip_km += (speed / 3600.0) * dt
            # Aceleração longitudinal em Gs via derivada de last_spd_ms (protegida contra ruído de quantização)
            spd_ms = speed / 3.6
            if 0.08 <= dt <= 3.5:
                accel_g = ((spd_ms - self.last_spd_ms) / dt) / 9.80665
                res["accel_g"] = round(max(-2.50, min(2.50, accel_g)), 2)
            elif dt > 3.5:
                res["accel_g"] = 0.0
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

        # 2. Desvio da Mistura Lambda Error (%) — suporta Wideband (lambda_eq) e Banda Estreita (lambda_v)
        lambda_eq = latest.get("lambda_eq")
        if lambda_eq is not None and lambda_eq > 0.1:
            res["lambda_error_pct"] = round((lambda_eq - 1.0) * 100.0, 1)
        elif lambda_v is not None and lambda_v > 0.02:
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

        # 5. Potência (cv) e Torque (kgfm) Estimados via Massa de Ar (Speed-Density)
        # Usa RPM + MAP + IAT (síncronos no mesmo frame), imune a inj_ms defasado
        # em Linha K e ao Bloco 103.5 (etanol dinâmico) travado em 100%.
        tps = latest.get("tps")
        inj_ms = latest.get("inj_ms") if "inj_ms" in latest else latest.get("inj_pulse_width")
        is_cut_off = (inj_ms is not None and inj_ms <= 0.05) or (
            tps is not None and tps <= 0.5 and rpm > 1400.0 and map_kpa < 28.0
        )
        if rpm > 600.0 and map_kpa > 20.0 and not is_cut_off:
            ethanol_pct = latest.get("flex_ethanol_pct") or latest.get("ethanol") or 27.0
            eth_ratio = min(1.0, max(0.0, ethanol_pct / 100.0))
            iat = latest.get("iat", 30.0)

            norm_map = max(0.2, map_kpa / 100.0)
            # Até ~106 kPa é pressão atmosférica ao nível do mar / ram-air em motor aspirado
            if norm_map <= 1.06:
                if rpm < 2000.0:
                    rpm_ve = 0.88 + 0.12 * (rpm / 2000.0)
                elif rpm <= 5250.0:
                    rpm_ve = max(0.84, 1.0 - 0.06 * ((rpm - 4200.0) / 1500.0)) if rpm > 4200.0 else 1.0
                else:
                    # Acima do regime de potência máxima (~5250 RPM), cabeçotes aspirados
                    # sofrem queda acentuada de enchimento volumétrico (evita inflar cv a 6000 RPM).
                    ve_at_5250 = 1.0 - 0.06 * ((5250.0 - 4200.0) / 1500.0)
                    rpm_ve = max(0.78, ve_at_5250 - 0.09 * ((rpm - 5250.0) / 750.0))
                ve = (0.72 + 0.25 * min(1.0, norm_map)) * rpm_ve
            else:
                ve = min(1.18, 0.97 + 0.08 * (norm_map - 1.0))

            t_kelvin = max(240.0, iat + 273.15)
            air_gs = (rpm * map_kpa * self.displacement_l * ve * 1000.0) / (120.0 * 287.05 * t_kelvin)

            # Energia térmica por g/s de ar (~2.96 kW/(g/s)) é quase idêntica entre gasolina e etanol
            cv_per_air_gs = 1.54 * (1.0 + 0.03 * eth_ratio)
            hp_gross = air_gs * cv_per_air_gs

            # Perdas mecânicas (FMEP) + bombeamento em vácuo (PMEP)
            fmep_kpa = 85.0 + 0.014 * rpm + max(0.0, (100.0 - map_kpa) * 0.60)
            hp_loss = (fmep_kpa * self.displacement_l * rpm / 120000.0) * 1.35962

            hp_est = max(0.0, min(900.0, hp_gross - hp_loss))
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
            self.last_battery_status = str(bat_eval["status"])
            res["battery_charging"] = 1.0 if bat_eval["is_charging"] else 0.0

        return res
