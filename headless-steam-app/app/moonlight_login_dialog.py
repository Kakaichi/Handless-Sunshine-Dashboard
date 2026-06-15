"""Prompt for Moonlight Web admin credentials."""

from __future__ import annotations

from PySide6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QVBoxLayout,
)


class MoonlightLoginDialog(QDialog):
    def __init__(self, username: str = "", parent=None) -> None:
        super().__init__(parent)
        self.setWindowTitle("Login Moonlight Web")
        self.setModal(True)
        self.resize(380, 200)

        layout = QVBoxLayout(self)
        layout.setSpacing(12)

        hint = QLabel("Use uma conta Admin do Moonlight Web.")
        hint.setWordWrap(True)
        hint.setObjectName("Muted")
        layout.addWidget(hint)

        form = QFormLayout()
        self._username = QLineEdit(username)
        self._password = QLineEdit()
        self._password.setEchoMode(QLineEdit.EchoMode.Password)
        form.addRow("Usuario", self._username)
        form.addRow("Senha", self._password)
        layout.addLayout(form)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Cancel | QDialogButtonBox.StandardButton.Ok
        )
        buttons.button(QDialogButtonBox.StandardButton.Ok).setObjectName("PrimaryButton")
        buttons.accepted.connect(self._validate_and_accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _validate_and_accept(self) -> None:
        if not self._username.text().strip():
            QMessageBox.warning(self, "Login Moonlight Web", "Informe o usuario.")
            return
        if not self._password.text():
            QMessageBox.warning(self, "Login Moonlight Web", "Informe a senha.")
            return
        self.accept()

    @property
    def username(self) -> str:
        return self._username.text().strip()

    @property
    def password(self) -> str:
        return self._password.text()
