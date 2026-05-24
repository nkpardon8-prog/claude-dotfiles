#!/usr/bin/env bash
# post-compact-resume-step2.sh — extracted from commands/post-compact-resume.md Step 2.
#
# Reads $HOME/.claude/progress/breadcrumb-*.json (R3 D2 per-session breadcrumb) and
# the most-recent CLAUDE.local file in $(pwd) or $REPO_ROOT. Prints a single STATE=...
# line on stdout that the orchestrator routes against the decision matrix in
# commands/post-compact-resume.md.
#
# Usage: bash "$HOME/.claude-dotfiles/scripts/hooks/post-compact-resume-step2.sh"
# (D9: moved out of lib/ — lib/ files are sourceable; this script executes.)
#
# Source-guard: not re-sourceable; intended to be invoked as a script.

set -uo pipefail

# Resolve script directory for relative lib sourcing (works regardless of cwd or HOME).
# D9: script lives at hooks/post-compact-resume-step2.sh; libs live at hooks/lib/.
_STEP2_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _STEP2_DIR=""

# Source libs via script-relative path first; $HOME-absolute fallback for edge cases.
# Fail-open if lib missing (use defaults).
if [ -n "$_STEP2_DIR" ]; then
  . "$_STEP2_DIR/lib/ctx-gate-config.sh" 2>/dev/null || . "$HOME/.claude-dotfiles/scripts/hooks/lib/ctx-gate-config.sh" 2>/dev/null
  . "$_STEP2_DIR/lib/handoff-config.sh" 2>/dev/null || . "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-config.sh" 2>/dev/null
  . "$_STEP2_DIR/lib/auto-compact-sentinel.sh" 2>/dev/null || . "$HOME/.claude-dotfiles/scripts/hooks/lib/auto-compact-sentinel.sh" 2>/dev/null
  # H1: source marker lib so we delegate to handoff_marker_check / handoff_marker_nonce
  # instead of inlining grep/sed (eliminates drift if canonical marker strings change).
  . "$_STEP2_DIR/lib/handoff-marker.sh" 2>/dev/null || . "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-marker.sh" 2>/dev/null
  # R4 H10 (Phase 3 task 3.5): source canonical resolver.
  # handoff_resolve_path and _primer_check_linkcount are defined here (R2-PR-6 BLOCKER fix:
  # _primer_check_linkcount lives in handoff-resolve.sh, not primer-helpers, to prevent
  # step2.sh from calling an undefined function — silent fail-closed on every valid handoff).
  . "$_STEP2_DIR/lib/handoff-resolve.sh" 2>/dev/null || . "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-resolve.sh" 2>/dev/null
else
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/ctx-gate-config.sh" 2>/dev/null
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-config.sh" 2>/dev/null
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/auto-compact-sentinel.sh" 2>/dev/null
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-marker.sh" 2>/dev/null
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-resolve.sh" 2>/dev/null
fi

# R3 D2: Per-session breadcrumb written by Stop hook (decoupled from .claim file
# lifecycle which the Stop hook EXIT trap removes). Read the most-recent breadcrumb
# matching this workspace's cwd. PR-1 SID-scoped path, PR-3 hostname check, PR-8
# dual canonical+raw cwd compare, PR-12 filesystem mtime canonical (no JSON mtime).
SENTINEL_SID=""
SENTINEL_NONCE=""
SID8=""
ADOPTED_BREADCRUMB_PATH=""
CURRENT_CWD_CANON=$(cd -P "$(pwd)" 2>/dev/null && pwd -P || printf '%s' "$(pwd)")

