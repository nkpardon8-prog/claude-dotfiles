---
description: Left-click at screenshot pixel (sx, sy) on the mini's screen. Optional --mod cmd|shift|opt|ctrl for modifier-click. Uses cliclick via gist transport.
argument-hint: "<sx> <sy> [--mod cmd|shift|opt|ctrl]"
---

# /macmini click

Left-click at SCREENSHOT pixel (sx, sy) on the Mac mini's screen.
Optionally hold a modifier key (Cmd/Shift/Option/Control) during the click.

This sub-command is SELF-CONTAINED. The agent does not need to read paste.md
to execute it. paste.md is referenced ONLY for the Step 0 credential pre-scan
(trivially safe here — payload is two integers) and the Step 9 unshifted-safety
validation (shared invariant).

See also: /macmini rclick, /macmini dblclick, /macmini drag, /macmini script
(same gist transport, different run.sh body). For text delivery, see /macmini paste.

## Step 1 — Parse args

```bash
set -- $ARGUMENTS
SX="$1"; SY="$2"
MOD=""
shift 2 2>/dev/null
while [ $# -gt 0 ]; do
  case "$1" in
    --mod) MOD="$2"; shift 2 ;;
    *) echo "ERROR: unknown arg '$1'"; exit 1 ;;
  esac
done
case "$SX$SY" in
  (*[!0-9-]*|"") echo "ERROR: sx/sy must be integers"; exit 1 ;;
esac
case "$MOD" in
  (""|cmd|shift|opt|ctrl) ;;
  (*) echo "ERROR: --mod must be one of cmd|shift|opt|ctrl"; exit 1 ;;
esac
```

## Step 2 — Load calibration

```bash
CALIB="$HOME/.config/claude/macmini-calibration.json"
[ -f "$CALIB" ] || { echo "Calibration missing — run /macmini measure first."; exit 2; }

# Age check (30 days = 2592000 seconds).
NOW=$(date +%s)
MTIME=$(stat -f %m "$CALIB" 2>/dev/null || stat -c %Y "$CALIB")
if [ $((NOW - MTIME)) -gt 2592000 ]; then
  echo "Calibration >30 days old — run /macmini measure to refresh."; exit 2
fi

# Pull values with python3 (jq may not be present on dev).
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

Returns: `{ dpr, zoom, scrollX, scrollY, canvas: {x, y, width, height} }`

- If `error === 'no canvas'`: abort "CRD canvas not present — /macmini connect".
- If `scrollX !== 0 || scrollY !== 0`: abort "CRD page is scrolled — scroll to top-left first."

## Step 5 — Staleness check: cached canvas vs fresh canvas

```bash
# Abort if the canvas dimensions diverged from what was measured at calibration time.
if abs(canvas.width - STORED_W) > 5 OR abs(canvas.height - STORED_H) > 5:
  abort "Canvas size changed since calibration (CRD streaming resolution toggled?) — run /macmini measure to refresh."
```

## Step 6 — Convert screenshot pixels → mini-physical pixels

```bash
total_scale = dpr * zoom
vx = SX / total_scale          # viewport CSS pixels
vy = SY / total_scale
cx = vx - canvas.x             # canvas-local CSS pixels
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
- If click target is in the top 60px or bottom 30px of canvas (CRD UI overlay zone): wait 3s and retry the occlusion check once.
- If still occluded, abort: "Click target occluded by CRD toolbar — wait for it to auto-hide, then retry."

## Step 8 — Build run.sh

The run.sh template below encodes four real-world fixes. The numbered comments
are load-bearing — do NOT drop them in a future "simplification."

Determine the target app (the app that should be foreground when the click
fires). For an explicit `--target <app>` arg, honor it. Otherwise, take a
screenshot and visually infer the foreground app the user wants clicked
(usually obvious — the user said "click the button on eBay" → target is
Chrome). If the agent cannot identify a target, default to **not activating
anything** and let cliclick fire against whatever is currently foreground —
but warn the user this is risky.

```bash
TARGET_APP="${TARGET_APP:-Google Chrome}"   # default; override per-call as needed

CLICKBIN_PROBE='if [ -x /opt/homebrew/bin/cliclick ]; then CB=/opt/homebrew/bin/cliclick; elif [ -x /usr/local/bin/cliclick ]; then CB=/usr/local/bin/cliclick; else echo "cliclick not installed — run: brew install cliclick"; exit 4; fi'

# Modifier-click uses atomic kd:MOD c:X,Y ku:MOD in a single shell invocation.
if [ -z "$MOD" ]; then
  CLICK_BODY='"$CB" c:'"$MINI_X"','"$MINI_Y"
else
  CLICK_BODY='"$CB" kd:'"$MOD"' c:'"$MINI_X"','"$MINI_Y"' ku:'"$MOD"
fi

TMPDIR_LOCAL="$(mktemp -d -t macmini-click.XXXXXX)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT INT TERM
RUN_FILE="$TMPDIR_LOCAL/run.sh"

cat > "$RUN_FILE" <<RUNSH
#!/bin/bash
set -uo pipefail
${CLICKBIN_PROBE}

# (1) Activate the TARGET app FIRST so the click lands on its window content.
# Without this, the cursor might be over the right pixel but the click goes
# to whichever app is currently foreground (often Terminal, behind everything).
osascript -e 'tell application "${TARGET_APP}" to activate' >/dev/null 2>&1

# (2) Sleep 0.6s — NOT 0.4s. macOS WindowServer may eat the first click after
# app activation as a "focus this window" event. 0.6s is the empirically-stable
# wait (observed 2026-05-19 during /macmini click bring-up on eBay).
sleep 0.6

# (3) Diagnostic: pre-click cursor position (so the agent can confirm cliclick
# is responding even if the click itself has no visible effect).
PRE=\$("\$CB" p: 2>&1)
echo "Pre: \$PRE"

# (4) Fire the click action.
${CLICK_BODY}
RC=\$?
echo "Exit: \$RC"

# (5) Diagnostic: post-click cursor position.
sleep 0.2
POST=\$("\$CB" p: 2>&1)
echo "Post: \$POST"

# (6) Bring Terminal back to the front so the NEXT gist clone command can be
# typed without a manual Cmd+Tab. If you don't want this (e.g. you're doing a
# single click and then leaving Chrome in focus), drop this line.
osascript -e 'tell application "Terminal" to activate' >/dev/null 2>&1

echo OK
RUNSH
```

