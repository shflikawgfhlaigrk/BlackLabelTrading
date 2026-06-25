"""Black Label Trading — backend data API (SELF-CONTAINED).

The server half of the product. Serves the Trading data over JSON so the sandboxed SwiftUI app
talks to it over the network. It reads the product's OWN local store (a SQLite database the
product owns under ~/Library/Application Support/Black Label Trading) — NOT Michael's Utah
Postgres. The store starts EMPTY; it is filled only by the buyer's own WealthCharts feed
(bltd_capture.py). Every endpoint degrades to an honest JSON payload on a cold store — never a
crash, never a fabricated number.

DECOUPLING: the default store is the own SQLite store (stdlib-only, no Postgres driver, no
utah). The legacy Utah Postgres path is reachable ONLY as an OPT-IN DEV OVERRIDE: set
BLTD_DSN=<postgres dsn> AND have a Postgres driver installed. Without that env, the product is
fully independent of Utah/Postgres.

Endpoints (Bearer token from /auth/signin required on /api/*):
  POST /auth/signin {email,password}      -> {ok, token}
  GET  /api/meta                          -> {online, feedLive, signalsToday}
  GET  /api/symbols                       -> {backtestable, live, liveTicks, busiest}
  GET  /api/bars?symbol=&limit=5000       -> {symbol, bars:[[o,h,l,c,ts_epoch]...]}  (oldest-> for backtest)
  GET  /api/recent?symbol=&limit=90       -> {symbol, bars:[...]}                      (chart history)
  GET  /api/live?symbol=                  -> {symbol, price, ts_epoch} | {gated}
  GET  /api/latest                        -> {fire:{...}|null}
  GET  /api/studies?symbol=&limit=300     -> {symbol, studies:{ema/vwap/rsi/bollinger...}}
  GET  /api/backtest?engine=&symbol=      -> {ok, stats:{...}, curve:[...], reason}
  GET  /api/screen?symbols=&engines=      -> {rows:[{engine,symbol,edge,winRate,netPts...}]}
  GET  /api/fires?limit=&symbol=&engine=  -> {fires:[{...}]}   (the signal journal)
  GET  /api/journal?symbol=&engine=       -> {graded, winRate, netPnl, byEngine}

Trading engine scope is intentionally ES-only. Endpoints that drive live bars, ticks, screen rows,
fires, and engine backtests reject/filter non-ES symbols even if an old local store contains them.

Run:  python3 bltd_api.py 8787
"""
from __future__ import annotations

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import bltd_store
import bltd_analytics

# A real deployment issues per-user tokens; for the local/dev backend any sign-in mints this.
TOKEN = os.environ.get("BLTD_TOKEN", "bl-local-token")

# --- store selection ------------------------------------------------------
# Default: the product's OWN SQLite store. The Utah Postgres DSN is an OPT-IN dev override only:
# it is used iff BLTD_DSN is set AND a Postgres driver is importable. Anything missing falls back
# to the own store, so a buyer machine with no Postgres still runs fully.
USING_PG = False
_DSN = os.environ.get("BLTD_DSN")


def _build_store():
    global USING_PG
    if _DSN:
        try:
            import bltd_pg  # noqa: F401 — thin optional Postgres adapter (dev only)
            store = bltd_pg.PgStore(_DSN)
            USING_PG = True
            return store
        except Exception as exc:  # noqa: BLE001 — no driver / unreachable -> own store
            print(f"BLTD_DSN set but Postgres unavailable ({exc}); using own SQLite store",
                  file=sys.stderr, flush=True)
    return bltd_store.Store(bltd_store.default_store_path())


STORE = _build_store()


# --- Connect handshake ----------------------------------------------------
# The Swift "Connect" screen calls these so the product (not the OS browser) owns the WC login:
#   POST /api/connect  -> launch the product's remote-debug Chrome at the buyer's WC sign-in and
#                         report whether a logged-in WC feed is reachable on the CDP port.
#   GET  /api/capture  -> live capture status (chrome up? WC logged in? feed flowing?) so the UI
#                         reflects REAL capture state, never a fabricated "connected".
def _connect() -> dict:
    """Launch the product-owned debug Chrome on the buyer's WealthCharts sign-in (idempotent),
    then report whether a logged-in WC page is reachable. Honest — never claims connected when
    the buyer hasn't signed in yet."""
    try:
        import bltd_capture as cap
        already = cap.feed_available()
        if not already and not cap.cdp_reachable():
            cap.launch_chrome()
        return {"ok": True, "launched": not already,
                "cdpReachable": cap.cdp_reachable(), "feedAvailable": cap.feed_available(),
                "cdpPort": cap.CDP_PORT}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}


