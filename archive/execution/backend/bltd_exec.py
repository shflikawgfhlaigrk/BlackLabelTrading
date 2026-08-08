"""ARCHIVED, NON-SHIPPING: Black Label Trading autonomous execution engine.

SAFETY IS THE WHOLE POINT. This is the ONLY module that may reach a broker order endpoint, and a
LIVE order is structurally impossible unless `precheck()` returns a LIVE route — a fail-closed,
ordered AND-chain where removing ANY one condition makes a live order impossible:

  0. per-firm ToS permission allows automation for the configured firm AND it's acknowledged
  1. kill clear — exec kill flag False AND no EXEC.KILL sentinel file
  2. armed — the user explicitly armed (default False)
  3. mode == "live"  (otherwise the order is routed to the PaperAdapter — zero broker contact)
  4. live authorization — broker creds present + account resolved + a FRESH human OS-auth token
  5. risk gates pass — daily-loss halt, contract cap, drawdown guard, max-trades/day
  6. edge re-asserted (cache bypassed) for this (engine, symbol)
  7. structural — target present (no naked bracket), $/pt known (=> a real size), dedup/idempotency

Default posture (fresh config: armed False, mode "paper", no firm, no creds) is byte-identical to
the old signals-only behavior — `on_fire` does nothing and no broker is contacted. The engine reads
all state from the store each fire (the capture daemon and API server are separate processes bridged
only by the shared store), so it can never act on stale in-process arming.

Ships NO data and NO creds. Broker creds live in the buyer's macOS Keychain (set by the app), never
here, never logged. The PaperAdapter simulates fills honestly (labeled sim, conservative, off real
ticks) and contacts no broker.
"""
from __future__ import annotations

import os
import threading
import time

# --- per-instrument $/point (real contract specs; unknown => no size => reject, never fabricate) ---
# Mirrors the Swift TradingSymbolScope.pointValue table. A symbol absent here cannot be sized, so it
# can never produce a live order (structural condition 7).
POINT_VALUES = {
    "ES": 50.0, "MES": 5.0, "NQ": 20.0, "MNQ": 2.0, "YM": 5.0, "MYM": 0.5,
    "RTY": 50.0, "M2K": 5.0, "CL": 1000.0, "MCL": 100.0, "GC": 100.0, "MGC": 10.0, "SI": 5000.0,
}

# Minimum tick (price increment) per instrument — needed to express bracket stop/target distances in
# TICKS for the ProjectX order API. Unknown => no live order (sizing already blocks, this is belt+braces).
TICK_SIZES = {
    "ES": 0.25, "MES": 0.25, "NQ": 0.25, "MNQ": 0.25, "YM": 1.0, "MYM": 1.0,
    "RTY": 0.1, "M2K": 0.1, "CL": 0.01, "MCL": 0.01, "GC": 0.1, "MGC": 0.1, "SI": 0.005,
}


def tick_size(symbol):
    return TICK_SIZES.get(futures_root(symbol))


def ticks_between(symbol, a, b):
    """Whole ticks between two prices for *symbol*, or None if the tick size is unknown."""
    ts = tick_size(symbol)
    if ts is None or ts <= 0 or a is None or b is None:
        return None
    return int(round(abs(a - b) / ts))

# Prop firms whose ToS permits (supervised) automation. Unknown / bot-banning firms can NEVER reach
# a live order (condition 0). Conservative allow-list — absence means BLOCK.
FIRM_AUTOMATION = {
    "topstep": True,        # permits automation on a supervised, own-machine basis
    "tradeify": True,
    # explicit bot bans (kept for clarity; any firm not True here is blocked anyway)
    "apex": False, "take profit trader": False, "tpt": False, "earn2trade": False,
}

_MONTH = "FGHJKMNQUVXZ"


def futures_root(symbol) -> str:
    """'CM.ESU6'->'ES', 'MNQU6'->'MNQ', 'EURUSD'->'EURUSD'. Mirrors the Swift resolver."""
    s = "".join(ch for ch in str(symbol or "").upper().split(".")[-1].lstrip("/@") if ch.isalnum())
    if len(s) >= 3 and s[-1].isdigit():
        i = len(s) - 1
        d = 0
        while i >= 0 and s[i].isdigit():
            i -= 1
            d += 1
        if 1 <= d <= 2 and i >= 1 and s[i] in _MONTH:
            return s[:i]
    return s


