# Prop-Firm Broker Connection — Design Spec

**Date:** 2026-06-26
**Product:** Black Label Trading (`~/BlackLabelTrading`) — native macOS SwiftUI app + local Python backend
**Status:** Approved direction (brainstorming complete) → next step: implementation plan

---

## 1. Problem & goal

The product is marketed as "open the app and connect your brokerage." **Today that does not exist.** Verified in source:

- Zero brokerage-connection code anywhere (no Tradovate / Rithmic / ProjectX / MetaTrader / NinjaTrader / order-placement).
- The in-app "Connect WealthCharts" button only writes username/password to `UserDefaults` + Keychain — **no network call, no login, no validation** (`Sources/Model.swift:820-862`, `Sources/Screens.swift:1147-1150`). The app's own text admits *"A real WealthCharts data feed is not wired in this build"* (`Sources/Screens.swift:1104`).
- A separate real pipeline exists (local Python backend + Chrome-DevTools-Protocol scrape of the buyer's own WealthCharts tab → ES bars in SQLite) but is data-only, ES-only, and does not run end-to-end as shipped (the launcher starts the API + Chrome but never starts the capture daemon).
- The storefront advertises "adapters for Tradovate, CQG, Rithmic (paper-proven)" that **do not exist** — a live honesty gap to fix in parallel.

**Goal:** Let a **funded / prop futures trader** connect the platform their prop firm gives them and stream their own **live market + account data** into the existing signal engines — read-only first, with order execution architected as a sealed, per-firm-gated seam for later.

### The reframing that defines the design

A prop trader does not connect to "their firm." They connect to the **back-end connectivity rail their firm resells**, using firm-issued credentials. There are three rails:

| Rail | Firms (current, 2026) | Mac-direct read-only? | Real-time data | Build decision |
|---|---|---|---|---|
| **Rithmic** | **Apex** (largest), Bulenox, Take Profit Trader, Earn2Trade/Elite, Lucid, The Trading Pit, Legends (partial) | ✅ protobuf over WSS (free MIT `async_rithmic`) | ✅ **bundled** in the trader's existing subscription | **Build (v2)** — coverage king, OWN-IT-cleanest. Needs Rithmic conformance certification (process, ~days for read-only scope). |
| **ProjectX / TopstepX** | **Topstep only** (ProjectX went Topstep-exclusive Feb 28 2026; former partners cut off) | ✅ REST + SignalR/WSS (existing `project-x-py` SDK) | ✅ L1 included; L2/DOM +$38/mo | **Build first (v1)** — fastest, sanctioned, read-only blessed in writing, no gatekeeping. |
| **Tradovate** | MyFundedFutures, Tradeify, TradeDay | ❌ **No — by policy** (API excludes prop/eval accounts; returns empty array) | n/a | **Do NOT build a prop adapter.** Honest "not possible" capability card. Retail (non-prop) Tradovate may be added later for non-prop users. |

**Honest corrections to the original ask:**
- **MetaTrader (MT4/MT5) is not a futures-prop platform** — it's forex/CFD retail. A funded futures trader will not use it. Out of scope for the prop use-case (could serve non-prop users later via a local Windows bridge, but that is a separate, lower-value track).
- **NinjaTrader and WealthCharts are front-ends** that sit on top of Rithmic/Tradovate. We connect the underlying **rail**, not the chart app. WealthCharts CDP capture remains as an existing supplementary data source.

### The binding constraint is ToS, not technology

On every rail, a native macOS app + local Python backend connects **directly, no Windows**. The real limits are firm rules:

- **Read-only / signals with manual execution is within ToS at all major firms** — their prohibitions target *order origination*, not *data reads*. Only Topstep (official API) and Apex (paid 2nd-login analytics) bless read-only **in writing**; for the rest it is permitted-by-absence-of-prohibition. → Lowest risk = **never place an order in v1**.
- **The backend MUST run on the trader's own Mac — never a VPS/cloud/remote server** (Topstep explicitly bans VPS/VPN/remote servers; violation = account termination). This matches the existing local-backend architecture.
- **Execution later is firm-gated:** Apex / Take Profit Trader / Earn2Trade ban bots outright; Topstep allows monitored automation on a personal device only; MyFundedFutures/Bulenox/Tradeify permit supervised automation. The sealed-execution gate must encode this per-firm.
- **Copy-trade correlation trap:** one signal driving multiple accounts is flagged as prohibited copy trading at Apex/Bulenox/MFFU even if all accounts are the trader's own. Design for one-signal → one-account, human-decisioned.

---

## 2. Scope

**In scope (v1 — ProjectX/Topstep):**
- ProjectX/TopstepX read-only adapter: auth, live L1 quotes + trades (SignalR Market Hub), historical bars (REST), positions/balance/orders (SignalR User Hub + REST), normalized into the existing store schema.
- "Select your prop firm" connection flow, honest per-firm capability cards, and a blocking ToS/permission acknowledgment.
- Generalize the dead "Connect WealthCharts" UI into a "Connect your data source / prop firm" surface; keep WealthCharts CDP capture as one source.
- Sealed execution seam (interfaces compiled in, hard-disabled).

**In scope (v2 — Rithmic, started in parallel day 1):**
- Rithmic read-only adapter (TICKER + PNL + read-only ORDER/HISTORY plants) via `async_rithmic`.
- Rithmic conformance certification for the read-only scope (begin on free Rithmic Test system immediately).

**Out of scope (this spec):**
- Any order execution (sealed only).
- Tradovate prop adapter (policy dead-end — honest block only).
- MetaTrader MT4/MT5 and NinjaTrader-desktop Windows bridges (separate non-prop track).
- Fixing the storefront's false adapter claims (tracked as a parallel cleanup task, not part of this build).
- Relaxing the ES-only engine scope (engines stay as-is in v1; adapters may carry more symbols, but the existing edge-gate/engine fleet is unchanged).

---

## 3. Architecture (Approach A — backend-owned adapter layer)

**Invariant:** the Swift app talks **only** to the local Python backend on `127.0.0.1`. The backend owns every adapter and presents one normalized local API. The app never learns which rail or transport is behind it. This is the same pattern already used for WealthCharts CDP capture — broker rails become additional **data sources** behind the existing bar/quote contract.

```
SwiftUI app ──HTTP/WS──> local Python backend (trader's own Mac) ──> rail
  FeedClient.swift          bltd_api.py + adapters                    ProjectX/TopstepX (HTTPS+SignalR)
  (127.0.0.1:8793)          normalize → bars/wc_live/positions        Rithmic (protobuf/WSS)
                                                                       WealthCharts (CDP, existing)
```

### 3.1 `BrokerAdapter` interface (Python, backend)

One protocol, one concrete adapter per rail. Read methods ship now; execution methods exist but are sealed (Section 6).

```python
class BrokerAdapter(Protocol):
    key: str                                   # "projectx" | "rithmic" | "wealthcharts"

    def capabilities(self) -> Capabilities     # drives honest UI; never hardcoded in the app
    async def connect(self, creds: Creds) -> Session
    async def health(self) -> HealthStatus     # CONNECTED | DELAYED | RAIL_DOWN | UNAVAILABLE | NEEDS_SETUP
    async def disconnect(self) -> None

    # read-only (PHASE 1 — ships now), normalized to existing schema
    async def subscribe_quotes(self, symbols: list[str], on_quote) -> SubId
    async def subscribe_bars(self, symbol: str, unit: str, on_bar) -> SubId
    async def fetch_bars(self, symbol: str, unit: str, rng: Range) -> list[Bar]
    async def fetch_positions(self) -> list[Position]
    async def fetch_balance(self) -> Balance
    async def fetch_orders(self) -> list[Order]               # read-only state

    # execution (PHASE 2 — SEALED; default raises)
    async def place_order(self, intent: OrderIntent) -> OrderResult   # raises ExecutionDisabled
    async def cancel_order(self, order_id: str) -> OrderResult        # raises ExecutionDisabled
    async def modify_order(self, order_id: str, changes) -> OrderResult  # raises ExecutionDisabled

@dataclass
class Capabilities:
    live_quotes: bool
    realtime: bool            # True=real-time; False=delayed (must be badged)
    bars: bool
    depth_l2: bool
    positions: bool
    balance: bool
    can_execute: bool         # platform CAN execute (not that the product WILL)
    execution_allowed_by_firm: bool | None   # firm ToS permits automation (None=unknown/verify)
    transport: str            # "cloud"
    requires_windows: bool     # always False on the prop rails
```

`Capabilities` is the single source of truth for the UI. The app renders availability, the "Delayed" badge, "not possible" cards, and the execution warning **off this struct** — never off hardcoded assumptions.

### 3.2 Normalization into the existing store

Adapters normalize each rail's native quote/bar into the **existing** schema so the engines, `LiveFactorEngine`, and `FeedClient` work unchanged:

- `bars` table — `(symbol TEXT, ts, o, h, l, c, [v, delta], PRIMARY KEY(symbol, ts))`, append-only, index `bars_sym_ts`. **Honor the append-only / permanent-bars rule** — adapters never overwrite history.
- `wc_live` — last-tick per symbol (generalize name/meaning to "last live tick", keep the column shape).
- `fires` — unchanged (engine output).
- New: `positions`, `balance` read models served to the app for the account dashboard.
- Symbol normalization reuses the existing `normalize_symbol` / `is_es_symbol` layer (`bltd_store.py:92-117`). ProjectX/Rithmic contract IDs map to the customer-facing futures token (e.g. `ES`).

ProjectX delivers **no native real-time bars** → the adapter aggregates `GatewayTrade`/`GatewayQuote` ticks client-side (or polls `History/retrieveBars` with `includePartialBar`). Rithmic's TICKER plant delivers **native live time bars**.

### 3.3 Backend local API (uniform surface)

Extend `bltd_api.py` with one rail-agnostic surface the Swift app consumes:

- `GET /sources` → available rails + each rail's `Capabilities` + connection state.
- `POST /connect {rail, creds}` → authenticate; creds go straight to Keychain (never logged).
- `GET /status` → normalized `CaptureStatus` / `FeedState` (reuse existing enum).
- `GET /bars`, `GET /quote`, `WS /stream` → existing bar/quote contract (reuse `FeedBars`/`FeedTypes` decode).
- `GET /positions`, `GET /balance`, `GET /orders` → account read models.
- `POST /order` → **403 until the double execution gate is open** (Section 6).

Auth note: the existing `/auth/signin` mints a *local backend* token (any non-empty creds → static token, `bltd_api.py:142-144`). That stays as the app↔backend local session. The **rail** credentials (ProjectX username+API key; Rithmic user/password/system/gateway) are separate and live in Keychain.

### 3.4 Swift app integration

- `FeedClient.swift` gains rail-aware status but keeps its decode contract (`FeedTypes.swift` is test-locked — extend additively, don't break).
- `FeedState` reused; add `.unavailable(reason:)` for Tradovate-prop / unsupported firms.
- The WealthCharts panel/sheet (`Screens.swift` `ConnectWealthChartsSheet`, `WealthChartsPanel`, `wealthChartsBanner`) generalizes into the **"Connect your prop firm / data source"** flow (Section 4). The dead local-only save is replaced by a real `POST /connect`.

---

## 4. "Select your prop firm" flow (honest by construction)

1. **Select firm** — searchable list of supported firms.
2. **Resolve rail** — map firm → rail. Where the firm locks the platform at purchase (Apex: Rithmic / Tradovate / WealthCharts; TPT: Rithmic / Tradovate), ask *"Which platform did you choose when you bought the account?"* (cannot be changed mid-account).
3. **Capability card** (rendered from `Capabilities`) — green/red for *Read positions & balance*, *Live L1 quotes*, *L2/DOM*, plus a plain-language line. For Tradovate-prop firms it states plainly: *"Your firm runs on Tradovate, which doesn't give individual traders API access to a funded account. No app can connect directly."*
4. **ToS / permission gate** (blocking acknowledgment):
   - *"This app reads your account and market data and shows you signals. It does not place trades. You click every button."*
   - Surfaces the *firm's own* automation stance before connecting.
5. **Credential entry → Keychain.** ProjectX: username + self-generated API key. Rithmic: firm-issued user / password / system_name / gateway. (No OAuth consent screen exists on these rails — the trader self-authorizes with their own credentials.)
6. **Cost disclosure** (honest; the trader pays, the app never bills): e.g. *"ProjectX API Access ~$14.50/mo with code `topstep`, billed by ProjectX. Rithmic data is included in your firm subscription. We never charge you for data."*

### Per-firm capability + permission matrix (drives the gate)

| Firm | Rail | Direct read? | Real-time included | Future-execution permission (warning only; not v1) |
|---|---|---|---|---|
| Topstep | ProjectX/TopstepX | ✅ | L1 yes; L2 +$38/mo | Monitored automation OK — **personal device only, no VPS** |
| Apex | Rithmic | ✅ | bundled (sim) | **Bans full automation on funded/PA** — human-in-loop only |
| Bulenox | Rithmic | ✅ | bundled | Permissive (no true HFT) |
| Take Profit Trader | Rithmic | ✅ | bundled | **Manual only — all bots banned** |
| Earn2Trade/Elite | Rithmic | ✅ | bundled | **EAs/automation banned** |
| Lucid, The Trading Pit | Rithmic | ✅ | bundled | Verify per firm |
| MyFundedFutures | Tradovate | ❌ no API | n/a | (moot — no API) |
| Tradeify, TradeDay | Tradovate | ❌ no API | n/a | (moot — no API) |
| Legends | Rithmic (partial) | ⚠️ | UNCONFIRMED | UNCONFIRMED — manual expected |

---

## 5. Real-time data & OWN-IT

- **Real-time L1 is included** on both real rails for prop accounts (ProjectX L1 included; Rithmic real-time bundled in the trader's subscription). This satisfies the "real-time by default" requirement **without** the retail-Tradovate CME ILA (~$290/mo) problem.
- **OWN-IT exception (confirmed):** the signal engine stays 100% in-house/free. The brokerage connection + data license is a paid dependency that **cannot be self-hosted** — but it is the **trader's own brokerage cost** (ProjectX ~$14.50/mo; Rithmic bundled). The app/company buys nothing. Rithmic additionally requires a one-time **conformance certification** (a process, not a recurring fee).
- **Honesty rules carried through:** delayed data (if ever) is always badged; `RAIL_DOWN` is a first-class state (never present stale bars as live); bars stay append-only; the app ships empty on the trader's own account (no bundled data).

---

## 6. Execution-later switch (sealed seam, nothing built now)

Build the seam, not the limb:

1. **Interfaces present, bodies sealed.** `place_order/cancel_order/modify_order` exist from day one; default raises `ExecutionDisabled`. `OrderIntent`/`OrderResult` types are defined now so callers compile and tests exist — no UI wired.
2. **Double gate.** A global `EXECUTION_ENABLED=false` (signals-only) **and** a per-rail/per-firm execution flag. `/order` returns **403** until both are set **and** `Capabilities.execution_allowed_by_firm` is true. Apex / TPT / Earn2Trade can never pass the firm check.
3. **Credential scoping mirrors the gate.** Phase 1 captures only read-scoped credentials. Trading-scoped credentials/tokens are requested only behind the execution flag.
4. **Demo-first.** First execution lands on demo/sim endpoints (ProjectX sim, Rithmic Test) before any live host. Same code, swap host.
5. **Exchange-policy fields baked into `OrderIntent` now.** ProjectX/Tradovate/Rithmic require `is_automated=true` for non-human orders — carried in the type from the start. Include `clOrdId`/`customTag` for reconciliation.

Result: enabling execution per-firm later = flip a flag, capture the trading credential, point at demo, wire a confirm-required button. Zero changes to the adapter contract or the app↔backend protocol.

---

## 7. Components & isolation

| Unit | Responsibility | Depends on |
|---|---|---|
| `BrokerAdapter` protocol + `Capabilities`/`Creds`/`Session` types | The contract every rail implements | — |
| `ProjectXAdapter` | TopstepX REST + SignalR; normalize to store | `BrokerAdapter`, SignalR client (`pysignalr`/`project-x-py`) |
| `RithmicAdapter` (v2) | Rithmic plants; normalize to store | `BrokerAdapter`, `async_rithmic` |
| `WealthChartsSource` | Existing CDP capture, wrapped to the same contract | existing `bltd_capture.py` |
| `AdapterRegistry` + firm→rail map | Resolve firm → rail → adapter; serve `/sources` | adapters |
| `bltd_api.py` (extended) | Uniform local API + Keychain creds + execution gate | registry |
| Store (extended) | `bars`/`wc_live`/`fires` + `positions`/`balance` | SQLite |
| Swift connect flow | Select-firm → capability card → ToS gate → creds | `FeedClient`, `/connect`, `/sources` |

Each unit is independently testable: an adapter can be exercised against a recorded rail fixture without the app; the registry/firm-map is pure data; the gate is a pure predicate.

---

## 8. Error handling & honesty states

- `RAIL_DOWN` / terminal logout / session drop → surface explicitly; never fabricate or show stale bars as live (reuse `FeedState.loggedOut`/`.offline`/`.idle`; add `.unavailable`).
- ProjectX JWT ~24h → revalidate via `Auth/validate` before expiry; 401 → re-login.
- Rithmic 3+ concurrent logins → CME "professional" reclassification (~10× fees): be the sole login or use the firm's 2nd-login add-on; detect and warn.
- Unsupported firm / Tradovate-prop → honest `UNAVAILABLE` capability card, not a silent failure.
- Cost/permission disclosures are shown before connect, never after.

---

## 9. Testing

- **Adapter unit tests** against recorded rail fixtures (ProjectX REST/SignalR payloads; Rithmic protobuf frames) → assert normalization to the exact `bars`/quote schema (`FeedTypes` decode stays green).
- **Capability/gate tests:** `/order` returns 403 under every flag combination except (global ON ∧ per-firm ON ∧ firm-allowed); Apex/TPT/Earn2Trade never reach executable state.
- **Firm→rail map tests:** every supported firm resolves to a rail + correct capability card; Tradovate-prop firms resolve to `UNAVAILABLE`.
- **Honesty tests:** delayed data badged; ship-empty on a cold account; no fabricated positions/quotes; append-only bars never overwritten.
- **Regression-lock** the existing `FeedTypes`/`FeedBars` decode contract (already test-locked) — additive only.

---

## 10. Build order

1. **v1 — ProjectX/TopstepX (ships first):** adapter contract + `ProjectXAdapter` + backend local API + Keychain creds + select-firm flow + capability cards + ToS gate + sealed execution seam. Proves the whole architecture through a sanctioned, gatekeeper-free, read-only-blessed API.
2. **In parallel from day 1:** begin Rithmic developer registration + conformance on the free Rithmic Test system (read-only scope).
3. **v2 — Rithmic adapter:** lands right after v1; unlocks Apex + the whole Rithmic stable.
4. **Parallel cleanup (separate task):** fix the storefront's false "adapters included" claims to match reality.

---

## 11. Key risks

- **ProjectX is now Topstep-only** — re-verify before claiming any other firm on this rail; former partners were cut off Feb 2026.
- **Rithmic conformance lead-time** — read-only scope clears in days, but it is a gate before production.
- **Tradovate-prop is a permanent dead-end** — don't promise it; the capability card must say so plainly.
- **ToS, not tech, is the wall for execution** — keep v1 strictly read-only; the execution gate must encode per-firm permission.
- **No VPS/cloud** — the backend must run on the trader's own Mac (Topstep ToS). Don't offer hosted mode.
- **Storefront/app honesty gap** — until the site is fixed it advertises non-existent adapters; flag for parallel fix.
