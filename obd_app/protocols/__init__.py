"""Registro central de estratégias veiculares (SOLID: OCP & Factory Pattern)."""
from __future__ import annotations

from typing import Dict, Type

from ..interfaces import IVehicleStrategy
from .base import BaseVehicleStrategy
from .ford import FordHsCanStrategy
from .generic import GenericObdStrategy
from .kw1281 import Kw1281Strategy, PROFILE_KW1281
from .vag import VagKwpStrategy
from .autodiscovery import UniversalAutoDiscovery

PROFILE_VW_GOL = "vw_gol_me75"
PROFILE_FORD_KA = "ford_ka_2016_sigma"
PROFILE_GENERIC = "generic_obd"

VEHICLE_STRATEGIES: Dict[str, Type[BaseVehicleStrategy]] = {
    PROFILE_VW_GOL: VagKwpStrategy,
    PROFILE_FORD_KA: FordHsCanStrategy,
    PROFILE_GENERIC: GenericObdStrategy,
    PROFILE_KW1281: Kw1281Strategy,
}


def get_vehicle_strategy(profile_id: str) -> BaseVehicleStrategy:
    """Retorna uma nova instância da estratégia correspondente ao ID do perfil."""
    strategy_cls = VEHICLE_STRATEGIES.get(profile_id, GenericObdStrategy)
    return strategy_cls()

