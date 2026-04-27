---
description: Pull text from Mac mini's clipboard to dev via CRD's clipboard sync.
argument-hint: "[driven]"
---

# /macmini grab

Pull whatever's on the Mac mini's clipboard back to the dev side via CRD's
built-in clipboard sync. Returns the synced text on stdout.

`MODE = $ARGUMENTS or "manual"` — `"manual"` (default) or `"driven"`.

## Pre-flight

1. Verify `chrome-devtools` MCP is reachable: `mcp.list_pages` returns a list.
   If not, abort with a hint to start the MCP (preferably with
   `--experimental-vision` for pixel clicks).
2. Find the CRD tab: first page with URL starting
   `https://remotedesktop.google.com/access/session/`.
   If none, abort with: `not connected to CRD — run /macmini connect first`.
3. `mcp.select_page(crd_page)`.

## Mode: manual (default)

Use this when a human (or Mac mini Claude) is doing the `Cmd+C` themselves on
the Mac mini side. This is the reliable path.

1. Print: `Waiting for you (or Mac mini Claude) to Cmd+C something on the Mac
   mini side. When done, the next /macmini grab call will return the synced
   content.`
2. (Caller invokes `/macmini grab` again, or this single invocation can also
   return immediately and let the operator decide.)

## Mode: driven (`$ARGUMENTS == "driven"`)

Auto-send Cmd+A then Cmd+C against whatever's currently focused on the Mac
mini canvas. **Caveat:** this is FRAGILE. It works for textfields where
Cmd+A selects all content. It does NOT work for:

- Terminal scrollback (Cmd+A selects visible region only or nothing).
- Web pages (Cmd+A selects entire page; Cmd+C may include CSS/markup).
- Apps in non-textfield focus state.

For Terminal output, ALWAYS use manual mode.

1. `mcp.click('canvas', 1, 1)`  — canvas focus via click (DOM `.focus()`
   doesn't work; canvas has no tabindex).
2. `mcp.press_key("Meta+a")`  — lowercase `a`.
3. Sleep ~100ms.
4. `mcp.press_key("Meta+c")`  — lowercase `c`.

## Sync trigger + read (both modes)

5. Activate Chrome on dev side so it receives the clipboard event:
   `osascript -e 'tell application "Google Chrome" to activate'`.
6. Force CRD's sync trigger via blur+focus:
   `mcp.evaluate_script("(() => { window.blur(); window.focus(); })()")`.
7. Sleep ~1500ms — mini→dev sync is historically slower than dev→mini; tune
   in Phase 6 testing.
8. `pbpaste` on dev → return result.
9. If result is empty or matches the previous grab content, warn:
   `Empty or stale clipboard — mini→dev sync may have failed.
   Recovery: in Mac mini, have Claude or human pbcopy explicitly, then retry.
   If repeated failure, reload the CRD tab and re-enable clipboard sync.`
10. Print result on stdout. Do not log or echo elsewhere (PII discipline).
