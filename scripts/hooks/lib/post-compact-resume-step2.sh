#!/usr/bin/env bash
# post-compact-resume-step2.sh — extracted from commands/post-compact-resume.md Step 2.
#
# Reads $HOME/.claude/progress/breadcrumb-*.json (R3 D2 per-session breadcrumb) and
# the most-recent CLAUDE.local file in $(pwd) or $REPO_ROOT. Prints a single STATE=...
# line on stdout that the orchestrator routes against the decision matrix in
# commands/post-compact-resume.md.
#
# Usage: bash post-compact-resume-step2.sh
# (Or sourced from a Bash tool call so HANDOFF_PATH etc. are available in scope.)
#
# Source-guard: not re-sourceable; intended to be invoked as a script.

set -uo pipefail

# Source libs for thresholds — use $HOME not ~ for reliable expansion.
# Fail-open if lib missing (use defaults).
. "$HOME/.claude-dotfiles/scripts/hooks/lib/ctx-gate-config.sh" 2>/dev/null
. "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-config.sh" 2>/dev/null
. "$HOME/.claude-dotfiles/scripts/hooks/lib/auto-compact-sentinel.sh" 2>/dev/null
# H1: source marker lib so we delegate to handoff_marker_check / handoff_marker_nonce
# instead of inlining grep/sed (eliminates drift if canonical marker strings change).
. "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-marker.sh" 2>/dev/null

# R3 D2: Per-session breadcrumb written by Stop hook (decoupled from .claim file
# lifecycle which the Stop hook EXIT trap removes). Read the most-recent breadcrumb
# matching this workspace's cwd. PR-1 SID-scoped path, PR-3 hostname check, PR-8
# dual canonical+raw cwd compare, PR-12 filesystem mtime canonical (no JSON mtime).
SENTINEL_SID=""
SENTINEL_NONCE=""
SID8=""
CURRENT_CWD_CANON=$(cd -P "$(pwd)" 2>/dev/null && pwd -P || printf '%s' "$(pwd)")
HOSTNAME_SHORT=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64)

# Glob over per-session breadcrumbs, newest first; pick the first that matches cwd + host.
for BREADCRUMB in $(ls -t "$HOME/.claude/progress/breadcrumb-"*.json 2>/dev/null); do
  [ -f "$BREADCRUMB" ] || continue
  [ -L "$BREADCRUMB" ] && continue  # reject symlinks
  # Ownership + size guard
  [ -O "$BREADCRUMB" ] || continue
  BREAD_SIZE=$(stat -f %z "$BREADCRUMB" 2>/dev/null | tr -d '[:space:]' || stat -c %s "$BREADCRUMB" 2>/dev/null | tr -d '[:space:]' || printf 0)
  [ -z "$BREAD_SIZE" ] && BREAD_SIZE=0
  [ "$BREAD_SIZE" -lt 1024 ] || continue
  # Age guard (PR-2: 1h matches GC TTL)
  BREAD_MTIME=$(stat -f %m "$BREADCRUMB" 2>/dev/null | tr -d '[:space:]' || stat -c %Y "$BREADCRUMB" 2>/dev/null | tr -d '[:space:]' || printf 0)
  [ -z "$BREAD_MTIME" ] && BREAD_MTIME=0
  BREAD_AGE=$(( $(date +%s) - BREAD_MTIME ))
  [ "$BREAD_AGE" -ge 0 ] && [ "$BREAD_AGE" -lt 3600 ] || continue
  # Cwd match (PR-8 dual: canonical OR raw)
  BREAD_CWD=$(jq -r '.cwd // empty' "$BREADCRUMB" 2>/dev/null) || continue
  if [ "$BREAD_CWD" != "$CURRENT_CWD_CANON" ] && [ "$BREAD_CWD" != "$(pwd)" ]; then continue; fi
  # Hostname match (PR-3 iCloud defense)
  BREAD_HOST=$(jq -r '.hostname // empty' "$BREADCRUMB" 2>/dev/null) || continue
  if [ -n "$BREAD_HOST" ] && [ "$BREAD_HOST" != "$HOSTNAME_SHORT" ]; then continue; fi
  # All checks pass — adopt this breadcrumb.
  SENTINEL_SID=$(jq -r '.sid // empty' "$BREADCRUMB" 2>/dev/null)
  SID8=$(jq -r '.sid8 // empty' "$BREADCRUMB" 2>/dev/null)
  SENTINEL_NONCE=$(jq -r '.nonce // empty' "$BREADCRUMB" 2>/dev/null)
  break
done

# Fallback: best-effort .claim.<pid> lookup (will usually fail because Stop hook
# EXIT trap removed it, but harmless to try in unusual lifecycles).
if [ -z "$SENTINEL_SID" ]; then
  CLAIM_FILE=$(ls -t "$HOME/.claude/progress/auto-compact-"*.json.claim.* 2>/dev/null | head -1)
  if [ -n "$CLAIM_FILE" ] && [ -f "$CLAIM_FILE" ]; then
    SENTINEL_SID=$(basename "$CLAIM_FILE" | sed 's/^auto-compact-//; s/\.json\.claim\..*//')
    if [ -n "$SENTINEL_SID" ]; then
      SID8=$(printf '%s' "$SENTINEL_SID" | head -c 8)
      [ -z "$SID8" ] && SID8="$SENTINEL_SID"
      SENTINEL_NONCE=$(jq -r '.marker_nonce // empty' "$CLAIM_FILE" 2>/dev/null) || SENTINEL_NONCE=""
    fi
  fi
