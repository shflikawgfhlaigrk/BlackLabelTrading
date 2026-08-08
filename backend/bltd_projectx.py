"""Black Label Trading — ProjectX Gateway API feed adapter (PRIMARY; powers TopstepX/Topstep).

The ProjectX Gateway API is the official programmatic interface behind TopstepX and a roster of
other prop firms (each firm is the same API on its own host). This adapter:

  1. REST auth with the buyer's OWN api key:
       POST https://<api-host>/api/Auth/loginKey
       body  {"userName": "<username>", "apiKey": "<api key>"}
       ->    {"token": "<JWT>", "success": true, "errorCode": 0, "errorMessage": null}
     (token is a 24h JWT; re-validatable at POST /api/Auth/validate)
  2. Resolve the ES contract id:
       POST /api/Contract/search  body {"searchText": "ES", "live": false}
       ->   {"contracts": [{"id": "CON.F.US.EP.U25", "name": "ESU5",
                            "description": "E-mini S&P 500: ...", ...}], "success": true}
     (the e-mini S&P root on ProjectX is "EP"; map_es_symbol handles EP/ES/MES/MEP -> ES)
  3. Real-time market data over the SignalR market hub:
       wss://<rtc-host>/hubs/market?access_token=<JWT>   (skipNegotiation + WebSockets transport)
       invoke "SubscribeContractQuotes"(contractId) and "SubscribeContractTrades"(contractId)
       receive "GatewayQuote"(contractId, data)  data.lastPrice / bestBid / bestAsk / volume / timestamp
               "GatewayTrade"(contractId, data)  data.price / size / timestamp
     Each real tick -> a normalized candle into the shared store. No order is ever placed.

Defaults target TopstepX (api.topstepx.com / rtc.topstepx.com). The host is buyer-overridable for
other ProjectX firms (e.g. gateway-api-demo.s2f.projectx.com / gateway-rtc-demo...).

ZERO FABRICATION: a quote with no usable lastPrice/price is dropped — never invented. The adapter
gates honestly on a rejected key (auth_error) and on a missing market-data entitlement (it stays
connected/idle with an honest detail rather than faking ticks).
"""
from __future__ import annotations

import json
import logging
import time
import urllib.error
import urllib.request

import bltd_feeds as F

log = logging.getLogger("bltd.feeds.projectx")

# TopstepX defaults; overridable per firm via the "apiHost"/"rtcHost" creds (ProjectX firms differ
# only by host). We accept a bare host or a full URL and normalize.
DEFAULT_API_HOST = "api.topstepx.com"
DEFAULT_RTC_HOST = "rtc.topstepx.com"
HTTP_TIMEOUT = 12.0


def _host(value: str, fallback: str) -> str:
    v = (value or "").strip()
    if not v:
        return fallback
    if v.startswith("http://") or v.startswith("https://") or v.startswith("wss://"):
        from urllib.parse import urlparse
        return urlparse(v).hostname or fallback
    return v.rstrip("/")


def _post_json(url: str, body: dict, token: str | None = None, timeout: float = HTTP_TIMEOUT):
    """POST JSON, return (status_code, parsed_json|None, raw_text). Never raises on HTTP error —
    returns the error body so the caller can report an honest auth failure."""
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
        parsed = json.loads(raw) if raw else None
    except (ValueError, TypeError):
        parsed = None
    return code, parsed, raw


# --- PURE response shaping (unit-tested without a network) -----------------
def pick_tradable_account(parsed: dict | None, prefer_name: str | None = None) -> dict | None:
    """From a /api/Account/search response, pick a TRADABLE account (canTrade truthy). If prefer_name
    is given, match it (case-insensitive) first. Returns {id, name, ...} or None. PURE. (Field shapes
    per the docs; confirmed during demo validation.)"""
    if not isinstance(parsed, dict):
        return None
    accts = parsed.get("accounts")
    if not isinstance(accts, list):
        return None
    tradable = [a for a in accts if isinstance(a, dict) and a.get("id") is not None
                and a.get("canTrade", True)]
    if prefer_name:
        for a in tradable:
            if str(a.get("name", "")).lower() == prefer_name.lower():
                return a
    return tradable[0] if tradable else None


def token_from_login(parsed: dict | None) -> str | None:
    """Extract the JWT from a /api/Auth/loginKey response, or None if the login was rejected."""
    if not isinstance(parsed, dict):
        return None
    if parsed.get("success") is False:
        return None
    tok = parsed.get("token")
    return tok if isinstance(tok, str) and tok else None


