"""Testes unitários para gravação de logs CSV e SeriesBuffer (obd_app.datalog)."""
import os
import tempfile
import pytest
from obd_app.datalog import CsvLogger, SeriesBuffer


def test_series_buffer_window():
    """Testa armazenamento e busca por janela de tempo no SeriesBuffer."""
    buf = SeriesBuffer(capacity=100)
    for i in range(10):
        buf.append(float(i), float(i * 10))

    t, v = buf.window(5.0)
    assert len(t) == 5
    assert t[0] == 5.0
    assert v[0] == 50.0
    assert t[-1] == 9.0
    assert v[-1] == 90.0


def test_csv_logger_pt_br_format():
    """Testa se o CsvLogger gera o padrão Excel pt-BR (delimitador ';' e vírgula decimal ',')."""
    with tempfile.TemporaryDirectory() as tmpdir:
        csv_path = os.path.join(tmpdir, "test_log.csv")
        logger = CsvLogger(decimal_comma=True)
        logger.start(csv_path)

        latest = {
            "rpm": 850.0,
            "lambda_v": 0.450,
            "lambda2_v": 0.655,
            "map": 32.5,
        }
        logger.write(wall_ms=1000.0, t_rel=1.234, updated="rpm", latest=latest, event="CUT_OFF")
        logger.stop()

        assert os.path.exists(csv_path)
        with open(csv_path, "r", encoding="utf-8") as f:
            lines = f.readlines()

        assert len(lines) == 2
        header = lines[0].strip().split(";")
        row = lines[1].strip().split(";")

        assert "timestamp_ms" in header
        assert "rpm" in header
        assert "lambda_v" in header
        assert "lambda2_v" in header
        assert header[-1] == "evento"

        # Verifica formato pt-BR no valor de tempo e sensor
        assert "1,234" in row
        assert "0,450" in row
        assert "0,655" in row
        assert row[-1] == "CUT_OFF"


def test_csv_logger_dynamic_columns():
    """Testa se o CsvLogger expande colunas dinâmicas (ex: blocos VAG ou DIDs novos) sem corromper o arquivo."""
    with tempfile.TemporaryDirectory() as tmpdir:
        csv_path = os.path.join(tmpdir, "test_dyn.csv")
        logger = CsvLogger(decimal_comma=True)
        logger.start(csv_path)

        # 1ª linha com sensores padrão
        logger.write(1000.0, 1.0, "rpm", {"rpm": 850.0})

        # Adiciona coluna dinâmica nova
        logger.add_columns({"cht_temp": "Temp Cabeça Cilindro [°C]"})
        logger.write(2000.0, 2.0, "cht_temp", {"rpm": 850.0, "cht_temp": 88.5})
        logger.stop()

        with open(csv_path, "r", encoding="utf-8") as f:
            lines = f.readlines()

        assert len(lines) == 3
        assert "Temp Cabeça Cilindro [°C]" in lines[0]

