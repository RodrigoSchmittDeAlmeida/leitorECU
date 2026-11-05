"""Camada de transporte (bytes crus) para o ELM327.

* TcpTransport  - ELM327 Wi-Fi (socket TCP, ex.: 192.168.0.10:35000)
* BleTransport  - ELM327 Bluetooth Low Energy (ex.: Vgate iCar Pro BLE 4.0) via ``bleak``
* MockTransport - simulador que responde como um ELM327 + ECU (modo Demo)

Todas expõem uma API síncrona e bloqueante para uso dentro de uma QThread.
"""
from __future__ import annotations

import asyncio
import queue
import socket
import threading
import time
from typing import Optional


class TransportError(Exception):
    """Falha de comunicação (conexão perdida, timeout de conexão, etc.)."""


class Transport:
    name = "base"

    def open(self) -> None: ...
    def close(self) -> None: ...
    def write(self, data: bytes) -> None: ...

    def read_some(self, timeout: float) -> bytes:
        """Retorna os bytes disponíveis (ou b'' em caso de timeout)."""
        raise NotImplementedError

    def flush_input(self) -> None:
        while self.read_some(0.0):
            pass

    def read_until_prompt(self, timeout: float) -> tuple[bytes, bool]:
        """Lê até o prompt '>' do ELM327. Retorna (dados, prompt_recebido)."""
        buf = bytearray()
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return bytes(buf), False
            chunk = self.read_some(min(remaining, 0.25))
            if chunk:
                buf += chunk
                if b">" in chunk:
                    return bytes(buf), True


# --------------------------------------------------------------------------- TCP
class TcpTransport(Transport):
    name = "Wi-Fi"

    def __init__(self, host: str = "192.168.0.10", port: int = 35000, timeout: float = 2.0):
        self.host, self.port, self.timeout = host, port, timeout
        self._sock: Optional[socket.socket] = None
        self._leftover = bytearray()

    def open(self) -> None:
        self._leftover.clear()
        try:
            self._sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
            self._sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError as e:
            raise TransportError(f"Não foi possível conectar em {self.host}:{self.port} ({e})") from e

    def close(self) -> None:
        self._leftover.clear()
        if self._sock:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    def write(self, data: bytes) -> None:
        if not self._sock:
            raise TransportError("Socket fechado")
        try:
            self._sock.sendall(data)
        except OSError as e:
            raise TransportError(f"Erro de envio: {e}") from e

    def flush_input(self) -> None:
        self._leftover.clear()
        if not self._sock:
            return
        try:
            self._sock.setblocking(False)
            while True:
                try:
                    if not self._sock.recv(4096):
                        break
                except (BlockingIOError, socket.timeout):
                    break
        except OSError:
            pass
        finally:
            try:
                self._sock.settimeout(self.timeout)
            except OSError:
                pass

    def read_some(self, timeout: float) -> bytes:
        if self._leftover:
            data = bytes(self._leftover)
            self._leftover.clear()
            return data
        if not self._sock:
            raise TransportError("Socket fechado")
        if timeout <= 0:
            try:
                self._sock.setblocking(False)
                data = self._sock.recv(4096)
            except (BlockingIOError, socket.timeout):
                return b""
            except OSError as e:
                raise TransportError(f"Erro de leitura: {e}") from e
            finally:
                try:
                    self._sock.settimeout(self.timeout)
                except OSError:
                    pass
        else:
            try:
                self._sock.settimeout(timeout)
                data = self._sock.recv(4096)
            except (socket.timeout, BlockingIOError):
                return b""
            except OSError as e:
                raise TransportError(f"Erro de leitura: {e}") from e
        if data == b"":
            raise TransportError("Conexão encerrada pelo adaptador")
        return data


