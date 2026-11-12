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
    assert hasattr(win, "btn_export_mlv")
    assert hasattr(win, "btn_settings")
    assert hasattr(win, "auto_log_chk")
    assert hasattr(win, "btn_clear_peaks")
    assert hasattr(win, "proto_badge")
    assert hasattr(win, "bg_scan_chk")
    assert win.map2d.minimumSizeHint().width() <= 300

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


def test_export_pdf_report_peak_extraction(monkeypatch, tmp_path):
    """Verifica que o laudo extrai corretamente min_val e max_val de cada ValueCard (sem AttributeError)."""
    win = MainWindow(demo=True)
    win.show()

    # Preenche valores e picos em cards conhecidos
    win.cards["rpm"].set_value(900.0)
    win.cards["rpm"].set_value(3200.0)
    win.cards["map"].set_value(35.0)
    win.cards["map"].set_value(98.0)

    captured_card_peaks = {}

    def mock_generate_html_report(**kwargs):
        nonlocal captured_card_peaks
        captured_card_peaks = kwargs.get("card_peaks", {})
        return "<html><body>Laudo Teste</body></html>"

    from PyQt6.QtWidgets import QFileDialog, QMessageBox
    target_path = str(tmp_path / "teste_laudo.html")
    monkeypatch.setattr(QFileDialog, "getSaveFileName", lambda *args, **kwargs: (target_path, "HTML"))
    monkeypatch.setattr(QMessageBox, "information", lambda *args, **kwargs: None)
    monkeypatch.setattr(QMessageBox, "critical", lambda *args, **kwargs: None)
    from obd_app import report_generator
    monkeypatch.setattr(report_generator, "generate_html_report", mock_generate_html_report)
    from obd_app.ui import main_window
    monkeypatch.setattr(main_window, "generate_html_report", mock_generate_html_report)

    # Executa a exportação sem crash
    win._export_pdf_report()

    assert "rpm" in captured_card_peaks
    assert captured_card_peaks["rpm"] == (900.0, 3200.0)
    assert captured_card_peaks["map"] == (35.0, 98.0)
    # Todos os 14 cards devem ter picos capturados
    assert len(captured_card_peaks) == 14

    win.close()


def test_wideband_lambda_state_evaluation():
    """Testa detecção do estado de mistura com sonda Wideband (lambda_eq) sem falso alarme 'TRAVADA RICA'."""
    win = MainWindow(demo=True)
    win.latest["rpm"] = 2200.0
    win.latest["ect"] = 88.0

    # Simula buffer de lambda_v estável (que causaria falso positivo 'TRAVADA RICA' em narrowband)
    for _ in range(10):
        win.buffers["lambda_v"].append(1.0, 0.450)

    # 1. Wideband Estequiométrica (λ ~ 1.0)
    win.latest["lambda_eq"] = 1.00
    state, note = win._lambda_state(now=10.0)
    assert state == "normal"
    assert "ESTEQ" in note or "1.0" in note

    # 2. Wideband Rica (λ < 0.90)
    win.latest["lambda_eq"] = 0.85
    state, note = win._lambda_state(now=10.0)
    assert "RICA" in note
    assert state in ("warn", "alarm")

    # 3. Wideband Pobre (λ > 1.08)
    win.latest["lambda_eq"] = 1.15
    state, note = win._lambda_state(now=10.0)
    assert "POBRE" in note
    assert state == "warn"

    # 4. Wideband Cut-off (λ > 1.50)
    win.latest["lambda_eq"] = 1.85
    state, note = win._lambda_state(now=10.0)
    assert "cut-off" in note
    assert state == "normal"

    win.close()


