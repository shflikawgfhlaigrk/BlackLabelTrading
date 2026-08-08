#!/bin/bash
# Black Label Trading — Windows W1 lane verifier (contract windows-w1-trading-20260720).
# Runs from a COLD macOS shell. Every check is output-on-disk truth, no wrapper trust.
# Exits 0 only if every gate passes. This is the machine_verify battery for the handoff packet.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO="$(pwd)"
fail=0
ok()   { echo "PASS $1"; }
bad()  { echo "FAIL $1"; fail=1; }

# 1. every new/touched module parses without writing __pycache__ into the source tree
if python3 - \
    backend/bltd_paths.py backend/bltd_browser.py backend/bltd_capture.py \
    backend/bltd_store.py backend/test_windows_lane.py windows/supervise.py <<'PY' 2>/dev/null
import pathlib
import sys
for raw in sys.argv[1:]:
    path = pathlib.Path(raw)
    compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY
then
  ok "modules compile"
else
  bad "modules compile"
fi

# 2. backend suite green + no macOS regression (baseline was 218; current lane expects >=240)
suite_output="$(bash backend/run-tests.sh 2>&1)"
suite_rc=$?
suite="$(printf '%s\n' "$suite_output" | tail -1)"
passed="$(echo "$suite" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+')"
failed="$(echo "$suite" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || true)"
failed="${failed:-0}"
if [ "$suite_rc" = "0" ] && [ "$failed" = "0" ] && [ "${passed:-0}" -ge 240 ]; then
  ok "backend suite ($suite)"
else
  bad "backend suite ($suite)"
fi

# 3. supervisor --plan launches nothing and names all three children + windows support path
plan="$(BLTD_SUPPORT_DIR='C:\Users\buyer\AppData\Local\Black Label Trading' python3 windows/supervise.py --plan 2>&1)"
if echo "$plan" | grep -q 'bltd_api.py' \
   && echo "$plan" | grep -q 'bltd_capture.py' \
   && echo "$plan" | grep -q 'bltd_topstep_bridge.py' \
   && echo "$plan" | grep -q 'C:\\Users\\buyer' \
   && echo "$plan" | grep -q 'api_port[[:space:]]*: 8793'; then
  ok "supervisor --plan resolves 3 children + Windows support dir (no spawn)"
else
  bad "supervisor --plan"
fi

# 4. Windows launch argv is a direct exe (no macOS 'open') — proven via bltd_browser
argv="$(cd backend && python3 - <<'PY'
import bltd_browser as b
b._os_kind = lambda: "win"
print(" ".join(b.build_argv(r"C:\chrome.exe", 9223, r"C:\prof", ["https://app.wealthcharts.com/"])))
PY
)"
if echo "$argv" | grep -q '^C:\\chrome.exe' \
   && echo "$argv" | grep -q -- '--remote-debugging-address=127.0.0.1' \
   && ! echo "$argv" | grep -qw 'open'; then
  ok "windows launch argv is direct exe, loopback-pinned"
else
  bad "windows launch argv ($argv)"
fi

# 5. build STAGES ONLY + fail-closed integrity guard + ships-empty assertion present;
#    the pin's first non-comment/non-blank line must be the __PENDING__ sentinel OR a real 64-hex
#    sha256 (comment lines may mention __PENDING__, so parse the hash line in isolation).
pin_line="$(grep -vE '^[[:space:]]*#' windows/python-embed.sha256 | grep -vE '^[[:space:]]*$' | head -1 | tr -d '[:space:]')"
if echo "$pin_line" | grep -qiE '^[0-9a-f]{64}$'; then pin_state="pinned 64-hex"; \
  elif [ "$pin_line" = "__PENDING__" ]; then pin_state="pending (fail-closed)"; else pin_state=""; fi
if [ -n "$pin_state" ] \
   && grep -q 'FAIL-CLOSED' windows/build-windows.ps1 \
   && grep -q '0-9a-f]{64}' windows/build-windows.ps1 \
   && grep -q 'ships-empty violation' windows/build-windows.ps1 \
   && grep -q 'NOT signed, NOT published' windows/build-windows.ps1; then
  ok "build fails closed on integrity pin [$pin_state] + asserts ships-empty + stages only"
else
  bad "build fail-closed/ships-empty guards or pin format ($pin_line)"
fi

# 6. sign stage is fail-closed and never publishes
if grep -q 'FAIL-CLOSED' windows/sign-windows.ps1 \
   && grep -q 'exit 2' windows/sign-windows.ps1; then
  ok "sign-windows fails closed (no identity → exit 2)"
else
  bad "sign-windows fail-closed"
fi

# 7. ships-empty: no buyer state committed into the windows lane
leak="$(find windows -type f \( -name 'trading.sqlite3' -o -name 'config.json' \
        -o -name 'webhook.token' -o -name '*.pem' -o -name '*.key' -o -name 'auth.json' \
        -o -name '*.pyc' \) 2>/dev/null)"
if [ -z "$leak" ]; then
  ok "no buyer state / creds in windows lane"
else
  bad "buyer state leaked: $leak"
fi

# 8. brand isolation for APP code: no OTHER product/client brand leaks into the windows lane
#    (the app is legitimately 'Black Label Trading'; it must not surface sibling/client brands)
cross="$(grep -rniE --exclude=verify-windows-lane.sh \
         'asgolf|gcwars|blackwater|sunsetmixing|blvigil|blbestate|sovereign|academy' \
         windows 2>/dev/null | grep -viE 'README|honest' || true)"
if [ -z "$cross" ]; then
  ok "no cross-brand strings in windows lane"
else
  bad "cross-brand leak: $cross"
fi

echo "----"
if [ "$fail" = "0" ]; then echo "WINDOWS-LANE VERIFY: ALL PASS"; exit 0; else echo "WINDOWS-LANE VERIFY: FAILURES"; exit 1; fi
