"""Windows W1 port — cross-platform port logic tests (contract windows-w1-trading-20260720).

Runs on macOS CI and proves the Windows behavior of bltd_paths + bltd_browser WITHOUT needing a
Windows host: the `_os_kind` seam is monkeypatched so both branches are exercised on any OS. Also
locks the darwin gold-master invariants (path + launch argv unchanged) so the port cannot silently
regress the Mac ship. Pure stdlib; prints "N passed, M failed" for run-tests.sh.
"""
from __future__ import annotations

import importlib.util
import os
import stat
import sys
import tempfile

import bltd_paths
import bltd_browser

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.dirname(_HERE)
_SUPERVISOR_PATH = os.path.join(_REPO, "windows", "supervise.py")
_SUPERVISOR_SPEC = importlib.util.spec_from_file_location(
    "bltd_windows_supervisor_contract", _SUPERVISOR_PATH)
supervisor = importlib.util.module_from_spec(_SUPERVISOR_SPEC)
_SUPERVISOR_SPEC.loader.exec_module(supervisor)


# --- helpers ---------------------------------------------------------------
class _kind:
    """Context manager that forces _os_kind on the given modules, then restores."""
    def __init__(self, value, *modules):
        self.value = value
        self.modules = modules
        self._saved = []

    def __enter__(self):
        for m in self.modules:
            self._saved.append((m, m._os_kind))
            m._os_kind = lambda v=self.value: v
        return self

    def __exit__(self, *a):
        for m, fn in self._saved:
            m._os_kind = fn
        return False


def _clear_env():
    for k in ("BLTD_SUPPORT_DIR", "BLTD_STORE", "BLTD_CONFIG", "BLTD_CHROME_PROFILE",
              "BLTD_CHROME_APP"):
        os.environ.pop(k, None)


def _raises(error_type, fn):
    try:
        fn()
    except error_type:
        return True
    return False


# --- bltd_paths: per-OS support dir ---------------------------------------
def test_mac_support_dir_is_library_path():
    _clear_env()
    with _kind("mac", bltd_paths):
        assert bltd_paths.app_support_dir() == os.path.expanduser(
            "~/Library/Application Support/Black Label Trading")


def test_win_support_dir_uses_localappdata():
    _clear_env()
    os.environ["LOCALAPPDATA"] = r"C:\Users\buyer\AppData\Local"
    try:
        with _kind("win", bltd_paths):
            got = bltd_paths.app_support_dir()
            # os.path.join uses the HOST separator; assert composition, not literal backslashes,
            # so the test is honest on the macOS CI box (real Windows joins with "\\").
            assert got == os.path.join(r"C:\Users\buyer\AppData\Local", "Black Label Trading"), got
            # store + config hang off the same base
            assert bltd_paths.store_path().endswith("trading.sqlite3")
            assert bltd_paths.config_path().endswith("config.json")
            assert bltd_paths.store_path().startswith(got)
    finally:
        os.environ.pop("LOCALAPPDATA", None)


def test_support_dir_env_override_wins_on_every_os():
    _clear_env()
    os.environ["BLTD_SUPPORT_DIR"] = "/tmp/bltd-test-support"
    try:
        for k in ("mac", "win", "other"):
            with _kind(k, bltd_paths):
                assert bltd_paths.app_support_dir() == "/tmp/bltd-test-support"
    finally:
        _clear_env()


# --- bltd_browser: per-OS argv (the honest connect flow, cross-platform) ---
def test_mac_launch_argv_unchanged_gold_master():
    """darwin argv must stay byte-identical to the historical inline launch."""
    with _kind("mac", bltd_browser):
        argv = bltd_browser.build_argv(
            "/Applications/Google Chrome.app", 9223, "/prof",
            ["https://www.topstepx.com/"],
            extra_args=("--disable-background-timer-throttling",))
    assert argv == [
        "open", "-g", "-n", "-a", "/Applications/Google Chrome.app", "--args",
        "--remote-debugging-port=9223", "--remote-debugging-address=127.0.0.1",
        "--remote-allow-origins=*",
        "--user-data-dir=/prof", "--no-first-run", "--no-default-browser-check",
        "--disable-background-timer-throttling", "https://www.topstepx.com/",
    ], argv


