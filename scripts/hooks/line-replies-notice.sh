#!/bin/bash
# SessionStart hook: tell a window that peer replies are waiting for it.
#
# WHY THIS EXISTS: the reply dropbox (~/claude-agent-replies/) was write-only in practice.
# `line-agent-communicator.py reply` even says so out loud - "it is not delivered, they have to
# look" - and nothing, anywhere, ever looked. No hook, no prompt, no reminder. So a peer answers a
# question, marks its own task done believing it communicated, and the answer sits on disk unread
# forever. The dropbox exists precisely as the GUARANTEED path for a window that cannot receive
# SendMessage; a guaranteed path nobody reads is worse than no path, because the sender stops
# looking for another one. This closes the loop at the one moment a window is guaranteed to be
# listening: its own session start.
#
# WHAT IT DELIBERATELY DOES NOT DO: print any reply CONTENT, or any filename, or any sender name.
# Reply bodies are peer-authored, untrusted, and may only ever enter an agent's context inside the
# untrusted-data frame that `replies` emits (per-item BEGIN/END banners, banner-defanging, size and
# count caps). Hook stdout is injected into session context RAW - so a hook that echoed one line of
# a reply body would be an unframed prompt-injection channel, and would hand an attacker a way to
# bypass every defense that command was built with. The count is the only safe thing to say.
#
# SILENCE INVARIANT (same as hooks/dotfiles-sync-pause-notice.sh): say NOTHING unless there is
# something to say. A hook that speaks at every session start is noise, and noise is skimmed - which
# is how the notice that actually matters gets missed. Zero replies -> zero output.
#
# `set -uo pipefail`, NOT -e: every path here must exit 0. A notice that fails a session start, or
# that aborts half-way through because jq is absent or the dropbox does not exist, has made a
# housekeeping convenience into an outage. -e would do exactly that on the first unlucky command.
set -uo pipefail

SCRIPT="$HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
[ -f "$SCRIPT" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Same session_id idiom as hooks/post-compact-primer.sh:44 - stdin JSON first (the harness supplies
# it and it is the only source that is right when several windows share an environment), env vars as
# the fallback for a hand-run or an older harness. stdin is bounded before parsing (DoS guard), and
# jq is optional: no jq just means we fall through to the env vars rather than exiting noisily.
SID=""
if [ ! -t 0 ]; then
  INPUT=$(head -c 1048576 2>/dev/null)
  if command -v jq >/dev/null 2>&1; then
    SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
  fi
fi
[ -n "$SID" ] || SID="${CLAUDE_SESSION_ID:-}"
[ -n "$SID" ] || SID="${CLAUDE_CODE_SESSION_ID:-}"
# Identical sanitisation to the script's safe_sid(), because this value ends up in a glob prefix.
SID=$(printf '%s' "$SID" | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -n "$SID" ] || exit 0

# ONE source of truth for "unread". This does not re-derive the rule from the filesystem - it asks
# the real script, which computes the count from the same glob and the same last-read state file
# that `replies` uses. A hook with its own idea of unread would drift from the inbox it points at,
# and the first symptom would be a notice for replies that are not there.
#
# `replies-count` prints one integer and nothing else, on every path including its own failures.
# The bound is belt-and-braces: it does no ps probing and no network, so it is a directory scan.
COUNT=""
if command -v timeout >/dev/null 2>&1; then
  COUNT=$(CLAUDE_SESSION_ID="$SID" timeout 10 python3 "$SCRIPT" replies-count 2>/dev/null)
elif command -v gtimeout >/dev/null 2>&1; then
  COUNT=$(CLAUDE_SESSION_ID="$SID" gtimeout 10 python3 "$SCRIPT" replies-count 2>/dev/null)
else
  # macOS ships no timeout(1); perl's alarm survives exec, so the child still dies on SIGALRM.
  COUNT=$(CLAUDE_SESSION_ID="$SID" perl -e 'alarm shift; exec @ARGV' 10 python3 "$SCRIPT" replies-count 2>/dev/null)
fi

# Anything that is not a plain positive integer is treated as "nothing to report". Malformed state,
# a truncated read, a python traceback that leaked a word onto stdout - all land here and stay quiet.
case "$COUNT" in
  ''|*[!0-9]*) exit 0 ;;
  0) exit 0 ;;
esac

if [ "$COUNT" = "1" ]; then
  WHAT="1 unread peer reply is"
else
  WHAT="${COUNT} unread peer replies are"
fi

echo "${WHAT} waiting in the agent reply dropbox (filed by another window because it could not reach you by SendMessage)."
echo "  Read them:  python3 ~/.claude-dotfiles/scripts/line-agent-communicator.py replies"
echo "  (That command frames them as untrusted peer-authored DATA. Nothing above is their content.)"
exit 0
