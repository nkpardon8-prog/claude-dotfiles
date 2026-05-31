#!/usr/bin/env bash
# 05-resume-idempotency-marker.sh
#
# A6 — A one-shot resume marker keyed on (sid, nonce) makes the self-invoke + typed-backstop
#      double-fire idempotent:
#        - no marker            -> resume PROCEEDS (and writes the marker atomically),
#        - same (sid,nonce)     -> STATE=already-resumed NO-OP (second channel does nothing),
#        - DIFFERENT nonce      -> resume PROCEEDS (the next compaction is a fresh resume — the
#                                  nonce scoping prevents a stale prior marker from blocking it),
#        - marker write is ATOMIC (mktemp+mv, mode 600) so a torn write can't both no-op and fail.
#
# NEGATIVE CONTROL (controllable precondition): with the marker absent the check returns "proceed";
#   after writing it the SAME-nonce check returns "already-resumed". The different-nonce assertion is
#   the regression guard for the overnight case (a prior compaction's marker must not kill a new resume).
#
# This is pure file-logic (no live infra), but it is load-bearing: getting the nonce scoping wrong
# either double-executes `## Next Action` or silently blocks the next overnight resume.
#
# Exit: 0 PASS · 1 FAIL · 2 REFUSED · 3 INFRASTRUCTURE
set -uo pipefail
[ "${CORRELATION_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set CORRELATION_TESTS_ALLOW_DEV=true to run assumption tests" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP="$HERE/05-resume-idempotency-marker.fingerprint.json"

# Per-run sandbox dir (never touch the real ~/.claude/progress)
RUNID=$(uuidgen 2>/dev/null | tr 'A-F' 'a-f' || od -vAn -N8 -tx1 /dev/urandom | tr -d ' \n')
SBOX=$(mktemp -d "/tmp/corr-marker.${RUNID}.XXXXXX") || { echo "INFRASTRUCTURE: mktemp -d failed" >&2; exit 3; }
cleanup() { rm -rf "$SBOX" 2>/dev/null; return 0; }
trap cleanup EXIT
# Startup reaper: clear any orphaned sandboxes from prior crashed runs (>1h old)
find /tmp -maxdepth 1 -type d -name 'corr-marker.*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true

# --- candidate helpers under test (mirror plan: marker path + atomic write + check) ---
marker_path() { printf '%s/resumed-%s-%s' "$SBOX" "$1" "$2"; }   # $1=sid $2=nonce
marker_write() {  # atomic mktemp+mv, mode 600
  local p="$1" tmp
  tmp=$(mktemp "${p}.XXXXXX") || return 1
  printf 'resumed ts=%s\n' "$(date +%s)" > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null
  mv -f "$tmp" "$p" || { rm -f "$tmp"; return 1; }
}
resume_state() { [ -f "$(marker_path "$1" "$2")" ] && printf 'already-resumed' || printf 'proceed'; }

SID="49d80a3a-7418-4e43-a465-420c2ff7c4bf"
N1="nonce-aaaa-1111"; N2="nonce-bbbb-2222"
fails=()

# A6a — no marker -> proceed
[ "$(resume_state "$SID" "$N1")" = "proceed" ] || fails+=("A6a expected 'proceed' with no marker")

# write marker (the first/self resume)
marker_write "$(marker_path "$SID" "$N1")" || fails+=("A6 marker_write failed")

# A6b — same (sid,nonce) -> already-resumed (the typed backstop no-ops)
[ "$(resume_state "$SID" "$N1")" = "already-resumed" ] || fails+=("A6b expected 'already-resumed' after marker written")

# A6c — DIFFERENT nonce -> proceed (next compaction is a fresh resume; stale marker must NOT block)
[ "$(resume_state "$SID" "$N2")" = "proceed" ] || fails+=("A6c expected 'proceed' for a different nonce (stale-marker-blocks-new-resume regression)")

# A6d — atomicity: marker file is mode 600 and contains a complete line (no torn write)
MP=$(marker_path "$SID" "$N1")
MODE=$(stat -f '%Lp' "$MP" 2>/dev/null || stat -c '%a' "$MP" 2>/dev/null)
[ "$MODE" = "600" ] || fails+=("A6d marker mode='$MODE' expected 600")
grep -q '^resumed ts=[0-9][0-9]*$' "$MP" 2>/dev/null || fails+=("A6d marker content malformed/torn: '$(cat "$MP" 2>/dev/null)'")
# no leftover temp files from the atomic write
LEFT=$(find "$SBOX" -name 'resumed-*.??????' 2>/dev/null | wc -l | tr -d ' ')
[ "$LEFT" = "0" ] || fails+=("A6d leftover temp files from atomic write: $LEFT")

if [ ${#fails[@]} -gt 0 ]; then
  echo "FAIL: 05-resume-idempotency-marker"; for f in "${fails[@]}"; do echo "  - $f"; done; exit 1
fi
printf '{"marker_mode":"%s","nonce_scoped":true}\n' "${MODE:-}" > "$FP"
echo "PASS: 05-resume-idempotency-marker — (A6a,A6b,A6c,A6d)"
exit 0
