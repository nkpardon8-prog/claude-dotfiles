#!/usr/bin/env bash
# ctx-gate-on-pretooluse.sh — PreToolUse hook: hard-zone tool denial with allowlist.
#
# At ctx ≥90% with no armed sentinel, denies any tool not on the allowlist.
# Allowlist: Skill, Task*, Read, Agent, Bash(read-only/arm subset), Edit/Write(handoff paths).
# Sentinel-fresh (< 30 min) releases the gate entirely — /pre-compact already ran.
# Fail-open on any error (exits 0, no output) so a buggy gate never blocks tools.

set -uo pipefail

[ "${CLAUDE_CTX_GATE_DISABLED:-0}" = "1" ] && exit 0  # kill-switch per Round 3 A #12 / B #7

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/ctx-gate-config.sh
. "$ROOT/lib/ctx-gate-config.sh"

INPUT=$(cat)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | head -c 128)
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# Bash operator-precedence trap: `[ a ] || [ b ] && exit 0` binds as `[ a ] || ([ b ] && exit 0)`.
# Use explicit grouping to exit when EITHER is empty (per Round 1).
{ [ -z "$SID" ] || [ -z "$TOOL" ]; } && exit 0

# Sub-agent handling (per Round 2 reviewer A #1 / B #7): the fields `.subagent` and `.agent_type`
# are NOT documented Claude Code PreToolUse JSON fields. The earlier draft installed a dead-code
# guard checking these. Task 0.c determines the truth at the field level:
#   - If 0.c confirms main-agent PreToolUse NEVER fires on sub-agent tool calls (the documented
#     expectation), this guard is unnecessary — DELETE this entire block during Task 6.
#   - If 0.c shows sub-agent calls DO fire main-agent PreToolUse, Task 6 must replace this block
#     with whatever real field 0.c surfaces (e.g., maybe `.tool_input.subagent_type` indicates
#     a Task tool call from main agent, which means we're not in sub-agent context — different signal).
# Until Task 0.c data is in, the safest default is: do nothing here, rely on the allowlist
# (Read, Agent, Task* are all already on the allowlist, so sub-agent dispatch from /pre-compact
# Step 3C will use Read which IS allowed — verify this is sufficient via §2.5 + live test).

PCT=$(ctx_gate_read_pct "$SID") || exit 0
[ "$PCT" -lt "$CTX_HARD_PCT" ] && exit 0  # below hard zone, no gating

# Sentinel staleness check (per Round 1 reviewer B #8): a sentinel armed long ago in a
# prior /pre-compact run shouldn't grant infinite gate-release if ctx climbs again.
# If sentinel present AND younger than 30 min, release. If older, treat as stale and re-gate.
# Per Round 3 reviewer A #9 / B #2: guard stat failures so a deleted file doesn't produce
# astronomical S_AGE (which would be > 1800 and trigger false stale-reengage).
SENTINEL_PATH="$HOME/.claude/progress/auto-compact-${SID}.json"
if [ -f "$SENTINEL_PATH" ]; then
  S_MTIME=$(stat -f %m "$SENTINEL_PATH" 2>/dev/null || stat -c %Y "$SENTINEL_PATH" 2>/dev/null || printf '')
  if [ -n "$S_MTIME" ]; then
    S_AGE=$(( $(date +%s) - S_MTIME ))
    if [ "$S_AGE" -lt 1800 ]; then
      ctx_gate_log "pretool sid=$SID pct=$PCT tool=$TOOL action=allow-sentinel-fresh age=${S_AGE}s"
      exit 0
    fi
    ctx_gate_log "pretool sid=$SID pct=$PCT tool=$TOOL action=stale-sentinel age=${S_AGE}s reenforcing"
  else
    # stat failed — treat as fresh (allow), better than false re-gate.
    ctx_gate_log "pretool sid=$SID pct=$PCT tool=$TOOL action=allow-sentinel-stat-failed-assume-fresh"
    exit 0
  fi
fi

