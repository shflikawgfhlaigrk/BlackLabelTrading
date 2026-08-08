"""Black Label Trading — the product's OWN local store + webhook/browser-capture helpers + edge gate.

SELF-CONTAINED. This module is the product's whole data + analysis spine. It has ZERO
dependency on Michael's Utah/Postgres: the store is a local SQLite database the product owns
(default ~/Library/Application Support/Black Label Trading/trading.sqlite3), the engines run
in-process here in pure stdlib Python, and webhook/browser capture writes the BUYER's own
bars/ticks/fires into this store. Nothing is baked in — the database starts EMPTY and is filled
only by the buyer's own pushed or captured feed at runtime.

- stdlib-only (sqlite3 + json) — no Postgres driver, no utah, no third-party deps.
- Cold/unreachable store degrades to an honest empty payload, never a crash, never a fabricated
  number (same contract the old Postgres backend had).
- Engine math (meanrev / breakout / research) is ported from utah.product.backtest /
  research_signal / the verified Swift Engines.swift — same bars in, same OOS verdict out.

The capture helpers (parse_candle / normalize_epoch / ohlc_bars) are ported pure from
utah.integrations.wc_feed so a live tick produces a real closed bar identically to Utah.
"""
from __future__ import annotations

import json
import math
import os
import re
import sqlite3
import threading
import time
from decimal import Decimal, InvalidOperation, ROUND_CEILING, ROUND_FLOOR

import bltd_paths   # cross-platform app-support paths (macOS gold master + Windows W1 port)

# ---------------------------------------------------------------------------
# Default own-store location (the product owns this; NOT Michael's Utah Postgres).
# Override with BLTD_STORE for tests / a custom path. The legacy Utah Postgres DSN is reachable
# ONLY through the opt-in dev override in bltd_api.py — never the default, and never from here.
# The per-OS base is resolved in bltd_paths (darwin path byte-identical to the historical one).
# ---------------------------------------------------------------------------
def default_store_path() -> str:
    return bltd_paths.store_path()


def default_config_path() -> str:
    return bltd_paths.config_path()


# Seven distinct strategy implementations run live. Two retired ids remain registered for old
# journals/reference evidence and permanently remain in the multiplicity family.
ACTIVE_ENGINE_FAMILY = ("meanrev", "breakout", "momentum", "structure",
                        "regime", "channel", "context_b")
DUPLICATE_ENGINE_ALIASES = {"research": "breakout", "context_a": "momentum"}
FDR_ENGINE_FAMILY = ("meanrev", "breakout", "research", "momentum", "structure", "regime",
                     "channel", "context_a", "context_b")
_KNOWN_ENGINES = FDR_ENGINE_FAMILY


# ---------------------------------------------------------------------------
# Buyer-tunable config (NOT hardcoded). Persisted as JSON the product owns; read by the capture
# daemon (engine geometry / which engines run / symbol filter / edge gate) and the store (edge
# gate floor). The Swift Settings surface writes it via the backend /api/config endpoint. Every
# value is range-clamped so a bad write can never crash or de-honest the gate.
# ---------------------------------------------------------------------------
CONFIG_DEFAULTS = {
    # Only distinct implementations run live. Retired duplicate aliases stay in PROVERS and the
    # immutable FDR family so their historical tests continue to count against multiplicity.
    "engines": list(ACTIVE_ENGINE_FAMILY),
    "lookback": 20,            # bars of context for the signal window
    "barSeconds": 15,          # bucket size of a closed bar
    "oosFrac": 0.4,            # held-out fraction for the OOS edge proof
    "minTrades": 20,           # min OOS trades before an edge can be "proven"
    "edgeGate": True,          # require proven OOS edge before a fire (NEVER fire blind)
    "mrZ": 2.0,                # mean-reversion z-score entry threshold
    "mrTgtFrac": 0.6,          # mean-reversion target as fraction of the move back to mean
    "mrStopMult": 8.0,         # mean-reversion stop in sd multiples
    "mrWinFloor": 0.87,        # mean-reversion OOS win-rate floor to count as edge
    "bkTargetR": 2.0,          # breakout reward:risk target
    "bkMaxHold": 80,           # bounded bars in a breakout/research trade (entry bar included)
    "researchTickSize": 0.25,  # legal ES/MES price increment for conservative research fills
    "fdrQ": 0.10,              # Benjamini–Hochberg false-discovery rate for the screen grid (across
                              # all engine×symbol cells) so the candidate count isn't inflated by grid size
    "symbols": [],             # capture filter: EMPTY = accept every in_scope symbol. A non-empty
                               # list must name the feed's own codes; ["ES"] dropped 100% of
                               # prop-feed bars (MESU6/CM.ESU6 never string-match "ES").
    # Manual planning / prop-firm reference values. They never route an order.
    "accountSize": 50000.0,
    "riskPerTradePct": 1.0,
    "maxDailyLossPct": 3.0,
    "maxTrades": 0,            # 0 = unlimited
    "propFirm": "",            # free-text label of the buyer's prop firm
    # Legacy planning/state keys retained for database compatibility; no shipping order route reads them.
    "execMaxContracts": 0,
    "execMaxDrawdown": 0.0,
    # alert/signal delivery channels (the daemon writes a fire; channels mirror it out)
    "alertSound": True,
    "alertWebhook": "",        # POST each fire as JSON to this URL (e.g. Discord/Slack)
    # TR-06 honest edge-gate ALERT channel (bltd_alerts): posts the gate VERDICT — incl. "no edge" —
    # to an endpoint the buyer owns. OFF by default; empty endpoint => zero egress. Never a relay,
    # never an aggregate win-rate/$ figure. See bltd_alerts.py for the full posture.
    "alertEnabled": False,     # master switch; False => bltd_alerts makes no network call at all
    "alertEndpoint": "",       # buyer's OWN https:// endpoint (ntfy topic / webhook / Shortcuts)
    "alertProvider": "ntfy",   # ntfy | pushover | webhook — how the body is shaped
    "alertPushoverToken": "",  # Pushover app token (buyer's own), only for the pushover provider
    "alertPushoverUser": "",   # Pushover user key (buyer's own), only for the pushover provider
}

_CONFIG_RANGES = {
    "lookback": (3, 200), "barSeconds": (1, 3600), "oosFrac": (0.1, 0.9),
    "minTrades": (1, 1000), "mrZ": (0.5, 6.0), "mrTgtFrac": (0.05, 1.0),
    "mrStopMult": (0.5, 50.0), "mrWinFloor": (0.0, 1.0), "bkTargetR": (0.25, 20.0),
    "bkMaxHold": (1, 10000), "researchTickSize": (0.0001, 100.0),
    # The production edge gate never permits a looser false-discovery budget than the documented
    # q=0.10 family. Research tools may be stricter, but a config write cannot silently relax it.
    "fdrQ": (0.001, 0.10),
    "accountSize": (0.0, 1e9), "riskPerTradePct": (0.0, 100.0),
    "maxDailyLossPct": (0.0, 100.0), "maxTrades": (0, 100000),
    "execMaxContracts": (0, 1000), "execMaxDrawdown": (0.0, 1e9),
}
ES_ROOT = "ES"
MES_ROOT = "MES"  # micro E-mini S&P — the most-traded TopStep instrument; first-class family member
_ES_MONTH_CODES = "FGHJKMNQUVXZ"
_ES_CONTRACT_RE = re.compile(rf"^M?ES[{_ES_MONTH_CODES}]\d{{1,2}}$")


def normalize_symbol(symbol) -> str:
    """Normalize feed/platform symbols to the customer-facing futures token.

    WealthCharts emits contract names like CM.ESU6. Users may also type ES or /ES. The engine
    product is intentionally ES-only, so this helper exists to make that rule testable at every
    boundary instead of scattering string checks through the capture/API code."""
    s = str(symbol or "").strip().upper()
    if not s:
        return ""
    if "." in s:
        s = s.split(".")[-1]
    s = s.lstrip("/@")
    return "".join(ch for ch in s if ch.isalnum())


def is_es_symbol(symbol) -> bool:
    """ES *family*: ES and MES (micro), root or dated contract."""
    s = normalize_symbol(symbol)
    return s in (ES_ROOT, MES_ROOT) or bool(_ES_CONTRACT_RE.match(s))


def es_symbols(symbols) -> list[str]:
    out = []
    seen = set()
    for sym in symbols or []:
        raw = str(sym or "").strip()
        if raw and is_es_symbol(raw) and raw not in seen:
            seen.add(raw)
            out.append(raw)
    return out


# ---------------------------------------------------------------------------
# INSTRUMENT SCOPE. WealthCharts can stream multiple real instruments, so the product default is to
# accept any sane symbol the buyer's own browser feed emits. Developers can still set BLTD_SCOPE=es
# to exercise the legacy Topstep-only release scope in tests.
# ---------------------------------------------------------------------------
INSTRUMENT_SCOPE = (os.environ.get("BLTD_SCOPE", "all") or "all").strip().lower()


def futures_root_any(symbol) -> str:
    """Futures root of ANY instrument symbol ('CM.ESU6'->'ES', 'MNQU6'->'MNQ', 'EURUSD'->'EURUSD').
    Used by the execution ledger to net contracts/positions by instrument. Mirrors bltd_exec."""
    s = normalize_symbol(symbol)
    if len(s) >= 3 and s[-1].isdigit():
        i, d = len(s) - 1, 0
        while i >= 0 and s[i].isdigit():
            i -= 1; d += 1
        if 1 <= d <= 2 and i >= 1 and s[i] in _ES_MONTH_CODES:
            return s[:i]
    return s


# ---------------------------------------------------------------------------
# INSTRUMENT CLASSIFICATION (TR-05 multi-asset product layer).
#
# The capture layer is already instrument-agnostic (BLTD_SCOPE=all): the buyer's own browser bridge
# streams whatever instruments they watch (ES, MNQ, CL, SPY, QQQ, …) straight into the SAME store via
# the SAME on_candle path. What was missing was a PRODUCT surface that enumerates those instruments,
# classifies each honestly, and states which ES-tuned modules do/do not apply. This section is that
# classifier — PURE, no store, no network. It NEVER invents an instrument the buyer doesn't have; the
# catalog (bltd_analytics.instruments) only ever classifies symbols already present in the buyer's bars.
#
# Point values are declared ONLY where the CME/exchange contract spec is genuinely known; an unmapped
# instrument returns pointValue=None so the UI shows points, never dollars computed with a wrong (e.g.
# ES $50) multiplier. Asset class is a real bucket, not a guess: a CME venue prefix + a known futures
# root classifies as that future; a US-equity venue prefix classifies as an ETF/equity; anything else
# is honestly labeled "other" rather than mis-bucketed.
# ---------------------------------------------------------------------------

# root -> ($ per 1.00 point, asset_class). Mirrors the Swift TradingSymbolScope.pointValues table and
# extends it with the asset bucket. Only KNOWN specs are listed.
_FUTURES_SPECS = {
    # US equity-index futures (ES-family is handled separately as es_family=True)
    "ES": (50.0, "us_index_future"),   "MES": (5.0, "us_index_future"),
    "EP": (50.0, "us_index_future"),
    "NQ": (20.0, "us_index_future"),   "MNQ": (2.0, "us_index_future"),
    "YM": (5.0, "us_index_future"),    "MYM": (0.5, "us_index_future"),
    "RTY": (50.0, "us_index_future"),  "M2K": (5.0, "us_index_future"),
    # energy futures
    "CL": (1000.0, "energy_future"),   "MCL": (100.0, "energy_future"),
    "NG": (10000.0, "energy_future"),  "RB": (42000.0, "energy_future"),
    "HO": (42000.0, "energy_future"),  "QM": (500.0, "energy_future"),
    # metal futures
    "GC": (100.0, "metal_future"),     "MGC": (10.0, "metal_future"),
    "SI": (5000.0, "metal_future"),    "SIL": (1000.0, "metal_future"),
    "HG": (25000.0, "metal_future"),   "PL": (50.0, "metal_future"),
    # rates futures ($ per point of price)
    "ZB": (1000.0, "rates_future"),    "ZN": (1000.0, "rates_future"),
    "ZF": (1000.0, "rates_future"),    "ZT": (2000.0, "rates_future"),
    "UB": (1000.0, "rates_future"),
    # currency futures
    "6E": (125000.0, "fx_future"),     "6J": (12500000.0, "fx_future"),
    "6B": (62500.0, "fx_future"),      "6A": (100000.0, "fx_future"),
    "6C": (100000.0, "fx_future"),
    # crypto futures
    "MBT": (0.1, "crypto_future"),     "MET": (0.1, "crypto_future"),
}

# US-equity venue prefixes seen from the browser bridge (WealthCharts emits US.SPY / US.QQQ / …).
_EQUITY_VENUES = {"US", "NASDAQ", "NYSE", "ARCA", "BATS", "AMEX"}
_FUTURES_VENUES = {"CM", "CME", "CBOT", "NYMEX", "COMEX", "GLOBEX"}


def classify_instrument(symbol) -> dict:
    """Classify ONE captured instrument symbol honestly. PURE. Returns a dict with:
      symbol       — the raw symbol as captured (venue prefix preserved)
      display      — clean normalized token (venue prefix stripped)
      root         — futures root (ES/MNQ/CL) or the bare ticker for equities
      assetClass   — real bucket: us_index_future / energy_future / metal_future / rates_future /
                     fx_future / crypto_future / equity_etf / other
      pointValue   — $ per 1.00 point when the contract spec is KNOWN, else None (UI shows points only)
      esFamily     — True only for ES/MES (root or dated contract)
      esModules    — True only when the ES-tuned Session/SMT modules genuinely apply (== esFamily);
                     the picker/factor UI labels these ES-only on every other instrument.
    Nothing is fabricated: an unknown instrument is labeled 'other' with pointValue None, never guessed.
    """
    raw = str(symbol or "").strip()
    display = normalize_symbol(raw)
    venue = raw.split(".")[0].strip().upper() if "." in raw else ""
    root = futures_root_any(raw)
    es_family = is_es_symbol(raw)

    if es_family:
        asset_class, point_value = "us_index_future", _FUTURES_SPECS.get(root, (50.0, "us_index_future"))[0]
    elif root in _FUTURES_SPECS:
        point_value, asset_class = _FUTURES_SPECS[root]
    elif venue in _EQUITY_VENUES:
        # A US-equity venue instrument. ETF vs single-name is not decidable from the ticker alone, so
        # we bucket honestly as equity_etf (equities + ETFs) and never claim a futures point value.
        asset_class, point_value = "equity_etf", None
    elif venue in _FUTURES_VENUES and root == display and display.isalpha():
        # A futures-venue root we don't have a spec for: it IS a future, but we won't fake a multiplier.
        asset_class, point_value = "other_future", None
    else:
        asset_class, point_value = "other", None

    return {
        "symbol": raw or display,
        "display": display,
        "root": root,
        "assetClass": asset_class,
        "pointValue": point_value,
        "esFamily": es_family,
        "esModules": es_family,
    }


