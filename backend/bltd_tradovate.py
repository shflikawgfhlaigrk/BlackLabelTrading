"""Black Label Trading — Tradovate API feed adapter (RETAIL / NON-PROP ONLY, not exposed).

Tradovate prop/evaluation accounts are a policy dead-end for direct trader API access, so this
adapter is intentionally NOT registered in the prop-firm feed picker. The picker exposes an honest
"unavailable" capability card instead. Keep this module as an offline-tested retail/non-prop
implementation candidate for a later separate track. If exposed later, it:

  1. REST auth with the buyer's OWN API credentials:
       POST https://{demo|live}.tradovateapi.com/v1/auth/accessTokenRequest
       body  {"name","password","appId","appVersion","cid","sec","deviceId"}
       ->    {"accessToken","mdAccessToken","expirationTime","userId", ...}
             (or {"errorText": "..."} on bad creds; {"p-ticket": ...} when captcha/penalty-boxed)
  2. Resolve the ES front-month contract:
       GET /contract/suggest?t=ES&l=10   ->  [{"name":"ESU5", ...}, ...]
  3. Real-time market data over the Tradovate WebSocket (SockJS-style text frames):
       wss://md.tradovateapi.com/v1/websocket
       - server frames: 'o' open, 'h' heartbeat, 'a[...]' messages, 'c[...]' close
       - client heartbeat: send '[]' every ~2.5s
       - request frame format (4 newline-separated fields): "<endpoint>\n<id>\n<query>\n<body>"
           authorize\n1\n\n<mdAccessToken>
           md/subscribeQuote\n2\n\n{"symbol":"ESU5"}
       - quote events: a[{"e":"md","d":{"quotes":[{"contractId":N,"entries":{"Trade":{"price":..},
                          "Bid":{..},"Offer":{..}, "HighPrice":{..}, "LowPrice":{..}, ...}}]}}]
     Each real Trade price -> a normalized candle into the shared store. No order is ever placed.

ZERO FABRICATION: a quote with no Trade price is dropped (bid/ask-only updates do not invent a
last). Honest auth_error on rejected creds; honest idle when connected but no fresh trade.
"""
from __future__ import annotations

import json
import logging
import time
import urllib.error
import urllib.parse
import urllib.request

import bltd_feeds as F

log = logging.getLogger("bltd.feeds.tradovate")

HTTP_TIMEOUT = 12.0
MD_WS = "wss://md.tradovateapi.com/v1/websocket"


def _base(env: str) -> str:
    return "https://live.tradovateapi.com/v1" if (env or "").strip().lower() == "live" \
        else "https://demo.tradovateapi.com/v1"


def _post_json(url, body, token=None, timeout=HTTP_TIMEOUT):
    data = json.dumps(body).encode("utf-8")
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            code = resp.getcode()
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace") if exc.fp else ""
        code = exc.code
    try:
        return code, (json.loads(raw) if raw else None)
    except (ValueError, TypeError):
        return code, None


