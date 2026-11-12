"""Testes para o Mapa 2D (RPM x MAP) e Replay de Datalog CSV."""
import os
import sys
import tempfile
import pytest
from PyQt6.QtWidgets import QApplication

from obd_app.datalog import CsvLogger
from obd_app.pids import CHANNELS, DYNAMIC_INFO
from obd_app.ford import FORD_CHANNELS_INFO
from obd_app.ui.map2d import (Map2DWidget, _find_bin, _color_for_value, RPM_BINS, MAP_BINS,
                             MAP_BINS_ASPIRADO, MAP_BINS_TURBO)
from obd_app.ui.main_window import MainWindow

app = QApplication.instance() or QApplication(sys.argv)


def test_map2d_binning_and_colors():
    """Testa aproximação de faixas de RPM e MAP e gradiente térmico."""
    # RPM 1380 rpm -> bin 1400 (índice 2)
    assert _find_bin(1380, RPM_BINS) == 2
    # MAP 73 kPa -> bin 70 (índice 3 em [100, 90, 80, 70, ...])
    assert _find_bin(73, MAP_BINS) == 3

    # Cor para retardo extremo (-19°) -> magenta/alerta
    bg_neg, fg_neg = _color_for_value("advance", -19.0)
    assert bg_neg.name() == "#880e4f"

    # Cor para avanço normal (24°) -> verde
    bg_pos, fg_pos = _color_for_value("advance", 24.0)
    assert bg_pos.name() == "#1b5e20"


def test_map2d_widget_accumulation():
    """Testa acúmulo de amostras e cálculo de médias na matriz."""
    widget = Map2DWidget()
    # Adiciona amostras
    widget.add_sample(1000.0, 40.0, {"advance": 12.0, "stft": 2.5, "lambda_v": 0.45})
    widget.add_sample(1000.0, 40.0, {"advance": 16.0, "stft": 3.5, "lambda_v": 0.55})

    # Verifica se a média de avanço foi calculada (14.0°)
    c = _find_bin(1000.0, RPM_BINS)
    r = _find_bin(40.0, MAP_BINS)
    coord = (r, c)
    assert widget._counts["advance"][coord] == 2
    assert widget._sums["advance"][coord] == 28.0
    item = widget.table.item(r, c)
    assert "14.0°" in item.text()

    # Limpeza
    widget.clear_data()
    assert len(widget._counts["advance"]) == 0
    assert widget.table.item(r, c).text() == "--"


def test_csv_logger_pre_registration_no_rewrite():
    """Garante que com pré-registro completo das colunas conhecidas no logger.start,
    não ocorre rewrite de arquivo durante o logging de canais dinâmicos."""
    with tempfile.TemporaryDirectory() as tmpdir:
        csv_path = os.path.join(tmpdir, "test_prereg.csv")
        logger = CsvLogger(decimal_comma=True)

        extra = {}
        for k, (label, unit) in DYNAMIC_INFO.items():
            extra[k] = f"{label} [{unit}]" if unit else label
        for k, (label, unit) in FORD_CHANNELS_INFO.items():
            extra[k] = f"{label} [{unit}]" if unit else label
        extra["g002_c3"] = "Bloco 002.3 Tempo injeção [ms]"

        logger.start(csv_path, extra=extra)

        # Escreve linhas incluindo canais dinâmicos já pré-registrados
        for i in range(10):
            sample = {
                "rpm": 850.0 + i,
                "map": 35.0,
                "g002_c3": 3.45,
                "cht_temp": 88.0,
            }
            logger.write(1000.0 + i * 100, float(i), "rpm", sample)

        logger.stop()

        with open(csv_path, "r", encoding="utf-8") as f:
            lines = f.readlines()

        assert len(lines) == 11
        header = lines[0].strip().split(";")
        assert "g002_c3" in header or "Bloco 002.3 Tempo injeção [ms]" in header
        assert "cht_temp" in header or "Temp. Cabeça Cilindro (CHT) [°C]" in header


