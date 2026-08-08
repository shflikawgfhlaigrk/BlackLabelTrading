@echo off
rem Black Label Trading — Windows entrypoint (contract windows-w1-trading-20260720).
rem Double-click target. Runs the bundled embeddable CPython on the supervisor, which owns the
rem lifecycle of the API server + capture/edge-gate daemon + TopstepX bridge, and opens the honest
rem "connect your platform" flow in a product-owned remote-debug Chrome. Ships empty; signals only.
setlocal
set "HERE=%~dp0"
set "PY=%HERE%python\python.exe"
if not exist "%PY%" (
  echo Black Label Trading: bundled runtime missing at "%PY%".
  echo Reinstall Black Label Trading from the official download, then reopen.
  exit /b 3
)
"%PY%" "%HERE%supervise.py" %*
endlocal
