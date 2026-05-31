# shellcheck shell=bash
# _common.sh — shared harness for the mission-bridge assumption tests.
# Sourced by every NN-*.sh test. macOS bash 3.2.57 compatible:
#   no mapfile, no associative arrays, no ${var,,}, no flock, no GNU timeout.
#
# Contract every test inherits from here:
#   - Safety gate: refuse (exit 2) unless MISSION_BRIDGE_SMOKE_ALLOW_TMP=true.
#   - Per-run UUID + stable namespace marker for precise + orphan-reaping cleanup.
#   - Hermetic scratch dir under $TMPDIR; trap-cleanup on EXIT; startup orphan reaper.
#   - Deterministic exit codes: 0 PASS / 1 FAIL / 2 REFUSED / 3 INFRASTRUCTURE.
#   - Assertion anchors A1.. with crisp FAIL output.
#
# These tests prove OS/shell BEHAVIOR the mission-bridge implementation depends on.
# They run NOW, before the mission_* primitives exist, by encoding the EXACT shell
# idioms from the plan's Key Pseudocode and proving the underlying guarantee holds.

set -u

# ---- Safety gate (first thing, per /script pattern) -------------------------
ATEST_GATE_VAR="MISSION_BRIDGE_SMOKE_ALLOW_TMP"
atest_gate() {
  eval "_g=\${${ATEST_GATE_VAR}:-}"
  if [ "${_g:-}" != "true" ]; then
    echo "REFUSED: set ${ATEST_GATE_VAR}=true to run mission-bridge assumption tests" >&2
    echo "         (tests are hermetic — they touch only a scratch dir under \$TMPDIR)" >&2
    exit 2
  fi
}

# ---- Identity: per-run UUID + constant namespace marker ---------------------
ATEST_MARKER="__mbridge_atest__"          # constant: lets a later run reap prior orphans
atest_runid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'; else echo "$$-$(date +%s 2>/dev/null || echo 0)"; fi
}

# ---- Scratch dir (hermetic) + startup orphan reaper -------------------------
# Reaps scratch dirs from PRIOR crashed runs (marker + mtime > ~1h) because a
# trap does not survive SIGKILL. Then creates THIS run's dir.
ATEST_DIR=""
atest_scratch() {
  _base="${TMPDIR:-/tmp}"
  # reap orphans (best-effort; failure never changes exit code)
  if command -v find >/dev/null 2>&1; then
    find "$_base" -maxdepth 1 -type d -name "${ATEST_MARKER}*" -mmin +60 -exec rm -rf {} + 2>/dev/null || true
  fi
  ATEST_DIR="$_base/${ATEST_MARKER}${ATEST_RUNID}"
  rm -rf "$ATEST_DIR" 2>/dev/null || true
  mkdir -p "$ATEST_DIR" || { echo "INFRA: cannot create scratch dir $ATEST_DIR" >&2; exit 3; }
}
atest_cleanup() { [ -n "${ATEST_DIR:-}" ] && rm -rf "$ATEST_DIR" 2>/dev/null; return 0; }

# ---- Assertion bookkeeping --------------------------------------------------
ATEST_NAME="${ATEST_NAME:-unnamed}"
ATEST_FAILS=""
ATEST_PASSED_ANCHORS=""
# atest_assert <anchor> <condition-rc:0|nonzero> <message-on-fail>
atest_assert() {
  _anchor="$1"; _rc="$2"; _msg="$3"
  if [ "$_rc" = "0" ]; then
    ATEST_PASSED_ANCHORS="${ATEST_PASSED_ANCHORS}${_anchor} "
  else
    ATEST_FAILS="${ATEST_FAILS}\n  - ${_anchor} ${_msg}"
  fi
}
# atest_infra <message>  — couldn't even run; exit 3 (NOT a logical fail)
atest_infra() { echo "INFRA: ${ATEST_NAME} — $1" >&2; exit 3; }

atest_report() {
  if [ -n "$ATEST_FAILS" ]; then
    echo "FAIL: ${ATEST_NAME}" >&2
    printf '%b\n' "$ATEST_FAILS" >&2
    exit 1
  fi
  echo "PASS: ${ATEST_NAME} — assertions (${ATEST_PASSED_ANCHORS})"
  exit 0
}

# ---- Init: every test calls atest_init first --------------------------------
atest_init() {
  ATEST_NAME="$1"
  atest_gate
  ATEST_RUNID="$(atest_runid)"
  atest_scratch
  trap atest_cleanup EXIT
}

# ---- Small portable helpers -------------------------------------------------
# byte length of stdin (locale-independent)
atest_bytes() { LC_ALL=C wc -c | tr -d ' '; }
# device id of a path (BSD stat). echoes the dev number or empty.
atest_devid() { stat -f '%d' "$1" 2>/dev/null; }
