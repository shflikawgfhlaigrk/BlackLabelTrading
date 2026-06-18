"""Black Label Trading — WealthCharts live capture daemon (SELF-CONTAINED, stdlib-only).

Ports Utah's WC capture *capability* (utah.integrations.wc_feed, read-only reference) into an
equivalent the PRODUCT owns. The BUYER signs into their OWN WealthCharts in a Chrome launched
with remote debugging; this daemon attaches over the Chrome DevTools Protocol, listens to WC's
realtime candle WebSocket, aggregates ticks into closed bars, and writes the buyer's OWN
bars/ticks into the product's OWN SQLite store (bltd_store). It then runs the in-process engines
+ edge gate and records a real fire when an engine proves held-out OOS edge on that symbol.

ZERO third-party deps: the CDP WebSocket client is hand-rolled on the stdlib `socket` + a
minimal RFC6455 implementation, so the product needs no `websockets`/`websocket-client` package.
SIGNALS-ONLY: read-only on the feed (only Network.enable), never sends an order. Never Yahoo.
Never fabricates a price — junk frames are dropped. Gates honestly when WC is unreachable.

Run:  python3 bltd_capture.py
Env:  BLTD_CDP_PORT (default 9223), BLTD_BAR_SECONDS (15), BLTD_LOOKBACK (20),
      BLTD_STORE (own-store path), BLTD_EDGE_GATE (1 to require proven OOS edge before a fire;
      default 1 — never fire blind).
"""
from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import socket
import struct
import time
import urllib.request
from urllib.parse import urlparse

import bltd_store as S

log = logging.getLogger("bltd.capture")

CDP_PORT = int(os.environ.get("BLTD_CDP_PORT", "9223"))
CDP_HOSTS = ("127.0.0.1", "[::1]")
WC_HOST = "wealthcharts.com"   # matches app.wealthcharts.com / www.wealthcharts.com
BAR_SECONDS = int(os.environ.get("BLTD_BAR_SECONDS", "15"))
LOOKBACK = int(os.environ.get("BLTD_LOOKBACK", "20"))
ENGINES = ("meanrev", "breakout", "research")
EDGE_GATE = os.environ.get("BLTD_EDGE_GATE", "1") != "0"
MAX_BARS = 400


# ===========================================================================
# Minimal RFC6455 WebSocket (client side) — stdlib only. PURE framing helpers.
# ===========================================================================
def ws_encode_text(text: str) -> bytes:
    """Encode one masked client text frame (client frames MUST be masked per RFC6455)."""
    payload = text.encode("utf-8")
    n = len(payload)
    header = bytearray([0x81])  # FIN + text opcode
    if n < 126:
        header.append(0x80 | n)
    elif n < (1 << 16):
        header.append(0x80 | 126)
        header += struct.pack(">H", n)
    else:
        header.append(0x80 | 127)
        header += struct.pack(">Q", n)
    mask = os.urandom(4)
    header += mask
    masked = bytes(payload[i] ^ mask[i % 4] for i in range(n))
    return bytes(header) + masked


def ws_parse_frame(buf: bytes):
    """Parse ONE server frame from the front of *buf*.

    Returns (opcode, payload, rest). If the buffer doesn't yet hold a full frame, returns
    (None, None, buf) unchanged so the caller can read more. Server frames are unmasked."""
    if len(buf) < 2:
        return (None, None, buf)
    b0, b1 = buf[0], buf[1]
    opcode = b0 & 0x0F
    masked = b1 & 0x80
    length = b1 & 0x7F
    idx = 2
    if length == 126:
        if len(buf) < 4:
            return (None, None, buf)
        length = struct.unpack(">H", buf[2:4])[0]
        idx = 4
    elif length == 127:
        if len(buf) < 10:
            return (None, None, buf)
        length = struct.unpack(">Q", buf[2:10])[0]
        idx = 10
    mask_key = b""
    if masked:
        if len(buf) < idx + 4:
            return (None, None, buf)
        mask_key = buf[idx:idx + 4]
        idx += 4
    if len(buf) < idx + length:
        return (None, None, buf)
    payload = buf[idx:idx + length]
    if masked:
        payload = bytes(payload[i] ^ mask_key[i % 4] for i in range(length))
    return (opcode, payload, buf[idx + length:])


