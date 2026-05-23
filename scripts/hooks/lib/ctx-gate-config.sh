#!/usr/bin/env bash
# ctx-gate-config.sh — Single source of truth for context-gate thresholds, allowlists,
# and shared helper functions. Sourced by all four ctx-gate hooks.
#
# Idempotent source guard — second sourcing is a no-op (avoids `readonly` redeclaration
# errors if any caller transitively re-sources this lib).
[ -n "${_CTX_GATE_CONFIG_LOADED:-}" ] && return 0
_CTX_GATE_CONFIG_LOADED=1

# ---------------------------------------------------------------------------
# Thresholds
# ---------------------------------------------------------------------------
readonly CTX_SOFT_PCT=70
readonly CTX_HARD_PCT=90
# PreCompact safety net only fires below this; at/above this it releases to avoid
# deadlock (native compact runs as degraded fallback).
readonly CTX_PRECOMPACT_SAFETY_PCT=95

# ---------------------------------------------------------------------------
# Log configuration
# ---------------------------------------------------------------------------
readonly CTX_GATE_LOG="$HOME/.claude/logs/ctx-gate.log"
readonly CTX_GATE_LOG_MAX=32768

# ---------------------------------------------------------------------------
# Kill-switch (per Round 3 reviewer A #12 / B #7):
# If anything goes wrong in production, set this env var to disable ALL gating
# without editing settings.json.
#
# Usage from terminal: `export CLAUDE_CTX_GATE_DISABLED=1` BEFORE launching `claude`.
#
# IMPORTANT (per R4 meta-pass): each hook script MUST check this env var itself at the
# very top before any other logic; this lib does NOT enforce it. The check shape,
# copy-pasted into each hook:
#   [ "${CLAUDE_CTX_GATE_DISABLED:-0}" = "1" ] && exit 0
#
# All four hooks (prompt-submit, pretooluse, precompact-safety, post-compact-primer)
# must have it. Sourcing this lib does NOT enforce the kill-switch.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Tool allowlist for PreToolUse during hard gate
# ---------------------------------------------------------------------------
# Tools the model is allowed to use while it works on /pre-compact.
# Everything else receives permissionDecision: deny.
# Tested against tool_name (exact string from PreToolUse input).
#
# NOTE: includes both `Skill` AND `Task` defensively until Task 0.b confirms which
# one Claude Code uses for slash-command invocations. The deadlock risk of denying
# /pre-compact itself is far worse than the slight surface expansion.
readonly CTX_GATE_TOOL_ALLOWLIST_REGEX='^(Skill|Task|Read|Agent|TaskList|TaskGet|TaskCreate|TaskUpdate|TaskOutput)$'

# ---------------------------------------------------------------------------
# Bash allowlist
# ---------------------------------------------------------------------------
# Only checked when tool_name == "Bash" — substring match on tool_input.command.
# Allows arming, git read-only, basic file inspection.
#
# Tightened per Round 2 reviewer B #5 + B #12:
#   - removed bare `cat` (was an exfiltration hole: `cat ~/.ssh/id_rsa` matched)
#   - allowlist patterns ALL anchored to start with `^` (or after compound-command
#     pre-check) to prevent `find ... | wc -l` from passing because `wc -l` is in list
#
# Per Round 4 reviewer A #6: leading ` *touch` removed; `touch ` must be at start.
# Compound-command pre-check (further down in pretooluse.sh) closes `||`/`&&`/`;`/`|`
# bypass even for anchored matches.
#
# Per Round 3 reviewer A #4 / B #1: the sourcing path for auto-compact-sentinel.sh
# is explicitly allowlisted so /pre-compact's own bootstrap at ctx ≥90% is not blocked.
readonly CTX_GATE_BASH_ALLOWLIST_REGEX='^(arm-auto-compact\.sh|"?\$HOME"?/\.claude-dotfiles/scripts/hooks/arm-auto-compact\.sh|\. "?\$HOME"?/\.claude-dotfiles/scripts/hooks/lib/auto-compact-sentinel\.sh|git (rev-parse|log|status|diff|branch|show-toplevel)|stat |date|ls |mkdir |jq |wc -[lc]|touch )'

# ---------------------------------------------------------------------------
# Edit/Write allowlist
# ---------------------------------------------------------------------------
# Substring match on tool_input.file_path.
#
# /pre-compact Step 7 writes to $REPO_ROOT/CLAUDE.md which is an ABSOLUTE path.
# The regex must match both relative `./CLAUDE.md` AND absolute `/CLAUDE.md`-terminated
# paths (per Round 1 reviewer A #2). Use no-anchor `CLAUDE\.md$`.
#
# Anchored with `(^|/)` per Round 2 reviewer B #2 to prevent overbroad match.
# Without the anchor, `CLAUDE\.md$` would also match `/path/evilCLAUDE.md`.
readonly CTX_GATE_WRITE_ALLOWLIST_REGEX='((^|/)CLAUDE\.local\.md(\.prev)?$|(^|/)CLAUDE\.md$|(^|/)\.gitignore$|/docs/|/tmp/done-plans/|/tmp/cancelled-plans/|/tmp/briefs/)'

# ---------------------------------------------------------------------------
# Helper: ctx_gate_log <message>
# ---------------------------------------------------------------------------
# Appends timestamped line to ctx-gate.log. Bounded ring (keep last 16KB when >32KB).
# Fail-open: never returns non-zero.
ctx_gate_log() {
  local dir
  dir=$(dirname "$CTX_GATE_LOG")
  [ -d "$dir" ] || { mkdir -p "$dir" 2>/dev/null; chmod 700 "$dir" 2>/dev/null; }
  ( umask 077 && printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$CTX_GATE_LOG" ) 2>/dev/null || return 0
  local size
  size=$(wc -c < "$CTX_GATE_LOG" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$size" ] && [ "$size" -gt "$CTX_GATE_LOG_MAX" ]; then
    local tmp
    tmp="${CTX_GATE_LOG}.tmp.$$"
    ( umask 077 && tail -c $((CTX_GATE_LOG_MAX / 2)) "$CTX_GATE_LOG" > "$tmp" ) 2>/dev/null && mv "$tmp" "$CTX_GATE_LOG" 2>/dev/null
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Helper: ctx_gate_read_pct <sid>
# ---------------------------------------------------------------------------
# Reads ctx% from sidecar file ~/.claude/progress/ctx-<sid>.txt.
# Fail-open: returns empty string (via non-zero exit) if missing or unreadable.
# Hooks that get empty MUST treat as "ctx unknown" and not gate.
ctx_gate_read_pct() {
  local sid="$1" file pct
  file="$HOME/.claude/progress/ctx-${sid}.txt"
  [ -f "$file" ] || return 1
  pct=$(head -c 8 "$file" 2>/dev/null | tr -cd '0-9')
  [ -n "$pct" ] || return 1
  printf '%s' "$pct"
}

# ---------------------------------------------------------------------------
# Helper: ctx_gate_pre_compact_armed <sid>
# ---------------------------------------------------------------------------
# Returns 0 (true) if pre-compact sentinel exists for sid (meaning /pre-compact ran).
ctx_gate_pre_compact_armed() {
  local sid="$1"
  [ -f "$HOME/.claude/progress/auto-compact-${sid}.json" ]
}
