"""Persist host-free / virtual display settings locally."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path


@dataclass
class HostSettings:
    host_free_mode_enabled: bool = False
    keep_focus_enabled: bool = False
    keep_remote_input_enabled: bool = True
    stream_output_device_id: str | None = None


def get_settings_path() -> Path:
    base = os.environ.get("APPDATA")
    if not base:
        base = str(Path.home())
    return Path(base) / "HeadlessSteam" / "host_settings.json"


def load_settings() -> HostSettings:
    path = get_settings_path()
    if not path.exists():
        return HostSettings()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, TypeError):
        return HostSettings()

    stream_output = data.get("stream_output_device_id")
    host_free = bool(data.get("host_free_mode_enabled"))
    keep_focus = bool(data.get("keep_focus_enabled"))
    if host_free and "keep_focus_enabled" not in data:
        keep_focus = False

    keep_remote = bool(data.get("keep_remote_input_enabled", True))

    return HostSettings(
        host_free_mode_enabled=host_free,
        keep_focus_enabled=keep_focus,
        keep_remote_input_enabled=keep_remote,
        stream_output_device_id=str(stream_output) if stream_output else None,
    )


def save_settings(settings: HostSettings) -> None:
    path = get_settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "host_free_mode_enabled": settings.host_free_mode_enabled,
        "keep_focus_enabled": settings.keep_focus_enabled,
        "keep_remote_input_enabled": settings.keep_remote_input_enabled,
        "stream_output_device_id": settings.stream_output_device_id,
    }
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
