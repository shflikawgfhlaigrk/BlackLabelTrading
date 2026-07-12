"""Black Label Trading — honest edge-gate ALERT delivery (TR-06). PURE stdlib.

WHAT THIS IS: a one-way push of the SHIPPED edge-gate's verdict — INCLUDING the honest
"no edge on your bars today" — to an endpoint the BUYER configures and owns (an ntfy topic, a
Pushover account, a Shortcuts/webhook recipe). It is the mobile/companion path for the person who
does not want to sit in front of the Mac: the gate re-runs on THEIR OWN captured bars, and the
result is posted to THEIR OWN channel.

NON-NEGOTIABLE POSTURE (CHARTER §5.1 / §5.7):
  * OFF by default. A fresh config has alertEnabled False and alertEndpoint "" — and in that state
    this module makes ZERO network calls (send_gate_alert / test_send return networked:False before
    any socket is opened). No endpoint => no egress, ever.
  * NEVER through a Black Label relay. The ONLY destination is the buyer's configured endpoint (or,
    for the Pushover convenience provider, Pushover's own public API with the buyer's own token/user).
    No Black Label server is ever contacted. This is the egress posture TR-20 attests and test_egress
    proves.
  * The payload carries the edge-gate VERDICT ONLY: engine counts + per-engine status + the gate's
    own honest reason strings + the prover-source sha256. It NEVER carries an aggregate win-rate, a
    $ P&L, an equity figure, or any performance promise. claim_linter.scan_alert_payloads() renders
    the real payloads and would fail the build if a forbidden figure ever appeared in one.
  * NO order / auto-trade path. This module imports NOTHING from bltd_exec and cannot arm, size, or
    place anything. A push is information out; it can never become an order in. (test_alerts asserts
    the module references no execution surface.)
  * Honest status language: a 2xx from the buyer's endpoint means the alert was POSTED to their
    channel — never "delivered" (whether a human sees it is their push provider's business, not a
    claim we can make).

Endpoint safety: only https:// endpoints are accepted for external hosts; http:// is allowed solely
for localhost/127.0.0.1 (a self-hosted ntfy on the same machine). Anything else is refused with an
honest reason and NO network call.
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request

import bltd_analytics
import bltd_store as S

# The ONE convenience provider host (a public push service the buyer opts into with THEIR OWN
# token + user key — not a Black Label server). Every other provider posts to a URL the buyer types
# in full. Kept as a named constant so test_egress can allow-list exactly this and nothing else.
PUSHOVER_API = "https://api.pushover.net/1/messages.json"

# The single honest disclaimer stamped on every payload. Signals-only; verdict, not a track record.
DISCLAIMER = ("Signals-only. Not a track record. No win-rate, P&L, or performance is promised — "
              "this reports only whether a proven out-of-sample edge exists on YOUR bars.")

_PROVIDERS = ("ntfy", "pushover", "webhook")


# ── configuration (read straight from the buyer's config; ships empty/off) ────────────────────────
def alert_config(cfg: dict) -> dict:
    """Normalize the alert settings out of the buyer config. Unknown provider => 'ntfy'. All values
    default to the OFF/empty posture so a fresh install never egresses."""
    provider = str(cfg.get("alertProvider", "ntfy") or "ntfy").strip().lower()
    if provider not in _PROVIDERS:
        provider = "ntfy"
    return {
        "enabled": bool(cfg.get("alertEnabled", False)),
        "endpoint": str(cfg.get("alertEndpoint", "") or "").strip(),
        "provider": provider,
        "pushoverToken": str(cfg.get("alertPushoverToken", "") or "").strip(),
        "pushoverUser": str(cfg.get("alertPushoverUser", "") or "").strip(),
    }


def _destination(ac: dict) -> str:
    """The actual URL a post would go to for this config, or "" if none is resolvable. For Pushover
    the buyer may leave the endpoint blank and use the public API; every other provider needs the
    buyer's own full URL."""
    if ac["endpoint"]:
        return ac["endpoint"]
    if ac["provider"] == "pushover" and ac["pushoverToken"] and ac["pushoverUser"]:
        return PUSHOVER_API
    return ""


def egress_allowed(url: str) -> bool:
    """https:// anywhere, or http:// only to localhost/127.0.0.1. Everything else is refused so the
    module can never be pointed at a plaintext external host."""
    try:
        u = urllib.parse.urlparse(url)
    except ValueError:
        return False
    host = (u.hostname or "").lower()
    if u.scheme == "https":
        return bool(host)
    if u.scheme == "http":
        return host in ("localhost", "127.0.0.1", "::1")
    return False


