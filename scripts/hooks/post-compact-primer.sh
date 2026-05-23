#!/usr/bin/env bash
# post-compact-primer.sh — SessionStart hook (matcher: "compact"): post-compact primer.
#
# Fires once after native /compact runs. Emits additionalContext directing the post-compact
# agent to read CLAUDE.local.md → ## Active Skill State + ## Next Action, state which
# skill+phase it's resuming, then proceed.
#
# Cannot block (SessionStart hooks are advisory-only). We trust Opus 4.7 to comply.
# Fail-open on any error (exits 0, no output) so a buggy hook never breaks session start.

set -uo pipefail

[ "${CLAUDE_CTX_GATE_DISABLED:-0}" = "1" ] && exit 0  # kill-switch per Round 3 A #12 / B #7

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/ctx-gate-config.sh
. "$ROOT/lib/ctx-gate-config.sh"

INPUT=$(head -c 1048576)  # bound stdin to 1MB (per codex-review R2 F16: DoS guard)

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null | tr -cd 'A-Za-z0-9_-' | head -c 128)
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)
# Belt-and-suspenders: settings.json matcher should already filter to "compact" sources,
# but guard at runtime too in case matcher is ignored (per Round 1 reviewer A #12 / B #10).
[ "$SOURCE" = "compact" ] || exit 0

CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="$PWD"

# Walk up to the git repo root: per Round 1 reviewer A #12 / reviewer B #10, the SessionStart
# cwd may be a subdirectory of the repo where CLAUDE.local.md was written. Look at cwd first,
# fall back to repo root.
HANDOFF_PATH=""
if [ -f "$CWD/CLAUDE.local.md" ]; then
  HANDOFF_PATH="$CWD/CLAUDE.local.md"
else
  REPO_ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || printf '')
  if [ -n "$REPO_ROOT" ] && [ -f "$REPO_ROOT/CLAUDE.local.md" ]; then
    HANDOFF_PATH="$REPO_ROOT/CLAUDE.local.md"
  fi
fi

if [ -n "$HANDOFF_PATH" ]; then
  MSG="🔄 POST-COMPACT SESSION. A /pre-compact handoff was written to ${HANDOFF_PATH}. Your VERY FIRST action this session — before any tool call, before responding to any prompt — is to:

1. Read ${HANDOFF_PATH} in full.
2. State explicitly which skill+phase you are resuming, from the '## Active Skill State' section (if populated) and '## Next Action' section.
3. If the Active Skill State indicates an in-flight skill (e.g., '/plan mid-review round 2', '/implement mid-phase 3', '/master-review mid-round 4'), re-enter that skill at that phase.
4. Then — and only then — proceed with new work.

Do not assume you remember the prior session. The handoff file is the source of truth."
else
  MSG="🔄 POST-COMPACT SESSION. No CLAUDE.local.md handoff found at \$CWD or repo root. The prior session's /pre-compact may not have run. Proceed with caution and ask the user what they were working on before assuming."
fi

ctx_gate_log "primer sid=${SID:-unknown} source=compact cwd=$CWD handoff=${HANDOFF_PATH:-none}"

# Emit additionalContext as soft-direction backup. The hard channel is the Stop hook
# (auto-compact-after-pre-compact.sh), which chains `/post-compact-resume` into the input
# queue right after `/compact` — Claude Code TUI buffers it during compaction and processes
# it as the next turn once /compact completes. That path is bulletproof: tab-targeted PTY
# writes via AppleScript do_script, no GUI focus dependency, no mount race.
#
# The additionalContext below is just belt — if for any reason `/post-compact-resume`
# didn't get queued (e.g., user ran /compact manually without arming the Stop chain),
# this directive still tells the model where the handoff lives.
jq -n --arg ctx "$MSG" '{ "hookSpecificOutput": { "hookEventName": "SessionStart", "additionalContext": $ctx } }'
exit 0
