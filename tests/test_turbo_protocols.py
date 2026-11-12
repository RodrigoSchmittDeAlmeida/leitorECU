"""Testes abrangentes de auditoria e telemetria para motores Turbo e novos protocolos."""
import pytest
from obd_app.elm327 import ELM327, ElmResponse, classify, extract_payload
from obd_app.pids import (
    CHANNELS, DYNAMIC_INFO, PIDS, _dec_lambda_wb_v, _dec_lambda_wb_i,
    _dec_vag_group20, _dec_vag_group114, _dec_vag_group115, _dec_vag_group118,
    _dec_pid_6e, _dec_pid_6f, _dec_pid_70, _dec_pid_77, decode_vag_cell
)
from obd_app.vag import is_negative, KNOWN_LABELS, channel_label
from obd_app.ford import (
    FORD_DIDS, FORD_CHANNELS_INFO, _dec_pcm_boost_target, _dec_pcm_wastegate,
    _dec_pcm_cac_temp, _dec_pcm_fuel_rail, _dec_pcm_turbo_inlet
)
from obd_app.protocols.ford import FordHsCanStrategy
from obd_app.protocols.vag import VagKwpStrategy
from obd_app.protocols.kw1281 import Kw1281Strategy
from obd_app.protocols.autodiscovery import UniversalAutoDiscovery
from obd_app.ecu_fingerprints import identify_ecu


class DummyWorker:
    """Mock worker para captura de sinais."""
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


# ---------------------------------------------------------------------------
# 1. ELM327: Mode 22 Multi-frame e Negative Response Code (NRC 7F)
# ---------------------------------------------------------------------------
def test_elm327_nrc_classification():
    """Garante que respostas negativas '7F <sid> <nrc>' são classificadas como não-ok."""
    # KWP2000 negativo: 7F 21 11 (serviço 21 não suportado)
    r1 = ElmResponse("2121", lines=["7F 21 11"])
    err1 = classify(r1.lines, prompt=True)
    assert err1 is not None
    assert "NEGATIVE RESPONSE" in err1
    assert "21" in err1 and "11" in err1

    # UDS negativo: 7F 22 31 (DID 22 fora da faixa)
    r2 = ElmResponse("22404C", lines=["7F 22 31"])
    err2 = classify(r2.lines, prompt=True)
    assert err2 is not None
    assert "NEGATIVE RESPONSE" in err2
    assert "22" in err2 and "31" in err2

    # Resposta positiva normal: 41 00
    err_pos = classify(["41 00 BE 3F A8 13"], prompt=True)
    assert err_pos is None


def test_elm327_extract_payload_mode22_multiframe():
    """Garante que cabeçalhos UDS Modo 22 de 6 caracteres (62 XX YY) não sofrem corrupção."""
    # Header: 62404C (6 caracteres). Se cortasse 4 caracteres (6240), '4C' vazaria no payload!
    lines = [
        "0: 62 40 4C 01 02",
        "1: 03 04 05 06 07",
    ]
    resp = ElmResponse("22404C", lines=lines)
    payload = extract_payload(resp, mode=0x22, pid=0x404C, nbytes=7)
    assert payload is not None
    assert payload == bytes([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])


# ---------------------------------------------------------------------------
# 2. PIDs Modo 01 Turbo, GDI e Sondas Wideband
# ---------------------------------------------------------------------------
def test_wideband_lambda_independence_and_voltage_bounds():
    """Garante que lambda_eq é sempre emitido e lambda_v apenas com tensão válida em Volts."""
    # 0124 com tensão válida: AB = 32768 (lambda = 1.000), CD = 8192 (1.000 V)
    d_v = bytes([0x80, 0x00, 0x20, 0x00])
    res_v = _dec_lambda_wb_v(d_v)
    assert pytest.approx(res_v["lambda_eq"], abs=0.001) == 1.000
    assert "lambda_v" in res_v
    assert pytest.approx(res_v["lambda_v"], abs=0.001) == 1.000

    # 0124 com tensão fora da faixa analógica (v = 0.000 V): apenas lambda_eq
    d_v_low = bytes([0x80, 0x00, 0x00, 0x00])
    res_v_low = _dec_lambda_wb_v(d_v_low)
    assert pytest.approx(res_v_low["lambda_eq"], abs=0.001) == 1.000
    assert "lambda_v" not in res_v_low

    # 0134 (corrente): deve emitir lambda_eq e JAMAIS jogar eq dentro de lambda_v
    d_i = bytes([0x80, 0x00, 0x80, 0x00])
    res_i = _dec_lambda_wb_i(d_i)
    assert pytest.approx(res_i["lambda_eq"], abs=0.001) == 1.000
    assert "lambda_v" not in res_i