class WSClient:
    """Hand-rolled CDP WebSocket client over a raw socket. Read-only on the feed."""

    def __init__(self, ws_url: str, timeout: float = 5.0):
        u = urlparse(ws_url)
        self.host = u.hostname or "127.0.0.1"
        self.port = u.port or 80
        self.path = u.path + (("?" + u.query) if u.query else "")
        self.sock = socket.create_connection((self.host, self.port), timeout=timeout)
        self._handshake()
        self.sock.settimeout(2.0)
        self._buf = b""

    def _handshake(self):
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET {self.path} HTTP/1.1\r\nHost: {self.host}:{self.port}\r\n"
               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        resp = b""
        self.sock.settimeout(5.0)
        while b"\r\n\r\n" not in resp:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("CDP handshake closed early")
            resp += chunk
        if b" 101 " not in resp.split(b"\r\n", 1)[0]:
            raise ConnectionError(f"CDP handshake failed: {resp[:80]!r}")
        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        if accept.encode() not in resp:
            raise ConnectionError("CDP handshake: bad Sec-WebSocket-Accept")
        # any extra bytes after the header belong to the frame stream
        self._buf = resp.split(b"\r\n\r\n", 1)[1]

    def send(self, text: str):
        self.sock.sendall(ws_encode_text(text))

    def recv_text(self):
        """Return the next text-frame payload as a str, or None on timeout/no-frame."""
        op, data, rest = ws_parse_frame(self._buf)
        while op is None:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                return None
            if not chunk:
                raise ConnectionError("CDP socket closed")
            self._buf += chunk
            op, data, rest = ws_parse_frame(self._buf)
        self._buf = rest
        if op == 0x8:  # close
            raise ConnectionError("CDP sent close frame")
        if op in (0x9, 0xA):  # ping/pong — ignore
            return ""
        if op in (0x1, 0x2):
            try:
                return data.decode("utf-8", "replace")
            except Exception:  # noqa: BLE001
                return ""
        return ""

    def close(self):
        try:
            self.sock.close()
        except Exception:  # noqa: BLE001
            pass


# ===========================================================================
# CDP target discovery (mirrors wc_feed._cdp_pages / _wc_page).
# ===========================================================================
def cdp_pages():
    for host in CDP_HOSTS:
        try:
            return json.load(urllib.request.urlopen(
                f"http://{host}:{CDP_PORT}/json", timeout=4))
        except Exception as exc:  # noqa: BLE001 — CDP down = feed unavailable, not an error
            log.debug("capture: CDP not reachable on %s:%d (%s)", host, CDP_PORT, exc)
    return None


def pick_wc_page(pages):
    """The logged-in WC dashboard CDP target, or None. PURE (unit-tested)."""
    for p in pages or []:
        url = p.get("url") or ""
        if (WC_HOST in url and p.get("type") == "page" and p.get("webSocketDebuggerUrl")
                and "/login" not in url):
            return p
    return None


def feed_available() -> bool:
    return pick_wc_page(cdp_pages()) is not None


# ===========================================================================
# Chrome lifecycle — the product owns a dedicated remote-debug Chrome profile so the buyer
# logs into THEIR OWN WealthCharts there (ports the intent of wc_feed.ensure_chrome_wc, but
# with a PRODUCT-owned profile under the app-support dir — never ~/.utah, never Michael's data).
# ===========================================================================
CHROME_APP = "/Applications/Google Chrome.app"
CHROME_PROFILE = os.path.expanduser(os.environ.get(
    "BLTD_CHROME_PROFILE", "~/Library/Application Support/Black Label Trading/chrome-wc"))
# Don't let Chrome throttle the (possibly backgrounded) WC feed tab — same reason as Utah.
_NO_THROTTLE = ("--disable-background-timer-throttling",
                "--disable-backgrounding-occluded-windows",
                "--disable-renderer-backgrounding")
_WINDOW = ("--window-position=1100,760", "--window-size=760,520")


def cdp_reachable() -> bool:
    return cdp_pages() is not None


