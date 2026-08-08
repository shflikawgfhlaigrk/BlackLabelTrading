"""Cross-platform application-support + store/profile paths for the Black Label Trading backend.

Single source of truth so the SAME pure-stdlib backend runs on macOS (the gold master) and on
Windows (the W1 port, contract windows-w1-trading-20260720). Behavior on darwin is byte-identical
to the historical hardcoded `~/Library/Application Support/Black Label Trading` path; Windows uses
`%LOCALAPPDATA%\\Black Label Trading`; anything else falls back to XDG. Every path is
env-overridable (tests + custom installs) using the SAME env var names the launcher already
exports, so no caller's contract changes. Pure stdlib — importing on any OS is harmless.

Ships-empty law (§5.2): these functions only NAME locations; the store/config/profile start
absent and are created empty by the buyer's own run. Nothing here bundles data, bars, or creds.
"""
from __future__ import annotations

import os
import sys

APP_NAME = "Black Label Trading"


def _os_kind() -> str:
    """Normalized OS token: 'mac' | 'win' | 'other'. Monkeypatchable seam for unit tests."""
    if sys.platform == "darwin":
        return "mac"
    if os.name == "nt":
        return "win"
    return "other"


def app_support_dir() -> str:
    """The per-user directory the product owns for this buyer. Env override wins (tests/installs)."""
    override = (os.environ.get("BLTD_SUPPORT_DIR") or "").strip()
    if override:
        return override
    kind = _os_kind()
    if kind == "mac":
        return os.path.expanduser(f"~/Library/Application Support/{APP_NAME}")
    if kind == "win":
        base = os.environ.get("LOCALAPPDATA") or os.path.expanduser(r"~\AppData\Local")
        return os.path.join(base, APP_NAME)
    # Linux / other — XDG data home.
    base = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.join(base, APP_NAME)


def store_path() -> str:
    """The buyer's OWN SQLite store. BLTD_STORE overrides (unchanged contract)."""
    return os.environ.get("BLTD_STORE", os.path.join(app_support_dir(), "trading.sqlite3"))


def config_path() -> str:
    """The buyer-tunable config JSON. BLTD_CONFIG overrides (unchanged contract)."""
    return os.environ.get("BLTD_CONFIG", os.path.join(app_support_dir(), "config.json"))


def chrome_profile_dir() -> str:
    """The product-owned remote-debug browser profile. BLTD_CHROME_PROFILE overrides (unchanged)."""
    return os.environ.get(
        "BLTD_CHROME_PROFILE", os.path.join(app_support_dir(), "chrome-topstepx"))


def optimizer_report_path() -> str:
    """Latest completed research-only nested-validation report."""
    return os.environ.get(
        "BLTD_OPTIMIZER_REPORT", os.path.join(app_support_dir(), "optimizer-latest.json"))


def optimizer_ledger_path() -> str:
    """Append-only hypothesis reservations; prevents a new run from resetting multiplicity."""
    return os.environ.get(
        "BLTD_OPTIMIZER_LEDGER", os.path.join(app_support_dir(), "optimizer-hypotheses.json"))
