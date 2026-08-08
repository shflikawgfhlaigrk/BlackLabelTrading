"""Black Label Trading — browser live capture daemon (SELF-CONTAINED, stdlib-only).

Ports the proven browser-capture capability into an equivalent the PRODUCT owns. The BUYER signs
into their OWN TopstepX or WealthCharts session in a Chrome launched with remote debugging; this
daemon attaches over the Chrome DevTools Protocol, listens to realtime candle WebSocket frames,
aggregates ticks into closed bars, and writes the buyer's OWN
bars/ticks into the product's OWN SQLite store (bltd_store). It then runs the in-process engines
+ edge gate and records a real fire when an engine proves held-out OOS edge on that symbol.

ZERO third-party deps: the CDP WebSocket client is hand-rolled on the stdlib `socket` + a
minimal RFC6455 implementation, so the product needs no `websockets`/`websocket-client` package.
CAPTURE is read-only on the feed (only Network.enable); it has no broker-order path. Never Yahoo.
Never fabricates a price — junk frames are dropped. Gates honestly when the feed is unreachable.

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
import threading
import time
import urllib.request
from urllib.parse import quote, urlparse

import bltd_store as S
import bltd_parsers as P
import bltd_paths      # cross-platform app-support / profile paths (macOS gold master + Windows W1)
import bltd_browser    # cross-platform Chromium-family resolution + remote-debug launch

log = logging.getLogger("bltd.capture")

CDP_PORT = int(os.environ.get("BLTD_CDP_PORT", "9223"))
CDP_HOSTS = ("127.0.0.1", "[::1]")
WC_HOST = "wealthcharts.com"   # matches app.wealthcharts.com / www.wealthcharts.com
BAR_SECONDS = int(os.environ.get("BLTD_BAR_SECONDS", "15"))
LOOKBACK = int(os.environ.get("BLTD_LOOKBACK", "20"))
ENGINES = S.ACTIVE_ENGINE_FAMILY
EDGE_GATE = os.environ.get("BLTD_EDGE_GATE", "1") != "0"
MAX_BARS = 400
# Stall watchdog: WC streams candles continuously while a chart is open (a flat market still
# prints repeat candles), so NO candle for this many seconds means the attached hook went silently
# dead (WC's realtime socket churned / the page navigated and reset our Network domain) — NOT a
# quiet market. When that happens stream_once returns so main() re-hooks on a FRESH attach, which
# resumes candles immediately. Keeps the chart LIVE while connected instead of stalling at "quiet".
STALL_SECONDS = float(os.environ.get("BLTD_STALL_SECONDS", "45"))


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

    def recv_text(self, max_wait: float = 3.0):
        """Return the next text-frame payload as a str, or None on timeout/no-frame.

        Bounded by *max_wait*: if a full frame can't be assembled within that window (a half-dead
        CDP socket that trickles bytes but never completes a frame — the exact wedge that could
        freeze capture for hours), give up and return None so the caller's loop keeps iterating and
        its stall watchdog can re-hook. Without this bound the inner recv loop spins forever while
        the socket keeps returning partial data (so it never raises socket.timeout), blocking the
        whole capture loop invisibly to the stall check at the top of stream_once."""
        op, data, rest = ws_parse_frame(self._buf)
        deadline = time.monotonic() + max_wait
        while op is None:
            if time.monotonic() > deadline:
                return None
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
# Browser-source auto-inject: discover logged-in trading-platform tabs in the product Chrome and
# scrape them through the parser registry. TopstepX remains the default setup, but WealthCharts is
# a first-class source too: the app opens it on request, the buyer signs into their own session,
# and observed chart data lands in the same local store/webhook path.
# ===========================================================================
BROWSER_SOURCES = {
    "topstepx": {
        "label": "TopStepX",
        "hosts": ("topstepx.com", "topstepx"),
        "login_url": "https://www.topstepx.com/",
    },
    "wealthcharts": {
        "label": "WealthCharts",
        "hosts": ("wealthcharts.com",),
        "login_url": "https://app.wealthcharts.com/",
    },
}
DEFAULT_BROWSER_SOURCE = "topstepx"


def normalize_browser_source(source=None) -> str:
    key = (source or DEFAULT_BROWSER_SOURCE).strip().lower()
    if key in ("browser", "platform"):
        return DEFAULT_BROWSER_SOURCE
    return key if key in BROWSER_SOURCES else DEFAULT_BROWSER_SOURCE


def _source_for_url(url: str):
    low = (url or "").lower()
    for key, spec in BROWSER_SOURCES.items():
        if any(host in low for host in spec["hosts"]):
            return key
    return None


def _login_url_for(source=None) -> str:
    return BROWSER_SOURCES[normalize_browser_source(source)]["login_url"]


def discover_feed_pages(source=None):
    """Logged-in supported browser-source tabs on the CDP port, as [(name, page), ...]. Counts a
    tab only when it's a real page with a debugger socket and isn't a login/signin page."""
    wanted = None if source in (None, "", "all") else normalize_browser_source(source)
    out, pages = [], (cdp_pages() or [])
    for p in pages:
        url = (p.get("url") or "")
        low = url.lower()
        key = _source_for_url(url)
        if (p.get("type") == "page" and p.get("webSocketDebuggerUrl")
                and "/login" not in low and "signin" not in low
                and key and (wanted is None or key == wanted)):
            out.append((key, p))
    return out


def feeds_available() -> bool:
    return bool(discover_feed_pages())


def watchdog_feed_available() -> bool:
    """Feed reachability for the self-heal watchdog: any logged-in trading tab, not WC-only."""
    return feeds_available()


# ===========================================================================
# Chrome lifecycle — the product owns a dedicated remote-debug Chrome profile so the buyer
# logs into THEIR OWN supported browser source there, with a PRODUCT-owned profile under the
# app-support dir.
# ===========================================================================
# Browser capture needs a Chromium-family browser exposing --remote-debugging-port. Google Chrome is
# the reference, but Chromium/Brave/Edge all speak the SAME CDP, so the buyer is NOT hard-blocked on a
# single vendor — resolve the first one actually installed. If NONE is present we never pretend a
# launch succeeded; we write an honest prerequisite sentinel the app surfaces (RC4 — no silent block).
# Cross-platform browser resolution lives in bltd_browser (macOS `.app` bundles + Windows/Linux
# executables, same CDP). Kept here as thin delegates so every existing caller and the daemon's
# behavior on darwin are unchanged, while the Windows W1 port reuses the identical connect flow.
_CHROME_CANDIDATES = bltd_browser._MAC_CANDIDATES


def resolve_chrome() -> str | None:
    """The first installed Chromium-family browser (env override wins). None if nothing is installed."""
    return bltd_browser.resolve_browser()


def chrome_present() -> bool:
    return bltd_browser.browser_present()


def _support_dir() -> str:
    return bltd_paths.app_support_dir()


def write_chrome_prereq() -> None:
    """Honest sentinel: browser capture needs a Chromium browser and none is installed. The app reads
    this and guides the buyer instead of looping 'no logged-in feed' forever. Never fabricates a feed."""
    try:
        os.makedirs(_support_dir(), exist_ok=True)
        with open(os.path.join(_support_dir(), "prereq.json"), "w") as fh:
            json.dump({"ok": False,
                       "reason": "Google Chrome is required for browser capture.",
                       "fix": "",
                       "detail": "Black Label Trading reads the live data feeding your platform's "
                                 "charts through a Chromium browser. Install Google Chrome (or "
                                 "Chromium, Brave, or Edge), then reopen and connect your platform.",
                       "ts": int(time.time())}, fh)
    except Exception as exc:  # noqa: BLE001
        log.warning("capture: could not write chrome prereq: %s", exc)


# Backwards-compatible module constant (messaging / default path). Launch functions re-resolve at
# call time so a browser installed after startup is picked up without forcing a daemon restart.
CHROME_APP = resolve_chrome() or _CHROME_CANDIDATES[0]
CHROME_PROFILE = bltd_paths.chrome_profile_dir()
# Don't let Chrome throttle the (possibly backgrounded) WC feed tab — same reason as Utah.
_NO_THROTTLE = ("--disable-background-timer-throttling",
                "--disable-backgrounding-occluded-windows",
                "--disable-renderer-backgrounding")
_WINDOW = ("--window-position=1100,760", "--window-size=760,520")


def cdp_reachable() -> bool:
    return cdp_pages() is not None


def launch_chrome(source=None) -> bool:
    """Open the product's remote-debug Chrome on a supported browser source using a dedicated,
    product-owned profile. The buyer logs into THEIR platform here once; the session
    persists in the product's own profile dir. Never raises."""
    chrome = resolve_chrome()
    if not chrome:
        write_chrome_prereq()
        log.warning("capture: no Chromium browser installed — wrote prereq, cannot launch")
        return False
    try:
        os.makedirs(CHROME_PROFILE, exist_ok=True)
        # The loopback-pinned CDP flag set (incl. the known "--remote-allow-origins=*" residual)
        # lives in bltd_browser so it is identical on macOS and the Windows port.
        return bltd_browser.launch_debug_browser(
            chrome, CDP_PORT, CHROME_PROFILE, [_login_url_for(source)],
            extra_args=(*_NO_THROTTLE, *_WINDOW))
    except Exception as exc:  # noqa: BLE001
        log.warning("capture: chrome launch failed: %s", exc)
        return False


