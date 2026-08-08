# Black Label Trading — Microsoft Store submission

Status: **the packaging lane is built and provable; the submission is BLOCKED on Partner Center
account verification.** Nothing below invents an identity value, a certificate, or a Store listing.

---

## 1. What has to be reserved first

In Partner Center → **Apps and games → New product → MSIX or PWA app**, reserve the app name:

> **Black Label Trading**

The account is registered as an **INDIVIDUAL, not a company**. Consequence: the publisher name
shown on the Store listing is the owner's **verified legal name**. It is not a trading name and it
is not editable to one. Any packaging that hardcoded a company publisher string would be rejected
at upload, which is why no such string exists anywhere in this lane.

Reserving the name is what causes Microsoft to assign the three identity values below. **They do
not exist until then.** None of them are guessed anywhere in this repository.

---

## 2. Where the three identity values get pasted

All three live in exactly **one file**:

```
windows/msix/AppxManifest.xml
```

Search it for `PASTE-` and `PASTE `. There are exactly three hits:

| # | Partner Center field (Product → **Product identity**) | Placeholder token in `AppxManifest.xml` | Line context |
|---|---|---|---|
| 1 | `Package/Identity/Name` | `PASTE-PARTNER-CENTER-PACKAGE-IDENTITY-NAME-HERE` | `<Identity Name="…">` |
| 2 | `Package/Identity/Publisher` (the `CN=…` string Microsoft issues) | `CN=PASTE-PARTNER-CENTER-PUBLISHER-CN-HERE` | `<Identity Publisher="…">` |
| 3 | `Package/Properties/PublisherDisplayName` (the **verified legal name**) | `PASTE VERIFIED LEGAL NAME FROM PARTNER CENTER` | `<PublisherDisplayName>…</PublisherDisplayName>` |

Copy each value **byte for byte** out of the Partner Center *Product identity* page. Partner Center
rejects an upload whose identity does not match exactly — including case.

### Alternative: inject at build time instead of editing the file

`build-msix.sh` reads three environment variables and substitutes the tokens without touching the
manifest on disk:

```bash
PARTNER_CENTER_IDENTITY_NAME='…' \
PARTNER_CENTER_PUBLISHER='CN=…' \
PARTNER_CENTER_PUBLISHER_DISPLAY_NAME='…' \
bash windows/build-msix.sh
```

In CI these are read from **repository variables** of the same three names (`vars.*` in
`.github/workflows/windows-msix.yml`). They are public identity values printed on the Store
listing, so they are variables, not secrets.

**Safety behaviour:** while any placeholder survives, `build-msix.sh` names the output
`BlackLabelTrading-PLACEHOLDER-IDENTITY-NOT-SUBMITTABLE.msix` and the CI artifact verdict reads
`PACKED-PLACEHOLDER-IDENTITY`. A lane-proof build can therefore never be mistaken for a
submittable package, even by someone who never opens it.

Also set `<Identity Version="…">` before the first submission. It must be `Major.Minor.Build.0` —
the Store requires the fourth part to be `0` and rejects a version already used by the product.

---

## 3. How to build

### On any machine, including this Mac — validate without packing

```bash
bash windows/build-msix.sh --validate
```

Assembles the package layout, checks the manifest is well-formed, gates every Store tile
(existence, real PNG, exact pixel size, no text-bearing metadata chunks), and enforces the
signals-only and ships-empty laws. Packs nothing. This is the fast feedback loop.

### On Windows — produce the real MSIX

```powershell
# 1. stage the payload: embeddable CPython 3.12 (sha256-pinned, fails closed) + pure-stdlib backend
./windows/build-windows.ps1

# 2. compile the MSIX entry-point launcher with the in-box .NET Framework compiler
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /platform:x64 `
    /out:windows/dist/BlackLabelTrading.exe windows/msix/launcher/Launcher.cs

