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
# Per user 2026-05-23 (first revision): 60/70/85 — "stop new risky work at 60%, wrap up at 70%".
# Per user 2026-05-23 (second revision, medical-grade tightening): tightened further to 50/60/75.
# Rationale: even 60/70 was too late for serious medical-grade production work; past 50% of
# window should stop new risky work; 60% = hard wrap-up zone; 75% = extreme release valve.
readonly CTX_SOFT_PCT=50         # stop new risky work zone (gentle reminder)
readonly CTX_HARD_PCT=60         # wrap-up & hand off zone (hard deny non-handoff tools)
# PreCompact safety net only fires below this; at/above this it releases to avoid
# deadlock (native compact runs as degraded fallback). Dropped from 95 → 85 → 75 to match
# the earlier-compaction posture (medical-grade tightening 2026-05-23 second revision).
readonly CTX_PRECOMPACT_SAFETY_PCT=75

# NEW for Decision F (pre-compact-soundness-hardening plan, R1 finding #6):
# Sessions longer than this are treated as "stale" by the primer and /post-compact-resume.
# Default 24h — 1h false-positives on legitimate overnight sessions, so default to 24h.
# Configurable via env var override (must be set BEFORE sourcing this lib):
#   CTX_STALE_HANDOFF_SECS_OVERRIDE=43200 (12h) in their shell
readonly CTX_STALE_HANDOFF_SECS="${CTX_STALE_HANDOFF_SECS_OVERRIDE:-86400}"

# NEW for legacy-file backwards-compat (R1 meta-pass blind spot, R2 #6 buffer):
# CLAUDE.local.md files with mtime BEFORE this cutoff are treated as "legacy" — absent
# END-OF-HANDOFF marker is acceptable (warn-but-allow rather than refuse). After the
# cutoff, marker absence = file is truncated/corrupt and should be flagged.
#
# Set to 3 days BEFORE implementation date (R2 #6 buffer — prevents flagging
# same-day legitimate files as TRUNCATED):
# - Implementation deploys 2026-05-24 → cutoff = 2026-05-21 00:00:00 UTC = 1779235200
# - Reason: a CLAUDE.local.md written on 2026-05-23 (day before deploy) by the prior
#   /pre-compact version would have mtime > a same-day cutoff, falsely triggering
#   TRUNCATED warnings. The 3-day buffer cleanly separates legacy from recent.
#
# Override-via-env (R2 #2/#3 — `readonly` cannot be overridden post-source; tests need
# this pattern to set deterministic past/future cutoffs):
# R3 #B4 — downgrade escape hatch: if user reverts pre-compact.md to a pre-marker
# version, set CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE=9999999999 to suppress all
# TRUNCATED warnings (makes all files appear "legacy"). See dotfiles README troubleshooting.
readonly CTX_LEGACY_HANDOFF_CUTOFF_EPOCH="${CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE:-1779235200}"  # 2026-05-21 00:00 UTC

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
#
# R3 #B3 + R4 #A6 — DUAL-LOOKUP DESIGN NOTE:
# This function uses SID-keyed lookup (intentional) — only used by the pretooluse hook
# which fires in the SAME session that wrote the sentinel, so SID matches by definition.
# The PRIMER hook uses glob+cwd-match (via ac_read_sentinel_cwd) because it fires in
# DIFFERENT sessions (resume/startup/clear) where the new session SID != sentinel SID.
# Do NOT "fix" this into a glob — the pretooluse use-case is correct as-is.
#
# R4 #A6 edge case: this function uses [ -f ... ] file-existence check only (no schema
# validation). After AC_SCHEMA_VERSION bump to 2 (Task 1.1a), an old in-flight
# schema_version=1 sentinel may still be detected as "armed" here while the primer's
# ac_read_sentinel_cwd correctly skips it as legacy. This inconsistency is bounded:
# (a) the same-session SID guarantee means the sentinel here is always from THIS session
#     (which is post-schema-bump, so v2 with cwd), or
# (b) it is a stale v1 sentinel from before the deploy that has not been pruned yet.
#     In case (b), pretooluse releases the gate but primer skips — model can still invoke
#     /pre-compact normally. Acceptable; documented for clarity.
ctx_gate_pre_compact_armed() {
  local sid="$1"
  [ -f "$HOME/.claude/progress/auto-compact-${sid}.json" ]
}