def point_value(symbol):
    """$/point for a symbol, or None when unknown (=> no size => order rejected)."""
    return POINT_VALUES.get(futures_root(symbol))


def kill_sentinel_path(store_dir: str) -> str:
    return os.path.join(store_dir or ".", "EXEC.KILL")


class ExecutionDisabled(Exception):
    """Raised by a live adapter method when execution is not authorized — a second, independent
    layer behind precheck so a live order is impossible even if precheck were somehow bypassed."""


class OrderIntent:
    """A bracket order the engine MIGHT place. is_automated is always True for engine-driven orders."""
    __slots__ = ("symbol", "direction", "entry", "stop", "target", "engine",
                 "client_order_id", "is_automated", "size")

    def __init__(self, symbol, direction, entry, stop, target, engine, client_order_id):
        self.symbol = symbol
        self.direction = direction            # "long" | "short"
        self.entry = float(entry)
        self.stop = None if stop is None else float(stop)
        self.target = None if target is None else float(target)
        self.engine = engine
        self.client_order_id = client_order_id
        self.is_automated = True
        self.size = 0                         # filled in by sizing (0 until precheck sizes it)

    @property
    def risk_points(self):
        return None if self.stop is None else abs(self.entry - self.stop)


class Decision:
    """precheck result. route ∈ {"blocked","paper","live"}; a broker order happens only on 'live'."""
    __slots__ = ("route", "reason", "size")

    def __init__(self, route, reason, size=0):
        self.route = route
        self.reason = reason
        self.size = size

    @property
    def allow_live(self):
        return self.route == "live"


# --- broker adapters --------------------------------------------------------------------------
class BrokerAdapter:
    name = "base"

    def place_bracket(self, intent: OrderIntent) -> dict:
        raise NotImplementedError

    def flatten_all(self) -> bool:
        raise NotImplementedError


class DisarmedExecutor:
    """The default. A pure no-op — receives fires and does nothing, contacts no broker. Capture falls
    back to this if the engine can't be constructed, so execution is impossible by default."""

    def on_fire(self, *a, **k):
        return Decision("blocked", "execution disabled (disarmed)")

    def flatten_all(self):
        return True


class PaperAdapter(BrokerAdapter):
    """Default simulated-fill adapter. Books a CONSERVATIVE fill at the signal's entry, marks it
    sim=True, and contacts NO broker. Honest: it never books a price the market didn't reach (it
    fills at the stated entry, the same level the signal is defined on)."""
    name = "paper"

    def __init__(self):
        self.placed = []

    def place_bracket(self, intent: OrderIntent) -> dict:
        rec = {"sim": True, "symbol": intent.symbol, "direction": intent.direction,
               "size": intent.size, "entry": intent.entry, "stop": intent.stop,
               "target": intent.target, "client_order_id": intent.client_order_id,
               "status": "paper_working"}
        self.placed.append(rec)
        return rec

    def flatten_all(self) -> bool:
        self.placed.clear()
        return True


# --- risk gate chain --------------------------------------------------------------------------
class RiskGateChain:
    """Enforced money gates. Every gate must pass; the first failure blocks the order with a reason.
    Reads live ledger values from `state` (injected; store-backed in production, fake in tests)."""

    @staticmethod
    def check(state, intent: OrderIntent, size: int) -> tuple[bool, str]:
        cfg = state.risk_config()
        # daily-loss halt: realized loss today + this order's full intended worst-case risk.
        acct = float(cfg.get("accountSize", 0) or 0)
        max_dd_loss = acct * float(cfg.get("maxDailyLossPct", 0) or 0) / 100.0
        provisional = (intent.risk_points or 0) * (point_value(intent.symbol) or 0) * size
        if max_dd_loss > 0 and (state.day_realized_loss() + provisional) > max_dd_loss:
            return False, f"daily-loss halt ({state.day_realized_loss():.0f}+{provisional:.0f} > {max_dd_loss:.0f})"
        # contract cap: pending + working + reconciled + this size.
        cap = int(cfg.get("execMaxContracts", 0) or 0)
        if cap > 0 and (state.open_contracts(intent.symbol) + size) > cap:
            return False, f"contract cap ({state.open_contracts(intent.symbol)}+{size} > {cap})"
        # drawdown guard vs the persisted real-equity high-water mark.
        max_dd = float(cfg.get("execMaxDrawdown", 0) or 0)
        if max_dd > 0 and (state.equity_hwm() - state.equity()) >= max_dd:
            return False, f"drawdown guard ({state.equity_hwm()-state.equity():.0f} >= {max_dd:.0f})"
        # max trades per day.
        maxt = int(cfg.get("maxTrades", 0) or 0)
        if maxt > 0 and state.trades_today() >= maxt:
            return False, f"max trades/day ({state.trades_today()} >= {maxt})"
        return True, ""


