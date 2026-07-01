# Black Label Trading

A holographic macOS signal dashboard for the Black Label engine method — a 16-signal-module composite scoring engine, a 13-gate risk checklist, multi-timeframe consensus, a 6-tier trailing-stop management plan, and an OOS-candidate engine fleet that runs on **your own** trading feed, with **optional autonomous execution that is OFF by default and paper-first**. It places a real broker order only when you explicitly arm live mode, connect your own broker credentials, your prop firm's rules permit automation, and every risk/edge/kill gate passes — otherwise it is a signals + research tool that touches no money.

---

## Overview

Black Label Trading is a native macOS (SwiftUI/AppKit) application. Its bundled TopstepX bridge opens a product-owned browser, you sign into **your own** TopstepX session, and observed ES market data is posted into a private local webhook/store on **your** Mac. Nothing is fetched from Black Label or any third party — the app talks only to its own self-contained backend running on localhost.

The product is honest by design: when there is no data, it shows an honest empty state and never fabricates prices, win-rates, or a track record. Every number on screen is computed from your own captured bars or your own journal — none is invented. The app ships with **no data** and starts **empty** on your own accounts and your own machine.

It is a decision-support and research tool — a scenario-scoring dashboard plus a coaching/analytics suite — with an **optional autonomous-execution engine that defaults OFF and paper-first**. It is **not** a track record. Live execution is a deliberate, separately-armed step requiring your own broker credentials and a firm that permits automation; until you do that, nothing here moves money.

---

## Key Features

The app is organized into a left sidebar with three groups — **Markets**, **Research**, and **Tools** — covering 16 screens.

