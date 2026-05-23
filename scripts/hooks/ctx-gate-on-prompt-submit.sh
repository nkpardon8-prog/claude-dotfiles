#!/usr/bin/env bash
# ctx-gate-on-prompt-submit.sh — UserPromptSubmit hook: soft + hard zone advisory.
#
# Soft zone (70–90%): emits additionalContext advising the model to wrap at a natural seam.
# Hard zone (≥90%):   emits additionalContext with strong directive to invoke Skill(pre-compact).
#
# NEVER uses `decision: block` — that would erase the user's prompt. Only additionalContext.
# Fail-open on any error (exits 0, no output) so a buggy gate never breaks the user's prompt.

set -uo pipefail

[ "${CLAUDE_CTX_GATE_DISABLED:-0}" = "1" ] && exit 0  # kill-switch per Round 3 A #12 / B #7

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/ctx-gate-config.sh
. "$ROOT/lib/ctx-gate-config.sh"
# shellcheck source=lib/auto-compact-sentinel.sh
. "$ROOT/lib/auto-compact-sentinel.sh"

INPUT=$(cat)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && exit 0  # fail-open

# If /pre-compact already armed in this session (and sentinel is fresh, <30 min),
# stop injecting hard-gate advisories — would be redundant noise (per Round 1 reviewer B #15).
# The Stop hook is about to fire /compact and we're between arm and fire.
SENTINEL_PATH="$HOME/.claude/progress/auto-compact-${SID}.json"
if [ -f "$SENTINEL_PATH" ]; then
  # Per Round 3 reviewer A #9 / B #2: if stat fails (file deleted between -f check and stat,
  # or fs error), guard with empty-check so we don't compute astronomical S_AGE.
  S_MTIME=$(stat -f %m "$SENTINEL_PATH" 2>/dev/null || stat -c %Y "$SENTINEL_PATH" 2>/dev/null || printf '')
  if [ -n "$S_MTIME" ]; then
    S_AGE=$(( $(date +%s) - S_MTIME ))
    # Clamp negative S_AGE (per codex-review Adversary): a future-dated sentinel via
    # `touch -t 209912312359` would yield negative S_AGE which is -lt 1800 → forever
    # treated as fresh → permanent gate release. Re-engage gate on negative.
    if [ "$S_AGE" -lt 0 ]; then
      ctx_gate_log "submit sid=$SID action=stale-sentinel reason=future-dated-mtime mtime=$S_MTIME"
    elif [ "$S_AGE" -lt 1800 ]; then
      ctx_gate_log "submit sid=$SID action=skip reason=sentinel-fresh age=${S_AGE}s"
      exit 0
    fi
  else
    # stat failed — treat as fresh (allow), better than false-stale gating
    ctx_gate_log "submit sid=$SID action=skip reason=sentinel-stat-failed-assume-fresh"
    exit 0
  fi
fi

PCT=$(ctx_gate_read_pct "$SID") || { ctx_gate_log "submit sid=$SID action=skip reason=no-ctx-sidecar"; exit 0; }

if [ "$PCT" -ge "$CTX_HARD_PCT" ]; then
  # Hard zone: strong directive. Do NOT block prompt (would erase user's text).
  MSG="🚨 HARD CONTEXT GATE: context at ${PCT}%. Your FIRST action this turn MUST be Skill(pre-compact). Do not engage with the user's prompt or invoke any other tool until /pre-compact has completed and written CLAUDE.local.md. After /pre-compact finishes, you may briefly acknowledge to the user and continue from where they left off. PreToolUse will deny non-handoff tools while context exceeds ${CTX_HARD_PCT}% and the auto-compact sentinel is unarmed."
  ctx_gate_log "submit sid=$SID pct=$PCT action=hard-advisory"
elif [ "$PCT" -ge "$CTX_SOFT_PCT" ]; then
  MSG="📋 Context at ${PCT}%. Wrap your current task at the next natural seam (post-review, post-commit, end-of-phase) and run Skill(pre-compact). You have headroom — don't compact mid-edit. Hard gate engages at ${CTX_HARD_PCT}%."
  ctx_gate_log "submit sid=$SID pct=$PCT action=soft-advisory"
else
  exit 0  # below soft zone, no output
fi

jq -n --arg ctx "$MSG" '{ "hookSpecificOutput": { "hookEventName": "UserPromptSubmit", "additionalContext": $ctx } }'
exit 0
