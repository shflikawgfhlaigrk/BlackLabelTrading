"""Black Label Trading — Windows backend supervisor (contract windows-w1-trading-20260720).

Replaces the macOS launchd/nohup respawn model with a single supervised parent process owned by
the Windows shell (double-click `launch-trading.cmd`). It:

  * resolves the buyer's OWN per-user paths via the backend's bltd_paths (%LOCALAPPDATA% on Windows)
    and exports them so the backend + capture daemon read/write only the product's own empty store;
  * mints a private loopback webhook token file if none exists (never bundled — ships empty, §5.2);
  * starts and KEEPS ALIVE three children — the API server (bltd_api.py), the capture/edge-gate
    daemon (bltd_capture.py, its own browser readers disabled so the bundled bridge is the single
    sender), and the TopstepX bridge (bltd_topstep_bridge.py) — restarting any that die, with
    backoff;
  * shuts the whole child tree down cleanly on Ctrl-C / Ctrl-Break / SIGTERM;
  * enforces single-instance via a pid lockfile.

Pure stdlib, cross-platform on purpose: `--plan` prints the fully-resolved launch plan (env + child
argv) and exits WITHOUT spawning anything, so the lane is verifiable from a cold macOS shell (the
W1 machine_verify hook) as well as on the real Windows target.

Same laws as the Mac gold master: ships empty, signals only, zero fabricated numbers. This file
launches processes; it never invents a feed, a fill, or a figure.
"""
from __future__ import annotations

import os
import ntpath
import re
import signal
import stat
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_PACKAGED_BACKEND_DIR = os.path.join(HERE, "backend")
_PACKAGED_PYTHON = os.path.join(HERE, "python", "python.exe")
_PACKAGED_RUNTIME = (
    os.path.isdir(_PACKAGED_BACKEND_DIR) or os.path.isfile(_PACKAGED_PYTHON)
)
_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{32,128}$")
_SAFE_POSIX_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def _validated_absolute_path(raw: str, name: str, *, kind: str | None = None) -> str:
    """Return one normalized absolute native/Windows path or reject it without reinterpretation."""
    if not isinstance(raw, str) or not raw or raw != raw.strip():
        raise ValueError(f"{name} must be a non-empty absolute path")
    if '"' in raw or any(ord(ch) < 32 for ch in raw):
        raise ValueError(f"{name} contains an invalid control or quote character")
    if os.path.isabs(raw):
        value = os.path.normpath(raw)
    elif ntpath.isabs(raw):
        value = ntpath.normpath(raw)
    else:
        raise ValueError(f"{name} must be an absolute path")
    if kind == "file" and not os.path.isfile(value):
        raise ValueError(f"{name} must name an existing file")
    if kind == "dir" and not os.path.isdir(value):
        raise ValueError(f"{name} must name an existing directory")
    return value


def _resolve_backend_dir() -> str:
    """A packaged backend always wins. BLTD_BACKEND_DIR remains a source-tree-only test seam."""
    if os.path.isdir(_PACKAGED_BACKEND_DIR):
        return os.path.realpath(_PACKAGED_BACKEND_DIR)
    if _PACKAGED_RUNTIME:
        raise RuntimeError("bundled backend directory is missing")
    override = os.environ.get("BLTD_BACKEND_DIR")
    if override:
        return os.path.realpath(
            _validated_absolute_path(override, "BLTD_BACKEND_DIR", kind="dir"))
    # dev tree layout: windows/ is a sibling of backend/
    alt = os.path.join(os.path.dirname(HERE), "backend")
    if os.path.isdir(alt):
        return os.path.realpath(alt)
    raise RuntimeError("bundled backend directory is missing")


BACKEND_DIR = _resolve_backend_dir()

sys.path.insert(0, BACKEND_DIR)
import bltd_paths  # noqa: E402  — resolved from BACKEND_DIR above


