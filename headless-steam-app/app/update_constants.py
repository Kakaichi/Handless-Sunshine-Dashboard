"""GitHub release metadata and semver helpers for auto-update."""

from __future__ import annotations

import re

GITHUB_OWNER = "Kakaichi"
GITHUB_REPO = "Handless-Sunshine-Dashboard"
GITHUB_LATEST_RELEASE_API = (
    f"https://api.github.com/repos/{GITHUB_OWNER}/{GITHUB_REPO}/releases/latest"
)
GITHUB_RELEASES_PAGE = f"https://github.com/{GITHUB_OWNER}/{GITHUB_REPO}/releases/latest"
WIN64_ASSET_SUFFIX = "-win64.zip"
WIN64_ASSET_PREFIX = "Handless-Sunshine-Dashboard-"

_SEMVER_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")


def normalize_version(text: str) -> str:
    raw = (text or "").strip().lstrip("v")
    match = _SEMVER_RE.match(raw) or _SEMVER_RE.match(f"v{raw}")
    if not match:
        return raw
    return f"{match.group(1)}.{match.group(2)}.{match.group(3)}"


def parse_semver(text: str) -> tuple[int, int, int] | None:
    raw = normalize_version(text)
    match = _SEMVER_RE.match(raw) or _SEMVER_RE.match(f"v{raw}")
    if not match:
        return None
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def is_newer(remote: str, local: str) -> bool:
    remote_tuple = parse_semver(remote)
    local_tuple = parse_semver(local)
    if remote_tuple is None or local_tuple is None:
        return False
    return remote_tuple > local_tuple
