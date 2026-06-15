"""Dialog to change Sunshine web UI credentials."""

from __future__ import annotations

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QVBoxLayout,
)


class ChangePasswordDialog(QDialog):
    def __init__(self, username: str = "", parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Mudar a senha")
        self.setModal(True)
        self.resize(400, 260)

        layout = QVBoxLayout(self)
        layout.setSpacing(12)

        hint = QLabel(
            "Altera o usuario e senha do painel Sunshine. "
            "O Sunshine precisa estar ligado."
        )
        hint.setWordWrap(True)
        hint.setObjectName("Muted")
        layout.addWidget(hint)

        form = QFormLayout()
        form.setSpacing(10)

        self._current_password = QLineEdit()
        self._current_password.setEchoMode(QLineEdit.EchoMode.Password)
        self._new_username = QLineEdit(username)
        self._new_password = QLineEdit()
        self._new_password.setEchoMode(QLineEdit.EchoMode.Password)
        self._confirm_password = QLineEdit()
        self._confirm_password.setEchoMode(QLineEdit.EchoMode.Password)

        form.addRow("Senha atual", self._current_password)
        form.addRow("Usuario", self._new_username)
        form.addRow("Nova senha", self._new_password)
        form.addRow("Confirmar senha", self._confirm_password)
        layout.addLayout(form)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Cancel | QDialogButtonBox.StandardButton.Save
        )
        buttons.button(QDialogButtonBox.StandardButton.Save).setObjectName("PrimaryButton")
        buttons.accepted.connect(self._validate_and_accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _validate_and_accept(self) -> None:
        current = self._current_password.text()
        user = self._new_username.text().strip()
        new_pass = self._new_password.text()
        confirm = self._confirm_password.text()

        if not current:
            QMessageBox.warning(self, "Mudar a senha", "Informe a senha atual.")
            return
        if not user:
            QMessageBox.warning(self, "Mudar a senha", "Informe o usuario.")
            return
        if not new_pass:
            QMessageBox.warning(self, "Mudar a senha", "Informe a nova senha.")
            return
        if new_pass != confirm:
            QMessageBox.warning(self, "Mudar a senha", "A confirmacao da senha nao confere.")
            return
        self.accept()

    @property
    def current_password(self) -> str:
        return self._current_password.text()

    @property
    def new_username(self) -> str:
        return self._new_username.text().strip()

    @property
    def new_password(self) -> str:
        return self._new_password.text()

    @property
    def confirm_password(self) -> str:
        return self._confirm_password.text()
