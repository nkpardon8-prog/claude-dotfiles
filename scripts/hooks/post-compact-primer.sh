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

# Emit additionalContext (belt — soft directive, model SHOULD comply)
jq -n --arg ctx "$MSG" '{ "hookSpecificOutput": { "hookEventName": "SessionStart", "additionalContext": $ctx } }'

# ── PTY injection (suspenders — hard channel, model MUST respond) ─────────────
# Per user 2026-05-23: additionalContext alone is soft (model can ignore). To make handoff
# bulletproof, ALSO type a real user-prompt into the just-compacted Terminal.app tab via the
# same AppleScript `do script` pattern that fires `/compact`. The agent then sees an actual
# user message it MUST respond to — not a passive context hint.
#
# Test-mode guard: when CLAUDE_CTX_GATE_SMOKE_ALLOW=true (set by test-ctx-gate.sh), skip
# the destructive AppleScript fire. Test harness can still exercise the rest of the path
# by checking the log line that says "test-mode skip-injection".
if [ "${CLAUDE_CTX_GATE_SMOKE_ALLOW:-}" = "true" ]; then
  ctx_gate_log "primer sid=${SID:-unknown} action=test-mode-skip-injection"
  exit 0
fi

# Platform gates (mirror arm-auto-compact.sh): Darwin only, Terminal.app only, no tmux/screen.
# Brace-group `||`/`&&` precedence trap fix (same as R1 pretooluse fix):
# `[ X ] || [ Y ] && exit 0` parses as `[ X ] || ([ Y ] && exit 0)` — if X is non-empty,
# the `&&` chain is never reached. Wrap the OR in braces.
[ "$(uname -s)" = "Darwin" ] || exit 0
{ [ -n "${TMUX:-}" ] || [ -n "${STY:-}" ]; } && exit 0
{ [ -n "${TERM_PROGRAM:-}" ] && [ "${TERM_PROGRAM:-}" != "Apple_Terminal" ]; } && exit 0

# Skip injection if no handoff was written (nothing useful to navigate to).
[ -z "$HANDOFF_PATH" ] && exit 0

# Resolve the originating TTY by walking up the process tree (this hook runs in a bash
# subprocess; the parent claude CLI process owns the controlling TTY).
ORIG_TTY=""
CHECK_PID="$PPID"
for _hop in 1 2 3 4 5; do
  [ -z "$CHECK_PID" ] && break
  if [ "$CHECK_PID" = "0" ] || [ "$CHECK_PID" = "1" ]; then break; fi
  RAW_TTY=$(ps -o tty= -p "$CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  case "$RAW_TTY" in
    ttys[0-9]*) ORIG_TTY="/dev/$RAW_TTY"; break ;;
  esac
  CHECK_PID=$(ps -o ppid= -p "$CHECK_PID" 2>/dev/null | tr -d '[:space:]')
done
# Validate TTY format (defense-in-depth — same as ac_validate_tty)
case "$ORIG_TTY" in
  /dev/ttys[0-9]*) : ;;
  *) ctx_gate_log "primer sid=${SID:-unknown} action=skip-inject reason=no-tty"; exit 0 ;;
esac

# Compose the navigation prompt. Keep it short — long prompts increase the window where
# the user could collide with their own typing.
NAV_PROMPT="Resume session from ${HANDOFF_PATH}. Read it now, state the skill+phase you're picking up from \"## Active Skill State\" and \"## Next Action\", then continue exactly where the prior session left off."

# First-prod-test finding (2026-05-23): `do script` typed the text into the new (just-
# compacted) session's input box but the trailing CR was consumed by the TUI's mount
# sequence — text landed, submit didn't. User had to press Enter manually.
#
# Defensive fix: (1) sleep before firing so TUI fully mounts its input handler;
# (2) after `do script`, fire an explicit hardware-level Return via System Events
# key code 36 — that's a real key event, not a pasted CR, so the TUI treats it as submit
# regardless of multi-line mode or startup race.
sleep 2

OSA_RESULT=$(/usr/bin/osascript - "$ORIG_TTY" "$NAV_PROMPT" <<'OSA_EOF' 2>/dev/null
on run argv
  set targetTTY to item 1 of argv
  set navPrompt to item 2 of argv
  set foundTab to missing value
  tell application "Terminal"
    if not running then return "not-running"
    if not (exists window 1) then return "no-windows"
    repeat with w in windows
      repeat with t in tabs of w
        try
          if (tty of t) is targetTTY then
            set foundTab to t
            exit repeat
          end if
        end try
      end repeat
      if foundTab is not missing value then exit repeat
    end repeat
    if foundTab is missing value then return "no-matching-tab"
    do script navPrompt in foundTab
    delay 0.8
    activate
    set frontmost to true
    try
      set selected of foundTab to true
    end try
  end tell
  delay 0.3
  try
    tell application "System Events"
      key code 36
    end tell
    return "fired+submitted"
  on error errMsg
    return "fired-no-submit:" & errMsg
  end try
end run
OSA_EOF
)
ctx_gate_log "primer sid=${SID:-unknown} action=inject-nav-prompt tty=$ORIG_TTY result=${OSA_RESULT:-empty}"
exit 0