def ensure_chrome(wait: float = 25.0) -> bool:
    """Bring up a reachable, logged-in WealthCharts feed for the legacy stream_once path. If nothing
    answers on the CDP port, launch the product's debug Chrome and wait for the buyer to have a live
    WealthCharts page. Returns True only when a logged-in feed page is reachable."""
    if feed_available():
        return True
    if not cdp_reachable():
        launch_chrome("wealthcharts")
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if feed_available():
            return True
        time.sleep(1.5)
    return False


# Default browser-source sign-in page the daemon auto-opens when it must launch Chrome cold.
FEED_LOGIN_URLS = (
    BROWSER_SOURCES[DEFAULT_BROWSER_SOURCE]["login_url"],
)
TOPSTEP_OPEN_DEBOUNCE_SECONDS = float(os.environ.get("BLTD_TOPSTEP_OPEN_DEBOUNCE_SECONDS", "90"))


def _browser_open_sentinel(source=None) -> str:
    return os.path.join(_support_dir(), f"{normalize_browser_source(source)}-opened.json")


def _mark_browser_opened(source=None) -> None:
    try:
        os.makedirs(_support_dir(), exist_ok=True)
        with open(_browser_open_sentinel(source), "w") as fh:
            json.dump({"source": normalize_browser_source(source), "ts": time.time()}, fh)
    except Exception as exc:  # noqa: BLE001
        log.debug("capture: could not mark browser open sentinel (%s)", exc)


def _browser_opened_recently(source=None, seconds: float = TOPSTEP_OPEN_DEBOUNCE_SECONDS) -> bool:
    try:
        with open(_browser_open_sentinel(source)) as fh:
            ts = float((json.load(fh) or {}).get("ts", 0))
        return (time.time() - ts) < seconds
    except Exception:  # noqa: BLE001
        return False


def _topstep_open_sentinel() -> str:
    return _browser_open_sentinel("topstepx")


def _mark_topstep_opened() -> None:
    _mark_browser_opened("topstepx")


def _topstep_opened_recently(seconds: float = TOPSTEP_OPEN_DEBOUNCE_SECONDS) -> bool:
    return _browser_opened_recently("topstepx", seconds)


def topstep_tab_present() -> bool:
    """Any TopstepX tab in the product Chrome, including login/loading pages."""
    return browser_tab_present("topstepx")