def test_mode01_turbo_pids():
    """Testa fórmulas dos novos PIDs turbo SAE J1979: 0x22, 0x23, 0x6E, 0x6F, 0x70, 0x77."""
    # PID 0x22: Pressão relativa flauta (((A*256)+B)*0.079)/100.0 bar
    # A=10, B=0 -> 2560 * 0.079 / 100.0 = 2.0224 bar
    res_22 = PIDS[0x22].decode(bytes([10, 0]))
    assert pytest.approx(res_22["fuel_rail_bar"], abs=0.01) == 2.02

    # PID 0x23: Pressão flauta GDI (((A*256)+B)*10.0)/100.0 bar
    # 150 bar -> 1500 = 0x05DC
    res_23 = PIDS[0x23].decode(bytes([0x05, 0xDC]))
    assert res_23["fuel_rail_bar"] == 150.0

    # PID 0x6E: Compressor Inlet Pressure (5 bytes SAE J1979)
    # Byte 0 = support 0x01, Byte 1 = 101 kPa
    res_6e = _dec_pid_6e(bytes([0x01, 101, 0, 0, 0]))
    assert res_6e["turbo_inlet_kpa"] == 101.0

    # PID 0x6F: Boost Pressure Control (Target)
    # 200 kPa absoluto -> target relative ~ 0.98 bar
    # 200 / 0.03125 = 6400 = 0x1900
    res_6f = _dec_pid_6f(bytes([0x01, 0x19, 0x00]))
    assert pytest.approx(res_6f["boost_target_bar"], abs=0.02) == 0.99

    # PID 0x70: Boost Target + Boost Actual + Wastegate Duty
    # Support = 0x03 (Target + Actual)
    # Target: 200 kPa = 0x1900, Actual: 220 kPa = 7040 = 0x1B80, WG: 60% = 153
    d_70 = bytes([0x03, 0x19, 0x00, 0x1B, 0x80, 0x00, 0x00, 153, 0x00, 153])
    res_70 = _dec_pid_70(d_70)
    assert pytest.approx(res_70["boost_target_bar"], abs=0.02) == 0.99
    assert pytest.approx(res_70["boost_bar"], abs=0.02) == 1.19
    assert pytest.approx(res_70["wastegate_pct"], abs=1.0) == 60.0

    # PID 0x77: Charge Air Cooler Temp (CAC °C)
    # Support mask 0x01 + 75 -> 75 - 40 = 35 °C
    res_77 = _dec_pid_77(bytes([0x01, 75, 0]))
    assert res_77["cac_temp_c"] == 35.0