# --- the engine -------------------------------------------------------------------------------
class ExecutionEngine:
    """Reads ALL state from `state` (the store) each fire. `state` must provide:
        exec_flags()        -> {armed:bool, mode:str, kill:bool, firm:str, firmAck:bool,
                                confirmEachOrder:bool, broker:str}
        live_authorized()   -> bool   (creds present + account resolved + fresh OS-auth)
        order_confirmed(cid)-> bool
        risk_config()       -> dict
        day_realized_loss/open_contracts/equity/equity_hwm/trades_today (risk ledger)
        edge_ok(engine,symbol) -> bool   (TTL bypassed)
        has_open_position(engine,symbol,direction) -> bool
        already_fired(client_order_id) -> bool
        store_dir()         -> str
        record_decision(intent, decision)   (audit; never raises)
    """

    def __init__(self, state, paper=None, live=None, live_factory=None):
        self.state = state
        self.paper = paper or PaperAdapter()
        self.live = live                     # registered ONLY when live + creds resolved
        # live_factory(creds: dict, symbol: str) -> adapter | None. Called lazily when going live to
        # build the broker adapter from the buyer's OWN Keychain creds (auth + account resolve). It
        # places nothing — only precheck's live route (demo-validated + confirm + all gates) can.
        self.live_factory = live_factory
        self._locks: dict[str, threading.Lock] = {}
        self._locks_guard = threading.Lock()

    def ensure_live_registered(self, symbol):
        """Lazily build + register the live adapter from the buyer's Keychain creds the first time we
        need it in live mode. Fail-safe: any error leaves self.live None (=> live route blocked).
        Registration performs broker AUTH only — it can place no order."""
        if self.live is not None or self.live_factory is None:
            return
        try:
            creds = self.state.broker_creds()        # reads Keychain; None if absent
            if not creds:
                return
            self.live = self.live_factory(creds, symbol)
        except Exception as exc:  # noqa: BLE001 — never let registration raise into capture
            self.live = None
            try:
                log_fn = getattr(self.state, "log", None)
                if log_fn:
                    log_fn(f"live adapter registration failed (staying disarmed): {type(exc).__name__}")
            except Exception:  # noqa: BLE001
                pass

    def _sym_lock(self, symbol):
        with self._locks_guard:
            return self._locks.setdefault(futures_root(symbol), threading.Lock())

    def register_live(self, adapter):
        """Attach a live broker adapter (e.g. ProjectXExecAdapter). Called by the API only after
        the buyer supplied creds AND an account resolved. Until then self.live is None and the live
        route is impossible."""
        self.live = adapter

    def kill_tripped(self) -> bool:
        f = self.state.exec_flags()
        if f.get("kill"):
            return True
        try:
            return os.path.exists(kill_sentinel_path(self.state.store_dir()))
        except Exception:  # noqa: BLE001
            return True     # fail-closed: if we can't check the sentinel, treat as killed

    def _size(self, intent: OrderIntent) -> int:
        pv = point_value(intent.symbol)
        rp = intent.risk_points
        if pv is None or rp is None or rp <= 0:
            return 0
        cfg = self.state.risk_config()
        acct = float(cfg.get("accountSize", 0) or 0)
        risk_pct = float(cfg.get("riskPerTradePct", 0) or 0)
        if acct <= 0 or risk_pct <= 0:
            return 0
        return int((acct * risk_pct / 100.0) / (rp * pv))   # floor

    def precheck(self, intent: OrderIntent) -> Decision:
        """Fail-closed AND-chain. Any exception => blocked. Returns the route; a broker order is
        possible ONLY when route == 'live'."""
        try:
            f = self.state.exec_flags()
            # (1) kill clear — checked FIRST.
            if self.kill_tripped():
                return Decision("blocked", "kill switch tripped")
            # (2) armed (default off)
            if not f.get("armed"):
                return Decision("blocked", "not armed (default off)")
            # (0) per-firm ToS permission + acknowledgement
            firm = str(f.get("firm", "")).strip().lower()
            if not FIRM_AUTOMATION.get(firm, False) or not f.get("firmAck"):
                return Decision("blocked", f"firm '{firm or '—'}' not permitted for automation")
            # (7a) structural: target present (no naked bracket)
            if intent.target is None or intent.stop is None:
                return Decision("blocked", "no target/stop (no naked bracket)")
            # (7b) $/pt known => real size
            size = self._size(intent)
            if size <= 0:
                return Decision("blocked", "no size ($/pt unknown or risk config unset)")
            # (7c) idempotency / single-flight
            if self.state.already_fired(intent.client_order_id):
                return Decision("blocked", "duplicate client_order_id (single-flight)")
            if self.state.has_open_position(intent.engine, intent.symbol, intent.direction):
                return Decision("blocked", "open position already exists (no double bracket)")
            # (5) risk gates (per-symbol submit lock so concurrent fires can't both pass the cap)
            with self._sym_lock(intent.symbol):
                ok, why = RiskGateChain.check(self.state, intent, size)
                if not ok:
                    return Decision("blocked", why, size)
                # (6) edge re-assert (cache bypassed)
                if not self.state.edge_ok(intent.engine, intent.symbol):
                    return Decision("blocked", "edge not proven (re-asserted)", size)
                # (3) mode: paper unless explicitly live
                if f.get("mode") != "live":
                    return Decision("paper", "paper mode", size)
                # lazily build the live adapter from the buyer's own Keychain creds (auth only)
                self.ensure_live_registered(intent.symbol)
                # (4) live authorization: creds + account + fresh OS-auth + live adapter registered
                if not self.state.live_authorized() or self.live is None:
                    return Decision("blocked", "live not authorized (creds/account/OS-auth)", size)
                # (4b) DEMO-PROVEN gate: a funded/real account is ineligible until the buyer has
                # validated the full live path on a broker DEMO/eval account. Default False; the
                # order code is built against the documented API but is UNPROVEN against the real
                # endpoint until this is set — so it can never touch real funds first.
                if not self.state.demo_validated():
                    return Decision("blocked", "live path not demo-validated yet (run a demo first)", size)
                # Per-order human confirm is MANDATORY for every live order. The ONLY firms permitted
                # to go live are human-in-loop (FIRM_AUTOMATION), so confirm is non-disableable — the
                # engine does NOT consult the config flag here, so a /api/config POST flipping
                # execConfirmEachOrder can never relax the live path. (The flag may only make paper
                # stricter; it can never weaken a live order.)
                if not self.state.order_confirmed(intent.client_order_id):
                    return Decision("blocked", "awaiting per-order confirmation", size)
                return Decision("live", "live authorized", size)
        except Exception as exc:  # noqa: BLE001 — fail closed
            return Decision("blocked", f"precheck error (fail-closed): {type(exc).__name__}")

    def on_fire(self, symbol, direction, entry, stop, target, engine, bar_key) -> Decision:
        """Called by capture immediately after a gate-passing fire is recorded. Best-effort: never
        raises into the capture loop. Places a PAPER or (only if fully authorized) LIVE bracket."""
        cid = f"{engine}:{futures_root(symbol)}:{direction}:{bar_key}"   # deterministic single-flight
        intent = OrderIntent(symbol, direction, entry, stop, target, engine, cid)
        d = self.precheck(intent)
        intent.size = d.size
        try:
            self.state.record_decision(intent, d)
        except Exception:  # noqa: BLE001
            pass
        if d.route == "paper":
            self.paper.place_bracket(intent)
        elif d.route == "live":
            # Double gate: the live adapter independently re-checks kill + authorization and raises
            # ExecutionDisabled otherwise, so a live order is impossible even if precheck were wrong.
            if self.kill_tripped():
                return Decision("blocked", "kill tripped pre-send")
            self.live.place_bracket(intent)
        return d

    def flatten_all(self) -> bool:
        """Master halt action: flatten everything the active adapter knows about."""
        ok = self.paper.flatten_all()
        if self.live is not None:
            try:
                ok = self.live.flatten_all() and ok
            except Exception:  # noqa: BLE001
                ok = False
        return ok


