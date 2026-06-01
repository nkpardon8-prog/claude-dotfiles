#!/usr/bin/env bash
# 07 — /mission resume = CLONE-ON-RESUME. mission_fork copies the picked mission into the resuming
# session's OWN sid file, leaving the source intact, so the resumed mission is a normal mission owned
# by the new sid (no sid-swap, no working-sid threading, no shared-file split-brain). Proves: clone
# lands under dest sid, verifies, preserves PLAN + log, leaves source untouched, refuses an existing
# dest (rc 3). This is the contract the entire clone-on-resume design rests on.
#
# NEGATIVE CONTROL (controllable precondition): A5 forks again into the now-existing dest and asserts
# rc 3 — proving the "already own a mission" guard actually fires (a clobber would silently succeed).
set -uo pipefail

GATE="${MISSION_SMOKE_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set MISSION_SMOKE_ALLOW_DEV=true to run" >&2; exit 2; }

WRITER="$HOME/.claude-dotfiles/scripts/hooks/mission-write.sh"
LIB="$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"
[ -f "$WRITER" ] && [ -f "$LIB" ] || { echo "INFRA: writer/lib not found" >&2; exit 3; }
# shellcheck disable=SC1090
. "$LIB" || { echo "INFRA: failed to source lib" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "INFRA: jq required" >&2; exit 3; }

runId="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
NS="__atest__"
BASE="${TMPDIR:-/tmp}/${NS}07 ${runId}"
ROOT="$BASE/with space/root"; HOMEDIR="$BASE/fakehome"
mkdir -p "$ROOT" "$HOMEDIR/.claude/chains"
cleanup() { rm -rf "$BASE" 2>/dev/null; }
trap cleanup EXIT
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${NS}07 *" -mmin +60 -exec rm -rf {} + 2>/dev/null

if ! type mission_fork >/dev/null 2>&1; then
  echo "PENDING (exit 3): mission_fork not implemented yet — pre-impl gate." >&2; exit 3
fi

SRC="b7000000-2222-4bbb-8bbb-bbbbbbbbbbbb"   # the picked (source) mission
DST="a7000000-1111-4aaa-8aaa-aaaaaaaaaaaa"   # the resuming session's own sid
MARK="ATEST07-${runId}"
w() { HOME="$HOMEDIR" bash "$WRITER" "$@" >/dev/null 2>&1; }

w create "$SRC" "$ROOT" "MISSION MODE: build
Roadmap ${MARK}" || { echo "INFRA: create SRC failed" >&2; exit 3; }
w log "$SRC" "$ROOT" "[mission] PART-START part=1 name=${MARK}" "m1-start" || { echo "INFRA: log SRC failed" >&2; exit 3; }

fail=0; FAILURES=()
new="$(HOME="$HOMEDIR" mission_fork "$DST" "$ROOT" "$ROOT/MISSION.$SRC.md")" || { fail=1; FAILURES+=("fork returned nonzero"); }

# A1 — clone lands at the dest's canonical path.
[ "$new" = "$ROOT/MISSION.$DST.md" ] || { fail=1; FAILURES+=("A1 clone path '$new' != dest canonical"); }
# A2 — clone is OWNED by dest sid (marker retargeted) and verifies sound under dest sid.
[ "$(_mission_marker_field "$ROOT/MISSION.$DST.md" sid 2>/dev/null)" = "$DST" ] || { fail=1; FAILURES+=("A2 clone marker sid != dest"); }
HOME="$HOMEDIR" mission_verify "$ROOT/MISSION.$DST.md" "$DST" >/dev/null 2>&1 || { fail=1; FAILURES+=("A2 clone fails mission_verify under dest sid"); }
# A3 — PLAN content + log carried into the clone.
mission_read_zone "$ROOT/MISSION.$DST.md" PLAN 2>/dev/null | grep -q "$MARK" || { fail=1; FAILURES+=("A3 clone PLAN missing roadmap marker"); }
grep -q "$MARK" "$ROOT/MISSION.$DST.log" 2>/dev/null || { fail=1; FAILURES+=("A3 clone log not carried"); }
# A4 — SOURCE left intact (still its own sid, still present).
[ "$(_mission_marker_field "$ROOT/MISSION.$SRC.md" sid 2>/dev/null)" = "$SRC" ] || { fail=1; FAILURES+=("A4 source marker changed/clobbered"); }
# A5 (NEGATIVE CONTROL) — forking again into the existing dest is refused with rc 3.
HOME="$HOMEDIR" mission_fork "$DST" "$ROOT" "$ROOT/MISSION.$SRC.md" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] || { fail=1; FAILURES+=("A5 re-fork into existing dest expected rc 3, got $rc"); }

if [ "$fail" = 0 ]; then
  echo "PASS: 07-resume-clone — 5 assertions (A1-A4 + negative control A5)"
  cat > "$(dirname "$0")/07-resume-clone.fingerprint.json" <<EOF
{"resume":"clone-on-resume","fork":"mission_fork","source_intact":true,"dest_owns_own_sid":true}
EOF
  exit 0
else
  echo "FAIL: 07-resume-clone" >&2
  for f in "${FAILURES[@]}"; do echo "  - $f" >&2; done
  exit 1
fi
