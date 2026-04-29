---
description: Quick health audit for the macmini skill — is the CRD canvas up, is the Google session valid, is the clipboard permission granted?
argument-hint: ""
---

# /macmini status

Audits the things that can actually fail in the post-strip skill: CRD tab presence, Google sign-in validity, clipboard runtime permission, and the CRD canvas DOM. No more user-policy or CDP-grant audits — those auto-grant modes were removed because they don't work in stock Chrome+CRD.

## Sequence

### 1. Find the CRD tab

```
pages = mcp.list_pages()
crd_page = first page where url startsWith "https://remotedesktop.google.com/"
```

If no CRD tab exists, surface it as `CRD session tab = CLOSED` and skip the page-scoped checks.

### 2. Select the page (if found)

`mcp.select_page({pageId, bringToFront: true})`

### 3. Run the audit battery

| Check                       | MCP call                                                                          | Expected      |
|-----------------------------|-----------------------------------------------------------------------------------|---------------|
| CRD session tab             | `mcp.list_pages` → match url ~ `remotedesktop.google.com/access/session`          | "OPEN"        |
| Clipboard runtime probe     | `mcp.evaluate_script` with the async-IIFE body in step 4                          | "granted"     |
| CRD canvas (DOM check)      | `mcp.evaluate_script({function: "() => !!document.querySelector('canvas')"})`     | true          |
| Sign-in valid               | `mcp.evaluate_script({function: "() => !!document.querySelector('a[href*=\\"accounts.google.com/signin\\"]') \|\| /accounts\\.google\\.com/.test(location.href)"})` | no match      |
| gh authenticated (dev)      | `gh auth status` exit code                                                        | exit 0        |

### 4. Clipboard runtime probe (single-call try/catch, async IIFE)

```
mcp.evaluate_script({
  function: "(async () => { try { await navigator.clipboard.readText(); return 'granted'; } catch (e) { const advisory = (await navigator.permissions.query({name:'clipboard-read'})).state; return advisory; } })()"
})
```

If the call returns `"granted"`, surface "granted" in the results table. Any other return value is the advisory permission state (`"prompt"`, `"denied"`, etc.); surface that as the diagnostic. Treat `permissions.query` as advisory only — `readText()` is the source of truth.

### 5. Print results table

```
| Layer                       | State    | Detail                                        |
|-----------------------------|----------|-----------------------------------------------|
| CRD session tab             | OK/FAIL  | <crd_page.url | CLOSED>                       |
| Clipboard runtime probe     | OK/FAIL  | <granted | denied (advisory: <state>)>        |
| CRD canvas (DOM check)      | OK/FAIL  | canvas element <present | missing>            |
| Sign-in valid               | OK/FAIL  | <signed in | sign-in page detected>           |
| gh authenticated (dev)      | OK/FAIL  | <user@gh | not logged in>                     |
```

### 6. Remediation matrix

| Failure                          | Fix                                                  |
|----------------------------------|------------------------------------------------------|
| CRD session tab CLOSED           | `/macmini connect`                                   |
| Clipboard probe `prompt`/`denied`| User: visit `chrome://settings/content/clipboard`, set `https://remotedesktop.google.com` to "Allow". (One-time. Persists across sessions.) |
| CRD canvas missing               | Page didn't load the canvas yet — wait 10s, retry; if still missing, `/macmini connect` |
| Sign-in EXPIRED                  | Sign in inside Chrome, then `/macmini connect`       |
| gh not authenticated             | `gh auth login` on dev. Also verify on Mac mini (`/macmini paste` requires gh on both sides). |
