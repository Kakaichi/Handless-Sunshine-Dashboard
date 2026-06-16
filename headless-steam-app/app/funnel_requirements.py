"""Shared Tailscale Funnel prerequisite status labels."""

from __future__ import annotations

from PySide6.QtWidgets import QLabel

from app.status_service import HeadlessSteamStatus
from app.widgets import LinkButton

_ACL_TITLE = "Policy ACL — nodeAttrs funnel"
_MAGIC_DNS_TITLE = "DNS — MagicDNS"
_HTTPS_TITLE = "DNS — Enable HTTPS"


def set_funnel_requirement_label(
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


def update_funnel_requirements(
    status: HeadlessSteamStatus,
    *,
    acl_label: QLabel,
    magic_dns_label: QLabel,
    https_label: QLabel,
    note_label: QLabel | None = None,
    acl_link: LinkButton | None = None,
    dns_link: LinkButton | None = None,
) -> None:
    if acl_link is not None:
        acl_link.set_url(
            "Abrir policy ACL (nodeAttrs funnel)",
            status.tailscale_funnel_acl_setup_url,
        )
    if dns_link is not None:
        dns_link.set_url(
            "Abrir DNS (MagicDNS + Enable HTTPS)",
            status.tailscale_funnel_dns_setup_url,
        )

    if not status.tailscale_running:
        for label, title in (
            (acl_label, _ACL_TITLE),
            (magic_dns_label, _MAGIC_DNS_TITLE),
            (https_label, _HTTPS_TITLE),
        ):
            set_funnel_requirement_label(label, title, available=False, ok=False)
        if note_label is not None:
            note_label.setText("Ligue o Tailscale para verificar.")
            note_label.show()
        return

    if note_label is not None:
        note_label.hide()

    set_funnel_requirement_label(
        acl_label,
        _ACL_TITLE,
        available=True,
        ok=status.tailscale_funnel_acl_ok,
    )
    set_funnel_requirement_label(
        magic_dns_label,
        _MAGIC_DNS_TITLE,
        available=True,
        ok=status.tailscale_magic_dns_ok,
    )
    set_funnel_requirement_label(
        https_label,
        _HTTPS_TITLE,
        available=True,
        ok=status.tailscale_https_ok,
    )
