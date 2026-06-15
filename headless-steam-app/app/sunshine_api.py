"""HTTP client for the Sunshine local REST API."""

from __future__ import annotations

import base64
import json
import ssl
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any
from urllib.parse import urljoin


class SunshineApiError(Exception):
    def __init__(self, message: str, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


class SunshineNotRunningError(SunshineApiError):
    pass


class SunshineAuthError(SunshineApiError):
    pass


@dataclass
class SunshineCredentials:
    username: str
    password: str


_SSL_CONTEXT = ssl.create_default_context()
_SSL_CONTEXT.check_hostname = False
_SSL_CONTEXT.verify_mode = ssl.CERT_NONE


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ARG002
        return None


_URL_OPENER = urllib.request.build_opener(
    _NoRedirectHandler,
    urllib.request.HTTPSHandler(context=_SSL_CONTEXT),
)


def _urlopen(request: urllib.request.Request, timeout: float) -> Any:
    return _URL_OPENER.open(request, timeout=timeout)


def _is_benign_disconnect(reason: str) -> bool:
    msg = reason.lower()
    return any(
        phrase in msg
        for phrase in (
            "remote end closed",
            "connection reset",
            "forcibly closed",
            "without response",
            "broken pipe",
            "connection aborted",
        )
    )


class SunshineApiClient:
    def __init__(self, base_url: str = "https://localhost:47990") -> None:
        self.base_url = base_url.rstrip("/") + "/"
        self._credentials: SunshineCredentials | None = None

    def set_credentials(self, credentials: SunshineCredentials | None) -> None:
        self._credentials = credentials

    def _auth_header(self) -> dict[str, str]:
        if not self._credentials:
            return {}
        token = base64.b64encode(
            f"{self._credentials.username}:{self._credentials.password}".encode("utf-8")
        ).decode("ascii")
        return {"Authorization": f"Basic {token}"}

    def _request(
        self,
        method: str,
        path: str,
        *,
        body: dict[str, Any] | None = None,
        auth: bool = True,
        timeout: float = 30.0,
        allow_disconnect: bool = False,
    ) -> Any:
        url = urljoin(self.base_url, path.lstrip("/"))
        headers = {"Accept": "application/json"}
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if auth:
            headers.update(self._auth_header())

        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with _urlopen(request, timeout=timeout) as response:
                raw = response.read().decode("utf-8", errors="replace")
                if not raw.strip():
                    return None
                try:
                    return json.loads(raw)
                except json.JSONDecodeError:
                    return raw
        except urllib.error.HTTPError as exc:
            detail = ""
            try:
                detail = exc.read().decode("utf-8", errors="replace")
            except OSError:
                pass
            if exc.code == 401:
                raise SunshineAuthError("Credenciais invalidas.", status_code=401) from exc
            if exc.code == 403:
                raise SunshineApiError(
                    "Acesso negado pelo Sunshine. Verifique origin_web_ui_allowed em sunshine.conf.",
                    status_code=403,
                ) from exc
            if exc.code in (302, 303, 307, 308):
                raise SunshineAuthError(
                    "Sunshine precisa de login inicial. Faca login na aba Sunshine ou abra o painel web.",
                    status_code=exc.code,
                ) from exc
            raise SunshineApiError(
                detail or f"HTTP {exc.code} em {path}",
                status_code=exc.code,
            ) from exc
        except urllib.error.URLError as exc:
            reason = str(exc.reason)
            if allow_disconnect and _is_benign_disconnect(reason):
                return None
            if _is_benign_disconnect(reason):
                raise SunshineApiError(
                    "Sunshine reiniciou a conexao. Aguarde alguns segundos e tente novamente."
                ) from exc
            if "timed out" in reason.lower():
                raise SunshineNotRunningError(
                    "Sunshine nao esta acessivel. Ligue o servico primeiro."
                ) from exc
            raise SunshineApiError(reason) from exc

    def _request_bytes(
        self,
        path: str,
        *,
        auth: bool = True,
        timeout: float = 15.0,
    ) -> bytes | None:
        url = urljoin(self.base_url, path.lstrip("/"))
        headers: dict[str, str] = {}
        if auth:
            headers.update(self._auth_header())

        request = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with _urlopen(request, timeout=timeout) as response:
                data = response.read()
                return data if data else None
        except urllib.error.HTTPError as exc:
            if exc.code in (401,):
                raise SunshineAuthError("Credenciais invalidas.", status_code=401) from exc
            if exc.code in (404,):
                return None
            raise SunshineApiError(f"HTTP {exc.code} em {path}", status_code=exc.code) from exc
        except urllib.error.URLError as exc:
            reason = str(exc.reason)
            if "timed out" in reason.lower():
                raise SunshineNotRunningError(
                    "Sunshine nao esta acessivel. Ligue o servico primeiro."
                ) from exc
            raise SunshineApiError(reason) from exc

    def get_cover(self, index: int) -> bytes | None:
        return self._request_bytes(f"/api/covers/{index}")

    def create_credentials(
        self,
        username: str,
        password: str,
        confirm_password: str,
    ) -> bool:
        result = self._request(
            "POST",
            "/api/password",
            body={
                "newUsername": username,
                "newPassword": password,
                "confirmNewPassword": confirm_password,
            },
            auth=False,
        )
        if isinstance(result, dict) and result.get("status") is True:
            return True
        if isinstance(result, dict) and result.get("error"):
            raise SunshineApiError(str(result["error"]))
        raise SunshineApiError("Nao foi possivel criar as credenciais do Sunshine.")

    def change_password(
        self,
        current_username: str,
        current_password: str,
        new_username: str,
        new_password: str,
        confirm_new_password: str,
    ) -> bool:
        result = self._request(
            "POST",
            "/api/password",
            body={
                "currentUsername": current_username,
                "currentPassword": current_password,
                "newUsername": new_username,
                "newPassword": new_password,
                "confirmNewPassword": confirm_new_password,
            },
            auth=True,
        )
        if isinstance(result, dict) and result.get("status") is True:
            return True
        if isinstance(result, dict) and result.get("error"):
            raise SunshineApiError(str(result["error"]))
        raise SunshineApiError("Nao foi possivel alterar as credenciais.")

    def pair_pin(self, pin: str, name: str = "") -> bool:
        result = self._request(
            "POST",
            "/api/pin",
            body={"pin": pin, "name": name or "Moonlight"},
        )
        if isinstance(result, dict) and result.get("status") is True:
            return True
        raise SunshineApiError("PIN invalido ou pareamento recusado.")

    def _normalize_config_result(self, result: Any) -> dict[str, Any] | None:
        if isinstance(result, dict):
            if result.get("status") is False and result.get("error"):
                raise SunshineApiError(str(result["error"]))
            return result
        if result is None:
            return None
        if isinstance(result, str):
            lowered = result.lower()
            if "<html" in lowered or "<!doctype" in lowered:
                raise SunshineAuthError(
                    "Sunshine redirecionou para o painel web. Faca login na aba Sunshine."
                )
            raise SunshineApiError("Resposta de configuracao invalida (nao JSON).")
        return None

    def get_config(self, *, retry: bool = False, timeout: float = 12.0) -> dict[str, Any]:
        deadline = time.monotonic() + (45.0 if retry else 0.0)
        interval = 1.5
        last_error: Exception | None = None

        while True:
            try:
                result = self._request("GET", "/api/config", timeout=timeout)
                normalized = self._normalize_config_result(result)
                if normalized is not None:
                    return normalized
                last_error = SunshineNotRunningError(
                    "Sunshine ainda iniciando. Aguarde alguns segundos."
                )
            except SunshineAuthError:
                raise
            except SunshineNotRunningError as exc:
                last_error = exc
            except SunshineApiError as exc:
                last_error = exc

            if not retry or time.monotonic() >= deadline:
                break
            time.sleep(interval)

        if isinstance(last_error, SunshineNotRunningError):
            raise last_error
        if isinstance(last_error, SunshineApiError):
            raise last_error
        raise SunshineApiError("Resposta de configuracao invalida.")

    def save_config(self, config: dict[str, Any]) -> bool:
        try:
            self._request("POST", "/api/config", body=config, timeout=20)
        except SunshineApiError as exc:
            if "reiniciou a conexao" in str(exc).lower():
                self.wait_until_ready()
                return True
            raise
        return True

    def restart(self) -> None:
        self._request("POST", "/api/restart", timeout=15, allow_disconnect=True)

    def wait_until_ready(self, timeout: float = 45.0, interval: float = 1.5) -> None:
        deadline = time.monotonic() + timeout
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            try:
                self.get_config()
                return
            except SunshineAuthError:
                raise
            except SunshineApiError as exc:
                last_error = exc
            time.sleep(interval)
        if last_error:
            raise SunshineNotRunningError(
                "Sunshine ainda reiniciando. Tente atualizar em alguns segundos."
            ) from last_error
        raise SunshineNotRunningError("Sunshine nao respondeu apos reiniciar.")

    def list_clients(self) -> list[dict[str, Any]]:
        result = self._request("GET", "/api/clients/list")
        if not isinstance(result, dict):
            return []

        named_certs = result.get("named_certs")
        if isinstance(named_certs, dict):
            clients: list[dict[str, Any]] = []
            for uuid, entry in named_certs.items():
                if isinstance(entry, dict):
                    item = dict(entry)
                    item.setdefault("uuid", uuid)
                    clients.append(item)
                else:
                    clients.append({"uuid": uuid, "name": str(entry)})
            return clients
        if isinstance(named_certs, list):
            return [c for c in named_certs if isinstance(c, dict)]
        return []

    def unpair_client(self, uuid: str) -> None:
        self._request("POST", "/api/clients/unpair", body={"uuid": uuid})

    def unpair_all_clients(self) -> None:
        self._request("POST", "/api/clients/unpair-all")

    def list_apps(self) -> list[dict[str, Any]]:
        result = self._request("GET", "/api/apps")
        if isinstance(result, dict):
            apps = result.get("apps", [])
            if isinstance(apps, list):
                return apps
        return []

    def save_partial_config(self, changes: dict[str, Any]) -> None:
        self.save_config(changes)
        self.restart()
        self.wait_until_ready()
