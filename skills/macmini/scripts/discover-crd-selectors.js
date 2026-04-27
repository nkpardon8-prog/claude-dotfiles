// Run via mcp.evaluate_script. On success, prints JSON to stdout that
// the caller can pipe to ~/.claude-dotfiles/skills/macmini/data/crd-selectors.json.
//
// Output format:
//   {
//     "_last_verified": "<timestamp>",
//     "begin_button": {"role": "button", "name_pattern": "...", "kind": "button-once"},
//     "clipboard_sync_toggle": {...},
//     "send_system_keys_toggle": {...}
//   }
//
// Caller writes this to data/crd-selectors.json (no markdown editing needed).

(() => {
  const findings = {};
  const seen = new WeakSet();
  function walk(root) {
    if (!root || seen.has(root)) return;
    seen.add(root);
    const elems = root.querySelectorAll ? root.querySelectorAll('*') : [];
    for (const el of elems) {
      const aria = el.getAttribute && (el.getAttribute('aria-label') || el.textContent.trim().slice(0, 50));
      const role = el.getAttribute && el.getAttribute('role');
      const tag = el.tagName.toLowerCase();

      // Heuristic: match expected hypotheses. JSON schema splits
      // pattern from flags (JS regex doesn't support inline (?i)).
      if (/^begin$/i.test(aria || '') && (role === 'button' || tag === 'button')) {
        findings.begin_button = {role: role || 'button', name_pattern: '^begin$', name_flags: 'i', kind: 'button-once'};
      }
      if (/enable clipboard sync/i.test(aria || '') && (role === 'switch' || tag === 'mwc-switch')) {
        findings.clipboard_sync_toggle = {role: role || 'switch', name_pattern: 'enable clipboard sync', name_flags: 'i', kind: 'toggle', aria_attr: 'aria-checked'};
      }
      if (/send system keys/i.test(aria || '') && (role === 'switch' || tag === 'mwc-switch')) {
        findings.send_system_keys_toggle = {role: role || 'switch', name_pattern: 'send system keys', name_flags: 'i', kind: 'toggle', aria_attr: 'aria-pressed'};
      }

      if (el.shadowRoot) walk(el.shadowRoot);
    }
  }
  walk(document);

  return JSON.stringify({
    _last_verified: new Date().toISOString(),
    _comment: "Discovered by discover-crd-selectors.js. Apply via: cat > ~/.claude-dotfiles/skills/macmini/data/crd-selectors.json",
    ...findings
  }, null, 2);
})();
