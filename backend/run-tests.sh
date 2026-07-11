#!/bin/bash
# Black Label Trading — backend engine test runner (pure stdlib; pytest optional).
# Runs the ported-engine + edge-gate test suite. Uses pytest when available, else the
# self-contained plain runner in test_engines.py (no third-party deps required).
#
#   bash backend/run-tests.sh
set -euo pipefail
cd "$(dirname "$0")"
if python3 -c "import pytest" 2>/dev/null; then
  exec python3 -m pytest test_engines.py test_feeds.py test_api.py test_exec.py test_topstep_bridge.py test_store_scope.py test_claim_linter.py -q
fi
python3 test_engines.py && python3 test_feeds.py && python3 test_api.py && python3 test_exec.py && python3 test_topstep_bridge.py && python3 test_store_scope.py && python3 test_claim_linter.py