def launch_chrome() -> bool:
    """Open the product's remote-debug Chrome on the WC sign-in page using a dedicated,
    product-owned profile. The buyer logs into THEIR WealthCharts here once; the session
    persists in the product's own profile dir. Never raises."""
    import subprocess
    try:
        os.makedirs(CHROME_PROFILE, exist_ok=True)
        subprocess.Popen(
            ["open", "-g", "-n", "-a", CHROME_APP, "--args",
             f"--remote-debugging-port={CDP_PORT}", "--remote-allow-origins=*",
             f"--user-data-dir={CHROME_PROFILE}", "--no-first-run",
             "--no-default-browser-check", *_NO_THROTTLE, *_WINDOW,
             "https://app.wealthcharts.com/"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception as exc:  # noqa: BLE001
        log.warning("capture: chrome launch failed: %s", exc)
        return False


def ensure_chrome(wait: float = 25.0) -> bool:
    """Bring up a reachable, logged-in WC feed. If nothing answers on the CDP port, launch the
    product's debug Chrome and wait for the buyer to have a live WC page. Returns True only when
    a logged-in WC dashboard is reachable (gates honestly on a logged-out session)."""
    if feed_available():
        return True
    if not cdp_reachable():
        launch_chrome()
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if feed_available():
            return True
        time.sleep(1.5)
    return False


# ===========================================================================
# The capture loop — attach, parse candles, persist bars/ticks, fire on edge.
# ===========================================================================
class Capture:
    """Consumes WC candle frames -> closed bars in the own store -> engine fires (edge-gated)."""

    def __init__(self, store: S.Store, *, bar_seconds=None, lookback=None, edge_gate=None):
        self.store = store
        cfg = store.config()
        # Buyer-tuned config wins; constructor args (tests) override; module defaults last.
        self.bar_seconds = bar_seconds if bar_seconds is not None else cfg.get("barSeconds", BAR_SECONDS)
        self.lookback = lookback if lookback is not None else cfg.get("lookback", LOOKBACK)
        self.edge_gate = edge_gate if edge_gate is not None else cfg.get("edgeGate", EDGE_GATE)
        self.engines = tuple(cfg.get("engines", ENGINES)) or ENGINES
        self.symbol_filter = set(cfg.get("symbols") or [])    # empty = capture all
        self.alert_webhook = cfg.get("alertWebhook", "")
        self.buf = {}                      # symbol -> [(epoch, close), ...] still-forming
        self.last_key = {}                 # symbol -> last persisted bar_key
        self.last_sig = {}                 # (engine, symbol) -> last direction (fire on flip)

    def on_candle(self, cd: dict, arrival: float = None):
        """One parsed candle dict -> live tick + (on bar roll) closed-bar persist + evaluate.

        *arrival* is the wall-clock when this tick reached us (defaults to now). Live ticks
        arrive within ~2s of their stamp, so the skew correction is a no-op live; the param
        lets a deterministic replay treat each tick as arriving at its own stamp (the same
        invariant), instead of all-at-once."""
        ep = S.normalize_epoch(cd["epoch"], time.time() if arrival is None else arrival)
        sym = cd["symbol"]
        if self.symbol_filter and sym not in self.symbol_filter:
            return                                     # buyer's watchlist allow-list (if set)
        close = cd["close"]
        self.store.record_tick(sym, close, ep)        # live price marker (always)
        self.buf.setdefault(sym, []).append((ep, close))
        key = ep // self.bar_seconds
        prev = self.last_key.get(sym)
        if prev is not None and key > prev:
            self._roll(sym)
        self.last_key[sym] = max(key, self.last_key.get(sym, key))

    def _roll(self, sym: str):
        ticks = self.buf.get(sym, [])
        bars = S.ohlc_bars(ticks, self.bar_seconds)    # closed buckets only
        if bars:
            rows = [((k + 1) * self.bar_seconds, o, h, l, c) for (k, o, h, l, c) in bars]
            self.store.record_bars(sym, rows)
            last_closed = bars[-1][0]
            # keep only ticks of the still-forming bucket (bound memory)
            self.buf[sym] = [(e, c) for (e, c) in ticks if e // self.bar_seconds > last_closed]
            self._evaluate(sym)

    def _evaluate(self, sym: str):
        ohlc = self.store.ohlc(sym)
        if len(ohlc) < self.lookback + 1:
            return
        for eng in self.engines:
            sig = self._signal(eng, ohlc)
            prev = self.last_sig.get((eng, sym))
            self.last_sig[(eng, sym)] = sig["direction"] if sig else None
            if not sig or not sig["direction"] or sig["direction"] == prev:
                continue   # fire only on appear/flip, never on every extended bar
            if self.edge_gate:
                verdict = self.store.edge_ok(eng, sym)
                if not verdict.get("ok"):
                    log.info("suppressed %s %s %s (no edge: %s)", eng, sym,
                             sig["direction"], verdict.get("reason", ""))
                    continue
            self.store.record_fire(eng, sig["direction"], entry=ohlc[-1][3], symbol=sym,
                                   stop=sig.get("stop"), target=sig.get("target"),
                                   rationale=sig.get("rationale"), synthetic=False)
            log.info("FIRE %s %s %s @ %.4f", eng, sym, sig["direction"], ohlc[-1][3])
            self._alert(eng, sym, sig, ohlc[-1][3])

    def _alert(self, engine, symbol, sig, entry):
        """Mirror a real fire out to the buyer's configured alert channel (webhook). Best-effort,
        signals-only — never blocks capture, never raises, never executes anything."""
        url = self.alert_webhook
        if not url:
            return
        try:
            payload = json.dumps({
                "content": f"Black Label signal: {engine} {sig['direction'].upper()} {symbol} @ {entry:.4f}"
                           f" — stop {sig.get('stop')}, target {sig.get('target')}. {sig.get('rationale','')}",
                "engine": engine, "symbol": symbol, "direction": sig["direction"],
                "entry": entry, "stop": sig.get("stop"), "target": sig.get("target"),
            }).encode()
            req = urllib.request.Request(url, data=payload,
                                         headers={"Content-Type": "application/json"}, method="POST")
            urllib.request.urlopen(req, timeout=4).read()
        except Exception as exc:  # noqa: BLE001 — alerting is best-effort
            log.info("alert webhook failed: %s", exc)

    def _signal(self, engine: str, ohlc):
        """Current live signal for *engine* on the latest bar — same geometry the gate proves."""
        closes = [b[3] for b in ohlc]
        if engine == "meanrev":
            prior = closes[-self.lookback - 1:-1]
            if len(prior) < self.lookback:
                return None
            mean = sum(prior) / self.lookback
            var = sum((x - mean) ** 2 for x in prior) / self.lookback
            if var <= 0:
                return None
            sd = var ** 0.5
            entry = closes[-1]
            z = (entry - mean) / sd
            if z <= -S.MR_Z:
                return {"direction": "long", "stop": entry - S.MR_STOP_MULT * sd,
                        "target": entry + S.MR_TGT_FRAC * (mean - entry),
                        "rationale": f"z={z:.2f} <= -{S.MR_Z}: revert up to mean"}
            if z >= S.MR_Z:
                return {"direction": "short", "stop": entry + S.MR_STOP_MULT * sd,
                        "target": entry - S.MR_TGT_FRAC * (entry - mean),
                        "rationale": f"z={z:.2f} >= {S.MR_Z}: revert down to mean"}
            return None
        # breakout / research are momentum-directional on the lookback range
        prior = closes[-self.lookback - 1:-1]
        if len(prior) < self.lookback:
            return None
        last = closes[-1]
        if last > max(prior):
            return {"direction": "long", "stop": min(prior),
                    "rationale": f"close {last:.4f} > {self.lookback}-bar high {max(prior):.4f}"}
        if last < min(prior):
            return {"direction": "short", "stop": max(prior),
                    "rationale": f"close {last:.4f} < {self.lookback}-bar low {min(prior):.4f}"}
        return None


def stream_once(store: S.Store, *, max_seconds: float = None) -> dict:
    """Attach to the live WC feed and capture until the connection drops (or *max_seconds*).
    Returns a summary. Never raises — a dropped hook just returns."""
    page = pick_wc_page(cdp_pages())
    if not page:
        return {"available": False, "reason": "no logged-in WC page on CDP"}
    cap = Capture(store)
    ws = None
    frames = candles = 0
    t0 = time.monotonic()
    try:
        ws = WSClient(page["webSocketDebuggerUrl"])
        ws.send(json.dumps({"id": 1, "method": "Network.enable"}))
        while True:
            if max_seconds is not None and time.monotonic() - t0 >= max_seconds:
                break
            raw = ws.recv_text()
            if not raw:
                continue
            frames += 1
            cd = _frame_candle(raw)
            if cd:
                candles += 1
                cap.on_candle(cd)
    except Exception as exc:  # noqa: BLE001 — hook dropped / chrome closed
        log.info("capture: hook ended (%s)", exc)
    finally:
        if ws:
            ws.close()
    return {"available": True, "frames": frames, "candles": candles,
            "symbols": list(cap.last_key.keys())}


def _frame_candle(raw: str):
    """One CDP envelope string -> candle dict or None (Network.webSocketFrameReceived). PURE."""
    try:
        m = json.loads(raw)
    except (TypeError, ValueError):
        return None
    if not isinstance(m, dict) or m.get("method") != "Network.webSocketFrameReceived":
        return None
    params = m.get("params")
    if not isinstance(params, dict):
        return None
    response = params.get("response")
    if not isinstance(response, dict):
        return None
    payload = response.get("payloadData")
    if not isinstance(payload, str):
        return None
    return S.parse_candle(payload)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    store = S.Store(S.default_store_path())
    log.info("capture: own store at %s; CDP :%d; edge_gate=%s", store.path, CDP_PORT, EDGE_GATE)
    while True:
        if not ensure_chrome():
            log.info("capture: WC not reachable on CDP :%d — the product's debug Chrome is "
                     "open; sign into YOUR WealthCharts there (gated, never faked)", CDP_PORT)
            time.sleep(5)
            continue
        r = stream_once(store)
        log.info("capture: %s", r)
        time.sleep(2)


if __name__ == "__main__":
    main()
