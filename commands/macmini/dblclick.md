---
description: Double-click at screenshot pixel (sx, sy) on the mini's screen via cliclick gist transport.
argument-hint: "<sx> <sy>"
---

# /macmini dblclick

Double-click at SCREENSHOT pixel (sx, sy) on the Mac mini's screen.

This sub-command is SELF-CONTAINED — all steps are inlined below.
The cliclick verb difference from /macmini click is `dc:MX,MY` instead of `c:MX,MY`.

See also: /macmini click (left-click, modifier support), /macmini rclick,
/macmini drag, /macmini script.

## Step 1 — Parse args

```bash
set -- $ARGUMENTS
SX="$1"; SY="$2"
shift 2 2>/dev/null
if [ $# -gt 0 ]; then echo "ERROR: dblclick takes exactly 2 args: sx sy"; exit 1; fi
case "$SX$SY" in
  (*[!0-9-]*|"") echo "ERROR: sx/sy must be integers"; exit 1 ;;
esac
```

## Step 2 — Load calibration

```bash
CALIB="$HOME/.config/claude/macmini-calibration.json"
[ -f "$CALIB" ] || { echo "Calibration missing — run /macmini measure first."; exit 2; }

NOW=$(date +%s)
MTIME=$(stat -f %m "$CALIB" 2>/dev/null || stat -c %Y "$CALIB")
if [ $((NOW - MTIME)) -gt 2592000 ]; then
  echo "Calibration >30 days old — run /macmini measure to refresh."; exit 2
fi

read SCALE_X SCALE_Y STORED_W STORED_H <<EOF
$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d["scale_x"], d["scale_y"],
      d["canvas_geometry_at_capture"]["canvas"]["width"],
      d["canvas_geometry_at_capture"]["canvas"]["height"])
' "$CALIB")
EOF
```

## Step 3 — Pre-flight: find and select the CRD page

```
mcp.list_pages()
```

Find the page whose URL starts with `https://remotedesktop.google.com/access/session/`.
If none found, abort: "CRD canvas not present — run /macmini connect first."

```
mcp.select_page({pageId: <crd_page_id>, bringToFront: true})
```

## Step 4 — Fetch fresh canvas geometry

```javascript
mcp.evaluate_script({
  function: "() => { const cs=[...document.querySelectorAll('canvas')].sort((a,b)=>b.width*b.height-a.width*a.height); const c=cs[0]; if(!c) return {error:'no canvas'}; const r=c.getBoundingClientRect(); const zoom=(window.visualViewport&&window.visualViewport.scale)||(window.outerWidth/window.innerWidth)||1; return { dpr: window.devicePixelRatio, zoom, scrollX:window.scrollX, scrollY:window.scrollY, canvas:{x:r.x,y:r.y,width:r.width,height:r.height}}; }"
})
```

- If `error === 'no canvas'`: abort "CRD canvas not present — /macmini connect".
- If `scrollX !== 0 || scrollY !== 0`: abort "CRD page is scrolled — scroll to top-left first."

## Step 5 — Staleness check

```
if abs(canvas.width - STORED_W) > 5 OR abs(canvas.height - STORED_H) > 5:
  abort "Canvas size changed since calibration — run /macmini measure to refresh."
```

## Step 6 — Convert screenshot pixels → mini-physical pixels

```bash
total_scale = dpr * zoom
vx = SX / total_scale
vy = SY / total_scale
cx = vx - canvas.x
cy = vy - canvas.y
```

If NOT (0 <= cx < canvas.width AND 0 <= cy < canvas.height):
  abort "Click target outside CRD canvas."

```bash
MINI_X = round(cx * SCALE_X)
MINI_Y = round(cy * SCALE_Y)
```

## Step 7 — Occlusion check (CRD auto-hide toolbar)

```javascript
mcp.evaluate_script({
  function: `() => { const cs=[...document.querySelectorAll('canvas')].sort((a,b)=>b.width*b.height-a.width*a.height); const target=cs[0]; const el=document.elementFromPoint(${vx}, ${vy}); return { isCanvas: el===target, actualTag: el?el.tagName:null }; }`
})
```

