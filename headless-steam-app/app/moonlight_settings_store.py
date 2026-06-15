"""Persist Moonlight Web app settings locally."""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path


@dataclass
class MoonlightSettings:
    public_funnel_enabled: bool = False
    skip_login_enabled: bool = False
    skip_login_user_id: str | None = None


def get_settings_path() -> Path:
    base = os.environ.get("APPDATA")
    if not base:
        base = str(Path.home())
    return Path(base) / "HeadlessSteam" / "moonlight_settings.json"


def load_settings() -> MoonlightSettings:
    path = get_settings_path()
    if not path.exists():
        return MoonlightSettings()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        user_id = data.get("skip_login_user_id")
        return MoonlightSettings(
            public_funnel_enabled=bool(data.get("public_funnel_enabled")),
            skip_login_enabled=bool(data.get("skip_login_enabled")),
            skip_login_user_id=str(user_id) if user_id is not None else None,
        )
    except (OSError, json.JSONDecodeError, TypeError):
        return MoonlightSettings()


def normalize_settings(settings: MoonlightSettings, user_count: int) -> MoonlightSettings:
    funnel = settings.public_funnel_enabled
    skip = settings.skip_login_enabled
    user_id = settings.skip_login_user_id

    if funnel and user_count <= 0:
        funnel = False
    if funnel:
        skip = False
        user_id = None
    elif skip and not user_id:
        skip = False
        user_id = None

    return MoonlightSettings(
        public_funnel_enabled=funnel,
        skip_login_enabled=skip,
        skip_login_user_id=user_id,
    )


def save_settings(settings: MoonlightSettings) -> None:
    path = get_settings_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "public_funnel_enabled": settings.public_funnel_enabled,
        "skip_login_enabled": settings.skip_login_enabled,
        "skip_login_user_id": settings.skip_login_user_id if settings.skip_login_enabled else None,
    }
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
