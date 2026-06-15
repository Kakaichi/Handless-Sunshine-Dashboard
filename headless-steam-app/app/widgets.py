"""Reusable UI widgets."""

from __future__ import annotations

from PySide6.QtCore import QSize, Qt, Signal
from PySide6.QtGui import QIcon, QMouseEvent, QWheelEvent
from PySide6.QtWidgets import (
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)


def _transparent_label(text: str = "", object_name: str = "") -> QLabel:
    label = QLabel(text)
    label.setAutoFillBackground(False)
    if object_name:
        label.setObjectName(object_name)
    return label


class NoWheelComboBox(QComboBox):
    """Ignore scroll wheel unless the dropdown list is open."""

    def __init__(self, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)

    def wheelEvent(self, event: QWheelEvent) -> None:  # noqa: N802
        popup = self.view()
        if popup is not None and popup.isVisible():
            super().wheelEvent(event)
        else:
            event.ignore()


class StatusCard(QFrame):
    clicked = Signal()

    def __init__(self, title: str, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("StatusCard")
        self.setMinimumHeight(110)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setProperty("active", False)
        self._running = False

        root = QHBoxLayout(self)
        root.setContentsMargins(18, 16, 18, 16)
        root.setSpacing(12)

        self._dot = _transparent_label("●", "StatusCardDot")
        self._dot.setFixedWidth(14)

        body = QVBoxLayout()
        body.setSpacing(4)

        self._title = _transparent_label(title, "StatusCardTitle")
        self._value = _transparent_label("—", "StatusCardValue")
        self._detail = _transparent_label("", "StatusCardDetail")
        self._detail.setWordWrap(True)

        body.addWidget(self._title)
        body.addWidget(self._value)
        body.addWidget(self._detail)

        root.addWidget(self._dot, alignment=Qt.AlignmentFlag.AlignTop)
        root.addLayout(body, stretch=1)

    def set_state(self, value: str, accent: str, detail: str = "") -> None:
        self._value.setText(value)
        self._value.setStyleSheet(
            f"background: transparent; font-size: 18px; font-weight: 600; color: {accent};"
        )
        self._dot.setStyleSheet(f"background: transparent; font-size: 10px; color: {accent};")
        self._detail.setText(detail)

    def set_running(self, running: bool) -> None:
        self._running = running
        self.setProperty("active", running)
        self.style().unpolish(self)
        self.style().polish(self)

    def is_running(self) -> bool:
        return self._running

    def mousePressEvent(self, event: QMouseEvent) -> None:  # noqa: N802
        if self.isEnabled() and event.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit()
        super().mousePressEvent(event)


class IconToolButton(QPushButton):
    def __init__(
        self,
        icon: QIcon,
        tooltip: str = "",
        variant: str = "icon",
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(parent)
        names = {
            "icon": "IconButton",
            "power": "PowerButton",
        }
        self.setObjectName(names.get(variant, "IconButton"))
        self.setIcon(icon)
        self.setIconSize(QSize(22, 22))
        self.setFixedSize(44, 44)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setToolTip(tooltip)
        self.setProperty("active", False)

    def set_active(self, active: bool) -> None:
        self.setProperty("active", active)
        self.style().unpolish(self)
        self.style().polish(self)


class ActionButton(QPushButton):
    def __init__(
        self,
        label: str,
        action: str,
        variant: str = "secondary",
        parent: QWidget | None = None,
    ) -> None:
        super().__init__(label, parent)
        self.action = action
        names = {
            "primary": "PrimaryButton",
            "danger": "DangerButton",
            "secondary": "SecondaryButton",
        }
        self.setObjectName(names.get(variant, "SecondaryButton"))
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setMinimumHeight(40)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)


class LinkButton(QPushButton):
    clicked_url = Signal(str)

    def __init__(self, label: str, url: str, parent: QWidget | None = None) -> None:
        super().__init__(label, parent)
        self._url = url
        self.setObjectName("LinkButton")
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.clicked.connect(lambda: self.clicked_url.emit(self._url))

    def set_url(self, label: str, url: str) -> None:
        self._url = url
        self.setText(label)
        self.setEnabled(bool(url))


class SurfaceCard(QFrame):
    def __init__(self, title: str, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.setObjectName("SurfaceCard")
        layout = QVBoxLayout(self)
        layout.setContentsMargins(20, 16, 20, 16)
        layout.setSpacing(12)

        heading = _transparent_label(title, "SectionTitle")
        layout.addWidget(heading)
        self.body = QVBoxLayout()
        self.body.setSpacing(10)
        layout.addLayout(self.body)