# R3-fix-sweep C5: only delete breadcrumb when a terminal state semantically CONSUMES
# the handoff decision.  Fail-closed states (sid-known-no-tagged-file, oversize,
# invalid-handoff-name) preserve the breadcrumb so the user can remediate the problem
# and retry /post-compact-resume without losing the SID → file association.
#
# _BREADCRUMB_CONSUMED is set to "yes" only at:
#   STATE=ok                        — handoff successfully read; breadcrumb done its job
#   STATE=nonce-mismatch-hard-stop  — definitively rejected; breadcrumb consumed
#   STATE=sid-mismatch-hard-stop    — definitively rejected; breadcrumb consumed
#
# All other states (sid-known-no-tagged-file, oversize, invalid-handoff-name, no-handoff,
# error) leave _BREADCRUMB_CONSUMED empty → trap is a no-op → breadcrumb preserved.
_BREADCRUMB_CONSUMED=""
trap '[ "$_BREADCRUMB_CONSUMED" = "yes" ] && [ -n "${ADOPTED_BREADCRUMB_PATH:-}" ] && [ -n "${SENTINEL_SID:-}" ] && rm -f "$ADOPTED_BREADCRUMB_PATH" 2>/dev/null || true' EXIT
HOSTNAME_SHORT=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64)

# Glob over per-session breadcrumbs, newest first; pick the first that matches cwd + host.
# H3 (Theme 5): use nullglob + mtime-array iteration instead of $(ls -t ...) to handle
# $HOME with spaces and avoid word-splitting / ls-parse pitfalls (bash 3.2 compatible).
shopt -s nullglob 2>/dev/null
_bc_candidates=()
for _bc_f in "$HOME/.claude/progress/breadcrumb-"*.json; do
  [ -f "$_bc_f" ] || continue
  if _bc_mt=$(stat -f %m "$_bc_f" 2>/dev/null); then :
  elif _bc_mt=$(stat -c %Y "$_bc_f" 2>/dev/null); then :
  else continue
  fi
  _bc_mt=$(printf '%s' "$_bc_mt" | tr -d '[:space:]')
  [ -n "$_bc_mt" ] || continue
  _bc_candidates+=("$_bc_mt $_bc_f")
