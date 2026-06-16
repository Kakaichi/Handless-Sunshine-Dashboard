"""Floating toast notifications (overlay, no layout shift)."""

from __future__ import annotations

from PySide6.QtCore import QEvent, QObject, Qt, QTimer
from PySide6.QtWidgets import (
    QFrame,
    QHBoxLayout,
    QLabel,
    QProgressBar,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

ACTIVITY_HIDE_MS = 4000
TOAST_WIDTH = 400
TOAST_MARGIN = 20


def _transparent_label(text: str = "", object_name: str = "") -> QLabel:
    label = QLabel(text)
    label.setAutoFillBackground(False)
    if object_name:
        label.setObjectName(object_name)
    return label


def _apply_property(widget: QFrame, name: str, value: str) -> None:
    widget.setProperty(name, value)
    widget.style().unpolish(widget)
    widget.style().polish(widget)


class ActivityToast(QFrame):
    """Transient toast for action progress and results."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("ToastActivity")
        self.setProperty("status", "idle")
        self.setFixedWidth(TOAST_WIDTH)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(14, 10, 14, 10)
        layout.setSpacing(4)

        self._title = _transparent_label("Pronto", "ActivityTitle")
        layout.addWidget(self._title)

        self._message = _transparent_label("", "Muted")
        self._message.setWordWrap(True)
        self._message.hide()
        layout.addWidget(self._message)

        self._progress = QProgressBar()
        self._progress.setTextVisible(False)
        self._progress.hide()
        layout.addWidget(self._progress)

        self._hide_timer = QTimer(self)
        self._hide_timer.setSingleShot(True)
        self._hide_timer.timeout.connect(self.hide_idle)

        self.hide()

    def title(self) -> str:
        return self._title.text()

    def set_title(self, text: str) -> None:
        self._title.setText(text)

    def message(self) -> str:
        return self._message.text()

    def set_message(self, text: str) -> None:
        self._message.setText(text)
        self._message.show()

    def show_running(self, title: str, message: str = "Executando…") -> None:
        self._hide_timer.stop()
        _apply_property(self, "status", "running")
        self._title.setText(title)
        self._message.setText(message)
        self._message.show()
        self._progress.setRange(0, 0)
        self._progress.show()
        self.show()

    def show_result(self, title: str, success: bool, message: str) -> None:
        self._hide_timer.stop()
        status = "success" if success else "error"
        _apply_property(self, "status", status)
        self._title.setText(title)
        self._message.setText(message)
        self._message.show()
        self._progress.hide()
        self.show()
        self._hide_timer.start(ACTIVITY_HIDE_MS)

    def show_for_message_update(self) -> None:
        self._hide_timer.stop()
        self.show()

    def set_progress_indeterminate(self) -> None:
        self._progress.setRange(0, 0)

    def set_progress_determinate(self, value: int) -> None:
        self._progress.setRange(0, 100)
        self._progress.setValue(max(0, min(100, value)))

    def show_progress(self) -> None:
        self._progress.show()

    def hide_progress(self) -> None:
        self._progress.hide()

    def hide_idle(self) -> None:
        self._hide_timer.stop()
        _apply_property(self, "status", "idle")
        self.hide()


class BannerToast(QFrame):
    """Persistent toast with message and action buttons."""

    def __init__(self, kind: str, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("ToastBanner")
        self.setProperty("kind", kind)
        width = 420 if kind == "update" else TOAST_WIDTH
        self.setFixedWidth(width)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(14, 12, 14, 12)
        layout.setSpacing(10)

        self._message = _transparent_label()
        self._message.setWordWrap(True)
        layout.addWidget(self._message)

        self._buttons = QVBoxLayout() if kind == "update" else QHBoxLayout()
        self._buttons.setSpacing(8)
        layout.addLayout(self._buttons)

        self.hide()

    def set_message(self, text: str) -> None:
        self._message.setText(text)

    def add_button(self, label: str, object_name: str = "") -> QPushButton:
        btn = QPushButton(label)
        btn.setCursor(Qt.CursorShape.PointingHandCursor)
        if object_name:
            btn.setObjectName(object_name)
        self._buttons.addWidget(btn)
        return btn

    def add_stretch(self) -> None:
        if isinstance(self._buttons, QHBoxLayout):
            self._buttons.addStretch()


class ToastHost(QWidget):
    """Full-area overlay stacking toasts at the bottom-right corner."""

    def __init__(self, parent: QWidget) -> None:
        super().__init__(parent)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
        self.setAttribute(Qt.WidgetAttribute.WA_NoSystemBackground)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(TOAST_MARGIN, TOAST_MARGIN, TOAST_MARGIN, TOAST_MARGIN)
        outer.addStretch()

        row = QHBoxLayout()
        row.addStretch()

        stack = QVBoxLayout()
        stack.setSpacing(8)

        self._setup = BannerToast("setup", self)
        self.setup_open_btn = self._setup.add_button(
            "Ir para Conta Sunshine", "PrimaryButton"
        )
        self._setup.add_stretch()

        self._update = BannerToast("update", self)
        self.update_install_btn = self._update.add_button(
            "Baixar e atualizar", "PrimaryButton"
        )
        self.update_release_btn = self._update.add_button("Ver no GitHub")
        self.update_dismiss_btn = self._update.add_button("Agora nao")

        self._activity = ActivityToast(self)

        stack.addWidget(self._setup)
        stack.addWidget(self._update)
        stack.addWidget(self._activity)
        row.addLayout(stack)
        outer.addLayout(row)

        parent.installEventFilter(self)
        self._sync_geometry()

    def _sync_geometry(self) -> None:
        parent = self.parentWidget()
        if parent is not None:
            self.setGeometry(parent.rect())

    def eventFilter(self, obj: QObject, event: QEvent) -> bool:  # noqa: N802
        if obj is self.parentWidget() and event.type() == QEvent.Type.Resize:
            self._sync_geometry()
        return super().eventFilter(obj, event)

    def raise_overlay(self) -> None:
        self.raise_()
        self.show()

    def show_setup(self, message: str) -> None:
        self._setup.set_message(message)
        self._setup.show()

    def hide_setup(self) -> None:
        self._setup.hide()

    def show_update(self, message: str) -> None:
        self._update.set_message(message)
        self._update.show()

    def hide_update(self) -> None:
        self._update.hide()

    def set_activity_idle(self) -> None:
        self._activity.hide_idle()

    def show_activity(self) -> None:
        self._activity.show_for_message_update()

    def set_activity_running(self, title: str, message: str = "Executando…") -> None:
        self._activity.show_running(title, message)

    def set_activity_result(self, title: str, success: bool, message: str) -> None:
        self._activity.show_result(title, success, message)

    def set_activity_message(self, message: str) -> None:
        self._activity.set_message(message)

    def activity_title(self) -> str:
        return self._activity.title()

    def set_activity_title(self, title: str) -> None:
        self._activity.set_title(title)

    def activity_message(self) -> str:
        return self._activity.message()

    def set_progress_indeterminate(self) -> None:
        self._activity.set_progress_indeterminate()

    def set_progress_value(self, value: int) -> None:
        self._activity.set_progress_determinate(value)

    def show_progress(self) -> None:
        self._activity.show_progress()

    def hide_progress(self) -> None:
        self._activity.hide_progress()
