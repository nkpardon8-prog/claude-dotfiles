#!/usr/bin/env bash
# 10 — Can a typo rename the window?
#
# Naming is destructive: the peer address is what other windows reach this one by, and setting a new
# one destroys the old with no undo. So anything that is not plainly a name must be REFUSED, never
# adopted. `main()` used to end in a bare `return dispatch_set(sid, args)`, and `--help` renamed this
# window to `help` on 2026-08-12 while printing a success line.
#
# The first fix guarded `main()` only — and review proved that missed the path users actually take:
# `/line`'s body is `... set "${ARGUMENTS:-}"`, so `/line --help` arrives as ["set", "--help"],
# never touches main()'s guard, and renamed the window anyway. The guard now lives in dispatch_set(),
# which every rename funnels through. These assertions exist because each one was demonstrated live.
#
# What is NOT claimed: that any mistyped verb is caught. A caption is arbitrary words, so a bare
# `lst` cannot be distinguished from someone naming a window "lst". What IS caught: flag-shaped
# input on every path, and a lone known verb in the wrong case.
#
# A1  `--help` exits 0, prints usage, renames nothing
# A2  an unknown flag exits 2, renames nothing
# A3  `set --help` — THE /line PATH — exits 2, renames nothing
# A4  an empty leading argv element does not smuggle a flag through
# A5  `set "billing" --own "x"` (mistyped --owns) exits 2, renames nothing
# A6  a lone `Help` (wrong case) exits 2, renames nothing
# A7  no refused invocation wrote a caption file
# A8  the whole registry entry is byte-identical after every refusal above
# A9  POSITIVE CONTROL — an explicit `set` still renames
# A10 POSITIVE CONTROL — the bare-sentence shorthand still renames
# A11 POSITIVE CONTROL — `set -- "-v caption"` can still set a dash-leading caption
#
# The positive controls are load-bearing: without them, deleting the rename path outright would
# leave every no-rename assertion green.
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): copy the script, neutralise BOTH guards (main()'s
# branches and flaglike()'s return), and re-run. The no-rename assertions must go red — and the
# check is specific: it requires A1/A2/A3/A5/A6 by name, so an unrelated fixture failure can no
# longer masquerade as a working negative control.
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
# Under `set -u` without `-e` a failed mktemp leaves ROOT empty, which would make FAKE_HOME "/home"
# and put this test's writes outside its sandbox. Refuse to run rather than escape containment.
[ -n "$ROOT" ] && [ -d "$ROOT" ] || { echo "INFRA: mktemp -d failed; refusing to run unsandboxed" >&2; exit 3; }
FAKE_HOME="$ROOT/home"
FAKE_PID=""
cleanup() {
  # Braces + 2>/dev/null: the shell prints its own "Terminated: 15" job notice when it reaps the
  # fixture, which lands under the verdict and reads as a failure to anyone scanning the output.
  { [ -n "$FAKE_PID" ] && kill "$FAKE_PID" 2>/dev/null; wait "$FAKE_PID" 2>/dev/null; } 2>/dev/null
  rm -rf "$ROOT" 2>/dev/null || echo "CLEANUP WARNING: could not remove $ROOT" >&2
}
trap cleanup EXIT
mkdir -p "$FAKE_HOME/.claude/sessions" "$FAKE_HOME/.claude/session-status"

SCRIPT="$REAL_SCRIPT"
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  SCRIPT="$ROOT/regressed.py"
  cp "$REAL_SCRIPT" "$SCRIPT"
  # Restore the pre-fix behaviour: main() adopts anything, and dispatch_set stops objecting.
  python3 - "$SCRIPT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
a = '    if len(args) == 1 and args[0] in ("help", "-h", "--help", "-help", "usage"):'
b = '        return _usage(sys.stderr, 2)'
start = s.index(a)
end = s.index(b, start) + len(b) + 1
s = s[:start] + s[end:]
anchor = '    toks = sentence.split()\n'
i = s.index(anchor)
s = s[:i] + '    return ""\n' + s[i:]          # flaglike() now never objects
open(p, "w").write(s)
PY
  grep -q 'unknown option' "$SCRIPT" \
    && { echo "INFRA: neg-control patch did not remove main()'s guard - anchors moved" >&2; exit 3; }
  python3 -c "import ast,sys;ast.parse(open(sys.argv[1]).read())" "$SCRIPT" \
    || { echo "INFRA: neg-control patch produced invalid python" >&2; exit 3; }
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
ENTRY_SHA0="$(shasum "$ENTRY" | awk '{print $1}')"

name_now() { python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('name',''))" "$ENTRY"; }

FAIL_N=0
FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }

