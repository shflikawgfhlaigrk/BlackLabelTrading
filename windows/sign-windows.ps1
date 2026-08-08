<#
  Black Label Trading — Windows signing/packaging stage (contract windows-w1-trading-20260720).

  FAIL-CLOSED BY DESIGN. Per the founder Windows-lane GO (2026-07-20) the channel is STORE-FIRST
  MSIX: Microsoft signs the package at Partner Center ingestion, so no Authenticode cert is needed
  for that path — but the Partner Center publisher identity does not exist yet (founder-only, ~10
  min registration), and the OV cert for the dormant /dl self-distribution fallback is not
  purchased until 2026-07-21+.

  Until ONE of those identities is real, this stage exits NON-ZERO and publishes NOTHING. It never
  invents a publisher name, never self-signs a shippable artifact, and never uploads. This mirrors
  the bl-ship Windows-lane law (PARTNER_CENTER_READY marker / fail-closed sign_windows).

  Inputs (any one flips the gate open; none exist today → fail closed):
    * $env:BLTD_WIN_PARTNER_CENTER_ID  — real Partner Center publisher id (Store MSIX path)
    * $env:BLTD_WIN_CERT               — path to a real OV/EV code-signing cert (self-dist path)
#>
[CmdletBinding()]
param([string]$Stage = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "dist\blacklabel-trading-win"))
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Gate($msg) { Write-Error "sign-windows [FAIL-CLOSED]: $msg"; exit 2 }

if (-not (Test-Path $Stage)) { Gate "no staged package at $Stage — run build-windows.ps1 first." }

$pcId = ($env:BLTD_WIN_PARTNER_CENTER_ID | ForEach-Object { $_ }) -as [string]
$cert = ($env:BLTD_WIN_CERT | ForEach-Object { $_ }) -as [string]

if ($pcId -and $pcId.Trim() -ne "" -and $pcId -notlike "*__PENDING__*") {
  Gate "Partner Center MSIX packaging is not implemented in W1 (staged only). Publisher id is set " +
       "but Store submission is a separate founder-gated step. Refusing to auto-publish."
}
if ($cert -and (Test-Path $cert)) {
  Gate "OV/EV Authenticode self-distribution is a DORMANT fallback. Signing is not wired for W1 " +
       "and /dl publishing is founder-gated. Refusing to sign+publish."
}

Gate "no Windows signing identity exists yet (Partner Center publisher unregistered; OV cert not " +
     "purchased until 2026-07-21+). Package STAYS staged + unsigned. Nothing published."
