#!/usr/bin/env bash
# 10 — Can a mistyped verb or a flag silently RENAME the window?
#
# main() ended in `return dispatch_set(sid, args)`: anything that was not a known verb became a
# caption AND a peer address. So `--help` did not print help — it renamed the window to "help",
# replacing the address other agents use to reach it, and printed a cheerful success line. That
# happened for real on 2026-08-12, to the window that built this system.
#
# The failure is SILENT (it reports success), it DESTROYS state (the previous address is gone), and
# the shape recurs on every typo, so it is fenced here rather than left to care.
#
# A1 — `--help` exits 0 and prints usage
# A2 — `--help` leaves the peer address untouched
# A3 — an unknown flag exits 2 (not 0) and says why
# A4 — an unknown flag leaves the peer address untouched
# A5 — neither one wrote a caption file
# A6 — POSITIVE CONTROL: a real `set` DOES change the address, so A2/A4 mean "refused", not
#      "the probe cannot see a rename at all"
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): copy the script, delete the two guard branches to
# restore the bare fallthrough, and re-run. A1-A5 must go RED.
set -uo pipefail

GATE="${LINE_AGENT_TESTS_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set LINE_AGENT_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }

REAL_SCRIPT="$HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
[ -f "$REAL_SCRIPT" ] || { echo "INFRA: script not found: $REAL_SCRIPT" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 missing" >&2; exit 3; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER="lac-atest"
RUN_ID="$(python3 -c 'import uuid;print(uuid.uuid4().hex[:12])')"

find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${MARKER}-*" -mmin +60 -exec rm -rf {} + 2>/dev/null

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/${MARKER}-${RUN_ID}-XXXXXX")"
FAKE_HOME="$ROOT/home"
FAKE_PID=""
cleanup() {
  [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null
  rm -rf "$ROOT" 2>/dev/null || echo "CLEANUP WARNING: could not remove $ROOT" >&2
}
trap cleanup EXIT
mkdir -p "$FAKE_HOME/.claude/sessions" "$FAKE_HOME/.claude/session-status"

SCRIPT="$REAL_SCRIPT"
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  SCRIPT="$ROOT/regressed.py"
  cp "$REAL_SCRIPT" "$SCRIPT"
  # Put the bare fallthrough back: strip both guard branches so any argv reaches dispatch_set.
  python3 - "$SCRIPT" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
start = s.index('    if args and args[0] in ("help", "-h", "--help", "-help", "usage"):')
end = s.index('        return _usage(sys.stderr, 2)') + len('        return _usage(sys.stderr, 2)\n')
open(p, "w").write(s[:start] + s[end:])
PY
  grep -q 'return _usage(sys.stderr, 2)' "$SCRIPT" \
    && { echo "INFRA: neg-control patch did not remove the guard - anchors moved" >&2; exit 3; }
fi

# A live process named `claude` so the seeded registry entry is treated as a real window.
# SYMLINK, not copy: macOS SIGKILLs a copied system binary on exec (code-signature check).
ln -s /bin/sleep "$FAKE_HOME/claude" 2>/dev/null || { echo "INFRA: cannot symlink /bin/sleep" >&2; exit 3; }
"$FAKE_HOME/claude" 120 &
FAKE_PID=$!
sleep 0.3
kill -0 "$FAKE_PID" 2>/dev/null || { echo "INFRA: fixture process died immediately" >&2; exit 3; }

PROC_START="$(ps -o lstart= -p "$FAKE_PID" 2>/dev/null | tr -s ' ' | sed 's/^ *//;s/ *$//')"
SID="00000000-0000-4000-8000-${RUN_ID}"
ENTRY="$FAKE_HOME/.claude/sessions/${FAKE_PID}.json"
ORIGINAL_NAME="dentall-zz"
python3 - "$ENTRY" "$FAKE_PID" "$SID" "$PROC_START" "$ORIGINAL_NAME" <<'PY'
import json, sys, time
path, pid, sid, procstart, name = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
entry = {
    "pid": pid, "sessionId": sid, "cwd": "/Users/nobody/dentall",
    "startedAt": int(time.time() * 1000), "procStart": procstart,
    "version": "2.1.228", "peerProtocol": 1, "kind": "interactive",
    "entrypoint": "cli", "name": name, "nameSource": "derived",
    "status": "idle", "updatedAt": int(time.time() * 1000), "bridgeSessionId": None,
}
with open(path, "w") as fh:
    json.dump(entry, fh, separators=(",", ":"))
PY

name_now() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('name',''))" "$ENTRY"; }

FAIL_N=0
FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }

run_lac() {  # run_lac <argv...> -> sets RC / OUT
  OUT="$(HOME="$FAKE_HOME" CLAUDE_SESSION_ID="$SID" python3 "$SCRIPT" "$@" 2>&1)"
  RC=$?
}

# --- A1/A2: --help --------------------------------------------------------------------------------
run_lac --help
[ "$RC" = "0" ] || fail "A1: \`--help\` exited ${RC}, expected 0"
case "$OUT" in
  *"line-agent-communicator.py - name this window"*) ;;
  *) fail "A1: \`--help\` printed no usage; got: $(printf '%s' "$OUT" | head -1)" ;;
esac
[ "$(name_now)" = "$ORIGINAL_NAME" ] \
  || fail "A2: \`--help\` RENAMED the window to '$(name_now)' (was ${ORIGINAL_NAME}) - this is the shipped defect"

# --- A3/A4: an unknown flag -----------------------------------------------------------------------
run_lac --bogus-flag
[ "$RC" = "2" ] || fail "A3: unknown flag exited ${RC}, expected 2 (0 would mean it was accepted as a name)"
case "$OUT" in
  *"unknown option"*) ;;
  *) fail "A3: unknown flag did not say it was unknown; got: $(printf '%s' "$OUT" | head -1)" ;;
esac
[ "$(name_now)" = "$ORIGINAL_NAME" ] \
  || fail "A4: an unknown flag RENAMED the window to '$(name_now)' (was ${ORIGINAL_NAME})"

# --- A5: no caption was written either -------------------------------------------------------------
if [ -e "$FAKE_HOME/.claude/session-status/${SID}.txt" ]; then
  fail "A5: a caption file was written for a refused invocation: $(cat "$FAKE_HOME/.claude/session-status/${SID}.txt")"
fi

# --- A6 positive control: a REAL set still works --------------------------------------------------
run_lac set "billing reconciliation"
if [ "$(name_now)" = "$ORIGINAL_NAME" ]; then
  fail "A6 positive control: a real \`set\` did NOT change the address - the probe cannot detect a rename, so A2/A4 prove nothing"
fi

# --- verdict --------------------------------------------------------------------------------------
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  if [ "$FAIL_N" -gt 0 ]; then
    echo "NEG-CONTROL OK: with the bare fallthrough restored, the assertions went RED (${FAIL_N} failed)"
    printf '%s' "$FAIL_MSGS"
    exit 0
  fi
  echo "NEG-CONTROL BROKEN: assertions stayed GREEN against a deliberately regressed script" >&2
  exit 1
fi

if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 10-verb-fallthrough-rename" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi

cat > "${HERE}/10-verb-fallthrough-rename.fingerprint.json" <<EOF
{"assumption":"an_unknown_verb_or_flag_never_rewrites_the_peer_address","uname":"$(uname -s)","help_exit":0,"unknown_flag_exit":2,"assertions":7}
EOF

echo "PASS: 10-verb-fallthrough-rename - 7 assertions (A1 help x2, A2 no-rename, A3 refusal x2, A4 no-rename, A5 no caption, A6 positive control)"
exit 0
