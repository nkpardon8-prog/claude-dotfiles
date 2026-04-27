---
description: Pure DevTools + bash audit — is the canvas up, is sign-in valid, are auto-grant policies and CDP grants in place?
argument-hint: ""
---

# /macmini status

Quick health summary using chrome-devtools MCP plus the auto-grant audit scripts. Tells you whether the user-policy is set, the latest CDP grant landed, Chrome is on the remote-debugging port, the CRD canvas is rendered, the runtime clipboard probe works, and the Google session is valid.

## Sequence

### 1. Find the CRD tab

```
pages = mcp.list_pages()
crd_page = first page where url startsWith "https://remotedesktop.google.com/"
```

If no CRD tab exists, surface it as a row in the audit table below (CRD session tab = CLOSED) — but still run the rest of the checks.

### 2. Select the page (if found)

`mcp.select_page(crd_page)`

### 3. Run the audit battery

Run a battery of audit checks. Two tables follow: shell-side audits (run in your dev terminal) and MCP-side audits (run via chrome-devtools MCP against the CRD page). Execute each row's command exactly as shown and surface the result in the results table in step 5.

#### 3a. Bash audits (run in dev terminal)

| Check                       | Bash to run                                                                       | Expected      |
|-----------------------------|-----------------------------------------------------------------------------------|---------------|
| user-policy clipboard       | `BUNDLE_ID=$(bash skills/macmini/scripts/chrome-bundle-id.sh)` then `bash skills/macmini/scripts/auto-grant-clipboard.sh --status --bundle-id "$BUNDLE_ID"` | "ALLOWED"     |
| CDP grant (last result)     | `cat ~/.cache/macmini/last-cdp-grant.json 2>/dev/null \|\| echo "NEVER RUN"`      | exit 0        |
| Chrome debug port 9222      | `curl -fsS http://127.0.0.1:9222/json/version > /dev/null`                        | exit 0        |

#### 3b. MCP audits (run via chrome-devtools MCP)

| Check                       | MCP call                                                                          | Expected      |
|-----------------------------|-----------------------------------------------------------------------------------|---------------|
| CRD session tab             | `mcp.list_pages` → match url ~ `remotedesktop.google.com/access/session`          | "OPEN"        |
| Clipboard runtime probe     | `mcp.evaluate_script` with the async-IIFE body in step 4                          | "granted"     |
| CRD canvas (DOM check)      | `mcp.evaluate_script({function: "() => !!document.querySelector('canvas')"})`     | true          |
| Sign-in valid               | `mcp.evaluate_script({function: "() => !!document.querySelector('a[href*=\\"accounts.google.com/signin\\"]') \|\| /accounts\\.google\\.com/.test(location.href)"})` | no match      |

### 4. Clipboard runtime probe (single-call try/catch, async IIFE)

The `evaluate_script` body must be wrapped in an async IIFE because top-level `await` is a syntax error in plain JS. Pass `awaitPromise: true` so chrome-devtools MCP awaits the returned promise.

```
mcp.evaluate_script({
  function: "(async () => { try { await navigator.clipboard.readText(); return 'granted'; } catch (e) { const advisory = (await navigator.permissions.query({name:'clipboard-read'})).state; return advisory; } })()",
  awaitPromise: true
})
```

If the call returns `"granted"`, surface "granted" in the results table. Any other return value is the advisory permission state (`"prompt"`, `"denied"`, etc.); surface that as the diagnostic. Treat `permissions.query` as advisory only — `readText()` is the source of truth.

### 5. Print results table

```
| Layer                       | State    | Detail                                        |
|-----------------------------|----------|-----------------------------------------------|
| user-policy clipboard       | OK/FAIL  | <ALLOWED | NOT SET>                          |
| CDP grant (last result)     | OK/FAIL  | <timestamp / NEVER RUN>                       |
| Chrome debug port 9222      | OK/FAIL  | <reachable | UNREACHABLE>                     |
| CRD session tab             | OK/FAIL  | <crd_page.url | CLOSED>                       |
| Clipboard runtime probe     | OK/FAIL  | <granted | denied (advisory: <state>)>        |
| CRD canvas (DOM check)      | OK/FAIL  | canvas element <present | missing>            |
| Sign-in valid               | OK/FAIL  | <signed in | sign-in page detected>           |
```

### 6. Remediation matrix

Print this matrix after the results table; map each row's failure mode to the exact fix command.

| Failure                                  | Fix                                                  |
|------------------------------------------|------------------------------------------------------|
| user-policy NOT SET                      | `/macmini auto-grant install`                        |
| user-policy ALLOWED but UI shows DENIED  | re-run install with `--mandatory`                    |
| CDP grant FAILED                         | `/macmini auto-grant cdp` (or relaunch Chrome)       |
| debug-port-9222 UNREACHABLE              | relaunch Chrome with `--remote-debugging-port=9222`  |
| CRD session tab CLOSED                   | `/macmini connect`                                   |
| Clipboard probe DENIED                   | `/macmini auto-grant install` + restart Chrome; check `chrome://settings/content/clipboard` |
| Sign-in EXPIRED                          | sign in inside Chrome, then `/macmini connect`       |