def _contract_symbol(contract: dict) -> str | None:
    if not isinstance(contract, dict):
        return None
    for field in ("name", "contractName", "symbol", "id", "description"):
        sym = F.map_market_symbol(contract.get(field))
        if sym:
            return sym
    return None


def pick_contract(parsed: dict | None, prefer_symbol: str = "ES") -> dict | None:
    """From a /api/Contract/search response, pick the requested contract.

    The shipped store/chart plane is ES-family scoped, but this protocol helper can still inspect
    a wider contract list. It matches by canonical futures root when a requested symbol is supplied,
    prefers active contracts, and falls back to the first recoverable contract when no exact root
    match is available."""
    if not isinstance(parsed, dict):
        return None
    contracts = parsed.get("contracts")
    if not isinstance(contracts, list):
        return None
    requested = F.canonical_root(F.futures_root(prefer_symbol or "ES"))
    exact = []
    for c in contracts:
        if not isinstance(c, dict):
            continue
        sym = _contract_symbol(c)
        if not sym:
            continue
        root = F.canonical_root(F.futures_root(sym))
        if root == requested:
            exact.append(c)
    pool = exact
    if not pool:
        return None
    # Front month = smallest contract id lexically is not reliable; prefer one flagged active if
    # present, else the first returned (search returns front-month first).
    active = [c for c in pool if c.get("activeContract") is True]
    return (active or pool)[0]


def pick_es_contract(parsed: dict | None) -> dict | None:
    """Back-compat wrapper for older tests/callers that explicitly need an ES-family contract."""
    return pick_contract(parsed, "ES")


def quote_candle(contract_name: str, data: dict) -> dict | None:
    """GatewayQuote payload -> normalized candle (uses lastPrice; bid/ask ignored for the bar).
    Drops a quote that carries no usable last price (never fabricates). PURE."""
    if not isinstance(data, dict):
        return None
    last = data.get("lastPrice")
    if last is None:
        last = data.get("last")           # tolerate a leaner shape
    sym = F.map_market_symbol(contract_name)
    if sym is None:
        return None
    return F.make_candle(sym, last, epoch=_epoch(data.get("timestamp")))


def trade_candle(contract_name: str, data: dict) -> dict | None:
    """GatewayTrade payload -> normalized candle (uses the trade price). PURE."""
    if not isinstance(data, dict):
        return None
    sym = F.map_market_symbol(contract_name)
    if sym is None:
        return None
    return F.make_candle(sym, data.get("price"), epoch=_epoch(data.get("timestamp")))


def _epoch(ts):
    """ProjectX timestamps are ISO-8601 strings or epoch numbers; make_candle wants a number or
    None. Parse the common ISO form; otherwise let make_candle stamp arrival."""
    if isinstance(ts, (int, float)):
        return ts
    if isinstance(ts, str) and ts:
        s = ts.replace("Z", "+00:00")
        try:
            from datetime import datetime
            return datetime.fromisoformat(s).timestamp()
        except (ValueError, TypeError):
            return None
    return None


