#!/usr/bin/env bash
# ctx-gate-on-prompt-submit.sh — UserPromptSubmit hook: three-tier context nudge.
#
# Execution context: this is a Claude Code UserPromptSubmit hook script.
# It runs as a direct subprocess of Claude Code, NOT through the orchestrator Bash tool.
#
# Threshold model (2026-05-28 tuning — code-quality-first):
#   <50%   → silent (no output)
#   50-64% → SOFT nudge (seam-opportunistic; checkpoint at a natural seam, don't interrupt mid-task)
#   65-74% → IMPORTANT nudge (finish current task, then invoke /pre-compact)
#   ≥75%   → FORCE nudge (FIRST action MUST be Skill(pre-compact) — context-critical)
#
# **Zone-bucket rate-limit (2026-05-28):** SOFT and IMPORTANT fire only when the 5% bucket
# changes (50/55/60/65/70 etc.), not on every user prompt. FORCE always fires every turn
# (action-required; persistent reminder is correct). Marker file at
# `~/.claude/progress/.ctx-zone-bucket-<sid>` records the last bucket the hook fired in;
# per-session, GC'd by the existing 720-min cleanup glob on `~/.claude/progress/`.
#
# NEVER uses `permissionDecision: deny` or `decision: block`.
# Only additionalContext. Fail-open on any error so a buggy gate never breaks prompts.
#
# FORCE overrides sentinel-fresh skip AND the bucket rate-limit — operator must see
# context-critical alerts on every turn. SOFT and IMPORTANT respect sentinel-fresh skip
# (already ran /pre-compact; no noise) AND the bucket rate-limit.

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

# FORCE check FIRST (≥75% per 2026-05-28 tuning, was 85%) — overrides sentinel-fresh skip so the operator sees
# context-critical alerts even after /pre-compact has armed.
# At this level the model MUST invoke /pre-compact before anything else.
if [ "$PCT" -ge "$CTX_FORCE_PCT" ]; then
  # R5 H3: updated wording — removed reference to CLAUDE.local.md alias (dead post-R4 D1);
  # /pre-compact now writes a SID-tagged file (CLAUDE.local.<sid8>.md) as the ONLY output.
  MSG="WRAP-UP & HAND-OFF ZONE: context at ${PCT}%. Native auto-compact fires at ~95% and will destroy this session WITHOUT writing a handoff file. Your FIRST action this turn MUST be Skill(pre-compact). Do not engage with the user's prompt or invoke any other tool until /pre-compact has completed."
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

# Below SOFT zone → silent (the most common case; emit nothing).
if [ "$PCT" -lt "$CTX_SOFT_PCT" ]; then
  exit 0
fi

# Zone-bucket rate-limit (SOFT + IMPORTANT only; FORCE already returned above).
# Fire only when the 5% bucket changes. This collapses ~30 SOFT pings during a long
# 50-64% stretch into ~3 (50/55/60), and keeps IMPORTANT to ~2 (65/70). Bucket = PCT/5;
# marker stores the last bucket fired. If current != last → fire + update. This handles
# both forward progress (climbing ctx) and resets (post-compact drops bucket below last).
BUCKET=$((PCT / 5))
BUCKET_FILE="$HOME/.claude/progress/.ctx-zone-bucket-${SID}"
LAST_BUCKET=""
if [ -f "$BUCKET_FILE" ]; then
  LAST_BUCKET=$(tr -cd '0-9' < "$BUCKET_FILE" 2>/dev/null | head -c 4)
fi
if [ "$BUCKET" = "$LAST_BUCKET" ]; then
  ctx_gate_log "submit sid=$SID pct=$PCT bucket=$BUCKET action=skip reason=same-bucket-as-last"
  exit 0
fi
# Bucket changed (forward or reset) — record the new one and fall through to fire.
mkdir -p "$HOME/.claude/progress" 2>/dev/null && chmod 700 "$HOME/.claude/progress" 2>/dev/null || true
printf '%s\n' "$BUCKET" > "$BUCKET_FILE" 2>/dev/null || true

# IMPORTANT zone: finish current task then /pre-compact before starting anything new.
if [ "$PCT" -ge "$CTX_IMPORTANT_PCT" ]; then
  MSG="Context at ${PCT}% — IMPORTANT zone. Finish the current task, then invoke Skill(pre-compact) before starting anything new. The ${CTX_FORCE_PCT}% FORCE threshold is approaching."
  ctx_gate_log "submit sid=$SID pct=$PCT bucket=$BUCKET action=important-nudge"
# SOFT zone: FYI reminder; the agent should NOT interrupt active work for this.
else
  MSG="Context at ${PCT}% — soft-zone reminder (FYI). Consider running Skill(pre-compact) at the next natural seam (post-review, post-commit, end-of-phase). Do NOT interrupt active work for this message; do not surface ctx % to the user; do not start /pre-compact in response. Act only on IMPORTANT or FORCE."
  ctx_gate_log "submit sid=$SID pct=$PCT bucket=$BUCKET action=soft-nudge"
fi

jq -n --arg ctx "$MSG" '{ "hookSpecificOutput": { "hookEventName": "UserPromptSubmit", "additionalContext": $ctx } }'
exit 0
