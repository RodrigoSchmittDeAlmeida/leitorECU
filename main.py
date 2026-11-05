"""Ponto de entrada: python main.py [--demo]"""
import argparse
import sys

from PyQt6.QtWidgets import QApplication

from obd_app.ui.main_window import MainWindow


def main():
    ap = argparse.ArgumentParser(description="Datalogger OBD2 ELM327 — Bosch ME7.5.30 (Gol G5)")
    ap.add_argument("--demo", action="store_true", help="inicia já no modo Demo/Simulador")
    args = ap.parse_args()

    app = QApplication(sys.argv)
    app.setApplicationName("Datalogger ME7.5.30")
    win = MainWindow(demo=args.demo)
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