def _capture_status() -> dict:
    """Real capture status for the UI: is the buyer's WC feed reachable on CDP, and is the own
    store currently receiving live ticks?"""
    feed = cdp = False
    try:
        import bltd_capture as cap
        cdp = cap.cdp_reachable()
        feed = cap.feed_available()
    except Exception:  # noqa: BLE001
        pass
    syms = STORE.symbols()
    return {"cdpReachable": cdp, "feedAvailable": feed,
            "liveTicks": syms.get("liveTicks", []), "feedLive": STORE.meta().get("feedLive", False)}


class Server(ThreadingHTTPServer):
    # let a fresh backend re-bind the port immediately after a restart (no TIME_WAIT stall)
    allow_reuse_address = True
    daemon_threads = True


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        b = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        try:
            self.wfile.write(b)
        except BrokenPipeError:
            pass

    def _authed(self) -> bool:
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def do_POST(self):
        u = urlparse(self.path)
        n = int(self.headers.get("Content-Length", 0) or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:  # noqa: BLE001
            body = {}
        if u.path == "/auth/signin":
            if (body.get("email") or "").strip() and (body.get("password") or "").strip():
                return self._send(200, {"ok": True, "token": TOKEN})
            return self._send(401, {"ok": False, "error": "email and password required"})
        if u.path == "/api/config":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            return self._send(200, {"config": STORE.set_config(body if isinstance(body, dict) else {})})
        if u.path == "/api/connect":
            if not self._authed():
                return self._send(401, {"error": "unauthorized"})
            return self._send(200, _connect())
        self._send(404, {"error": "not found"})

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        g = lambda k, d="": (q.get(k, [d])[0] or d)  # noqa: E731
        if u.path == "/health":
            return self._send(200, {"ok": True, "ts": time.time(), "store": "pg" if USING_PG else "own"})
        if not u.path.startswith("/api/"):
            return self._send(404, {"error": "not found"})
        if not self._authed():
            return self._send(401, {"error": "unauthorized"})
        try:
            if u.path == "/api/meta":
                return self._send(200, STORE.meta())
            if u.path == "/api/symbols":
                return self._send(200, STORE.symbols())
            if u.path == "/api/bars":
                return self._send(200, STORE.bars(g("symbol"), int(g("limit", "5000")), newest=False))
            if u.path == "/api/recent":
                return self._send(200, STORE.bars(g("symbol"), int(g("limit", "90")), newest=True))
            if u.path == "/api/live":
                return self._send(200, STORE.live_price(g("symbol")))
            if u.path == "/api/latest":
                return self._send(200, STORE.latest_fire())
            if u.path == "/api/config":
                return self._send(200, {"config": STORE.config()})
            if u.path == "/api/capture":
                return self._send(200, _capture_status())
            if u.path == "/api/studies":
                sym = g("symbol")
                ohlc = STORE.ohlc(sym, int(g("limit", "300")))
                return self._send(200, {"symbol": sym, "studies": bltd_analytics.studies(ohlc, STORE.config())})
            if u.path == "/api/backtest":
                engine = g("engine", "meanrev")
                sym = g("symbol")
                if not bltd_store.is_es_symbol(sym):
                    return self._send(200, {"ok": False, "engine": engine,
                                            "reason": f"unsupported symbol '{sym}' — engines are ES-only",
                                            "stats": bltd_analytics._stats([]), "curve": [], "enoughBars": False})
                ohlc = STORE.ohlc(sym)
                return self._send(200, bltd_analytics.full_backtest(engine, ohlc, STORE.config()))
            if u.path == "/api/screen":
                cfg = STORE.config()
                requested_syms = [s for s in g("symbols").split(",") if s]
                syms = bltd_store.es_symbols(requested_syms) if requested_syms else STORE.symbols().get("backtestable", [])
                engs = [e for e in g("engines").split(",") if e] or cfg.get("engines", [])
                return self._send(200, {"rows": bltd_analytics.screen(STORE, syms, engs, cfg)})
            if u.path == "/api/fires":
                return self._send(200, STORE.fires(int(g("limit", "200")),
                                                   g("symbol") or None, g("engine") or None))
            if u.path == "/api/journal":
                return self._send(200, STORE.journal_stats(g("symbol") or None, g("engine") or None))
        except Exception as exc:  # noqa: BLE001
            return self._send(200, {"error": f"{type(exc).__name__}: {exc}"})
        self._send(404, {"error": "unknown endpoint"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    where = f"Postgres DSN (dev override)" if USING_PG else f"own store {STORE.path}"
    print(f"Black Label Trading API on http://127.0.0.1:{port}/  (data: {where})", flush=True)
    Server(("127.0.0.1", port), H).serve_forever()


if __name__ == "__main__":
    main()