# ── payload construction from the SHIPPED gate verdict (no aggregate stats, ever) ─────────────────
def _engine_line(e: dict) -> dict:
    """One honest per-engine line: name, status, and the gate's OWN reason string for the
    representative contract (the proven one for a candidate; the most-traded sufficient contract for
    no-edge; the most-warmed contract otherwise). These reasons are per-contract EVIDENCE, never an
    aggregate claim."""
    status = e.get("status", "insufficient")
    contracts = e.get("contracts", []) or []
    c = None
    if status == "candidate":
        c = next((x for x in contracts if x.get("proven")), None)
    elif status == "no_edge":
        suff = [x for x in contracts if not x.get("insufficient")]
        c = max(suff, key=lambda x: x.get("trades", 0)) if suff else None
    if c is None and contracts:
        c = max(contracts, key=lambda x: x.get("bars", 0))
    c = c or {}
    return {"engine": e.get("engine", "?"), "status": status,
            "symbol": c.get("symbol", ""), "reason": c.get("reason", "")}


def _summary(report: dict) -> str:
    """The one-line headline. Candidate-count 0 renders the honest 'no edge' line — the whole point
    of TR-06 is that a no-edge day still alerts."""
    if not report.get("available"):
        return "No bars captured yet — connect your feed and let bars accumulate, then re-run."
    ec = int(report.get("engineCount", 0))
    cand = int(report.get("candidateCount", 0))
    no_edge = int(report.get("noEdgeCount", 0))
    insuf = int(report.get("insufficientCount", 0))
    if cand == 0:
        return (f"No edge on your bars today: 0 candidate, {no_edge} no-edge, {insuf} insufficient "
                f"across {ec} engines.")
    return (f"{cand} candidate engine(s) cleared the edge-gate on your bars "
            f"({no_edge} no-edge, {insuf} insufficient of {ec}) — research only, live "
            f"verification required.")


def canonical_payload(report: dict) -> dict:
    """The provider-agnostic verdict payload. STRICTLY: counts + per-engine status/reason +
    prover_sha + symbols + disclaimer. No aggregate win-rate / $ / equity anywhere."""
    return {
        "kind": "edge_gate_alert",
        "title": "Black Label Trading — edge-gate verdict",
        "summary": _summary(report),
        "engineCount": int(report.get("engineCount", 0)),
        "candidateCount": int(report.get("candidateCount", 0)),
        "noEdgeCount": int(report.get("noEdgeCount", 0)),
        "insufficientCount": int(report.get("insufficientCount", 0)),
        "engines": [_engine_line(e) for e in report.get("engines", []) or []],
        "symbols": list(report.get("symbols", []) or []),
        "prover_sha": report.get("prover_sha", S.prover_source_sha()),
        "source": "your own captured bars (this Mac)",
        "generatedUTC": report.get("generatedUTC")
        or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "disclaimer": DISCLAIMER,
    }


def _sample_payload() -> dict:
    """A fixed, honest TEST payload — proves the channel works without asserting any market result."""
    return {
        "kind": "edge_gate_alert",
        "title": "Black Label Trading — test alert",
        "summary": ("Test alert: your edge-gate alert channel is configured. Real alerts carry the "
                    "gate verdict for your bars, including 'no edge' days."),
        "engineCount": 0, "candidateCount": 0, "noEdgeCount": 0, "insufficientCount": 0,
        "engines": [], "symbols": [],
        "prover_sha": S.prover_source_sha(),
        "source": "your own captured bars (this Mac)",
        "generatedUTC": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "disclaimer": DISCLAIMER,
    }


def render_text(payload: dict) -> str:
    """The plaintext body for ntfy / a generic text webhook. Every line is verdict/evidence."""
    lines = [payload["title"], payload["summary"]]
    for e in payload.get("engines", []):
        sym = f" ({e['symbol']})" if e.get("symbol") else ""
        reason = f" — {e['reason']}" if e.get("reason") else ""
        lines.append(f"• {e['engine']}: {e['status']}{sym}{reason}")
    if payload.get("symbols"):
        lines.append("symbols: " + ", ".join(payload["symbols"]))
    lines.append(f"prover_sha: {payload.get('prover_sha', '')}")
    lines.append(payload["disclaimer"])
    return "\n".join(lines)