# --------------------------------------------------------------------------- BLE
# Pares (serviço, característica notify/RX, característica write/TX) conhecidos
KNOWN_BLE_UUIDS = [
    # Vgate iCar Pro BLE 4.0 / vLinker ("IOS-Vlink", "Android-Vlink")
    ("e7810a71-73ae-499d-8c15-faa9aef0c3f2",
     "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f",
     "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"),
    # Vgate iCar Pro BLE 4.0 (serviço secundário 18F0 presente em vários lotes)
    ("000018f0-0000-1000-8000-00805f9b34fb",
     "00002af0-0000-1000-8000-00805f9b34fb",
     "00002af1-0000-1000-8000-00805f9b34fb"),
    # Clones ELM327 BLE genéricos (FFF0: RX=FFF1/TX=FFF2 ou vice-versa)
    ("0000fff0-0000-1000-8000-00805f9b34fb",
     "0000fff1-0000-1000-8000-00805f9b34fb",
     "0000fff2-0000-1000-8000-00805f9b34fb"),
    ("0000fff0-0000-1000-8000-00805f9b34fb",
     "0000fff2-0000-1000-8000-00805f9b34fb",
     "0000fff1-0000-1000-8000-00805f9b34fb"),
    ("0000ffe0-0000-1000-8000-00805f9b34fb",
     "0000ffe1-0000-1000-8000-00805f9b34fb",
     "0000ffe1-0000-1000-8000-00805f9b34fb"),
    # Nordic UART
    ("6e400001-b5a3-f393-e0a9-e50e24dcca9e",
     "6e400003-b5a3-f393-e0a9-e50e24dcca9e",
     "6e400002-b5a3-f393-e0a9-e50e24dcca9e"),
]
_STD_SERVICES = ("00001800-", "00001801-", "0000180a-", "0000180f-")