def _get_json(url, token, timeout=HTTP_TIMEOUT):
    req = urllib.request.Request(url, headers={"Accept": "application/json",
                                               "Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace") if exc.fp else ""
    try:
        return json.loads(raw) if raw else None
    except (ValueError, TypeError):
        return None


# --- PURE response shaping (unit-tested without a network) -----------------
def tokens_from_auth(parsed: dict | None):
    """(accessToken, mdAccessToken) from an accessTokenRequest response, or (None, None).
    Raises nothing — the caller turns a None access token into an honest AuthError. PURE."""
    if not isinstance(parsed, dict):
        return None, None
    return parsed.get("accessToken"), parsed.get("mdAccessToken")


def auth_error_text(parsed: dict | None) -> str | None:
    """Human auth-failure reason from an accessTokenRequest response, or None if it looks OK."""
    if not isinstance(parsed, dict):
        return "no response from Tradovate auth"
    if parsed.get("accessToken"):
        return None
    if parsed.get("errorText"):
        return str(parsed["errorText"])
    if parsed.get("p-ticket"):
        return "Tradovate is rate-limiting/captcha-gating this login — wait and retry"
    return "Tradovate auth did not return an access token"


def pick_es_contract_name(contracts) -> str | None:
    """From a /contract/suggest list, pick the ES front-month contract name. PURE."""
    if not isinstance(contracts, list):
        return None
    names = []
    for c in contracts:
        name = c.get("name") if isinstance(c, dict) else (c if isinstance(c, str) else None)
        if name and F.map_es_symbol(name) == "ES":
            names.append(name)
    # Prefer a concrete e-mini (ESxN) over the micro (MESxN); among those, the shortest/front name.
    emini = [n for n in names if F.futures_root(n) == "ES"]
    return sorted(emini or names)[0] if (emini or names) else None


def authorize_response(frame_text: str, request_id: int = 1):
    """Inspect a Tradovate 'a' frame for the RESPONSE to request id *request_id*.

    Tradovate replies to every request (authorize, subscribeQuote, ...) with a frame of shape
    a[{"s": <httpStatus>, "i": <requestId>, "d": <data>}]. A non-2xx status means that request was
    REJECTED — e.g. a present-but-unentitled mdAccessToken (lapsed/absent CME market-data sub)
    returns a[{"s":401,"i":1,"d":"\\"Access is denied\\""}] for the authorize request. We must read
    that status, not blindly treat the first 'a' frame as a success ack (which would leave the user
    stuck on "connecting / awaiting ticks" forever with no honest reason).

    Returns (status:int|None, detail:str|None). status is None when this frame carries no response
    for *request_id*. PURE — unit-tested without a network."""
    if not frame_text or frame_text[0] != "a":
        return None, None
    try:
        msgs = json.loads(frame_text[1:])
    except (ValueError, TypeError):
        return None, None
    if not isinstance(msgs, list):
        return None, None
    for m in msgs:
        if not isinstance(m, dict) or m.get("i") != request_id or "s" not in m:
            continue
        try:
            status = int(m.get("s"))
        except (TypeError, ValueError):
            status = None
        d = m.get("d")
        detail = None
        if isinstance(d, str):
            detail = d.strip().strip('"') or None       # d is often a JSON-quoted string
        elif isinstance(d, dict):
            detail = d.get("errorText") or d.get("message") or d.get("text") or None
        return status, detail
    return None, None


def md_frame_candles(frame_text: str, symbol: str = "ES") -> list:
    """One Tradovate WS text frame -> list of normalized candle dicts (possibly empty). Handles
    the SockJS 'a[...]' message frame; ignores 'o'/'h'/'c' control frames. Uses entries.Trade.price
    as the close (and HighPrice/LowPrice/OpeningPrice if present). PURE — never fabricates: a quote
    with no Trade price yields nothing."""
    if not frame_text or frame_text[0] != "a":
        return []
    try:
        msgs = json.loads(frame_text[1:])
    except (ValueError, TypeError):
        return []
    out = []
    if not isinstance(msgs, list):
        return out
    for msg in msgs:
        if not isinstance(msg, dict) or msg.get("e") != "md":
            continue
        d = msg.get("d")
        if not isinstance(d, dict):
            continue
        for q in (d.get("quotes") or []):
            if not isinstance(q, dict):
                continue
            entries = q.get("entries")
            if not isinstance(entries, dict):
                continue
            trade = entries.get("Trade")
            if not isinstance(trade, dict) or trade.get("price") is None:
                continue   # bid/ask-only update: no last trade -> not a candle (never invent)
            cd = F.make_candle(
                symbol, trade.get("price"),
                open=_entry_price(entries.get("OpeningPrice")),
                high=_entry_price(entries.get("HighPrice")),
                low=_entry_price(entries.get("LowPrice")),
                epoch=_epoch(q.get("timestamp")))
            if cd:
                out.append(cd)
    return out


def _entry_price(entry):
    return entry.get("price") if isinstance(entry, dict) else None


def _epoch(ts):
    if isinstance(ts, (int, float)):
        return ts
    if isinstance(ts, str) and ts:
        try:
            from datetime import datetime
            return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
        except (ValueError, TypeError):
            return None
    return None


class TradovateSource(F.FeedSource):
    key = "tradovate"
    label = "Tradovate"
    kind = "api"
    cred_fields = [
        {"name": "name", "label": "Username", "secret": False, "placeholder": "Tradovate username"},
        {"name": "password", "label": "Password", "secret": True},
        {"name": "appId", "label": "App ID", "secret": False, "placeholder": "your API app name"},
        {"name": "appVersion", "label": "App version", "secret": False, "optional": True,
         "default": "1.0", "placeholder": "1.0"},
        {"name": "cid", "label": "API Key ID (cid)", "secret": False},
        {"name": "sec", "label": "API Secret", "secret": True},
        {"name": "env", "label": "Environment", "secret": False, "optional": True,
         "default": "demo", "placeholder": "demo or live"},
        {"name": "symbol", "label": "Contract (advanced)", "secret": False, "optional": True,
         "placeholder": "auto front-month (e.g. ESU5)"},
    ]
    note = ("Enter the API credentials issued to you in Tradovate (Application Settings → API "
            "Access: app name, key id/cid, and secret) plus your username/password. They stay in "
            "your macOS Keychain. Real-time market data requires a Tradovate market-data subscription.")

    def __init__(self, creds, on_candle, opts=None):
        super().__init__(creds, on_candle, opts)
        self._env = self._creds.get("env", "demo")
        self._access = None
        self._md = None

    def _authenticate(self):
        self._set(F.ST_AUTHENTICATING, "authenticating with Tradovate…")
        body = {
            "name": (self._creds.get("name") or "").strip(),
            "password": self._creds.get("password") or "",
            "appId": (self._creds.get("appId") or "Black Label Trading").strip(),
            "appVersion": (self._creds.get("appVersion") or "1.0").strip(),
            "cid": (self._creds.get("cid") or "").strip(),
            "sec": (self._creds.get("sec") or "").strip(),
        }
        dev = (self._creds.get("deviceId") or "").strip()
        if dev:
            body["deviceId"] = dev
        if not body["name"] or not body["password"]:
            raise F.AuthError("username and password are required")
        code, parsed = _post_json(f"{_base(self._env)}/auth/accessTokenRequest", body)
        err = auth_error_text(parsed)
        if err:
            raise F.AuthError(err)
        self._access, self._md = tokens_from_auth(parsed)
        if not self._md:
            raise F.AuthError("authenticated, but no market-data token returned — your account "
                              "may lack a Tradovate market-data subscription")
        # Resolve the ES contract symbol (explicit override wins).
        sym = (self._creds.get("symbol") or "").strip()
        if not sym:
            suggest = _get_json(
                f"{_base(self._env)}/contract/suggest?t=ES&l=10", self._access)
            sym = pick_es_contract_name(suggest)
        if not sym:
            raise F.AuthError("could not resolve an ES contract from Tradovate "
                              "— enter the contract symbol (e.g. ESU5) in the advanced field")
        self._symbol = sym
        self._set(F.ST_CONNECTING, f"authenticated · subscribing {sym}")

    def _run(self):
        backoff = 2.0
        while not self._stop.is_set():
            try:
                self._stream_once()
                backoff = 2.0
            except F.AuthError:
                raise
            except Exception as exc:  # noqa: BLE001
                self._set(F.ST_CONNECTING, f"reconnecting: {type(exc).__name__}")
                log.info("tradovate: stream ended (%s) — reconnecting in %.0fs", exc, backoff)
            if self._stop.is_set():
                break
            end = time.monotonic() + backoff
            while time.monotonic() < end and not self._stop.is_set():
                time.sleep(0.25)
            backoff = min(backoff * 1.7, 30.0)

    def _stream_once(self, _ws=None):
        # _ws is a test injection seam (a stub WS); production opens a real TLS WebSocket.
        ws = _ws if _ws is not None else F.WSConn(MD_WS)
        try:
            opened = False
            authed = False
            subbed = False
            last_hb = time.monotonic()
            while not self._stop.is_set():
                frame = ws.recv_text(max_wait=1.0)
                now = time.monotonic()
                if now - last_hb >= 2.5:           # client heartbeat keeps the socket alive
                    ws.send_text("[]")
                    last_hb = now
                if frame is None:
                    continue
                if not frame:
                    continue
                kind = frame[0]
                if kind == "o" and not opened:     # SockJS open -> authorize
                    opened = True
                    ws.send_text(f"authorize\n1\n\n{self._md}")
                elif kind == "a":
                    if not authed:
                        # The authorize reply also arrives as an 'a' frame. Tradovate signals a
                        # REJECTED authorize (an unentitled/lapsed market-data token — absent CME
                        # ILA) with an ERROR STATUS on request id 1, NOT by silently withholding
                        # ticks. So we must read that status instead of treating the first 'a' frame
                        # as a success ack — otherwise the user sits on "connecting / awaiting ticks"
                        # forever with no honest reason. A MISSING token is already caught at REST;
                        # this is the present-but-unentitled case. (status None -> no authorize
                        # response in this frame: fall through to the lenient ack, unchanged.)
                        status, detail = authorize_response(frame, request_id=1)
                        if status is not None and not (200 <= status < 300):
                            raise F.AuthError(
                                "Tradovate denied market-data access: "
                                f"{detail or ('status ' + str(status))}. Your account may lack an "
                                "active market-data subscription (e.g. CME ILA / non-pro data fees).")
                        authed = True
                        if not subbed:
                            ws.send_text("md/subscribeQuote\n2\n\n"
                                         + json.dumps({"symbol": self._symbol}))
                            subbed = True
                            self._set(F.ST_CONNECTING, f"subscribed {self._symbol} — awaiting ticks")
                    for cd in md_frame_candles(frame, self._symbol):
                        self._emit(cd)
                elif kind == "c":                  # SockJS close
                    raise ConnectionError("Tradovate sent a close frame")
                # 'h' heartbeat from server: ignore
        finally:
            ws.close()