def render_wire(payload: dict, ac: dict) -> tuple[str, bytes, dict]:
    """Return (content_type, body_bytes, extra_headers) for the configured provider. The DESTINATION
    is chosen by _destination(); this only shapes the body. No performance figure is ever added
    here — the body is derived solely from the verdict payload."""
    provider = ac["provider"]
    text = render_text(payload)
    if provider == "pushover":
        form = {"token": ac["pushoverToken"], "user": ac["pushoverUser"],
                "title": payload["title"], "message": text[:1024]}
        body = urllib.parse.urlencode(form).encode("utf-8")
        return ("application/x-www-form-urlencoded", body, {})
    if provider == "ntfy":
        # ntfy takes the message as the raw body; Title/Tags via headers.
        return ("text/plain; charset=utf-8", text.encode("utf-8"),
                {"Title": payload["title"], "Tags": "chart_with_upwards_trend"})
    # generic webhook — send both the plaintext and the structured verdict so Slack/Discord/Shortcuts
    # and custom receivers all have something usable. "text"/"content" are the common message keys.
    obj = dict(payload)
    obj["text"] = text
    obj["content"] = text
    return ("application/json", json.dumps(obj).encode("utf-8"), {})


# ── the actual (guarded) network post ─────────────────────────────────────────────────────────────
def _post(url: str, content_type: str, body: bytes, headers: dict, timeout: float = 8.0) -> dict:
    """POST to the buyer's endpoint. Returns honest status. NEVER says 'delivered' — a 2xx means the
    channel accepted the POST (posted), not that a human saw it."""
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", content_type)
    req.add_header("User-Agent", "BlackLabelTrading/alerts")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # nosec - buyer's own endpoint
            code = getattr(resp, "status", resp.getcode())
            return {"posted": 200 <= int(code) < 300, "status": int(code),
                    "endpoint": url, "reason": "posted to your endpoint"}
    except urllib.error.HTTPError as exc:
        return {"posted": False, "status": int(exc.code), "endpoint": url,
                "reason": f"your endpoint returned HTTP {exc.code}"}
    except (urllib.error.URLError, OSError, ValueError) as exc:
        # Report the failure type only — never leak an endpoint token in an error string.
        return {"posted": False, "status": 0, "endpoint": url,
                "reason": f"could not reach your endpoint ({type(exc).__name__})"}


def _send_payload(payload: dict, ac: dict) -> dict:
    """Guarded send: enforces enabled + endpoint + egress policy BEFORE any socket. Returns a result
    dict with networked:bool so callers/tests can prove the no-egress path."""
    if not ac["enabled"]:
        return {"sent": False, "networked": False, "reason": "alerts are off",
                "summary": payload.get("summary", "")}
    url = _destination(ac)
    if not url:
        return {"sent": False, "networked": False, "reason": "no endpoint configured",
                "summary": payload.get("summary", "")}
    if not egress_allowed(url):
        return {"sent": False, "networked": False,
                "reason": "endpoint must be https:// (http allowed only for localhost)",
                "summary": payload.get("summary", "")}
    content_type, body, headers = render_wire(payload, ac)
    result = _post(url, content_type, body, headers)
    return {"sent": bool(result["posted"]), "networked": True, "status": result["status"],
            "reason": result["reason"], "endpoint": _redact(url),
            "summary": payload.get("summary", "")}


def _redact(url: str) -> str:
    """Endpoint for display — strip any query/token so a UI/log never shows a secret."""
    try:
        u = urllib.parse.urlparse(url)
        return f"{u.scheme}://{u.hostname}{u.path}" if u.hostname else url
    except ValueError:
        return url


