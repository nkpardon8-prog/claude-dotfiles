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
mc_await() { bash "$MW" await "$2" "${ROOT}/$1" "$3" >/dev/null 2>&1; }
# mc_state <subdir> <sid> -> stdout the bare await-state token.
mc_state() { bash "$MW" await-state "$2" "${ROOT}/$1" 2>/dev/null; }
# mc_cursor <subdir> <sid> -> stdout the bare cursor hash.
mc_cursor() { bash "$MW" cursor-hash "$2" "${ROOT}/$1" 2>/dev/null; }

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
