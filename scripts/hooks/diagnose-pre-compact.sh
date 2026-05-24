#!/usr/bin/env bash
# diagnose-pre-compact.sh — operator diagnostic for the /pre-compact + ctx-gate system.
# Prints: hook registration state, last sentinel content, last handoff state,
# CLAUDE_CTX_GATE_DISABLED status, recent log entries from all relevant logs.
#
# Usage: bash ~/.claude-dotfiles/scripts/hooks/diagnose-pre-compact.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/lib/ctx-gate-config.sh" 2>/dev/null || { echo "ERROR: failed to source lib/ctx-gate-config.sh"; exit 1; }
. "$ROOT/lib/auto-compact-sentinel.sh" 2>/dev/null || { echo "ERROR: failed to source lib/auto-compact-sentinel.sh"; exit 1; }
. "$ROOT/lib/handoff-config.sh" 2>/dev/null || { echo "ERROR: failed to source lib/handoff-config.sh"; exit 1; }

echo "=== /pre-compact diagnostic ==="
echo "date: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
echo "host: $(hostname)"
echo "uname: $(uname -srm)"
echo "bash: $BASH_VERSION"
echo

echo "=== Hook registration (~/.claude/settings.json) ==="
if [ -f "$HOME/.claude/settings.json" ]; then
  jq -r '.hooks | to_entries[] | "\(.key): \(.value | length) hook(s)"' "$HOME/.claude/settings.json" 2>/dev/null \
    || echo "ERROR: jq failed to parse settings.json"
  echo
  PRE_TOOL_USE_VAL=$(jq -r '.hooks.PreToolUse // "ABSENT (expected post-R2)"' "$HOME/.claude/settings.json" 2>/dev/null | head -c 50)
  echo "PreToolUse present: $PRE_TOOL_USE_VAL"
else
  echo "WARNING: ~/.claude/settings.json not found"
fi
echo

