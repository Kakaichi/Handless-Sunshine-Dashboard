"""Dedicated Sunshine account setup and login tab."""

from __future__ import annotations

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from app.constants import APP_DISPLAY_NAME
from app.credential_store import load_credentials
from app.sunshine_service import SunshineService
from app.widgets import ActionButton, LinkButton, SurfaceCard


class SunshineAccountPage(QWidget):
    request_action = Signal(str)
    activity_message = Signal(str, bool)
    open_web_panel = Signal()
    change_password_requested = Signal()
    logout_requested = Signal()

    def __init__(self, sunshine_service: SunshineService, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._service = sunshine_service
        self._sunshine_running = False
        self._needs_setup = False
        self._account_state = "unknown"
        self._sunshine_username: str | None = None
        self._api_busy = False

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QScrollArea.Shape.NoFrame)

        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(16)

        self._build_intro(layout)
        self._build_offline_section(layout)
        self._build_create_section(layout)
        self._build_login_section(layout)
        self._build_ready_section(layout)
        layout.addStretch()

        scroll.setWidget(content)
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(scroll)

        self._service.operation_finished.connect(self._on_operation_finished)
        self._service.operation_failed.connect(self._on_operation_failed)
        self._service.session_changed.connect(self._refresh_ready_state)

        self._update_visibility()

    def _build_intro(self, parent: QVBoxLayout) -> None:
        card = SurfaceCard("Conta Sunshine")
        hint = QLabel(
            "O Sunshine nao funciona no Moonlight ate voce criar usuario e senha aqui "
            "(ou em https://localhost:47990/welcome). "
            "Depois de criar ou entrar, o app salva as credenciais para PIN, sync e configuracoes."
        )
        hint.setObjectName("Muted")
        hint.setWordWrap(True)
        hint.setAutoFillBackground(False)
        card.body.addWidget(hint)
        parent.addWidget(card)

    def _build_offline_section(self, parent: QVBoxLayout) -> None:
        self._offline_card = SurfaceCard("Sunshine desligado")
        hint = QLabel("Ligue o servico Sunshine antes de criar a conta ou entrar.")
        hint.setObjectName("Muted")
        hint.setWordWrap(True)
        self._offline_card.body.addWidget(hint)

        row = QHBoxLayout()
        btn = ActionButton("Ligar Sunshine", "sunshine_ligar", "primary")
        btn.clicked.connect(lambda: self.request_action.emit("sunshine_ligar"))
        row.addWidget(btn)
        row.addStretch()
        self._offline_card.body.addLayout(row)
        parent.addWidget(self._offline_card)

    def _build_create_section(self, parent: QVBoxLayout) -> None:
        self._create_card = SurfaceCard("Criar primeiro usuario")
        hint = QLabel(
            "Nenhuma senha configurada no Sunshine. Defina usuario e senha do painel web — "
            "obrigatorio para parear Moonlight e sincronizar jogos."
        )
        hint.setObjectName("Muted")
        hint.setWordWrap(True)
        self._create_card.body.addWidget(hint)

        form = QFormLayout()
        self._create_user = QLineEdit("sunshine")
        self._create_pass = QLineEdit()
        self._create_pass.setEchoMode(QLineEdit.EchoMode.Password)
        self._create_confirm = QLineEdit()
        self._create_confirm.setEchoMode(QLineEdit.EchoMode.Password)
        form.addRow("Usuario", self._create_user)
        form.addRow("Senha", self._create_pass)
        form.addRow("Confirmar senha", self._create_confirm)
        self._create_card.body.addLayout(form)

        self._btn_create = QPushButton("Criar credenciais")
        self._btn_create.setObjectName("PrimaryButton")
        self._btn_create.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_create.clicked.connect(self._submit_create)
        self._create_card.body.addWidget(self._btn_create)

        link = LinkButton("Ou abrir painel web do Sunshine", "https://localhost:47990")
        link.clicked_url.connect(self.open_web_panel.emit)
        self._create_card.body.addWidget(link)
        parent.addWidget(self._create_card)

    def _build_login_section(self, parent: QVBoxLayout) -> None:
        self._login_card = SurfaceCard("Entrar no Sunshine")
        hint = QLabel(
            "O Sunshine ja tem usuario configurado. Use o mesmo login do painel web "
            "(Mudar a senha / Log Out)."
        )
        hint.setObjectName("Muted")
        hint.setWordWrap(True)
        self._login_card.body.addWidget(hint)

        form = QFormLayout()
        self._login_user = QLineEdit()
        self._login_pass = QLineEdit()
        self._login_pass.setEchoMode(QLineEdit.EchoMode.Password)
        form.addRow("Usuario", self._login_user)
        form.addRow("Senha", self._login_pass)
        self._login_card.body.addLayout(form)

        self._btn_login = QPushButton("Entrar")
        self._btn_login.setObjectName("PrimaryButton")
        self._btn_login.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_login.clicked.connect(self._submit_login)
        self._login_card.body.addWidget(self._btn_login)
        parent.addWidget(self._login_card)

    def _build_ready_section(self, parent: QVBoxLayout) -> None:
        self._ready_card = SurfaceCard("Conta conectada")
        self._ready_label = QLabel("")
        self._ready_label.setWordWrap(True)
        self._ready_card.body.addWidget(self._ready_label)

        row = QHBoxLayout()
        self._btn_change_password = QPushButton("Mudar a senha")
        self._btn_change_password.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_change_password.clicked.connect(self.change_password_requested.emit)
        self._btn_logout = QPushButton("Sair deste app")
        self._btn_logout.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_logout.clicked.connect(self.logout_requested.emit)
        row.addWidget(self._btn_change_password)
        row.addWidget(self._btn_logout)
        row.addStretch()
        self._ready_card.body.addLayout(row)
        parent.addWidget(self._ready_card)

    def update_status(
        self,
        *,
        sunshine_running: bool,
        sunshine_needs_setup: bool,
        sunshine_account_state: str,
        sunshine_username: str | None,
        panel_url: str,
    ) -> None:
        self._sunshine_running = sunshine_running
        self._needs_setup = sunshine_needs_setup
        self._account_state = sunshine_account_state or "unknown"
        self._sunshine_username = sunshine_username
        self._service.set_base_url(panel_url)

        if sunshine_username and not self._login_user.text().strip():
            self._login_user.setText(sunshine_username)

        self._update_visibility()

    def _refresh_ready_state(self) -> None:
        self._update_visibility()

    def _update_visibility(self) -> None:
        has_app_creds = self._service.has_saved_credentials()
        stored = load_credentials()
        display_name = stored.username if stored else self._sunshine_username

        show_offline = not self._sunshine_running
        show_create = (
            self._sunshine_running
            and not has_app_creds
            and self._account_state in ("no_password", "unknown")
            and self._needs_setup
        )
        show_login = (
            self._sunshine_running
            and not has_app_creds
            and not show_create
            and self._account_state in ("needs_app_login", "unknown")
        )
        if self._sunshine_running and not has_app_creds and not show_create and not show_login:
            show_login = not self._needs_setup

        show_ready = self._sunshine_running and has_app_creds

        self._offline_card.setVisible(show_offline)
        self._create_card.setVisible(show_create)
        self._login_card.setVisible(show_login)
        self._ready_card.setVisible(show_ready)

        if show_ready and display_name:
            self._ready_label.setText(f"Conectado como {display_name}. PIN, sync e configuracoes estao disponiveis.")
        elif show_ready:
            self._ready_label.setText("Credenciais salvas neste app. PIN, sync e configuracoes estao disponiveis.")

        busy = self._api_busy
        for widget in (
            self._create_user,
            self._create_pass,
            self._create_confirm,
            self._btn_create,
            self._login_user,
            self._login_pass,
            self._btn_login,
            self._btn_change_password,
            self._btn_logout,
        ):
            widget.setEnabled(not busy)

    def _set_api_busy(self, busy: bool) -> None:
        self._api_busy = busy
        self._update_visibility()

    def _submit_create(self) -> None:
        user = self._create_user.text().strip()
        password = self._create_pass.text()
        confirm = self._create_confirm.text()
        if not user or not password:
            QMessageBox.warning(self, APP_DISPLAY_NAME, "Preencha usuario e senha.")
            return
        if password != confirm:
            QMessageBox.warning(self, APP_DISPLAY_NAME, "As senhas nao coincidem.")
            return
        self._set_api_busy(True)
        self._service.create_credentials(user, password, confirm)

    def _submit_login(self) -> None:
        user = self._login_user.text().strip()
        password = self._login_pass.text()
        if not user or not password:
            QMessageBox.warning(self, APP_DISPLAY_NAME, "Preencha usuario e senha.")
            return
        self._set_api_busy(True)
        self._service.verify_login(user, password)

    def _on_operation_finished(self, op_name: str, _result: object) -> None:
        self._set_api_busy(False)
        if op_name == "create_credentials":
            self.activity_message.emit("Credenciais do Sunshine criadas com sucesso.", True)
            self._login_pass.clear()
            self._create_pass.clear()
            self._create_confirm.clear()
        elif op_name == "verify_login":
            self.activity_message.emit("Login no Sunshine realizado.", True)
            self._login_pass.clear()

    def _on_operation_failed(self, op_name: str, message: str) -> None:
        self._set_api_busy(False)
        if op_name in ("create_credentials", "verify_login"):
            self.activity_message.emit(message, False)
