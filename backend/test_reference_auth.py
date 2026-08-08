#!/usr/bin/env python3
"""REGRESSION LOCK (trading-engineer, 2026-07-23) — GET /api/reference must fail CLOSED.

Bug this locks: bltd_api.do_GET once served /api/reference BEFORE the Bearer-auth gate, rationalized
as "public research". That let a cold, UNAUTHENTICATED GET on the local Trading port scrape a signed edge-gate
verdict (the "OOS candidate (cleared significance)" / "no edge" reference artifact) the server cannot
attribute to a buyer session — a fail-open flagged by trading-analyst. Every other /api/* read
requires the per-launch token; the reference artifact must too.

The fix moves the /api/reference handler BELOW `if not self._authed(): 401`.

Positive control: this file does not just assert "401". It first proves the route is LIVE and
serves the artifact WITH a valid token (200 + reference payload), so the unauthenticated 401 is a
real auth refusal — not a dead route, a 404, or a server that is simply down (the way a vacuous
"refused" check silently passes). Both halves must hold for the lock to be meaningful.

Stdlib-only, OFFLINE, loopback server. Mirrors test_api.py's harness. Run standalone:
    python3 backend/test_reference_auth.py
"""
from __future__ import annotations

import http.client
import json
import os
import tempfile
import threading

os.environ["BLTD_STORE"] = os.path.join(tempfile.mkdtemp(), "t.sqlite3")
os.environ["BLTD_TOKEN"] = "test-token-ref"          # deterministic Bearer for this suite

import bltd_api as A            # noqa: E402 — env must be set before import binds TOKEN/STORE

# This file can run alone or inside the combined pytest process, where another test may already have
# imported bltd_api with its own deterministic token. Use the token bound by the production module so
# the positive control proves the route, not pytest import order.
TOK = A.TOKEN


def _start_server():
    srv = A.Server(("127.0.0.1", 0), A.H)            # ephemeral port
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, port


def _req(port, method, path, *, host=None, token=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    conn.putrequest(method, path, skip_host=(host is not None))
    if host is not None:
        conn.putheader("Host", host)
    if token is not None:
        conn.putheader("Authorization", f"Bearer {token}")
    conn.endheaders()
    resp = conn.getresponse()
    raw = resp.read()
    conn.close()
    try:
        obj = json.loads(raw or b"{}")
    except Exception:  # noqa: BLE001
        obj = {}
    return resp.status, obj


def test_reference_requires_auth_unauthenticated_get_is_refused():
    """REGRESSION: a cold GET with no Bearer token must be refused (401), not served the verdict."""
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        st, body = _req(port, "GET", "/api/reference", host=h)      # no token
        assert st == 401, f"unauthenticated GET /api/reference returned {st}, expected 401 (fail-open regressed)"
        assert body.get("error") == "unauthorized", body
        # It must not have leaked any reference content on the refusal.
        assert "kind" not in body and "engines" not in body, f"refusal leaked reference payload: {body}"
    finally:
        srv.shutdown()


def test_reference_positive_control_authed_get_is_served():
    """POSITIVE CONTROL: the route is live and DOES serve the artifact with a valid token (200).

    Without this, the 401 assertion above could pass against a dead/removed route — a false green.
    """
    srv, port = _start_server()
    try:
        h = f"127.0.0.1:{port}"
        st, body = _req(port, "GET", "/api/reference", host=h, token=TOK)
        assert st == 200, f"authed GET /api/reference returned {st}, expected 200 (route not live?)"
        # A real reference payload (present-artifact) carries kind=reference_oos; an absent artifact
        # carries available:False. Either is a legitimate served body — what matters is that the
        # AUTHED caller is served and the UNAUTHED caller (above) is not.
        assert body.get("kind") == "reference_oos" or body.get("available") is False, body
    finally:
        srv.shutdown()


def test_reference_host_allowlist_before_auth():
    """A foreign Host is rejected (403) before auth is even considered, like every other route."""
    srv, port = _start_server()
    try:
        st, _ = _req(port, "GET", "/api/reference", host="attacker.com", token=TOK)
        assert st == 403, f"foreign-Host GET /api/reference returned {st}, expected 403"
    finally:
        srv.shutdown()


if __name__ == "__main__":
    import sys
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"  ok   {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"  FAIL {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"  ERR  {fn.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(fns) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
