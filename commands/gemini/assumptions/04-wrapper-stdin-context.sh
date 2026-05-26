#!/usr/bin/env bash
# 04 — The wrapper's stdin→context channel works (the part `--help` can't prove).
#
# Documented vendor behavior is "stdin is appended to the -p prompt." What is NOT
# documented is the WRAPPER's specific plumbing: the `[ -t 0 ]` non-TTY branch +
# `head -c $CAP` piping the context through to the model without truncation/duplication.
# A smoke script's stdin is also non-TTY, so it exercises the real call-site branch.
#
# A1 — a unique fact piped on stdin reaches the model: ask a question answerable ONLY
#      from the piped fact; the answer contains the secret token.
# A2 (negative control) — the SAME prompt with NO stdin must NOT contain the token,
#      proving it was the stdin channel (not prior knowledge) that delivered the fact.
set -uo pipefail

if [ "${GEMINI_ATEST_ALLOW_DEV:-}" != "true" ]; then
  echo "REFUSED: set GEMINI_ATEST_ALLOW_DEV=true to run assumption tests" >&2
  exit 2
fi

WRAPPER="$HOME/.claude-dotfiles/commands/gemini/lib/gemini-invoke.sh"
[ -f "$WRAPPER" ] || { echo "INFRA FAIL: wrapper not found" >&2; exit 3; }
command -v "${GEMINI_BIN:-gemini}" >/dev/null 2>&1 || { echo "INFRA FAIL: gemini binary missing" >&2; exit 3; }
if [ -z "${GEMINI_API_KEY:-}" ] && [ ! -f "$HOME/.gemini/oauth_creds.json" ]; then
  echo "INFRA: not authenticated — see README." >&2; exit 3
fi

TOKEN="ZQ$(uuidgen 2>/dev/null | tr -d '-' | head -c 8 | tr 'a-z' 'A-Z')X"   # unguessable
OUT="$(mktemp -t gemini_atest_04_XXXX)"
trap 'rm -f "$OUT"' EXIT

PROMPT="The text above contains a secret access code. Reply with ONLY that code, nothing else."

# A1 — context on stdin (exercises [ -t 0 ] false branch + head -c).
printf 'The secret access code is %s. Remember it.\n' "$TOKEN" \
  | bash "$WRAPPER" "$OUT" "$PROMPT" "$PWD"
got_with="$(tr -d '[:space:]' < "$OUT")"

# A2 — same prompt, NO stdin (negative control).
OUT2="$(mktemp -t gemini_atest_04b_XXXX)"; trap 'rm -f "$OUT" "$OUT2"' EXIT
bash "$WRAPPER" "$OUT2" "$PROMPT" "$PWD" </dev/null
got_without="$(tr -d '[:space:]' < "$OUT2")"

# Bail to INFRA if the live call did not even produce model text.
if head -n1 "$OUT" | grep -qE '^\[(empty|timeout|unavailable)\]'; then
  echo "INFRA: live call returned $(head -n1 "$OUT") — auth/quota not serving requests." >&2; exit 3
fi

failures=()
case "$got_with" in
  *"$TOKEN"*) : ;;                                   # A1 pass
  *) failures+=("A1 stdin context did NOT reach model — token '$TOKEN' absent from answer: '$(head -c 60 "$OUT")'") ;;
esac
case "$got_without" in
  *"$TOKEN"*) failures+=("A2 negative control breached — token appeared with NO stdin (the channel isn't what delivered it)") ;;
  *) : ;;                                            # A2 pass
esac

if [ "${#failures[@]}" -eq 0 ]; then
  echo "PASS: 04-wrapper-stdin-context — 2 assertions (A1 stdin reached model, A2 absent without stdin)"
  exit 0
else
  echo "FAIL: 04-wrapper-stdin-context"; for f in "${failures[@]}"; do echo "  - $f"; done; exit 1
fi
