#!/usr/bin/env bash
# _common.sh - shared setup for the transfer-assumptions suite. Sourced, never run directly
# (its name does not match run-all.sh's NN-*.sh pattern, so it is never picked up as a test).
#
# Every test drives the REAL scripts (transfer-send.sh, resumework) as subprocesses against a
# throwaway sandbox: never reimplement their rules in bash, only build situations for them.
#
# One physical $HOME plays BOTH "Mac A" and "Mac B" sequentially for most tests (the same
# same-machine proxy the plan itself uses for assumption A1): CWD/ROOT are absolute paths that
# must be identical on both ends anyway, so reusing one directory tree is the simplest hermetic
# stand-in for "same username, same paths, two Macs". Test 07 (identity) is the one test that
# genuinely needs two different $HOME directories, since it is exactly about that mismatch.
set -uo pipefail

TX_MARKER="tx-atest"
TX_REPO="$HOME/.claude-dotfiles"
TX_LIB="$TX_REPO/scripts/transfer/transfer-lib.sh"
TX_SEND="$TX_REPO/scripts/transfer/transfer-send.sh"
TX_RESUME="$TX_REPO/scripts/transfer/resumework"

[ -f "$TX_LIB" ] || { echo "INFRA: transfer-lib.sh not found at $TX_LIB" >&2; exit 3; }
[ -x "$TX_SEND" ] || { echo "INFRA: transfer-send.sh missing or not executable at $TX_SEND" >&2; exit 3; }
[ -x "$TX_RESUME" ] || { echo "INFRA: resumework missing or not executable at $TX_RESUME" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 missing" >&2; exit 3; }
command -v git >/dev/null 2>&1 || { echo "INFRA: git missing" >&2; exit 3; }

# Source the REAL lib directly (not a reimplementation - it IS the function under test) for a
# few cross-cutting checks (tx_git_diff_head hashing, tx_normalize/tx_locator in test 06).
# shellcheck source=../../transfer/transfer-lib.sh
. "$TX_LIB"

export GIT_AUTHOR_NAME="tx-test" GIT_AUTHOR_EMAIL="tx-test@example.invalid"
export GIT_COMMITTER_NAME="tx-test" GIT_COMMITTER_EMAIL="tx-test@example.invalid"

FAIL_N=0
FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }
ok_report() {  # ok_report <test-name> <n-assertions-description>
  if [ "$FAIL_N" -gt 0 ]; then
    echo "FAIL: $1" >&2
    printf '%s' "$FAIL_MSGS" >&2
    exit 1
  fi
  echo "PASS: $1 - $2"
  exit 0
}

# tx_sandbox <suffix> -> creates+prints a fresh scratch root under $TMPDIR; reaps orphans >60min.
tx_sandbox() {
  local suffix="$1" run_id
  run_id=$(python3 -c 'import uuid; print(uuid.uuid4().hex[:12])')
  find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${TX_MARKER}-*" -mmin +60 -exec rm -rf {} + 2>/dev/null
  mktemp -d "${TMPDIR:-/tmp}/${TX_MARKER}-${suffix}-${run_id}-XXXXXX"
}

tx_new_sid() { python3 -c 'import uuid; print(uuid.uuid4().hex)'; }
tx_new_uuid() { python3 -c 'import uuid; print(str(uuid.uuid4()))'; }
tx_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
tx_sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
tx_mtime() { stat -f %m "$1" 2>/dev/null; }

# tx_write_transcript <home> <sid> <cwd> - a minimal, realistic-shaped transcript with a distinct
# marker string, so a restored copy can be proven byte-identical AND content-bearing.
tx_write_transcript() {
  local home="$1" sid="$2" cwd="$3" pdir
  pdir="$home/.claude/projects/$(tx_slug "$cwd")"
  mkdir -p "$pdir"
  python3 - "$pdir/$sid.jsonl" "$cwd" "$sid" <<'PY'
import json, sys
path, cwd, sid = sys.argv[1:4]
lines = [
    {"type": "user", "sessionId": sid, "cwd": cwd,
     "message": {"role": "user", "content": "remember the word PINEAPPLE-42 for later"}},
    {"type": "assistant", "sessionId": sid, "cwd": cwd,
     "message": {"role": "assistant", "content": "noted: PINEAPPLE-42"}},
]
with open(path, "w") as fh:
    for l in lines:
        fh.write(json.dumps(l) + "\n")
PY
}

