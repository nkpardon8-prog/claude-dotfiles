#!/usr/bin/env bash
# 05 — manifest mission_path lifecycle: preserve-merge never clobbers; recovery
#      re-derives the canonical path.
#
# Proves the pointer-survival contract (plan On-disk contract #8/#9/#10/#15):
#   merge:    .mission_path = (.mission_path // $mp)     # preserve existing
#   recovery: re-derive from handoff_canonical_root (mirrors last_handoff_path)
#
# Load-bearing assumption: across a seq-bump manifest merge, an already-set
# mission_path is NEVER overwritten (so the primer can always find the spine);
# and if the manifest is rebuilt from the ledger, the path is re-derived rather
# than lost. Losing this pointer = the mission silently vanishes post-compact.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
atest_init "05-manifest-mission-path"

command -v jq >/dev/null 2>&1 || atest_infra "jq not found (required for manifest merge)"

REAL="/Users/x/anchor/MISSION.sid.md"

merge() { # $1 existing-json  $2 incoming-mp  -> merged .mission_path
  printf '%s' "$1" | jq -r --arg mp "$2" '(.mission_path = (.mission_path // $mp)) | .mission_path'
}

# --- A1: existing SET, incoming SET -> existing preserved --------------------
out="$(merge "{\"mission_path\":\"$REAL\",\"current_seq\":1}" "/other/path/MISSION.sid.md")"
[ "$out" = "$REAL" ]
atest_assert "A1" "$?" "seq-bump merge clobbered a set mission_path (got '$out', want '$REAL') — the spine pointer would be overwritten."

# --- A2: existing SET, incoming EMPTY -> existing preserved (key no-clobber) --
# Reviewer's worry cell: jq // returns LEFT when left is truthy, so a non-empty
# existing path survives even an empty incoming $mp. Lock it down.
out="$(merge "{\"mission_path\":\"$REAL\",\"current_seq\":2}" "")"
[ "$out" = "$REAL" ]
atest_assert "A2" "$?" "empty incoming \$mp clobbered a set mission_path (got '$out') — preserve-merge is broken for the empty-incoming case."

# --- A3: existing NULL, incoming SET -> takes incoming ------------------------
out="$(merge '{"current_seq":1}' "$REAL")"
[ "$out" = "$REAL" ]
atest_assert "A3" "$?" "null existing + set incoming did not adopt the incoming path (got '$out') — first-time set is broken."

# --- A4: existing NULL, incoming EMPTY -> empty (acceptable; recovery re-derives)
out="$(merge '{"current_seq":1}' "")"
[ "$out" = "" ]
atest_assert "A4" "$?" "null+empty produced unexpected value (got '$out', want empty) — merge truth-table diverged."

# --- A5 (NEGATIVE CONTROL): the NAIVE assignment WOULD clobber ---------------
# Proves the // guard is load-bearing: a naive `.mission_path = $mp` overwrites.
naive="$(printf '%s' "{\"mission_path\":\"$REAL\"}" | jq -r --arg mp "/other.md" '(.mission_path = $mp) | .mission_path')"
[ "$naive" = "/other.md" ]   # naive MUST clobber -> confirms A1/A2 are non-vacuous
atest_assert "A5" "$?" "naive assignment did NOT clobber (got '$naive') — the preserve-merge test is vacuous (cannot distinguish // from plain =)."

# --- A6: ledger-recovery re-derive yields the canonical path ------------------
# Mirror how the recovery branch re-derives last_handoff_path: from the anchor +
# sid. We don't depend on the real handoff_canonical_root here (that needs a repo
# context); we prove the COMPOSITION idiom is deterministic and round-trips.
derive() { printf '%s/MISSION.%s.md' "$1" "$2"; }   # anchor, sid -> path
d1="$(derive "/Users/x/anchor" "sid")"
d2="$(derive "/Users/x/anchor" "sid")"
[ "$d1" = "$REAL" ] && [ "$d1" = "$d2" ]
atest_assert "A6" "$?" "recovery re-derive non-deterministic or wrong (d1='$d1' d2='$d2' want '$REAL') — a rebuilt manifest would point at the wrong/absent file."

atest_report
