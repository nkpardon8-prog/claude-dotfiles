---
description: One-time calibration — captures screenshot-pixel → mini-physical-pixel scale and writes ~/.config/claude/macmini-calibration.json. Re-run when display config changes.
argument-hint: "(no arguments)"
---

# /macmini measure

One-time per mini. Measures the screenshot-pixel → mini-physical-pixel conversion
factors and writes `~/.config/claude/macmini-calibration.json` on the dev side.

The click sub-commands (/macmini click, rclick, dblclick, drag) read this file
on every invocation. If the file is missing, older than 30 days, or the stored
canvas dimensions no longer match the live CRD canvas, those sub-commands refuse
with an explicit "run /macmini measure" message.

## When to re-run

- Display resolution changed on the mini.
- CRD streaming resolution changed (user toggled "Match local" / "1080p" / "720p").
- More than 30 days have passed.
- `/macmini status` flags "calibration missing or stale."

## Pre-requisites

- CRD canvas live (run `/macmini connect` first).
- Mac mini Terminal focused with a shell prompt visible.
- `cliclick` installed on the mini (`brew install cliclick`).
- `gh` authenticated on both sides to the same account.

---

## Step 1 — Pre-flight: find and select the CRD page

```
mcp.list_pages()
```

Find the page whose URL starts with `https://remotedesktop.google.com/access/session/`.
If none: abort "CRD canvas not present — run /macmini connect first."

```
mcp.select_page({pageId: <crd_page_id>, bringToFront: true})
```

Take a screenshot. Confirm the Mac mini Terminal is focused with a shell prompt.
If not, abort: "Mac mini Terminal not focused — bring it forward first."

## Step 2 — Read mini physical resolution via system_profiler + screenshot OCR

Use /macmini paste to run the following one-liner on the mini:

```bash
system_profiler SPDisplaysDataType | grep -i "Resolution:"
```

This prints a short, OCR-friendly line such as:

```
Resolution: 2560 x 1440 (QHD/WQHD - Wide Quad High Definition)
```

Take a screenshot with `mcp.take_screenshot()` and read the two resolution
integers visually. The digits in `system_profiler` output are unambiguous at
typical Terminal font sizes (`2`, `5`, `6`, `0` etc. do not confuse with
`l`/`1`/`I` at normal font size). Screenshot-OCR is appropriate here — avoids
a second gist round-trip compared to the reverse-gist pattern, and the numbers
are the only data we need.

```bash
MINI_W=<width-from-screenshot>
MINI_H=<height-from-screenshot>
```

Sanity check: `MINI_W` and `MINI_H` must both be positive integers > 0.
Common valid values: 1920x1080, 2560x1440, 3840x2160, 1280x720.

## Step 3 — Fetch live canvas geometry on the CRD page

```javascript
mcp.evaluate_script({
  function: "() => { const cs=[...document.querySelectorAll('canvas')].sort((a,b)=>b.width*b.height-a.width*a.height); const c=cs[0]; if(!c) return {error:'no canvas'}; const r=c.getBoundingClientRect(); const zoom=(window.visualViewport&&window.visualViewport.scale)||(window.outerWidth/window.innerWidth)||1; return { dpr: window.devicePixelRatio, zoom, scrollX:window.scrollX, scrollY:window.scrollY, canvas:{x:r.x,y:r.y,width:r.width,height:r.height}}; }"
})
```

Returns: `{ dpr, zoom, scrollX, scrollY, canvas: {x, y, width, height} }`

- If `error === 'no canvas'`: abort "CRD canvas not found."
- If `scrollX !== 0 || scrollY !== 0`: abort "CRD page is scrolled — scroll to top-left first."

## Step 4 — Compute scale factors

```bash
scale_x = MINI_W / canvas.width
scale_y = MINI_H / canvas.height
```

Sanity checks:
- Both scale values must be > 0.5 and < 10. Values outside this range indicate
  a misread resolution or an unusual DPR configuration — abort and ask the user
  to verify the `system_profiler` output.
- Typical values: 2.0 for a 2560x1440 mini viewed on a 1280-CSS-px-wide canvas;
  1.0 for 1080p mini on a 1920-CSS-px-wide canvas.

## Step 5 — Verification: fire a test cursor move and check screenshot position

Build a one-shot gist that moves the cursor to mini-physical pixel (100, 100):

