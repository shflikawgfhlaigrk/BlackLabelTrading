# Black Label Trading — Feed cost & network egress (TR-20)

This document is the plain-truth statement of two things buyers ask about a trading app: **what the
data feed actually costs**, and **where the app sends data**. Both are backed by mechanical checks in
the repo, not marketing.

## Feed cost — you already own the feed

Black Label Trading does **not** resell market data and does **not** run a data subscription you pay
us for. It reads the feed **you already have**:

- The app opens **your own** WealthCharts or TopstepX session in a product-owned browser profile on
  your Mac. You sign in with your credentials. The app observes the market-data frames that session
  already streams and writes them into a local store on this machine.
- Because the bars come from **your** already-open session, there is **no extra exchange fee** to run
  the app. In particular there is **$0** additional CME "non-professional real-time" add-on to buy on
  our account — you are not on our data entitlement, you are on yours.
- Optional broker connections (Tradovate, Rithmic, a ProjectX host) are **your** accounts with **your**
  credentials, used only if you choose to connect them. We never sit between you and your broker.

What it is: a dashboard + edge-gate that runs on the bars your own session produces.
What it is **not**: a data vendor, a resold feed, or a service that charges you for quotes.

## Network egress — the app phones home to nobody

The app sends data to exactly three classes of destination, and **none of them is a Black Label
server**:

1. **localhost / 127.0.0.1** — the app's own loopback API, its local store, and the local Chrome
   capture endpoint. This traffic never leaves the machine.
2. **Your own broker / feed hosts** — WealthCharts, TopstepX, Tradovate, Rithmic, or a ProjectX host
   you enter — reached only with **your** credentials, only when **you** connect that feed/broker.
3. **Your own alert endpoint** (the TR-06 honest-alert channel) — an ntfy topic, a webhook, a
   Shortcuts recipe, or a Pushover account **you** configure. It is **off by default**; with no
   endpoint set, the app makes no alert network call at all. Alerts post only to the endpoint you
   own, never through a Black Label relay, and never carry a win-rate or P&L figure.

There is **no Black Label analytics, no telemetry, no crash-reporter, no tracker, and no
"call-home"** anywhere in the shipped backend. Your captured bars, your journal, and your gate
verdicts stay on your Mac.

## How this is proven (not just asserted)

- **`backend/test_egress.py`** statically audits every outbound URL/WebSocket literal in the shipped
  backend (`bltd_*.py`) and fails the build if any destination is a Black Label server or a known
  analytics/telemetry host, or is anything other than localhost / a documented buyer-owned host / the
  buyer-configured alert endpoint. If anyone later adds a phone-home, the test goes red.
- **`backend/bltd_alerts.py`** hardcodes no destination except the documented public Pushover API
  host; every other alert target is the URL you type in. `test_egress.py` asserts this.
- **`backend/claim_linter.py`** additionally renders the real alert payloads and fails the build if a
  forbidden aggregate figure (win-rate, $ P&L, return) ever appears in one.

## Entitlements posture (Developer ID, hardened runtime)

Trading ships **outside** the App Store via Developer ID because it runs its own bundled Python data
backend (a loopback server + a browser-capture helper), which the App Store sandbox forbids. The
signed entitlements (`Sources/app-developerid.entitlements` for the local build,
`Sources/app-devid.entitlements` for a Developer-ID release) declare:

- `com.apple.security.network.client` — **outgoing** connections only (loopback capture, your broker/
  feed, your alert endpoint). This is the entitlement `codesign -d --entitlements` reports on the
  installed app.
- **No** `com.apple.security.network.server` entitlement is required — the loopback API binds
  `127.0.0.1` and needs no inbound-server grant.
- `com.apple.security.cs.disable-library-validation` + `allow-dyld-environment-variables` — the
  hardened-runtime exceptions the bundled Python backend needs to run.

Client-only, loopback-server, no inbound grant: the entitlement set documents "reaches out to the
endpoints you point it at; accepts no inbound network server role."

Verify on the installed app:

```sh
codesign -d --entitlements - "/Applications/Black Label Trading.app" | grep network
# -> com.apple.security.network.client  (and no network.server)
```
