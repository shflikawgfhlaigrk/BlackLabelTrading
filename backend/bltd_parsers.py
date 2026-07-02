"""Black Label Trading — pluggable multi-platform candle/tick parser registry.

The capture daemon scrapes the realtime WebSocket of ANY logged-in trading web platform in the
product's debug Chrome (CDP Network.webSocketFrameReceived). Different platforms use different
frame formats, so each platform gets a parser here. A parser turns one raw WS payload string into
a NORMALIZED candle dict, or None.

NORMALIZED CANDLE: {symbol:str, open:float|None, high:float|None, low:float|None,
                    close:float (REQUIRED), epoch:int|None}
  - close is mandatory; a frame with no usable close is NOT a candle -> None (never fabricate).
  - epoch None means "no trustworthy timestamp" -> the capture loop stamps arrival wall-clock.

FAIL-CLOSED: every parser returns None unless it is confident the frame is real market data. We
drop unknown/auth/telemetry frames rather than invent a price. Adding a platform = add one class.

Coverage strategy: a PROVEN per-platform parser for WealthCharts (delegates to the battle-tested
bltd_store.parse_candle), best-effort per-platform parsers for the common prop-firm platforms
(TradingView / Tradovate), and a conservative GENERIC heuristic parser that recognizes common
OHLC / last-price JSON shapes on ANY platform — so a brand-new broker's feed is scraped on day one
without hand-coding it, as long as its frames carry a recognizable symbol + price.
"""
from __future__ import annotations

import json
import re

import bltd_store as S


def _num(v):
    """Coerce to a finite float, or None. Rejects NaN/inf and junk — never fabricates."""
    if v is None or isinstance(v, bool):
        return None
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f != f or f in (float("inf"), float("-inf")):
        return None
    return f


def _candle(symbol, close, *, open=None, high=None, low=None, epoch=None, volume=None, delta=None):
    c = _num(close)
    if not symbol or c is None:
        return None
    return {"symbol": str(symbol), "open": _num(open), "high": _num(high),
            "low": _num(low), "close": c,
            "epoch": (int(epoch) if isinstance(epoch, (int, float)) and epoch == epoch else None),
            "volume": _num(volume) or 0.0, "delta": _num(delta) or 0.0}


# ===========================================================================
# Per-platform parsers
# ===========================================================================
class WealthChartsParser:
    """PROVEN reference — delegates to the battle-tested store parser (zero behavior change)."""
    name = "wealthcharts"
    hosts = ("wealthcharts.com",)

    def detect(self, payload: str) -> bool:
        return '"cmd"' in payload and '"feed"' in payload and '"candle"' in payload

    def parse(self, payload: str):
        return S.parse_candle(payload)   # already returns the normalized dict (or None)


class TradingViewParser:
    """TradingView pushes socket.io-style frames `~m~<len>~m~{json}`; quote-stream messages carry
    `qsd`/`du` with a last price `lp` (and sometimes OHLC). Best-effort, fail-closed."""
    name = "tradingview"
    hosts = ("tradingview.com", "tradingview-widget.com", "prodata.tradingview.com")

    def detect(self, payload: str) -> bool:
        return "~m~" in payload and ('"qsd"' in payload or '"du"' in payload or '"lp"' in payload)

    def parse(self, payload: str):
        try:
            for chunk in re.split(r"~m~\d+~m~", payload):
                chunk = chunk.strip()
                if not chunk.startswith("{"):
                    continue
                obj = json.loads(chunk)
                p = obj.get("p")
                if not isinstance(p, list) or len(p) < 2 or not isinstance(p[1], dict):
                    continue
                d = p[1]
                sym = d.get("n") or d.get("s")
                v = d.get("v") if isinstance(d.get("v"), dict) else d
                if not sym or not isinstance(v, dict):
                    continue
                cd = _candle(sym, v.get("lp"), open=v.get("open_price"),
                             high=v.get("high_price"), low=v.get("low_price"),
                             epoch=v.get("lp_time"))
                if cd:
                    return cd
        except (ValueError, TypeError, KeyError):
            pass
        return None


