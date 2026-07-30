// mcp-kit.mjs — self-contained MCP stdio server kit. Zero npm dependencies.
//
// VENDORED FILE. This file is COPIED into each app's `mcp/` directory and imported
// with a RELATIVE path (`./mcp-kit.mjs`). It must never be imported from a shared
// cross-repo location at runtime, and it must never name any product but the one it
// ships inside. Everything here is brand-neutral on purpose: names, env vars and
// error strings are all derived from the `name` you pass to createServer().
//
// Protocol: JSON-RPC 2.0 over stdio, newline-delimited. stdout is the protocol
// channel and carries nothing else. All logging goes to stderr, redacted.
//
// Quick start (inside an app's mcp/server.mjs):
//
//   import { createServer, listResult, emptyResult, ToolError } from "./mcp-kit.mjs";
//
//   createServer({
//     name: "<product>",            // e.g. the app's own name, nothing else
//     version: "1.0.0",
//     tools: [
//       {
//         name: "<product>__list_things",
//         description: "List the things.",
//         inputSchema: { type: "object", properties: { q: { type: "string" } } },
//         async handler({ q }) { ... }
//       },
//       {
//         name: "<product>__do_dangerous_thing",
//         description: "Performs a side effect.",
//         inputSchema: { type: "object", properties: {}, required: [] },
//         gated: true,                        // OFF unless <PRODUCT>_ALLOW_GATED=1
//         dryRun: (args) => ({ would: "...", steps: [...] }),
//         async handler(args) { ... }
//       }
//     ]
//   });
//
// Exports: createServer, ToolError, listResult, emptyResult, okResult, collect,
//          isEnabled, gateEnvFor, redact, createLogger, registerSecret, loadSecret,
//          withTimeout, PROTOCOL_VERSIONS, DEFAULT_TIMEOUT_MS.

import { readFileSync } from "node:fs";

// ---------------------------------------------------------------------------
// Protocol constants
// ---------------------------------------------------------------------------

/** Protocol revisions this kit speaks, newest first. */
export const PROTOCOL_VERSIONS = ["2025-06-18", "2025-03-26", "2024-11-05"];
export const DEFAULT_PROTOCOL_VERSION = PROTOCOL_VERSIONS[0];
export const DEFAULT_TIMEOUT_MS = 60_000;

const JSONRPC = "2.0";
const ERR_PARSE = -32700;
const ERR_INVALID_REQUEST = -32600;
const ERR_METHOD_NOT_FOUND = -32601;
const ERR_INVALID_PARAMS = -32602;
const ERR_INTERNAL = -32603;

const MAX_LINE_BYTES = 32 * 1024 * 1024; // guard against an unterminated stream

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/**
 * Error type that carries a machine-readable code and optional details.
 * Handlers may throw this (or any Error) — the real message is always surfaced
 * to the caller. Nothing is swallowed.
 */
export class ToolError extends Error {
  constructor(message, { code = "TOOL_ERROR", details = undefined, cause = undefined } = {}) {
    super(message);
    this.name = "ToolError";
    this.code = code;
    if (details !== undefined) this.details = details;
    if (cause !== undefined) this.cause = cause;
  }
}

function describeError(err) {
  if (err instanceof Error) {
    const out = { message: err.message || String(err), code: err.code || err.name || "Error" };
    if (err.details !== undefined) out.details = err.details;
    if (err.cause) {
      const c = err.cause;
      out.cause = c instanceof Error ? (c.message || String(c)) : String(c);
    }
    if (err.stack) out.stack = String(err.stack).split("\n").slice(0, 6).join("\n");
    return out;
  }
  return { message: typeof err === "string" ? err : safeStringify(err), code: "NonError" };
}

// ---------------------------------------------------------------------------
// Secret redaction
// ---------------------------------------------------------------------------

const REDACTED = "[REDACTED]";

// Exact values registered at runtime (anything loadSecret() reads). These are the
// strongest guarantee: no pattern matching required, the literal value never prints.
const knownSecrets = new Set();

