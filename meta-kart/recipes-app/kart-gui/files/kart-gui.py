#!/usr/bin/env python3
"""Kart GUI - PyQt6 kiosk application sample."""

import json
import os
import sys

from PyQt6.QtCore import QTimer, Qt
from PyQt6.QtWidgets import (
    QApplication,
    QLabel,
    QMainWindow,
    QVBoxLayout,
    QWidget,
)

CONFIG_PATH = os.path.join(os.path.dirname(__file__), "gpio-config.json")


def load_gpio_config():
    try:
        with open(CONFIG_PATH, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"input_pin": 17, "output_pin": 27, "chip": "gpiochip0"}


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.gpio_cfg = load_gpio_config()
        self.setWindowTitle("Kart")
        self._build_ui()
        self._start_timer()

    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)
        layout.setAlignment(Qt.AlignmentFlag.AlignCenter)

        self.label_title = QLabel("Kart System")
        self.label_title.setStyleSheet("font-size: 48px; font-weight: bold;")
        self.label_title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(self.label_title)

        self.label_status = QLabel("Initializing...")
        self.label_status.setStyleSheet("font-size: 24px;")
        self.label_status.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(self.label_status)

        self.label_can = QLabel("CAN: --")
        self.label_can.setStyleSheet("font-size: 20px; color: #666;")
        self.label_can.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(self.label_can)

        self.label_gpio = QLabel("GPIO: --")
        self.label_gpio.setStyleSheet("font-size: 20px; color: #666;")
        self.label_gpio.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(self.label_gpio)

    def _start_timer(self):
        self.timer = QTimer(self)
        self.timer.timeout.connect(self._update_status)
        self.timer.start(2000)
        self._update_status()

    def _update_status(self):
        # CAN interface check
        can_status = "UP" if os.path.exists("/sys/class/net/can0") else "N/A"
        self.label_can.setText(f"CAN: {can_status}")

        # GPIO status (basic check)
        chip = self.gpio_cfg.get("chip", "gpiochip0")
        gpio_ok = os.path.exists(f"/dev/{chip}")
        self.label_gpio.setText(f"GPIO ({chip}): {'OK' if gpio_ok else 'N/A'}")

        self.label_status.setText("Running")


def main():
    app = QApplication(sys.argv)
    window = MainWindow()
    window.showFullScreen()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
