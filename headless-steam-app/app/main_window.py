"""Main window for Handless Sunshine Dashboard."""

from __future__ import annotations

import os
import re
import subprocess
import sys
from dataclasses import replace
from pathlib import Path

from PySide6.QtCore import QPoint, Qt, QTimer, QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QMenu,
    QDialog,
    QScrollArea,
    QStackedWidget,
    QVBoxLayout,
    QWidget,
)

from app.constants import APP_DISPLAY_NAME, APP_EXE_NAME, APP_VERSION, format_app_title
from app.action_runner import ActionRunner
from app.apps_loader import load_apps_from_disk
from app.change_password_dialog import ChangePasswordDialog
from app.credential_store import load_credentials
from app.funnel_requirements import update_funnel_requirements
from app.games_library import GamesLibraryWidget
from app.icons import load_icon
from app.moonlight_panels import MoonlightPage
from app.moonlight_service import MoonlightService
from app.paths import get_app_root, script_path
from app.status_service import HeadlessSteamStatus, StatusService
from app.sunshine_account_page import SunshineAccountPage
from app.sunshine_panels import SunshinePage
from app.sunshine_service import SunshineService
from app.toast import ToastHost
from app.update_constants import GITHUB_RELEASES_PAGE
from app.update_service import UpdateInfo, UpdateService, should_auto_check
from app.widgets import ActionButton, IconToolButton, LinkButton, StatusCard, SurfaceCard

ACTION_LABELS = {
    "ligar_tudo": "Ligar Sunshine e Tailscale",
    "desligar_tudo": "Desligar todos os servicos",
    "alternar": "Alternar estado dos servicos",
    "change_password": "Mudar a senha",
    "sunshine_ligar": "Ligar Sunshine",
    "sunshine_desligar": "Desligar Sunshine",
    "gamepad_ds4": "Configurar gamepad DS4",
    "gamepad_x360": "Configurar gamepad Xbox 360",
    "tailscale_ligar": "Ligar Tailscale",
    "tailscale_desligar": "Desligar Tailscale",
    "moonlight_ligar": "Ligar Moonlight Web",
    "moonlight_desligar": "Desligar Moonlight Web",
    "moonlight_expose": "Configurar acesso Moonlight",
    "moonlight_apply_settings": "Aplicar configuracoes Moonlight",
    "instalar_deps": "Instalar dependencias",
    "atualizar_jogos": "Sincronizar jogos Steam",
    "open_sunshine_web": "Abrir painel Sunshine",
    "vdd_install": "Instalar monitor virtual",
    "host_free_setup": "Configurar tela virtual",
    "host_free_teardown": "Desativar tela virtual",
}

NAV_ITEMS = (
    ("Visao geral", 0),
    ("Conta Sunshine", 1),
    ("Sunshine", 2),
    ("Tailscale", 3),
    ("Moonlight Web", 4),
)

SERVICE_ACTIONS: dict[str, tuple[str, str]] = {
    "sunshine": ("sunshine_ligar", "sunshine_desligar"),
    "tailscale": ("tailscale_ligar", "tailscale_desligar"),
    "moonlight": ("moonlight_ligar", "moonlight_desligar"),
}

POWER_TOGGLE_ACTIONS = frozenset(
    {
        "ligar_tudo",
        "desligar_tudo",
        "alternar",
        "sunshine_ligar",
        "sunshine_desligar",
        "tailscale_ligar",
        "tailscale_desligar",
        "moonlight_ligar",
        "moonlight_desligar",
    }
)

_ACTION_STATUS_PATCHES: dict[str, dict[str, object]] = {
    "sunshine_ligar": {"sunshine_running": True},
    "sunshine_desligar": {"sunshine_running": False},
    "tailscale_ligar": {"tailscale_running": True},
    "tailscale_desligar": {
        "tailscale_running": False,
        "tailscale_connected": False,
        "tailscale_ip": None,
    },
    "moonlight_ligar": {"moonlight_running": True},
    "moonlight_desligar": {"moonlight_running": False},
    "ligar_tudo": {
        "sunshine_running": True,
        "tailscale_running": True,
    },
    "desligar_tudo": {
        "sunshine_running": False,
        "tailscale_running": False,
        "tailscale_connected": False,
        "tailscale_ip": None,
        "moonlight_running": False,
    },
}

_NOISE_PATTERNS = (
    re.compile(r"^\[OK\]", re.I),
    re.compile(r"^Verificando dependencias", re.I),
    re.compile(r"^Todas as dependencias", re.I),
    re.compile(r"^---"),
    re.compile(r"^Aguarde alguns segundos", re.I),
    re.compile(r"^Tailscale novo:", re.I),
    re.compile(r"^Sunshine novo:", re.I),
)


