#!/usr/bin/env bash
# SessionStart cleanup — removes progress files older than 7 days.
mkdir -p "$HOME/.claude/progress" 2>/dev/null
chmod 700 "$HOME/.claude/progress" 2>/dev/null
find "$HOME/.claude/progress" -type f -mtime +7 -delete 2>/dev/null
# Prune stale auto-compact sentinels (and abandoned claim files) older than 720 minutes (12h).
# Covers cases where /pre-compact armed auto-compact but Terminal was killed, or the user
# walked away for an afternoon before the Stop hook fired. 12h is the realistic
# "I'll be back later today" upper bound; shorter would race against long sessions.
find "$HOME/.claude/progress" -maxdepth 1 \( -name 'auto-compact-*.json' -o -name 'auto-compact-*.json.claim.*' -o -name 'pre-compact-parent-*.json' \) -mmin +720 -delete 2>/dev/null || true
# R7-INC-03 (F3): GC stale PID-keyed pre-compact scratch files (>720 min / 12h old).
# Scratch files are normally removed by Step 9.1 (orchestrator self-cleanup) or by the
# Stop hook (if PRECOMPACT_PID is exported). The 720-min GC here is a final safety net
# covering cases where /pre-compact was killed before Step 9.1 ran.
find "$HOME/.claude/progress" -maxdepth 1 -name 'pre-compact-scratch-*.json' -mmin +720 -delete 2>/dev/null || true
# GC codex-review run dirs older than 24h (1440 min). codex-review.md creates one per run via
# `mktemp -d "${TMPDIR:-/tmp}/codex-review.XXXXXX"` and (as of the 7e cleanup removal) no longer
# deletes it at skill end — it now holds report-final.md for downstream consumers (e.g. /mission
# reads the `Report-file:` line AFTER the skill returns), so cleanup is deferred here. These are
# directories with contents, so `rm -rf` (not `-delete`) does the removal; an actively-used dir keeps
# a fresh mtime and is never swept.
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'codex-review.*' -mmin +1440 -exec rm -rf {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# Parallelizer wave machinery (commands/implement.md wave mode; shapes frozen in
# docs/wave-plan-schema.md). Two sweeps + one throttled measurement run, all fail-open.
# NEVER swept, at any age: parallel-waves/rework.log (the measurement record every
# parallelism claim rests on) and the replay-*.txt outputs.
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.claude/parallel-waves" 2>/dev/null

# (a1) Dead wave-state files: >7 days old AND none of the worktrees they record still
# exists on disk. A state file whose worktrees survive is a RECOVERABLE wave (implement.md's
# stale-wave gate prints its two recovery commands), so age alone never justifies deleting
# it. An unparseable state file is left alone on purpose - merge-wave.sh refuses loudly on
# corruption, and silently deleting the evidence would hide that.
find "$HOME/.claude/parallel-waves" -maxdepth 1 -type f -name '*-w*.json' -mtime +7 2>/dev/null | while IFS= read -r _st; do
  python3 -c 'import json, os, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
paths = [c.get("worktree") for c in doc.get("chunks", []) if isinstance(c, dict)]
sys.exit(1 if any(p and os.path.isdir(p) for p in paths) else 0)' "$_st" 2>/dev/null && rm -f "$_st" 2>/dev/null
done || true

# (a2) Orphaned wave worktrees: >7 days old with NO surviving wave-state referencing them
# (substring match on the absolute path is exactly how the state file stores it). Removal
# ORDER is inverted vs. the plan sketch on purpose, because git enforces it: `worktree prune`
# only drops entries whose working tree is already GONE, and `branch -D` refuses a branch that
# is still checked out in a registered worktree. So: rm -rf the tree, prune the registration,
# then delete this session's w<W>-<SID8>-<chunk> branches.
find "$HOME/.claude/wave-worktrees" -mindepth 1 -maxdepth 1 -type d -mtime +7 2>/dev/null | while IFS= read -r _wt; do
  grep -lF -- "$_wt" "$HOME"/.claude/parallel-waves/*-w*.json >/dev/null 2>&1 && continue
  _sid8=$(basename "$_wt")
  _root=""
  [ -f "$_wt/.repo-root" ] && _root=$(head -n 1 "$_wt/.repo-root" 2>/dev/null)
  rm -rf "$_wt" 2>/dev/null
  if [ -n "$_root" ] && [ -e "$_root/.git" ]; then
    git -C "$_root" worktree prune 2>/dev/null || true
    git -C "$_root" for-each-ref --format='%(refname:short)' "refs/heads/w*-$_sid8-*" 2>/dev/null | while IFS= read -r _br; do
      git -C "$_root" branch -D "$_br" >/dev/null 2>&1 || true
    done
  else
    # No breadcrumb: the tree is gone but its repo cannot be identified, so the stale worktree
    # registration and branches survive in some unknown repo. Record it rather than pretend.
    printf '%s orphan wave-worktrees dir removed with no .repo-root breadcrumb: %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_wt" >> "$HOME/.claude/parallel-waves/sweep.log" 2>/dev/null || true
  fi
done || true

# (b) Weekly transcript replay (Divergence 2: layer-2 telemetry accrues by mechanism, no
# ambient nudging). Throttle is keyed on a COMPLETION marker, never on the output's mtime -
# a killed or timed-out run must not suppress the next attempt. Bounded three ways: the 10
# newest top-level transcripts of the newest project dir, a 45s pt_run cap, and tmp->mv so a
# partial run never overwrites the last good output.
_PW="$HOME/.claude/parallel-waves"
_MARK="$_PW/replay-last-success"
if [ ! -f "$_MARK" ] || [ -n "$(find "$_MARK" -mtime +7 2>/dev/null)" ]; then
  _PROJ=""
  for _d in $(ls -dt "$HOME"/.claude/projects/*/ 2>/dev/null); do
    if ls "$_d"*.jsonl >/dev/null 2>&1; then _PROJ="$_d"; break; fi
  done
  if [ -n "$_PROJ" ]; then
    _FILES=()
    while IFS= read -r _f; do _FILES+=("$_f"); done < <(ls -t "$_PROJ"*.jsonl 2>/dev/null | head -10)
    if [ "${#_FILES[@]}" -gt 0 ]; then
      # shellcheck source=/dev/null
      . "$HOME/.claude-dotfiles/scripts/lib/portable-timeout.sh" 2>/dev/null || true
      if declare -F pt_run >/dev/null 2>&1; then
        pt_run 45 python3 "$HOME/.claude-dotfiles/scripts/parallel-stats.py" --replay "${_FILES[@]}" \
          > "$_PW/replay-latest.txt.tmp" 2>/dev/null \
          && mv -f "$_PW/replay-latest.txt.tmp" "$_PW/replay-latest.txt" 2>/dev/null \
          && touch "$_MARK" 2>/dev/null
      else
        # No pt_run helper on this machine (macOS has no `timeout`): run uncapped but with the
        # transcript count already bounded to 10 above.
        python3 "$HOME/.claude-dotfiles/scripts/parallel-stats.py" --replay "${_FILES[@]}" \
          > "$_PW/replay-latest.txt.tmp" 2>/dev/null \
          && mv -f "$_PW/replay-latest.txt.tmp" "$_PW/replay-latest.txt" 2>/dev/null \
          && touch "$_MARK" 2>/dev/null
      fi
      rm -f "$_PW/replay-latest.txt.tmp" 2>/dev/null || true
    fi
  fi
fi || true

exit 0
