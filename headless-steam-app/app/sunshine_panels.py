"""Sunshine configuration panels for the Qt app."""

from __future__ import annotations

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QCheckBox,
    QFormLayout,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from app.constants import APP_DISPLAY_NAME
from app.games_library import GamesLibraryWidget
from app.host_free_requirements import update_host_free_requirements
from app.host_settings_store import HostSettings, load_settings, save_settings
from app.sunshine_service import SunshineService
from app.widgets import ActionButton, LinkButton, NoWheelComboBox, SurfaceCard


class SunshinePage(QWidget):
    """Full Sunshine tab: setup, PIN, clients, config, apps."""

    request_action = Signal(str)
    activity_message = Signal(str, bool)
    open_web_panel = Signal()

    def __init__(self, sunshine_service: SunshineService, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self._service = sunshine_service
        self._config_cache: dict | None = None
        self._needs_setup = False
        self._sunshine_running = False
        self._api_busy = False
        self._pending_gamepad_mode: str | None = None
        self._last_panel_url = ""
        self._last_needs_setup: bool | None = None
        self._last_running: bool | None = None
        self._pending_restart_save = False
        self._loading_host_settings = False
        self._host_free_pending: bool | None = None

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QScrollArea.Shape.NoFrame)

        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(16)

        self._offline_label = QLabel("Sunshine desligado. Ligue o servico para usar estas opcoes.")
        self._offline_label.setObjectName("Muted")
        self._offline_label.setWordWrap(True)
        self._offline_label.setAutoFillBackground(False)
        layout.addWidget(self._offline_label)

        self._build_power_section(layout)
        self._build_pin_section(layout)
        self._build_clients_section(layout)
        self._build_config_section(layout)
        self._build_host_free_section(layout)
        self._build_apps_section(layout)
        self._build_advanced_link(layout)
        layout.addStretch()

        self._load_host_settings_into_ui()

        scroll.setWidget(content)
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(scroll)

        self._service.operation_finished.connect(self._on_operation_finished)
        self._service.operation_failed.connect(self._on_operation_failed)
        self._service.auth_required.connect(self._on_auth_required)

        self._update_availability()

    def _build_power_section(self, parent: QVBoxLayout) -> None:
        card = SurfaceCard("Servico")
        row = QHBoxLayout()
        row.setSpacing(10)
        self._btn_power_on = ActionButton("Ligar", "sunshine_ligar", "primary")
        self._btn_power_off = ActionButton("Desligar", "sunshine_desligar", "danger")
        self._btn_power_on.clicked.connect(lambda: self.request_action.emit("sunshine_ligar"))
        self._btn_power_off.clicked.connect(lambda: self.request_action.emit("sunshine_desligar"))
        row.addWidget(self._btn_power_on)
        row.addWidget(self._btn_power_off)
        row.addStretch()
        card.body.addLayout(row)
        parent.addWidget(card)

    def _build_pin_section(self, parent: QVBoxLayout) -> None:
        self._pin_card = SurfaceCard("Parear Moonlight (PIN)")
        hint = QLabel(
            "No Moonlight, adicione o PC e anote o PIN de 4 digitos. Informe-o aqui para parear."
        )
        hint.setObjectName("Muted")
        hint.setWordWrap(True)
        hint.setAutoFillBackground(False)
        self._pin_card.body.addWidget(hint)

        form = QFormLayout()
        self._pin_input = QLineEdit()
        self._pin_input.setMaxLength(4)
        self._pin_input.setPlaceholderText("0000")
        self._pin_name = QLineEdit()
        self._pin_name.setPlaceholderText("Meu celular")
        form.addRow("PIN", self._pin_input)
        form.addRow("Nome do dispositivo", self._pin_name)
        self._pin_card.body.addLayout(form)

        self._btn_pair = QPushButton("Parear dispositivo")
        self._btn_pair.setObjectName("PrimaryButton")
        self._btn_pair.setCursor(Qt.CursorShape.PointingHandCursor)
        self._btn_pair.clicked.connect(self._submit_pin)
        self._pin_card.body.addWidget(self._btn_pair)
        self._pin_card.hide()
        parent.addWidget(self._pin_card)

    def _build_clients_section(self, parent: QVBoxLayout) -> None:
        self._clients_card = SurfaceCard("Clientes pareados")
        self._clients_list = QListWidget()
        self._clients_list.setMinimumHeight(100)
        self._clients_card.body.addWidget(self._clients_list)

        row = QHBoxLayout()
        self._btn_refresh_clients = QPushButton("Atualizar")
        self._btn_refresh_clients.setObjectName("SecondaryButton")
        self._btn_refresh_clients.clicked.connect(self._refresh_clients)
        self._btn_unpair = QPushButton("Desparear selecionado")
        self._btn_unpair.setObjectName("DangerButton")
        self._btn_unpair.clicked.connect(self._unpair_selected)
        self._btn_unpair_all = QPushButton("Desparear todos")
        self._btn_unpair_all.setObjectName("DangerButton")
        self._btn_unpair_all.clicked.connect(self._unpair_all)
        row.addWidget(self._btn_refresh_clients)
        row.addWidget(self._btn_unpair)
        row.addWidget(self._btn_unpair_all)
        row.addStretch()
        self._clients_card.body.addLayout(row)
        self._clients_card.hide()
        parent.addWidget(self._clients_card)

    def _build_config_section(self, parent: QVBoxLayout) -> None:
        self._config_card = SurfaceCard("Configuracao")
        form = QFormLayout()
        form.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.ExpandingFieldsGrow)
        form.setFormAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignTop)
        form.setLabelAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
        form.setHorizontalSpacing(16)
        form.setVerticalSpacing(12)

        self._name_input = QLineEdit()
        self._gamepad_combo = NoWheelComboBox()
        self._gamepad_combo.addItems(["auto", "ds4", "x360"])
        self._pin_origin_combo = NoWheelComboBox()
        self._pin_origin_combo.addItems(["pc", "lan", "wan"])
        self._web_origin_combo = NoWheelComboBox()
        self._web_origin_combo.addItems(["pc", "lan", "wan"])
        self._upnp_combo = NoWheelComboBox()
        self._upnp_combo.addItems(["disabled", "enabled"])

        for combo in (
            self._gamepad_combo,
            self._pin_origin_combo,
            self._web_origin_combo,
            self._upnp_combo,
        ):
            combo.setMinimumWidth(260)
            combo.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

        form.addRow("Nome no Moonlight", self._name_input)
        form.addRow("Gamepad", self._gamepad_combo)
        form.addRow("PIN permitido de", self._pin_origin_combo)
        form.addRow("Web UI permitida de", self._web_origin_combo)
        form.addRow("UPnP", self._upnp_combo)
        self._config_card.body.addLayout(form)

        row = QHBoxLayout()
        self._btn_save_config = QPushButton("Salvar")
        self._btn_save_config.setObjectName("SecondaryButton")
        self._btn_save_config.clicked.connect(lambda: self._save_config(restart=False))
        self._btn_apply_config = QPushButton("Salvar e reiniciar")
        self._btn_apply_config.setObjectName("PrimaryButton")
        self._btn_apply_config.clicked.connect(lambda: self._save_config(restart=True))
        row.addWidget(self._btn_save_config)
        row.addWidget(self._btn_apply_config)
        row.addStretch()
        self._config_card.body.addLayout(row)
        self._config_card.hide()
        parent.addWidget(self._config_card)

    def _build_host_free_section(self, parent: QVBoxLayout) -> None:
        self._host_free_card = SurfaceCard("Tela virtual (Experimental)")
        intro = QLabel(
            "Permite usar o computador normalmente, enquanto quem joga em outra sessão "
            "(Recomendável jogar em modo gamepad)."
        )
        intro.setObjectName("Muted")
        intro.setWordWrap(True)
        intro.setAutoFillBackground(False)
        self._host_free_card.body.addWidget(intro)

        self._host_free_enabled = QCheckBox("Iniciar jogo em uma tela virtual")
        self._host_free_enabled.toggled.connect(self._on_host_free_toggled)
        self._host_free_card.body.addWidget(self._host_free_enabled)

        host_free_warn = QLabel("Nem todos os jogos podem funcionar.")
        host_free_warn.setObjectName("Muted")
        host_free_warn.setWordWrap(True)
        host_free_warn.setAutoFillBackground(False)
        self._host_free_card.body.addWidget(host_free_warn)

        self._host_free_req_vdd = QLabel()
        self._host_free_req_vdd.setAutoFillBackground(False)
        self._host_free_card.body.addWidget(self._host_free_req_vdd)

        self._host_free_req_monitor = QLabel()
        self._host_free_req_monitor.setAutoFillBackground(False)
        self._host_free_card.body.addWidget(self._host_free_req_monitor)

        self._host_free_req_sunshine = QLabel()
        self._host_free_req_sunshine.setAutoFillBackground(False)
        self._host_free_card.body.addWidget(self._host_free_req_sunshine)

        self._host_free_note = QLabel()
        self._host_free_note.setObjectName("Muted")
        self._host_free_note.setWordWrap(True)
        self._host_free_note.setAutoFillBackground(False)
        self._host_free_note.hide()
        self._host_free_card.body.addWidget(self._host_free_note)

        self._host_free_actions = QWidget()
        actions_row = QHBoxLayout(self._host_free_actions)
        actions_row.setContentsMargins(0, 0, 0, 0)
        actions_row.setSpacing(10)
        self._btn_install_vdd = ActionButton("Instalar monitor virtual", "vdd_install", "secondary")
        self._btn_install_vdd.clicked.connect(lambda: self.request_action.emit("vdd_install"))
        actions_row.addWidget(self._btn_install_vdd)
        actions_row.addStretch()
        self._host_free_card.body.addWidget(self._host_free_actions)
        parent.addWidget(self._host_free_card)

    def _set_host_free_checkbox(self, checked: bool) -> None:
        self._loading_host_settings = True
        self._host_free_enabled.setChecked(checked)
        self._loading_host_settings = False

    def _load_host_settings_into_ui(self) -> None:
        settings = load_settings()
        self._loading_host_settings = True
        self._host_free_enabled.setChecked(settings.host_free_mode_enabled)
        self._desktop_access.setChecked(settings.desktop_access_enabled)
        self._loading_host_settings = False

    def _persist_host_settings(self) -> None:
        if self._loading_host_settings:
            return
        current = load_settings()
        host_free = self._host_free_enabled.isChecked()
        save_settings(
            HostSettings(
                host_free_mode_enabled=host_free,
                keep_focus_enabled=current.keep_focus_enabled if not host_free else False,
                desktop_access_enabled=current.desktop_access_enabled,
                stream_output_device_id=current.stream_output_device_id if host_free else None,
            )
        )

    def _persist_desktop_access(self) -> None:
        if self._loading_host_settings:
            return
        current = load_settings()
        save_settings(
            HostSettings(
                host_free_mode_enabled=current.host_free_mode_enabled,
                keep_focus_enabled=current.keep_focus_enabled,
                desktop_access_enabled=self._desktop_access.isChecked(),
                stream_output_device_id=current.stream_output_device_id,
            )
        )

    def _revert_host_free_toggle(self, *, wanted_enabled: bool) -> None:
        """Revert UI/settings after a failed enable/disable of host-free mode."""
        self._host_free_pending = None
        self._set_host_free_checkbox(not wanted_enabled)
        current = load_settings()
        if wanted_enabled:
            save_settings(
                HostSettings(
                    host_free_mode_enabled=False,
                    keep_focus_enabled=True,
                    desktop_access_enabled=current.desktop_access_enabled,
                    stream_output_device_id=None,
                )
            )
        else:
            save_settings(
                HostSettings(
                    host_free_mode_enabled=True,
                    keep_focus_enabled=False,
                    desktop_access_enabled=current.desktop_access_enabled,
                    stream_output_device_id=current.stream_output_device_id,
                )
            )

    def _on_desktop_access_toggled(self, _checked: bool) -> None:
        if self._loading_host_settings:
            return
        self._persist_desktop_access()
        self.request_action.emit("atualizar_jogos")

    def _on_host_free_toggled(self, checked: bool) -> None:
        if self._loading_host_settings:
            return
        self._host_free_pending = checked
        self._persist_host_settings()
        if checked:
            self.request_action.emit("host_free_setup")
        else:
            self.request_action.emit("host_free_teardown")

    def update_host_free_status(self, status) -> None:
        update_host_free_requirements(
            status,
            vdd_label=self._host_free_req_vdd,
            monitor_label=self._host_free_req_monitor,
            sunshine_label=self._host_free_req_sunshine,
            note_label=self._host_free_note,
        )
        if self._host_free_pending is not None:
            self._set_host_free_checkbox(self._host_free_pending)
        else:
            self._set_host_free_checkbox(status.host_free_mode_enabled)
        self._btn_install_vdd.setVisible(not status.virtual_display_installed)
        self._host_free_actions.setVisible(not status.virtual_display_installed)

    def _build_apps_section(self, parent: QVBoxLayout) -> None:
        self._apps_card = SurfaceCard("Jogos no Sunshine")
        hint = QLabel("Lista sincronizada da Steam. Use Sincronizar jogos para atualizar.")
        hint.setObjectName("Muted")
        hint.setAutoFillBackground(False)
        self._apps_card.body.addWidget(hint)

        self._desktop_access = QCheckBox("Permitir acesso ao Desktop no Moonlight")
        self._desktop_access.setToolTip(
            "Quando ativado, convidados podem iniciar stream da area de trabalho. "
            "Desativado por padrao — apenas jogos da lista."
        )
        self._desktop_access.toggled.connect(self._on_desktop_access_toggled)
        self._apps_card.body.addWidget(self._desktop_access)

        self._apps_library = GamesLibraryWidget(self._service, layout_mode="list")
        self._apps_library.setMinimumHeight(280)
        self._apps_card.body.addWidget(self._apps_library)

        row = QHBoxLayout()
        self._btn_refresh_apps = QPushButton("Atualizar lista")
        self._btn_refresh_apps.setObjectName("SecondaryButton")
        self._btn_refresh_apps.clicked.connect(self._refresh_apps)
        self._btn_sync_apps = ActionButton("Sincronizar jogos", "atualizar_jogos")
        self._btn_sync_apps.clicked.connect(lambda: self.request_action.emit("atualizar_jogos"))
        row.addWidget(self._btn_refresh_apps)
        row.addWidget(self._btn_sync_apps)
        row.addStretch()
        self._apps_card.body.addLayout(row)
        self._apps_card.hide()
        parent.addWidget(self._apps_card)

    def _build_advanced_link(self, parent: QVBoxLayout) -> None:
        card = SurfaceCard("Opcoes avancadas")
        link = LinkButton("Abrir painel web do Sunshine", "https://localhost:47990")
        link.clicked_url.connect(lambda _u: self.open_web_panel.emit())
        card.body.addWidget(link)
        parent.addWidget(card)

    def update_status(
        self,
        *,
        sunshine_running: bool,
        sunshine_needs_setup: bool,
        panel_url: str,
        gamepad_mode: str,
        sunshine_username: str | None = None,
    ) -> None:
        self._sunshine_running = sunshine_running
        self._needs_setup = sunshine_needs_setup
        self._service.set_base_url(panel_url)
        self._update_availability()

        state_changed = (
            self._last_running != sunshine_running
            or self._last_needs_setup != sunshine_needs_setup
            or self._last_panel_url != panel_url
        )
        self._last_running = sunshine_running
        self._last_needs_setup = sunshine_needs_setup
        self._last_panel_url = panel_url

        if (
            sunshine_running
            and self._service.has_saved_credentials()
            and state_changed
            and not self._api_busy
        ):
            self._service.fetch_config()
            self._service.fetch_clients()
            self._service.fetch_apps()

    def on_action_finished(self, action: str, success: bool) -> None:
        if action == "atualizar_jogos" and success and self._sunshine_running:
            self._refresh_apps()
        if action == "host_free_setup":
            if success:
                self._host_free_pending = None
                self._load_host_settings_into_ui()
            else:
                self._revert_host_free_toggle(wanted_enabled=True)
        elif action == "host_free_teardown":
            if success:
                self._host_free_pending = None
                self._load_host_settings_into_ui()
            else:
                self._revert_host_free_toggle(wanted_enabled=False)
        elif action == "vdd_install" and success:
            self.request_action.emit("host_free_setup")

    def _update_availability(self) -> None:
        online = self._sunshine_running
        has_creds = self._service.has_saved_credentials()

        self._offline_label.setVisible(not online)

        show_api = online and has_creds

        if show_api:
            self._pin_card.show()
            self._clients_card.show()
            self._config_card.show()
            self._apps_card.show()
        else:
            self._pin_card.hide()
            self._clients_card.hide()
            self._config_card.hide()
            self._apps_card.hide()

        api_enabled = show_api
        for widget in (
            self._pin_input,
            self._pin_name,
            self._btn_pair,
            self._clients_list,
            self._btn_refresh_clients,
            self._btn_unpair,
            self._btn_unpair_all,
            self._name_input,
            self._gamepad_combo,
            self._pin_origin_combo,
            self._web_origin_combo,
            self._upnp_combo,
            self._btn_save_config,
            self._btn_apply_config,
            self._desktop_access,
            self._apps_library,
            self._btn_refresh_apps,
            self._btn_sync_apps,
        ):
            widget.setEnabled(api_enabled and not self._api_busy)

        for widget in (
            self._btn_power_on,
            self._btn_power_off,
        ):
            widget.setEnabled(not self._api_busy)

    def _set_api_busy(self, busy: bool) -> None:
        self._api_busy = busy
        self._update_availability()

    def _submit_pin(self) -> None:
        pin = self._pin_input.text().strip()
        if len(pin) != 4 or not pin.isdigit():
            QMessageBox.warning(self, APP_DISPLAY_NAME, "Informe um PIN de 4 digitos.")
            return
        self._set_api_busy(True)
        self._service.pair_pin(pin, self._pin_name.text().strip())

    def _refresh_clients(self) -> None:
        self._set_api_busy(True)
        self._service.fetch_clients()

    def _unpair_selected(self) -> None:
        item = self._clients_list.currentItem()
        if not item:
            QMessageBox.information(self, APP_DISPLAY_NAME, "Selecione um cliente.")
            return
        uuid = item.data(Qt.ItemDataRole.UserRole)
        if not uuid:
            return
        self._set_api_busy(True)
        self._service.unpair_client(str(uuid))

    def _unpair_all(self) -> None:
        answer = QMessageBox.question(
            self,
            APP_DISPLAY_NAME,
            "Desparear todos os dispositivos?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
        )
        if answer != QMessageBox.StandardButton.Yes:
            return
        self._set_api_busy(True)
        self._service.unpair_all_clients()

    def _save_config(self, restart: bool) -> None:
        changes = {
            "sunshine_name": self._name_input.text().strip(),
            "gamepad": self._gamepad_combo.currentText(),
            "origin_pin_allowed": self._pin_origin_combo.currentText(),
            "origin_web_ui_allowed": self._web_origin_combo.currentText(),
            "upnp": self._upnp_combo.currentText(),
        }
        if changes["gamepad"] == "ds4":
            changes["motion_as_ds4"] = "enabled"
            changes["touchpad_as_ds4"] = "enabled"
        self._set_api_busy(True)
        self._pending_restart_save = restart
        self._service.save_config(changes, restart=restart)

    def _refresh_apps(self) -> None:
        self._set_api_busy(True)
        self._service.fetch_apps()

    def set_gamepad_via_api(self, mode: str) -> None:
        if not self._sunshine_running:
            self.request_action.emit(f"gamepad_{mode}")
            return
        if not self._service.has_saved_credentials():
            QMessageBox.warning(
                self,
                APP_DISPLAY_NAME,
                "Faca login na aba Conta Sunshine antes de alterar o gamepad.",
            )
            return
        self._pending_gamepad_mode = mode
        self._set_api_busy(True)
        self._service.set_gamepad(mode)

    def _populate_config_form(self, config: dict) -> None:
        self._name_input.setText(str(config.get("sunshine_name", "")))
        for combo, key in (
            (self._gamepad_combo, "gamepad"),
            (self._pin_origin_combo, "origin_pin_allowed"),
            (self._web_origin_combo, "origin_web_ui_allowed"),
            (self._upnp_combo, "upnp"),
        ):
            value = str(config.get(key, "")).strip()
            if not value:
                continue
            idx = combo.findText(value)
            if idx >= 0:
                combo.setCurrentIndex(idx)

    def _populate_clients(self, clients: list) -> None:
        self._clients_list.clear()
        for client in clients:
            if not isinstance(client, dict):
                continue
            name = client.get("name") or client.get("alias") or "Dispositivo"
            uuid = client.get("uuid") or client.get("uniqueid") or ""
            item_text = f"{name}"
            if uuid:
                item_text += f"  ({uuid[:8]}…)" if len(str(uuid)) > 8 else f"  ({uuid})"
            self._clients_list.addItem(item_text)
            item = self._clients_list.item(self._clients_list.count() - 1)
            if item:
                item.setData(Qt.ItemDataRole.UserRole, uuid)

    def _populate_apps(self, apps: list) -> None:
        use_api = self._sunshine_running and self._service.has_saved_credentials()
        self._apps_library.set_apps(
            [app for app in apps if isinstance(app, dict)],
            use_api=use_api,
        )

    def on_logged_out(self) -> None:
        self._update_availability()

    def _on_auth_required(self) -> None:
        self._pin_card.hide()
        self._clients_card.hide()
        self._config_card.hide()
        self._apps_card.hide()

    def _on_operation_finished(self, op_name: str, result: object) -> None:
        self._set_api_busy(False)
        if op_name == "change_password":
            self.activity_message.emit("Senha alterada com sucesso.", True)
        elif op_name == "pair_pin":
            self.activity_message.emit("Dispositivo pareado com sucesso.", True)
            self._pin_input.clear()
            self._pin_name.clear()
            self._service.fetch_clients()
        elif op_name == "fetch_config" and isinstance(result, dict):
            self._config_cache = result
            self._populate_config_form(result)
        elif op_name == "fetch_clients" and isinstance(result, list):
            self._populate_clients(result)
        elif op_name in ("unpair_client", "unpair_all"):
            self.activity_message.emit("Cliente(s) despareado(s).", True)
            self._service.fetch_clients()
        elif op_name == "save_config":
            if self._pending_restart_save:
                self.activity_message.emit(
                    "Configuracao salva e Sunshine reiniciado com sucesso.",
                    True,
                )
            else:
                self.activity_message.emit("Configuracao salva.", True)
            self._pending_restart_save = False
            self._service.fetch_config()
        elif op_name == "set_gamepad":
            self._pending_gamepad_mode = None
            self.activity_message.emit("Gamepad configurado.", True)
            self._service.fetch_config()
        elif op_name == "fetch_apps" and isinstance(result, list):
            self._populate_apps(result)

    def _on_operation_failed(self, op_name: str, message: str) -> None:
        self._set_api_busy(False)
        self._pending_restart_save = False
        if op_name in ("fetch_config", "fetch_clients", "fetch_apps"):
            return
        self.activity_message.emit(message, False)
        if op_name == "set_gamepad" and self._pending_gamepad_mode:
            mode = self._pending_gamepad_mode
            self._pending_gamepad_mode = None
            self.request_action.emit(f"gamepad_{mode}")