def _python() -> str:
    """The interpreter that runs the children. In the shipped package this is the bundled
    embeddable CPython (`python\\python.exe` next to this file); dev falls back to the current one."""
    if os.path.isfile(_PACKAGED_PYTHON):
        return os.path.realpath(_PACKAGED_PYTHON)
    if _PACKAGED_RUNTIME:
        raise RuntimeError("bundled Python runtime is missing")
    override = os.environ.get("BLTD_PYTHON")
    if override:
        return os.path.realpath(
            _validated_absolute_path(override, "BLTD_PYTHON", kind="file"))
    return os.path.realpath(sys.executable)


def _secure_private_file(path: str, label: str) -> None:
    """Reject indirection/non-files and restrict an existing runtime secret/config where supported.

    Windows LocalAppData supplies the per-user ACL; chmod adds the strongest portable file-mode
    restriction and is fully effective for source-tree/dev validation on POSIX.
    """
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise RuntimeError(f"{label} must be a regular file, not a link or special file")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def _ensure_private_support_dir(support_dir: str) -> None:
    os.makedirs(support_dir, mode=0o700, exist_ok=True)
    if os.path.islink(support_dir) or not os.path.isdir(support_dir):
        raise RuntimeError("BLTD_SUPPORT_DIR must be a real directory")
    try:
        os.chmod(support_dir, 0o700)
    except OSError:
        pass


def _ensure_token_file(support_dir: str) -> str:
    """Validate or atomically mint the private token file and return only its path."""
    import secrets

    _ensure_private_support_dir(support_dir)
    tok_file = os.path.join(support_dir, "webhook.token")
    if os.path.lexists(tok_file):
        _secure_private_file(tok_file, "webhook token")
        try:
            with open(tok_file, encoding="ascii") as fh:
                token = fh.read(256).strip()
        except (OSError, UnicodeError) as exc:
            raise RuntimeError("webhook token is unreadable") from exc
        if not _TOKEN_RE.fullmatch(token):
            raise RuntimeError("webhook token has an invalid format")
        return tok_file

    token = secrets.token_urlsafe(24)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    try:
        fd = os.open(tok_file, flags, 0o600)
    except FileExistsError:
        # A concurrent first launch won the create race. Validate its file rather than overwrite it.
        return _ensure_token_file(support_dir)
    try:
        with os.fdopen(fd, "w", encoding="ascii") as fh:
            fh.write(token)
            fh.flush()
            os.fsync(fh.fileno())
    except Exception:
        try:
            os.remove(tok_file)
        except OSError:
            pass
        raise
    _secure_private_file(tok_file, "webhook token")
    return tok_file


def _validated_port(source_env: dict, key: str, default: str) -> str:
    raw = source_env.get(key)
    value = default if raw is None else raw
    if not isinstance(value, str) or not value.isascii() or not value.isdecimal():
        raise ValueError(f"{key} must be a canonical decimal TCP port")
    number = int(value)
    if not 1 <= number <= 65_535 or str(number) != value:
        raise ValueError(f"{key} must be a canonical decimal TCP port in 1...65535")
    return value


def _account_home() -> str:
    """OS-account home for non-Windows source-tree runs; never trusts caller HOME."""
    try:
        import pwd
        return _validated_absolute_path(pwd.getpwuid(os.getuid()).pw_dir, "account home")
    except (ImportError, KeyError, OSError, ValueError):
        return _validated_absolute_path(os.path.expanduser("~"), "account home")


def _join_under(base: str, name: str) -> str:
    if not os.path.isabs(base) and ntpath.isabs(base):
        return ntpath.join(base, name)
    return os.path.join(base, name)


def _support_dir(source_env: dict, *, packaged_runtime: bool | None = None,
                 os_name: str | None = None) -> str:
    # A source-tree test/developer may relocate the whole product state root. A packaged buyer
    # runtime always uses the OS account location and ignores caller BLTD path overrides.
    packaged = _PACKAGED_RUNTIME if packaged_runtime is None else packaged_runtime
    host_os = os.name if os_name is None else os_name
    override = source_env.get("BLTD_SUPPORT_DIR")
    if override and not packaged:
        return _validated_absolute_path(override, "BLTD_SUPPORT_DIR")
    if host_os == "nt":
        local = _windows_known_paths()["LOCALAPPDATA"]
        return ntpath.join(local, bltd_paths.APP_NAME)
    home = _account_home()
    if sys.platform == "darwin":
        return os.path.join(home, "Library", "Application Support", bltd_paths.APP_NAME)
    xdg = source_env.get("XDG_DATA_HOME")
    base = (
        _validated_absolute_path(xdg, "XDG_DATA_HOME")
        if xdg else os.path.join(home, ".local", "share")
    )
    return os.path.join(base, bltd_paths.APP_NAME)


