"""Moonlight Web configuration tab."""

from __future__ import annotations

from PySide6.QtCore import Qt, QTimer, Signal
from PySide6.QtWidgets import (
    QCheckBox,
    QHBoxLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from app.moonlight_credential_store import clear_credentials, load_credentials
from app.moonlight_edit_user_dialog import MoonlightEditUserDialog
from app.moonlight_login_dialog import MoonlightLoginDialog
from app.moonlight_service import MoonlightRole, MoonlightService
from app.moonlight_settings_store import MoonlightSettings, normalize_settings
from app.moonlight_user_dialog import MoonlightUserDialog
from app.status_service import HeadlessSteamStatus
from app.widgets import ActionButton, LinkButton, NoWheelComboBox, SurfaceCard


class MoonlightPage(QWidget):
    request_action = Signal(str)
    open_url = Signal(str)
    activity_message = Signal(str, bool)

    def __init__(self, moonlight_service: MoonlightService, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._service = moonlight_service
        self._moonlight_running = False
        self._was_moonlight_running = False
        self._last_data_mtime: float | None = None
        self._pending_create: dict[str, str] | None = None
        self._pending_delete_user_id: str | None = None
        self._pending_update: dict[str, str | None] | None = None
        self._pending_edit_user_id: str | None = None
        self._pending_roles_for_create = False
        self._cached_roles: list[MoonlightRole] = []
        self._loading_settings = False
        self._tailscale_funnel_allowed = True
        self._funnel_setup_url = "https://login.tailscale.com/admin/acls/file"
        self._funnel_acl_setup_url = "https://login.tailscale.com/admin/acls/file"
        self._funnel_dns_setup_url = "https://login.tailscale.com/admin/dns"
        self._last_funnel_url: str | None = None

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QScrollArea.Shape.NoFrame)

        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(16)

        self._build_urls_section(layout)
        self._build_power_section(layout)
        self._build_users_section(layout)
        self._build_skip_login_section(layout)
        self._build_funnel_section(layout)
        layout.addStretch()

        scroll.setWidget(content)
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(scroll)

        self._service.operation_finished.connect(self._on_operation_finished)
        self._service.operation_failed.connect(self._on_operation_failed)
        self._service.auth_required.connect(self._on_auth_required)

        self._reload_users()
        self._load_settings_into_ui()

    def _build_urls_section(self, parent: QVBoxLayout) -> None:
        self._urls_card = SurfaceCard("Enderecos de acesso")
        self._funnel_public_hint = QLabel("")
        self._funnel_public_hint.setObjectName("Muted")
        self._funnel_public_hint.setWordWrap(True)
        self._funnel_public_hint.hide()

        self._ml_funnel = LinkButton("Internet (Funnel) · desativado", "")
        self._ml_funnel.hide()
        self._ml_local = LinkButton("Local · http://localhost:8080", "http://localhost:8080")
        self._ml_tailscale = LinkButton("Via Tailscale · indisponivel", "")
        self._funnel_warning = QLabel("")
        self._funnel_warning.setObjectName("Muted")
        self._funnel_warning.setWordWrap(True)
        self._funnel_warning.hide()

        self._urls_card.body.addWidget(self._funnel_public_hint)
        for link in (self._ml_funnel, self._ml_local, self._ml_tailscale):
            link.clicked_url.connect(self.open_url.emit)
            self._urls_card.body.addWidget(link)
        self._urls_card.body.addWidget(self._funnel_warning)
        parent.addWidget(self._urls_card)

    def _build_power_section(self, parent: QVBoxLayout) -> None:
        card = SurfaceCard("Servico")
        row = QHBoxLayout()
        row.setSpacing(10)
        self._btn_power_on = ActionButton("Ligar", "moonlight_ligar", "primary")
        self._btn_power_off = ActionButton("Desligar", "moonlight_desligar", "danger")
        self._btn_power_on.clicked.connect(lambda: self.request_action.emit("moonlight_ligar"))
        self._btn_power_off.clicked.connect(lambda: self.request_action.emit("moonlight_desligar"))
        row.addWidget(self._btn_power_on)
        row.addWidget(self._btn_power_off)
        row.addStretch()
        card.body.addLayout(row)
        parent.addWidget(card)

    def _build_users_section(self, parent: QVBoxLayout) -> None:
        card = SurfaceCard("Usuarios")
        hint = QLabel(
            "Gerencie contas do Moonlight Web. A lista le data.json (offline ou online). "
            "Sem usuarios, Criar usuario configura o primeiro administrador. "
            "Demais operacoes de criar/editar exigem o servico ligado."
        )
        hint.setObjectName("Muted")
        hint.setWordWrap(True)
        hint.setAutoFillBackground(False)
        card.body.addWidget(hint)

        self._users_list = QListWidget()
        self._users_list.setMinimumHeight(120)
        card.body.addWidget(self._users_list)

        row = QHBoxLayout()
        row.setSpacing(10)
        self._btn_create_user = QPushButton("Criar usuario")
        self._btn_create_user.setObjectName("PrimaryButton")
        self._btn_create_user.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_create_user.clicked.connect(self._create_user)
        self._btn_edit_user = QPushButton("Editar perfil")
        self._btn_edit_user.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_edit_user.clicked.connect(self._edit_user)
        self._btn_delete_user = QPushButton("Excluir selecionado")
        self._btn_delete_user.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_delete_user.clicked.connect(self._delete_user)
        self._btn_admin_panel = LinkButton("Abrir painel admin", "http://localhost:8080/admin.html")
        self._btn_admin_panel.clicked_url.connect(self.open_url.emit)
        row.addWidget(self._btn_create_user)
        row.addWidget(self._btn_edit_user)
        row.addWidget(self._btn_delete_user)
        row.addWidget(self._btn_admin_panel)
        row.addStretch()
        card.body.addLayout(row)
        parent.addWidget(card)

    def _build_skip_login_section(self, parent: QVBoxLayout) -> None:
        card = SurfaceCard("Acesso sem login (nao recomendavel)")
        hint = QLabel(
            "Qualquer pessoa com acesso a URL entra automaticamente como o usuario escolhido."
        )
        hint.setObjectName("Muted")
        hint.setWordWrap(True)
        hint.setAutoFillBackground(False)
        card.body.addWidget(hint)

        self._skip_login_check = QCheckBox("Entrar automaticamente sem senha")
        self._skip_login_check.toggled.connect(self._on_skip_login_toggled)
        card.body.addWidget(self._skip_login_check)

        self._skip_login_funnel_hint = QLabel(
            "Desativado enquanto o Funnel estiver ativo (exposicao publica exige login)."
        )
        self._skip_login_funnel_hint.setObjectName("Muted")
        self._skip_login_funnel_hint.setWordWrap(True)
        self._skip_login_funnel_hint.hide()
        card.body.addWidget(self._skip_login_funnel_hint)

        user_row = QHBoxLayout()
        user_row.addWidget(QLabel("Usuario padrao"))
        self._skip_login_user = NoWheelComboBox()
        self._skip_login_user.currentIndexChanged.connect(self._on_settings_changed)
        user_row.addWidget(self._skip_login_user, stretch=1)
        card.body.addLayout(user_row)

        self._btn_apply_settings = QPushButton("Salvar e aplicar")
        self._btn_apply_settings.setObjectName("PrimaryButton")
        self._btn_apply_settings.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_apply_settings.clicked.connect(self._apply_settings)
        card.body.addWidget(self._btn_apply_settings)
        parent.addWidget(card)

    def _build_funnel_section(self, parent: QVBoxLayout) -> None:
        card = SurfaceCard("Exposicao na internet (nao recomendavel)")
        hint = QLabel(
            "Usa Tailscale Funnel: visitantes nao precisam de Tailscale nem port forwarding."
        )
        hint.setObjectName("Muted")
        hint.setWordWrap(True)
        hint.setAutoFillBackground(False)
        card.body.addWidget(hint)

        prereq = QLabel(
            "Requisitos no admin Tailscale (todos obrigatorios):\n"
            "• Policy ACL — nodeAttrs com attr funnel\n"
            "• DNS — MagicDNS ligado\n"
            "• DNS — Enable HTTPS ligado (sem HTTPS o link fica em Aguardando URL)\n\n"
            "Apos alterar ACL ou DNS, reinicie o servico Tailscale e clique Salvar e aplicar."
        )
        prereq.setObjectName("Muted")
        prereq.setWordWrap(True)
        prereq.setAutoFillBackground(False)
        card.body.addWidget(prereq)

        links_row = QHBoxLayout()
        links_row.setSpacing(10)
        self._funnel_acl_link = LinkButton(
            "Abrir policy ACL (nodeAttrs funnel)",
            self._funnel_acl_setup_url,
        )
        self._funnel_acl_link.clicked_url.connect(self.open_url.emit)
        self._funnel_dns_link = LinkButton(
            "Abrir DNS (MagicDNS + Enable HTTPS)",
            self._funnel_dns_setup_url,
        )
        self._funnel_dns_link.clicked_url.connect(self.open_url.emit)
        links_row.addWidget(self._funnel_acl_link)
        links_row.addWidget(self._funnel_dns_link)
        links_row.addStretch()
        card.body.addLayout(links_row)

        self._funnel_check = QCheckBox("Expor via Tailscale Funnel (internet publica)")
        self._funnel_check.toggled.connect(self._on_funnel_toggled)
        card.body.addWidget(self._funnel_check)

        self._funnel_users_warning = QLabel("")
        self._funnel_users_warning.setObjectName("Muted")
        self._funnel_users_warning.setWordWrap(True)
        self._funnel_users_warning.hide()
        card.body.addWidget(self._funnel_users_warning)

        self._funnel_account_warning = QLabel("")
        self._funnel_account_warning.setObjectName("Muted")
        self._funnel_account_warning.setWordWrap(True)
        self._funnel_account_warning.hide()
        card.body.addWidget(self._funnel_account_warning)
        parent.addWidget(card)

    def update_status(self, status: HeadlessSteamStatus) -> None:
        was_running = self._moonlight_running
        self._moonlight_running = status.moonlight_running
        self._tailscale_funnel_allowed = status.tailscale_funnel_allowed
        self._funnel_setup_url = status.tailscale_funnel_acl_setup_url
        self._funnel_acl_setup_url = status.tailscale_funnel_acl_setup_url
        self._funnel_acl_link.set_url(
            "Abrir policy ACL (nodeAttrs funnel)",
            self._funnel_acl_setup_url,
        )
        self._funnel_dns_link.set_url(
            "Abrir DNS (MagicDNS + Enable HTTPS)",
            self._funnel_dns_setup_url,
        )
        self._ml_local.set_url(status.moonlight_local_url, status.moonlight_local_url)

        tailscale_only = " (somente com Tailscale instalado)"
        if status.moonlight_tailscale_url:
            self._ml_tailscale.set_url(
                f"Via Tailscale{tailscale_only} · {status.moonlight_tailscale_url}",
                status.moonlight_tailscale_url,
            )
        else:
            self._ml_tailscale.set_url(f"Via Tailscale{tailscale_only} · indisponivel", "")

        if status.moonlight_funnel_enabled:
            if status.moonlight_funnel_url:
                self._last_funnel_url = status.moonlight_funnel_url

            funnel_url = status.moonlight_funnel_url or self._last_funnel_url
            self._funnel_public_hint.setText(
                "Para acessar de qualquer lugar (sem Tailscale), use o link Internet (Funnel) abaixo. "
                "O link Via Tailscale so funciona com o app Tailscale instalado."
            )
            self._funnel_public_hint.show()
            if funnel_url:
                self._ml_funnel.show()
                self._ml_funnel.set_url(
                    f"Internet (Funnel) · {funnel_url}",
                    funnel_url,
                )
                self._funnel_warning.setText(
                    "Nao recomendavel: Moonlight Web exposto na internet via Tailscale Funnel."
                )
                self._funnel_warning.show()
            else:
                waiting_label = (
                    "Internet (Funnel) · aguardando URL..."
                    if status.moonlight_running
                    else "Internet (Funnel) · aguardando URL (ligue o Moonlight Web)"
                )
                self._ml_funnel.show()
                self._ml_funnel.set_url(waiting_label, "")
                if status.tailscale_funnel_allowed:
                    if status.moonlight_running:
                        self._funnel_warning.setText(
                            "ACL OK, mas o Funnel ainda nao esta ativo neste PC. "
                            "Confirme MagicDNS e Enable HTTPS (link DNS acima), reinicie o Tailscale, "
                            "depois Salvar e aplicar."
                        )
                    else:
                        self._funnel_warning.setText(
                            "Funnel habilitado no app. Ligue o Moonlight Web e clique em Salvar e aplicar."
                        )
                else:
                    self._funnel_warning.setText(
                        "Funnel ativado, mas este PC ainda nao tem permissao funnel na tailnet. "
                        "Salve a ACL e reinicie o Tailscale; depois Salvar e aplicar no app."
                    )
                self._funnel_warning.show()
        else:
            self._last_funnel_url = None
            self._funnel_public_hint.hide()
            self._ml_funnel.hide()
            self._funnel_warning.hide()

        funnel_enabled = self._service.load_settings().public_funnel_enabled
        self._update_funnel_account_state(funnel_enabled)
        self._update_security_constraints()

        if status.moonlight_running and not was_running:
            QTimer.singleShot(1500, self._reload_users)
            QTimer.singleShot(800, self._warm_admin_session)
        elif status.moonlight_running:
            if self._users_list.count() == 0 and self._user_count() > 0:
                self._reload_users()
            else:
                mtime = self._service.data_mtime()
                if mtime is not None and mtime != self._last_data_mtime:
                    self._reload_users()

        self._was_moonlight_running = status.moonlight_running

    def on_page_shown(self) -> None:
        self._load_settings_into_ui()
        self._reload_users()
        if self._moonlight_running:
            QTimer.singleShot(800, self._warm_admin_session)

    def _user_count(self) -> int:
        return len(self._service.list_users_from_disk())

    def _update_security_constraints(self) -> None:
        user_count = self._user_count()
        funnel_on = self._funnel_check.isChecked()
        funnel_allowed = user_count > 0

        self._funnel_check.setEnabled(funnel_allowed)
        if not funnel_allowed:
            self._funnel_users_warning.setText(
                "Crie pelo menos um usuario antes de ativar o Funnel."
            )
            self._funnel_users_warning.show()
            if funnel_on:
                self._funnel_check.blockSignals(True)
                self._funnel_check.setChecked(False)
                self._funnel_check.blockSignals(False)
                self._persist_settings_only()
        else:
            self._funnel_users_warning.hide()

        skip_allowed = not self._funnel_check.isChecked()
        self._skip_login_check.setEnabled(skip_allowed)
        self._skip_login_funnel_hint.setVisible(not skip_allowed)

        if not skip_allowed and self._skip_login_check.isChecked():
            self._skip_login_check.blockSignals(True)
            self._skip_login_check.setChecked(False)
            self._skip_login_check.blockSignals(False)
            self._skip_login_user.setEnabled(False)
            self._persist_settings_only()
        else:
            self._skip_login_user.setEnabled(
                self._skip_login_check.isChecked() and skip_allowed
            )

    def _update_funnel_account_state(self, funnel_enabled_in_app: bool) -> None:
        needs_acl = funnel_enabled_in_app and not self._tailscale_funnel_allowed
        if needs_acl:
            self._funnel_account_warning.setText(
                "Funnel ativo no app, mas a policy ACL ainda nao permite Funnel neste PC. "
                "General access rules (src/dst *) nao bastam: use nodeAttrs com attr funnel."
            )
            self._funnel_account_warning.show()
        else:
            self._funnel_account_warning.hide()

    def _open_funnel_setup(self) -> None:
        self.open_url.emit(self._funnel_acl_setup_url)

    def _ensure_tailscale_funnel_allowed(self) -> bool:
        if self._tailscale_funnel_allowed:
            return True

        self._open_funnel_setup()
        QMessageBox.information(
            self,
            "Funnel nao habilitado",
            "O Funnel ainda nao esta habilitado neste PC / tailnet.\n\n"
            "1. Policy ACL — nodeAttrs funnel\n"
            "2. DNS — MagicDNS ligado\n"
            "3. DNS — Enable HTTPS ligado\n\n"
            "Use os links na secao Funnel desta aba.",
        )
        return False

    def _role_labels(self, roles: list[MoonlightRole]) -> list[tuple[str, str]]:
        return [
            (f"{role.name} ({role.role_type})", role.role_id)
            for role in roles
        ]

    def _reload_users(self) -> None:
        users = self._service.list_users_from_disk()
        self._last_data_mtime = self._service.data_mtime()
        current_id = self._skip_login_user.currentData()

        self._users_list.clear()
        self._skip_login_user.blockSignals(True)
        self._skip_login_user.clear()

        for user in users:
            item = QListWidgetItem(f"{user.name} · {user.role_name}")
            item.setData(Qt.ItemDataRole.UserRole, user.user_id)
            self._users_list.addItem(item)
            self._skip_login_user.addItem(user.name, user.user_id)

        if current_id is not None:
            index = self._skip_login_user.findData(current_id)
            if index >= 0:
                self._skip_login_user.setCurrentIndex(index)
        elif self._skip_login_user.count() > 0:
            self._skip_login_user.setCurrentIndex(0)

        self._skip_login_user.blockSignals(False)
        self._update_security_constraints()

    def _load_settings_into_ui(self) -> None:
        self._loading_settings = True
        stored = self._service.load_settings()
        settings = normalize_settings(stored, self._user_count())
        if settings != stored:
            self._service.save_settings(settings)
        self._skip_login_check.setChecked(settings.skip_login_enabled)
        self._funnel_check.setChecked(settings.public_funnel_enabled)
        if settings.skip_login_user_id:
            index = self._skip_login_user.findData(settings.skip_login_user_id)
            if index >= 0:
                self._skip_login_user.setCurrentIndex(index)
        self._loading_settings = False
        self._update_security_constraints()

    def _current_settings(self) -> MoonlightSettings:
        user_id = self._skip_login_user.currentData()
        return MoonlightSettings(
            public_funnel_enabled=self._funnel_check.isChecked(),
            skip_login_enabled=self._skip_login_check.isChecked(),
            skip_login_user_id=str(user_id) if user_id is not None else None,
        )

    def _normalized_settings(self) -> MoonlightSettings:
        return normalize_settings(self._current_settings(), self._user_count())

    def _on_skip_login_toggled(self, checked: bool) -> None:
        if not self._loading_settings and self._funnel_check.isChecked():
            self._skip_login_check.blockSignals(True)
            self._skip_login_check.setChecked(False)
            self._skip_login_check.blockSignals(False)
            return
        self._skip_login_user.setEnabled(checked and not self._funnel_check.isChecked())
        if not self._loading_settings:
            self._persist_settings_only()

    def _on_funnel_toggled(self, checked: bool) -> None:
        if self._loading_settings:
            return
        if checked and self._user_count() <= 0:
            QMessageBox.warning(
                self,
                "Funnel indisponivel",
                "Crie pelo menos um usuario antes de ativar o Funnel.",
            )
            self._funnel_check.blockSignals(True)
            self._funnel_check.setChecked(False)
            self._funnel_check.blockSignals(False)
            return
        if checked:
            if self._skip_login_check.isChecked():
                self._skip_login_check.blockSignals(True)
                self._skip_login_check.setChecked(False)
                self._skip_login_check.blockSignals(False)
            self._loading_settings = True
            answer = QMessageBox.warning(
                self,
                "Exposicao na internet",
                "Isso expoe o Moonlight Web na internet via Tailscale Funnel.\n\n"
                "Confirme antes: ACL com nodeAttrs funnel, MagicDNS e Enable HTTPS ligados "
                "no admin Tailscale (links na secao abaixo).\n\n"
                "Nao e recomendavel. Continuar?",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.No,
            )
            if answer != QMessageBox.StandardButton.Yes:
                self._loading_settings = False
                self._funnel_check.blockSignals(True)
                self._funnel_check.setChecked(False)
                self._funnel_check.blockSignals(False)
                return
        settings = self._normalized_settings()
        self._service.save_settings(settings)
        self._loading_settings = False
        self._update_funnel_account_state(settings.public_funnel_enabled)
        self._update_security_constraints()
        if self._moonlight_running:
            self.request_action.emit("moonlight_expose")

    def _on_settings_changed(self) -> None:
        if not self._loading_settings:
            self._persist_settings_only()

    def _persist_settings_only(self) -> None:
        self._service.save_settings(self._normalized_settings())

    def _apply_settings(self) -> None:
        settings = self._normalized_settings()
        if settings.public_funnel_enabled and self._user_count() <= 0:
            QMessageBox.warning(
                self,
                "Moonlight Web",
                "Crie pelo menos um usuario antes de ativar o Funnel.",
            )
            return
        if settings.skip_login_enabled and not settings.skip_login_user_id:
            QMessageBox.warning(self, "Moonlight Web", "Selecione um usuario padrao.")
            return
        if settings.public_funnel_enabled and settings.skip_login_enabled:
            QMessageBox.warning(
                self,
                "Moonlight Web",
                "Entrar sem senha nao pode ficar ativo com o Funnel ligado.",
            )
            return
        self._service.save_settings(settings)
        self._load_settings_into_ui()
        self.request_action.emit("moonlight_apply_settings")

    def _warm_admin_session(self) -> None:
        if self._moonlight_running and self._service.has_saved_credentials():
            self._service.warm_saved_session()

    def _prompt_admin_credentials(self) -> tuple[str, str] | None:
        stored = load_credentials()
        dialog = MoonlightLoginDialog(stored.username if stored else "", self)
        if dialog.exec() != MoonlightLoginDialog.DialogCode.Accepted:
            return None
        return dialog.username, dialog.password

    def _bootstrap_first_admin(self) -> None:
        dialog = MoonlightUserDialog([], self, bootstrap=True)
        if dialog.exec() != MoonlightUserDialog.DialogCode.Accepted:
            return
        self._service.bootstrap_first_admin(dialog.user_name, dialog.password)

    def _start_create_with_roles(self, roles: list[MoonlightRole]) -> None:
        role_labels = self._role_labels(roles)
        if not role_labels:
            QMessageBox.warning(self, "Criar usuario", "Nenhum perfil encontrado.")
            return

        first_user = self._user_count() == 0
        dialog = MoonlightUserDialog(role_labels, self, first_user=first_user)
        if dialog.exec() != MoonlightUserDialog.DialogCode.Accepted:
            return

        existing = {user.name.lower() for user in self._service.list_users_from_disk()}
        if dialog.user_name.lower() in existing:
            QMessageBox.warning(self, "Criar usuario", "Ja existe um usuario com esse nome.")
            return

        self._pending_create = {
            "name": dialog.user_name,
            "password": dialog.password,
            "role_id": dialog.role_id,
        }
        self._run_with_admin_auth(
            "create_user",
            lambda username, admin_password: self._service.create_user(
                dialog.user_name,
                dialog.password,
                dialog.role_id,
                username=username,
                admin_password=admin_password,
            ),
        )

    def _create_user(self) -> None:
        if not self._moonlight_running:
            QMessageBox.warning(
                self,
                "Criar usuario",
                "Ligue o Moonlight Web antes de criar usuarios.",
            )
            return

        if self._user_count() == 0:
            self._bootstrap_first_admin()
            return

        roles = self._service.list_roles_from_disk()
        if roles:
            self._start_create_with_roles(roles)
            return

        self._pending_roles_for_create = True
        self._run_with_admin_auth(
            "fetch_roles",
            lambda username, admin_password: self._service.fetch_roles(
                username=username,
                admin_password=admin_password,
            ),
        )

    def _edit_user(self) -> None:
        if not self._moonlight_running:
            QMessageBox.warning(
                self,
                "Editar perfil",
                "Ligue o Moonlight Web antes de editar perfis pela API.",
            )
            return

        item = self._users_list.currentItem()
        if not item:
            QMessageBox.information(self, "Editar perfil", "Selecione um usuario.")
            return

        user_id = str(item.data(Qt.ItemDataRole.UserRole))
        user = self._service.get_user_from_disk(user_id)
        if not user:
            QMessageBox.warning(self, "Editar perfil", "Usuario nao encontrado.")
            return

        roles = self._service.list_roles_from_disk()
        if roles:
            self._open_edit_dialog(user, roles)
            return

        self._pending_edit_user_id = user_id
        self._run_with_admin_auth(
            "fetch_roles",
            lambda username, admin_password: self._service.fetch_roles(
                username=username,
                admin_password=admin_password,
            ),
        )

    def _open_edit_dialog(self, user, roles: list[MoonlightRole]) -> None:
        dialog = MoonlightEditUserDialog(
            user.name,
            user.role_id,
            self._role_labels(roles),
            self,
        )
        if dialog.exec() != MoonlightEditUserDialog.DialogCode.Accepted:
            return

        if user.role_id == dialog.role_id and dialog.password is None:
            return

        if self._service.would_remove_last_admin(user.user_id, dialog.role_id):
            QMessageBox.warning(
                self,
                "Editar perfil",
                "Nao e possivel remover o ultimo administrador.",
            )
            return

        self._pending_update = {
            "user_id": user.user_id,
            "role_id": dialog.role_id,
            "password": dialog.password,
        }
        self._run_with_admin_auth(
            "update_user",
            lambda username, admin_password: self._service.update_user(
                user.user_id,
                dialog.role_id,
                password=dialog.password,
                username=username,
                admin_password=admin_password,
            ),
        )

    def _run_with_admin_auth(
        self,
        op_name: str,
        fn,
        *,
        force_prompt: bool = False,
    ) -> None:
        if not force_prompt and self._service.has_saved_credentials():
            fn(None, None)
            return

        if self._user_count() > 0:
            creds = self._prompt_admin_credentials()
            if not creds:
                if op_name == "create_user":
                    self._pending_create = None
                elif op_name == "update_user":
                    self._pending_update = None
                elif op_name == "delete_user":
                    self._pending_delete_user_id = None
                elif op_name in {"fetch_roles"}:
                    self._pending_roles_for_create = False
                    self._pending_edit_user_id = None
                return
            fn(creds[0], creds[1])
            return

        self.activity_message.emit(
            "Nenhum usuario cadastrado. Use Criar usuario para o primeiro administrador.",
            False,
        )

    def _delete_user(self) -> None:
        item = self._users_list.currentItem()
        if not item:
            QMessageBox.information(self, "Excluir usuario", "Selecione um usuario.")
            return

        user_id = str(item.data(Qt.ItemDataRole.UserRole))
        user_name = item.text().split(" · ", 1)[0]
        answer = QMessageBox.question(
            self,
            "Excluir usuario",
            f"Excluir o usuario '{user_name}'?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if answer != QMessageBox.StandardButton.Yes:
            return

        self._pending_delete_user_id = user_id
        if self._moonlight_running:
            self._run_with_admin_auth(
                "delete_user",
                lambda username, admin_password: self._service.delete_user(
                    user_id,
                    use_api=True,
                    username=username,
                    admin_password=admin_password,
                ),
            )
        else:
            self._service.delete_user(user_id, use_api=False)

    def _on_auth_required(self) -> None:
        clear_credentials()

        if self._pending_create:
            pending = self._pending_create
            creds = self._prompt_admin_credentials()
            if creds:
                self._service.create_user(
                    pending["name"],
                    pending["password"],
                    pending["role_id"],
                    username=creds[0],
                    admin_password=creds[1],
                )
            else:
                self._pending_create = None
                self.activity_message.emit("Criacao de usuario cancelada.", False)
            return

        if self._pending_update and "role_id" in self._pending_update:
            pending = self._pending_update
            creds = self._prompt_admin_credentials()
            if creds:
                self._service.update_user(
                    str(pending["user_id"]),
                    str(pending["role_id"]),
                    password=pending.get("password"),
                    username=creds[0],
                    admin_password=creds[1],
                )
            else:
                self._pending_update = None
                self.activity_message.emit("Edicao de perfil cancelada.", False)
            return

        if self._pending_delete_user_id:
            user_id = self._pending_delete_user_id
            creds = self._prompt_admin_credentials()
            if creds:
                self._service.delete_user(
                    user_id,
                    use_api=True,
                    username=creds[0],
                    admin_password=creds[1],
                )
            else:
                self._pending_delete_user_id = None
                self.activity_message.emit("Exclusao de usuario cancelada.", False)
            return

        if self._pending_roles_for_create:
            creds = self._prompt_admin_credentials()
            if creds:
                self._service.fetch_roles(username=creds[0], admin_password=creds[1])
            else:
                self._pending_roles_for_create = False
                self.activity_message.emit("Criacao de usuario cancelada.", False)
            return

        if self._pending_edit_user_id:
            creds = self._prompt_admin_credentials()
            if creds:
                self._service.fetch_roles(username=creds[0], admin_password=creds[1])
            else:
                self._pending_edit_user_id = None
                self.activity_message.emit("Edicao de perfil cancelada.", False)

    def _on_operation_finished(self, op_name: str, result: object) -> None:
        if op_name == "fetch_roles":
            roles = result if isinstance(result, list) else []
            self._cached_roles = roles
            if self._pending_edit_user_id:
                user_id = self._pending_edit_user_id
                self._pending_edit_user_id = None
                user = self._service.get_user_from_disk(user_id)
                if user:
                    self._open_edit_dialog(user, roles)
                return
            self._pending_roles_for_create = False
            self._start_create_with_roles(roles)
        elif op_name == "bootstrap_first_admin":
            self._reload_users()
            QTimer.singleShot(400, self._reload_users)
            self._update_security_constraints()
            self.activity_message.emit("Primeiro administrador criado.", True)
        elif op_name == "create_user":
            self._pending_create = None
            self._reload_users()
            QTimer.singleShot(400, self._reload_users)
            self._update_security_constraints()
            self.activity_message.emit("Usuario criado.", True)
        elif op_name == "update_user":
            self._pending_update = None
            self._reload_users()
            QTimer.singleShot(400, self._reload_users)
            self.activity_message.emit("Perfil atualizado.", True)
        elif op_name == "delete_user":
            self._pending_delete_user_id = None
            self._reload_users()
            QTimer.singleShot(400, self._reload_users)
            self._update_security_constraints()
            self.activity_message.emit("Usuario excluido.", True)
        elif op_name == "refresh_users":
            self._reload_users()

    def _on_operation_failed(self, op_name: str, message: str) -> None:
        if op_name == "create_user":
            self._pending_create = None
        elif op_name == "delete_user":
            self._pending_delete_user_id = None
        elif op_name == "update_user":
            self._pending_update = None
        elif op_name == "fetch_roles":
            self._pending_roles_for_create = False
            self._pending_edit_user_id = None

        self.activity_message.emit(message, False)

        if op_name in {"create_user", "update_user", "delete_user", "fetch_roles", "bootstrap_first_admin"}:
            titles = {
                "create_user": "Criar usuario",
                "update_user": "Editar perfil",
                "delete_user": "Excluir usuario",
                "fetch_roles": "Moonlight Web",
                "bootstrap_first_admin": "Criar primeiro administrador",
            }
            QMessageBox.warning(self, titles.get(op_name, "Moonlight Web"), message)

    def on_action_finished(self, action: str, success: bool) -> None:
        if action in {"moonlight_apply_settings", "moonlight_expose"}:
            self._load_settings_into_ui()
            self._update_funnel_account_state(self._funnel_check.isChecked())
            if not success and self._funnel_check.isChecked():
                self.activity_message.emit(
                    "Funnel nao iniciou. Verifique ACL (nodeAttrs funnel), MagicDNS e Enable HTTPS, "
                    "reinicie o Tailscale e clique Salvar e aplicar.",
                    False,
                )
        if action in {"moonlight_ligar", "moonlight_expose"} and success:
            QTimer.singleShot(2000, self._reload_users)
        if action == "moonlight_ligar" and success:
            QTimer.singleShot(800, self._warm_admin_session)
