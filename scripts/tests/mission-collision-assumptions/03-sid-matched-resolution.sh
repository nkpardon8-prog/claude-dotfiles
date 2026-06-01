#!/usr/bin/env bash
# 03 — CORE collision guarantee: mission_resolve_path returns MY sid's file,
# never the mtime-NEWEST stranger. Fixture root contains a SPACE (merges old 04:
# this env's real root is ".../untitled folder/skills").
#
# NEGATIVE CONTROL (controllable precondition): the same fixture has B as the
# mtime-newest file; we assert the OLD buggy idiom `ls -t | head -1` returns B,
# proving the fixture genuinely reproduces the bug AND that the resolver avoids it.
# If mission_resolve_path is ever reverted to mtime selection, A1 flips to FAIL.
set -uo pipefail

GATE="${MISSION_SMOKE_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set MISSION_SMOKE_ALLOW_DEV=true to run" >&2; exit 2; }

LIB="$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"
[ -f "$LIB" ] || { echo "INFRA: lib not found: $LIB" >&2; exit 3; }
# shellcheck disable=SC1090
. "$LIB" || { echo "INFRA: failed to source lib" >&2; exit 3; }

runId="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
NS="__atest__"
BASE="${TMPDIR:-/tmp}/${NS}03 ${runId}"   # NOTE: space in the path, intentional
ROOT="$BASE/with space/root"
HOMEDIR="$BASE/fakehome"                   # empty home → no manifest → forces deterministic tier
mkdir -p "$ROOT" "$HOMEDIR/.claude/chains"

cleanup() { rm -rf "$BASE" 2>/dev/null; }
trap cleanup EXIT
# startup orphan reap: any __atest__03 dir older than 1h
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${NS}03 *" -mmin +60 -exec rm -rf {} + 2>/dev/null

SID_A="aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa"
SID_B="bbbbbbbb-2222-4bbb-8bbb-bbbbbbbbbbbb"
SID_UNKNOWN="cccccccc-3333-4ccc-8ccc-cccccccccccc"

make_mission() { # <file> <sid>
  printf '# MISSION %s\n\n<!-- MISSION schema=v1 sid=%s nonce=00000000-0000-0000-0000-000000000000 plan_hash=0000000000000000 -->\n' "$2" "$2" > "$1"
}
make_mission "$ROOT/MISSION.$SID_A.md" "$SID_A"
make_mission "$ROOT/MISSION.$SID_B.md" "$SID_B"
# Force A OLDEST, B NEWEST — so a pass cannot be an accident of creation order.
touch -t 200001010000.00 "$ROOT/MISSION.$SID_A.md"
touch -t 203012312359.59 "$ROOT/MISSION.$SID_B.md"

if ! type mission_resolve_path >/dev/null 2>&1; then
  echo "PENDING (exit 3): mission_resolve_path not implemented yet — this is the pre-impl gate; will validate post-impl." >&2
  exit 3
fi

fail=0; FAILURES=()

# A1 — resolver returns A's own file even though A is the mtime-OLDEST.
got_a="$(HOME="$HOMEDIR" mission_resolve_path "$SID_A" "$ROOT")"
[ "$got_a" = "$ROOT/MISSION.$SID_A.md" ] || { fail=1; FAILURES+=("A1 expected A's file, got '$got_a'"); }

# A2 — resolver NEVER returns the mtime-newest stranger B for sid A.
[ "$got_a" != "$ROOT/MISSION.$SID_B.md" ] || { fail=1; FAILURES+=("A2 resolver returned the newest stranger B for sid A"); }

# A3 — unknown sid resolves to EMPTY (no adoption of anything).
got_u="$(HOME="$HOMEDIR" mission_resolve_path "$SID_UNKNOWN" "$ROOT")"
[ -z "$got_u" ] || { fail=1; FAILURES+=("A3 unknown sid expected empty, got '$got_u'"); }

# NEGATIVE CONTROL — prove the fixture reproduces the bug: the old idiom picks B.
buggy="$(ls -t "$ROOT"/MISSION.*.md 2>/dev/null | head -1)"
[ "$buggy" = "$ROOT/MISSION.$SID_B.md" ] || { fail=1; FAILURES+=("NEGCTRL fixture invalid: ls -t|head -1 did not pick B (got '$buggy')"); }

if [ "$fail" = 0 ]; then
  echo "PASS: 03-sid-matched-resolution — 3 assertions (A1, A2, A3) + negative control; spaced root"
  cat > "$(dirname "$0")/03-sid-matched-resolution.fingerprint.json" <<EOF
{"resolver":"mission_resolve_path","selects_by":"sid","mtime_newest_ignored":true,"root_has_space":true}
EOF
  exit 0
else
  echo "FAIL: 03-sid-matched-resolution" >&2
  for f in "${FAILURES[@]}"; do echo "  - $f" >&2; done
  exit 1
fi
