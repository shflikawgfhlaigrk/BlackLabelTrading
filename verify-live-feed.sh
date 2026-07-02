#!/usr/bin/env bash
# verify-live-feed.sh — turnkey, self-capturing PROOF that a prop-firm feed is loading REAL live bars.
# Run this AFTER connecting a feed in the app (Feeds tab), during market hours.
# It reports the honest truth: PROVEN LIVE (with evidence) / idle / auth_error / not connected.
# It never simulates anything — it only reads what the running backend + local store actually hold.
set -u
PORT="${BLTD_PORT:-8787}"
SUPPORT="$HOME/Library/Application Support/Black Label Trading"
STORE="${BLTD_STORE:-$SUPPORT/trading.sqlite3}"
PROOF_DIR="$SUPPORT/proofs"; mkdir -p "$PROOF_DIR"
PY="$(command -v python3 || true)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

echo "── Black Label Trading · live-feed proof ── $STAMP"
if [ -z "$PY" ]; then echo "⚪ python3 not found — open the app once (it installs a working python3) or run: xcode-select --install"; exit 2; fi

STATUS="$(curl -s --max-time 5 "http://127.0.0.1:$PORT/api/feed/status" 2>/dev/null || true)"
if [ -z "$STATUS" ]; then
  echo "⚪ NOT CONNECTED — backend not reachable on :$PORT. Open the app and Connect a feed first."
  exit 2
fi

"$PY" - "$STATUS" "$STORE" "$PROOF_DIR/proof-$STAMP.json" <<'PYEOF'
import sys, json, sqlite3, time, os
status_raw, store, proof_path = sys.argv[1], sys.argv[2], sys.argv[3]
try: st = json.loads(status_raw)
except Exception: st = {}
state  = str(st.get("state",""))
source = str(st.get("source") or st.get("feed") or "")
detail = str(st.get("detail",""))
age    = st.get("lastTickAge")

# Ground truth = the local store. Count ES bars + read the most recent real bar.
bars=0; last_epoch=None; last_price=None
try:
    c=sqlite3.connect(store); cur=c.cursor()
    cur.execute("select count(*), max(epoch) from bars where symbol='ES'")
    row=cur.fetchone() or (0,None); bars=row[0] or 0; last_epoch=row[1]
    if last_epoch is not None:
        cur.execute("select close from bars where symbol='ES' and epoch=? limit 1",(last_epoch,))
        r=cur.fetchone();  last_price=(r[0] if r else None)
    c.close()
except Exception as e:
    detail=(detail+f" [store: {e}]").strip()

now=int(time.time())
fresh = (last_epoch is not None) and (now-int(last_epoch) <= 120)   # a real bar within 2 min
verdict, line = "UNKNOWN", ""
if state=="live" and fresh:
    verdict="PROVEN_LIVE"
    line=(f"✅ PROVEN LIVE — REAL bars from '{source}'. ES last={last_price} "
          f"@ epoch {last_epoch} ({now-int(last_epoch)}s ago), {bars} ES bars in store. Not simulated.")
elif state in ("connecting","authenticating") or (state=="live" and not fresh):
    verdict="IDLE"
    line=(f"⏳ CONNECTED, NO TICKS YET — state='{state}'. Market may be closed, or the account lacks "
          f"its market-data entitlement. {bars} ES bars stored; newest is "
          f"{('%ds old'%(now-int(last_epoch))) if last_epoch else 'none'}. (Honest empty — nothing faked.)")
elif state in ("auth_error","error"):
    verdict="AUTH_ERROR"
    line=f"🔴 AUTH/ENTITLEMENT ERROR — {detail or 'rejected by the feed'}. Fix the credential or data subscription."
else:
    verdict="NOT_CONNECTED"
    line=f"⚪ NOT STREAMING — state='{state or 'none'}'. Connect a feed in the app's Feeds tab."

print(line)
rec=dict(stamp_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),verdict=verdict,state=state,
         source=source,detail=detail,es_bars=bars,last_epoch=last_epoch,last_price=last_price,
         last_age_sec=(now-int(last_epoch)) if last_epoch else None)
open(proof_path,"w").write(json.dumps(rec,indent=2))
print(f"   evidence written: {proof_path}")
sys.exit(0 if verdict=="PROVEN_LIVE" else 1)
PYEOF
