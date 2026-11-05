"""Testes de interface gráfica e conformidade de UX (PyQt6)."""
import sys
import pytest
from PyQt6.QtWidgets import QApplication
from obd_app.ui.main_window import MainWindow

app = QApplication.instance() or QApplication(sys.argv)


def test_main_window_instantiation():
    """Testa inicialização limpa da janela principal e conformidade UX."""
    win = MainWindow(demo=True)
    win.show()

    # 1. Conformidade de resolução: deve caber 100% em Full HD (1920x1080 16:9)
    w = win.size().width()
    h = win.size().height()
    assert w <= 1920, f"Largura {w} excede 1920!"
    assert h <= 1080, f"Altura {h} excede 1080!"

    # 2. 14 ValueCards simétricos configurados
    assert len(win.cards) == 14
    assert "lambda_v" in win.cards
    assert "lambda2_v" in win.cards

    # 3. Tooltips presentes nos cards (UX)
    assert win.cards["rpm"].toolTip() != ""
    assert win.cards["lambda_v"].toolTip() != ""
    assert win.cards["lambda2_v"].toolTip() != ""

    # 4. Osciloscópio tem curvas para ambas as sondas
    assert "lambda_v" in win.curves
    assert "lambda2_v" in win.curves

    # 5. Barra de busca presente na aba de canais (UX)
    assert hasattr(win, "ch_search")

    # 6. Aba Ford Ka presente
    tab_names = [win.tabs.tabText(i) for i in range(win.tabs.count())]
    assert any("Ford Ka" in t for t in tab_names)

    win.close()
