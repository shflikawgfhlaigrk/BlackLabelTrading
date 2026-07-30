#!/usr/bin/env node
// Trading — MCP stdio server.
//
// SIGNALS-ONLY, READ-ONLY. This server exposes the Trading app's own local backend
// (bltd_api.py on 127.0.0.1:8793) to an MCP client. It can read the signal journal,
// read captured bars, and re-run the shipped backtest prover. It cannot place, modify,
// or route an order, and it cannot write anything into the local store.
//
// The read-only posture is enforced HERE, in this process, and does not depend on the
// backend behaving: see ALLOWED_METHODS / ALLOWED_GET_PATHS / DENIED_PATHS below. Every
// outbound call goes through httpRequest(), which refuses any method other than GET and
// any path not on the allowlist BEFORE a socket is opened.
//
// Run:  node mcp/server.mjs      (speaks JSON-RPC 2.0 over stdio)

import http from "node:http";
import { statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { createServer, ToolError, listResult, loadSecret } from "./mcp-kit.mjs";

// ---------------------------------------------------------------------------
// Runtime configuration — every value is an env override with a real default.
// Nothing here is a credential; the bearer token is read from disk per call.
// ---------------------------------------------------------------------------

const SERVER_NAME = "trading";
const SERVER_VERSION = "1.0.0";

const HOST = "127.0.0.1";
const PORT = Number.parseInt(process.env.BLTD_PORT || "8793", 10);
const BASE_URL = `http://${HOST}:${PORT}`;

// The backend launcher (backend/launch-backend.sh) mints a per-launch bearer token and
// writes it to $BLTD_SUPPORT_DIR/webhook.token, exporting BLTD_TOKEN_FILE to the API
// process. Reading any other file means every call 401s, so resolve the same one.
const SUPPORT_DIR =
  process.env.BLTD_SUPPORT_DIR || join(homedir(), "Library", "Application Support", "Black Label Trading");
const TOKEN_FILE = process.env.BLTD_TOKEN_FILE || join(SUPPORT_DIR, "webhook.token");
const STORE_PATH = process.env.BLTD_STORE || join(SUPPORT_DIR, "trading.sqlite3");
const HEARTBEAT_FILE = join(SUPPORT_DIR, "evaluator.heartbeat");

const ENGINES = ["meanrev", "breakout", "momentum", "structure", "regime", "channel", "context_b"];

// ---------------------------------------------------------------------------
// READ-ONLY ENFORCEMENT (local, independent of the backend)
// ---------------------------------------------------------------------------

/** The only HTTP method this process will ever emit. */
const ALLOWED_METHODS = Object.freeze(new Set(["GET"]));

/** Every path this process may read. Anything absent is refused, not attempted. */
const ALLOWED_GET_PATHS = Object.freeze(
  new Set([
    "/api/fires", // signal journal
    "/api/latest", // latest stored fire
    "/api/screen", // compute-fresh engine x symbol scan
    "/api/bars", // captured bars, oldest-first (backtest feed order)
    "/api/recent", // captured bars, newest N
    "/api/backtest/run", // shipped prover, one engine x symbol
    "/api/backtest/bounds", // real first/last bar timestamps
    "/api/symbols", // symbol catalog (recency context)
    "/api/meta", // online / feedLive / signalsToday (recency context)
    "/api/journal", // graded-fire counts (recency context)
    "/health", // backend identity + capability contract
  ])
);

/**
 * Paths this server refuses on purpose, with the reason surfaced to the caller.
 * These are never reachable through a tool — the map exists so a refusal is explained
 * rather than looking like a missing feature.
 */
const DENIED_PATHS = Object.freeze(
  new Map([
    ["/api/backtest/farm", "forks a worker process per CPU core; this server never starts a compute farm"],
    ["/webhook/feed", "writes captured ticks/bars into the local store (mutating)"],
    ["/api/webhook/feed", "writes captured ticks/bars into the local store (mutating)"],
    ["/api/webhook/info", "returns the raw bearer token in its body"],
    ["/auth/signin", "credential exchange; this server reads the launcher's token file instead"],
    ["/api/config", "writes buyer configuration"],
    ["/api/connect", "mutates connection state"],
    ["/api/feed/connect", "mutates feed state"],
    ["/api/feed/disconnect", "mutates feed state"],
    ["/api/alerts/test", "sends an outbound alert"],
    ["/api/alerts/send", "sends an outbound alert"],
    ["/api/capture", "probes the local browser debug port and enumerates browser tabs"],
  ])
);

/** Refuse anything that is not a GET, before a socket is opened. */
export function assertMethodAllowed(method) {
  const m = String(method || "").toUpperCase();
  if (!ALLOWED_METHODS.has(m)) {
    throw new ToolError(
      `Refused ${m || "(empty)"}: this server is GET-only and emits no ${m || "non-GET"} request. ` +
        `Allowed methods: ${[...ALLOWED_METHODS].join(", ")}. Nothing was sent.`,
      { code: "METHOD_NOT_ALLOWED", details: { requested_method: m, allowed_methods: [...ALLOWED_METHODS] } }
    );
  }
  return m;
}

/** Refuse any path that is not on the read allowlist, before a socket is opened. */
export function assertPathAllowed(path) {
  const p = String(path || "");
  if (DENIED_PATHS.has(p)) {
    throw new ToolError(
      `Refused ${p}: explicitly denied by this server because it ${DENIED_PATHS.get(p)}. Nothing was sent.`,
      { code: "PATH_DENIED", details: { path: p, reason: DENIED_PATHS.get(p) } }
    );
  }
  if (!ALLOWED_GET_PATHS.has(p)) {
    throw new ToolError(
      `Refused ${p}: not on this server's read allowlist. Allowed: ${[...ALLOWED_GET_PATHS].join(", ")}. Nothing was sent.`,
      { code: "PATH_NOT_ALLOWED", details: { path: p, allowed_paths: [...ALLOWED_GET_PATHS] } }
    );
  }
  return p;
}

/** Both guards together. Exported so the posture can be tested without stdio. */
export function guardRequest(method, path) {
  return { method: assertMethodAllowed(method), path: assertPathAllowed(path) };
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

function bearerToken() {
  // Read at call time so a relaunch (new per-launch token) is picked up without a restart.
  // loadSecret registers the value with the kit's redactor: it can never reach a log line.
  try {
    return loadSecret(TOKEN_FILE);
  } catch (err) {
    // Report the errno separately from the path: the kit's redactor scrubs anything following a
    // "…token:" fragment, which would otherwise blank out the very reason the read failed.
    let why = "unreadable";
    try {
      statSync(TOKEN_FILE);
      why = "present but empty or unreadable";
    } catch (statErr) {
      why = statErr?.code || "unreadable";
    }
    throw new ToolError(
      `Cannot read the backend's per-launch bearer credential (${why}). The backend writes it when it starts ` +
        `(backend/launch-backend.sh); without it every /api/* call returns 401. Expected file — ${TOKEN_FILE}`,
      { code: "TOKEN_UNAVAILABLE" }
    );
  }
}

/**
 * Perform one guarded request. Method is pinned to GET by assertMethodAllowed, redirects
 * are never followed, and a 200 carrying an {"error": ...} body is raised as an error —
 * the backend answers some failures with HTTP 200, and letting that through would look
 * like a successful empty read.
 */
async function httpRequest({ method = "GET", path, params = {}, timeoutMs = 60_000, signal } = {}) {
  const guarded = guardRequest(method, path);
  const search = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === null || v === "") continue;
    search.set(k, String(v));
  }
  const qs = search.toString();
  const fullPath = qs ? `${guarded.path}?${qs}` : guarded.path;
  const auth = guarded.path === "/health" ? null : bearerToken();

  const body = await new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: HOST,
        port: PORT,
        path: fullPath,
        method: guarded.method, // pinned GET; never taken from caller input
        headers: {
          Accept: "application/json",
          Host: `${HOST}:${PORT}`, // backend enforces a loopback Host allowlist
          ...(auth ? { Authorization: `Bearer ${auth}` } : {}),
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          if (res.statusCode >= 300 && res.statusCode < 400) {
            reject(
              new ToolError(
                `${fullPath} returned HTTP ${res.statusCode} (redirect). This server never follows redirects. No data was read.`,
                { code: "HTTP_REDIRECT_REFUSED", details: { status: res.statusCode, location: res.headers?.location } }
              )
            );
            return;
          }
          if (res.statusCode !== 200) {
            reject(
              new ToolError(
                `${guarded.path} returned HTTP ${res.statusCode} from ${BASE_URL}. ` +
                  (res.statusCode === 401
                    ? `The bearer token in ${TOKEN_FILE} does not match the running backend's per-launch token — restart the backend or point BLTD_TOKEN_FILE at the file it actually wrote.`
                    : `Body: ${text.slice(0, 400)}`),
                { code: `HTTP_${res.statusCode}`, details: { status: res.statusCode, path: guarded.path } }
              )
            );
            return;
          }
          let parsed;
          try {
            parsed = JSON.parse(text);
          } catch (err) {
            reject(
              new ToolError(`${guarded.path} returned a 200 that is not JSON: ${err?.message}. First 200 bytes: ${text.slice(0, 200)}`, {
                code: "BAD_JSON",
              })
            );
            return;
          }
          // The backend catches handler exceptions and answers 200 {"error": "..."}.
          // Treating that as data would turn a failure into a clean-looking result.
          if (parsed && typeof parsed === "object" && !Array.isArray(parsed) && typeof parsed.error === "string") {
            reject(
              new ToolError(
                `${guarded.path} answered HTTP 200 but its body reports a backend failure: ${parsed.error}. ` +
                  `No usable data was returned; this is an error, not an empty result.`,
                { code: "BACKEND_REPORTED_ERROR", details: { path: guarded.path, backend_error: parsed.error } }
              )
            );
            return;
          }
          resolve(parsed);
        });
      }
    );
    req.on("error", (err) =>
      reject(
        new ToolError(
          `Cannot reach the Trading backend at ${BASE_URL}${guarded.path}: ${err?.code || err?.message}. ` +
            `Start it with backend/launch-backend.sh --bg (it serves 127.0.0.1:${PORT}).`,
          { code: "BACKEND_UNREACHABLE", cause: err }
        )
      )
    );
    req.setTimeout(timeoutMs, () => {
      req.destroy(new Error(`no response within ${timeoutMs}ms`));
    });
    if (signal) {
      if (signal.aborted) req.destroy(new Error("aborted"));
      else signal.addEventListener("abort", () => req.destroy(new Error("aborted")), { once: true });
    }
    req.end();
  });
  return body;
}

