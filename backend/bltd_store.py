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

# ---------------------------------------------------------------------------
# Default own-store location (the product owns this; NOT Michael's Utah Postgres).
# Override with BLTD_STORE for tests / a custom path. The legacy Utah Postgres DSN is reachable
# ONLY through the opt-in dev override in bltd_api.py — never the default, and never from here.
# ---------------------------------------------------------------------------
def default_store_path() -> str:
    base = os.path.expanduser("~/Library/Application Support/Black Label Trading")
    return os.environ.get("BLTD_STORE", os.path.join(base, "trading.sqlite3"))


def default_config_path() -> str:
    base = os.path.expanduser("~/Library/Application Support/Black Label Trading")
    return os.environ.get("BLTD_CONFIG", os.path.join(base, "config.json"))


# ---------------------------------------------------------------------------
# Buyer-tunable config (NOT hardcoded). Persisted as JSON the product owns; read by the capture
# daemon (engine geometry / which engines run / symbol filter / edge gate) and the store (edge
# gate floor). The Swift Settings surface writes it via the backend /api/config endpoint. Every
# value is range-clamped so a bad write can never crash or de-honest the gate.
# ---------------------------------------------------------------------------
CONFIG_DEFAULTS = {
    # The full engine roster (meanrev/breakout/research + the consensus-family engines). Every name
    # here is registered in PROVERS + ENGINE_TRADES and has a live-fire signal; the edge gate
    # decides per (engine,symbol) whether it may actually fire on the buyer's own bars.
    "engines": ["meanrev", "breakout", "research", "momentum", "structure", "regime",
                "channel", "context_a", "context_b"],   # which engines may fire
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
    "fdrQ": 0.10,              # Benjamini–Hochberg false-discovery rate for the screen grid (across
                              # all engine×symbol cells) so the candidate count isn't inflated by grid size
    "symbols": [],             # capture filter: EMPTY = accept every in_scope symbol. A non-empty
                               # list must name the feed's own codes; ["ES"] dropped 100% of
                               # prop-feed bars (MESU6/CM.ESU6 never string-match "ES").
    # risk / prop-firm rules. These are ENFORCED execution risk gates when execution is armed+live
    # (see bltd_exec.RiskGateChain); informational otherwise.
    "accountSize": 50000.0,
    "riskPerTradePct": 1.0,
    "maxDailyLossPct": 3.0,
    "maxTrades": 0,            # 0 = unlimited
    "propFirm": "",            # free-text label of the buyer's prop firm
    # execution risk params (also enforced by the exec engine). NOTE: arm/mode/kill are NOT here —
    # they live in a dedicated exec_kv table so a /api/config POST can never flip them on.
    "execMaxContracts": 0,     # 0 = no execution cap set (engine treats 0 as "no cap configured")
    "execMaxDrawdown": 0.0,    # $ trailing-drawdown guard vs the real-equity high-water mark
    # NOTE: per-order confirm is NOT here on purpose. It lived in config and a plain /api/config POST
    # could flip it off (2026-07-01 audit). It now lives in exec_kv ("confirmEachOrder", default "1")
    # and can only be disabled through /api/exec/confirmeachorder WITH a fresh OS-auth — same class of
    # gate as going live. The engine already never consults it for the live path (confirm is mandatory).
    # alert/signal delivery channels (the daemon writes a fire; channels mirror it out)
    "alertSound": True,
    "alertWebhook": "",        # POST each fire as JSON to this URL (e.g. Discord/Slack)
}

_CONFIG_RANGES = {
    "lookback": (3, 200), "barSeconds": (1, 3600), "oosFrac": (0.1, 0.9),
    "minTrades": (1, 1000), "mrZ": (0.5, 6.0), "mrTgtFrac": (0.05, 1.0),
    "mrStopMult": (0.5, 50.0), "mrWinFloor": (0.0, 1.0), "bkTargetR": (0.25, 20.0),
    "fdrQ": (0.001, 1.0),
    "accountSize": (0.0, 1e9), "riskPerTradePct": (0.0, 100.0),
    "maxDailyLossPct": (0.0, 100.0), "maxTrades": (0, 100000),
    "execMaxContracts": (0, 1000), "execMaxDrawdown": (0.0, 1e9),
}
_KNOWN_ENGINES = ("meanrev", "breakout", "research", "momentum", "structure", "regime",
                  "channel", "context_a", "context_b")
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
    except (TypeError, ValueError):
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
    eng = [e for e in (out.get("engines") or []) if e in _KNOWN_ENGINES]
    out["engines"] = eng or list(CONFIG_DEFAULTS["engines"])
    out["edgeGate"] = bool(out.get("edgeGate", True))
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