def _windows_directory() -> str:
    """Resolve the loader/system root from the OS API, never caller SystemRoot/WINDIR."""
    if os.name != "nt":
        raise RuntimeError("Windows directory requested on a non-Windows host")
    import ctypes
    buffer = ctypes.create_unicode_buffer(32_768)
    length = ctypes.windll.kernel32.GetWindowsDirectoryW(buffer, len(buffer))
    if length <= 0 or length >= len(buffer):
        raise RuntimeError("GetWindowsDirectoryW failed")
    return _validated_absolute_path(buffer.value, "Windows directory")


def _windows_known_folder(csidl: int, label: str) -> str:
    """Resolve a per-account/system path through Shell32, not caller environment variables."""
    if os.name != "nt":
        raise RuntimeError(f"{label} requested on a non-Windows host")
    import ctypes
    buffer = ctypes.create_unicode_buffer(32_768)
    result = ctypes.windll.shell32.SHGetFolderPathW(None, csidl, None, 0, buffer)
    if result != 0 or not buffer.value:
        raise RuntimeError(f"SHGetFolderPathW failed for {label}")
    return _validated_absolute_path(buffer.value, label)


def _windows_known_paths() -> dict:
    # CSIDL constants remain supported on Windows 10/11 and avoid trusting spoofable path variables.
    paths = {
        "LOCALAPPDATA": _windows_known_folder(0x001C, "LocalAppData"),
        "USERPROFILE": _windows_known_folder(0x0028, "UserProfile"),
        "ProgramFiles": _windows_known_folder(0x0026, "ProgramFiles"),
    }
    try:
        paths["ProgramFiles(x86)"] = _windows_known_folder(0x002A, "ProgramFilesX86")
    except RuntimeError:
        pass
    return paths


def _windows_system_environment(_source_env: dict) -> dict:
    root = _windows_directory()
    known = _windows_known_paths()
    local = known["LOCALAPPDATA"]
    system32 = ntpath.join(root, "System32")
    env = {
        "SystemRoot": root,
        "WINDIR": root,
        "COMSPEC": ntpath.join(system32, "cmd.exe"),
        "PATH": ";".join((system32, root, ntpath.join(system32, "Wbem"))),
        "PATHEXT": ".COM;.EXE;.BAT;.CMD",
        "LOCALAPPDATA": local,
        "TEMP": ntpath.join(local, "Temp"),
        "TMP": ntpath.join(local, "Temp"),
    }
    # Browser discovery needs these locations; all came from Shell32 rather than the caller.
    env.update({key: known[key] for key in ("ProgramFiles", "ProgramFiles(x86)", "USERPROFILE")
                if key in known})
    return env


def build_env(source_env: dict | None = None) -> dict:
    """The child environment (PURE — no filesystem side effects, safe for --plan).

    Constructed from scratch so launcher credentials, import/shell/loader hooks, proxies, and
    unrelated BLTD_* values cannot reach the children. Resolves the buyer's OWN per-user
    store/profile paths. The loopback token file is NOT minted here (that touches disk); run()
    ensures it and exports only its path right before spawning children.
    """
    source = os.environ if source_env is None else source_env
    support = _support_dir(source)
    port = _validated_port(source, "BLTD_PORT", "8793")
    cdp_port = _validated_port(source, "BLTD_CDP_PORT", "9223")
    env = _windows_system_environment(source) if os.name == "nt" else {
        "PATH": _SAFE_POSIX_PATH
    }
    env.update({
        "BLTD_SUPPORT_DIR": support,
        "BLTD_STORE": _join_under(support, "trading.sqlite3"),
        "BLTD_CONFIG": _join_under(support, "config.json"),
        "BLTD_CHROME_PROFILE": _join_under(support, "chrome-topstepx"),
        "BLTD_PORT": port,
        "BLTD_CDP_PORT": cdp_port,
        "BLTD_SCOPE": "all",
        "BLTD_WEBHOOK_URL": f"http://127.0.0.1:{port}/webhook/feed",
        # Fixed Python controls: no caller import path/home/startup hooks or in-bundle bytecode.
        "PYTHONPATH": BACKEND_DIR,
        "PYTHONUNBUFFERED": "1",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONNOUSERSITE": "1",
        "PYTHONUTF8": "1",
        "PYTHONPYCACHEPREFIX": _join_under(support, "pycache"),
    })
    browser_override = source.get("BLTD_CHROME_APP")
    if browser_override and not _PACKAGED_RUNTIME:
        env["BLTD_CHROME_APP"] = _validated_absolute_path(
            browser_override, "BLTD_CHROME_APP", kind="file")
    return env


