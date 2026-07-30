# Trading — MCP server

Read-only, signals-only MCP access to the Trading app's own local backend
(`backend/bltd_api.py`, serving `127.0.0.1:8793`).

Three tools: `trading__get_signals`, `trading__get_bars`, `trading__run_backtest`.

---

## mcpServers config stanza

Paste this into your MCP client's config (`claude_desktop_config.json`, `.mcp.json`, or
`claude mcp add-json trading '<the object below>'`):

```json
{
  "mcpServers": {
    "trading": {
      "command": "node",
      "args": ["/Users/michaelbarber/BlackLabelTrading/mcp/server.mjs"],
      "env": {
        "BLTD_PORT": "8793"
      }
    }
  }
}
```

Optional `env` overrides — all have working defaults, none is a credential:

| Variable | Default | Purpose |
|---|---|---|
| `BLTD_PORT` | `8793` | Port the backend listens on (loopback only). |
| `BLTD_SUPPORT_DIR` | `~/Library/Application Support/Black Label Trading` | Where the backend keeps its store, token file, and evaluator heartbeat. |
| `BLTD_TOKEN_FILE` | `$BLTD_SUPPORT_DIR/webhook.token` | The per-launch bearer token file the backend launcher writes. |
| `BLTD_STORE` | `$BLTD_SUPPORT_DIR/trading.sqlite3` | Store path, reported back in `data_recency.backend.store_path`. |
| `MCP_LOG_LEVEL` | `info` | `silent` \| `error` \| `warn` \| `info` \| `debug`. Logs go to stderr, redacted. |

---

## Start the backend first

The backend is not running by default and the bearer token is **per launch**. Start it with
its own launcher, which mints/reuses the token file this server reads:

```sh
cd /Users/michaelbarber/BlackLabelTrading/backend
BLTD_PYTHON=/usr/bin/python3 ./launch-backend.sh --bg
# -> backend healthy (pid NNNNN) → http://127.0.0.1:8793
```

`--bg` is idempotent: if a backend matching this build and capability contract is already
healthy it reuses it and starts nothing.

`BLTD_PYTHON` is only needed when running from the repo. The shipped `.app` carries its own
CPython at `Contents/Resources/backend/python3` and the launcher finds it automatically.

If the backend is restarted, the token file is rewritten. This server re-reads the file on
every call, so no MCP restart is needed.

---

## Tools

### `trading__get_signals`

Reads the signal journal.

- `mode` — `stored` (default) reads recorded fires from `/api/fires` plus the latest stored
  fire from `/api/latest`. `fresh` recomputes the engine × symbol screen via `/api/screen`.
- `limit` — 1–1000, default 50 (stored mode only).
- `symbol`, `engine` — optional filters. `engine` is one of
  `meanrev`, `breakout`, `momentum`, `structure`, `regime`, `channel`, `context_b`.
- A `symbol` the store has never held is an **error** (`SYMBOL_NOT_IN_STORE`) in **both** modes.
  `/api/screen` will happily screen an unknown symbol and answer with one zeroed
  `warming (0 bars, arms at 22)` row per engine; that is refused rather than returned, because a
  row count of 7 with `winRate: 0` reads like a computed screen for a real instrument.

`mode: "fresh"` is **compute**-fresh, not **data**-fresh: it recomputes over the bars already
in the store. The response says so, and `data_recency` states how old those bars are.

### `trading__get_bars`

Reads captured OHLC bars for one symbol.

- `symbol` — optional. Omitted, the store's busiest symbol is used and reported back in
  `symbol_resolution`. A symbol with no bars is an **error**, not an empty series.
- `limit` — 1–5000, default 100.
- `window` — `recent` (default) returns the **newest** n bars via `/api/recent`.
  `history_start` returns the **oldest** n bars via `/api/bars`, which is the backend's
  backtest feed order. `history_start` with a small limit gives you the beginning of the
  capture, not today. Both are labelled in `window_semantics` on the response.

Rows are returned as objects: `{ ts, utc, open, high, low, close, volume, delta }`.

### `trading__run_backtest`

Runs the shipped prover for one engine on one symbol over the bars in the store.

- `engine` — default `meanrev`, from the list above.
- `symbol` — optional, same resolution rule as `get_bars`.
- `start`, `end` — optional epoch-seconds. Omitted = the full captured span. `start > end` is
  refused (`WINDOW_INVERTED`); an `end` in the future is clamped to the newest stored bar for
  `newest_data_used_utc`, so the reported data age can never go negative.
- `folds` — 1–8, default 1 (the shipped prover clamps folds at 8, so a larger request would be
  reported as a split that never happened).