fi

# Resolve HANDOFF_PATH: SID-tagged first, then generic alias, then repo root.
HANDOFF_PATH=""
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

try_path() {
  local p="$1"
  [ -z "$p" ] && return 1
  [ -f "$p" ] || return 1
  [ -L "$p" ] && { echo "WARN: skipping symlink at $p" >&2; return 1; }
  HANDOFF_PATH="$p"
  return 0
}

if [ -n "$SID8" ]; then
  try_path "$(pwd)/CLAUDE.local.${SID8}.md" || true
fi
if [ -z "$HANDOFF_PATH" ]; then
  try_path "$(pwd)/CLAUDE.local.md" || true
fi
if [ -z "$HANDOFF_PATH" ] && [ -n "$REPO_ROOT" ]; then
  if [ -n "$SID8" ]; then
    try_path "$REPO_ROOT/CLAUDE.local.${SID8}.md" || true
  fi
  try_path "$REPO_ROOT/CLAUDE.local.md" || true
fi

if [ -z "$HANDOFF_PATH" ]; then
  # Signaling convention: exit 0 here so the orchestrator reads STATE= from stdout
  # and routes accordingly. Non-zero exit would surface as a Bash tool error, not
  # as a routable state signal.
  echo "STATE=no-handoff"
  exit 0
fi

# H11: size check before Read tool ingestion. Reject handoffs larger than HANDOFF_MAX_SIZE_BYTES.
# Oversized files can cause Read tool truncation or unexpected context inflation.
HANDOFF_SIZE=0
if HANDOFF_SIZE=$(stat -f %z "$HANDOFF_PATH" 2>/dev/null | tr -d '[:space:]'); then
  :
elif HANDOFF_SIZE=$(stat -c %s "$HANDOFF_PATH" 2>/dev/null | tr -d '[:space:]'); then
  :
else
  HANDOFF_SIZE=0
fi
[ -z "$HANDOFF_SIZE" ] && HANDOFF_SIZE=0
if [ "$HANDOFF_SIZE" -gt "${HANDOFF_MAX_SIZE_BYTES:-5242880}" ]; then
  echo "STATE=oversize size=$HANDOFF_SIZE max=${HANDOFF_MAX_SIZE_BYTES:-5242880} path=$HANDOFF_PATH"
  exit 0
fi

# Whitespace-strip stat output for bash 3.2 arithmetic safety.
HANDOFF_MTIME=$(stat -f %m "$HANDOFF_PATH" 2>/dev/null | tr -d '[:space:]' || stat -c %Y "$HANDOFF_PATH" 2>/dev/null | tr -d '[:space:]' || printf 0)
[ -z "$HANDOFF_MTIME" ] && HANDOFF_MTIME=0
NOW=$(date +%s)
HANDOFF_AGE=$((NOW - HANDOFF_MTIME))

# STAT_OK guard against false-stale on stat failure
if [ "$HANDOFF_MTIME" -eq 0 ]; then STAT_OK=false; HANDOFF_AGE=0; else STAT_OK=true; fi

CUTOFF="${HANDOFF_LEGACY_CUTOFF_EPOCH:-1779321600}"
if [ "$STAT_OK" = "true" ] && [ "$HANDOFF_MTIME" -lt "$CUTOFF" ]; then LEGACY=true; else LEGACY=false; fi

# Dual-form marker check: match both new form (schema=v1) and legacy form (--).
# Use mktemp only — no PID-predictable /tmp path (fail-closed if mktemp unavailable).
MARKER=absent
TAIL_TMP=$(mktemp -t handoff_tail.XXXXXX 2>/dev/null)
if [ -n "$TAIL_TMP" ]; then
  tail -c 512 "$HANDOFF_PATH" > "$TAIL_TMP" 2>/dev/null
  if grep -qF '<!-- END-OF-HANDOFF schema=v1' "$TAIL_TMP" 2>/dev/null \
     || grep -qF '<!-- END-OF-HANDOFF -->' "$TAIL_TMP" 2>/dev/null; then
    MARKER=present
  fi
  rm -f "$TAIL_TMP"
else
  MARKER=unknown  # mktemp unavailable — treat as unknown, not absent
fi

# Nonce validation: extract nonce from marker and compare with consumed sentinel.
MARKER_NONCE=$(tail -c 512 "$HANDOFF_PATH" 2>/dev/null | sed -nE 's/.*nonce=([a-f0-9-]+).*/\1/p' | head -1)
# SENTINEL_NONCE already populated above by breadcrumb-first lookup (or claim-file fallback).
NONCE_OK="unknown"
if [ -n "$MARKER_NONCE" ] && [ -n "$SENTINEL_NONCE" ]; then
  if [ "$MARKER_NONCE" = "$SENTINEL_NONCE" ]; then NONCE_OK=match; else NONCE_OK=mismatch; fi
fi

STALE_SECS="${HANDOFF_STALE_SECS:-86400}"
if [ "$STAT_OK" = "true" ] && [ "$HANDOFF_AGE" -gt "$STALE_SECS" ]; then STALE=true; else STALE=false; fi

HANDOFF_AGE_HOURS=$((HANDOFF_AGE / 3600))
echo "STATE=ok MARKER=$MARKER LEGACY=$LEGACY STALE=$STALE AGE_HOURS=$HANDOFF_AGE_HOURS NONCE_OK=$NONCE_OK SID8=${SID8:-none} PATH=$HANDOFF_PATH"
