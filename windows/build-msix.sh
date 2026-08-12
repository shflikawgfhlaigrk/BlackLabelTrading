#!/usr/bin/env bash
# Black Label Trading — MSIX packaging for the Microsoft Store.
#
#   bash windows/build-msix.sh --validate   # ANY host (macOS ok): assemble layout, run every
#                                           # gate, pack NOTHING. Proves the recipe without a
#                                           # Windows box.
#   bash windows/build-msix.sh              # Windows only: assemble + makeappx pack -> .msix
#
# STORE-FIRST, UNSIGNED. No Authenticode certificate has been purchased and none is applied.
# The Microsoft Store re-signs an uploaded package under the Partner Center account identity,
# so the Store path needs no cert. The output of this script therefore CANNOT be sideloaded
# (MSIX sideload install requires a signature) and this script never claims otherwise.
#
# PORTABILITY IS A HARD REQUIREMENT. Every path below is derived from this script's own
# location. Nothing references a home directory, a developer's username, or a sibling repo.
# If it runs from a fresh `git clone` on a GitHub-hosted runner, it runs anywhere.
#
# PRODUCT LAW: Black Label Trading is SIGNALS-ONLY. Nothing packaged here can place, route,
# modify or cancel an order.
set -euo pipefail

MODE="${1:-pack}"

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MSIX_SRC="$HERE/msix"
LAYOUT="$HERE/msix-layout"
DIST="$HERE/dist"
STAGE="$DIST/blacklabel-trading-win"     # produced by windows/build-windows.ps1

# --- Partner Center identity ------------------------------------------------------------
# These three values are ASSIGNED BY PARTNER CENTER after the app name is reserved. They do
# not exist yet. The defaults below are the exact placeholder tokens that live in
# windows/msix/AppxManifest.xml — the one place they are edited. Nothing here invents a GUID,
# a publisher CN, or a legal name.
PC_NAME="${PARTNER_CENTER_IDENTITY_NAME:-}"
PC_PUBLISHER="${PARTNER_CENTER_PUBLISHER:-}"
PC_DISPLAY="${PARTNER_CENTER_PUBLISHER_DISPLAY_NAME:-}"

PLACEHOLDER_NAME='PASTE-PARTNER-CENTER-PACKAGE-IDENTITY-NAME-HERE'
PLACEHOLDER_PUBLISHER='CN=PASTE-PARTNER-CENTER-PUBLISHER-CN-HERE'
PLACEHOLDER_DISPLAY='PASTE VERIFIED LEGAL NAME FROM PARTNER CENTER'

case "$MODE" in
  --validate|--pack|pack) ;;
  *) echo "usage: build-msix.sh [--validate]" >&2; exit 2 ;;
esac

echo "== [1/6] clean layout =="
rm -rf "$LAYOUT"
mkdir -p "$LAYOUT/Assets"

echo "== [2/6] stage the app payload into the package layout =="
if [ -d "$STAGE" ]; then
  # build-windows.ps1 already produced the verified stage (embeddable CPython + pure-stdlib
  # backend + supervisor). Copy it in wholesale; it is the exact tree that ships.
  cp -R "$STAGE"/. "$LAYOUT"/
  echo "   payload: $STAGE"
else
  if [ "$MODE" != "--validate" ]; then
    echo "   ERROR: no staged payload at $STAGE." >&2
    echo "          Run windows/build-windows.ps1 first (Windows only — it downloads and" >&2
    echo "          sha256-verifies the embeddable CPython runtime)." >&2
    exit 1
  fi
  # --validate on a non-Windows host: stage only the host-portable parts so the layout, the
  # manifest and the asset gate are all still exercised end to end.
  cp "$HERE/supervise.py" "$HERE/launch-trading.cmd" "$LAYOUT"/
  [ -f "$HERE/README-WINDOWS.md" ] && cp "$HERE/README-WINDOWS.md" "$LAYOUT"/
  echo "   (--validate) no Windows stage present; layout holds the portable payload only"
fi

# --- the MSIX entry-point executable ----------------------------------------------------
# MSIX requires Application/@Executable to be a real PE. launch-trading.cmd cannot be it, so a
# thin launcher (msix/launcher/Launcher.cs) is compiled on the Windows runner and dropped here.
echo "== [3/6] entry-point executable =="
if [ -f "$DIST/BlackLabelTrading.exe" ]; then
  cp "$DIST/BlackLabelTrading.exe" "$LAYOUT/BlackLabelTrading.exe"
  echo "   BlackLabelTrading.exe: compiled launcher from $DIST"
elif [ "$MODE" = "--validate" ]; then
  printf 'MZ not-a-real-PE placeholder: BlackLabelTrading.exe is compiled from msix/launcher/Launcher.cs on Windows' \
    > "$LAYOUT/BlackLabelTrading.exe"
  echo "   (--validate) wrote a non-PE placeholder so the layout can be checked off-Windows"
else
  echo "   ERROR: $DIST/BlackLabelTrading.exe not found." >&2
  echo "          Compile it first (Windows only):" >&2
  echo '            csc.exe /nologo /target:winexe /platform:x64 \' >&2
  echo '              /out:windows/dist/BlackLabelTrading.exe windows/msix/launcher/Launcher.cs' >&2
  exit 1
fi

echo "== [4/6] Store tiles =="
cp "$MSIX_SRC/Assets/"*.png "$LAYOUT/Assets/"