/** Register a literal secret value so it is scrubbed from every log line and error. */
export function registerSecret(value) {
  if (typeof value === "string" && value.length >= 6) knownSecrets.add(value);
  return value;
}

const SECRET_PATTERNS = [
  // key: "value" / key=value  (json, env, query strings)
  /(["']?\b(?:api[_-]?key|apikey|secret|secret[_-]?key|client[_-]?secret|token|access[_-]?token|refresh[_-]?token|id[_-]?token|password|passwd|pwd|passphrase|authorization|auth[_-]?token|credential|private[_-]?key|session[_-]?key|signing[_-]?key)\b["']?\s*[:=]\s*)(["']?)([^\s"',;}&]{4,})\2/gi,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/gi,
  /\b(?:sk|rk|pk|whsec|pi|plink)[-_](?:live|test)?[-_]?[A-Za-z0-9]{12,}\b/g,
  /\bgh[pousr]_[A-Za-z0-9]{16,}\b/g,
  /\bgithub_pat_[A-Za-z0-9_]{20,}\b/g,
  /\bxox[baprse]-[A-Za-z0-9-]{10,}\b/g,
  /\bAKIA[0-9A-Z]{16}\b/g,
  /\bAIza[0-9A-Za-z_-]{30,}\b/g,
  /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}\b/g, // JWT
  /\b-----BEGIN[^-]*PRIVATE KEY-----[\s\S]*?-----END[^-]*PRIVATE KEY-----/g,
];

// High-entropy blob: >=32 chars of token alphabet containing upper, lower and digit.
const ENTROPY_RE = /\b[A-Za-z0-9_-]{32,}\b/g;
function looksHighEntropy(s) {
  return /[a-z]/.test(s) && /[A-Z]/.test(s) && /[0-9]/.test(s);
}

/**
 * Scrub anything that looks like a key/token out of a string. Applied to every log
 * line, every error message surfaced to the caller, and every echoed argument.
 * Over-redaction is deliberate: a redacted diagnostic beats a leaked credential.
 */
export function redact(input) {
  if (input == null) return input;
  let s = typeof input === "string" ? input : safeStringify(input);
  for (const secret of knownSecrets) {
    if (secret && s.includes(secret)) s = s.split(secret).join(REDACTED);
  }
  for (const re of SECRET_PATTERNS) {
    re.lastIndex = 0;
    s = s.replace(re, (m, ...rest) => {
      // key:value form keeps the key so the log stays readable
      if (rest.length >= 3 && typeof rest[0] === "string" && /[:=]\s*$/.test(rest[0])) {
        return `${rest[0]}${rest[1] || ""}${REDACTED}${rest[1] || ""}`;
      }
      return REDACTED;
    });
  }
  ENTROPY_RE.lastIndex = 0;
  s = s.replace(ENTROPY_RE, (m) => (looksHighEntropy(m) ? REDACTED : m));
  return s;
}

/** Deep-redact a JSON-able value (used when echoing arguments back to the caller). */
export function redactValue(value, depth = 0) {
  if (depth > 8) return "[depth-limit]";
  if (value == null) return value;
  if (typeof value === "string") return redact(value);
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (Array.isArray(value)) return value.map((v) => redactValue(v, depth + 1));
  if (typeof value === "object") {
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      out[k] = /\b(key|token|secret|password|passwd|pwd|auth|credential|passphrase)\b/i.test(k)
        ? REDACTED
        : redactValue(v, depth + 1);
    }
    return out;
  }
  return String(value);
}

function safeStringify(value, space = 0) {
  const seen = new WeakSet();
  try {
    return JSON.stringify(
      value,
      (_k, v) => {
        if (typeof v === "bigint") return `${v}n`;
        if (typeof v === "function") return `[function ${v.name || "anonymous"}]`;
        if (v instanceof Error) return describeError(v);
        if (typeof v === "object" && v !== null) {
          if (seen.has(v)) return "[circular]";
          seen.add(v);
        }
        return v;
      },
      space
    );
  } catch (err) {
    return `[unserializable: ${err?.message || String(err)}]`;
  }
}