class BleTransport(Transport):
    name = "BLE"

    def __init__(self, address: str, timeout: float = 2.0, log=None):
        self.address = address
        self.timeout = timeout
        self._log = log or (lambda msg: None)
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._thread: Optional[threading.Thread] = None
        self._client = None
        self._rx_char = None
        self._tx_char = None
        self._tx_response = False
        self._chunk = 20
        self._rx: "queue.Queue[bytes]" = queue.Queue()
        self._connected = False

    # -- infraestrutura asyncio em thread própria
    def _run(self, coro, timeout: float):
        assert self._loop is not None
        fut = asyncio.run_coroutine_threadsafe(coro, self._loop)
        try:
            return fut.result(timeout)
        except TimeoutError as e:
            fut.cancel()
            raise TransportError("Timeout na operação BLE") from e

    def open(self) -> None:
        try:
            import bleak  # noqa: F401
        except ImportError as e:
            raise TransportError("Biblioteca 'bleak' não instalada (pip install bleak)") from e
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._loop.run_forever, name="ble-loop", daemon=True)
        self._thread.start()
        try:
            self._run(self._connect(), timeout=30)
        except TransportError:
            self.close()
            raise
        except Exception as e:  # erros do bleak / WinRT
            self.close()
            raise TransportError(f"Falha BLE: {e}") from e

    async def _connect(self):
        from bleak import BleakClient

        self._client = BleakClient(self.address, disconnected_callback=self._on_disconnect)
        await self._client.connect(timeout=20.0)
        self._connected = True

        # Aguarda a enumeração dos serviços GATT no Windows WinRT se necessário
        for _ in range(20):
            if self._client.services:
                break
            await asyncio.sleep(0.1)

        rx, tx = self._pick_characteristics()
        if rx is None or tx is None:
            raise TransportError("Não encontrei características BLE de UART (notify/write) no adaptador")
        self._rx_char, self._tx_char = rx, tx
        self._tx_response = "write-without-response" not in tx.properties
        try:
            mtu = int(getattr(self._client, "mtu_size", 23) or 23)
        except Exception:
            mtu = 23
        self._chunk = max(20, min(mtu - 3, 180))
        self._log(f"BLE: RX={rx.uuid} TX={tx.uuid} (write {'com' if self._tx_response else 'sem'} resposta, MTU={mtu})")
        await self._client.start_notify(rx, self._on_notify)

    def _pick_characteristics(self):
        services = self._client.services
        for svc_uuid, rx_uuid, tx_uuid in KNOWN_BLE_UUIDS:
            svc = services.get_service(svc_uuid)
            if svc is None:
                continue
            rx = svc.get_characteristic(rx_uuid)
            tx = svc.get_characteristic(tx_uuid)
            if (rx is not None and tx is not None
                    and ({"notify", "indicate"} & set(rx.properties))
                    and ({"write", "write-without-response"} & set(tx.properties))):
                return rx, tx
        # Busca genérica: serviço não padrão com notify + write
        for svc in services:
            if str(svc.uuid).lower().startswith(_STD_SERVICES):
                continue
            rx = next((c for c in svc.characteristics if {"notify", "indicate"} & set(c.properties)), None)
            tx = next((c for c in svc.characteristics
                       if {"write", "write-without-response"} & set(c.properties)), None)
            if rx is not None and tx is not None:
                return rx, tx
        return None, None

    def _on_notify(self, _char, data: bytearray) -> None:
        self._rx.put(bytes(data))

    def _on_disconnect(self, _client) -> None:
        self._connected = False

    def close(self) -> None:
        if self._loop is None:
            return
        if self._client is not None:
            async def _shutdown():
                try:
                    if self._client.is_connected:
                        try:
                            await self._client.stop_notify(self._rx_char)
                        except Exception:
                            pass
                        await self._client.disconnect()
                except Exception:
                    pass
            try:
                self._run(_shutdown(), timeout=8)
            except Exception:
                pass
        self._loop.call_soon_threadsafe(self._loop.stop)
        if self._thread:
            self._thread.join(timeout=3)
        self._loop = None
        self._client = None
        self._connected = False

    def write(self, data: bytes) -> None:
        if not self._connected or self._client is None:
            raise TransportError("Adaptador BLE desconectado")
        for i in range(0, len(data), self._chunk):
            chunk = data[i:i + self._chunk]
            try:
                self._run(self._client.write_gatt_char(self._tx_char, chunk, response=self._tx_response), 5)
            except TransportError:
                raise
            except Exception:
                # Tenta alternar entre write com/sem resposta antes de falhar
                try:
                    self._tx_response = not self._tx_response
                    self._run(self._client.write_gatt_char(self._tx_char, chunk, response=self._tx_response), 5)
                except Exception as e:
                    raise TransportError(f"Erro de escrita BLE: {e}") from e

    def read_some(self, timeout: float) -> bytes:
        if not self._connected and self._rx.empty():
            raise TransportError("Adaptador BLE desconectado")
        try:
            if timeout <= 0:
                return self._rx.get_nowait()
            return self._rx.get(timeout=timeout)
        except queue.Empty:
            return b""


# --------------------------------------------------------------------------- MOCK
class MockTransport(Transport):
    """Simula um ELM327 conectado a um Gol G5 (latência típica da linha K)."""

    name = "Demo"

    def __init__(self, kline_latency: float = 0.085):
        from .mock_engine import MockEngine

        self.engine = MockEngine()
        self.kline_latency = kline_latency
        self._pending = b""
        self._ready_at = 0.0
        self._open = False

    def open(self) -> None:
        self._open = True

    def close(self) -> None:
        self._open = False

    def write(self, data: bytes) -> None:
        if not self._open:
            raise TransportError("Mock fechado")
        cmd = data.decode("ascii", "ignore").strip().upper().replace(" ", "")
        resp, latency = self.engine.respond(cmd, self.kline_latency)
        self._pending = (resp + "\r\r>").encode("ascii")
        self._ready_at = time.monotonic() + latency

    def read_some(self, timeout: float) -> bytes:
        if not self._pending:
            if timeout > 0:
                time.sleep(min(timeout, 0.05))
            return b""
        wait = self._ready_at - time.monotonic()
        if wait > 0:
            if wait > timeout:
                time.sleep(max(timeout, 0))
                return b""
            time.sleep(wait)
        data, self._pending = self._pending, b""
        return data

    def flush_input(self) -> None:
        self._pending = b""
