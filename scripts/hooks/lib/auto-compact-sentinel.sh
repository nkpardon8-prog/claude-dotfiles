#!/usr/bin/env bash
# Idempotent source guard — second sourcing is a no-op (avoids `readonly` redeclaration
# errors if any caller transitively re-sources this lib).
[ -n "${_AC_LIB_LOADED:-}" ] && return 0
_AC_LIB_LOADED=1

# Shared helpers for the auto-compact-after-pre-compact feature.
# Sourced by `arm-auto-compact.sh` (writer) and `auto-compact-after-pre-compact.sh` (reader).
# Single source of truth for paths, schema, sentinel layout.
#
# Public functions:
#   ac_sentinel_path <sid>                    → echoes ~/.claude/progress/auto-compact-<sid>.json
#   ac_log_path                               → echoes ~/.claude/logs/auto-compact.log
#   ac_log <message>                          → append timestamped line to log; bounded ring (keep last 64K)
#   handoff_log <message>                     → delegate to ac_log with handoff: prefix
#   ac_resolve_session_id                     → echoes the current Claude Code session id (or empty); folds TTY basename into slug-fallback SID when CLAUDE_SESSION_ID unset (C1)
#   _ac_resolve_tty_basename_via_ppid         → echoes TTY basename (e.g. ttys012) via PPID-walk; empty on failure
#   ac_validate_tty <tty>                     → returns 0 if matches /dev/ttys[0-9]+, else 1
#   ac_canonicalize_path <path>               → echoes realpath via cd -P; returns 1 on failure
#   _ac_validate_sentinel_path <path>         → shared preamble: symlink/size guard; returns 0 if OK
#   ac_write_sentinel <sid> <tty> <cwd> <nonce> → writes JSON sentinel via jq+atomic mv, mode 600
#   ac_read_sentinel_tty <path>               → echoes target_tty from sentinel (schema v1+)
#   ac_read_sentinel_cwd <path>               → echoes cwd from sentinel (schema v2+; empty for v1)
#   ac_read_sentinel_nonce <path>             → echoes marker_nonce from sentinel (schema v3+; empty for v1/v2)
#   ac_read_breadcrumb_sid <path>             → echoes sid from breadcrumb (schema_version 1 only)
#   ac_read_breadcrumb_cwd <path>             → echoes cwd from breadcrumb (schema_version 1 only)
#   ac_read_breadcrumb_nonce <path>           → echoes nonce from breadcrumb (schema_version 1 only)
#   ac_read_breadcrumb_hostname <path>        → echoes hostname from breadcrumb (schema_version 1 only)
#
# Schema (v1):
#   {"schema_version":1,"target_tty":"/dev/ttys<N>","originating_command":"pre-compact"}
#
# Schema (v2 — Task 1.1a per pre-compact-soundness-hardening plan):
#   {"schema_version":2,...,"cwd":"/path/to/workspace"}
#
# Schema (v3 — R2 plan: adds marker_nonce for /post-compact-resume validation):
#   {"schema_version":3,...,"cwd":"/path/to/workspace","marker_nonce":"<uuid>"}

readonly AC_SCHEMA_VERSION=3
readonly AC_MAX_SENTINEL_BYTES=4096

ac_sentinel_path() {
  printf '%s/.claude/progress/auto-compact-%s.json' "$HOME" "$1"
}

ac_log_path() {
  printf '%s/.claude/logs/auto-compact.log' "$HOME"
}

