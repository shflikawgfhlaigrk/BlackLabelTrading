# Black Label Trading — Windows lane (W1 flagship port)

Contract `windows-w1-trading-20260720` · plan §W1 · founder GO `STATE/decisions/windows-lane-go-20260720.md`.
Same laws as the macOS gold master: **ships empty, signals only, zero fabricated numbers.**

## What this lane is

The Trading backend is pure-stdlib Python with zero Apple imports, so the Windows product is a
**thin cross-platform port of the same engine**, not a rewrite. This directory holds the Windows
shell + packaging; the port itself lives in the shared backend and stays byte-identical on macOS.

```
windows/
  supervise.py          supervised child-process shell — REPLACES launchd/nohup respawn.
                        Owns lifecycle of: bltd_api (API), bltd_capture (capture + edge-gate),
                        bltd_topstep_bridge. Restarts on death, clean shutdown, single-instance.
                        `python supervise.py --plan` prints the launch plan and exits (no spawn).
  build-windows.ps1     bundles embeddable CPython 3.12 + the stdlib backend into dist/ (STAGES ONLY).
  python-embed.sha256   integrity pin for the embeddable runtime (real upstream SHA-256 pinned).
  sign-windows.ps1      signing/publish stage — FAIL-CLOSED (no identity exists yet).
  launch-trading.cmd    double-click entrypoint (runs bundled python on supervise.py).
```

Shared cross-platform port (in `../backend/`, darwin behavior unchanged, proven by the suite):
- `bltd_paths.py` — per-OS app-support/store/profile paths (`%LOCALAPPDATA%` on Windows, the
  historical `~/Library/Application Support/...` on macOS, byte-identical).
- `bltd_browser.py` — Chromium-family resolution + remote-debug launch. macOS uses
  `open -g -n -a`; Windows launches `chrome.exe`/`msedge.exe`/`brave.exe` directly with the SAME
  loopback-pinned CDP flag set. This is the **§T3 honest connect flow, now cross-platform** — the
  buyer logs into THEIR OWN TopstepX/WealthCharts in a product-owned debug profile.
- `bltd_capture.py` / `bltd_store.py` — rewired to delegate to the two modules above.

## Charts / UI

Charts are the buyer's own trading-platform charts, rendered in the product-owned remote-debug
browser (identical to macOS) — there is no separate chart HTML to port. The Windows UI story for
W1 is the supervised backend + the honest connect screen in the browser. A richer wrapped web UI
is a later phase; W1 proves the engine + feed + connect flow run natively on Windows.

## Honest status (do not round up)

- ⚠️ **Ported; cross-platform unit gate currently blocked on macOS:** paths, browser
  resolution/launch argv (both OS branches), the supervisor plan, canonical port, and external
  Python cache are covered. The complete backend suite currently collects **256 tests:
  254 passed / 2 failed**; both failures are release-blocking `reference_oos.json`
  freshness/provenance checks. This is code-path evidence, not an on-Windows acceptance result.
  See `test_windows_lane.py`.
- ⏳ **STAGED, not verified on Windows:** `build-windows.ps1` has not been run on the Windows VM
  in this session (the embeddable-CPython bundle + on-Windows import smoke check run there). The
  upstream runtime hash is pinned and provenance-recorded, but the package remains unverified on
  an actual Windows host.
- 🔒 **Not signed, not published (founder gates):** `sign-windows.ps1` fails closed — no Partner
  Center publisher identity (Store MSIX path) and no OV cert (self-dist path, purchase deferred
  past 2026-07-21). No storefront page/button/marketing exists or is wired.
- ⏳ **Gauntlet NOT run:** the clean-buyer VM download→sha→SmartScreen→Defender→install→first-run
  dossier (plan §The gauntlet) has not been executed. Required before any Windows ship claim.

## Next (for the assignment that picks this up)

1. Run `build-windows.ps1` on the `builder` VM and capture the on-Windows stdlib-import smoke result.
2. Wire the Windows lane into bl-ship (`build_cmd_windows`, `built_artifact_windows`, MSIX stage).
3. Run the clean-buyer gauntlet → dossier in `STATE/reports/`.
4. Founder gates: Partner Center registration, SKU stance, any Windows storefront surface.
