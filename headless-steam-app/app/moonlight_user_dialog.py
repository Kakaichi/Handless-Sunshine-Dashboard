"""Dialog to create a Moonlight Web user."""

from __future__ import annotations

from app.widgets import NoWheelComboBox
from PySide6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QFormLayout,
    QLabel,
    QLineEdit,
    QMessageBox,
    QVBoxLayout,
)


class MoonlightUserDialog(QDialog):
    def __init__(
        self,
        roles: list[tuple[str, str]],
        parent=None,
        *,
        first_user: bool = False,
        bootstrap: bool = False,
    ) -> None:
        super().__init__(parent)
        self._bootstrap = bootstrap
        self.setWindowTitle("Criar primeiro administrador" if bootstrap else "Criar usuario")
        self.setModal(True)
        self.resize(400, 260 if bootstrap else 240)

        layout = QVBoxLayout(self)
        layout.setSpacing(12)

        if bootstrap:
            hint_text = (
                "Nenhum usuario cadastrado. O Moonlight Web cria o primeiro login "
                "automaticamente como administrador — nao e preciso conta admin existente."
            )
        else:
            hint_text = "Requer Moonlight Web ligado e conta admin."
            if first_user:
                hint_text += " O primeiro usuario tambem pode ser criado no login web."
        hint = QLabel(hint_text)
        hint.setWordWrap(True)
        hint.setObjectName("Muted")
        layout.addWidget(hint)

        form = QFormLayout()
        form.setSpacing(10)

        self._name = QLineEdit()
        self._password = QLineEdit()
        self._password.setEchoMode(QLineEdit.EchoMode.Password)
        self._role = NoWheelComboBox()
        for label, role_id in roles:
            self._role.addItem(label, role_id)

        form.addRow("Nome", self._name)
        form.addRow("Senha", self._password)
        if not bootstrap:
            form.addRow("Perfil", self._role)
        layout.addLayout(form)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Cancel | QDialogButtonBox.StandardButton.Save
        )
        buttons.button(QDialogButtonBox.StandardButton.Save).setObjectName("PrimaryButton")
        buttons.accepted.connect(self._validate_and_accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def _validate_and_accept(self) -> None:
        if not self._name.text().strip():
            QMessageBox.warning(self, "Criar usuario", "Informe o nome.")
            return
        if not self._password.text():
            QMessageBox.warning(self, self.windowTitle(), "Informe a senha.")
            return
        if not self._bootstrap and self._role.currentData() is None:
            QMessageBox.warning(self, self.windowTitle(), "Selecione um perfil.")
            return
        self.accept()

    @property
    def user_name(self) -> str:
        return self._name.text().strip()

    @property
    def password(self) -> str:
        return self._password.text()

    @property
    def role_id(self) -> str:
        if self._bootstrap:
            return ""
        return str(self._role.currentData())
