---
description: Send text to the Mac mini's clipboard via CRD's built-in bidirectional clipboard sync, then Cmd+V via DevTools MCP.
argument-hint: "<text — multi-line OK, up to ~50KB safe>"
---

# /macmini paste

## What this does

Pushes a string into the Mac mini's clipboard via CRD's built-in clipboard sync, then issues `Cmd+V` on the canvas. Bypasses CRD's broken keystroke forwarding (the Shift modifier is dropped, so `HELLO_WORLD` typed via `press_key` arrives as `hello-world`). Paste is a bytes-blob event, not character-by-character, so it survives intact.

---

## Sequence

### 0. Pre-flight — chrome-devtools MCP must be reachable

Try `mcp.list_pages()`. If it raises (MCP not configured / not running), abort with:

```
chrome-devtools MCP not reachable — verify it's configured in your MCP settings.
Recommended: start with --experimental-vision flag for canvas pixel clicks.
```

### 1. Size check + character-aware chunking (>50KB)

Compute character length in JS (the spread-iterator handles UTF-8 correctly):

```js
[...str].length
```

If `char_len > 50000`:

- Print a warning that the payload exceeds CRD's clipboard sync ceiling (~64KB safe).
- Chunk in JS via `evaluate_script`, NOT via shell byte-slicing (multi-byte glyphs get corrupted at byte boundaries):

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

```
pages = mcp.list_pages()
crd_page = first page where url startsWith "https://remotedesktop.google.com/access/session/"
if not crd_page: abort("not connected to CRD — run /macmini connect first")
mcp.select_page(crd_page)
```

### 3. Verify clipboard-read permission (two-call workaround)

The async-IIFE single-call pattern is unreliable across MCP versions. Use two calls:

```
mcp.evaluate_script(
  "navigator.permissions.query({name:'clipboard-read'}).then(p => { window.__clipState = p.state; });"
)
sleep 100ms
state = mcp.evaluate_script("window.__clipState")
```

If `state != 'granted'`, abort with:

```
Chrome clipboard-read permission not granted on remotedesktop.google.com.
Fix: in the CRD page, grant clipboard permission when Chrome prompts; OR visit
chrome://settings/content/clipboard, find https://remotedesktop.google.com,
set to Allow. Then re-run.
```

### 4. Set up tempfile (NOT a shell-expanded string)

A shell-expanded `pbcopy "$VAR"` corrupts payloads with `$VAR`, backslashes, and embedded quotes. Use a tempfile:

```bash
TEMPFILE="/tmp/macmini-paste.$$"
trap 'rm -f "$TEMPFILE"' EXIT INT TERM
```

### 5. Per-chunk loop

For each chunk:

```bash
# 5a. Write THIS chunk to tempfile (overwrite — only this chunk's content)
printf '%s' "<chunk>" > "$TEMPFILE"
chmod 600 "$TEMPFILE"
```

```
# 5b. Re-select CRD page (other code may have switched)
mcp.select_page(crd_page)

# 5c. Bring CRD tab to front. Try mcp.bring_to_front first; if not available,
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
# 5d. pbcopy from tempfile (not from shell-expanded string)
pbcopy < "$TEMPFILE"
```

```
# 5e. Force CRD's clipboard sync trigger via blur+focus on the page
mcp.evaluate_script("(() => { window.blur(); window.focus(); return true; })()")

# 5f. Brief sync wait (tune in Phase 6)
sleep 800ms

# 5g. Focus the canvas via mcp.click — DOM .focus() is a no-op on canvas.
mcp.click('canvas', 1, 1)

# 5h. Send Cmd+V (LOWERCASE v — uppercase V is Cmd+Shift+V)
mcp.press_key("Meta+v")

# 5i. Brief wait for paste to land on Mac mini side
sleep 200ms
```

### 6. Cleanup

```bash
rm -f "$TEMPFILE"
```

### 7. Final report

Print:

```
pasted <char_len> chars (<n> chunks)
```

If chunked (n > 1), also print:

```
WARNING: chunked paste — verify integrity on Mac mini with shasum if payload matters.
```

Never log the payload itself (PII discipline).

---

## Errors

- **MCP unreachable** — chrome-devtools MCP not configured/running. Check MCP settings.
- **No CRD tab** — run `/macmini connect` first.
- **Clipboard permission not granted** — see step 3 fix message.
- **Paste arrives empty / stale on Mac mini** — CRD clipboard sync may not be enabled. Open CRD side menu (right-edge arrow) → "Enable clipboard synchronization" → Begin.
