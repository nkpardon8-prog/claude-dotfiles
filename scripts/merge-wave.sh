#!/usr/bin/env bash
# merge-wave.sh - INCREMENTAL, RESUMABLE integration of one write wave.
#
# usage: merge-wave.sh <wave-state.json>
#
# SCHEMA AUTHORITY: docs/wave-plan-schema.md (wave_state = s5, event = s7).
#
# What it does, in order:
#   1. Re-verifies the wave INLINE via verify-parallel-wave.mjs --wave-state. A nonzero
#      verdict exits with that exact code and merges NOTHING.
#   2. Merges each chunk branch in DECLARED order with --no-ff, skipping ids already in
#      merged_chunks[], and records {id, merge_sha} back into the wave-state VIA NODE
#      (read-modify-write to <state>.tmp then rename - no jq dependency, and no partial JSON
#      if the process dies mid-write).
#   3. Emits ONE outcome event per run (merge failure, or success).
#
# Failure semantics are pinned to what the assumption tests actually proved
# (dentall scripts/parallelizer-assumptions/03-merge-wave-failure-semantics.sh):
#   - `git merge --abort` ERRORS when no merge is in progress, and an untracked-file
#     collision makes git refuse BEFORE starting the merge (no MERGE_HEAD). So the abort is
#     conditional on MERGE_HEAD existing - a blanket abort would turn a clean refusal into a
#     confusing second error.
#   - Either way the tree ends CLEAN at the last successful merge tip. Earlier merges stay,
#     by design: that is what makes a re-run a RESUME rather than a restart.
#
# NEVER deletes a worktree or a branch. Teardown is barrier step (d)'s job, after the gates.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CHECKER="${SCRIPT_DIR}/verify-parallel-wave.mjs"
WAVES_DIR="${PARALLEL_WAVES_DIR:-$HOME/.claude/parallel-waves}"

die() { echo "merge-wave: $*" >&2; exit 2; }

[ $# -eq 1 ] || die "usage: merge-wave.sh <wave-state.json>"
STATE="$1"
[ -f "$STATE" ] || die "wave-state file not found: ${STATE}"
[ -f "$CHECKER" ] || die "checker not found beside this script: ${CHECKER}"
command -v node >/dev/null 2>&1 || die "node is required"

REPO=""
WAVE="null"

# --- event emission (schema doc s7 + s8: ONE serializer) ----------------------------------
# merge-wave writes with tool_mode "wave-state" (an operation ON the wave-state; the closed
# tool_mode set has no fourth value to invent). There is exactly ONE event serializer -
# buildEventLine() in the checker - and merge-wave routes through it via the --emit-event mode
# instead of re-implementing the 480-byte fixed-key line in bash+sed. PARALLEL_WAVES_DIR is
# inherited by the child, so the event lands in the same log the checker itself appends to.
emit_event() {  # emit_event <exit> <reason>
  mkdir -p "$WAVES_DIR" 2>/dev/null || {
    echo "merge-wave: WARNING - cannot create ${WAVES_DIR}; event not recorded" >&2; return 0; }
  node "$CHECKER" --emit-event --exit "$1" --reason "$2" --repo-root "$REPO" --wave "$WAVE" \
    || echo "merge-wave: WARNING - could not append event via ${CHECKER}" >&2
}

# --- 1. fresh inline verification -------------------------------------------------------
# The checker writes its OWN event for this invocation, including on the corrupt/unparseable
# state path (exit 2). So nothing is double-logged here, and a refusal is already on record.
node "$CHECKER" --wave-state "$STATE"
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "merge-wave: checker exited ${RC} - MERGED NOTHING. Reconcile serially, then re-run." >&2
  exit "$RC"
fi

# --- 1b. read the state (node; a corrupt file refuses loudly BEFORE any merge) ------------
STATE_TSV="$(node -e '
const fs = require("fs");
const st = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (!st || typeof st !== "object" || Array.isArray(st)) throw new Error("wave_state is not an object");
if (typeof st.repo_root !== "string" || !st.repo_root) throw new Error("repo_root missing");
if (!Number.isInteger(st.wave)) throw new Error("wave missing");
if (!Array.isArray(st.merged_chunks)) throw new Error("merged_chunks missing");
if (!Array.isArray(st.chunks) || st.chunks.length === 0) throw new Error("chunks missing");
const done = new Set(st.merged_chunks.map(function (m) { return m && m.id; }));
const out = [st.repo_root + "\t" + st.wave];
st.chunks.forEach(function (c) {
  if (!c || typeof c.id !== "string" || typeof c.branch !== "string") throw new Error("chunk shape");
  if (/[\t\n]/.test(c.id + c.branch)) throw new Error("chunk id or branch contains whitespace");
  out.push(c.id + "\t" + c.branch + "\t" + (done.has(c.id) ? "1" : "0"));
});
process.stdout.write(out.join("\n") + "\n");
' "$STATE" 2>&1)"
if [ $? -ne 0 ]; then
  echo "merge-wave: REFUSING - wave-state is corrupt or unreadable: ${STATE}" >&2
  echo "${STATE_TSV}" >&2
  exit 2
fi

REPO="$(printf '%s\n' "$STATE_TSV" | sed -n '1p' | cut -f1)"
WAVE="$(printf '%s\n' "$STATE_TSV" | sed -n '1p' | cut -f2)"
CHUNK_LINES="$(printf '%s\n' "$STATE_TSV" | sed -n '2,$p')"
[ -n "$REPO" ] || die "wave-state has an empty repo_root"

# --- 1c. branch-name safety (schema doc s2.1 / s5.2) --------------------------------------
# Every branch name is handed to `git merge`. The node pre-check only rejected tab/newline, so
# a leading dash could be read as a git option and a malformed ref could name the wrong commit.
# Validate each branch as a real git branch ref (format-only; existence is proven by the
# checker's rule 13 branch==HEAD binding) and reject a leading dash, BEFORE any merge. Fail
# closed: refuse the whole wave and merge nothing.
while IFS="$(printf '\t')" read -r _BID _BBRANCH _BDONE; do
  [ -n "${_BBRANCH:-}" ] || continue
  case "$_BBRANCH" in
    -*) echo "merge-wave: REFUSING - chunk ${_BID} branch '${_BBRANCH}' begins with a dash" >&2
        emit_event 2 io_error; exit 2 ;;
  esac
  if ! git -C "$REPO" check-ref-format --branch "$_BBRANCH" >/dev/null 2>&1; then
    echo "merge-wave: REFUSING - chunk ${_BID} branch '${_BBRANCH}' is not a valid git branch ref" >&2
    emit_event 2 io_error; exit 2
  fi