const apiGet = (path, params, opts = {}) => httpRequest({ method: "GET", path, params, ...opts });

// ---------------------------------------------------------------------------
// Recency — every tool must make staleness impossible to miss
// ---------------------------------------------------------------------------

const iso = (epochSeconds) =>
  Number.isFinite(epochSeconds) ? new Date(epochSeconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z") : null;
const days = (seconds) => Math.round((seconds / 86400) * 100) / 100;

function evaluatorHeartbeat() {
  try {
    const st = statSync(HEARTBEAT_FILE);
    const ageSeconds = Math.round((Date.now() - st.mtimeMs) / 1000);
    return {
      heartbeat_file: HEARTBEAT_FILE,
      exists: true,
      last_touched_utc: new Date(st.mtimeMs).toISOString().replace(/\.\d{3}Z$/, "Z"),
      age_seconds: ageSeconds,
      age_days: days(ageSeconds),
      // The backend treats a heartbeat older than 30s as "evaluator offline".
      evaluator_process_alive: ageSeconds < 30,
      note:
        "The evaluator runs in a separate capture daemon and touches this file each cycle (~8s). " +
        "A live heartbeat means the daemon is running; it does NOT mean signals are being graded — " +
        "grading only happens for symbols that are live right now (see store.symbols_live_now).",
    };
  } catch (err) {
    return {
      heartbeat_file: HEARTBEAT_FILE,
      exists: false,
      error: err?.code || String(err),
      evaluator_process_alive: false,
      note: "No heartbeat file: the evaluator daemon has never run against this store, or the store path differs.",
    };
  }
}

/**
 * Build the recency block from live backend reads. Every number here is observed, never
 * assumed. Throws if the backend cannot answer — a recency block that silently degrades
 * to "unknown" is exactly how stale data gets mistaken for current data.
 */
async function dataRecency({ signal, timeoutMs = 30_000 } = {}) {
  const nowSec = Math.floor(Date.now() / 1000);
  const [health, meta, symbols, journal] = await Promise.all([
    apiGet("/health", {}, { signal, timeoutMs }),
    apiGet("/api/meta", {}, { signal, timeoutMs }),
    apiGet("/api/symbols", {}, { signal, timeoutMs }),
    apiGet("/api/journal", {}, { signal, timeoutMs }),
  ]);

  const backtestable = Array.isArray(symbols?.backtestable) ? symbols.backtestable : [];
  const perSymbol = [];
  for (const sym of backtestable) {
    const b = await apiGet("/api/backtest/bounds", { symbol: sym }, { signal, timeoutMs });
    const lastTs = Number.isFinite(b?.lastTs) ? b.lastTs : null;
    perSymbol.push({
      symbol: sym,
      bar_count: b?.count ?? 0,
      first_bar_ts: b?.firstTs ?? null,
      first_bar_utc: iso(b?.firstTs),
      last_bar_ts: lastTs,
      last_bar_utc: iso(lastTs),
      last_bar_age_seconds: lastTs === null ? null : nowSec - lastTs,
      last_bar_age_days: lastTs === null ? null : days(nowSec - lastTs),
    });
  }

  const newestBarTs = perSymbol.reduce((m, s) => (s.last_bar_ts !== null && s.last_bar_ts > m ? s.last_bar_ts : m), 0);
  const newestBarAge = newestBarTs ? nowSec - newestBarTs : null;
  const liveNow = Array.isArray(symbols?.live) ? symbols.live : [];
  const heartbeat = evaluatorHeartbeat();

  // The signal journal's grading state: fires the evaluator has resolved to target/stop.
  const fires = await apiGet("/api/fires", { limit: 1000 }, { signal, timeoutMs });
  const fireRows = Array.isArray(fires?.fires) ? fires.fires : [];
  const ungraded = fireRows.filter((f) => f?.outcome === null || f?.outcome === undefined).length;
  const newestFireTs = fireRows.reduce((m, f) => (Number.isFinite(f?.tsEpoch) && f.tsEpoch > m ? f.tsEpoch : m), 0);

  const warnings = [];
  if (newestBarAge === null) {
    warnings.push("NO BARS: the store holds no captured bars at all. Any backtest or screen over it is empty by construction.");
  } else if (newestBarAge > 86_400) {
    warnings.push(
      `STALE BARS: the newest captured bar is ${iso(newestBarTs)} — ${days(newestBarAge)} days old. ` +
        `This is NOT current market data. Do not read any signal, screen row or backtest here as a statement about today's market.`
    );
  }
  if (backtestable.length === 1) {
    warnings.push(
      `SINGLE-SYMBOL COVERAGE: the store holds bars for exactly one symbol (${backtestable[0]}). ` +
        `Nothing here generalizes to any other instrument.`
    );
  }
  if (liveNow.length === 0) {
    warnings.push(
      "NOTHING LIVE: no symbol has produced a bar inside the backend's live window, so no capture is happening and " +
        "the evaluator grades nothing even when its daemon is running."
    );
  }
  if (fireRows.length > 0 && (journal?.graded ?? 0) === 0) {
    warnings.push(
      `UNGRADED JOURNAL: ${fireRows.length} recorded signal(s), ${ungraded} with a NULL outcome and ${journal?.graded ?? 0} graded. ` +
        `No win/loss figure can be computed from this journal, and none is reported.`
    );
  }
  if (!heartbeat.evaluator_process_alive) {
    warnings.push(
      `EVALUATOR OFFLINE: the evaluator heartbeat was last touched ${heartbeat.last_touched_utc || "never"}` +
        (heartbeat.age_days === undefined ? "" : ` (${heartbeat.age_days} days ago)`) +
        ". Fires stop being recorded and stop being graded while it is down."
    );
  }

  return {
    observed_at_utc: iso(nowSec),
    verdict: newestBarAge === null ? "NO_DATA" : newestBarAge > 86_400 ? "STALE" : "CURRENT",
    backend: {
      base_url: BASE_URL,
      service: health?.service ?? null,
      build: health?.build ?? null,
      runtime_contract: health?.runtimeContract ?? null,
      capabilities: health?.capabilities ?? null,
      store_path: STORE_PATH,
    },
    store: {
      online: meta?.online ?? null,
      feed_live: meta?.feedLive ?? null,
      signals_today: meta?.signalsToday ?? null,
      symbols_with_bars: backtestable,
      symbols_live_now: liveNow,
      default_symbol: symbols?.busiest ?? null,
    },
    bars: {
      newest_bar_ts: newestBarTs || null,
      newest_bar_utc: newestBarTs ? iso(newestBarTs) : null,
      newest_bar_age_days: newestBarAge === null ? null : days(newestBarAge),
      per_symbol: perSymbol,
    },
    signal_journal: {
      recorded_fires: fireRows.length,
      graded: journal?.graded ?? 0,
      ungraded_null_outcome: ungraded,
      newest_fire_ts: newestFireTs || null,
      newest_fire_utc: newestFireTs ? iso(newestFireTs) : null,
      newest_fire_age_days: newestFireTs ? days(nowSec - newestFireTs) : null,
    },
    evaluator: heartbeat,
    warnings,
  };
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

async function resolveSymbol(requested, { signal, timeoutMs } = {}) {
  const symbols = await apiGet("/api/symbols", {}, { signal, timeoutMs });
  const backtestable = Array.isArray(symbols?.backtestable) ? symbols.backtestable : [];
  if (requested) {
    if (!backtestable.includes(requested)) {
      throw new ToolError(
        `Symbol "${requested}" has no bars in this store. Symbols that do: ${
          backtestable.length ? backtestable.join(", ") : "(none — the store is empty)"
        }. Refusing to return an empty series that would read as "no signal".`,
        { code: "SYMBOL_NOT_IN_STORE", details: { requested, available: backtestable } }
      );
    }
    return { symbol: requested, resolution: "caller-supplied" };
  }
  const fallback = symbols?.busiest || backtestable[0] || null;
  if (!fallback) {
    throw new ToolError(
      "No symbol was supplied and the store holds bars for no symbol at all, so there is nothing to read.",
      { code: "STORE_EMPTY" }
    );
  }
  return { symbol: fallback, resolution: `auto-selected (store's busiest symbol; store holds ${backtestable.length} symbol(s))` };
}

const clampInt = (value, { min, max, fallback }) => {
  const n = Number.parseInt(value, 10);
  if (!Number.isFinite(n)) return fallback;
  return Math.min(max, Math.max(min, n));
};

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

const tools = [
  {
    name: "trading__get_signals",
    description:
      "Read the Trading app's signal journal from its local backend. mode=stored (default) returns recorded fires " +
      "newest-first plus the latest stored fire; mode=fresh recomputes the engine x symbol screen from the stored bars. " +
      "Signals only: these are hypothetical entries/stops/targets, never orders, and nothing is routed anywhere. " +
      "Every response carries a data_recency block — read it: the underlying bars can be weeks old, in which case a " +
      "'fresh' recompute is fresh arithmetic over stale data, not a current market view.",
    inputSchema: {
      type: "object",
      properties: {
        mode: {
          type: "string",
          enum: ["stored", "fresh"],
          description: "stored = recorded fires from the journal; fresh = recompute the screen from stored bars.",
        },
        limit: { type: "integer", description: "Max journal rows to return (1-1000, default 50). Ignored when mode=fresh." },
        symbol: { type: "string", description: "Filter to one symbol. Omitted = all symbols in the store." },
        engine: {
          type: "string",
          enum: ENGINES,
          description: "Filter to one engine. Omitted = all engines.",
        },
      },
      required: [],
    },
    timeoutMs: 120_000,
    async handler({ mode = "stored", limit, symbol, engine } = {}, { signal } = {}) {
      const recency = await dataRecency({ signal });

      if (mode === "fresh") {
        // /api/screen happily screens a symbol this store has never held: it answers with one
        // "warming (0 bars, arms at 22)" row per engine, every metric zeroed. Passing that through
        // as status:"ok" with a row count would read as a computed result for a real instrument.
        // stored mode, get_bars and run_backtest all refuse an unknown symbol; fresh mode must too.
        if (symbol) {
          const known = [
            ...(recency.store?.symbols_with_bars || []),
            ...(recency.store?.symbols_live_now || []),
          ];
          const unique = [...new Set(known)];
          if (!unique.includes(symbol)) {
            throw new ToolError(
              `Symbol "${symbol}" is not in this store: it holds no bars for it and it is not live. ` +
                `Symbols it does hold bars for: ${unique.length ? unique.join(", ") : "(none — the store is empty)"}. ` +
                `Screening an unknown symbol returns one zero-metric "warming (0 bars)" row per engine, which reads ` +
                `like a computed screen for a real instrument. Refusing to return that.`,
              { code: "SYMBOL_NOT_IN_STORE", details: { requested: symbol, available: unique } }
            );
          }
        }
        const screen = await apiGet(
          "/api/screen",
          { symbols: symbol || "", engines: engine || "" },
          { signal, timeoutMs: 110_000 }
        );
        const rows = Array.isArray(screen?.rows) ? screen.rows : null;
        if (rows === null) {
          throw new ToolError(
            `/api/screen returned no "rows" array (got ${screen === null ? "null" : typeof screen?.rows}). ` +
              `Refusing to report that as an empty screen.`,
            { code: "SCREEN_SHAPE_UNEXPECTED", details: { received_keys: Object.keys(screen || {}) } }
          );
        }
        return listResult(rows, {
          what: "compute-fresh screen rows (engine x symbol edge scan)",
          source: `${BASE_URL}/api/screen`,
          mode: "fresh",
          computed_at_utc: iso(Math.floor(Date.now() / 1000)),
          freshness_meaning:
            "COMPUTE-fresh, not DATA-fresh: the screen was recomputed just now, but only over the bars already in the " +
            "local store. See data_recency.bars.newest_bar_utc for how old those bars actually are.",
          filters: { symbol: symbol || "(all)", engine: engine || "(all engines in config)" },
          data_recency: recency,
        });
      }

      const n = clampInt(limit, { min: 1, max: 1000, fallback: 50 });
      const [firesResp, latestResp, symbolsResp] = await Promise.all([
        apiGet("/api/fires", { limit: n, symbol, engine }, { signal, timeoutMs: 60_000 }),
        apiGet("/api/latest", {}, { signal, timeoutMs: 60_000 }),
        apiGet("/api/symbols", {}, { signal, timeoutMs: 60_000 }),
      ]);
      const knownSymbols = Array.isArray(symbolsResp?.backtestable) ? symbolsResp.backtestable : [];
      const symbolKnown = symbol ? knownSymbols.includes(symbol) : null;
      const rows = Array.isArray(firesResp?.fires) ? firesResp.fires : null;
      if (rows === null) {
        throw new ToolError(
          `/api/fires returned no "fires" array (got ${typeof firesResp?.fires}). Refusing to report that as an empty journal.`,
          { code: "FIRES_SHAPE_UNEXPECTED", details: { received_keys: Object.keys(firesResp || {}) } }
        );
      }
      const graded = rows.filter((f) => f?.outcome !== null && f?.outcome !== undefined).length;
      // An empty list under a filter must say WHY it is empty. "No fires for symbol X" reads very
      // differently depending on whether the store has ever held a single bar of X.
      const emptyReason =
        symbolKnown === false
          ? `no signals matched, and the filter symbol "${symbol}" is not a symbol this store holds bars for at all ` +
            `(it holds: ${knownSymbols.length ? knownSymbols.join(", ") : "none"}). The zero is about the filter, not about market conditions.`
          : `the signal journal ran the query and matched no rows (filters: symbol=${symbol || "(all)"}, engine=${engine || "(all)"}).`;
      return listResult(rows, {
        what: "recorded trading signals (fires) from the local signal journal",
        source: `${BASE_URL}/api/fires`,
        mode: "stored",
        reason: emptyReason,
        filters: { symbol: symbol || "(all)", engine: engine || "(all)", limit: n },
        filter_symbol_known_to_store: symbolKnown,
        symbols_this_store_holds_bars_for: knownSymbols,
        returned_rows_graded: graded,
        returned_rows_ungraded_null_outcome: rows.length - graded,
        grading_note:
          graded === 0 && rows.length > 0
            ? "None of the returned signals has an outcome. No win rate, hit rate or P&L can be derived from them, and none is reported."
            : `${graded} of ${rows.length} returned signals carry a graded outcome.`,
        latest_stored_fire_store_wide: latestResp?.fire ?? null,
        latest_stored_fire_note:
          "latest_stored_fire_store_wide is the newest fire in the WHOLE store and ignores the symbol/engine filters above. " +
          "Do not read it as the latest fire for a filtered symbol or engine.",
        signals_only: "Hypothetical signals. This server cannot place, modify or route an order.",
        data_recency: recency,
      });
    },
  },

  {
    name: "trading__get_bars",
    description:
      "Read captured OHLC bars for one symbol out of the Trading app's local store. " +
      "window=recent (default) returns the NEWEST n bars; window=history_start returns the OLDEST n bars in the " +
      "backend's backtest feed order — asking for history_start with a small limit gives you the beginning of the " +
      "capture, not today. The store is filled only by the buyer's own capture, so it can be far behind the live " +
      "market; the data_recency block on every response states exactly how far.",
    inputSchema: {
      type: "object",
      properties: {
        symbol: {
          type: "string",
          description: "Instrument symbol. Omitted = the store's busiest symbol, reported back in symbol_resolution.",
        },
        limit: { type: "integer", description: "Number of bars (1-5000, default 100)." },
        window: {
          type: "string",
          enum: ["recent", "history_start"],
          description: "recent = newest n bars (/api/recent). history_start = oldest n bars (/api/bars, backtest feed order).",
        },
      },
      required: [],
    },
    timeoutMs: 90_000,
    async handler({ symbol, limit, window = "recent" } = {}, { signal } = {}) {
      const recency = await dataRecency({ signal });
      const resolved = await resolveSymbol(symbol, { signal });
      const n = clampInt(limit, { min: 1, max: 5000, fallback: 100 });
      const path = window === "history_start" ? "/api/bars" : "/api/recent";
      const resp = await apiGet(path, { symbol: resolved.symbol, limit: n }, { signal, timeoutMs: 80_000 });
      const raw = Array.isArray(resp?.bars) ? resp.bars : null;
      if (raw === null) {
        throw new ToolError(
          `${path} returned no "bars" array (got ${typeof resp?.bars}). Refusing to report that as a symbol with no bars.`,
          { code: "BARS_SHAPE_UNEXPECTED", details: { received_keys: Object.keys(resp || {}) } }
        );
      }
      // Backend row shape: [open, high, low, close, ts_epoch, volume, delta]
      const bars = raw.map((r) => ({
        ts: r[4],
        utc: iso(r[4]),
        open: r[0],
        high: r[1],
        low: r[2],
        close: r[3],
        volume: r[5] ?? null,
        delta: r[6] ?? null,
      }));
      const nowSec = Math.floor(Date.now() / 1000);
      const last = bars.length ? bars[bars.length - 1] : null;
      const first = bars.length ? bars[0] : null;

      return listResult(bars, {
        what: `captured OHLC bars for ${resolved.symbol}`,
        source: `${BASE_URL}${path}`,
        symbol: resolved.symbol,
        symbol_resolution: resolved.resolution,
        window,
        window_semantics:
          window === "history_start"
            ? "OLDEST-first slice from the start of the capture. These are the earliest bars in the store, not the latest."
            : "NEWEST n bars, returned oldest-to-newest. The last element is the most recent bar the store holds.",
        requested_limit: n,
        returned_range:
          bars.length === 0
            ? null
            : {
                first_bar_utc: first.utc,
                last_bar_utc: last.utc,
                last_bar_age_days: days(nowSec - last.ts),
              },
        staleness_note:
          bars.length === 0
            ? "No bars returned."
            : `The most recent bar in this response is ${last.utc}, ${days(nowSec - last.ts)} days old as of ${iso(nowSec)}. ` +
              `Treat these prices as historical, not as the current market.`,
        data_recency: recency,
      });
    },
  },

  {
    name: "trading__run_backtest",
    description:
      "Run the Trading app's SHIPPED backtest prover for one engine on one symbol over the bars already in the local " +
      "store, split into contiguous folds. Returns the prover's own per-fold n / wins / losses / max-drawdown-R / " +
      "p-value plus its prover_sha; it reports no aggregate win rate and no equity/currency figure. Read-only and " +
      "single-process: the multi-core parameter-sweep farm endpoint is deliberately not exposed by this server. " +
      "A result is only ever as current as the bars behind it — see data_recency and backtest_window on the response.",
    inputSchema: {
      type: "object",
      properties: {
        engine: { type: "string", enum: ENGINES, description: "Engine to prove. Default meanrev." },
        symbol: { type: "string", description: "Instrument symbol. Omitted = the store's busiest symbol." },
        start: { type: "integer", description: "Optional start epoch-seconds. Omitted = first captured bar." },
        end: { type: "integer", description: "Optional end epoch-seconds. Omitted = last captured bar." },
        folds: { type: "integer", description: "Contiguous folds to split the window into (1-8, default 1). The shipped prover caps folds at 8." },
      },
      required: [],
    },
    timeoutMs: 240_000,
    async handler({ engine = "meanrev", symbol, start, end, folds } = {}, { signal } = {}) {
      const recency = await dataRecency({ signal });
      const resolved = await resolveSymbol(symbol, { signal });
      // The shipped prover clamps folds to 8 (bltd_analytics.backtest_lab). Clamping to the same
      // number here keeps folds_requested from claiming a split the prover never performed.
      const foldCount = clampInt(folds, { min: 1, max: 8, fallback: 1 });

      if (Number.isFinite(start) && Number.isFinite(end) && start > end) {
        throw new ToolError(
          `Refusing an inverted window: start (${start}, ${iso(start)}) is after end (${end}, ${iso(end)}). ` +
            `No backtest was run — a window that ends before it begins contains no bars and would report zero trades.`,
          { code: "WINDOW_INVERTED", details: { start, end } }
        );
      }

      const bounds = await apiGet("/api/backtest/bounds", { symbol: resolved.symbol }, { signal, timeoutMs: 30_000 });
      if (!bounds || !Number.isFinite(bounds.count) || bounds.count === 0) {
        throw new ToolError(
          `${resolved.symbol} has 0 bars in the store (bounds: ${JSON.stringify(bounds)}). A backtest over zero bars ` +
            `would produce a meaningless zero result, so none was run.`,
          { code: "NO_BARS_FOR_SYMBOL", details: { symbol: resolved.symbol, bounds } }
        );
      }

      const startedAt = Date.now();
      const report = await apiGet(
        "/api/backtest/run",
        { engine, symbol: resolved.symbol, start, end, folds: foldCount },
        { signal, timeoutMs: 230_000 }
      );
      const nowSec = Math.floor(Date.now() / 1000);

      // The prover reports available:false with a plain-English reason when the requested window
      // holds too few bars to arm it (whole:null, folds:[], totalBars small or 0). Wrapping that in
      // status:"ok" would present a run that never happened as a completed backtest with no trades.
      if (report && report.available === false) {
        throw new ToolError(
          `The shipped prover did NOT run for engine=${engine} symbol=${resolved.symbol}: ${
            report.reason || "the backend reported available:false without a reason"
          }. It returned ${report.totalBars ?? 0} bar(s) inside the requested window and no fold results, so there is ` +
            `no backtest to report. Reporting this as a completed run with zero trades would be a lie.`,
          {
            code: "BACKTEST_NOT_AVAILABLE",
            details: {
              engine,
              symbol: resolved.symbol,
              backend_reason: report.reason ?? null,
              total_bars_in_window: report.totalBars ?? 0,
              requested_start_ts: Number.isFinite(start) ? start : null,
              requested_end_ts: Number.isFinite(end) ? end : null,
              store_first_bar_ts: bounds.firstTs ?? null,
              store_last_bar_ts: bounds.lastTs ?? null,
            },
          }
        );
      }

      // The run can never see past the newest bar in the store, so a requested end in the future
      // must not be reported as the newest data used (that yields a negative "age in days").
      const effectiveEnd = Number.isFinite(end)
        ? Number.isFinite(bounds.lastTs)
          ? Math.min(end, bounds.lastTs)
          : end
        : bounds.lastTs;

      return {
        ok: true,
        status: "ok",
        what: `shipped-prover backtest: engine=${engine} symbol=${resolved.symbol} folds=${foldCount}`,
        source: `${BASE_URL}/api/backtest/run`,
        engine,
        symbol: resolved.symbol,
        symbol_resolution: resolved.resolution,
        folds_requested: foldCount,
        elapsed_ms: Date.now() - startedAt,
        backtest_window: {
          requested_start_ts: Number.isFinite(start) ? start : null,
          requested_end_ts: Number.isFinite(end) ? end : null,
          store_first_bar_ts: bounds.firstTs ?? null,
          store_first_bar_utc: iso(bounds.firstTs),
          store_last_bar_ts: bounds.lastTs ?? null,
          store_last_bar_utc: iso(bounds.lastTs),
          store_bar_count: bounds.count,
          newest_data_used_utc: iso(effectiveEnd),
          newest_data_age_days: Number.isFinite(effectiveEnd) ? days(nowSec - effectiveEnd) : null,
        },
        staleness_note: Number.isFinite(effectiveEnd)
          ? `This backtest could not see anything after ${iso(effectiveEnd)} (${days(nowSec - effectiveEnd)} days before now). ` +
            `It is a statement about that historical window only.`
          : "The window end could not be determined from the store.",
        signals_only:
          "Hypothetical, points-based prover output. No order was placed, no broker was contacted, no money moved.",
        not_exposed: {
          "/api/backtest/farm":
            "The multi-core parameter-sweep farm is on this server's deny list (it forks a worker per CPU core) and cannot be reached through any tool here.",
        },
        report,
        data_recency: recency,
      };
    },
  },
];

// ---------------------------------------------------------------------------
// Boot (only when run directly, so the guards can be imported and tested)
// ---------------------------------------------------------------------------

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];

if (isMain) {
  createServer({
    name: SERVER_NAME,
    version: SERVER_VERSION,
    tools,
    instructions:
      "Read-only, signals-only access to the Trading app's local backend. This server emits GET requests exclusively " +
      "and refuses every non-GET method and every path outside its own allowlist, so it cannot write to the store, " +
      "cannot connect a feed, and cannot place an order. Every tool response carries a data_recency block; the local " +
      "store is filled only by the buyer's own capture and can be far behind the live market, so check " +
      "data_recency.verdict and data_recency.warnings before treating any number as current.",
  });
}

export { tools, ALLOWED_GET_PATHS, ALLOWED_METHODS, DENIED_PATHS, httpRequest, dataRecency, BASE_URL, TOKEN_FILE };
