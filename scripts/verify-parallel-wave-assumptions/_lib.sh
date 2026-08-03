#!/usr/bin/env bash
# _lib.sh - shared fixture builders and assertions for the verify-parallel-wave assumption
# suite. SOURCED by every NN-*.sh case; it is not a case itself (run-all.sh lists the cases
# explicitly, and the leading underscore keeps it out of the NN-* namespace).
#
# HERMETIC by construction: every case gets its own `mktemp -d` sandbox holding the repo, the
# worktrees, the plans, the states, AND its own PARALLEL_WAVES_DIR. No case can reach the real
# ~/.claude/parallel-waves/rework.log, so running the suite never pollutes the measurement the
# whole parallelizer story rests on.
#
# bash 3.2 safe (macOS /bin/bash): no associative arrays, no `mapfile`, no ${var^^}.

# --- gate --------------------------------------------------------------------------------
wc_gate() {
  if [ "${WAVECHECK_SMOKE_ALLOW_DEV:-}" != "true" ]; then
    echo "REFUSED: set WAVECHECK_SMOKE_ALLOW_DEV=true to run assumption tests" >&2
    exit 2
  fi
}

wc_cleanup() {
  [ -n "${BASE:-}" ] || return 0
  rm -rf "$BASE" 2>/dev/null || echo "CLEANUP WARNING: ${BASE}" >&2
}

wc_setup() {  # wc_setup <case-name>
  NAME="$1"
  DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd -P)"
  CHECKER="${DIR}/../verify-parallel-wave.mjs"
  MERGE_WAVE="${DIR}/../merge-wave.sh"
  [ -f "$CHECKER" ] || { echo "INFRA: missing ${CHECKER}" >&2; exit 3; }
  [ -f "$MERGE_WAVE" ] || { echo "INFRA: missing ${MERGE_WAVE}" >&2; exit 3; }
  command -v node >/dev/null 2>&1 || { echo "INFRA: node is required" >&2; exit 3; }
  command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 is required" >&2; exit 3; }
  BASE="$(mktemp -d "${TMPDIR:-/tmp}/wavecheck-XXXXXX")" || { echo "INFRA: mktemp failed" >&2; exit 3; }
  WAVES="${BASE}/waves"
  mkdir -p "$WAVES" || { echo "INFRA: cannot create ${WAVES}" >&2; exit 3; }
  export PARALLEL_WAVES_DIR="$WAVES"
  FAILS=()
  WC_OUT=""
  WC_RC=0
  WC_REASON=""
  trap wc_cleanup EXIT
}

# --- git fixtures -------------------------------------------------------------------------
g() {  # g <repo-or-worktree> <git args...>
  local r="$1"; shift
  git -C "$r" -c user.email=wave@test -c user.name=wavetest -c commit.gpgsign=false "$@"
}

wc_repo() {  # wc_repo <dir> [<package.json scripts object>]
  mkdir -p "$1/src" || return 1
  g "$1" init -q -b main . || { echo "INFRA: git init failed" >&2; exit 3; }
  printf 'a0\n' > "$1/src/a.ts"
  printf 'b0\n' > "$1/src/b.ts"
  printf 'shared0\n' > "$1/src/shared.ts"
  # Tracked so the impl_plan_path dirty-tree exemption (schema doc s5) has something real to
  # be dirty about; never declared or touched by any chunk.
  printf '# impl plan\n' > "$1/impl-plan.md"
  if [ -n "${2:-}" ]; then printf '{"name":"fixture","private":true,"scripts":%s}\n' "$2" > "$1/package.json"; fi
  g "$1" add -A
  g "$1" commit -q -m init
}

# Builds the standard 2-chunk wave: a repo at REPO, base_sha at BASE_SHA, and two worktrees
# branched at that sha. Exports REPO BASE_SHA WT_A WT_B BR_A BR_B.
wc_wave() {  # wc_wave [<package.json scripts object>; pass "" for a repo with NO package.json]
  local scripts='{"typecheck":"tsc","test":"vitest"}'
  [ $# -gt 0 ] && scripts="$1"
  REPO="${BASE}/repo"
  wc_repo "$REPO" "$scripts"
  BASE_SHA="$(g "$REPO" rev-parse HEAD)"
  BR_A="w1-fixture-chunk-a"
  BR_B="w1-fixture-chunk-b"
  WT_A="${BASE}/wt/chunk-a"
  WT_B="${BASE}/wt/chunk-b"
  g "$REPO" worktree add -q -b "$BR_A" "$WT_A" "$BASE_SHA" || { echo "INFRA: worktree add failed" >&2; exit 3; }
  g "$REPO" worktree add -q -b "$BR_B" "$WT_B" "$BASE_SHA" || { echo "INFRA: worktree add failed" >&2; exit 3; }
}

wc_commit() {  # wc_commit <worktree> <message>
  g "$1" add -A
  g "$1" commit -q -m "$2"
}

# --- plan / state writers -------------------------------------------------------------------
wc_plan() {  # wc_plan <fixture-file> <out>
  sed -e "s#__REPO_ROOT__#${REPO}#g" -e "s#__BASE_SHA__#${BASE_SHA}#g" "${DIR}/fixtures/$1" > "$2"
}

# wc_mutate <in> <out> <python body operating on the parsed plan as `p`>
# Every mutant differs from the KNOWN-GOOD golden plan by exactly one rule violation, which
# is what makes a red result attributable to that rule and nothing else.
wc_mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
src, dst, body = sys.argv[1], sys.argv[2], sys.argv[3]
p = json.load(open(src))
exec(body)
json.dump(p, open(dst, "w"))
PY
}

