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
SUPPORT="$TEST_HOME/Library/Application Support/Black Label Trading"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cleanup() {
  if [ -x "${LAUNCH:-}" ] && [ -x "${PY:-}" ]; then
    BLTD_SUPPORT_DIR="$SUPPORT" \
    BLTD_PYTHON="$PY" \
    BLTD_PORT="${PORT:-8793}" \
    BLTD_BUILD="28" \
      /bin/bash "$LAUNCH" --stop-owned >/dev/null 2>&1 || true
  fi
  [ -n "${OCCUPIER_PID:-}" ] && kill "$OCCUPIER_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -d "$APP" ] || fail "built app not found: $APP"

BUNDLE_REF="$APP/Contents/Resources/backend/reference_oos.json"
LAUNCH="$APP/Contents/Resources/backend/launch-backend.sh"
PY="$APP/Contents/Resources/backend/python3"
INFO="$APP/Contents/Info.plist"

[ -f "$INFO" ] || fail "missing bundle Info.plist at $INFO"
[ -f "$BUNDLE_REF" ] || fail "missing bundled reference_oos.json at $BUNDLE_REF"
[ -x "$LAUNCH" ] || fail "missing executable bundled backend launcher at $LAUNCH"
[ -x "$PY" ] || fail "missing executable bundled python wrapper at $PY"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO" 2>/dev/null || true)"
[ "$BUILD_VERSION" = "28" ] || fail "built bundle is build '$BUILD_VERSION', expected b28"
bash "$ROOT/Tests/signals-only-release-contract.sh" "$APP" ||
  fail "built bundle violates the signals-only boundary introduced in b27"
codesign --verify --deep --strict "$APP" || fail "built bundle signature is invalid before launch"
if find "$APP/Contents/Resources/backend" \( -type d -name __pycache__ -o -type f -name '*.pyc' \) | grep -q .; then
  fail "built bundle contains mutable Python caches before launch"
fi

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
assert any(e.get("status") == "no_edge" for e in d["engines"]), "expected honest no_edge verdicts"
assert d.get("candidateCount") == sum(e.get("status") == "candidate" for e in d["engines"]), d
sig = d.get("significance", {})
assert sig.get("fdrQ") == 0.1 and sig.get("gridCells") == 18, sig
for e in d["engines"]:
    if e.get("status") == "candidate":
        assert any(c.get("proven") is True for c in e.get("contracts", [])), e
    else:
        assert not any(c.get("proven") is True for c in e.get("contracts", [])), e
assert "disclaimer" in d and "not your results" in d["disclaimer"], d.get("disclaimer", "")
PY

# A foreign listener on the requested port must be reported as a collision, never as a successful
# Trading start. This is the exact production regression that occurred when Capstone owned :8787.
OCCUPIED_PORT="$("$PY" - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
)"
HOME="$TEST_HOME" BLTD_PYCACHE_ROOT="$WORK/pycache" \
  "$PY" -m http.server "$OCCUPIED_PORT" --bind 127.0.0.1 >"$WORK/occupier.log" 2>&1 &
OCCUPIER_PID=$!
for _ in $(seq 1 20); do
  curl -fsS "http://127.0.0.1:$OCCUPIED_PORT/" >/dev/null 2>&1 && break
  sleep 0.1
done
set +e
HOME="$TEST_HOME" BLTD_PORT="$OCCUPIED_PORT" BLTD_PYCACHE_ROOT="$WORK/pycache" \
  /bin/bash "$LAUNCH" --bg >"$WORK/collision.out" 2>&1
collision_rc=$?
set -e
[ "$collision_rc" -eq 4 ] || fail "foreign listener collision returned $collision_rc, expected 4"
grep -q "owned by another service" "$WORK/collision.out" ||
  fail "foreign listener collision did not emit the honest ownership error"
kill "$OCCUPIER_PID" 2>/dev/null || true
wait "$OCCUPIER_PID" 2>/dev/null || true
OCCUPIER_PID=""

HOME="$TEST_HOME" \
BLTD_PORT="$PORT" \
BLTD_STORE="$WORK/trading.sqlite3" \
BLTD_CONFIG="$WORK/config.json" \
BLTD_TOKEN="ref-contract-token" \
BLTD_PYCACHE_ROOT="$WORK/pycache" \
BLTD_CAPTURE_BROWSER="0" \
BLTD_AUTO_BROWSER="0" \
  /bin/bash "$LAUNCH" --bg >"$WORK/launch.out" 2>&1 ||
  fail "bundled launcher failed: $(tail -n 1 "$WORK/launch.out")"

body=""
for _ in $(seq 1 40); do
  body="$(curl -fsS -H "Authorization: Bearer ref-contract-token" \
    "http://127.0.0.1:$PORT/api/reference" 2>/dev/null || true)"
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
assert d.get("candidateCount") == sum(e.get("status") == "candidate" for e in d["engines"]), d
assert d.get("candidateCount") == 0, "current reference truth must remain zero until BH-FDR earns a candidate"
label = d.get("label", "")
assert "Reference only" in label and "NOT your account" in label and "NOT a promise" in label, label
assert isinstance(d.get("engines"), list) and len(d["engines"]) == 9, len(d.get("engines", []))
PY

codesign --verify --deep --strict "$APP" || fail "launch mutated the signed bundle"
if find "$APP/Contents/Resources/backend" \( -type d -name __pycache__ -o -type f -name '*.pyc' \) | grep -q .; then
  fail "launch wrote mutable Python caches inside the signed bundle"
fi

echo "Reference OOS built-bundle contract PASS: $APP -> /api/reference on :$PORT"
echo "6 passed, 0 failed"
