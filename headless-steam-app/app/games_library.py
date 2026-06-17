"""Games library for dashboard grid and Sunshine list views."""

from __future__ import annotations

import math
from typing import Any, Callable, Literal

from PySide6.QtCore import QEvent, QObject, QRectF, QRunnable, QSize, Qt, QThreadPool, QTimer, Signal
from PySide6.QtGui import QColor, QFontMetrics, QIcon, QImage, QPainter, QPainterPath, QPixmap
from PySide6.QtWidgets import (
    QFrame,
    QGridLayout,
    QLabel,
    QListWidget,
    QListWidgetItem,
    QScrollArea,
    QSizePolicy,
    QVBoxLayout,
    QWidget,
)

from app.apps_loader import load_apps_from_disk, resolve_cover_path
from app.sunshine_service import SunshineService

TILE_WIDTH = 130
POSTER_HEIGHT = int(TILE_WIDTH * 1.5)  # 2:3 portrait (Steam 600x900)
TILE_SPACING = 12
TILE_NAME_HEIGHT = 20
TILE_HEIGHT = POSTER_HEIGHT + 6 + TILE_NAME_HEIGHT

LIST_ICON_WIDTH = 40
LIST_ICON_HEIGHT = 56
LIST_ROW_HEIGHT = 64

LayoutMode = Literal["grid", "list"]


class _CoverSignals(QObject):
    loaded = Signal(int, bytes)


class _CoverTask(QRunnable):
    def __init__(self, index: int, loader: Callable[[], bytes | None], signals: _CoverSignals) -> None:
        super().__init__()
        self._index = index
        self._loader = loader
        self._signals = signals
        self.setAutoDelete(True)

    def run(self) -> None:
        try:
            data = self._loader()
            if data:
                self._signals.loaded.emit(self._index, data)
        except Exception:
            return


def _fit_cover(pixmap: QPixmap, width: int, height: int) -> QPixmap:
    scaled = pixmap.scaled(
        width,
        height,
        Qt.AspectRatioMode.KeepAspectRatio,
        Qt.TransformationMode.SmoothTransformation,
    )
    frame = QPixmap(width, height)
    frame.fill(QColor("#252b33"))
    painter = QPainter(frame)
    painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
    x = (width - scaled.width()) // 2
    y = (height - scaled.height()) // 2
    painter.drawPixmap(x, y, scaled)
    painter.end()
    return frame


def _rounded_pixmap(pixmap: QPixmap, radius: int = 8) -> QPixmap:
    if pixmap.isNull():
        return pixmap
    result = QPixmap(pixmap.size())
    result.fill(Qt.GlobalColor.transparent)
    painter = QPainter(result)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    path = QPainterPath()
    path.addRoundedRect(QRectF(result.rect()), radius, radius)
    painter.setClipPath(path)
    painter.drawPixmap(0, 0, pixmap)
    painter.end()
    return result


def _placeholder_pixmap(letter: str, width: int, height: int) -> QPixmap:
    pixmap = QPixmap(width, height)
    pixmap.fill(Qt.GlobalColor.transparent)
    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    path = QPainterPath()
    path.addRoundedRect(QRectF(0, 0, width, height), 8, 8)
    painter.fillPath(path, QColor("#252b33"))
    painter.setPen(QColor("#8b929a"))
    font = painter.font()
    font.setPointSize(28)
    font.setBold(True)
    painter.setFont(font)
    painter.drawText(pixmap.rect(), Qt.AlignmentFlag.AlignCenter, letter)
    painter.end()
    return pixmap


