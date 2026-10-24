#!/bin/bash
# Black Label Trading — --devid signing-entitlements contract guard.
# ──────────────────────────────────────────────────────────────────────────────
# build.command's --devid path signs the notarization-ready Developer-ID bundle. That bundle
# spawns a bundled Python backend which loads UNSIGNED .so extensions, so it MUST be signed with
# entitlements that grant com.apple.security.cs.disable-library-validation (and network.client),
# or macOS library validation refuses the .so files and the backend never starts.
#
# Sources/ carries TWO near-namesake files whose names differ by four characters:
#   * app-developerid.entitlements  — the REAL hardened one (network.client + disable-library-validation)
#   * app-devid.entitlements         — an EMPTY <dict> (a live-defect trap; must NOT be signed with)
#
# This guard reads the ACTUAL DEVID_ENTITLEMENTS assignment out of build.command, resolves the
# file it points at, and asserts that file grants the load-bearing entitlements. If DEVID_ENTITLEMENTS
# is ever repointed at the empty dict (the original blocker-3 defect), the disable-library-validation
# check below goes RED for ITS OWN reason — the resolved file is missing that exact key.
#
# It also pins dev==ship parity: the --devid dev path (build.command) and the ship lane
# (build-developer-id.sh) must sign with the SAME entitlements file, so a hardening change to one
# can never silently diverge from the other.
#
# Fully OFFLINE and read-only: no swiftc, no codesign, no network.
#
#   ./Tests/devid-entitlements-contract.sh        (exit 0 iff every contract check passes)
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import os, re, sys

ROOT = os.getcwd()
passed = 0
failed = 0

def check(label, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
        print(f"  ok   {label}" + (f" — {detail}" if detail else ""))
    else:
        failed += 1
        print(f"  FAIL {label}" + (f" — {detail}" if detail else ""))

def read(path):
    try:
        return open(path, encoding="utf-8").read()
    except OSError as e:
        return None

# resolve_var(script_text, VAR) -> basename that VAR="$SRC/<name>" points at, or None.
# SRC is "$ROOT/Sources" in every build script, so we only need the leaf name.
def resolve_entitlements(text, var):
    if text is None:
        return None
    m = re.search(rf'^{var}="\$SRC/([^"]+)"', text, re.MULTILINE)
    return m.group(1) if m else None

# --- 1) build.command defines DEVID_ENTITLEMENTS -------------------------------------
build = read(os.path.join(ROOT, "build.command"))
check("build.command readable", build is not None)
devid_name = resolve_entitlements(build, "DEVID_ENTITLEMENTS")
check("build.command defines DEVID_ENTITLEMENTS=$SRC/<file>", devid_name is not None,
      f"resolved={devid_name}")

# --- 2) the resolved DEVID entitlements file exists and is a NON-empty dict ----------
devid_path = os.path.join(ROOT, "Sources", devid_name) if devid_name else None
devid_ents = read(devid_path) if devid_path else None
check("--devid entitlements file exists on disk", devid_ents is not None,
      f"path=Sources/{devid_name}")

# count declared <key>…</key> entries — the empty-dict trap has ZERO.
key_count = len(re.findall(r"<key>", devid_ents or ""))
check("--devid entitlements is not an empty <dict>", key_count > 0,
      f"declared_keys={key_count} in Sources/{devid_name}")

# --- 3) THE load-bearing grants — this is the mutation tripwire ----------------------
# If DEVID_ENTITLEMENTS is repointed at Sources/app-devid.entitlements (empty dict), THIS check
# fails for its own reason: the resolved file does not grant disable-library-validation.
def grants(text, key):
    # <key>KEY</key> immediately followed by <true/> (whitespace-tolerant)
    return re.search(rf"<key>{re.escape(key)}</key>\s*<true\s*/>", text or "") is not None

check("--devid entitlements grant cs.disable-library-validation (backend .so loading)",
      grants(devid_ents, "com.apple.security.cs.disable-library-validation"),
      f"resolved=Sources/{devid_name}")
check("--devid entitlements grant network.client",
      grants(devid_ents, "com.apple.security.network.client"),
      f"resolved=Sources/{devid_name}")

# --- 4) dev(--devid) == ship(build-developer-id.sh) entitlements parity --------------
ship = read(os.path.join(ROOT, "build-developer-id.sh"))
check("build-developer-id.sh readable", ship is not None)
ship_name = resolve_entitlements(ship, "ENTS")
check("build-developer-id.sh defines ENTS=$SRC/<file>", ship_name is not None,
      f"resolved={ship_name}")
check("--devid dev path and Developer-ID ship lane sign with the SAME entitlements file",
      devid_name is not None and devid_name == ship_name,
      f"devid={devid_name} ship={ship_name}")

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
