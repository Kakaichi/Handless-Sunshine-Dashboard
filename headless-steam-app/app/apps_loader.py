"""Load Sunshine apps and cover paths from disk."""

from __future__ import annotations

import json
from pathlib import Path

from app.paths import get_sunshine_dir


def load_apps_from_disk() -> list[dict]:
    try:
        path = get_sunshine_dir() / "apps.json"
        if not path.exists():
            return []
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        apps = data.get("apps", [])
        if not isinstance(apps, list):
            return []
        return [app for app in apps if isinstance(app, dict)]
    except (OSError, json.JSONDecodeError, TypeError):
        return []


def resolve_cover_path(image_path: str) -> Path | None:
    if not image_path or not str(image_path).strip():
        return None

    raw = str(image_path).strip().strip('"')
    if raw.startswith(("http://", "https://")):
        return None

    sunshine_dir = get_sunshine_dir()
    file_name = Path(raw).name

    if file_name.endswith(".png"):
        bundled = sunshine_dir / "covers" / file_name
        if bundled.is_file():
            return bundled

    direct = Path(raw)
    if direct.is_file():
        return direct

    candidates = (
        sunshine_dir / raw,
        sunshine_dir / "covers" / file_name,
    )
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return None