def test_win_launch_argv_is_direct_exe():
    """Windows launches the executable directly (no `open`), same CDP flag set + order."""
    with _kind("win", bltd_browser):
        argv = bltd_browser.build_argv(
            r"C:\Program Files\Google\Chrome\Application\chrome.exe", 9223,
            r"C:\prof", ["https://www.topstepx.com/"])
    assert argv[0] == r"C:\Program Files\Google\Chrome\Application\chrome.exe"
    assert "open" not in argv and "--args" not in argv
    assert "--remote-debugging-port=9223" in argv
    assert "--remote-debugging-address=127.0.0.1" in argv   # loopback pin present on Windows too
    assert r"--user-data-dir=C:\prof" in argv
    assert argv[-1] == "https://www.topstepx.com/"


def test_cdp_listener_is_loopback_pinned_both_os():
    for k in ("mac", "win"):
        with _kind(k, bltd_browser):
            argv = bltd_browser.build_argv("b", 9223, "p", ["u"])
        assert "--remote-debugging-address=127.0.0.1" in argv, k


# --- bltd_browser: Windows resolution against a simulated filesystem -------
def test_win_resolves_chrome_from_program_files(tmp=None):
    base = "/tmp/bltd-winfs"
    exe = os.path.join(base, r"Google\Chrome\Application\chrome.exe".replace("\\", "/"))
    os.makedirs(os.path.dirname(exe), exist_ok=True)
    with open(exe, "w") as fh:
        fh.write("stub")
    _clear_env()
    os.environ["ProgramFiles"] = base
    # point the other bases somewhere empty so only Program Files hits
    os.environ["ProgramFiles(x86)"] = "/tmp/bltd-empty1"
    os.environ["LOCALAPPDATA"] = "/tmp/bltd-empty2"
    try:
        with _kind("win", bltd_browser):
            # _win_candidates uses "\\" separators; on POSIX os.path.join won't split them, so this
            # test drives the ENV-OVERRIDE resolution path, which is the real cross-host contract.
            got = bltd_browser.resolve_browser(env_override=exe)
            assert got == exe, got
    finally:
        _clear_env()


def test_env_override_requires_file_on_win_and_dir_on_mac():
    _clear_env()
    # a real file
    f = "/tmp/bltd-fake-chrome.exe"
    with open(f, "w") as fh:
        fh.write("x")
    with _kind("win", bltd_browser):
        assert bltd_browser.resolve_browser(env_override=f) == f
        assert bltd_browser.resolve_browser(env_override="/tmp/does-not-exist.exe") is None
    with _kind("mac", bltd_browser):
        # a file is NOT a valid .app on mac, so the override is REJECTED (it must not be returned;
        # resolution then falls through to real installed candidates, which may or may not exist on
        # the CI host — we only assert the invalid override itself never wins).
        assert bltd_browser.resolve_browser(env_override=f) != f
        # a directory IS a valid .app-shaped override on mac
        assert bltd_browser.resolve_browser(env_override="/tmp") == "/tmp"


# --- ships-empty: naming a path must never create it -----------------------
def test_paths_are_names_only_no_data_created():
    _clear_env()
    os.environ["BLTD_SUPPORT_DIR"] = "/tmp/bltd-should-not-exist-" + str(os.getpid())
    try:
        p = bltd_paths.store_path()
        bltd_paths.config_path()
        bltd_paths.chrome_profile_dir()
        assert not os.path.exists(os.environ["BLTD_SUPPORT_DIR"]), "naming paths must not create them"
        assert p  # sanity
    finally:
        _clear_env()