class TradovateParser:
    """Tradovate (and the NinjaTrader-group futures stack many prop firms use) streams over a
    SockJS-ish channel: array-wrapped JSON `a[{...}]` with md/chart payloads. Best-effort."""
    name = "tradovate"
    hosts = ("tradovate.com", "topstepx.com")

    def detect(self, payload: str) -> bool:
        return (payload[:2] == "a[" or payload[:1] == "[") and ('"md"' in payload or '"bars"' in payload
                                                                 or '"tradePrice"' in payload or '"close"' in payload)

    def parse(self, payload: str):
        try:
            body = payload[1:] if payload[:1] == "a" else payload   # strip SockJS 'a' frame marker
            arr = json.loads(body)
            if not isinstance(arr, list):
                return None
            for msg in arr:
                if isinstance(msg, str):
                    try:
                        msg = json.loads(msg)
                    except (ValueError, TypeError):
                        continue
                if not isinstance(msg, dict):
                    continue
                d = msg.get("d") if isinstance(msg.get("d"), dict) else msg
                sym = d.get("symbol") or d.get("contract") or d.get("s")
                # bar shape
                bars = d.get("bars")
                if sym and isinstance(bars, list) and bars and isinstance(bars[-1], dict):
                    b = bars[-1]
                    cd = _candle(sym, b.get("close"), open=b.get("open"), high=b.get("high"),
                                 low=b.get("low"), epoch=b.get("timestamp"),
                                 volume=b.get("volume"), delta=b.get("delta"))
                    if cd:
                        return cd
                # tick shape
                price = d.get("tradePrice") or d.get("last") or d.get("close")
                if sym and price is not None:
                    cd = _candle(sym, price, epoch=d.get("timestamp"))
                    if cd:
                        return cd
        except (ValueError, TypeError, KeyError):
            pass
        return None


# Symbol / price / ohlc field-name candidates the generic sniffer understands.
_SYM_KEYS = ("symbol", "s", "sym", "ticker", "instrument", "contract", "n", "id", "epic")
_CLOSE_KEYS = ("close", "c", "lp", "last", "lastPrice", "price", "p", "bid", "ask", "mid")
_OPEN_KEYS = ("open", "o", "openPrice")
_HIGH_KEYS = ("high", "h", "highPrice")
_LOW_KEYS = ("low", "l", "lowPrice")
_TS_KEYS = ("epoch", "time", "timestamp", "ts", "t", "lp_time", "datetime")
_PLAUSIBLE = (0.0001, 10_000_000.0)   # sane price band — rejects ids/quantities masquerading as prices
_NON_MARKET_KEYS = ("qty", "quantity", "size", "amount", "side", "status", "orderid", "order_id",
                    "accountid", "account_id", "balance", "pnl", "unrealizedpnl",
                    "realizedpnl", "filled", "execution", "positionid", "position_id")


class GenericOHLCParser:
    """Conservative heuristic for ANY platform: scan a frame's JSON for a (symbol, price) pair and
    optional OHLC, in any common naming. Emits a candle ONLY when it finds a recognizable symbol +
    a plausible price (full OHLC strongly preferred). Fail-closed — drops anything ambiguous so it
    never turns account/order/telemetry JSON into a fake price. This is what lets a brand-new
    broker's feed be scraped without hand-coding its format."""
    name = "generic"
    hosts = ()    # tried last, for every page

    def detect(self, payload: str) -> bool:
        return payload[:1] in ("{", "[") and any(k in payload for k in ('"c"', '"close"', '"lp"',
                                                                          '"last"', '"price"', '"p"'))

    def parse(self, payload: str):
        try:
            obj = json.loads(payload)
        except (ValueError, TypeError):
            return None
        return self._scan(obj, depth=0)

    def _scan(self, node, depth):
        if depth > 6:
            return None
        if isinstance(node, list):
            for item in reversed(node):          # latest entry first
                cd = self._scan(item, depth + 1)
                if cd:
                    return cd
            return None
        if not isinstance(node, dict):
            return None
        cd = self._from_dict(node)
        if cd:
            return cd
        for v in node.values():                  # recurse into nested payloads (d/data/msg wrappers)
            if isinstance(v, (dict, list)):
                cd = self._scan(v, depth + 1)
                if cd:
                    return cd
        return None

    def _from_dict(self, d):
        if any(k.lower() in _NON_MARKET_KEYS for k in d):
            return None
        sym = next((d[k] for k in _SYM_KEYS if isinstance(d.get(k), str) and d[k].strip()), None)
        if not sym:
            return None
        close = next((_num(d[k]) for k in _CLOSE_KEYS if _num(d.get(k)) is not None), None)
        if close is None or not (_PLAUSIBLE[0] <= close <= _PLAUSIBLE[1]):
            return None
        o = next((_num(d[k]) for k in _OPEN_KEYS if _num(d.get(k)) is not None), None)
        h = next((_num(d[k]) for k in _HIGH_KEYS if _num(d.get(k)) is not None), None)
        lo = next((_num(d[k]) for k in _LOW_KEYS if _num(d.get(k)) is not None), None)
        ts = next((d[k] for k in _TS_KEYS if isinstance(d.get(k), (int, float))), None)
        # Timestamps are often ms or non-unix; only keep a plausible unix-seconds value, else None.
        epoch = int(ts) if isinstance(ts, (int, float)) and 1_000_000_000 <= ts <= 4_000_000_000 else None
        vol = next((_num(d[k]) for k in ("volume", "vol", "v") if _num(d.get(k)) is not None), None)
        dlt = next((_num(d[k]) for k in ("delta", "cvd", "orderFlowDelta") if _num(d.get(k)) is not None), None)
        return _candle(sym, close, open=o, high=h, low=lo, epoch=epoch, volume=vol, delta=dlt)


