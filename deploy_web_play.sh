#!/bin/bash
# Deploys the staged FORGEFALL web build (v0.6.3, code 42) to
# https://vatherty.github.io/Forgefall-updates/play/
# Staged export: ~/workspace/forgefall/web_staging/forgefall-web/ (2026-10-19, single-threaded)
# Run from a NORMAL turn (proactivity turns lack GitHub write authority).
set -u
G="python3 $HOME/workspace/custom-connectors/custom.github/bin/github.py"
O="--owner vatherty --repo Forgefall-updates"
SRC="$HOME/workspace/forgefall/web_staging/forgefall-web"
ok=1
n=0
total=9
for f in index.html index.js index.wasm index.pck index.audio.worklet.js index.audio.position.worklet.js index.icon.png index.apple-touch-icon.png index.png; do
  n=$((n+1))
  if [ ! -f "$SRC/$f" ]; then echo "MISSING: $f"; ok=0; continue; fi
  out=$($G upload $O --path "play/$f" --file "$SRC/$f" --message "Web build: FORGEFALL v0.6.3 browser port ($n/$total)" 2>&1)
  if echo "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['content']['path'])" 2>/dev/null; then
    : # uploaded
  else
    echo "FAILED: $f"; echo "$out" | head -c 300; echo; ok=0
  fi
done
if [ $ok -eq 1 ]; then
  echo "ALL $total UPLOADED. Verify: curl -s -o /dev/null -w '%{http_code}' https://vatherty.github.io/Forgefall-updates/play/"
  echo "(Allow ~1-2 min for the Pages build. If pages-get says 'errored', re-run pages-enable for a 409 + rebuild, as with website-demos.)"
else
  echo "DEPLOY INCOMPLETE — fix failures above before announcing the link."
fi
