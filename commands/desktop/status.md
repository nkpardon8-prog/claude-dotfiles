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

## Smoke test (`--smoke-test` flag, or natural language "run a smoke test")

End-to-end validation of the full /desktop pipeline. **Always confirm with the user before running** — moves cursor, opens Calculator, types keys.

Procedure (keyboard-driven for input; vision only on result):

1. Confirm with user: "Run smoke test? Will open Calculator and type 1+1= via keyboard. (y/n)"
2. `open -a Calculator`
3. `sleep 1.0` (let Calculator gain focus)
4. `cliclick t:'1'` (keyboard, no vision)
5. `cliclick t:'+'` (cliclick handles shifted symbols natively)
6. `cliclick t:'1'`
7. `cliclick kp:return` (`=` on Mac Calculator triggers via Return)
8. `sleep 0.4`
9. Run `/desktop window Calculator` for a focused snapshot. If Quartz is unavailable, fall back to `/desktop shot` and crop to Calculator.
10. Use Read on `/tmp/desktop/last.png`. **Read the DISPLAY REGISTER** (the large numeric area at top of the Calculator window) — NOT a keypad button.
11. Report PASS if the register reads `2`. FAIL with the actual value otherwise.
12. Close Calculator: `cliclick kd:cmd t:'w' ku:cmd` (auto-fire — user opted in).

The smoke test validates: TCC, scale detection, cliclick keyboard input, screencapture, vision read. ~5 seconds end-to-end. Failure modes typically point to the broken link in the chain (e.g., wallpaper-only screenshot → Screen Recording denied; cliclick exits non-zero → Accessibility denied; register reads `0` → focus didn't reach Calculator).

## Quartz availability check

Add to the preflight summary so `/desktop window` failures are diagnosable:

```bash
python3 -c 'from Quartz import CGWindowListCopyWindowInfo' 2>/dev/null && QUARTZ=ok || QUARTZ=missing
```

If missing: `/desktop window` will fall back to `/desktop shot`. pyobjc-framework-Quartz ships with system Python 3 on macOS 11+; if the user has shimmed `python3` to a venv, it may be missing.

## Gotchas

- TCC fields are NOT honored from cache — always re-probe. Probe is < 200ms total.
- cliclick probe moves the user's cursor to (1,1) — brief, harmless, but visible.
- macOS deep-link URL syntax can drift between versions; if `open` fails, AGENT-GUIDE has manual nav fallback.
- Smoke test side-effects: opens Calculator, moves cursor, types keys. Always opt-in.

## See also

- Setup walkthrough: `/desktop setup`
- AGENT-GUIDE: `~/.claude-dotfiles/skills/desktop/docs/AGENT-GUIDE.md`
- Window capture (used by smoke test): `/desktop window`
