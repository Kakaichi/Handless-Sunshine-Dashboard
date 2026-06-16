"""Poll HeadlessSteam-Status.ps1 and expose JSON status to the UI."""

from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass, replace
from typing import Any

from PySide6.QtCore import QObject, QThread, QTimer, Signal

from app.moonlight_settings_store import load_settings
from app.paths import get_app_root, script_path

_QUICK_STATUS_FIELDS = frozenset({
    "sunshine_running",
    "tailscale_running",
    "tailscale_connected",
    "tailscale_ip",
    "tailscale_health",
    "tailscale_needs_login",
    "tailscale_is_starting",
    "moonlight_running",
    "moonlight_funnel_enabled",
    "moonlight_skip_login_enabled",
    "moonlight_tailscale_url",
})


@dataclass
class HeadlessSteamStatus:
    sunshine_running: bool = False
    tailscale_running: bool = False
    tailscale_connected: bool = False
    tailscale_ip: str | None = None
    tailscale_health: str | None = None
    tailscale_needs_login: bool = False
    tailscale_is_starting: bool = False
    moonlight_running: bool = False
    moonlight_funnel_enabled: bool = False
    moonlight_funnel_active: bool = False
    moonlight_funnel_url: str | None = None
    moonlight_skip_login_enabled: bool = False
    tailscale_funnel_allowed: bool = False
    tailscale_funnel_setup_url: str = "https://login.tailscale.com/admin/acls/file"
    tailscale_funnel_acl_setup_url: str = "https://login.tailscale.com/admin/acls/file"
    tailscale_funnel_acl_ok: bool = False
    tailscale_magic_dns_ok: bool = False
    tailscale_https_ok: bool = False
    tailscale_funnel_requirements_met: bool = False
    tailscale_funnel_dns_setup_url: str = "https://login.tailscale.com/admin/dns"
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
            tailscale_health=data.get("TailscaleHealth") or None,
            tailscale_needs_login=bool(data.get("TailscaleNeedsLogin")),
            tailscale_is_starting=bool(data.get("TailscaleIsStarting")),
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
            tailscale_funnel_acl_ok=bool(data.get("TailscaleFunnelAclOk")),
            tailscale_magic_dns_ok=bool(data.get("TailscaleMagicDnsOk")),
            tailscale_https_ok=bool(data.get("TailscaleHttpsOk")),
            tailscale_funnel_requirements_met=bool(data.get("TailscaleFunnelRequirementsMet")),
            tailscale_funnel_dns_setup_url=str(
                data.get("TailscaleFunnelDnsSetupUrl") or "https://login.tailscale.com/admin/dns"
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


def _windows_service_running(service_name: str) -> bool:
    try:
        completed = subprocess.run(
            ["sc", "query", service_name],
            capture_output=True,
            text=True,
            timeout=5,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return "RUNNING" in (completed.stdout or "")


def _process_image_running(image_name: str) -> bool:
    try:
        completed = subprocess.run(
            ["tasklist", "/FI", f"IMAGENAME eq {image_name}", "/NH"],
            capture_output=True,
            text=True,
            timeout=5,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    return image_name.lower() in (completed.stdout or "").lower()


_TAILSCALE_IPV4_RE = re.compile(r"\b(100(?:\.\d{1,3}){3})\b")
_TAILSCALE_EXE = r"C:\Program Files\Tailscale\tailscale.exe"


def _parse_tailscale_ipv4_from_ipconfig(text: str) -> str | None:
    lines = text.splitlines()
    in_tailscale = False
    for line in lines:
        if re.search(r"tailscale", line, re.IGNORECASE):
            in_tailscale = True
            continue

        stripped = line.strip()
        if not stripped:
            if in_tailscale:
                in_tailscale = False
            continue

        if in_tailscale and ("IPv4" in line or "Endere" in line):
            match = re.search(r"(\d+\.\d+\.\d+\.\d+)", line)
            if match and match.group(1).startswith("100."):
                return match.group(1)

    match = _TAILSCALE_IPV4_RE.search(text)
    return match.group(1) if match else None


def _query_tailscale_ipv4_cli() -> str | None:
    if not os.path.isfile(_TAILSCALE_EXE):
        return None
    try:
        completed = subprocess.run(
            [_TAILSCALE_EXE, "ip", "-4"],
            capture_output=True,
            text=True,
            timeout=4,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in (completed.stdout or "").splitlines():
        ip = line.strip()
        if ip.startswith("100."):
            return ip
    return None


def _query_tailscale_ipv4_fast() -> str | None:
    try:
        completed = subprocess.run(
            ["ipconfig"],
            capture_output=True,
            text=True,
            encoding="cp850",
            errors="replace",
            timeout=2,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.TimeoutExpired):
        return _query_tailscale_ipv4_cli()

    ip = _parse_tailscale_ipv4_from_ipconfig(completed.stdout or "")
    return ip or _query_tailscale_ipv4_cli()


def _tailscale_vpn_active() -> bool:
    if not _windows_service_running("Tailscale"):
        return False
    if _query_tailscale_ipv4_fast():
        return True
    if not os.path.isfile(_TAILSCALE_EXE):
        return False
    try:
        completed = subprocess.run(
            [_TAILSCALE_EXE, "status"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=3,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False

    text = f"{completed.stdout or ''}\n{completed.stderr or ''}".lower()
    if "tailscale is stopped" in text or "logged out" in text:
        return False
    if "starting" in text or "please wait" in text:
        return True
    return completed.returncode == 0 and "100." in text


def _query_tailscale_connection_state() -> dict[str, object]:
    result: dict[str, object] = {
        "needs_login": False,
        "is_starting": False,
        "health": None,
    }
    if not os.path.isfile(_TAILSCALE_EXE):
        return result

    try:
        completed = subprocess.run(
            [_TAILSCALE_EXE, "status", "--json"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=4,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
    except (OSError, subprocess.TimeoutExpired):
        result["is_starting"] = True
        return result

    raw = (completed.stdout or "").strip()
    if not raw:
        result["is_starting"] = True
        return result

    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        result["is_starting"] = True
        return result

    backend = str(data.get("BackendState") or "")
    if re.search(r"needslogin", backend, re.I):
        result["needs_login"] = True

    for line in data.get("Health") or []:
        health = str(line)
        if not health:
            continue
        if not result["health"]:
            result["health"] = health
        lower = health.lower()
        if "logged out" in lower or "log in" in lower or "login" in lower:
            result["needs_login"] = True
        if "starting" in lower or "please wait" in lower:
            result["is_starting"] = True

    return result


def fetch_quick_status() -> HeadlessSteamStatus:
    settings = load_settings()
    sunshine_running = _windows_service_running("SunshineService")
    tailscale_running = _tailscale_vpn_active()
    tailscale_ip = _query_tailscale_ipv4_fast() if tailscale_running else None
    tailscale_needs_login = False
    tailscale_is_starting = False
    tailscale_health: str | None = None
    if tailscale_running and not tailscale_ip:
        hints = _query_tailscale_connection_state()
        tailscale_needs_login = bool(hints["needs_login"])
        tailscale_is_starting = bool(hints["is_starting"])
        tailscale_health = hints["health"]  # type: ignore[assignment]

    return HeadlessSteamStatus(
        sunshine_running=sunshine_running,
        tailscale_running=tailscale_running,
        tailscale_connected=bool(tailscale_ip),
        tailscale_ip=tailscale_ip,
        tailscale_health=tailscale_health,
        tailscale_needs_login=tailscale_needs_login,
        tailscale_is_starting=tailscale_is_starting,
        moonlight_running=_process_image_running("web-server.exe"),
        moonlight_funnel_enabled=settings.public_funnel_enabled,
        moonlight_skip_login_enabled=settings.skip_login_enabled,
        moonlight_tailscale_url=f"http://{tailscale_ip}:8080" if tailscale_ip else None,
    )


def fetch_status(*, quick: bool = False) -> HeadlessSteamStatus:
    if quick:
        return fetch_quick_status()

    ps1 = script_path("HeadlessSteam-Status.ps1")
    args = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(ps1),
    ]

    env = os.environ.copy()
    env.setdefault("HEADLESS_STEAM_APP_ROOT", str(get_app_root()))

    result = subprocess.run(
        args,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=60,
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
        try:
            quick = fetch_quick_status()
            self._last_status = quick
            self._poll_count = 1
            self.status_changed.emit(quick)
        except Exception:
            pass
        self.refresh()
        QTimer.singleShot(250, lambda: self.refresh(full=True))
        self._timer.start()

    def stop(self) -> None:
        self._stopped = True
        self._refresh_pending = False
        self._refresh_pending_full = False
        self._timer.stop()
        worker = self._worker
        if worker is not None and worker.isRunning():
            worker.wait(5000)

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
        if self._worker is not None and self._worker.isRunning():
            self._refresh_pending = True
            return
        self._start_worker(full=full or self._refresh_pending_full)

    def _start_worker(self, *, full: bool = False) -> None:
        if self._worker is not None and self._worker.isRunning():
            self._refresh_pending = True
            if full:
                self._refresh_pending_full = True
            return

        self._refresh_pending_full = False
        needs_full = full or (self._poll_count > 0 and self._poll_count % 12 == 0)
        quick = not needs_full
        worker_epoch = self._status_epoch
        worker = _StatusWorker(quick=quick, parent=self)
        self._worker = worker
        worker.finished_ok.connect(
            lambda status, is_quick, epoch=worker_epoch: self._on_worker_ok(status, is_quick, epoch)
        )
        worker.finished_err.connect(self._on_worker_err)
        worker.finished.connect(lambda w=worker: self._on_worker_finished(w))
        worker.start()

    def _merge_quick_status(
        self,
        status: HeadlessSteamStatus,
        previous: HeadlessSteamStatus,
    ) -> HeadlessSteamStatus:
        updates = {field: getattr(status, field) for field in _QUICK_STATUS_FIELDS}

        if status.tailscale_running:
            if status.tailscale_ip:
                updates["tailscale_connected"] = True
                updates["moonlight_tailscale_url"] = f"http://{status.tailscale_ip}:8080"
            else:
                updates["tailscale_connected"] = False
                updates["tailscale_ip"] = None
                updates["moonlight_tailscale_url"] = None
        else:
            updates["tailscale_connected"] = False
            updates["tailscale_ip"] = None
            updates["moonlight_tailscale_url"] = None

        merged = replace(previous, **updates)

        if not merged.moonlight_funnel_enabled:
            return merged

        sticky: dict[str, object] = {}
        if not merged.moonlight_funnel_url and previous.moonlight_funnel_url:
            sticky["moonlight_funnel_url"] = previous.moonlight_funnel_url
            sticky["moonlight_funnel_active"] = True
        if not merged.tailscale_funnel_allowed and previous.tailscale_funnel_allowed:
            sticky["tailscale_funnel_allowed"] = True

        if sticky:
            return replace(merged, **sticky)
        return merged

    def _on_worker_ok(self, status: HeadlessSteamStatus, quick: bool, worker_epoch: int) -> None:
        if self._stopped or worker_epoch != self._status_epoch:
            return
        if quick and self._last_status is not None:
            status = self._merge_quick_status(status, self._last_status)
        self._poll_count += 1
        self._last_status = status
        self.status_changed.emit(status)

    def _on_worker_err(self, message: str) -> None:
        if self._stopped:
            return
        if self._last_status is not None:
            return
        self.error.emit(message)

    def _on_worker_finished(self, worker: _StatusWorker) -> None:
        if self._worker is worker:
            self._worker = None
        worker.deleteLater()

        if self._stopped or not self._refresh_pending:
            self._refresh_pending = False
            return

        if self._worker is not None and self._worker.isRunning():
            return

        self._refresh_pending = False
        self._start_worker(full=self._refresh_pending_full)
