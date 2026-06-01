#!/usr/bin/env bash
# 05 — Resolver prefers a non-empty manifest pointer over the deterministic path, BUT only an IN-ROOT
# CANONICAL one: pointer target must equal mission_path(<its own marker sid>, <root>). This covers the
# sid-divergence reattach case (manifest for sid Q points at the in-root MISSION.<P>.md). An out-of-root
# or basename!=marker pointer must be REJECTED (fall through), so cross-root/crafted adoption is dead.
#
# NEGATIVE CONTROL (controllable precondition): A2 points the manifest at an OUT-OF-ROOT file with a
# valid marker; the resolver must reject it and return empty (Q has no in-root file). If the resolver
# honored any existing pointer, A2 would FAIL.
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
ROOT="$BASE/with space/root"; HOMEDIR="$BASE/fakehome"
mkdir -p "$ROOT" "$HOMEDIR/.claude/chains" "$BASE/elsewhere"
cleanup() { rm -rf "$BASE" 2>/dev/null; }
trap cleanup EXIT
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${NS}05 *" -mmin +60 -exec rm -rf {} + 2>/dev/null

if ! type mission_resolve_path >/dev/null 2>&1; then
  echo "PENDING (exit 3): mission_resolve_path not implemented yet — pre-impl gate." >&2; exit 3
fi

Q="dddddddd-4444-4ddd-8ddd-dddddddddddd"   # requester (no deterministic file of its own)
P="eeee5555-5555-4eee-8eee-eeeeeeeeeeee"   # the divergence target, lives in-root
mk() { printf '# MISSION %s\n<!-- MISSION schema=v1 sid=%s nonce=00000000-0000-0000-0000-000000000000 plan_hash=0000000000000000 -->\n' "$1" "$1" > "$2"; }
mk "$P" "$ROOT/MISSION.$P.md"                       # in-root canonical
mk "$P" "$BASE/elsewhere/MISSION.$P.md"             # same basename/marker but OUT of root

fail=0; FAILURES=()

# A1 — manifest for Q points at the IN-ROOT MISSION.<P>.md (canonical) -> resolver returns it.
printf '{"mission_path":"%s"}\n' "$ROOT/MISSION.$P.md" > "$HOMEDIR/.claude/chains/$Q.json"
got="$(HOME="$HOMEDIR" mission_resolve_path "$Q" "$ROOT")"
[ "$got" = "$ROOT/MISSION.$P.md" ] || { fail=1; FAILURES+=("A1 expected in-root pointer target, got '$got'"); }

# A2 — manifest for Q points OUT-OF-ROOT (valid marker, wrong location) -> REJECTED -> empty.
printf '{"mission_path":"%s"}\n' "$BASE/elsewhere/MISSION.$P.md" > "$HOMEDIR/.claude/chains/$Q.json"
got2="$(HOME="$HOMEDIR" mission_resolve_path "$Q" "$ROOT" 2>/dev/null)"
[ -z "$got2" ] || { fail=1; FAILURES+=("A2 out-of-root pointer should be rejected, got '$got2'"); }

if [ "$fail" = 0 ]; then
  echo "PASS: 05-manifest-pointer-wins — 2 assertions (A1 in-root honored, A2 out-of-root rejected)"
  cat > "$(dirname "$0")/05-manifest-pointer-wins.fingerprint.json" <<EOF
{"resolver":"mission_resolve_path","pointer_precedence":"in_root_canonical_only"}
EOF
  exit 0
else
  echo "FAIL: 05-manifest-pointer-wins" >&2
  for f in "${FAILURES[@]}"; do echo "  - $f" >&2; done
  exit 1
fi