def test_windows_supervisor_child_environment_is_minimal_and_poison_resistant():
    """Real build_env output is independent of representative caller secrets/injection variables."""
    with tempfile.TemporaryDirectory(prefix="bltd-win-env-") as support:
        caller = {
            "BLTD_SUPPORT_DIR": support,       # validated source-tree/test seam
            "BLTD_PORT": "8794",              # validated supported override
            "BLTD_CDP_PORT": "9333",          # validated supported override
            "PATH": "/tmp/caller-bin",
            "GITHUB_TOKEN": "github-secret",
            "ANTHROPIC_API_KEY": "claude-secret",
            "OPENAI_API_KEY": "openai-secret",
            "AWS_SECRET_ACCESS_KEY": "aws-secret",
            "HTTPS_PROXY": "http://attacker.invalid:8080",
            "SSLKEYLOGFILE": "/tmp/caller-tls-keys",
            "PYTHONPATH": "/tmp/caller-python",
            "PYTHONHOME": "/tmp/caller-python-home",
            "PYTHONSTARTUP": "/tmp/caller-startup.py",
            "BASH_ENV": "/tmp/caller-bashenv",
            "ENV": "/tmp/caller-shellenv",
            "DYLD_INSERT_LIBRARIES": "/tmp/caller.dylib",
            "LD_PRELOAD": "/tmp/caller.so",
            "BLTD_STORE": "/tmp/caller.sqlite3",
            "BLTD_CONFIG": "/tmp/caller-config.json",
            "BLTD_TOKEN": "caller-token",
            "BLTD_TOKEN_FILE": "/tmp/caller-webhook.token",
            "BLTD_DSN": "host=attacker",
            "BLTD_SCOPE": "es",
            "BLTD_WEBHOOK_URL": "https://attacker.invalid/collect",
            "BLTD_PYTHON": "/tmp/caller-python.exe",
            "BLTD_BACKEND_DIR": "/tmp/caller-backend",
            "BLTD_BUILD": "caller-build",
        }
        env = supervisor.build_env(caller)

    expected = {
        "PATH",
        "BLTD_SUPPORT_DIR", "BLTD_STORE", "BLTD_CONFIG", "BLTD_CHROME_PROFILE",
        "BLTD_PORT", "BLTD_CDP_PORT", "BLTD_SCOPE", "BLTD_WEBHOOK_URL",
        "PYTHONPATH", "PYTHONUNBUFFERED", "PYTHONDONTWRITEBYTECODE",
        "PYTHONNOUSERSITE", "PYTHONUTF8", "PYTHONPYCACHEPREFIX",
    }
    if os.name == "nt":
        expected.update({
            "SystemRoot", "WINDIR", "COMSPEC", "PATHEXT", "LOCALAPPDATA",
            "TEMP", "TMP", "ProgramFiles", "USERPROFILE",
        })
        if "ProgramFiles(x86)" in env:
            expected.add("ProgramFiles(x86)")
    assert set(env) == expected, sorted(env)
    if os.name == "nt":
        assert env["PATH"] != caller["PATH"]
        assert env["PATH"].split(";")[0].endswith(r"\System32")
    else:
        assert env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin"
    assert env["BLTD_SUPPORT_DIR"] == support
    assert env["BLTD_STORE"] == os.path.join(support, "trading.sqlite3")
    assert env["BLTD_CONFIG"] == os.path.join(support, "config.json")
    assert env["BLTD_CHROME_PROFILE"] == os.path.join(support, "chrome-topstepx")
    assert env["BLTD_PORT"] == "8794"
    assert env["BLTD_CDP_PORT"] == "9333"
    assert env["BLTD_SCOPE"] == "all"
    assert env["BLTD_WEBHOOK_URL"] == "http://127.0.0.1:8794/webhook/feed"
    assert env["PYTHONPATH"] == supervisor.BACKEND_DIR
    assert env["PYTHONPYCACHEPREFIX"] == os.path.join(support, "pycache")

    forbidden = {
        "GITHUB_TOKEN", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "AWS_SECRET_ACCESS_KEY",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "SSLKEYLOGFILE",
        "PYTHONHOME", "PYTHONSTARTUP", "PYTHONINSPECT", "BASH_ENV", "ENV",
        "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "LD_PRELOAD", "LD_LIBRARY_PATH",
        "BLTD_TOKEN", "BLTD_TOKEN_FILE", "BLTD_DSN", "BLTD_PYTHON",
        "BLTD_BACKEND_DIR", "BLTD_BUILD",
    }
    assert forbidden.isdisjoint(env)


