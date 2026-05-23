#!/usr/bin/env bash
# ctx-gate-precompact-safety.sh — PreCompact hook (matcher: "auto"): last-resort safety net.
#
# Fires before native auto-compact would run.
# If /pre-compact never ran (no sentinel) AND ctx is below the extreme-release threshold:
#   BLOCK native auto-compact and inject reason directing /pre-compact.
# If ctx ≥ CTX_PRECOMPACT_SAFETY_PCT (95%): RELEASE — let native compact run as a degraded
#   fallback. Handoff is lost, but this is preferable to a bricked session that can make
#   no forward progress.
#
# Trade-off: blocking native auto-compact when context is at 90-94% leaves the session at
# that level. But the alternative — letting native run with no handoff — is exactly what
# the user said is unacceptable. Blocking gives the model one more chance to invoke
# /pre-compact via the next-turn hard gate.
#
# Only fires when trigger is "auto" — manual /compact (user explicit) is NEVER blocked.
# Fail-open on any error (exits 0, no block output) so a buggy gate never bricks the session.

set -uo pipefail

# Per codex-review round 1 Adversary: kill-switch must fire BEFORE sourcing config lib —
# a broken lib could trip set -u and abort before the kill-switch ever runs, leaving the
# user unable to disable the gate even with the documented escape hatch.
[ "${CLAUDE_CTX_GATE_DISABLED:-0}" = "1" ] && exit 0

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/ctx-gate-config.sh
. "$ROOT/lib/ctx-gate-config.sh"

INPUT=$(head -c 1048576)  # bound stdin to 1MB (per codex-review R2 F16: DoS guard)

TRIGGER=$(printf '%s' "$INPUT" | jq -r '.trigger // empty' 2>/dev/null)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | head -c 128)

# Only block "auto" trigger; manual /compact always passes through.
[ "$TRIGGER" = "auto" ] || exit 0
[ -z "$SID" ] && exit 0  # fail-open if no session id

# If sentinel armed AND fresh (<30 min), pre-compact ran recently — let native compact
# proceed (the Stop hook will fire /compact via AppleScript shortly anyway).
# Per codex-review round 1 Gaps: also enforce staleness here, otherwise an ancient sentinel
# from a previous /pre-compact run would falsely release the safety net for native compaction.
SENTINEL_PATH="$HOME/.claude/progress/auto-compact-${SID}.json"
# Symlink rejection (per codex-review R2 F15).
if [ -L "$SENTINEL_PATH" ]; then
  ctx_gate_log "precompact sid=$SID trigger=auto action=reject-symlink-sentinel"
elif [ -f "$SENTINEL_PATH" ]; then
  S_MTIME=$(stat -f %m "$SENTINEL_PATH" 2>/dev/null || stat -c %Y "$SENTINEL_PATH" 2>/dev/null || printf '')
  if [ -n "$S_MTIME" ]; then
    S_AGE=$(( $(date +%s) - S_MTIME ))
    if [ "$S_AGE" -ge 0 ] && [ "$S_AGE" -lt 1800 ]; then
      ctx_gate_log "precompact sid=$SID trigger=auto action=allow-sentinel-fresh age=${S_AGE}s"
      exit 0
    fi
    ctx_gate_log "precompact sid=$SID trigger=auto action=stale-sentinel age=${S_AGE}s reenforcing"
  fi
fi

# Sentinel absent + native trying to auto-compact.
# Round 2 reviewer A #7 / B #6 correction: do NOT block unconditionally above CTX_PRECOMPACT_SAFETY_PCT
# (95%). At extreme contexts, blocking native compact leaves a worst-of-both state where the
# PreToolUse gate would also be enforcing the allowlist — model has no escape AND can't compact.
# Decision matrix:
#   - PCT below CTX_PRECOMPACT_SAFETY_PCT (e.g., 90-94%): BLOCK native compact, advise /pre-compact.
#     The model still has plenty of context to run /pre-compact via the (still-active) PreToolUse
#     allowlist (Skill, Read, Agent are permitted).
#   - PCT ≥ CTX_PRECOMPACT_SAFETY_PCT (95%+): RELEASE — let native auto-compact happen as a
#     degraded fallback. Yes, the handoff is lost (native's summary is what user said is "useless"),
#     but this is preferable to a bricked session that can't make any forward progress.
PCT=$(ctx_gate_read_pct "$SID") || PCT="?"

if [ "$PCT" != "?" ] && [ "$PCT" -ge "$CTX_PRECOMPACT_SAFETY_PCT" ]; then
  ctx_gate_log "precompact sid=$SID pct=$PCT trigger=auto action=release-extreme-pct"
  exit 0  # let native compact run; handoff lost but better than deadlock
fi

REASON="Native auto-compact blocked: /pre-compact was never invoked, so handoff would be lost. Context: ${PCT}%. Invoke Skill(pre-compact) NOW to write CLAUDE.local.md, arm the auto-compact sentinel, and let the Stop hook deliver a clean /compact instead. (At ${CTX_PRECOMPACT_SAFETY_PCT}% this safety net releases so the session can recover via native compaction.)"
ctx_gate_log "precompact sid=$SID pct=$PCT trigger=auto action=block"

jq -n --arg r "$REASON" '{ "decision": "block", "reason": $r }'
exit 0
