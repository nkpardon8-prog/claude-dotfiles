#!/bin/bash
# codex-build-chunk.sh — the ONLY sanctioned way to let Codex WRITE code.
#
# Everywhere else in this repo Codex runs `-s read-only`. This wrapper is the single exception, and
# it exists because the permission was already half-written into /mission ("hand a mechanical chunk
# to Codex") while every invocation still pinned `-s read-only` - a licence that could not execute.
#
# THE RULE IT SPLITS (mission.md 6.5):
#   * Codex NEVER writes the mission bridge.        <- absolute, unchanged, enforced below
#   * Codex MAY implement an isolated, mechanical, well-specified chunk.   <- new, this script
#
# WHY A LINKED WORKTREE IS MANDATORY (the load-bearing safety property).
# `-s workspace-write` makes the `-C` directory writable. In a MAIN working tree, `.git/` lives
# INSIDE that directory - and the mission bridge artifacts (MISSION.<sid>.md, .mission-backups/)
# live at the canonical root beside it. Pointing this at a main tree therefore hands Codex write
# access to the bridge and to git's own state, which is exactly the thing the absolute half of the
# rule forbids. In a LINKED worktree the real gitdir is `<canonical-root>/.git/worktrees/<name>`,
# OUTSIDE the writable root, so the sandbox boundary does the enforcing rather than a promise.
# So: linked worktrees only, asserted, no override.
#
# Codex must not run git either. That is instructed in the prompt AND verified after the fact -
# HEAD, the branch, and the index must be unchanged - because an instruction alone is not a control.
#
# Usage: codex-build-chunk.sh <promptfile> <outfile> <worktree-dir>
#   Env: CODEX_EFFORT, CODEX_TIMEOUT_SECS  - same contract as codex-exec.sh.
#        CODEX_BUILD_CHUNK_CMD  - test seam ONLY: the command run in place of `codex`.
#
# Writes: <outfile> (model output), <outfile>.status  (ok | refused-<reason> | timeout |
#         unavailable | no-changes | nonzero-<rc>)
#
# Exit 0 ONLY when Codex ran, git state is untouched, the bridge is untouched, and the worktree
# actually changed. ZERO changed files is a FAILURE, not an ok - a silent no-op that reads as
# success is how a build step gets believed without having built anything.
#
# The output is NOT trusted work. Claude runs the tests on it before it counts for anything.

set -u
PROMPT="${1:?usage: codex-build-chunk.sh <promptfile> <outfile> <worktree-dir>}"
OUT="${2:?usage: codex-build-chunk.sh <promptfile> <outfile> <worktree-dir>}"
WT="${3:?usage: codex-build-chunk.sh <promptfile> <outfile> <worktree-dir> (a LINKED git worktree)}"

_status() { printf '%s\n' "$1" > "$OUT.status.tmp" 2>/dev/null && mv -f "$OUT.status.tmp" "$OUT.status" 2>/dev/null; }
_refuse() { echo "codex-build-chunk: REFUSED — $1" >&2; _status "refused-$2"; exit 3; }

[ -f "$PROMPT" ] || _refuse "prompt file not found: $PROMPT" "no-prompt"
[ -d "$WT" ]     || _refuse "worktree dir not found: $WT" "no-worktree"
case "$WT" in *..*) _refuse "worktree path contains '..'" "bad-path" ;; esac

WT_ABS=$(cd "$WT" 2>/dev/null && pwd -P) || _refuse "cannot resolve worktree path" "bad-path"

# ── ASSERTION 1: the passed dir IS the top of a git working tree (not a subdir of one) ──────────
TOP=$(cd "$WT_ABS" && git rev-parse --show-toplevel 2>/dev/null)
TOP=$(cd "$TOP" 2>/dev/null && pwd -P)
[ -n "$TOP" ] || _refuse "not inside a git working tree: $WT_ABS" "not-git"
[ "$TOP" = "$WT_ABS" ] || _refuse "not the TOP of its working tree (toplevel=$TOP) — a subdir would leave the rest of the tree writable and unaudited" "not-toplevel"