No heredoc / randomized terminator needed for the cliclick coords — cliclick
payloads are integers and literal tokens (`cliclick`, `c:`, `,`, `kd:`, `ku:`).
No payload-collision risk. The heredoc above wraps the entire run.sh body for
clean variable substitution of `TARGET_APP`, `MINI_X`, `MINI_Y`, `MOD`.

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

## Step 10 — Make sure mini Terminal is foreground, validate clone command, then type it

**Critical:** the typed clone command goes to whichever app is foreground on
the mini. If Terminal is hidden behind Chrome (the usual state after a prior
click), the keystrokes will land in Chrome's URL bar / search box / random
input — silently. ALWAYS screenshot first to confirm Terminal is foreground.

```
mcp.take_screenshot()
```

If Terminal is NOT foreground, surface it via one of these (in order of
reliability):

1. `mcp.press_key("Meta+Tab")` — cycles to the most-recently-used other app.
   Works when Terminal was the MRU app (the previous run.sh activated
   Terminal at the end via the Step 8 (6) line, so this is the common case).
2. `mcp.press_key("Meta+h")` — hides the foreground app, revealing what's
   behind. Useful when Cmd+Tab cycled to the wrong app.
3. Manual: ask the user to click Terminal in the Dock.

Re-screenshot after each attempt; do not proceed until Terminal is clearly
foreground (cursor blinking in a shell prompt).

```bash
CLONE_CMD="rm -rf /tmp/macmini-click; gh gist clone $GIST_ID /tmp/macmini-click; bash /tmp/macmini-click/run.sh"

LC_ALL=C bash -c '
  case "$1" in
    (*[^a-z0-9\ /.\;:_-]*) exit 3 ;;
  esac
' _ "$CLONE_CMD" || { echo "ERROR: clone command contains unsafe chars"; exit 3; }
```

```
mcp.type_text("rm -rf /tmp/macmini-click; gh gist clone " + GIST_ID + " /tmp/macmini-click; bash /tmp/macmini-click/run.sh", "Enter")
```

## Step 11 — Verify clone + execute landed

```
mcp.take_screenshot()
```

Confirm:
- `Cloning into '/tmp/macmini-click/'` line present, AND
- `Pre: <x>,<y>`, `Exit: 0`, `Post: <x>,<y>` lines from run.sh, AND
- `OK` line at the end, AND
- A fresh shell prompt at the bottom.

If the Terminal output scrolled off-viewport during `gh gist clone` (verbose
output), press `Meta+H` to hide whatever's currently on top — Terminal's full
output usually becomes visible behind it. The Pre/Post cursor positions are
the diagnostic: if `Post == (MINI_X, MINI_Y)`, the cursor moved correctly
even if the click had no visible effect (in which case the click coords were
wrong, or the WindowServer ate the click — see "Verify-after" Step 12).

Shift-strip detection (same as paste.md Step 6): if a continuation prompt
(`> `, `bquote>`, `quote>`, etc.) appears instead of a normal `$`/`%` prompt,
press Control+c twice to recover, then retry. `gh: command not found` means
mini is missing gh. 404 means mini gh authed to the wrong account.

`mcp.wait_for(["OK", "ERR", "Exit:"])` is unreliable for run.sh output —
verbose clone output scrolls past the viewport before `wait_for` polls.
Prefer a fixed sleep (`sleep 4` for fast clicks, `sleep 8` for slow networks)
then screenshot.

## Step 12 — Verify-after click

```
mcp.take_screenshot()
```

Confirm the click had its intended visual effect on the mini's screen.

Mandatory verify-after contexts (per AGENT-GUIDE.md): OAuth approve, payment
confirm, destructive actions (delete/discard), send/post/publish, file-overwrite,
2FA dialogs, any "are you sure?" confirmation.

## Step 13 — Cleanup

```bash
gh gist delete "$GIST_ID" --yes 2>/dev/null
```

## Step 14 — Final report

```
clicked screenshot ($SX, $SY) → mini ($MINI_X, $MINI_Y) [mod: ${MOD:-none}] via gist $GIST_ID (deleted)
```