// ---------------------------------------------------------------------------
// Logging — stderr only, never stdout
// ---------------------------------------------------------------------------

/**
 * Build a logger bound to stderr. stdout is reserved for the JSON-RPC channel;
 * writing anything else there corrupts the protocol.
 */
export function createLogger(prefix = "mcp", { level = process.env.MCP_LOG_LEVEL || "info" } = {}) {
  const order = { silent: 0, error: 1, warn: 2, info: 3, debug: 4 };
  const threshold = order[String(level).toLowerCase()] ?? 3;
  const emit = (lvl, args) => {
    if ((order[lvl] ?? 3) > threshold) return;
    const line = args
      .map((a) => (typeof a === "string" ? a : safeStringify(a)))
      .join(" ");
    try {
      process.stderr.write(`[${new Date().toISOString()}] [${prefix}] [${lvl}] ${redact(line)}\n`);
    } catch {
      /* stderr closed — there is nowhere left to report, and stdout must stay clean */
    }
  };
  return {
    error: (...a) => emit("error", a),
    warn: (...a) => emit("warn", a),
    info: (...a) => emit("info", a),
    debug: (...a) => emit("debug", a),
  };
}

// ---------------------------------------------------------------------------
// Secrets — read from disk at runtime, never hardcoded, never printed
// ---------------------------------------------------------------------------

/**
 * Read a credential from a file at call time. The value is registered with the
 * redactor so it can never appear in a log line or an error message.
 * Throws a truthful error naming the file (never the value) when unavailable.
 */
export function loadSecret(filePath, { field = null, json = null, required = true } = {}) {
  let raw;
  try {
    raw = readFileSync(filePath, "utf8");
  } catch (err) {
    if (!required) return null;
    throw new ToolError(`Cannot read credential file ${filePath}: ${err?.code || err?.message || "unknown error"}`, {
      code: "SECRET_UNREADABLE",
    });
  }
  const isJson = json ?? filePath.endsWith(".json");
  if (!isJson) {
    const value = raw.trim();
    if (!value) {
      if (!required) return null;
      throw new ToolError(`Credential file ${filePath} is empty.`, { code: "SECRET_EMPTY" });
    }
    return registerSecret(value);
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    throw new ToolError(`Credential file ${filePath} is not valid JSON: ${err?.message}`, { code: "SECRET_MALFORMED" });
  }
  if (!field) {
    for (const v of Object.values(parsed || {})) if (typeof v === "string") registerSecret(v);
    return parsed;
  }
  const value = parsed?.[field];
  if (typeof value !== "string" || !value) {
    if (!required) return null;
    throw new ToolError(`Credential file ${filePath} has no usable "${field}" field.`, { code: "SECRET_FIELD_MISSING" });
  }
  return registerSecret(value);
}

// ---------------------------------------------------------------------------
// Honest results — "no results" must never be confusable with "failed to look"
// ---------------------------------------------------------------------------

/** A successful result carrying data. */
export function okResult(data, meta = {}) {
  return { ok: true, status: "ok", ...meta, data };
}

/**
 * A VERIFIED zero result. Only build one of these when the lookup actually ran and
 * genuinely found nothing. Never return this from a catch block.
 */
export function emptyResult({ what = "results", source = "unknown", reason = "the source returned no matching records", checked = undefined, ...meta } = {}) {
  const out = {
    ok: true,
    status: "empty",
    count: 0,
    items: [],
    what,
    source,
    reason,
    // Every remaining field the caller supplied is KEPT. Dropping it here would turn a
    // zero result carrying warnings ("the device probe failed", "this credential is dead")
    // into a clean-looking empty list — the exact confusion this module exists to prevent.
    ...meta,
    note: "Verified zero result: the lookup ran successfully and found nothing. This is not a failure and not a placeholder.",
  };
  if (checked !== undefined) out.checked = checked;
  return out;
}