If `isCanvas === false`:
- If in the CRD UI overlay zone (top 60px or bottom 30px of canvas): wait 3s and retry once.
- If still occluded, abort: "Click target occluded by CRD toolbar — wait for it to auto-hide, then retry."

## Step 8 — Build run.sh (with activate-target / sleep-0.6 / refocus-Terminal pattern)

```bash
TARGET_APP="${TARGET_APP:-Google Chrome}"

CLICKBIN_PROBE='if [ -x /opt/homebrew/bin/cliclick ]; then CB=/opt/homebrew/bin/cliclick; elif [ -x /usr/local/bin/cliclick ]; then CB=/usr/local/bin/cliclick; else echo "cliclick not installed — run: brew install cliclick"; exit 4; fi'

TMPDIR_LOCAL="$(mktemp -d -t macmini-dblclick.XXXXXX)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT INT TERM
RUN_FILE="$TMPDIR_LOCAL/run.sh"

cat > "$RUN_FILE" <<RUNSH
#!/bin/bash
set -uo pipefail
${CLICKBIN_PROBE}
osascript -e 'tell application "${TARGET_APP}" to activate' >/dev/null 2>&1
sleep 0.6
PRE=\$("\$CB" p: 2>&1); echo "Pre: \$PRE"
"\$CB" dc:${MINI_X},${MINI_Y}
RC=\$?; echo "Exit: \$RC"
sleep 0.2
POST=\$("\$CB" p: 2>&1); echo "Post: \$POST"
osascript -e 'tell application "Terminal" to activate' >/dev/null 2>&1
echo OK
RUNSH
```

## Step 9 — Upload as a SECRET gist

```bash
GIST_OUT=$(gh gist create "$RUN_FILE" 2>&1)
GIST_URL=$(printf '%s' "$GIST_OUT" | grep -oE 'https://gist\.github\.com/[^[:space:]]+' | head -n1)
GIST_ID=$(printf '%s' "$GIST_URL" | sed -E 's#.*/##' | sed 's/[?#].*//')
case "$GIST_ID" in
  ([a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]*) ;;
  *) echo "ERROR: gh did not produce a gist URL. Output: $GIST_OUT"; exit 3 ;;
esac
```

## Step 10 — Confirm mini Terminal is foreground, then type the clone command

Screenshot first. If Terminal isn't foreground, `mcp.press_key("Meta+Tab")`
(MRU cycle) or `mcp.press_key("Meta+h")` (hide top app to reveal Terminal).

```bash
CLONE_CMD="rm -rf /tmp/macmini-dblclick; gh gist clone $GIST_ID /tmp/macmini-dblclick; bash /tmp/macmini-dblclick/run.sh"

LC_ALL=C bash -c '
  case "$1" in
    (*[^a-z0-9\ /.\;:_-]*) exit 3 ;;
  esac
' _ "$CLONE_CMD" || { echo "ERROR: clone command contains unsafe chars"; exit 3; }
```

```
mcp.type_text("rm -rf /tmp/macmini-dblclick; gh gist clone " + GIST_ID + " /tmp/macmini-dblclick; bash /tmp/macmini-dblclick/run.sh", "Enter")
```

## Step 11 — Verify clone + execute landed

```
mcp.take_screenshot()
```

Confirm `Cloning into '/tmp/macmini-dblclick/'`, `OK`, and a fresh shell prompt.
Shift-strip detection: continuation prompt → press Control+c twice, retry.

## Step 12 — Verify-after

```
mcp.take_screenshot()
```

Confirm the double-click had its intended visual effect (file opened, text selected, etc.).

## Step 13 — Cleanup

```bash
gh gist delete "$GIST_ID" --yes 2>/dev/null
```

## Step 14 — Final report

```
double-clicked screenshot ($SX, $SY) → mini ($MINI_X, $MINI_Y) via gist $GIST_ID (deleted)
```
