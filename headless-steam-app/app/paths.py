"""Resolve sunshine/ and related paths for dev and packaged layouts."""

from __future__ import annotations

import os
import sys
from pathlib import Path

_SUNSHINE_MARKERS = (
    "HeadlessSteam-Status.ps1",
    "Invoke-HeadlessSteamAction.ps1",
    "sync-steam-games.ps1",
    "gerenciar-servicos.bat",
)

_resolved_sunshine_dir: Path | None = None


def get_app_root() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


def ensure_runtime_paths() -> None:
    os.environ.setdefault("HEADLESS_STEAM_APP_ROOT", str(get_app_root()))


def _is_sunshine_dir(path: Path) -> bool:
    if not path.is_dir():
        return False
    return any((path / name).is_file() for name in _SUNSHINE_MARKERS)


def _add_candidate(candidates: list[Path], seen: set[Path], path: Path) -> None:
    try:
        resolved = path.resolve()
    except OSError:
        resolved = path

    if resolved in seen:
        return

    seen.add(resolved)
    candidates.append(resolved)


def _sunshine_dir_candidates() -> list[Path]:
    candidates: list[Path] = []
    seen: set[Path] = set()

    for env_name in ("HEADLESS_STEAM_APP_ROOT", "HEADLESS_STEAM_HOME"):
        raw = os.environ.get(env_name, "").strip()
        if not raw:
            continue

        base = Path(raw)
        if _is_sunshine_dir(base):
            _add_candidate(candidates, seen, base)
        sunshine_child = base / "sunshine"
        if _is_sunshine_dir(sunshine_child):
            _add_candidate(candidates, seen, sunshine_child)

    app_root = get_app_root()
    _add_candidate(candidates, seen, app_root / "sunshine")
    _add_candidate(candidates, seen, app_root.parent / "sunshine")

    if getattr(sys, "frozen", False):
        exe_root = Path(sys.executable).resolve().parent
        current = exe_root
        for _ in range(4):
            _add_candidate(candidates, seen, current / "sunshine")
            if current.parent == current:
                break
            current = current.parent

    if not getattr(sys, "frozen", False):
        repo_sunshine = Path(__file__).resolve().parent.parent.parent / "sunshine"
        _add_candidate(candidates, seen, repo_sunshine)

    return candidates


def get_sunshine_dir() -> Path:
    global _resolved_sunshine_dir

    if _resolved_sunshine_dir is not None and _is_sunshine_dir(_resolved_sunshine_dir):
        return _resolved_sunshine_dir

    for path in _sunshine_dir_candidates():
        if _is_sunshine_dir(path):
            _resolved_sunshine_dir = path
            return path

    expected = get_app_root() / "sunshine"
    raise FileNotFoundError(
        "Pasta sunshine/ nao encontrada. "
        f"Esperado em: {expected}. "
        "Use a pasta completa do aplicativo (HandlessSteam.exe com sunshine/ ao lado) "
        "ou defina HEADLESS_STEAM_HOME / HEADLESS_STEAM_APP_ROOT."
    )


def script_path(name: str) -> Path:
    return get_sunshine_dir() / name


def get_moonlight_web_dir() -> Path:
    app_root = get_app_root()
    candidates: list[Path] = []
    seen: set[Path] = set()

    def add(path: Path) -> None:
        try:
            resolved = path.resolve()
        except OSError:
            resolved = path
        if resolved not in seen:
            seen.add(resolved)
            candidates.append(resolved)

    for env_name in ("HEADLESS_STEAM_APP_ROOT", "HEADLESS_STEAM_HOME"):
        raw = os.environ.get(env_name, "").strip()
        if not raw:
            continue
        base = Path(raw)
        add(base / "moonlight-web")
        if base.name.lower() == "moonlight-web":
            add(base)

    add(app_root / "moonlight-web")
    add(app_root.parent / "moonlight-web")

    try:
        add(get_sunshine_dir().parent / "moonlight-web")
    except FileNotFoundError:
        pass

    for path in candidates:
        if (path / "package" / "web-server.exe").is_file():
            return path

    expected = app_root / "moonlight-web"
    raise FileNotFoundError(
        "Pasta moonlight-web/ nao encontrada. "
        f"Esperado em: {expected} (com package/web-server.exe). "
        "Use a pasta completa do aplicativo."
    )
