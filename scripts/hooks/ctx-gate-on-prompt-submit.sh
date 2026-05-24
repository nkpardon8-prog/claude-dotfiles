#!/usr/bin/env bash
# ctx-gate-on-prompt-submit.sh — UserPromptSubmit hook: three-tier context nudge.
#
# Execution context: this is a Claude Code UserPromptSubmit hook script.
# It runs as a direct subprocess of Claude Code, NOT through the orchestrator Bash tool.
#
# Threshold model (R2 redesign — N4 locked decision):
#   <50%  → silent (no output)
#   50-74% → SOFT nudge (consider /pre-compact at next natural seam)
#   75-84% → IMPORTANT nudge (finish current task, then invoke /pre-compact)
#   ≥85%   → FORCE nudge (FIRST action MUST be Skill(pre-compact) — context-critical)
#
# NEVER uses `permissionDecision: deny` or `decision: block`.
# Only additionalContext. Fail-open on any error so a buggy gate never breaks prompts.
#
# FORCE (≥85%) overrides sentinel-fresh skip — operator must see context-critical alerts.
# SOFT and IMPORTANT respect sentinel-fresh skip (already ran /pre-compact; no noise).

set -uo pipefail

[ "${CLAUDE_CTX_GATE_DISABLED:-0}" = "1" ] && exit 0  # kill-switch

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/ctx-gate-config.sh
. "$ROOT/lib/ctx-gate-config.sh"
# shellcheck source=lib/auto-compact-sentinel.sh
. "$ROOT/lib/auto-compact-sentinel.sh"

INPUT=$(head -c 1048576)  # bound stdin to 1MB (DoS guard)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && exit 0  # fail-open

PCT=$(ctx_gate_read_pct "$SID") || { ctx_gate_log "submit sid=$SID action=skip reason=no-ctx-sidecar"; exit 0; }

# FORCE check FIRST (≥85%) — overrides sentinel-fresh skip so the operator sees
# context-critical alerts even after /pre-compact has armed.
# At this level the model MUST invoke /pre-compact before anything else.
if [ "$PCT" -ge "$CTX_FORCE_PCT" ]; then
  MSG="WRAP-UP & HAND-OFF ZONE: context at ${PCT}%. Native auto-compact fires at ~95% and will destroy this session WITHOUT writing CLAUDE.local.md. Your FIRST action this turn MUST be Skill(pre-compact). Do not engage with the user's prompt or invoke any other tool until /pre-compact has completed."
  ctx_gate_log "submit sid=$SID pct=$PCT action=force-wrapup"
  jq -n --arg ctx "$MSG" '{ "hookSpecificOutput": { "hookEventName": "UserPromptSubmit", "additionalContext": $ctx } }'
  exit 0
fi

# Sentinel-fresh skip for SOFT and IMPORTANT only (already ran /pre-compact; avoid noise).
# Per codex-review R2 F15: reject symlinks (same-UID attacker could swap sentinel to a
# file with attacker-controlled mtime to forge "fresh" status).
SENTINEL_PATH="$HOME/.claude/progress/auto-compact-${SID}.json"
if [ -L "$SENTINEL_PATH" ]; then
  ctx_gate_log "submit sid=$SID action=reject-symlink-sentinel"
elif [ -f "$SENTINEL_PATH" ]; then
  # If stat fails (file deleted between -f check and stat, or fs error),
  # guard with empty-check so we don't compute astronomical S_AGE.
  S_MTIME=$(stat -f %m "$SENTINEL_PATH" 2>/dev/null || stat -c %Y "$SENTINEL_PATH" 2>/dev/null || printf '')
  if [ -n "$S_MTIME" ]; then
    S_AGE=$(( $(date +%s) - S_MTIME ))
    # Clamp negative S_AGE: a future-dated sentinel would yield negative S_AGE
    # which is -lt 1800 and would be forever treated as fresh. Re-engage on negative.
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

# IMPORTANT (75-84%): finish current task then /pre-compact before starting anything new.
if [ "$PCT" -ge "$CTX_IMPORTANT_PCT" ]; then
  MSG="Context at ${PCT}% — IMPORTANT zone. Finish the current task, then invoke Skill(pre-compact) before starting anything new. The 85% FORCE threshold is approaching."
  ctx_gate_log "submit sid=$SID pct=$PCT action=important-nudge"
# SOFT (50-74%): gentle reminder at next natural seam.
elif [ "$PCT" -ge "$CTX_SOFT_PCT" ]; then
  MSG="Context at ${PCT}% — soft-zone reminder. Consider running Skill(pre-compact) at the next natural seam (post-review, post-commit, end-of-phase). No action required mid-task."
  ctx_gate_log "submit sid=$SID pct=$PCT action=soft-nudge"
else
  exit 0  # below soft zone, no output
fi

jq -n --arg ctx "$MSG" '{ "hookSpecificOutput": { "hookEventName": "UserPromptSubmit", "additionalContext": $ctx } }'
exit 0
