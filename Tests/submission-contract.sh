#!/bin/bash
# Black Label Trading — offline submission-readiness contract guard.
# ──────────────────────────────────────────────────────────────────────────────
# Trading ships as a macOS app (project.yml: platform macOS, deploymentTarget 13.0).
# Its icon wiring lives in THREE places that must stay in lockstep or the bundle
# ships with a blank/rejected icon:
#
#   1. project.yml sets ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
#   2. every build script (build.command, build-signed.command, build-developer-id.sh)
#      stamps BOTH CFBundleIconFile=AppIcon and CFBundleIconName=AppIcon into Info.plist
#   3. Sources/Assets.xcassets/AppIcon.appiconset/Contents.json references the mac icon
#      PNGs, every referenced PNG exists on disk, and each PNG's real pixel size matches
#      its declared size*scale (incl. the 1024x1024 largest mac icon the store requires).
#
# This guard is fully OFFLINE and read-only: no swiftc, no xcodebuild, no altool, no
# network, no App Store Connect. It is the macOS analogue of BlackLabelLeads'
# SubmissionTests AppIconiOS/CFBundleIconName checks, adapted to Trading's mac
# AppIcon.appiconset + build-script-stamped Info.plist shape.
#
#   ./Tests/submission-contract.sh        (exit 0 iff every contract check passes)
set -uo pipefail
cd "$(dirname "$0")/.."

python3 - <<'PY'
import json, os, re, struct, subprocess, sys

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

def check_exact_slots(label, actual, expected):
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    check(label, not missing and not extra, f"missing={missing} extra={extra}")

# Canonical complete macOS AppIcon set: 16/32/128/256/512 at 1x and 2x.
MAC_SLOTS = {
    ("mac", "16x16", "1x"),
    ("mac", "16x16", "2x"),
    ("mac", "32x32", "1x"),
    ("mac", "32x32", "2x"),
    ("mac", "128x128", "1x"),
    ("mac", "128x128", "2x"),
    ("mac", "256x256", "1x"),
    ("mac", "256x256", "2x"),
    ("mac", "512x512", "1x"),
    ("mac", "512x512", "2x"),
}

# 1) project.yml asset-catalog app-icon name --------------------------------------
proj = os.path.join(ROOT, "project.yml")
try:
    pj = open(proj, encoding="utf-8").read()
except OSError as e:
    pj = ""
    check("project.yml readable", False, str(e))
check(
    "project.yml ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon",
    re.search(r"ASSETCATALOG_COMPILER_APPICON_NAME:\s*AppIcon\b", pj) is not None,
)

# 2) every build script stamps CFBundleIconFile + CFBundleIconName = AppIcon -------
for script in ("build.command", "build-signed.command", "build-developer-id.sh"):
    p = os.path.join(ROOT, script)
    try:
        s = open(p, encoding="utf-8").read()
    except OSError as e:
        check(f"{script} icon stamp", False, str(e))
        continue
    has_file = re.search(r"<key>CFBundleIconFile</key>\s*<string>AppIcon</string>", s) is not None
    has_name = re.search(r"<key>CFBundleIconName</key>\s*<string>AppIcon</string>", s) is not None
    check(
        f"{script} stamps CFBundleIconFile+CFBundleIconName=AppIcon",
        has_file and has_name,
        f"file={has_file} name={has_name}",
    )

# 3) AppIcon.appiconset Contents.json + every referenced PNG on disk, correct size --
iconset = os.path.join(ROOT, "Sources/Assets.xcassets/AppIcon.appiconset")
contents = os.path.join(iconset, "Contents.json")

def png_dim(path):
    with open(path, "rb") as f:
        if f.read(8) != b"\x89PNG\r\n\x1a\n":
            raise ValueError("not a PNG")
        f.read(4)
        if f.read(4) != b"IHDR":
            raise ValueError("no IHDR")
        return struct.unpack(">II", f.read(8))

try:
    cj = json.load(open(contents, encoding="utf-8"))
    images = cj.get("images", [])
except (OSError, ValueError) as e:
    images = []
    check("AppIcon.appiconset/Contents.json parses", False, str(e))
else:
    check("AppIcon.appiconset/Contents.json parses", True, f"{len(images)} entries")

missing = 0
mismatched = 0
expected_px = []
present_idioms = set()
for im in images:
    fn = im.get("filename")
    present_idioms.add(im.get("idiom"))
    if not fn:
        continue
    try:
        sz = int(im["size"].split("x")[0])
        scale = int(im["scale"].replace("x", ""))
    except (KeyError, ValueError):
        mismatched += 1
        continue
    exp = sz * scale
    expected_px.append(exp)
    path = os.path.join(iconset, fn)
    if not (os.path.isfile(path) and os.path.getsize(path) > 0):
        missing += 1
        continue
    try:
        w, h = png_dim(path)
    except (OSError, ValueError):
        mismatched += 1
        continue
    if not (w == h == exp):
        mismatched += 1

check("every referenced AppIcon PNG exists and is non-empty", images and missing == 0, f"missing={missing}")
check("every AppIcon PNG pixel size matches declared size*scale", images and mismatched == 0, f"mismatched={mismatched}")
check("mac idiom present in AppIcon set", "mac" in present_idioms, f"idioms={sorted(i for i in present_idioms if i)}")
check("largest 1024x1024 mac icon declared", 1024 in expected_px, f"max_declared={max(expected_px) if expected_px else 0}")

# Standard complete mac icon set: 16/32/128/256/512 at 1x and 2x = 10 entries.
check("complete 10-image mac AppIcon set", len(images) == 10, f"count={len(images)}")

# Exact idiom:size:scale slot-set parity (matches RealEstate/Academy guards):
# count==10 alone can't catch a duplicated slot masking a missing one, so lock
# the precise slot set the macOS store target requires.
mac_slots = {(im.get("idiom"), im.get("size"), im.get("scale")) for im in images}
check_exact_slots("mac AppIcon slots match canonical 10-image policy", mac_slots, MAC_SLOTS)

# 4) launcher must not narrow WealthCharts back to ES-only -----------------------
launcher = os.path.join(ROOT, "backend", "launch-backend.sh")
try:
    launch = open(launcher, encoding="utf-8").read()
except OSError as e:
    launch = ""
    check("backend launcher readable", False, str(e))
try:
    syntax = subprocess.run(["bash", "-n", launcher], capture_output=True, text=True)
    check("backend launcher shell syntax", syntax.returncode == 0, syntax.stderr.strip())
except OSError as e:
    check("backend launcher shell syntax", False, str(e))
check(
    "backend launcher defaults to WealthCharts-wide scope",
    'export BLTD_SCOPE="${BLTD_SCOPE:-all}"' in launch,
)
check(
    "backend launcher uses versioned pid-file supervisors",
    "bltd-supervisor-v2" in launch and "pgrep -f \"bltd_capture.py\"" not in launch,
)
check(
    "backend launcher does not force ES-only scope",
    'export BLTD_SCOPE="${BLTD_SCOPE:-es}"' not in launch,
)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