def test_adaptive_turbo_card_display_and_1080p_budget():
    """Garante manutenção estrita de 14 cards (2x7) e adaptação inteligente para telemetria Turbo."""
    win = MainWindow(demo=True)
    win.show()

    # Orçamento visual Full HD 1080p: exatamente 14 cards, 2 linhas de 7
    assert len(win.cards) == 14
    w = win.size().width()
    h = win.size().height()
    assert w <= 1920
    assert h <= 1080

    # Seletor de Perfil Demo presente e compacto
    assert hasattr(win, "mock_profile_cb")
    assert win.mock_profile_cb.count() >= 2
    win.mock_profile_cb.setCurrentIndex(1)  # Turbo mode
    assert win.mock_profile_cb.currentIndex() == 1

    # Injeta telemetria Turbo
    win.latest["rpm"] = 3500.0
    win.latest["map"] = 220.0  # Regime de sobrealimentação (1.2 bar boost)
    win.latest["boost_bar"] = 1.18
    win.dirty.update({"rpm", "map"})

    win._render()

    # Card MAP adapta visualmente para 'MAP / Boost'
    assert "Boost" in win.cards["map"].title.text()
    # Card lambda2_v adapta para Pressão Turbo quando em modo turbo
    assert win.cards["lambda2_v"].title.text() == "Pressão Turbo"
    assert win.cards["lambda2_v"].unit.text() == "bar"

    # Verificação de que as chaves de cards padrão permanecem íntegras (sem 3ª linha)
    assert len(win.cards) == 14
    assert "map" in win.cards
    assert "lambda2_v" in win.cards

    win.mock_profile_cb.setCurrentIndex(0)
    win.close()


def test_aspirated_card_telemetry_preservation():
    """Garante que telemetria aspirada com boost_bar sintético negativo NÃO aciona modo Turbo.

    (a) Carro aspirado com Sonda 2 (ex: Ford Ka+ 1.5 Sigma) preserva 'MAP' e 'Sonda 2 (Pós)'.
    (b) Carro aspirado com sonda única (ex: VW Gol G5) preserva 'MAP' e fallback 'Tempo Injeção'.
    """
    win = MainWindow(demo=True)
    win.is_turbo = False

    # (a) Ford Ka+ 1.5 Sigma: Sonda 2 ativa, MAP 32 kPa, vácuo sintético -0.69 bar
    win.latest.clear()
    win.stamp.clear()
    now = 100.0
    win.latest.update({
        "rpm": 850.0,
        "map": 32.0,
        "boost_bar": -0.69,
        "lambda2_v": 0.65,
    })
    win.stamp.update({
        "rpm": now,
        "map": now,
        "boost_bar": now,
        "lambda2_v": now,
    })
    win.dirty.update({"rpm", "map", "lambda2_v"})

    win._render()
    win._update_card_states(now)

    assert win.cards["map"].title.text() == "MAP"
    assert win.cards["lambda2_v"].title.text() == "Sonda 2 (Pós)"
    assert win.cards["lambda2_v"].unit.text() == "V"

    # (b) VW Gol G5: Sonda única, sem Sonda 2, mas com inj_ms
    win.latest.clear()
    win.stamp.clear()
    win.latest.update({
        "rpm": 920.0,
        "map": 36.0,
        "boost_bar": -0.65,
        "inj_ms": 2.85,
    })
    win.stamp.update({
        "rpm": now,
        "map": now,
        "boost_bar": now,
        "inj_ms": now,
    })
    win.dirty.update({"rpm", "map", "inj_ms"})

    win._render()
    win._update_card_states(now)

    assert win.cards["map"].title.text() == "MAP"
    assert win.cards["lambda2_v"].title.text() == "Tempo Injeção"
    assert win.cards["lambda2_v"].unit.text() == "ms"

    win.close()


def test_ecu_detected_turbo_propagation():
    """Garante propagação de is_turbo via _on_ecu_detected e adaptação automática de cards."""
    win = MainWindow(demo=True)
    win.is_turbo = False

    # 1. ECU Turbo identificada
    win._on_ecu_detected({
        "display_title": "VW Golf GTI 2.0 TSI EA888",
        "protocol": "CAN UDS 500k",
        "is_turbo": True,
    })
    assert win.is_turbo is True
    assert "Golf GTI" in win.windowTitle()

    # Injeta telemetria
    now = 50.0
    win.latest.update({
        "rpm": 3200.0,
        "map": 180.0,
        "boost_bar": 0.78,
    })
    win.stamp.update({
        "rpm": now,
        "map": now,
        "boost_bar": now,
    })
    win.dirty.update({"rpm", "map", "boost_bar"})

    win._render()
    win._update_card_states(now)

    assert "Boost" in win.cards["map"].title.text()
    assert win.cards["lambda2_v"].title.text() == "Pressão Turbo"
    assert win.cards["lambda2_v"].unit.text() == "bar"

    # 2. ECU Aspirada identificada explicitamente desativa is_turbo
    win._on_ecu_detected({
        "display_title": "VW Gol G5 1.6 TotalFlex EA111",
        "protocol": "VAG KWP2000",
        "is_turbo": False,
    })
    assert win.is_turbo is False
    assert "Gol G5" in win.windowTitle()

    win.close()
