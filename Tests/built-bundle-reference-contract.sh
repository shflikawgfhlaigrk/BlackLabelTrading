#!/bin/bash
# Black Label Trading — post-build Reference OOS bundle/API contract.
#
# This runs against a BUILT .app bundle, not source. It proves the cold-buyer
# Reference panel's data path can be served from the app bundle with no network
# and no external backend: bundled launch-backend.sh -> /api/reference.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/Black Label Trading.app}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/blt-ref.XXXXXX")"
TEST_HOME="$WORK/home"
mkdir -p "$TEST_HOME"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -d "$APP" ] || fail "built app not found: $APP"

BUNDLE_REF="$APP/Contents/Resources/backend/reference_oos.json"
LAUNCH="$APP/Contents/Resources/backend/launch-backend.sh"
PY="$APP/Contents/Resources/backend/python3"

[ -f "$BUNDLE_REF" ] || fail "missing bundled reference_oos.json at $BUNDLE_REF"
[ -x "$LAUNCH" ] || fail "missing executable bundled backend launcher at $LAUNCH"
[ -x "$PY" ] || fail "missing executable bundled python wrapper at $PY"

PORT="${BLT_REFERENCE_TEST_PORT:-}"
if [ -z "$PORT" ]; then
  PORT="$("$PY" - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
fi
trap 'pkill -f "bltd_api.py '"$PORT"'" 2>/dev/null || true; pkill -f "'"$TEST_HOME"'/Library/Application Support/Black Label Trading" 2>/dev/null || true; rm -rf "$WORK"' EXIT

"$PY" - "$BUNDLE_REF" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    d = json.load(f)
assert d.get("kind") == "reference_oos", d.get("kind")
label = d.get("label", "")
assert "Reference only" in label and "NOT your account" in label and "NOT a promise" in label, label
assert d.get("engineCount") == 9, d.get("engineCount")
assert isinstance(d.get("engines"), list) and len(d["engines"]) == 9, len(d.get("engines", []))
assert any(e.get("status") == "candidate" for e in d["engines"]), "expected at least one labeled candidate"
assert any(e.get("status") == "no_edge" for e in d["engines"]), "expected honest no_edge verdicts"
assert "disclaimer" in d and "not your results" in d["disclaimer"], d.get("disclaimer", "")
PY

HOME="$TEST_HOME" \
BLTD_PORT="$PORT" \
BLTD_STORE="$WORK/trading.sqlite3" \
BLTD_CONFIG="$WORK/config.json" \
BLTD_TOKEN="ref-contract-token" \
BLTD_CAPTURE_BROWSER="0" \
BLTD_AUTO_BROWSER="0" \
  /bin/bash "$LAUNCH" --bg >/dev/null 2>&1 || true

body=""
for _ in $(seq 1 40); do
  body="$(curl -fsS "http://127.0.0.1:$PORT/api/reference" 2>/dev/null || true)"
  [ -n "$body" ] && break
  sleep 0.25
done

[ -n "$body" ] || fail "bundled backend did not serve /api/reference on :$PORT"
printf '%s' "$body" > "$WORK/reference.json"

"$PY" - "$WORK/reference.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
assert d.get("available") is True, d
assert d.get("kind") == "reference_oos", d.get("kind")
assert d.get("engineCount") == 9, d.get("engineCount")
assert d.get("candidateCount", 0) >= 1, d.get("candidateCount")
label = d.get("label", "")
assert "Reference only" in label and "NOT your account" in label and "NOT a promise" in label, label
assert isinstance(d.get("engines"), list) and len(d["engines"]) == 9, len(d.get("engines", []))
PY

echo "Reference OOS built-bundle contract PASS: $APP -> /api/reference on :$PORT"
echo "1 passed, 0 failed"
