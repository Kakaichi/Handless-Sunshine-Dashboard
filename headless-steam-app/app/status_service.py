"""Poll HeadlessSteam-Status.ps1 and expose JSON status to the UI."""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass, replace
from typing import Any

from PySide6.QtCore import QObject, QThread, QTimer, Signal

from app.paths import get_app_root, script_path


@dataclass
class HeadlessSteamStatus:
    sunshine_running: bool = False
    tailscale_running: bool = False
    tailscale_connected: bool = False
    tailscale_ip: str | None = None
    moonlight_running: bool = False
    moonlight_funnel_enabled: bool = False
    moonlight_funnel_active: bool = False
    moonlight_funnel_url: str | None = None
    moonlight_skip_login_enabled: bool = False
    tailscale_funnel_allowed: bool = False
    tailscale_funnel_setup_url: str = "https://login.tailscale.com/admin/acls/file"
    tailscale_funnel_acl_setup_url: str = "https://login.tailscale.com/admin/acls/file"
    gamepad_mode: str = "auto"
    lan_ip: str | None = None
    sunshine_web_port: int = 47990
    sunshine_panel_url: str = "https://localhost:47990"
    sunshine_needs_setup: bool = False
    sunshine_account_state: str = "unknown"
    sunshine_username: str | None = None
    moonlight_local_url: str = "http://localhost:8080"
    moonlight_tailscale_url: str | None = None

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> HeadlessSteamStatus:
        return cls(
            sunshine_running=bool(data.get("SunshineRunning")),
            tailscale_running=bool(data.get("TailscaleRunning")),
            tailscale_connected=bool(data.get("TailscaleConnected")),
            tailscale_ip=data.get("TailscaleIp") or None,
            moonlight_running=bool(data.get("MoonlightRunning")),
            moonlight_funnel_enabled=bool(data.get("MoonlightFunnelEnabled")),
            moonlight_funnel_active=bool(data.get("MoonlightFunnelActive")),
            moonlight_funnel_url=data.get("MoonlightFunnelUrl") or None,
            moonlight_skip_login_enabled=bool(data.get("MoonlightSkipLoginEnabled")),
            tailscale_funnel_allowed=bool(data.get("TailscaleFunnelAllowed")),
            tailscale_funnel_setup_url=str(
                data.get("TailscaleFunnelSetupUrl") or "https://login.tailscale.com/admin/acls/file"
            ),
            tailscale_funnel_acl_setup_url=str(
                data.get("TailscaleFunnelAclSetupUrl") or "https://login.tailscale.com/admin/acls/file"
            ),
            gamepad_mode=str(data.get("GamepadMode") or "auto"),
            lan_ip=data.get("LanIp") or None,
            sunshine_web_port=int(data.get("SunshineWebPort") or 47990),
            sunshine_panel_url=str(data.get("SunshinePanelUrl") or "https://localhost:47990"),
            sunshine_needs_setup=bool(data.get("SunshineNeedsSetup")),
            sunshine_account_state=str(data.get("SunshineAccountState") or "unknown"),
            sunshine_username=data.get("SunshineUsername") or None,
            moonlight_local_url=str(data.get("MoonlightLocalUrl") or "http://localhost:8080"),
            moonlight_tailscale_url=data.get("MoonlightTailscaleUrl") or None,
        )


def fetch_status(*, quick: bool = False) -> HeadlessSteamStatus:
    ps1 = script_path("HeadlessSteam-Status.ps1")
    args = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(ps1),
    ]
    if quick:
        args.append("-Quick")

    env = os.environ.copy()
    env.setdefault("HEADLESS_STEAM_APP_ROOT", str(get_app_root()))

    result = subprocess.run(
        args,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=20 if quick else 60,
        creationflags=subprocess.CREATE_NO_WINDOW,
        env=env,
    )
    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        raise RuntimeError(stderr or f"Status script falhou (codigo {result.returncode})")

    raw = (result.stdout or "").strip()
    if not raw:
        raise RuntimeError("Status script retornou vazio")

    if raw and ord(raw[0]) == 0xFEFF:
        raw = raw[1:]

    data = json.loads(raw)
    return HeadlessSteamStatus.from_dict(data)