# ── ASSERTION 2: it is a LINKED worktree whose real gitdir sits OUTSIDE the writable root ───────
# This is the sandbox boundary doing the work. `git rev-parse --git-dir` in a linked worktree
# resolves to <canonical-root>/.git/worktrees/<name>; in a main tree it is <root>/.git.
GITDIR=$(cd "$WT_ABS" && git rev-parse --absolute-git-dir 2>/dev/null)
GITDIR=$(cd "$GITDIR" 2>/dev/null && pwd -P)
[ -n "$GITDIR" ] || _refuse "cannot resolve the git dir" "not-git"
case "$GITDIR/" in
  "$WT_ABS"/*) _refuse "the git dir ($GITDIR) is INSIDE the writable root — this is a MAIN working tree, so a workspace-write Codex could reach git state and the mission bridge. Use a LINKED worktree (git worktree add)." "main-worktree" ;;
esac

# ── ASSERTION 3: it is registered in `git worktree list` (not a hand-made lookalike) ────────────
if ! (cd "$WT_ABS" && git worktree list --porcelain 2>/dev/null | grep -qxF "worktree $WT_ABS"); then
  _refuse "$WT_ABS is not registered in 'git worktree list'" "unregistered-worktree"
fi

# ── ASSERTION 4: the worktree is CLEAN before we start ──────────────────────────────────────────
# A dirty start makes the before/after diff meaningless: pre-existing edits would be credited to
# Codex, and Codex's own no-op would read as a change.
BEFORE=$(cd "$WT_ABS" && git status --porcelain -z 2>/dev/null | tr '\0' '\n')
[ -z "$BEFORE" ] || _refuse "worktree is not clean — commit or stash first (a dirty start makes the before/after diff a lie)" "dirty-worktree"

HEAD_BEFORE=$(cd "$WT_ABS" && git rev-parse HEAD 2>/dev/null)
REF_BEFORE=$(cd "$WT_ABS" && git symbolic-ref -q HEAD 2>/dev/null)

command -v codex >/dev/null 2>&1 || [ -n "${CODEX_BUILD_CHUNK_CMD:-}" ] \
  || { echo "codex-build-chunk: codex CLI not on PATH" >&2; _status unavailable; exit 127; }

. "$HOME/.claude-dotfiles/scripts/lib/portable-timeout.sh"

EFFORT_ARGS=()
if [ -n "${CODEX_EFFORT:-}" ]; then
  case "$CODEX_EFFORT" in
    low|medium)     EFFORT_ARGS=(-c "model_reasoning_effort=xhigh") ;;
    high|xhigh|max) EFFORT_ARGS=(-c "model_reasoning_effort=$CODEX_EFFORT") ;;
    *) echo "codex-build-chunk: ignoring unknown CODEX_EFFORT='$CODEX_EFFORT'" >&2 ;;
  esac
fi

# The no-git instruction rides WITH the prompt. It is belt; assertion 6 below is braces.
PREAMBLE=$(mktemp "${TMPDIR:-/tmp}/cbc-prompt.XXXXXX") || _refuse "cannot create temp prompt" "no-temp"
{
  printf 'HARD CONSTRAINTS for this task (these override anything below):\n'
  printf '1. EDIT FILES ONLY. Do NOT run git - no add, commit, checkout, stash, reset, branch, worktree.\n'
  printf '   Your changes are reviewed and committed by the caller. A git invocation FAILS this run.\n'
  printf '2. Stay inside %s. Do not write outside it.\n' "$WT_ABS"
  printf '3. Do not create or modify any MISSION.*.md file or anything under .mission-backups/.\n'
  printf '4. Make the change. Returning without editing any file FAILS this run.\n\n'
  cat "$PROMPT"
} > "$PREAMBLE"

TIMEOUT="${CODEX_TIMEOUT_SECS:-1800}"
CODEX_BIN="${CODEX_BUILD_CHUNK_CMD:-codex}"
pt_run "$TIMEOUT" "$CODEX_BIN" exec ${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"} \
  -s workspace-write --ephemeral -C "$WT_ABS" - < "$PREAMBLE" > "$OUT.tmp" 2>&1
rc=$?
mv -f "$OUT.tmp" "$OUT" 2>/dev/null
rm -f "$PREAMBLE" 2>/dev/null

case "$rc" in
  0)   : ;;
  124) _status timeout;     exit 124 ;;
  127) _status unavailable; exit 127 ;;
  *)   _status "nonzero-$rc"; exit "$rc" ;;
esac

# ── ASSERTION 5: the bridge was NOT touched (absolute half of the rule) ─────────────────────────
AFTER=$(cd "$WT_ABS" && git status --porcelain -z 2>/dev/null | tr '\0' '\n')
if printf '%s\n' "$AFTER" | grep -qE '(^|/)MISSION\.[^/]*\.md$|(^| )\.mission-backups/|(^|/)MISSION\.[^/]*\.log'; then
  echo "codex-build-chunk: REFUSED — Codex touched mission bridge artifacts. Revert this worktree before doing anything else." >&2
  _status refused-touched-bridge
  exit 4
fi

# ── ASSERTION 6: git state is untouched (Codex did not run git) ─────────────────────────────────
HEAD_AFTER=$(cd "$WT_ABS" && git rev-parse HEAD 2>/dev/null)
REF_AFTER=$(cd "$WT_ABS" && git symbolic-ref -q HEAD 2>/dev/null)
if [ "$HEAD_AFTER" != "$HEAD_BEFORE" ] || [ "$REF_AFTER" != "$REF_BEFORE" ]; then
  echo "codex-build-chunk: REFUSED — git state moved during the run (HEAD $HEAD_BEFORE -> $HEAD_AFTER, ref '$REF_BEFORE' -> '$REF_AFTER'). Codex must edit files only." >&2
  _status refused-git-moved
  exit 5
fi
if (cd "$WT_ABS" && git diff --cached --quiet 2>/dev/null); then :; else
  echo "codex-build-chunk: REFUSED — the index has staged changes; Codex ran 'git add'. Edit files only." >&2
  _status refused-git-moved
  exit 5
fi

# ── ASSERTION 7: something actually changed. Zero changes is a FAILURE, never an ok ─────────────
if [ -z "$AFTER" ]; then
  echo "codex-build-chunk: NO CHANGES — Codex returned without editing anything. This is a failure, not a success." >&2
  _status no-changes
  exit 6
fi

printf '%s\n' "$AFTER" > "$OUT.changed" 2>/dev/null
_status ok
echo "codex-build-chunk: ok — $(printf '%s\n' "$AFTER" | grep -c .) changed path(s); see $OUT.changed. NOT verified: run the tests before this counts." >&2
exit 0
