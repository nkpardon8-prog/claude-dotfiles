#!/usr/bin/env bash
# 04 - idempotent-cursor: the cursor hash the wake routine uses to collapse overlapping wakes
# into exactly one advance. Contract: STABLE across repeated reads with no append; CHANGES
# after any append to the current-generation state stream.
#
# Load-bearing because two wakes (a background completion and a restored ScheduleWakeup tick,
# say) can enter the wake routine near-simultaneously. Each computes cursor_before, selects a
# transition, then recomputes the cursor immediately before dispatch; if it moved, it discards
# the stale decision and re-reads. That is ONLY safe if the hash is deterministic over an
# unchanged state (or the first wake's own no-op read would look like a change and thrash) AND
# actually moves once the first wake banks its transition (or the second would re-bank the same
# line -> a duplicate advance). A stable-but-never-moving hash, or a moving-when-idle hash,
# each breaks the collapse in opposite directions; A1 and A2 pin both edges.
#
# Rotation-invariance (a rotation that moves live-log lines into an archive yields the same
# hash) is a property of _gen_sliced_stream - it concatenates archives before the live log -
# and is proven in the mission-bridge suite's gen-sliced coverage; forcing a real rotation
# here would duplicate that machinery, so this case pins stability + change and defers rotation
# to that owner (noted, not skipped).
#
# NEGATIVE CONTROL: make mission_cursor_hash fold in a timestamp (e.g. append `date +%s` to
# the hashed stream) - A1 then differs across two idle reads and goes RED. Or make it hash a
# constant - A2 then stays equal after an append and goes RED. Restore to green.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
mc_gate
mc_setup "04-idempotent-cursor"

SUB="cur"; SID="cursor$$"
mc_new_mission "$SUB" "$SID"
mc_await "$SUB" "$SID" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=0"

# A1 - stability: three reads with NO append in between are byte-identical and non-empty.
C1=$(mc_cursor "$SUB" "$SID")
C2=$(mc_cursor "$SUB" "$SID")
C3=$(mc_cursor "$SUB" "$SID")
[ -n "$C1" ] && mc_ok "A1 cursor non-empty" || mc_fail "A1 cursor empty"
mc_eq "$C1" "$C2" "A1 stable read 1==2"
mc_eq "$C2" "$C3" "A1 stable read 2==3"

# A2 - change on append: banking one lane's progress (got=0 -> got=2) appends a state line, so
# the cursor MUST move. This is what a second overlapping wake detects to collapse to one advance.
mc_await "$SUB" "$SID" "part=1 phase=review round=1 kind=job op=reviewbar attempt=1 need=3 got=2"
C4=$(mc_cursor "$SUB" "$SID")
if [ "$C4" != "$C1" ]; then mc_ok "A2 cursor moved after an append"
else mc_fail "A2 cursor did NOT move after an append (C1=$C1 C4=$C4)"; fi

# A3 - stable AGAIN at the new value: after the append the hash re-stabilises (a re-read of
# the post-append state is a no-op, so the wake routine does not thrash).
C5=$(mc_cursor "$SUB" "$SID")
mc_eq "$C4" "$C5" "A3 re-stable at the new value"

mc_finish '{"idle_reads":"identical + non-empty","after_append":"changed","post_append_reads":"identical (re-stable)","rotation":"deferred to _gen_sliced_stream coverage"}' \
  "5 assertions (cursor stable-when-idle, moves-on-append, re-stable)"