def browser_tab_present(source=None) -> bool:
    """Any requested browser-source tab in the product Chrome, including login/loading pages."""
    wanted = normalize_browser_source(source)
    for p in cdp_pages() or []:
        url = (p.get("url") or "").lower()
        key = _source_for_url(url)
        if p.get("type") == "page" and p.get("webSocketDebuggerUrl") and key == wanted:
            return True
    return False


def _launch_chrome_multi(source=None) -> bool:
    """Open the product's remote-debug Chrome to the requested browser source. Only used when Chrome is cold —
    never piles tabs onto a running Chrome. Never raises."""
    chrome = resolve_chrome()
    if not chrome:
        write_chrome_prereq()
        log.warning("capture: no Chromium browser installed — wrote prereq, cannot launch")
        return False
    try:
        os.makedirs(CHROME_PROFILE, exist_ok=True)
        ok = bltd_browser.launch_debug_browser(
            chrome, CDP_PORT, CHROME_PROFILE, [_login_url_for(source)],
            extra_args=(*_NO_THROTTLE,))
        if ok:
            _mark_browser_opened(source)
        return ok
    except Exception as exc:  # noqa: BLE001
        log.warning("capture: chrome launch failed: %s", exc)
        return False


def open_feed_login_tabs(source=None) -> bool:
    """Open the requested browser-source login tab in the product-owned debug Chrome.

    If the debug Chrome is already reachable, use the DevTools /json/new endpoint so the tabs open
    inside the same remote-debug profile the capture daemon reads. If Chrome is cold, launch it with
    the full login set. Never raises."""
    source = normalize_browser_source(source)
    if browser_tab_present(source) or _browser_opened_recently(source):
        return True
    if cdp_reachable():
        url = _login_url_for(source)
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{CDP_PORT}/json/new?{quote(url, safe=':/?&=%')}",
                method="PUT")
            urllib.request.urlopen(req, timeout=2).read()
            _mark_browser_opened(source)
            return True
        except Exception as exc:  # noqa: BLE001
            log.debug("capture: CDP open-tab failed for %s (%s)", url, exc)
    return _launch_chrome_multi(source)


