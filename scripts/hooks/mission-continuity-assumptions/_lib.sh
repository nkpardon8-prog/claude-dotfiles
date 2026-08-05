#!/usr/bin/env bash
# _lib.sh - shared harness + assertions for the mission-continuity assumption suite.
# SOURCED by every NN-*.sh case; not a case itself (run-all.sh lists the cases explicitly,
# and the leading underscore keeps it out of the NN-* namespace).
#
# WHAT THIS SUITE PROVES. The mission-stall fix rests on runtime contracts that are all
# QUIET when broken: an AWAIT bookmark that fails to stay outstanding (a dropped completion
# wake then silently clears -> the mission stalls forever), a cursor hash that does not move
# on an append (two queued wakes both advance -> a duplicate transition), and a no-detach
# gate that fails to block an orphaning `nohup codex &`. None of these throw; each is a green
# tick over a dead leg. A contract whose failure mode is silent gets an assumption suite.
#
# HERMETIC BY CONSTRUCTION. Each case builds a throwaway mission root under `mktemp -d` and
# drives the LIVE mission-write.sh / no-detach-gate.py against it. No live DB, no OD, no
# network, no PHI, no ~/.claude state. The root is removed on exit, including failure paths.
# We exercise the REAL scripts (not copies): they are the thing under test and are pure over
# the sandbox root passed to them, so there is no seam that needs a checked-in snapshot.
#
# bash 3.2 safe (macOS /bin/bash): no associative arrays, no `mapfile`, no ${var^^}.

# --- gate ---------------------------------------------------------------------------------
# A hermetic suite carries no safety need for a gate, but its Validation-Gates siblings all
# gate on a _SMOKE_ALLOW_ env, and a suite that silently runs when its siblings refuse trains
# the wrong reflex. UNIFORMITY CONVENTION, NOT A SAFETY CLAIM - unset it and every case exit 2.
mc_gate() {
  if [ "${MISSIONCONT_SMOKE_ALLOW_DEV:-}" != "true" ]; then
    echo "REFUSED: set MISSIONCONT_SMOKE_ALLOW_DEV=true to run assumption tests" >&2
    exit 2
  fi
}

mc_cleanup() {
  [ -n "${ROOT:-}" ] || return 0
  rm -rf "$ROOT" 2>/dev/null || echo "CLEANUP WARNING: ${ROOT}" >&2
}

mc_setup() {  # mc_setup <case-name>
  NAME="$1"
  DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd -P)"
  HOOKS="$(cd "${DIR}/.." && pwd -P)"                 # scripts/hooks
  MW="${HOOKS}/mission-write.sh"
  GATE="${HOOKS}/no-detach-gate.py"
  FIXTURE_TEST="${HOOKS}/test-no-detach-fixtures.py"
  [ -f "$MW" ]   || { echo "INFRA: missing mission-write.sh" >&2; exit 3; }
  command -v bash    >/dev/null 2>&1 || { echo "INFRA: bash required" >&2; exit 3; }
  command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 required" >&2; exit 3; }

  ROOT="$(mktemp -d "${TMPDIR:-/tmp}/missioncont-XXXXXX")" || { echo "INFRA: mktemp failed" >&2; exit 3; }
  trap mc_cleanup EXIT
  FAILS=0
}

# --- assertions ---------------------------------------------------------------------------
mc_fail() { echo "  FAIL: $1" >&2; FAILS=$((FAILS+1)); }
mc_ok()   { echo "  ok: $1"; }

# mc_eq <expected> <actual> <label>
mc_eq() {
  if [ "$1" = "$2" ]; then mc_ok "$3 (= '$1')"
  else mc_fail "$3: expected '$1', got '$2'"; fi
}

# mc_rc <expected-exit> <label> <cmd...> - run a command, capture rc, assert it.
mc_rc() {
  local want="$1" label="$2"; shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "$want" ]; then mc_ok "${label} (exit ${rc})"
  else mc_fail "${label}: exit ${rc}, expected ${want}"; fi
}

