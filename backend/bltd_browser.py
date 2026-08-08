"""Cross-platform Chromium-family browser resolution + remote-debug launch.

The buyer logs into THEIR OWN trading platform (TopstepX / WealthCharts) inside a product-owned,
loopback-pinned remote-debug browser profile; the capture daemon reads the live feed from it. This
module owns the OS-specific bits so the rest of the stdlib backend stays portable:

  * darwin  — resolves the installed `.app` bundle and launches via `open -g -n -a <App> --args …`
              (byte-identical to the historical inline launch in bltd_capture).
  * nt       — resolves chrome.exe / msedge.exe / brave.exe from the standard install locations and
              PATH, then launches the executable DIRECTLY (no `open`, detached, no console window).
  * other    — best-effort PATH resolution (Linux), same flag set.

ONE place owns the loopback-pinned CDP flag set (`_cdp_args`) so the security posture is auditable
in a single spot across every OS. The `--remote-allow-origins=*` value is a known residual carried
verbatim from bltd_capture (tightening it needs a live Chrome handshake test — not changed blind).

Pure stdlib; importing on any OS is harmless (nothing OS-specific runs at import time).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys


def _os_kind() -> str:
    """Normalized OS token: 'mac' | 'win' | 'other'. A single, monkeypatchable seam so the
    per-OS branches below are unit-testable on any host without mutating global sys/os state."""
    if sys.platform == "darwin":
        return "mac"
    if os.name == "nt":
        return "win"
    return "other"


# macOS: `.app` bundles. resolve returns the bundle path; `open -a` handles the exec.
_MAC_CANDIDATES = (
    "/Applications/Google Chrome.app",
    "/Applications/Chromium.app",
    "/Applications/Brave Browser.app",
    "/Applications/Microsoft Edge.app",
)


def _win_candidates() -> list[str]:
    """Standard Windows install locations for Chromium-family browsers + PATH fallbacks.

    Covers per-machine (Program Files / Program Files (x86)) and per-user (LocalAppData) installs,
    which is where Chrome/Edge/Brave land by default. No registry read is needed; BLTD_CHROME_APP
    and PATH cover anything unusual. Nothing here is a hard vendor lock — all speak the same CDP.
    """
    bases = [
        os.environ.get("ProgramFiles", r"C:\Program Files"),
        os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"),
        os.environ.get("LOCALAPPDATA", os.path.expanduser(r"~\AppData\Local")),
    ]
    rel = (
        r"Google\Chrome\Application\chrome.exe",
        r"Chromium\Application\chrome.exe",
        r"BraveSoftware\Brave-Browser\Application\brave.exe",
        r"Microsoft\Edge\Application\msedge.exe",
    )
    out: list[str] = []
    for base in bases:
        for r in rel:
            out.append(os.path.join(base, r))
    for exe in ("chrome.exe", "msedge.exe", "brave.exe"):
        found = shutil.which(exe)
        if found:
            out.append(found)
    return out


def resolve_browser(env_override: str | None = None) -> str | None:
    """The first installed Chromium-family browser (env override wins). None if nothing is installed.

    Returns a `.app` bundle path on darwin and an executable path on Windows/Linux — the caller
    passes whatever this returns straight back into `launch_debug_browser`, which knows how to run
    each. Never raises.
    """
    kind = _os_kind()
    override = env_override if env_override is not None else os.environ.get("BLTD_CHROME_APP", "")
    override = (override or "").strip()
    if override:
        if kind == "mac":
            if os.path.isdir(override):
                return override
        elif os.path.isfile(override):
            return override
    if kind == "mac":
        for app in _MAC_CANDIDATES:
            if os.path.isdir(app):
                return app
        return None
    if kind == "win":
        for exe in _win_candidates():
            if os.path.isfile(exe):
                return exe
        return None
    # Linux / other.
    for exe in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser",
                "brave-browser", "microsoft-edge"):
        found = shutil.which(exe)
        if found:
            return found
    return None


def browser_present() -> bool:
    return resolve_browser() is not None


def _cdp_args(cdp_port: int, profile_dir: str) -> list[str]:
    """The loopback-pinned remote-debug flag set — SINGLE source of truth across every OS.

    SECURITY: the CDP listener is pinned to 127.0.0.1 so off-machine TCP cannot reach it. The
    "*" origin is a known residual (the capture WS client sends no Origin header); it is carried
    verbatim and NOT changed blind here.
    """
    return [
        f"--remote-debugging-port={cdp_port}", "--remote-debugging-address=127.0.0.1",
        "--remote-allow-origins=*",
        f"--user-data-dir={profile_dir}", "--no-first-run", "--no-default-browser-check",
    ]


def build_argv(browser: str, cdp_port: int, profile_dir: str, urls, extra_args=()) -> list[str]:
    """The exact process argv that would be launched, for the current OS. Pure/testable (no I/O)."""
    args = _cdp_args(cdp_port, profile_dir) + list(extra_args) + list(urls)
    if _os_kind() == "mac":
        return ["open", "-g", "-n", "-a", browser, "--args", *args]
    return [browser, *args]


def launch_debug_browser(browser: str, cdp_port: int, profile_dir: str, urls, extra_args=()) -> bool:
    """Launch the product's remote-debug browser to the given login URL(s). Never raises.

    On Windows the executable is launched DETACHED with no console window so the buyer never sees a
    stray terminal, and the child outlives the spawning shell (the supervisor owns lifecycle).
    """
    argv = build_argv(browser, cdp_port, profile_dir, urls, extra_args)
    try:
        if _os_kind() == "win":
            DETACHED_PROCESS = 0x00000008
            CREATE_NO_WINDOW = 0x08000000
            subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                              creationflags=DETACHED_PROCESS | CREATE_NO_WINDOW, close_fds=True)
        else:
            subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:  # noqa: BLE001 — launch is best-effort; caller logs + writes prereq sentinel.
        return False