def ensure_feeds(wait: float = 25.0) -> bool:
    """Bring up Chrome + at least one logged-in browser feed tab, NO manual scraper setup. Honest:
    returns False (gated) while logged out — the debug Chrome sits open at the sign-in pages."""
    if discover_feed_pages():
        return True
    open_feed_login_tabs()
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if discover_feed_pages():
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
        self._bar_seconds_override = bar_seconds
        self._lookback_override = lookback
        self._edge_gate_override = edge_gate
        self.bar_seconds = bar_seconds if bar_seconds is not None else cfg.get("barSeconds", BAR_SECONDS)
        self.lookback = lookback if lookback is not None else cfg.get("lookback", LOOKBACK)
        self.edge_gate = edge_gate if edge_gate is not None else cfg.get("edgeGate", EDGE_GATE)
        self.engines = tuple(cfg.get("engines", ENGINES)) or ENGINES
        self.symbol_filter = {"ES"}          # legacy attr (unused); scope now via S.in_scope
        self.alert_webhook = cfg.get("alertWebhook", "")
        self.buf = {}                      # symbol -> [(epoch, close), ...] still-forming
        self.last_key = {}                 # symbol -> last persisted bar_key
        self.last_sig = {}                 # (engine, symbol) -> last direction (fire on flip)
        self.last_evaluated_bar = {}       # symbol -> newest closed bar already evaluated this process
        # symbol -> (preceding closed-bar ts, first observed price of the new forming bar). Set only
        # on a bucket transition this process witnessed, so a mid-bar daemon restart never labels
        # an arbitrary later tick as the open.
        self.next_bar_open = {}
        # In-memory write buffers. The frame read loop touches ONLY these (pure memory, as fast as
        # a bare reader); a separate flusher thread (see _flusher_loop) batches them into SQLite
        # every ~0.3s. Doing a SQLite write per candle in the read loop (a fresh connection each)
        # backed the live WC stream up and wedged capture after ~75s — keeping ALL I/O off the read
        # loop is the no-wedge core. Volume/delta ride with the same in-memory bar rows when the
        # browser source supplies them; legacy close-only frames still persist as zero-volume bars.
        self.latest = {}                   # symbol -> (close, epoch)  latest tick, coalesced
        self.last_close = {}               # symbol -> last observed tick close for tick-rule delta
        self.pending_bars = {}             # symbol -> [(ts,o,h,l,c,volume,delta), ...]

    def on_candle(self, cd: dict, arrival: float = None):
        """One parsed candle dict -> live tick + (on bar roll) closed-bar persist + evaluate.

        *arrival* is the wall-clock when this tick reached us (defaults to now). Live ticks
        arrive within ~2s of their stamp, so the skew correction is a no-op live; the param
        lets a deterministic replay treat each tick as arriving at its own stamp (the same
        invariant), instead of all-at-once.

        Some WC tick frames (the `cts` shape) carry NO real epoch (parse_candle returns
        epoch=None). Those are live ticks arriving right now, so their honest timestamp IS the
        arrival wall-clock — we stamp them with arrival directly rather than fabricating one."""
        now = time.time() if arrival is None else arrival
        ep = int(now) if cd.get("epoch") is None else S.normalize_epoch(cd["epoch"], now)
        sym = cd["symbol"]
        if not S.in_scope(sym):
            return                                     # accept any in-scope instrument the buyer streams
        close = cd["close"]
        vol = float(cd.get("volume") or 0.0)
        dlt = float(cd.get("delta") or 0.0)
        prev_close = self.last_close.get(sym)
        if vol > 0 and dlt == 0.0 and prev_close is not None and close != prev_close:
            dlt = vol if close > prev_close else -vol
        self.last_close[sym] = close
        self.latest[sym] = (close, ep)                # in-memory latest tick (flusher persists it)
        self.buf.setdefault(sym, []).append((ep, close, vol, dlt))
        key = ep // self.bar_seconds
        prev = self.last_key.get(sym)
        if prev is not None and key > prev:
            self._roll(sym)
            self.next_bar_open[sym] = (key * self.bar_seconds, float(close))
        self.last_key[sym] = max(key, self.last_key.get(sym, key))

    def _roll(self, sym: str):
        ticks = self.buf.get(sym, [])
        bars = S.ohlcv_bars(ticks, self.bar_seconds)   # closed buckets only
        if bars:
            rows = [((k + 1) * self.bar_seconds, o, h, l, c, v, d)
                    for (k, o, h, l, c, v, d) in bars]
            self.pending_bars.setdefault(sym, []).extend(rows)   # queue; flusher persists (no I/O here)
            last_closed = bars[-1][0]
            # keep only ticks of the still-forming bucket (bound memory)
            self.buf[sym] = [t for t in ticks if t[0] // self.bar_seconds > last_closed]
            # NOTE: engine evaluation is deliberately NOT run here. Running the roster's edge-gate
            # OOS backtests inline on every bar roll blocked the read loop long enough that the live
            # WC frame stream backed up and capture wedged after ~75s (the WS itself stays live for
            # hours). Evaluation now runs on the _evaluator_loop thread (evaluate_all), reading
            # closed bars back from the store, so the read loop only does fast in-memory buffering.

    def flush(self):
        """Persist the in-memory write buffers to the store. Runs on the flusher thread, never in
        the read loop. Coalesces ticks (one write per symbol regardless of how many candles arrived)
        and batches the queued closed bars, so SQLite I/O is a few writes/sec, not per-candle.

        Bars are unique by ts, so on a batch write failure (record_bars_batch returns -1) they are
        RE-QUEUED to retry — never silently dropped. Ticks are self-healing: a failed batch just
        isn't persisted this round; the next candle re-fills self.latest and the next flush retries."""
        latest = dict(self.latest)                 # copy (don't race on_candle's writes)
        pend = self.pending_bars
        self.pending_bars = {}                     # swap out queued bars (single rebind, GIL-atomic)
        if latest:
            self.store.record_ticks_batch([(s, c, e) for s, (c, e) in latest.items()])
        if pend and self.store.record_bars_batch(pend) < 0:
            for sym, rows in pend.items():
                self.pending_bars.setdefault(sym, [])[:0] = rows

    def evaluate_all(self):
        """Evaluate every active symbol's engines from the STORE's closed bars. Runs on the
        _evaluator_loop thread, decoupled from frame ingestion, so the heavy edge-gate work can
        never stall live capture. Symbols come from the store, not the read loop, so this path
        shares no mutable frame state with on_candle."""
        cfg = self.store.config()
        # Settings are buyer-tunable at runtime. Reload the evaluator contract each cycle unless a
        # test/embedding explicitly supplied a constructor override.
        if self._lookback_override is None:
            self.lookback = cfg.get("lookback", LOOKBACK)
        if self._edge_gate_override is None:
            self.edge_gate = cfg.get("edgeGate", EDGE_GATE)
        self.engines = tuple(cfg.get("engines", ENGINES)) or ENGINES
        self.alert_webhook = cfg.get("alertWebhook", "")
        syms = self.store.symbols()
        # Backtestable is a research catalog, NOT evidence that a symbol is currently producing.
        # Unioning it here made every historical contract re-evaluate forever and allowed a stale
        # endpoint to fire after each daemon restart. A fresh CLOSED bar is the live-fire floor.
        active = set(syms.get("live", []))
        if not active:
            return
        latest_by_symbol = {sym: self.store.latest_bar_ts(sym) for sym in active}
        changed = {
            sym for sym, latest in latest_by_symbol.items()
            if latest is not None and self.last_evaluated_bar.get(sym) != latest
        }
        # The evaluator wakes every eight seconds for liveness, while default bars close every
        # fifteen. Do no research work when the immutable closed-bar endpoint is unchanged.
        if not changed:
            return
        gate_rows = None
        if self.edge_gate:
            try:
                import bltd_analytics
                family_symbols = list(syms.get("backtestable", []))
                rows = bltd_analytics.screen(
                    self.store, family_symbols, list(self.engines), cfg)
                gate_rows = {(r.get("engine"), r.get("symbol")): r for r in rows}
            except Exception as exc:  # noqa: BLE001 — family gate failure pauses every live fire
                log.info("evaluate_all: family-wide edge gate unavailable: %s", exc)
                gate_rows = {}
        for sym in changed:
            try:
                self.store.grade_open_fires(sym)
                self._evaluate(sym, gate_rows=gate_rows)
                self.last_evaluated_bar[sym] = latest_by_symbol[sym]
            except Exception as exc:  # noqa: BLE001 — one symbol's failure must not stop the rest
                log.info("evaluate_all: %s failed: %s", sym, exc)

    def _evaluate(self, sym: str, gate_rows=None):
        # A signal is knowable only at a CLOSED bar, while its causal entry is the NEXT bar's
        # observable open. When this capture process witnessed the bucket transition, evaluate the
        # newest closed row immediately against that first forming-bar tick. A cold/restarted
        # process never invents an open from a mid-bar tick; once the bar closes, its stored OHLC
        # supports the same causal catch-up using penultimate signal + newest entry row.
        timestamped = self.store.ohlc_between_timestamped(
            sym, limit=S.LIVE_ENGINE_BARS)
        if len(timestamped) < self.lookback + 1:
            return
        latest_ts = int(timestamped[-1][4])
        observed = self.next_bar_open.get(sym)
        if observed and int(observed[0]) == latest_ts:
            signal_rows = timestamped
            entry_open = float(observed[1])
        else:
            if len(timestamped) < self.lookback + 2:
                return
            signal_rows = timestamped[:-1]
            entry_open = float(timestamped[-1][0])
        signal_ohlc = [row[:4] for row in signal_rows]
        signal_bar_ts = int(signal_rows[-1][4])
        cfg = self.store.config()
        tick_size = S._research_tick_size(cfg)
        if tick_size is None:
            return
        for eng in self.engines:
            sig = self._signal(eng, signal_ohlc, entry_open=entry_open)
            direction = sig.get("direction") if sig else None
            prev = self.last_sig.get((eng, sym))
            self.last_sig[(eng, sym)] = direction
            edge_ok = True
            verdict = None
            if self.edge_gate:
                if gate_rows is None:
                    verdict = self.store.edge_ok(eng, sym)
                    edge_ok = bool(verdict.get("ok"))
                else:
                    verdict = gate_rows.get((eng, sym))
                    edge_ok = bool(verdict and verdict.get("edge"))
                if direction and not edge_ok and direction != prev:
                    log.info("suppressed %s %s %s (no edge: %s)", eng, sym,
                             direction, (verdict or {}).get("reason", ""))
            inserted = self.store.record_signal_evaluation(
                eng, sym, direction, edge_ok, signal_bar_ts,
                entry=(sig.get("entry") if sig and direction else None),
                stop=(sig.get("stop") if sig else None),
                target=(sig.get("target") if sig else None),
                rationale=(sig.get("rationale") if sig else None),
                max_hold=(S._breakout_max_hold(cfg)
                          if eng in ("breakout", "research") else S.MR_MAX_HOLD),
                tick_size=tick_size)
            if inserted <= 0:
                continue
            entry = sig["entry"]
            log.info("FIRE %s %s %s @ %.4f", eng, sym, direction, entry)
            self._alert(eng, sym, sig, entry)
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

    # Live-fire signal functions for the consensus-family engines (same geometry their gate proves).
    # meanrev + breakout/research stay inline below; everything else dispatches here so the live
    # signal matches the prover exactly (no drift between what fires and what backtested).
    _SIG = {
        "momentum": S._momentum_signal, "structure": S._structure_signal,
        "regime": S._regime_signal, "channel": S._channel_signal,
        "context_a": S._context_a_signal, "context_b": S._context_b_signal,
    }

    def _signal(self, engine: str, ohlc, entry_open=None):
        """Signal on ``ohlc[-1]`` with optional causal next-bar-open geometry.

        Without ``entry_open`` this retains the narrow signal-inspection behavior used by the UI
        tests. Production passes the next observable open, matching every canonical prover: entry
        is adversely rounded first, then stop/target orders are rounded conservatively and fixed
        around that entry.
        """
        cfg = self.store.config()
        closes = [b[3] for b in ohlc]

        def causal_geometry(direction, raw_entry, stop, target, rationale):
            tick_size = S._research_tick_size(cfg)
            if tick_size is None:
                return None
            entry = S._round_fill(raw_entry, direction, tick_size, is_entry=True)
            order_stop = S._round_order_level(stop, direction, "stop", tick_size)
            order_target = S._round_order_level(target, direction, "target", tick_size)
            if entry is None or order_stop is None or order_target is None:
                return None
            if direction == "long":
                valid = order_stop <= entry < order_target
            else:
                valid = order_target < entry <= order_stop
            if not valid:
                return None
            return {"direction": direction, "entry": entry, "stop": order_stop,
                    "target": order_target, "rationale": rationale}

        if engine == "meanrev":
            prior = closes[-self.lookback - 1:-1]
            if len(prior) < self.lookback:
                return None
            mean = sum(prior) / self.lookback
            var = sum((x - mean) ** 2 for x in prior) / self.lookback
            if var <= 0:
                return None
            sd = var ** 0.5
            signal_close = closes[-1]
            z = (signal_close - mean) / sd
            z_enter = cfg.get("mrZ", S.MR_Z)
            stop_mult = cfg.get("mrStopMult", S.MR_STOP_MULT)
            target_frac = cfg.get("mrTgtFrac", S.MR_TGT_FRAC)
            if z <= -z_enter:
                rationale = f"z={z:.2f} <= -{z_enter}: revert up to mean"
                if entry_open is None:
                    return {"direction": "long", "stop": signal_close - stop_mult * sd,
                            "target": signal_close + target_frac * (mean - signal_close),
                            "rationale": rationale}
                entry = S._round_fill(entry_open, "long", S._research_tick_size(cfg),
                                      is_entry=True)
                if entry is None:
                    return None
                return causal_geometry(
                    "long", entry, entry - stop_mult * sd,
                    entry + target_frac * (mean - entry), rationale)
            if z >= z_enter:
                rationale = f"z={z:.2f} >= {z_enter}: revert down to mean"
                if entry_open is None:
                    return {"direction": "short", "stop": signal_close + stop_mult * sd,
                            "target": signal_close - target_frac * (signal_close - mean),
                            "rationale": rationale}
                entry = S._round_fill(entry_open, "short", S._research_tick_size(cfg),
                                      is_entry=True)
                if entry is None:
                    return None
                return causal_geometry(
                    "short", entry, entry + stop_mult * sd,
                    entry - target_frac * (entry - mean), rationale)
            return None
        fn = self._SIG.get(engine)
        if fn:
            sig = fn(closes, ohlc, self.lookback, cfg)
            if not sig or entry_open is None:
                return sig
            direction = sig.get("direction")
            entry = S._round_fill(entry_open, direction, S._research_tick_size(cfg),
                                  is_entry=True)
            if entry is None:
                return None
            stop, target = S._atr_stop_target(
                ohlc, entry, direction, S.MO_ATR_MULT, S.MO_TARGET_R)
            return causal_geometry(
                direction, entry, stop, target, sig.get("rationale", ""))
        # breakout / research are momentum-directional on the lookback range
        prior = closes[-self.lookback - 1:-1]
        if len(prior) < self.lookback:
            return None
        last = closes[-1]
        if last > max(prior):
            stop = min(prior)
            if entry_open is None:
                target = last + cfg.get("bkTargetR", S.BK_TARGET_R) * (last - stop)
                return {"direction": "long", "stop": stop, "target": target,
                        "rationale": f"close {last:.4f} > {self.lookback}-bar high {max(prior):.4f}"}
            entry = S._round_fill(entry_open, "long", S._research_tick_size(cfg),
                                  is_entry=True)
            order_stop = S._round_order_level(
                stop, "long", "stop", S._research_tick_size(cfg))
            if entry is None or order_stop is None:
                return None
            risk = abs(entry - order_stop) or abs(entry - float(stop))
            target = entry + cfg.get("bkTargetR", S.BK_TARGET_R) * risk
            return causal_geometry(
                "long", entry, stop, target,
                f"close {last:.4f} > {self.lookback}-bar high {max(prior):.4f}")
        if last < min(prior):
            stop = max(prior)
            if entry_open is None:
                target = last - cfg.get("bkTargetR", S.BK_TARGET_R) * (stop - last)
                return {"direction": "short", "stop": stop, "target": target,
                        "rationale": f"close {last:.4f} < {self.lookback}-bar low {min(prior):.4f}"}
            entry = S._round_fill(entry_open, "short", S._research_tick_size(cfg),
                                  is_entry=True)
            order_stop = S._round_order_level(
                stop, "short", "stop", S._research_tick_size(cfg))
            if entry is None or order_stop is None:
                return None
            risk = abs(entry - order_stop) or abs(entry - float(stop))
            target = entry - cfg.get("bkTargetR", S.BK_TARGET_R) * risk
            return causal_geometry(
                "short", entry, stop, target,
                f"close {last:.4f} < {self.lookback}-bar low {min(prior):.4f}")
        return None


def stream_once(store: S.Store, *, max_seconds: float = None, stall_seconds: float = None,
                shared_cap=None, _ws=None, _clock=time.monotonic) -> dict:
    """Attach to the live WC feed and capture until the connection drops, *max_seconds* elapses,
    or the feed STALLS — no candle parsed within *stall_seconds* (a silently-dead hook). On a
    stall we return with ``stalled=True`` so main() re-hooks on a FRESH attach, which resumes
    candles immediately (this is what keeps the chart LIVE while the buyer stays connected,
    instead of freezing at "connected · quiet"). Never raises — a dropped hook just returns.

    ``shared_cap`` lets main() reuse ONE Capture across re-hooks so its in-memory buffers (and the
    flusher/evaluator threads bound to it) persist between attaches; when None (tests) a fresh
    Capture is built per attach. ``_ws`` / ``_clock`` are injection seams for tests; production
    always builds a real WSClient and uses the monotonic clock."""
    stall = STALL_SECONDS if stall_seconds is None else stall_seconds
    ws = _ws
    if ws is None:
        page = pick_wc_page(cdp_pages())
        if not page:
            return {"available": False, "reason": "no logged-in WC page on CDP"}
    cap = shared_cap if shared_cap is not None else Capture(store)
    frames = candles = 0
    t0 = _clock()
    last_candle = t0          # arm the watchdog from attach so a never-starting hook re-hooks too
    stalled = False
    try:
        if _ws is None:
            ws = WSClient(page["webSocketDebuggerUrl"])
            ws.send(json.dumps({"id": 1, "method": "Network.enable"}))
        while True:
            now = _clock()
            if max_seconds is not None and now - t0 >= max_seconds:
                break
            if stall and now - last_candle >= stall:
                stalled = True
                break
            raw = ws.recv_text()
            if not raw:
                continue
            frames += 1
            cd = _frame_candle(raw)
            if cd:
                candles += 1
                last_candle = _clock()
                cap.on_candle(cd)
    except Exception as exc:  # noqa: BLE001 — hook dropped / chrome closed
        log.info("capture: hook ended (%s)", exc)
    finally:
        if ws:
            ws.close()
    res = {"available": True, "frames": frames, "candles": candles,
           "symbols": list(cap.last_key.keys())}
    if stalled:
        res["stalled"] = True
        log.info("capture: feed stalled (no candle in %.0fs) — re-hooking on a fresh attach", stall)
    return res


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


def _frame_candle_reg(raw, candidates, parser_cache):
    """CDP envelope -> normalized candle via the pluggable parser registry (bltd_parsers). Cheap
    raw-bytes prefilter before json.loads (most frames are noise). Per-socket parser cache (keyed by
    CDP requestId) so detect() runs once per WebSocket, not per frame. Returns None for
    auth/telemetry/keepalive frames (never fabricates). This is the multi-platform sibling of
    _frame_candle: the WealthCharts tab still routes to the proven parse_candle (via
    WealthChartsParser), while TradingView/Tradovate/TopstepX and any platform the generic sniffer
    recognizes are read by the SAME path."""
    if "webSocketFrameReceived" not in raw:
        return None
    try:
        m = json.loads(raw)
    except (TypeError, ValueError):
        return None
    if not isinstance(m, dict) or m.get("method") != "Network.webSocketFrameReceived":
        return None
    params = m.get("params") or {}
    payload = (params.get("response") or {}).get("payloadData")
    if not isinstance(payload, str):
        return None
    rid = params.get("requestId")
    parser = parser_cache.get(rid)
    if parser is None:
        parser = P.pick_parser(payload, candidates)
        if parser is None:
            return None
        if rid is not None:
            if len(parser_cache) > 500:
                parser_cache.clear()             # bound — sockets churn over a long session
            parser_cache[rid] = parser
    return parser.parse(payload)


def stream_tab(name, page, cap, *, idle_stall=45.0, _ws=None, _clock=time.monotonic) -> dict:
    """ONE reader thread for ONE logged-in trading tab -> cap.on_candle (PURE MEMORY, no I/O). The
    pluggable parser registry (bltd_parsers) handles the platform's frame format, so WealthCharts,
    TradingView, Tradovate/TopstepX, and any platform the generic sniffer recognizes are read by the
    SAME reader. Returns (so main() re-spawns a fresh attach) when a producing tab goes quiet, or a
    non-producing tab (logged out / wrong page) yields nothing for *idle_stall*. The WealthCharts
    tab routes to the proven parse_candle path — identical to stream_once.

    Bars carry volume/delta when the source frame supplies them; close-only platforms continue as
    zero-volume bars. ``_ws`` / ``_clock`` are test injection seams (same contract as stream_once);
    production builds a real WSClient on the monotonic clock. Never raises — a dropped hook just
    returns its counts."""
    candidates = P.platforms_for_host(page.get("url") or "")
    parser_cache = {}
    ws = _ws
    frames = candles = 0
    t0 = _clock()
    last_candle = t0
    try:
        if _ws is None:
            ws = WSClient(page["webSocketDebuggerUrl"])
            ws.send(json.dumps({"id": 1, "method": "Network.enable"}))
        while True:
            now = _clock()
            if candles == 0 and now - t0 >= idle_stall:
                break                            # non-producing tab -> stop, free the thread
            if candles > 0 and now - last_candle >= idle_stall * 2:
                break                            # was producing, went quiet -> recycle on a fresh attach
            raw = ws.recv_text()
            if not raw:
                continue
            frames += 1
            cd = _frame_candle_reg(raw, candidates, parser_cache)
            if cd:
                candles += 1
                last_candle = _clock()
                cap.on_candle(cd)
    except Exception as exc:  # noqa: BLE001 — dropped hook / chrome closed
        log.info("capture[%s]: hook ended (%s)", name, exc)
    finally:
        if ws:
            ws.close()
    return {"source": name, "frames": frames, "candles": candles}


# ===========================================================================
# Reliability threads — keep ALL SQLite I/O and the heavy edge-gate evaluation OFF the frame read
# loop, and self-heal a silently-wedged daemon. Ported from the live runtime against the generic
# source roster + volume/delta-capable bar schema.
# ===========================================================================
def _store_is_wedged(prev_seen, prev_progress, cur, now, *, stale_after):
    """PURE wedge decision for the freshness watchdog (unit-tested in isolation). Given the
    previously-seen newest tick timestamp, the wall-clock when it last advanced, the current newest
    tick, and *now*, return ``(new_seen, new_progress, wedged)``. ``wedged`` is True only when the
    store's newest tick has not advanced for *stale_after* seconds — capture is alive enough to be
    checked but is persisting nothing (blocked recv, dead hook, or failing writes)."""
    if cur > prev_seen:
        return cur, now, False
    return prev_seen, prev_progress, (now - prev_progress > stale_after)


# --- market-hours gate for the freshness watchdog ---------------------------
# CME equity-index futures (ES/NQ) trade on Globex Sun 17:00 -> Fri 16:00 CT,
# with a daily maintenance halt 16:00-17:00 CT Mon-Thu. A closed market leaves
# the store nothing to advance, so the freshness watchdog must NOT respawn-loop
# on a weekend/overnight idle — that is normal, not a wedge. PURE so it is
# unit-tested in isolation. Holidays/early-closes are deliberately NOT modeled:
# the gate only ever SUPPRESSES a respawn inside a known-closed window, never
# forces one, so an unmodeled holiday degrades to the prior always-respawn
# behavior — never worse, never masks a real in-session wedge.
from datetime import datetime as _datetime
try:
    from zoneinfo import ZoneInfo as _ZoneInfo
    _CENTRAL = _ZoneInfo("America/Chicago")
except Exception:  # noqa: BLE001 — zoneinfo/tzdata missing: fall back to host-local clock
    _CENTRAL = None


def _central_now(now_epoch=None):
    """Current (or given-epoch) wall time as a Central-time datetime — the tz CME quotes in."""
    ts = time.time() if now_epoch is None else now_epoch
    return _datetime.fromtimestamp(ts, _CENTRAL) if _CENTRAL else _datetime.fromtimestamp(ts)


def _market_is_open(dt_central) -> bool:
    """True when CME equity-index futures are trading at *dt_central* (a Central-time datetime)."""
    weekday = dt_central.weekday()                  # Mon=0 .. Sun=6
    minutes = dt_central.hour * 60 + dt_central.minute
    if weekday == 5:                                # Saturday: closed all day
        return False
    if weekday == 6:                                # Sunday: reopens 17:00 CT
        return minutes >= 17 * 60
    if weekday == 4:                                # Friday: weekly close at 16:00 CT
        return minutes < 16 * 60
    return not (16 * 60 <= minutes < 17 * 60)       # Mon-Thu: closed only for the 16:00-17:00 halt


def _freshness_watchdog(store_path, *, stale_after=300.0, check_every=15.0):
    """Self-heal a wedged capture. The in-loop stall watchdog only fires if stream_once's loop is
    actually iterating — it can't see a blocked recv, a silently-failing store write, or a hook that
    parses frames but persists nothing. This thread watches GROUND TRUTH instead: the store's newest
    tick timestamp. If it stops advancing for *stale_after* seconds WHILE a trading feed is reachable,
    capture is wedged — force-exit so launchd (KeepAlive) respawns a fresh daemon that re-attaches
    and resumes. Gated on watchdog_feed_available() so a merely logged-out browser (nothing to
    wedge) never drives a respawn loop; the first observation seeds the baseline so a fresh start
    gets grace."""
    import sqlite3 as _sq
    last_seen, last_progress = -1, time.time()
    while True:
        time.sleep(check_every)
        try:
            cx = _sq.connect(store_path, timeout=2)
            row = cx.execute("SELECT max(recorded) FROM wc_live").fetchone()
            cx.close()
            cur = (row[0] or 0) if row else 0
        except Exception:  # noqa: BLE001
            continue
        last_seen, last_progress, wedged = _store_is_wedged(
            last_seen, last_progress, cur, time.time(), stale_after=stale_after)
        if wedged and watchdog_feed_available() and _market_is_open(_central_now()):
            # os._exit fires even when the main thread is hard-blocked; launchd KeepAlive respawns
            # a fresh daemon that re-attaches. Only trips when the feed IS reachable AND the market
            # is open but the store stopped advancing — a real wedge, not a logged-out session and
            # not a closed market (weekend/overnight idle leaves nothing to advance).
            log.warning("capture: store not advancing for %.0fs while feed reachable and market "
                        "open — exiting so launchd respawns a fresh capture",
                        time.time() - last_progress)
            os._exit(1)


def evaluator_heartbeat_path(store_path: str) -> str:
    """Liveness file the evaluator touches each cycle, next to the store. The API process (a
    SEPARATE process, bridged to this daemon ONLY by the shared store) reads its mtime to tell an
    honest 'evaluator offline — signals paused' state instead of letting an API-feed buyer silently
    get bars-but-no-fires when this daemon dies."""
    return os.path.join(os.path.dirname(store_path) or ".", "evaluator.heartbeat")


def _touch_heartbeat(store_path: str):
    try:
        with open(evaluator_heartbeat_path(store_path), "w") as f:
            f.write(str(int(time.time())))
    except OSError as exc:
        log.info("evaluator heartbeat: %s", exc)


def _evaluator_loop(cap, *, every=8.0):
    """Run the signal engines off the capture read loop, every *every* seconds. Decoupling the
    edge-gate evaluation from frame ingestion is what lets a single WS attach stream indefinitely
    instead of wedging after ~75s under the old design that ran the engines inline in _roll.
    Touches the heartbeat each cycle so the API process can prove this evaluator is alive."""
    _touch_heartbeat(cap.store.path)             # immediate liveness at start
    while True:
        time.sleep(every)
        try:
            cap.evaluate_all()
        except Exception as exc:  # noqa: BLE001
            log.info("evaluator loop: %s", exc)
        _touch_heartbeat(cap.store.path)         # alive even on a quiet (no-fire) cycle


def _flusher_loop(cap, *, every=0.3):
    """Persist the read loop's in-memory tick/bar buffers every *every* seconds. Keeping ALL SQLite
    I/O here (off the frame read loop) is what lets capture keep pace with the live WS indefinitely
    — the read loop only touches memory, as fast as a bare reader."""
    while True:
        time.sleep(every)
        try:
            cap.flush()
        except Exception as exc:  # noqa: BLE001
            log.info("flusher: %s", exc)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    store = S.Store(S.default_store_path())
    log.info("capture: own store at %s; CDP :%d; edge_gate=%s", store.path, CDP_PORT, EDGE_GATE)
    # ONE shared Capture across re-hooks: the frame read loop fills its in-memory tick/bar buffers
    # (PURE MEMORY); the flusher thread drains them to SQLite and the evaluator thread runs the
    # edge-gated engines off the read loop. The read loop NEVER touches SQLite — that's the no-wedge
    # core. The freshness watchdog force-exits a silently-wedged daemon so launchd respawns it.
    cap = Capture(store)
    threading.Thread(target=_freshness_watchdog, args=(store.path,), daemon=True).start()
    threading.Thread(target=_flusher_loop, args=(cap,), daemon=True).start()
    # Source keeps capture as the fire generator (no separate evaluator process), so the evaluator
    # runs by default; set BLTD_CAPTURE_ENGINES=0 to capture data only without firing.
    if os.environ.get("BLTD_CAPTURE_ENGINES", "1") != "0":
        threading.Thread(target=_evaluator_loop, args=(cap,), daemon=True).start()
    if os.environ.get("BLTD_CAPTURE_BROWSER", "1") == "0":
        log.info("capture: browser readers disabled; flusher + evaluator heartbeat only")
        while True:
            time.sleep(60)
    # AUTO-INJECT BROWSER FEEDS: discover logged-in supported tabs and run one reader thread per tab
    # into the shared store. A tab the buyer logs into mid-session is picked up on rediscovery.
    # BLTD_AUTO_BROWSER=0 -> never auto-open Chrome here (the in-app feed connect action
    # opens it on demand via /api/connect). The flusher + evaluator threads above run regardless,
    # so bars captured from browser platform sessions are evaluated without blocking frame reads.
    auto_browser = os.environ.get("BLTD_AUTO_BROWSER", "1") != "0"
    readers = {}     # webSocketDebuggerUrl -> (name, Thread)
    while True:
        present = bool(discover_feed_pages())
        if not present and auto_browser:
            present = ensure_feeds()
        if not present:
            log.info("capture: no logged-in trading feed on CDP :%d (auto_browser=%s) — flusher + "
                     "evaluator running; open browser capture and sign into a trading platform",
                     CDP_PORT, auto_browser)
            time.sleep(5)
            continue
        for name, page in discover_feed_pages():
            url = page["webSocketDebuggerUrl"]
            cur = readers.get(url)
            if cur is None or not cur[1].is_alive():
                t = threading.Thread(target=stream_tab, args=(name, page, cap), daemon=True)
                t.start()
                readers[url] = (name, t)
                log.info("capture[%s]: reader attached -> %s", name, (page.get("url") or "")[:60])
        for url in [u for u, (n, t) in readers.items() if not t.is_alive()]:
            readers.pop(url, None)     # let a re-logged-in tab re-attach on the next rediscovery
        time.sleep(3)    # rediscover so a newly-logged-in platform is auto-attached, no restart


if __name__ == "__main__":
    main()
