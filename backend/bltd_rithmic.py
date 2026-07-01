"""Black Label Trading — Rithmic feed adapter (R|Protocol, REAL — closes the "any prop firm" gap).

Rithmic powers many prop firms (Apex, Topstep's Rithmic path, and others). Its real-time market data
is NOT a plain REST+JSON-WebSocket API — it speaks R|Protocol: Google Protocol Buffers messages over
a TLS WebSocket to a FIRM-SPECIFIC Rithmic gateway. We implement that for real, with a hand-rolled
stdlib-only protobuf codec (bltd_rprotocol — NO pip dependency), against the published R|Protocol
field numbers / template ids.

Flow (TICKER_PLANT market data):
  connect wss gateway -> RequestLogin(10, user/password/system_name/infra=TICKER_PLANT/app)
  -> ResponseLogin(11): rp_code "0" == ok, else surface the server's reason (honest auth_error)
  -> RequestMarketDataUpdate(100) SUBSCRIBE symbol/exchange, update_bits = LAST_TRADE|BBO
  -> LastTrade(150).trade_price -> a normalized candle into the SAME store as every other source
  -> RequestHeartbeat(18) keepalive. No order is ever placed.

CREDENTIALS: the buyer enters their own Rithmic system / gateway / username / password (Keychain
only, never bundled or logged). HONEST STATES: authenticating / connecting / live / idle, and a real
auth_error carrying the gateway's rp_code reason on a denied login or denied market-data subscribe
(the Tradovate lesson — never stall silently). ZERO FABRICATION: a LastTrade with no trade_price
yields no candle; the emitted symbol is the buyer-selected contract.

UNVERIFIED-LIVE: like ProjectX, the live tick path can only be validated against a real
Rithmic-provisioned gateway + account (e.g. the Rithmic Test/Paper system). The protocol encoding is
unit-tested against known protobuf vectors; the gateway URL is firm-specific and entered by the buyer.
"""
from __future__ import annotations

import logging
import time

import bltd_feeds as F
import bltd_rprotocol as RP

log = logging.getLogger("bltd.feeds.rithmic")

DEFAULT_EXCHANGE = "CME"
LOGIN_TIMEOUT = 15.0


def _gateway_url(value: str) -> str:
    """Normalize a gateway value into a wss:// URL. Accepts a bare host[:port] or a full ws/wss URL."""
    v = (value or "").strip()
    if not v:
        return ""
    if v.startswith("wss://") or v.startswith("ws://"):
        return v
    return "wss://" + v.lstrip("/")