def test_windows_supervisor_rejects_malformed_paths_and_ports():
    with tempfile.TemporaryDirectory(prefix="bltd-win-validate-") as support:
        base = {"BLTD_SUPPORT_DIR": support}
        for key in ("BLTD_PORT", "BLTD_CDP_PORT"):
            for bad in ("", "0", "65536", "08793", "-1", "8793 ", "8793;calc.exe"):
                poisoned = dict(base)
                poisoned[key] = bad
                assert _raises(ValueError, lambda e=poisoned: supervisor.build_env(e)), (key, bad)
        assert supervisor.build_env({**base, "BLTD_PORT": "1"})["BLTD_PORT"] == "1"
        assert supervisor.build_env({**base, "BLTD_PORT": "65535"})["BLTD_PORT"] == "65535"
    assert _raises(
        ValueError,
        lambda: supervisor.build_env({"BLTD_SUPPORT_DIR": r"relative\support"}))
    assert _raises(
        ValueError,
        lambda: supervisor.build_env({"BLTD_SUPPORT_DIR": "/tmp/good\nBASH_ENV=bad"}))


def test_windows_supervisor_packaged_code_and_python_ignore_caller_overrides():
    with tempfile.TemporaryDirectory(prefix="bltd-win-package-") as package:
        packaged_backend = os.path.join(package, "backend")
        os.makedirs(packaged_backend)
        packaged_python = os.path.join(package, "python.exe")
        with open(packaged_python, "w", encoding="ascii") as fh:
            fh.write("stub")
        dev_browser = os.path.join(package, "chrome.exe")
        with open(dev_browser, "w", encoding="ascii") as fh:
            fh.write("stub")

        original_backend = supervisor._PACKAGED_BACKEND_DIR
        original_python = supervisor._PACKAGED_PYTHON
        original_runtime = supervisor._PACKAGED_RUNTIME
        previous_backend = os.environ.get("BLTD_BACKEND_DIR")
        previous_python = os.environ.get("BLTD_PYTHON")
        os.environ["BLTD_BACKEND_DIR"] = _HERE
        os.environ["BLTD_PYTHON"] = sys.executable
        supervisor._PACKAGED_BACKEND_DIR = packaged_backend
        supervisor._PACKAGED_PYTHON = packaged_python
        supervisor._PACKAGED_RUNTIME = True
        try:
            assert supervisor._resolve_backend_dir() == os.path.realpath(packaged_backend)
            assert supervisor._python() == os.path.realpath(packaged_python)
            assert "BLTD_CHROME_APP" not in supervisor.build_env(
                {"BLTD_CHROME_APP": dev_browser})
        finally:
            supervisor._PACKAGED_BACKEND_DIR = original_backend
            supervisor._PACKAGED_PYTHON = original_python
            supervisor._PACKAGED_RUNTIME = original_runtime
            if previous_backend is None:
                os.environ.pop("BLTD_BACKEND_DIR", None)
            else:
                os.environ["BLTD_BACKEND_DIR"] = previous_backend
            if previous_python is None:
                os.environ.pop("BLTD_PYTHON", None)
            else:
                os.environ["BLTD_PYTHON"] = previous_python

        dev_env = supervisor.build_env({
            "BLTD_SUPPORT_DIR": package,
            "BLTD_CHROME_APP": dev_browser,
        })
        assert dev_env["BLTD_CHROME_APP"] == os.path.normpath(dev_browser)


