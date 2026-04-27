---
description: One-time + per-session permission grants so the user is never asked to click "Allow" mid-flow.
argument-hint: "<install|cdp|ui|revert|status>"
---

# auto-grant — make Chrome stop asking

ARGS = $ARGUMENTS  # required, no default
mode = first word of ARGS

if not mode:
  print "Usage: /macmini auto-grant <install|cdp|ui|revert|status>"
  print "  install — Chrome user policy (one-time, no sudo)"
  print "  cdp     — Browser.grantPermissions for current session (called from connect)"
  print "  ui      — auto-click Begin + Send System Keys (called from connect)"
  print "  revert  — surgically remove our origin from policy"
  print "  status  — show what's in place + remediation"
  exit 1

────────────────────────────────────────────────────────────
## mode == "install"
────────────────────────────────────────────────────────────

Step 1 — Detect Chrome bundle ID
  bash:
    BUNDLE_ID=$(bash skills/macmini/scripts/chrome-bundle-id.sh)
    # Returns one of: com.google.Chrome | com.google.Chrome.beta |
    #                 com.google.Chrome.canary | org.chromium.Chromium
  print "Detected Chrome: $BUNDLE_ID"

Step 2 — Note on prior denials (limitation)
  # CDP doesn't expose a permission-state getter, so we cannot programmatically
  # detect a prior chrome://settings denial. If the user has previously denied
  # clipboard at chrome://settings/content/clipboard for remotedesktop.google.com,
  # the recommended user policy will be silently overridden. Fix: clear the denial
  # in chrome://settings, or use --mandatory (sudo) which overrides user UI choices.
  print:
    "Note: cannot programmatically detect prior chrome://settings denials."
    "If clipboard still prompts after restart, either:"
    "  (a) Visit chrome://settings/content/clipboard, find https://remotedesktop.google.com,"
    "      change Block to Default, then rerun after clearing chrome://settings denial, OR"
    "  (b) Use --mandatory: sudo bash skills/macmini/scripts/auto-grant-clipboard.sh --mandatory"
    "      (mandatory policy overrides user UI choices)"

Step 3 — Write user policy (idempotent)
  bash:
    bash skills/macmini/scripts/auto-grant-clipboard.sh grant --bundle-id "$BUNDLE_ID"

Step 4 — Print next steps
  print:
    "Wrote Chrome user policy. RESTART CHROME for it to take effect."
    "Verify after restart:"
    "  chrome://policy → search 'Clipboard'"
    "  chrome://settings/content/clipboard → origin shows 'Allowed by your administrator'"
    ""
    "Optional stronger mode (mandatory, sudo required, survives user override):"
    "  sudo bash skills/macmini/scripts/auto-grant-clipboard.sh --mandatory --bundle-id $BUNDLE_ID"

────────────────────────────────────────────────────────────
## mode == "cdp"
────────────────────────────────────────────────────────────

Step 1 — Verify Chrome debug port reachable; soft-fail if not
  bash:
    if ! curl -fsS http://127.0.0.1:9222/json/version > /dev/null 2>&1; then
      echo "WARN: Chrome not on debug port 9222."
      echo "  Soft-failing CDP grant; clipboard policy fallback (set by"
      echo "  /macmini auto-grant install) still covers us."
      echo "  To enable CDP grants, relaunch Chrome with --remote-debugging-port=9222"
      echo "  (see setup.md). Note: this disconnects any existing CRD session."
      exit 0
    fi

Step 2 — Grant clipboard + keyboardLock
  bash:
    mkdir -p ~/.cache/macmini
    OUT=$(node skills/macmini/scripts/grant-cdp-permissions.mjs \
      --origin "https://remotedesktop.google.com" \
      --permissions "clipboardReadWrite,clipboardSanitizedWrite,keyboardLock" 2>&1)
    EXIT=$?
    echo "{\"timestamp\":\"$(date -u +%FT%TZ)\",\"exit\":$EXIT,\"output\":$(echo "$OUT" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')}" > ~/.cache/macmini/last-cdp-grant.json
    echo "$OUT"

────────────────────────────────────────────────────────────
## mode == "ui"
────────────────────────────────────────────────────────────

This mode auto-clicks in-canvas CRD controls (Begin clipboard sync, Send System
Keys toggle) so the user is never asked to click "Allow" mid-flow. It reads
selector hypotheses from `skills/macmini/data/crd-selectors.json`. Each selector
has fields: `role`, `name_pattern` (regex source), `name_flags` (JS regex flags
like `"i"`), `kind` (`"button"` or `"toggle"`), `aria_attr` (for toggles, the
attribute holding ON/OFF state, typically `aria-checked` or `aria-pressed`).

Execute the following steps in order. The agent runs each step explicitly.

### Step 1 — Confirm the CRD tab is selected

Call `mcp.list_pages()`. Find the first page whose `url` starts with
`https://remotedesktop.google.com/access/session/`. If none, print
`Skip: no CRD session page open` and exit cleanly. Otherwise call
`mcp.select_page({pageIdx: <crd_page.idx>, bringToFront: true})`.

### Step 2 — Load selector hypotheses

Read the JSON file at `~/.claude-dotfiles/skills/macmini/data/crd-selectors.json`.
This is a flat object whose keys are selector names (e.g. `begin_button`,
`send_system_keys`) and values are selector objects. Skip any key that starts
with `_` (those are metadata like `_last_verified`).

### Step 3 — For each selector entry (in iteration order)

For each `(key, sel)` pair in the JSON, do the following sub-steps. If any
sub-step decides to skip this selector, move on to the next one.

