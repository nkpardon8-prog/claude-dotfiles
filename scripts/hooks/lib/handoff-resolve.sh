#!/usr/bin/env bash
# handoff-resolve.sh — canonical HANDOFF_PATH resolver.
# Used by post-compact-primer.sh (via primer_resolve_handoff_path in primer-helpers) AND
# post-compact-resume-step2.sh (directly).
#
# Sets HANDOFF_PATH on success; returns:
#   0 — resolved
#   1 — no handoff (SID unknown, no alias either)
#   2 — SID known but no SID-tagged file found (R4 D3 fail-closed signal)
#   3 — SID-tagged file exists but is hardlinked (rc=3 distinct from rc=2)
#
# R7-INC: adds marker-sid content-check (F2/RQ-INC-02) and alias-with-marker-binding
# probe (F4/RQ-INC-04 Defense H12).  Both checks use inline grep|sed unconditionally
# (no `command -v handoff_marker_sid` dual-path). Canonical pattern mirrors
# handoff-marker.sh:130.
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
#   - Tries SID-tagged files first: <cwd>/CLAUDE.local.<sid8>.md + repo-root variant.
#     R7-INC-02 (F2): each SID-tagged candidate is content-verified — the file's
#     END-OF-HANDOFF marker `sid=` attribute MUST match the requested sid8.
#     Allow-empty marker only for legacy files (mtime < HANDOFF_LEGACY_CUTOFF_EPOCH).
#   - If no SID-tagged file passes content-check: R7-INC-04 (F4) alias probe —
#     tries <cwd>/CLAUDE.local.md + repo-root alias, accepted ONLY when the alias
#     has a marker with sid= matching sid8 (Defense H12: alias-with-marker-binding).
#   - If no probe resolves: returns 2 (R4 D3 fail-closed signal).
#   - If found but hardlinked: logs primer_skip reason=multi-hardlink + returns 3
#     (Phase 4 Round 4: distinct rc so step2.sh can emit STATE=sid-known-hardlinked).
#
# When sid8 is empty (SID unknown):
#   - Tries legacy alias files only: <cwd>/CLAUDE.local.md + repo-root variant.
#   - No content-check for the SID-unknown path (legacy; alias accepted as-is).
#   - If found: sets HANDOFF_PATH, returns 0.
#   - If not found: returns 1.
# ---------------------------------------------------------------------------
handoff_resolve_path() {
  local cwd="$1" sid8="${2:-}"
  HANDOFF_PATH=""

  if [ -n "$sid8" ]; then
    local _legacy_cutoff="${HANDOFF_LEGACY_CUTOFF_EPOCH:-1779321600}"

    # ---------- cwd SID-tagged probe ----------
    local p="$cwd/CLAUDE.local.${sid8}.md"
    if [ -f "$p" ] && [ ! -L "$p" ]; then
      if _primer_check_linkcount "$p"; then
        # R7-INC-02 (F2): marker-sid content-check. Inline grep|sed (NOT command -v guard).
        # Canonical pattern mirrors handoff-marker.sh:130.
        local _resolver_marker_sid
        _resolver_marker_sid=$(grep -E '^<!-- END-OF-HANDOFF schema=v1 ' "$p" 2>/dev/null | head -1 \
          | sed -nE 's/.*sid=([A-Za-z0-9_-]+).*/\1/p')
        if [ -n "$_resolver_marker_sid" ]; then
          if [ "$_resolver_marker_sid" = "$sid8" ]; then
            HANDOFF_PATH="$p"
            return 0
          else
            ctx_gate_log "primer skip reason=resolver-marker-sid-mismatch sid8=$sid8 marker_sid=$_resolver_marker_sid file=$p"
            # Fall through to next probe.
          fi
        else
          # No marker — apply mtime gate (R7-INC-02 v2 closes BLOCKER #2).
          # Files with no marker but recent mtime are NOT accepted (bypass attack closed).
          local _fmtime
          if _fmtime=$(stat -f %m "$p" 2>/dev/null); then :
          elif _fmtime=$(stat -c %Y "$p" 2>/dev/null); then :
          else _fmtime=9999999999; fi
          _fmtime=$(printf '%s' "$_fmtime" | tr -d '[:space:]')
          [ -z "$_fmtime" ] && _fmtime=9999999999
          if [ "$_fmtime" -lt "$_legacy_cutoff" ]; then
            HANDOFF_PATH="$p"
            return 0
          else
            ctx_gate_log "primer skip reason=resolver-no-marker-non-legacy sid8=$sid8 file=$p mtime=$_fmtime cutoff=$_legacy_cutoff"
            # Fall through.
          fi
        fi
      else
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

    # ---------- repo-root SID-tagged probe ----------
    local repo_root
    repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || repo_root=""
    if [ -n "$repo_root" ]; then
      p="$repo_root/CLAUDE.local.${sid8}.md"
      if [ -f "$p" ] && [ ! -L "$p" ]; then
        if _primer_check_linkcount "$p"; then
          local _resolver_marker_sid2
          _resolver_marker_sid2=$(grep -E '^<!-- END-OF-HANDOFF schema=v1 ' "$p" 2>/dev/null | head -1 \
            | sed -nE 's/.*sid=([A-Za-z0-9_-]+).*/\1/p')
          if [ -n "$_resolver_marker_sid2" ]; then
            if [ "$_resolver_marker_sid2" = "$sid8" ]; then
              HANDOFF_PATH="$p"
              return 0
            else
              ctx_gate_log "primer skip reason=resolver-marker-sid-mismatch sid8=$sid8 marker_sid=$_resolver_marker_sid2 file=$p"
            fi
          else
            local _fmtime2
            if _fmtime2=$(stat -f %m "$p" 2>/dev/null); then :
            elif _fmtime2=$(stat -c %Y "$p" 2>/dev/null); then :
            else _fmtime2=9999999999; fi
            _fmtime2=$(printf '%s' "$_fmtime2" | tr -d '[:space:]')
            [ -z "$_fmtime2" ] && _fmtime2=9999999999
            if [ "$_fmtime2" -lt "$_legacy_cutoff" ]; then
              HANDOFF_PATH="$p"
              return 0
            else
              ctx_gate_log "primer skip reason=resolver-no-marker-non-legacy sid8=$sid8 file=$p mtime=$_fmtime2 cutoff=$_legacy_cutoff"
            fi
          fi
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

    # ---------- R7-INC-04 (F4) cwd alias probe (Defense H12: alias-with-marker-binding) ----------
    # The alias is accepted ONLY when its marker sid= matches the requested sid8.
    # No marker → NOT accepted (no legacy allow for alias; legacy allow is SID-tagged only).
    local alias_p="$cwd/CLAUDE.local.md"
    if [ -f "$alias_p" ] && [ ! -L "$alias_p" ] && _primer_check_linkcount "$alias_p"; then
      local _alias_marker_sid
      _alias_marker_sid=$(grep -E '^<!-- END-OF-HANDOFF schema=v1 ' "$alias_p" 2>/dev/null | head -1 \
        | sed -nE 's/.*sid=([A-Za-z0-9_-]+).*/\1/p')
      if [ -n "$_alias_marker_sid" ] && [ "$_alias_marker_sid" = "$sid8" ]; then
        ctx_gate_log "primer accept reason=alias-with-marker-match sid8=$sid8 file=$alias_p"
        HANDOFF_PATH="$alias_p"
        return 0
      elif [ -n "$_alias_marker_sid" ]; then
        ctx_gate_log "primer skip reason=alias-marker-mismatch sid8=$sid8 alias_marker_sid=${_alias_marker_sid} file=$alias_p"
      fi
      # Alias with no marker: NOT accepted under Defense H12 (binding requires marker).
    fi

    # ---------- R7-INC-04 (F4) repo-root alias probe ----------
    if [ -n "$repo_root" ]; then
      local alias_p2="$repo_root/CLAUDE.local.md"
      if [ -f "$alias_p2" ] && [ ! -L "$alias_p2" ] && _primer_check_linkcount "$alias_p2"; then
        local _alias_marker_sid2
        _alias_marker_sid2=$(grep -E '^<!-- END-OF-HANDOFF schema=v1 ' "$alias_p2" 2>/dev/null | head -1 \
          | sed -nE 's/.*sid=([A-Za-z0-9_-]+).*/\1/p')
        if [ -n "$_alias_marker_sid2" ] && [ "$_alias_marker_sid2" = "$sid8" ]; then
          ctx_gate_log "primer accept reason=alias-with-marker-match sid8=$sid8 file=$alias_p2"
          HANDOFF_PATH="$alias_p2"
          return 0
        elif [ -n "$_alias_marker_sid2" ]; then
          ctx_gate_log "primer skip reason=alias-marker-mismatch sid8=$sid8 alias_marker_sid=${_alias_marker_sid2} file=$alias_p2"
        fi
      fi
    fi

    # All probes failed — R4 D3 fail-closed.
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
