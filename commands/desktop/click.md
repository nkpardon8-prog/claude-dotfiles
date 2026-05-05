---
description: Vision-guided click on the local macOS screen. Identifies the target via vision, applies the safety classifier, converts pixel→logical coords, executes via cliclick, then verifies with a re-snap.
argument-hint: "[target description, e.g. \"the Allow button\" or \"the X to close this dialog\"]"
---

# /desktop click

Click a vision-identified target. Retina-aware. Safety-classified. Verified.

## Steps

1. **Freshness check.** Read `/tmp/desktop/last.json` if present. Compute age:
   ```bash
   now_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
   ts=$(jq -r .timestamp_ms /tmp/desktop/last.json 2>/dev/null)
   ```
   **Validate `ts` is an integer** before comparing. If `ts` is missing, the literal `null`, or a non-integer string (e.g. `%3N` from a stale-bug regression), treat as stale and re-snap:
   ```bash
   if ! [[ "$ts" =~ ^[0-9]+$ ]]; then ts=0; fi
   ```
   If `last.json` is missing or `(now_ms - ts) > 2000` → run `/desktop shot` first (or `/desktop window <app>` if a focused capture is appropriate).

2. **Vision identifies target.** Use the Read tool to view `/tmp/desktop/last.png`. Find the target described in args. Return `{x_pixel, y_pixel, label}`. If not found → abort, ask user to clarify or move the target into view.

3. **Read scale from sidecar:**
   ```bash
   scale=$(jq -r .scale /tmp/desktop/last.json)
   ```

4. **Convert pixel → logical:**
   ```
   x_logical = round(x_pixel / scale)
   y_logical = round(y_pixel / scale)
   ```
   **This step is mandatory on Retina (scale 2.0). Forgetting it misses by half.**

5. **Apply safety classifier.** Canonical rules: `~/.claude-dotfiles/skills/desktop/docs/AGENT-GUIDE.md` → "Hybrid safety classifier". Summary:
   - **AUTO_FIRE** = OK / Allow / Accept / Continue / Got it / Close / Dismiss / Not Now / Later / Skip / Maybe Later → fire immediately.
   - **DESTRUCTIVE** = Delete / Remove / Discard / Erase / Quit Without Saving / Don't Save / Move to Trash / Empty / Reset / Forget / Uninstall → confirm with EXPLICIT warning.
   - **Everything else** (including Cancel / Don't Allow / Sign Out / Quit / unknown labels) → confirm with summary "click `<label>` at (x,y)?".

6. **Execute via cliclick:**
   - Single click: `cliclick c:<x_logical>,<y_logical>`
   - Double click: `cliclick dc:<x_logical>,<y_logical>`
   - Right click: `cliclick rc:<x_logical>,<y_logical>`
   - Modifier combos: `cliclick kd:cmd c:<x>,<y> ku:cmd` (single mod) or `cliclick kd:cmd kd:shift c:<x>,<y> ku:shift ku:cmd` (multi mod, release in reverse order).

7. **Sleep 0.4s** to let the UI settle.

8. **Verify.** Run `/desktop shot` again. Vision-compare to expectation:
   - Clicked a dialog button → expect dialog gone.
   - Clicked an app button → expect some visible state change.
   - If no observable change after 0.4s, sleep another 0.6s and re-snap once more.
   - If still no change → abort, report: "Click landed at (x,y) but no visible effect. Target may have moved or been wrong."

## Gotchas

- `cliclick` exits 0 even when the click lands in dead space — never trust exit code as proof; trust the verify snapshot.
- Vision can misidentify the target. The verify-after step is the safety net.
- If vision sees an unexpected dialog in the verify snapshot (e.g., macOS "want to control your computer" TCC prompt popped up over the target) → STOP, do not click through it; report to user.
- Forgetting Retina division is the #1 failure mode. Inline reminder: divide by `scale` from `last.json`.

## See also

- Hybrid safety classifier: `~/.claude-dotfiles/skills/desktop/docs/AGENT-GUIDE.md`
- Screenshot primitive: `/desktop shot`
