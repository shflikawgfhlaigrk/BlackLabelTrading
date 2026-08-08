<#
  Black Label Trading — Windows package builder (contract windows-w1-trading-20260720).

  Runs ON the Windows build VM (Phase W0 `builder` snapshot). Assembles a self-contained,
  SHIPS-EMPTY package around the embeddable CPython runtime:

      dist/blacklabel-trading-win/
        python/            embeddable CPython 3.12 (python.exe + stdlib) — NO pip, NO site-packages
        backend/           the pure-stdlib bltd_*.py runtime (buyer path only)
        supervise.py       the supervised-child shell (replaces launchd)
        launch-trading.cmd double-click entrypoint

  LAWS enforced here:
    * Ships empty (§5.2): the staged tree is asserted to contain NO buyer state — no trading
      SQLite store, no config.json, no webhook.token, no chrome profile, no credentials, no bars.
    * Pure stdlib: the backend imports only the standard library; Postgres/Utah-only dev modules
      (bltd_pg.py, gen_reference.py) and the whole test suite are EXCLUDED from the ship.
    * No fabricated integrity: the embeddable-CPython download is verified against a REAL sha256
      pinned in windows\python-embed.sha256. Until that file holds a real hash (not __PENDING__),
      the build FAILS CLOSED — it never invents a hash and never ships an unverified runtime.
    * This script STAGES ONLY. It does not sign and does not publish. Signing is sign-windows.ps1
      (fail-closed until the cert exists, 2026-07-21+); publishing is a separate founder gate.
#>
[CmdletBinding()]
param(
  [string]$PythonVersion = "3.12.8",
  [string]$Arch = "amd64"
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Repo      = Split-Path -Parent $Here
$BackendSrc= Join-Path $Repo "backend"
$Dist      = Join-Path $Here "dist"
$Stage     = Join-Path $Dist "blacklabel-trading-win"
$PinFile   = Join-Path $Here "python-embed.sha256"

function Fail($msg) { Write-Error "build-windows: $msg"; exit 1 }

if (-not (Test-Path $BackendSrc)) { Fail "backend source not found at $BackendSrc" }
if (-not (Test-Path $PinFile))    { Fail "missing integrity pin windows\python-embed.sha256 (fail-closed)" }

# --- 1. integrity pin (no fabricated hash) --------------------------------
# The pin file's FIRST non-comment, non-blank line is the bare lowercase sha256; the remaining
# lines are guidance comments (which themselves mention __PENDING__), so the hash line MUST be
# parsed in isolation — reading the whole file -Raw would drag the comments into $Expected and
# both fail-close the build forever and break the hash compare below.
$Expected = (Get-Content $PinFile |
             Where-Object { ($_ -notmatch '^\s*#') -and ($_.Trim() -ne "") } |
             Select-Object -First 1)
$Expected = if ($null -eq $Expected) { "" } else { $Expected.Trim().ToLower() }
if ($Expected -eq "" -or $Expected -like "*__pending__*") {
  Fail "python-embed.sha256 is not pinned yet (__PENDING__). Fetch the real sha256 for " +
       "python-$PythonVersion-embed-$Arch.zip from python.org and write it to $PinFile. FAIL-CLOSED."
}
if ($Expected -notmatch '^[0-9a-f]{64}$') {
  Fail "python-embed.sha256 first line is not a 64-hex sha256 (got '$Expected'). FAIL-CLOSED."
}

# --- 2. clean stage -------------------------------------------------------
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

# --- 3. embeddable CPython (verified) -------------------------------------
$ZipName = "python-$PythonVersion-embed-$Arch.zip"
$Url     = "https://www.python.org/ftp/python/$PythonVersion/$ZipName"
$ZipPath = Join-Path $Dist $ZipName
Write-Host "build-windows: downloading $Url"
Invoke-WebRequest -Uri $Url -OutFile $ZipPath
$Actual = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLower()
if ($Actual -ne $Expected) {
  Fail "embeddable CPython sha256 mismatch. expected=$Expected actual=$Actual — refusing to ship."
}
Expand-Archive -Path $ZipPath -DestinationPath (Join-Path $Stage "python") -Force

# --- 4. backend runtime (buyer path only) ---------------------------------
$BackendDst = Join-Path $Stage "backend"
New-Item -ItemType Directory -Force -Path $BackendDst | Out-Null
# Explicit signals-only runtime allowlist. Broker-order adapters are never staged.
$RuntimeModules = @(
  "bltd_alerts.py", "bltd_analytics.py", "bltd_api.py", "bltd_browser.py",
  "bltd_capture.py", "bltd_feeds.py", "bltd_optimizer.py", "bltd_optimizer_cli.py",
  "bltd_parsers.py", "bltd_paths.py", "bltd_store.py", "bltd_topstep_bridge.py"
)
foreach ($name in $RuntimeModules) {
  $source = Join-Path $BackendSrc $name
  if (-not (Test-Path $source)) { Fail "missing backend runtime module $name" }
  Copy-Item $source -Destination $BackendDst
}

# --- 5. shell + entrypoint ------------------------------------------------
Copy-Item (Join-Path $Here "supervise.py")        -Destination $Stage
Copy-Item (Join-Path $Here "launch-trading.cmd")  -Destination $Stage
if (Test-Path (Join-Path $Here "README-WINDOWS.md")) {
  Copy-Item (Join-Path $Here "README-WINDOWS.md")  -Destination $Stage
}

# --- 6. SHIPS-EMPTY assertion (fail the build if any buyer state leaked) ---
$Forbidden = @("trading.sqlite3", "config.json", "webhook.token", "chrome-topstepx",
               "*.pem", "*.key", "credentials*.json", "auth.json")
foreach ($pat in $Forbidden) {
  $hit = Get-ChildItem -Path $Stage -Recurse -Force -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -like $pat }
  if ($hit) { Fail "ships-empty violation: staged package contains '$pat' ($($hit[0].FullName))" }
}

# --- 7. pure-stdlib smoke check with the bundled runtime ------------------
# The embeddable runtime has no pip/site-packages; if the buyer path needed a third-party module
# this import would fail HERE, on the build box, not on the buyer's machine.
$Py = Join-Path $Stage "python\python.exe"
$env:PYTHONPATH = $BackendDst
$env:PYTHONDONTWRITEBYTECODE = "1"
$env:PYTHONPYCACHEPREFIX = Join-Path $Dist "pycache-smoke"
& $Py -c "import bltd_api, bltd_capture, bltd_optimizer, bltd_optimizer_cli, bltd_store, bltd_topstep_bridge, bltd_browser, bltd_paths; print('stdlib-import OK')"
if ($LASTEXITCODE -ne 0) { Fail "bundled runtime could not import the buyer backend with stdlib only" }
$MutableCache = Get-ChildItem -Path $Stage -Recurse -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.PSIsContainer -and $_.Name -eq "__pycache__" -or
                               -not $_.PSIsContainer -and $_.Extension -eq ".pyc" }
if ($MutableCache) {
  Fail "mutable Python cache was written inside staged package ($($MutableCache[0].FullName))"
}

Write-Host "build-windows: STAGED (unsigned) -> $Stage"
Write-Host "build-windows: NOT signed, NOT published. Next: sign-windows.ps1 (fail-closed until cert)."