#### 3a. Compute a CSS-safe name hint from the regex pattern

The `sel.name_pattern` is a regex source string. CSS attribute selectors
(`[aria-label*='...' i]`) cannot contain regex metachars — they must be plain
text. The agent computes the hint by stripping regex special chars before
using `name_pattern` in a CSS selector.

Strip these chars from `sel.name_pattern`: `^ $ . * + ? ( ) [ ] { } \ |`
Then trim whitespace and take the first whitespace-delimited word.

Examples:
- `"^begin$"` → strip to `"begin"` → first word `"begin"`
- `"send system keys"` → strip leaves `"send system keys"` → first word `"send"`
- `"^connect|join$"` → strip to `"connectjoin"` → first word `"connectjoin"`

The agent does this transformation in prose (no Python `re.sub` call needed —
just substitute manually based on the JSON it just read). Call the result
`name_hint`. Call `sel.role` simply `role_str`.

#### 3b. Wait for UI hydration

Try `mcp.wait_for` with a CSS selector built from `role_str` + `name_hint`:

  selector = `[role='` + role_str + `'][aria-label*='` + name_hint + `' i]`

Call `mcp.wait_for(selector, "5s")`.

If it times out, fall back to the plain role match:

  fallback = `[role='` + role_str + `']`

Call `mcp.wait_for(fallback, "5s")`. If THAT also times out, print
`Skip <key>: role=<role_str> not in DOM within 5s (already done OR CRD UI changed)`
and continue to the next selector.

#### 3c. Find the matching uid via accessibility snapshot

Call `mcp.take_snapshot()` and read the returned text. The snapshot lists
elements line-by-line in a format like:

  button "Begin" [uid:1234] role=button

The agent walks the lines and for each line:
- Skip the line if it does not contain `role_str` anywhere in the text.
- Extract the uid by finding the substring matching `[uid:XXXX]` (alphanumeric).
- Extract the name by finding the first quoted string `"..."`.
- Test whether the name matches `sel.name_pattern` using `sel.name_flags`. The
  agent does this match itself (it knows JS regex semantics — pattern + flags,
  NEVER inline `(?i)`). If it matches, record this `uid` and stop scanning.

If no line matches, print:
  `Skip <key>: no name match in snapshot. See AGENT-GUIDE.md → 'Discovering CRD selectors empirically' to refresh hypotheses.`
and continue to the next selector.

#### 3d. For toggles, probe current ON/OFF state via DOM

If `sel.kind == "toggle"`, run this exact `evaluate_script` to read the toggle's
current aria attribute. Pass the function source as a string and supply runtime
values via the `args` array — DO NOT string-interpolate values into the source.

```
mcp.evaluate_script({
  function: "(opts) => { const els = document.querySelectorAll('[role=\"' + opts.role + '\"]'); const re = new RegExp(opts.pattern, opts.flags); for (const el of els) { const label = el.getAttribute('aria-label') || el.textContent.trim(); if (re.test(label)) return el.getAttribute(opts.aria_attr); } return null; }",
  args: [{role: sel.role, pattern: sel.name_pattern, flags: sel.name_flags || "", aria_attr: sel.aria_attr}]
})
```

If the returned value is the string `"true"`, the toggle is already ON. Print
`Skip <key>: already ON (<sel.aria_attr>=true)` and continue to the next
selector.

#### 3e. Click the target

Call `mcp.click({uid: <recorded uid from 3c>})`. Then print
`Clicked <key> (<uid>)`.

────────────────────────────────────────────────────────────
## mode == "revert"
────────────────────────────────────────────────────────────

  bash:
    BUNDLE_ID=$(bash skills/macmini/scripts/chrome-bundle-id.sh)
    bash skills/macmini/scripts/auto-grant-clipboard.sh --revert --bundle-id "$BUNDLE_ID"
  print:
    "If you also installed mandatory policy, run:"
    "  sudo bash skills/macmini/scripts/auto-grant-clipboard.sh --revert-mandatory"

────────────────────────────────────────────────────────────
## mode == "status"
────────────────────────────────────────────────────────────

  bash:
    BUNDLE_ID=$(bash skills/macmini/scripts/chrome-bundle-id.sh)
    
    bash skills/macmini/scripts/auto-grant-clipboard.sh --status --bundle-id "$BUNDLE_ID"
    
    if [ -f ~/.cache/macmini/last-cdp-grant.json ]; then
      cat ~/.cache/macmini/last-cdp-grant.json
    else
      echo "cdp-grant: NEVER RUN"
    fi
    
    if curl -fsS http://127.0.0.1:9222/json/version > /dev/null 2>&1; then
      echo "debug-port-9222: REACHABLE"
    else
      echo "debug-port-9222: UNREACHABLE"
    fi
  
  pages = mcp.list_pages()
  if any p in pages where p.url contains "remotedesktop.google.com/access/session/":
    print "crd-session-tab: OPEN"
  else:
    print "crd-session-tab: CLOSED"
  
  Print remediation table:
    "REMEDIATION:"
    "  user-policy: NOT SET           → /macmini auto-grant install"
    "  user-policy: ALLOWED but UI shows DENIED  → use --mandatory"
    "  cdp-grant: FAILED              → /macmini auto-grant cdp"
    "  cdp-grant: NEVER RUN           → /macmini connect (calls cdp internally)"
    "  debug-port-9222: UNREACHABLE   → relaunch Chrome (see setup.md)"
    "  crd-session-tab: CLOSED        → /macmini connect"
