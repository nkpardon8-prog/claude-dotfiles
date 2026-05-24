#!/usr/bin/env bash
# post-compact-primer-helpers.sh — helper functions for post-compact-primer.sh.
# Extracted to keep the primer body lean (orchestration + source-routing only).
#
# Execution context: sourced by post-compact-primer.sh, which runs as a direct
# subprocess of Claude Code (SessionStart hook). Not subject to orchestrator
# Bash tool restrictions.
#
# Source-guard: second sourcing is a no-op.
[ -n "${_POST_COMPACT_PRIMER_HELPERS_LOADED:-}" ] && return 0
readonly _POST_COMPACT_PRIMER_HELPERS_LOADED=1

# Dependencies sourced by the caller (post-compact-primer.sh) before sourcing this lib:
#   lib/ctx-gate-config.sh  — ctx_gate_log
#   lib/auto-compact-sentinel.sh — ac_log, ac_canonicalize_path, ac_read_sentinel_cwd
#   lib/handoff-config.sh   — HANDOFF_STALE_SECS, HANDOFF_LEGACY_CUTOFF_EPOCH, HANDOFF_MAX_SIZE_BYTES
#   lib/handoff-marker.sh   — handoff_marker_check

# ---------------------------------------------------------------------------
# primer_resolve_handoff_path <cwd>
#
# Given the session cwd, resolves the handoff file path.
# R3 D6: prefers SID-tagged file (CLAUDE.local.<sid8>.md) when SENTINEL_SID8 is known.
# SENTINEL_SID8 is set by primer_find_sentinel_for_cwd — that function MUST run first.
# Sets HANDOFF_PATH (global) on success; leaves it empty if not found.
# Returns 0 on success, 1 if no handoff file found.
# ---------------------------------------------------------------------------
primer_resolve_handoff_path() {
  local cwd="$1"
  HANDOFF_PATH=""

  # R3 D6: prefer SID-tagged file if sentinel SID is known.
  # SENTINEL_SID8 is set by primer_find_sentinel_for_cwd (must run BEFORE this function).
  if [ -n "${SENTINEL_SID8:-}" ]; then
    if [ -f "$cwd/CLAUDE.local.${SENTINEL_SID8}.md" ] && [ ! -L "$cwd/CLAUDE.local.${SENTINEL_SID8}.md" ]; then
      HANDOFF_PATH="$cwd/CLAUDE.local.${SENTINEL_SID8}.md"
      return 0
    fi
    local repo_root
    repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || repo_root=""
    if [ -n "$repo_root" ] && [ -f "$repo_root/CLAUDE.local.${SENTINEL_SID8}.md" ] && [ ! -L "$repo_root/CLAUDE.local.${SENTINEL_SID8}.md" ]; then
      HANDOFF_PATH="$repo_root/CLAUDE.local.${SENTINEL_SID8}.md"
      return 0
    fi
    # PR-11: SID known but no SID-tagged file found — log explicit warning before falling through.
    ctx_gate_log "primer warn reason=sentinel-without-sid-file sid=${SENTINEL_SID8}"
  fi

  # Fall back to generic alias.
  if [ -f "$cwd/CLAUDE.local.md" ] && [ ! -L "$cwd/CLAUDE.local.md" ]; then
    HANDOFF_PATH="$cwd/CLAUDE.local.md"
    return 0
  fi
  local repo_root2
  repo_root2=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || repo_root2=""
  if [ -n "$repo_root2" ] && [ -f "$repo_root2/CLAUDE.local.md" ] && [ ! -L "$repo_root2/CLAUDE.local.md" ]; then
    HANDOFF_PATH="$repo_root2/CLAUDE.local.md"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# primer_check_marker <file>
#
# Checks for END-OF-HANDOFF marker (new or legacy form) in the last 512 bytes.
# Sets MARKER_PRESENT ("true" or "false") globally.
# ---------------------------------------------------------------------------
primer_check_marker() {
  local file="$1"
  MARKER_PRESENT="true"
  local tail_buf
  tail_buf=$(tail -c 512 "$file" 2>/dev/null)
  local marker_new='<!-- END-OF-HANDOFF schema=v1'
  local marker_legacy='<!-- END-OF-HANDOFF -->'
  if ! { printf '%s' "$tail_buf" | grep -qF "$marker_new" || printf '%s' "$tail_buf" | grep -qF "$marker_legacy"; }; then
    MARKER_PRESENT="false"
  fi
}

# ---------------------------------------------------------------------------
# primer_check_freshness <file>
#
# Checks handoff file mtime for staleness.
# Sets HANDOFF_MTIME, HANDOFF_AGE, STAT_OK, LEGACY, STALE_WARNING globally.
# Requires HANDOFF_STALE_SECS and HANDOFF_LEGACY_CUTOFF_EPOCH to be set.
# ---------------------------------------------------------------------------
primer_check_freshness() {
  local file="$1" sid="${2:-unknown}"
  # B2 fix: explicit if-elif for stat (no || chaining — macOS BSD stat short-circuits).
  if HANDOFF_MTIME=$(stat -f %m "$file" 2>/dev/null); then
    :
  elif HANDOFF_MTIME=$(stat -c %Y "$file" 2>/dev/null); then
    :
  else
    HANDOFF_MTIME=0
  fi
  HANDOFF_MTIME=$(printf '%s' "$HANDOFF_MTIME" | tr -d '[:space:]')
  [ -z "$HANDOFF_MTIME" ] && HANDOFF_MTIME=0
  local now
  now=$(date +%s)
  HANDOFF_AGE=$((now - HANDOFF_MTIME))

  # Guard: stat failure (HANDOFF_MTIME=0) produces a ~57-year false-positive age.
  STAT_OK="true"
  if [ "$HANDOFF_MTIME" -eq 0 ]; then
    STAT_OK="false"
    HANDOFF_AGE=0
    ctx_gate_log "primer sid=${sid} action=stat-failed-mtime-zero stale-check-skipped"
  fi

  LEGACY="false"
  if [ "$STAT_OK" = "true" ] && [ "$HANDOFF_MTIME" -lt "${HANDOFF_LEGACY_CUTOFF_EPOCH:-1779321600}" ]; then
    LEGACY="true"
  fi

  STALE_WARNING=""
  if [ "$STAT_OK" = "true" ] && [ "$HANDOFF_AGE" -gt "${HANDOFF_STALE_SECS:-86400}" ]; then
    local age_human
    age_human=$((HANDOFF_AGE / 3600))
    STALE_WARNING="WARNING STALE HANDOFF — predates this session by ~${age_human}h; it may be from a prior conversation. Verify with the user before resuming."$'\n\n'
  fi
}

# ---------------------------------------------------------------------------
# primer_find_sentinel_for_cwd <cwd_canon>
#
# Scans $HOME/.claude/progress/ for a sentinel matching the given canonical cwd.
# Sets SENTINEL_PRESENT, SENTINEL_PATH, SENTINEL_SID8, SENTINEL_NONCE globally.
# ---------------------------------------------------------------------------
primer_find_sentinel_for_cwd() {
  local cwd_canon="$1"
  SENTINEL_PRESENT="false"
  SENTINEL_PATH=""
  SENTINEL_SID8=""
  SENTINEL_NONCE=""

  local sentinel_candidate
  for sentinel_candidate in "$HOME/.claude/progress/auto-compact-"*.json; do
    [ -f "$sentinel_candidate" ] || continue
    local sent_cwd
    # Schema-validating reader: symlink rejection, size cap, schema_version check.
    # Legacy sentinels (no cwd field) → skip via continue.
    sent_cwd=$(ac_read_sentinel_cwd "$sentinel_candidate" 2>/dev/null) || {
      ac_log "primer action=skip-legacy-sentinel path=$sentinel_candidate reason=no-cwd-field-or-invalid-schema"
      continue
    }
    if [ -z "$sent_cwd" ]; then
      ac_log "primer action=skip-legacy-sentinel path=$sentinel_candidate reason=empty-cwd"
      continue
    fi
    # Canonicalize sentinel cwd; match if EITHER canonical OR raw equality (R1-H1 fallback).
    local sent_cwd_canon
    sent_cwd_canon=$(ac_canonicalize_path "$sent_cwd") || sent_cwd_canon="$sent_cwd"
    # CWD (raw, pre-canonicalization) is available via the caller's global CWD variable.
    if [ "$sent_cwd_canon" = "$cwd_canon" ] || [ "$sent_cwd" = "${CWD:-}" ]; then
      SENTINEL_PRESENT="true"
      SENTINEL_PATH="$sentinel_candidate"
      local sentinel_sid_full
      sentinel_sid_full=$(basename "$sentinel_candidate" .json | sed 's/^auto-compact-//')
      SENTINEL_SID8=$(printf '%s' "$sentinel_sid_full" | head -c 8)
      [ -z "$SENTINEL_SID8" ] && SENTINEL_SID8="$sentinel_sid_full"
      SENTINEL_NONCE=$(jq -r '.marker_nonce // empty' "$sentinel_candidate" 2>/dev/null) || SENTINEL_NONCE=""
      handoff_log "handoff_detected sid=${SENTINEL_SID8:-unknown} file=${HANDOFF_PATH:-unknown}"
      break
    fi
    # Different cwd — sentinel for another workspace; skip.
  done
}