run_lac() {  # run_lac <argv...> -> sets RC / OUT
  OUT="$(HOME="$FAKE_HOME" CLAUDE_SESSION_ID="$SID" python3 "$SCRIPT" "$@" 2>&1)"
  RC=$?
}
# Assert a refusal did not rename. `label` is the assertion tag the neg-control looks for by name.
assert_no_rename() {  # assert_no_rename <label> <expected-rc>
  label="$1"; want="$2"
  [ "$RC" = "$want" ] || fail "${label}: exited ${RC}, expected ${want}"
  [ "$(name_now)" = "$ORIGINAL_NAME" ] \
    || fail "${label}: RENAMED the window to '$(name_now)' (was ${ORIGINAL_NAME})"
}

# --- A1: --help prints help instead of becoming one ----------------------------------------------
run_lac --help
assert_no_rename "A1" 0
case "$OUT" in
  *"line-agent-communicator.py - name this window"*) ;;
  *) fail "A1: printed no usage; got: $(printf '%s' "$OUT" | head -1)" ;;
esac

# --- A2: an unknown flag ---------------------------------------------------------------------------
run_lac --bogus-flag
assert_no_rename "A2" 2
case "$OUT" in
  *"unknown option"*) ;;
  *) fail "A2: did not say the option was unknown; got: $(printf '%s' "$OUT" | head -1)" ;;
esac

# --- A3: THE /line PATH. `/line --help` reaches the script as ["set", "--help"] --------------------
run_lac set --help
assert_no_rename "A3" 2

# --- A4: an empty leading argv element must not smuggle a flag through -----------------------------
run_lac "" --help
assert_no_rename "A4" 0

# --- A5: a mistyped --owns must not be folded into the caption -------------------------------------
run_lac set "billing" --own "Stripe webhooks"
assert_no_rename "A5" 2

# --- A6: a lone known verb in the wrong case is a verb, not a name ---------------------------------
run_lac Help
assert_no_rename "A6" 2

# --- A7: no refused invocation wrote a caption -----------------------------------------------------
if [ -e "$FAKE_HOME/.claude/session-status/${SID}.txt" ]; then
  fail "A7: a caption file was written by a refused invocation: $(cat "$FAKE_HOME/.claude/session-status/${SID}.txt")"
fi

# --- A8: the registry entry is untouched, not merely same-named ------------------------------------
if [ "$(shasum "$ENTRY" | awk '{print $1}')" != "$ENTRY_SHA0" ]; then
  fail "A8: the registry entry changed on disk despite every invocation above being refused"
fi

# --- A9/A10/A11 positive controls: the real paths still work --------------------------------------
run_lac set "billing reconciliation"
[ "$(name_now)" = "billing-reconciliation" ] \
  || fail "A9 positive control: explicit \`set\` did not rename (name is '$(name_now)') - the no-rename assertions above would pass even with the rename path deleted"

run_lac "patient retention"
[ "$(name_now)" = "patient-retention" ] \
  || fail "A10 positive control: the bare-sentence shorthand no longer renames (name is '$(name_now)')"

run_lac set -- "-v dash caption"
[ "$(name_now)" = "v-dash-caption" ] \
  || fail "A11 positive control: \`set --\` cannot set a dash-leading caption (name is '$(name_now)') - the guard has no escape hatch"

# --- verdict --------------------------------------------------------------------------------------
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  # Specific, not merely non-zero: every no-rename assertion must have fired. A broken fixture that
  # only trips a positive control used to print NEG-CONTROL OK and prove nothing.
  MISSING=""
  for tag in A1 A2 A3 A5 A6; do
    case "$FAIL_MSGS" in *"${tag}: RENAMED"*) ;; *) MISSING="${MISSING} ${tag}" ;; esac
  done
  if [ -z "$MISSING" ]; then
    echo "NEG-CONTROL OK: with both guards removed, every no-rename assertion went RED (${FAIL_N} failed)"
    printf '%s' "$FAIL_MSGS"
    exit 0
  fi
  echo "NEG-CONTROL BROKEN: these assertions did NOT report a rename against a deliberately regressed script:${MISSING}" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi

if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 10-verb-fallthrough-rename" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi

cat > "${HERE}/10-verb-fallthrough-rename.fingerprint.json" <<EOF
{"assumption":"flag_shaped_input_is_refused_on_every_rename_path_including_set","uname":"$(uname -s)","paths_covered":"bare,set,empty-argv,wrong-case-verb","escape_hatch":"set --","assertions":11}
EOF

echo "PASS: 10-verb-fallthrough-rename - 11 assertions (A1-A6 refusals incl. the /line set path, A7 no caption, A8 entry byte-identical, A9-A11 positive controls)"
exit 0