# ---------------------------------------------------------------------------
# 3. VAG KWP2000 Turbo Blocks (114, 115, 118) e Knock Retard Máximo
# ---------------------------------------------------------------------------
def test_vag_turbo_blocks_and_knock_max():
    """Testa decodificação dos blocos VAG 020 (Knock Retard Máx), 114, 115 e 118."""
    # Bloco 020: Retardo detonação cilindros 1..4 (°KW)
    # C1=-3.0°, C2=0.0°, C3=-6.0°, C4=-1.5° (Fórmula 0x1E ou 0x22: (b-128)*0.01*a)
    # Para simplicidade de teste, simulamos bytes decodificados via fórmula 0x22: a=100
    # b = 128 - 3 = 125 (-3.0°), 128 (0.0°), 128 - 6 = 122 (-6.0°), 128 - 1 = 127 (-1.0°)
    d_20 = bytes([
        0x22, 100, 125,  # C1: -3.0°
        0x22, 100, 128,  # C2: 0.0°
        0x22, 100, 122,  # C3: -6.0°
        0x22, 100, 127,  # C4: -1.0°
    ])
    res_20 = _dec_vag_group20(d_20)
    assert res_20["knock_ret_c1"] == -3.0
    assert res_20["knock_ret_c3"] == -6.0
    assert res_20["knock_retard_max"] == 6.0

    # Bloco 114: Carga e Wastegate %
    # C1=Spec Load %, C2=Corr Load %, C3=Actual Load %, C4=Wastegate %
    # Fórmula 0x02: 0.002 * a * b. Com a=200, b=175 -> 70.0 %
    # Com a=250, b=150 -> 75.0 %
    d_114 = bytes([
        0x02, 100, 250,  # C1: 50%
        0x02, 100, 250,  # C2: 50%
        0x02, 200, 175,  # C3: 70% Actual Load
        0x02, 250, 150,  # C4: 75% N75 Wastegate
    ])
    res_114 = _dec_vag_group114(d_114)
    assert res_114["load"] == 70.0
    assert res_114["wastegate_pct"] == 75.0

    # Bloco 115: RPM, Load %, Boost Spec mbar, Boost Actual mbar
    # C1: RPM (form 0x01: 0.2*a*b) -> a=100, b=150 -> 3000 RPM
    # C2: Load % (form 0x02: 0.002*200*200) -> 80%
    # C3: Boost Spec mbar (form 0x12: 0.04*a*b) -> a=250, b=200 -> 2000 mbar (200 kPa abs -> ~0.99 bar rel)
    # C4: Boost Actual mbar (form 0x12) -> a=250, b=210 -> 2100 mbar (210 kPa abs -> ~1.09 bar rel)
    d_115 = bytes([
        0x01, 100, 150,  # C1: 3000 rpm
        0x02, 200, 200,  # C2: 80% load
        0x12, 250, 200,  # C3: 2000 mbar
        0x12, 250, 210,  # C4: 2100 mbar
    ])
    res_115 = _dec_vag_group115(d_115)
    assert res_115["rpm"] == 3000.0
    assert res_115["load"] == 80.0
    assert res_115["boost_target_abs_kpa"] == 200.0
    assert pytest.approx(res_115["boost_target_bar"], abs=0.01) == 0.99
    assert res_115["map"] == 210.0
    assert pytest.approx(res_115["boost_bar"], abs=0.01) == 1.09
    assert pytest.approx(res_115["boost_psi"], abs=0.2) == 15.8

    # Bloco 118: RPM, IAT, N75 %, Boost Actual
    # C1: RPM (form 0x01) -> a=100, b=150 -> 3000 RPM
    # C2: IAT (form 0x05: a*(b-100)*0.1) -> a=10, b=135 -> 35 °C
    # C3: N75 % (form 0x02: 0.002*250*130) -> 65%
    # C4: Boost Actual (form 0x12: 0.04*250*210) -> 2100 mbar
    d_118 = bytes([
        0x01, 100, 150,
        0x05, 10, 135,
        0x02, 250, 130,
        0x12, 250, 210,
    ])
    res_118 = _dec_vag_group118(d_118)
    assert res_118["rpm"] == 3000.0
    assert res_118["iat"] == 35.0
    assert res_118["wastegate_pct"] == 65.0
    assert res_118["map"] == 210.0


def test_vag_known_labels_turbo():
    """Garante que KNOWN_LABELS contém descrições humanas para 114, 115 e 118."""
    assert (114, 4) in KNOWN_LABELS
    assert "N75" in KNOWN_LABELS[(114, 4)] or "Wastegate" in KNOWN_LABELS[(114, 4)]
    assert (115, 3) in KNOWN_LABELS
    assert "turbo" in KNOWN_LABELS[(115, 3)].lower()
    assert (118, 3) in KNOWN_LABELS


# ---------------------------------------------------------------------------
# 4. Ford EcoBoost DIDs
# ---------------------------------------------------------------------------
def test_ford_ecoboost_dids():
    """Testa decodificadores UDS Ford EcoBoost (Boost Target, Wastegate, CAC, Fuel Rail, TIP)."""
    # 220462: Boost Target (ex: 200 kPa abs -> ~0.99 bar rel)
    res_tgt = _dec_pcm_boost_target(bytes([0x00, 200]))
    assert pytest.approx(res_tgt["boost_target_bar"], abs=0.02) == 0.99

    # 220333: Wastegate % (ex: 65%)
    res_wg = _dec_pcm_wastegate(bytes([166]))  # 166 * 100 / 255 = 65.1%
    assert pytest.approx(res_wg["wastegate_pct"], abs=0.5) == 65.1

    # 2203A0: CAC Temp (ex: 40 °C -> 40 + 40 = 80 = 0x50)
    res_cac = _dec_pcm_cac_temp(bytes([80]))
    assert res_cac["cac_temp_c"] == 40.0

    # 2203E7: Flauta GDI (ex: 150 bar)
    res_rail = _dec_pcm_fuel_rail(bytes([0x00, 150]))
    assert res_rail["fuel_rail_bar"] == 150.0

    # 2204FE: Turbo Inlet / TIP (ex: 102 kPa)
    res_tip = _dec_pcm_turbo_inlet(bytes([0x00, 102]))
    assert res_tip["turbo_inlet_kpa"] == 102.0


