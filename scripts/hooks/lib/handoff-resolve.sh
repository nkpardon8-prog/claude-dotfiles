#!/usr/bin/env bash
# handoff-resolve.sh — canonical HANDOFF_PATH resolver.
# Used by post-compact-primer.sh (via primer_resolve_handoff_path in primer-helpers) AND
# post-compact-resume-step2.sh (directly).
#
# Sets HANDOFF_PATH on success; returns:
#   0 — resolved
#   1 — no handoff (SID unknown, no alias either)
#   2 — SID known but no SID-tagged file found (R4 D3 fail-closed signal)
#
# macOS bash 3.2.57 compatible.

[ -n "${_HANDOFF_RESOLVE_LOADED:-}" ] && return 0
readonly _HANDOFF_RESOLVE_LOADED=1

# Defensive stub: if ctx_gate_log wasn't sourced from lib/ctx-gate-config.sh, no-op it.
# Lib callers source ctx-gate-config.sh before this lib; this guard prevents stderr
# pollution if the source failed (e.g., lib relocated/unreadable).
command -v ctx_gate_log >/dev/null 2>&1 || ctx_gate_log() { :; }

# ---------------------------------------------------------------------------
# _primer_check_linkcount <path>
#
# R2-PR-6 (Round 3 BLOCKER fix): DEFINED HERE (not in primer-helpers).
# This eliminates the cross-lib dependency that previously caused step2.sh to call an
# undefined function (silent fail-closed on every valid handoff read — production-breaking).
# Phase 3 task 3.5 also DELETES this function from lib/post-compact-primer-helpers.sh.
#
# H9: Returns 0 if file linkcount == 1 (normal file); 1 if linkcount > 1 (hardlink).
# Defends against hardlink-as-symlink-bypass attacks where an attacker creates a
# hardlink to a sensitive file to make it appear as a legitimate handoff location.
# BSD stat: -f %l; GNU stat: -c %h. Falls back to 1 (safe — assume no hardlink).
# ---------------------------------------------------------------------------
_primer_check_linkcount() {
  local p="$1"
  local linkcount stat_ok
  stat_ok=false
  if linkcount=$(stat -f %l "$p" 2>/dev/null); then
    stat_ok=true
  elif linkcount=$(stat -c %h "$p" 2>/dev/null); then
    stat_ok=true
  fi
  # H10 fix: fail-CLOSED on stat failure (was: fail-open with linkcount=1).
  # If stat fails entirely, we cannot confirm the file is not a hardlink — refuse
  # to proceed rather than silently trust a path we cannot verify.
  if [ "$stat_ok" = "false" ]; then
    ctx_gate_log "primer skip reason=stat-failed path=$p"
    return 1
  fi
  linkcount=$(printf '%s' "$linkcount" | tr -d '[:space:]')
  [ -z "$linkcount" ] && linkcount=1
  if [ "$linkcount" -gt 1 ]; then
    ctx_gate_log "primer skip reason=multi-hardlink path=$p linkcount=$linkcount"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# handoff_resolve_path <cwd> [sid8]
#
# PR-9: canonical resolver. sid8 may be empty (SID-unknown / no-breadcrumb path).
#
# When sid8 is provided (non-empty):
#   - ONLY tries SID-tagged files: <cwd>/CLAUDE.local.<sid8>.md + repo-root variant.
#   - If found (non-symlink, non-hardlink): sets HANDOFF_PATH, returns 0.
#   - If not found: returns 2 (R4 D3 fail-closed signal).
#   - If found but hardlinked: logs primer_skip reason=multi-hardlink + returns 3
#     (Phase 4 Round 4: distinct rc so step2.sh can emit STATE=sid-known-hardlinked
#     instead of silently falling to sid-known-no-tagged-file).
#
# When sid8 is empty (SID unknown):
#   - Tries legacy alias files only: <cwd>/CLAUDE.local.md + repo-root variant.
#   - If found: sets HANDOFF_PATH, returns 0.
#   - If not found: returns 1.
# ---------------------------------------------------------------------------
handoff_resolve_path() {
  local cwd="$1" sid8="${2:-}"
  HANDOFF_PATH=""

  if [ -n "$sid8" ]; then
    # SID-known path: ONLY try SID-tagged files. NEVER fall back to alias.
    local p="$cwd/CLAUDE.local.${sid8}.md"
    if [ -f "$p" ] && [ ! -L "$p" ]; then
      if _primer_check_linkcount "$p"; then
        HANDOFF_PATH="$p"
        return 0
      else
        # File exists and is not a symlink, but is a hardlink (linkcount > 1).
        # Phase 4 Round 4: return rc=3 (distinct from rc=2 "no file") so step2.sh
        # can surface STATE=sid-known-hardlinked with an actionable message.
        local LCNT
        if LCNT=$(stat -f %l "$p" 2>/dev/null); then :
        elif LCNT=$(stat -c %h "$p" 2>/dev/null); then :
        else LCNT=">1"
        fi
        LCNT=$(printf '%s' "$LCNT" | tr -d '[:space:]')
        ctx_gate_log "primer skip reason=multi-hardlink linkcount=${LCNT} file=$p"
        return 3
      fi
    fi
    local repo_root
    repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || repo_root=""
    if [ -n "$repo_root" ]; then
      p="$repo_root/CLAUDE.local.${sid8}.md"
      if [ -f "$p" ] && [ ! -L "$p" ]; then
        if _primer_check_linkcount "$p"; then
          HANDOFF_PATH="$p"
          return 0
        else
          local LCNT2
          if LCNT2=$(stat -f %l "$p" 2>/dev/null); then :
          elif LCNT2=$(stat -c %h "$p" 2>/dev/null); then :
          else LCNT2=">1"
          fi
          LCNT2=$(printf '%s' "$LCNT2" | tr -d '[:space:]')
          ctx_gate_log "primer skip reason=multi-hardlink linkcount=${LCNT2} file=$p"
          return 3
        fi
      fi
    fi
    # SID known but no SID-tagged file found (or all rejected) — R4 D3 fail-closed.
    ctx_gate_log "primer skip reason=sid-known-no-tagged-file sid=${sid8}"
    return 2
  fi

  # SID UNKNOWN: legacy alias-only path.
  local p2="$cwd/CLAUDE.local.md"
  if [ -f "$p2" ] && [ ! -L "$p2" ] && _primer_check_linkcount "$p2"; then
    HANDOFF_PATH="$p2"
    return 0
  fi
  local repo_root2
  repo_root2=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || repo_root2=""
  if [ -n "$repo_root2" ]; then
    p2="$repo_root2/CLAUDE.local.md"
    if [ -f "$p2" ] && [ ! -L "$p2" ] && _primer_check_linkcount "$p2"; then
      HANDOFF_PATH="$p2"
      return 0
    fi
  fi
  return 1
}
