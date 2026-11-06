"""Classe base para estratégias veiculares (SOLID: Template Method & OCP)."""
from __future__ import annotations

import logging
from abc import ABC, abstractmethod
from typing import Any, Dict, List, Optional, Tuple

from ..interfaces import IVehicleStrategy

logger = logging.getLogger(__name__)


class BaseVehicleStrategy(ABC, IVehicleStrategy):
    """Implementação base abstrata para qualquer protocolo de veículo."""

    def __init__(self, profile_id: str, display_name: str):
        self._profile_id = profile_id
        self._display_name = display_name

    @property
    def profile_id(self) -> str:
        return self._profile_id

    @property
    def display_name(self) -> str:
        return self._display_name

    @abstractmethod
    def initialize(self, elm: Any, worker: Any) -> bool:
        """Handshake com a ECU."""
        raise NotImplementedError

    @abstractmethod
    def poll_cycle(self, elm: Any, worker: Any, cycle: int, decel_mode: bool) -> int:
        """Ciclo de leitura rápida/lenta de sensores."""
        raise NotImplementedError

    @abstractmethod
    def read_dtcs(self, elm: Any, worker: Any) -> None:
        """Leitura de códigos de falha (DTC)."""
        raise NotImplementedError

    @abstractmethod
    def clear_dtcs(self, elm: Any, worker: Any) -> None:
        """Limpeza de códigos de falha (DTC)."""
        raise NotImplementedError

    def reset_adaptation(self, elm: Any, worker: Any) -> None:
        """Reset de valores aprendidos / adaptação de combustível (default: clear_dtcs)."""
        self.clear_dtcs(elm, worker)

    def scan_all(self, elm: Any, worker: Any) -> None:
        """Varredura opcional de blocos ou DIDs (default: no-op)."""
        worker.log.emit("Varredura avançada não aplicável a este perfil.")

    def get_channels_info(self) -> Dict[str, Tuple[str, str]]:
        """Canais extras conhecidos pelo perfil."""
        return {}

