#!/usr/bin/env bash
# 05 - corrupt-read-loud: a REFUSED gen-sliced read must surface LOUDLY, not degrade to "empty".
#
# The rollover/corruption crash window (a MISSION.md marker committed a gen>=2 bump but the
# matching MISSION-REBASELINED boundary append died) makes _gen_sliced_stream REFUSE. Round-1
# review C5: the old readers swallowed that refusal (`|| true`) and hashed / read an EMPTY stream,
# so a corrupt mission was INDISTINGUISHABLE from a healthy idle one - the wake routine would then
# advance stale state instead of stopping. This is the canonical silent-failure a machine guard
# must catch: a green idle read over a dead/corrupt leg.
#
# Contract proven: on a gen-boundary mismatch, BOTH read-only wake verbs emit the distinct token
# `corrupt` (never `none` / a hex digest / empty), so the wake routine takes its STOP-LOUD path.
#
# NEGATIVE CONTROL: restore the old `_gen_sliced_stream ... 2>/dev/null || true` swallow in
# mission_await_state / mission_cursor_hash - both verbs then return `none` / a real hash over the
# empty stream and A2/A3 go RED.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
mc_gate
mc_setup "05-corrupt-read-loud"

SUB="corrupt"; SID="corrupt$$"
mc_new_mission "$SUB" "$SID"
MD="${ROOT}/${SUB}/MISSION.${SID}.md"

# A1 - a healthy gen-1 mission with no awaits reads cleanly (`none`, a real hex cursor).
mc_eq "none" "$(mc_state "$SUB" "$SID")" "A1 healthy mission reads none"
C=$(mc_cursor "$SUB" "$SID")
case "$C" in
  corrupt|"") mc_fail "A1 healthy cursor should be a hex digest, got '$C'" ;;
  *)          mc_ok "A1 healthy cursor is a digest" ;;
esac

# Force the rollover crash window: bump the marker to gen=2 WITHOUT appending the matching
# MISSION-REBASELINED boundary. Portable in-place edit (no sed -i portability trap).
awk '{ gsub(/ gen=1 /, " gen=2 ") } 1' "$MD" > "${MD}.tmp" && mv "${MD}.tmp" "$MD" \
  || { echo "INFRA: could not bump gen" >&2; exit 3; }

# A2 - await-state must emit `corrupt`, NOT `none` (a corrupt read is not valid empty state).
mc_eq "corrupt" "$(mc_state "$SUB" "$SID")" "A2 await-state loud on gen-boundary refusal (C5)"
# A3 - cursor-hash must emit `corrupt`, NOT a hash over the empty stream.
mc_eq "corrupt" "$(mc_cursor "$SUB" "$SID")" "A3 cursor-hash loud on gen-boundary refusal (C5)"

mc_finish '{"healthy":"none + hex cursor","corrupt_read":"corrupt (both verbs)"}' \
  "3 assertions (a refused gen-sliced read surfaces the corrupt token, never silent-empty)"