echo "== [5/6] resolve manifest identity =="
# Substitution is line-oriented and token-exact. When an env var is empty the placeholder is
# left standing verbatim — this never fabricates an identity value.
cp "$MSIX_SRC/AppxManifest.xml" "$LAYOUT/AppxManifest.xml"
# node (not sed) does the replace: the tokens and the legal-name replacement are literal
# strings, and a legal name can contain characters sed would treat as delimiters or regex.
subst() { # subst <token> <replacement>
  [ -n "${2:-}" ] || return 0
  node -e '
    const fs = require("fs");
    const [file, oldTok, newTok] = process.argv.slice(1);
    fs.writeFileSync(file, fs.readFileSync(file, "utf8").split(oldTok).join(newTok));
  ' "$LAYOUT/AppxManifest.xml" "$1" "$2"
}
subst "$PLACEHOLDER_NAME" "$PC_NAME"
subst "$PLACEHOLDER_PUBLISHER" "$PC_PUBLISHER"
subst "$PLACEHOLDER_DISPLAY" "$PC_DISPLAY"

IDENTITY_RESOLVED=1
if grep -q 'PASTE-PARTNER-CENTER\|PASTE VERIFIED LEGAL NAME' "$LAYOUT/AppxManifest.xml"; then
  IDENTITY_RESOLVED=0
  echo "   IDENTITY IS STILL A PLACEHOLDER."
  echo "   The three values are assigned by Partner Center once the app name is reserved."
  echo "   Paste them into windows/msix/AppxManifest.xml, or export:"
  echo "     PARTNER_CENTER_IDENTITY_NAME, PARTNER_CENTER_PUBLISHER, PARTNER_CENTER_PUBLISHER_DISPLAY_NAME"
  echo "   The package will still build — it just cannot be submitted."
else
  echo "   identity resolved from environment / manifest edit"
fi

# The output filename carries the verdict so a placeholder build can never be mistaken for a
# submittable one on someone's Downloads folder.
if [ "$IDENTITY_RESOLVED" = "1" ]; then
  OUT="$DIST/BlackLabelTrading.msix"
else
  OUT="$DIST/BlackLabelTrading-PLACEHOLDER-IDENTITY-NOT-SUBMITTABLE.msix"
fi

echo "== [5b/6] gates =="
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$LAYOUT/AppxManifest.xml"
  echo "   xmllint: AppxManifest.xml is well-formed XML"
else
  node -e '
    const s = require("fs").readFileSync(process.argv[1], "utf8");
    if (!/<Package[\s>]/.test(s) || !/<\/Package>\s*$/.test(s)) throw new Error("manifest not well-formed");
    console.log("   node: AppxManifest.xml has a Package root");
  ' "$LAYOUT/AppxManifest.xml"
fi

node "$MSIX_SRC/check-assets.mjs" "$LAYOUT"

# Signals-only law: an execution adapter must never reach a shipped package.
FORBIDDEN_MODULES="bltd_projectx.py bltd_tradovate.py"
for m in $FORBIDDEN_MODULES; do
  if [ -e "$LAYOUT/backend/$m" ]; then
    echo "   ERROR: signals-only violation — $m is in the package layout." >&2
    exit 1
  fi
done
echo "   signals-only: no broker/execution adapter in the layout"

# Ships-empty law: no buyer state, credential or captured market data may be inside the package.
for pat in 'trading.sqlite3' 'config.json' 'webhook.token' '*.pem' '*.key' 'credentials*.json' 'auth.json'; do
  hit="$(find "$LAYOUT" -name "$pat" -print -quit 2>/dev/null || true)"
  if [ -n "$hit" ]; then
    echo "   ERROR: ships-empty violation — package layout contains '$pat' ($hit)" >&2
    exit 1
  fi
done
echo "   ships-empty: no buyer state in the layout"

if [ "$MODE" = "--validate" ]; then
  echo "== [6/6] --validate: layout assembled, manifest + tiles + laws all gated. Nothing packed. =="
  du -sh "$LAYOUT" 2>/dev/null || true
  exit 0
fi

echo "== [6/6] makeappx pack -> UNSIGNED .msix =="
command -v makeappx >/dev/null 2>&1 || {
  echo "   ERROR: makeappx (Windows SDK) is not on PATH. This mode is Windows-only." >&2
  exit 1
}
mkdir -p "$DIST"
# Native makeappx cannot resolve Git-Bash POSIX paths (/d/a/...), and letting MSYS path
# conversion loose would mangle the /d /p option FLAGS instead. So: convert the path
# VALUES explicitly with cygpath, keep automatic conversion off so the flags survive.
LAYOUT_NATIVE="$(cygpath -w "$LAYOUT" 2>/dev/null || printf '%s' "$LAYOUT")"
OUT_NATIVE="$(cygpath -w "$OUT" 2>/dev/null || printf '%s' "$OUT")"
MSYS_NO_PATHCONV=1 makeappx pack /d "$LAYOUT_NATIVE" /p "$OUT_NATIVE" /overwrite
echo "   packed (UNSIGNED): $OUT"
echo
echo "   This package is UNSIGNED. It is for Partner Center upload only — the Store signs it."
echo "   It CANNOT be installed by double-clicking; MSIX sideload requires a signature."
if [ "$IDENTITY_RESOLVED" != "1" ]; then
  echo "   Identity is a placeholder: this build is a lane proof, NOT a submittable package."
fi
