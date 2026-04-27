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

Step 1 — Confirm CRD tab is selected
  pages = mcp.list_pages()
  crd_page = first page where url starts with "https://remotedesktop.google.com/access/session/"
  if not crd_page:
    print "Skip: no CRD session page open"
    exit 0
  mcp.select_page(crd_page.uid)

Step 2 — Load selector hypotheses
  selectors = JSON.parse(read("~/.claude-dotfiles/skills/macmini/data/crd-selectors.json"))

Step 3 — For each selector, attempt click (idempotent)

(The agent runs this loop. For each selector entry from the JSON,
execute the sub-steps. All variables are simple text substitutions —
no embedded mini-language; the agent fills `${...}` placeholders
explicitly using values from the JSON object.)

  for each (key, sel) in selectors:
    if key starts with "_": continue   # skip metadata
    
    # 3a. Wait for UI hydration via CSS-selector wait_for.
    # First word of name_pattern serves as a coarse aria-label hint;
    # if no [aria-label*=...] match in 5s, fall back to plain role match.
    name_hint = first_word_of(sel.name_pattern)   # "^begin$" → "begin"
    role_str  = sel.role
    
    try:
      mcp.wait_for("[role='${role_str}'][aria-label*='${name_hint}' i]", "5s")
    except timeout:
      try:
        mcp.wait_for("[role='${role_str}']", "5s")
      except timeout:
        print "Skip ${key}: role=${role_str} not in DOM within 5s (already done OR CRD UI changed)"
        continue
    
    # 3b. Take snapshot, parse markdown line-by-line for a uid match.
    # take_snapshot returns lines like:
    #   button "Begin" [uid:1234] role=button
    # Match: a line containing role=${role_str} (or quoted role) AND a
    # name matching the regex.
    snap_text = mcp.take_snapshot()
    target_uid = null
    for line in snap_text.split('\n'):
      # Filter to candidate role lines:
      if 'role=${role_str}' not in line and '${role_str}' not in line:
        continue
      uid_match = re.search(r'\[uid:(\w+)\]', line)
      if not uid_match:
        continue
      # Extract a name token from the line (typically a quoted string after role)
      name_match = re.search(r'"([^"]+)"', line)
      if not name_match:
        continue
      candidate_name = name_match.group(1)
      # Build regex with explicit pattern + flags (NO inline (?i) — JS-incompat,
      # but our Python parsing also separates them for consistency)
      if re.search(sel.name_pattern, candidate_name, flags=flags_to_python(sel.name_flags or "")):
        target_uid = uid_match.group(1)
        break
    
    if not target_uid:
      print "Skip ${key}: no name match in snapshot. Run discovery:"
      print "  See AGENT-GUIDE.md → 'Discovering CRD selectors empirically'"
      continue
    
    # 3c. For toggles, probe current state via evaluate_script DOM read.
    # CRITICAL: build the regex with separate pattern + flags, NOT inline (?i).
    # JS rejects inline flag syntax.
    if sel.kind == "toggle":
      # Inject the pattern + flags + aria_attr + role as JSON-encoded constants
      js_function_body = '''
(opts) => {
  const els = document.querySelectorAll('[role="' + opts.role + '"]');
  const re = new RegExp(opts.pattern, opts.flags);
  for (const el of els) {
    const label = el.getAttribute('aria-label') || el.textContent.trim();
    if (re.test(label)) return el.getAttribute(opts.aria_attr);
  }
  return null;
}
'''
      state = mcp.evaluate_script(
        function = js_function_body,
        args = [{
          "role": sel.role,
          "pattern": sel.name_pattern,
          "flags": sel.name_flags or "",
          "aria_attr": sel.aria_attr
        }]
      )
      if state == "true":
        print "Skip ${key}: already ON (${sel.aria_attr}=${state})"
        continue
    
    # 3d. Click
    mcp.click(target_uid)
    print "Clicked ${key} (${target_uid})"

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
