"""Async wrapper around SunshineApiClient for the Qt UI."""

from __future__ import annotations

from typing import Any, Callable

from PySide6.QtCore import QObject, QThread, Signal

from app.credential_store import SunshineCredentials as StoredCredentials
from app.credential_store import clear_credentials, load_credentials, save_credentials
from app.sunshine_api import (
    SunshineApiClient,
    SunshineApiError,
    SunshineAuthError,
    SunshineCredentials,
    SunshineNotRunningError,
)


class _ApiWorker(QThread):
    finished_ok = Signal(object)
    finished_err = Signal(str)

    def __init__(self, fn: Callable[[], Any], parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._fn = fn

    def run(self) -> None:
        try:
            result = self._fn()
            self.finished_ok.emit(result)
        except SunshineAuthError as exc:
            self.finished_err.emit(f"AUTH:{exc}")
        except SunshineNotRunningError as exc:
            self.finished_err.emit(f"OFFLINE:{exc}")
        except SunshineApiError as exc:
            self.finished_err.emit(str(exc))
        except Exception as exc:  # noqa: BLE001
            self.finished_err.emit(str(exc))


class SunshineService(QObject):
    operation_finished = Signal(str, object)
    operation_failed = Signal(str, str)
    auth_required = Signal()
    session_changed = Signal()

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._base_url = "https://localhost:47990"
        self._client = SunshineApiClient(self._base_url)
        self._workers: list[_ApiWorker] = []
        self._load_saved_credentials()

    def _load_saved_credentials(self) -> None:
        stored = load_credentials()
        if stored:
            self._client.set_credentials(
                SunshineCredentials(stored.username, stored.password)
            )

    def set_base_url(self, url: str) -> None:
        self._base_url = url
        self._client = SunshineApiClient(url)
        self._load_saved_credentials()

    def has_saved_credentials(self) -> bool:
        return load_credentials() is not None

    def set_credentials(self, username: str, password: str, persist: bool = True) -> None:
        creds = SunshineCredentials(username, password)
        self._client.set_credentials(creds)
        if persist:
            save_credentials(StoredCredentials(username=username, password=password))

    def _run(self, op_name: str, fn: Callable[[], Any]) -> None:
        worker = _ApiWorker(fn, self)
        self._workers.append(worker)

        def _cleanup() -> None:
            if worker in self._workers:
                self._workers.remove(worker)
            worker.deleteLater()

        def _ok(result: object) -> None:
            _cleanup()
            self.operation_finished.emit(op_name, result)

        def _err(message: str) -> None:
            _cleanup()
            if message.startswith("AUTH:"):
                self.auth_required.emit()
                self.operation_failed.emit(op_name, message[5:])
            elif message.startswith("OFFLINE:"):
                self.operation_failed.emit(op_name, message[8:])
            else:
                self.operation_failed.emit(op_name, message)

        worker.finished_ok.connect(_ok)
        worker.finished_err.connect(_err)
        worker.start()

    def create_credentials(self, username: str, password: str, confirm: str) -> None:
        def _fn() -> bool:
            ok = self._client.create_credentials(username, password, confirm)
            if ok:
                self.set_credentials(username, password, persist=True)
                self.session_changed.emit()
            return ok

        self._run("create_credentials", _fn)

    def verify_login(self, username: str, password: str) -> None:
        def _fn() -> dict[str, Any]:
            self._client.set_credentials(SunshineCredentials(username, password))
            config = self._client.get_config()
            self.set_credentials(username, password, persist=True)
            self.session_changed.emit()
            return config

        self._run("verify_login", _fn)

    def pair_pin(self, pin: str, name: str) -> None:
        self._run("pair_pin", lambda: self._client.pair_pin(pin, name))

    def fetch_config(self) -> None:
        self._run("fetch_config", lambda: self._client.get_config(retry=True))

    def save_config(self, changes: dict[str, Any], restart: bool = False) -> None:
        def _fn() -> bool:
            self._client.save_config(changes)
            if restart:
                self._client.restart()
                self._client.wait_until_ready()
            return True

        self._run("save_config", _fn)

    def set_gamepad(self, mode: str) -> None:
        changes: dict[str, Any] = {"gamepad": mode}
        if mode == "ds4":
            changes["motion_as_ds4"] = "enabled"
            changes["touchpad_as_ds4"] = "enabled"
        self._run("set_gamepad", lambda: self._client.save_partial_config(changes))

    def fetch_clients(self) -> None:
        self._run("fetch_clients", self._client.list_clients)

    def unpair_client(self, uuid: str) -> None:
        self._run("unpair_client", lambda: self._client.unpair_client(uuid))

    def unpair_all_clients(self) -> None:
        self._run("unpair_all", self._client.unpair_all_clients)

    def fetch_apps(self) -> None:
        self._run("fetch_apps", self._client.list_apps)

    def get_cover_sync(self, index: int) -> bytes | None:
        return self._client.get_cover(index)

    def logout(self) -> None:
        self._client.set_credentials(None)
        clear_credentials()
        self.session_changed.emit()

    def change_password(
        self,
        current_username: str,
        current_password: str,
        new_username: str,
        new_password: str,
        confirm_new_password: str,
    ) -> None:
        def _fn() -> bool:
            ok = self._client.change_password(
                current_username,
                current_password,
                new_username,
                new_password,
                confirm_new_password,
            )
            if ok:
                self.set_credentials(new_username, new_password, persist=True)
                self.session_changed.emit()
            return ok

        self._run("change_password", _fn)