# ── public entrypoints (used by the API server) ───────────────────────────────────────────────────
def send_gate_alert(store, symbols=None, engines=None) -> dict:
    """Re-run the SHIPPED edge-gate on the buyer's OWN bars and post the verdict to their endpoint.
    OFF/no-endpoint => returns immediately with networked:False (zero egress). A no-edge result still
    posts — that is the honest whole point."""
    cfg = store.config()
    ac = alert_config(cfg)
    # Short-circuit BEFORE touching the store's provers if we would not send anyway (no wasted work,
    # and provably no egress in the off state).
    if not ac["enabled"] or not _destination(ac):
        return {"sent": False, "networked": False,
                "reason": "alerts are off" if not ac["enabled"] else "no endpoint configured"}
    requested = [s for s in (symbols or []) if s]
    syms = S.scoped_symbols(requested) if requested else store.symbols().get("backtestable", [])
    engs = [e for e in (engines or []) if e] or cfg.get("engines", [])
    report = bltd_analytics.gate_rerun(store, syms, engs, cfg)
    report["generatedUTC"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    return _send_payload(canonical_payload(report), ac)


def test_send(store) -> dict:
    """Post a fixed TEST payload to the configured endpoint so the buyer can confirm the channel.
    Same OFF/no-endpoint guard: zero egress unless configured."""
    ac = alert_config(store.config())
    return _send_payload(_sample_payload(), ac)


def status(store) -> dict:
    """Honest, TOKEN-FREE view of the alert configuration for the UI. Never returns the Pushover
    token/user or the raw endpoint query."""
    ac = alert_config(store.config())
    dest = _destination(ac)
    return {
        "enabled": ac["enabled"],
        "provider": ac["provider"],
        "endpoint": _redact(ac["endpoint"]) if ac["endpoint"] else "",
        "configured": bool(dest),
        "egressOk": bool(dest) and egress_allowed(dest),
        "pushoverConfigured": bool(ac["pushoverToken"] and ac["pushoverUser"]),
        "note": ("Alerts post ONLY to the endpoint you configure — never to a Black Label server. "
                 "A no-edge day still alerts. No win-rate or P&L is ever sent."),
    }


# ── linter hook: render the REAL payloads so claim_linter can scan the wire text ──────────────────
def linter_sample_payloads() -> list[str]:
    """Rendered wire text for a representative set of verdicts (no-edge, candidate, empty, test),
    across every provider shape. claim_linter.scan_alert_payloads() scans these so a forbidden figure
    injected into the render path — even a computed one — fails the build, not just a source literal.

    The reports below are synthetic fixtures shaped exactly like bltd_analytics.gate_rerun output,
    including the per-contract 'win X% / net Y pts' EVIDENCE strings (honest, not aggregate claims)."""
    no_edge = {
        "available": True, "engineCount": 2, "candidateCount": 0, "noEdgeCount": 1,
        "insufficientCount": 1, "prover_sha": "deadbeefdeadbeef", "symbols": ["ES", "NQ"],
        "engines": [
            {"engine": "meanrev", "status": "no_edge", "contracts": [
                {"symbol": "ES", "trades": 41, "bars": 900, "insufficient": False, "proven": False,
                 "reason": "no edge — win 47.2% / net -3.20 pts on 41 OOS trades (p=0.612, need p<0.05)"}]},
            {"engine": "breakout", "status": "insufficient", "contracts": [
                {"symbol": "NQ", "trades": 4, "bars": 120, "insufficient": True, "proven": False,
                 "reason": "insufficient sample — 4 OOS trades, need >=30 before significance"}]},
        ],
    }
    candidate = {
        "available": True, "engineCount": 1, "candidateCount": 1, "noEdgeCount": 0,
        "insufficientCount": 0, "prover_sha": "deadbeefdeadbeef", "symbols": ["ES"],
        "engines": [
            {"engine": "structure", "status": "candidate", "contracts": [
                {"symbol": "ES", "trades": 55, "bars": 1200, "insufficient": False, "proven": True,
                 "reason": "OOS candidate — win 61.8% / net +18.40 pts on 55 trades (p=0.021); "
                           "research only, live verification required"}]},
        ],
    }
    empty = {"available": False, "engineCount": 0, "candidateCount": 0, "noEdgeCount": 0,
             "insufficientCount": 0, "prover_sha": "deadbeefdeadbeef", "symbols": [], "engines": []}

    texts: list[str] = []
    for report in (no_edge, candidate, empty):
        payload = canonical_payload(report)
        for provider in _PROVIDERS:
            ac = {"provider": provider, "pushoverToken": "t", "pushoverUser": "u"}
            _ctype, body, _hdrs = render_wire(payload, ac)
            texts.append(body.decode("utf-8", errors="replace"))
    # the test payload too
    for provider in _PROVIDERS:
        ac = {"provider": provider, "pushoverToken": "t", "pushoverUser": "u"}
        _ctype, body, _hdrs = render_wire(_sample_payload(), ac)
        texts.append(body.decode("utf-8", errors="replace"))
    return texts
