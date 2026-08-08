"""Black Label Trading — live feed normalization layer (SELF-CONTAINED, stdlib-only).

WHY THIS EXISTS: a buyer who trades a prop account should not need a broker API key. The supported
product path is inbound webhook data: the buyer's bridge/sender posts observed ticks or bars into
the local backend, and the backend writes them into the SAME closed-bar/tick path
(Capture.on_candle / Store.record_bars -> the product's own SQLite store), so the SAME
FeedClient/status UI, the SAME engines, and the SAME edge gate run unchanged regardless of which
prop platform produced bars.

HARD BINDINGS (CHARTER §5.1/§5.2/§5.6/§5.7):
  - ZERO fabrication: every bar/tick is a REAL value from the connected account. A frame with no
    usable price is dropped (never invented). Unknown edge / no data -> honest empty/error state.
  - SHIP NO DATA: this module bundles NO credentials and NO bars. Webhook ingestion uses a local
    receiver URL/token; no prop-firm API key is requested or accepted by FeedManager.
  - These FEED adapters are read-only market data. The shipping product has no order route.
  - Instrument scope is enforced downstream by the store (release default "es"): webhook ingestion
    accepts the shipped Topstep ES-family feed and drops stale/non-ES rows.

The old API adapter modules stay in-repo for offline protocol tests and execution code, but
FeedManager exposes only the no-creds webhook receiver for data ingestion.
"""
from __future__ import annotations

import json
import logging
import os
import re
import socket
import ssl
import struct
import threading
import time
from urllib.parse import urlparse

import bltd_store as S
# Reuse the proven RFC6455 framing helpers + the Capture normalizer (no behavior change to either).
from bltd_capture import ws_encode_text, ws_parse_frame, Capture

log = logging.getLogger("bltd.feeds")


# ===========================================================================
# Symbol mapping — feed adapters can still parse wider broker symbols, but the shipped store/chart
# scope is ES-family only unless a developer explicitly sets BLTD_SCOPE=all.
# ===========================================================================
# Contract roots that ARE the S&P 500 e-mini family across supported platform/native tokens:
#   ES / EP  -> CME E-mini S&P 500   (ProjectX uses "EP"; Tradovate/most use "ES")
#   MES / MEP-> CME Micro E-mini S&P 500
# All normalize to the product's ES root (is_es_symbol("ES") is True; engines are ES-only).
_ES_FAMILY_ROOTS = ("MES", "MEP", "ES", "EP")
_ROOT_ALIASES = {
    # ProjectX/Gateway roots that differ from the common retail futures root.
    "EP": "ES",
    "MEP": "MES",
    "ENQ": "NQ",
}
_FUTURES_MONTHS = "FGHJKMNQUVXZ"
# A contract symbol = ROOT + month-letter + 1-2 year digits, e.g. ESU5 / MESM25 / EPZ25.
_CONTRACT_RE = re.compile(rf"^([A-Z]{{1,4}})[{_FUTURES_MONTHS}]\d{{1,2}}$")


def futures_root(text) -> str:
    """The alphabetic ROOT of a futures token, correctly stripping the trailing month+year suffix.
    'ESU5'->'ES', 'MESM25'->'MES', 'EPZ25'->'EP', bare 'ES'->'ES'. PURE."""
    s = "".join(ch for ch in str(text or "").upper() if ch.isalnum())
    if "." in str(text or ""):
        s = "".join(ch for ch in str(text).upper().split(".")[-1] if ch.isalnum())
    m = _CONTRACT_RE.match(s)
    if m:
        return m.group(1)
    # bare root (no month/year) or unparseable: take leading alpha run
    i = 0
    while i < len(s) and s[i].isalpha():
        i += 1
    return s[:i]