class GameTile(QFrame):
    def __init__(self, name: str, index: int, parent: QWidget | None = None) -> None:
        super().__init__(parent)
        self.index = index
        self.setObjectName("GameTile")
        self.setFixedWidth(TILE_WIDTH)
        self.setMinimumHeight(TILE_HEIGHT)
        self.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(6)

        self._poster = QLabel()
        self._poster.setObjectName("GameTilePoster")
        self._poster.setFixedSize(TILE_WIDTH, POSTER_HEIGHT)
        self._poster.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._poster.setScaledContents(False)

        initial = name.strip()[:1].upper() if name.strip() else "?"
        self._poster.setPixmap(_rounded_pixmap(_placeholder_pixmap(initial, TILE_WIDTH, POSTER_HEIGHT)))

        self._name = QLabel(name)
        self._name.setObjectName("GameTileName")
        self._name.setFixedHeight(TILE_NAME_HEIGHT)
        self._name.setWordWrap(False)
        self._name.setAlignment(Qt.AlignmentFlag.AlignHCenter | Qt.AlignmentFlag.AlignTop)
        self._name.setToolTip(name)
        metrics = QFontMetrics(self._name.font())
        self._name.setText(metrics.elidedText(name, Qt.TextElideMode.ElideRight, TILE_WIDTH - 4))

        layout.addWidget(self._poster)
        layout.addWidget(self._name)

    def set_cover(self, pixmap: QPixmap) -> None:
        if pixmap.isNull():
            return
        fitted = _fit_cover(pixmap, TILE_WIDTH, POSTER_HEIGHT)
        self._poster.setPixmap(_rounded_pixmap(fitted))


