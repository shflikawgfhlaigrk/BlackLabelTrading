# Black Label Trading

A holographic macOS signal dashboard for the Black Label engine method — a multi-module scoring engine, a 13-gate risk checklist, multi-timeframe consensus, and an edge-gated engine fleet that runs on **your own** WealthCharts feed. Signals only. It never auto-trades and never moves money.

---

## Overview

Black Label Trading is a native macOS (SwiftUI/AppKit) application. It captures **your** WealthCharts session into a private store on **your** Mac and serves it locally to the chart, screener, backtester, and engine fleet. Nothing is fetched from Black Label or any third party — the app talks only to its own self-contained backend running on localhost.

The product is honest by design: when there is no data, it shows an honest empty state and never fabricates prices, win-rates, or a track record. Every number on screen is computed from your own captured bars or your own journal — none is invented. The app ships with **no data** and starts **empty** on your own accounts and your own machine.

It is a decision-support and research tool — a scenario-scoring dashboard plus a coaching/analytics suite. It is **not** a live broker feed, **not** execution, and **not** a track record.

---

## Key Features

The app is organized into a left sidebar with three groups — **Markets**, **Research**, and **Tools** — covering 16 screens.

### Markets
- **Signals** — the primary dashboard. Shows the edge-gated engine fleet, a multi-timeframe consensus panel (direction-lock requires at least 2 of the 8 timeframes to agree — 2-of-8), a composite factor score, and an honestly-graded **session ledger** (you grade each committed signal Win or Loss; running W/L, win rate, and realized P&L are computed on this Mac). Includes a real equity curve plotted from that ledger and a reachable WealthCharts connection banner.
- **Chart** — candlestick / Heikin-Ashi / Renko rendering on your live or imported bars, with indicators, drawing tools, and multi-timeframe view. Drawings persist on this Mac.
- **Grid** — a configurable grid of charts to load different symbols/timeframes side by side; empty tiles show an honest empty state.
- **Watchlists** — track your symbols and the snapshot metrics you enter.
- **Screener** — scan your watchlist symbols by the snapshot metrics you've entered, with one-tap preset scans and CSV export of results.
- **Alerts** — price / % / volume / RSI conditions on your symbols; fires a real macOS notification when your snapshot meets the condition, with optional re-arm (repeat).

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
- **Settings** — account, theme studio, WealthCharts connection, backend URL, sign-in providers, and app info.

### The engine fleet & edge gate
The bundled backend runs a roster of 9 engines — `meanrev`, `breakout`, `research`, `momentum`, `structure`, `regime`, `channel`, `context_a`, `context_b`. Each engine's edge is proven **out-of-sample on your own captured bars**. An engine fires a signal **only** when it proves real held-out OOS edge for that (engine, symbol) pair; until then it honestly shows "warming." The edge gate is on by default. Recorded fires appear in a real, edge-gated signal journal.

---

## Requirements / What You Connect

- **macOS** (native SwiftUI/AppKit desktop app).
- **Your own WealthCharts account.** The app captures your live WealthCharts feed into a private local store. You connect your own WealthCharts session from the Signals banner or from Settings. No WealthCharts credentials are bundled.
- **(Optional) Your own Google Desktop OAuth client ID** if you want the "Sign in with Google" button to perform a real login. Paste it in Settings → Sign-in providers; it is stored on this Mac and never bundled. Email/password and "Continue as guest" always work. Apple Sign-In works in the signed (provisioned) build.
- **(Optional) Your own backend host/port.** The app starts a bundled, stdlib-only Python backend on `http://127.0.0.1:8787` automatically. If you run the backend elsewhere on your own machine or network, point the Backend URL field (Settings → Live data feed) at it.
- **(Optional) A broker/platform CSV export** to populate the Journal and Analytics.

There is no Black Label server in the loop. All data lives on your Mac.

---

## First Run & Empty State

1. Launch the app and sign in (email/password, Apple in the signed build, Google with your own client ID, or continue as guest).
2. On sign-in, the app starts its bundled local backend and reports an **honest feed state** (offline / logged-out / idle / live). Because you have no data yet, the store is **empty**:
   - The engine fleet shows "Engine fleet idle / warming" — nothing arms until your own data proves (or disproves) its edge out-of-sample.
   - The Signals session ledger shows "No committed signals."
   - The Journal shows "No trades logged yet."
   - Charts and grid tiles show honest empty states — no prices are fabricated.
3. Connect your WealthCharts account (Signals banner or Settings) and let bars accumulate. As your own data flows in, engines warm up, fires get recorded, and the charts/screener/backtester populate from your captured bars.

The app never shows a value it can't ground in your real data.

---

## How to Use (main flows)

- **Capture a live feed:** Settings → Live data feed (or the Signals banner) → connect your WealthCharts account → the bundled backend captures bars into your private local store and the feed banner reflects real capture state.
- **Read signals:** open **Signals**. Watch the engine fleet for engines that have proven OOS edge on your symbols, review multi-timeframe consensus and the composite score, then commit a gate-passing signal and grade it Win/Loss to build an honest session record.
- **Research a rule:** **Strategy Builder** to compose entries → **Backtest** (with walk-forward and Monte Carlo) on your own bars → optionally turn the rule into an **Alert** or save it.
- **Practice:** **Paper Trade** to run a simulated blotter, or **Replay** to step a session bar-by-bar with no look-ahead.
- **Track performance:** log or import trades in **Journal**, then review **Analytics** for expectancy, R distributions, and seasonality.
- **Size risk:** **Calculators** for position sizing, R:R, and compounding; **Prop Firms** for evaluation-firm reference.

---

## Privacy

- The app ships with **no data** — no leads, no bars, no journal, no account info. It starts empty on your own data and accounts.
- All capture, bars, signals, journal, drawings, and account credentials are stored **privately on your Mac**. Nothing is sent to Black Label or any third party.
- The local backend serves only what your own WealthCharts session captured, over localhost. When the backend is down or your WealthCharts session is logged out, the app reports an honest offline/logged-out state and shows no bars.
- Deleting your account removes your credentials from this Mac; your local store remains under your control.
- **Signals only:** the app can read bars/ticks/fires but can never place a trade or move money.

---

## Distribution

Black Label Trading is distributed as a **Developer ID–signed, notarized** macOS application with a **Hardened Runtime** (not Mac App Store, not app-sandbox). The build is signed with a "Developer ID Application" identity and submitted to Apple's notary service, so it launches cleanly on end-user Macs via Gatekeeper.
