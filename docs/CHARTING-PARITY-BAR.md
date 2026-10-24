# Charting parity bar (TR-07)

The **defined, checked-in target** for in-app charting depth. This is the bar the Trading product
commits to matching against a mainstream charting terminal (TradingView-class), implemented on **both
render paths** from the **same pure math**. The machine-readable source of truth is the
`ChartParityBar` constant in `Sources/Charting.swift`; this doc is its human map. Tests assert the
implementation meets this bar (`Tests/main.swift` charting-parity tests).

## Floors

- **Indicators: ≥ 8** (`ChartParityBar.minIndicators`)
- **Timeframes: ≥ 5** (`ChartParityBar.minTimeframes`)

## Shipped indicator set (9 — meets/exceeds the ≥8 floor)

Every indicator is real math on the buyer's OWN bars (nothing downloaded/invented), computed once and
drawn identically on both paths.

| # | Indicator | Math (module) | Live path (`ChartScreen`) | Headless path (`ChartRender`) |
|---|-----------|---------------|---------------------------|-------------------------------|
| 1 | SMA | `Indicators.sma` (Backtest.swift) | `ind.sma` overlay | `RenderIndicators.sma` overlay |
| 2 | EMA (2 lengths) | `Indicators.ema` | `ind.ema` overlay | `RenderIndicators.ema1/ema2` |
| 3 | VWAP | `ChartIndicators.vwap` (Charting.swift) | `ind.vwap` overlay | `RenderIndicators.vwapWindow` |
| 4 | Bollinger Bands | `ChartIndicators.bollinger` | `ind.bollinger` overlay | `RenderIndicators.bollinger` |
| 5 | RSI | `Indicators.rsi` | `ind.rsi` sub-pane | RSI sub-pane |
| 6 | MACD | `ChartIndicators.macd` | `ind.macd` sub-pane | MACD sub-pane |
| 7 | ATR | `Indicators.atr` | `ind.atr` sub-pane | ATR sub-pane |
| 8 | Stochastic (%K/%D) | `ChartIndicators.stochastic` | `ind.stochastic` sub-pane | Stochastic sub-pane |
| 9 | Volume | real per-bar volume | volume sub-pane | volume sub-pane |

Both paths build a `RenderIndicators` and render through `ChartRender.drawChart`, so the live
interactive chart and the PNG proof draw the exact same overlays from the exact same math.

## Shipped timeframe set (6 — meets/exceeds the ≥5 floor)

Honest down-sampling of the buyer's own base bars (15s capture bars) — no bar is ever invented.

| Timeframe | Aggregation |
|-----------|-------------|
| 1m | fixed-count resample (`Resampler.resample`, factor 4) |
| 5m | fixed-count resample (factor 20) |
| 15m | fixed-count resample (factor 60) |
| 30m | fixed-count resample (factor 120) |
| 1h | fixed-count resample (factor 240) |
| 1D | calendar-day aggregation (`Resampler.daily`) |

Live path: `ChartTimeframe` picker in the chart toolbar. Headless path: the render-proof harness
resamples the base bars before drawing (`/tmp/bltd_chart_multitf.png`), proving the coarser-timeframe
render from the same resampler math.

## Honesty invariants

- Every value is computed from the buyer's own captured/imported bars; empty bars → empty output.
- A flat range (Stochastic hi==lo) yields nil, never a fabricated reading; zero-volume bars contribute
  nothing to VWAP.
- No indicator implies a signal or a track record — this is chart depth, not a performance claim.

## Proof

`./render-proof/render-proof.sh <bars.csv>` writes:
- `/tmp/bltd_chart_indicators.png` — the full 9-indicator parity set on one timeframe.
- `/tmp/bltd_chart_multitf.png` — the parity set on a 5m resample (multi-timeframe axis).
