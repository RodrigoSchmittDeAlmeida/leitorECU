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

    # 6. Abas de funções por módulo, Mapa 2D e Desempenho presentes
    tab_names = [win.tabs.tabText(i) for i in range(win.tabs.count())]
    assert "Funções" in tab_names
    assert "Desempenho" in tab_names
    assert any("Mapa 2D" in t for t in tab_names)
    assert hasattr(win, "btn_readiness")
    assert hasattr(win, "btn_freeze_frame")
    assert hasattr(win, "btn_export_report")
    assert hasattr(win, "audio_alerts")

    # 6.1 Funções são agnósticas ao veículo e reveladas por canais detectados
    win.latest.clear()
    win._refresh_function_modules()
    assert not win.functions_grid_widget.isVisible()
    win.latest.update({"rpm": 850.0, "map": 35.0})
    win._refresh_function_modules()
    assert not win.engine_module_box.isHidden()
    assert win.body_module_box.isHidden()

    # 7. Controles de UX: Replay CSV, Limpar Picos, Badge de Protocolo e Varredura
    assert hasattr(win, "btn_open_csv")
    assert hasattr(win, "btn_clear_peaks")
    assert hasattr(win, "proto_badge")
    assert hasattr(win, "bg_scan_chk")

    # 8. Peak Hold funcional no ValueCard
    rpm_card = win.cards["rpm"]
    rpm_card.set_value(850.0)
    rpm_card.set_value(2500.0)
    assert rpm_card.min_val == 850.0
    assert rpm_card.max_val == 2500.0
    assert "850" in rpm_card.peaks_label.text()
    assert "2500" in rpm_card.peaks_label.text()

    rpm_card.reset_peaks()
    assert rpm_card.min_val is None
    assert rpm_card.max_val is None
    assert rpm_card.peaks_label.text() == ""

    win.close()
