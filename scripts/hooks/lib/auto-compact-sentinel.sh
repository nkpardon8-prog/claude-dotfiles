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
#   ac_sentinel_path <sid>       → echoes ~/.claude/progress/auto-compact-<sid>.json
#   ac_log_path                  → echoes ~/.claude/logs/auto-compact.log
#   ac_log <message>             → append timestamped line to log; bounded ring (keep last 64K)
#   ac_resolve_session_id        → echoes the current Claude Code session id (or empty)
#   ac_validate_tty <tty>        → returns 0 if matches /dev/ttys[0-9]+, else 1
#   ac_write_sentinel <sid> <tty>→ writes JSON sentinel, mode 600, returns 0 on success
#   ac_read_sentinel_tty <path>  → echoes target_tty from sentinel, after validating schema/size
#
# Schema (v1):
#   {"schema_version":1,"target_tty":"/dev/ttys<N>","originating_command":"pre-compact"}
#   Filesystem mtime is the single source of truth for "when armed" (used by the
#   >12h prune in scripts/progress/on-session-start-cleanup.sh). `armed_at` was
#   removed in round 4 as dead data.

readonly AC_SCHEMA_VERSION=1
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

ac_resolve_session_id() {
  local sid="${CLAUDE_SESSION_ID:-}"
  if [ -z "$sid" ]; then
    # Slug derivation: Claude Code's project transcript dirs replace every
    # non-alphanumeric byte of the absolute path with `-`. The naive
    # `s|/|-|g; s|^|-|` produces a double leading dash and ignores spaces.
    local slug dir
    slug=$(pwd | sed 's|[^A-Za-z0-9]|-|g')
    dir="$HOME/.claude/projects/${slug}"
    if [ -d "$dir" ]; then
      sid=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1 | xargs -I {} basename {} .jsonl)
    fi
  fi
  printf '%s' "$sid" | tr -cd 'A-Za-z0-9_-' | head -c 128
}

ac_validate_tty() {
  [[ "$1" =~ ^/dev/ttys[0-9]+$ ]]
}

ac_write_sentinel() {
  local sid="$1" tty="$2"
  local path
  path=$(ac_sentinel_path "$sid")
  ac_validate_tty "$tty" || return 1
  mkdir -p "$(dirname "$path")" 2>/dev/null
  chmod 700 "$(dirname "$path")" 2>/dev/null
  # umask 077 ensures mode 600 — sentinel readable only by the user.
  # NOTE: `armed_at` was removed in round 4 (round 3 BREADTH flagged it as dead data
  # — never consumed by reader, GC, or test harness). Filesystem mtime is the
  # single source of truth for "when was this armed", used by the >12h prune.
  ( umask 077 && printf '{"schema_version":%d,"target_tty":"%s","originating_command":"pre-compact"}\n' \
      "$AC_SCHEMA_VERSION" "$tty" > "$path" ) 2>/dev/null
}

# Reads target_tty from a sentinel after validating: not a symlink, size bounded,
# parseable JSON, schema_version matches, originating_command is "pre-compact",
# and target_tty matches the anchored regex.
# Echoes the validated target_tty on success, nothing on failure (returns non-zero).
ac_read_sentinel_tty() {
  local path="$1"
  [ -f "$path" ] || return 1
  # Symlink rejection (defense against same-UID redirection).
  [ -L "$path" ] && { ac_log "symlink rejected path=$path"; return 1; }
  local size
  size=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$size" ] || [ "$size" -gt "$AC_MAX_SENTINEL_BYTES" ]; then
    ac_log "oversized sentinel size=$size path=$path"
    return 1
  fi
  local raw
  # Read entire JSON, then validate shape, schema, and target_tty in one jq pass.
  # The `((...) | type) == "string"` parens are LOAD-BEARING — without them, jq's `|`
  # has lower precedence than `and`, so `and X | type == "string"` parses as
  # `and (X | type == "string")` which evaluates type on the whole boolean chain
  # ("boolean" != "string", always false). Round 3 caught this.
  raw=$(jq -r --argjson v "$AC_SCHEMA_VERSION" '
    if type == "object"
       and .schema_version == $v
       and (.originating_command // "") == "pre-compact"
       and (((.target_tty // "") | type) == "string")
    then .target_tty else empty end' < "$path" 2>/dev/null)
  if [ -z "$raw" ]; then
    raw=$(python3 -c '
import sys, json
try:
  d = json.load(sys.stdin)
  assert isinstance(d, dict)
  assert d.get("schema_version") == '"$AC_SCHEMA_VERSION"'
  assert d.get("originating_command") == "pre-compact"
  t = d.get("target_tty")
  assert isinstance(t, str)
  print(t)
except Exception:
  pass
' < "$path" 2>/dev/null)
  fi
  if ! ac_validate_tty "$raw"; then
    ac_log "invalid target_tty='$raw' path=$path"
    return 1
  fi
  printf '%s' "$raw"
}