def test_ford_scan_all_uses_did_failures():
    """Garante que FordHsCanStrategy.scan_all não sofre crash por _module_failures."""
    strat = FordHsCanStrategy()
    worker = DummyWorker()

    class MockElm:
        def command(self, cmd, timeout=None):
            if cmd.startswith("22"):
                return ElmResponse(cmd, lines=["NO DATA"], error="NO DATA")
            return ElmResponse(cmd, lines=["OK"])

    # Chama scan_all — anteriormente quebrava com AttributeError em _module_failures.clear()
    strat.scan_all(MockElm(), worker)
    assert len(worker.emitted_logs) > 0


# ---------------------------------------------------------------------------
# 5. KW1281: DTC Signal Corrigido
# ---------------------------------------------------------------------------
def test_kw1281_dtc_signal_emission():
    """Garante que read_dtcs e clear_dtcs emitem worker.dtcs(False, 0, []) sem AttributeError."""
    strat = Kw1281Strategy()
    worker = DummyWorker()

    strat.read_dtcs(None, worker)
    assert len(worker.emitted_dtcs) == 1
    assert worker.emitted_dtcs[0] == (False, 0, [])

    strat.clear_dtcs(None, worker)
    assert len(worker.emitted_dtcs) == 2
    assert worker.emitted_dtcs[1] == (False, 0, [])


# ---------------------------------------------------------------------------
# 6. AutoDiscovery: Atualização de Filtros ATCRA por Módulo
# ---------------------------------------------------------------------------
def test_autodiscovery_atcra_filters_per_module():
    """Garante que AutoDiscovery envia ATCRA específico para cada módulo CAN secundário."""
    ad = UniversalAutoDiscovery()
    worker = DummyWorker()
    sent_cmds = []

    class MockElmDiscovery:
        def command(self, cmd, timeout=None):
            sent_cmds.append(cmd.strip())
            if cmd.startswith("0100"):
                return ElmResponse(cmd, lines=["41 00 BE 3F A8 13"])
            if cmd.startswith("224001"):
                return ElmResponse(cmd, lines=["62 40 01 0D 80"])  # BCM vivo
            if cmd.startswith("222B00"):
                return ElmResponse(cmd, lines=["62 2B 00 13 88 13 88 13 88 13 88"])  # ABS vivo
            return ElmResponse(cmd, lines=["OK"])

    strat, meta = UniversalAutoDiscovery.discover(MockElmDiscovery(), worker)
    assert strat is not None

    # Verifica se os filtros de recepção ATCRA foram configurados para os módulos
    cmd_str = " ".join(sent_cmds)
    assert "ATCRA 72E" in cmd_str
    assert "ATCRA 768" in cmd_str
    assert "ATCRA 728" in cmd_str
    assert "ATCRA 738" in cmd_str