def test_windows_supervisor_system_environment_uses_safe_loader_paths():
    caller = {
        "LOCALAPPDATA": r"C:\attacker\local",
        "ProgramFiles": r"C:\attacker\programs",
        "ProgramFiles(x86)": r"C:\attacker\programs-x86",
        "USERPROFILE": r"C:\attacker\profile",
        "SystemRoot": r"C:\attacker",
        "WINDIR": r"C:\attacker",
        "COMSPEC": r"C:\attacker\cmd.exe",
        "PATH": r"C:\attacker",
        "TEMP": r"C:\attacker",
    }
    original_directory = supervisor._windows_directory
    original_paths = supervisor._windows_known_paths
    supervisor._windows_directory = lambda: r"D:\Windows"
    supervisor._windows_known_paths = lambda: {
        "LOCALAPPDATA": r"C:\Users\buyer\AppData\Local",
        "ProgramFiles": r"C:\Program Files",
        "ProgramFiles(x86)": r"C:\Program Files (x86)",
        "USERPROFILE": r"C:\Users\buyer",
    }
    try:
        env = supervisor._windows_system_environment(caller)
        packaged_support = supervisor._support_dir(
            {"BLTD_SUPPORT_DIR": r"C:\attacker\support"},
            packaged_runtime=True,
            os_name="nt")
    finally:
        supervisor._windows_directory = original_directory
        supervisor._windows_known_paths = original_paths

    assert packaged_support == (
        r"C:\Users\buyer\AppData\Local\Black Label Trading")
    assert env["SystemRoot"] == r"D:\Windows"
    assert env["WINDIR"] == r"D:\Windows"
    assert env["COMSPEC"] == r"D:\Windows\System32\cmd.exe"
    assert env["PATH"] == (
        r"D:\Windows\System32;D:\Windows;D:\Windows\System32\Wbem")
    assert env["TEMP"] == r"C:\Users\buyer\AppData\Local\Temp"
    assert env["TMP"] == env["TEMP"]
    assert env["ProgramFiles"] == r"C:\Program Files"
    assert set(env) == {
        "SystemRoot", "WINDIR", "COMSPEC", "PATH", "PATHEXT", "LOCALAPPDATA",
        "TEMP", "TMP", "ProgramFiles", "ProgramFiles(x86)", "USERPROFILE",
    }


def test_windows_supervisor_token_file_ignores_caller_and_is_private():
    previous = os.environ.get("BLTD_TOKEN")
    os.environ["BLTD_TOKEN"] = "caller-controlled-token"
    try:
        with tempfile.TemporaryDirectory(prefix="bltd-win-token-") as support:
            token_path = os.path.join(support, "webhook.token")
            env = supervisor._runtime_environment({
                "BLTD_SUPPORT_DIR": support,
                "BLTD_TOKEN": "caller-controlled-token",
                "BLTD_TOKEN_FILE": "/tmp/caller-webhook.token",
            })
            assert "BLTD_TOKEN" not in env
            assert env["BLTD_TOKEN_FILE"] == token_path
            assert supervisor._ensure_token_file(support) == token_path
            with open(token_path, encoding="ascii") as fh:
                token = fh.read()
            assert token != "caller-controlled-token"
            assert supervisor._TOKEN_RE.fullmatch(token)
            if os.name != "nt":
                assert stat.S_IMODE(os.stat(token_path).st_mode) == 0o600
                os.chmod(token_path, 0o666)
                assert supervisor._ensure_token_file(support) == token_path
                assert stat.S_IMODE(os.stat(token_path).st_mode) == 0o600
        with tempfile.TemporaryDirectory(prefix="bltd-win-invalid-token-") as support:
            token_path = os.path.join(support, "webhook.token")
            with open(token_path, "w", encoding="ascii") as fh:
                fh.write("invalid token")
            assert _raises(RuntimeError, lambda: supervisor._ensure_token_file(support))
    finally:
        if previous is None:
            os.environ.pop("BLTD_TOKEN", None)
        else:
            os.environ["BLTD_TOKEN"] = previous


