"""Moonlight Web configuration and user management."""

from __future__ import annotations

import http.cookiejar
import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from PySide6.QtCore import QObject, QThread, Signal

from app.moonlight_credential_store import (
    MoonlightCredentials,
    load_credentials,
    save_credentials,
)
from app.moonlight_settings_store import MoonlightSettings, load_settings, save_settings
from app.paths import get_moonlight_web_dir


class MoonlightApiError(Exception):
    pass


class MoonlightAuthError(MoonlightApiError):
    pass


class MoonlightOfflineError(MoonlightApiError):
    pass


@dataclass
class MoonlightUser:
    user_id: str
    name: str
    role_name: str
    is_admin: bool
    role_id: str | None = None


@dataclass
class MoonlightRole:
    role_id: str
    name: str
    role_type: str


def _lookup_role(roles: dict[Any, Any], role_id: Any) -> dict[str, Any]:
    if role_id is None or role_id == "":
        return {}
    key = str(role_id)
    role = roles.get(key)
    if isinstance(role, dict):
        return role
    if isinstance(role_id, int):
        role = roles.get(role_id)
        if isinstance(role, dict):
            return role
    return {}


def _resolve_user_role(
    user: dict[str, Any], roles: dict[Any, Any]
) -> tuple[str, bool, str | None]:
    role_id_raw = user.get("role_id")
    role_id = str(role_id_raw) if role_id_raw is not None else None

    if role_id is not None:
        role = _lookup_role(roles, role_id_raw)
        if role:
            role_type = str(role.get("ty", "User"))
            role_name = str(role.get("name", "Usuario"))
            is_admin = role_type.lower() == "admin"
            display = "Admin" if is_admin else (role_name or "Usuario")
            return display, is_admin, role_id

    legacy_role = str(user.get("role", "")).strip()
    if legacy_role:
        is_admin = legacy_role.lower() == "admin"
        display = "Admin" if is_admin else "Usuario"
        return display, is_admin, None

    return "Usuario", False, None


def _parse_roles_from_api(data: Any) -> list[MoonlightRole]:
    if not isinstance(data, dict):
        return []
    roles_raw = data.get("roles")
    if isinstance(roles_raw, list):
        items = roles_raw
    elif isinstance(roles_raw, dict):
        items = [
            {"id": role_id, **role}
            for role_id, role in roles_raw.items()
            if isinstance(role, dict)
        ]
    else:
        return []

    result: list[MoonlightRole] = []
    for role in items:
        if not isinstance(role, dict):
            continue
        role_id = role.get("id", role.get("role_id"))
        if role_id is None:
            continue
        result.append(
            MoonlightRole(
                role_id=str(role_id),
                name=str(role.get("name", role_id)),
                role_type=str(role.get("ty", "User")),
            )
        )
    return sorted(result, key=lambda item: item.name.lower())


class _MoonlightWorker(QThread):
    finished_ok = Signal(object)
    finished_err = Signal(str)

    def __init__(self, fn: Callable[[], Any], parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._fn = fn

    def run(self) -> None:
        try:
            result = self._fn()
            self.finished_ok.emit(result)
        except MoonlightAuthError as exc:
            self.finished_err.emit(f"AUTH:{exc}")
        except MoonlightOfflineError as exc:
            self.finished_err.emit(f"OFFLINE:{exc}")
        except MoonlightApiError as exc:
            self.finished_err.emit(str(exc))
        except Exception as exc:  # noqa: BLE001
            self.finished_err.emit(str(exc))


class MoonlightApiClient:
    def __init__(self, base_url: str = "http://localhost:8080") -> None:
        self._base_url = base_url.rstrip("/")
        self._cookie_jar = http.cookiejar.CookieJar()
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self._cookie_jar)
        )

    def _request(
        self,
        method: str,
        endpoint: str,
        payload: dict[str, Any] | None = None,
        timeout: int = 15,
    ) -> Any:
        url = f"{self._base_url}/api{endpoint}"
        data = None
        headers = {"Accept": "application/json"}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"

        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with self._opener.open(request, timeout=timeout) as response:
                body = response.read().decode("utf-8", errors="replace")
                if not body:
                    return None
                return json.loads(body)
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                detail = exc.read().decode("utf-8", errors="replace").strip()
            except Exception:  # noqa: BLE001
                pass
            if exc.code in (401, 403):
                message = "Credenciais invalidas ou sem permissao de admin."
                if detail:
                    message = f"{message} ({detail})"
                raise MoonlightAuthError(message) from exc
            if detail:
                raise MoonlightApiError(f"HTTP {exc.code}: {detail}") from exc
            raise MoonlightApiError(f"HTTP {exc.code}") from exc
        except urllib.error.URLError as exc:
            raise MoonlightOfflineError("Moonlight Web nao esta acessivel em localhost:8080.") from exc

    def login(self, username: str, password: str) -> None:
        self._cookie_jar.clear()
        self._request("POST", "/login", {"name": username, "password": password})

    def authenticate(self) -> None:
        """Confirm session cookie is valid. Moonlight may return an empty body."""
        self._request("GET", "/authenticate")

    def get_current_user(self) -> dict[str, Any]:
        result = self._request("GET", "/user")
        if not isinstance(result, dict):
            raise MoonlightApiError("Resposta de usuario invalida.")
        return result

    def list_users(self) -> dict[str, Any]:
        result = self._request("GET", "/users")
        if not isinstance(result, dict):
            raise MoonlightApiError("Resposta de usuarios invalida.")
        return result

    def list_roles(self) -> dict[str, Any]:
        result = self._request("GET", "/roles")
        if not isinstance(result, dict):
            raise MoonlightApiError("Resposta de perfis invalida.")
        return result

    def create_user(
        self,
        name: str,
        password: str,
        role_id: str,
        client_unique_id: str | None = None,
    ) -> None:
        self._request(
            "POST",
            "/user",
            {
                "name": name,
                "password": password,
                "role_id": int(role_id),
                "client_unique_id": client_unique_id or name,
            },
        )

    def patch_user(
        self,
        user_id: str,
        role_id: str,
        password: str | None = None,
        client_unique_id: str | None = None,
    ) -> None:
        payload: dict[str, Any] = {
            "id": int(user_id),
            "role_id": int(role_id),
        }
        if password is not None:
            payload["password"] = password
        if client_unique_id is not None:
            payload["client_unique_id"] = client_unique_id
        self._request("PATCH", "/user", payload)

    def delete_user(self, user_id: str) -> None:
        self._request("DELETE", "/user", {"id": int(user_id)})


