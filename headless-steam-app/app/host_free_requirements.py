"""Shared host-free / virtual display status labels."""

from __future__ import annotations

from PySide6.QtWidgets import QLabel

from app.status_service import HeadlessSteamStatus

_VDD_TITLE = "Driver Virtual Display (VDD)"
_MONITOR_TITLE = "Monitor virtual ativo"
_SUNSHINE_TITLE = "Sunshine no monitor virtual"


def set_host_free_requirement_label(
    label: QLabel,
    title: str,
    *,
    available: bool,
    ok: bool,
) -> None:
    if not available:
        label.setText(f"{title} — indisponivel")
        label.setObjectName("Muted")
    elif ok:
        label.setText(f"{title} — OK")
        label.setObjectName("FunnelReqOk")
    else:
        label.setText(f"{title} — pendente")
        label.setObjectName("FunnelReqMissing")
    label.style().unpolish(label)
    label.style().polish(label)


def update_host_free_requirements(
    status: HeadlessSteamStatus,
    *,
    vdd_label: QLabel,
    monitor_label: QLabel,
    sunshine_label: QLabel,
    note_label: QLabel | None = None,
) -> None:
    set_host_free_requirement_label(
        vdd_label,
        _VDD_TITLE,
        available=True,
        ok=status.virtual_display_installed,
    )
    set_host_free_requirement_label(
        monitor_label,
        _MONITOR_TITLE,
        available=status.virtual_display_installed,
        ok=status.virtual_display_active,
    )
    set_host_free_requirement_label(
        sunshine_label,
        _SUNSHINE_TITLE,
        available=status.virtual_display_active,
        ok=status.stream_output_configured,
    )

    if note_label is None:
        return

    if status.host_free_status_message:
        note_label.setText(status.host_free_status_message)
        note_label.show()
    else:
        note_label.hide()