def map_es_symbol(native) -> str | None:
    """Map a broker-native futures token/name to the product ES root, or None if not S&P e-mini.

    Accepts contract names ('ESU5', 'MESM25', 'EPZ25'), descriptions containing 'E-mini S&P 500',
    and the bare roots. Returns 'ES' for the e-mini family (incl micro) so it lands in the ES-only
    store; returns None for unrelated contracts (NQ, CL, gold, ...) so they are dropped."""
    if native is None:
        return None
    raw = str(native).upper()
    # A broker contract id can carry the root in any segment: 'ESU5', 'CON.F.US.EP.U25' (root=EP),
    # 'CON.F.US.MES.U25'. Scan each dot-segment's futures root, plus the bare token.
    segs = raw.split(".") if "." in raw else [raw]
    for seg in segs + [raw]:
        if futures_root(seg) in _ES_FAMILY_ROOTS:
            return "ES"
    # description fallback (e.g. ProjectX contract.description = "E-mini S&P 500: September 2025")
    if "E-MINI S&P 500" in raw or "E-MINI S&P500" in raw or "MICRO E-MINI S&P 500" in raw:
        return "ES"
    return None


def canonical_root(root: str) -> str:
    r = str(root or "").upper()
    return _ROOT_ALIASES.get(r, r)


def map_market_symbol(native) -> str | None:
    """Map a broker-native contract token/name/id to a display/store symbol.

    Full contract symbols are preserved (NQU6 -> NQU6, ESU6 -> ESU6). Broker-specific roots inside
    dotted ids are canonicalized when no full contract name is present (CON.F.US.ENQ.U25 -> NQ,
    CON.F.US.EP.U25 -> ES). Returns None only when no sane symbol can be recovered."""
    if native is None:
        return None
    raw = str(native).strip().upper()
    if not raw:
        return None
    cleaned = "".join(ch for ch in raw.split(".")[-1].lstrip("/@") if ch.isalnum())
    if "." not in raw and cleaned and futures_root(cleaned):
        # Preserve full contract names when the last token is the symbol itself.
        root = futures_root(cleaned)
        if root and root != cleaned:
            return cleaned
        if cleaned.isalpha() and len(cleaned) <= 5:
            return canonical_root(cleaned)
    for seg in raw.split("."):
        root = futures_root(seg)
        if root:
            canon = canonical_root(root)
            if canon and canon not in ("CON", "F", "US"):
                return canon
    # description fallback for ES family strings that do not expose a compact token
    if "E-MINI S&P 500" in raw or "E-MINI S&P500" in raw:
        return "ES"
    return None


def make_candle(symbol, close, *, open=None, high=None, low=None, epoch=None,
                volume=None, delta=None) -> dict | None:
    """One NORMALIZED candle dict for Capture.on_candle, or None. close is mandatory and must be a
    finite, plausible price — a frame without one is NOT a candle (never fabricate)."""
    try:
        c = float(close)
    except (TypeError, ValueError):
        return None
    if c != c or c in (float("inf"), float("-inf")) or not (0.0001 <= c <= 10_000_000.0):
        return None
    if not symbol:
        return None

    def _f(v):
        try:
            f = float(v)
        except (TypeError, ValueError):
            return None
        return f if (f == f and f not in (float("inf"), float("-inf"))) else None

    ep = None
    if isinstance(epoch, (int, float)) and epoch == epoch:
        e = float(epoch)
        if e > 1e12:          # milliseconds -> seconds
            e /= 1000.0
        if 1_000_000_000 <= e <= 4_000_000_000:
            ep = int(e)
    return {"symbol": str(symbol), "open": _f(open), "high": _f(high),
            "low": _f(low), "close": c, "epoch": ep,
            "volume": max(0.0, _f(volume) or 0.0), "delta": _f(delta) or 0.0}


def ws_encode_binary(data: bytes) -> bytes:
    """Encode one masked client BINARY frame (opcode 0x2). Sibling of bltd_capture.ws_encode_text;
    client frames MUST be masked per RFC6455. Used for Rithmic's protobuf-over-WebSocket transport."""
    n = len(data)
    header = bytearray([0x82])               # FIN + binary opcode
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
    masked = bytes(data[i] ^ mask[i % 4] for i in range(n))
    return bytes(header) + masked


