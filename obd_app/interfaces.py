"""Interfaces e protocolos abstratos da aplicação (SOLID: DIP & ISP)."""
from __future__ import annotations

from typing import Any, Callable, Dict, List, Optional, Protocol, Tuple, runtime_checkable


@runtime_checkable
class ITransport(Protocol):
    """Interface abstrata para transportes físicos (BLE, TCP, Serial, Mock)."""

    def open(self) -> None:
        ...

    def close(self) -> None:
        ...

    def write(self, data: bytes) -> None:
        ...

    def read_some(self, size: int = 4096, timeout: float = 1.0) -> bytes:
        ...

    def read_until_prompt(self, timeout: float = 2.0) -> Tuple[bytes, bool]:
        ...

    def flush_input(self) -> None:
        ...

    @property
    def name(self) -> str:
        ...

    @property
    def is_connected(self) -> bool:
        ...


@runtime_checkable
class IDataLogger(Protocol):
    """Interface abstrata para gravação de telemetria."""

    @property
    def active(self) -> bool:
        ...

    def start(self, path: str, extra: Optional[Dict[str, str]] = None) -> None:
        ...

    def add_columns(self, cols: Dict[str, str]) -> None:
        ...

    def write(self, wall_ms: float, t_rel: float, updated: str, latest: Dict[str, float], event: str = "") -> None:
        ...

    def stop(self) -> None:
        ...


@runtime_checkable
class IDetector(Protocol):
    """Interface abstrata para detecção de eventos, anomalias e cut-off."""

    @property
    def in_decel(self) -> bool:
        ...

    def update(self, t: float, latest: Dict[str, float], stamp: Dict[str, float]) -> List[Any]:
        ...

    def reset(self) -> None:
        ...


@runtime_checkable
class IVehicleStrategy(Protocol):
    """Estratégia de comunicação veicular específica (SOLID: OCP & LSP)."""

    @property
    def profile_id(self) -> str:
        ...

    @property
    def display_name(self) -> str:
        ...

    def initialize(self, elm: Any, worker: Any) -> bool:
        """Executa handshake e inicialização física com a ECU."""
        ...

    def poll_cycle(self, elm: Any, worker: Any, cycle: int, decel_mode: bool) -> int:
        """Executa um ciclo multiplexado de leitura. Retorna quantidade de respostas bem-sucedidas."""
        ...

    def read_dtcs(self, elm: Any, worker: Any) -> None:
        """Lê códigos de falha do(s) módulo(s)."""
        ...

    def clear_dtcs(self, elm: Any, worker: Any) -> None:
        """Limpa códigos de falha do(s) módulo(s)."""
        ...

    def scan_all(self, elm: Any, worker: Any) -> None:
        """Varre blocos ou DIDs suportados pela ECU."""
        ...

    def get_channels_info(self) -> Dict[str, Tuple[str, str]]:
        """Retorna metadados de canais específicos {chave: (descrição, unidade)}."""
        ...

