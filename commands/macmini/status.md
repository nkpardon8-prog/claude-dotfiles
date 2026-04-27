---
description: Pure DevTools check — is the CRD canvas up, is sign-in valid, is clipboard-read permission granted?
argument-hint: ""
---

# /macmini status

Quick health summary using only chrome-devtools MCP. Tells you whether the canvas is rendered, the Google session is valid, and the prerequisite Chrome permissions are in place.

## Sequence

### 1. Find the CRD tab

```
pages = mcp.list_pages()
crd_page = first page where url startsWith "https://remotedesktop.google.com/"
```

If no CRD tab exists, print:

```
| Layer        | State | Detail                                    |
|--------------|-------|-------------------------------------------|
| CRD session  | FAIL  | not connected — run /macmini connect      |
```

and exit.

### 2. Select the page

`mcp.select_page(crd_page)`

### 3. Probe canvas + sign-in (single evaluate_script)

```
mcp.evaluate_script("(() => ({
  canvas_present: !!document.querySelector('canvas'),
  signin_visible:
    !!document.querySelector('a[href*=\"accounts.google.com/signin\"]') ||
    /accounts\\.google\\.com/.test(location.href),
}))()")
```

### 4. Probe clipboard-read permission (TWO-CALL workaround)

The async-IIFE single-call form is unreliable across MCP versions. Use two calls:

```
mcp.evaluate_script(
  "navigator.permissions.query({name:'clipboard-read'}).then(p => { window.__clipState = p.state; });"
)
sleep 100ms
clipboard_state = mcp.evaluate_script("window.__clipState")
```

### 5. Probe fullscreen state (TWO-CALL workaround for symmetry)

The Fullscreen API check is best-effort — CRD has its own internal fullscreen mode that may not set `document.fullscreenElement`. This check is informational, not authoritative.

```
mcp.evaluate_script(
  "window.__fsState = !!document.fullscreenElement || !!document.webkitFullscreenElement;"
)
sleep 50ms
fullscreen_state = mcp.evaluate_script("window.__fsState")
```

### 6. Print results table

```
| Layer            | State    | Detail                                        |
|------------------|----------|-----------------------------------------------|
| CRD tab          | OK       | <crd_page.url>                                |
| Canvas           | OK/FAIL  | canvas element <present|missing>              |
| Google sign-in   | OK/FAIL  | <signed in | sign-in page detected>           |
| Clipboard perm   | OK/FAIL  | granted | prompt | denied                     |
| Fullscreen (API) | OK/hint  | <true | false — see hint below>               |
```

Use `OK` when the check passes, `FAIL` when it fails. Use `hint` for the fullscreen row when the API reports false (it is not a hard failure — see Fullscreen note above).

### 7. Inline remediation hints

- **Canvas FAIL** — `/macmini connect` to drive the PIN/sign-in flow.
- **Sign-in FAIL** — Google session expired. Sign in inside the open Chrome window, then re-run `/macmini connect`.
- **Clipboard perm = prompt** — paste any small string via `/macmini paste "test"` to trigger Chrome's permission prompt.
- **Clipboard perm = denied** — visit `chrome://settings/content/clipboard`, find `https://remotedesktop.google.com`, set to Allow.
- **Fullscreen hint** — if `Cmd+Space` / `Cmd+Tab` don't forward to the Mac mini, click the right-edge arrow → Full-screen + enable "Send System Keys".