# mc_has <needle> <haystack> <label>
mc_has() { case "$2" in *"$1"*) mc_ok "$3: names '$1'";; *) mc_fail "$3: '$2' does not contain '$1'";; esac; }

# --- mission helpers ----------------------------------------------------------------------
# A fresh mission under a per-call subdir of ROOT so cases can hold several independent
# missions. Echoes the sid; the caller passes ROOT-relative subdir back in.
mc_new_mission() {  # mc_new_mission <subdir> <sid>  -> creates ROOT/<subdir>/MISSION.<sid>.md
  local sub="$1" sid="$2"
  mkdir -p "${ROOT}/${sub}" || { echo "INFRA: mkdir ${sub} failed" >&2; exit 3; }
  bash "$MW" create "$sid" "${ROOT}/${sub}" "hermetic mission plan" >/dev/null 2>&1 \
    || { echo "INFRA: mission create failed" >&2; exit 3; }
}

# mc_await <subdir> <sid> <fields...> - open/update the AWAIT marker.
# R8r2-A: the public `await` verb REFUSES a human got=0 opener (only pending-stop may mint one, under the
# mint lock). This WHITE-BOX helper needs to mint a human opener directly for the suite's lib-level AWAIT
# grammar + lifecycle cases. R8r3-R1: mission-write.sh now UNSETS `_MISSION_INTERNAL_HUMAN_OPEN` at its CLI
# entry, so passing it as an ENV var to `bash $MW await` (child-inherited) no longer lifts the got=0 human
# refusal - that env-inheritance path is exactly the bypass R1 closed. So this helper SOURCES the lib and
# calls mission_await_append directly with the flag as a same-process FUNCTION prefix - the identical
# sanctioned mechanism mission_pending_stop_mint uses (set inside the running process, not inherited). The
# flag is inert for job barriers and for got=1 closes (FIX A gates only the human got=0 branch). The
# PUBLIC-verb refusal (marker-less AND env-inherited) is proven by R8r2-A + R8r3-R1 in 08.
mc_await() { ( . "${HOOKS}/lib/mission-bridge.sh" >/dev/null 2>&1; _MISSION_INTERNAL_HUMAN_OPEN=1 mission_await_append "$2" "${ROOT}/$1" "$3" ) >/dev/null 2>&1; }
# mc_state <subdir> <sid> -> stdout the bare await-state token.
mc_state() { bash "$MW" await-state "$2" "${ROOT}/$1" 2>/dev/null; }
# mc_cursor <subdir> <sid> -> stdout the bare cursor hash.
mc_cursor() { bash "$MW" cursor-hash "$2" "${ROOT}/$1" 2>/dev/null; }
# mc_pending <subdir> <sid> <slug> <question> -> stdout the MINTED pd id (from `pending ok id=<pd>`).
mc_pending() { bash "$MW" pending "$2" "${ROOT}/$1" "$3" "$4" 2>/dev/null | sed -n 's/^mission-write: pending ok id=//p'; }
# mc_resolve <subdir> <sid> <pd-id> [resolution] - drain a minted pending decision.
mc_resolve() { bash "$MW" resolve "$2" "${ROOT}/$1" "$3" "${4:-resolved}" >/dev/null 2>&1; }
# mc_log_out <subdir> <sid> <entry> [idtag] -> combined stdout+stderr of the log verb (for refusal asserts).
mc_log_out() { bash "$MW" log "$2" "${ROOT}/$1" "$3" "${4:-}" 2>&1; }

