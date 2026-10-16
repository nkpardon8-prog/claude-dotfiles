#!/usr/bin/env bash
# 18 - Does every window's Remote Control title end up equal to its peer address?
#
# SendMessage on the owner's OTHER Mac resolves a window by its Remote Control title. Until
# 2026-10-16 that title came from a Stop hook typing `/rename` into a Terminal.app tab, so in Pane
# (and iTerm, tmux) it never happened: the MacBook's windows sat under titles like
# `macbookair-m4-local-clever-marble` and SendMessage("online-docker") from the mini answered
# "No agent named 'online-docker' is reachable". `session-title` is now a UserPromptSubmit +
# SessionStart hook whose `hookSpecificOutput.sessionTitle` output Claude Code applies like /rename.
#
# T1  unnamed window, no title          -> emits its registry name (owner: EVERY window gets one)
# T2  title already equal               -> emits nothing (no record written per prompt)
# T3  captioned window, sentence title  -> emits the short handle, not the sentence (owner)
# T4  `/line Front Desk --owns x`       -> predicts EXACTLY the address `set` then writes, before
#                                          /line's own Bash runs - with a live window already
#                                          holding `front-desk`, so the -2 suffix must match too
# T5  `/line --help`                    -> no new name from a refused flag
# T6  `/rename ...` prompt              -> emits nothing (the owner is naming it by hand this turn)
# T7  SessionStart resume, title equal  -> emits anyway (a reopen resets the Remote Control title)
# T8  SessionStart compact              -> emits nothing (sessionTitle only applies on startup/resume/fork)
# T9  garbage stdin / unknown session   -> exit 0, empty stdout (fail-open, never blocks a prompt)
# T10 the hook is read-only             -> registry entries and caption byte-identical after T1-T9
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): copy the script and make it ignore the /line prompt
# (predict from the old caption). T4 must go red - proving T4 tests the prediction, not luck.
set -uo pipefail

GATE="${LINE_AGENT_TESTS_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set LINE_AGENT_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }

REAL_SCRIPT="$HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
[ -f "$REAL_SCRIPT" ] || { echo "INFRA: script not found: $REAL_SCRIPT" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 missing" >&2; exit 3; }

MARKER="lac-atest"
RUN_ID="$(python3 -c 'import uuid;print(uuid.uuid4().hex[:12])')"
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${MARKER}-*" -mmin +60 -exec rm -rf {} + 2>/dev/null

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/${MARKER}-${RUN_ID}-XXXXXX")"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "INFRA: mktemp -d failed; refusing to run unsandboxed" >&2; exit 3; }
FAKE_HOME="$ROOT/home"
PIDS_FILE="$ROOT/pids"   # seed() runs in $(...), so its pids are collected through a file
cleanup() {
  # Braces + 2>/dev/null: otherwise the shell prints a "Terminated: 15" job notice under the verdict.
  for p in $(cat "$PIDS_FILE" 2>/dev/null); do { kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; } 2>/dev/null; done
  rm -rf "$ROOT" 2>/dev/null || echo "CLEANUP WARNING: could not remove $ROOT" >&2
}
trap cleanup EXIT
mkdir -p "$FAKE_HOME/.claude/sessions" "$FAKE_HOME/.claude/session-status"

SCRIPT="$REAL_SCRIPT"
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  SCRIPT="$ROOT/regressed.py"
  cp "$REAL_SCRIPT" "$SCRIPT"
  python3 - "$SCRIPT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
a = "    sentence = line_prompt_sentence(prompt)\n"
if a not in s:
    sys.exit(3)
open(p, "w").write(s.replace(a, '    sentence = ""\n', 1))
PY
  [ $? -eq 0 ] || { echo "INFRA: neg-control anchor moved" >&2; exit 3; }
fi

# Live processes named `claude` so seeded registry entries count as real windows.
# SYMLINK, not copy: macOS SIGKILLs a copied system binary on exec (code-signature check).
ln -s /bin/sleep "$FAKE_HOME/claude" 2>/dev/null || { echo "INFRA: cannot symlink /bin/sleep" >&2; exit 3; }

seed() {  # seed <sid> <name> <nameSource> -> prints the registry file path
  "$FAKE_HOME/claude" 120 >/dev/null 2>&1 &   # detached stdout, or $(seed) waits 120 s for it
  local pid=$!
  echo "$pid" >> "$PIDS_FILE"
  sleep 0.2
  kill -0 "$pid" 2>/dev/null || { echo "INFRA: fixture process died immediately" >&2; exit 3; }
  local start; start="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
  python3 - "$FAKE_HOME/.claude/sessions/${pid}.json" "$pid" "$1" "$start" "$2" "$3" <<'PY'
import json, sys, time
path, pid, sid, procstart, name, source = sys.argv[1], int(sys.argv[2]), *sys.argv[3:]
json.dump({"pid": pid, "sessionId": sid, "cwd": "/Users/nobody/dentall",
           "startedAt": int(time.time() * 1000), "procStart": procstart, "version": "2.1.302",
           "peerProtocol": 1, "kind": "interactive", "entrypoint": "cli", "name": name,
           "nameSource": source, "status": "idle", "updatedAt": int(time.time() * 1000),
           "bridgeSessionId": None}, open(path, "w"), separators=(",", ":"))
PY
  echo "$FAKE_HOME/.claude/sessions/${pid}.json"
}

