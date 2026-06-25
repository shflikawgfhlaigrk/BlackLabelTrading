"""Black Label Trading — the product's OWN local store + WC capture helpers + edge gate.

SELF-CONTAINED. This module is the product's whole data + analysis spine. It has ZERO
dependency on Michael's Utah/Postgres: the store is a local SQLite database the product owns
(default ~/Library/Application Support/Black Label Trading/trading.sqlite3), the engines run
in-process here in pure stdlib Python, and the WC capture (bltd_capture.py) writes the BUYER's
own bars/ticks/fires into this store. Nothing is baked in — the database starts EMPTY and is
filled only by the buyer's own WealthCharts feed at runtime.

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
    "symbols": ["ES"],         # product scope: ES only; capture/screen ignore all non-ES symbols
    # risk / prop-firm rules (signals-only — informational, shapes alert sizing, never executes)
    "accountSize": 50000.0,
    "riskPerTradePct": 1.0,
    "maxDailyLossPct": 3.0,
    "maxTrades": 0,            # 0 = unlimited
    "propFirm": "",            # free-text label of the buyer's prop firm
    # alert/signal delivery channels (the daemon writes a fire; channels mirror it out)
    "alertSound": True,
    "alertWebhook": "",        # POST each fire as JSON to this URL (e.g. Discord/Slack)
}

_CONFIG_RANGES = {
    "lookback": (3, 200), "barSeconds": (1, 3600), "oosFrac": (0.1, 0.9),
    "minTrades": (1, 1000), "mrZ": (0.5, 6.0), "mrTgtFrac": (0.05, 1.0),
    "mrStopMult": (0.5, 50.0), "mrWinFloor": (0.0, 1.0), "bkTargetR": (0.25, 20.0),
    "accountSize": (0.0, 1e9), "riskPerTradePct": (0.0, 100.0),
    "maxDailyLossPct": (0.0, 100.0), "maxTrades": (0, 100000),
}
_KNOWN_ENGINES = ("meanrev", "breakout", "research", "momentum", "structure", "regime",
                  "channel", "context_a", "context_b")
ES_ROOT = "ES"
_ES_MONTH_CODES = "FGHJKMNQUVXZ"
_ES_CONTRACT_RE = re.compile(rf"^ES[{_ES_MONTH_CODES}]\d{{1,2}}$")


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
    s = normalize_symbol(symbol)
    return s == ES_ROOT or bool(_ES_CONTRACT_RE.match(s))


def es_symbols(symbols) -> list[str]:
    out = []
    seen = set()
    for sym in symbols or []:
        raw = str(sym or "").strip()
        if raw and is_es_symbol(raw) and raw not in seen:
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
    return {"symbol": symbol, "close": close, "open": _f(candle.get("co")),
            "high": _f(candle.get("cM")), "low": _f(candle.get("cm")), "epoch": epoch}


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


def _summarize(trades, min_trades=MIN_TRADES):
    n = len(trades)
    if n == 0:
        return {"trades": 0, "wins": 0, "winRate": 0.0, "expectancyR": 0.0, "netPts": 0.0,
                "edgeProven": False, "reason": "no trades triggered on this series"}
    rs = [t["r"] for t in trades]
    wins = sum(1 for r in rs if r > 0)
    total_r = sum(rs)
    expectancy = total_r / n
    net_pts = sum((t["exit"] - t["entry"]) if t["dir"] == "long" else (t["entry"] - t["exit"]) for t in trades)
    return {"trades": n, "wins": wins, "winRate": round(wins / n, 4),
            "expectancyR": round(expectancy, 4), "netPts": round(net_pts, 4),
            "edgeProven": n >= min_trades and expectancy > 0, "reason": ""}


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
    s = _summarize(_bk_trades(ohlc[split:], lookback, cfg), min_trades)
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
    s = _summarize(_consensus_engine_trades(ohlc[split:], lookback, cfg, dir_fn), min_trades)
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


# ===========================================================================
# The own SQLite store.
# ===========================================================================
SCHEMA = """
CREATE TABLE IF NOT EXISTS bars (
    symbol TEXT NOT NULL,
    ts INTEGER NOT NULL,          -- bar close epoch (seconds)
    o REAL, h REAL, l REAL, c REAL NOT NULL,
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
        self.config_path = config_path or default_config_path()
        self._lock = threading.Lock()
        self._edge_cache = {}  # (engine,symbol) -> (expiry, verdict)
        self._ok = False
        try:
            d = os.path.dirname(path)
            if d:
                os.makedirs(d, exist_ok=True)
            with self._connect() as cx:
                cx.executescript(SCHEMA)
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
        return {"online": self.online(), "feedLive": any(is_es_symbol(s) for (s,) in live_syms),
                "signalsToday": sum(1 for (s,) in fires_today if is_es_symbol(s))}

    # ---- symbols -------------------------------------------------------
    def symbols(self) -> dict:
        bt = es_symbols([r[0] for r in self._q(
            "SELECT symbol FROM bars GROUP BY symbol HAVING count(*)>=40 ORDER BY symbol")])
        live = es_symbols([r[0] for r in self._q(
            "SELECT DISTINCT symbol FROM bars WHERE ts_recorded>? ORDER BY symbol",
            (int(time.time()) - LIVE_BAR_WINDOW,))])
        ticks = es_symbols([r[0] for r in self._q(
            "SELECT symbol FROM wc_live WHERE recorded>? ORDER BY symbol",
            (int(time.time()) - LIVE_TICK_WINDOW,))])
        busiest_rows = self._q("SELECT symbol FROM bars GROUP BY symbol ORDER BY count(*) DESC")
        busiest = next((r[0] for r in busiest_rows if is_es_symbol(r[0])), None)
        return {"backtestable": bt, "live": live, "liveTicks": ticks,
                "busiest": busiest}

    # ---- bars ----------------------------------------------------------
    def bars(self, symbol: str, limit: int, newest: bool) -> dict:
        if not symbol or not is_es_symbol(symbol):
            return {"symbol": symbol, "bars": []}
        if newest:
            rows = self._q(
                "SELECT o,h,l,c,ts FROM (SELECT o,h,l,c,ts FROM bars WHERE symbol=? "
                "ORDER BY ts DESC LIMIT ?) ORDER BY ts ASC", (symbol, limit))
        else:
            rows = self._q("SELECT o,h,l,c,ts FROM bars WHERE symbol=? ORDER BY ts LIMIT ?",
                           (symbol, limit))
        return {"symbol": symbol,
                "bars": [[r[0], r[1], r[2], r[3], float(r[4])] for r in rows]}

    def record_bars(self, symbol: str, rows) -> int:
        """rows: [(ts_epoch, o, h, l, c), ...]. Upsert by (symbol, ts) so overlapping capture
        windows never double-count. Returns count attempted."""
        if not is_es_symbol(symbol):
            return 0
        now = int(time.time())
        seq = [(symbol, int(ts), o, h, l, c, now) for (ts, o, h, l, c) in rows]
        if not seq:
            return 0
        self._exec(
            "INSERT INTO bars(symbol,ts,o,h,l,c,ts_recorded) VALUES(?,?,?,?,?,?,?) "
            "ON CONFLICT(symbol,ts) DO UPDATE SET o=excluded.o,h=excluded.h,l=excluded.l,"
            "c=excluded.c,ts_recorded=excluded.ts_recorded", seq, many=True)
        return len(seq)

    # ---- live tick -----------------------------------------------------
    def live_price(self, symbol: str) -> dict:
        if not symbol or not is_es_symbol(symbol):
            return {"gated": True}
        rows = self._q("SELECT price,recorded FROM wc_live WHERE symbol=?", (symbol,))
        if not rows:
            return {"symbol": symbol, "gated": True}
        return {"symbol": symbol, "price": rows[0][0], "ts": float(rows[0][1])}

    def record_tick(self, symbol: str, price: float, epoch: int) -> None:
        if not is_es_symbol(symbol):
            return
        self._exec("INSERT INTO wc_live(symbol,price,recorded) VALUES(?,?,?) "
                   "ON CONFLICT(symbol) DO UPDATE SET price=excluded.price,"
                   "recorded=excluded.recorded", (symbol, float(price), int(epoch)))

    # ---- fires ---------------------------------------------------------
    def record_fire(self, engine, direction, entry, symbol=None, stop=None, target=None,
                    rationale=None, synthetic=False) -> int:
        if symbol is not None and not is_es_symbol(symbol):
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
        row = next((r for r in rows if is_es_symbol(r[4])), None)
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
        if symbol and not is_es_symbol(symbol):
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
        return {"fires": [self._fire_dict(r) for r in rows if is_es_symbol(r[4])][:int(limit)]}

    def journal_stats(self, symbol: str | None = None, engine: str | None = None) -> dict:
        """Performance analytics over the journal of *graded* fires (hypothetical, signals-only).
        Counts only fires the daemon has marked target/stop with a pnl — never invents an outcome
        for an open signal."""
        if symbol and not is_es_symbol(symbol):
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
        rows = [r for r in rows if is_es_symbol(r[3])]
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
        if not is_es_symbol(symbol):
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

    def edge_ok(self, engine: str, symbol: str, cfg: dict | None = None) -> dict:
        """The product's OWN edge gate: backtest THIS engine on THIS symbol's bars (OOS split)
        and return {ok, reason, ...}. Runs entirely in-process. TTL-cached. Honest empty
        verdict when there aren't enough bars. Uses the buyer's tuned config (lookback / OOS /
        win-floor / geometry) — nothing hardcoded."""
        cfg = cfg or self.config()
        if not is_es_symbol(symbol):
            return {"ok": False, "reason": f"unsupported symbol '{symbol}' — Black Label Trading engines are ES-only"}
        key = (engine, symbol)
        cached = self._edge_cache.get(key)
        now = time.time()
        if cached and cached[0] > now:
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
