#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUT="$ROOT/build/trading-persistence-tests"
mkdir -p "$ROOT/build"

xcrun --sdk macosx swiftc \
  -sdk "$SDK" \
  -target arm64-apple-macosx13.0 \
  -framework Foundation -framework CryptoKit -framework Security \
  -o "$OUT" \
  "$ROOT/Sources/TradingKeychain.swift" \
  "$ROOT/Sources/TradingSessionStore.swift" \
  "$ROOT/Tests/TradingPersistenceTests.swift"

"$OUT"
