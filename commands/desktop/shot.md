---
description: Capture a screenshot of the local macOS main display, write the image and a sidecar JSON with display scale and dimensions. Foundation primitive — every other /desktop sub-command depends on a fresh shot.
argument-hint: "[optional region as \"X,Y,W,H\" in PHYSICAL pixels]"
---

# /desktop shot

Take a screenshot of the main display. Write `/tmp/desktop/last.png` + `/tmp/desktop/last.json` sidecar with display scale and dimensions. The sidecar is what every click/type/key operation reads to do Retina coord conversion.

## Steps

1. Ensure target dir:
   ```bash
   mkdir -p /tmp/desktop
   ```

2. Capture:
   ```bash
   screencapture -x /tmp/desktop/last.png
   ```
   - `-x` suppresses the camera-shutter sound (mandatory).
   - For partial capture: `screencapture -x -R "X,Y,W,H" /tmp/desktop/last.png` — quote the `-R` arg, coords are PHYSICAL pixels.

3. Check exit code. Non-zero → abort with: "Screen Recording denied. Run `/desktop setup` to fix."

4. **Vision sanity-check** (necessary because macOS 14/15 often returns exit 0 even when SR is denied — wallpaper-only frame). Use the Read tool to view `/tmp/desktop/last.png`. If you expected app windows visible and see only wallpaper → warn the user: "Screenshot may indicate Screen Recording denial; run `/desktop status` to verify."

5. Read pixel dimensions:
   ```bash
   pixel_w=$(sips -g pixelWidth  /tmp/desktop/last.png | tail -1 | awk '{print $2}')
   pixel_h=$(sips -g pixelHeight /tmp/desktop/last.png | tail -1 | awk '{print $2}')
   ```

6. Derive logical dimensions per the priority chain:

   **Primary — pyobjc / AppKit (ships with system Python 3 on macOS 11+):**
   ```bash
   appkit_out=$(python3 -c 'from AppKit import NSScreen
   s = NSScreen.mainScreen()
   if s is not None:
       f = s.frame()
       print(int(f.size.width), int(f.size.height))' 2>/dev/null)
   if [ -n "$appkit_out" ]; then
     logical_w=$(echo "$appkit_out" | awk '{print $1}')
     logical_h=$(echo "$appkit_out" | awk '{print $2}')
     scale_source="appkit"
   fi
   ```

   **Fallback — `system_profiler` "UI Looks like:" line.** Extract numbers via grep, NOT positional awk on a regex separator (label "UI Looks like" contains spaces that consume fields):
   ```bash
   if [ -z "$logical_w" ]; then
     dims=$(system_profiler SPDisplaysDataType 2>/dev/null \
            | grep -m1 "UI Looks like:" \
            | grep -oE '[0-9]+ x [0-9]+' | head -1)
     if [ -n "$dims" ]; then
       logical_w=$(echo "$dims" | awk '{print $1}')
       logical_h=$(echo "$dims" | awk '{print $3}')
       scale_source="system_profiler"
     fi
   fi
   ```

   **Last-resort — assume Retina 2x:**
   ```bash
   if [ -z "$logical_w" ]; then
     logical_w=$((pixel_w / 2))
     logical_h=$((pixel_h / 2))
     scale_source="assumed_retina"
   fi
   ```

7. Compute scale:
   ```bash
   scale=$(awk -v p=$pixel_w -v l=$logical_w 'BEGIN { printf "%.1f", p/l }')
   ```

8. Get millisecond epoch — **use Python, NOT `date +%s%3N` (BSD `date` on macOS does not support `%3N` and would silently write the literal string into JSON, breaking the freshness check):**
   ```bash
   now_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
   ```

9. Write the sidecar:
   ```bash
   cat > /tmp/desktop/last.json <<EOF
   {"path":"/tmp/desktop/last.png","timestamp_ms":$now_ms,"pixel_w":$pixel_w,"pixel_h":$pixel_h,"logical_w":$logical_w,"logical_h":$logical_h,"scale":$scale,"scale_source":"$scale_source","display":"main"}
   EOF
   ```

10. Use the Read tool to view `/tmp/desktop/last.png` so vision can see it.

11. Return: path, scale, dimensions, scale_source.

## Gotchas

- Always `-x` or every screenshot beeps.
- Always `mkdir -p` — first run on a fresh machine fails otherwise.
- Always quote `-R` arg.
- Sidecar written *after* PNG, never assume cached values.
- `scale_source: assumed_retina` in the sidecar means scale is a guess — surface this so the user knows.
- `scale_source: appkit` is the most reliable source.
- Never `date +%s%3N` — BSD date silently writes literal `%3N` into the JSON, breaking the 2s freshness check downstream.

## See also

- Retina coordinate handling: `~/.claude-dotfiles/skills/desktop/docs/AGENT-GUIDE.md` → "Coordinate handling"
