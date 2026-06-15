import sys

from PySide6.QtWidgets import QApplication

from app.constants import APP_DISPLAY_NAME, APP_VERSION, format_app_title
from app.icons import load_app_icon
from app.main_window import MainWindow
from app.paths import ensure_runtime_paths, get_sunshine_dir
from app.theme import APP_STYLESHEET


def main() -> int:
    ensure_runtime_paths()
    try:
        get_sunshine_dir()
    except FileNotFoundError as exc:
        print(exc, file=sys.stderr)
        return 1

    app = QApplication(sys.argv)
    app.setApplicationName(APP_DISPLAY_NAME)
    app.setApplicationVersion(APP_VERSION)
    app.setWindowIcon(load_app_icon())
    app.setStyleSheet(APP_STYLESHEET)
    window = MainWindow()
    window.setWindowIcon(app.windowIcon())
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
