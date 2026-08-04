#!/usr/bin/env bash
# mission-drift-check.sh — READ-ONLY manual reporter for the stale-claim guard.
#
# Reports, per part, whether the working tree has DRIFTED since that part's convergence snapshot
# (stamped by _mw_emit_snapshot at each `phase=review findings=0 dry=2` round). This is the
# "let me check by hand" surface — NOT an enforcement path. The real guard is the tree-drift
# precondition inside _mw_partdone_check (mission-write.sh), which mechanically blocks a stale
# PART-DONE with rc=4 at write time. This script only observes; it ALWAYS exits 0 and never writes.
#
# Usage: mission-drift-check.sh <sid> <root>
# Output (one line per part carrying a converged snapshot, plus a summary):
#   drift-check: part=N CLEAR (tree matches convergence <h16>)
#   drift-check: part=N DRIFT (stamped=<h16> current=<h16> — re-review before PART-DONE)
#   drift-check: part=N N/A (cannot fingerprint: <sentinel>)
#   drift-check: summary parts_checked=<n> drift=<n>
# macOS bash 3.2.57 compatible.

# --- source the lib (relative-then-absolute, mirrors mission-write.sh) ---
if ! command -v _mission_tree_fingerprint >/dev/null 2>&1; then
  if [ -n "${BASH_SOURCE:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/mission-bridge.sh" ]; then
    . "$(dirname "${BASH_SOURCE[0]}")/lib/mission-bridge.sh"
  elif [ -f "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh" ]; then
    . "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"
  fi
fi
if ! command -v _mission_tree_fingerprint >/dev/null 2>&1; then
  echo "drift-check: FAILED (lib mission-bridge.sh not found/sourced)"; exit 0
fi

sid="${1:-}"; root="${2:-}"
if [ -z "$sid" ] || [ -z "$root" ]; then
  echo "drift-check: usage: mission-drift-check.sh <sid> <root>"; exit 0
fi

stream=$(_gen_sliced_stream "$sid" "$root" 2>/dev/null) || {
  echo "drift-check: N/A (gen-sliced read refused — gen-boundary mismatch)"; exit 0; }

# S2 (round-4): double-anchored the same way mission-bridge.sh's gen-sliced readers are (grep them for
# `-F'\t'` / `$1 ~` / `$2 ~`) - match on BOTH the snapshot idtag column ($1, `(g<N>-)?snap-p<N>-conv-…`,
# the idtag _mw_emit_snapshot stamps) AND the body prefix ($2 starts with `[mission] SNAPSHOT `). A
# criticer/note free-text line that merely EMBEDS a forged `SNAPSHOT … tree=<current>` carries a
# non-snapshot idtag column, so it can no longer make this report falsely claim CLEAR.
parts=$(printf '%s\n' "$stream" \
  | awk -F'\t' '$1 ~ /^(g[0-9]+-)?snap-p[0-9]+-conv-/ && $2 ~ /^\[mission\] SNAPSHOT part=[0-9]+ kind=converged/ { print $2 }' \
  | grep -oE 'part=[0-9]+' | sed 's/part=//' | sort -un)
if [ -z "$parts" ]; then
  echo "drift-check: no convergence snapshots yet (nothing to check)"; exit 0
fi

current=$(_mission_tree_fingerprint "$root" 2>/dev/null)
drift=0; checked=0
for p in $parts; do
  # S2 (round-4): double-anchored ($1 snapshot idtag column + $2 body prefix), mirroring mission-write.sh's
  # _mw_partdone_check reader so a forged free-text SNAPSHOT line cannot be picked as the stamp.
  snapline=$(printf '%s\n' "$stream" | awk -F'\t' -v pn="$p" '$1 ~ /^(g[0-9]+-)?snap-p[0-9]+-conv-/ && $2 ~ ("^\\[mission\\] SNAPSHOT part=" pn "[^0-9]") && $2 ~ "kind=converged"' | tail -1)
  stamped=$(printf '%s' "$snapline" | sed -n "s/.*tree=\\([A-Za-z0-9_.:-]*\\).*/\\1/p")
  checked=$((checked + 1))
  case "$current" in
    ''|nogit|nohead|nohash)
      echo "drift-check: part=${p} N/A (cannot fingerprint: ${current:-empty})" ;;
    *)
      if [ -n "$stamped" ] && [ "$current" != "$stamped" ]; then
        echo "drift-check: part=${p} DRIFT (stamped=${stamped} current=${current} — re-review before PART-DONE)"
        drift=$((drift + 1))
      else
        echo "drift-check: part=${p} CLEAR (tree matches convergence ${stamped})"
      fi ;;
  esac
done
echo "drift-check: summary parts_checked=${checked} drift=${drift}"
exit 0