echo "=== Thresholds (ctx-gate-config + handoff-config) ==="
echo "CTX_SOFT_PCT=${CTX_SOFT_PCT:-unset}"
echo "CTX_IMPORTANT_PCT=${CTX_IMPORTANT_PCT:-unset}"
echo "CTX_FORCE_PCT=${CTX_FORCE_PCT:-unset}"
echo "HANDOFF_STALE_SECS=${HANDOFF_STALE_SECS:-unset}"
CUTOFF_EPOCH="${HANDOFF_LEGACY_CUTOFF_EPOCH:-0}"
CUTOFF_DATE=$(date -u -r "$CUTOFF_EPOCH" +'%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "date-failed")
echo "HANDOFF_LEGACY_CUTOFF_EPOCH=${CUTOFF_EPOCH} ($CUTOFF_DATE)"
echo "HANDOFF_MAX_SIZE_BYTES=${HANDOFF_MAX_SIZE_BYTES:-unset}"
echo "HANDOFF_AUTOCOMPACT_BYPASS_PCT=${HANDOFF_AUTOCOMPACT_BYPASS_PCT:-unset}"
echo "AC_SCHEMA_VERSION=${AC_SCHEMA_VERSION:-unset}"
echo "CLAUDE_CTX_GATE_DISABLED=${CLAUDE_CTX_GATE_DISABLED:-unset}"
echo

echo "=== Sentinels (~/.claude/progress/auto-compact-*.json) ==="
SENTINEL_COUNT=0
for s in "$HOME/.claude/progress/auto-compact-"*.json; do
  [ -f "$s" ] || continue
  SENTINEL_COUNT=$((SENTINEL_COUNT + 1))
  echo "--- $s"
  # Explicit if-elif for BSD/GNU stat compat (B2 pattern).
  if SMTIME=$(stat -f %Sm "$s" 2>/dev/null); then
    :
  elif SMTIME=$(stat -c %y "$s" 2>/dev/null); then
    :
  else
    SMTIME="stat-failed"
  fi
  echo "  mtime: $SMTIME"
  if SSIZE=$(stat -f %z "$s" 2>/dev/null); then
    :
  elif SSIZE=$(stat -c %s "$s" 2>/dev/null); then
    :
  else
    SSIZE="stat-failed"
  fi
  echo "  size: $SSIZE bytes"
  if [ -L "$s" ]; then
    echo "  WARN: symlink — would be rejected by readers"
  else
    jq . "$s" 2>/dev/null | sed 's/^/  /' || echo "  ERROR: jq parse failed"
  fi
done
[ "$SENTINEL_COUNT" = 0 ] && echo "(no sentinels — none armed)"
echo

echo "=== Claim files (consumed sentinels) ==="
CLAIM_COUNT=0
for c in "$HOME/.claude/progress/"auto-compact-*.json.claim.*; do
  [ -f "$c" ] && CLAIM_COUNT=$((CLAIM_COUNT + 1))
done
echo "count: $CLAIM_COUNT (GC at >60min via Stop hook)"
echo

echo "=== Current cwd handoff state ==="
HANDOFF_PATH=""
if [ -f "./CLAUDE.local.md" ]; then
  HANDOFF_PATH="$(pwd)/CLAUDE.local.md"
else
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
  if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/CLAUDE.local.md" ]; then
    HANDOFF_PATH="$REPO_ROOT/CLAUDE.local.md"
  fi
fi
if [ -n "$HANDOFF_PATH" ]; then
  echo "path: $HANDOFF_PATH"
  if HMTIME=$(stat -f %Sm "$HANDOFF_PATH" 2>/dev/null); then
    :
  elif HMTIME=$(stat -c %y "$HANDOFF_PATH" 2>/dev/null); then
    :
  else
    HMTIME="stat-failed"
  fi
  echo "mtime: $HMTIME"
  if HSIZE=$(stat -f %z "$HANDOFF_PATH" 2>/dev/null); then
    :
  elif HSIZE=$(stat -c %s "$HANDOFF_PATH" 2>/dev/null); then
    :
  else
    HSIZE="stat-failed"
  fi
  HLINES=$(wc -l < "$HANDOFF_PATH" 2>/dev/null | tr -d ' ')
  echo "size: $HSIZE bytes / $HLINES lines"
  TAIL=$(tail -c 512 "$HANDOFF_PATH" 2>/dev/null)
  if printf '%s' "$TAIL" | grep -qF '<!-- END-OF-HANDOFF schema=v1'; then
    echo "marker: PRESENT (new schema=v1 form)"
    NONCE=$(printf '%s' "$TAIL" | sed -nE 's/.*nonce=([a-f0-9-]+).*/\1/p')
    echo "  nonce: ${NONCE:-EXTRACT_FAILED}"
  elif printf '%s' "$TAIL" | grep -qF '<!-- END-OF-HANDOFF -->'; then
    echo "marker: PRESENT (legacy form)"
  else
    echo "marker: ABSENT — handoff may be truncated"
  fi
  # SID-tagged files in same dir:
  DIR=$(dirname "$HANDOFF_PATH")
  SID_TAGGED_COUNT=0
  for f in "$DIR"/CLAUDE.local.????????.md; do
    [ -f "$f" ] && SID_TAGGED_COUNT=$((SID_TAGGED_COUNT + 1))
  done
  echo "SID-tagged variants: $SID_TAGGED_COUNT"
  if [ "$SID_TAGGED_COUNT" -gt 0 ]; then
    ls -t "$DIR"/CLAUDE.local.????????.md 2>/dev/null | head -5 | sed 's/^/  /'
  fi
else
  echo "(no CLAUDE.local.md in cwd or repo root)"
fi
echo

echo "=== Breadcrumbs (~/.claude/progress/breadcrumb-*.json) ==="
BREADCRUMB_COUNT=0
BREADCRUMB_LATEST_MTIME="(none)"
BREADCRUMB_LATEST_HOST="(none)"
for b in "$HOME/.claude/progress/breadcrumb-"*.json; do
  [ -f "$b" ] || continue
  BREADCRUMB_COUNT=$((BREADCRUMB_COUNT + 1))
  if BMTIME=$(stat -f %Sm "$b" 2>/dev/null); then
    :
  elif BMTIME=$(stat -c %y "$b" 2>/dev/null); then
    :
  else
    BMTIME="stat-failed"
  fi
  BREADCRUMB_LATEST_MTIME="$BMTIME"
  BREADCRUMB_LATEST_HOST=$(jq -r '.hostname // "no-hostname-field"' "$b" 2>/dev/null)
done
echo "count: $BREADCRUMB_COUNT"
echo "latest mtime: $BREADCRUMB_LATEST_MTIME"
echo "latest hostname: $BREADCRUMB_LATEST_HOST"
# Verify step2.sh exists at new D9 path (post-compact-resume-step2.sh, no longer in lib/)
STEP2_PATH="$ROOT/post-compact-resume-step2.sh"
if [ -x "$STEP2_PATH" ]; then
  echo "step2.sh: PRESENT + executable at $STEP2_PATH"
elif [ -f "$STEP2_PATH" ]; then
  echo "step2.sh: PRESENT but NOT executable at $STEP2_PATH (run: chmod +x $STEP2_PATH)"
else
  echo "step2.sh: MISSING at $STEP2_PATH"
fi
echo "--- Recent breadcrumb log entries (grep from auto-compact.log):"
if [ -f "$HOME/.claude/logs/auto-compact.log" ]; then
  grep -i 'breadcrumb' "$HOME/.claude/logs/auto-compact.log" 2>/dev/null | tail -10 | sed 's/^/  /' \
    || echo "  (no breadcrumb log entries)"
else
  echo "  (auto-compact.log not found)"
fi
echo

echo "=== Recent log entries (last 20) ==="
for log in "$HOME/.claude/logs/auto-compact.log" "$HOME/.claude/logs/ctx-gate.log"; do
  if [ -f "$log" ]; then
    echo "--- $log (last 20):"
    tail -20 "$log" 2>/dev/null | sed 's/^/  /'
  fi
done
echo

echo "=== Done. ==="