# wc_state <out> <A_paths> <A_reads> <B_paths> <B_reads> \
#          [<impl_plan_path json>] [<merged json>] [<shared_hazard_paths json>] [<nosidecar>]
#
# v1.1: the state now names the wave_plan it was derived from (wave_plan_path) and echoes that
# plan's shared_hazard_paths. To keep every otherwise-valid state BLESSED, wc_state writes a
# matching wave_plan and runs --validate-plan to emit its <plan>.validated sidecar (the SAME
# code path --wave-state reads, so there is no hand-authored hash to drift). A state with bad
# topology fails plan validation, leaves no sidecar, and the wave-state rule the test targets
# fires anyway (the reason token is rule_violation either way). Pass "nosidecar" as arg 9 to
# suppress the sidecar entirely (the dedicated absent-sidecar case). Exports WC_PLAN.
wc_state() {
  local out="$1" ap="$2" ar="$3" bp="$4" br="$5"
  local impl="${6:-null}" merged="${7:-[]}" hazards="${8:-[]}" nosidecar="${9:-}"
  WC_PLAN="${out%.json}.waveplan.json"
  cat > "$WC_PLAN" <<JSON
{"schema_version":"parallelizer.v1.1","verdict":"FAN_OUT","confidence":"high",
 "analysis_basis":{"repo_root":"${REPO}","base_sha":"${BASE_SHA}","shared_hazard_paths":${hazards}},
 "waves":[{"wave":1,"chunks":[
  {"id":"chunk-a","items":[{"id":"I1","text":"chunk a"}],"exclusive_paths":${ap},"reads":${ar},
   "rationale":"chunk a","independent_of":[{"chunk_id":"chunk-b","reason":"disjoint"}],"write_set_confidence":"high"},
  {"id":"chunk-b","items":[{"id":"I2","text":"chunk b"}],"exclusive_paths":${bp},"reads":${br},
   "rationale":"chunk b","independent_of":[{"chunk_id":"chunk-a","reason":"disjoint"}],"write_set_confidence":"high"}
 ],"post_integration_commands":["npm run typecheck"]}],
 "hazards_found":[],"serial_reasons":[]}
JSON
  if [ "$nosidecar" != "nosidecar" ]; then
    # Best-effort blessing; a bad-topology plan simply leaves no sidecar (the target rule fires).
    node "$CHECKER" --validate-plan "$WC_PLAN" --repo-root "$REPO" --base-sha "$BASE_SHA" >/dev/null 2>&1 || true
  else
    rm -f "${WC_PLAN}.validated" 2>/dev/null || true
  fi
  cat > "$out" <<JSON
{"repo_root":"${REPO}","base_sha":"${BASE_SHA}","wave":1,
 "wave_plan_path":"${WC_PLAN}",
 "shared_hazard_paths":${hazards},
 "impl_plan_path":${impl},
 "merged_chunks":${merged},
 "gate_list":["npm run typecheck"],
 "chunks":[
  {"id":"chunk-a","branch":"${BR_A}","worktree":"${WT_A}","exclusive_paths":${ap},"reads":${ar}},
  {"id":"chunk-b","branch":"${BR_B}","worktree":"${WT_B}","exclusive_paths":${bp},"reads":${br}}]}
JSON
}

# --- assertions ------------------------------------------------------------------------------
wc_fail() { FAILS+=("$1"); }

wc_events_count() {
  if [ -f "${WAVES}/rework.log" ]; then wc -l < "${WAVES}/rework.log" | tr -d ' '; else echo 0; fi
}

wc_event_field() {  # wc_event_field <key>   -> the LAST event's value, or NOEVENT
  python3 -c '
import json, sys
try:
    lines = [l for l in open(sys.argv[1]) if l.strip()]
except OSError:
    print("NOEVENT"); raise SystemExit(0)
if not lines:
    print("NOEVENT"); raise SystemExit(0)
v = json.loads(lines[-1]).get(sys.argv[2], "MISSING")
print("null" if v is None else v)
' "${WAVES}/rework.log" "$1" 2>/dev/null || echo "NOEVENT"
}