class GamesLibraryWidget(QWidget):
    def __init__(
        self,
        sunshine_service: SunshineService | None = None,
        parent: QWidget | None = None,
        *,
        layout_mode: LayoutMode = "grid",
    ) -> None:
        super().__init__(parent)
        self._service = sunshine_service
        self._layout_mode = layout_mode
        self._use_api = False
        self._apps: list[dict[str, Any]] = []
        self._tiles: dict[int, GameTile] = {}
        self._list_items: dict[int, QListWidgetItem] = {}
        self._cover_cache: dict[int, QPixmap] = {}
        self._pending_covers: set[int] = set()
        self._last_cover_signature: tuple[str, ...] = ()
        self._disk_cover_by_name: dict[str, Any] = {}
        self._last_cols = 0
        self._thread_pool = QThreadPool.globalInstance()
        self._cover_signals = _CoverSignals()
        self._cover_signals.loaded.connect(self._on_cover_loaded)

        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 4, 0, 0)
        outer.setSpacing(0)

        self._empty_label = QLabel("Nenhum jogo encontrado.")
        self._empty_label.setObjectName("Muted")
        self._empty_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._empty_label.hide()
        outer.addWidget(self._empty_label)

        if self._layout_mode == "list":
            self._list_widget = QListWidget()
            self._list_widget.setObjectName("GamesList")
            self._list_widget.setUniformItemSizes(True)
            self._list_widget.setSelectionMode(QListWidget.SelectionMode.NoSelection)
            self._list_widget.setFocusPolicy(Qt.FocusPolicy.NoFocus)
            outer.addWidget(self._list_widget, stretch=1)
            self._scroll = None
            self._grid_host = None
            self._grid = None
        else:
            self._list_widget = None
            self._scroll = QScrollArea()
            self._scroll.setWidgetResizable(True)
            self._scroll.setFrameShape(QScrollArea.Shape.NoFrame)
            self._scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)

            self._grid_host = QWidget()
            self._grid_host.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Minimum)
            self._grid = QGridLayout(self._grid_host)
            self._grid.setContentsMargins(0, 12, 0, 8)
            self._grid.setSpacing(TILE_SPACING)
            self._grid.setAlignment(Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignLeft)

            self._scroll.setWidget(self._grid_host)
            self._scroll.viewport().installEventFilter(self)
            outer.addWidget(self._scroll, stretch=1)

    def set_use_api(self, use_api: bool) -> None:
        self._use_api = use_api

    def set_apps(
        self,
        apps: list[dict[str, Any]],
        *,
        use_api: bool | None = None,
        reload_covers: bool = False,
    ) -> None:
        if use_api is not None:
            self._use_api = use_api
        self._apps = [app for app in apps if isinstance(app, dict)]
        signature = self._cover_signature()
        if reload_covers or signature != self._last_cover_signature:
            self._cover_cache.clear()
            self._pending_covers.clear()
            self._last_cover_signature = signature
        self._disk_cover_by_name = {}
        for disk_app in load_apps_from_disk():
            name = str(disk_app.get("name", "") or "")
            if not name:
                continue
            local = resolve_cover_path(str(disk_app.get("image-path", "") or ""))
            if local:
                self._disk_cover_by_name[name] = local
        self._rebuild()
        self._load_covers()
        if self._layout_mode == "grid":
            self._schedule_layout_refresh()

    def _cover_signature(self) -> tuple[str, ...]:
        parts: list[str] = []
        for app in self._apps:
            name = str(app.get("name", "") or "")
            image_path = str(app.get("image-path", "") or "")
            mtime = ""
            local = resolve_cover_path(image_path)
            if local and local.is_file():
                try:
                    mtime = str(local.stat().st_mtime_ns)
                except OSError:
                    mtime = ""
            parts.append(f"{name}|{image_path}|{mtime}")
        return tuple(parts)

    def _placeholder_icon(self, letter: str) -> QIcon:
        pixmap = _rounded_pixmap(
            _placeholder_pixmap(letter, LIST_ICON_WIDTH, LIST_ICON_HEIGHT),
            radius=6,
        )
        return QIcon(pixmap)

    def _cover_icon(self, pixmap: QPixmap) -> QIcon:
        fitted = _fit_cover(pixmap, LIST_ICON_WIDTH, LIST_ICON_HEIGHT)
        return QIcon(_rounded_pixmap(fitted, radius=6))

    def _rebuild(self) -> None:
        if self._layout_mode == "list":
            self._rebuild_list()
        else:
            self._rebuild_grid()

    def _rebuild_list(self) -> None:
        if self._list_widget is None:
            return

        self._list_widget.clear()
        self._list_items.clear()

        if not self._apps:
            self._empty_label.setText(
                "Nenhum jogo encontrado. Sincronize os jogos Steam ou ligue o Sunshine."
            )
            self._empty_label.show()
            self._list_widget.hide()
            return

        self._empty_label.hide()
        self._list_widget.show()

        for index, app in enumerate(self._apps):
            name = str(app.get("name", "App"))
            item = QListWidgetItem(name)
            item.setSizeHint(QSize(0, LIST_ROW_HEIGHT))
            item.setToolTip(name)

            letter = name.strip()[:1].upper() if name.strip() else "?"
            item.setIcon(self._placeholder_icon(letter))
            if index in self._cover_cache:
                item.setIcon(self._cover_icon(self._cover_cache[index]))

            self._list_widget.addItem(item)
            self._list_items[index] = item

    def _available_width(self) -> int:
        if self._scroll is not None:
            viewport_w = self._scroll.viewport().width()
            if viewport_w > 50:
                return viewport_w

        own_w = self.width()
        if own_w > 50:
            return own_w

        parent = self.parentWidget()
        while parent is not None:
            parent_w = parent.width()
            if parent_w > 50:
                return parent_w
            parent = parent.parentWidget()

        window = self.window()
        if window is not None:
            # Sidebar (180) + content horizontal margins (28 * 2).
            estimate = max(0, window.width() - 236)
            if estimate > 50:
                return estimate

        return 600

    def _sync_grid_host_width(self) -> None:
        if self._grid_host is None:
            return
        width = self._available_width()
        if width > 50:
            self._grid_host.setMinimumWidth(width)

    def _schedule_layout_refresh(self) -> None:
        QTimer.singleShot(0, self._refresh_layout_when_ready)

    def _refresh_layout_when_ready(self) -> None:
        if self._layout_mode != "grid" or self._scroll is None or self._grid is None:
            return

        if not self._apps:
            return

        if self._available_width() < 50:
            QTimer.singleShot(50, self._refresh_layout_when_ready)
            return

        cols = self._column_count()
        if not self._tiles:
            self._rebuild_grid()
            return

        if cols != self._last_cols:
            self._relayout_grid()
        else:
            self._sync_grid_host_width()
            self._update_grid_minimum_height(cols)

    def eventFilter(self, obj, event) -> bool:  # noqa: N802
        if (
            self._layout_mode == "grid"
            and self._scroll is not None
            and obj is self._scroll.viewport()
            and event.type() == QEvent.Type.Resize
            and self._apps
            and self._tiles
        ):
            QTimer.singleShot(0, self._refresh_layout_when_ready)
        return super().eventFilter(obj, event)

    def showEvent(self, event) -> None:  # noqa: N802
        super().showEvent(event)
        if self._layout_mode == "grid":
            self._schedule_layout_refresh()

    def _clear_grid(self) -> None:
        while self._grid.count():
            item = self._grid.takeAt(0)
            widget = item.widget()
            if widget:
                widget.deleteLater()
        self._tiles.clear()

    def _column_count(self) -> int:
        width = self._available_width()
        cols = max(1, (width + TILE_SPACING) // (TILE_WIDTH + TILE_SPACING))
        return cols

    def _update_grid_minimum_height(self, cols: int) -> None:
        if not self._apps:
            self._grid_host.setMinimumHeight(0)
            return
        rows = math.ceil(len(self._apps) / cols)
        min_h = rows * TILE_HEIGHT + max(0, rows - 1) * TILE_SPACING + 20
        self._grid_host.setMinimumHeight(min_h)

    def _relayout_grid(self) -> None:
        if not self._apps or not self._tiles:
            return

        cols = self._column_count()
        if cols == self._last_cols:
            self._sync_grid_host_width()
            self._update_grid_minimum_height(cols)
            return

        while self._grid.count():
            self._grid.takeAt(0)

        for index in sorted(self._tiles.keys()):
            tile = self._tiles[index]
            row = index // cols
            col = index % cols
            self._grid.addWidget(tile, row, col)

        self._last_cols = cols
        self._sync_grid_host_width()
        self._update_grid_minimum_height(cols)

    def _rebuild_grid(self) -> None:
        self._clear_grid()
        self._last_cols = 0

        if not self._apps:
            self._empty_label.setText(
                "Nenhum jogo encontrado. Sincronize os jogos Steam ou ligue o Sunshine."
            )
            self._empty_label.show()
            self._scroll.hide()
            self._grid_host.setMinimumHeight(0)
            return

        self._empty_label.hide()
        self._scroll.show()

        cols = self._column_count()
        for index, app in enumerate(self._apps):
            name = str(app.get("name", "App"))
            tile = GameTile(name, index)
            self._tiles[index] = tile
            row = index // cols
            col = index % cols
            self._grid.addWidget(tile, row, col)

            if index in self._cover_cache:
                tile.set_cover(self._cover_cache[index])

        self._last_cols = cols
        self._sync_grid_host_width()
        self._update_grid_minimum_height(cols)

    def resizeEvent(self, event) -> None:  # noqa: N802
        super().resizeEvent(event)
        if self._layout_mode == "grid" and self._apps:
            self._schedule_layout_refresh()

    def _load_covers(self) -> None:
        for index, app in enumerate(self._apps):
            if index in self._cover_cache:
                self._store_cover(index, self._cover_cache[index])
                continue
            if index in self._pending_covers:
                continue

            image_path = str(app.get("image-path", "") or "")
            name = str(app.get("name", "") or "")
            local = resolve_cover_path(image_path)
            if not local and name:
                local = self._disk_cover_by_name.get(name)
            if local:
                pixmap = QPixmap(str(local))
                if not pixmap.isNull():
                    self._store_cover(index, pixmap)
                    continue

            if self._use_api and self._service and self._service.has_saved_credentials():
                self._pending_covers.add(index)
                service = self._service
                task = _CoverTask(
                    index,
                    lambda i=index, s=service: s.get_cover_sync(i),
                    self._cover_signals,
                )
                self._thread_pool.start(task)

    def _store_cover(self, index: int, pixmap: QPixmap) -> None:
        self._cover_cache[index] = pixmap
        if self._layout_mode == "list":
            item = self._list_items.get(index)
            if item is not None:
                item.setIcon(self._cover_icon(pixmap))
        elif index in self._tiles:
            self._tiles[index].set_cover(pixmap)

    def _on_cover_loaded(self, index: int, data: bytes) -> None:
        self._pending_covers.discard(index)
        image = QImage.fromData(data)
        if image.isNull():
            return
        self._store_cover(index, QPixmap.fromImage(image))