The response carries the prover's own output verbatim under `report` (per-fold `trades` /
`wins` / `losses` / `maxDrawdownR` / `pEdge` / `proven`, plus `prover_sha`), a
`backtest_window` block naming the newest bar the run could see, and `data_recency`.
Zero bars for the symbol is an error, not a zero-trade result. So is a requested **window** with
too few bars to arm the prover: the backend answers `available: false` with a reason, and that is
raised as `BACKTEST_NOT_AVAILABLE` rather than wrapped in `status: "ok"` with `whole: null`.

---

## Read-only enforcement (in this process, not delegated)

`server.mjs` refuses non-GET methods and non-allowlisted paths **before a socket is opened**,
independently of what the backend accepts:

- `ALLOWED_METHODS` = `{ GET }`. Any `POST` / `PUT` / `DELETE` / `PATCH` throws
  `METHOD_NOT_ALLOWED` with "Nothing was sent."
- `ALLOWED_GET_PATHS` — the only readable paths: `/api/fires`, `/api/latest`, `/api/screen`,
  `/api/bars`, `/api/recent`, `/api/backtest/run`, `/api/backtest/bounds`, `/api/symbols`,
  `/api/meta`, `/api/journal`, `/health`.
- `DENIED_PATHS` — refused with a stated reason, including
  **`/api/backtest/farm`** (forks a worker per CPU core — deliberately not exposed),
  `/webhook/feed`, `/api/config`, `/api/feed/connect`, `/api/feed/disconnect`,
  `/api/alerts/send`, `/api/alerts/test`, `/auth/signin`, `/api/webhook/info`
  (that one returns the raw bearer token in its body), and `/api/capture`
  (probes the local browser debug port and enumerates browser tabs).
- Redirects are never followed — a 3xx is raised as `HTTP_REDIRECT_REFUSED`.

Verify the posture without starting stdio:

```sh
node --input-type=module -e '
import { guardRequest } from "/Users/michaelbarber/BlackLabelTrading/mcp/server.mjs";
for (const [m, p] of [["POST","/api/fires"],["GET","/api/backtest/farm"],["GET","/api/fires"]]) {
  try { console.log("ALLOW", m, p, JSON.stringify(guardRequest(m, p))); }
  catch (e) { console.log("REFUSE", m, p, e.code); }
}'
```

No tool can place, modify, or route an order. The backend itself reports
`capabilities: { signals: true, execution: false, optimizerCompute: false }`, and that
contract is echoed in every `data_recency.backend` block.

---

## Data honesty

**Every** response carries a `data_recency` block built from live reads, never from
assumptions. It contains:

- `verdict` — `CURRENT` | `STALE` | `NO_DATA`.
- `bars.newest_bar_utc` / `newest_bar_age_days`, and per-symbol first/last/count.
- `store.symbols_with_bars` and `store.symbols_live_now` (empty = nothing is being captured).
- `signal_journal.graded` vs `ungraded_null_outcome`, and the newest fire's age.
- `evaluator` — the heartbeat file's real mtime and whether the daemon is alive. A live
  heartbeat does **not** imply grading: grading only happens for symbols live right now.
- `warnings[]` — plain-language strings generated from the observed numbers.

State of this machine's store when this server was built and exercised
(2026-07-29, read through the tools themselves):

| Fact | Value |
|---|---|
| Symbols with bars | `CM.MNQU6` — one, only |
| Bars | 29,449, spanning `2026-07-07T09:59:20Z` → `2026-07-08T23:59:59Z` |
| Newest bar age | 20.71 days — `verdict: STALE` |
| Symbols live now | none |
| Recorded fires | 31, **all 31 with `outcome: null`**, 0 graded |
| Newest fire | `2026-07-17T16:04:03Z` |

Nothing in these tools converts that into a win rate, a hit rate, or a P&L figure, because
nothing in the journal has been graded. `grading_note` says so explicitly on every response.

Failures never degrade into empty results:

- The backend answers some handler exceptions with **HTTP 200 and an `{"error": …}` body**.
  This server raises that as `BACKEND_REPORTED_ERROR` rather than passing an empty payload
  through as data.
- A missing/mismatched token → `TOKEN_UNAVAILABLE` / `HTTP_401` with the file path and fix.
- Backend down → `BACKEND_UNREACHABLE` naming the launcher command.
- A response missing its expected array → `*_SHAPE_UNEXPECTED`, never a silent `[]`.

An honest zero (a query that ran and matched nothing) comes back as `status: "empty"` with a
`reason` — and when the zero is caused by filtering on a symbol the store has never held, the
reason says exactly that.

---

## Files

| File | Role |
|---|---|
| `server.mjs` | The MCP server. |
| `mcp-kit.mjs` | Vendored MCP stdio kit (zero npm dependencies). Copied in, not imported across repos, and not modified — SHA-256 `cab039675ac638923e02d16734e19bd076111f6ff453e6419aa2c7ef0cf30bca`. |

Requires Node 18+ (developed and exercised on Node v25.9.0). No `npm install`.