def _projectx_live_factory(creds, symbol):
    """Build a ProjectXExecAdapter from the buyer's OWN creds: auth (loginKey) -> resolve a tradable
    account -> resolve the contract -> adapter. Network — runs ONLY when going live. Returns None on
    any failure (=> live route stays blocked). Places NO order. UNPROVEN until demo-validated.
    Account/contract field shapes are per the docs; the demo_validated gate blocks funded use until
    the buyer proves this end-to-end on an eval account."""
    try:
        import bltd_projectx as PX
        host = PX.DEFAULT_API_HOST
        _, login, _ = PX._post_json(f"https://{host}/api/Auth/loginKey",
                                    {"userName": creds.get("username"), "apiKey": creds.get("apiKey")})
        token = PX.token_from_login(login)
        if not token:
            return None
        _, accts, _ = PX._post_json(f"https://{host}/api/Account/search",
                                    {"onlyActiveAccounts": True}, token=token)
        acct = PX.pick_tradable_account(accts, creds.get("account"))
        if not acct:
            return None
        root = futures_root(symbol)
        _, cons, _ = PX._post_json(f"https://{host}/api/Contract/search",
                                   {"searchText": root, "live": False}, token=token)
        contract = PX.pick_contract(cons, symbol)
        if not contract or not contract.get("id"):
            return None
        return PX.ProjectXExecAdapter(token, acct["id"], contract["id"], symbol, api_host=host)
    except Exception:  # noqa: BLE001
        return None