/** Wrap a real array of items; automatically reports the honest-empty shape at length 0. */
export function listResult(items, { what = "results", source = "unknown", ...meta } = {}) {
  if (!Array.isArray(items)) {
    throw new ToolError(
      `listResult(${what}) expected an array from ${source} but received ${items === null ? "null" : typeof items}. Refusing to report an unverified empty list.`,
      { code: "LIST_NOT_ARRAY" }
    );
  }
  if (items.length === 0) return emptyResult({ what, source, ...meta });
  return { ok: true, status: "ok", count: items.length, items, what, source, ...meta };
}

/**
 * Run a producer and convert its outcome into an honest result.
 * - producer throws  -> ToolError (never an empty list)
 * - producer returns null/undefined -> ToolError (an absent value is not a zero result)
 * - producer returns [] -> verified empty result
 */
export async function collect(producer, { what = "results", source = "unknown", signal = undefined } = {}) {
  let raw;
  try {
    raw = await producer(signal);
  } catch (err) {
    throw new ToolError(`Failed to collect ${what} from ${source}: ${err?.message || String(err)}`, {
      code: "COLLECT_FAILED",
      cause: err,
    });
  }
  if (raw === null || raw === undefined) {
    throw new ToolError(
      `Collecting ${what} from ${source} produced no value (${raw === null ? "null" : "undefined"}). Reporting that as an empty result would be a lie.`,
      { code: "COLLECT_NO_VALUE" }
    );
  }
  return listResult(Array.isArray(raw) ? raw : [raw], { what, source });
}

// ---------------------------------------------------------------------------
// Gating
// ---------------------------------------------------------------------------

const ENABLED_VALUES = new Set(["1", "true", "yes", "on", "enable", "enabled", "allow"]);

/** True only when the env var is set to an explicit enable value. Unset = disabled. */
export function isEnabled(envName, env = process.env) {
  if (!envName) return false;
  const raw = env?.[envName];
  if (raw === undefined || raw === null) return false;
  return ENABLED_VALUES.has(String(raw).trim().toLowerCase());
}

