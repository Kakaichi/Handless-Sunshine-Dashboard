"""Persist Moonlight Web admin credentials for API operations."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path


@dataclass
class MoonlightCredentials:
    username: str
    password: str


def get_store_path() -> Path:
    base = os.environ.get("APPDATA")
    if not base:
        base = str(Path.home())
    return Path(base) / "HeadlessSteam" / "moonlight_credentials.json"


def load_credentials() -> MoonlightCredentials | None:
    path = get_store_path()
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        username = str(data.get("username", "")).strip()
        password = str(data.get("password", ""))
        if username and password:
            return MoonlightCredentials(username=username, password=password)
    except (OSError, json.JSONDecodeError, TypeError):
        pass
    return None


def save_credentials(credentials: MoonlightCredentials) -> None:
    path = get_store_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "username": credentials.username,
        "password": credentials.password,
    }
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def clear_credentials() -> None:
    path = get_store_path()
    if path.exists():
        path.unlink()
