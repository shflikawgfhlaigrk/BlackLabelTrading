#!/bin/bash
# Black Label Trading — self-contained backend launcher (ships INSIDE the .app bundle at
# Contents/Resources/backend). Starts the buyer's OWN data backend:
#   - captures THE BUYER'S OWN WealthCharts feed (their login, their Chrome profile) over CDP
#   - stores bars/ticks in a local SQLite database the product owns
#       (~/Library/Application Support/Black Label Trading/trading.sqlite3)
#   - serves /api/recent, /api/live, /api/symbols, /api/capture on 127.0.0.1:8787
#
# FULLY SELF-CONTAINED + ZERO DATA: stdlib-only Python (no pip installs, no Postgres, no Utah),
# the store starts EMPTY and is filled ONLY by the buyer's own feed. Nothing here reaches into
# any Black Label / Utah instance. Signals-only — it reads a feed, it never trades.
#
#   ./launch-backend.sh            # foreground
#   ./launch-backend.sh --bg       # background (writes pid + log under the app-support dir)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="$HOME/Library/Application Support/Black Label Trading"
mkdir -p "$SUPPORT"

# stdlib-only: any python3 (>=3.9) works; no virtualenv, no dependencies.
PY="$(command -v python3 || true)"
if [ -z "$PY" ]; then echo "python3 not found — install Xcode CLT or python.org build." >&2; exit 1; fi

export PYTHONPATH="$HERE:${PYTHONPATH:-}"
# Backend reads/writes ONLY the product's own store + the buyer's own WC CDP session.
export BLTD_STORE="${BLTD_STORE:-$SUPPORT/trading.sqlite3}"
export BLTD_PORT="${BLTD_PORT:-8787}"

if [ "${1:-}" == "--bg" ]; then
  LOG="$SUPPORT/backend.log"; PIDF="$SUPPORT/backend.pid"
  nohup "$PY" "$HERE/bltd_api.py" "$BLTD_PORT" >>"$LOG" 2>&1 &
  echo $! > "$PIDF"
  echo "backend started (pid $(cat "$PIDF")) → http://127.0.0.1:$BLTD_PORT  log: $LOG"
else
  exec "$PY" "$HERE/bltd_api.py" "$BLTD_PORT"
fi
