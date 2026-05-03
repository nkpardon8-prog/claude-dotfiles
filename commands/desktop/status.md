---
description: Preflight check for /desktop — verifies cliclick is installed and Screen Recording / Accessibility TCC permissions are granted. Detects display scale.
---

# /desktop status

One-screen preflight. Detects: cliclick installed?, Screen Recording granted?, Accessibility granted?, display scale.

## Steps

1. **cliclick check** (cached 1h via `permissions.json` if `cliclick_installed_checked_at_ms` is fresh):
   ```bash
   command -v cliclick
   ```
   If missing → flag and recommend `/desktop setup`.

2. **Screen Recording probe** — exit-code based, with vision fallback:
   ```bash
   mkdir -p /tmp/desktop
   screencapture -x /tmp/desktop/probe.png 2>/tmp/desktop/probe.err
   SCAP_EXIT=$?
   if [ $SCAP_EXIT -ne 0 ]; then SR=denied; else SR=granted_or_unknown; fi
   ```
   On macOS 14/15, exit 0 doesn't guarantee SR is granted (denied state can return 0 with wallpaper-only frame). If exit is 0, use Read on `/tmp/desktop/probe.png` and check via vision: does it show the user's apps/dock, or just wallpaper? Wallpaper-only when the user has windows open → flag as "likely denied; verify in System Settings".

3. **Accessibility probe** — `cliclick m:1,1` requires Accessibility to execute (side effect: cursor jumps to top-left, expected and acceptable):
   ```bash
   cliclick m:1,1 2>/tmp/desktop/cc.err
   CC_EXIT=$?
   if [ $CC_EXIT -ne 0 ] || grep -qi 'tcc\|accessibility\|not allowed' /tmp/desktop/cc.err; then
     ACC=denied
   else
     ACC=granted
   fi
   ```

4. **Detect scale** (only if SR granted) by running the scale-derivation logic from `/desktop shot` against `/tmp/desktop/probe.png` (or just run `/desktop shot` and read the resulting `last.json`).

5. **Write `/tmp/desktop/permissions.json`** with `checked_at_ms` for TCC fields and `cliclick_installed_checked_at_ms` for the install check. Use Python for the timestamp (BSD `date` does not support `%3N`):
   ```bash
   now_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
   ```

6. **Print one-screen summary:**
   ```
   ✓/✗ cliclick installed (path: <path>)
   ✓/✗ Screen Recording granted
   ✓/✗ Accessibility granted
   Display scale: 2.0 (source: appkit)
   $TERM_PROGRAM: <e.g. iTerm.app>

   <For any ✗:>
   To fix: open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
   Or run: /desktop setup
   ```

## Gotchas

- TCC fields are NOT honored from cache — always re-probe. Probe is < 200ms total.
- cliclick probe moves the user's cursor to (1,1) — brief, harmless, but visible.
- macOS deep-link URL syntax can drift between versions; if `open` fails, AGENT-GUIDE has manual nav fallback.

## See also

- Setup walkthrough: `/desktop setup`
- AGENT-GUIDE: `~/.claude-dotfiles/skills/desktop/docs/AGENT-GUIDE.md`