# ===========================================================================
# Minimal TLS-capable RFC6455 WebSocket client (ws:// AND wss://). The proven CDP WSClient in
# bltd_capture is localhost-only (no TLS); broker hubs are wss://, so this adds an ssl-wrapped
# socket while REUSING the same battle-tested framing helpers. Stdlib only.
# ===========================================================================
class WSConn:
    def __init__(self, url: str, headers: dict | None = None, timeout: float = 12.0):
        u = urlparse(url)
        secure = (u.scheme == "wss")
        self.host = u.hostname or "127.0.0.1"
        self.port = u.port or (443 if secure else 80)
        self.path = (u.path or "/") + (("?" + u.query) if u.query else "")
        raw = socket.create_connection((self.host, self.port), timeout=timeout)
        if secure:
            ctx = ssl.create_default_context()
            raw = ctx.wrap_socket(raw, server_hostname=self.host)
        self.sock = raw
        self._handshake(headers or {})
        self.sock.settimeout(1.0)
        self._buf = b""

    def _handshake(self, headers):
        import base64
        import hashlib
        key = base64.b64encode(os.urandom(16)).decode()
        hostline = self.host if self.port in (80, 443) else f"{self.host}:{self.port}"
        lines = [f"GET {self.path} HTTP/1.1", f"Host: {hostline}",
                 "Upgrade: websocket", "Connection: Upgrade",
                 f"Sec-WebSocket-Key: {key}", "Sec-WebSocket-Version: 13"]
        for k, v in headers.items():
            lines.append(f"{k}: {v}")
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        resp = b""
        self.sock.settimeout(12.0)
        while b"\r\n\r\n" not in resp:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("websocket handshake closed early")
            resp += chunk
        if b" 101 " not in resp.split(b"\r\n", 1)[0]:
            raise ConnectionError(f"websocket handshake failed: {resp[:90]!r}")
        accept = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        if accept.encode() not in resp:
            raise ConnectionError("websocket handshake: bad Sec-WebSocket-Accept")
        self._buf = resp.split(b"\r\n\r\n", 1)[1]

    def send_text(self, text: str):
        self.sock.sendall(ws_encode_text(text))

    def send_binary(self, data: bytes):
        """Send one masked binary frame (opcode 0x2) — Rithmic's R|Protocol is protobuf-over-binary."""
        self.sock.sendall(ws_encode_binary(data))

    def _recv_frame(self, max_wait: float):
        """Return (opcode, payload_bytes) for the next frame, or (None, None) on timeout."""
        op, data, rest = ws_parse_frame(self._buf)
        deadline = time.monotonic() + max_wait
        while op is None:
            if time.monotonic() > deadline:
                return None, None
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                return None, None
            if not chunk:
                raise ConnectionError("websocket closed")
            self._buf += chunk
            op, data, rest = ws_parse_frame(self._buf)
        self._buf = rest
        if op == 0x8:
            raise ConnectionError("websocket close frame")
        return op, data

    def recv_text(self, max_wait: float = 2.0):
        """Next text-frame payload as str, or None on timeout. Bounded like the CDP client so a
        half-dead socket can never wedge the read loop. Control frames -> '' (caller ignores)."""
        op, data = self._recv_frame(max_wait)
        if op is None:
            return None
        if op in (0x9, 0xA):
            return ""
        if op in (0x1, 0x2):
            try:
                return data.decode("utf-8", "replace")
            except Exception:  # noqa: BLE001
                return ""
        return ""

    def recv_bytes(self, max_wait: float = 2.0):
        """Next data-frame payload as RAW bytes, or None on timeout. Control frames -> b'' (ignored).
        Used by the Rithmic adapter, whose messages are binary protobuf (not text)."""
        op, data = self._recv_frame(max_wait)
        if op is None:
            return None
        if op in (0x1, 0x2):
            return data
        return b""

    def close(self):
        try:
            self.sock.close()
        except Exception:  # noqa: BLE001
            pass


# ===========================================================================
# Minimal SignalR (JSON hub protocol) client over WSConn — exactly what ProjectX's market hub
# speaks (it documents skipNegotiation:true + WebSockets transport, so no negotiate POST is
# needed; we connect the socket directly and do the JSON handshake). Messages are JSON records
# delimited by 0x1e. Stdlib only.
# ===========================================================================
_RS = "\x1e"