def _mr_simulate_ohlc(ohlc, i, direction, entry, stop, target, max_hold):
    """ohlc: list of (o,h,l,c). Mirrors Engines.swift mrSimulate."""
    risk = abs(entry - stop)
    if risk <= 0:
        return None
    target_r = abs(target - entry) / risk
    end = len(ohlc) if max_hold <= 0 else min(len(ohlc), i + 1 + max_hold)
    j = i + 1
    while j < end:
        hi, lo = ohlc[j][1], ohlc[j][2]
        if direction == "long":
            if lo <= stop:
                return {"dir": direction, "entry": entry, "exit": stop, "held": j - i, "r": -1.0}
            if hi >= target:
                return {"dir": direction, "entry": entry, "exit": target, "held": j - i, "r": target_r}
        else:
            if hi >= stop:
                return {"dir": direction, "entry": entry, "exit": stop, "held": j - i, "r": -1.0}
            if lo <= target:
                return {"dir": direction, "entry": entry, "exit": target, "held": j - i, "r": target_r}
        j += 1
    k = end - 1
    last = ohlc[k][3]
    held = k - i
    r = (last - entry) / risk if direction == "long" else (entry - last) / risk
    return {"dir": direction, "entry": entry, "exit": last, "held": held, "r": round(r, 4)}


def _mr_trades(ohlc, lookback=LOOKBACK, cfg=None):
    cfg = cfg or CONFIG_DEFAULTS
    z_enter = cfg.get("mrZ", MR_Z)
    tgt_frac = cfg.get("mrTgtFrac", MR_TGT_FRAC)
    stop_mult = cfg.get("mrStopMult", MR_STOP_MULT)
    closes = [b[3] for b in ohlc]
    out = []
    i = lookback
    n = len(ohlc)
    while i < n:
        prior = closes[i - lookback:i]
        mean = sum(prior) / lookback
        varc = sum((x - mean) ** 2 for x in prior) / lookback
        if varc <= 0:
            i += 1
            continue
        sd = math.sqrt(varc)
        entry = closes[i]
        z = (entry - mean) / sd
        if z <= -z_enter:
            direction, target, stop = "long", entry + tgt_frac * (mean - entry), entry - stop_mult * sd
        elif z >= z_enter:
            direction, target, stop = "short", entry - tgt_frac * (entry - mean), entry + stop_mult * sd
        else:
            i += 1
            continue
        t = _mr_simulate_ohlc(ohlc, i, direction, entry, stop, target, MR_MAX_HOLD)
        if not t:
            i += 1
            continue
        out.append(t)
        i += max(1, t["held"])
    return out


# Significance bar for the OOS edge proof. expectancy>0 alone is NOT proof: under a 2:1 target a
# driftless random walk clears expectancy>0 >50% of the time, so the directional engines would
# "prove" an edge on pure noise. An edge is proven only if the OOS win-rate SIGNIFICANTLY beats the
# R-geometry breakeven (one-sided binomial, p<0.05) on a sufficient sample. Verified: this collapses
# the random-walk false-positive rate from ~55-63% to the ~5% floor; honest engines are unaffected.
SIG_MIN_N = 30          # minimum OOS trades before significance can be assessed
SIG_ALPHA = 0.05        # one-sided binomial significance level


def _binom_sf(k, n, p):
    """P(X >= k) for X ~ Binomial(n, p), exact via stdlib. n is the (small) OOS trade count."""
    if k <= 0:
        return 1.0
    return sum(math.comb(n, i) * (p ** i) * ((1.0 - p) ** (n - i)) for i in range(k, n + 1))