/** Uppercase, underscore-safe token derived from the server name (its own brand only). */
export function envPrefixFor(serverName) {
  const base = String(serverName || "mcp")
    .split("__")[0]
    .replace(/[-_\s]*mcp$/i, "")
    .replace(/[^A-Za-z0-9]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .toUpperCase();
  return base || "MCP";
}

/** The env var that unlocks a gated tool: per-tool override, else <PREFIX>_ALLOW_GATED. */
export function gateEnvFor(serverName, tool) {
  if (tool && typeof tool.gateEnv === "string" && tool.gateEnv.trim()) return tool.gateEnv.trim();
  return `${envPrefixFor(serverName)}_ALLOW_GATED`;
}

// ---------------------------------------------------------------------------
// Timeouts
// ---------------------------------------------------------------------------

/**
 * Race a function against a deadline. A hung handler can never wedge the server:
 * the request is answered with a timeout error and the read loop keeps running.
 * The function receives an AbortSignal so cooperative handlers can stop early.
 */
export async function withTimeout(fn, ms = DEFAULT_TIMEOUT_MS, label = "operation") {
  const controller = new AbortController();
  let timer = null;
  const deadline = new Promise((_resolve, reject) => {
    timer = setTimeout(() => {
      try {
        controller.abort(new Error(`${label} timed out`));
      } catch {
        /* older runtimes: abort() takes no reason */
      }
      reject(
        new ToolError(`${label} exceeded its ${ms}ms timeout and was abandoned. No result was produced.`, {
          code: "TIMEOUT",
          details: { timeout_ms: ms },
        })
      );
    }, ms);
    if (typeof timer.unref === "function") timer.unref();
  });
  try {
    return await Promise.race([Promise.resolve().then(() => fn(controller.signal)), deadline]);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

// ---------------------------------------------------------------------------
// Minimal input validation (top-level required + type + enum)
// ---------------------------------------------------------------------------

function typeOfJson(v) {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  if (Number.isInteger(v)) return "integer";
  return typeof v; // string | number | boolean | object | undefined
}

function typeMatches(expected, value) {
  const actual = typeOfJson(value);
  if (Array.isArray(expected)) return expected.some((t) => typeMatches(t, value));
  switch (expected) {
    case "integer":
      return actual === "integer";
    case "number":
      return actual === "integer" || actual === "number";
    case "object":
      return actual === "object";
    case "array":
      return actual === "array";
    case "null":
      return actual === "null";
    default:
      return actual === expected;
  }
}

function validateArgs(schema, args) {
  const problems = [];
  if (!schema || typeof schema !== "object") return problems;
  const props = schema.properties || {};
  for (const req of schema.required || []) {
    if (args?.[req] === undefined) problems.push(`missing required argument "${req}"`);
  }
  for (const [key, value] of Object.entries(args || {})) {
    const spec = props[key];
    if (!spec || typeof spec !== "object") continue;
    if (spec.type && value !== undefined && !typeMatches(spec.type, value)) {
      problems.push(`argument "${key}" must be ${Array.isArray(spec.type) ? spec.type.join("|") : spec.type}, received ${typeOfJson(value)}`);
    }
    if (Array.isArray(spec.enum) && value !== undefined && !spec.enum.includes(value)) {
      problems.push(`argument "${key}" must be one of ${JSON.stringify(spec.enum)}`);
    }
  }
  return problems;
}

// ---------------------------------------------------------------------------
// Result envelope helpers
// ---------------------------------------------------------------------------

function asText(value) {
  if (typeof value === "string") return value;
  return safeStringify(value, 2) ?? String(value);
}

function toolResultFromValue(tool, value) {
  // Pass through anything already in MCP content shape.
  if (value && typeof value === "object" && Array.isArray(value.content)) return value;
  const result = { content: [{ type: "text", text: asText(value) }], isError: false };
  if (tool?.outputSchema && value && typeof value === "object" && !Array.isArray(value)) {
    result.structuredContent = value;
  }
  return result;
}

function toolErrorResult(toolName, err) {
  const info = describeError(err);
  const payload = {
    ok: false,
    status: "error",
    executed: "unknown",
    tool: toolName,
    error: {
      code: info.code,
      message: redact(info.message),
    },
  };
  if (info.details !== undefined) payload.error.details = redactValue(info.details);
  if (info.cause) payload.error.cause = redact(info.cause);
  return {
    content: [{ type: "text", text: `ERROR in ${toolName}: ${redact(info.message)}\n\n${safeStringify(payload, 2)}` }],
    isError: true,
  };
}

function gateRefusalResult({ toolName, envName, description, args, preview, previewError }) {
  const payload = {
    ok: false,
    status: "refused",
    reason: "gated",
    executed: false,
    tool: toolName,
    message: `"${toolName}" is gated off. Its handler did NOT run and nothing was changed.`,
    enable_with: { env_var: envName, set_to: "1", scope: "this server's process environment" },
    default_state: `disabled — ${envName} is unset or not set to an enabling value`,
    dry_run: preview,
  };
  if (description) payload.tool_description = description;
  if (args !== undefined) payload.arguments_received = redactValue(args);
  if (previewError) payload.dry_run_error = redact(previewError);
  return {
    content: [
      {
        type: "text",
        text:
          `REFUSED (gated off) — nothing was executed.\n` +
          `Tool: ${toolName}\n` +
          `Set ${envName}=1 in this server's environment to enable it.\n\n` +
          safeStringify(payload, 2),
      },
    ],
    isError: false,
  };
}

function fallbackPreview(tool, args, why = "no_dry_run_declared") {
  return {
    preview_available: false,
    note:
      (why === "dry_run_failed"
        ? `This tool's dryRun() function ran and FAILED (see dry_run_error), so the kit cannot state its exact side effects. `
        : `This tool declares no dryRun() function, so the kit cannot state its exact side effects. `) +
      `Reported below is only what the tool declares about itself and the arguments it was called with.`,
    tool: tool.name,
    declared_description: tool.description || "(no description declared)",
    would_run_with: redactValue(args ?? {}),
  };
}

// ---------------------------------------------------------------------------
// stdout guard — stdout belongs to the protocol
// ---------------------------------------------------------------------------

function installStdoutGuard(log) {
  const original = process.stdout.write.bind(process.stdout);
  let guarded = true;
  process.stdout.write = function guardedWrite(chunk, encoding, callback) {
    if (typeof encoding === "function") {
      callback = encoding;
      encoding = undefined;
    }
    try {
      const text = Buffer.isBuffer(chunk) ? chunk.toString("utf8") : String(chunk);
      if (text.trim()) log.warn("stdout write intercepted (stdout is the protocol channel):", text.trimEnd());
    } catch {
      /* ignore */
    }
    if (typeof callback === "function") callback();
    return true;
  };
  return {
    write: original,
    restore() {
      if (guarded) {
        process.stdout.write = original;
        guarded = false;
      }
    },
  };
}

// ---------------------------------------------------------------------------
// createServer
// ---------------------------------------------------------------------------

/**
 * Create (and by default start) an MCP stdio server.
 *
 * @param {object}   opts
 * @param {string}   opts.name        Server/product name. Use only this app's own name.
 * @param {string}   opts.version     Server version string.
 * @param {Array}    opts.tools       [{ name, description, inputSchema, gated?, gateEnv?, timeoutMs?, dryRun?, handler }]
 * @param {string}   [opts.instructions]  Optional instructions returned by initialize.
 * @param {number}   [opts.timeoutMs] Default per-handler timeout (60s).
 * @param {boolean}  [opts.autoStart] Start the stdio loop immediately (default true).
 * @param {boolean}  [opts.guardStdout] Redirect stray stdout writes to stderr (default true).
 * @param {object}   [opts.env]       Environment used for gate checks (default process.env).
 * @returns {{start:Function, stop:Function, handleMessage:Function, tools:Array, name:string, version:string, log:object}}
 */
export function createServer({
  name,
  version = "0.0.0",
  tools = [],
  instructions = undefined,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  autoStart = true,
  guardStdout = true,
  env = process.env,
  stdin = process.stdin,
} = {}) {
  if (!name || typeof name !== "string") {
    throw new Error("createServer requires a { name } string — use this app's own name only.");
  }

  const log = createLogger(name);

  const registry = new Map();
  for (const tool of tools) {
    if (!tool || typeof tool !== "object") throw new Error(`${name}: every tool must be an object`);
    if (!tool.name || typeof tool.name !== "string") throw new Error(`${name}: every tool needs a string name`);
    if (typeof tool.handler !== "function") throw new Error(`${name}: tool "${tool.name}" has no handler function`);
    if (registry.has(tool.name)) throw new Error(`${name}: duplicate tool name "${tool.name}"`);
    registry.set(tool.name, tool);
  }

  const out = guardStdout ? installStdoutGuard(log) : { write: process.stdout.write.bind(process.stdout), restore() {} };

  let negotiatedProtocol = DEFAULT_PROTOCOL_VERSION;
  let initialized = false;
  let stopped = false;
  let buffer = "";
  let onData = null;
  let onEnd = null;

  function send(message) {
    if (stopped) return;
    let line;
    try {
      line = JSON.stringify(message);
    } catch (err) {
      log.error("failed to serialize outgoing message:", err?.message);
      line = JSON.stringify({
        jsonrpc: JSONRPC,
        id: message?.id ?? null,
        error: { code: ERR_INTERNAL, message: `Response could not be serialized: ${err?.message}` },
      });
    }
    try {
      out.write(line + "\n");
    } catch (err) {
      log.error("failed to write to stdout:", err?.message);
    }
  }

  const sendResult = (id, result) => send({ jsonrpc: JSONRPC, id, result });
  const sendError = (id, code, message, data) =>
    send({ jsonrpc: JSONRPC, id, error: data === undefined ? { code, message } : { code, message, data } });

  function listedTools() {
    return [...registry.values()].map((tool) => {
      const envName = gateEnvFor(name, tool);
      const gated = tool.gated === true;
      let description = tool.description || "";
      if (gated) {
        description +=
          `${description ? " " : ""}[GATED: disabled by default. Runs only when ${envName}=1 is set in this server's environment; ` +
          `otherwise it returns a refusal plus a dry-run preview and performs no action.]`;
      }
      const entry = {
        name: tool.name,
        description,
        inputSchema: tool.inputSchema || { type: "object", properties: {} },
      };
      if (tool.outputSchema) entry.outputSchema = tool.outputSchema;
      if (tool.annotations) entry.annotations = tool.annotations;
      return entry;
    });
  }

  async function callTool(params) {
    const toolName = params?.name;
    const args = params?.arguments ?? {};
    const tool = registry.get(toolName);
    if (!tool) {
      const known = [...registry.keys()];
      throw new ToolError(
        `Unknown tool "${toolName}". This server exposes: ${known.length ? known.join(", ") : "(none)"}.`,
        { code: "UNKNOWN_TOOL", details: { known_tools: known } }
      );
    }

    const problems = validateArgs(tool.inputSchema, args);
    if (problems.length) {
      return {
        content: [
          {
            type: "text",
            text:
              `INVALID ARGUMENTS for ${tool.name} — the handler did not run.\n` +
              safeStringify(
                { ok: false, status: "invalid_arguments", executed: false, tool: tool.name, problems, received: redactValue(args) },
                2
              ),
          },
        ],
        isError: true,
      };
    }

    const perToolTimeout = Number.isFinite(tool.timeoutMs) ? tool.timeoutMs : timeoutMs;

    if (tool.gated === true) {
      const envName = gateEnvFor(name, tool);
      if (!isEnabled(envName, env)) {
        let preview = null;
        let previewError = null;
        if (typeof tool.dryRun === "function") {
          try {
            preview = await withTimeout((signal) => tool.dryRun(args, { signal, log, env }), perToolTimeout, `${tool.name} dryRun`);
          } catch (err) {
            previewError = err?.message || String(err);
            preview = fallbackPreview(tool, args, "dry_run_failed");
          }
        } else {
          preview = fallbackPreview(tool, args);
        }
        log.info(`refused gated tool ${tool.name}: ${envName} is not enabled`);
        return gateRefusalResult({
          toolName: tool.name,
          envName,
          description: tool.description,
          args,
          preview,
          previewError,
        });
      }
      log.info(`gated tool ${tool.name} enabled via ${envName}`);
    }

    const value = await withTimeout((signal) => tool.handler(args, { signal, log, env }), perToolTimeout, `${tool.name}`);
    return toolResultFromValue(tool, value);
  }

  async function handleRequest(msg) {
    const { id, method, params } = msg;
    switch (method) {
      case "initialize": {
        const requested = params?.protocolVersion;
        negotiatedProtocol = PROTOCOL_VERSIONS.includes(requested) ? requested : DEFAULT_PROTOCOL_VERSION;
        initialized = true;
        const result = {
          protocolVersion: negotiatedProtocol,
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name, version },
        };
        if (instructions) result.instructions = instructions;
        log.info(`initialize: client=${params?.clientInfo?.name || "unknown"} protocol=${negotiatedProtocol}`);
        sendResult(id, result);
        return;
      }
      case "ping":
        sendResult(id, {});
        return;
      case "tools/list":
        sendResult(id, { tools: listedTools() });
        return;
      case "tools/call": {
        if (!params?.name || typeof params.name !== "string") {
          sendError(id, ERR_INVALID_PARAMS, "tools/call requires a string params.name");
          return;
        }
        const started = Date.now();
        try {
          const result = await callTool(params);
          log.debug(`tools/call ${params.name} -> ${result.isError ? "error" : "ok"} in ${Date.now() - started}ms`);
          sendResult(id, result);
        } catch (err) {
          if (err instanceof ToolError && err.code === "UNKNOWN_TOOL") {
            sendError(id, ERR_INVALID_PARAMS, redact(err.message), redactValue(err.details));
            return;
          }
          log.error(`tools/call ${params.name} threw:`, err?.message);
          sendResult(id, toolErrorResult(params.name, err));
        }
        return;
      }
      case "resources/list":
        sendResult(id, { resources: [] });
        return;
      case "prompts/list":
        sendResult(id, { prompts: [] });
        return;
      default:
        sendError(id, ERR_METHOD_NOT_FOUND, `Method not found: ${method}`);
    }
  }

  function handleNotification(msg) {
    switch (msg.method) {
      case "notifications/initialized":
        initialized = true;
        log.debug("client reported initialized");
        return;
      case "notifications/cancelled":
        log.debug(`client cancelled request ${msg.params?.requestId}`);
        return;
      default:
        log.debug(`ignoring notification ${msg.method}`);
    }
  }

  /** Handle one already-parsed JSON-RPC message. Exposed for in-process testing. */
  function handleMessage(msg) {
    if (!msg || typeof msg !== "object" || Array.isArray(msg)) {
      sendError(null, ERR_INVALID_REQUEST, "Invalid JSON-RPC message: expected an object");
      return Promise.resolve();
    }
    if (typeof msg.method !== "string") {
      if (msg.id !== undefined && (msg.result !== undefined || msg.error !== undefined)) {
        log.debug("ignoring inbound response message");
        return Promise.resolve();
      }
      sendError(msg.id ?? null, ERR_INVALID_REQUEST, "Invalid JSON-RPC message: missing method");
      return Promise.resolve();
    }
    if (msg.id === undefined || msg.id === null) {
      handleNotification(msg);
      return Promise.resolve();
    }
    // Dispatched without awaiting at the call site: a slow tool never blocks the read loop.
    return handleRequest(msg).catch((err) => {
      log.error("unhandled dispatch error:", err?.message);
      sendError(msg.id, ERR_INTERNAL, redact(err?.message || String(err)));
    });
  }

  function feed(chunk) {
    buffer += chunk;
    if (buffer.length > MAX_LINE_BYTES) {
      log.error(`input buffer exceeded ${MAX_LINE_BYTES} bytes without a newline; dropping it`);
      buffer = "";
      sendError(null, ERR_PARSE, "Input line exceeded the server's maximum length and was discarded");
      return;
    }
    let index;
    while ((index = buffer.indexOf("\n")) !== -1) {
      const line = buffer.slice(0, index).replace(/\r$/, "");
      buffer = buffer.slice(index + 1);
      if (!line.trim()) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch (err) {
        log.error("parse error on input line:", err?.message);
        sendError(null, ERR_PARSE, `Parse error: ${err?.message}`);
        continue;
      }
      if (Array.isArray(msg)) {
        for (const one of msg) handleMessage(one);
      } else {
        handleMessage(msg);
      }
    }
  }

  function start() {
    if (onData) return api;
    stdin.setEncoding("utf8");
    onData = (chunk) => feed(chunk);
    onEnd = () => {
      log.info("stdin closed; shutting down");
      stop();
      // Let queued stderr/stdout writes flush before the process ends.
      setTimeout(() => process.exit(0), 10).unref?.();
    };
    stdin.on("data", onData);
    stdin.on("end", onEnd);
    stdin.on("close", onEnd);
    if (typeof stdin.resume === "function") stdin.resume();
    process.on("uncaughtException", (err) => {
      log.error("uncaughtException:", err?.stack || err?.message || String(err));
    });
    process.on("unhandledRejection", (err) => {
      log.error("unhandledRejection:", err?.stack || err?.message || String(err));
    });
    log.info(`ready: ${name} v${version} with ${registry.size} tool(s)`);
    return api;
  }

  function stop() {
    if (stopped) return;
    stopped = true;
    if (onData) stdin.off?.("data", onData);
    if (onEnd) {
      stdin.off?.("end", onEnd);
      stdin.off?.("close", onEnd);
    }
    out.restore();
  }

  const api = {
    name,
    version,
    log,
    tools: [...registry.values()],
    get initialized() {
      return initialized;
    },
    get protocolVersion() {
      return negotiatedProtocol;
    },
    handleMessage,
    start,
    stop,
  };

  if (autoStart) start();
  return api;
}

export default createServer;
