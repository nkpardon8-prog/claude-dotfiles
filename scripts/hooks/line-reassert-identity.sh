#!/bin/bash
# line-reassert-identity.sh — async SessionStart hook (startup|resume|clear|compact).
#
# Re-applies this window's PEER ADDRESS from its `/line` caption after a restart.
#
# Why it exists: the two names a window carries are keyed differently. The caption lives at
# ~/.claude/session-status/<sessionId>.txt and SURVIVES a resume; the peer address lives in
# ~/.claude/sessions/<pid>.json and is re-derived by the harness under the NEW pid. So a resumed
# window keeps its caption while its address silently reverts to an auto-generated handle —
# observed live: the window captioned "summit admin hub" came back addressable only as
# `dentall-f9` with nameSource=derived, which is precisely the caption-vs-address divergence
# /line was built to end. Without this hook the fix decays on every restart.
#
# Posture: fail-open everywhere. A hook that breaks session start is worse than a stale name, so
# every failure path exits 0 silently and prints nothing on stdout even on success (this runs async,
# and a name re-assert is not news). It is NOT silent to disk: see the log below.
set -uo pipefail   # NO -e: a missing caption, an absent registry entry, or a malformed session
                   # file are all ORDINARY states here, not errors — each is handled inline and
                   # must not abort the hook mid-way through the checks that follow.

SESSIONS_DIR="$HOME/.claude/sessions"
STATUS_DIR="$HOME/.claude/session-status"
LAC="$HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
LOG="$HOME/.claude/logs/line-reassert.log"

# A hook that is silent on success and silent on failure is UNFALSIFIABLE — there is no way to tell
# "it ran and had nothing to do" from "it never ran at all". That is not hypothetical here: this
# hook first resolved its session id from $CLAUDE_SESSION_ID alone, which the harness does not
# export into hook processes, so it was a permanent no-op that nobody could have noticed (the
# window captioned "summit admin hub" was still nameSource=derived). One line per re-assert makes
# the hook provable; bounded so it can never grow without limit.
log_line() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || return 0
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')" -gt 65536 ] 2>/dev/null; then
    tail -c 32768 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
  fi
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$LOG" 2>/dev/null || true
}

# Session id: stdin JSON FIRST, env vars only as a fallback.
#
# Every sibling SessionStart hook reads it from the hook payload — post-compact-primer.sh takes
# `.session_id` off stdin, stale-handoff-guard.sh does the same — because that is the channel the
# harness actually populates for hooks. $CLAUDE_SESSION_ID is what a Bash TOOL call inherits (which
# is why /line reads it); a hook process is not a tool call. Reading env only made this hook a
# silent no-op. stdin is bounded to 1MB, matching post-compact-primer.sh's DoS guard.
#
# Either way it is the harness's own id — never a transcript-mtime guess, which loses the race
# against sibling tabs and can re-assert one window's name onto another.
INPUT=$(head -c 1048576)
sid=""
if command -v jq >/dev/null 2>&1; then
  sid=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
fi
[ -n "$sid" ] || sid="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
sid=$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -n "$sid" ] || exit 0

[ -f "$LAC" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

caption=$(head -n 1 "$STATUS_DIR/$sid.txt" 2>/dev/null)
caption=$(printf '%s' "$caption" | tr -d '\r')
[ -n "$caption" ] || exit 0   # never /line'd, or the caption was cleared — nothing to re-assert

# Read nameSource for THIS session's registry entry.
#
# jq is still run on ONE file at a time, never over a glob: at least one file in this directory is
# malformed (trailing data past the closing brace) and a multi-file jq aborts the whole pass on the
# first parse error, which would make every window look unregistered. Same tolerance
# load_sessions() already has — so `jq -s` over the glob is not an option here.
#
# What IS fixed is the cost of NOT finding it. The old shape was jq-per-file inside the retry loop:
# 19 session files x 6 attempts = 114 jq processes at session start, all of it on the path where
# the entry does not exist yet. A single `grep -l` narrows the directory to the one file that even
# mentions this sessionId, so each attempt costs 1 grep (+1 jq if there was a hit) instead of 19
# jq. grep is a prefilter ONLY — jq still decides, because a sessionId can appear in a field we do
# not mean (bridgeSessionId), and a substring match must never be allowed to name a window.
name_source=""
attempt=0
while [ "$attempt" -lt 6 ]; do
  # read -r, not `for f in $(...)`: an unquoted command substitution word-splits, and $HOME may
  # contain a space. A here-string keeps the loop in THIS shell, so `break` and the assignment to
  # name_source survive it (a pipe would run the body in a subshell and lose both).
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    got=$(jq -r --arg sid "$sid" \
      'if (.sessionId? // "") == $sid then (.nameSource // "derived") else empty end' \
      "$f" 2>/dev/null)
    if [ -n "$got" ]; then
      name_source="$got"
      break
    fi
  done <<<"$(grep -ls -- "$sid" "$SESSIONS_DIR"/*.json 2>/dev/null)"
  [ -z "$name_source" ] || break
  # The harness writes the entry for the new pid at startup and we may simply be early. Bounded
  # wait — if it never appears, this window has no address to fix and we leave quietly.
  attempt=$((attempt + 1))
  sleep 0.5
done

[ -n "$name_source" ] || exit 0
[ "$name_source" = "explicit" ] && exit 0   # address already survived — nothing diverged

# Re-derive the address from the caption through the SAME code path /line uses, so handle
# slugging and live-collision suffixing stay in one place rather than being reimplemented here.
CLAUDE_SESSION_ID="$sid" python3 "$LAC" set "$caption" >/dev/null 2>&1
rc=$?

# The proof this hook ran. Logged AFTER the work, with the outcome, so the line means "a re-assert
# was attempted for this session" and not merely "the hook was invoked".
log_line "reassert sid=${sid} nameSource=${name_source} caption=$(printf '%s' "$caption" | head -c 60) rc=${rc}"

exit 0
