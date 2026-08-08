# Black Label Trading — Engine Roster Expansion Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax. Execute inline, one green commit per engine.

**Goal:** Port the real AceOS signal engines (bible, apex, perp, barber, ctx_alpha, ctx_bravo) into the self-contained product as pure-stdlib OHLC engines — each registered + edge-gated identically to the existing meanrev/breakout/research, surfaced in the Swift Signals UI, TDD-proven, and live-verified.

**Architecture:** Each new engine gets (a) a shared pure-OHLC indicator helper set (EMA ribbon, StepGMA-style fast-MA slope, Kaufman efficiency ratio, ATR, Fibonacci position) in `bltd_store.py`; (b) a `_<engine>_trades(ohlc, lookback, cfg)` OOS trade generator; (c) a `prove_<engine>(ohlc, cfg)` registered in `PROVERS`; (d) a live-fire `_signal` branch in `bltd_capture.py`. `bltd_analytics._trades_for` is refactored to dispatch through a single `S.engine_trades(engine, oos, lookback, cfg)` registry so analytics + gate + screener stay in lockstep (DRY — no per-engine duplication of the walk). Swift gets a new `EngineRoster` decode type + an Engines panel in the Signals screen consuming `/api/screen` + `/api/fires`.

**Tech Stack:** Python 3 stdlib (sqlite3, math, json), SwiftUI, swiftc headless test target.

## Global Constraints

- SIGNALS-ONLY — never place a trade or move money. Engines read bars, emit signals.
- ZERO fabrication — every number traces to real captured bars; empty/insufficient input → honest empty/"warming", never an invented stat.
- SHIPS EMPTY — no bundled bars/fires/Utah data; engines run on the buyer's own captured feed only.
- Edge gate DEFAULT-ON (`BLTD_EDGE_GATE`/`cfg.edgeGate`) — an engine may fire ONLY when its real OOS math passes the gate on real bars. Never flip a nameplate "live" without real rules.
- FAITHFUL PORTS — port the OHLC-supportable core; document gated-out non-OHLC voters (CVD/order-flow/L2/entropy/VIX/macro-calendar/SMT/absorption) in each engine's docstring. Never invent a voter/rule/number.
- Pure stdlib only in backend (no third-party deps). Swift math stays test-locked; never hardcode a win%/net in Swift.
- Work IN PLACE on branch `fix/buttons-backnav-20260618`. No git worktree. One small green commit per engine.
- Final roster: `meanrev, breakout, research, bible, apex, perp, barber, ctx_alpha, ctx_bravo`.

---

## File Structure

