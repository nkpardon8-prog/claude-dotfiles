#!/usr/bin/env bash
# 07 — Resume sid-swap WRITE-ROUTING contract (provable now against the existing
# mission-write.sh). /mission resume adopts another mission's sid; the whole feature
# is only safe if a write performed with sid=B lands in MISSION.<B>.md / .log and
# leaves MISSION.<A>.* untouched. Every writer keys filename+lock by the passed sid
# (mission-bridge.sh:739/802/320) — this locks that contract so a future refactor
# that mis-threads the post-swap sid (read B, write A split-brain) fails loudly.
#
# NEGATIVE CONTROL (controllable precondition): we ALSO write the same marker with
# sid=A and confirm it DOES appear in A — proving the absence check in A2 is real,
# not a marker that never lands anywhere.
set -uo pipefail

GATE="${MISSION_SMOKE_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set MISSION_SMOKE_ALLOW_DEV=true to run" >&2; exit 2; }

WRITER="$HOME/.claude-dotfiles/scripts/hooks/mission-write.sh"
LIB="$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"
[ -f "$WRITER" ] || { echo "INFRA: writer not found: $WRITER" >&2; exit 3; }
[ -f "$LIB" ] || { echo "INFRA: lib not found: $LIB" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "INFRA: jq required" >&2; exit 3; }

runId="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
NS="__atest__"
BASE="${TMPDIR:-/tmp}/${NS}07 ${runId}"
ROOT="$BASE/with space/root"
HOMEDIR="$BASE/fakehome"
mkdir -p "$ROOT" "$HOMEDIR/.claude/chains"

cleanup() { rm -rf "$BASE" 2>/dev/null; }
trap cleanup EXIT
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${NS}07 *" -mmin +60 -exec rm -rf {} + 2>/dev/null

SID_A="a7000000-1111-4aaa-8aaa-aaaaaaaaaaaa"
SID_B="b7000000-2222-4bbb-8bbb-bbbbbbbbbbbb"
MARK="ATEST07-${runId}"

w() { HOME="$HOMEDIR" bash "$WRITER" "$@" >/dev/null 2>&1; }

# seed two independent missions
w create "$SID_A" "$ROOT" "MISSION MODE: build
fixture A $runId" || { echo "INFRA: create A failed" >&2; exit 3; }
w create "$SID_B" "$ROOT" "MISSION MODE: build
fixture B $runId" || { echo "INFRA: create B failed" >&2; exit 3; }

LOG_A="$ROOT/MISSION.$SID_A.log"
LOG_B="$ROOT/MISSION.$SID_B.log"

# snapshot A before the B write (split-brain bleed check)
a_before="$( [ -f "$LOG_A" ] && wc -c < "$LOG_A" || echo 0 )"

# THE routed write: sid=B
w log "$SID_B" "$ROOT" "[mission] note ${MARK}" "atest07-b" || { echo "INFRA: log B failed" >&2; exit 3; }

fail=0; FAILURES=()
# A1 — the marker landed in B's log.
if ! grep -q "$MARK" "$LOG_B" 2>/dev/null; then fail=1; FAILURES+=("A1 marker not found in B's log ($LOG_B)"); fi
# A2 — the marker did NOT bleed into A's log.
if grep -q "$MARK" "$LOG_A" 2>/dev/null; then fail=1; FAILURES+=("A2 split-brain: B's write appeared in A's log"); fi
# A3 — A's log size unchanged by the B write.
a_after="$( [ -f "$LOG_A" ] && wc -c < "$LOG_A" || echo 0 )"
[ "$a_before" = "$a_after" ] || { fail=1; FAILURES+=("A3 A's log size changed by a B write ($a_before -> $a_after)"); }

# NEGATIVE CONTROL — same marker via sid=A DOES land in A (absence check is real).
w log "$SID_A" "$ROOT" "[mission] note ${MARK}-NEG" "atest07-a"
grep -q "${MARK}-NEG" "$LOG_A" 2>/dev/null || { fail=1; FAILURES+=("NEGCTRL marker via sid=A did not land in A — assertion mechanism broken"); }

if [ "$fail" = 0 ]; then
  echo "PASS: 07-resume-write-routing — 3 assertions (A1, A2, A3) + negative control"
  cat > "$(dirname "$0")/07-resume-write-routing.fingerprint.json" <<EOF
{"writer":"mission-write.sh","routes_by":"sid","split_brain":false}
EOF
  exit 0
else
  echo "FAIL: 07-resume-write-routing" >&2
  for f in "${FAILURES[@]}"; do echo "  - $f" >&2; done
  exit 1
fi
