#!/usr/bin/env bash
# ctx-gate-precompact-safety.sh — PreCompact hook (matcher: "auto"): last-resort safety net.
#
# Execution context: this is a Claude Code PreCompact hook script.
# It runs as a direct subprocess of Claude Code, NOT through the orchestrator Bash tool.
#
# Fires before native auto-compact would run.
# If /pre-compact never ran (no sentinel) AND ctx is below the extreme-release threshold:
#   BLOCK native auto-compact and inject reason directing /pre-compact.
# If ctx ≥ HANDOFF_AUTOCOMPACT_BYPASS_PCT (90%): RELEASE — let native compact run as a degraded
#   fallback. Handoff is lost, but this is preferable to a bricked session that can make
#   no forward progress.
#
# Trade-off: blocking native auto-compact below HANDOFF_AUTOCOMPACT_BYPASS_PCT (90%) leaves
# the session at that level. But the alternative — letting native run with no handoff
# — is exactly what the user said is unacceptable. Blocking gives the model one more
# chance to invoke /pre-compact via the next-turn UserPromptSubmit FORCE nudge.
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
# shellcheck source=lib/handoff-config.sh
. "$ROOT/lib/handoff-config.sh"

# H13 (Theme 5): explicit default for HANDOFF_AUTOCOMPACT_BYPASS_PCT.
# If lib/handoff-config.sh fails to source, HANDOFF_AUTOCOMPACT_BYPASS_PCT is unset.
# An unset variable in the [ "$PCT" -ge "$HANDOFF_AUTOCOMPACT_BYPASS_PCT" ] test would
# silently evaluate to 0, causing the BLOCK branch to fire even at 99% context — deadlock.
# Explicit default here ensures the release threshold is always defined.
: "${HANDOFF_AUTOCOMPACT_BYPASS_PCT:=90}"

INPUT=$(head -c 1048576)  # bound stdin to 1MB (DoS guard)

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
# Symlink rejection — defense against path-swap attacks (same-UID sentinel forgery).
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
# Do NOT block unconditionally — at extreme contexts, blocking native compact leaves a
# worst-of-both state. Decision matrix:
#   - PCT below HANDOFF_AUTOCOMPACT_BYPASS_PCT (90%): BLOCK native compact, advise /pre-compact.
#     The model still has plenty of context to run /pre-compact via the UserPromptSubmit
#     FORCE nudge which fires at 85%.
#   - PCT >= HANDOFF_AUTOCOMPACT_BYPASS_PCT (90%+): RELEASE — let native auto-compact happen
#     as a degraded fallback. Yes, the handoff is lost, but this is preferable to a bricked
#     session that cannot make any forward progress.
PCT=$(ctx_gate_read_pct "$SID") || PCT="?"

# H13 (R4 Phase 3): PCT=? (unknown) is now fail-OPEN. Previously PCT=? fell through to
# the BLOCK branch, causing a deadlock at 95%+ when the ctx-sidecar file is unreadable.
# A blocked session at 95%+ with an unreadable sidecar cannot recover — worse than losing
# the handoff. If we cannot read PCT, release and let native compact proceed.
if [ "$PCT" = "?" ]; then
  ctx_gate_log "precompact sid=$SID pct=? trigger=auto action=release-pct-unknown reason=fail-open"
  exit 0  # PCT unknown — fail-open; let native compact run rather than deadlock
fi

if [ "$PCT" -ge "$HANDOFF_AUTOCOMPACT_BYPASS_PCT" ]; then
  ctx_gate_log "precompact sid=$SID pct=$PCT trigger=auto action=release-extreme-pct"
  exit 0  # let native compact run; handoff lost but better than deadlock
fi

# R5 H3: updated wording — removed reference to CLAUDE.local.md alias (dead post-R4 D1);
# /pre-compact now writes a SID-tagged file (CLAUDE.local.<sid8>.md) as the ONLY handoff output.
REASON="Native auto-compact blocked: /pre-compact was never invoked, so handoff would be lost. Context: ${PCT}%. Invoke Skill(pre-compact) NOW to write the SID-tagged handoff file, arm the auto-compact sentinel, and let the Stop hook deliver a clean /compact instead. (At ${HANDOFF_AUTOCOMPACT_BYPASS_PCT}% this safety net releases so the session can recover via native compaction.)"
ctx_gate_log "precompact sid=$SID pct=$PCT trigger=auto action=block"

jq -n --arg r "$REASON" '{ "decision": "block", "reason": $r }'
exit 0