# Runs the checker and enforces the invariants that hold for EVERY invocation of a named mode
# (schema doc s7): exactly ONE new event, whose `exit` agrees with the process exit and whose
# `reason`/`tool_mode` are inside their closed sets. Every case therefore re-proves the event
# contract for free, on both exit paths.
wc_check() {  # wc_check <expected-exit> <label> <checker args...>
  local exp="$1" label="$2"; shift 2
  local before after delta ev_exit ev_reason ev_mode
  before="$(wc_events_count)"
  WC_OUT="$(node "$CHECKER" "$@" 2>&1)"; WC_RC=$?
  after="$(wc_events_count)"
  delta=$((after - before))
  [ "$WC_RC" = "$exp" ] \
    || wc_fail "${label}: expected exit ${exp}, got ${WC_RC} :: $(printf '%s' "$WC_OUT" | head -2 | tr '\n' ' ')"
  [ "$delta" = "1" ] || wc_fail "${label}: expected exactly 1 new event, got ${delta}"
  ev_exit="$(wc_event_field exit)"
  ev_reason="$(wc_event_field reason)"
  ev_mode="$(wc_event_field tool_mode)"
  [ "$ev_exit" = "$WC_RC" ] || wc_fail "${label}: event exit=${ev_exit} disagrees with process exit ${WC_RC}"
  case "$ev_reason" in
    lt2_chunks|no_review|dirty_repo_root|merge_in_progress|pct_unknown|pct_over_60|stale_wave|dotfiles_unpaused|serial_correct|malformed|low_confidence|fan_out) ;;
    rule_violation|usage_error|io_error|merge_success|merge_conflict) ;;  # v1.1 de-aliased tokens
    *) wc_fail "${label}: event reason '${ev_reason}' is outside the closed set" ;;
  esac
  case "$ev_mode" in
    validate-plan|wave-state|log-decision) ;;
    *) wc_fail "${label}: event tool_mode '${ev_mode}' is outside the closed set" ;;
  esac
  WC_REASON="$ev_reason"
}

wc_check_noevent() {  # same, for the usage path that names no mode at all
  local exp="$1" label="$2"; shift 2
  local before after delta
  before="$(wc_events_count)"
  WC_OUT="$(node "$CHECKER" "$@" 2>&1)"; WC_RC=$?
  after="$(wc_events_count)"
  delta=$((after - before))
  [ "$WC_RC" = "$exp" ] || wc_fail "${label}: expected exit ${exp}, got ${WC_RC}"
  [ "$delta" = "0" ] || wc_fail "${label}: expected NO event for a mode-less invocation, got ${delta}"
}

wc_merge() {  # wc_merge <expected-exit> <expected-event-delta> <label> <state file>
  local exp="$1" dexp="$2" label="$3" state="$4"
  local before after delta
  before="$(wc_events_count)"
  WC_OUT="$(bash "$MERGE_WAVE" "$state" 2>&1)"; WC_RC=$?
  after="$(wc_events_count)"
  delta=$((after - before))
  [ "$WC_RC" = "$exp" ] \
    || wc_fail "${label}: expected merge-wave exit ${exp}, got ${WC_RC} :: $(printf '%s' "$WC_OUT" | head -3 | tr '\n' ' ')"
  [ "$delta" = "$dexp" ] || wc_fail "${label}: expected ${dexp} new event(s), got ${delta}"
}

wc_expect_reason() {  # wc_expect_reason <token> <label>
  [ "$WC_REASON" = "$1" ] || wc_fail "${2}: expected event reason '${1}', got '${WC_REASON}'"
}

wc_out_has() {  # wc_out_has <literal> <label>   - the operator must SEE the offending path/id
  printf '%s' "$WC_OUT" | grep -qF -- "$1" || wc_fail "${2}: output never mentioned '${1}'"
}

wc_out_lacks() {  # wc_out_lacks <literal> <label>
  printf '%s' "$WC_OUT" | grep -qF -- "$1" && wc_fail "${2}: output unexpectedly mentioned '${1}'"
  return 0
}

wc_finish() {  # wc_finish <fingerprint json> <summary>
  if [ "${#FAILS[@]}" -gt 0 ]; then
    echo "FAIL: ${NAME}"
    local f
    for f in "${FAILS[@]}"; do echo "  - ${f}"; done
    exit 1
  fi
  printf '%s\n' "$1" > "${DIR}/${NAME}.fingerprint.json"
  echo "PASS: ${NAME} - $2"
  exit 0
}
