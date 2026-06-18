#!/bin/bash
# Black Label Trading — build + run the headless chart render proof.
# Compiles the PURE chart math + the CoreGraphics renderer + the CLI harness (NO SwiftUI),
# then renders /tmp/bltd_chart_candles.png and /tmp/bltd_chart_indicators.png from the buyer's
# OWN captured bars served by the self-contained backend.
#
#   ./render-proof/render-proof.sh [SYMBOL] [BASE_URL]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUT="$ROOT/build/bltd-render-proof"
mkdir -p "$ROOT/build"

SOURCES=(
  "$ROOT/Tests/TestSupport.swift"   # TradeDirection stand-in (no SwiftUI)
  "$ROOT/Sources/Analytics.swift"   # TradeStat (referenced by Backtest)
  "$ROOT/Sources/Backtest.swift"    # Bar, BarCSV, Indicators
  "$ROOT/Sources/Charting.swift"    # CandleTransform, ChartIndicators, ChartScale
  "$ROOT/Sources/FeedTypes.swift"   # FeedBars/LiveTick wire decode
  "$ROOT/Sources/ChartRender.swift" # CoreGraphics renderer
  "$ROOT/render-proof/main.swift"   # CLI harness
)

echo "==> Compiling headless render proof"
xcrun --sdk macosx swiftc \
  -O \
  -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -framework Foundation -framework CoreGraphics -framework ImageIO -framework CoreText \
  -o "$OUT" \
  "${SOURCES[@]}"

echo "==> Running render proof"
"$OUT" "$@"
