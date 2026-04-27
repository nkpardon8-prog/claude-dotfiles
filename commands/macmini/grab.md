---
description: Pull text from Mac mini's clipboard back to dev. Manual mode only — driven mode was deleted (synthetic clicks fail CRD's isTrusted check).
argument-hint: ""
---

# /macmini grab

Pull whatever's on the Mac mini's clipboard back to the dev side. Returns the synced text on stdout.

**Note on reliability:** mini→dev clipboard sync is brittle (per HARDWARE-FINDINGS-2026-04-27.md — the dev→mini direction is broken; mini→dev sometimes works depending on focus and recent paste activity). For verbatim multi-line output, prefer the **reverse-gist pattern**: on the Mac mini, run `<command> > /tmp/o.log; gh gist create -f o.log /tmp/o.log`, then on dev run `gh gist clone <id> /tmp/back; cat /tmp/back/o.log`. That's lossless. `/macmini grab` is for short, opportunistic single-line buffers.

## Pre-flight

1. `mcp.list_pages()` returns a list. If not, abort with `chrome-devtools MCP not reachable`.
2. Find the CRD page: URL starts `https://remotedesktop.google.com/access/session/`. If none, abort: `not connected — run /macmini connect first`.
3. `mcp.select_page({pageId, bringToFront: true})`.

## Sequence

The user (or a Mac mini Claude session) runs `pbcopy` on the Mac mini side to put text on mini's clipboard. The agent reads from dev-side `navigator.clipboard.readText()` on the CRD page.

1. Print: `Run pbcopy on the Mac mini for whatever you want to grab. Then call /macmini grab again — this call returns the synced content.` (Or: this single invocation can also return immediately and let the operator decide.)

2. Activate Chrome on dev so it receives the clipboard event:

   ```bash
   osascript -e 'tell application "Google Chrome" to activate'
   ```

3. Force CRD's sync trigger (best-effort) via blur+focus on the page:

   ```
   mcp.evaluate_script({function: "() => { window.blur(); window.focus(); return true; }"})
   ```

4. Wait for sync. Use `mcp.wait_for({text: ["any sentinel"], timeout: 1500})` as a delay (or just sleep on the dev shell side).

5. Read the dev page's clipboard:

   ```
   mcp.evaluate_script({function: "(async () => { try { return await navigator.clipboard.readText(); } catch (e) { return ''; } })()"})
   ```

6. If result is empty or matches the previously-grabbed content, warn:

   ```
   Empty or stale clipboard — mini→dev sync may have failed.
   Recovery: have Mac mini Claude (or the user) run `pbcopy < /path/to/output` explicitly,
   then retry. For long verbatim text, use the reverse-gist pattern instead.
   ```

7. Print result on stdout. Do NOT log or echo elsewhere (PII discipline — clipboard may contain anything).

## Why no driven mode?

A previous version had `/macmini grab driven` that synthesized `Cmd+A` then `Cmd+C` against the canvas. Removed because CRD requires real user-gesture events for clipboard ops; CDP-injected key events are synthetic (`isTrusted=false`), so `Cmd+C` doesn't trigger CRD's onCopy handler. The reverse-gist pattern is the reliable replacement.