# 3. pack
bash windows/build-msix.sh
```

Output: `windows/dist/BlackLabelTrading.msix`.

### In CI

`.github/workflows/windows-msix.yml` — `workflow_dispatch`, or any push touching `windows/**`.

* `validate` job on `ubuntu-latest` runs the host-agnostic gates first.
* `msix` job on `windows-latest` does all three steps above and uploads the `.msix`, the resolved
  `AppxManifest.xml`, runner evidence, the sha256 and a `VERDICT` file.
* The job is **fail-closed** — no `continue-on-error`. A run that packs nothing ends red.
* Everything is repo-relative. The lane checks out one repository and needs no sibling checkout,
  no self-hosted runner and no developer machine.

---

## 4. Why the MSIX has a launcher .exe

MSIX requires `Application/@Executable` to be a real PE image. `launch-trading.cmd` cannot be it.
`windows/msix/launcher/Launcher.cs` is a ~100-line launcher that resolves its own directory inside
the installed package, starts the bundled `python\pythonw.exe` on `supervise.py`, and waits for it
so Windows sees one process representing the app. It reads no configuration, opens no socket, and
resolves nothing outside the package directory. `launch-trading.cmd` is still shipped inside the
package for non-Store/manual use.

---

## 5. Store assets

Six Store tiles are committed at `windows/msix/Assets/`, generated from the product's own
512×512 app icon and stripped of all text-bearing PNG metadata:

| File | Size | Referenced by |
|---|---|---|
| `StoreLogo.png` | 50×50 | `Properties/Logo` |
| `Square44x44Logo.png` | 44×44 | `VisualElements/Square44x44Logo` |
| `Square71x71Logo.png` | 71×71 | `DefaultTile/Square71x71Logo` |
| `Square150x150Logo.png` | 150×150 | `VisualElements/Square150x150Logo` |
| `Square310x310Logo.png` | 310×310 | `DefaultTile/Square310x310Logo` |
| `Wide310x150Logo.png` | 310×150 | `DefaultTile/Wide310x150Logo` |

`windows/msix/check-assets.mjs` reads the required tiles **out of the manifest**, so a manifest
edit can never drift away from the art on disk.

**Still missing — these are Partner Center *listing* assets, not package assets, and they block
the store listing, not the build:**

* **Screenshots** — at least one 1366×768 (or larger) PNG of the running Windows app. None exist;
  the Windows app has not been run and captured.
* **Store listing copy** — description, feature list, search terms, "what's new".
* **Age rating questionnaire** answers.
* **Privacy policy URL** — mandatory for any app that makes network calls, and this one fetches
  market data feeds.
* **Support contact.**
* Optional but recommended: a 2400×1200 hero image, and per-scale (125/150/200/400%) tile variants.
  Only the scale-100 tiles above are declared, which is valid — Windows scales them.

---

## 6. Signing — read this before assuming the package is installable

No Authenticode certificate has been purchased and none is applied.

* **Store path (this lane): correct as-is.** Microsoft re-signs an uploaded package under the
  Partner Center account identity. Uploading an unsigned `.msix` is the supported flow.
* **Sideload path: NOT supported by this lane.** MSIX sideload install requires a signature.
  Double-clicking the artifact this lane produces will fail. It is not a distributable build and
  nothing here pretends it is. Sideloading would need either a purchased Authenticode certificate
  or a self-signed test certificate trusted on the target machine — neither exists, and buying one
  is an owner decision.

---

## 7. What is still blocked

| Blocker | Owner | Blocks |
|---|---|---|
| Partner Center account **verification not complete** | Microsoft / owner | everything downstream |
| App name **not reserved** → the 3 identity values do not exist | owner (after verification) | a *submittable* package |
| Store **listing assets** (screenshots, copy, privacy policy URL, age rating, support contact) | owner | the listing, not the build |
| **No Windows machine has ever run this package** | — | end-to-end install proof. CI proves the package *packs*; it does not prove the app *launches*. |
| Authenticode certificate (sideload only) | owner, a purchase | sideload distribution only — irrelevant to the Store path |

**What is NOT blocked:** the packaging lane itself. It builds, gates and produces a real MSIX
today, with placeholder identity, on a GitHub-hosted `windows-latest` runner.

---

## 8. Note on the `winapp` CLI

Microsoft's `winapp` CLI (public preview, installable in CI via the `setup-WinAppCli` action) can
do MSIX packaging, manifest generation and certificate generate/sign, and is the better fit for a
Tauri or WinUI project. This app is not one: it is an embeddable-CPython payload behind a thin
launcher, so the pieces `winapp` would generate are the pieces that already exist here. This lane
therefore uses `makeappx` from the Windows SDK, which is preinstalled on `windows-latest` and needs
no install step.

Its exact flag syntax has not been verified against a live install from this machine, so no
`winapp` command line is written down here rather than guessing one. If the lane is ever moved onto
it, verify the flags against `winapp --help` on a real runner first.

---

## 9. Product law

Black Label Trading is **signals-only**. It never places, routes, modifies or cancels an order.
Nothing in this packaging lane adds execution capability, and `build-msix.sh` fails the pack if a
broker/execution adapter (`bltd_projectx.py`, `bltd_tradovate.py`) ever reaches the package layout.
The package also ships empty — no buyer state, credentials or captured market data — and the pack
fails if any appears in the layout.