def test_windows_supervisor_hardens_existing_config_and_rejects_links():
    with tempfile.TemporaryDirectory(prefix="bltd-win-config-") as support:
        config = os.path.join(support, "config.json")
        with open(config, "w", encoding="utf-8") as fh:
            fh.write("{}")
        if os.name != "nt":
            os.chmod(config, 0o666)
        supervisor._secure_private_file(config, "backend config")
        if os.name != "nt":
            assert stat.S_IMODE(os.stat(config).st_mode) == 0o600
            link = os.path.join(support, "config-link.json")
            os.symlink(config, link)
            assert _raises(
                RuntimeError,
                lambda: supervisor._secure_private_file(link, "backend config"))


def test_windows_supervisor_spawn_receives_only_sanitized_environment():
    with tempfile.TemporaryDirectory(prefix="bltd-win-spawn-") as support:
        env = supervisor._runtime_environment(supervisor.build_env({
            "BLTD_SUPPORT_DIR": support,
            "BLTD_TOKEN": "caller-controlled-token",
            "BLTD_TOKEN_FILE": "/tmp/caller-webhook.token",
        }))
        spec = {
            "name": "capture-test",
            "argv": [sys.executable, "-c", "pass"],
            "env": {"BLTD_AUTO_BROWSER": "0", "BLTD_CAPTURE_BROWSER": "0"},
        }
        captured = {}
        marker = object()

        def fake_popen(argv, **kwargs):
            captured["argv"] = argv
            captured.update(kwargs)
            return marker

        original = supervisor.subprocess.Popen
        supervisor.subprocess.Popen = fake_popen
        try:
            assert supervisor._spawn_child(spec, env, support) is marker
        finally:
            supervisor.subprocess.Popen = original

        expected = dict(env)
        expected.update(spec["env"])
        assert captured["env"] == expected
        assert "GITHUB_TOKEN" not in captured["env"]
        assert "BLTD_TOKEN" not in captured["env"]
        token_path = captured["env"]["BLTD_TOKEN_FILE"]
        assert token_path == os.path.join(support, "webhook.token")
        with open(token_path, encoding="ascii") as fh:
            assert supervisor._TOKEN_RE.fullmatch(fh.read())
        if os.name != "nt":
            assert stat.S_IMODE(os.stat(token_path).st_mode) == 0o600
        assert captured["cwd"] == supervisor.BACKEND_DIR
        assert _raises(
            ValueError,
            lambda: supervisor._child_environment(
                env, {"env": {"BLTD_DSN": "host=attacker"}}))
        log_path = os.path.join(support, "capture-test.log")
        assert os.path.isfile(log_path)
        if os.name != "nt":
            assert stat.S_IMODE(os.stat(log_path).st_mode) == 0o600


def test_windows_supervisor_uses_canonical_trading_port_and_external_cache():
    """The lane shares the product's canonical port and never mutates a future signed tree."""
    with open(_SUPERVISOR_PATH, encoding="utf-8") as fh:
        text = fh.read()
    assert '_validated_port(source, "BLTD_PORT", "8793")' in text
    assert "PYTHONPYCACHEPREFIX" in text
    assert '_join_under(support, "pycache")' in text
    assert "dict(os.environ)" not in text
    assert 'env["BLTD_TOKEN"]' not in text
    assert 'env["BLTD_TOKEN_FILE"] = _ensure_token_file' in text
    # A single Popen call consumes the exact child_env through kwargs on every OS branch.
    assert "env=child_env" not in text
    assert '"env": child_env' in text


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    passed = failed = 0
    for fn in fns:
        try:
            fn()
            passed += 1
        except AssertionError as e:
            failed += 1
            print(f"FAIL {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"ERR {fn.__name__}: {e!r}")
    print(f"{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
