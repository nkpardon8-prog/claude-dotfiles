#!/usr/bin/env bash
# 06 — The ORIGINAL `// empty` bug, regression-locked. A chain manifest can carry
# mission_path:"" (handoff-chain.sh:17-18 documents this is a live state when the
# canonical root is unavailable). A naive `jq '.mission_path // empty'` keeps "" and
# the OLD code then fell through to the mtime glob → cross-instance adoption.
# The resolver must treat "" as ABSENT → fall to the deterministic path → return
# THIS sid's file (never "" and never a stranger).
#
# NEGATIVE CONTROL (synthetic injection): with mission_path:"" AND the deterministic
# file present, the correct result is the deterministic file. A regression that
# returns "" (treating "" as a valid pointer to nothing) FAILs A1; a regression that
# returns the stranger FAILs A2.
set -uo pipefail

GATE="${MISSION_SMOKE_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set MISSION_SMOKE_ALLOW_DEV=true to run" >&2; exit 2; }

LIB="$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"
[ -f "$LIB" ] || { echo "INFRA: lib not found: $LIB" >&2; exit 3; }
# shellcheck disable=SC1090
. "$LIB" || { echo "INFRA: failed to source lib" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "INFRA: jq required" >&2; exit 3; }

runId="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
NS="__atest__"
BASE="${TMPDIR:-/tmp}/${NS}06 ${runId}"
ROOT="$BASE/with space/root"
HOMEDIR="$BASE/fakehome"
mkdir -p "$ROOT" "$HOMEDIR/.claude/chains"

cleanup() { rm -rf "$BASE" 2>/dev/null; }
trap cleanup EXIT
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${NS}06 *" -mmin +60 -exec rm -rf {} + 2>/dev/null

SID="eeeeeeee-5555-4eee-8eee-eeeeeeeeeeee"
STRANGER="ffffffff-6666-4fff-8fff-ffffffffffff"
DET="$ROOT/MISSION.$SID.md"

mk() { printf '# MISSION %s\n<!-- MISSION schema=v1 sid=%s nonce=00000000-0000-0000-0000-000000000000 plan_hash=0000000000000000 -->\n' "$1" "$1" > "$2"; }
mk "$SID" "$DET"
mk "$STRANGER" "$ROOT/MISSION.$STRANGER.md"
touch -t 203012312359.59 "$ROOT/MISSION.$STRANGER.md"   # stranger is newest (mtime trap)
touch -t 200001010000.00 "$DET"
# manifest carries the empty-string pointer — the exact trap.
printf '{"chain_id":"%s","mission_path":""}\n' "$SID" > "$HOMEDIR/.claude/chains/$SID.json"

if ! type mission_resolve_path >/dev/null 2>&1; then
  echo "PENDING (exit 3): mission_resolve_path not implemented yet — pre-impl gate." >&2
  exit 3
fi

fail=0; FAILURES=()
got="$(HOME="$HOMEDIR" mission_resolve_path "$SID" "$ROOT")"
# A1 — empty pointer falls through to the deterministic file (not "").
[ "$got" = "$DET" ] || { fail=1; FAILURES+=("A1 expected deterministic '$DET', got '$got'"); }
# A2 — never the mtime-newest stranger.
[ "$got" != "$ROOT/MISSION.$STRANGER.md" ] || { fail=1; FAILURES+=("A2 returned the newest stranger"); }

if [ "$fail" = 0 ]; then
  echo "PASS: 06-empty-pointer-fallthrough — 2 assertions (A1, A2)"
  cat > "$(dirname "$0")/06-empty-pointer-fallthrough.fingerprint.json" <<EOF
{"resolver":"mission_resolve_path","empty_string_pointer":"treated_as_absent"}
EOF
  exit 0
else
  echo "FAIL: 06-empty-pointer-fallthrough" >&2
  for f in "${FAILURES[@]}"; do echo "  - $f" >&2; done
  exit 1
fi