# mc_pending_stop <subdir> <sid> <slug> <part> <round> <attempt> <phase> <question>
#   -> stdout the MINTED (or adopted) pd id (from `pending-stop ok id=<pd>`); empty on any refusal.
#   The BLOCKING barrier-opener: mints pd:<seq>-<slug> AND opens the durable human STOP AWAIT got=0.
mc_pending_stop() {
  bash "$MW" pending-stop "$2" "${ROOT}/$1" "$3" "$4" "$5" "$6" "$7" "$8" 2>/dev/null \
    | sed -n 's/^mission-write: pending-stop ok id=//p'
}
# mc_pending_stop_out <subdir> <sid> <slug> <part> <round> <attempt> <phase> <question>
#   -> combined stdout+stderr (for FAILED/refusal asserts: rc, sequence-exhausted, slug/line cap, etc).
mc_pending_stop_out() {
  bash "$MW" pending-stop "$2" "${ROOT}/$1" "$3" "$4" "$5" "$6" "$7" "$8" 2>&1
}
# mc_decision <subdir> <sid> <op> <outcome> -> write the durable DECISION marker for a human op.
#   op is `<seq>-<slug>`; the idtag is the pinned `pd-<seq>-decision-<slug>` (the lib gen-tags it).
mc_decision() {
  local _seq="${3%%-*}" _slug="${3#*-}"
  bash "$MW" log "$2" "${ROOT}/$1" "[mission] DECISION op=${3} outcome=${4}" "pd-${_seq}-decision-${_slug}" >/dev/null 2>&1
}
# mc_close_human <subdir> <sid> <op> [outcome] [part] [round] [attempt] [phase]
#   Close a human STOP the way the lib demands: DECISION marker FIRST (lib-enforced DECISION-first),
#   THEN the `await got=need` close. Without the DECISION the got=1 close is REFUSED and the barrier
#   stays live, so this two-step is the ONLY legitimate close order.
mc_close_human() {
  local _sub="$1" _sid="$2" _op="$3" _out="${4:-approve}"
  local _part="${5:-1}" _round="${6:-1}" _att="${7:-1}" _phase="${8:-decision}"
  mc_decision "$_sub" "$_sid" "$_op" "$_out"
  bash "$MW" await "$_sid" "${ROOT}/${_sub}" \
    "part=${_part} phase=${_phase} round=${_round} kind=human op=${_op} attempt=${_att} need=1 got=1" >/dev/null 2>&1
}
# mc_await_out <subdir> <sid> <fields...> -> combined stdout+stderr of the await verb (for refusal asserts).
# Carries the R8r2-A white-box marker (mirrors mc_await) so a got=1 close under test reaches the
# DECISION-first gate rather than the public-verb human-opener refusal. Marker is inert for got=1 closes.
mc_await_out() { _MISSION_INTERNAL_HUMAN_OPEN=1 bash "$MW" await "$2" "${ROOT}/$1" "$3" 2>&1; }
# mc_resolve_out <subdir> <sid> <pd-id> [resolution] -> combined stdout+stderr of resolve (for drain /
# never-existed / idempotent-redrive asserts). The process always exits 0; the rc is in the printed line.
mc_resolve_out() { bash "$MW" resolve "$2" "${ROOT}/$1" "$3" "${4:-resolved}" 2>&1; }
# mc_has_pd <subdir> <sid> <pd-id> -> stdout the count of `- [pd:<id>]` lines in the mission .md (drain
# check). grep -c prints `0` AND exits 1 on no match, so capture-then-print (never `|| echo`, which would
# double the count line).
mc_has_pd() {
  local _n
  _n=$(grep -c "^- \[${3}\] " "${ROOT}/$1/MISSION.$2.md" 2>/dev/null)
  printf '%s\n' "${_n:-0}"
}
# mc_log_file <subdir> <sid> -> the mission LOG path (where DECISION lines and idtag stream land).
mc_log_file() { printf '%s\n' "${ROOT}/$1/MISSION.$2.log"; }

# --- finish -------------------------------------------------------------------------------
mc_finish() {  # mc_finish <fingerprint-json> <summary>
  local fp="${DIR}/${NAME}.fingerprint.json"
  if [ "${FAILS}" -gt 0 ]; then
    echo "FAIL ${NAME}: ${FAILS} assertion(s)" >&2
    exit 1
  fi
  printf '%s\n' "$1" > "$fp"
  echo "PASS ${NAME}: $2"
  exit 0
}
