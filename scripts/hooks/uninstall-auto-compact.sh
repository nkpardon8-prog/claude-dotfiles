#!/usr/bin/env bash
# Uninstall the auto-compact-after-pre-compact feature.
# Reverses the wiring without deleting source files (those are owned by the dotfiles repo).
#
# Removes:
#   - The Stop hook entry from ~/.claude/settings.json (the second entry pointing to
#     auto-compact-after-pre-compact.sh)
#   - Any active sentinels in ~/.claude/progress/auto-compact-*.json
#   - The log at ~/.claude/logs/auto-compact.log
#
# Does NOT remove:
#   - The hook script itself (~/.claude-dotfiles/scripts/hooks/auto-compact-after-pre-compact.sh)
#   - The arming script (~/.claude-dotfiles/scripts/hooks/arm-auto-compact.sh)
#   - The Step 9.0 block in pre-compact.md (the skill detects no hook is registered and
#     reports "NOT armed" gracefully)
#
# Idempotent — safe to re-run.

set -u
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || { echo "no settings.json at $SETTINGS"; exit 0; }

# Remove the Stop-hook entry that references auto-compact-after-pre-compact.sh.
# `all(...)` ensures multi-hook entries are dropped only if NONE of their hooks remain
# (i.e., the entry was solely for auto-compact). For entries that contain BOTH our hook
# AND unrelated hooks, we filter the inner array instead so we don't drop the other hooks.
TMP="${SETTINGS}.tmp.$$"
jq '
  if .hooks.Stop then
    .hooks.Stop |= (
      map(
        .hooks |= map(select((.command // "") | test("auto-compact-after-pre-compact\\.sh") | not))
      )
      | map(select((.hooks | length) > 0))
    )
  else . end
' "$SETTINGS" > "$TMP" 2>/dev/null || { echo "jq failed; aborting"; rm -f "$TMP"; exit 1; }

# Sanity-check the result is valid JSON before swapping.
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP" 2>/dev/null || {
  echo "post-edit JSON invalid; aborting"; rm -f "$TMP"; exit 1;
}
mv "$TMP" "$SETTINGS"
echo "removed Stop hook entry from $SETTINGS"

# Clean up runtime state.
rm -f "$HOME/.claude/progress/auto-compact-"*.json 2>/dev/null
rm -f "$HOME/.claude/progress/auto-compact-"*.json.claim.* 2>/dev/null
rm -f "$HOME/.claude/logs/auto-compact.log" 2>/dev/null
echo "cleaned sentinels + log"

echo "DONE. Restart Claude Code for the settings change to take effect."
