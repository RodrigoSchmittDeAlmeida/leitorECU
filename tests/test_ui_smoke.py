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

    # 6. Abas Ford Ka e Mapa 2D presentes
    tab_names = [win.tabs.tabText(i) for i in range(win.tabs.count())]
    assert any("Ford Ka" in t for t in tab_names)
    assert any("Mapa 2D" in t for t in tab_names)

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

    # 9. Seletores interativos de canais para os 3 gráficos (p1, p2, p3)
    assert hasattr(win, "plot_selectors")
    assert set(win.plot_selectors.keys()) == {1, 2, 3}
    # Troca o canal R1 do gráfico 1 para 'battery' e verifica atualização imediata
    cb_r1 = win.plot_selectors[1]["R1"]
    bat_idx = cb_r1.findData("battery")
    assert bat_idx >= 0
    cb_r1.setCurrentIndex(bat_idx)
    assert win.slot_keys[(1, "R1")] == "battery"
    assert "battery" in win.curves

    # 10. Guias visíveis de métricas no Mapa 2D (sem setas de scroll)
    assert len(win.map2d.metric_buttons) == 6
    assert not win.tabs.tabBar().usesScrollButtons()

    # 11. Janela permanece com geometria idêntica ao trocar veículo ou status
    size_before = win.size()
    win.vehicle_cb.setCurrentIndex(1)
    win._on_status("connecting", "Varrendo blocos de medição 001..255 na ECU Bosch ME7.5.30 (aguarde)...")
    assert win.size() == size_before

    win.close()

