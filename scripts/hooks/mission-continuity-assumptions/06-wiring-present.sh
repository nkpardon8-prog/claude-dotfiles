#!/usr/bin/env bash
# 06 - wiring-present: STRUCTURAL regression net for two silent-removal risks the round-1 review
# caught (C13 cold-start prompt broken, C14 post-compact resume not routed into the wake routine).
# These are PROSE contracts an LLM follows, so they cannot be unit-tested by behavior; but they CAN
# be guarded against silent deletion. Each assertion greps for a load-bearing wiring token that, if
# it vanishes, means the fix regressed - a reword that trips this test is a prompt to re-verify, not
# a nuisance. The tokens chosen are the stable structural ones (verb names / section refs), not prose.
#
# NEGATIVE CONTROL: delete the `<PLAYBOOK>`/`<MW>` substitution from the §12.2 tick prompt (C13) or
# the `§12.1 wake routine` routing from post-compact-resume.md's mission-mode section (C14) and the
# matching assertion goes RED.
set -uo pipefail
DIR0="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${DIR0}/_lib.sh"
mc_gate
mc_setup "06-wiring-present"

CMDS="$(cd "${HOOKS}/../../commands" && pwd -P)"
MISSION_MD="${CMDS}/mission.md"
PCR_MD="${CMDS}/post-compact-resume.md"
[ -f "$MISSION_MD" ] || { echo "INFRA: missing mission.md" >&2; exit 3; }
[ -f "$PCR_MD" ]     || { echo "INFRA: missing post-compact-resume.md" >&2; exit 3; }

grepc() { grep -qF -- "$1" "$2"; }  # fixed-string presence

# C13 - the cold-start tick prompt must carry the PLAYBOOK path AND the mission-write.sh CLI path, so
# a wake with no memory can find the numbered sections (they live in the PLAYBOOK, NOT the <MFILE>
# four-zone artifact) and run every bridge verb.
if grepc "full playbook <PLAYBOOK>" "$MISSION_MD"; then mc_ok "C13 tick prompt names <PLAYBOOK>"; else mc_fail "C13 tick prompt lost <PLAYBOOK> path"; fi
if grepc "bridge CLI <MW>" "$MISSION_MD"; then mc_ok "C13 tick prompt names <MW> (mission-write.sh)"; else mc_fail "C13 tick prompt lost <MW> path"; fi
if grepc "Read the PLAYBOOK <PLAYBOOK>" "$MISSION_MD"; then mc_ok "C13 tick prompt reads the PLAYBOOK, not <MFILE>, for sections"; else mc_fail "C13 tick prompt does not point at the PLAYBOOK for sections"; fi

# C14 - post-compact resume must ROUTE a mid-mission resume into the §12.1 wake routine, not do the
# old last-round hand-resume (which re-drives the whole barrier or skips a human stop mid-barrier).
if grepc "§12.1 wake routine" "$PCR_MD"; then mc_ok "C14 post-compact routes into the §12.1 wake routine"; else mc_fail "C14 post-compact does NOT route into the wake routine"; fi
if grepc "JUST ANOTHER WAKE SOURCE" "$PCR_MD"; then mc_ok "C14 post-compact framed as a wake source (§12.4 composition)"; else mc_fail "C14 §12.4 composition framing missing"; fi
if grepc "do NOT hand-resume the last round line" "$PCR_MD"; then mc_ok "C14 old last-round resume explicitly forbidden"; else mc_fail "C14 does not forbid the old last-round resume"; fi

mc_finish '{"c13_playbook":"present","c13_mw":"present","c13_reads_playbook":"present","c14_routes_wake":"present","c14_wake_source":"present","c14_forbids_last_round":"present"}' \
  "6 assertions (C13 cold-start prompt completeness + C14 post-compact wake-routine routing are wired)"
