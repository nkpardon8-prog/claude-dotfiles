---
description: Drag from screenshot pixel (sx1, sy1) to (sx2, sy2) on the mini's screen via cliclick gist transport.
argument-hint: "<sx1> <sy1> <sx2> <sy2>"
---

# /macmini drag

Drag from SCREENSHOT pixel (sx1, sy1) to (sx2, sy2) on the Mac mini's screen.
Mouse-down fires at the start point; mouse-up fires at the end point. Both happen
in a single cliclick invocation (`dd:MX1,MY1 du:MX2,MY2`) — atomic.

This sub-command is SELF-CONTAINED. All steps are inlined below. The coord
conversion and occlusion check run TWICE — once per endpoint.

**Occlusion policy:** the START point must be unoccluded (abort if covered).
The END point occlusion check is a WARNING ONLY — drop targets may legitimately
be on toolbars or sidebars. Log a warning and proceed.

See also: /macmini click, /macmini rclick, /macmini dblclick, /macmini script.

## Step 1 — Parse args

```bash
set -- $ARGUMENTS
SX1="$1"; SY1="$2"; SX2="$3"; SY2="$4"
shift 4 2>/dev/null
if [ $# -gt 0 ]; then echo "ERROR: drag takes exactly 4 args: sx1 sy1 sx2 sy2"; exit 1; fi
case "$SX1$SY1$SX2$SY2" in
  (*[!0-9-]*|"") echo "ERROR: all four coords must be integers"; exit 1 ;;
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

## Step 4 — Fetch fresh canvas geometry (once — shared by both endpoints)

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

## Step 6 — Convert START point (sx1, sy1) → mini-physical pixels

```bash
total_scale = dpr * zoom
vx1 = SX1 / total_scale
vy1 = SY1 / total_scale
cx1 = vx1 - canvas.x
cy1 = vy1 - canvas.y
```

If NOT (0 <= cx1 < canvas.width AND 0 <= cy1 < canvas.height):
  abort "Drag start point outside CRD canvas."

```bash
MINI_X1 = round(cx1 * SCALE_X)
MINI_Y1 = round(cy1 * SCALE_Y)
```

## Step 7 — Occlusion check: START point (ABORT if occluded)

```javascript
mcp.evaluate_script({
  function: `() => { const cs=[...document.querySelectorAll('canvas')].sort((a,b)=>b.width*b.height-a.width*a.height); const target=cs[0]; const el=document.elementFromPoint(${vx1}, ${vy1}); return { isCanvas: el===target, actualTag: el?el.tagName:null }; }`
})
```

If `isCanvas === false`:
- If start is in CRD UI overlay zone (top 60px or bottom 30px of canvas): wait 3s and retry once.
- If still occluded, abort: "Drag start point occluded by CRD toolbar — wait for it to auto-hide, then retry."

## Step 8 — Convert END point (sx2, sy2) → mini-physical pixels

```bash
vx2 = SX2 / total_scale
vy2 = SY2 / total_scale
cx2 = vx2 - canvas.x
cy2 = vy2 - canvas.y
```

If NOT (0 <= cx2 < canvas.width AND 0 <= cy2 < canvas.height):
  abort "Drag end point outside CRD canvas."

```bash
MINI_X2 = round(cx2 * SCALE_X)
MINI_Y2 = round(cy2 * SCALE_Y)
```

## Step 9 — Occlusion check: END point (WARNING ONLY — do not abort)

```javascript
mcp.evaluate_script({
  function: `() => { const cs=[...document.querySelectorAll('canvas')].sort((a,b)=>b.width*b.height-a.width*a.height); const target=cs[0]; const el=document.elementFromPoint(${vx2}, ${vy2}); return { isCanvas: el===target, actualTag: el?el.tagName:null }; }`
})
```

If `isCanvas === false`:
  Print: "WARNING: drag end point is occluded by a non-canvas element (tag: <actualTag>). This may be a valid drop target (toolbar/sidebar). Proceeding."
  Do NOT abort — continue to Step 10.

## Step 10 — Build run.sh (with activate-target / sleep-0.6 / refocus-Terminal pattern)

```bash
TARGET_APP="${TARGET_APP:-Google Chrome}"

