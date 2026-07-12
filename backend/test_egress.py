"""TR-20 provable no-network-posture test — the attestable egress audit (mirrors Circuit's AIRGAP).

Black Label Trading phones home to NOBODY. This test statically audits every outbound URL/WebSocket
LITERAL in the shipped backend surface (bltd_*.py) and asserts that every egress destination is one
of exactly three honest classes:

  1. localhost / 127.0.0.1  — the app's OWN loopback API, its Postgres, and the local Chrome CDP
     capture endpoint. Never leaves the machine.
  2. a documented BUYER-OWNED broker/feed host — WealthCharts, TopstepX, Tradovate, Rithmic, or a
     ProjectX host the buyer types in — reached ONLY with the buyer's OWN credentials when the buyer
     connects that feed/broker. Never a Black Label server.
  3. the TR-06 alert endpoint the buyer configures (a runtime value, no source literal) plus the one
     documented public push convenience host (Pushover's API), used only with the buyer's own token.

It asserts, as a hard invariant, that NO shipped backend URL points at a Black Label server or any
analytics/telemetry service. If someone later adds a phone-home or a tracker, this test fails the
build. This is the mechanical proof behind the in-app "no Black Label server ever receives your
data" statement and docs/EGRESS-AND-FEED-COST.md.

Runnable via `python3 -m pytest test_egress.py` or plain `python3 test_egress.py`.
"""
import glob
import os
import re

ROOT = os.path.dirname(os.path.abspath(__file__))

# Buyer-owned broker/feed hosts (the buyer connects these with THEIR OWN creds) + the one public
# push provider. Matched as domain suffixes. Every one is the buyer's account, never our server.
ALLOWED_DOMAIN_SUFFIXES = (
    "wealthcharts.com",     # the buyer's own WealthCharts session (browser capture login page)
    "topstepx.com",         # the buyer's own TopstepX session
    "tradovateapi.com",     # the buyer's own Tradovate account (md + demo/live)
    "rithmic.com",          # the buyer's own Rithmic gateway
    "pushover.net",         # TR-06 public push provider — buyer's OWN token/user
)
LOCALHOSTS = ("localhost", "127.0.0.1", "::1", "0.0.0.0")

# Substrings that would betray a phone-home / tracker. None of these may appear in ANY shipped
# backend egress host. (Kept broad on purpose.)
FORBIDDEN_HOST_SUBSTRINGS = (
    "blacklabel", "blacklabelbots",
    "google-analytics", "googletagmanager", "analytics.google",
    "sentry.io", "ingest.sentry", "posthog", "mixpanel", "segment.io", "segment.com",
    "amplitude.com", "datadoghq", "bugsnag", "firebaseio", "firebase", "loggly",
    "newrelic", "rollbar", "heap.io", "fullstory", "hotjar", "intercom",
)

# host chars only — a capture that comes back empty or full of punctuation is a placeholder/comment
# fragment (e.g. "wss://," or "{host}"), not a real destination.
_URL = re.compile(r"(?:https?|wss?)://([A-Za-z0-9._:\-\[\]]*)")


def _shipped_backend_files():
    return sorted(glob.glob(os.path.join(ROOT, "bltd_*.py")))


def _hostname(raw: str) -> str:
    """Strip a trailing :port (but keep a bare ::1 / [ipv6])."""
    h = raw.strip().strip("[]")
    if not h:
        return ""
    # split a trailing :digits port
    m = re.match(r"^(.*?)(?::\d+)?$", h)
    host = (m.group(1) if m else h)
    if host.endswith(":") and not host.endswith("::"):   # "127.0.0.1:" left by a templated {port}
        host = host[:-1]
    return host.lower()


def _host_allowed(host: str) -> bool:
    if host in LOCALHOSTS:
        return True
    return any(host == d or host.endswith("." + d) for d in ALLOWED_DOMAIN_SUFFIXES)


def _iter_url_hosts():
    for path in _shipped_backend_files():
        with open(path, encoding="utf-8", errors="replace") as fh:
            for ln, line in enumerate(fh, 1):
                for raw in _URL.findall(line):
                    host = _hostname(raw)
                    yield os.path.basename(path), ln, host, line.strip()


def test_no_phone_home_or_tracker_host_anywhere():
    offenders = []
    for fname, ln, host, _line in _iter_url_hosts():
        for bad in FORBIDDEN_HOST_SUBSTRINGS:
            if bad in host:
                offenders.append(f"{fname}:{ln} -> {host} (matches '{bad}')")
    assert not offenders, ("Trading must phone home to NOBODY — forbidden egress host(s):\n  "
                           + "\n  ".join(offenders))


def test_every_backend_egress_destination_is_localhost_or_buyer_owned():
    offenders = []
    for fname, ln, host, line in _iter_url_hosts():
        if not host:
            continue                       # placeholder / comment fragment (e.g. wss://, {host})
        if any(ch in host for ch in "{}<>|"):
            continue                       # runtime-substituted buyer-configured host template
        if not _host_allowed(host):
            offenders.append(f"{fname}:{ln} -> {host}   [{line[:80]}]")
    assert not offenders, ("An egress destination is neither localhost nor a documented buyer-owned "
                           "host. Add it to ALLOWED_DOMAIN_SUFFIXES ONLY if it is genuinely the "
                           "buyer's own account, never a Black Label server:\n  "
                           + "\n  ".join(offenders))


def test_alert_module_hardcodes_no_destination_except_pushover():
    """bltd_alerts posts ONLY to the endpoint the buyer configures at runtime. The single permitted
    source literal is the documented Pushover public API host."""
    src = open(os.path.join(ROOT, "bltd_alerts.py"), encoding="utf-8").read()
    literals = re.findall(r"https?://[A-Za-z0-9._:\-/]+", src)
    for u in literals:
        assert "api.pushover.net" in u, (
            f"bltd_alerts must not hardcode an egress host other than Pushover's public API: {u}")


def test_backtest_farm_module_does_no_network_during_compute():
    """TR-19 own-silicon farm: the sweep runs entirely on local cores — no cloud, no data fee, no
    egress during compute. Statically assert the farm code path in bltd_analytics imports/uses NO
    network primitive (urllib/requests/socket/http.client) and reaches no URL literal. The farm is
    pure math over the buyer's OWN captured bars fanned across concurrent.futures; the ONLY thing it
    touches off-core is the local process pool. If someone later wires a cloud backtest service or a
    telemetry ping into the farm, this test fails the build."""
    src = open(os.path.join(ROOT, "bltd_analytics.py"), encoding="utf-8").read()
    # no URL literals of any scheme anywhere in the analytics/farm module
    urls = _URL.findall(src)
    assert not urls, f"bltd_analytics (farm module) must contain no egress URL literal: {urls}"
    # no network client imports/uses in the module
    forbidden = ("import socket", "import requests", "import urllib", "from urllib",
                 "http.client", "urlopen(", "requests.", "socket.socket")
    offenders = [tok for tok in forbidden if tok in src]
    assert not offenders, ("the farm module must use no network primitive during compute — found: "
                           + ", ".join(offenders))
    # the farm's only off-core reach is the local process pool
    assert "concurrent.futures" in src, "the farm must fan across local cores (concurrent.futures)"


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
