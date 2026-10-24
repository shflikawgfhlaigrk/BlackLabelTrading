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
cleanup() {
  # Only processes recorded by this isolated launch may be stopped. Stop the
  # supervisors first, then their workers, so cleanup cannot respawn a child.
  local file pid command
  for file in "$TEST_HOME/Library/Application Support/Black Label Trading/"*-supervisor.pid \
              "$TEST_HOME/Library/Application Support/Black Label Trading/"*.pid; do
    [ -f "$file" ] || continue
    pid="$(cat "$file")"
    case "$pid" in ''|*[!0-9]*) continue;; esac
    command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$command" in
      *"$APP/Contents/Resources/backend/"*|*"$TEST_HOME/"*)
        if [ -n "${BLT_REFERENCE_TEST_TERMINATE_HELPER:-}" ]; then
          "$BLT_REFERENCE_TEST_TERMINATE_HELPER" "$pid" || {
            echo "FAIL: scoped cleanup refused for pid $pid; evidence retained at $WORK" >&2
            trap - EXIT
            exit 1
          }
        else
          kill "$pid" 2>/dev/null || true
        fi
        ;;
    esac
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

"$PY" - "$BUNDLE_REF" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    d = json.load(f)
assert d.get("kind") == "reference_oos", d.get("kind")
label = d.get("label", "")
assert "Reference only" in label and "NOT your account" in label and "NOT a promise" in label, label
assert isinstance(d.get("engines"), list) and d["engines"], "missing reference engines"
assert d.get("engineCount") == len(d["engines"]), d.get("engineCount")
assert all(e.get("status") in ("candidate", "no_edge", "insufficient") for e in d["engines"])
assert d.get("candidateCount") == sum(e["status"] == "candidate" for e in d["engines"])
assert "disclaimer" in d and "not your results" in d["disclaimer"], d.get("disclaimer", "")
PY

HOME="$TEST_HOME" \
BLTD_PORT="$PORT" \
BLTD_STORE="$WORK/trading.sqlite3" \
BLTD_CONFIG="$WORK/config.json" \
BLTD_DSN="" \
BLTD_TOKEN="ref-contract-token" \
BLTD_CAPTURE_BROWSER="0" \
BLTD_AUTO_BROWSER="0" \
BLTD_CDP_PORT="0" \
  /bin/bash "$LAUNCH" --bg >/dev/null 2>&1 || true

body=""
for _ in $(seq 1 40); do
  body="$(curl -fsS -H 'Authorization: Bearer ref-contract-token' "http://127.0.0.1:$PORT/api/reference" 2>/dev/null || true)"
  [ -n "$body" ] && break
  sleep 0.25
done

[ -n "$body" ] || fail "bundled backend did not serve /api/reference on :$PORT"
printf '%s' "$body" > "$WORK/reference.json"

code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api/reference")"
[ "$code" = "401" ] || fail "unauthenticated reference request returned $code"

"$PY" - "$WORK/reference.json" "$BUNDLE_REF" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
assert d.get("available") is True, d
assert d.get("kind") == "reference_oos", d.get("kind")
with open(sys.argv[2], encoding="utf-8") as f:
    bundled = json.load(f)
assert d.get("engineCount") == bundled["engineCount"], d.get("engineCount")
assert d.get("candidateCount") == bundled["candidateCount"], d.get("candidateCount")
label = d.get("label", "")
assert "Reference only" in label and "NOT your account" in label and "NOT a promise" in label, label
assert d.get("engines") == bundled["engines"], "API altered the bundled verdicts"
PY

echo "Reference OOS built-bundle contract PASS: $APP -> /api/reference on :$PORT"
echo "1 passed, 0 failed"
