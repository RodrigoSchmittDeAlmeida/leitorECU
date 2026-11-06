"""Testes para o Mapa 2D (RPM x MAP) e Replay de Datalog CSV."""
import os
import sys
import tempfile
import pytest
from PyQt6.QtWidgets import QApplication

from obd_app.datalog import CsvLogger
from obd_app.pids import CHANNELS, DYNAMIC_INFO
from obd_app.ford import FORD_CHANNELS_INFO
from obd_app.ui.map2d import Map2DWidget, _find_bin, _color_for_value, RPM_BINS, MAP_BINS

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
