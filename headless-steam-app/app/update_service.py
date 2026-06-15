"""Check GitHub releases and download update packages."""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from PySide6.QtCore import QObject, QThread, Signal

from app.constants import APP_DISPLAY_NAME, APP_EXE_NAME, APP_VERSION
from app.update_constants import (
    GITHUB_LATEST_RELEASE_API,
    GITHUB_RELEASES_PAGE,
    WIN64_ASSET_PREFIX,
    WIN64_ASSET_SUFFIX,
    is_newer,
    normalize_version,
)


def _user_agent() -> str:
    return f"{APP_DISPLAY_NAME}/{APP_VERSION}"


def _dismissed_store_path() -> Path:
    base = os.environ.get("APPDATA") or str(Path.home())
    return Path(base) / "HeadlessSteam" / "update_dismissed.json"


def load_dismissed_version() -> str | None:
    path = _dismissed_store_path()
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        version = normalize_version(str(data.get("version") or ""))
        return version or None
    except (OSError, json.JSONDecodeError, TypeError):
        return None


def save_dismissed_version(version: str) -> None:
    path = _dismissed_store_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"version": normalize_version(version)}
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def should_auto_check() -> bool:
    if APP_VERSION == "dev":
        return False
    return bool(getattr(sys, "frozen", False))


@dataclass
class UpdateInfo:
    version: str
    tag: str
    release_url: str
    download_url: str
    notes: str
    asset_name: str


def _github_request(url: str, *, timeout: int = 15) -> dict[str, Any]:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": _user_agent(),
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        raw = response.read().decode("utf-8", errors="replace")
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise RuntimeError("Resposta invalida da API GitHub.")
    return data


def fetch_latest_update(*, local_version: str = APP_VERSION) -> UpdateInfo | None:
    payload = _github_request(GITHUB_LATEST_RELEASE_API)
    tag = str(payload.get("tag_name") or "").strip()
    version = normalize_version(tag)
    if not version or not is_newer(version, local_version):
        return None

    download_url = ""
    asset_name = ""
    for asset in payload.get("assets") or []:
        if not isinstance(asset, dict):
            continue
        name = str(asset.get("name") or "")
        if name.startswith(WIN64_ASSET_PREFIX) and name.endswith(WIN64_ASSET_SUFFIX):
            download_url = str(asset.get("browser_download_url") or "").strip()
            asset_name = name
            break

    if not download_url:
        return None

    release_url = str(payload.get("html_url") or GITHUB_RELEASES_PAGE).strip()
    notes = str(payload.get("body") or "").strip()
    if len(notes) > 600:
        notes = notes[:597] + "..."

    return UpdateInfo(
        version=version,
        tag=tag or f"v{version}",
        release_url=release_url,
        download_url=download_url,
        notes=notes,
        asset_name=asset_name,
    )


def download_and_extract_update(
    info: UpdateInfo,
    *,
    progress_callback: Callable[[int], None] | None = None,
) -> Path:
    base_dir = Path(tempfile.gettempdir()) / "HeadlessSteam-update" / info.version
    if base_dir.exists():
        for child in base_dir.iterdir():
            if child.is_dir():
                shutil.rmtree(child, ignore_errors=True)
            else:
                child.unlink(missing_ok=True)
    base_dir.mkdir(parents=True, exist_ok=True)

    zip_path = base_dir / info.asset_name
    request = urllib.request.Request(
        info.download_url,
        headers={"User-Agent": _user_agent()},
    )

    with urllib.request.urlopen(request, timeout=120) as response:
        total = int(response.headers.get("Content-Length") or 0)
        downloaded = 0
        chunk_size = 256 * 1024
        with zip_path.open("wb") as handle:
            while True:
                chunk = response.read(chunk_size)
                if not chunk:
                    break
                handle.write(chunk)
                downloaded += len(chunk)
                if progress_callback and total > 0:
                    progress_callback(min(99, int(downloaded * 100 / total)))

    extract_dir = base_dir / "extracted"
    if extract_dir.exists():
        shutil.rmtree(extract_dir, ignore_errors=True)
    extract_dir.mkdir(parents=True, exist_ok=True)

    with zipfile.ZipFile(zip_path, "r") as archive:
        archive.extractall(extract_dir)

    exe_path = extract_dir / APP_EXE_NAME
    version_path = extract_dir / "VERSION"
    if not exe_path.is_file() or not version_path.is_file():
        raise RuntimeError(f"Pacote de atualizacao invalido (faltam {APP_EXE_NAME} ou VERSION).")

    if progress_callback:
        progress_callback(100)

    return extract_dir


