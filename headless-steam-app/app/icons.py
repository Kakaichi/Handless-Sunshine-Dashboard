"""Load bundled SVG icons for dev and PyInstaller layouts."""

from __future__ import annotations

import sys
from pathlib import Path

from PySide6.QtGui import QIcon

from app.paths import get_app_root


def icon_path(name: str) -> Path:
    base = Path(getattr(sys, "_MEIPASS", get_app_root()))
    return base / "resources" / "icons" / name


def load_icon(name: str) -> QIcon:
    path = icon_path(name)
    if path.exists():
        return QIcon(str(path))
    return QIcon()


def load_app_icon() -> QIcon:
    base = Path(getattr(sys, "_MEIPASS", get_app_root()))
    for candidate in (
        base / "resources" / "favicon.ico",
        get_app_root() / "resources" / "favicon.ico",
    ):
        if candidate.is_file():
            return QIcon(str(candidate))
    return QIcon()