ac_log() {
  local log dir
  log=$(ac_log_path)
  dir=$(dirname "$log")
  # mkdir/chmod only when missing — saves a syscall pair on every log call.
  if [ ! -d "$dir" ]; then
    mkdir -p "$dir" 2>/dev/null
    chmod 700 "$dir" 2>/dev/null
  fi
  # umask 077 → log file mode 600 (matches sentinel mode for symmetry).
  ( umask 077 && printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$log" ) 2>/dev/null || return 0
  # Bounded ring: if log exceeds 64KB, rewrite to last 32KB. Concurrent rotations can
  # truncate each other on burst load; accepted for a diagnostic ring (lossy is fine).
  local size
  size=$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$size" ] && [ "$size" -gt 65536 ]; then
    local tmp
    tmp="${log}.tmp.$$"
    ( umask 077 && tail -c 32768 "$log" > "$tmp" ) 2>/dev/null && mv "$tmp" "$log" 2>/dev/null
  fi
  return 0
}

# Delegate to ac_log with handoff: prefix — no new log file (same ring, same rotation).
handoff_log() {
  ac_log "handoff:$1"
}

# ---------------------------------------------------------------------------
# _ac_resolve_tty_basename_via_ppid
#
# C1 fix: resolves the controlling TTY basename (e.g. "ttys012") by walking
# the PPID chain — the same algorithm arm-auto-compact.sh uses to derive the
# target TTY.  Echoes the basename (without /dev/) on success; echoes nothing
# on failure (no TTY found, or TTY form not recognized).
#
# Only used by ac_resolve_session_id when CLAUDE_SESSION_ID is unset (slug
# fallback path).  When CLAUDE_SESSION_ID IS set the env var is returned
# as-is — no TTY suffix needed (the env var is already session-authoritative).
# ---------------------------------------------------------------------------
_ac_resolve_tty_basename_via_ppid() {
  local check_pid raw_tty
  check_pid="${PPID:-}"
  local _hop
  for _hop in 1 2 3 4 5; do
    [ -z "$check_pid" ] && break
    if [ "$check_pid" = "0" ] || [ "$check_pid" = "1" ]; then break; fi
    raw_tty=$(ps -o tty= -p "$check_pid" 2>/dev/null | tr -d '[:space:]')
    case "$raw_tty" in
      ttys[0-9]*) printf '%s' "$raw_tty"; return 0 ;;
    esac
    check_pid=$(ps -o ppid= -p "$check_pid" 2>/dev/null | tr -d '[:space:]')
  done
  # No TTY found in ancestry — return nothing (caller treats empty as "no TTY").
  return 1
}

# ---------------------------------------------------------------------------
# ac_compute_sid8 <sid>
#
# R3-fix-sweep C2: TTY-aware SID8 computation.  When SID contains a __ttysN
# suffix (slug-fallback path in ac_resolve_session_id), `head -c 8` returns
# only the first 8 bytes of the transcript UUID — the TTY discriminator is at
# position ~36+ and is never reached.  Two parallel sessions in the same cwd
# therefore get the same SID8, causing handoff filename clobber.
#
# This helper preserves the TTY suffix in SID8 so parallel-track sessions
# produce DISTINCT handoff filenames.
#
# Format:
#   With TTY suffix:    <first_8_of_transcript_uuid>_<tty_basename>
#   Without TTY suffix: <first_8_of_sid>  (unchanged behaviour — env-var path)
#
# Output charset: [A-Za-z0-9_-]+  — safe for filename construction.
# The underscore separator between UUID prefix and tty_basename is a single _
# (not double __) to keep SID8 short and human-readable while still
# distinguishing it from the UUID portion.
# ---------------------------------------------------------------------------
ac_compute_sid8() {
  local sid="$1"
  case "$sid" in
    *__ttys[0-9]*)
      local transcript_part tty_suffix prefix
      transcript_part="${sid%%__*}"
      tty_suffix="${sid##*__}"
      prefix=$(printf '%s' "$transcript_part" | head -c 8)
      [ -z "$prefix" ] && prefix="$transcript_part"
      printf '%s_%s' "$prefix" "$tty_suffix"
      ;;
    *)
      local prefix
      prefix=$(printf '%s' "$sid" | head -c 8)
      [ -z "$prefix" ] && prefix="$sid"
      printf '%s' "$prefix"
      ;;
  esac
}