def _status_style(running: bool) -> tuple[str, str]:
    if running:
        return "Ativo", "#3dd68c"
    return "Inativo", "#8b929a"


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle(format_app_title())
        self.resize(1260, 820)
        self.setMinimumSize(1040, 700)

        self._status_service = StatusService(self)
        self._update_service = UpdateService(self)
        self._action_runner = ActionRunner(self)
        self._sunshine_service = SunshineService(self)
        self._moonlight_service = MoonlightService(self)
        self._busy = False
        self._any_service_running = False
        self._sunshine_needs_setup = False
        self._action_buttons: list[ActionButton] = []
        self._service_cards: dict[str, StatusCard] = {}
        self._last_games_refresh_key: tuple[bool, bool, bool] | None = None
        self._alternar_was_running = False
        self._pending_update_info: UpdateInfo | None = None
        self._last_action: str | None = None

        central = QWidget()
        self.setCentralWidget(central)
        root = QHBoxLayout(central)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)

        self._sidebar = QListWidget()
        self._sidebar.setObjectName("Sidebar")
        self._sidebar.setFixedWidth(180)
        for label, _index in NAV_ITEMS:
            item = QListWidgetItem(label)
            self._sidebar.addItem(item)
        self._sidebar.setCurrentRow(0)
        self._sidebar.currentRowChanged.connect(self._on_nav_changed)
        root.addWidget(self._sidebar)

        content = QWidget()
        content_layout = QVBoxLayout(content)
        content_layout.setContentsMargins(28, 24, 28, 20)
        content_layout.setSpacing(16)
        root.addWidget(content, stretch=1)

        self._build_header(content_layout)

        self._scroll = QScrollArea()
        self._scroll.setWidgetResizable(True)
        self._scroll.setFrameShape(QScrollArea.Shape.NoFrame)
        self._scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)

        self._stack = QStackedWidget()
        self._scroll.setWidget(self._stack)
        content_layout.addWidget(self._scroll, stretch=1)

        self._build_dashboard_page()
        self._build_sunshine_account_page()
        self._build_sunshine_page()
        self._build_tailscale_page()
        self._build_moonlight_page()

        self._toast = ToastHost(content)
        self._toast.setup_open_btn.clicked.connect(self._go_to_sunshine_account)
        self._toast.update_install_btn.clicked.connect(self._on_install_update_clicked)
        self._toast.update_release_btn.clicked.connect(self._on_open_update_release)
        self._toast.update_dismiss_btn.clicked.connect(self._on_dismiss_update)
        self._toast.raise_overlay()

        self._status_service.status_changed.connect(self._on_status)
        self._status_service.error.connect(self._on_status_error)
        self._action_runner.started.connect(self._on_action_started)
        self._action_runner.line_output.connect(self._on_line_output)
        self._action_runner.finished.connect(self._on_action_finished)
        self._action_runner.failed.connect(self._on_action_failed)
        self._sunshine_service.operation_finished.connect(self._on_sunshine_operation)
        self._sunshine_service.operation_failed.connect(self._on_sunshine_operation_failed)
        self._sunshine_service.session_changed.connect(self._rebuild_user_menu)
        self._sunshine_service.session_changed.connect(self._status_service.refresh)

        self._update_service.check_finished.connect(self._on_update_check_finished)
        self._update_service.check_failed.connect(self._on_update_check_failed)
        self._update_service.download_progress.connect(self._on_update_download_progress)
        self._update_service.download_finished.connect(self._on_update_download_finished)
        self._update_service.download_failed.connect(self._on_update_download_failed)

        QTimer.singleShot(0, self._status_service.start)
        self._set_activity_idle()

        QTimer.singleShot(0, self._load_initial_games_library)
        if should_auto_check():
            QTimer.singleShot(4000, lambda: self._update_service.check(silent=True))

    def showEvent(self, event) -> None:  # noqa: N802
        super().showEvent(event)

    def _load_initial_games_library(self) -> None:
        self._games_library.set_apps(load_apps_from_disk(), use_api=False)

    def _build_header(self, parent: QVBoxLayout) -> None:
        row = QHBoxLayout()
        titles = QVBoxLayout()
        titles.setSpacing(2)

        title = QLabel(APP_DISPLAY_NAME)
        title.setObjectName("AppTitle")
        subtitle = QLabel(f"v{APP_VERSION} · Sunshine · Tailscale · Moonlight")
        subtitle.setObjectName("AppSubtitle")
        titles.addWidget(title)
        titles.addWidget(subtitle)
        row.addLayout(titles)
        row.addStretch()

        toolbar = QHBoxLayout()
        toolbar.setSpacing(8)

        self._power_btn = IconToolButton(
            load_icon("power.svg"),
            "Ligar tudo",
            variant="power",
        )
        self._power_btn.clicked.connect(self._on_power_clicked)
        toolbar.addWidget(self._power_btn)

        self._sync_btn = IconToolButton(
            load_icon("sync.svg"),
            "Sincronizar jogos Steam",
        )
        self._sync_btn.clicked.connect(lambda: self._run_action("atualizar_jogos"))
        toolbar.addWidget(self._sync_btn)

        self._user_btn = IconToolButton(
            load_icon("user.svg"),
            "Conta Sunshine",
        )
        self._user_btn.clicked.connect(self._show_user_menu)
        toolbar.addWidget(self._user_btn)

        self._user_menu = QMenu(self)
        self._rebuild_user_menu()

        row.addLayout(toolbar)
        parent.addLayout(row)

    def _register_button(self, btn: ActionButton) -> ActionButton:
        btn.clicked.connect(lambda checked=False, a=btn.action: self._run_action(a))
        self._action_buttons.append(btn)
        return btn

    def _build_dashboard_page(self) -> None:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(16)

        cards = QHBoxLayout()
        cards.setSpacing(12)
        self._sunshine_card = StatusCard("Sunshine")
        self._tailscale_card = StatusCard("Tailscale")
        self._moonlight_card = StatusCard("Moonlight Web")

        self._service_cards = {
            "sunshine": self._sunshine_card,
            "tailscale": self._tailscale_card,
            "moonlight": self._moonlight_card,
        }
        for service_id, card in self._service_cards.items():
            card.clicked.connect(
                lambda sid=service_id: self._on_service_card_clicked(sid)
            )
            cards.addWidget(card, stretch=1)
        layout.addLayout(cards)

        hint = QLabel("Clique em um servico para ligar ou desligar")
        hint.setObjectName("DashboardHint")
        hint.setAutoFillBackground(False)
        layout.addWidget(hint)
        layout.addSpacing(4)

        games_title = QLabel("Jogos Steam Detectados")
        games_title.setObjectName("SectionTitle")
        games_title.setAutoFillBackground(False)
        layout.addWidget(games_title)

        self._games_library = GamesLibraryWidget(self._sunshine_service)
        self._games_library.setMinimumHeight(200)
        layout.addWidget(self._games_library, stretch=1)

        self._stack.addWidget(page)

    def _build_sunshine_account_page(self) -> None:
        self._sunshine_account_page = SunshineAccountPage(self._sunshine_service)
        self._sunshine_account_page.request_action.connect(self._run_action)
        self._sunshine_account_page.activity_message.connect(self._on_sunshine_activity)
        self._sunshine_account_page.open_web_panel.connect(self._open_sunshine_panel)
        self._sunshine_account_page.change_password_requested.connect(self._change_password)
        self._sunshine_account_page.logout_requested.connect(self._logout_user)
        self._stack.addWidget(self._sunshine_account_page)

    def _build_sunshine_page(self) -> None:
        self._sunshine_page = SunshinePage(self._sunshine_service)
        self._sunshine_page.request_action.connect(self._run_action)
        self._sunshine_page.activity_message.connect(self._on_sunshine_activity)
        self._sunshine_page.open_web_panel.connect(self._open_sunshine_panel)
        self._stack.addWidget(self._sunshine_page)

    def _build_tailscale_page(self) -> None:
        page = QWidget()
        layout = QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(16)

        info = SurfaceCard("Rede privada")
        self._tailscale_detail = QLabel("—")
        self._tailscale_detail.setObjectName("Muted")
        self._tailscale_detail.setWordWrap(True)
        self._tailscale_detail.setAutoFillBackground(False)
        info.body.addWidget(self._tailscale_detail)
        layout.addWidget(info)

        power = SurfaceCard("Servico")
        row = QHBoxLayout()
        row.setSpacing(10)
        row.addWidget(self._register_button(ActionButton("Ligar", "tailscale_ligar", "primary")))
        row.addWidget(self._register_button(ActionButton("Desligar", "tailscale_desligar", "danger")))
        row.addStretch()
        power.body.addLayout(row)
        layout.addWidget(power)

        funnel = SurfaceCard("Requisitos Funnel")
        funnel_hint = QLabel(
            "Requisitos da conta/tailnet no admin Tailscale. "
            "Todos precisam estar OK para o Funnel do Moonlight Web funcionar."
        )
        funnel_hint.setObjectName("Muted")
        funnel_hint.setWordWrap(True)
        funnel_hint.setAutoFillBackground(False)
        funnel.body.addWidget(funnel_hint)

        self._funnel_req_acl = QLabel()
        self._funnel_req_acl.setAutoFillBackground(False)
        funnel.body.addWidget(self._funnel_req_acl)

        self._funnel_req_magic_dns = QLabel()
        self._funnel_req_magic_dns.setAutoFillBackground(False)
        funnel.body.addWidget(self._funnel_req_magic_dns)

        self._funnel_req_https = QLabel()
        self._funnel_req_https.setAutoFillBackground(False)
        funnel.body.addWidget(self._funnel_req_https)

        self._funnel_req_note = QLabel()
        self._funnel_req_note.setObjectName("Muted")
        self._funnel_req_note.setWordWrap(True)
        self._funnel_req_note.setAutoFillBackground(False)
        self._funnel_req_note.hide()
        funnel.body.addWidget(self._funnel_req_note)

        funnel_links = QHBoxLayout()
        funnel_links.setSpacing(10)
        self._funnel_acl_link = LinkButton(
            "Abrir policy ACL (nodeAttrs funnel)",
            "https://login.tailscale.com/admin/acls/file",
        )
        self._funnel_acl_link.clicked_url.connect(self._open_url)
        self._funnel_dns_link = LinkButton(
            "Abrir DNS (MagicDNS + Enable HTTPS)",
            "https://login.tailscale.com/admin/dns",
        )
        self._funnel_dns_link.clicked_url.connect(self._open_url)
        funnel_links.addWidget(self._funnel_acl_link)
        funnel_links.addWidget(self._funnel_dns_link)
        funnel_links.addStretch()
        funnel.body.addLayout(funnel_links)
        layout.addWidget(funnel)

        layout.addStretch()

        self._stack.addWidget(page)

    def _build_moonlight_page(self) -> None:
        self._moonlight_page = MoonlightPage(self._moonlight_service)
        self._moonlight_page.request_action.connect(self._run_action)
        self._moonlight_page.open_url.connect(self._open_url)
        self._moonlight_page.activity_message.connect(self._on_moonlight_activity)
        self._stack.addWidget(self._moonlight_page)

    def _on_moonlight_activity(self, message: str, success: bool) -> None:
        self._set_activity_result("Moonlight Web", success, message)

    def _on_nav_changed(self, index: int) -> None:
        if 0 <= index < self._stack.count():
            self._stack.setCurrentIndex(index)
        if index == 4:
            self._moonlight_page.on_page_shown()
            self._status_service.refresh(full=True)
        elif index == 3:
            self._status_service.refresh(full=True)

    def _set_activity_idle(self) -> None:
        self._toast.set_activity_idle()

    def _set_activity_running(self, action: str) -> None:
        label = ACTION_LABELS.get(action, action)
        self._toast.set_activity_running(label)

    def _set_activity_result(self, action: str, success: bool, message: str) -> None:
        label = ACTION_LABELS.get(action, action)
        self._toast.set_activity_result(label, success, message)

    def _is_noise_line(self, line: str) -> bool:
        stripped = line.strip()
        if not stripped:
            return True
        return any(pattern.search(stripped) for pattern in _NOISE_PATTERNS)

    def _friendly_line(self, line: str) -> str | None:
        stripped = line.strip()
        if not stripped or self._is_noise_line(stripped):
            return None
        if stripped.upper().startswith("ERRO"):
            return stripped
        if "Concluido" in stripped or "concluido" in stripped:
            return stripped
        if stripped.startswith("AVISO"):
            return stripped
        if any(
            key in stripped
            for key in (
                "iniciado",
                "parado",
                "configurado",
                "atualizando",
                "atualizados",
                "sincroniz",
                "instalad",
                "disponivel",
                "Serve",
                "Funnel",
                "Moonlight",
                "Sunshine",
                "Tailscale",
                "Atalho",
                "jogos",
            )
        ):
            return stripped
        return None

    def _on_power_clicked(self) -> None:
        action = "desligar_tudo" if self._any_service_running else "ligar_tudo"
        self._run_action(action)

    def _on_service_card_clicked(self, service_id: str) -> None:
        if self._busy:
            QMessageBox.information(self, APP_DISPLAY_NAME, "Aguarde a acao atual terminar.")
            return

        if service_id == "sunshine" and self._sunshine_needs_setup:
            self._go_to_sunshine_account()
            return

        card = self._service_cards.get(service_id)
        if not card:
            return

        on_action, off_action = SERVICE_ACTIONS[service_id]
        action = off_action if card.is_running() else on_action
        self._run_action(action)

    def _update_power_button(self) -> None:
        if self._any_service_running:
            self._power_btn.setIcon(load_icon("power-off.svg"))
            self._power_btn.setToolTip("Desligar tudo")
            self._power_btn.set_active(True)
        else:
            self._power_btn.setIcon(load_icon("power.svg"))
            self._power_btn.setToolTip("Ligar tudo")
            self._power_btn.set_active(False)

    def _run_action(self, action: str) -> None:
        if self._busy:
            QMessageBox.information(self, APP_DISPLAY_NAME, "Aguarde a acao atual terminar.")
            return
        self._action_runner.run(action)

    def _go_to_sunshine_account(self) -> None:
        self._sidebar.setCurrentRow(1)

    def _go_to_sunshine_setup(self) -> None:
        self._go_to_sunshine_account()

    def _rebuild_user_menu(self) -> None:
        self._user_menu.clear()
        self._user_menu.addAction("Verificar atualizacoes", self._check_for_updates_manual)
        self._user_menu.addSeparator()
        if self._sunshine_service.has_saved_credentials():
            self._user_menu.addAction("Mudar a senha", self._change_password)
            self._user_menu.addSeparator()
            self._user_menu.addAction("Log Out", self._logout_user)
            self._user_btn.setToolTip("Conta Sunshine")
        else:
            self._user_menu.addAction("Entrar", self._go_to_sunshine_account)
            self._user_btn.setToolTip("Faca login na aba Sunshine")

    def _show_user_menu(self) -> None:
        self._rebuild_user_menu()
        pos = self._user_btn.mapToGlobal(QPoint(0, self._user_btn.height()))
        self._user_menu.popup(pos)

    def _check_for_updates_manual(self) -> None:
        self._toast.set_activity_running("Verificar atualizacoes", "Consultando GitHub...")
        self._update_service.check(silent=False)

    def _on_update_check_finished(self, info: object) -> None:
        if info is None:
            if self._toast.activity_title() == "Verificar atualizacoes":
                self._set_activity_result("", True, "Voce ja esta na versao mais recente.")
            return

        if not isinstance(info, UpdateInfo):
            return

        self._pending_update_info = info
        self._toast.show_update(
            f"Nova versao v{info.version} disponivel. "
            f"Versao atual: v{APP_VERSION}."
        )
        if self._toast.activity_title() == "Verificar atualizacoes":
            self._set_activity_result("", True, f"Atualizacao v{info.version} disponivel.")

    def _on_update_check_failed(self, message: str) -> None:
        if self._toast.activity_title() == "Verificar atualizacoes":
            self._set_activity_result("", False, message)
        else:
            self._set_activity_idle()

    def _on_dismiss_update(self) -> None:
        if self._pending_update_info is not None:
            self._update_service.dismiss(self._pending_update_info.version)
        self._pending_update_info = None
        self._toast.hide_update()

    def _on_open_update_release(self) -> None:
        url = (
            self._pending_update_info.release_url
            if self._pending_update_info
            else GITHUB_RELEASES_PAGE
        )
        QDesktopServices.openUrl(QUrl(url))

    def _on_install_update_clicked(self) -> None:
        if self._busy:
            QMessageBox.information(self, APP_DISPLAY_NAME, "Aguarde a acao atual terminar.")
            return
        if self._pending_update_info is None:
            return

        if self._any_service_running:
            answer = QMessageBox.question(
                self,
                "Atualizar aplicativo",
                "Ha servicos ligados. O instalador vai encerrar o app e processos relacionados.\n\n"
                "Continuar com a atualizacao?",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.Yes,
            )
            if answer != QMessageBox.StandardButton.Yes:
                return

        self._busy = True
        self._set_actions_enabled(False)
        self._toast.set_activity_running("Baixar atualizacao", "Baixando pacote...")
        self._toast.set_progress_value(0)
        self._update_service.download(self._pending_update_info)

    def _on_update_download_progress(self, value: int) -> None:
        self._toast.set_progress_value(value)
        self._toast.set_activity_message(f"Baixando pacote... {value}%")

    def _on_update_download_finished(self, extracted_dir: object) -> None:
        self._busy = False
        self._set_actions_enabled(True)
        self._toast.hide_progress()

        if not isinstance(extracted_dir, Path):
            self._set_activity_result("", False, "Atualizacao invalida.")
            return

        answer = QMessageBox.question(
            self,
            "Reiniciar para atualizar",
            "Download concluido. O aplicativo vai reiniciar para aplicar a nova versao.\n\n"
            "Continuar?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.Yes,
        )
        if answer != QMessageBox.StandardButton.Yes:
            self._set_activity_result("", True, "Download salvo em pasta temporaria.")
            return

        self._apply_downloaded_update(extracted_dir)

    def _on_update_download_failed(self, message: str) -> None:
        self._busy = False
        self._set_actions_enabled(True)
        self._toast.hide_progress()
        self._set_activity_result("", False, message)

    def _apply_downloaded_update(self, extracted_dir: Path) -> None:
        app_root = get_app_root()
        restart_exe = app_root / APP_EXE_NAME
        updater = script_path("Apply-HeadlessSteamUpdate.ps1")

        if not updater.is_file():
            QMessageBox.warning(
                self,
                APP_DISPLAY_NAME,
                f"Script de atualizacao nao encontrado:\n{updater}",
            )
            return

        creationflags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
        subprocess.Popen(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(updater),
                "-SourceDir",
                str(extracted_dir),
                "-TargetDir",
                str(app_root),
                "-RestartExe",
                str(restart_exe),
                "-ParentPid",
                str(os.getpid()),
            ],
            creationflags=creationflags,
        )

        from PySide6.QtWidgets import QApplication

        QApplication.quit()

    def _change_password(self) -> None:
        status = self._status_service.last_status
        if not status or not status.sunshine_running:
            QMessageBox.warning(
                self,
                "Mudar a senha",
                "Ligue o Sunshine antes de alterar a senha.",
            )
            return

        stored = load_credentials()
        username = stored.username if stored else ""
        dialog = ChangePasswordDialog(username, self)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return

        self._sunshine_service.change_password(
            username,
            dialog.current_password,
            dialog.new_username,
            dialog.new_password,
            dialog.confirm_password,
        )

    def _logout_user(self) -> None:
        answer = QMessageBox.question(
            self,
            "Log Out",
            "Deseja sair da conta Sunshine neste app?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if answer != QMessageBox.StandardButton.Yes:
            return

        self._sunshine_service.logout()
        self._sunshine_page.on_logged_out()
        self._last_games_refresh_key = None
        self._games_library.set_apps(load_apps_from_disk(), use_api=False)
        self._set_activity_result("", True, "Sessao encerrada.")

    def _on_sunshine_activity(self, message: str, success: bool) -> None:
        self._set_activity_result("Sunshine", success, message)

    def _open_url(self, url: str) -> None:
        if url:
            QDesktopServices.openUrl(QUrl(url))

    def _update_tailscale_funnel_requirements(self, status: HeadlessSteamStatus) -> None:
        update_funnel_requirements(
            status,
            acl_label=self._funnel_req_acl,
            magic_dns_label=self._funnel_req_magic_dns,
            https_label=self._funnel_req_https,
            note_label=self._funnel_req_note,
            acl_link=self._funnel_acl_link,
            dns_link=self._funnel_dns_link,
        )

    def _open_sunshine_panel(self) -> None:
        status = self._status_service.last_status
        if not status or not status.sunshine_running:
            QMessageBox.warning(
                self,
                APP_DISPLAY_NAME,
                "Sunshine esta desligado. Ligue primeiro.",
            )
            return
        QDesktopServices.openUrl(QUrl(status.sunshine_panel_url))

    def _on_status(self, status: HeadlessSteamStatus) -> None:
        self._sunshine_needs_setup = status.sunshine_needs_setup

        s_text, s_color = _status_style(status.sunshine_running)
        self._sunshine_card.set_state(s_text, s_color)
        self._sunshine_card.set_running(status.sunshine_running)

        self._sunshine_account_page.update_status(
            sunshine_running=status.sunshine_running,
            sunshine_needs_setup=status.sunshine_needs_setup,
            sunshine_account_state=status.sunshine_account_state,
            sunshine_username=status.sunshine_username,
            panel_url=status.sunshine_panel_url,
        )

        self._sunshine_page.update_status(
            sunshine_running=status.sunshine_running,
            sunshine_needs_setup=status.sunshine_needs_setup,
            panel_url=status.sunshine_panel_url,
            gamepad_mode=status.gamepad_mode,
            sunshine_username=status.sunshine_username,
        )
        self._sunshine_page.update_host_free_status(status)

        if status.tailscale_connected:
            t_text, t_color = "Conectado", "#3dd68c"
            t_detail = status.tailscale_ip or ""
        elif status.tailscale_needs_login:
            t_text, t_color = "Precisa login", "#f5a623"
            t_detail = "Abra o Tailscale na bandeja e entre na conta"
        elif status.tailscale_is_starting:
            t_text, t_color = "Conectando...", "#f5a623"
            t_detail = status.tailscale_health or "Aguarde o IP 100.x"
        elif status.tailscale_running:
            t_text, t_color = "Sem IP", "#f5a623"
            t_detail = "Abra o Tailscale na bandeja para concluir"
        else:
            t_text, t_color = "Inativo", "#8b929a"
            t_detail = ""
        self._tailscale_card.set_state(t_text, t_color, t_detail)
        self._tailscale_card.set_running(status.tailscale_running)
        health_line = f"\nEstado: {status.tailscale_health}" if status.tailscale_health else ""
        self._tailscale_detail.setText(
            f"Servico: {'ativo' if status.tailscale_running else 'inativo'}\n"
            f"VPN: {'conectada' if status.tailscale_connected else 'desconectada'}\n"
            f"IP Tailscale: {status.tailscale_ip or '—'}{health_line}"
        )
        self._update_tailscale_funnel_requirements(status)

        m_text, m_color = _status_style(status.moonlight_running)
        self._moonlight_card.set_state(m_text, m_color)
        self._moonlight_card.set_running(status.moonlight_running)

        self._any_service_running = (
            status.sunshine_running
            or status.tailscale_running
            or status.moonlight_running
        )
        self._update_power_button()

        self._rebuild_user_menu()

        if status.sunshine_needs_setup:
            self._toast.show_setup(
                "Sunshine sem senha. Crie usuario e senha na aba Conta Sunshine (obrigatorio para Moonlight)."
            )
        elif status.sunshine_running and not self._sunshine_service.has_saved_credentials():
            self._toast.show_setup(
                "Faca login na aba Conta Sunshine com seu usuario e senha do painel web."
            )
        else:
            self._toast.hide_setup()

        self._moonlight_page.update_status(status)

        self._refresh_games_library(status)

    def _refresh_games_library(self, status: HeadlessSteamStatus) -> None:
        has_creds = self._sunshine_service.has_saved_credentials()
        key = (status.sunshine_running, status.sunshine_needs_setup, has_creds)
        if key == self._last_games_refresh_key:
            return
        self._last_games_refresh_key = key

        if status.sunshine_running and not status.sunshine_needs_setup and has_creds:
            self._games_library.set_use_api(True)
            self._sunshine_service.fetch_apps()
        else:
            self._games_library.set_apps(load_apps_from_disk(), use_api=False)

    def _on_sunshine_operation(self, op_name: str, result: object) -> None:
        if op_name == "change_password":
            self._set_activity_result("change_password", True, "Senha alterada com sucesso.")
            return
        if op_name != "fetch_apps" or not isinstance(result, list):
            return
        status = self._status_service.last_status
        use_api = bool(
            status
            and status.sunshine_running
            and not status.sunshine_needs_setup
            and self._sunshine_service.has_saved_credentials()
        )
        self._games_library.set_apps(
            result,
            use_api=use_api,
            reload_covers=self._sunshine_service.consume_reload_covers(),
        )

    def _on_sunshine_operation_failed(self, op_name: str, message: str) -> None:
        if op_name == "change_password":
            self._set_activity_result("change_password", False, message)

    def _on_status_error(self, message: str) -> None:
        self._set_activity_result("", False, f"Falha ao ler status: {message}")

    def _on_action_started(self, action: str) -> None:
        self._last_action = action
        self._busy = True
        self._set_activity_running(action)
        self._set_actions_enabled(False)
        if action == "alternar":
            self._alternar_was_running = self._any_service_running
            if self._alternar_was_running:
                self._apply_action_status_patch("desligar_tudo", invalidate_polls=True)
        elif action.endswith("_desligar") or action == "desligar_tudo":
            self._apply_action_status_patch(action, invalidate_polls=True)

    def _apply_action_status_patch(self, action: str, *, invalidate_polls: bool = False) -> None:
        patch = _ACTION_STATUS_PATCHES.get(action)
        if not patch:
            return
        current = self._status_service.last_status
        if current is None:
            return
        self._status_service.apply_local_status(
            replace(current, **patch),
            invalidate_polls=invalidate_polls,
        )

    def _schedule_status_refresh_after_toggle(self) -> None:
        self._status_service.refresh(full=True)
        QTimer.singleShot(800, lambda: self._status_service.refresh(full=True))
        QTimer.singleShot(2500, lambda: self._status_service.refresh(full=True))

    def _on_line_output(self, line: str) -> None:
        if line.startswith("TAILSCALE_LOGIN_REQUIRED:"):
            url = line.split(":", 1)[1].strip() or "https://login.tailscale.com/admin/machines"
            QDesktopServices.openUrl(QUrl(url))
            self._toast.show_activity()
            self._toast.set_activity_message(
                "Tailscale precisa de login. Abrindo pagina de autenticacao — "
                "conclua no app da bandeja e aguarde o IP 100.x."
            )
            return

        if line.startswith("TAILSCALE_GUI_OPENED:"):
            self._toast.show_activity()
            self._toast.set_activity_message(
                "App Tailscale aberto na bandeja. Entre na conta ou aguarde a conexao."
            )
            return

        if line.startswith("HOST_FREE_VIRTUAL_RES:"):
            resolution = line.split(":", 1)[1].strip()
            self._toast.show_activity()
            self._toast.set_activity_message(
                f"Monitor virtual ajustado para {resolution}."
                if resolution
                else "Resolucao do monitor virtual ajustada."
            )
            return

        if line.startswith("HOST_FREE_READY:"):
            self._toast.show_activity()
            self._toast.set_activity_message("Tela virtual configurada e pronta.")
            self._status_service.refresh(full=True)
            return

        if line.startswith("HOST_FREE_MISSING_VDD:"):
            self._toast.show_activity()
            self._toast.set_activity_message("Instale o Virtual Display Driver primeiro.")
            return

        if line.startswith("HOST_FREE_TEARDOWN:"):
            self._toast.show_activity()
            self._toast.set_activity_message(
                "Tela virtual desativada. Jogos usarao a tela principal."
            )
            self._status_service.refresh(full=True)
            return

        if line.startswith("HOST_FREE_OUTPUT:"):
            self._toast.show_activity()
            self._toast.set_activity_message("Sunshine configurado para o monitor virtual.")
            return

        if line.startswith("FUNNEL_ACL_REQUIRED:"):
            url = line.split(":", 1)[1].strip()
            if url:
                QDesktopServices.openUrl(QUrl(url))
            self._toast.show_activity()
            self._toast.set_activity_message(
                "ACL sem permissao funnel. Edite login.tailscale.com/admin/acls/file "
                "e adicione nodeAttrs funnel (nao basta General access rules)."
            )
            return

        if line.startswith("FUNNEL_DNS_REQUIRED:"):
            url = line.split(":", 1)[1].strip() or "https://login.tailscale.com/admin/dns"
            QDesktopServices.openUrl(QUrl(url))
            self._toast.show_activity()
            self._toast.set_activity_message(
                "Funnel exige MagicDNS e Enable HTTPS ligados. Abrindo login.tailscale.com/admin/dns..."
            )
            return

        if line.startswith("FUNNEL_SETUP_REQUIRED:"):
            url = line.split(":", 1)[1].strip() or "https://login.tailscale.com/admin/acls/file"
            QDesktopServices.openUrl(QUrl(url))
            self._toast.show_activity()
            self._toast.set_activity_message(
                "Funnel nao configurado na policy ACL. Abrindo login.tailscale.com/admin/acls/file..."
            )
            return

        friendly = self._friendly_line(line)
        if friendly:
            self._toast.set_activity_message(friendly)

    def _on_action_finished(self, action: str, exit_code: int) -> None:
        self._busy = False
        self._set_actions_enabled(True)

        success = exit_code == 0
        if success:
            self._set_activity_result(action, True, "Operacao concluida com sucesso.")
            if action == "alternar":
                patch_action = "ligar_tudo" if not self._alternar_was_running else "desligar_tudo"
                self._apply_action_status_patch(patch_action)
            elif action in _ACTION_STATUS_PATCHES:
                self._apply_action_status_patch(action)
        else:
            last = self._toast.activity_message()
            msg = last if last and last != "Executando…" else "A operacao falhou."
            self._set_activity_result(action, False, msg)

        if action in POWER_TOGGLE_ACTIONS:
            self._schedule_status_refresh_after_toggle()
        else:
            self._status_service.refresh(full=True)

        if action == "open_sunshine_web" and success:
            self._open_sunshine_panel()

        if action == "atualizar_jogos" and success:
            self._last_games_refresh_key = None
            status = self._status_service.last_status
            use_api = bool(
                status
                and status.sunshine_running
                and not status.sunshine_needs_setup
                and self._sunshine_service.has_saved_credentials()
            )
            if use_api:
                self._games_library.set_use_api(True)
                self._sunshine_service.fetch_apps(reload_covers=True)
            else:
                self._games_library.set_apps(
                    load_apps_from_disk(),
                    use_api=False,
                    reload_covers=True,
                )

        self._sunshine_page.on_action_finished(action, success)
        self._moonlight_page.on_action_finished(action, success)

    def _on_action_failed(self, message: str) -> None:
        self._busy = False
        self._set_actions_enabled(True)
        self._set_activity_result("", False, message)
        self._schedule_status_refresh_after_toggle()
        action = self._last_action or ""
        if action in {"host_free_setup", "host_free_teardown"}:
            self._sunshine_page.on_action_finished(action, False)
        QMessageBox.warning(self, APP_DISPLAY_NAME, message)

    def _set_actions_enabled(self, enabled: bool) -> None:
        for btn in self._action_buttons:
            btn.setEnabled(enabled)
        self._power_btn.setEnabled(enabled)
        self._sync_btn.setEnabled(enabled)
        for card in self._service_cards.values():
            card.setEnabled(enabled)

    def closeEvent(self, event) -> None:  # noqa: N802
        self._status_service.stop()
        super().closeEvent(event)