def child_specs(env: dict) -> list[dict]:
    """The three supervised children, as (name, argv, extra_env) specs."""
    py = _python()
    return [
        {"name": "api",
         "argv": [py, os.path.join(BACKEND_DIR, "bltd_api.py"), env["BLTD_PORT"]],
         "env": {}},
        {"name": "capture",
         "argv": [py, os.path.join(BACKEND_DIR, "bltd_capture.py")],
         # match the Mac launcher: capture's own browser readers OFF, bridge is the single sender
         "env": {"BLTD_AUTO_BROWSER": "0", "BLTD_CAPTURE_BROWSER": "0"}},
        {"name": "topstep-bridge",
         "argv": [py, os.path.join(BACKEND_DIR, "bltd_topstep_bridge.py")],
         "env": {}},
    ]


def _pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes
        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259
        k = ctypes.windll.kernel32
        h = k.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, pid)
        if not h:
            return False
        try:
            code = ctypes.c_ulong()
            if k.GetExitCodeProcess(h, ctypes.byref(code)):
                return code.value == STILL_ACTIVE
            return False
        finally:
            k.CloseHandle(h)
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _acquire_single_instance(support_dir: str):
    _ensure_private_support_dir(support_dir)
    lock = os.path.join(support_dir, "supervisor.pid")
    if os.path.lexists(lock):
        _secure_private_file(lock, "supervisor pid")
        try:
            with open(lock, encoding="ascii") as fh:
                other = int((fh.read() or "0").strip() or "0")
        except (ValueError, OSError):
            other = 0
        if other and other != os.getpid() and _pid_alive(other):
            print(f"supervisor: already running (pid {other}) — exiting", file=sys.stderr)
            raise SystemExit(0)
    fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="ascii") as fh:
        fh.write(str(os.getpid()))
    _secure_private_file(lock, "supervisor pid")
    return lock


def plan(env: dict) -> str:
    lines = ["Black Label Trading — Windows supervisor launch plan",
             f"  os            : {os.name} ({sys.platform})",
             f"  python        : {_python()}",
             f"  backend_dir   : {BACKEND_DIR}",
             f"  support_dir   : {env['BLTD_SUPPORT_DIR']}",
             f"  store         : {env['BLTD_STORE']}",
             f"  chrome_profile: {env['BLTD_CHROME_PROFILE']}",
             f"  api_port      : {env['BLTD_PORT']}   cdp_port: {env['BLTD_CDP_PORT']}",
             "  children:"]
    for spec in child_specs(env):
        extra = " ".join(f"{k}={v}" for k, v in spec["env"].items())
        lines.append(f"    - {spec['name']:14s} {' '.join(spec['argv'])}"
                     + (f"   [{extra}]" if extra else ""))
    return "\n".join(lines)


def _child_environment(base_env: dict, spec: dict) -> dict:
    """Apply only the supervisor's two fixed per-child switches to the already-sanitized base."""
    extra = spec.get("env") or {}
    if not set(extra).issubset({"BLTD_AUTO_BROWSER", "BLTD_CAPTURE_BROWSER"}):
        raise ValueError("child spec contains an unapproved environment variable")
    if any(value not in ("0", "1") for value in extra.values()):
        raise ValueError("child environment switches must be exactly 0 or 1")
    child_env = dict(base_env)
    child_env.update(extra)
    return child_env


