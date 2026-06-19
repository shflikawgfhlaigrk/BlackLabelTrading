#!/bin/bash
# Black Label Trading — backend engine test runner (pure stdlib; pytest optional).
# Runs the ported-engine + edge-gate test suite. Uses pytest when available, else the
# self-contained plain runner in test_engines.py (no third-party deps required).
#
#   bash backend/run-tests.sh
set -euo pipefail
cd "$(dirname "$0")"
if python3 -c "import pytest" 2>/dev/null; then
  exec python3 -m pytest test_engines.py -q
fi
exec python3 test_engines.py