# Round 2 reviewer A #7 / B #6 caught a dangerous interaction: a previous draft of this hook
# released ALL tools at ≥95% as an "escape hatch" AT THE SAME TIME the PreCompact safety net
# blocked native compaction. Net effect: at 96% all tools unblocked AND can't compact = worst-case.
# Fix: at ≥95%, fall through to the normal allowlist check (NOT a blanket release). The model
# can still invoke Skill/Read/Agent/handoff-Write to run /pre-compact. If even that doesn't work,
# the user must intervene — the PreCompact safety net is meant to BLOCK destructive automatic
# compaction, not to unblock everything in the hope the model will recover.
# (See ctx-gate-precompact-safety.sh for the matching change.)

# Sentinel absent + ctx ≥ hard gate: enforce allowlist.
ALLOWED=0
if printf '%s' "$TOOL" | grep -qE "$CTX_GATE_TOOL_ALLOWLIST_REGEX"; then
  ALLOWED=1
elif [ "$TOOL" = "Bash" ]; then
  # Per codex-review round 1 (Depth/Adversary): drop the `head -c 500` truncation — payload
  # after byte 500 was hiding destructive tails from the compound pre-check, allowing
  # `<499 chars of allowlisted prefix> > /etc/foo` bypass.
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  # Compound-command pre-check — hardened against:
  #  - `cmd1|cmd2` and `cmd1;cmd2` with NO surrounding spaces (was bypassable)
  #  - `cmd1;;cmd2` double-semicolon (was bypassable)
  #  - `${IFS}` field-separator splitting trick
  #  - `>` at end of input with nothing after (was bypassable when trailing)
  #  - trailing `>` with anything but a digit/& after (catches `>file`, allows `2>&1`, `>&2`)
  # Allowed `2>&1`, `>&N`, `N>&M` fd-redirects remain unblocked.
  if printf '%s' "$CMD" | grep -qE '(&&|\|\||\||;|sudo |rm -[rRf]|chmod |chown |[^0-9&]>[^&]|^>|>$|>>|\$\(|\$\{IFS\}|`)'; then
    ALLOWED=0  # explicit reset; deny on chained / piped / destructive
  elif printf '%s' "$CMD" | grep -qE "$CTX_GATE_BASH_ALLOWLIST_REGEX"; then
    ALLOWED=1
  fi
elif [ "$TOOL" = "Edit" ] || [ "$TOOL" = "Write" ]; then
  FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null | head -c 500)
  printf '%s' "$FP" | grep -qE "$CTX_GATE_WRITE_ALLOWLIST_REGEX" && ALLOWED=1
elif [ "$TOOL" = "MultiEdit" ]; then
  # Per Round 4 reviewer B #5: MultiEdit's tool_input uses `file_path` at the top level (same as Edit)
  # in current Claude Code — verify in Task 0.b alongside Skill/Task. The path lookup is the same;
  # this branch exists only to be explicit if MultiEdit's schema diverges.
  FP=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null | head -c 500)
  printf '%s' "$FP" | grep -qE "$CTX_GATE_WRITE_ALLOWLIST_REGEX" && ALLOWED=1
fi

if [ "$ALLOWED" = "1" ]; then
  ctx_gate_log "pretool sid=$SID pct=$PCT tool=$TOOL action=allow-allowlist"
  exit 0
fi

# Deny.
REASON="Hard context gate active (ctx ${PCT}% ≥ ${CTX_HARD_PCT}%, pre-compact sentinel not yet armed). Tool '${TOOL}' is not on the gate allowlist. To proceed, invoke Skill(pre-compact) — it will write CLAUDE.local.md, arm the auto-compact sentinel, and release this gate. Allowed during gate: Skill, Read, Agent, Task* (progress), arm-auto-compact, git read-only Bash, writes to handoff paths (CLAUDE.local.md, CLAUDE.md, .gitignore, docs/, tmp/done-plans/)."
ctx_gate_log "pretool sid=$SID pct=$PCT tool=$TOOL action=deny"

jq -n --arg r "$REASON" '{ "hookSpecificOutput": { "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": $r } }'
exit 0