def in_scope(symbol) -> bool:
    """True if this symbol is an instrument the product accepts (stores/charts).

    Default scope accepts any sane, non-empty normalized symbol. The opt-in developer scope 'es'
    keeps only ES-family instruments for legacy Topstep-only tests."""
    if is_es_symbol(symbol):
        return True
    if INSTRUMENT_SCOPE == "es":
        return False
    return bool(normalize_symbol(symbol))


def scoped_symbols(symbols) -> list[str]:
    """Dedup of in-scope symbols, order-preserved."""
    out, seen = [], set()
    for sym in symbols or []:
        raw = str(sym or "").strip()
        if raw and in_scope(raw) and raw not in seen:
            seen.add(raw)
            out.append(raw)
    return out


def _clamp(key, val):
    lo, hi = _CONFIG_RANGES[key]
    try:
        v = float(val)
    except (TypeError, ValueError, OverflowError):
        return CONFIG_DEFAULTS[key]
    if not math.isfinite(v):
        return CONFIG_DEFAULTS[key]
    v = max(lo, min(hi, v))
    return int(v) if isinstance(CONFIG_DEFAULTS[key], int) else v


def load_config(path: str | None = None) -> dict:
    """The current buyer config merged over defaults, range-clamped. Honest on a missing/bad
    file: returns defaults (never crashes, never silently de-honests the gate)."""
    path = path or default_config_path()
    cfg = dict(CONFIG_DEFAULTS)
    try:
        with open(path) as f:
            raw = json.load(f)
        if isinstance(raw, dict):
            cfg.update({k: raw[k] for k in raw if k in CONFIG_DEFAULTS})
    except (OSError, ValueError):
        pass
    return _sanitize(cfg)


def _sanitize(cfg: dict) -> dict:
    out = dict(CONFIG_DEFAULTS)
    out.update({k: cfg.get(k, out[k]) for k in out})
    for k in _CONFIG_RANGES:
        out[k] = _clamp(k, out[k])
    eng = []
    for raw_engine in (out.get("engines") or []):
        canonical = DUPLICATE_ENGINE_ALIASES.get(raw_engine, raw_engine)
        if canonical in ACTIVE_ENGINE_FAMILY and canonical not in eng:
            eng.append(canonical)
    out["engines"] = eng or list(CONFIG_DEFAULTS["engines"])
    # Shipping signals are always edge-gated. Tests and offline embeddings can still pass an
    # explicit Capture(..., edge_gate=False); persisted buyer config cannot disable the safety gate.
    out["edgeGate"] = True
    out["alertSound"] = bool(out.get("alertSound", True))
    out["symbols"] = [ES_ROOT]
    out["propFirm"] = str(out.get("propFirm", ""))[:64]
    out["alertWebhook"] = str(out.get("alertWebhook", ""))[:512]
    return out


