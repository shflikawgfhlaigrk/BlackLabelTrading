#!/usr/bin/env python3
"""Regression locks for b27's signals-only daemon identity and upgrade takeover."""
from __future__ import annotations

import os
import json
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request

_TEMP = tempfile.TemporaryDirectory()
if "bltd_api" not in sys.modules:
    os.environ["BLTD_STORE"] = os.path.join(_TEMP.name, "runtime-contract.sqlite3")
import bltd_api as API

HERE = os.path.dirname(os.path.abspath(__file__))
LAUNCHER = os.path.join(HERE, "launch-backend.sh")


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _launcher_env(support: str, port: int, build: str) -> dict[str, str]:
    return {
        "HOME": os.path.expanduser("~"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C",
        "LC_ALL": "C",
        "BLTD_PYTHON": sys.executable,
        "BLTD_SUPPORT_DIR": support,
        "BLTD_PORT": str(port),
        "BLTD_BUILD": build,
        "BLTD_STORE": os.path.join(support, "trading.sqlite3"),
        "BLTD_CONFIG": os.path.join(support, "config.json"),
        "BLTD_TOKEN": "runtime-contract-token",
        "BLTD_CAPTURE_BROWSER": "0",
        "BLTD_AUTO_BROWSER": "0",
        "PYTHONPYCACHEPREFIX": os.path.join(support, "pycache"),
    }


def _write_pid(support: str, name: str, pid: object) -> None:
    with open(os.path.join(support, name), "w", encoding="utf-8") as handle:
        handle.write(f"{pid}\n")


def _read_pid(support: str, name: str) -> int:
    with open(os.path.join(support, name), encoding="utf-8") as handle:
        return int(handle.read().strip())


def _process_command(pid: int) -> str:
    return subprocess.run(
        ["/bin/ps", "-ww", "-p", str(pid), "-o", "command="],
        text=True,
        capture_output=True,
        check=False,
    ).stdout.strip()


def _wait_pidfiles(support: str, timeout: float = 5.0) -> dict[str, tuple[int, str]]:
    names = (
        "backend.pid", "capture-supervisor.pid", "capture.pid",
        "topstep-bridge-supervisor.pid", "topstep-bridge.pid",
    )
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            captured = {
                name: (_read_pid(support, name), "")
                for name in names
            }
            captured = {
                name: (pid, _process_command(pid))
                for name, (pid, _) in captured.items()
            }
            if all(pid > 0 and command for pid, command in captured.values()):
                return captured
        except (FileNotFoundError, ValueError):
            pass
        time.sleep(0.05)
    raise AssertionError(f"runtime pidfiles did not become complete under {support}")


def _wait_captured_pid_dead(pid: int, command: str, timeout: float = 5.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        current = _process_command(pid)
        if not current or current != command:
            return True
        time.sleep(0.05)
    current = _process_command(pid)
    return not current or current != command


def _force_clean_captured(runtime: dict[str, tuple[int, str]]) -> None:
    for pid, command in runtime.values():
        if _process_command(pid) == command:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                continue
    deadline = time.time() + 2.0
    while time.time() < deadline:
        if all(_process_command(pid) != command for pid, command in runtime.values()):
            return
        time.sleep(0.05)
    for pid, command in runtime.values():
        if _process_command(pid) == command:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


def _assert_captured_runtime_dead(
        runtime: dict[str, tuple[int, str]], label: str) -> None:
    survivors = []
    for name, (pid, command) in runtime.items():
        if not _wait_captured_pid_dead(pid, command):
            survivors.append(f"{name} pid={pid} command={_process_command(pid)!r}")
    if survivors:
        _force_clean_captured(runtime)
        raise AssertionError(f"{label} left owned processes alive: {'; '.join(survivors)}")


def _wait_json(port: int, timeout: float = 8.0) -> dict:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/health", timeout=0.3) as response:
                return json.load(response)
        except Exception:  # noqa: BLE001 - readiness polling
            time.sleep(0.05)
    raise AssertionError(f"health did not come up on :{port}")


def _wait_dead(process: subprocess.Popen, timeout: float = 5.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if process.poll() is not None:
            return True
        time.sleep(0.05)
    return process.poll() is not None


def _terminate(process) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=2)


def _run_launcher(support: str, port: int, build: str, mode: str,
                  extra_env=None) -> subprocess.CompletedProcess:
    env = _launcher_env(support, port, build)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["/bin/bash", LAUNCHER, mode],
        env=env,
        text=True,
        capture_output=True,
        timeout=20,
        check=False,
        start_new_session=True,
    )


def _health_is_down(port: int) -> bool:
    try:
        with urllib.request.urlopen(
                f"http://127.0.0.1:{port}/health", timeout=0.3):
            return False
    except Exception:  # noqa: BLE001 - expected refusal/closed connection
        return True


def test_health_payload_has_exact_fail_closed_runtime_identity():
    payload = API._health_payload()
    assert payload["ok"] is True
    assert payload["service"] == "black-label-trading"
    assert payload["build"] == API.BUILD_ID
    assert payload["runtimeContract"] == "bltd-signals-only-runtime-v1"
    assert os.path.realpath(payload["backendScript"]) == os.path.realpath(API.__file__)
    assert payload["capabilities"] == {
        "signals": True,
        "execution": False,
        "optimizerCompute": False,
    }


def test_token_file_precedes_legacy_environment_override():
    import bltd_topstep_bridge as bridge

    with tempfile.TemporaryDirectory() as work:
        token_file = os.path.join(work, "webhook.token")
        with open(token_file, "w", encoding="utf-8") as handle:
            handle.write("file-backed-token\n")
        saved_file = os.environ.get("BLTD_TOKEN_FILE")
        saved_token = os.environ.get("BLTD_TOKEN")
        try:
            os.environ["BLTD_TOKEN_FILE"] = token_file
            os.environ["BLTD_TOKEN"] = "legacy-environment-token"
            assert API._resolve_token() == "file-backed-token"
            assert bridge.webhook_token() == "file-backed-token"
        finally:
            if saved_file is None:
                os.environ.pop("BLTD_TOKEN_FILE", None)
            else:
                os.environ["BLTD_TOKEN_FILE"] = saved_file
            if saved_token is None:
                os.environ.pop("BLTD_TOKEN", None)
            else:
                os.environ["BLTD_TOKEN"] = saved_token


def test_launcher_reuse_requires_build_path_contract_and_no_execution():
    with open(LAUNCHER, encoding="utf-8") as handle:
        source = handle.read()
    required = (
        'str(body.get("build")) == sys.argv[2]',
        'body.get("runtimeContract") == sys.argv[3]',
        'os.path.realpath(str(body.get("backendScript") or "")) == os.path.realpath(sys.argv[4])',
        'capabilities.get("execution") is False',
        'capabilities.get("optimizerCompute") is False',
    )
    for literal in required:
        assert literal in source, f"launcher reuse no longer checks {literal}"


def test_launcher_only_stops_a_verified_product_pid_and_versions_supervisors():
    with open(LAUNCHER, encoding="utf-8") as handle:
        source = handle.read()
    assert "stop_owned_runtime" in source
    assert 'CANONICAL_BACKEND="/Applications/Black Label Trading.app/Contents/Resources/backend"' in source
    assert '[[ "${1:-}" =~ ^[1-9][0-9]*$ ]]' in source
    assert "bltd-supervisor-v3:$BLTD_BUILD:$NAME" in source
    assert "bltd-worker-v3:$BLTD_BUILD:$NAME" in source
    assert "pkill" not in source
    assert "pgrep" not in source
    assert "find_existing_child" not in source
    assert 'SUPPORT="${BLTD_SUPPORT_DIR:-' in source
    assert "umask 077" in source
    assert 'export PYTHONPATH="$HERE"' in source
    assert '${PYTHONPATH:-}' not in source
    assert 'nohup /usr/bin/env -i "${RUNTIME_ENV[@]}"' in source
    assert 'write_pidfile_atomic "$PIDF" "$API_PID"' in source
    assert "trap shutdown HUP INT TERM EXIT" in source
    assert "release_launcher_lock" in source
    assert '"BLTD_TOKEN_FILE=$BLTD_TOKEN_FILE"' in source
    assert '"BLTD_TOKEN=$BLTD_TOKEN"' not in source
    teardown = source.index("if ! stop_owned_runtime")
    collision = source.index("if port_is_listening", teardown)
    assert teardown < collision


def test_manual_replacement_stops_legacy_port_and_workers_then_reuses_exact_b27():
    with tempfile.TemporaryDirectory() as work:
        support = os.path.join(work, "support")
        os.makedirs(support)
        legacy_port = 8787
        with socket.socket() as probe:
            try:
                probe.bind(("127.0.0.1", legacy_port))
            except OSError:
                legacy_port = _free_port()
        new_port = _free_port()
        old_env = _launcher_env(support, legacy_port, "26")
        old_env["BLTD_STORE"] = os.path.join(support, "legacy.sqlite3")
        processes: list[subprocess.Popen] = []
        fresh_runtime: dict[str, tuple[int, str]] = {}
        try:
            old_api = subprocess.Popen(
                [sys.executable, API.__file__, str(legacy_port)],
                env=old_env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            processes.append(old_api)
            _wait_json(legacy_port)
            _write_pid(support, "backend.pid", old_api.pid)

            def sleeper(*identity: str) -> subprocess.Popen:
                process = subprocess.Popen(
                    [sys.executable, "-c", "import time; time.sleep(120)", *identity],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                processes.append(process)
                return process

            capture_script = os.path.join(HERE, "bltd_capture.py")
            bridge_script = os.path.join(HERE, "bltd_topstep_bridge.py")
            legacy_processes = [
                sleeper("bltd-supervisor-v2:capture", capture_script),
                sleeper(capture_script),
                sleeper("bltd-supervisor-v3:26:topstep-bridge", bridge_script),
                sleeper(bridge_script),
            ]
            for filename, process in zip((
                    "capture-supervisor.pid", "capture.pid",
                    "topstep-bridge-supervisor.pid", "topstep-bridge.pid",
            ), legacy_processes):
                _write_pid(support, filename, process.pid)

            launched = _run_launcher(support, new_port, "27", "--bg")
            assert launched.returncode == 0, (launched.stdout, launched.stderr)
            labels = ("legacy-api", "capture-supervisor", "capture-worker",
                      "bridge-supervisor", "bridge-worker")
            for label, process in zip(labels, [old_api, *legacy_processes]):
                if not _wait_dead(process):
                    command = subprocess.run(
                        ["/bin/ps", "-ww", "-p", str(process.pid), "-o", "command="],
                        text=True, capture_output=True, check=False).stdout.strip()
                    raise AssertionError(
                        f"{label} survived pid={process.pid} command={command!r}")

            health = _wait_json(new_port)
            assert health["build"] == "27"
            assert health["runtimeContract"] == "bltd-signals-only-runtime-v1"
            assert health["capabilities"] == {
                "signals": True,
                "execution": False,
                "optimizerCompute": False,
            }
            fresh_runtime = _wait_pidfiles(support)
            first_pids = {
                name: pid for name, (pid, _) in fresh_runtime.items()
            }
            reused = _run_launcher(support, new_port, "27", "--bg")
            assert reused.returncode == 0, (reused.stdout, reused.stderr)
            second_pids = {name: _read_pid(support, name) for name in first_pids}
            assert second_pids == first_pids, (first_pids, second_pids)
        finally:
            cleanup_error = None
            stopped = _run_launcher(support, new_port, "27", "--stop-owned")
            if stopped.returncode != 0:
                cleanup_error = AssertionError((stopped.stdout, stopped.stderr))
            if fresh_runtime:
                try:
                    _assert_captured_runtime_dead(
                        fresh_runtime, "replacement-test teardown")
                except Exception as exc:  # noqa: BLE001 - clean before surfacing
                    cleanup_error = exc
            for process in processes:
                _terminate(process)
            if cleanup_error is not None:
                raise cleanup_error


def test_foreground_runtime_is_pidfile_owned_and_stoppable():
    with tempfile.TemporaryDirectory() as work:
        support = os.path.join(work, "support")
        os.makedirs(support)
        port = _free_port()
        foreground = subprocess.Popen(
            ["/bin/bash", LAUNCHER],
            env=_launcher_env(support, port, "27"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        runtime: dict[str, tuple[int, str]] = {}
        cleanup_error = None
        stopped = False
        try:
            health = _wait_json(port)
            assert health["build"] == "27"
            runtime = _wait_pidfiles(support)
            assert runtime["backend.pid"][0] != foreground.pid
            assert not os.path.exists(os.path.join(support, "launcher.lock"))

            result = _run_launcher(support, port, "27", "--stop-owned")
            assert result.returncode == 0, (result.stdout, result.stderr)
            stopped = True
            _assert_captured_runtime_dead(runtime, "foreground teardown")
            assert _health_is_down(port)
            assert _wait_dead(foreground), "foreground launcher did not reap its API"
            for name in runtime:
                assert not os.path.exists(os.path.join(support, name)), name
        finally:
            if not stopped:
                _run_launcher(support, port, "27", "--stop-owned")
            if runtime:
                try:
                    _assert_captured_runtime_dead(runtime, "foreground fallback cleanup")
                except Exception as exc:  # noqa: BLE001
                    cleanup_error = exc
            _terminate(foreground)
            if cleanup_error is not None:
                raise cleanup_error


def test_supervisors_kill_in_memory_children_when_worker_pidfiles_are_empty():
    with tempfile.TemporaryDirectory() as work:
        support = os.path.join(work, "support")
        os.makedirs(support)
        port = _free_port()
        runtime: dict[str, tuple[int, str]] = {}
        stopped = False
        try:
            launched = _run_launcher(support, port, "27", "--bg")
            assert launched.returncode == 0, (launched.stdout, launched.stderr)
            _wait_json(port)
            runtime = _wait_pidfiles(support)

            # Model the observable truncate/write window that previously made teardown silently
            # lose both workers. The supervisors must retain and stop the child PIDs they forked.
            for name in ("capture.pid", "topstep-bridge.pid"):
                with open(os.path.join(support, name), "w", encoding="utf-8"):
                    pass

            result = _run_launcher(support, port, "27", "--stop-owned")
            assert result.returncode == 0, (result.stdout, result.stderr)
            stopped = True
            _assert_captured_runtime_dead(runtime, "empty-worker-pidfile teardown")
            assert _health_is_down(port)
            for name in runtime:
                assert not os.path.exists(os.path.join(support, name)), name
        finally:
            if not stopped:
                _run_launcher(support, port, "27", "--stop-owned")
            if runtime:
                _assert_captured_runtime_dead(runtime, "empty-pidfile fallback cleanup")


def test_long_lived_runtime_does_not_inherit_caller_environment():
    with tempfile.TemporaryDirectory() as work:
        support = os.path.join(work, "support")
        os.makedirs(support)
        port = _free_port()
        wrapper = os.path.join(work, "python-wrapper")
        observations = os.path.join(work, "runtime-env.log")
        wrapper_source = f"""#!/bin/sh
case "${{1:-}}" in
  *bltd_api.py|*bltd_capture.py|*bltd_topstep_bridge.py)
    status=clean
    [ -z "${{BLTD_ENV_SENTINEL+x}}" ] || status=leaked
    /usr/bin/printf '%s:%s\\n' "$(/usr/bin/basename "$1")" "$status" >>{shlex.quote(observations)}
    ;;
esac
exec {shlex.quote(sys.executable)} "$@"
"""
        with open(wrapper, "w", encoding="utf-8") as handle:
            handle.write(wrapper_source)
        os.chmod(wrapper, 0o700)

        runtime: dict[str, tuple[int, str]] = {}
        stopped = False
        try:
            launched = _run_launcher(
                support,
                port,
                "27",
                "--bg",
                {
                    "BLTD_PYTHON": wrapper,
                    "BLTD_ENV_SENTINEL": "must-not-reach-runtime",
                    "PYTHONSTARTUP": os.path.join(work, "malicious-startup.py"),
                    "BASH_ENV": os.path.join(work, "malicious-bash-env"),
                },
            )
            assert launched.returncode == 0, (launched.stdout, launched.stderr)
            _wait_json(port)
            runtime = _wait_pidfiles(support)

            deadline = time.time() + 5.0
            observations_text = ""
            while time.time() < deadline:
                try:
                    with open(observations, encoding="utf-8") as handle:
                        observations_text = handle.read()
                except FileNotFoundError:
                    pass
                if all(name in observations_text for name in (
                        "bltd_api.py:clean",
                        "bltd_capture.py:clean",
                        "bltd_topstep_bridge.py:clean",
                )):
                    break
                time.sleep(0.05)
            assert ":leaked" not in observations_text, observations_text
            assert "bltd_api.py:clean" in observations_text, observations_text
            assert "bltd_capture.py:clean" in observations_text, observations_text
            assert "bltd_topstep_bridge.py:clean" in observations_text, observations_text
            for _, command in runtime.values():
                assert "must-not-reach-runtime" not in command, command
                assert "runtime-contract-token" not in command, command

            result = _run_launcher(support, port, "27", "--stop-owned")
            assert result.returncode == 0, (result.stdout, result.stderr)
            stopped = True
            _assert_captured_runtime_dead(runtime, "environment-sentinel teardown")
        finally:
            if not stopped:
                _run_launcher(support, port, "27", "--stop-owned")
            if runtime:
                _assert_captured_runtime_dead(runtime, "environment fallback cleanup")


def test_malformed_pidfiles_and_unrelated_listener_are_never_signaled():
    with tempfile.TemporaryDirectory() as work:
        support = os.path.join(work, "support")
        os.makedirs(support)
        port = _free_port()
        listener = subprocess.Popen(
            [sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        unrelated = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(120)", "not-black-label"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            deadline = time.time() + 5
            while time.time() < deadline:
                with socket.socket() as probe:
                    if probe.connect_ex(("127.0.0.1", port)) == 0:
                        break
                time.sleep(0.05)
            _write_pid(support, "backend.pid", listener.pid)
            _write_pid(support, "capture-supervisor.pid", "0")
            _write_pid(support, "capture.pid", "-1")
            _write_pid(support, "topstep-bridge-supervisor.pid", unrelated.pid)
            launched = _run_launcher(support, port, "27", "--bg")
            assert launched.returncode == 4, (launched.stdout, launched.stderr)
            assert listener.poll() is None
            assert unrelated.poll() is None
            with open(os.path.join(support, "prereq.json"), encoding="utf-8") as handle:
                prereq = json.load(handle)
            assert prereq["ok"] is False
            assert "already owned by another service" in prereq["reason"]
        finally:
            _terminate(listener)
            _terminate(unrelated)


def test_exact_legacy_8787_api_pidfile_is_stopped_without_port_scan():
    with tempfile.TemporaryDirectory() as work:
        support = os.path.join(work, "support")
        os.makedirs(support)
        legacy_api = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(120)",
             API.__file__, "8787"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            _write_pid(support, "backend.pid", legacy_api.pid)
            stopped = _run_launcher(support, _free_port(), "27", "--stop-owned")
            assert stopped.returncode == 0, (stopped.stdout, stopped.stderr)
            assert _wait_dead(legacy_api), "verified legacy :8787 API identity survived"
        finally:
            _terminate(legacy_api)


def test_updater_can_pin_a_custom_installed_backend_without_widening_kills():
    with tempfile.TemporaryDirectory() as work:
        support = os.path.join(work, "support")
        installed_backend = os.path.join(
            work, "Custom Trading.app", "Contents", "Resources", "backend")
        os.makedirs(support)
        os.makedirs(installed_backend)
        installed_api = os.path.join(installed_backend, "bltd_api.py")
        custom_api = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(120)",
             installed_api, "8787"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        unrelated = subprocess.Popen(
            [sys.executable, "-c", "import time; time.sleep(120)",
             os.path.join(installed_backend, "not_bltd_api.py"), "8787"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            _write_pid(support, "backend.pid", custom_api.pid)
            stopped = _run_launcher(
                support, _free_port(), "27", "--stop-owned",
                {"BLTD_OWNED_BACKEND_DIR": installed_backend})
            assert stopped.returncode == 0, (stopped.stdout, stopped.stderr)
            if not _wait_dead(custom_api):
                command = subprocess.run(
                    ["/bin/ps", "-ww", "-p", str(custom_api.pid), "-o", "command="],
                    text=True, capture_output=True, check=False).stdout.strip()
                raise AssertionError(
                    f"custom installed Trading API survived command={command!r}")
            assert unrelated.poll() is None
        finally:
            _terminate(custom_api)
            _terminate(unrelated)


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items())
             if name.startswith("test_") and callable(value)]
    failed = 0
    for test in tests:
        started = time.monotonic()
        try:
            test()
            print(f"ok {test.__name__} ({time.monotonic() - started:.1f}s)")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            print(f"FAIL {test.__name__}: {type(exc).__name__}: {exc} "
                  f"({time.monotonic() - started:.1f}s)")
    print(f"\n{len(tests) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
