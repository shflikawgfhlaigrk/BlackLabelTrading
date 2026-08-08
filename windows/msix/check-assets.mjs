#!/usr/bin/env node
// Black Label Trading — MSIX Store-tile gate.
//
// makeappx fails a pack if a manifest-referenced Assets\*.png is missing or is not a real PNG,
// and the Store rejects a submission whose tiles are the wrong pixel size. Both failures are
// cheap to catch here and expensive to catch after a full Windows stage build, so this runs on
// ANY host (macOS included) before anything is packed.
//
// It reads the REQUIRED sizes out of the manifest itself, so a manifest edit can never drift
// silently away from the art on disk.
//
//   node windows/msix/check-assets.mjs <dir-containing-AppxManifest.xml-and-Assets>
//
// Zero dependencies by design (the product backend is pure-stdlib; the packaging lane matches).

import fs from 'node:fs';
import path from 'node:path';

// Microsoft's fixed pixel dimensions for the scale-100 tiles this manifest declares.
// Keyed by the manifest attribute / element that references each one.
const SPEC = {
  'StoreLogo.png': [50, 50],
  'Square44x44Logo.png': [44, 44],
  'Square71x71Logo.png': [71, 71],
  'Square150x150Logo.png': [150, 150],
  'Square310x310Logo.png': [310, 310],
  'Wide310x150Logo.png': [310, 150],
};

// Ancillary PNG chunks that can carry free text (author, software, comment, source path, XMP).
// Those are a brand-isolation leak surface in a shipped Store tile: a rasteriser routinely
// stamps the originating file path or toolchain into them. Colour chunks (gAMA, cHRM, sRGB,
// pHYs) hold no strings and stay allowed.
const TEXT_CHUNKS = new Set(['tEXt', 'iTXt', 'zTXt', 'eXIf', 'tIME']);

function chunkTypes(buf) {
  const types = [];
  let o = 8;
  while (o + 12 <= buf.length) {
    const len = buf.readUInt32BE(o);
    types.push(buf.toString('ascii', o + 4, o + 8));
    o += 12 + len;
  }
  return types;
}

const root = process.argv[2];
if (!root) {
  console.error('usage: check-assets.mjs <dir with AppxManifest.xml + Assets/>');
  process.exit(2);
}

const manifestPath = path.join(root, 'AppxManifest.xml');
if (!fs.existsSync(manifestPath)) {
  console.error(`FAIL: no AppxManifest.xml in ${root}`);
  process.exit(1);
}
const manifest = fs.readFileSync(manifestPath, 'utf8');

const referenced = [
  ...new Set(
    [...manifest.matchAll(/Assets[\\/]([A-Za-z0-9._-]+\.png)/g)].map((m) => m[1]),
  ),
].sort();

if (referenced.length === 0) {
  console.error('FAIL: the manifest references no Assets\\*.png — Logo/VisualElements is broken');
  process.exit(1);
}

let bad = 0;
for (const name of referenced) {
  const file = path.join(root, 'Assets', name);
  if (!fs.existsSync(file)) {
    console.error(`FAIL ${name}: referenced by the manifest but MISSING from Assets/`);
    bad++;
    continue;
  }
  const buf = fs.readFileSync(file);
  const sigOk =
    buf.length > 24 &&
    buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47;
  if (!sigOk) {
    console.error(`FAIL ${name}: not a real PNG (makeappx would reject the pack)`);
    bad++;
    continue;
  }
  const w = buf.readUInt32BE(16);
  const h = buf.readUInt32BE(20);
  const want = SPEC[name];
  if (!want) {
    console.error(`FAIL ${name}: manifest references a tile with no known Store size spec`);
    bad++;
    continue;
  }
  if (w !== want[0] || h !== want[1]) {
    console.error(`FAIL ${name}: is ${w}x${h}, Store spec is ${want[0]}x${want[1]}`);
    bad++;
    continue;
  }
  const texty = chunkTypes(buf).filter((t) => TEXT_CHUNKS.has(t));
  if (texty.length) {
    console.error(
      `FAIL ${name}: carries text-bearing PNG chunks (${texty.join(', ')}) — strip them; ` +
        'they can leak a toolchain or filesystem path into a shipped Store tile',
    );
    bad++;
    continue;
  }
  console.log(`  ok ${name} ${w}x${h}`);
}

if (bad) {
  console.error(`\nStore tile gate FAILED (${bad} problem${bad === 1 ? '' : 's'}).`);
  process.exit(1);
}
console.log(`Store tile gate PASSED (${referenced.length} tiles).`);
