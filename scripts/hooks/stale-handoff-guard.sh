#!/bin/bash
# stale-handoff-guard.sh — non-async SessionStart hook (registered AFTER post-compact-primer.sh).
#
# Kills the stale-handoff defect class at its chokepoint (the 2026-07-07 transcript audit's #1
# finding: a May-29 un-tagged CLAUDE.local.md silently re-ingested for weeks):
#   1. Quarantines an un-tagged CLAUDE.local.md at the repo's canonical root ONLY when it is
#      handoff-SHAPED (END-OF-HANDOFF marker or "# Post-Compact Reference" header) AND >7 days
#      old. Hand-authored project-instruction files (no handoff fingerprint) are NEVER touched.
#   2. GCs SID-tagged handoffs (CLAUDE.local.<sid>.md) older than 30 days — EXCEPT the current
#      session's (sid from the SessionStart stdin JSON).
#   3. Warns when the project's MEMORY.md approaches the injection cliff (>90 entries or >150 lines).
#
# Posture: fail-open everywhere (any missing dependency/parse failure => exit 0, silent).
# Quarantine = move (a warning already failed once); archive names are collision-proof.
# stdout is INJECTED into session context (non-async) — stay silent unless something happened.

HOOK_JSON=$(cat)
cwd=$(jq -r '.cwd // empty' <<<"$HOOK_JSON" 2>/dev/null)
sid=$(jq -r '.session_id // empty' <<<"$HOOK_JSON" 2>/dev/null | tr -cd 'A-Za-z0-9_-' | head -c 128)
cd "${cwd:-$PWD}" 2>/dev/null || exit 0

. "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-locate.sh" 2>/dev/null || exit 0
root=$(handoff_canonical_root 2>/dev/null) || exit 0
[ -n "$root" ] || exit 0
# Non-repo cwd fallback must NEVER quarantine (handoff_canonical_root falls back to cwd outside git).
git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# --- 1. Un-tagged CLAUDE.local.md: quarantine only handoff-shaped AND >7d old ---
f="$root/CLAUDE.local.md"
if [ -f "$f" ] && [ ! -L "$f" ] && grep -qE 'END-OF-HANDOFF|^# Post-Compact Reference' "$f" 2>/dev/null; then
  # stat -f %m is BSD/macOS; stat -c %Y is GNU/Linux. Try each SEPARATELY and validate the result is
  # a pure integer before accepting it — on GNU, `stat -f` means --file-system and can print
  # non-numeric data yet exit 0, which a naive `A || B` would wrongly accept (codex-review 2026-07-12).
  mtime=$(stat -f %m "$f" 2>/dev/null)
  case "$mtime" in ''|*[!0-9]*) mtime=$(stat -c %Y "$f" 2>/dev/null) ;; esac
  case "$mtime" in ''|*[!0-9]*) mtime="" ;; esac
  # Quarantine ONLY with a usable numeric mtime that proves age >7d. No usable mtime → leave the
  # file in place (do NOT default to now: age 0 would silently keep a stale handoff; and never
  # quarantine on an unprovable age).
  if [ -n "$mtime" ]; then
    age=$(( $(date +%s) - mtime ))
    if [ "$age" -gt 604800 ]; then
      mkdir -p "$root/.handoff-archive" \
        && mv "$f" "$root/.handoff-archive/CLAUDE.local.stale-$(date +%Y%m%d-%H%M%S)-$$.md" \
        && echo "stale-handoff-guard: QUARANTINED stale handoff CLAUDE.local.md (age $((age/86400))d) -> .handoff-archive/ (hand-authored files are never touched; restore from the archive if this was wrong)"
    fi
  fi
fi   # hand-authored (no handoff fingerprint) -> NEVER touched

# --- 2. GC SID-tagged handoffs >30d, sparing the current session's ---
find "$root" -maxdepth 1 -name 'CLAUDE.local.*.md' ! -name "CLAUDE.local.${sid:-none}.md" -type f -mtime +30 \
  -exec sh -c 'arch=$1; f=$2; mkdir -p "$arch"; mv -- "$f" "$arch/$(basename "$f").$(date +%s)"' sh "$root/.handoff-archive" {} \; 2>/dev/null

# --- 2b. Surface a paused dotfiles auto-sync (criticer 2026-07-12: the out-of-repo marker is
#         invisible to git status; without this notice, local dotfiles commits silently strand) ---
if [ -f "$HOME/.claude/.dotfiles-sync-paused" ]; then
  behind=$(git -C "$HOME/.claude-dotfiles" log --oneline @{u}..HEAD 2>/dev/null | wc -l | tr -d ' ')
  echo "stale-handoff-guard: NOTE — dotfiles auto-sync is PAUSED (~/.claude/.dotfiles-sync-paused present; ${behind:-?} unpushed commit(s)). Remove the marker + run dotfiles-sync.sh when the hold is over."
fi

# --- 3. MEMORY.md injection-cliff warning ---
mem="$HOME/.claude/projects/$(printf '%s' "$root" | tr '/.' '--')/memory/MEMORY.md"
if [ -f "$mem" ]; then
  # NOTE: `grep -c` PRINTS 0 and EXITS 1 on no-match, so `grep -c … || echo 0` yields "0\n0" which
  # breaks the numeric test below. Take grep's stdout as-is and default only a truly empty capture.
  n=$(grep -c '^- \[' "$mem" 2>/dev/null); n=${n:-0}
  l=$(wc -l < "$mem" 2>/dev/null | tr -d ' '); l=${l:-0}
  if [ "$n" -gt 90 ] || [ "$l" -gt 150 ]; then
    echo "stale-handoff-guard: MEMORY.md at $n entries/$l lines — approaching the 200-line injection cliff (archive DONE entries to MEMORY-archive.md)"
  fi
fi
exit 0