```bash
TMPDIR_V="$(mktemp -d -t macmini-measure.XXXXXX)"
trap 'rm -rf "$TMPDIR_V"' EXIT INT TERM
VFILE="$TMPDIR_V/run.sh"
{
  echo '#!/bin/bash'
  echo 'set -euo pipefail'
  echo 'if [ -x /opt/homebrew/bin/cliclick ]; then CB=/opt/homebrew/bin/cliclick; elif [ -x /usr/local/bin/cliclick ]; then CB=/usr/local/bin/cliclick; else echo "cliclick not installed — run: brew install cliclick"; exit 4; fi'
  echo '"$CB" m:100,100'
  echo 'echo OK'
} > "$VFILE"

GIST_OUT=$(gh gist create "$VFILE" 2>&1)
GIST_URL=$(printf '%s' "$GIST_OUT" | grep -oE 'https://gist\.github\.com/[^[:space:]]+' | head -n1)
GIST_ID=$(printf '%s' "$GIST_URL" | sed -E 's#.*/##' | sed 's/[?#].*//')
```

Type the clone command (unshifted-safe by construction — gist IDs are hex):

```
mcp.type_text("rm -rf /tmp/macmini-measure; gh gist clone " + GIST_ID + " /tmp/macmini-measure; bash /tmp/macmini-measure/run.sh", "Enter")
```

Wait for `OK` and a fresh prompt in the screenshot.

```bash
gh gist delete "$GIST_ID" --yes 2>/dev/null
```

Now take a screenshot and verify the cursor position:

```bash
# Expected cursor position in SCREENSHOT pixels (important on Retina dev machines):
total_scale = dpr * zoom
expected_canvas_local_x = 100 / scale_x      # CSS pixels within canvas
expected_canvas_local_y = 100 / scale_y
expected_sx = (canvas.x + expected_canvas_local_x) * total_scale
expected_sy = (canvas.y + expected_canvas_local_y) * total_scale
```

Look at the screenshot. The cursor (arrow pointer) should appear within ~30
screenshot pixels of `(expected_sx, expected_sy)`.

If off by more than ~30px:
- Abort and print: "Cursor verification failed — calibration values may be wrong.
  Verify: (1) cliclick has Accessibility TCC permission on the mini; (2) the mini
  display is not mirrored; (3) the system_profiler resolution matches the active
  display. Then retry /macmini measure."

## Step 6 — Write calibration file atomically

```python
python3 -c '
import json, datetime, sys

data = {
    "version": 1,
    "captured_at": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "mini_resolution": {"width": int(sys.argv[1]), "height": int(sys.argv[2])},
    "canvas_geometry_at_capture": {
        "dpr": float(sys.argv[3]),
        "zoom": float(sys.argv[4]),
        "canvas": {
            "x":      float(sys.argv[5]),
            "y":      float(sys.argv[6]),
            "width":  float(sys.argv[7]),
            "height": float(sys.argv[8]),
        }
    },
    "scale_x": float(sys.argv[9]),
    "scale_y": float(sys.argv[10]),
}

import os, tempfile, shutil
path = os.path.expanduser("~/.config/claude/macmini-calibration.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
shutil.move(tmp, path)
print("wrote", path)
' "$MINI_W" "$MINI_H" "$dpr" "$zoom" \
  "$canvas_x" "$canvas_y" "$canvas_width" "$canvas_height" \
  "$scale_x" "$scale_y"
```

Write atomically: write to `.tmp`, then `mv` into place. If the directory
`~/.config/claude/` does not exist, `os.makedirs` creates it.

**Calibration file schema:**

```json
{
  "version": 1,
  "captured_at": "2026-05-19T14:00:00Z",
  "mini_resolution": { "width": 2560, "height": 1440 },
  "canvas_geometry_at_capture": {
    "dpr": 2,
    "zoom": 1,
    "canvas": { "x": 0, "y": 0, "width": 1280, "height": 720 }
  },
  "scale_x": 2.0,
  "scale_y": 2.0
}
```

`canvas_geometry_at_capture` is used by the click sub-commands as a STALENESS
MARKER only — they compare its `canvas.{width,height}` against freshly-fetched
geometry on every click. If they differ by more than 5px, the click sub-command
refuses and asks the user to re-run `/macmini measure`.

## Step 7 — Final report

```
calibration written to ~/.config/claude/macmini-calibration.json
  mini: ${MINI_W}x${MINI_H}  canvas: ${canvas_width}x${canvas_height}  scale: ${scale_x}x${scale_y}
  verification: cursor at expected position — OK
```