class _CheckWorker(QThread):
    finished_ok = Signal(object)
    finished_err = Signal(str)

    def __init__(self, *, local_version: str, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._local_version = local_version

    def run(self) -> None:
        try:
            info = fetch_latest_update(local_version=self._local_version)
            self.finished_ok.emit(info)
        except urllib.error.URLError as exc:
            self.finished_err.emit(f"Sem conexao com GitHub: {exc.reason}")
        except Exception as exc:  # noqa: BLE001
            self.finished_err.emit(str(exc))


class _DownloadWorker(QThread):
    progress = Signal(int)
    finished_ok = Signal(object)
    finished_err = Signal(str)

    def __init__(self, info: UpdateInfo, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._info = info

    def run(self) -> None:
        try:
            extracted = download_and_extract_update(
                self._info,
                progress_callback=lambda value: self.progress.emit(value),
            )
            self.finished_ok.emit(extracted)
        except urllib.error.URLError as exc:
            self.finished_err.emit(f"Falha no download: {exc.reason}")
        except Exception as exc:  # noqa: BLE001
            self.finished_err.emit(str(exc))


class UpdateService(QObject):
    check_finished = Signal(object)
    check_failed = Signal(str)
    download_progress = Signal(int)
    download_finished = Signal(object)
    download_failed = Signal(str)

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._check_worker: _CheckWorker | None = None
        self._download_worker: _DownloadWorker | None = None
        self._pending_info: UpdateInfo | None = None

    @property
    def pending_update(self) -> UpdateInfo | None:
        return self._pending_info

    def check(self, *, silent: bool = False) -> None:
        if self._check_worker is not None and self._check_worker.isRunning():
            return

        worker = _CheckWorker(local_version=APP_VERSION, parent=self)
        self._check_worker = worker
        worker.finished_ok.connect(self._on_check_ok)
        worker.finished_err.connect(lambda msg: self._on_check_err(msg, silent=silent))
        worker.finished.connect(self._on_check_finished)
        worker.start()

    def download(self, info: UpdateInfo) -> None:
        if self._download_worker is not None and self._download_worker.isRunning():
            return

        worker = _DownloadWorker(info, parent=self)
        self._download_worker = worker
        worker.progress.connect(self.download_progress.emit)
        worker.finished_ok.connect(self.download_finished.emit)
        worker.finished_err.connect(self.download_failed.emit)
        worker.finished.connect(self._on_download_finished)
        worker.start()

    def _on_check_ok(self, info: object) -> None:
        if info is None:
            self._pending_info = None
            self.check_finished.emit(None)
            return

        if not isinstance(info, UpdateInfo):
            self.check_finished.emit(None)
            return

        dismissed = load_dismissed_version()
        if dismissed and not is_newer(info.version, dismissed):
            self._pending_info = None
            self.check_finished.emit(None)
            return

        self._pending_info = info
        self.check_finished.emit(info)

    def _on_check_err(self, message: str, *, silent: bool) -> None:
        self._pending_info = None
        if not silent:
            self.check_failed.emit(message)

    def _on_check_finished(self) -> None:
        worker = self._check_worker
        self._check_worker = None
        if worker is not None:
            worker.deleteLater()

    def _on_download_finished(self) -> None:
        worker = self._download_worker
        self._download_worker = None
        if worker is not None:
            worker.deleteLater()

    def dismiss(self, version: str) -> None:
        save_dismissed_version(version)
        if self._pending_info and normalize_version(version) == self._pending_info.version:
            self._pending_info = None
