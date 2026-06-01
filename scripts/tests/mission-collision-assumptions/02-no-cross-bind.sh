#!/usr/bin/env bash
# 02 (ADVISORY) — Integrity audit of REAL chain manifests. The fix trusts the chain
# manifest as the authoritative anchor; this audits that no existing
# ~/.claude/chains/<sid>.json mission_path points at a MISSION file whose embedded
# marker sid != the manifest's own sid. A mismatch is NOT a fix-blocker (it would be
# evidence the OLD mtime bug already corrupted a pointer — exactly what the fix kills
# going forward) — so this prints ADVISORY WARN and still exits 0. Read-only.
set -uo pipefail

GATE="${MISSION_SMOKE_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set MISSION_SMOKE_ALLOW_DEV=true to run" >&2; exit 2; }

LIB="$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"
[ -f "$LIB" ] || { echo "INFRA: lib not found: $LIB" >&2; exit 3; }
# shellcheck disable=SC1090
. "$LIB" || { echo "INFRA: failed to source lib" >&2; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "INFRA: jq required" >&2; exit 3; }

CHAINS="$HOME/.claude/chains"
[ -d "$CHAINS" ] || { echo "INFRA: no chains dir ($CHAINS) — nothing to audit" >&2; exit 3; }

checked=0; matched=0; warned=0
for mf in "$CHAINS"/*.json; do
  [ -f "$mf" ] || continue
  manifest_sid="$(basename "$mf" .json)"
  mp="$(jq -r '.mission_path // empty' "$mf" 2>/dev/null)"
  [ -n "$mp" ] || continue                       # no pointer → nothing to cross-check
  checked=$((checked+1))
  if [ ! -f "$mp" ]; then
    echo "  ADVISORY WARN: manifest $manifest_sid points at a MISSING file: $mp" >&2
    warned=$((warned+1)); continue
  fi
  marker_sid="$(_mission_marker_field "$mp" sid 2>/dev/null || true)"
  if [ "$marker_sid" = "$manifest_sid" ]; then
    matched=$((matched+1))
  else
    echo "  ADVISORY WARN: CROSS-BIND — manifest $manifest_sid -> file marker sid '$marker_sid' ($mp)" >&2
    warned=$((warned+1))
  fi
done

echo "PASS (advisory): 02-no-cross-bind — checked=$checked matched=$matched warned=$warned"
cat > "$(dirname "$0")/02-no-cross-bind.fingerprint.json" <<EOF
{"audit":"chain_manifest_cross_bind","checked":$checked,"matched":$matched,"warned":$warned}
EOF
exit 0
