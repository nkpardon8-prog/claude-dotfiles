---
description: Send text to the Mac mini's clipboard via CRD's built-in bidirectional clipboard sync, then Cmd+V via DevTools MCP.
argument-hint: "<text — multi-line OK, up to ~50KB safe>"
---

# /macmini paste

Pushes a string into the Mac mini's clipboard via CRD's clipboard sync, then issues `Cmd+V` on the canvas. Bypasses CRD's broken keystroke forwarding (Shift mangling: `HELLO_WORLD` typed via `press_key` arrives as `hello-world`). Paste is a bytes-blob event, so it survives intact.

## Sequence

### 0. Pre-flight — chrome-devtools MCP must be reachable

Try `mcp.list_pages()`. If it raises, abort with: `chrome-devtools MCP not reachable — verify it's configured in your MCP settings. Recommended: start with --experimental-vision flag for canvas pixel clicks.`

### 1. Size check + character-aware chunking (>50KB)

Compute char length in JS (spread-iterator is UTF-8 safe): `[...str].length`. If `> 50000`, print a warning and chunk via `evaluate_script` (NOT shell byte-slicing — multi-byte glyphs corrupt at byte boundaries):

```js
const arr = [...str];
const chunks = [];
for (let i = 0; i < arr.length; i += 50000) {
  chunks.push(arr.slice(i, i + 50000).join(''));
}
return chunks;
```

Otherwise `chunks = [ARGUMENTS]`.

### 2. Find the CRD tab

`pages = mcp.list_pages()`; pick the first page whose URL starts with `https://remotedesktop.google.com/access/session/`. If none, abort: `not connected to CRD — run /macmini connect first`. Then `mcp.select_page(crd_page)`.

### 3. Verify clipboard-read works (single-call try/catch)

Don't trust `permissions.query` — it can return `'prompt'` even after policy is set. Source of truth is whether `readText()` actually works; treat `permissions.query` as advisory only.

```js
let clipboardOk;
try { await navigator.clipboard.readText(); clipboardOk = true; }
catch (err) { clipboardOk = false; console.warn("Clipboard access failed:", err.message); }
if (!clipboardOk) {
  const advisory = (await navigator.permissions.query({name:'clipboard-read'})).state;
  return { ok: false, reason: "clipboard-blocked", permissionAdvisory: advisory,
    fix: "Run /macmini auto-grant install (then restart Chrome) and /macmini auto-grant cdp" };
}
```

If the call returns `ok: false`, abort with the `fix` message above.

### 4. Tempfile (NOT shell-expanded string)

`pbcopy "$VAR"` corrupts payloads with `$VAR`, backslashes, embedded quotes. Use a tempfile:

```bash
TEMPFILE="/tmp/macmini-paste.$$"
trap 'rm -f "$TEMPFILE"' EXIT INT TERM
```

### 5. Per-chunk loop

For each chunk:

- 5a. `printf '%s' "<chunk>" > "$TEMPFILE" && chmod 600 "$TEMPFILE"` — overwrite tempfile.
- 5b. `mcp.select_page(crd_page)`.
- 5c. Bring CRD tab to foreground: call `mcp.select_page({pageIdx: <crd_page.idx>, bringToFront: true})`. For OS-level Chrome window activation, fall back to AppleScript targeting the CRD window specifically (`osascript -e 'tell application "Google Chrome" to activate'`, or for more precision: `tell application "Google Chrome" ... set crdWin to first window whose URL of active tab starts with "https://remotedesktop.google.com" ... set index of crdWin to 1 ... activate`).
- 5d. `pbcopy < "$TEMPFILE"`.
- 5e. Force CRD clipboard sync trigger via blur+focus: `mcp.evaluate_script("(() => { window.blur(); window.focus(); return true; })()")`.
- 5f. `sleep 800ms` (sync wait — tune in Phase 6).
- 5g. `mcp.click('canvas', 1, 1)` — focus canvas (DOM `.focus()` is a no-op on canvas).
- 5h. `mcp.press_key("Meta+v")` — Cmd+V, **LOWERCASE v** (uppercase V = Cmd+Shift+V).
- 5i. `sleep 200ms` — wait for paste to land.

### 6. Cleanup

`rm -f "$TEMPFILE"`

### 7. Final report

Print: `pasted <char_len> chars (<n> chunks)`. If `n > 1`, also print: `WARNING: chunked paste — verify integrity on Mac mini with shasum if payload matters.` Never log the payload itself.

## Errors

- **MCP unreachable** — chrome-devtools MCP not configured/running. Check MCP settings.
- **No CRD tab** — run `/macmini connect` first.
- **Clipboard blocked** — see step 3 fix message; run `/macmini auto-grant install` then restart Chrome, and `/macmini auto-grant cdp`.
- **Paste empty/stale on Mac mini** — CRD clipboard sync not enabled in this canvas. Run `/macmini auto-grant ui`.