def _runtime_environment(base_env: dict) -> dict:
    """Add only the supervisor-owned token-file path to a sanitized launch environment."""
    env = dict(base_env)
    env.pop("BLTD_TOKEN", None)
    env["BLTD_TOKEN_FILE"] = _ensure_token_file(env["BLTD_SUPPORT_DIR"])
    return env


def _open_private_log(path: str):
    if os.path.lexists(path):
        _secure_private_file(path, "supervisor log")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    _secure_private_file(path, "supervisor log")
    return os.fdopen(fd, "a", encoding="utf-8", buffering=1)


def _spawn_child(spec: dict, env: dict, log_dir: str):
    child_env = _child_environment(env, spec)
    logf = _open_private_log(os.path.join(log_dir, f"{spec['name']}.log"))
    kwargs = {
        "cwd": BACKEND_DIR,
        "env": child_env,
        "stdout": logf,
        "stderr": subprocess.STDOUT,
    }
    if os.name == "nt":
        kwargs["creationflags"] = 0x08000000  # CREATE_NO_WINDOW
    try:
        return subprocess.Popen(spec["argv"], **kwargs)
    finally:
        # Popen duplicates/inherits the handle during construction; no parent copy is retained.
        logf.close()


def run() -> int:
    try:
        os.umask(0o077)
    except (AttributeError, OSError):
        pass
    env = build_env()
    _ensure_private_support_dir(env["BLTD_SUPPORT_DIR"])
    _secure_private_file(env["BLTD_CONFIG"], "backend config")
    lock = _acquire_single_instance(env["BLTD_SUPPORT_DIR"])
    env = _runtime_environment(env)  # touches disk — only on real launch
    log_dir = env["BLTD_SUPPORT_DIR"]
    procs: dict[str, subprocess.Popen] = {}
    stop = {"flag": False}

    def _sig(_signum, _frame):
        stop["flag"] = True

    for s in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(s, _sig)
        except (ValueError, OSError):
            pass
    if os.name == "nt" and hasattr(signal, "SIGBREAK"):
        try:
            signal.signal(signal.SIGBREAK, _sig)  # Ctrl-Break
        except (ValueError, OSError):
            pass

    specs = {s["name"]: s for s in child_specs(env)}
    for name, spec in specs.items():
        procs[name] = _spawn_child(spec, env, log_dir)
    print(plan(env))

    backoff: dict[str, float] = {n: 0.0 for n in specs}
    try:
        while not stop["flag"]:
            for name, spec in specs.items():
                p = procs.get(name)
                if p is not None and p.poll() is not None:
                    # child died — restart with mild backoff so a hard-crashing child can't spin
                    wait = min(30.0, 1.0 + backoff[name])
                    backoff[name] = wait
                    print(f"supervisor: '{name}' exited ({p.returncode}); restarting in {wait:.0f}s",
                          file=sys.stderr)
                    time.sleep(wait)
                    if stop["flag"]:
                        break
                    procs[name] = _spawn_child(spec, env, log_dir)
                elif p is not None and p.poll() is None:
                    backoff[name] = max(0.0, backoff[name] - 0.5)
            time.sleep(1.0)
    finally:
        for name, p in procs.items():
            try:
                p.terminate()
            except Exception:  # noqa: BLE001
                pass
        deadline = time.monotonic() + 8
        for p in procs.values():
            try:
                p.wait(timeout=max(0.1, deadline - time.monotonic()))
            except Exception:  # noqa: BLE001
                try:
                    p.kill()
                except Exception:  # noqa: BLE001
                    pass
        try:
            if os.path.isfile(lock):
                os.remove(lock)
        except OSError:
            pass
    return 0


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        if "--plan" in argv or "--dry-run" in argv:
            print(plan(build_env()))
            return 0
        return run()
    except (ValueError, RuntimeError) as exc:
        print(f"supervisor: invalid launch environment: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