done
shopt -u nullglob 2>/dev/null
IFS=$'\n' _bc_sorted=($(printf '%s\n' "${_bc_candidates[@]+"${_bc_candidates[@]}"}" | sort -rn))
unset IFS
for _bc_entry in "${_bc_sorted[@]+"${_bc_sorted[@]}"}"; do
  BREADCRUMB="${_bc_entry#* }"
  [ -f "$BREADCRUMB" ] || continue
  [ -L "$BREADCRUMB" ] && continue  # reject symlinks
  # Ownership + size guard
  [ -O "$BREADCRUMB" ] || continue
  # H3/H9 (R4): replace || stat-cascade with explicit if-elif (macOS BSD stat short-circuits).
  # H9 (R4): lower-bound guard added (BREAD_SIZE > 0) — empty file is invalid.
  if BREAD_SIZE=$(stat -f %z "$BREADCRUMB" 2>/dev/null); then
    :
  elif BREAD_SIZE=$(stat -c %s "$BREADCRUMB" 2>/dev/null); then
    :
  else
    BREAD_SIZE=0
  fi
  BREAD_SIZE=$(printf '%s' "$BREAD_SIZE" | tr -d '[:space:]')
  [ -z "$BREAD_SIZE" ] && BREAD_SIZE=0
  # H9: both lower-bound (> 0) and upper-bound (< 1024) required.
  [ "$BREAD_SIZE" -gt 0 ] || continue
  [ "$BREAD_SIZE" -lt 1024 ] || continue
  # Age guard (PR-2: 1h matches GC TTL)
  # H3 (R4): explicit if-elif for stat (no || chaining).
  if BREAD_MTIME=$(stat -f %m "$BREADCRUMB" 2>/dev/null); then
    :
  elif BREAD_MTIME=$(stat -c %Y "$BREADCRUMB" 2>/dev/null); then
    :
  else
    BREAD_MTIME=0
  fi
  BREAD_MTIME=$(printf '%s' "$BREAD_MTIME" | tr -d '[:space:]')
  [ -z "$BREAD_MTIME" ] && BREAD_MTIME=0
  BREAD_AGE=$(( $(date +%s) - BREAD_MTIME ))
  [ "$BREAD_AGE" -ge 0 ] && [ "$BREAD_AGE" -lt 3600 ] || continue
  # H12 (R4): schema-validating breadcrumb reader — check schema_version + originating_command
  # + type-guards on each field. PR-M4: handle missing schema_version as 0 (old breadcrumbs).
  # H14 (R4): explicitly reject if BREAD_CWD or BREAD_HOST are empty after extraction.
  BREAD_CWD=$(jq -r '
    if ((.schema_version // 0) == 1)
       and ((.originating_command // "") == "pre-compact")
       and ((.cwd | type) == "string")
       and (.cwd != "")
    then .cwd else empty end' "$BREADCRUMB" 2>/dev/null) || continue
  # H14: explicit reject on empty (guards against jq returning null / type mismatch).
  if [ -z "$BREAD_CWD" ]; then continue; fi
  # Cwd match (PR-8 dual: canonical OR raw)
  if [ "$BREAD_CWD" != "$CURRENT_CWD_CANON" ] && [ "$BREAD_CWD" != "$(pwd)" ]; then continue; fi
  # Hostname match (PR-3 iCloud defense)
  BREAD_HOST=$(jq -r '
    if ((.schema_version // 0) == 1)
       and ((.originating_command // "") == "pre-compact")
       and ((.hostname | type) == "string")
       and (.hostname != "")
    then .hostname else empty end' "$BREADCRUMB" 2>/dev/null) || continue
  # H14: explicit reject on empty hostname.
  if [ -z "$BREAD_HOST" ]; then continue; fi
  if [ "$BREAD_HOST" != "$HOSTNAME_SHORT" ]; then continue; fi
  # All checks pass — adopt this breadcrumb.
  SENTINEL_SID=$(jq -r '
    if ((.sid | type) == "string") and (.sid != "") then .sid else empty end' \
    "$BREADCRUMB" 2>/dev/null) || SENTINEL_SID=""
  SID8=$(jq -r '
    if ((.sid8 | type) == "string") and (.sid8 != "") then .sid8 else empty end' \
    "$BREADCRUMB" 2>/dev/null) || SID8=""
  # C5 fix: regex-validate SID8 at primary breadcrumb-read path (was: only at claim-fallback).
  # Reject any SID8 containing characters outside [A-Za-z0-9_-] to prevent path-traversal
  # when SID8 is later interpolated into CLAUDE.local.<SID8>.md file paths.
  # Double-underscore TTY separator (C1) uses _ which is in the safe set — no false rejects.
  if [ -n "$SID8" ] && ! printf '%s' "$SID8" | grep -qE '^[A-Za-z0-9_-]+$'; then
    ctx_gate_log "step2 skip reason=invalid-sid8 sid8=$SID8 path=$BREADCRUMB"
    SENTINEL_SID=""
    SID8=""
    SENTINEL_NONCE=""
    continue
  fi
  # Also validate full SENTINEL_SID for the same reason.
  if [ -n "$SENTINEL_SID" ] && ! printf '%s' "$SENTINEL_SID" | grep -qE '^[A-Za-z0-9_-]+$'; then
    ctx_gate_log "step2 skip reason=invalid-sentinel-sid sid=$SENTINEL_SID path=$BREADCRUMB"
    SENTINEL_SID=""
    SID8=""
    SENTINEL_NONCE=""
    continue
  fi
  SENTINEL_NONCE=$(jq -r '
    if ((.nonce | type) == "string") and (.nonce != "") then .nonce else empty end' \
    "$BREADCRUMB" 2>/dev/null) || SENTINEL_NONCE=""
  # R4 D5: track path for read-once consumption after successful adoption.
  ADOPTED_BREADCRUMB_PATH="$BREADCRUMB"
  break
done

# Fallback: best-effort .claim.<pid> lookup (will usually fail because Stop hook
# EXIT trap removed it, but harmless to try in unusual lifecycles).
if [ -z "$SENTINEL_SID" ]; then
  CLAIM_FILE=$(ls -t "$HOME/.claude/progress/auto-compact-"*.json.claim.* 2>/dev/null | head -1)
  if [ -n "$CLAIM_FILE" ] && [ -f "$CLAIM_FILE" ]; then
    # H11 (R4): validate sentinel basename against ^[A-Za-z0-9_-]+$ before extracting SID.
    CLAIM_BASENAME=$(basename "$CLAIM_FILE")
    CLAIM_SID_RAW=$(printf '%s' "$CLAIM_BASENAME" | sed 's/^auto-compact-//; s/\.json\.claim\..*//')
    # Reject if SID contains any character outside safe set.
    if printf '%s' "$CLAIM_SID_RAW" | grep -qE '^[A-Za-z0-9_-]+$'; then
      SENTINEL_SID="$CLAIM_SID_RAW"
      if [ -n "$SENTINEL_SID" ]; then
        # R3-fix-sweep C2: use TTY-aware ac_compute_sid8 (sourced from
        # lib/auto-compact-sentinel.sh above) — preserves __ttysN discriminator.
        SID8=$(ac_compute_sid8 "$SENTINEL_SID")
        SENTINEL_NONCE=$(jq -r '.marker_nonce // empty' "$CLAIM_FILE" 2>/dev/null) || SENTINEL_NONCE=""
      fi
    fi
  fi
fi

# Resolve HANDOFF_PATH: SID-tagged first (when SID known), alias-only when SID unknown.
# R4 H10 (Phase 3): delegated to lib/handoff-resolve.sh (handoff_resolve_path).
# R4 D3 / R4-PR-M9: when SID8 known, ONLY SID-tagged files; NEVER mix with alias.
# _primer_check_linkcount (H9 hardlink defense) is embedded in handoff-resolve.sh (R2-PR-6).
HANDOFF_PATH=""
RESOLVE_RC=0
handoff_resolve_path "$(pwd)" "${SID8:-}" || RESOLVE_RC=$?

if [ "$RESOLVE_RC" -eq 2 ]; then
  # R4 D3: SID known but no SID-tagged file found — fail closed.
  # Do NOT fall back to alias (that may belong to another parallel-track session).
  # H4: emit step2_terminal log so operators can reconstruct terminal state audit trail.
  handoff_log "step2_terminal state=sid-known-no-tagged-file sid8=${SID8}"
  _json=$(jq -c -n --arg sid8 "$SID8" \
    '{"state":"sid-known-no-tagged-file","sid8":$sid8}' 2>/dev/null)
  if [ -n "$_json" ]; then
    printf 'STATE=%s\n' "$_json"
  else
    printf 'STATE={"state":"sid-known-no-tagged-file","sid8":"%s"}\n' "$SID8"
  fi
  exit 0
fi

if [ -z "$HANDOFF_PATH" ]; then
  # Signaling convention: exit 0 here so the orchestrator reads STATE= from stdout
  # and routes accordingly. Non-zero exit would surface as a Bash tool error, not
  # as a routable state signal.
  # H4: emit step2_terminal log so operators can reconstruct terminal state audit trail.
  handoff_log "step2_terminal state=no-handoff sid8=${SID8:-none}"
  _json=$(jq -c -n '{"state":"no-handoff"}' 2>/dev/null)
  if [ -n "$_json" ]; then
    printf 'STATE=%s\n' "$_json"
  else
    printf 'STATE={"state":"no-handoff"}\n'
  fi
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
  # R4 D10: JSON-encoded STATE line (handles paths with spaces).
  # H4: emit step2_terminal log so operators can reconstruct terminal state audit trail.
  handoff_log "step2_terminal state=oversize sid8=${SID8:-none} size=${HANDOFF_SIZE}"
  _json=$(jq -c -n \
    --argjson size "$HANDOFF_SIZE" \
    --argjson max "${HANDOFF_MAX_SIZE_BYTES:-5242880}" \
    --arg path "$HANDOFF_PATH" \
    '{"state":"oversize","size":$size,"max":$max,"path":$path}' 2>/dev/null)
  if [ -n "$_json" ]; then
    printf 'STATE=%s\n' "$_json"
  else
    printf 'STATE={"state":"oversize","size":%s,"max":%s}\n' "$HANDOFF_SIZE" "${HANDOFF_MAX_SIZE_BYTES:-5242880}"
  fi
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

# H1: delegate marker check to lib/handoff-marker.sh (canonical marker constants).
# If lib failed to source (handoff_marker_check undefined), fall back to inline grep.
MARKER=absent
if command -v handoff_marker_check >/dev/null 2>&1; then
  if handoff_marker_check "$HANDOFF_PATH"; then MARKER=present; fi
else
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
fi

# H1: delegate nonce extraction to lib/handoff-marker.sh. Fall back to inline sed if lib absent.
if command -v handoff_marker_nonce >/dev/null 2>&1; then
  MARKER_NONCE=$(handoff_marker_nonce "$HANDOFF_PATH" 2>/dev/null)
else
  # R3-fix-sweep C3+C4: anchor inline nonce extraction to marker line (same as lib fix).
  MARKER_NONCE=$(tail -c 512 "$HANDOFF_PATH" 2>/dev/null \
    | grep -F 'END-OF-HANDOFF schema=' \
    | tail -1 \
    | sed -nE 's/.*nonce=([a-f0-9-]+).*/\1/p')
fi

# C3 fix: extract marker sid= attribute and validate it against SID8 from breadcrumb.
# If the marker's SID8 disagrees with the breadcrumb SID8, the file belongs to a
# DIFFERENT session — hard stop immediately (before nonce comparison).
# Uses handoff_marker_sid() from lib/handoff-marker.sh if available (sourced above).
MARKER_SID=""
if command -v handoff_marker_sid >/dev/null 2>&1; then
  MARKER_SID=$(handoff_marker_sid "$HANDOFF_PATH" 2>/dev/null) || MARKER_SID=""
else
  # R3-fix-sweep C1+C3+C4: inline fallback — anchor to marker line (same fix as lib).
  # grep -F filters to marker lines only; tail -1 picks the last canonical marker;
  # sed extracts sid= — no \b needed (already on marker-only line).
  MARKER_SID=$(tail -c 512 "$HANDOFF_PATH" 2>/dev/null \
    | grep -F 'END-OF-HANDOFF schema=' \
    | tail -1 \
    | sed -nE 's/.*sid=([A-Za-z0-9_-]+).*/\1/p')
fi
if [ -n "$MARKER_SID" ] && [ -n "$SID8" ] && [ "$MARKER_SID" != "$SID8" ]; then
  _json=$(jq -c -n \
    --arg sid8 "$SID8" \
    --arg marker_sid "$MARKER_SID" \
    '{"state":"sid-mismatch-hard-stop","sentinel_sid8":$sid8,"marker_sid8":$marker_sid}' 2>/dev/null)
  if [ -n "$_json" ]; then
    printf 'STATE=%s\n' "$_json"
  else
    printf 'STATE={"state":"sid-mismatch-hard-stop","sentinel_sid8":"%s","marker_sid8":"%s"}\n' "$SID8" "$MARKER_SID"
  fi
  handoff_log "sid_mismatch_hard_stop sentinel_sid8=$SID8 marker_sid8=$MARKER_SID"
  # H4: emit step2_terminal log so operators can reconstruct terminal state audit trail.
  handoff_log "step2_terminal state=sid-mismatch-hard-stop sid8=${SID8}"
  exit 0
fi

# SENTINEL_NONCE already populated above by breadcrumb-first lookup (or claim-file fallback).
NONCE_OK="unknown"
if [ -n "$MARKER_NONCE" ] && [ -n "$SENTINEL_NONCE" ]; then
  if [ "$MARKER_NONCE" = "$SENTINEL_NONCE" ]; then NONCE_OK=match; else NONCE_OK=mismatch; fi
fi

# R4 D4: when SID known, nonce mismatch is a HARD STOP (not advisory).
# The alias could be from another session; we refuse to proceed with possibly wrong content.
if [ "$NONCE_OK" = "mismatch" ] && [ -n "$SID8" ]; then
  # C6: emit handoff_log so operators can grep auto-compact.log for nonce_mismatch_hard_stop
  # (was: STDOUT-only STATE JSON, invisible to log consumers).
  handoff_log "nonce_mismatch_hard_stop sid8=${SID8} marker_first8=$(printf '%s' "${MARKER_NONCE:-}" | head -c 8) sentinel_first8=$(printf '%s' "${SENTINEL_NONCE:-}" | head -c 8)"
  # H4: emit step2_terminal log so operators can reconstruct terminal state audit trail.
  handoff_log "step2_terminal state=nonce-mismatch-hard-stop sid8=${SID8}"
  _json=$(jq -c -n \
    --arg sid8 "$SID8" \
    --arg marker_nonce "${MARKER_NONCE:-}" \
    --arg sentinel_nonce "${SENTINEL_NONCE:-}" \
    '{"state":"nonce-mismatch-hard-stop","sid8":$sid8,
      "marker_nonce_first8":($marker_nonce | .[0:8]),
      "sentinel_nonce_first8":($sentinel_nonce | .[0:8])}' 2>/dev/null)
  if [ -n "$_json" ]; then
    printf 'STATE=%s\n' "$_json"
  else
    printf 'STATE={"state":"nonce-mismatch-hard-stop","sid8":"%s"}\n' "$SID8"
  fi
  exit 0
fi

STALE_SECS="${HANDOFF_STALE_SECS:-86400}"
if [ "$STAT_OK" = "true" ] && [ "$HANDOFF_AGE" -gt "$STALE_SECS" ]; then STALE=true; else STALE=false; fi

HANDOFF_AGE_HOURS=$((HANDOFF_AGE / 3600))
[ -z "$HANDOFF_AGE_HOURS" ] && HANDOFF_AGE_HOURS=0

# H11 (Theme 5): re-validate HANDOFF_PATH basename against expected naming pattern before
# announcing path to orchestrator (trust boundary re-check). Basename must match
# CLAUDE.local.<sid8>.md (SID-tagged) or CLAUDE.local.md (legacy alias-only path).
# Rejects traversal attempts, injected paths, and files with unexpected shapes.
_handoff_bn=$(basename "$HANDOFF_PATH")
if ! printf '%s' "$_handoff_bn" | grep -qE '^CLAUDE\.local\.([A-Za-z0-9_-]+\.)?md$'; then
  handoff_log "step2_terminal state=invalid-handoff-name path=$HANDOFF_PATH"
  _json=$(jq -c -n --arg path "$HANDOFF_PATH" \
    '{"state":"invalid-handoff-name","path":$path}' 2>/dev/null)
  if [ -n "$_json" ]; then
    printf 'STATE=%s\n' "$_json"
  else
    printf 'STATE={"state":"invalid-handoff-name"}\n'
  fi
  exit 0
fi

# R4 D10: emit STATE as single-line JSON (handles workspace paths with spaces).
# H4: emit step2_terminal log BEFORE STATE emission so audit trail precedes the signal.
handoff_log "step2_terminal state=ok sid8=${SID8:-none} marker=${MARKER} nonce_ok=${NONCE_OK}"
_json=$(jq -c -n \
  --arg state "ok" \
  --arg marker "$MARKER" \
  --argjson legacy "$LEGACY" \
  --argjson stale "$STALE" \
  --argjson age_hours "$HANDOFF_AGE_HOURS" \
  --arg nonce_ok "$NONCE_OK" \
  --arg sid8 "${SID8:-}" \
  --arg path "$HANDOFF_PATH" \
  '{"state":$state,"marker":$marker,"legacy":$legacy,"stale":$stale,
    "age_hours":$age_hours,"nonce_ok":$nonce_ok,"sid8":$sid8,"path":$path}' 2>/dev/null)
if [ -n "$_json" ]; then
  printf 'STATE=%s\n' "$_json"
else
  printf 'STATE={"state":"error","reason":"jq-failed"}\n'
fi

# R4 D5 (C4 fix): breadcrumb cleanup is now handled by the EXIT trap installed at
# the top of the script. The trap fires on every exit path — STATE=ok AND all
# fail-closed paths — ensuring the read-once invariant holds regardless of which
# branch exits. No explicit cleanup block is needed here.
