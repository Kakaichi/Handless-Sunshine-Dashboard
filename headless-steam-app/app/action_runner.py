"""Run Invoke-HeadlessSteamAction.ps1 without blocking the UI."""

from __future__ import annotations

import ctypes
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from PySide6.QtCore import QObject, QProcess, QProcessEnvironment, QTimer, Signal

from app.constants import APP_DISPLAY_NAME
from app.paths import get_app_root, script_path

ACTIONS = (
    "ligar_tudo",
    "desligar_tudo",
    "alternar",
    "sunshine_ligar",
    "sunshine_desligar",
    "gamepad_ds4",
    "gamepad_x360",
    "tailscale_ligar",
    "tailscale_desligar",
    "moonlight_ligar",
    "moonlight_desligar",
    "moonlight_expose",
    "moonlight_reset_exposure",
    "moonlight_apply_settings",
    "instalar_deps",
    "atualizar_jogos",
    "open_sunshine_web",
)

MOONLIGHT_USER_ACTIONS = {
    "moonlight_ligar": ("start", "moonlight_expose"),
}

MOONLIGHT_ACTION_TIMEOUT_MS = 120_000


def _is_admin() -> bool:
    if sys.platform != "win32":
        return True
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:  # noqa: BLE001
        return False


def _get_tailscale_ipv4() -> str | None:
    if sys.platform != "win32":
        return None

    tailscale = Path(r"C:\Program Files\Tailscale\tailscale.exe")
    if not tailscale.is_file():
        return None

    creationflags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
    try:
        result = subprocess.run(
            [str(tailscale), "ip", "-4"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=15,
            creationflags=creationflags,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None

    if result.returncode != 0:
        return None

    for line in result.stdout.splitlines():
        candidate = line.strip()
        if re.fullmatch(r"\d+\.\d+\.\d+\.\d+", candidate):
            return candidate
    return None


def _apply_headless_env(process: QProcess) -> None:
    env = QProcessEnvironment.systemEnvironment()
    env.insert("HEADLESS_STEAM_APP_ROOT", str(get_app_root()))
    process.setProcessEnvironment(env)


class ActionRunner(QObject):
    line_output = Signal(str)
    started = Signal(str)
    finished = Signal(str, int)
    failed = Signal(str)

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._process: QProcess | None = None
        self._current_action: str | None = None
        self._action_log_path: Path | None = None
        self._moonlight_follow_up: str | None = None
        self._moonlight_root_action: str | None = None
        self._watchdog_timer = QTimer(self)
        self._watchdog_timer.setSingleShot(True)
        self._watchdog_timer.timeout.connect(self._on_watchdog_timeout)

    @property
    def is_running(self) -> bool:
        return self._process is not None and self._process.state() != QProcess.ProcessState.NotRunning

    @property
    def current_action(self) -> str | None:
        return self._current_action

    def run(self, action: str) -> None:
        if action not in ACTIONS:
            self.failed.emit(f"Acao desconhecida: {action}")
            return
        if self.is_running:
            self.failed.emit("Ja existe uma acao em execucao.")
            return

        if action in MOONLIGHT_USER_ACTIONS:
            self._run_moonlight_user_action(action)
            return

        if action == "moonlight_desligar":
            self._start_invoke_action(action)
            return

        self._start_invoke_action(action)

    def _emit_started(self, action: str) -> None:
        display = self._moonlight_root_action or action
        self.started.emit(display)
        timeout_ms = MOONLIGHT_ACTION_TIMEOUT_MS if action in {
            "moonlight_ligar",
            "moonlight_expose",
            "moonlight_apply_settings",
        } else 180_000
        self._watchdog_timer.start(timeout_ms)

    def _stop_watchdog(self) -> None:
        self._watchdog_timer.stop()

    def _on_watchdog_timeout(self) -> None:
        if not self._process or self._process.state() == QProcess.ProcessState.NotRunning:
            return
        self._process.kill()
        action = self._moonlight_root_action or self._current_action or "acao"
        self._stop_watchdog()
        self.failed.emit(
            f"Tempo esgotado ao executar {action}. Moonlight Web pode estar ligado; verifique Tailscale."
        )

    def _run_moonlight_user_action(self, action: str) -> None:
        user_action, follow_up = MOONLIGHT_USER_ACTIONS[action]
        user_script = script_path("Start-MoonlightWeb-UserProcess.ps1")
        if not user_script.is_file():
            self.failed.emit(f"Script nao encontrado: {user_script}")
            return

        self._current_action = action
        self._moonlight_root_action = action
        self._moonlight_follow_up = follow_up
        self._action_log_path = None
        self._process = QProcess(self)
        self._process.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        self._process.readyReadStandardOutput.connect(self._on_output)
        self._process.finished.connect(self._on_finished)
        self._process.errorOccurred.connect(self._on_error)
        _apply_headless_env(self._process)

        ps_args = [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(user_script),
            "-Action",
            user_action,
            "-AppRoot",
            str(get_app_root()),
        ]
        tailscale_ip = _get_tailscale_ipv4()
        if tailscale_ip:
            ps_args.extend(["-TailscaleIp", tailscale_ip])

        self._emit_started(action)
        # Run elevated (exe is already admin). The PS script starts web-server in the
        # interactive user session via cmd start — same approach as moonlight-web/iniciar.bat.
        self._process.start("powershell.exe", ps_args[1:])

    def _start_invoke_action(self, action: str) -> None:
        invoke = script_path("Invoke-HeadlessSteamAction.ps1")
        if not invoke.is_file():
            self.failed.emit(f"Script nao encontrado: {invoke}")
            return

        self._current_action = action
        self._moonlight_follow_up = None
        self._action_log_path = None
        self._process = QProcess(self)
        self._process.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        self._process.readyReadStandardOutput.connect(self._on_output)
        self._process.finished.connect(self._on_finished)
        self._process.errorOccurred.connect(self._on_error)
        _apply_headless_env(self._process)

        self._emit_started(action)
        if _is_admin():
            self._process.start(
                "powershell.exe",
                [
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(invoke),
                    "-Action",
                    action,
                ],
            )
            return

        log_path = Path(tempfile.gettempdir()) / f"headless-steam-{os.getpid()}-{action}.log"
        self._action_log_path = log_path
        if log_path.exists():
            log_path.unlink()

        wrapper = script_path("Run-ElevatedHeadlessSteamAction.ps1")
        app_root = str(get_app_root()).replace("'", "''")
        command = (
            "$p = Start-Process powershell -Verb RunAs -PassThru -Wait -ArgumentList @("
            "'-NoProfile','-ExecutionPolicy','Bypass','-File',"
            f"'{wrapper}','-Action','{action}','-LogPath','{log_path}','-AppRoot','{app_root}'"
            "); exit $p.ExitCode"
        )
        self._process.start(
            "powershell.exe",
            ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command],
        )

    def _emit_log_file(self, path: Path) -> None:
        if not path.is_file():
            return
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return
        for line in text.splitlines():
            if line.strip():
                self.line_output.emit(line.rstrip())

    def _on_output(self) -> None:
        if not self._process:
            return
        data = bytes(self._process.readAllStandardOutput()).decode("utf-8", errors="replace")
        for line in data.splitlines():
            if line.strip():
                self.line_output.emit(line.rstrip())

    def _on_finished(self, exit_code: int, _status: QProcess.ExitStatus) -> None:
        self._stop_watchdog()
        if self._action_log_path is not None:
            self._emit_log_file(self._action_log_path)
            try:
                self._action_log_path.unlink(missing_ok=True)
            except OSError:
                pass

        action = self._current_action or ""
        follow_up = self._moonlight_follow_up
        root_action = self._moonlight_root_action
        self._current_action = None
        self._moonlight_follow_up = None
        self._action_log_path = None
        self._process = None

        if follow_up and exit_code == 0:
            QTimer.singleShot(2000, lambda: self._start_invoke_action(follow_up))
            return

        self._moonlight_root_action = None
        self.finished.emit(root_action or action, exit_code)

    def _on_error(self, error: QProcess.ProcessError) -> None:
        self._stop_watchdog()
        if error == QProcess.ProcessError.FailedToStart:
            self.failed.emit(
                f"Nao foi possivel iniciar PowerShell. Execute o {APP_DISPLAY_NAME} como administrador."
            )