### Markets
- **Signals** — the primary dashboard. Shows the OOS-candidate engine fleet, a multi-timeframe consensus panel (direction-lock requires at least 2 of the 8 timeframes to agree — 2-of-8), a **16-module** composite factor score (each module a real computation on your own bars, honestly absent when its data source isn't present), a **6-tier trailing-stop plan** (suggested management ladder — copy it to your own platform, or have the optional Execution engine place it), and an honestly-graded **session ledger** (you grade each committed signal Win or Loss; running W/L, win rate, and modeled P&L are computed on this Mac), with **exportable vault-backed daily logs** (grouped by day with per-day W/L + net modeled P&L, written to a CSV in your local vault). Includes a real equity curve plotted from that ledger and a reachable feed connection banner.
- **Chart** — candlestick / Heikin-Ashi / Renko rendering on your live or imported bars, with indicators, drawing tools, and multi-timeframe view. Drawings persist on this Mac.
- **Grid** — a configurable grid of charts to load ES contracts/timeframes side by side; empty tiles show an honest empty state.
- **Watchlists** — track your symbols and the snapshot metrics you enter.
- **Screener** — scan your watchlist symbols by the snapshot metrics you've entered, with one-tap preset scans and CSV export of results.
- **Alerts** — price / % / volume / RSI conditions on your symbols; fires a real macOS notification when your snapshot meets the condition, with optional re-arm (repeat).
- **Execution** — *optional* autonomous order execution, **OFF by default and paper-first**. Arm it to have gate-passing signals turn into bracket orders (entry + stop + target + 6-tier trail) sized from your own account/risk. **Paper mode** simulates fills with no broker contact (the default). **Live mode** is a deliberate, Touch-ID-gated second step that places real orders only when: you've armed live, supplied your own broker credentials, your prop firm's ToS permits automation, and every risk gate (daily-loss halt, contract cap, drawdown guard, max-trades) + a re-proven edge pass. A master **kill switch** halts and flattens everything instantly. Every decision (placed or blocked, with the reason) is logged. Validate on a broker demo/eval account before any funded account.

### Research
- **Backtest** — test a rule set on your own historical bars with honest metrics; includes walk-forward folds and a Monte Carlo run projector.
- **Strategy Builder** — compose entry rules with no code, backtest them on your bars, save them, and turn mappable rules into alerts.
- **Patterns** — auto-detect candlestick and chart-structure patterns on your imported bars, with chart markers and support/resistance levels. A detected pattern is treated as a geometric fact, not a forecast.
- **Replay** — step a session bar-by-bar with no look-ahead, optionally overlaying a strategy's entries — coaching over your own data.
- **Paper Trade** — a practice blotter for opening/closing simulated positions at prices you enter; honest simulated P&L, clearly labeled a simulation.
- **Journal** — log trades (entry, stop, target) or import a broker/platform CSV (auto-detects symbol, side, qty, entry/exit, P&L, times, MAE/MFE, tags; only mappable rows import — nothing is invented). The dashboard math updates live.
- **Analytics** — deep performance analytics on your closed journal trades: win rate, expectancy, R distributions, time-of-day/day-of-week, per-tag and per-symbol breakdowns, and seasonality. Every stat is computed.

### Tools
- **Calculators** — position sizing, risk:reward, and a compounding projector.
- **Prop Firms** — a reference list of futures evaluation firms and their rules (confirm current terms on each firm's own site).
- **Settings** — account, theme studio, live feed / TopstepX bridge state, backend URL, sign-in providers, and app info.

### The engine fleet & research gate
The bundled backend runs an ES-only roster of 9 engines — `meanrev`, `breakout`, `research`, `momentum`, `structure`, `regime`, `channel`, `context_a`, `context_b`. Each engine can produce an **out-of-sample candidate** on your own captured ES bars, but that is research evidence, not a verified-live profit claim. A signal appears only when your local ES data clears the configured OOS candidate gate; until then it honestly shows "warming." Recorded fires appear in a real, research-gated signal journal for manual review and grading.

---

## Requirements / What You Connect

- **macOS** (native SwiftUI/AppKit desktop app).
- **Your own Topstep / TopstepX account.** The app opens a product-owned TopstepX browser, you sign in there, and the bridge reads the market data already feeding your session into the local webhook/store. No Topstep credentials are bundled or stored by Black Label Trading.
- **(Optional) Your own Google Desktop OAuth client ID** if you want the "Sign in with Google" button to perform a real login. Paste it in Settings → Sign-in providers; it is stored on this Mac and never bundled. Email/password and "Continue as guest" always work. Apple Sign-In works in the signed (provisioned) build.
- **(Optional) Your own backend host/port.** The app starts a bundled, stdlib-only Python backend on `http://127.0.0.1:8787` automatically. If you run the backend elsewhere on your own machine or network, point the Backend URL field (Settings → Live data feed) at it.
- **(Optional) A broker/platform CSV export** to populate the Journal and Analytics.

There is no Black Label server in the loop. All data lives on your Mac.

---

## First Run & Empty State

1. Launch the app and sign in (email/password, Apple in the signed build, Google with your own client ID, or continue as guest).
2. On sign-in, the app starts its bundled local backend and reports an **honest feed state** (offline / logged-out / idle / live). Because you have no data yet, the store is **empty**:
   - The engine fleet shows "Engine fleet idle / warming" — nothing arms until your own data produces an OOS candidate or fails the gate.
   - The Signals session ledger shows "No committed signals."
   - The Journal shows "No trades logged yet."
   - Charts and grid tiles show honest empty states — no prices are fabricated.
3. Open the bundled TopstepX bridge (Signals banner or Settings), sign into your own TopstepX session, and let ES bars accumulate through the local webhook. As your own ES data flows in, engines warm up, fires get recorded, and the charts/backtester populate from your captured bars.

The app never shows a value it can't ground in your real data.

---

## How to Use (main flows)

- **Capture a live feed:** Settings → Live data feed (or the Signals banner) → open the bundled TopstepX bridge → sign into your own TopstepX session → the bridge posts observed ES bars into your private local store and the feed banner reflects real capture state.
- **Read signals:** open **Signals**. Watch the engine fleet for OOS candidates on ES, review multi-timeframe consensus and the composite score, then commit a gate-passing research signal and grade it Win/Loss to build an honest session record.
- **Research a rule:** **Strategy Builder** to compose entries → **Backtest** (with walk-forward and Monte Carlo) on your own bars → optionally turn the rule into an **Alert** or save it.
- **Practice:** **Paper Trade** to run a simulated blotter, or **Replay** to step a session bar-by-bar with no look-ahead.
- **Track performance:** log or import trades in **Journal**, then review **Analytics** for expectancy, R distributions, and seasonality.
- **Size risk:** **Calculators** for position sizing, R:R, and compounding; **Prop Firms** for evaluation-firm reference.

---

## Privacy

- The app ships with **no data** — no leads, no bars, no journal, no account info. It starts empty on your own data and accounts.
- All capture, bars, signals, journal, drawings, and account credentials are stored **privately on your Mac**. Nothing is sent to Black Label or any third party.
- The local backend serves only what your own TopstepX bridge or webhook sender captured, over localhost. When the backend is down or your TopstepX session is logged out / not producing data, the app reports an honest offline/idle state and shows no bars.
- Deleting your account removes your credentials from this Mac; your local store remains under your control.
- **Execution is OFF by default:** the app reads bars/ticks/fires and places **no** trade and moves **no** money unless you explicitly arm live execution (a separate Touch-ID-gated step) with your own broker credentials on a firm that permits automation. Paper mode (simulated fills, no broker contact) is the default; a master kill switch halts and flattens everything at any time.

---

## Distribution

Black Label Trading is distributed as a **Developer ID–signed**, **Hardened Runtime**, **non-sandboxed** macOS application (not Mac App Store, not app-sandbox) — the same distribution path Sovereign and Homefront use. The build is signed with a "Developer ID Application" identity (Team `745ZPGFRA5`). Notarization is the explicitly gated final step: until the submit-and-staple to Apple's notary service completes, the on-disk Developer-ID build is signed but **not yet notarized** — Gatekeeper currently treats it as an unnotarized Developer-ID app (`spctl` rejects it) and no stapled ticket exists on the build. Once notarized and stapled, it will launch cleanly on end-user Macs via Gatekeeper.