def _edge_pvalue(trades, wins, n, expectancy, min_trades, target_r=None):
    """One-sided binomial p-value that the OOS win-rate beats the R-geometry breakeven (1/(1+winR)).
    Returns 1.0 (no evidence) when the sample is too small / no wins / non-positive expectancy, so
    a thin or losing series can never look significant. This is the single edge statistic; both the
    per-test gate and the grid-wide FDR correction derive from it.

    winR is the INTENDED target R, NOT the realized max win — using max() would data-snoop the
    breakeven downward (one lucky runner lowers the bar and inflates significance). When the caller
    knows its fixed target we cap at it; for a variable-R engine we use the robust median winning R.
    For the current fixed-2:1 engines max==median==target so this changes nothing today; it is the
    guard that keeps the gate honest if an uncapped-R (trailing/runner) engine ever ships."""
    if n < max(min_trades, SIG_MIN_N) or wins <= 0 or expectancy <= 0:
        return 1.0
    win_rs = [t["r"] for t in trades if t["r"] > 0]
    if not win_rs:
        return 1.0
    if target_r is not None and target_r > 0:
        win_r = min(max(win_rs), float(target_r))   # cap at the intended reward:risk
    else:
        win_r = sorted(win_rs)[len(win_rs) // 2]    # robust median for variable-R geometry
    breakeven = 1.0 / (1.0 + win_r)                  # win-rate needed just to break even at this R
    return _binom_sf(wins, n, breakeven)


def _edge_proven(trades, wins, n, expectancy, min_trades, target_r=None):
    """Per-test gate: the edge p-value clears SIG_ALPHA. (The screen grid additionally applies a
    Benjamini–Hochberg FDR correction across all (engine,symbol) cells — see bltd_analytics.screen.)"""
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
    edge = s["trades"] >= min_trades and s["winRate"] >= win_floor and s["netPts"] > 0
    reason = (f"OOS candidate: win {s['winRate']*100:.1f}% / net {s['netPts']:+.2f} pts on {s['trades']} trades; live verification required"
              if edge else
              f"not proven: OOS win {s['winRate']*100:.1f}% / net {s['netPts']:+.2f} pts on {s['trades']} trades "
              f"(need win>={win_floor*100:.0f}%, net>0, >={min_trades} trades)")
    return {"ok": edge, "reason": reason, **s}


def _bk_simulate(closes, i, direction, entry, stop, target_r):
    risk = abs(entry - stop)
    if risk <= 0:
        return None
    target = entry + target_r * risk if direction == "long" else entry - target_r * risk
    j = i + 1
    while j < len(closes):
        px = closes[j]
        if direction == "long":
            if px <= stop:
                return {"dir": direction, "entry": entry, "exit": stop, "held": j - i, "r": -1.0}
            if px >= target:
                return {"dir": direction, "entry": entry, "exit": target, "held": j - i, "r": target_r}
        else:
            if px >= stop:
                return {"dir": direction, "entry": entry, "exit": stop, "held": j - i, "r": -1.0}
            if px <= target:
                return {"dir": direction, "entry": entry, "exit": target, "held": j - i, "r": target_r}
        j += 1
    last = closes[-1]
    r = (last - entry) / risk if direction == "long" else (entry - last) / risk
    return {"dir": direction, "entry": entry, "exit": last, "held": len(closes) - 1 - i, "r": round(r, 4)}


def _bk_trades(ohlc, lookback=LOOKBACK, cfg=None):
    """Breakout walk over a bar series: long on a close above the prior `lookback` high, short
    below the prior low; stop at the opposite extreme; fixed reward:risk target. Pure — this is
    the single canonical breakout generator the gate, screener and full-backtest all share."""
    cfg = cfg or CONFIG_DEFAULTS
    target_r = cfg.get("bkTargetR", BK_TARGET_R)
    closes = [b[3] for b in ohlc]
    trades = []
    i = lookback
    n = len(closes)
    while i < n:
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
        t = _bk_simulate(closes, i, direction, last, stop, target_r)
        if not t:
            i += 1
            continue
        trades.append(t)
        i += max(1, t["held"])
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
    yields 'long'/'short'/None on each bar; geometry is the shared ATR stop/2:1 target."""
    cfg = cfg or CONFIG_DEFAULTS
    closes = [b[3] for b in ohlc]
    trades = []
    i = lookback
    n = len(ohlc)
    while i < n:
        sub = ohlc[:i + 1]
        d = dir_fn(closes[:i + 1], sub, lookback, cfg)
        if not d:
            i += 1
            continue
        entry = closes[i]
        stop, target = _atr_stop_target(sub, entry, d, MO_ATR_MULT, MO_TARGET_R)
        t = _mr_simulate_ohlc(ohlc, i, d, entry, stop, target, MR_MAX_HOLD)
        if not t:
            i += 1
            continue
        trades.append(t)
        i += max(1, t["held"])
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


def prover_source_sha() -> str:
    """sha256 (16-hex) of THIS prover module's source — the exact edge-gate math a verdict was
    computed with. Reproducible by the buyer: `shasum -a 256 bltd_store.py`. So a re-run the buyer
    triggers on their own bars carries the fingerprint of the code that produced it, and any change
    to the gate math changes the fingerprint. Same computation gen_reference.py stamps onto the
    reference artifact, exposed here so the live re-run endpoint can stamp it identically."""
    import hashlib
    try:
        with open(__file__, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()[:16]
    except OSError:
        return "unknown"


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
    ts INTEGER NOT NULL
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
                # Idempotent: relabel any fires captured under the old engine codenames.
                for old, new in _RENAMED_ENGINES.items():
                    cx.execute("UPDATE fires SET engine=? WHERE engine=?", (new, old))
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
                    rationale=None, synthetic=False) -> int:
        # Storage gate only — WHETHER to fire is decided upstream by the edge-gate (proven OOS edge
        # per engine,symbol). in_scope just keeps junk symbols out of the journal.
        if symbol is not None and not in_scope(symbol):
            return 0
        return self._exec(
            "INSERT INTO fires(engine,direction,entry,symbol,stop,target,rationale,synthetic,ts) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (engine, direction, float(entry), symbol, stop, target, rationale,
             1 if synthetic else 0, int(time.time())))

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
    def ohlc(self, symbol: str, limit: int = 5000):
        """A symbol's bars as [(o,h,l,c), ...] oldest->newest — the engine/gate input. Public so
        the capture daemon can evaluate the live signal off the same series the gate proves."""
        if not in_scope(symbol):
            return []
        rows = self._q("SELECT o,h,l,c FROM bars WHERE symbol=? ORDER BY ts LIMIT ?",
                       (symbol, limit))
        # tolerate null o/h/l (close-only history) by falling back to close
        return [((o if o is not None else c), (h if h is not None else c),
                 (l if l is not None else c), c) for (o, h, l, c) in rows]

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

    # ---- execution control state (separate from config; /api/config can NEVER touch these) -----
    _EXEC_DEFAULTS = {"armed": "0", "mode": "paper", "kill": "0", "firm": "",
                      "firmAck": "0", "broker": "", "liveAuthExpiry": "0",
                      "confirmEachOrder": "1"}  # "1" = require per-order confirm (safe default)

    def _exec_kv(self, k: str) -> str:
        rows = self._q("SELECT v FROM exec_kv WHERE k=?", (k,))
        return rows[0][0] if rows else self._EXEC_DEFAULTS.get(k, "")

    def set_exec_kv(self, k: str, v) -> None:
        """Set ONE exec-state key. Only the dedicated /api/exec/* routes call this — never config."""
        self._exec("INSERT INTO exec_kv(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v",
                   [(k, str(v))], many=True)

    def exec_flags(self) -> dict:
        """Current execution control flags (the engine reads this each fire). Kill also honors the
        out-of-band sentinel file (checked in bltd_exec). confirmEachOrder is exec_kv-only (a
        /api/config POST can never flip it; disabling needs /api/exec/confirmeachorder + OS-auth)."""
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
        """The product's OWN edge gate: backtest THIS engine on THIS symbol's bars (OOS split)
        and return {ok, reason, ...}. Runs entirely in-process. TTL-cached. Honest empty
        verdict when there aren't enough bars. Uses the buyer's tuned config (lookback / OOS /
        win-floor / geometry) — nothing hardcoded. bypass_cache=True forces a FRESH verdict (the
        execution engine uses this so a stale 120s-cached 'ok' can never authorize a live order)."""
        cfg = cfg or self.config()
        if not in_scope(symbol):
            return {"ok": False, "reason": f"'{symbol}' is not a recognized instrument"}
        key = (engine, symbol)
        cached = self._edge_cache.get(key)
        now = time.time()
        if cached and cached[0] > now and not bypass_cache:
            return cached[1]
        prover = PROVERS.get(engine)
        lookback = cfg.get("lookback", LOOKBACK)
        if not prover:
            v = {"ok": False, "reason": f"unknown engine '{engine}'"}
        else:
            ohlc = self.ohlc(symbol)
            if len(ohlc) < lookback + 2:
                v = {"ok": False, "reason": f"insufficient bars ({len(ohlc)}) — gate arms when "
                     f"the feed has persisted >= {lookback + 2}"}
            else:
                v = prover(ohlc, cfg)
        self._edge_cache[key] = (now + EDGE_TTL, v)
        return v
