#!/usr/bin/env bash
# ctx-gate-config.sh — thresholds and shared helper functions for context-gate hooks.
#
# Post-R2 redesign: three-tier UserPromptSubmit nudge model.
# PreToolUse hook deleted (N4 locked decision — gate never blocks Bash mid-task).
# Allowlist apparatus removed (no consumer post-R2).
# Handoff-lifecycle constants moved to lib/handoff-config.sh.
#
# Idempotent source guard — second sourcing is a no-op (avoids `readonly` redeclaration
# errors if any caller transitively re-sources this lib).
[ -n "${_CTX_GATE_CONFIG_LOADED:-}" ] && return 0
_CTX_GATE_CONFIG_LOADED=1

# ---------------------------------------------------------------------------
# Thresholds (2026-05-28 tuning: 50 SOFT / 65 IMPORTANT / 75 FORCE — code-quality-first)
# ---------------------------------------------------------------------------
# Rationale: LLM accuracy degrades meaningfully past ~70% ctx; original 75/85 thresholds
# let the most critical wrap-up work happen in the worst-quality zone. With the chain
# primitives (lib/handoff-chain.sh) making compactions near-lossless, the cost of compacting
# earlier is small and the quality gain is real. Pre-tuning git tag: ctx-thresholds-pre-tuning-2026-05-28.
#
# _OVERRIDE env-var pattern allows tests and users to set deterministic thresholds
# before sourcing this lib (readonly cannot be re-declared post-source).
readonly CTX_SOFT_PCT="${CTX_SOFT_PCT_OVERRIDE:-50}"           # FYI nudge at next natural seam
readonly CTX_IMPORTANT_PCT="${CTX_IMPORTANT_PCT_OVERRIDE:-65}" # finish current task then /pre-compact
readonly CTX_FORCE_PCT="${CTX_FORCE_PCT_OVERRIDE:-75}"         # FIRST action MUST be /pre-compact

# ---------------------------------------------------------------------------
# Log configuration
# ---------------------------------------------------------------------------
readonly CTX_GATE_LOG="$HOME/.claude/logs/ctx-gate.log"
readonly CTX_GATE_LOG_MAX=32768

# ---------------------------------------------------------------------------
# Kill-switch
# If anything goes wrong in production, set this env var to disable ALL gating
# without editing settings.json.
#
# Usage from terminal: `export CLAUDE_CTX_GATE_DISABLED=1` BEFORE launching `claude`.
#
# Each hook script MUST check this env var itself at the very top before any other
# logic. Sourcing this lib does NOT enforce the kill-switch.
#   [ "${CLAUDE_CTX_GATE_DISABLED:-0}" = "1" ] && exit 0
# ---------------------------------------------------------------------------

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