class SignalRJson:
    def __init__(self, ws: WSConn):
        self.ws = ws
        self._buf = ""

    def handshake(self, timeout: float = 12.0):
        self.ws.send_text(json.dumps({"protocol": "json", "version": 1}) + _RS)
        msg = self._next(timeout)
        if msg is None:
            raise ConnectionError("SignalR handshake: no response")
        if isinstance(msg, dict) and msg.get("error"):
            raise ConnectionError(f"SignalR handshake error: {msg['error']}")

    def invoke(self, target: str, *args):
        self.ws.send_text(json.dumps({"type": 1, "target": target, "arguments": list(args)}) + _RS)

    def ping(self):
        self.ws.send_text(json.dumps({"type": 6}) + _RS)

    def _next(self, timeout: float):
        """Next 0x1e-delimited JSON record as a dict, or None on timeout."""
        deadline = time.monotonic() + timeout
        while _RS not in self._buf:
            if time.monotonic() > deadline:
                return None
            t = self.ws.recv_text(max_wait=1.0)
            if t:
                self._buf += t
        raw, self._buf = self._buf.split(_RS, 1)
        if not raw:
            return {}
        try:
            return json.loads(raw)
        except (ValueError, TypeError):
            return {}

    def records(self, max_wait: float = 1.0):
        """Yield available parsed records (drains the buffer). Auto-replies to server pings."""
        while True:
            t = self.ws.recv_text(max_wait=max_wait)
            if t:
                self._buf += t
            if _RS not in self._buf:
                return
            while _RS in self._buf:
                raw, self._buf = self._buf.split(_RS, 1)
                if not raw:
                    continue
                try:
                    rec = json.loads(raw)
                except (ValueError, TypeError):
                    continue
                if isinstance(rec, dict) and rec.get("type") == 6:   # ping -> pong
                    try:
                        self.ping()
                    except Exception:  # noqa: BLE001
                        pass
                    continue
                yield rec


# ===========================================================================
# FeedSource interface. Every data source (browser-scraped or broker-API) implements this and
# feeds NORMALIZED candles to on_candle(cd). Status is OBSERVED, never assumed — an adapter that
# hasn't authenticated reports auth_error; one with no recent tick reports idle; it NEVER claims
# "live" without a real, recent tick.
# ===========================================================================
# Source states surfaced to the UI (honest banner):
ST_DISCONNECTED = "disconnected"
ST_AUTHENTICATING = "authenticating"
ST_CONNECTING = "connecting"     # authed, opening/subscribing the market socket
ST_LIVE = "live"                 # a real tick landed within LIVE_TICK_WINDOW
ST_IDLE = "idle"                 # connected, but no fresh tick (market closed / quiet)
ST_AUTH_ERROR = "auth_error"     # credentials rejected by the broker
ST_ERROR = "error"               # network / socket / unexpected
ST_NEEDS_SETUP = "needs_setup"   # adapter requires a prerequisite the buyer must supply (Rithmic)
ST_UNAVAILABLE = "unavailable"   # known policy/rail dead-end; not a credential problem

_LIVE_TICK_WINDOW = 30.0