ac_resolve_session_id() {
  local sid="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
  if [ -z "$sid" ]; then
    # Slug derivation: Claude Code's project transcript dirs replace every
    # non-alphanumeric byte of the absolute path with `-`. The naive
    # `s|/|-|g; s|^|-|` produces a double leading dash and ignores spaces.
    local slug dir transcript_sid tty_base
    slug=$(pwd | sed 's|[^A-Za-z0-9]|-|g')
    dir="$HOME/.claude/projects/${slug}"
    if [ -d "$dir" ]; then
      transcript_sid=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1 | xargs -I {} basename {} .jsonl 2>/dev/null)
    else
      transcript_sid=""
    fi
    # C1: fold TTY basename into slug-fallback SID to disambiguate N parallel
    # sessions sharing the same cwd (each session's claude process has a
    # distinct controlling TTY).  Format: <transcript_sid>__<tty_base>
    # Double underscore chosen: sanitizable ([A-Za-z0-9_-] set keeps both
    # underscores), visually distinct from single-underscore UUID delimiters.
    # Only fold when (a) CLAUDE_SESSION_ID was unset (we are in fallback mode)
    # AND (b) a transcript SID was found AND (c) the TTY resolves cleanly.
    if [ -n "$transcript_sid" ]; then
      tty_base=$(_ac_resolve_tty_basename_via_ppid 2>/dev/null) || tty_base=""
      if [ -n "$tty_base" ]; then
        sid="${transcript_sid}__${tty_base}"
      else
        sid="$transcript_sid"
      fi
    fi
  fi
  local final_sid
  final_sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9_-' | head -c 128)
  # Phase 4 (Round 4): refuse empty SID — emit arm-failed log and return non-zero.
  # An empty SID would result in a sentinel named auto-compact-.json (the "empty-SID
  # collision" where the first session in any new cwd shares a sentinel with any other
  # session that also resolves to an empty SID).
  if [ -z "$final_sid" ]; then
    ac_log "arm_failed reason=empty-sid cwd=$(pwd)"
    return 1
  fi
  printf '%s' "$final_sid"
}

ac_validate_tty() {
  [[ "$1" =~ ^/dev/ttys[0-9]+$ ]]
}

# Returns canonical path via `cd -P` + `pwd -P`. Returns 1 on failure.
# Used at arm time AND at primer-compare to ensure string equality holds across
# symlinks, trailing slashes, and ./-segments.
ac_canonicalize_path() {
  local p="$1"
  [ -z "$p" ] && return 1
  ( cd -P "$p" 2>/dev/null && pwd -P ) || return 1
}

# Shared preamble: validate sentinel path before reading.
# Returns 0 if file is safe to read; non-zero (and logs) otherwise.
# Checks: file exists, not a symlink, not oversized.
_ac_validate_sentinel_path() {
  local p="$1"
  [ -f "$p" ] || return 1
  if [ -L "$p" ]; then ac_log "skip-sentinel reason=symlink path=$p"; return 1; fi
  local size
  # Explicit if-elif for stat: no || chaining which short-circuits on macOS BSD stat.
  if size=$(stat -f %z "$p" 2>/dev/null); then
    :
  elif size=$(stat -c %s "$p" 2>/dev/null); then
    :
  else
    size=0
  fi
  size=$(printf '%s' "$size" | tr -d '[:space:]')
  [ -z "$size" ] && size=0
  if [ "$size" -gt "${AC_MAX_SENTINEL_BYTES:-4096}" ]; then
    ac_log "skip-sentinel reason=oversized size=$size path=$p"
    return 1
  fi
  return 0
}

# Writes a sentinel JSON file atomically (tmp+rename) with mode 600.
# Args: <sid> <tty> <cwd> <nonce>
# The nonce arg is the marker_nonce that /pre-compact will embed in CLAUDE.local.md's
# END-OF-HANDOFF marker; /post-compact-resume validates nonce consistency.
# JSON construction via jq -c -n — escapes all special characters in cwd correctly
# (defense against path-injection if cwd contains quotes, backslashes, etc.).
ac_write_sentinel() {
  local sid="$1" tty="$2" cwd="${3:-}" nonce="${4:-}"
  local path
  path=$(ac_sentinel_path "$sid")
  ac_validate_tty "$tty" || return 1
  mkdir -p "$(dirname "$path")" 2>/dev/null
  chmod 700 "$(dirname "$path")" 2>/dev/null
  # Build JSON via jq -c -n — argjson for numeric schema_version, --arg for strings.
  local json
  json=$(jq -c -n \
    --argjson sv "$AC_SCHEMA_VERSION" \
    --arg tty "$tty" \
    --arg cwd "$cwd" \
    --arg nonce "$nonce" \
    '{schema_version:$sv,target_tty:$tty,originating_command:"pre-compact",cwd:$cwd,marker_nonce:$nonce}') || return 1
  # H8: reject sentinel JSON that exceeds the size cap (defends against oversized cwd
  # or nonce values inflating the sentinel beyond the expected ~300-byte range).
  if [ "${#json}" -gt "${AC_MAX_SENTINEL_BYTES:-4096}" ]; then
    ac_log "ac_write_sentinel skip reason=oversize size=${#json} limit=${AC_MAX_SENTINEL_BYTES:-4096}"
    return 1
  fi
  # Atomic write via temp+rename (POSIX same-fs atomicity verified by smoke 03).
  # Hook subprocess — not subject to orchestrator Bash tool restrictions.
  local tmp="${path}.tmp.$$"
  ( umask 077; printf '%s\n' "$json" > "$tmp" ) 2>/dev/null || return 1
  mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
}