done <<< "$CHUNK_LINES"

# --- state mutation: read-modify-write via node, tmp + rename -----------------------------
record_merge() {  # record_merge <chunk-id> <merge-sha>
  node -e '
const fs = require("fs");
const state = process.argv[1], id = process.argv[2], sha = process.argv[3];
const st = JSON.parse(fs.readFileSync(state, "utf8"));
if (!Array.isArray(st.merged_chunks)) throw new Error("merged_chunks missing");
if (!st.merged_chunks.some(function (m) { return m && m.id === id; })) {
  st.merged_chunks.push({ id: id, merge_sha: sha });
}
const tmp = state + ".tmp";
fs.writeFileSync(tmp, JSON.stringify(st, null, 2) + "\n");
fs.renameSync(tmp, state);
' "$STATE" "$1" "$2"
}

# --- 2. merge in declared order, skipping what is already merged --------------------------
MERGED=0
SKIPPED=0
while IFS="$(printf '\t')" read -r CID CBRANCH CDONE; do
  [ -n "${CID:-}" ] || continue
  if [ "${CDONE:-0}" = "1" ]; then
    echo "merge-wave: skip ${CID} - already in merged_chunks[] (resume)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  echo "merge-wave: merging ${CID} (${CBRANCH}) into ${REPO}"
  MERGE_OUT="$(git -C "$REPO" merge --no-ff -m "wave ${WAVE}: merge ${CID}" "$CBRANCH" 2>&1)"
  if [ $? -eq 0 ]; then
    MERGE_SHA="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
    if [ -z "$MERGE_SHA" ]; then
      echo "merge-wave: merged ${CID} but could not resolve the new HEAD" >&2
      emit_event 2 io_error
      exit 2
    fi
    if ! record_merge "$CID" "$MERGE_SHA"; then
      # The merge is real and in history; the state file is now behind it. Say so loudly -
      # a silent miss here would make the next resume merge the same branch twice.
      echo "merge-wave: MERGED ${CID} as ${MERGE_SHA} but FAILED to record it in ${STATE}" >&2
      echo "merge-wave: fix the state file by hand before re-running, or the resume will repeat this merge." >&2
      emit_event 2 io_error
      exit 2
    fi
    MERGED=$((MERGED + 1))
    echo "merge-wave: recorded ${CID} -> ${MERGE_SHA}"
    continue
  fi

  # --- merge failure -----------------------------------------------------------------
  echo "merge-wave: MERGE FAILED for ${CID} (${CBRANCH})" >&2
  echo "${MERGE_OUT}" >&2
  GITDIR="$(git -C "$REPO" rev-parse --absolute-git-dir 2>/dev/null)"
  if [ -n "${GITDIR:-}" ] && [ -f "${GITDIR}/MERGE_HEAD" ]; then
    # A real conflict: a merge IS in progress, so --abort returns the tree to the last
    # successful merge tip (proven: 03-merge-wave-failure-semantics A3).
    if git -C "$REPO" merge --abort >/dev/null 2>&1; then
      echo "merge-wave: aborted the in-progress merge; tree restored to the last successful merge tip" >&2
    else
      echo "merge-wave: WARNING - 'git merge --abort' failed; resolve ${REPO} by hand" >&2
    fi
  else
    # git refused BEFORE starting (e.g. an untracked file in repo_root would be overwritten).
    # `git merge --abort` ERRORS in this state (proven: A1/A2) - do not run it.
    echo "merge-wave: no merge was in progress (git refused before starting); not running 'merge --abort'" >&2
  fi
  if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
    echo "merge-wave: WARNING - ${REPO} is NOT clean after the failed merge; inspect it before re-running" >&2
  fi
  echo "merge-wave: ${MERGED} chunk(s) merged before the failure and remain in history - a re-run RESUMES from ${CID}." >&2
  emit_event 1 merge_conflict
  exit 1
done <<< "$CHUNK_LINES"   # here-STRING, not a here-doc: the content must never be re-expanded

# --- 3. success ---------------------------------------------------------------------------
emit_event 0 merge_success
echo "merge-wave: wave ${WAVE} integrated - ${MERGED} merged, ${SKIPPED} already present. HEAD: $(git -C "$REPO" rev-parse HEAD 2>/dev/null)"
exit 0