class MoonlightService(QObject):
    operation_finished = Signal(str, object)
    operation_failed = Signal(str, str)
    auth_required = Signal()

    def __init__(self, parent: QObject | None = None) -> None:
        super().__init__(parent)
        self._client = MoonlightApiClient()
        self._workers: list[_MoonlightWorker] = []

    @staticmethod
    def data_path() -> Path:
        return get_moonlight_web_dir() / "package" / "server" / "data.json"

    def data_mtime(self) -> float | None:
        path = self.data_path()
        if not path.exists():
            return None
        return path.stat().st_mtime

    def load_settings(self) -> MoonlightSettings:
        return load_settings()

    def save_settings(self, settings: MoonlightSettings) -> None:
        save_settings(settings)

    def has_saved_credentials(self) -> bool:
        return load_credentials() is not None

    def _load_data(self) -> dict[str, Any]:
        path = self.data_path()
        if not path.exists():
            return {"users": {}, "roles": {}}
        return json.loads(path.read_text(encoding="utf-8"))

    def _save_data(self, data: dict[str, Any]) -> None:
        path = self.data_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, indent=2), encoding="utf-8")

    def get_user_from_disk(self, user_id: str) -> MoonlightUser | None:
        for user in self.list_users_from_disk():
            if user.user_id == user_id:
                return user
        return None

    def list_users_from_disk(self) -> list[MoonlightUser]:
        data = self._load_data()
        users = data.get("users") or {}
        roles = data.get("roles") or {}
        result: list[MoonlightUser] = []

        for user_id, user in users.items():
            if not isinstance(user, dict):
                continue
            role_name, is_admin, role_id = _resolve_user_role(user, roles)
            result.append(
                MoonlightUser(
                    user_id=str(user_id),
                    name=str(user.get("name", user_id)),
                    role_name=role_name,
                    is_admin=is_admin,
                    role_id=role_id,
                )
            )
        return sorted(result, key=lambda item: item.name.lower())

    def list_roles_from_disk(self) -> list[MoonlightRole]:
        data = self._load_data()
        roles = data.get("roles") or {}
        result: list[MoonlightRole] = []
        for role_id, role in roles.items():
            if not isinstance(role, dict):
                continue
            result.append(
                MoonlightRole(
                    role_id=str(role_id),
                    name=str(role.get("name", role_id)),
                    role_type=str(role.get("ty", "User")),
                )
            )
        return sorted(result, key=lambda item: item.name.lower())

    def list_roles_from_api(self) -> list[MoonlightRole]:
        data = self._client.list_roles()
        return _parse_roles_from_api(data)

    def _count_admins(self, data: dict[str, Any]) -> int:
        users = data.get("users") or {}
        roles = data.get("roles") or {}
        count = 0
        for user in users.values():
            if not isinstance(user, dict):
                continue
            _, is_admin, _ = _resolve_user_role(user, roles)
            if is_admin:
                count += 1
        return count

    def would_remove_last_admin(self, user_id: str, new_role_id: str) -> bool:
        data = self._load_data()
        users = data.get("users") or {}
        roles = data.get("roles") or {}
        user = users.get(user_id)
        if not isinstance(user, dict):
            return False

        _, was_admin, _ = _resolve_user_role(user, roles)
        if not was_admin:
            return False

        new_role = _lookup_role(roles, new_role_id)
        if str(new_role.get("ty", "")).lower() == "admin":
            return False

        return self._count_admins(data) <= 1

    def delete_user_from_disk(self, user_id: str) -> None:
        data = self._load_data()
        users = data.get("users") or {}
        if user_id not in users:
            raise MoonlightApiError("Usuario nao encontrado.")

        user = users[user_id]
        if not isinstance(user, dict):
            raise MoonlightApiError("Usuario invalido.")

        roles = data.get("roles") or {}
        _, is_admin, _ = _resolve_user_role(user, roles)
        if is_admin and self._count_admins(data) <= 1:
            raise MoonlightApiError("Nao e possivel excluir o ultimo administrador.")

        del users[user_id]
        data["users"] = users
        self._save_data(data)

    def _ensure_client_auth(self, username: str | None = None, password: str | None = None) -> None:
        user = username
        pwd = password
        if not user or not pwd:
            stored = load_credentials()
            if not stored:
                raise MoonlightAuthError("Informe as credenciais de admin do Moonlight Web.")
            user = stored.username
            pwd = stored.password

        self._client.login(user, pwd)
        self._client.authenticate()
        current = self._client.get_current_user()
        role = str(current.get("role", ""))
        if role.lower() != "admin":
            raise MoonlightAuthError("A conta precisa ser Admin.")

        save_credentials(MoonlightCredentials(username=user, password=pwd))

    def _run(
        self,
        op_name: str,
        fn: Callable[[], Any],
        *,
        notify_auth: bool = True,
    ) -> None:
        worker = _MoonlightWorker(fn, self)
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
                if notify_auth:
                    self.auth_required.emit()
            elif message.startswith("OFFLINE:"):
                self.operation_failed.emit(op_name, message[8:])
            else:
                self.operation_failed.emit(op_name, message)

        worker.finished_ok.connect(_ok)
        worker.finished_err.connect(_err)
        worker.start()

    def warm_saved_session(self) -> None:
        """Login silently with stored admin credentials (e.g. after Moonlight starts)."""
        if not load_credentials():
            return

        def _fn() -> bool:
            self._ensure_client_auth()
            return True

        self._run("warm_session", _fn, notify_auth=False)

    def fetch_roles(
        self,
        username: str | None = None,
        admin_password: str | None = None,
    ) -> None:
        def _fn() -> list[MoonlightRole]:
            self._ensure_client_auth(username, admin_password)
            return self.list_roles_from_api()

        self._run("fetch_roles", _fn)

    def refresh_users(self) -> None:
        def _fn() -> list[MoonlightUser]:
            return self.list_users_from_disk()

        self._run("refresh_users", _fn)

    def bootstrap_first_admin(self, name: str, password: str) -> None:
        """Create the first Moonlight Web user via POST /login (becomes admin)."""

        def _fn() -> bool:
            if self.list_users_from_disk():
                raise MoonlightApiError("Ja existem usuarios. Use criar usuario normal.")
            self._client.login(name, password)
            self._client.authenticate()
            current = self._client.get_current_user()
            role = str(current.get("role", ""))
            if role.lower() != "admin":
                raise MoonlightApiError(
                    "Moonlight Web nao criou o primeiro usuario como administrador."
                )
            save_credentials(MoonlightCredentials(username=name, password=password))
            return True

        self._run("bootstrap_first_admin", _fn)

    def create_user(
        self,
        name: str,
        password: str,
        role_id: str,
        username: str | None = None,
        admin_password: str | None = None,
    ) -> None:
        def _fn() -> bool:
            self._ensure_client_auth(username, admin_password)
            self._client.create_user(name, password, role_id)
            return True

        self._run("create_user", _fn)

    def update_user(
        self,
        user_id: str,
        role_id: str,
        password: str | None = None,
        username: str | None = None,
        admin_password: str | None = None,
    ) -> None:
        def _fn() -> bool:
            if self.would_remove_last_admin(user_id, role_id):
                raise MoonlightApiError("Nao e possivel remover o ultimo administrador.")
            self._ensure_client_auth(username, admin_password)
            self._client.patch_user(user_id, role_id, password=password)
            return True

        self._run("update_user", _fn)

    def delete_user(
        self,
        user_id: str,
        *,
        use_api: bool,
        username: str | None = None,
        admin_password: str | None = None,
    ) -> None:
        def _fn() -> bool:
            if use_api:
                data = self._load_data()
                users = data.get("users") or {}
                user = users.get(user_id)
                roles = data.get("roles") or {}
                if isinstance(user, dict):
                    _, is_admin, _ = _resolve_user_role(user, roles)
                    if is_admin and self._count_admins(data) <= 1:
                        raise MoonlightApiError("Nao e possivel excluir o ultimo administrador.")
                self._ensure_client_auth(username, admin_password)
                self._client.delete_user(user_id)
            else:
                self.delete_user_from_disk(user_id)
            return True

        self._run("delete_user", _fn)