# Reads target_tty from a sentinel after validating: not a symlink, size bounded,
# parseable JSON, schema_version in range [1, AC_SCHEMA_VERSION], originating_command
# is "pre-compact", and target_tty is a valid TTY.
# Accepts ANY schema_version from 1 up to AC_SCHEMA_VERSION for backwards-compat.
# Echoes the validated target_tty on success, nothing on failure (returns non-zero).
ac_read_sentinel_tty() {
  local path="$1"
  _ac_validate_sentinel_path "$path" || return 1
  local raw
  # jq filter: type-guard on schema_version, range check, originating_command,
  # and string type-guard on target_tty. Parenthesization is LOAD-BEARING:
  # `((.target_tty // "") | type) == "string"` — without parens, jq `|` has lower
  # precedence than `and`, causing incorrect parse (round 3 regression).
  raw=$(jq -r --argjson v "$AC_SCHEMA_VERSION" '
    if type == "object"
       and ((.schema_version | type) == "number")
       and (.schema_version >= 1 and .schema_version <= $v)
       and (.originating_command // "") == "pre-compact"
       and (((.target_tty // "") | type) == "string")
    then .target_tty else empty end' < "$path" 2>/dev/null)
  if ! ac_validate_tty "$raw"; then
    ac_log "invalid target_tty='$raw' path=$path"
    return 1
  fi
  printf '%s' "$raw"
}

# Reads the cwd field from a sentinel after validating schema, size, type guards.
# Returns empty string (non-zero exit) for v1 sentinels (no cwd field), symlinks,
# oversized files, jq parse failures, schema_version out of range, or empty/missing cwd.
# Echoes the validated cwd on success, nothing on failure (returns non-zero).
ac_read_sentinel_cwd() {
  local sentinel="$1"
  _ac_validate_sentinel_path "$sentinel" || { ac_log "skip-sentinel reason=validate-failed path=$sentinel"; return 1; }
  local cwd
  cwd=$(jq -r --argjson v "${AC_SCHEMA_VERSION:-3}" '
    if ((.schema_version | type) == "number")
       and .schema_version >= 1
       and .schema_version <= $v
       and .originating_command == "pre-compact"
       and ((.cwd | type) == "string")
       and (.cwd != "")
    then .cwd
    else empty
    end' "$sentinel" 2>/dev/null) || { ac_log "skip-sentinel reason=jq-parse path=$sentinel"; return 1; }
  if [ -z "$cwd" ]; then
    ac_log "skip-sentinel reason=no-cwd-or-invalid-schema path=$sentinel"
    return 1
  fi
  printf '%s' "$cwd"
}

# Reads the marker_nonce field from a sentinel (schema v3+).
# Returns empty string (non-zero exit) for v1/v2 sentinels or missing field.
# Used by /post-compact-resume for nonce consistency validation.
ac_read_sentinel_nonce() {
  local sentinel="$1"
  _ac_validate_sentinel_path "$sentinel" || return 1
  local nonce
  nonce=$(jq -r --argjson v "${AC_SCHEMA_VERSION:-3}" '
    if ((.schema_version | type) == "number")
       and .schema_version >= 1
       and .schema_version <= $v
       and (.originating_command // "") == "pre-compact"
       and (((.marker_nonce // "") | type) == "string")
       and (.marker_nonce != "")
    then .marker_nonce
    else empty
    end' "$sentinel" 2>/dev/null) || { ac_log "skip-sentinel-nonce reason=jq-parse path=$sentinel"; return 1; }
  if [ -z "$nonce" ]; then
    return 1
  fi
  printf '%s' "$nonce"
}

# ---------------------------------------------------------------------------
# H1 (Commit 3 fix-sweep): ac_read_breadcrumb_* and _ac_validate_breadcrumb were
# defined here but never called — post-compact-resume-step2.sh inlines its own jq
# for breadcrumb reads and does not delegate to these helpers. Keeping dead helpers
# is actively harmful: _ac_validate_breadcrumb emitted `breadcrumb_read_invalid_schema`
# which could never fire, creating a phantom log verb in LOG_VERBS.md that G5 reverse
# scan would flag. Deleted here; step2.sh's inline jq is the canonical implementation.
# ---------------------------------------------------------------------------