# ===========================================================================
# Registry + dispatch
def _topstep_sym(s):
    """ProjectX/TopstepX contract id -> short symbol. F.US.MES -> MES ; CON.F.US.MES.U26 -> MES."""
    if not s or not isinstance(s, str):
        return None
    parts = s.split(".")
    if "US" in parts:
        i = parts.index("US")
        if i + 1 < len(parts):
            return parts[i + 1]
    return parts[-1]


class TopstepXParser:
    """TopstepX / ProjectX SignalR market feed. Frames look like
    {"type":1,"target":"RealTimeContractQuote","arguments":[{"symbol":"F.US.MES","bestBid":..,"bestAsk":..}]}
    (also RealTimeDom / RealTimeTilt / {"type":6} keepalives, which carry no tradable price -> None).
    ProjectX streams quotes/DOM, NOT OHLC bars, so we emit a close-only price tick from the quote mid
    (or the single available side); the store builds bars from the tick stream. Symbol F.US.MES -> MES.
    Fail-closed: only a RealTimeContractQuote with a real numeric price yields a candle (never fabricates
    from Tilt/sentiment/account frames)."""
    name = "topstepx"
    hosts = ("topstepx.com",)

    def detect(self, payload: str) -> bool:
        p = payload.lstrip()
        return p.startswith('{"type"') or p.startswith('{"protocol"') or '"target":"RealTime' in p

    def parse(self, payload: str):
        # SignalR JSON protocol packs MULTIPLE messages into one WS frame, each terminated by the
        # 0x1e record separator. json.loads on the whole frame throws "Extra data" — so split first.
        cd = None
        for rec in payload.split("\x1e"):
            if '"RealTimeContractQuote"' not in rec:
                continue
            try:
                m = json.loads(rec)
            except (ValueError, TypeError):
                continue
            if not isinstance(m, dict) or m.get("type") != 1 or m.get("target") != "RealTimeContractQuote":
                continue
            args = m.get("arguments")
            if not isinstance(args, list) or not args or not isinstance(args[0], dict):
                continue
            q = args[0]
            sym = q.get("symbol") or q.get("contract")
            last = q.get("lastPrice") if q.get("lastPrice") is not None else q.get("last")
            bid, ask = q.get("bestBid"), q.get("bestAsk")
            if last is not None:
                price = last
            elif bid is not None and ask is not None:
                price = (bid + ask) / 2.0
            elif bid is not None:
                price = bid
            elif ask is not None:
                price = ask
            else:
                continue
            c = _candle(_topstep_sym(sym), price)
            if c:
                cd = c   # last valid quote in the frame wins (freshest)
        return cd


# ===========================================================================
# Order matters: proven/specific parsers first, generic sniffer LAST (fallback for any platform).
# TopstepX before Tradovate so SignalR frames route to the real ProjectX parser, not the SockJS one.
_PARSERS = [WealthChartsParser(), TradingViewParser(), TopstepXParser(), TradovateParser(), GenericOHLCParser()]

# Host substrings that mark a tab as "a trading platform we should scrape".
FEED_HOSTS = ("wealthcharts.com", "tradingview.com", "tradovate.com", "topstepx.com",
              "metatraderweb", "web.metatrader", "ctrader.com", "dxtrade", "match-trader",
              "dx.trade", "trade.")


def page_is_feed(url: str) -> bool:
    """Is this browser tab a trading platform we should attach a scraper to?"""
    u = (url or "").lower()
    return any(h in u for h in FEED_HOSTS)


def platforms_for_host(url: str):
    """Candidate parsers for a page, host-specific first, then the generic sniffer."""
    u = (url or "").lower()
    specific = [p for p in _PARSERS if p.hosts and any(h in u for h in p.hosts)]
    generic = [p for p in _PARSERS if not p.hosts]
    return (specific + generic) if specific else list(_PARSERS)


def pick_parser(payload: str, candidates):
    """First candidate whose detect() claims the frame. Cached per socket by the caller."""
    for p in candidates:
        try:
            if p.detect(payload):
                return p
        except Exception:  # noqa: BLE001
            continue
    return None