def make_executor(store):
    """Construct the store-backed engine, or a DisarmedExecutor no-op on ANY error (fail-safe:
    execution must be impossible if the engine can't be built correctly). The live adapter is built
    lazily from Keychain creds only when the buyer goes live (and stays blocked behind every gate)."""
    try:
        return ExecutionEngine(StoreExecState(store), live_factory=_projectx_live_factory)
    except Exception:  # noqa: BLE001
        return DisarmedExecutor()


class StoreExecState:
    """Adapts the product SQLite store to the engine's state interface. Thin + defensive; all the
    enforcement lives in the engine/RiskGateChain. (Store helpers are added in bltd_store.py.)"""

    def __init__(self, store):
        self.store = store

    def exec_flags(self):
        return self.store.exec_flags()

    def live_authorized(self):
        return bool(self.store.exec_live_authorized())

    def demo_validated(self):
        return bool(self.store.exec_demo_validated())

    def broker_creds(self):
        """Read the buyer's OWN broker API key from the macOS Keychain (the Swift app stored it,
        ThisDeviceOnly). The secret NEVER lives in config/files/logs/the store — only Keychain. The
        username/account label (non-secret) live in exec_kv. Returns None if no key is present."""
        import subprocess
        f = self.store.exec_flags()
        broker = (f.get("broker") or "projectx").strip().lower()
        if broker != "projectx":
            return None
        svc = f"com.blacklabel.trading.exec.{broker}"
        try:
            r = subprocess.run(["security", "find-generic-password", "-s", svc, "-w"],
                               capture_output=True, text=True, timeout=5)
        except Exception:  # noqa: BLE001
            return None
        key = (r.stdout or "").strip()
        if r.returncode != 0 or not key:
            return None
        return {"broker": broker, "apiKey": key,
                "username": self.store._exec_kv("execUser"),
                "account": self.store._exec_kv("execAccount")}

    def log(self, msg):
        try:
            import logging
            logging.getLogger("bltd.exec").info("%s", msg)
        except Exception:  # noqa: BLE001
            pass

    def order_confirmed(self, cid):
        return bool(self.store.exec_order_confirmed(cid))

    def risk_config(self):
        return self.store.config()

    def day_realized_loss(self):
        return float(self.store.exec_day_realized_loss())

    def open_contracts(self, symbol):
        return int(self.store.exec_open_contracts(symbol))

    def equity(self):
        return float(self.store.exec_equity())

    def equity_hwm(self):
        return float(self.store.exec_equity_hwm())

    def trades_today(self):
        return int(self.store.exec_trades_today())

    def edge_ok(self, engine, symbol):
        return bool(self.store.edge_ok(engine, symbol, bypass_cache=True).get("ok"))

    def has_open_position(self, engine, symbol, direction):
        return bool(self.store.exec_has_open_position(engine, symbol, direction))

    def already_fired(self, cid):
        return bool(self.store.exec_already_fired(cid))

    def store_dir(self):
        import os as _os
        return _os.path.dirname(getattr(self.store, "path", "") or ".") or "."

    def record_decision(self, intent, decision):
        self.store.exec_record_decision(
            {"symbol": intent.symbol, "direction": intent.direction, "engine": intent.engine,
             "size": decision.size, "route": decision.route, "reason": decision.reason,
             "client_order_id": intent.client_order_id, "is_automated": intent.is_automated})
