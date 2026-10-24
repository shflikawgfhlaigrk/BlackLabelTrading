#!/bin/bash
# Black Label Trading — pure-logic test runner.
# Compiles the testable engine sources + the test harness into one executable and runs it.
# These sources are deliberately free of SwiftUI/AppKit so the math is verifiable headlessly.
#
#   ./Tests/run-tests.sh
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUT="$ROOT/build/blt-tests"
mkdir -p "$ROOT/build"

# Pure-logic engine sources under test (NO SwiftUI/AppKit). TestSupport.swift provides the
# minimal types (TradeDirection, BLColor stand-ins) the engines reference so they compile alone.
SOURCES=(
  "$ROOT/Tests/TestSupport.swift"
  "$ROOT/Sources/HoloTheme.swift"
  "$ROOT/Sources/Updater.swift"
  "$ROOT/Sources/TradeMath.swift"
  "$ROOT/Sources/SignalCore.swift"
  "$ROOT/Sources/RuleProfile.swift"
  "$ROOT/Sources/Analytics.swift"
  "$ROOT/Sources/Backtest.swift"
  "$ROOT/Sources/BacktestDepth.swift"
  "$ROOT/Sources/Charting.swift"
  "$ROOT/Sources/ChartRender.swift"
  "$ROOT/Sources/FeedTypes.swift"
  "$ROOT/Sources/JournalImport.swift"
  "$ROOT/Sources/Screener.swift"
  "$ROOT/Sources/AlertsEngine.swift"
  "$ROOT/Sources/WatchlistModel.swift"
  "$ROOT/Sources/Patterns.swift"
  "$ROOT/Sources/StrategyBuilder.swift"
  "$ROOT/Sources/PaperTrade.swift"
  "$ROOT/Sources/Replay.swift"
  "$ROOT/Tests/main.swift"
)

echo "==> Compiling pure-logic test target"
xcrun --sdk macosx swiftc \
  -O \
  -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -framework Foundation -framework CoreGraphics -framework ImageIO -framework CoreText -framework UniformTypeIdentifiers -framework CryptoKit -framework Security \
  -o "$OUT" \
  "${SOURCES[@]}"

echo "==> Running"
"$OUT"
