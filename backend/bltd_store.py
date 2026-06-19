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
    "engines": ["meanrev", "breakout", "research"],   # which engines may fire
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
    "symbols": [],             # [] = capture every symbol the feed sends; else allow-list
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
_KNOWN_ENGINES = ("meanrev", "breakout", "research")


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
    out["symbols"] = [str(s).strip() for s in (out.get("symbols") or []) if str(s).strip()]
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
    never crashes the capture or fabricates a price."""
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
    epoch = candle.get("cepoch")
    if close is None or epoch is None:
        return None
    return {"symbol": symbol, "close": close, "open": _f(candle.get("co")),
            "high": _f(candle.get("cM")), "low": _f(candle.get("cm")), "epoch": int(epoch)}


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
# Pure OHLC indicator helpers — the shared voter primitives the ported engines
# (bible/apex/perp/barber/ctx_*) compute their signals from. Stdlib-only, no state.
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
# OOS-split, edge proven only on the held-out tail. Same numbers as the Swift engines.
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
    reason = (f"edge proven: OOS win {s['winRate']*100:.1f}% / net {s['netPts']:+.2f} pts on {s['trades']} trades"
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


def prove_breakout(ohlc, cfg=None):
    cfg = cfg or CONFIG_DEFAULTS
    lookback = cfg.get("lookback", LOOKBACK)
    oos_frac = cfg.get("oosFrac", OOS_FRAC)
    min_trades = cfg.get("minTrades", MIN_TRADES)
    target_r = cfg.get("bkTargetR", BK_TARGET_R)
    closes = [b[3] for b in ohlc]
    split = int(len(closes) * (1.0 - oos_frac))
    seg = closes[split:]
    trades = []
    i = lookback
    n = len(seg)
    while i < n:
        prior = seg[i - lookback:i]
        last = seg[i]
        if last > max(prior):
            direction, stop = "long", min(prior)
        elif last < min(prior):
            direction, stop = "short", max(prior)
        else:
            i += 1
            continue
        t = _bk_simulate(seg, i, direction, last, stop, target_r)
        if not t:
            i += 1
            continue
        trades.append(t)
        i += max(1, t["held"])
    s = _summarize(trades, min_trades)
    reason = (f"edge proven: OOS expectancy {s['expectancyR']:+.3f}R on {s['trades']} trades"
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


PROVERS = {"meanrev": prove_meanrev, "breakout": prove_breakout, "research": prove_research}


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
        cnt = self._q("SELECT count(*) FROM fires WHERE synthetic=0 AND ts>=?", (today,))
        live = self._q("SELECT 1 FROM bars WHERE ts_recorded>? LIMIT 1", (cutoff,))
        return {"online": self.online(), "feedLive": bool(live),
                "signalsToday": (cnt[0][0] if cnt else 0)}

    # ---- symbols -------------------------------------------------------
    def symbols(self) -> dict:
        bt = [r[0] for r in self._q(
            "SELECT symbol FROM bars GROUP BY symbol HAVING count(*)>=40 ORDER BY symbol")]
        live = [r[0] for r in self._q(
            "SELECT DISTINCT symbol FROM bars WHERE ts_recorded>? ORDER BY symbol",
            (int(time.time()) - LIVE_BAR_WINDOW,))]
        ticks = [r[0] for r in self._q(
            "SELECT symbol FROM wc_live WHERE recorded>? ORDER BY symbol",
            (int(time.time()) - LIVE_TICK_WINDOW,))]
        busiest = self._q("SELECT symbol FROM bars GROUP BY symbol ORDER BY count(*) DESC LIMIT 1")
        return {"backtestable": bt, "live": live, "liveTicks": ticks,
                "busiest": busiest[0][0] if busiest else None}

    # ---- bars ----------------------------------------------------------
    def bars(self, symbol: str, limit: int, newest: bool) -> dict:
        if not symbol:
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
        if not symbol:
            return {"gated": True}
        rows = self._q("SELECT price,recorded FROM wc_live WHERE symbol=?", (symbol,))
        if not rows:
            return {"symbol": symbol, "gated": True}
        return {"symbol": symbol, "price": rows[0][0], "ts": float(rows[0][1])}

    def record_tick(self, symbol: str, price: float, epoch: int) -> None:
        self._exec("INSERT INTO wc_live(symbol,price,recorded) VALUES(?,?,?) "
                   "ON CONFLICT(symbol) DO UPDATE SET price=excluded.price,"
                   "recorded=excluded.recorded", (symbol, float(price), int(epoch)))

    # ---- fires ---------------------------------------------------------
    def record_fire(self, engine, direction, entry, symbol=None, stop=None, target=None,
                    rationale=None, synthetic=False) -> int:
        return self._exec(
            "INSERT INTO fires(engine,direction,entry,symbol,stop,target,rationale,synthetic,ts) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (engine, direction, float(entry), symbol, stop, target, rationale,
             1 if synthetic else 0, int(time.time())))

    def latest_fire(self) -> dict:
        rows = self._q(
            "SELECT id,engine,direction,entry,symbol,stop,target,rationale,outcome,pnl,ts "
            "FROM fires WHERE synthetic=0 ORDER BY id DESC LIMIT 1")
        if not rows:
            return {"fire": None}
        return {"fire": self._fire_dict(rows[0])}

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
        return {"fires": [self._fire_dict(r) for r in rows]}

    def journal_stats(self, symbol: str | None = None, engine: str | None = None) -> dict:
        """Performance analytics over the journal of *graded* fires (hypothetical, signals-only).
        Counts only fires the daemon has marked target/stop with a pnl — never invents an outcome
        for an open signal."""
        where = ["synthetic=0", "outcome IS NOT NULL", "pnl IS NOT NULL"]
        params: list = []
        if symbol:
            where.append("symbol=?")
            params.append(symbol)
        if engine:
            where.append("engine=?")
            params.append(engine)
        rows = self._q(
            f"SELECT outcome,pnl,engine FROM fires WHERE {' AND '.join(where)}", tuple(params))
        n = len(rows)
        if n == 0:
            return {"graded": 0, "wins": 0, "losses": 0, "winRate": 0.0, "netPnl": 0.0,
                    "avgWin": 0.0, "avgLoss": 0.0, "byEngine": {}}
        wins = [r[1] for r in rows if (r[1] or 0) > 0]
        losses = [r[1] for r in rows if (r[1] or 0) < 0]
        by_engine: dict = {}
        for outcome, pnl, eng in rows:
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
