#!/usr/bin/env bash
# 05 — Resolver prefers a NON-empty manifest pointer over the deterministic path.
# This is the post-compact reattach guarantee: a session whose chain manifest
# records mission_path=<target> must resolve <target>, even when a different
# deterministic <root>/MISSION.<sid>.md ALSO exists.
#
# NEGATIVE CONTROL (controllable precondition): point the manifest at a target
# that differs from the deterministic file; if the resolver ignored the pointer
# (returned the deterministic file), A1 FAILs.
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
BASE="${TMPDIR:-/tmp}/${NS}05 ${runId}"
ROOT="$BASE/with space/root"
HOMEDIR="$BASE/fakehome"
mkdir -p "$ROOT" "$HOMEDIR/.claude/chains" "$BASE/elsewhere"

cleanup() { rm -rf "$BASE" 2>/dev/null; }
trap cleanup EXIT
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${NS}05 *" -mmin +60 -exec rm -rf {} + 2>/dev/null

SID="dddddddd-4444-4ddd-8ddd-dddddddddddd"
DETERMINISTIC="$ROOT/MISSION.$SID.md"
POINTER_TARGET="$BASE/elsewhere/MISSION.$SID.md"   # different location the pointer wins to

mk() { printf '# MISSION %s — %s\n<!-- MISSION schema=v1 sid=%s nonce=00000000-0000-0000-0000-000000000000 plan_hash=0000000000000000 -->\n' "$1" "$2" "$1" > "$2"; }
mk "$SID" "$DETERMINISTIC"
mk "$SID" "$POINTER_TARGET"
printf '{"chain_id":"%s","mission_path":"%s"}\n' "$SID" "$POINTER_TARGET" > "$HOMEDIR/.claude/chains/$SID.json"

if ! type mission_resolve_path >/dev/null 2>&1; then
  echo "PENDING (exit 3): mission_resolve_path not implemented yet — pre-impl gate." >&2
  exit 3
fi

fail=0; FAILURES=()
got="$(HOME="$HOMEDIR" mission_resolve_path "$SID" "$ROOT")"
# A1 — manifest pointer target wins over the deterministic file.
[ "$got" = "$POINTER_TARGET" ] || { fail=1; FAILURES+=("A1 expected pointer target '$POINTER_TARGET', got '$got'"); }

if [ "$fail" = 0 ]; then
  echo "PASS: 05-manifest-pointer-wins — 1 assertion (A1)"
  cat > "$(dirname "$0")/05-manifest-pointer-wins.fingerprint.json" <<EOF
{"resolver":"mission_resolve_path","pointer_precedence":"manifest_over_deterministic"}
EOF
  exit 0
else
  echo "FAIL: 05-manifest-pointer-wins" >&2
  for f in "${FAILURES[@]}"; do echo "  - $f" >&2; done
  exit 1
fi
