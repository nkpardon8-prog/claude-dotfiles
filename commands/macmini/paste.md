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

### 3. Verify clipboard-read permission (TWO-CALL workaround)

The async-IIFE single-call form is unreliable across MCP versions. Use two calls:

```
mcp.evaluate_script(
  "navigator.permissions.query({name:'clipboard-read'}).then(p => { window.__clipState = p.state; });"
)
sleep 100ms
state = mcp.evaluate_script("window.__clipState")
```

If `state != 'granted'`, abort with: `Chrome clipboard-read permission not granted on remotedesktop.google.com. Fix: in the CRD page, grant clipboard permission when Chrome prompts; OR visit chrome://settings/content/clipboard, find https://remotedesktop.google.com, set to Allow. Then re-run.`

### 4. Tempfile (NOT shell-expanded string)

`pbcopy "$VAR"` corrupts payloads with `$VAR`, backslashes, embedded quotes. Use a tempfile:

```bash
TEMPFILE="/tmp/macmini-paste.$$"
trap 'rm -f "$TEMPFILE"' EXIT INT TERM
```

### 5. Per-chunk loop

For each chunk:

```bash
# 5a. Write THIS chunk to tempfile (overwrite)
printf '%s' "<chunk>" > "$TEMPFILE" && chmod 600 "$TEMPFILE"
```

```
# 5b. Re-select CRD page
mcp.select_page(crd_page)

# 5c. Bring CRD tab to front. Try mcp.bring_to_front; on not-available,
#     fall back to AppleScript targeting the CRD window specifically.
try:
    mcp.bring_to_front()
except not_available:
    bash: osascript -e 'tell application "Google Chrome"
      set crdWin to first window whose URL of active tab starts with "https://remotedesktop.google.com"
      set index of crdWin to 1
      activate
    end tell'
```

```bash
# 5d. pbcopy from tempfile
pbcopy < "$TEMPFILE"
```

```
# 5e. Force CRD clipboard sync trigger via blur+focus
mcp.evaluate_script("(() => { window.blur(); window.focus(); return true; })()")

# 5f. Sync wait (tune in Phase 6)
sleep 800ms

# 5g. Focus canvas via mcp.click — DOM .focus() is a no-op on canvas
mcp.click('canvas', 1, 1)

# 5h. Cmd+V — LOWERCASE v (uppercase V = Cmd+Shift+V)
mcp.press_key("Meta+v")

# 5i. Wait for paste to land
sleep 200ms
```

### 6. Cleanup

`rm -f "$TEMPFILE"`

### 7. Final report

Print: `pasted <char_len> chars (<n> chunks)`. If `n > 1`, also print: `WARNING: chunked paste — verify integrity on Mac mini with shasum if payload matters.` Never log the payload itself.

## Errors

- **MCP unreachable** — chrome-devtools MCP not configured/running. Check MCP settings.
- **No CRD tab** — run `/macmini connect` first.
- **Clipboard permission not granted** — see step 3 fix message.
- **Paste empty/stale on Mac mini** — CRD clipboard sync may not be enabled. Open CRD side menu (right-edge arrow) → "Enable clipboard synchronization" → Begin.
