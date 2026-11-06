"""Testes das estratégias de protocolo veicular (SOLID: OCP & LSP)."""
import pytest
from obd_app.elm327 import ELM327
from obd_app.interfaces import IVehicleStrategy
from obd_app.protocols import (PROFILE_FORD_KA, PROFILE_GENERIC,
                               PROFILE_VW_GOL, get_vehicle_strategy)
from obd_app.protocols.ford import FordHsCanStrategy
from obd_app.protocols.generic import GenericObdStrategy
from obd_app.protocols.vag import VagKwpStrategy
from obd_app.transports import MockTransport


class DummyWorker:
    """Mock worker para captura de sinais durante os testes."""
    def __init__(self):
        self._running = True
        self.emitted_samples = []
        self.emitted_status = []
        self.emitted_logs = []
        self.emitted_channels = {}
        self.emitted_dtcs = []

    class DummySignal:
        def __init__(self, target_list):
            self.target_list = target_list
        def emit(self, *args):
            self.target_list.append(args)

    @property
    def status(self):
        return self.DummySignal(self.emitted_status)

    @property
    def log(self):
        return self.DummySignal(self.emitted_logs)

    @property
    def info(self):
        return self.DummySignal([])

    @property
    def channels(self):
        class ChanSig:
            def __init__(self, outer):
                self.outer = outer
            def emit(self, d):
                self.outer.emitted_channels.update(d)
        return ChanSig(self)

    @property
    def dtcs(self):
        return self.DummySignal(self.emitted_dtcs)

    def _emit(self, vals):
        self.emitted_samples.append(vals)

    def _reinit_bus(self):
        pass


def test_strategy_factory():
    """Garante que a factory instancia as classes corretas."""
    s_vag = get_vehicle_strategy(PROFILE_VW_GOL)
    assert isinstance(s_vag, VagKwpStrategy)
    assert isinstance(s_vag, IVehicleStrategy)

    s_ford = get_vehicle_strategy(PROFILE_FORD_KA)
    assert isinstance(s_ford, FordHsCanStrategy)
    assert isinstance(s_ford, IVehicleStrategy)

    s_gen = get_vehicle_strategy(PROFILE_GENERIC)
    assert isinstance(s_gen, GenericObdStrategy)
    assert isinstance(s_gen, IVehicleStrategy)


def test_ford_strategy_polling():
    """Testa ciclo de polling da estratégia Ford Ka+ (HS-CAN 500k)."""
    transport = MockTransport(kline_latency=0.0)
    transport.open()
    elm = ELM327(transport)
    worker = DummyWorker()

    strategy = FordHsCanStrategy()
    init_ok = strategy.initialize(elm, worker)
    assert init_ok

    # Executa ciclo 0
    n = strategy.poll_cycle(elm, worker, cycle=0, decel_mode=False)
    assert n > 0
    # Verifica que amostras foram emitidas
    all_keys = set().union(*worker.emitted_samples)
    assert "rpm" in all_keys
    assert "lambda_v" in all_keys
    assert "lambda2_v" in all_keys

    transport.close()


def test_vag_strategy_polling():
    """Testa ciclo de polling da estratégia VAG KWP2000 (VW Gol G5)."""
    transport = MockTransport(kline_latency=0.0)
    transport.open()
    elm = ELM327(transport)
    worker = DummyWorker()

    strategy = VagKwpStrategy()
    init_ok = strategy.initialize(elm, worker)
    assert init_ok

    n = strategy.poll_cycle(elm, worker, cycle=0, decel_mode=False)
    assert n > 0
    all_keys = set().union(*worker.emitted_samples)
    assert "rpm" in all_keys
    assert "lambda_v" in all_keys

    transport.close()

