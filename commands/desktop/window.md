---
description: Capture a screenshot of just one app's frontmost window for higher-accuracy vision targeting. Same sidecar shape as /desktop shot, plus window metadata.
argument-hint: "[app name as it appears to System Events, e.g. \"Calculator\", \"Google Chrome\", \"Messages\"]"
---

# /desktop window

Capture only the frontmost window of a specific app. Use when full-screen vision-targeting is imprecise (small UI elements, multi-window clutter, dock/menu-bar distractions).

## Steps

1. Ensure target dir: `mkdir -p /tmp/desktop`.

2. **Pre-check Quartz availability** (pyobjc-framework-Quartz):
   ```bash
   python3 -c 'from Quartz import CGWindowListCopyWindowInfo' 2>/dev/null || {
     echo "pyobjc-framework-Quartz not available. Falling back: use /desktop shot for full-screen capture."
     exit 2
   }
   ```

3. **Get frontmost-process PID** to disambiguate when an app has multiple on-screen windows:
   ```bash
   front_pid=$(osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null)
   ```

4. **Look up window ID for `<app>` via Quartz**, preferring the frontmost-process match. Pass app name as `sys.argv[1]` to avoid shell-quoting bugs (apostrophes in app names break interpolation):
   ```bash
   APP_NAME="$1"
   window_id=$(python3 - "$APP_NAME" "${front_pid:-0}" <<'PYEOF'
   from Quartz import (CGWindowListCopyWindowInfo,
                        kCGWindowListOptionOnScreenOnly,
                        kCGNullWindowID)
   import sys
   target = sys.argv[1]
   front_pid = int(sys.argv[2]) if sys.argv[2].isdigit() else None

   infos = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID) or []
   candidates = [w for w in infos
                 if w.get('kCGWindowOwnerName') == target
                 and w.get('kCGWindowLayer') == 0
                 and w.get('kCGWindowIsOnscreen', True)]
   chosen = None
   if front_pid is not None:
       for w in candidates:
           if w.get('kCGWindowOwnerPID') == front_pid:
               chosen = w
               break
   if chosen is None and candidates:
       chosen = candidates[0]
   if chosen:
       print(chosen['kCGWindowNumber'])
   PYEOF
   )

   if [ -z "$window_id" ]; then
     echo "No on-screen window found for '$APP_NAME'. Try /desktop shot for full-screen, or open the app first."
     exit 1
   fi
   ```

5. **Capture the window:**
   ```bash
   screencapture -x -l "$window_id" /tmp/desktop/last.png
   ```

6. **Read pixel dims, derive logical scale** — same procedure as `/desktop shot` (sips → AppKit → system_profiler → assumed_retina last-resort).

7. **Write sidecar** with window metadata:
   ```bash
   now_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
   cat > /tmp/desktop/last.json <<EOF
   {"path":"/tmp/desktop/last.png","timestamp_ms":$now_ms,"pixel_w":$pixel_w,"pixel_h":$pixel_h,"logical_w":$logical_w,"logical_h":$logical_h,"scale":$scale,"scale_source":"$scale_source","display":"main","window":{"app":"$APP_NAME","window_id":$window_id}}
   EOF
   ```

8. Use the Read tool to view `/tmp/desktop/last.png`.

9. Return: path + scale + dimensions + scale_source + window metadata.

## Gotchas

- **Window ID disambiguation:** Apps with multiple on-screen windows (Chrome, multi-document apps) need the frontmost-PID anchor. Without it, you'd get an arbitrary window from Quartz enumeration order.
- **Layer 0 only:** `kCGWindowLayer == 0` filters out menus, tooltips, dock items. If an app's main window is non-zero (rare), this lookup misses it.
- **App name must match `kCGWindowOwnerName` exactly:** "Google Chrome" not "Chrome", and "Google Chrome Helper" might have its own window. To list current windows:
  ```bash
  python3 -c 'from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID; [print(w.get("kCGWindowOwnerName"), "|", w.get("kCGWindowName")) for w in CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID) or []]'
  ```
- **Lost cross-window context:** window-only screenshots don't show the dock, menu bar, or system dialogs that may have popped over the app. If suspicious of state, use `/desktop shot` (full-screen) instead.
- **No region cropping in v1:** for sub-window targeting (e.g. just a toolbar), use `screencapture -x -R "X,Y,W,H"` directly. See AGENT-GUIDE → "Region & window capture".

## See also

- Full-screen alternative: `/desktop shot`
- Region & window capture rules: `~/.claude-dotfiles/skills/desktop/docs/AGENT-GUIDE.md` → "Region & window capture"
