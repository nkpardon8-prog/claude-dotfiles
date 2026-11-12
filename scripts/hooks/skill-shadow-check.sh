#!/usr/bin/env bash
# skill-shadow-check.sh - SessionStart warning: a local ~/.claude/skills/<name>/ directory with the
# same name as a synced ~/.claude-dotfiles/commands/<name>.md wins skill resolution, so every agent on
# that machine silently runs the stale local copy. Found 2026-11-12: an April copy of plan/implement
# hid the /mission --roadmap and --mission modes on Nick's Mac mini. Silent at zero. Always exits 0.
skills="$HOME/.claude/skills"; cmds="$HOME/.claude-dotfiles/commands"
[ -d "$skills" ] && [ -d "$cmds" ] || exit 0
hits=""
for d in "$skills"/*/; do
  n=$(basename "$d")
  [ -f "$cmds/$n.md" ] && [ ! -L "${d%/}" ] && hits="$hits $n"
done
[ -z "$hits" ] && exit 0
echo "skill-shadow-check: local ~/.claude/skills copies override the synced commands:$hits."
echo "  They are stale and win skill lookup. Move them aside (not delete):"
echo "  mkdir -p ~/.claude/skills-shadowed && mv ~/.claude/skills/{$(echo $hits | tr ' ' ',')} ~/.claude/skills-shadowed/"
exit 0