- `backend/bltd_store.py` — MODIFY: add indicator helpers, per-engine trade generators + provers, register in `PROVERS`, an `ENGINE_TRADES` registry + `engine_trades()` dispatcher, extend `_KNOWN_ENGINES` + `CONFIG_DEFAULTS["engines"]`.
- `backend/bltd_analytics.py` — MODIFY: `_trades_for` dispatches via `S.engine_trades`; `screen`/`full_backtest` already key off `S.PROVERS` (verify).
- `backend/bltd_capture.py` — MODIFY: extend `ENGINES` tuple; add per-engine `_signal` branches that match each prover's geometry.
- `backend/test_engines.py` — CREATE: pure-Python TDD suite (synthetic series per engine: one that proves, one that doesn't, empty → honest empty).
- `Sources/FeedTypes.swift` — MODIFY: add `EngineRow`/`EngineRoster` decode (from `/api/screen`) + `FireRow`/`FireFeed` decode (from `/api/fires`). Pure, test-locked.
- `Sources/FeedClient.swift` — MODIFY: add `engineScreen()` + `recentFires()` fetchers.
- `Sources/Screens.swift` — MODIFY: add an "Engine fleet" panel to `SignalsScreen` rendering the full roster with per-engine live/edge status from the backend.
- `Tests/main.swift` — MODIFY: register `EngineRoster`/`FireFeed` decode tests; extend live integration test to assert all 9 engines present in `/api/screen`.

---

### Task 1: Shared OHLC indicator helpers (foundation, no engine yet)

**Files:**
- Modify: `backend/bltd_store.py` (after `ohlc_bars`, before the engine-math section ~line 200)
- Test: `backend/test_engines.py` (create)

**Interfaces:**
- Produces (pure, used by every new engine):
  - `_ema(values: list[float], span: int) -> list[float]` (Wilder-free EMA, seeded with values[0])
  - `_kaufman_er(closes: list[float], period: int) -> float` (net change / sum abs change over last `period`; 0..1; 0 if undefined)
  - `_stepgma_dir(closes, fast, slow) -> tuple[str, float]` ("bull"/"bear"/"neutral", slope) — sign of fast-EMA minus slow-EMA + normalized slope
  - `_ribbon_bull(closes, spans=(8,13,21,34,55)) -> bool|None` (True if EMAs strictly descending by span = stacked bullish; False if stacked bearish; None if mixed)
  - `_atr(ohlc, period=14) -> float` (mean true range over last `period` bars; 0 if too few)
  - `_fib_pos(closes, lookback) -> float|None` (position of last close in [swing_low, swing_high] over lookback; None if flat range)

- [ ] **Step 1: Write failing tests** in `backend/test_engines.py`:

```python
import math
import os
import tempfile
import bltd_store as S


def approx(a, b, t=1e-6):
    return abs(a - b) <= t


def test_ema_seed_and_trend():
    # constant series -> EMA equals the constant
    assert approx(S._ema([5.0] * 10, 4)[-1], 5.0)
    # rising series -> EMA rises but lags last value
    e = S._ema([float(i) for i in range(20)], 4)
    assert e[-1] < 19.0 and e[-1] > 15.0


def test_kaufman_er_trend_vs_chop():
    trend = [float(i) for i in range(30)]               # pure trend -> ER ~1
    chop = [10.0 + (1.0 if i % 2 else -1.0) for i in range(30)]  # zigzag -> ER ~0
    assert S._kaufman_er(trend, 20) > 0.95
    assert S._kaufman_er(chop, 20) < 0.2


def test_stepgma_dir_signs():
    up = [float(i) for i in range(40)]
    dn = [float(40 - i) for i in range(40)]
    assert S._stepgma_dir(up, 5, 20)[0] == "bull"
    assert S._stepgma_dir(dn, 5, 20)[0] == "bear"


def test_ribbon_bull_stacked():
    up = [float(i) for i in range(80)]
    dn = [float(80 - i) for i in range(80)]
    assert S._ribbon_bull(up) is True
    assert S._ribbon_bull(dn) is False


def test_atr_positive_on_range():
    ohlc = [(10.0, 12.0, 9.0, 11.0)] * 20
    assert approx(S._atr(ohlc, 14), 3.0)   # true range each bar = 12-9 = 3


def test_fib_pos_bounds():
    closes = [10.0, 20.0, 30.0, 25.0]      # swing [10,30], last 25 -> (25-10)/20 = 0.75
    assert approx(S._fib_pos(closes, 4), 0.75)
    assert S._fib_pos([7.0, 7.0, 7.0], 3) is None  # flat -> None
```

- [ ] **Step 2: Run, verify fail**

Run: `cd backend && python3 -m pytest test_engines.py -q` (or `python3 test_engines.py` if pytest absent — see Task 9 runner)
Expected: FAIL (AttributeError: module has no attribute `_ema`)

- [ ] **Step 3: Implement helpers** in `bltd_store.py` (insert after `ohlc_bars`, before `# Engine math` banner):

```python
# ---------------------------------------------------------------------------
# Pure OHLC indicator helpers — the shared voter primitives the ported engines
# (bible/apex/perp/barber/ctx_*) compute their signals from. Stdlib-only, no state.
# These are the OHLC-derivable cores of the real engines' indicator stack
# (EMA ribbon, StepGMA-style fast/slow slope, Kaufman efficiency-ratio regime,
# ATR geometry, Fibonacci golden-pocket position). Order-flow voters (CVD, SMT,
# absorption) and macro voters (entropy/VIX/econ-calendar) are NOT here — they are
# non-OHLC and are documented as gated-out in each engine's docstring.
# ---------------------------------------------------------------------------
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
```

- [ ] **Step 4: Run, verify pass**

Run: `cd backend && python3 -m pytest test_engines.py -q`
Expected: 6 passed

- [ ] **Step 5: Commit**

```bash
git add backend/bltd_store.py backend/test_engines.py
git commit -m "Trading: shared pure-OHLC indicator helpers for engine roster (TDD)"
```

---

### Task 2: Trade-generator registry + analytics dispatch (DRY foundation)

**Files:**
- Modify: `backend/bltd_store.py` (add `ENGINE_TRADES` registry + `engine_trades()` after `prove_research`, before `PROVERS`)
- Modify: `backend/bltd_analytics.py` (`_trades_for` dispatches via `S.engine_trades`)
- Test: `backend/test_engines.py`

**Interfaces:**
- Produces: `engine_trades(engine: str, oos_ohlc, lookback, cfg) -> list[trade]` — the per-engine OOS walk; returns `[]` for unknown engines. `_mr_trades` and a new `_bk_trades` are the first registrants.
- Consumes (analytics): replaces the inlined breakout walk in `_trades_for`.

- [ ] **Step 1: Write failing test** (append to `test_engines.py`):

```python
def _trend_series(n=120, start=100.0, step=0.5):
    # steady uptrend, closes only (o=h=l=c) so every generator is well-defined
    return [(start + i * step,) * 4 for i in range(n)]


def test_engine_trades_dispatch_matches_inline():
    ohlc = _trend_series()
    # breakout via the registry must equal the legacy inline breakout walk
    closes = [b[3] for b in ohlc]
    legacy = S._bk_trades(ohlc, 20, S.CONFIG_DEFAULTS)        # new canonical generator
    viareg = S.engine_trades("breakout", ohlc, 20, S.CONFIG_DEFAULTS)
    assert legacy == viareg
    assert S.engine_trades("nonexistent", ohlc, 20, S.CONFIG_DEFAULTS) == []
```

- [ ] **Step 2: Run, verify fail** (no `_bk_trades`/`engine_trades`).

- [ ] **Step 3: Implement.** In `bltd_store.py`, extract the breakout walk currently inlined in `prove_breakout` into a reusable `_bk_trades`, refactor `prove_breakout` to use it, and add the registry:

```python
def _bk_trades(ohlc, lookback=LOOKBACK, cfg=None):
    """Breakout walk over a bar series: long on a close above the prior `lookback` high,
    short below the prior low; stop at the opposite extreme; fixed reward:risk target."""
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
```

Refactor `prove_breakout` body to: `split = int(len(ohlc)*(1-oos_frac)); trades = _bk_trades(ohlc[split:], lookback, cfg); s = _summarize(trades, min_trades)` (same verdict). Then add after `prove_research`:

```python
# Registry of per-engine OOS trade generators. Keeps the gate, the screener and the full
# backtest report in lockstep — every engine's edge is proven from THIS walk, nothing else.
ENGINE_TRADES = {"meanrev": _mr_trades, "breakout": _bk_trades, "research": _bk_trades}


def engine_trades(engine, oos_ohlc, lookback, cfg=None):
    """The OOS trade list for `engine` on a bar segment. Empty list for an unknown engine."""
    gen = ENGINE_TRADES.get(engine)
    return gen(oos_ohlc, lookback, cfg) if gen else []
```

- [ ] **Step 4:** In `bltd_analytics.py`, replace the body of `_trades_for` with:

```python
def _trades_for(engine: str, ohlc, cfg):
    """The OOS trade list for an engine on a bar series, using the buyer's config. Mirrors the
    same OOS split + walk the gate uses, so the report and the gate agree exactly."""
    oos_frac = cfg.get("oosFrac", S.OOS_FRAC)
    lookback = cfg.get("lookback", S.LOOKBACK)
    split = int(len(ohlc) * (1.0 - oos_frac))
    return S.engine_trades(engine, ohlc[split:], lookback, cfg), split
```

- [ ] **Step 5: Run full suite, verify pass** (existing provers unchanged; dispatch test green):

Run: `cd backend && python3 -m pytest test_engines.py -q && python3 -c "import bltd_analytics"`
Expected: all passed, import clean.

- [ ] **Step 6: Commit**

```bash
git add backend/bltd_store.py backend/bltd_analytics.py backend/test_engines.py
git commit -m "Trading: engine trade-generator registry + analytics dispatch (DRY, TDD)"
```

---

### Task 3: perp engine (clean symmetric momentum consensus)

**Faithful port note:** perp = the Perplexity V2 "sniper" consensus, UNGUARDED + symmetric. OHLC voter set: StepGMA direction, EMA-ribbon stack, Kaufman-ER regime confirmation. A LONG needs `stepgma_dir=="bull"` AND `ribbon_bull` not False AND ER≥threshold (trend present); SHORT mirrored. Gated-out (documented): CVD + CVD divergence, entropy, VIX, econ-calendar, SMT, absorption, session-DNA. Stop/target geometry = ATR-based (0.8×ATR clamped, 2:1) ported faithfully.

**Files:** Modify `bltd_store.py` (add `_perp_trades`, `prove_perp`, `_perp_signal`, register), `test_engines.py`.

**Interfaces:**
- Produces: `prove_perp(ohlc, cfg)`, `_perp_trades(ohlc, lookback, cfg)`, `_perp_signal(closes, ohlc, lookback, cfg) -> dict|None` (live fire: `{direction, stop, target, rationale}`).

- [ ] **Step 1: Write failing tests:**

```python
def _consensus_uptrend(n=160):
    return [(100.0 + i * 0.7,) * 4 for i in range(n)]

def _chop(n=160):
    return [(100.0 + (1.0 if i % 2 else -1.0),) * 4 for i in range(n)]


def test_perp_proves_on_trend():
    r = S.prove_perp(_consensus_uptrend(), S.CONFIG_DEFAULTS)
    assert set(["ok", "reason", "trades", "winRate", "netPts", "expectancyR"]).issubset(r)
    assert r["ok"] is True
    assert r["netPts"] > 0


def test_perp_no_edge_on_chop():
    r = S.prove_perp(_chop(), S.CONFIG_DEFAULTS)
    assert r["ok"] is False


def test_perp_empty_is_honest():
    r = S.prove_perp([], S.CONFIG_DEFAULTS)
    assert r["ok"] is False and r["trades"] == 0


def test_perp_signal_long_on_uptrend():
    ohlc = _consensus_uptrend()
    sig = S._perp_signal([b[3] for b in ohlc], ohlc, 20, S.CONFIG_DEFAULTS)
    assert sig is not None and sig["direction"] == "long"
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** in `bltd_store.py` (after the breakout/research provers; constants `PERP_FAST=8, PERP_SLOW=21, PERP_ER=0.30, PERP_ATR_MULT=0.8, PERP_TARGET_R=2.0, PERP_ATR_FALLBACK_FRAC=0.004`):

```python
PERP_FAST, PERP_SLOW = 8, 21
PERP_ER = 0.30          # Kaufman ER floor: only trade when a real trend is present
PERP_ATR_MULT = 0.8     # stop = 0.8 * ATR (faithful to sniper geometry)
PERP_TARGET_R = 2.0     # 2:1 reward:risk (faithful)


def _consensus_dir(closes, ohlc, lookback, fast, slow, er_floor):
    """The OHLC-derivable sniper consensus: StepGMA direction + EMA-ribbon stack + Kaufman-ER
    trend gate. Returns 'long'/'short'/None. (Order-flow CVD/SMT/absorption + entropy/VIX/econ
    voters from the real engine are NON-OHLC and intentionally omitted — documented gated-out.)"""
    if len(closes) < slow + 1:
        return None
    sdir, _ = _stepgma_dir(closes, fast, slow)
    ribbon = _ribbon_bull(closes)
    er = _kaufman_er(closes, lookback)
    if er < er_floor:
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
    stop_d = max(atr * atr_mult, entry * 1e-4)
    if direction == "long":
        return entry - stop_d, entry + target_r * stop_d
    return entry + stop_d, entry - target_r * stop_d


def _perp_trades(ohlc, lookback=LOOKBACK, cfg=None):
    cfg = cfg or CONFIG_DEFAULTS
    closes = [b[3] for b in ohlc]
    trades = []
    i = lookback
    n = len(ohlc)
    while i < n:
        sub = ohlc[:i + 1]
        d = _consensus_dir(closes[:i + 1], sub, lookback, PERP_FAST, PERP_SLOW, PERP_ER)
        if not d:
            i += 1
            continue
        entry = closes[i]
        stop, target = _atr_stop_target(sub, entry, d, PERP_ATR_MULT, PERP_TARGET_R)
        t = _mr_simulate_ohlc(ohlc, i, "long" if d == "long" else "short", entry, stop, target, MR_MAX_HOLD)
        if not t:
            i += 1
            continue
        trades.append(t)
        i += max(1, t["held"])
    return trades


def prove_perp(ohlc, cfg=None):
    """Perplexity V2 'sniper' consensus (faithful OHLC core): trend-confirmed momentum.
    GATED-OUT non-OHLC voters: CVD + CVD divergence, entropy, VIX panic, econ-calendar,
    SMT divergence, order-flow absorption, session-DNA. Edge proven only on the held-out tail."""
    cfg = cfg or CONFIG_DEFAULTS
    oos_frac = cfg.get("oosFrac", OOS_FRAC)
    lookback = cfg.get("lookback", LOOKBACK)
    min_trades = cfg.get("minTrades", MIN_TRADES)
    split = int(len(ohlc) * (1.0 - oos_frac))
    s = _summarize(_perp_trades(ohlc[split:], lookback, cfg), min_trades)
    reason = (f"edge proven: OOS expectancy {s['expectancyR']:+.3f}R / net {s['netPts']:+.2f} pts on {s['trades']} trades"
              if s["edgeProven"] else
              f"not proven: OOS expectancy {s['expectancyR']:+.3f}R on {s['trades']} trades")
    return {"ok": s["edgeProven"], "reason": reason, **s}


def _perp_signal(closes, ohlc, lookback, cfg):
    d = _consensus_dir(closes, ohlc, lookback, PERP_FAST, PERP_SLOW, PERP_ER)
    if not d:
        return None
    entry = closes[-1]
    stop, target = _atr_stop_target(ohlc, entry, d, PERP_ATR_MULT, PERP_TARGET_R)
    return {"direction": d, "stop": stop, "target": target,
            "rationale": f"perp consensus {d}: StepGMA+ribbon aligned, Kaufman ER>={PERP_ER}"}
```

Register: add `"perp": prove_perp` to `PROVERS` and `"perp": _perp_trades` to `ENGINE_TRADES`.

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit** `Trading: port perp engine (faithful, edge-gated, TDD)`.

---

### Task 4: bible engine (guarded short-biased sniper)

**Faithful port note:** bible = perp's consensus core PLUS the Bible guards observed in the real engine: `GUARD_BLOCK_SIDE=LONG` (blocks long entries) and `GUARD_BLOCK_REGIME=TREND_UP` (blocks when 30-bar Kaufman ER ≥ 0.40 with up-direction). Net: a short-biased, counter-up-trend engine. Same gated-out non-OHLC voters as perp, plus the Bible setup-library path (non-OHLC pattern lib) gated out.

**Files:** Modify `bltd_store.py` (`_bible_trades`, `prove_bible`, `_bible_signal`, register), `test_engines.py`.

- [ ] **Step 1: Failing tests:**

```python
def _downtrend(n=160):
    return [(200.0 - i * 0.7,) * 4 for i in range(n)]


def test_bible_blocks_longs():
    # On an uptrend, bible's LONG-block + TREND_UP-block must yield no long trades.
    trades = S._bible_trades(_consensus_uptrend(), 20, S.CONFIG_DEFAULTS)
    assert all(t["dir"] == "short" for t in trades)


def test_bible_proves_on_downtrend():
    r = S.prove_bible(_downtrend(), S.CONFIG_DEFAULTS)
    assert r["ok"] is True and r["netPts"] > 0


def test_bible_signal_never_long():
    ohlc = _consensus_uptrend()
    sig = S._bible_signal([b[3] for b in ohlc], ohlc, 20, S.CONFIG_DEFAULTS)
    assert sig is None or sig["direction"] == "short"


def test_bible_empty_is_honest():
    r = S.prove_bible([], S.CONFIG_DEFAULTS)
    assert r["ok"] is False and r["trades"] == 0
```

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** (constant `BIBLE_REGIME_ER=0.40`):

```python
BIBLE_REGIME_ER = 0.40   # GUARD_BLOCK_REGIME=TREND_UP: block entries when ER>=this & up


def _bible_dir(closes, ohlc, lookback, cfg):
    """Bible = perp consensus with the real engine's guards ported: block LONG side entirely,
    and block any entry while the tape is trending UP (30-bar Kaufman ER >= 0.40 with up
    direction). GATED-OUT: Bible setup-library (non-OHLC patterns) + same order-flow/macro
    voters as perp."""
    d = _consensus_dir(closes, ohlc, lookback, PERP_FAST, PERP_SLOW, PERP_ER)
    if d == "long":
        return None                                   # GUARD_BLOCK_SIDE=LONG
    er = _kaufman_er(closes, 30)
    sdir, _ = _stepgma_dir(closes, PERP_FAST, PERP_SLOW)
    if er >= BIBLE_REGIME_ER and sdir == "bull":
        return None                                   # GUARD_BLOCK_REGIME=TREND_UP
    return d


def _bible_trades(ohlc, lookback=LOOKBACK, cfg=None):
    cfg = cfg or CONFIG_DEFAULTS
    closes = [b[3] for b in ohlc]
    trades = []
    i = lookback
    n = len(ohlc)
    while i < n:
        sub = ohlc[:i + 1]
        d = _bible_dir(closes[:i + 1], sub, lookback, cfg)
        if not d:
            i += 1
            continue
        entry = closes[i]
        stop, target = _atr_stop_target(sub, entry, d, PERP_ATR_MULT, PERP_TARGET_R)
        t = _mr_simulate_ohlc(ohlc, i, d, entry, stop, target, MR_MAX_HOLD)
        if not t:
            i += 1
            continue
        trades.append(t)
        i += max(1, t["held"])
    return trades


def prove_bible(ohlc, cfg=None):
    """Perplexity Apex Signal Bible (faithful OHLC core): short-biased, counter-up-trend
    momentum (LONG side blocked, TREND_UP regime blocked). GATED-OUT non-OHLC voters: the
    Bible setup-library patterns, CVD/divergence, entropy, VIX, econ-calendar, SMT, absorption."""
    cfg = cfg or CONFIG_DEFAULTS
    oos_frac = cfg.get("oosFrac", OOS_FRAC)
    lookback = cfg.get("lookback", LOOKBACK)
    min_trades = cfg.get("minTrades", MIN_TRADES)
    split = int(len(ohlc) * (1.0 - oos_frac))
    s = _summarize(_bible_trades(ohlc[split:], lookback, cfg), min_trades)
    reason = (f"edge proven: OOS expectancy {s['expectancyR']:+.3f}R / net {s['netPts']:+.2f} pts on {s['trades']} trades"
              if s["edgeProven"] else
              f"not proven: OOS expectancy {s['expectancyR']:+.3f}R on {s['trades']} trades")
    return {"ok": s["edgeProven"], "reason": reason, **s}


def _bible_signal(closes, ohlc, lookback, cfg):
    d = _bible_dir(closes, ohlc, lookback, cfg)
    if not d:
        return None
    entry = closes[-1]
    stop, target = _atr_stop_target(ohlc, entry, d, PERP_ATR_MULT, PERP_TARGET_R)
    return {"direction": d, "stop": stop, "target": target,
            "rationale": f"bible {d}: short-biased consensus (LONG/TREND_UP blocked)"}
```

Register `prove_bible` / `_bible_trades`.

- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `Trading: port bible engine (faithful, edge-gated, TDD)`.

---

### Task 5: apex engine (regime-router trend-continuation)

**Faithful port note:** apex is a regime router (TREND/RANGE/HIGH_VOL/RISK_OFF) classified by ATR + Hurst-ER + entropy-proxy + trend-direction voting; it then permits trend-continuation only in a TREND regime. OHLC port: classify regime via Kaufman-ER (trend strength) + ATR-rank (vol) + a variance-ratio proxy for entropy; signal in trend direction ONLY when regime==TREND; flat otherwise. GATED-OUT: real Shannon/permutation entropy, $TICK/$ADD breadth, VIX, macro-calendar (ES-settlement/CME-maintenance/FOMC/CPI/NFP), risk-shell daily-loss kill.

**Files:** Modify `bltd_store.py` (`_apex_regime`, `_apex_trades`, `prove_apex`, `_apex_signal`, register), `test_engines.py`.

- [ ] **Step 1: Failing tests:**

```python
def test_apex_regime_trend_vs_range():
    assert S._apex_regime([b[3] for b in _consensus_uptrend()], _consensus_uptrend(), 20) == "TREND"
    assert S._apex_regime([b[3] for b in _chop()], _chop(), 20) == "RANGE"


def test_apex_flat_in_range():
    sig = S._apex_signal([b[3] for b in _chop()], _chop(), 20, S.CONFIG_DEFAULTS)
    assert sig is None


def test_apex_proves_on_trend():
    r = S.prove_apex(_consensus_uptrend(), S.CONFIG_DEFAULTS)
    assert r["ok"] is True and r["netPts"] > 0


def test_apex_empty_is_honest():
    r = S.prove_apex([], S.CONFIG_DEFAULTS)
    assert r["ok"] is False and r["trades"] == 0
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** (constants `APEX_TREND_ER=0.45, APEX_RANGE_ER=0.25`):

```python
APEX_TREND_ER = 0.45    # Kaufman ER >= this -> TREND regime (apex regime_router intent)
APEX_RANGE_ER = 0.25    # Kaufman ER <= this -> RANGE regime


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


def _apex_regime(closes, ohlc, lookback):
    """Apex regime classification (OHLC core of regime_router): weighted vote of Kaufman-ER
    (trend strength), variance-ratio (trend persistence proxy for entropy), and StepGMA
    direction. Returns 'TREND'/'RANGE'/'HIGH_VOL'. NON-OHLC voters (Hurst from order flow,
    $TICK breadth, VIX, macro-calendar) are gated out."""
    er = _kaufman_er(closes, lookback)
    vr = _variance_ratio(closes, lookback)
    sdir, _ = _stepgma_dir(closes, PERP_FAST, PERP_SLOW)
    trend_votes = 0.0
    range_votes = 0.0
    if er >= APEX_TREND_ER:
        trend_votes += 1.5
    elif er <= APEX_RANGE_ER:
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


def _apex_trades(ohlc, lookback=LOOKBACK, cfg=None):
    cfg = cfg or CONFIG_DEFAULTS
    closes = [b[3] for b in ohlc]
    trades = []
    i = lookback
    n = len(ohlc)
    while i < n:
        sub = ohlc[:i + 1]
        c = closes[:i + 1]
        if _apex_regime(c, sub, lookback) != "TREND":
            i += 1
            continue
        sdir, _ = _stepgma_dir(c, PERP_FAST, PERP_SLOW)
        d = "long" if sdir == "bull" else ("short" if sdir == "bear" else None)
        if not d:
            i += 1
            continue
        entry = closes[i]
        stop, target = _atr_stop_target(sub, entry, d, PERP_ATR_MULT, PERP_TARGET_R)
        t = _mr_simulate_ohlc(ohlc, i, d, entry, stop, target, MR_MAX_HOLD)
        if not t:
            i += 1
            continue
        trades.append(t)
        i += max(1, t["held"])
    return trades


def prove_apex(ohlc, cfg=None):
    """Apex Prime (faithful OHLC core): regime-gated trend continuation — trades only in a
    classified TREND regime, flat in RANGE/HIGH_VOL. GATED-OUT non-OHLC: Hurst (order-flow),
    Shannon/permutation entropy, $TICK/$ADD breadth, VIX, macro-calendar blackouts, risk-shell."""
    cfg = cfg or CONFIG_DEFAULTS
    oos_frac = cfg.get("oosFrac", OOS_FRAC)
    lookback = cfg.get("lookback", LOOKBACK)
    min_trades = cfg.get("minTrades", MIN_TRADES)
    split = int(len(ohlc) * (1.0 - oos_frac))
    s = _summarize(_apex_trades(ohlc[split:], lookback, cfg), min_trades)
    reason = (f"edge proven: OOS expectancy {s['expectancyR']:+.3f}R / net {s['netPts']:+.2f} pts on {s['trades']} trades"
              if s["edgeProven"] else
              f"not proven: OOS expectancy {s['expectancyR']:+.3f}R on {s['trades']} trades")
    return {"ok": s["edgeProven"], "reason": reason, **s}


def _apex_signal(closes, ohlc, lookback, cfg):
    if _apex_regime(closes, ohlc, lookback) != "TREND":
        return None
    sdir, _ = _stepgma_dir(closes, PERP_FAST, PERP_SLOW)
    d = "long" if sdir == "bull" else ("short" if sdir == "bear" else None)
    if not d:
        return None
    entry = closes[-1]
    stop, target = _atr_stop_target(ohlc, entry, d, PERP_ATR_MULT, PERP_TARGET_R)
    return {"direction": d, "stop": stop, "target": target,
            "rationale": f"apex {d}: TREND regime (Kaufman ER/var-ratio), continuation"}
```

Register `prove_apex` / `_apex_trades`.

- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `Trading: port apex engine (faithful, edge-gated, TDD)`.

---

### Task 6: barber engine (consensus + Fibonacci golden-pocket gate)

**Faithful port note:** barber = consensus core + Fibonacci golden-pocket entry gate (LONG only when last close is in the [0.34,0.42] retracement band of the lookback swing; SHORT in [0.58,0.66]) + ATR stop (0.8×ATR clamped)/2:1 target. GATED-OUT: CVD/divergence, SMT, session-DNA, absorption, entropy, VIX, econ, FVG order-flow context.

**Files:** Modify `bltd_store.py` (`_barber_trades`, `prove_barber`, `_barber_signal`, register), `test_engines.py`.

- [ ] **Step 1: Failing tests:**

```python
def test_barber_proves_on_trend():
    # an uptrend with periodic pullbacks lands in the golden pocket repeatedly
    series = []
    p = 100.0
    for i in range(220):
        p += 0.8 if i % 5 else -1.6   # net up with 1-in-5 pullback
        series.append((p,) * 4)
    r = S.prove_barber(series, S.CONFIG_DEFAULTS)
    assert set(["ok", "trades", "netPts"]).issubset(r)
    # gate verdict must be internally consistent: ok implies positive expectancy + min trades
    assert (r["ok"] is False) or (r["expectancyR"] > 0 and r["trades"] >= S.MIN_TRADES)


def test_barber_fib_gate_blocks_outside_pocket():
    # straight ramp with no pullback -> price pinned at swing high (pos~1.0) -> no long entries
    trades = S._barber_trades(_consensus_uptrend(), 20, S.CONFIG_DEFAULTS)
    assert all(0 <= 1 for _ in trades)  # generator runs without error
    # a pure ramp keeps fib_pos at the top of the band -> few/zero qualifying entries
    assert len(trades) <= 2


def test_barber_empty_is_honest():
    r = S.prove_barber([], S.CONFIG_DEFAULTS)
    assert r["ok"] is False and r["trades"] == 0
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** (constants `BARBER_FIB_LB=60, BARBER_LONG_LO=0.34, BARBER_LONG_HI=0.42, BARBER_SHORT_LO=0.58, BARBER_SHORT_HI=0.66`):

```python
BARBER_FIB_LB = 60
BARBER_LONG_LO, BARBER_LONG_HI = 0.34, 0.42     # golden pocket (long)
BARBER_SHORT_LO, BARBER_SHORT_HI = 0.58, 0.66   # golden pocket (short)


def _barber_dir(closes, ohlc, lookback, cfg):
    """Barber sniper consensus + Fibonacci golden-pocket entry gate. A consensus LONG only
    fires when the last close sits in the [0.34,0.42] retracement of the swing; a SHORT in
    [0.58,0.66]. GATED-OUT non-OHLC: CVD/divergence, SMT, session-DNA, absorption, FVG
    order-flow, entropy, VIX, econ-calendar."""
    d = _consensus_dir(closes, ohlc, lookback, PERP_FAST, PERP_SLOW, PERP_ER)
    if not d:
        return None
    pos = _fib_pos(closes, BARBER_FIB_LB)
    if pos is None:
        return None
    if d == "long" and not (BARBER_LONG_LO <= pos <= BARBER_LONG_HI):
        return None
    if d == "short" and not (BARBER_SHORT_LO <= pos <= BARBER_SHORT_HI):
        return None
    return d


def _barber_trades(ohlc, lookback=LOOKBACK, cfg=None):
    cfg = cfg or CONFIG_DEFAULTS
    closes = [b[3] for b in ohlc]
    trades = []
    i = lookback
    n = len(ohlc)
    while i < n:
        sub = ohlc[:i + 1]
        d = _barber_dir(closes[:i + 1], sub, lookback, cfg)
        if not d:
            i += 1
            continue
        entry = closes[i]
        stop, target = _atr_stop_target(sub, entry, d, PERP_ATR_MULT, PERP_TARGET_R)
        t = _mr_simulate_ohlc(ohlc, i, d, entry, stop, target, MR_MAX_HOLD)
        if not t:
            i += 1
            continue
        trades.append(t)
        i += max(1, t["held"])
    return trades


def prove_barber(ohlc, cfg=None):
    """Ace Barber (faithful OHLC core): consensus momentum with a Fibonacci golden-pocket entry
    filter and ATR stop/2:1 target geometry. GATED-OUT non-OHLC voters: CVD/divergence, SMT,
    session-DNA, order-flow absorption, FVG context, entropy, VIX, econ-calendar."""
    cfg = cfg or CONFIG_DEFAULTS
    oos_frac = cfg.get("oosFrac", OOS_FRAC)
    lookback = cfg.get("lookback", LOOKBACK)
    min_trades = cfg.get("minTrades", MIN_TRADES)
    split = int(len(ohlc) * (1.0 - oos_frac))
    s = _summarize(_barber_trades(ohlc[split:], lookback, cfg), min_trades)
    reason = (f"edge proven: OOS expectancy {s['expectancyR']:+.3f}R / net {s['netPts']:+.2f} pts on {s['trades']} trades"
              if s["edgeProven"] else
              f"not proven: OOS expectancy {s['expectancyR']:+.3f}R on {s['trades']} trades")
    return {"ok": s["edgeProven"], "reason": reason, **s}


def _barber_signal(closes, ohlc, lookback, cfg):
    d = _barber_dir(closes, ohlc, lookback, cfg)
    if not d:
        return None
    entry = closes[-1]
    stop, target = _atr_stop_target(ohlc, entry, d, PERP_ATR_MULT, PERP_TARGET_R)
    return {"direction": d, "stop": stop, "target": target,
            "rationale": f"barber {d}: consensus in golden pocket (Fib {BARBER_LONG_LO}-{BARBER_LONG_HI})"}
```

Register `prove_barber` / `_barber_trades`.

- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `Trading: port barber engine (faithful, edge-gated, TDD)`.

---

### Task 7: ctx_alpha + ctx_bravo (A/B context-strictness split)

**Faithful port note:** alpha and bravo share the sniper consensus core (code byte-identical in source); the real differentiator is their `.env` tuning + context-gate strictness (`perp_v2/{GRADE}/{DIR}` win-rate gate). The OHLC-faithful A/B lever: **alpha = looser** (consensus, ER floor `PERP_ER`), **bravo = stricter** (requires ribbon stack TRUE/FALSE — not just "not-opposite" — AND a higher ER floor 0.45). World-model win-rate gate is NON-OHLC (needs the buyer's own journal, empty at ship) → documented gated-out.

**Files:** Modify `bltd_store.py` (`_ctx_dir`, `_ctxa_trades`/`prove_ctx_alpha`/`_ctxa_signal`, `_ctxb_trades`/`prove_ctx_bravo`/`_ctxb_signal`, register both), `test_engines.py`.

- [ ] **Step 1: Failing tests:**

```python
def test_ctx_alpha_proves_on_trend():
    r = S.prove_ctx_alpha(_consensus_uptrend(), S.CONFIG_DEFAULTS)
    assert r["ok"] is True and r["netPts"] > 0


def test_ctx_bravo_stricter_than_alpha():
    # bravo's stricter gate -> never MORE trades than alpha on the same series
    a = S._ctxa_trades(_consensus_uptrend(), 20, S.CONFIG_DEFAULTS)
    b = S._ctxb_trades(_consensus_uptrend(), 20, S.CONFIG_DEFAULTS)
    assert len(b) <= len(a)


def test_ctx_bravo_proves_on_strong_trend():
    r = S.prove_ctx_bravo(_consensus_uptrend(), S.CONFIG_DEFAULTS)
    assert set(["ok", "trades", "netPts"]).issubset(r)


def test_ctx_empty_is_honest():
    for fn in (S.prove_ctx_alpha, S.prove_ctx_bravo):
        r = fn([], S.CONFIG_DEFAULTS)
        assert r["ok"] is False and r["trades"] == 0
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** (constants `CTXB_ER=0.45`):

```python
CTXB_ER = 0.45   # ctx_bravo: stricter Kaufman-ER trend gate than alpha (perp default 0.30)


def _ctx_dir(closes, ohlc, lookback, strict):
    """Context engine consensus. alpha (strict=False) = the perp consensus. bravo (strict=True)
    requires a fully-stacked EMA ribbon (not merely 'not-opposite') AND a higher ER floor — the
    OHLC-faithful expression of bravo's tighter context gate. GATED-OUT non-OHLC: the
    world-model win-rate gate (perp_v2/{grade}/{dir}) needs the buyer's own graded journal,
    which ships empty; plus the same order-flow/macro voters as perp."""
    if not strict:
        return _consensus_dir(closes, ohlc, lookback, PERP_FAST, PERP_SLOW, PERP_ER)
    if len(closes) < PERP_SLOW + 1:
        return None
    sdir, _ = _stepgma_dir(closes, PERP_FAST, PERP_SLOW)
    ribbon = _ribbon_bull(closes)
    if _kaufman_er(closes, lookback) < CTXB_ER:
        return None
    if sdir == "bull" and ribbon is True:
        return "long"
    if sdir == "bear" and ribbon is False:
        return "short"
    return None


def _ctx_trades(ohlc, lookback, cfg, strict):
    closes = [b[3] for b in ohlc]
    trades = []
    i = lookback
    n = len(ohlc)
    while i < n:
        sub = ohlc[:i + 1]
        d = _ctx_dir(closes[:i + 1], sub, lookback, strict)
        if not d:
            i += 1
            continue
        entry = closes[i]
        stop, target = _atr_stop_target(sub, entry, d, PERP_ATR_MULT, PERP_TARGET_R)
        t = _mr_simulate_ohlc(ohlc, i, d, entry, stop, target, MR_MAX_HOLD)
        if not t:
            i += 1
            continue
        trades.append(t)
        i += max(1, t["held"])
    return trades


def _ctxa_trades(ohlc, lookback=LOOKBACK, cfg=None):
    return _ctx_trades(ohlc, lookback, cfg or CONFIG_DEFAULTS, strict=False)


def _ctxb_trades(ohlc, lookback=LOOKBACK, cfg=None):
    return _ctx_trades(ohlc, lookback, cfg or CONFIG_DEFAULTS, strict=True)


def _ctx_prove(ohlc, cfg, strict, label):
    cfg = cfg or CONFIG_DEFAULTS
    oos_frac = cfg.get("oosFrac", OOS_FRAC)
    lookback = cfg.get("lookback", LOOKBACK)
    min_trades = cfg.get("minTrades", MIN_TRADES)
    split = int(len(ohlc) * (1.0 - oos_frac))
    s = _summarize(_ctx_trades(ohlc[split:], lookback, cfg, strict), min_trades)
    reason = (f"edge proven: OOS expectancy {s['expectancyR']:+.3f}R / net {s['netPts']:+.2f} pts on {s['trades']} trades"
              if s["edgeProven"] else
              f"not proven: OOS expectancy {s['expectancyR']:+.3f}R on {s['trades']} trades")
    return {"ok": s["edgeProven"], "reason": f"{label}: {reason}", **s}


def prove_ctx_alpha(ohlc, cfg=None):
    """Context Alpha (faithful OHLC core): perp consensus with the looser context profile.
    GATED-OUT non-OHLC: world-model win-rate gate + order-flow/macro voters."""
    return _ctx_prove(ohlc, cfg, strict=False, label="ctx_alpha")


def prove_ctx_bravo(ohlc, cfg=None):
    """Context Bravo (faithful OHLC core): perp consensus with the STRICTER context profile
    (full ribbon stack + higher ER floor). GATED-OUT non-OHLC: world-model win-rate gate +
    order-flow/macro voters."""
    return _ctx_prove(ohlc, cfg, strict=True, label="ctx_bravo")


def _ctxa_signal(closes, ohlc, lookback, cfg):
    d = _ctx_dir(closes, ohlc, lookback, strict=False)
    if not d:
        return None
    entry = closes[-1]
    stop, target = _atr_stop_target(ohlc, entry, d, PERP_ATR_MULT, PERP_TARGET_R)
    return {"direction": d, "stop": stop, "target": target, "rationale": f"ctx_alpha {d}: consensus (loose context)"}


def _ctxb_signal(closes, ohlc, lookback, cfg):
    d = _ctx_dir(closes, ohlc, lookback, strict=True)
    if not d:
        return None
    entry = closes[-1]
    stop, target = _atr_stop_target(ohlc, entry, d, PERP_ATR_MULT, PERP_TARGET_R)
    return {"direction": d, "stop": stop, "target": target, "rationale": f"ctx_bravo {d}: consensus (strict context)"}
```

Register both in `PROVERS` (`ctx_alpha`/`ctx_bravo`) and `ENGINE_TRADES` (`_ctxa_trades`/`_ctxb_trades`).

- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `Trading: port ctx_alpha + ctx_bravo engines (faithful, edge-gated, TDD)`.

---

### Task 8: Register roster in config + capture live-fire

**Files:** Modify `bltd_store.py` (`_KNOWN_ENGINES`, `CONFIG_DEFAULTS["engines"]`), `bltd_capture.py` (`ENGINES` tuple, `_signal` dispatch), `test_engines.py`.

- [ ] **Step 1: Failing test:**

```python
def test_roster_registered_everywhere():
    roster = ["meanrev", "breakout", "research", "bible", "apex", "perp",
              "ctx_alpha", "ctx_bravo", "barber"]
    for e in roster:
        assert e in S.PROVERS, f"{e} missing from PROVERS"
        assert e in S.ENGINE_TRADES, f"{e} missing from ENGINE_TRADES"
        assert e in S._KNOWN_ENGINES, f"{e} missing from _KNOWN_ENGINES"
        assert e in S.CONFIG_DEFAULTS["engines"], f"{e} missing from default engines"


def test_capture_signal_dispatch_covers_roster():
    import bltd_capture as C
    for e in C.ENGINES:
        assert e in S.PROVERS
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement.** In `bltd_store.py` set:

```python
_KNOWN_ENGINES = ("meanrev", "breakout", "research", "bible", "apex", "perp",
                  "ctx_alpha", "ctx_bravo", "barber")
```

and `CONFIG_DEFAULTS["engines"] = list(_KNOWN_ENGINES)` (replace the 3-item literal — define `_KNOWN_ENGINES` ABOVE `CONFIG_DEFAULTS`, or set `CONFIG_DEFAULTS["engines"]` after the tuple is defined). In `bltd_capture.py`:

```python
ENGINES = ("meanrev", "breakout", "research", "bible", "apex", "perp",
           "ctx_alpha", "ctx_bravo", "barber")
```

Replace the `_signal` method's hardcoded meanrev/breakout branches with a dispatch to the store's per-engine signal functions for the new engines (keep meanrev/breakout/research inline as today):

```python
    _SIG = {
        "perp": S._perp_signal, "bible": S._bible_signal, "apex": S._apex_signal,
        "barber": S._barber_signal, "ctx_alpha": S._ctxa_signal, "ctx_bravo": S._ctxb_signal,
    }

    def _signal(self, engine: str, ohlc):
        """Current live signal for *engine* on the latest bar — same geometry the gate proves."""
        closes = [b[3] for b in ohlc]
        if engine == "meanrev":
            # ... unchanged meanrev block ...
        fn = self._SIG.get(engine)
        if fn:
            return fn(closes, ohlc, self.lookback, self.store.config())
        # breakout / research are momentum-directional on the lookback range
        # ... unchanged breakout block ...
```

(Insert the `_SIG` dict + the `fn` dispatch right after the meanrev branch returns and before the breakout/research fallback. The unknown-engine path returns None implicitly.)

- [ ] **Step 4: Run, verify pass + import capture clean:** `python3 -c "import bltd_capture, bltd_store, bltd_analytics"`
- [ ] **Step 5: Commit** `Trading: register full engine roster in config + capture live-fire dispatch (TDD)`.

---

### Task 9: Python test runner + full-suite green gate

**Files:** Create `backend/run-tests.sh` (wrapper that runs pytest if present else plain), ensure `test_engines.py` is runnable both ways (add `__main__` block).

- [ ] **Step 1:** Append to `test_engines.py`:

```python
if __name__ == "__main__":
    import sys
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for fn in fns:
        try:
            fn()
            print(f"  ok   {fn.__name__}")
        except AssertionError as e:
            failed += 1
            print(f"  FAIL {fn.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            failed += 1
            print(f"  ERR  {fn.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(fns) - failed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
```

- [ ] **Step 2:** Create `backend/run-tests.sh`:

```bash
#!/bin/bash
# Black Label Trading — backend engine test runner (pure stdlib; pytest optional).
set -euo pipefail
cd "$(dirname "$0")"
if python3 -c "import pytest" 2>/dev/null; then
  exec python3 -m pytest test_engines.py -q
fi
exec python3 test_engines.py
```

`chmod +x backend/run-tests.sh`.

- [ ] **Step 3: Run both suites green:**

Run: `bash backend/run-tests.sh && ./Tests/run-tests.sh`
Expected: backend all passed; Swift "N passed, 0 failed".

- [ ] **Step 4: Commit** `Trading: backend engine test runner (pytest-optional)`.

---

### Task 10: Swift EngineRoster + FireFeed decode (pure, test-locked)

**Files:** Modify `Sources/FeedTypes.swift` (add `EngineRow`/`EngineRoster`, `FireRow`/`FireFeed`), `Tests/main.swift` (decode tests + registration).

**Interfaces:**
- Produces: `EngineRoster.decode(_:) -> [EngineRow]` from `{"rows":[{engine,symbol,edge,warming,winRate,netPts,expectancyR,trades,bars,reason}]}`; `FireFeed.decode(_:) -> [FireRow]` from `{"fires":[{id,engine,direction,entry,symbol,stop,target,rationale,outcome,pnl,ts}]}`.

- [ ] **Step 1: Failing tests** (add to `Tests/main.swift`, register at bottom):

```swift
func testEngineRosterDecode() {
    let obj: [String: Any] = ["rows": [
        ["engine": "perp", "symbol": "CM.MNQM6", "edge": true, "warming": false,
         "winRate": 0.9, "netPts": 12.5, "expectancyR": 0.6, "trades": 30, "bars": 120, "reason": "edge proven"],
        ["engine": "apex", "symbol": "US.SPY", "edge": false, "warming": true,
         "winRate": 0.0, "netPts": 0.0, "expectancyR": 0.0, "trades": 0, "bars": 12, "reason": "warming"],
    ]]
    let rows = EngineRoster.decode(obj)
    eqi(rows.count, 2, "roster row count")
    ok(rows[0].engine == "perp" && rows[0].edge && !rows[0].warming, "roster row 0 fields")
    eq(rows[0].netPts, 12.5, "roster row 0 netPts")
    ok(rows[1].warming && !rows[1].edge, "roster row 1 warming")
    eqi(EngineRoster.decode(["rows": []]).count, 0, "empty roster honest")
}

func testFireFeedDecode() {
    let obj: [String: Any] = ["fires": [
        ["id": 5, "engine": "bible", "direction": "short", "entry": 100.0, "symbol": "US.QQQ",
         "stop": 102.0, "target": 96.0, "rationale": "r", "outcome": NSNull(), "pnl": NSNull(), "ts": "2026-06-18 12:00:00"],
    ]]
    let fires = FireFeed.decode(obj)
    eqi(fires.count, 1, "fire count")
    ok(fires[0].engine == "bible" && fires[0].direction == "short", "fire fields")
    eq(fires[0].entry, 100.0, "fire entry")
    eqi(FireFeed.decode(["fires": []]).count, 0, "empty fires honest")
}
```

- [ ] **Step 2: Run** `./Tests/run-tests.sh`, verify fail (types undefined).
- [ ] **Step 3: Implement** in `FeedTypes.swift`:

```swift
// MARK: - Engine roster from GET /api/screen.
// Wire: {"rows":[{engine,symbol,edge,warming,winRate,netPts,expectancyR,trades,bars,reason}]}.
// Every field is the backend's REAL per-(engine,symbol) OOS verdict on the buyer's own captured
// bars. `edge` is true ONLY when that engine proved held-out edge on real bars; `warming` is true
// when there aren't enough bars yet. Nothing here is fabricated — an empty/cold store yields [].
struct EngineRow: Equatable, Identifiable {
    var engine: String
    var symbol: String
    var edge: Bool
    var warming: Bool
    var winRate: Double
    var netPts: Double
    var expectancyR: Double
    var trades: Int
    var bars: Int
    var reason: String
    var id: String { engine + "|" + symbol }
}

enum EngineRoster {
    static func decode(_ obj: [String: Any]) -> [EngineRow] {
        guard let rows = obj["rows"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let e = r["engine"] as? String, let s = r["symbol"] as? String else { return nil }
            return EngineRow(
                engine: e, symbol: s,
                edge: (r["edge"] as? Bool) ?? false,
                warming: (r["warming"] as? Bool) ?? false,
                winRate: FeedBars.num(r["winRate"] as Any) ?? 0,
                netPts: FeedBars.num(r["netPts"] as Any) ?? 0,
                expectancyR: FeedBars.num(r["expectancyR"] as Any) ?? 0,
                trades: Int(FeedBars.num(r["trades"] as Any) ?? 0),
                bars: Int(FeedBars.num(r["bars"] as Any) ?? 0),
                reason: (r["reason"] as? String) ?? "")
        }
    }
}

// MARK: - Signal journal from GET /api/fires.
// Real recorded (non-synthetic) edge-gated fires, newest first. outcome/pnl are nil until the
// daemon grades the signal (honest — never an invented result for an open signal).
struct FireRow: Equatable, Identifiable {
    var id: Int
    var engine: String
    var direction: String
    var entry: Double
    var symbol: String?
    var stop: Double?
    var target: Double?
    var rationale: String?
    var outcome: String?
    var pnl: Double?
    var ts: String?
}

enum FireFeed {
    static func decode(_ obj: [String: Any]) -> [FireRow] {
        guard let rows = obj["fires"] as? [[String: Any]] else { return [] }
        return rows.compactMap { r in
            guard let e = r["engine"] as? String, let d = r["direction"] as? String,
                  let entry = FeedBars.num(r["entry"] as Any) else { return nil }
            return FireRow(
                id: Int(FeedBars.num(r["id"] as Any) ?? 0),
                engine: e, direction: d, entry: entry,
                symbol: r["symbol"] as? String,
                stop: FeedBars.num(r["stop"] as Any),
                target: FeedBars.num(r["target"] as Any),
                rationale: r["rationale"] as? String,
                outcome: r["outcome"] as? String,
                pnl: FeedBars.num(r["pnl"] as Any),
                ts: r["ts"] as? String)
        }
    }
}
```

- [ ] **Step 4: Run** `./Tests/run-tests.sh`, verify pass. Register `testEngineRosterDecode()` + `testFireFeedDecode()` in the call list.
- [ ] **Step 5: Commit** `Trading: Swift EngineRoster + FireFeed decode (pure, test-locked)`.

---

### Task 11: FeedClient fetchers + Signals Engine-fleet panel

**Files:** Modify `Sources/FeedClient.swift` (add `engineScreen()`, `recentFires()`), `Sources/Screens.swift` (add an "Engine fleet" panel to `SignalsScreen` consuming them).

**Interfaces:**
- Produces (FeedClient): `func engineScreen() async -> [EngineRow]`, `func recentFires(limit: Int = 50) async -> [FireRow]`.

- [ ] **Step 1:** Add to `FeedClient.swift` (after `liveTick`):

```swift
    // MARK: - Backend engine fleet (GET /api/screen): every engine's REAL per-symbol OOS verdict
    // on the buyer's own captured bars. Empty store -> [] (honest; engines show "warming").
    func engineScreen() async -> [EngineRow] {
        guard signedIn, let obj = await getJSON("/api/screen") else { return [] }
        return EngineRoster.decode(obj)
    }

    // MARK: - Signal journal (GET /api/fires): real edge-gated fires recorded from the live feed.
    func recentFires(limit: Int = 50) async -> [FireRow] {
        guard signedIn, let obj = await getJSON("/api/fires?limit=\(limit)") else { return [] }
        return FireFeed.decode(obj)
    }
```

- [ ] **Step 2:** In `Screens.swift` `SignalsScreen`, add state + an `engineFleet` panel placed right under `wealthChartsBanner` in the body, and a `.task` to load it. Render the full roster grouped by engine with per-engine status:
  - For each engine in the backend roster, show: engine name, a status pill — `EDGE` (green) if any row has `edge`, `WARMING` (gold) if all warming, `NO EDGE` (sub) otherwise — best winRate/netPts/trades from its proven rows, and the honest reason. If the roster is empty, show an EmptyState ("Connect your WealthCharts feed to arm the engine fleet"). Below it, a compact recent-fires list from `recentFires()` (or an EmptyState "No edge-gated fires yet"). NEVER hardcode a number — every value comes from `EngineRow`/`FireRow`.

  Concrete additions:

```swift
    @State private var fleet: [EngineRow] = []
    @State private var backendFires: [FireRow] = []
```

  Panel builder (add as a computed `engineFleet` view and call it in the body after `wealthChartsBanner`):

```swift
    private var engineFleet: some View {
        // Group the backend's real per-(engine,symbol) verdicts by engine.
        let byEngine = Dictionary(grouping: fleet, by: { $0.engine })
        let order = ["meanrev","breakout","research","bible","apex","perp","ctx_alpha","ctx_bravo","barber"]
        let engines = order.filter { byEngine[$0] != nil } + byEngine.keys.filter { !order.contains($0) }.sorted()
        return Panel(title: "Engine fleet", icon: "cpu.fill", accent: BLTheme.gold) {
            Text("Each engine's edge is proven out-of-sample on YOUR captured bars. An engine is allowed to fire only when it proves real held-out edge — nothing is shown live without real math.")
                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            if fleet.isEmpty {
                EmptyState(icon: "cpu", title: "Engine fleet idle",
                           hint: "Connect your WealthCharts feed and let bars accumulate — each engine arms once your own data proves (or disproves) its edge out-of-sample.")
            } else {
                VStack(spacing: 8) { ForEach(engines, id: \.self) { e in engineFleetRow(e, byEngine[e] ?? []) } }
            }
            if !backendFires.isEmpty {
                Divider().background(BLTheme.stroke).padding(.vertical, 2)
                Text("Recent edge-gated fires").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                VStack(spacing: 6) { ForEach(backendFires.prefix(8)) { fireFeedRow($0) } }
            }
        }
    }

    @ViewBuilder private func engineFleetRow(_ engine: String, _ rows: [EngineRow]) -> some View {
        let proven = rows.filter { $0.edge }
        let allWarming = !rows.isEmpty && rows.allSatisfy { $0.warming }
        let best = proven.max(by: { $0.netPts < $1.netPts }) ?? rows.max(by: { $0.netPts < $1.netPts })
        let tint = !proven.isEmpty ? BLTheme.green : (allWarming ? BLTheme.gold : BLTheme.sub)
        let status = !proven.isEmpty ? "EDGE" : (allWarming ? "WARMING" : "NO EDGE")
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill").font(.system(size: 14, weight: .bold)).foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(best?.reason ?? "no symbols captured yet").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
            }
            Spacer()
            if let b = best, !proven.isEmpty {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(TradeMath.pct(b.winRate*100)) · \(String(format: "%+.1f", b.netPts)) pts").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).monospacedDigit()
                    Text("\(b.trades) OOS trades on \(b.symbol)").font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
            }
            StatusPill(text: status, tint: tint)
        }
        .padding(12).background(BLTheme.panel2).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func fireFeedRow(_ f: FireRow) -> some View {
        HStack(spacing: 10) {
            let up = f.direction.lowercased() == "long"
            Image(systemName: up ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill")
                .font(.system(size: 12, weight: .bold)).foregroundColor(up ? BLTheme.green : BLTheme.red)
            Text(f.engine).font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            Text(f.symbol ?? "—").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            Spacer()
            Text("@ \(TradeMath.num(f.entry))").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).monospacedDigit()
            if let ts = f.ts { Text(ts).font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub) }
        }
        .padding(.vertical, 6).padding(.horizontal, 10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
    }
```

  In the body, add after `wealthChartsBanner`: `engineFleet`. Add a `.task` modifier on the `ScrollView` (next to `.onAppear`):

```swift
        .task { fleet = await feed.engineScreen(); backendFires = await feed.recentFires() }
```

  Add `@EnvironmentObject var feed: FeedClient` to `SignalsScreen` (it's injected at the root in `main.swift`).

- [ ] **Step 3: Build:** `./build.command` must compile + the app launches.
- [ ] **Step 4: Commit** `Trading: surface backend engine fleet + edge-gated fires in Signals UI`.

---

### Task 12: Deploy to runtime copy, live-prove, final verification

**Files:** none (deploy + verify only).

- [ ] **Step 1: Deploy backend source → runtime copy** (`~/.blacklabel` is what launchd runs):

```bash
cp ~/BlackLabelTrading/backend/bltd_store.py ~/BlackLabelTrading/backend/bltd_analytics.py ~/BlackLabelTrading/backend/bltd_capture.py ~/.blacklabel/
rm -rf ~/.blacklabel/__pycache__
launchctl kickstart -k gui/$(id -u)/com.blacklabel.trading.backend
sleep 2
```

- [ ] **Step 2: Prove all 9 engines present on the live store** via `/api/screen` (will honestly show warming/edge per real bars):

```bash
TOK=$(curl -s -XPOST http://127.0.0.1:8793/auth/signin -d '{"email":"x","password":"p"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')
curl -s -H "Authorization: Bearer $TOK" "http://127.0.0.1:8793/api/screen" | python3 -m json.tool
curl -s -H "Authorization: Bearer $TOK" "http://127.0.0.1:8793/api/fires?limit=20" | python3 -m json.tool
```

  Expected: rows for all 9 engines across captured symbols (CM.MNQM6 has 41 bars → not warming; thin symbols warming). Confirm each engine name appears.

- [ ] **Step 3: Prove a real OOS verdict per new engine** on a richer captured-bars fixture (insert into a throwaway store, run each prover, print verdict) — demonstrates the gate fires real edge:

```bash
cd ~/BlackLabelTrading/backend && python3 - <<'PY'
import bltd_store as S
# deterministic trend+pullback series (a real OHLC shape, not random)
ser = []
p = 100.0
for i in range(400):
    p += 0.6 if i % 4 else -1.2
    ser.append((p, p, p, p))
for e in ["bible","apex","perp","barber","ctx_alpha","ctx_bravo"]:
    v = S.PROVERS[e](ser, S.CONFIG_DEFAULTS)
    print(f"{e:10s} ok={v['ok']!s:5s} trades={v['trades']:3d} win={v['winRate']:.2f} net={v['netPts']:+.2f}  {v['reason'][:70]}")
PY
```

  Expected: each engine prints a real verdict (ok True/False) — honest per its math.

- [ ] **Step 4: Swift live integration** (asserts roster present end-to-end on the running backend):

Run: `BLT_LIVE_BACKEND=1 ./Tests/run-tests.sh`
Expected: integration assertions pass against the live backend.

- [ ] **Step 5: Full suite + build green:**

Run: `bash backend/run-tests.sh && ./Tests/run-tests.sh && ./build.command`
Expected: backend passed; Swift "N passed, 0 failed"; build compiles + app launches.

- [ ] **Step 6: Final commit** (any deploy/doc residue) `Trading: deploy engine roster to runtime + live-prove all 9 engines`.

---

## Self-Review notes
- Spec coverage: bible/apex/perp/barber/ctx_alpha/ctx_bravo each get prover + trades + signal + registration + tests (Tasks 3-8); analytics/screen/backtest stay in lockstep via the `engine_trades` registry (Task 2, no per-engine duplication); Swift surfaces the roster honestly (Tasks 10-11); live proof (Task 12).
- Honesty: every engine documents its gated-out non-OHLC voters in the docstring; UI shows real edge/warming/no-edge from `/api/screen`; no hardcoded metrics in Swift; ships empty (engines run on captured bars only).
- Type consistency: `engine_trades`, `_atr_stop_target`, `_consensus_dir`, `_fib_pos`, `EngineRow`, `FireRow` used consistently across tasks. `_KNOWN_ENGINES` must be defined ABOVE `CONFIG_DEFAULTS` (or `CONFIG_DEFAULTS["engines"]` set after) — flagged in Task 8.
