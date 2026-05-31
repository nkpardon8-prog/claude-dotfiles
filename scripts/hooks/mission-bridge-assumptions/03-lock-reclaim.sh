#!/usr/bin/env bash
# 03 — PID-stamped mkdir-lock: dead-holder reclaim + live-holder never stolen.
#
# Proves the concurrency guard (_mission_lock, plan Key Pseudocode):
#   mkdir "$lock"  &&  printf '%s\n' "$$" > "$lock/pid"
#   holder=$(cat "$lock/pid" | tr -cd '0-9')
#   if [ -n "$holder" ] && ! kill -0 "$holder"; then rm -rf "$lock"; fi   # reclaim
#
# Load-bearing assumption: a SIGKILLed writer leaves a RECLAIMABLE lock (so the
# spine never deadlocks across a crash), while a LIVE writer's lock is NEVER
# stolen (so two writers never mutate the durable file concurrently).
#
# Determinism (per reviewer): the dead-holder case uses a PID that is guaranteed
# NOT live and NOT reused within the window (a reaped child, re-confirmed dead);
# the live-holder case uses a real running background process.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
atest_init "03-lock-reclaim"

LOCK="$ATEST_DIR/.claude-mission-test.lock"

# Reproduce the plan's reclaim decision exactly.
reclaim_if_dead() { # $1 lockdir -> echoes "reclaimed" | "held"
  _lk="$1"
  _holder="$(cat "$_lk/pid" 2>/dev/null | tr -cd '0-9')"
  if [ -n "$_holder" ] && ! kill -0 "$_holder" 2>/dev/null; then
    rm -rf "$_lk" 2>/dev/null
    echo "reclaimed"
  else
    echo "held"
  fi
}

# --- A1: DEAD holder -> reclaimed --------------------------------------------
# Spawn a child, capture its pid, let it exit, reap it. Re-confirm dead. To avoid
# the (vanishingly rare) PID-reuse race we additionally verify kill -0 fails NOW.
( exit 0 ) & dead=$!
wait "$dead" 2>/dev/null
mkdir -p "$LOCK"; printf '%s\n' "$dead" > "$LOCK/pid"
if kill -0 "$dead" 2>/dev/null; then
  # extremely rare: pid was reused by a live process during the window -> infra skip
  atest_infra "captured 'dead' pid $dead is live (PID reuse) — rerun"
fi
r1="$(reclaim_if_dead "$LOCK")"
[ "$r1" = "reclaimed" ] && [ ! -d "$LOCK" ]
atest_assert "A1" "$?" "dead-holder lock not reclaimed (decision='$r1', dir-exists=$([ -d "$LOCK" ] && echo y || echo n)) — a crashed writer would deadlock the spine."

# --- A2: LIVE holder -> never stolen -----------------------------------------
rm -rf "$LOCK" 2>/dev/null
sleep 30 & live=$!
mkdir -p "$LOCK"; printf '%s\n' "$live" > "$LOCK/pid"
r2="$(reclaim_if_dead "$LOCK")"
[ "$r2" = "held" ] && [ -d "$LOCK" ]
_a2=$?
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
atest_assert "A2" "$_a2" "LIVE holder lock was stolen (decision='$r2') — two writers could mutate the durable file concurrently (corruption)."

# --- A3: full acquire loop — second acquirer waits then reclaims a dead lock --
# Mirror the 50-try x sleep 0.1 acquire: a fresh acquirer facing a dead-holder
# lock must succeed by reclaiming, within the bounded retry budget.
acquire() { # $1 lockdir ; returns 0 on acquired, 1 on timeout
  _lk="$1"; _t=0
  while [ "$_t" -lt 50 ]; do
    if mkdir "$_lk" 2>/dev/null; then printf '%s\n' "$$" > "$_lk/pid"; return 0; fi
    _h="$(cat "$_lk/pid" 2>/dev/null | tr -cd '0-9')"
    if [ -n "$_h" ] && ! kill -0 "$_h" 2>/dev/null; then rm -rf "$_lk" 2>/dev/null; fi
    _t=$((_t+1)); sleep 0.1
  done
  return 1
}
rm -rf "$LOCK" 2>/dev/null
( exit 0 ) & dead2=$!; wait "$dead2" 2>/dev/null
mkdir -p "$LOCK"; printf '%s\n' "$dead2" > "$LOCK/pid"   # pre-existing dead lock
acquire "$LOCK"
_a3=$?
[ "$_a3" = "0" ] && [ -d "$LOCK" ] && [ "$(cat "$LOCK/pid" 2>/dev/null | tr -cd '0-9')" = "$$" ]
atest_assert "A3" "$?" "acquire loop failed to reclaim a dead lock within 50 tries (rc=$_a3) — autonomous run would stall at a stale lock."

# --- A4 (NEGATIVE CONTROL): a held LIVE lock blocks acquire (bounded) --------
# Prove the acquire loop CAN fail (go red) when the holder is genuinely alive:
# with a short retry budget against a live holder, acquisition must NOT succeed.
acquire_short() { # like acquire but only 3 tries
  _lk="$1"; _t=0
  while [ "$_t" -lt 3 ]; do
    if mkdir "$_lk" 2>/dev/null; then printf '%s\n' "$$" > "$_lk/pid"; return 0; fi
    _h="$(cat "$_lk/pid" 2>/dev/null | tr -cd '0-9')"
    if [ -n "$_h" ] && ! kill -0 "$_h" 2>/dev/null; then rm -rf "$_lk" 2>/dev/null; fi
    _t=$((_t+1)); sleep 0.1
  done
  return 1
}
rm -rf "$LOCK" 2>/dev/null
sleep 30 & live2=$!
mkdir -p "$LOCK"; printf '%s\n' "$live2" > "$LOCK/pid"
acquire_short "$LOCK"; _got=$?
kill "$live2" 2>/dev/null; wait "$live2" 2>/dev/null
[ "$_got" = "1" ]   # MUST time out against a live holder
atest_assert "A4" "$?" "acquire succeeded against a LIVE holder (rc=$_got) — the live-holder protection is not actually enforced."

atest_report
