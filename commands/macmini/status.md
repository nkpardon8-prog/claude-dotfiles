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

Run a battery of audit checks. For each row, execute the bash on the right and surface the result in the table.

| Check                       | Bash to run                                                                       | Expected      |
|-----------------------------|-----------------------------------------------------------------------------------|---------------|
| user-policy clipboard       | `bash skills/macmini/scripts/auto-grant-clipboard.sh --status`                    | "ALLOWED"     |
| CDP grant (last result)     | `cat ~/.cache/macmini/last-cdp-grant.json 2>/dev/null \|\| echo "NEVER RUN"`      | exit 0        |
| Chrome debug port 9222      | `curl -fsS http://127.0.0.1:9222/json/version > /dev/null`                        | exit 0        |
| CRD session tab             | `mcp.list_pages` → match url ~ `remotedesktop.google.com/access/session`          | "OPEN"        |
| Clipboard runtime probe     | single-call try/catch `readText()` in CRD page context (see step 4)               | "granted"     |
| CRD canvas (DOM check)      | `mcp.evaluate_script: !!document.querySelector('canvas')`                         | true          |
| Sign-in valid               | `mcp.evaluate_script: !!document.querySelector('a[href*="accounts.google.com/signin"]') \|\| /accounts\.google\.com/.test(location.href)` | no match      |

### 4. Clipboard runtime probe (single-call try/catch)

In the CRD page context:

```js
let clipboardOk;
try { await navigator.clipboard.readText(); clipboardOk = true; }
catch (err) { clipboardOk = false; }
const advisory = (await navigator.permissions.query({name:'clipboard-read'})).state;
return { clipboardOk, advisory };
```

If `clipboardOk === true`, surface "granted". Otherwise surface "denied" and include the advisory state for diagnostics. Treat `permissions.query` as advisory only — `readText()` is the source of truth.

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