class FeedSource:
    """Base class. Subclasses set key/label/kind/cred_fields and implement _run()."""
    key = "base"
    label = "Base"
    kind = "api"                  # "api" (REST+socket) | "browser" (CDP scrape)
    cred_fields: list[dict] = []  # [{name,label,secret,optional,default,placeholder}]
    note = ""

    def __init__(self, creds: dict, on_candle, opts: dict | None = None):
        self._creds = dict(creds or {})       # in-memory only; never persisted, never logged
        self._on_candle = on_candle
        self._opts = dict(opts or {})
        self._state = ST_DISCONNECTED
        self._detail = ""
        self._symbol = None                   # the resolved instrument label (e.g. ESU5)
        self._last_tick = 0.0
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    # -- lifecycle ------------------------------------------------------
    def start(self):
        """Authenticate (synchronously, so an auth error is reported immediately) then spawn the
        streaming thread. Returns the current status dict. Never raises to the caller."""
        try:
            self._authenticate()
        except AuthError as exc:
            self._set(ST_AUTH_ERROR, str(exc))
            return self.status()
        except Exception as exc:  # noqa: BLE001
            self._set(ST_ERROR, f"{type(exc).__name__}: {exc}")
            return self.status()
        self._stop.clear()
        self._thread = threading.Thread(target=self._run_guarded, daemon=True)
        self._thread.start()
        return self.status()

    def stop(self):
        self._stop.set()
        self._set(ST_DISCONNECTED, "disconnected by user")

    def _run_guarded(self):
        try:
            self._run()
        except AuthError as exc:
            self._set(ST_AUTH_ERROR, str(exc))
        except Exception as exc:  # noqa: BLE001
            self._set(ST_ERROR, f"{type(exc).__name__}: {exc}")

    # -- subclass hooks -------------------------------------------------
    def _authenticate(self):
        """REST login etc. Raise AuthError on bad credentials. Default: nothing to do."""

    def _run(self):
        """Long-lived market-data loop. Call self._emit(cd) per tick. Honor self._stop."""
        raise NotImplementedError

    # -- helpers for subclasses ----------------------------------------
    def _emit(self, cd: dict | None):
        if not cd:
            return
        self._last_tick = time.time()
        if self._state in (ST_CONNECTING, ST_IDLE, ST_AUTHENTICATING):
            self._set(ST_LIVE, "ticks flowing")
        try:
            self._on_candle(cd)
        except Exception as exc:  # noqa: BLE001 — one bad candle must never kill the stream
            log.info("feed[%s]: on_candle failed: %s", self.key, exc)

    def _set(self, state, detail=""):
        self._state = state
        self._detail = detail

    # -- status ---------------------------------------------------------
    def status(self) -> dict:
        st = self._state
        if st == ST_LIVE and (time.time() - self._last_tick) > _LIVE_TICK_WINDOW:
            st = ST_IDLE
        age = (time.time() - self._last_tick) if self._last_tick else None
        return {"source": self.key, "label": self.label, "kind": self.kind,
                "state": st, "detail": self._detail, "symbol": self._symbol,
                "lastTickAge": round(age, 1) if age is not None else None}

    # -- catalogue entry (for the picker) -------------------------------
    @classmethod
    def descriptor(cls) -> dict:
        return {"key": cls.key, "label": cls.label, "kind": cls.kind,
                "credFields": cls.cred_fields, "note": cls.note}


class AuthError(Exception):
    """Credentials were rejected (or insufficient) — surfaces as ST_AUTH_ERROR, not a crash."""


# ===========================================================================
# Source registry + manager. The manager owns ONE shared Capture (the same normalization the WC
# capture daemon uses) writing into the product's own store, plus a flusher thread that persists
# the in-memory tick/bar buffers. It does NOT run an engine evaluator: firing stays owned by the
# single capture daemon's evaluator (which fires on ES bars in the store regardless of which
# source produced them), so there is exactly one firing path and never a double fire.
# ===========================================================================
def _registry() -> dict:
    """Source classes by key. Imported lazily to avoid an import cycle (adapters import this
    module for FeedSource/helpers). A broken adapter import disables only that one source."""
    reg = {}
    for mod, attr in (("bltd_projectx", "ProjectXSource"),
                      ("bltd_rithmic", "RithmicSource")):
        try:
            reg_cls = getattr(__import__(mod), attr)
            reg[reg_cls.key] = reg_cls
        except Exception as exc:  # noqa: BLE001
            log.warning("feed registry: %s unavailable (%s)", mod, exc)
    return reg


# Webhook ingestion is the supported no-creds prop-account path. Connecting it does NOT go through
# an API adapter — the user's bridge posts observed ticks/bars into /webhook/feed.
_WEBHOOK_DESCRIPTOR = {
    "key": "webhook", "label": "Webhook receiver", "kind": "webhook",
    "credFields": [],
    "note": "No prop-firm credentials. Post observed ticks or OHLC bars into the local webhook "
            "receiver. The app writes only pushed real data into your local store.",
}

# Browser-capture platforms for this release. The buyer signs into the selected platform in the
# product-owned debug Chrome; the bridge/capture path reads the same market-data frames feeding the
# chart and writes them into the local store.
_BROWSER_PLATFORMS = [
    {"key": "topstepx", "label": "TopStepX", "support": "generic",
     "note": "Opens TopStepX. Sign in and the app reads its live market-data frames."},
    {"key": "wealthcharts", "label": "WealthCharts", "support": "generic",
     "note": "Opens WealthCharts. Sign in, open a chart, and the app reads its live chart feed."},
]
_BROWSER_KEYS = {p["key"] for p in _BROWSER_PLATFORMS}


