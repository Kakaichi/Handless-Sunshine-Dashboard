"""Dialog to edit a Moonlight Web user profile."""

from __future__ import annotations

from app.widgets import NoWheelComboBox
from PySide6.QtWidgets import (
    QCheckBox,
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QVBoxLayout,
)


class MoonlightEditUserDialog(QDialog):
    def __init__(
        self,
        user_name: str,
        current_role_id: str | None,
        roles: list[tuple[str, str]],
        parent=None,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle("Editar perfil")
        self.setModal(True)
        self.resize(420, 260)

        layout = QVBoxLayout(self)
        layout.setSpacing(12)

        hint = QLabel("Altere o perfil (Admin/Usuario) e opcionalmente a senha.")
        hint.setWordWrap(True)
        hint.setObjectName("Muted")
        layout.addWidget(hint)

        form = QFormLayout()
        form.setSpacing(10)

        self._name = QLineEdit(user_name)
        self._name.setReadOnly(True)
        self._role = NoWheelComboBox()
        for label, role_id in roles:
            self._role.addItem(label, role_id)
        if current_role_id:
            index = self._role.findData(current_role_id)
            if index >= 0:
                self._role.setCurrentIndex(index)

        self._change_password = QCheckBox("Alterar senha")
        self._change_password.toggled.connect(self._on_password_toggle)
        self._password = QLineEdit()
        self._password.setEchoMode(QLineEdit.EchoMode.Password)
        self._password.setEnabled(False)

        form.addRow("Nome", self._name)
        form.addRow("Perfil", self._role)
        form.addRow(self._change_password)
        form.addRow("Nova senha", self._password)
        layout.addLayout(form)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Cancel | QDialogButtonBox.StandardButton.Save
        )
        buttons.button(QDialogButtonBox.StandardButton.Save).setObjectName("PrimaryButton")
        buttons.accepted.connect(self._validate_and_accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _on_password_toggle(self, checked: bool) -> None:
        self._password.setEnabled(checked)
        if not checked:
            self._password.clear()

    def _validate_and_accept(self) -> None:
        if self._role.currentData() is None:
            QMessageBox.warning(self, "Editar perfil", "Selecione um perfil.")
            return
        if self._change_password.isChecked() and not self._password.text():
            QMessageBox.warning(self, "Editar perfil", "Informe a nova senha ou desmarque a opcao.")
            return
        self.accept()

    @property
    def role_id(self) -> str:
        return str(self._role.currentData())

    @property
    def password(self) -> str | None:
        if self._change_password.isChecked():
            return self._password.text()
        return None