def save_config(cfg: dict, path: str | None = None) -> dict:
    """Persist a sanitized config; returns what was written (the clamped truth)."""
    path = path or default_config_path()
    clean = _sanitize(cfg)
    try:
        d = os.path.dirname(path)
        if d:
            os.makedirs(d, exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(clean, f, indent=2)
        os.replace(tmp, path)
    except OSError:
        pass
    return clean


# ===========================================================================
# Pure WC capture helpers — ported 1:1 from utah.integrations.wc_feed (READ-ONLY ref).
# ===========================================================================
def _f(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _signed_volume_delta(candle: dict, close: float) -> float:
    """Best-effort delta from real WC candle fields.

    If WC supplies an explicit delta-like field we use it. Otherwise, when WC supplies real volume,
    derive a Lee-Ready-style signed volume from the candle direction. That makes CVD/VPIN reflect
    real traded volume and price direction while staying deterministic and source-bound.
    """
    for k in ("delta", "cd", "cDelta", "cvd", "aggressorDelta"):
        v = _f(candle.get(k))
        if v is not None:
            return v
    vol = _f(candle.get("cq") or candle.get("volume") or candle.get("v") or candle.get("cv"))
    if vol is None or vol <= 0:
        return 0.0
    op = _f(candle.get("co"))
    if op is None or close == op:
        return 0.0
    return vol if close > op else -vol


def parse_candle(payload: str):
    """One WC WebSocket frame string -> {symbol, close, open, high, low, epoch} or None.
    PURE. Returns None for keepalives / non-candle / malformed / value-less frames so junk
    never crashes the capture or fabricates a price.

    WC sends TWO live candle shapes on the same socket:
      * the realtime BAR shape carries a real Unix epoch in ``cepoch``
        (e.g. {"co":...,"cM":...,"cm":...,"cc":...,"cepoch":1781045182,"type":"rt"});
      * the intraday TICK shape carries ``cts`` (exchange-session seconds, NOT a Unix epoch)
        and NO ``cepoch`` (e.g. {"cnu":1,"co":...,"cc":...,"cts":72427,"cq":"..."}).
    Both are genuine candles for the symbol. We accept BOTH: a real ``cepoch`` is preserved;
    otherwise ``epoch`` is None and the capture loop stamps the tick with its true ARRIVAL
    wall-clock (we never coerce ``cts`` into a fabricated epoch). Dropping the ``cts`` shape was
    the bug that silently starved the store of every live tick when WC emitted the tick variant,
    so the chart never filled after Connect."""
    try:
        obj = json.loads(payload)
    except (ValueError, TypeError):
        return None
    if not isinstance(obj, dict) or obj.get("cmd") != "feed":
        return None
    data = obj.get("data")
    if not isinstance(data, dict) or data.get("type") != "candle":
        return None
    candle = data.get("candle")
    symbol = data.get("c")
    if not isinstance(candle, dict) or not symbol:
        return None
    close = _f(candle.get("cc"))
    if close is None:
        return None                          # no price -> junk, never fabricate one
    raw_epoch = candle.get("cepoch")
    epoch = int(raw_epoch) if raw_epoch is not None else None
    volume = _f(candle.get("cq") or candle.get("volume") or candle.get("v") or candle.get("cv")) or 0.0
    return {"symbol": symbol, "close": close, "open": _f(candle.get("co")),
            "high": _f(candle.get("cM")), "low": _f(candle.get("cm")), "epoch": epoch,
            "volume": max(0.0, volume), "delta": _signed_volume_delta(candle, close)}


def normalize_epoch(epoch: int, arrival: float, step: int = 900) -> int:
    """Strip WC's exchange-wall-clock skew (equity bars arrive stamped +3600s). Any whole
    multiple of *step* between stamp and ARRIVAL is timezone skew, not latency: snap to zero,
    keep the sub-step remainder. PURE."""
    skew = round((int(epoch) - arrival) / step) * step
    return int(epoch - skew)


def ohlc_bars(ticks, bar_seconds: int = 15):
    """[(epoch, close), ...] -> [(bar_key, o, h, l, c), ...] for CLOSED buckets only (the
    still-forming final bucket is excluded). o/h/l/c derived from the ~1s tick closes seen in
    each bucket. PURE."""
    order = []
    agg = {}
    for ep, cl in ticks:
        if ep is None or cl is None:
            continue
        k = int(ep) // bar_seconds
        if k not in agg:
            order.append(k)
            agg[k] = []
        agg[k].append(cl)
    closed = order[:-1] if len(order) >= 2 else []
    return [(k, agg[k][0], max(agg[k]), min(agg[k]), agg[k][-1]) for k in closed]


def ohlcv_bars(ticks, bar_seconds: int = 15):
    """[(epoch, close, volume, delta), ...] -> [(bar_key,o,h,l,c,volume,delta), ...].

    Volume and delta are carried from real source fields when present. WC tick updates usually carry
    the current candle's cumulative volume, so each bucket uses the max observed volume and the last
    observed signed delta instead of summing every websocket update.
    """
    order = []
    agg = {}
    for item in ticks:
        if len(item) < 2:
            continue
        ep, cl = item[0], item[1]
        if ep is None or cl is None:
            continue
        vol = _f(item[2]) if len(item) >= 3 else 0.0
        dlt = _f(item[3]) if len(item) >= 4 else 0.0
        k = int(ep) // bar_seconds
        if k not in agg:
            order.append(k)
            agg[k] = {"prices": [], "volume": 0.0, "delta": 0.0}
        agg[k]["prices"].append(cl)
        agg[k]["volume"] = max(agg[k]["volume"], max(0.0, vol or 0.0))
        if dlt:
            agg[k]["delta"] = dlt
    closed = order[:-1] if len(order) >= 2 else []
    out = []
    for k in closed:
        prices = agg[k]["prices"]
        if not prices:
            continue
        out.append((k, prices[0], max(prices), min(prices), prices[-1],
                    agg[k]["volume"], agg[k]["delta"]))
    return out


# ===========================================================================
# Pure OHLC indicator helpers — the shared voter primitives the consensus-family engines
# (momentum/structure/regime/channel/context_*) compute their signals from. Stdlib-only, no state.
# These are the OHLC-derivable cores of the real engines' indicator stack (EMA ribbon,
# StepGMA-style fast/slow slope, Kaufman efficiency-ratio regime, ATR geometry, Fibonacci
# golden-pocket position). Order-flow voters (CVD, SMT, absorption) and macro voters
# (entropy/VIX/econ-calendar) are NOT here — they are non-OHLC and are documented as
# gated-out in each engine's docstring.
# ===========================================================================
def _ema(values, span):
    if not values:
        return []
    k = 2.0 / (span + 1.0)
    out = [values[0]]
    for v in values[1:]:
        out.append(out[-1] + k * (v - out[-1]))
    return out


def _kaufman_er(closes, period):
    """Kaufman efficiency ratio over the last `period` closes: |net change| / sum|change|.
    1.0 = perfectly trending, ~0 = pure chop. 0.0 when undefined (flat / too few)."""
    if len(closes) < period + 1:
        return 0.0
    seg = closes[-(period + 1):]
    net = abs(seg[-1] - seg[0])
    vol = sum(abs(seg[i] - seg[i - 1]) for i in range(1, len(seg)))
    return (net / vol) if vol > 0 else 0.0


def _stepgma_dir(closes, fast, slow):
    """('bull'|'bear'|'neutral', slope). Direction = sign(fastEMA - slowEMA) on the last bar;
    slope = normalized 1-bar change of the fast EMA. 'neutral' when the EMAs coincide."""
    if len(closes) < slow + 1:
        return ("neutral", 0.0)
    ef = _ema(closes, fast)
    es = _ema(closes, slow)
    diff = ef[-1] - es[-1]
    slope = (ef[-1] - ef[-2]) / es[-1] if es[-1] else 0.0
    if diff > 0:
        return ("bull", slope)
    if diff < 0:
        return ("bear", slope)
    return ("neutral", slope)


def _ribbon_bull(closes, spans=(8, 13, 21, 34, 55)):
    """True if the EMA ribbon is stacked bullish (faster EMA above slower, monotonically),
    False if stacked bearish, None if mixed/insufficient. Pure momentum confirmation voter."""
    if len(closes) < max(spans) + 1:
        return None
    vals = [_ema(closes, s)[-1] for s in spans]
    if all(vals[i] > vals[i + 1] for i in range(len(vals) - 1)):
        return True
    if all(vals[i] < vals[i + 1] for i in range(len(vals) - 1)):
        return False
    return None


def _atr(ohlc, period=14):
    """Mean true range over the last `period` bars. ohlc rows: (o,h,l,c). 0 if too few."""
    if len(ohlc) < period + 1:
        return 0.0
    trs = []
    for i in range(len(ohlc) - period, len(ohlc)):
        h, l, pc = ohlc[i][1], ohlc[i][2], ohlc[i - 1][3]
        trs.append(max(h - l, abs(h - pc), abs(l - pc)))
    return sum(trs) / len(trs) if trs else 0.0


def _fib_pos(closes, lookback):
    """Position of the last close within [swing_low, swing_high] over the last `lookback`
    closes, in [0,1]. None if the range is flat (no swing). Golden-pocket gate input."""
    if len(closes) < 2:
        return None
    seg = closes[-lookback:] if lookback > 0 else closes
    lo, hi = min(seg), max(seg)
    if hi <= lo:
        return None
    return (closes[-1] - lo) / (hi - lo)


# ===========================================================================
# Engine math (pure) — ported from utah.product.backtest / research_signal / Engines.swift.
# OOS-split, OOS-candidate verdict only on the held-out tail. Same numbers as the Swift engines.
# ===========================================================================
LOOKBACK = 20
OOS_FRAC = 0.4
MIN_TRADES = 20
MR_Z = 2.0
MR_TGT_FRAC = 0.6
MR_STOP_MULT = 8.0
MR_WIN_FLOOR = 0.87
MR_MAX_HOLD = 80
BK_TARGET_R = 2.0
BK_MAX_HOLD = 80
RESEARCH_TICK_SIZE = 0.25


def _valid_ohlc_bar(bar) -> bool:
    """True only for a finite, internally consistent OHLC row.

    Research must fail closed on a corrupt bar. In particular, accepting NaN makes every
    comparison false and can silently turn a broken series into a flattering time-stop fill.
    """
    if not isinstance(bar, (list, tuple)) or len(bar) < 4:
        return False
    try:
        o, h, l, c = (float(bar[k]) for k in range(4))
    except (TypeError, ValueError, OverflowError):
        return False
    return (all(math.isfinite(v) for v in (o, h, l, c))
            and l <= min(o, c) <= max(o, c) <= h)


def _valid_ohlc_series(ohlc) -> bool:
    return isinstance(ohlc, (list, tuple)) and all(_valid_ohlc_bar(b) for b in ohlc)


def _round_fill(price, direction, tick_size=RESEARCH_TICK_SIZE, is_entry=False):
    """Round one ES-family research fill in the adverse direction.

    LONG entries round up and SHORT entries down. Exits do the inverse: LONG exits round down
    and SHORT exits up. Decimal avoids binary-float boundary errors at legal 0.25 ES/MES ticks.
    Invalid price/direction/tick returns None so the caller can reject the trade.
    """
    if direction not in ("long", "short"):
        return None
    try:
        px = Decimal(str(price))
        tick = Decimal(str(tick_size))
        if not px.is_finite() or not tick.is_finite() or tick <= 0:
            return None
        round_up = ((direction == "long") if is_entry else (direction == "short"))
        mode = ROUND_CEILING if round_up else ROUND_FLOOR
        units = (px / tick).to_integral_value(rounding=mode)
        result = float(units * tick)
    except (InvalidOperation, TypeError, ValueError, OverflowError):
        return None
    return result if math.isfinite(result) else None


def _round_order_level(price, direction, kind, tick_size=RESEARCH_TICK_SIZE):
    """Round a stop/target to a legal tick without improving the research geometry.

    Order placement and realized fill rounding are different operations. A LONG stop must never
    move farther away and a LONG target must never move closer, so both round UP. The SHORT inverse
    rounds both levels DOWN. Once a legal trigger is touched, ``_round_fill`` still applies the
    adverse realized-fill rule independently.
    """
    if direction not in ("long", "short") or kind not in ("stop", "target"):
        return None
    try:
        px = Decimal(str(price))
        tick = Decimal(str(tick_size))
        if not px.is_finite() or not tick.is_finite() or tick <= 0:
            return None
        mode = ROUND_CEILING if direction == "long" else ROUND_FLOOR
        units = (px / tick).to_integral_value(rounding=mode)
        result = float(units * tick)
    except (InvalidOperation, TypeError, ValueError, OverflowError):
        return None
    return result if math.isfinite(result) else None


def _research_tick_size(cfg):
    try:
        value = float(cfg.get("researchTickSize", RESEARCH_TICK_SIZE))
    except (AttributeError, TypeError, ValueError, OverflowError):
        return None
    lo, hi = _CONFIG_RANGES["researchTickSize"]
    return value if math.isfinite(value) and lo <= value <= hi else None


def _breakout_max_hold(cfg):
    try:
        value = int(cfg.get("bkMaxHold", BK_MAX_HOLD))
    except (AttributeError, TypeError, ValueError, OverflowError):
        return None
    lo, hi = _CONFIG_RANGES["bkMaxHold"]
    return value if lo <= value <= hi else None


def _bracket_trade(ohlc, entry_index, direction, entry, stop, target, max_hold,
                   tick_size=RESEARCH_TICK_SIZE, signal_index=None,
                   close_incomplete=True):
    """Walk an OHLC bracket causally from an already-known entry bar.

    ``max_hold`` is entry-inclusive: 1 examines only the entry bar; 80 examines the entry bar
    plus at most 79 later bars. Each bar checks its OPEN before its intrabar range, so a gap
    beyond a bracket fills at the (adversely tick-rounded) open. If both stop and target occur
    inside one bar, stop wins because OHLC cannot establish touch order.
    """
    if direction not in ("long", "short") or not _valid_ohlc_series(ohlc):
        return None
    try:
        entry_index = int(entry_index)
        max_hold = int(max_hold)
    except (TypeError, ValueError, OverflowError):
        return None
    if entry_index < 0 or entry_index >= len(ohlc) or max_hold < 1:
        return None

    try:
        raw_stop = float(stop)
    except (TypeError, ValueError, OverflowError):
        return None
    entry = _round_fill(entry, direction, tick_size, is_entry=True)
    stop = _round_order_level(stop, direction, "stop", tick_size)
    target = _round_order_level(target, direction, "target", tick_size)
    if entry is None or stop is None or target is None:
        return None
    if direction == "long":
        if not (stop <= entry < target):
            return None
    elif not (target < entry <= stop):
        return None
    risk = abs(entry - stop)
    # A conservative legal stop can round exactly to the entry (for example LONG 100.00 with an
    # intended 99.90 stop on a 0.25-tick instrument). That is an immediate scratch/loss, not a
    # reason to discard the observation. Preserve the intended distance only as the R denominator.
    if risk <= 0:
        risk = abs(entry - raw_stop)
    if risk <= 0:
        try:
            risk = float(tick_size)
        except (TypeError, ValueError, OverflowError):
            return None
    if not math.isfinite(risk) or risk <= 0:
        return None

    try:
        sig_i = entry_index - 1 if signal_index is None else int(signal_index)
    except (TypeError, ValueError, OverflowError):
        return None
    end = min(len(ohlc), entry_index + max_hold)

    def result(exit_price, exit_index):
        filled = _round_fill(exit_price, direction, tick_size, is_entry=False)
        if filled is None:
            return None
        pnl = filled - entry if direction == "long" else entry - filled
        r = pnl / risk
        if not math.isfinite(r):
            return None
        return {
            "dir": direction, "entry": entry, "exit": filled,
            "stop": stop, "target": target,
            "signalIndex": sig_i, "entryIndex": entry_index, "exitIndex": exit_index,
            "held": exit_index - entry_index, "r": round(r, 4),
        }

    for j in range(entry_index, end):
        op, hi, lo, _ = (float(ohlc[j][k]) for k in range(4))
        if direction == "long":
            if op <= stop:
                return result(op, j)       # gap through stop: no impossible stop-price fill
            if op >= target:
                return result(op, j)       # favorable target gap also fills at the open
            if lo <= stop:
                return result(stop, j)     # stop-first for ambiguous same-bar touches
            if hi >= target:
                return result(target, j)
        else:
            if op >= stop:
                return result(op, j)
            if op <= target:
                return result(op, j)
            if hi >= stop:
                return result(stop, j)
            if lo <= target:
                return result(target, j)

    # The historical prover closes a truncated sample at its final observable close. A live fire
    # is different: it remains pending until the full hold window is observable. This switch lets
    # the journal use the exact same trigger/fill walker without inventing a premature time exit.
    if not close_incomplete and len(ohlc) - entry_index < max_hold:
        return None

    # No bracket touch inside the bounded window: flatten at its final close, never at a later
    # session's price. This is also the entry bar's close when max_hold == 1.
    exit_index = end - 1
    return result(float(ohlc[exit_index][3]), exit_index)


def _mr_simulate_ohlc(ohlc, i, direction, entry, stop, target, max_hold,
                      tick_size=RESEARCH_TICK_SIZE, signal_index=None):
    """Compatibility wrapper for the shared causal OHLC bracket simulator."""
    return _bracket_trade(ohlc, i, direction, entry, stop, target, max_hold,
                          tick_size, signal_index)


def _mr_trades(ohlc, lookback=LOOKBACK, cfg=None):
    cfg = cfg or CONFIG_DEFAULTS
    if not _valid_ohlc_series(ohlc):
        return []
    tick_size = _research_tick_size(cfg)
    try:
        lookback = int(lookback)
        z_enter = float(cfg.get("mrZ", MR_Z))
        tgt_frac = float(cfg.get("mrTgtFrac", MR_TGT_FRAC))
        stop_mult = float(cfg.get("mrStopMult", MR_STOP_MULT))
    except (AttributeError, TypeError, ValueError, OverflowError):
        return []
    if (tick_size is None or lookback < 1
            or not all(math.isfinite(v) and v > 0 for v in (z_enter, tgt_frac, stop_mult))):
        return []
    closes = [float(b[3]) for b in ohlc]
    out = []
    i = lookback
    n = len(ohlc)
    while i < n - 1:
        prior = closes[i - lookback:i]
        mean = sum(prior) / lookback
        varc = sum((x - mean) ** 2 for x in prior) / lookback
        if varc <= 0:
            i += 1
            continue
        sd = math.sqrt(varc)
        signal_close = closes[i]
        z = (signal_close - mean) / sd
        entry_index = i + 1
        raw_entry = float(ohlc[entry_index][0])
        entry = _round_fill(raw_entry, "long" if z <= -z_enter else "short",
                            tick_size, is_entry=True)
        if entry is None:
            i += 1
            continue
        if z <= -z_enter:
            direction = "long"
            target = entry + tgt_frac * (mean - entry)
            stop = entry - stop_mult * sd
        elif z >= z_enter:
            direction = "short"
            target = entry - tgt_frac * (entry - mean)
            stop = entry + stop_mult * sd
        else:
            i += 1
            continue
        t = _mr_simulate_ohlc(ohlc, entry_index, direction, entry, stop, target,
                              MR_MAX_HOLD, tick_size, signal_index=i)
        if not t:
            i += 1
            continue
        out.append(t)
        i = max(i + 1, t["exitIndex"])
    return out


# Significance bar for the OOS edge proof. expectancy>0 alone is NOT proof: a driftless series
# clears that threshold roughly half the time. More importantly, real research trades include gaps
# and time exits, so they are not Bernoulli trials with one fixed win/loss payoff. The edge statistic
# therefore tests the realized R-return mean directly, using capped positive outcomes, every actual
# loss, and a Newey-West long-run variance that penalizes serially clustered results.
SIG_MIN_N = 30          # minimum OOS trades before significance can be assessed
SIG_ALPHA = 0.05        # one-sided mean-R significance level


def _binom_sf(k, n, p):
    """P(X >= k) for X ~ Binomial(n, p), stable for small and large OOS samples.

    The direct ``comb * p**i`` sum overflowed while optimizing high-turnover cells (n≈1,300),
    crashing the farm instead of returning an honest p-value. Log-space summation chooses the
    smaller tail and uses expm1 for the complement, avoiding integer→float overflow and severe
    cancellation without adding a scipy dependency.
    """
    if k <= 0:
        return 1.0
    if k > n:
        return 0.0
    if p <= 0.0:
        return 0.0
    if p >= 1.0:
        return 1.0

    log_p = math.log(p)
    log_q = math.log1p(-p)

    def log_pmf(i):
        return (math.lgamma(n + 1) - math.lgamma(i + 1) - math.lgamma(n - i + 1)
                + i * log_p + (n - i) * log_q)

    def log_add(a, b):
        if a == -math.inf:
            return b
        if b > a:
            a, b = b, a
        return a + math.log1p(math.exp(b - a))

    if k <= n * p:
        # Survival is the large tail; compute the smaller lower CDF and complement it stably.
        log_cdf = -math.inf
        for i in range(0, k):
            log_cdf = log_add(log_cdf, log_pmf(i))
        return max(0.0, min(1.0, -math.expm1(log_cdf)))

    log_sf = -math.inf
    for i in range(k, n + 1):
        log_sf = log_add(log_sf, log_pmf(i))
    return max(0.0, min(1.0, math.exp(log_sf)))


def _beta_continued_fraction(a, b, x):
    """Numerical-Recipes continued fraction for the regularized incomplete beta.

    This tiny stdlib-only primitive lets the edge gate use a Student-t tail rather than treating a
    small OOS sample as asymptotically normal. ``None`` means the fraction did not converge, which
    callers treat as no evidence.
    """
    max_iterations = 200
    epsilon = 3.0e-14
    fp_min = 1.0e-300
    qab = a + b
    qap = a + 1.0
    qam = a - 1.0
    c = 1.0
    d = 1.0 - qab * x / qap
    if abs(d) < fp_min:
        d = fp_min
    d = 1.0 / d
    h = d
    for m in range(1, max_iterations + 1):
        m2 = 2 * m
        aa = m * (b - m) * x / ((qam + m2) * (a + m2))
        d = 1.0 + aa * d
        if abs(d) < fp_min:
            d = fp_min
        c = 1.0 + aa / c
        if abs(c) < fp_min:
            c = fp_min
        d = 1.0 / d
        h *= d * c
        aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
        d = 1.0 + aa * d
        if abs(d) < fp_min:
            d = fp_min
        c = 1.0 + aa / c
        if abs(c) < fp_min:
            c = fp_min
        d = 1.0 / d
        delta = d * c
        h *= delta
        if not math.isfinite(h):
            return None
        if abs(delta - 1.0) <= epsilon:
            return h
    return None


def _regularized_beta(x, a, b):
    """Regularized incomplete beta I_x(a,b), or ``None`` on invalid/nonconvergent input."""
    if not all(math.isfinite(v) for v in (x, a, b)) or a <= 0.0 or b <= 0.0:
        return None
    if x <= 0.0:
        return 0.0
    if x >= 1.0:
        return 1.0
    try:
        front = math.exp(
            math.lgamma(a + b) - math.lgamma(a) - math.lgamma(b)
            + a * math.log(x) + b * math.log1p(-x))
    except (OverflowError, ValueError):
        return None
    if not math.isfinite(front):
        return None
    if x < (a + 1.0) / (a + b + 2.0):
        fraction = _beta_continued_fraction(a, b, x)
        value = None if fraction is None else front * fraction / a
    else:
        fraction = _beta_continued_fraction(b, a, 1.0 - x)
        value = None if fraction is None else 1.0 - front * fraction / b
    if value is None or not math.isfinite(value):
        return None
    return max(0.0, min(1.0, value))


def _student_t_sf(t_stat, degrees_freedom):
    """One-sided Student-t survival probability, dependency-free and stable at large n."""
    try:
        t_stat = float(t_stat)
        degrees_freedom = float(degrees_freedom)
    except (TypeError, ValueError, OverflowError):
        return 1.0
    if not math.isfinite(degrees_freedom) or degrees_freedom < 1.0:
        return 1.0
    if math.isnan(t_stat):
        return 1.0
    if t_stat == math.inf:
        return 0.0
    if t_stat == -math.inf:
        return 1.0
    try:
        x = degrees_freedom / (degrees_freedom + t_stat * t_stat)
    except OverflowError:
        x = 0.0
    beta = _regularized_beta(x, degrees_freedom / 2.0, 0.5)
    if beta is None:
        return 1.0
    return 0.5 * beta if t_stat >= 0.0 else 1.0 - 0.5 * beta


def _edge_pvalue(trades, wins, n, expectancy, min_trades, target_r=None):
    """Conservative one-sided test of ``mean(realized R) > 0`` on the OOS trade sequence.

    Positive R is capped at the intended target when known. Variable-payoff engines use the lower
    median realized positive R as a robust cap, so a rare runner cannot purchase significance.
    Losses are never clipped. A Bartlett/Newey-West variance preserves short-range serial
    dependence; it is floored at the IID variance so negative autocorrelation cannot make the test
    more permissive. The bounded automatic lag is O(n * n**(2/9)), capped at 32 for optimizer scale.

    Any thin, malformed, nonfinite, internally inconsistent, non-positive, or effectively
    zero-variance sample returns 1.0. Both the per-cell edge gate and grid-wide BH-FDR consume this
    same deterministic p-value.
    """
    try:
        n_value = int(n)
        wins_value = int(wins)
        min_value = int(min_trades)
        expectancy_value = float(expectancy)
        rows = list(trades)
    except (TypeError, ValueError, OverflowError):
        return 1.0
    if (n_value != n or wins_value != wins or min_value != min_trades
            or n_value != len(rows) or n_value < max(min_value, SIG_MIN_N)
            or wins_value <= 0 or not math.isfinite(expectancy_value)
            or expectancy_value <= 0.0):
        return 1.0

    realized = []
    try:
        for trade in rows:
            value = float(trade["r"])
            if not math.isfinite(value):
                return 1.0
            realized.append(value)
    except (KeyError, TypeError, ValueError, OverflowError):
        return 1.0
    positives = sorted(value for value in realized if value > 0.0)
    if len(positives) != wins_value:
        return 1.0
    if target_r is not None:
        try:
            positive_cap = float(target_r)
        except (TypeError, ValueError, OverflowError):
            return 1.0
        if not math.isfinite(positive_cap) or positive_cap <= 0.0:
            return 1.0
    else:
        # Lower median is deliberate for even samples: uncertainty about the payoff distribution
        # must reduce, never inflate, evidence.
        positive_cap = positives[(len(positives) - 1) // 2]
    if not math.isfinite(positive_cap) or positive_cap <= 0.0:
        return 1.0

    returns = [min(value, positive_cap) if value > 0.0 else value for value in realized]
    try:
        mean_r = math.fsum(returns) / n_value
    except (OverflowError, ValueError):
        return 1.0
    if not math.isfinite(mean_r) or mean_r <= 0.0:
        return 1.0
    deviations = [value - mean_r for value in returns]
    try:
        iid_variance = math.fsum(value * value for value in deviations) / n_value
    except (OverflowError, ValueError):
        return 1.0
    max_magnitude = max(abs(value) for value in returns)
    variance_floor = (max(1.0, max_magnitude) * 1.0e-12) ** 2
    if not math.isfinite(iid_variance) or iid_variance <= variance_floor:
        return 1.0

    # Andrews/Newey-West automatic bandwidth, hard-capped so large optimizer cells stay bounded.
    lag_count = max(1, min(n_value - 1, 32,
                           int(4.0 * (n_value / 100.0) ** (2.0 / 9.0))))
    long_run_variance = iid_variance
    for lag in range(1, lag_count + 1):
        try:
            covariance = math.fsum(
                deviations[index] * deviations[index - lag]
                for index in range(lag, n_value)) / n_value
        except (OverflowError, ValueError):
            return 1.0
        weight = 1.0 - lag / (lag_count + 1.0)
        long_run_variance += 2.0 * weight * covariance
    # Never reward negative autocorrelation or a non-positive finite-sample HAC estimate.
    long_run_variance = max(iid_variance, long_run_variance)
    if not math.isfinite(long_run_variance) or long_run_variance <= variance_floor:
        return 1.0
    standard_error = math.sqrt(long_run_variance / n_value)
    if not math.isfinite(standard_error) or standard_error <= 0.0:
        return 1.0
    t_stat = mean_r / standard_error
    # Treat each (lag+1)-wide dependence block as one effective observation for the small-sample
    # tail. This is deliberately more conservative than using n-1 degrees of freedom.
    effective_df = max(1, n_value // (lag_count + 1) - 1)
    p_value = _student_t_sf(t_stat, effective_df)
    return p_value if math.isfinite(p_value) and 0.0 <= p_value <= 1.0 else 1.0


def _edge_proven(trades, wins, n, expectancy, min_trades, target_r=None):
    """Per-test gate: the return-based edge p-value clears SIG_ALPHA. (The screen grid additionally
    applies BH-FDR across all (engine,symbol) cells — see bltd_analytics.screen.)"""
    return _edge_pvalue(trades, wins, n, expectancy, min_trades, target_r) < SIG_ALPHA


def _max_drawdown_r(trades):
    """Peak-to-trough drawdown of the cumulative-R equity curve over the OOS trade sequence, in R
    units (>=0). Honest worst-case pain, not a return claim — computed straight from the same trade
    R's the edge stat uses, in chronological order. 0.0 for an empty/monotonic-up series."""
    peak = 0.0
    cum = 0.0
    max_dd = 0.0
    for t in trades:
        cum += t["r"]
        if cum > peak:
            peak = cum
        dd = peak - cum
        if dd > max_dd:
            max_dd = dd
    return round(max_dd, 4)


def _summarize(trades, min_trades=MIN_TRADES, target_r=None):
    n = len(trades)
    if n == 0:
        return {"trades": 0, "wins": 0, "losses": 0, "winRate": 0.0, "expectancyR": 0.0,
                "netPts": 0.0, "maxDrawdownR": 0.0, "edgeProven": False, "pEdge": 1.0,
                "reason": "no trades triggered on this series"}
    rs = [t["r"] for t in trades]
    wins = sum(1 for r in rs if r > 0)
    total_r = sum(rs)
    expectancy = total_r / n
    net_pts = sum((t["exit"] - t["entry"]) if t["dir"] == "long" else (t["entry"] - t["exit"]) for t in trades)
    p_edge = _edge_pvalue(trades, wins, n, expectancy, min_trades, target_r)
    return {"trades": n, "wins": wins, "losses": n - wins, "winRate": round(wins / n, 4),
            "expectancyR": round(expectancy, 4), "netPts": round(net_pts, 4),
            "maxDrawdownR": _max_drawdown_r(trades),
            "edgeProven": p_edge < SIG_ALPHA, "pEdge": round(p_edge, 6), "reason": ""}


def prove_meanrev(ohlc, cfg=None):
    cfg = cfg or CONFIG_DEFAULTS
    oos_frac = cfg.get("oosFrac", OOS_FRAC)
    lookback = cfg.get("lookback", LOOKBACK)
    min_trades = cfg.get("minTrades", MIN_TRADES)
    win_floor = cfg.get("mrWinFloor", MR_WIN_FLOOR)
    split = int(len(ohlc) * (1.0 - oos_frac))
    oos = ohlc[split:]
    s = _summarize(_mr_trades(oos, lookback, cfg), min_trades)
    effective_min = max(min_trades, SIG_MIN_N)
    # Mean reversion used to return ok=True from a high configured win floor without requiring the
    # same statistical edge test every other engine exposes. Keep the strategy-specific floor, but
    # make significance a non-negotiable part of the single-engine verdict too.
    edge = (s["trades"] >= effective_min and s["winRate"] >= win_floor
            and s["netPts"] > 0 and s["edgeProven"])
    reason = (f"OOS candidate: win {s['winRate']*100:.1f}% / net {s['netPts']:+.2f} pts on "
              f"{s['trades']} trades (p={s['pEdge']:.3f}); live verification required"
              if edge else
              f"not proven: OOS win {s['winRate']*100:.1f}% / net {s['netPts']:+.2f} pts on {s['trades']} trades "
              f"(need win>={win_floor*100:.0f}%, net>0, >={effective_min} trades, p<{SIG_ALPHA})")
    return {"ok": edge, "reason": reason, **s}


def _bk_simulate(ohlc, i, direction, entry, stop, target_r,
                 max_hold=BK_MAX_HOLD, tick_size=RESEARCH_TICK_SIZE, signal_index=None):
    """Breakout bracket wrapper.

    Numeric close-only input remains accepted for narrow compatibility tests, but real engine
    callers pass OHLC so gaps and intrabar stop/target touches are modeled honestly.
    """
    if isinstance(ohlc, (list, tuple)) and ohlc and not isinstance(ohlc[0], (list, tuple)):
        try:
            ohlc = [(float(px),) * 4 for px in ohlc]
        except (TypeError, ValueError, OverflowError):
            return None
    try:
        raw_stop = float(stop)
    except (TypeError, ValueError, OverflowError):
        return None
    rounded_entry = _round_fill(entry, direction, tick_size, is_entry=True)
    rounded_stop = _round_order_level(stop, direction, "stop", tick_size)
    try:
        target_r = float(target_r)
    except (TypeError, ValueError, OverflowError):
        return None
    if (rounded_entry is None or rounded_stop is None
            or not math.isfinite(target_r) or target_r <= 0):
        return None
    risk = abs(rounded_entry - rounded_stop)
    if risk <= 0:
        risk = abs(rounded_entry - raw_stop)
    if risk <= 0:
        return None
    target = (rounded_entry + target_r * risk if direction == "long"
              else rounded_entry - target_r * risk)
    return _bracket_trade(ohlc, i, direction, rounded_entry, stop, target,
                          max_hold, tick_size, signal_index)


def _bk_trades(ohlc, lookback=LOOKBACK, cfg=None):
    """Breakout walk over a bar series: long on a close above the prior `lookback` high, short
    below the prior low; enter at the NEXT bar's open; stop at the opposite extreme; fixed
    reward:risk target; and flatten within configured ``bkMaxHold`` bars. Pure — this is the
    single canonical breakout/research generator the gate, screener and full-backtest share."""
    cfg = cfg or CONFIG_DEFAULTS
    if not _valid_ohlc_series(ohlc):
        return []
    tick_size = _research_tick_size(cfg)
    max_hold = _breakout_max_hold(cfg)
    try:
        lookback = int(lookback)
        target_r = float(cfg.get("bkTargetR", BK_TARGET_R))
    except (AttributeError, TypeError, ValueError, OverflowError):
        return []
    if (tick_size is None or max_hold is None or lookback < 1
            or not math.isfinite(target_r) or target_r <= 0):
        return []
    closes = [float(b[3]) for b in ohlc]
    trades = []
    i = lookback
    n = len(closes)
    while i < n - 1:
        prior = closes[i - lookback:i]
        last = closes[i]
        if not prior:
            i += 1
            continue
        if last > max(prior):
            direction, stop = "long", min(prior)
        elif last < min(prior):
            direction, stop = "short", max(prior)
        else:
            i += 1
            continue
        entry_index = i + 1
        entry = float(ohlc[entry_index][0])
        t = _bk_simulate(ohlc, entry_index, direction, entry, stop, target_r,
                         max_hold, tick_size, signal_index=i)
        if not t:
            i += 1
            continue
        trades.append(t)
        i = max(i + 1, t["exitIndex"])
    return trades


def prove_breakout(ohlc, cfg=None):
    cfg = cfg or CONFIG_DEFAULTS
    lookback = cfg.get("lookback", LOOKBACK)
    oos_frac = cfg.get("oosFrac", OOS_FRAC)
    min_trades = cfg.get("minTrades", MIN_TRADES)
    split = int(len(ohlc) * (1.0 - oos_frac))
    s = _summarize(_bk_trades(ohlc[split:], lookback, cfg), min_trades,
                   target_r=cfg.get("bkTargetR", BK_TARGET_R))
    reason = (f"OOS candidate: expectancy {s['expectancyR']:+.3f}R on {s['trades']} trades; live verification required"
              if s["edgeProven"] else
              f"not proven: OOS expectancy {s['expectancyR']:+.3f}R on {s['trades']} trades")
    return {"ok": s["edgeProven"], "reason": reason, **s}


def prove_research(ohlc, cfg=None):
    """research composite — directional/trend OOS. Ported intent of research_signal; the
    edge gate just needs a positive-expectancy OOS verdict on a real sample."""
    # The research engine is the directional voter set; for the in-process gate we reuse the
    # breakout walk on the OOS tail as its tradable proxy (both are momentum-directional and
    # the Swift `research` archetype proved on trending series). Honest: same OOS frame.
    r = prove_breakout(ohlc, cfg)
    r = dict(r)
    r["reason"] = r["reason"].replace("expectancy", "research expectancy")
    return r


# ===========================================================================
# Consensus-family engines (faithful OHLC cores). Each implements the OHLC-supportable signal of
# its archetype; non-OHLC voters (CVD/order-flow, entropy, VIX, econ-calendar, SMT, absorption,
# session-DNA, world-model win-rate) are documented as GATED-OUT in each prover's docstring and
# are NOT invented. All share the consensus + ATR-geometry primitives below so the roster is DRY.
# ===========================================================================
MO_FAST, MO_SLOW = 8, 21
MO_ER = 0.30          # Kaufman ER floor: only trade when a real trend is present
MO_ATR_MULT = 0.8     # stop = 0.8 * ATR (momentum-family geometry)
MO_TARGET_R = 2.0     # 2:1 reward:risk


def _consensus_dir(closes, ohlc, lookback, fast, slow, er_floor):
    """The OHLC-derivable sniper consensus: StepGMA direction + EMA-ribbon stack + Kaufman-ER
    trend gate. Returns 'long'/'short'/None. (Order-flow CVD/SMT/absorption + entropy/VIX/econ
    voters from the real engine are NON-OHLC and intentionally omitted — documented gated-out.)"""
    if len(closes) < slow + 1:
        return None
    sdir, _ = _stepgma_dir(closes, fast, slow)
    ribbon = _ribbon_bull(closes)
    if _kaufman_er(closes, lookback) < er_floor:
        return None                       # no trend present -> stand aside
    if sdir == "bull" and ribbon is not False:
        return "long"
    if sdir == "bear" and ribbon is not True:
        return "short"
    return None


def _atr_stop_target(ohlc, entry, direction, atr_mult, target_r):
    """ATR-based stop/target faithful to the sniper geometry. Falls back to a 0.4% stop when
    ATR is undefined so the geometry is always well-formed (never a zero-risk trade)."""
    atr = _atr(ohlc, 14) or (entry * 0.004)
    stop_d = max(atr * atr_mult, abs(entry) * 1e-4)
    if direction == "long":
        return entry - stop_d, entry + target_r * stop_d
    return entry + stop_d, entry - target_r * stop_d


def _consensus_engine_trades(ohlc, lookback, cfg, dir_fn):
    """Shared OOS walk for the consensus-family engines. `dir_fn(closes, ohlc, lookback, cfg)`
    yields 'long'/'short'/None on each CLOSED signal bar. Entry is the next bar's adverse-rounded
    open; geometry is the shared ATR stop/2:1 target and the shared gap-aware OHLC fill walk."""
    cfg = cfg or CONFIG_DEFAULTS
    if not _valid_ohlc_series(ohlc):
        return []
    tick_size = _research_tick_size(cfg)
    try:
        lookback = int(lookback)
    except (TypeError, ValueError, OverflowError):
        return []
    if tick_size is None or lookback < 1 or not callable(dir_fn):
        return []
    closes = [float(b[3]) for b in ohlc]
    trades = []
    i = lookback
    n = len(ohlc)
    while i < n - 1:
        sub = ohlc[:i + 1]
        try:
            d = dir_fn(closes[:i + 1], sub, lookback, cfg)
        except (ArithmeticError, IndexError, TypeError, ValueError):
            return []                      # broken strategy/config fails closed, never partial truth
        if not d:
            i += 1
            continue
        entry_index = i + 1
        entry = _round_fill(ohlc[entry_index][0], d, tick_size, is_entry=True)
        if entry is None:
            i += 1
            continue
        stop, target = _atr_stop_target(sub, entry, d, MO_ATR_MULT, MO_TARGET_R)
        t = _mr_simulate_ohlc(ohlc, entry_index, d, entry, stop, target,
                              MR_MAX_HOLD, tick_size, signal_index=i)
        if not t:
            i += 1
            continue
        trades.append(t)
        i = max(i + 1, t["exitIndex"])
    return trades


def _consensus_prove(ohlc, cfg, dir_fn, label):
    """Shared OOS edge proof for the consensus-family engines."""
    cfg = cfg or CONFIG_DEFAULTS
    oos_frac = cfg.get("oosFrac", OOS_FRAC)
    lookback = cfg.get("lookback", LOOKBACK)
    min_trades = cfg.get("minTrades", MIN_TRADES)
    split = int(len(ohlc) * (1.0 - oos_frac))
    s = _summarize(_consensus_engine_trades(ohlc[split:], lookback, cfg, dir_fn), min_trades,
                   target_r=MO_TARGET_R)   # fixed 2:1 reward:risk — cap so a runner can't snoop it
    reason = (f"OOS candidate: expectancy {s['expectancyR']:+.3f}R / net {s['netPts']:+.2f} pts on {s['trades']} trades; live verification required"
              if s["edgeProven"] else
              f"not proven: OOS expectancy {s['expectancyR']:+.3f}R on {s['trades']} trades")
    return {"ok": s["edgeProven"], "reason": f"{label}: {reason}" if label else reason, **s}


# ---- momentum (trend-confirmed momentum consensus, unguarded + symmetric) --
def _momentum_dir(closes, ohlc, lookback, cfg):
    return _consensus_dir(closes, ohlc, lookback, MO_FAST, MO_SLOW, MO_ER)


def _momentum_trades(ohlc, lookback=LOOKBACK, cfg=None):
    return _consensus_engine_trades(ohlc, lookback, cfg, _momentum_dir)


def prove_momentum(ohlc, cfg=None):
    """Momentum (faithful OHLC core): trend-confirmed momentum
    (StepGMA direction + EMA-ribbon stack + Kaufman-ER trend gate), symmetric long/short, ATR
    stop / 2:1 target. GATED-OUT non-OHLC voters: CVD + CVD divergence, Shannon entropy, VIX
    panic, econ-calendar, SMT divergence, order-flow absorption, session-DNA. Edge proven only
    on the held-out tail."""
    return _consensus_prove(ohlc, cfg, _momentum_dir, "")


def _momentum_signal(closes, ohlc, lookback, cfg):
    d = _momentum_dir(closes, ohlc, lookback, cfg)
    if not d:
        return None
    entry = closes[-1]
    stop, target = _atr_stop_target(ohlc, entry, d, MO_ATR_MULT, MO_TARGET_R)
    return {"direction": d, "stop": stop, "target": target,
            "rationale": f"momentum consensus {d}: StepGMA+ribbon aligned, Kaufman ER>={MO_ER}"}


# ---- structure (guarded, short-biased counter-trend consensus) -------------
STRUCT_REGIME_ER = 0.40   # block entries when 30-bar Kaufman ER >= this & trending up


def _structure_dir(closes, ohlc, lookback, cfg):
    """Structure = momentum consensus with structural guards: block LONG side entirely, and
    block any entry while the tape trends UP (30-bar Kaufman ER >= 0.40 with up direction). Net:
    short-biased, counter-up-trend. GATED-OUT: non-OHLC setup-library patterns + the same
    order-flow/macro voters as momentum."""
    d = _consensus_dir(closes, ohlc, lookback, MO_FAST, MO_SLOW, MO_ER)
    if d == "long":
        return None                                   # block LONG side
    er = _kaufman_er(closes, 30)
    sdir, _ = _stepgma_dir(closes, MO_FAST, MO_SLOW)
    if er >= STRUCT_REGIME_ER and sdir == "bull":
        return None                                   # block TREND_UP regime
    return d


def _structure_trades(ohlc, lookback=LOOKBACK, cfg=None):
    return _consensus_engine_trades(ohlc, lookback, cfg, _structure_dir)


def prove_structure(ohlc, cfg=None):
    """Structure (faithful OHLC core): short-biased, counter-up-trend momentum (LONG side
    blocked, up-trend regime blocked). GATED-OUT non-OHLC voters: setup-library patterns,
    CVD/divergence, entropy, VIX, econ-calendar, SMT, absorption."""
    return _consensus_prove(ohlc, cfg, _structure_dir, "")


def _structure_signal(closes, ohlc, lookback, cfg):
    d = _structure_dir(closes, ohlc, lookback, cfg)
    if not d:
        return None
    entry = closes[-1]
    stop, target = _atr_stop_target(ohlc, entry, d, MO_ATR_MULT, MO_TARGET_R)
    return {"direction": d, "stop": stop, "target": target,
            "rationale": f"structure {d}: short-biased consensus (LONG/up-trend blocked)"}


# ---- regime (regime router -> trend continuation) --------------------------
REGIME_TREND_ER = 0.45    # Kaufman ER >= this -> TREND regime
REGIME_RANGE_ER = 0.25    # Kaufman ER <= this -> RANGE regime


def _variance_ratio(closes, lookback):
    """Lo-MacKinlay-style variance ratio proxy (OHLC stand-in for the engine's entropy voter):
    var(k-step returns)/(k*var(1-step)). ~1 = random walk, >1 = trending, <1 = mean-reverting."""
    if len(closes) < lookback + 2:
        return 1.0
    seg = closes[-(lookback + 1):]
    r1 = [seg[i] - seg[i - 1] for i in range(1, len(seg))]
    if len(r1) < 4:
        return 1.0
    mean = sum(r1) / len(r1)
    v1 = sum((x - mean) ** 2 for x in r1) / len(r1)
    if v1 <= 0:
        return 1.0
    k = 2
    rk = [seg[i] - seg[i - k] for i in range(k, len(seg))]
    meank = sum(rk) / len(rk)
    vk = sum((x - meank) ** 2 for x in rk) / len(rk)
    return (vk / (k * v1)) if v1 > 0 else 1.0


def _regime_class(closes, ohlc, lookback):
    """Regime classification (OHLC core of the regime router): weighted vote of Kaufman-ER
    (trend strength), variance-ratio (trend persistence proxy for entropy), and StepGMA
    direction. Returns 'TREND' or 'RANGE'. NON-OHLC voters (Hurst from order flow, $TICK
    breadth, VIX, macro-calendar) are gated out."""
    er = _kaufman_er(closes, lookback)
    vr = _variance_ratio(closes, lookback)
    sdir, _ = _stepgma_dir(closes, MO_FAST, MO_SLOW)
    trend_votes = range_votes = 0.0
    if er >= REGIME_TREND_ER:
        trend_votes += 1.5
    elif er <= REGIME_RANGE_ER:
        range_votes += 1.5
    if vr > 1.1:
        trend_votes += 1.0
    elif vr < 0.9:
        range_votes += 1.0
    if sdir in ("bull", "bear"):
        trend_votes += 1.0
    else:
        range_votes += 0.5
    return "TREND" if trend_votes > range_votes else "RANGE"


def _regime_dir(closes, ohlc, lookback, cfg):
    """Regime trades trend-continuation ONLY in a classified TREND regime; flat otherwise."""
    if _regime_class(closes, ohlc, lookback) != "TREND":
        return None
    sdir, _ = _stepgma_dir(closes, MO_FAST, MO_SLOW)
    return "long" if sdir == "bull" else ("short" if sdir == "bear" else None)


def _regime_trades(ohlc, lookback=LOOKBACK, cfg=None):
    return _consensus_engine_trades(ohlc, lookback, cfg, _regime_dir)


def prove_regime(ohlc, cfg=None):
    """Regime (faithful OHLC core): regime-gated trend continuation — trades only in a
    classified TREND regime (Kaufman-ER + variance-ratio + StepGMA vote), flat in RANGE.
    GATED-OUT non-OHLC: Hurst (order-flow), Shannon/permutation entropy, $TICK/$ADD breadth,
    VIX, macro-calendar blackouts (ES-settlement/CME-maintenance/FOMC/CPI/NFP), the risk-shell
    daily-loss kill."""
    return _consensus_prove(ohlc, cfg, _regime_dir, "")


def _regime_signal(closes, ohlc, lookback, cfg):
    d = _regime_dir(closes, ohlc, lookback, cfg)
    if not d:
        return None
    entry = closes[-1]
    stop, target = _atr_stop_target(ohlc, entry, d, MO_ATR_MULT, MO_TARGET_R)
    return {"direction": d, "stop": stop, "target": target,
            "rationale": f"regime {d}: TREND regime (Kaufman ER/var-ratio), continuation"}


# ---- channel (consensus + Fibonacci golden-pocket entry gate) --------------
CHAN_FIB_LB = 60
CHAN_LONG_LO, CHAN_LONG_HI = 0.34, 0.42     # golden pocket (long retracement)
CHAN_SHORT_LO, CHAN_SHORT_HI = 0.58, 0.66   # golden pocket (short retracement)


def _channel_dir(closes, ohlc, lookback, cfg):
    """Channel = momentum consensus + Fibonacci golden-pocket entry gate. A consensus LONG only
    fires when the last close sits in the [0.34,0.42] retracement of the swing; a SHORT in
    [0.58,0.66]. GATED-OUT non-OHLC voters: CVD/divergence, SMT, session-DNA, order-flow
    absorption, FVG context, entropy, VIX, econ-calendar."""
    d = _consensus_dir(closes, ohlc, lookback, MO_FAST, MO_SLOW, MO_ER)
    if not d:
        return None
    pos = _fib_pos(closes, CHAN_FIB_LB)
    if pos is None:
        return None
    if d == "long" and not (CHAN_LONG_LO <= pos <= CHAN_LONG_HI):
        return None
    if d == "short" and not (CHAN_SHORT_LO <= pos <= CHAN_SHORT_HI):
        return None
    return d


def _channel_trades(ohlc, lookback=LOOKBACK, cfg=None):
    return _consensus_engine_trades(ohlc, lookback, cfg, _channel_dir)


def prove_channel(ohlc, cfg=None):
    """Channel (faithful OHLC core): consensus momentum with a Fibonacci golden-pocket entry
    filter and ATR stop / 2:1 target geometry. GATED-OUT non-OHLC voters: CVD/divergence, SMT,
    session-DNA, order-flow absorption, FVG context, entropy, VIX, econ-calendar."""
    return _consensus_prove(ohlc, cfg, _channel_dir, "")


def _channel_signal(closes, ohlc, lookback, cfg):
    d = _channel_dir(closes, ohlc, lookback, cfg)
    if not d:
        return None
    entry = closes[-1]
    stop, target = _atr_stop_target(ohlc, entry, d, MO_ATR_MULT, MO_TARGET_R)
    return {"direction": d, "stop": stop, "target": target,
            "rationale": f"channel {d}: consensus in golden pocket (Fib {CHAN_LONG_LO}-{CHAN_LONG_HI})"}


# ---- context_a / context_b (Context engines: A/B context-strictness split) -
# A and B share the momentum-consensus core; the OHLC-faithful A/B lever: A = the loose momentum
# consensus; B = a strict variant requiring a FULLY-stacked EMA ribbon (not merely 'not-opposite')
# AND a higher Kaufman-ER floor. The world-model win-rate gate is NON-OHLC (needs the buyer's own
# graded journal, which ships EMPTY) -> documented gated-out.
CTX_B_ER = 0.45   # context_b: stricter Kaufman-ER trend gate than context_a (default 0.30)


def _ctx_dir(closes, ohlc, lookback, strict):
    if not strict:
        return _consensus_dir(closes, ohlc, lookback, MO_FAST, MO_SLOW, MO_ER)
    if len(closes) < MO_SLOW + 1:
        return None
    sdir, _ = _stepgma_dir(closes, MO_FAST, MO_SLOW)
    ribbon = _ribbon_bull(closes)
    if _kaufman_er(closes, lookback) < CTX_B_ER:
        return None
    if sdir == "bull" and ribbon is True:
        return "long"
    if sdir == "bear" and ribbon is False:
        return "short"
    return None


def _context_a_dir(closes, ohlc, lookback, cfg):
    return _ctx_dir(closes, ohlc, lookback, strict=False)


def _context_b_dir(closes, ohlc, lookback, cfg):
    return _ctx_dir(closes, ohlc, lookback, strict=True)


def _context_a_trades(ohlc, lookback=LOOKBACK, cfg=None):
    return _consensus_engine_trades(ohlc, lookback, cfg, _context_a_dir)


def _context_b_trades(ohlc, lookback=LOOKBACK, cfg=None):
    return _consensus_engine_trades(ohlc, lookback, cfg, _context_b_dir)


def prove_context_a(ohlc, cfg=None):
    """Context A (faithful OHLC core): momentum consensus with the looser context profile.
    GATED-OUT non-OHLC: the world-model win-rate gate needs the buyer's own graded journal
    (ships empty) + the same order-flow/macro voters as momentum."""
    return _consensus_prove(ohlc, cfg, _context_a_dir, "context_a")


def prove_context_b(ohlc, cfg=None):
    """Context B (faithful OHLC core): momentum consensus with the STRICTER context profile
    (full EMA-ribbon stack + higher Kaufman-ER floor). GATED-OUT non-OHLC: the world-model
    win-rate gate (ships empty) + the same order-flow/macro voters as momentum."""
    return _consensus_prove(ohlc, cfg, _context_b_dir, "context_b")


def _context_a_signal(closes, ohlc, lookback, cfg):
    d = _context_a_dir(closes, ohlc, lookback, cfg)
    if not d:
        return None
    entry = closes[-1]
    stop, target = _atr_stop_target(ohlc, entry, d, MO_ATR_MULT, MO_TARGET_R)
    return {"direction": d, "stop": stop, "target": target,
            "rationale": f"context_a {d}: consensus (loose context)"}


def _context_b_signal(closes, ohlc, lookback, cfg):
    d = _context_b_dir(closes, ohlc, lookback, cfg)
    if not d:
        return None
    entry = closes[-1]
    stop, target = _atr_stop_target(ohlc, entry, d, MO_ATR_MULT, MO_TARGET_R)
    return {"direction": d, "stop": stop, "target": target,
            "rationale": f"context_b {d}: consensus (strict context)"}


# Registry of per-engine OOS trade generators. Keeps the gate, the screener and the full
# backtest report in lockstep — every engine's OOS candidate verdict comes from THIS walk, nothing else.
# research reuses the breakout walk as its tradable OOS proxy (same as prove_research).
ENGINE_TRADES = {"meanrev": _mr_trades, "breakout": _bk_trades, "research": _bk_trades,
                 "momentum": _momentum_trades, "structure": _structure_trades,
                 "regime": _regime_trades, "channel": _channel_trades,
                 "context_a": _context_a_trades, "context_b": _context_b_trades}


def engine_trades(engine, oos_ohlc, lookback, cfg=None):
    """The OOS trade list for `engine` on a bar segment. Empty list for an unknown engine."""
    gen = ENGINE_TRADES.get(engine)
    return gen(oos_ohlc, lookback, cfg) if gen else []


PROVERS = {"meanrev": prove_meanrev, "breakout": prove_breakout, "research": prove_research,
           "momentum": prove_momentum, "structure": prove_structure, "regime": prove_regime,
           "channel": prove_channel, "context_a": prove_context_a, "context_b": prove_context_b}


def prover_source_sha256() -> str:
    """Full SHA-256 of this prover module for immutable optimizer provenance."""
    import hashlib
    try:
        with open(__file__, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except OSError:
        return "unknown"


def prover_source_sha() -> str:
    """Compact 16-hex display form used by the existing API/reference wire contract."""
    digest = prover_source_sha256()
    return digest[:16] if len(digest) == 64 else digest


# ===========================================================================
# The own SQLite store.
# ===========================================================================
SCHEMA = """
CREATE TABLE IF NOT EXISTS bars (
    symbol TEXT NOT NULL,
    ts INTEGER NOT NULL,          -- bar close epoch (seconds)
    o REAL, h REAL, l REAL, c REAL NOT NULL,
    v REAL NOT NULL DEFAULT 0,     -- real source volume when supplied
    delta REAL NOT NULL DEFAULT 0, -- real/inferred source order-flow delta when supplied
    ts_recorded INTEGER NOT NULL, -- wall-clock when captured (for feedLive window)
    PRIMARY KEY (symbol, ts)
);
CREATE INDEX IF NOT EXISTS bars_sym_ts ON bars(symbol, ts);
CREATE TABLE IF NOT EXISTS wc_live (
    symbol TEXT PRIMARY KEY,
    price REAL NOT NULL,
    recorded INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS fires (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    engine TEXT NOT NULL,
    direction TEXT NOT NULL,
    entry REAL NOT NULL,
    symbol TEXT,
    stop REAL, target REAL,
    rationale TEXT,
    outcome TEXT,
    pnl REAL,
    synthetic INTEGER NOT NULL DEFAULT 0,
    bar_ts INTEGER,              -- exact closed-bar epoch that created the signal (durable dedupe/grading)
    max_hold INTEGER,            -- entry-inclusive causal hold window fixed when the signal fires
    tick_size REAL,              -- fill/order increment fixed when the signal fires
    ts INTEGER NOT NULL
);
-- Durable signal-transition state. Capture processes restart; an in-memory last-direction map made
-- the same historical signal fire again after every restart. Persist direction + gate state at the
-- exact closed-bar endpoint so unchanged/rejected signals remain idempotent across processes.
CREATE TABLE IF NOT EXISTS signal_state (
    engine TEXT NOT NULL,
    symbol TEXT NOT NULL,
    direction TEXT,
    edge_ok INTEGER NOT NULL DEFAULT 0,
    bar_ts INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (engine, symbol)
);
-- EXECUTION control state (arm/mode/kill/firm/...). Deliberately a SEPARATE table, NOT in the
-- config blob, so a /api/config POST can never flip arm/mode/kill (set_config only touches config).
CREATE TABLE IF NOT EXISTS exec_kv (
    k TEXT PRIMARY KEY,
    v TEXT
);
-- EXECUTION order/decision audit. Every precheck decision (placed or blocked) is recorded here —
-- the source of truth for trades-today, open paper contracts, dedup, and an honest audit trail.
CREATE TABLE IF NOT EXISTS exec_orders (
    client_order_id TEXT PRIMARY KEY,
    engine TEXT, symbol TEXT, direction TEXT,
    size INTEGER, route TEXT, reason TEXT,
    status TEXT,                  -- blocked | paper_working | pending | working | filled | closed | cancelled
    realized_pnl REAL,           -- set when closed (NULL while open)
    confirmed INTEGER NOT NULL DEFAULT 0,
    is_automated INTEGER NOT NULL DEFAULT 1,
    ts INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS exec_orders_ts ON exec_orders(ts);
"""

LIVE_BAR_WINDOW = 600     # feedLive: a bar recorded in the last 10 min
LIVE_TICK_WINDOW = 30     # liveTicks: a tick in the last 30 s
EDGE_TTL = 120            # cache edge verdicts for 2 min (matches Utah's TTL intent)
LIVE_ENGINE_BARS = 5000   # bounded newest-bar window for the continuously-running live evaluator
ANALYSIS_MAX_BARS = 250000  # bounded but materially complete local research/backtest history

# One-time, idempotent rename migration. The engine roster moved from internal codenames to
# generic customer-facing ids; any fire rows captured under the old id are relabelled in place so
# the journal stays consistent. Safe + a no-op on the empty store this product ships with (an
# UPDATE that matches nothing changes nothing).
_RENAMED_ENGINES = {
    "perp": "momentum", "bible": "structure", "apex": "regime",
    "barber": "channel", "ctx_alpha": "context_a", "ctx_bravo": "context_b",
}


class Store:
    """The product's own SQLite-backed data + analysis store. Thread-safe (one lock; the
    backend is a ThreadingHTTPServer). Every read degrades to empty on a broken store."""

    def __init__(self, path: str, config_path: str | None = None):
        self.path = path
        # Config travels WITH the store: it lives next to the store DB unless an explicit config_path
        # (or BLTD_CONFIG) is given. In production store+config both sit in the app-support dir, so this
        # is identical to default_config_path(); for a test/temp store it keeps set_config writes inside
        # the temp dir instead of clobbering the buyer's real app-support config.json (test isolation).
        self.config_path = (config_path or os.environ.get("BLTD_CONFIG")
                            or os.path.join(os.path.dirname(os.path.abspath(path)), "config.json"))
        self._lock = threading.Lock()
        self._edge_cache = {}  # (engine,symbol) -> (expiry, verdict)
        self._ok = False
        try:
            d = os.path.dirname(path)
            if d:
                os.makedirs(d, exist_ok=True)
            with self._connect() as cx:
                cx.executescript(SCHEMA)
                cols = {r[1] for r in cx.execute("PRAGMA table_info(bars)").fetchall()}
                if "v" not in cols:
                    cx.execute("ALTER TABLE bars ADD COLUMN v REAL NOT NULL DEFAULT 0")
                if "delta" not in cols:
                    cx.execute("ALTER TABLE bars ADD COLUMN delta REAL NOT NULL DEFAULT 0")
                fire_cols = {r[1] for r in cx.execute("PRAGMA table_info(fires)").fetchall()}
                if "bar_ts" not in fire_cols:
                    cx.execute("ALTER TABLE fires ADD COLUMN bar_ts INTEGER")
                if "max_hold" not in fire_cols:
                    cx.execute("ALTER TABLE fires ADD COLUMN max_hold INTEGER")
                if "tick_size" not in fire_cols:
                    cx.execute("ALTER TABLE fires ADD COLUMN tick_size REAL")
                # Existing rows migrate with bar_ts=NULL, which SQLite deliberately permits through
                # the unique index. Every new real fire carries a bar timestamp and is idempotent.
                cx.execute(
                    "CREATE UNIQUE INDEX IF NOT EXISTS fires_signal_bar_unique "
                    "ON fires(engine,symbol,direction,bar_ts) "
                    "WHERE synthetic=0 AND bar_ts IS NOT NULL")
                # Idempotent: relabel any fires captured under the old engine codenames.
                for old, new in _RENAMED_ENGINES.items():
                    cx.execute("UPDATE fires SET engine=? WHERE engine=?", (new, old))
                # b27 is signals-only. Neutralize any legacy armed state before the API/capture
                # starts; the shipping runtime exposes no route or adapter that can re-enable it.
                for key, value in (
                    ("armed", "0"), ("mode", "paper"), ("kill", "1"),
                    ("liveAuthExpiry", "0"), ("demoValidated", "0"),
                    ("confirmEachOrder", "1"),
                ):
                    cx.execute(
                        "INSERT INTO exec_kv(k,v) VALUES(?,?) "
                        "ON CONFLICT(k) DO UPDATE SET v=excluded.v",
                        (key, value))
                cx.commit()
            self._ok = True
        except Exception:  # noqa: BLE001 — unwritable path: store stays "offline", never crashes
            self._ok = False

    def _connect(self):
        cx = sqlite3.connect(self.path, timeout=5)
        cx.execute("PRAGMA journal_mode=WAL")
        cx.execute("PRAGMA busy_timeout=5000")
        return cx

    def _q(self, sql, params=()):
        """Read-only query -> list of tuples. Any error -> [] (honest empty)."""
        if not self._ok:
            return []
        try:
            with self._lock, self._connect() as cx:
                return list(cx.execute(sql, params).fetchall())
        except Exception:  # noqa: BLE001
            return []

    def _exec(self, sql, seq, many=False):
        if not self._ok:
            return 0
        try:
            with self._lock, self._connect() as cx:
                cur = cx.executemany(sql, seq) if many else cx.execute(sql, seq)
                cx.commit()
                return cur.rowcount
        except Exception:  # noqa: BLE001
            return 0

    # ---- health / meta -------------------------------------------------
    def online(self) -> bool:
        return self._ok and self._q("SELECT 1") == [(1,)]

    def meta(self) -> dict:
        cutoff = int(time.time()) - LIVE_BAR_WINDOW
        today = int(time.time()) - (int(time.time()) % 86400)  # UTC midnight
        fires_today = self._q("SELECT symbol FROM fires WHERE synthetic=0 AND ts>=?", (today,))
        live_syms = self._q("SELECT DISTINCT symbol FROM bars WHERE ts_recorded>?", (cutoff,))
        return {"online": self.online(), "feedLive": any(in_scope(s) for (s,) in live_syms),
                "signalsToday": sum(1 for (s,) in fires_today if in_scope(s))}

    # ---- symbols -------------------------------------------------------
    def symbols(self) -> dict:
        bt = scoped_symbols([r[0] for r in self._q(
            "SELECT symbol FROM bars GROUP BY symbol HAVING count(*)>=40 ORDER BY symbol")])
        live = scoped_symbols([r[0] for r in self._q(
            "SELECT DISTINCT symbol FROM bars WHERE ts_recorded>? ORDER BY symbol",
            (int(time.time()) - LIVE_BAR_WINDOW,))])
        ticks = scoped_symbols([r[0] for r in self._q(
            "SELECT symbol FROM wc_live WHERE recorded>? ORDER BY symbol",
            (int(time.time()) - LIVE_TICK_WINDOW,))])
        # "busiest" drives the app's default chart symbol, so it must follow what is LIVE right now,
        # not all-time volume. Otherwise a retired instrument (an old front month carrying a huge
        # all-time bar count, or a final burst before it stopped) hijacks the default and the app opens
        # on a dead chart while another symbol is actively trading. Rule: among symbols live right now
        # (a bar in the last LIVE_BAR_WINDOW), pick the most active; only when nothing is live (market
        # closed / fresh store) fall back to the all-time leader for backtesting.
        live_rows = self._q(
            "SELECT symbol FROM bars WHERE ts_recorded>? GROUP BY symbol ORDER BY count(*) DESC",
            (int(time.time()) - LIVE_BAR_WINDOW,))
        busiest = next((r[0] for r in live_rows if in_scope(r[0])), None)
        if busiest is None:
            busiest_rows = self._q("SELECT symbol FROM bars GROUP BY symbol ORDER BY count(*) DESC")
            busiest = next((r[0] for r in busiest_rows if in_scope(r[0])), None)
        return {"backtestable": bt, "live": live, "liveTicks": ticks,
                "busiest": busiest}

    # ---- bars ----------------------------------------------------------
    def bars(self, symbol: str, limit: int, newest: bool) -> dict:
        if not symbol or not in_scope(symbol):
            return {"symbol": symbol, "bars": []}
        if newest:
            rows = self._q(
                "SELECT o,h,l,c,ts,v,delta FROM (SELECT o,h,l,c,ts,v,delta FROM bars WHERE symbol=? "
                "ORDER BY ts DESC LIMIT ?) ORDER BY ts ASC", (symbol, limit))
        else:
            rows = self._q("SELECT o,h,l,c,ts,v,delta FROM bars WHERE symbol=? ORDER BY ts LIMIT ?",
                           (symbol, limit))
        return {"symbol": symbol,
                "bars": [[r[0], r[1], r[2], r[3], float(r[4]), r[5], r[6]] for r in rows]}

    def record_bars(self, symbol: str, rows) -> int:
        """rows: [(ts_epoch, o, h, l, c), ...]. Upsert by (symbol, ts) so overlapping capture
        windows never double-count. Returns count attempted."""
        if not in_scope(symbol):
            return 0
        now = int(time.time())
        seq = []
        for row in rows:
            ts, o, h, l, c = row[:5]
            v = row[5] if len(row) >= 6 else 0.0
            d = row[6] if len(row) >= 7 else 0.0
            seq.append((symbol, int(ts), o, h, l, c, float(v or 0), float(d or 0), now))
        if not seq:
            return 0
        self._exec(
            "INSERT INTO bars(symbol,ts,o,h,l,c,v,delta,ts_recorded) VALUES(?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(symbol,ts) DO UPDATE SET o=excluded.o,h=excluded.h,l=excluded.l,"
            "c=excluded.c,v=excluded.v,delta=excluded.delta,ts_recorded=excluded.ts_recorded", seq, many=True)
        return len(seq)

    def record_bars_batch(self, by_symbol) -> int:
        """by_symbol: {symbol: [(ts_epoch, o, h, l, c[, volume[, delta]]), ...]}.

        Batch-shaped companion to record_bars. Filters out-of-scope symbols before write, and
        returns -1 if the batch write fails so callers can requeue instead of dropping source data
        silently."""
        if not isinstance(by_symbol, dict):
            return 0
        now = int(time.time())
        seq = []
        try:
            for symbol, rows in by_symbol.items():
                if not in_scope(symbol):
                    continue
                for row in rows or []:
                    ts, o, h, l, c = row[:5]
                    v = row[5] if len(row) >= 6 else 0.0
                    d = row[6] if len(row) >= 7 else 0.0
                    seq.append((symbol, int(ts), o, h, l, c, float(v or 0), float(d or 0), now))
        except (TypeError, ValueError):
            return -1
        if not seq:
            return 0
        rc = self._exec(
            "INSERT INTO bars(symbol,ts,o,h,l,c,v,delta,ts_recorded) VALUES(?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(symbol,ts) DO UPDATE SET o=excluded.o,h=excluded.h,l=excluded.l,"
            "c=excluded.c,v=excluded.v,delta=excluded.delta,ts_recorded=excluded.ts_recorded", seq, many=True)
        return -1 if rc <= 0 else len(seq)

    # ---- live tick -----------------------------------------------------
    def live_price(self, symbol: str) -> dict:
        if not symbol or not in_scope(symbol):
            return {"gated": True}
        # Recency-gated: a "live" last price must be FRESH (same LIVE_TICK_WINDOW the symbols()
        # liveTicks set uses). A stale row is gated, never served as the live line — otherwise the
        # chart would show an hours-old price as live (stale-as-live fabrication).
        rows = self._q("SELECT price,recorded FROM wc_live WHERE symbol=? AND recorded>?",
                       (symbol, int(time.time()) - LIVE_TICK_WINDOW))
        if not rows:
            return {"symbol": symbol, "gated": True}
        return {"symbol": symbol, "price": rows[0][0], "ts": float(rows[0][1])}

    def record_tick(self, symbol: str, price: float, epoch: int) -> None:
        if not in_scope(symbol):
            return
        self._exec("INSERT INTO wc_live(symbol,price,recorded) VALUES(?,?,?) "
                   "ON CONFLICT(symbol) DO UPDATE SET price=excluded.price,"
                   "recorded=excluded.recorded", (symbol, float(price), int(epoch)))

    def record_ticks_batch(self, items) -> int:
        """items: [{"symbol": sym, "price": px, "epoch": ts}, ...] or [(sym, px, ts), ...].

        Filters out-of-scope ticks before write and returns -1 on write failure so a future flusher can
        requeue. The live tick table remains one latest row per symbol, matching record_tick."""
        seq = []
        try:
            for item in items or []:
                if isinstance(item, dict):
                    symbol = item.get("symbol")
                    price = item.get("price", item.get("close"))
                    epoch = item.get("epoch", item.get("recorded"))
                else:
                    try:
                        symbol, price, epoch = item
                    except (TypeError, ValueError):
                        continue
                if not in_scope(symbol):
                    continue
                seq.append((symbol, float(price), int(epoch)))
        except (TypeError, ValueError):
            return -1
        if not seq:
            return 0
        rc = self._exec(
            "INSERT INTO wc_live(symbol,price,recorded) VALUES(?,?,?) "
            "ON CONFLICT(symbol) DO UPDATE SET price=excluded.price,"
            "recorded=excluded.recorded", seq, many=True)
        return -1 if rc <= 0 else len(seq)

    # ---- fires ---------------------------------------------------------
    def record_fire(self, engine, direction, entry, symbol=None, stop=None, target=None,
                    rationale=None, synthetic=False, bar_ts=None, max_hold=None,
                    tick_size=None) -> int:
        # Storage gate only — WHETHER to fire is decided upstream by the edge-gate (proven OOS edge
        # per engine,symbol). in_scope just keeps junk symbols out of the journal. New real signals
        # are keyed to the exact closed bar so a daemon restart/race cannot duplicate the journal.
        if symbol is not None and not in_scope(symbol):
            return 0
        return self._exec(
            "INSERT OR IGNORE INTO fires("
            "engine,direction,entry,symbol,stop,target,rationale,synthetic,bar_ts,"
            "max_hold,tick_size,ts) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            (engine, direction, float(entry), symbol, stop, target, rationale,
             1 if synthetic else 0, (int(bar_ts) if bar_ts is not None else None),
             (int(max_hold) if max_hold is not None else None),
             (float(tick_size) if tick_size is not None else None), int(time.time())))

    def observe_signal(self, engine: str, symbol: str, direction: str | None,
                       edge_ok: bool, bar_ts: int) -> bool:
        """Persist one evaluated signal state and return True exactly when it should fire.

        A fire is eligible on signal appearance/flip, or when an unchanged direction transitions
        from FDR-rejected to FDR-approved. State is committed atomically with the decision so a new
        capture process over the same closed bar cannot replay it. A None direction clears the
        appearance state, allowing a later genuine reappearance to fire.
        """
        if not self._ok or not in_scope(symbol):
            return False
        direction = direction if direction in ("long", "short") else None
        bar_ts = int(bar_ts)
        now = int(time.time())
        try:
            with self._lock, self._connect() as cx:
                row = cx.execute(
                    "SELECT direction,edge_ok,bar_ts FROM signal_state WHERE engine=? AND symbol=?",
                    (engine, symbol)).fetchone()
                previous_direction = row[0] if row else None
                previous_edge = bool(row[1]) if row else False
                should_fire = bool(
                    direction and edge_ok
                    and (row is None or direction != previous_direction or not previous_edge))
                cx.execute(
                    "INSERT INTO signal_state(engine,symbol,direction,edge_ok,bar_ts,updated_at) "
                    "VALUES(?,?,?,?,?,?) "
                    "ON CONFLICT(engine,symbol) DO UPDATE SET "
                    "direction=excluded.direction,edge_ok=excluded.edge_ok,"
                    "bar_ts=excluded.bar_ts,updated_at=excluded.updated_at",
                    (engine, symbol, direction, 1 if edge_ok else 0, bar_ts, now))
                cx.commit()
                return should_fire
        except Exception:  # noqa: BLE001 — broken state storage fails closed (never duplicate/fire)
            return False

    def record_signal_evaluation(self, engine: str, symbol: str, direction: str | None,
                                 edge_ok: bool, bar_ts: int, entry=None, stop=None,
                                 target=None, rationale=None, max_hold=None,
                                 tick_size=None) -> int:
        """Atomically persist one evaluation and, when flat, its journal fire.

        The earlier two-transaction sequence committed ``signal_state`` before inserting ``fires``.
        A crash or disk error between those writes permanently consumed the transition without a
        journal row or alert. This single transaction either records both facts or neither.

        Lifecycle parity is position-based, not direction-transition-based: the canonical prover
        may re-enter an unchanged LONG/SHORT signal after the prior bracket closes. At most one
        outcome-NULL fire per engine+symbol is allowed; while it is open, later signal bars only
        advance durable state. Once grading closes it, a strictly later eligible signal bar may
        fire even when direction is unchanged. The same bar remains restart-idempotent.
        """
        if not self._ok or not in_scope(symbol):
            return 0
        direction = direction if direction in ("long", "short") else None
        try:
            bar_ts = int(bar_ts)
            entry_value = float(entry) if entry is not None else None
            max_hold_value = int(max_hold) if max_hold is not None else None
            tick_size_value = float(tick_size) if tick_size is not None else None
        except (TypeError, ValueError, OverflowError):
            return 0
        now = int(time.time())
        try:
            with self._lock, self._connect() as cx:
                # Serialize the read-open-position -> state/fire write sequence across processes,
                # not only threads sharing this Store instance.
                cx.execute("BEGIN IMMEDIATE")
                row = cx.execute(
                    "SELECT direction,edge_ok,bar_ts FROM signal_state WHERE engine=? AND symbol=?",
                    (engine, symbol)).fetchone()
                previous_direction = row[0] if row else None
                previous_edge = bool(row[1]) if row else False
                previous_bar_ts = int(row[2]) if row else None
                if previous_bar_ts is not None and bar_ts < previous_bar_ts:
                    cx.rollback()
                    return 0
                open_fire = cx.execute(
                    "SELECT 1 FROM fires WHERE synthetic=0 AND engine=? AND symbol=? "
                    "AND outcome IS NULL LIMIT 1",
                    (engine, symbol)).fetchone()
                newer_bar = previous_bar_ts is None or bar_ts > previous_bar_ts
                # A transient family-gate failure may recover before the immutable signal bar
                # changes. Preserve that prior contract without allowing a same-bar direction
                # rewrite or a restart duplicate.
                same_bar_gate_recovery = bool(
                    previous_bar_ts == bar_ts and direction == previous_direction
                    and edge_ok and not previous_edge)
                should_fire = bool(
                    direction and edge_ok and entry_value is not None
                    and not open_fire and (newer_bar or same_bar_gate_recovery))
                # Replaying an already-evaluated immutable bar changes nothing unless the sole
                # allowed mutation is rejected->approved gate recovery above.
                if (previous_bar_ts == bar_ts and not same_bar_gate_recovery):
                    cx.commit()
                    return 0
                cx.execute(
                    "INSERT INTO signal_state(engine,symbol,direction,edge_ok,bar_ts,updated_at) "
                    "VALUES(?,?,?,?,?,?) "
                    "ON CONFLICT(engine,symbol) DO UPDATE SET "
                    "direction=excluded.direction,edge_ok=excluded.edge_ok,"
                    "bar_ts=excluded.bar_ts,updated_at=excluded.updated_at",
                    (engine, symbol, direction, 1 if edge_ok else 0, bar_ts, now))
                inserted = 0
                if should_fire:
                    cur = cx.execute(
                        "INSERT OR IGNORE INTO fires("
                        "engine,direction,entry,symbol,stop,target,rationale,synthetic,bar_ts,"
                        "max_hold,tick_size,ts) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                        (engine, direction, entry_value, symbol, stop, target, rationale,
                         0, bar_ts, max_hold_value, tick_size_value, now))
                    inserted = max(0, cur.rowcount)
                cx.commit()
                return inserted
        except Exception:  # noqa: BLE001 — no partial state/fire and no fail-open signal
            return 0

    def grade_open_fires(self, symbol: str) -> dict:
        """Grade new real signals from later CLOSED OHLC bars.

        Only fires carrying a durable bar_ts are eligible; legacy rows remain honestly ungraded.
        If a bar spans both stop and target, OHLC cannot reveal touch order, so the result is
        conservatively resolved as a stop/loss. PnL is points, matching the journal's existing
        points-only posture.
        """
        summary = {"graded": 0, "wins": 0, "losses": 0}
        if not self._ok or not in_scope(symbol):
            return summary
        try:
            with self._lock, self._connect() as cx:
                cfg = self.config()
                default_tick = _research_tick_size(cfg) or RESEARCH_TICK_SIZE
                fires = list(cx.execute(
                    "SELECT id,engine,direction,entry,stop,target,bar_ts,max_hold,tick_size "
                    "FROM fires "
                    "WHERE synthetic=0 AND outcome IS NULL AND symbol=? AND bar_ts IS NOT NULL "
                    "AND stop IS NOT NULL AND target IS NOT NULL ORDER BY id",
                    (symbol,)).fetchall())
                for (fire_id, engine, direction, entry, stop, target, fired_bar_ts,
                     stored_max_hold, stored_tick_size) in fires:
                    if stored_max_hold is not None:
                        try:
                            max_hold = int(stored_max_hold)
                        except (TypeError, ValueError, OverflowError):
                            continue
                    elif engine in ("breakout", "research"):
                        max_hold = _breakout_max_hold(cfg) or BK_MAX_HOLD
                    else:
                        max_hold = MR_MAX_HOLD
                    try:
                        tick_size = (float(stored_tick_size) if stored_tick_size is not None
                                     else default_tick)
                    except (TypeError, ValueError, OverflowError):
                        continue
                    if max_hold < 1 or not math.isfinite(tick_size) or tick_size <= 0:
                        continue
                    bars = cx.execute(
                        "SELECT o,h,l,c FROM bars WHERE symbol=? AND ts>? "
                        "ORDER BY ts LIMIT ?",
                        (symbol, int(fired_bar_ts), max_hold)).fetchall()
                    ohlc = [((o if o is not None else c), (h if h is not None else c),
                             (l if l is not None else c), c)
                            for (o, h, l, c) in bars if c is not None]
                    trade = _bracket_trade(
                        ohlc, 0, direction, entry, stop, target, max_hold, tick_size,
                        signal_index=-1, close_incomplete=False) if ohlc else None
                    if trade:
                        pnl = ((trade["exit"] - trade["entry"]) if direction == "long"
                               else (trade["entry"] - trade["exit"]))
                        outcome = "win" if pnl > 0 else "loss"
                        cx.execute("UPDATE fires SET outcome=?,pnl=? WHERE id=? AND outcome IS NULL",
                                   (outcome, round(float(pnl), 6), fire_id))
                        summary["graded"] += 1
                        summary["wins" if outcome == "win" else "losses"] += 1
                cx.commit()
            return summary
        except Exception:  # noqa: BLE001 — grading failure leaves signals open, never fabricates
            return summary

    def latest_fire(self) -> dict:
        rows = self._q(
            "SELECT id,engine,direction,entry,symbol,stop,target,rationale,outcome,pnl,ts "
            "FROM fires WHERE synthetic=0 ORDER BY id DESC LIMIT 100")
        row = next((r for r in rows if in_scope(r[4])), None)
        return {"fire": self._fire_dict(row) if row else None}

    @staticmethod
    def _fire_dict(r) -> dict:
        ts = time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(r[10])) if r[10] else None
        return {"id": r[0], "engine": r[1], "direction": r[2], "entry": r[3], "symbol": r[4],
                "stop": r[5], "target": r[6], "rationale": r[7], "outcome": r[8], "pnl": r[9],
                "ts": ts, "tsEpoch": r[10]}

    def fires(self, limit: int = 200, symbol: str | None = None, engine: str | None = None) -> dict:
        """The signal journal: recorded real (non-synthetic) fires, newest first, optionally
        filtered. Each row carries its outcome/pnl if the daemon has graded it. Honest empty on
        a cold store."""
        if symbol and not in_scope(symbol):
            return {"fires": []}
        where = ["synthetic=0"]
        params: list = []
        if symbol:
            where.append("symbol=?")
            params.append(symbol)
        if engine:
            where.append("engine=?")
            params.append(engine)
        params.append(int(limit))
        rows = self._q(
            "SELECT id,engine,direction,entry,symbol,stop,target,rationale,outcome,pnl,ts "
            f"FROM fires WHERE {' AND '.join(where)} ORDER BY id DESC LIMIT ?", tuple(params))
        return {"fires": [self._fire_dict(r) for r in rows if in_scope(r[4])][:int(limit)]}

    def journal_stats(self, symbol: str | None = None, engine: str | None = None) -> dict:
        """Performance analytics over the journal of *graded* fires (hypothetical, signals-only).
        Counts only fires the daemon has marked target/stop with a pnl — never invents an outcome
        for an open signal."""
        if symbol and not in_scope(symbol):
            return {"graded": 0, "wins": 0, "losses": 0, "winRate": 0.0, "netPnl": 0.0,
                    "avgWin": 0.0, "avgLoss": 0.0, "byEngine": {}}
        where = ["synthetic=0", "outcome IS NOT NULL", "pnl IS NOT NULL"]
        params: list = []
        if symbol:
            where.append("symbol=?")
            params.append(symbol)
        if engine:
            where.append("engine=?")
            params.append(engine)
        rows = self._q(
            f"SELECT outcome,pnl,engine,symbol FROM fires WHERE {' AND '.join(where)}", tuple(params))
        rows = [r for r in rows if in_scope(r[3])]
        n = len(rows)
        if n == 0:
            return {"graded": 0, "wins": 0, "losses": 0, "winRate": 0.0, "netPnl": 0.0,
                    "avgWin": 0.0, "avgLoss": 0.0, "byEngine": {}}
        wins = [r[1] for r in rows if (r[1] or 0) > 0]
        losses = [r[1] for r in rows if (r[1] or 0) < 0]
        by_engine: dict = {}
        for outcome, pnl, eng, _sym in rows:
            e = by_engine.setdefault(eng, {"n": 0, "wins": 0, "netPnl": 0.0})
            e["n"] += 1
            e["wins"] += 1 if (pnl or 0) > 0 else 0
            e["netPnl"] = round(e["netPnl"] + (pnl or 0), 4)
        return {"graded": n, "wins": len(wins), "losses": len(losses),
                "winRate": round(len(wins) / n, 4),
                "netPnl": round(sum((r[1] or 0) for r in rows), 4),
                "avgWin": round(sum(wins) / len(wins), 4) if wins else 0.0,
                "avgLoss": round(sum(losses) / len(losses), 4) if losses else 0.0,
                "byEngine": by_engine}

    # ---- in-process edge gate -----------------------------------------
    def ohlc(self, symbol: str, limit: int = LIVE_ENGINE_BARS):
        """Newest bounded live-engine window as [(o,h,l,c), ...] oldest->newest.

        Selecting the oldest LIMIT rows freezes the live endpoint forever once a store grows past
        the limit. The inner DESC query deliberately selects the newest rows; the outer ASC restores
        chronological order for causal engine math.
        """
        if not in_scope(symbol):
            return []
        rows = self._q(
            "SELECT o,h,l,c FROM ("
            "SELECT o,h,l,c,ts FROM bars WHERE symbol=? ORDER BY ts DESC LIMIT ?"
            ") ORDER BY ts ASC",
            (symbol, max(1, min(int(limit), ANALYSIS_MAX_BARS))))
        # tolerate null o/h/l (close-only history) by falling back to close
        return [((o if o is not None else c), (h if h is not None else c),
                 (l if l is not None else c), c) for (o, h, l, c) in rows]

    def ohlc_between(self, symbol: str, start_ts=None, end_ts=None,
                     limit: int = ANALYSIS_MAX_BARS):
        """A symbol's bars as [(o,h,l,c), ...] oldest->newest, optionally restricted to the closed
        epoch-second window [start_ts, end_ts] — the date-scoped input for the no-code backtest lab.
        This research path has its own materially larger cap and therefore never silently inherits
        the 5,000-bar live-evaluator window. Same null-tolerant close fallback as ohlc()."""
        if not in_scope(symbol):
            return []
        clauses = ["symbol=?"]
        params: list = [symbol]
        if start_ts is not None:
            clauses.append("ts>=?"); params.append(int(start_ts))
        if end_ts is not None:
            clauses.append("ts<=?"); params.append(int(end_ts))
        params.append(max(1, min(int(limit), ANALYSIS_MAX_BARS)))
        rows = self._q(
            "SELECT o,h,l,c FROM (SELECT o,h,l,c,ts FROM bars WHERE "
            + " AND ".join(clauses) + " ORDER BY ts DESC LIMIT ?) ORDER BY ts ASC",
            tuple(params))
        return [((o if o is not None else c), (h if h is not None else c),
                 (l if l is not None else c), c) for (o, h, l, c) in rows]

    def ohlc_between_timestamped(self, symbol: str, start_ts=None, end_ts=None,
                                 limit: int = ANALYSIS_MAX_BARS):
        """Immutable optimizer snapshot rows ``(o,h,l,c,ts)`` oldest->newest.

        Research provenance hashes timestamps with prices; the ordinary engine reader intentionally
        stays four-column for compatibility.
        """
        if not in_scope(symbol):
            return []
        clauses = ["symbol=?"]
        params: list = [symbol]
        if start_ts is not None:
            clauses.append("ts>=?")
            params.append(int(start_ts))
        if end_ts is not None:
            clauses.append("ts<=?")
            params.append(int(end_ts))
        params.append(max(1, min(int(limit), ANALYSIS_MAX_BARS)))
        rows = self._q(
            "SELECT o,h,l,c,ts FROM (SELECT o,h,l,c,ts FROM bars WHERE "
            + " AND ".join(clauses) + " ORDER BY ts DESC LIMIT ?) ORDER BY ts ASC",
            tuple(params))
        return [((o if o is not None else c), (h if h is not None else c),
                 (l if l is not None else c), c, int(ts))
                for (o, h, l, c, ts) in rows]

    def latest_bar_ts(self, symbol: str) -> int | None:
        if not in_scope(symbol):
            return None
        rows = self._q("SELECT MAX(ts) FROM bars WHERE symbol=?", (symbol,))
        return int(rows[0][0]) if rows and rows[0][0] is not None else None

    def bar_bounds(self, symbol: str) -> dict:
        """First/last captured epoch-second timestamp + bar count for a symbol — so the lab can show
        the buyer the real span of their OWN data and default the date range to it. Empty -> zeros."""
        if not in_scope(symbol):
            return {"symbol": symbol, "count": 0, "firstTs": None, "lastTs": None}
        r = self._q("SELECT COUNT(*), MIN(ts), MAX(ts) FROM bars WHERE symbol=?", (symbol,))
        n, lo, hi = (r[0] if r else (0, None, None))
        return {"symbol": symbol, "count": int(n or 0), "firstTs": lo, "lastTs": hi}

    def config(self) -> dict:
        """The current buyer config (defaults + persisted overrides, range-clamped)."""
        return load_config(self.config_path)

    def set_config(self, patch: dict) -> dict:
        """Merge a partial config patch over the current config, persist, and invalidate the edge
        cache (so retuned parameters take effect immediately). Returns the clamped truth."""
        merged = self.config()
        merged.update({k: patch[k] for k in patch if k in CONFIG_DEFAULTS})
        written = save_config(merged, self.config_path)
        self._edge_cache.clear()
        return written

    # ---- inert legacy execution audit state (retained only to read/migrate old local databases) ----
    _EXEC_DEFAULTS = {"armed": "0", "mode": "paper", "kill": "0", "firm": "",
                      "firmAck": "0", "broker": "", "liveAuthExpiry": "0",
                      "confirmEachOrder": "1"}  # "1" = require per-order confirm (safe default)

    def _exec_kv(self, k: str) -> str:
        rows = self._q("SELECT v FROM exec_kv WHERE k=?", (k,))
        return rows[0][0] if rows else self._EXEC_DEFAULTS.get(k, "")

    def set_exec_kv(self, k: str, v) -> None:
        """Write one legacy audit-state key. No shipping API or capture path calls this."""
        self._exec("INSERT INTO exec_kv(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",
                   [(k, str(v))], many=True)

    def exec_flags(self) -> dict:
        """Read inert legacy flags for migration/audit tooling. The b27 signals-only runtime forces
        these fail-closed and has no API, UI, broker adapter, or capture path that can consume them."""
        cfg = self.config()
        return {"armed": self._exec_kv("armed") == "1",
                "mode": self._exec_kv("mode") or "paper",
                "kill": self._exec_kv("kill") == "1",
                "firm": (self._exec_kv("firm") or cfg.get("propFirm", "")),
                "firmAck": self._exec_kv("firmAck") == "1",
                "broker": self._exec_kv("broker"),
                # From exec_kv, NOT config: /api/config can never flip this on/off. Default "1".
                "confirmEachOrder": self._exec_kv("confirmEachOrder") != "0"}

    def exec_live_authorized(self) -> bool:
        """Live needs a FRESH human OS-auth capability (set by the Swift app after Touch ID/password)
        — a short-lived expiry the backend verifies, NOT the shared signin token. Expired => not
        authorized. (Creds-present/account-resolved are also required; the live adapter re-checks.)"""
        try:
            return time.time() < float(self._exec_kv("liveAuthExpiry") or 0)
        except (TypeError, ValueError):
            return False

    def exec_demo_validated(self) -> bool:
        """Whether the buyer has validated the full live order path on a broker DEMO/eval account.
        Default False — a funded/real account can't place an order until this is set (the order code
        is built to the documented API but unproven against the live endpoint until demo-confirmed)."""
        return self._exec_kv("demoValidated") == "1"

    def exec_order_confirmed(self, cid: str) -> bool:
        rows = self._q("SELECT confirmed FROM exec_orders WHERE client_order_id=?", (cid,))
        return bool(rows and rows[0][0])

    def exec_confirm_order(self, cid: str) -> None:
        self._exec("UPDATE exec_orders SET confirmed=1 WHERE client_order_id=?", [(cid,)], many=True)

    def _today0(self) -> int:
        return int(time.time()) - (int(time.time()) % 86400)

    def exec_day_realized_loss(self) -> float:
        rows = self._q("SELECT realized_pnl FROM exec_orders WHERE realized_pnl IS NOT NULL AND ts>=?",
                       (self._today0(),))
        return -sum(min(0.0, r[0]) for r in rows)   # positive magnitude of today's realized losses

    def exec_open_contracts(self, symbol: str) -> int:
        root = futures_root_any(symbol)
        rows = self._q("SELECT symbol,size FROM exec_orders WHERE status IN ('paper_working','pending','working')")
        return sum(int(s or 0) for (sym, s) in rows if futures_root_any(sym) == root)

    def exec_equity(self) -> float:
        # accountSize + cumulative realized PnL (paper has none until exits simulated in a later slice)
        rows = self._q("SELECT realized_pnl FROM exec_orders WHERE realized_pnl IS NOT NULL")
        return float(self.config().get("accountSize", 0) or 0) + sum(r[0] for r in rows)

    def exec_equity_hwm(self) -> float:
        try:
            hwm = float(self._exec_kv("equityHwm") or 0)
        except (TypeError, ValueError):
            hwm = 0.0
        eq = self.exec_equity()
        if eq > hwm:
            self.set_exec_kv("equityHwm", eq); return eq
        return hwm

    def exec_trades_today(self) -> int:
        rows = self._q("SELECT count(*) FROM exec_orders WHERE route IN ('paper','live') AND ts>=?",
                       (self._today0(),))
        return int(rows[0][0]) if rows else 0

    def exec_has_open_position(self, engine: str, symbol: str, direction: str) -> bool:
        root = futures_root_any(symbol)
        rows = self._q("SELECT symbol,direction FROM exec_orders WHERE status IN ('paper_working','pending','working')")
        return any(futures_root_any(sym) == root and d == direction for (sym, d) in rows)

    def exec_already_fired(self, cid: str) -> bool:
        return bool(self._q("SELECT 1 FROM exec_orders WHERE client_order_id=?", (cid,)))

    def exec_record_decision(self, d: dict) -> None:
        status = "blocked" if d.get("route") == "blocked" else (
            "paper_working" if d.get("route") == "paper" else "pending")
        self._exec(
            "INSERT INTO exec_orders(client_order_id,engine,symbol,direction,size,route,reason,"
            "status,confirmed,is_automated,ts) VALUES(?,?,?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(client_order_id) DO UPDATE SET route=excluded.route,reason=excluded.reason,"
            "status=excluded.status,size=excluded.size",
            [(d.get("client_order_id"), d.get("engine"), d.get("symbol"), d.get("direction"),
              int(d.get("size", 0)), d.get("route"), d.get("reason"), status, 0,
              1 if d.get("is_automated", True) else 0, int(time.time()))], many=True)

    def exec_orders(self, limit: int = 100) -> dict:
        rows = self._q("SELECT client_order_id,engine,symbol,direction,size,route,reason,status,"
                       "realized_pnl,ts FROM exec_orders ORDER BY ts DESC LIMIT ?", (int(limit),))
        return {"orders": [{"clientOrderId": r[0], "engine": r[1], "symbol": r[2], "direction": r[3],
                            "size": r[4], "route": r[5], "reason": r[6], "status": r[7],
                            "realizedPnl": r[8], "ts": r[9]} for r in rows]}

    def edge_ok(self, engine: str, symbol: str, cfg: dict | None = None, bypass_cache: bool = False) -> dict:
        """The product's live edge gate, corrected across the whole engine×symbol family.

        A prior implementation called one prover in isolation. That let a per-test p<alpha signal
        surface even when the product's own screen correctly rejected it under BH-FDR. This method
        now consumes the same family-wide screen verdict used by the research UI. bypass_cache=True
        forces a fresh research grid for diagnostics; the capture path uses the normal bounded cache.
        """
        cfg = cfg or self.config()
        if not in_scope(symbol):
            return {"ok": False, "reason": f"'{symbol}' is not a recognized instrument"}
        key = (engine, symbol)
        cached = self._edge_cache.get(key)
        now = time.time()
        if cached and cached[0] > now and not bypass_cache:
            return cached[1]
        if engine not in PROVERS:
            v = {"ok": False, "reason": f"unknown engine '{engine}'"}
        else:
            try:
                # Lazy import avoids a module-import cycle: bltd_analytics imports this module, while
                # screen() itself only reads Store.ohlc and the prover registry.
                import bltd_analytics
                syms = list(self.symbols().get("backtestable", []))
                if symbol not in syms:
                    syms.append(symbol)
                engines = [e for e in cfg.get("engines", []) if e in PROVERS]
                if engine not in engines:
                    engines.append(engine)
                rows = bltd_analytics.screen(self, syms, engines, cfg)
                row = next((r for r in rows
                            if r.get("engine") == engine and r.get("symbol") == symbol), None)
                if row is None:
                    v = {"ok": False, "reason": "no family-wide edge verdict available"}
                else:
                    v = dict(row)
                    v["ok"] = bool(row.get("edge"))
            except Exception as exc:  # noqa: BLE001 — gate calculation failure must fail closed
                v = {"ok": False, "reason": f"family-wide edge gate unavailable ({type(exc).__name__})"}
        self._edge_cache[key] = (now + EDGE_TTL, v)
        return v