def _browser_descriptor(p: dict) -> dict:
    return {"key": p["key"], "label": p["label"], "kind": "browser",
            "credFields": [], "support": p["support"], "note": p["note"]}


class FeedManager:
    def __init__(self, store: S.Store):
        self.store = store
        self._cap = Capture(store)
        self._lock = threading.Lock()
        self.active: FeedSource | None = None
        self._flusher = None

    def _ensure_flusher(self):
        if self._flusher and self._flusher.is_alive():
            return
        self._flusher = threading.Thread(target=self._flusher_loop, daemon=True)
        self._flusher.start()

    def _flusher_loop(self):
        while True:
            time.sleep(0.3)
            try:
                self._cap.flush()
            except Exception as exc:  # noqa: BLE001
                log.info("feed flusher: %s", exc)

    # -- catalogue ------------------------------------------------------
    def sources(self) -> dict:
        # Real browser-capture platforms first (the primary no-API path), webhook ingestion last.
        out = [_browser_descriptor(p) for p in _BROWSER_PLATFORMS]
        out.append(dict(_WEBHOOK_DESCRIPTOR))
        return {"sources": out, "active": self.active.key if self.active else None}

    # -- connect / disconnect ------------------------------------------
    def connect(self, source_key: str, creds: dict) -> dict:
        source_key = (source_key or "").strip().lower()
        if source_key in _BROWSER_KEYS or source_key == "browser":
            # Pure routing only — selecting a browser platform tells the UI to use the capture
            # browser. The actual Chrome launch (and the no-Chrome prerequisite) is driven by the
            # /api/connect path (FeedClient.launchCapture), so this stays side-effect-free/testable.
            label = next((p["label"] for p in _BROWSER_PLATFORMS if p["key"] == source_key),
                         "your platform")
            return {"source": source_key, "label": label, "kind": "browser", "state": "browser",
                    "detail": f"Open the capture browser and sign into {label}. Bars flow as soon as "
                              "a logged-in chart is streaming."}
        if source_key == "webhook":
            return {"source": "webhook", "label": _WEBHOOK_DESCRIPTOR["label"],
                    "state": "webhook",
                    "detail": "Post ticks or OHLC bars to the local webhook receiver. No prop-firm "
                              "credentials are stored or sent."}
        return {"source": source_key, "state": ST_ERROR,
                "detail": "webhook ingestion only; no broker/API feed is accepted"}

    def disconnect(self) -> dict:
        with self._lock:
            if self.active:
                self.active.stop()
                self.active = None
        return {"state": ST_DISCONNECTED}

    def status(self) -> dict:
        with self._lock:
            src = self.active
        if not src:
            try:
                import bltd_capture as C
                pages = C.discover_feed_pages()
                if pages:
                    key = pages[0][0]
                    label = next((p["label"] for p in _BROWSER_PLATFORMS if p["key"] == key), key)
                    return {"source": key, "label": label, "kind": "browser",
                            "state": "browser",
                            "detail": f"{label} is open in the capture browser. Keep a live chart open; bars flow into this Mac when market-data frames arrive.",
                            "symbol": None, "lastTickAge": None}
            except Exception:  # noqa: BLE001
                pass
            syms = self.store.symbols()
            if syms.get("liveTicks"):
                return {"source": "webhook", "label": _WEBHOOK_DESCRIPTOR["label"],
                        "kind": "webhook", "state": ST_LIVE,
                        "detail": "webhook ticks flowing", "symbol": syms["liveTicks"][0],
                        "lastTickAge": 0}
            if syms.get("live"):
                return {"source": "webhook", "label": _WEBHOOK_DESCRIPTOR["label"],
                        "kind": "webhook", "state": ST_IDLE,
                        "detail": "webhook bars received; no fresh tick right now",
                        "symbol": syms["live"][0], "lastTickAge": None}
            return {"source": None, "state": ST_DISCONNECTED, "detail": "waiting for webhook data"}
        return src.status()