CLICKBIN_PROBE='if [ -x /opt/homebrew/bin/cliclick ]; then CB=/opt/homebrew/bin/cliclick; elif [ -x /usr/local/bin/cliclick ]; then CB=/usr/local/bin/cliclick; else echo "cliclick not installed — run: brew install cliclick"; exit 4; fi'

TMPDIR_LOCAL="$(mktemp -d -t macmini-drag.XXXXXX)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT INT TERM
RUN_FILE="$TMPDIR_LOCAL/run.sh"

cat > "$RUN_FILE" <<RUNSH
#!/bin/bash
set -uo pipefail
${CLICKBIN_PROBE}
osascript -e 'tell application "${TARGET_APP}" to activate' >/dev/null 2>&1
sleep 0.6
PRE=\$("\$CB" p: 2>&1); echo "Pre: \$PRE"
# dd = mouse-down at start, du = mouse-up at end. Single shell invocation — atomic drag.
"\$CB" dd:${MINI_X1},${MINI_Y1} du:${MINI_X2},${MINI_Y2}
RC=\$?; echo "Exit: \$RC"
sleep 0.2
POST=\$("\$CB" p: 2>&1); echo "Post: \$POST"
osascript -e 'tell application "Terminal" to activate' >/dev/null 2>&1
echo OK
RUNSH
```

## Step 11 — Upload as a SECRET gist

```bash
GIST_OUT=$(gh gist create "$RUN_FILE" 2>&1)
GIST_URL=$(printf '%s' "$GIST_OUT" | grep -oE 'https://gist\.github\.com/[^[:space:]]+' | head -n1)
GIST_ID=$(printf '%s' "$GIST_URL" | sed -E 's#.*/##' | sed 's/[?#].*//')
case "$GIST_ID" in
  ([a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]*) ;;
  *) echo "ERROR: gh did not produce a gist URL. Output: $GIST_OUT"; exit 3 ;;
esac
```

## Step 12 — Confirm mini Terminal is foreground, then type the clone command

Screenshot first. If Terminal isn't foreground, `mcp.press_key("Meta+Tab")`
(MRU cycle) or `mcp.press_key("Meta+h")` (hide top app to reveal Terminal).

```bash
CLONE_CMD="rm -rf /tmp/macmini-drag; gh gist clone $GIST_ID /tmp/macmini-drag; bash /tmp/macmini-drag/run.sh"

LC_ALL=C bash -c '
  case "$1" in
    (*[^a-z0-9\ /.\;:_-]*) exit 3 ;;
  esac
' _ "$CLONE_CMD" || { echo "ERROR: clone command contains unsafe chars"; exit 3; }
```

```
mcp.type_text("rm -rf /tmp/macmini-drag; gh gist clone " + GIST_ID + " /tmp/macmini-drag; bash /tmp/macmini-drag/run.sh", "Enter")
```

## Step 13 — Verify clone + execute landed

```
mcp.take_screenshot()
```

Confirm `Cloning into '/tmp/macmini-drag/'`, `OK`, and a fresh shell prompt.
Shift-strip detection: continuation prompt → press Control+c twice, retry.

## Step 14 — Verify-after

```
mcp.take_screenshot()
```

Confirm the drag had its intended visual effect (file moved, text selected,
UI element repositioned, etc.).

## Step 15 — Cleanup

```bash
gh gist delete "$GIST_ID" --yes 2>/dev/null
```

## Step 16 — Final report

```
dragged screenshot ($SX1, $SY1)→($SX2, $SY2) — mini ($MINI_X1, $MINI_Y1)→($MINI_X2, $MINI_Y2) via gist $GIST_ID (deleted)
```
