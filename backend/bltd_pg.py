"""OPTIONAL Postgres adapter — DEV OVERRIDE ONLY, never the product default.

This module is imported by bltd_api.py ONLY when BLTD_DSN is explicitly set (e.g. a developer
pointing the backend at a legacy Postgres `bars`/`fires`/`wc_live` store for comparison). It is
NOT part of the shipped self-contained product path: the default store is the stdlib SQLite
own-store in bltd_store.py. If `psycopg` is not installed, importing this module raises, and
bltd_api falls back to the own store — so a buyer machine with no Postgres driver still runs.

It mirrors the read surface of bltd_store.Store so the API code is identical for both stores.
Read-only; never writes; the writers (capture/engines) only ever target the own store.
"""
from __future__ import annotations

import time

import psycopg  # noqa: F401 — absence here is the signal to fall back to the own store


class PgStore:
    """Read-only adapter over a legacy Postgres trading store (dev override)."""

    def __init__(self, dsn: str):
        self.dsn = dsn
        self.path = f"postgres:{dsn}"  # for the /health 'store' label
        # fail fast so bltd_api can fall back if the DSN is unreachable
        with psycopg.connect(dsn, autocommit=True, connect_timeout=3) as cx:
            cx.execute("SELECT 1")

    def _q(self, sql, params=()):
        try:
            with psycopg.connect(self.dsn, autocommit=True, connect_timeout=3) as cx:
                return list(cx.execute(sql, params).fetchall())
        except Exception:  # noqa: BLE001 — cold/unreachable DB -> honest empty
            return []

    def online(self) -> bool:
        return self._q("SELECT 1") == [(1,)]

    def meta(self) -> dict:
        today = self._q("SELECT count(*) FROM fires WHERE NOT synthetic AND ts::date = current_date")
        live = self._q("SELECT 1 FROM bars WHERE ts_recorded > now() - interval '10 minutes' LIMIT 1")
        return {"online": self.online(), "feedLive": bool(live),
                "signalsToday": (today[0][0] if today else 0)}

    def symbols(self) -> dict:
        bt = [r[0] for r in self._q("SELECT symbol FROM bars GROUP BY symbol HAVING count(*) >= 40 ORDER BY symbol")]
        live = [r[0] for r in self._q("SELECT DISTINCT symbol FROM bars WHERE ts_recorded > now() - interval '10 minutes'")]
        ticks = [r[0] for r in self._q("SELECT symbol FROM wc_live WHERE recorded > now() - interval '30 seconds' ORDER BY symbol")]
        busiest = self._q("SELECT symbol FROM bars GROUP BY symbol ORDER BY count(*) DESC LIMIT 1")
        return {"backtestable": bt, "live": live, "liveTicks": ticks,
                "busiest": busiest[0][0] if busiest else None}

    def bars(self, symbol: str, limit: int, newest: bool) -> dict:
        if not symbol:
            return {"symbol": symbol, "bars": []}
        if newest:
            rows = self._q("SELECT o::float8,h::float8,l::float8,c::float8,extract(epoch from ts)::float8 FROM ("
                           "SELECT o,h,l,c,ts FROM bars WHERE symbol=%s ORDER BY ts DESC, id DESC LIMIT %s) q "
                           "ORDER BY ts ASC", (symbol, limit))
        else:
            rows = self._q("SELECT o::float8,h::float8,l::float8,c::float8,extract(epoch from ts)::float8 "
                           "FROM bars WHERE symbol=%s ORDER BY ts, id LIMIT %s", (symbol, limit))
        return {"symbol": symbol, "bars": [[r[0], r[1], r[2], r[3], r[4]] for r in rows]}

    def live_price(self, symbol: str) -> dict:
        if not symbol:
            return {"gated": True}
        # Recency-gated (mirrors the SQLite store): a stale row is never served as the live line.
        rows = self._q("SELECT price::float8, extract(epoch from recorded)::float8 FROM wc_live "
                       "WHERE symbol=%s AND recorded > now() - interval '30 seconds'", (symbol,))
        if not rows:
            return {"symbol": symbol, "gated": True}
        return {"symbol": symbol, "price": rows[0][0], "ts": rows[0][1]}

    def latest_fire(self) -> dict:
        rows = self._q("SELECT id, engine, direction, entry::float8, symbol, stop::float8, target::float8, "
                       "rationale, outcome, pnl::float8, to_char(ts,'YYYY-MM-DD HH24:MI:SS') "
                       "FROM fires WHERE NOT synthetic ORDER BY id DESC LIMIT 1")
        if not rows:
            return {"fire": None}
        r = rows[0]
        return {"fire": {"id": r[0], "engine": r[1], "direction": r[2], "entry": r[3], "symbol": r[4],
                         "stop": r[5], "target": r[6], "rationale": r[7], "outcome": r[8],
                         "pnl": r[9], "ts": r[10]}}
