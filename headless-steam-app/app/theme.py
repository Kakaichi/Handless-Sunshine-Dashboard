"""Application-wide Qt stylesheet."""

APP_STYLESHEET = """
QMainWindow, QWidget {
    background-color: #16181d;
    color: #e8eaed;
    font-family: "Segoe UI", sans-serif;
    font-size: 13px;
}

QLabel {
    background-color: transparent;
    background: none;
    border: none;
    padding: 0;
}

QFrame QLabel {
    background-color: transparent;
    background: none;
}

QLabel#AppTitle {
    font-size: 22px;
    font-weight: 600;
    color: #f3f4f6;
}

QLabel#AppSubtitle {
    font-size: 12px;
    color: #8b929a;
}

QLabel#SectionTitle {
    font-size: 11px;
    font-weight: 600;
    color: #6b7280;
    letter-spacing: 0.08em;
    text-transform: uppercase;
}

QLabel#Muted {
    color: #8b929a;
    font-size: 13px;
}

QLabel#FunnelReqOk {
    color: #3dd68c;
    font-size: 13px;
}

QLabel#FunnelReqMissing {
    color: #f5a623;
    font-size: 13px;
}

QLabel#ActivityTitle {
    font-weight: 600;
    color: #e8eaed;
    font-size: 13px;
}

QLabel#StatusCardTitle {
    font-size: 12px;
    color: #8b929a;
    font-weight: 500;
}

QLabel#StatusCardValue {
    font-size: 17px;
    font-weight: 600;
    color: #e8eaed;
}

QLabel#StatusCardDetail {
    font-size: 11px;
    color: #6b7280;
}

QLabel#StatusCardDot {
    font-size: 10px;
    color: #5c6370;
}

QScrollArea {
    background-color: transparent;
    border: none;
}

QScrollArea > QWidget > QWidget {
    background-color: transparent;
}

QFrame#StatusCard {
    background-color: #1f2329;
    border: 1px solid #2d333b;
    border-radius: 12px;
}

QFrame#StatusCard:hover:!disabled {
    border-color: #454d58;
    background-color: #232830;
}

QFrame#StatusCard[active="true"] {
    border-color: #2a6b4a;
    background-color: #1a2620;
}

QFrame#StatusCard:disabled {
    opacity: 0.55;
}

QLabel#DashboardHint {
    color: #6b7280;
    font-size: 11px;
}

QFrame#GameTile {
    background-color: transparent;
    border: none;
}

QLabel#GameTilePoster {
    background-color: #252b33;
    border: 1px solid #2d333b;
    border-radius: 8px;
}

QLabel#GameTileName {
    color: #e8eaed;
    font-size: 12px;
    font-weight: 500;
    background: transparent;
}

QFrame#SurfaceCard {
    background-color: #1f2329;
    border: 1px solid #2d333b;
    border-radius: 12px;
}

QFrame#SetupBanner {
    background-color: #2a2418;
    border: 1px solid #4a3f28;
    border-radius: 10px;
}

QFrame#SetupBanner QLabel {
    color: #f0d78c;
    background: transparent;
}

QFrame#UpdateBanner {
    background-color: #182433;
    border: 1px solid #284a6b;
    border-radius: 10px;
}

QFrame#UpdateBanner QLabel {
    color: #9ec8f0;
    background: transparent;
}

QFrame#ActivityBar {
    background-color: #1f2329;
    border: 1px solid #2d333b;
    border-radius: 10px;
}

QFrame#ActivityBar[status="success"] {
    background-color: #152218;
    border-color: #1f4d35;
}

QFrame#ActivityBar[status="error"] {
    background-color: #2a1818;
    border-color: #5c2a2a;
}

QFrame#ActivityBar[status="running"] {
    background-color: #1a2030;
    border-color: #2d3a52;
}

QFrame#ActivityBar QLabel {
    background: transparent;
}

QListWidget#Sidebar {
    background-color: #12151a;
    border: none;
    border-right: 1px solid #2d333b;
    outline: none;
    padding: 12px 8px;
}

QListWidget#Sidebar::item {
    color: #9aa0a6;
    padding: 12px 16px;
    border-radius: 8px;
    margin: 2px 4px;
}

QListWidget#Sidebar::item:selected {
    background-color: #252b36;
    color: #e8eaed;
}

QListWidget#Sidebar::item:hover:!selected {
    background-color: #1c2028;
}

QMenu {
    background-color: #1f2329;
    border: 1px solid #2d333b;
    border-radius: 8px;
    padding: 4px;
}

QMenu::item {
    padding: 8px 24px;
    color: #e8eaed;
    border-radius: 4px;
}

QMenu::item:selected {
    background-color: #252b33;
}

QMenu::separator {
    height: 1px;
    background-color: #2d333b;
    margin: 4px 8px;
}

QPushButton#PrimaryButton {
    background-color: #4f7df3;
    color: #ffffff;
    border: none;
    border-radius: 8px;
    padding: 10px 18px;
    font-weight: 600;
    min-height: 20px;
}

QPushButton#PrimaryButton:hover {
    background-color: #6b93f5;
}

QPushButton#PrimaryButton:pressed {
    background-color: #3d68e0;
}

QPushButton#PrimaryButton:disabled {
    background-color: #2d3548;
    color: #6b7280;
}

QPushButton#DangerButton {
    background-color: #2d333b;
    color: #f87171;
    border: 1px solid #3d444d;
    border-radius: 8px;
    padding: 10px 18px;
    font-weight: 600;
    min-height: 20px;
}

QPushButton#DangerButton:hover {
    background-color: #3a2226;
    border-color: #5c2a2a;
}

QPushButton#SecondaryButton {
    background-color: #252b33;
    color: #e8eaed;
    border: 1px solid #353c46;
    border-radius: 8px;
    padding: 10px 18px;
    min-height: 20px;
}

QPushButton#SecondaryButton:hover {
    background-color: #2d343e;
    border-color: #454d58;
}

QPushButton#SecondaryButton:disabled,
QPushButton#DangerButton:disabled {
    background-color: #1c2028;
    color: #5c6370;
    border-color: #2d333b;
}

QPushButton#GhostButton {
    background-color: transparent;
    color: #8b929a;
    border: none;
    padding: 6px 12px;
    border-radius: 6px;
}

QPushButton#GhostButton:hover {
    background-color: #252b33;
    color: #e8eaed;
}

QPushButton#IconButton {
    background-color: #252b33;
    color: #e8eaed;
    border: 1px solid #353c46;
    border-radius: 10px;
    padding: 0;
}

QPushButton#IconButton:hover {
    background-color: #2d343e;
    border-color: #454d58;
}

QPushButton#IconButton:disabled {
    background-color: #1c2028;
    border-color: #2d333b;
    opacity: 0.5;
}

QPushButton#PowerButton {
    background-color: #2a3d6b;
    color: #e8eaed;
    border: 1px solid #3d5a9e;
    border-radius: 10px;
    padding: 0;
}

QPushButton#PowerButton:hover {
    background-color: #354878;
    border-color: #4f7df3;
}

QPushButton#PowerButton[active="true"] {
    background-color: #3a2226;
    border-color: #7f3d3d;
}

QPushButton#PowerButton[active="true"]:hover {
    background-color: #4a2828;
    border-color: #a34a4a;
}

QPushButton#PowerButton:disabled {
    background-color: #1c2028;
    border-color: #2d333b;
    opacity: 0.5;
}

QPushButton#LinkButton {
    background-color: transparent;
    color: #6b9fff;
    border: none;
    text-align: left;
    padding: 4px 0;
}

QPushButton#LinkButton:hover {
    color: #93b8ff;
}

QProgressBar {
    background-color: #252b33;
    border: none;
    border-radius: 3px;
    max-height: 4px;
    min-height: 4px;
}

QProgressBar::chunk {
    background-color: #4f7df3;
    border-radius: 3px;
}

QTextEdit#TechLog {
    background-color: #12151a;
    border: 1px solid #2d333b;
    border-radius: 8px;
    color: #9aa0a6;
    font-family: "Cascadia Mono", "Consolas", monospace;
    font-size: 11px;
    padding: 8px;
}

QLineEdit, QComboBox {
    background-color: #12151a;
    border: 1px solid #2d333b;
    border-radius: 8px;
    padding: 8px 10px;
    color: #e8eaed;
    min-height: 20px;
}

QLineEdit:focus, QComboBox:focus {
    border-color: #4f7df3;
}

QListWidget {
    background-color: #12151a;
    border: 1px solid #2d333b;
    border-radius: 8px;
    padding: 4px;
}

QListWidget#GamesList::item {
    color: #e8eaed;
    padding: 4px 8px;
    border-radius: 6px;
}

QListWidget#GamesList::item:hover {
    background-color: #252b33;
}

QScrollBar:vertical {
    background: #16181d;
    width: 8px;
    border-radius: 4px;
}

QScrollBar::handle:vertical {
    background: #3d444d;
    border-radius: 4px;
    min-height: 24px;
}

QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical {
    height: 0;
}
"""