def test_map2d_turbo_scale_and_new_metrics():
    """Garante suporte à escala Turbo de 250 kPa e novas métricas (Boost, Wastegate, Knock, Lambda wideband)."""
    assert 250 in MAP_BINS_TURBO
    widget = Map2DWidget()

    # Verifica métricas presentes
    metric_keys = [m[1] for m in widget.metrics]
    assert "boost_bar" in metric_keys
    assert "wastegate_pct" in metric_keys
    assert "knock_retard_max" in metric_keys
    assert "lambda_eq" in metric_keys

    # Mudança manual de escala para Turbo
    widget.set_scale("turbo")
    assert widget.map_bins == MAP_BINS_TURBO
    assert widget.table.rowCount() == len(MAP_BINS_TURBO)
    header_item = widget.table.verticalHeaderItem(0)
    assert header_item is not None and "250 kPa" in header_item.text()

    # Teste de gradientes térmicos das métricas turbo
    bg_boost, _ = _color_for_value("boost_bar", 1.25)
    assert bg_boost.name() == "#665914"  # Boost forte

    bg_wg, _ = _color_for_value("wastegate_pct", 75.0)
    assert bg_wg.name() == "#4c3912"

    bg_knock, _ = _color_for_value("knock_retard_max", 4.0)
    assert bg_knock.name() == "#8a1c1c"

    bg_lam, _ = _color_for_value("lambda_eq", 0.88)
    assert bg_lam.name() == "#005c51"


def test_map2d_auto_expansion_and_throttling(monkeypatch):
    """Testa auto-expansão para escala Turbo quando MAP > 105 kPa e throttling de repaint da célula."""
    widget = Map2DWidget()
    assert widget.map_bins == MAP_BINS_ASPIRADO

    # Amostra com MAP elevado (> 105 kPa) deve acionar expansão automática para escala Turbo
    widget.add_sample(3500.0, 175.0, {"advance": 19.0, "boost_bar": 0.75})
    assert widget.map_bins == MAP_BINS_TURBO
    assert widget.table.rowCount() == len(MAP_BINS_TURBO)

    # Throttling de setCurrentCell: contar chamadas
    cell_calls = 0
    orig_setCurrentCell = widget.table.setCurrentCell

    def mock_setCurrentCell(r, c):
        nonlocal cell_calls
        cell_calls += 1
        orig_setCurrentCell(r, c)

    monkeypatch.setattr(widget.table, "setCurrentCell", mock_setCurrentCell)

    # 1. Mesma célula operacional -> não deve chamar setCurrentCell novamente
    widget.add_sample(3500.0, 175.0, {"advance": 19.2, "boost_bar": 0.74})
    assert cell_calls == 0

    # 2. Célula operacional diferente -> chama setCurrentCell
    widget.add_sample(5000.0, 240.0, {"advance": 23.0, "boost_bar": 1.40})
    assert cell_calls == 1


def test_replay_with_turbo_telemetry():
    """Valida replay de log CSV contendo telemetria Turbo, auto-escala do osciloscópio e cards adaptativos."""
    with tempfile.TemporaryDirectory() as tmpdir:
        csv_file = os.path.join(tmpdir, "turbo_run.csv")
        with open(csv_file, "w", encoding="utf-8") as f:
            f.write("timestamp_ms;tempo_s;atualizado;rpm;map;boost_bar;wastegate_pct;lambda_eq;fuel_rail_bar;knock_retard_max\n")
            f.write("1000;0.0;rpm;1200;95;0.00;15.0;1.000;45.0;0.0\n")
            f.write("2000;1.0;rpm+map;2800;165;0.65;55.0;0.920;115.0;0.5\n")
            f.write("3000;2.0;rpm+map;4500;235;1.35;78.0;0.840;150.0;2.0\n")

        win = MainWindow(demo=True)
        win.show()

        win._load_csv_file(csv_file)
        assert win._replay_mode is True
        assert len(win._replay_records) == 3

        # O osciloscópio de ar/giro (Plot 1) auto-escalou o eixo direito até suportar 235 kPa
        right_view_range = win.p1.vb2.viewRange()[1]
        assert right_view_range[1] >= 235.0

        # O Mapa 2D auto-escalou para Turbo
        assert win.map2d.map_bins == MAP_BINS_TURBO

        # Cards adaptativos exibem telemetria Turbo no ponto de pico (t = 2.0 s)
        win._update_replay_cards(2.0)
        assert "Boost" in win.cards["map"].title.text()
        assert win.cards["lambda2_v"].title.text() == "Pressão Turbo"
        assert win.cards["lambda2_v"].unit.text() == "bar"
        assert "+1.35" in win.cards["lambda2_v"].value.text() or "1.35" in win.cards["lambda2_v"].value.text()

        win.close()
