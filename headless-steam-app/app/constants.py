"""Shared display names and version for the desktop app."""

from __future__ import annotations

import sys
from pathlib import Path

APP_DISPLAY_NAME = "Handless Sunshine Dashboard"
APP_EXE_NAME = "HandlessSteam.exe"


def _version_file_candidates() -> list[Path]:
    if getattr(sys, "frozen", False):
        return [Path(sys.executable).parent / "VERSION"]

    app_dir = Path(__file__).resolve().parent.parent
    return [
        app_dir / "VERSION",
        app_dir.parent / "headless-steam-app" / "VERSION",
    ]


def get_app_version() -> str:
    for path in _version_file_candidates():
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8-sig").strip()
        if text:
            return text
    return "dev"


APP_VERSION = get_app_version()


def format_app_title(include_version: bool = True) -> str:
    if include_version and APP_VERSION != "dev":
        return f"{APP_DISPLAY_NAME} v{APP_VERSION}"
    return APP_DISPLAY_NAME