class _StatusWorker(QThread):
    finished_ok = Signal(object, bool)
    finished_err = Signal(str)

    def __init__(self, *, quick: bool, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._quick = quick

    def run(self) -> None:
        try:
            self.finished_ok.emit(fetch_status(quick=self._quick), self._quick)
        except Exception as exc:  # noqa: BLE001 - surface to UI
            self.finished_err.emit(str(exc))


class StatusService(QObject):
    status_changed = Signal(object)
    error = Signal(str)

    def __init__(self, parent: QObject | None = None, interval_ms: int = 3000) -> None:
        super().__init__(parent)
        self._timer = QTimer(self)
        self._timer.setInterval(interval_ms)
        self._timer.timeout.connect(self.refresh)
        self._last_status: HeadlessSteamStatus | None = None
        self._worker: _StatusWorker | None = None
        self._refresh_pending = False
        self._refresh_pending_full = False
        self._stopped = False
        self._poll_count = 0
        self._status_epoch = 0

    def start(self) -> None:
        self._stopped = False
        self.refresh()
        self._timer.start()

    def stop(self) -> None:
        self._stopped = True
        self._refresh_pending = False
        self._refresh_pending_full = False
        self._timer.stop()

    @property
    def last_status(self) -> HeadlessSteamStatus | None:
        return self._last_status

    def apply_local_status(self, status: HeadlessSteamStatus, *, invalidate_polls: bool = False) -> None:
        if invalidate_polls:
            self._status_epoch += 1
        self._last_status = status
        self.status_changed.emit(status)

    def refresh(self, *, full: bool = False) -> None:
        if self._stopped:
            return
        if full:
            self._refresh_pending_full = True
            self._status_epoch += 1
        if self._worker is not None and self._worker.isRunning():
            self._refresh_pending = True
            return
        self._start_worker(full=full or self._refresh_pending_full)

    def _start_worker(self, *, full: bool = False) -> None:
        self._refresh_pending_full = False
        quick = not full and (self._poll_count == 0 or self._poll_count % 5 != 0)
        worker_epoch = self._status_epoch
        worker = _StatusWorker(quick=quick, parent=self)
        self._worker = worker
        worker.finished_ok.connect(
            lambda status, is_quick, epoch=worker_epoch: self._on_worker_ok(status, is_quick, epoch)
        )
        worker.finished_err.connect(self._on_worker_err)
        worker.finished.connect(self._on_worker_finished)
        worker.start()

    def _merge_sticky_funnel_fields(
        self,
        status: HeadlessSteamStatus,
        previous: HeadlessSteamStatus,
    ) -> HeadlessSteamStatus:
        if not status.moonlight_funnel_enabled:
            return status

        updates: dict[str, object] = {}
        if not status.moonlight_funnel_url and previous.moonlight_funnel_url:
            updates["moonlight_funnel_url"] = previous.moonlight_funnel_url
            updates["moonlight_funnel_active"] = True
        if not status.tailscale_funnel_allowed and previous.tailscale_funnel_allowed:
            updates["tailscale_funnel_allowed"] = True

        if updates:
            return replace(status, **updates)
        return status

    def _on_worker_ok(self, status: HeadlessSteamStatus, quick: bool, worker_epoch: int) -> None:
        if self._stopped or worker_epoch != self._status_epoch:
            return
        if quick and self._last_status is not None:
            status = self._merge_sticky_funnel_fields(status, self._last_status)
        self._poll_count += 1
        self._last_status = status
        self.status_changed.emit(status)

    def _on_worker_err(self, message: str) -> None:
        if self._stopped:
            return
        self.error.emit(message)

    def _on_worker_finished(self) -> None:
        worker = self._worker
        self._worker = None
        if worker is not None:
            worker.deleteLater()

        if self._stopped or not self._refresh_pending:
            self._refresh_pending = False
            return

        self._refresh_pending = False
        self._start_worker(full=self._refresh_pending_full)
