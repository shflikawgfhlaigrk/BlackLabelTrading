#!/usr/bin/env python3
"""Open-market wedge proof for the capture freshness watchdog.

WHY: a TRUE live-session wedge can only happen if the capture daemon is actually
broken during ES hours — you cannot stage one without inducing a fault in the live
runtime, which is risky. So this proof drives the EXACT live decision loop
(`_freshness_watchdog`) directly, with a controlled clock and a temp store, and
asserts the combined gate:

    wedged AND watchdog_feed_available() AND _market_is_open(_central_now()) -> os._exit(1)

It is READ-ONLY against the live runtime: it imports the deployed module, uses a
throwaway temp sqlite store, monkeypatches only its own in-memory copies of the
hooks/clock, and restores every patch. It never writes the live store, never
restarts the daemon, never touches launchd.

Default target is the deployed live runtime; override with CAPTURE_DIR.

    python3 render-proof/watchdog-wedge-proof.py            # live ~/.blacklabel
    CAPTURE_DIR=$PWD/backend python3 render-proof/watchdog-wedge-proof.py  # bundle source

Exit 0 => all three cases behaved correctly. Exit 1 => a gate is wrong.
"""
import os
import sqlite3
import sys
import tempfile
from datetime import datetime

CAPTURE_DIR = os.environ.get("CAPTURE_DIR", os.path.expanduser("~/.blacklabel"))
sys.path.insert(0, CAPTURE_DIR)
import bltd_capture as c  # noqa: E402

CENTRAL = c._CENTRAL


class _Exited(Exception):
    def __init__(self, code):
        self.code = code


class _LoopBudget(Exception):
    pass


def _make_stale_store():
    """Temp store whose max(recorded) is fixed and old => never advances."""
    d = tempfile.mkdtemp(prefix="wedge-proof-")
    path = os.path.join(d, "trading.sqlite3")
    cx = sqlite3.connect(path)
    cx.execute("CREATE TABLE wc_live (recorded REAL)")
    cx.execute("INSERT INTO wc_live (recorded) VALUES (?)", (1000.0,))
    cx.commit()
    cx.close()
    return path


def run_case(name, *, feed_available, market_dt, max_iters, expect_exit):
    store_path = _make_stale_store()

    # Controlled, deterministic fake clock: +100s per call so a 300s stale window
    # is crossed after a few iterations regardless of real wall time.
    clock = {"t": 10000.0}

    def fake_time():
        clock["t"] += 100.0
        return clock["t"]

    iters = {"n": 0}

    def fake_sleep(_):
        iters["n"] += 1
        if iters["n"] > max_iters:
            raise _LoopBudget()

    def fake_exit(code):
        raise _Exited(code)

    orig = {
        "time": c.time.time,
        "sleep": c.time.sleep,
        "exit": c.os._exit,
        "feed": c.watchdog_feed_available,
        "central": c._central_now,
    }
    c.time.time = fake_time
    c.time.sleep = fake_sleep
    c.os._exit = fake_exit
    c.watchdog_feed_available = lambda: feed_available
    c._central_now = lambda now=None: market_dt
    try:
        c._freshness_watchdog(store_path, stale_after=300.0, check_every=0.0)
        result = "RETURNED"
    except _Exited as e:
        result = f"EXIT({e.code})"
    except _LoopBudget:
        result = f"NO-EXIT/{iters['n'] - 1}iters"
    finally:
        c.time.time = orig["time"]
        c.time.sleep = orig["sleep"]
        c.os._exit = orig["exit"]
        c.watchdog_feed_available = orig["feed"]
        c._central_now = orig["central"]

    ok = (result == "EXIT(1)") if expect_exit else result.startswith("NO-EXIT")
    print(f"[{'PASS' if ok else 'FAIL'}] {name}: {result} "
          f"(expected {'exit' if expect_exit else 'no-exit'})")
    return ok


def main():
    open_dt = datetime(2026, 6, 29, 9, 30, tzinfo=CENTRAL)    # Mon 09:30 CT -> open
    closed_dt = datetime(2026, 6, 28, 12, 0, tzinfo=CENTRAL)  # Sun 12:00 CT -> closed

    # Sanity: the REAL _market_is_open agrees with our chosen times.
    assert c._market_is_open(open_dt) is True, "open_dt should be open"
    assert c._market_is_open(closed_dt) is False, "closed_dt should be closed"
    print(f"runtime: {CAPTURE_DIR}/bltd_capture.py")
    print(f"  _market_is_open(Mon 09:30 CT) = {c._market_is_open(open_dt)}")
    print(f"  _market_is_open(Sun 12:00 CT) = {c._market_is_open(closed_dt)}")

    results = [
        run_case("A open + wedged + feed", feed_available=True,
                 market_dt=open_dt, max_iters=50, expect_exit=True),
        run_case("B closed + wedged + feed", feed_available=True,
                 market_dt=closed_dt, max_iters=30, expect_exit=False),
        run_case("C open + wedged + NO feed", feed_available=False,
                 market_dt=open_dt, max_iters=30, expect_exit=False),
    ]
    if all(results):
        print("RESULT: WATCHDOG-GATE-CORRECT")
        return 0
    print("RESULT: WATCHDOG-GATE-WRONG")
    return 1


if __name__ == "__main__":
    sys.exit(main())