class RithmicSource(F.FeedSource):
    key = "rithmic"
    label = "Rithmic"
    kind = "api"
    cred_fields = [
        {"name": "system", "label": "Rithmic system name", "secret": False,
         "placeholder": "e.g. Rithmic Test / Rithmic Paper Trading / your firm's system"},
        {"name": "gateway", "label": "Gateway URL", "secret": False,
         "placeholder": "wss://rprotocol.rithmic.com:443 (your firm provides this)"},
        {"name": "username", "label": "Rithmic username", "secret": False},
        {"name": "password", "label": "Rithmic password", "secret": True},
        {"name": "symbol", "label": "Contract (advanced)", "secret": False, "optional": True,
         "placeholder": "auto ES front-month (e.g. ESU6)"},
        {"name": "exchange", "label": "Exchange (advanced)", "secret": False, "optional": True,
         "default": DEFAULT_EXCHANGE, "placeholder": DEFAULT_EXCHANGE},
        {"name": "appName", "label": "App name (advanced)", "secret": False, "optional": True,
         "default": "Black Label Trading", "placeholder": "Black Label Trading"},
        {"name": "appVersion", "label": "App version (advanced)", "secret": False, "optional": True,
         "default": "1.0", "placeholder": "1.0"},
    ]
    note = ("Rithmic uses R|Protocol (Protocol Buffers over your firm's TLS gateway). Enter your "
            "Rithmic system name, gateway URL, username and password — they stay in your macOS "
            "Keychain. Market data requires your account's data entitlement. Validate against the "
            "Rithmic Test/Paper system if your firm provides one. Nothing is ever simulated.")

    def __init__(self, creds, on_candle, opts=None):
        super().__init__(creds, on_candle, opts)
        self._gateway = _gateway_url(self._creds.get("gateway"))
        self._system = (self._creds.get("system") or "").strip()
        self._exchange = (self._creds.get("exchange") or DEFAULT_EXCHANGE).strip() or DEFAULT_EXCHANGE
        self._app_name = (self._creds.get("appName") or "Black Label Trading").strip()
        self._app_version = (self._creds.get("appVersion") or "1.0").strip()
        # Subscription contract: the buyer's explicit symbol, else a best-effort ES front-month.
        self._sub_symbol = (self._creds.get("symbol") or "").strip() or RP.es_front_month()

    # -- input validation (synchronous; the real login happens over the WS in _run) ----
    def _authenticate(self):
        user = (self._creds.get("username") or "").strip()
        pwd = self._creds.get("password") or ""
        if not (self._system and self._gateway and user and pwd):
            raise F.AuthError("Rithmic needs system name, gateway URL, username and password")
        self._symbol = self._sub_symbol
        self._set(F.ST_AUTHENTICATING, f"connecting to Rithmic gateway · {self._system}")

    # -- market-data stream -----------------------------------------------------
    def _run(self):
        backoff = 2.0
        while not self._stop.is_set():
            try:
                self._stream_once()
                backoff = 2.0
            except F.AuthError:
                raise                          # denied login/subscribe is terminal — never loop on it
            except Exception as exc:  # noqa: BLE001 — socket dropped: reconnect with backoff
                self._set(F.ST_CONNECTING, f"reconnecting: {type(exc).__name__}")
                log.info("rithmic: stream ended (%s) — reconnecting in %.0fs", exc, backoff)
            if self._stop.is_set():
                break
            end = time.monotonic() + backoff
            while time.monotonic() < end and not self._stop.is_set():
                time.sleep(0.25)
            backoff = min(backoff * 1.7, 30.0)

    def _stream_once(self, _ws=None):
        # _ws is a test injection seam; production opens a real TLS WebSocket to the firm gateway.
        ws = _ws if _ws is not None else F.WSConn(self._gateway)
        try:
            user = (self._creds.get("username") or "").strip()
            pwd = self._creds.get("password") or ""
            self._set(F.ST_AUTHENTICATING, f"logging into Rithmic · {self._system}")
            ws.send_binary(RP.build_login(user, pwd, self._system, self._app_name,
                                          self._app_version, RP.INFRA_TICKER_PLANT))
            hb_interval = self._await_login(ws)
            # Authenticated -> subscribe to the ES contract's LAST_TRADE + BBO.
            self._set(F.ST_CONNECTING, f"authenticated · subscribing {self._sub_symbol} on {self._exchange}")
            ws.send_binary(RP.build_market_data_subscribe(self._sub_symbol, self._exchange))
            last_hb = time.monotonic()
            while not self._stop.is_set():
                buf = ws.recv_bytes(max_wait=1.0)
                now = time.monotonic()
                if now - last_hb >= max(5.0, hb_interval * 0.5):
                    ws.send_binary(RP.build_heartbeat())
                    last_hb = now
                if not buf:
                    continue
                self._handle(buf)
        finally:
            ws.close()

    def _await_login(self, ws) -> float:
        """Block until ResponseLogin. Returns the heartbeat interval. Raises AuthError with the
        gateway's rp_code reason on a denied login (honest — never proceeds to subscribe blind)."""
        deadline = time.monotonic() + LOGIN_TIMEOUT
        while not self._stop.is_set():
            buf = ws.recv_bytes(max_wait=1.0)
            if buf is None:
                if time.monotonic() > deadline:
                    raise F.AuthError("no login response from Rithmic gateway (timeout)")
                continue
            if not buf:
                continue
            tid, dec = RP.parse_frame(buf)
            if tid == RP.T_RESPONSE_LOGIN:
                ok, detail = RP.rp_result(dec)
                if not ok:
                    raise F.AuthError(f"Rithmic login denied: {detail or 'rejected by gateway'}")
                hb = RP.field_double(dec, RP.F_HEARTBEAT_INTERVAL)
                return float(hb) if hb and hb > 0 else 30.0
            # ignore any other frame (e.g. system-info) while waiting for the login response
        raise F.AuthError("login interrupted")

    def _handle(self, buf: bytes):
        tid, dec = RP.parse_frame(buf)
        if tid == RP.T_LAST_TRADE:
            price = RP.field_double(dec, RP.F_TRADE_PRICE)
            epoch = RP.field_int(dec, RP.F_SSBOE)            # seconds since epoch (real exchange ts)
            self._emit(F.make_candle(self._sub_symbol, price, epoch=epoch))
        elif tid == RP.T_RESPONSE_MARKET_DATA_UPDATE:
            ok, detail = RP.rp_result(dec)
            if not ok:
                # A denied subscribe (e.g. no data entitlement) must surface, not stall silently.
                raise F.AuthError(f"Rithmic market-data subscribe denied: {detail or 'rejected'}")
        # BestBidOffer(151) and heartbeats are intentionally not turned into bars (we emit on the
        # real last trade only — bid/ask is not a traded price, so making a candle from it would
        # be a fabricated print).