# tx_write_session <home> <sid> <cwd> [pid] - a session registry entry (not required to be a
# LIVE process for a plain --cwd send; only --seal-after-exit needs a real pid, via TX_SEAL_PID).
tx_write_session() {
  local home="$1" sid="$2" cwd="$3" pid="${4:-$$}"
  mkdir -p "$home/.claude/sessions"
  python3 - "$home" "$sid" "$cwd" "$pid" <<'PY'
import json, os, sys, time
home, sid, cwd, pid = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
entry = {"pid": pid, "sessionId": sid, "cwd": cwd, "startedAt": int(time.time() * 1000)}
with open(os.path.join(home, ".claude", "sessions", "%d.json" % pid), "w") as fh:
    json.dump(entry, fh)
PY
}

tx_write_caption() {  # tx_write_caption <home> <sid> <text>
  mkdir -p "$1/.claude/session-status"
  printf '%s\n' "$3" > "$1/.claude/session-status/$2.txt"
}

# tx_write_handoff <root> <sid> [age_secs] [marker_sid] - a minimal CLAUDE.local.<sid>.md that
# satisfies transfer-send.sh's marker + freshness check (default: fresh, matching sid).
tx_write_handoff() {
  local root="$1" sid="$2" age="${3:-0}"
  local msid="${4:-$sid}"
  local f="$root/CLAUDE.local.$sid.md"
  cat > "$f" <<EOF
# Handoff for $sid (test fixture)

Fixture handoff for the transfer-assumptions suite.

<!-- END-OF-HANDOFF schema=v1 sid=$msid -->
EOF
  if [ "$age" != 0 ]; then
    local t
    t=$(( $(date +%s) - age ))
    touch -t "$(date -r "$t" '+%Y%m%d%H%M.%S' 2>/dev/null)" "$f" 2>/dev/null || \
      python3 -c "import os,sys; os.utime(sys.argv[1], (float(sys.argv[2]), float(sys.argv[2])))" "$f" "$t"
  fi
}

# tx_init_origin <origin-dir> <clone-dir> - a bare origin plus a clone with one pushed commit.
# Prints the clone's default branch name.
tx_init_origin() {
  local origin="$1" clone="$2"
  git init -q --bare "$origin"
  git clone -q "$origin" "$clone" 2>/dev/null
  printf 'seed\n' > "$clone/README.md"
  git -C "$clone" add README.md
  git -C "$clone" commit -q -m "seed"
  local br
  br=$(git -C "$clone" symbolic-ref --short HEAD)
  git -C "$clone" push -q origin "$br"
  printf '%s' "$br"
}

# tx_run_send <home> <drop> [args...] - runs the REAL transfer-send.sh; stdout/stderr captured to
# $TX_LAST_OUT/$TX_LAST_ERR, return code in $TX_LAST_RC. Extracts CODE/LOCATOR into $TX_LAST_CODE
# / $TX_LAST_LOC when present.
TX_LAST_OUT=""; TX_LAST_ERR=""; TX_LAST_RC=0; TX_LAST_CODE=""; TX_LAST_LOC=""
tx_run_send() {
  local home="$1" drop="$2"; shift 2
  local out err rc
  out=$(mktemp "${TMPDIR:-/tmp}/tx-out.XXXXXX"); err=$(mktemp "${TMPDIR:-/tmp}/tx-err.XXXXXX")
  ( HOME="$home" TX_DROP_DIR="$drop" "$TX_SEND" "$@" >"$out" 2>"$err" )
  rc=$?
  TX_LAST_OUT=$(cat "$out"); TX_LAST_ERR=$(cat "$err"); TX_LAST_RC=$rc
  TX_LAST_CODE=$(printf '%s\n' "$TX_LAST_OUT" | sed -n 's/^CODE=//p' | head -1)
  TX_LAST_LOC=$(printf '%s\n' "$TX_LAST_OUT" | sed -n 's/^LOCATOR=//p' | head -1)
  rm -f "$out" "$err"
  return "$rc"
}

# tx_run_resume <home> <drop> <code> [args...] - runs the REAL resumework. Same capture contract.
tx_run_resume() {
  local home="$1" drop="$2" code="$3"; shift 3
  local out err rc
  out=$(mktemp "${TMPDIR:-/tmp}/tx-out.XXXXXX"); err=$(mktemp "${TMPDIR:-/tmp}/tx-err.XXXXXX")
  ( HOME="$home" TX_DROP_DIR="$drop" "$TX_RESUME" "$code" "$@" >"$out" 2>"$err" )
  rc=$?
  TX_LAST_OUT=$(cat "$out"); TX_LAST_ERR=$(cat "$err"); TX_LAST_RC=$rc
  rm -f "$out" "$err"
  return "$rc"
}

tx_combined() { printf '%s\n%s\n' "$TX_LAST_OUT" "$TX_LAST_ERR"; }