class ProjectXSource(F.FeedSource):
    key = "projectx"
    label = "TopstepX / ProjectX"
    kind = "api"
    cred_fields = [
        {"name": "username", "label": "Username", "secret": False,
         "placeholder": "your TopstepX username"},
        {"name": "apiKey", "label": "API Key", "secret": True,
         "placeholder": "from TopstepX → Settings → API Key"},
        {"name": "symbol", "label": "Contract (advanced)", "secret": False, "optional": True,
         "default": "ES", "placeholder": "ES, NQ, CL, GC…"},
        {"name": "apiHost", "label": "API host (advanced)", "secret": False, "optional": True,
         "default": DEFAULT_API_HOST, "placeholder": DEFAULT_API_HOST},
        {"name": "rtcHost", "label": "Market hub host (advanced)", "secret": False,
         "optional": True, "default": DEFAULT_RTC_HOST, "placeholder": DEFAULT_RTC_HOST},
    ]
    note = ("Enter your TopstepX username and API Key (TopstepX → Settings → API Key). The key "
            "stays in your macOS Keychain and is used only to authenticate to your own account. "
            "Real-time market data requires the API market-data add-on on your TopstepX account.")

    def __init__(self, creds, on_candle, opts=None):
        super().__init__(creds, on_candle, opts)
        self._api = _host(self._creds.get("apiHost"), DEFAULT_API_HOST)
        self._rtc = _host(self._creds.get("rtcHost"), DEFAULT_RTC_HOST)
        self._token = None
        self._contract_id = None
        self._contract_name = None
        self._requested_symbol = (self._creds.get("symbol") or "ES").strip().upper() or "ES"

    # -- auth + contract resolve (synchronous; reports auth_error immediately) ----
    def _authenticate(self):
        self._set(F.ST_AUTHENTICATING, "authenticating with TopstepX…")
        username = (self._creds.get("username") or "").strip()
        api_key = (self._creds.get("apiKey") or "").strip()
        if not username or not api_key:
            raise F.AuthError("username and API key are required")
        code, parsed, _ = _post_json(
            f"https://{self._api}/api/Auth/loginKey",
            {"userName": username, "apiKey": api_key})
        token = token_from_login(parsed)
        if not token:
            msg = (parsed or {}).get("errorMessage") if isinstance(parsed, dict) else None
            raise F.AuthError(msg or f"login rejected (HTTP {code}) — check your username/API key")
        self._token = token
        # Resolve the buyer-selected contract to subscribe to. Default remains ES, but a prop-account
        # buyer can enter NQ/MNQ/CL/etc. and see that instrument's own feed.
        search = F.canonical_root(F.futures_root(self._requested_symbol))
        code, parsed, _ = _post_json(
            f"https://{self._api}/api/Contract/search",
            {"searchText": search, "live": False}, token=token)
        contract = pick_contract(parsed, self._requested_symbol)
        if not contract:
            # Some firms expose /api/Contract/available instead of /search.
            code, parsed, _ = _post_json(
                f"https://{self._api}/api/Contract/available", {"live": False}, token=token)
            contract = pick_contract(parsed, self._requested_symbol)
        if not contract:
            raise F.AuthError(f"authenticated, but no {self._requested_symbol} contract was returned "
                              "— your account may lack futures market-data entitlement")
        self._contract_id = contract.get("id")
        self._contract_name = _contract_symbol(contract) or self._requested_symbol
        self._symbol = self._contract_name
        self._set(F.ST_CONNECTING, f"authenticated · subscribing {self._contract_name}")

    # -- market-data stream (SignalR market hub over wss) ------------------------
    def _run(self):
        backoff = 2.0
        while not self._stop.is_set():
            try:
                self._stream_once()
                backoff = 2.0
            except F.AuthError:
                raise
            except Exception as exc:  # noqa: BLE001 — socket dropped: reconnect with backoff
                self._set(F.ST_CONNECTING, f"reconnecting: {type(exc).__name__}")
                log.info("projectx: stream ended (%s) — reconnecting in %.0fs", exc, backoff)
            if self._stop.is_set():
                break
            self._wait(backoff)
            backoff = min(backoff * 1.7, 30.0)

    def _wait(self, secs):
        end = time.monotonic() + secs
        while time.monotonic() < end and not self._stop.is_set():
            time.sleep(0.25)

    def _stream_once(self):
        url = f"wss://{self._rtc}/hubs/market?access_token={self._token}"
        ws = F.WSConn(url)
        try:
            hub = F.SignalRJson(ws)
            hub.handshake()
            hub.invoke("SubscribeContractQuotes", self._contract_id)
            hub.invoke("SubscribeContractTrades", self._contract_id)
            self._set(F.ST_CONNECTING, f"subscribed {self._contract_name} — awaiting ticks")
            last_ping = time.monotonic()
            while not self._stop.is_set():
                for rec in hub.records(max_wait=1.0):
                    self._handle(rec)
                if time.monotonic() - last_ping > 12.0:
                    hub.ping()
                    last_ping = time.monotonic()
        finally:
            ws.close()

    def _handle(self, rec: dict):
        if not isinstance(rec, dict) or rec.get("type") != 1:
            return
        target = rec.get("target")
        args = rec.get("arguments") or []
        if len(args) < 2 or not isinstance(args[1], dict):
            return
        cid, data = args[0], args[1]
        # Trust the subscribed contract name for symbol mapping (the event echoes the contract id).
        if target == "GatewayQuote":
            self._emit(quote_candle(self._contract_name, data))
        elif target == "GatewayTrade":
            self._emit(trade_candle(self._contract_name, data))