SID_A="00000000-0000-4000-8000-a${RUN_ID:1}"    # unnamed window
SID_B="00000000-0000-4000-8000-b${RUN_ID:1}"    # captioned window
SID_C="00000000-0000-4000-8000-c${RUN_ID:1}"    # a live window already holding front-desk
ENTRY_A="$(seed "$SID_A" "dentall-zz" "derived")" || exit 3
ENTRY_B="$(seed "$SID_B" "billing-desk" "explicit")" || exit 3
seed "$SID_C" "front-desk" "explicit" >/dev/null || exit 3
printf 'billing desk\n' > "$FAKE_HOME/.claude/session-status/${SID_B}.txt"
SHA0="$(cat "$FAKE_HOME"/.claude/sessions/*.json "$FAKE_HOME"/.claude/session-status/* | shasum | awk '{print $1}')"

FAIL_N=0
FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }

hook() {  # hook <payload-json> -> OUT (stdout), RC
  OUT="$(printf '%s' "$1" | HOME="$FAKE_HOME" python3 "$SCRIPT" session-title 2>/dev/null)"
  RC=$?
}
title_of() { python3 -c 'import json,sys
s=sys.stdin.read().strip()
print(json.loads(s)["hookSpecificOutput"]["sessionTitle"] if s else "")' <<<"$OUT"; }
event_of() { python3 -c 'import json,sys
s=sys.stdin.read().strip()
print(json.loads(s)["hookSpecificOutput"]["hookEventName"] if s else "")' <<<"$OUT"; }
ups() { printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit","prompt":%s%s}' \
  "$1" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")" "${3:+,\"session_title\":\"$3\"}"; }

# T1
hook "$(ups "$SID_A" "hello")"
[ "$RC" = 0 ] && [ "$(title_of)" = "dentall-zz" ] && [ "$(event_of)" = "UserPromptSubmit" ] \
  || fail "T1: unnamed window got '$(title_of)' rc=$RC, expected dentall-zz"
# T2
hook "$(ups "$SID_A" "hello" "dentall-zz")"
[ -z "$OUT" ] || fail "T2: emitted '$OUT' although the title already matched"
# T3
hook "$(ups "$SID_B" "hello" "billing desk")"
[ "$(title_of)" = "billing-desk" ] || fail "T3: captioned window got '$(title_of)', expected billing-desk"
# T5
hook "$(ups "$SID_A" "/line --help" "dentall-zz")"
[ -z "$OUT" ] || fail "T5: a refused flag produced a title: $OUT"
# T6
hook "$(ups "$SID_A" "/rename something else")"
[ -z "$OUT" ] || fail "T6: emitted during a /rename prompt: $OUT"
# T7
hook "{\"session_id\":\"$SID_A\",\"hook_event_name\":\"SessionStart\",\"source\":\"resume\",\"session_title\":\"dentall-zz\"}"
[ "$(title_of)" = "dentall-zz" ] && [ "$(event_of)" = "SessionStart" ] \
  || fail "T7: resume did not re-assert the title (got '$OUT')"
# T8
hook "{\"session_id\":\"$SID_A\",\"hook_event_name\":\"SessionStart\",\"source\":\"compact\"}"
[ -z "$OUT" ] || fail "T8: emitted on compact: $OUT"
# T9
hook "not json"
[ "$RC" = 0 ] && [ -z "$OUT" ] || fail "T9: garbage stdin -> rc=$RC out='$OUT'"
hook '{"session_id":"nope","hook_event_name":"UserPromptSubmit","prompt":"x"}'
[ "$RC" = 0 ] && [ -z "$OUT" ] || fail "T9: unknown session -> rc=$RC out='$OUT'"
# T10
SHA1="$(cat "$FAKE_HOME"/.claude/sessions/*.json "$FAKE_HOME"/.claude/session-status/* | shasum | awk '{print $1}')"
[ "$SHA0" = "$SHA1" ] || fail "T10: the hook modified the registry or a caption"

# T4 last: it runs the real `set`, which does write.
hook "$(ups "$SID_A" "/line Front Desk --owns check-in" "dentall-zz")"
PREDICTED="$(title_of)"
HOME="$FAKE_HOME" CLAUDE_SESSION_ID="$SID_A" python3 "$SCRIPT" set "Front Desk --owns check-in" >/dev/null 2>&1
WRITTEN="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('name',''))" "$ENTRY_A")"
[ "$WRITTEN" = "front-desk-2" ] || fail "T4: fixture check - set wrote '$WRITTEN', expected front-desk-2"
[ -n "$PREDICTED" ] && [ "$PREDICTED" = "$WRITTEN" ] \
  || fail "T4: /line prompt predicted '$PREDICTED' but set wrote '$WRITTEN'"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  case "$FAIL_MSGS" in
    *"T4: /line prompt predicted"*)
      echo "NEG-CONTROL OK: with the /line prediction removed, T4 went RED"; exit 0 ;;
  esac
  echo "NEG-CONTROL BROKEN: T4 stayed green against a script that ignores /line prompts" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi

if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 18-session-title" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi
echo "PASS: 18-session-title - 10 assertions (T1-T3 names, T4 /line prediction == set, T5-T9 no-ops, T10 read-only)"
exit 0