# ---------------------------------------------------------------------------
# 7. Fingerprints: Detecção Automática de Centrais Turbo
# ---------------------------------------------------------------------------
def test_turbo_ecu_fingerprints():
    """Testa detecção inteligente de centrais turboalimentadas via identify_ecu."""
    # 1. EA888 Simos 18 (Golf GTI / Audi S3)
    meta_simos = identify_ecu(raw_id="06K907425 Simos 18", vin="9BWCA05X9CP000000", protocol_name="CAN 500k")
    assert meta_simos["is_turbo"] is True
    assert "Simos" in meta_simos["display_title"]

    # 2. Bosch MED17 (TSI / EcoBoost)
    meta_med17 = identify_ecu(raw_id="06J906026 MED17.5", protocol_name="CAN 500k")
    assert meta_med17["is_turbo"] is True

    # 3. Fiat GSE Turbo T270 (MG1CS032)
    meta_gse = identify_ecu(raw_id="MG1CS032 GSE T270", protocol_name="CAN 500k")
    assert meta_gse["is_turbo"] is True
    assert "GSE Turbo" in meta_gse["display_title"]

    # 4. GM Onix/Tracker Turbo (CSS Prime Delco E84)
    meta_gm = identify_ecu(raw_id="DELCO E84 CSS PRIME", protocol_name="CAN 500k")
    assert meta_gm["is_turbo"] is True

    # 5. Motores aspirados NÃO devem ser marcados como turbo
    meta_gol = identify_ecu(raw_id="032906032AJ ME7.5.30", protocol_name="VAG KWP2000")
    assert meta_gol["is_turbo"] is False

    meta_kombi = identify_ecu(raw_id="2379060211 MP9.0", protocol_name="VAG KW1281")
    assert meta_kombi["is_turbo"] is False

    meta_sigma = identify_ecu(raw_id="EMS2211", protocol_name="ISO 15765-4 CAN")
    assert meta_sigma["is_turbo"] is False


# ---------------------------------------------------------------------------
# 8. Isolamento de Unidades e Proteção contra Falsos Positivos em Motores Aspirados
# ---------------------------------------------------------------------------
def test_vag_groups_ignore_non_pressure_units():
    """Garante que células com °C, rpm ou % não são convertidas em pressão/boost (caso Gol G5 115)."""
    # Bloco 115 com células não-turbo (ex: Gol G5: RPM, %, °C, °C)
    d_non_turbo = bytes([
        0x01, 100, 150,  # C1: 3000 rpm
        0x02, 200, 200,  # C2: 80% load
        0x05, 10, 190,   # C3: 90 °C (NÃO é pressão!)
        0x05, 10, 195,   # C4: 95 °C (NÃO é pressão!)
    ])
    res_115 = _dec_vag_group115(d_non_turbo)
    assert res_115["rpm"] == 3000.0
    assert res_115["load"] == 80.0
    # Não pode conter map, boost_abs_kpa, boost_bar, boost_psi, boost_target_*
    assert "map" not in res_115
    assert "boost_bar" not in res_115
    assert "boost_target_bar" not in res_115
    assert "boost_abs_kpa" not in res_115

    # Bloco 118 com C4 = °C (NÃO é pressão!)
    d_118_non_turbo = bytes([
        0x01, 100, 150,  # C1: 3000 rpm
        0x05, 10, 135,   # C2: 35 °C IAT
        0x02, 250, 130,  # C3: 65% wastegate
        0x05, 10, 190,   # C4: 90 °C (NÃO é pressão!)
    ])
    res_118 = _dec_vag_group118(d_118_non_turbo)
    assert res_118["rpm"] == 3000.0
    assert res_118["iat"] == 35.0
    assert res_118["wastegate_pct"] == 65.0
    assert "map" not in res_118
    assert "boost_bar" not in res_118


def test_aspirated_gol_does_not_promote_group115_to_active_fast(monkeypatch, tmp_path):
    """Garante que a central aspirada 032906032AJ (Gol G5) NÃO promove Bloco 115 para active_fast."""
    import obd_app.vag as vag_mod
    monkeypatch.setattr(vag_mod, "CACHE_DIR", str(tmp_path))

    strat = VagKwpStrategy()
    strat.ecu_id = "032906032AJ"
    strat.vag_supported.add(115)  # Bloco 115 suportado no cache aspirado
    worker = DummyWorker()

    strat._setup_discovery(worker)
    assert 0x2173 not in strat.active_fast


def test_autodiscovery_detects_turbo_mock_engine(monkeypatch, tmp_path):
    """Garante que UniversalAutoDiscovery identifica central turbo quando o simulador está em turbo_mode."""
    import obd_app.vag as vag_mod
    from obd_app.transports import MockTransport

    monkeypatch.setattr(vag_mod, "CACHE_DIR", str(tmp_path))

    transport = MockTransport(kline_latency=0.001)
    transport.engine.turbo_mode = True
    transport.open()
    elm = ELM327(transport)
    worker = DummyWorker()

    strat, meta = UniversalAutoDiscovery.discover(elm, worker)
    assert meta["is_turbo"] is True
    assert "MED17" in meta["raw_id"] or "TSI" in meta["raw_id"]
    transport.close()
