#!/bin/bash
# lint-skill-contract.sh - fail-closed contract-survival lint for the restructured
# skill files. Inventories captured 2026-08-01 PRE-restructure; any edit that drops
# a required literal fails here, converting "the slim kept every check" from a
# one-shot /tmp diff into a durable, re-runnable guard.
#
# Covers mission.md, post-compact-resume.md, pre-compact.md (2026-08-01 restructure)
# and codex-review.md, implement.md, plan.md (2026-08-02 parallelizer v1: the
# same-message launch registers and the mode/timeout contracts they depend on).
#
# Modes:
#   --staged   check only files in the git staged set (pre-commit use)
#   --all      check every rule unconditionally (phase-gate / CI use; default)
#
# bash 3.2 compatible. Exit 1 on any contract violation, 2 on a bad argument.

set -u

# ROOT SPLIT (2026-08-02) - two different questions, two different answers:
#   ROOT     WHERE THE FILES LIVE. Derived from this script's own location, so a copy of
#            the tree (a linked worktree, a hermetic test sandbox) lints ITS OWN
#            commands/ rather than always reaching back into $HOME.
#   GITROOT  WHICH INDEX the --staged query reads. Hooks run with cwd at the INVOKING
#            worktree root, and a main-tree `--cached` query cannot see a linked
#            worktree's index - it would report an empty staged set and skip everything.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
GITROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$ROOT")"

MODE="${1:-}"
case "$MODE" in
    ""|--all)  MODE="--all" ;;
    --staged)  ;;
    *) echo "lint-skill-contract: unknown argument: $MODE (expected --staged or --all)" >&2; exit 2 ;;
esac

# CONTENT AUTHORITY (2026-08-03, codex-review C1 fix): WHICH BYTES do the checks read?
#   --all     the WORKING TREE ($ROOT/<path>). The phase-gate/CI invocation judges the
#             files on disk; there is no index/worktree divergence to reconcile.
#   --staged  the STAGED BLOB (`git show :<path>` from $GITROOT) - the exact bytes this
#             commit will record. Reading the WORKTREE here was the bypass (C1): a file
#             staged broken, or `git rm --cached`'d, but left clean/present in the worktree
#             sailed past the gate while the COMMITTED content was broken/absent. Selecting
#             files from the index (staged_has) but reading their content from the worktree
#             is the exact index-vs-worktree seam an attacker (or an honest stage-then-edit)
#             slips through. resolve_content closes it by materializing the staged blob.
#
# A staged DELETION is the sharpest form of that bypass: `git show :<path>` fails, so
# resolve_content returns NOTHING, and every required-literal check below fails CLOSED on
# it - a deleted guarded command is exactly the thing the machine must refuse to ship.
STAGED_TMP=""
_lint_cleanup() { [ -n "$STAGED_TMP" ] && rm -rf "$STAGED_TMP" 2>/dev/null; return 0; }
trap _lint_cleanup EXIT

# resolve_content <repo-relative-path> -> prints an absolute path whose bytes are the
# content to check for the active mode, or prints NOTHING when that content does not exist
# (worktree file absent in --all; staged deletion / unreadable blob in --staged). Memoized
# per path via the temp dir so repeated req/absent/req_before calls materialize once.
resolve_content() {
    local path="$1" out
    if [ "$MODE" != "--staged" ]; then
        [ -f "$ROOT/$path" ] && printf '%s\n' "$ROOT/$path"
        return 0
    fi
    [ -n "$STAGED_TMP" ] || STAGED_TMP="$(mktemp -d "${TMPDIR:-/tmp}/lint-staged-XXXXXX")" || return 0
    out="$STAGED_TMP/$path"
    if [ ! -f "$out" ]; then
        mkdir -p "$(dirname "$out")" 2>/dev/null || return 0
        # git show writes the staged blob; on a staged deletion (or any missing index
        # entry) it exits non-zero. Drop the truncated file so callers see "no content".
        if ! git -C "$GITROOT" show ":$path" > "$out" 2>/dev/null; then
            rm -f "$out" 2>/dev/null
            return 0
        fi
    fi
    printf '%s\n' "$out"
}

fail=0

# In --staged mode, a file outside the staged set is not this commit's business.
staged_has() { # staged_has <repo-relative-path>
    [ "$MODE" != "--staged" ] && return 0
    git -C "$GITROOT" diff --cached --name-only 2>/dev/null | grep -qxF -- "$1"
}

# NOTE: grep -cF counts matching LINES, not occurrences. A min-count of N therefore means
# "N separate lines carry this literal" - verify that shape before raising a min.
req() { # req <file> <fixed-string> [min-count]
    local rel="$1" s="$2" min="${3:-1}" f n
    staged_has "$rel" || return 0
    f="$(resolve_content "$rel")"
    if [ -z "$f" ]; then
        echo "lint-skill-contract: FAIL $rel is missing/deleted in the checked tree (cannot prove required literal is present, need >=$min): $s" >&2
        fail=1; return 0
    fi
    n=$(grep -cF -- "$s" "$f" 2>/dev/null || true)
    if [ "${n:-0}" -lt "$min" ]; then
        echo "lint-skill-contract: FAIL $rel missing required literal (need >=$min, have ${n:-0}): $s" >&2
        fail=1
    fi
}

# A literal that must NOT survive. Swept wording re-grows by copy-paste from an older
# revision; req() cannot catch that, because the replacement text is present too.
absent() { # absent <file> <fixed-string>
    local rel="$1" s="$2" f hits
    staged_has "$rel" || return 0
    f="$(resolve_content "$rel")"
    if [ -z "$f" ]; then
        echo "lint-skill-contract: FAIL $rel is missing (cannot prove the banned literal is gone): $s" >&2
        fail=1; return 0
    fi
    hits=$(grep -nF -- "$s" "$f" || true)
    if [ -n "$hits" ]; then
        echo "lint-skill-contract: FAIL $rel still carries a banned literal: $s" >&2
        echo "$hits" >&2
        fail=1
    fi
}

# FIRST-occurrence character offset (chars, not bytes - mirrors lint-skill-size.sh's
# marker_pos, because the 20,000-char re-injection ceiling it guards is counted in chars).
# -1 when absent.
first_pos() { # first_pos <abs-file> <fixed-string>
    python3 -c "
import sys
s=open(sys.argv[1],encoding='utf-8').read()
print(s.find(sys.argv[2]))" "$1" "$2" 2>/dev/null || echo -1
}

# A literal that must sit ABOVE the contract-core marker - i.e. inside the first slice a
# post-compaction agent is re-injected with. Text below the marker is invisible to that
# agent, so a register that drifts below it is present in the file and absent in practice.
# FAILS CLOSED: a missing literal, a missing marker, or an unreadable file all fail.
req_before() { # req_before <file> <fixed-string>
    local rel="$1" s="$2" f p m
    staged_has "$rel" || return 0
    f="$(resolve_content "$rel")"
    if [ -z "$f" ]; then
        echo "lint-skill-contract: FAIL $rel is missing (cannot check contract-core position): $s" >&2
        fail=1; return 0
    fi
    p=$(first_pos "$f" "$s")
    m=$(first_pos "$f" "<!-- CONTRACT-CORE-END -->")
    if [ "${p:--1}" -lt 0 ]; then
        echo "lint-skill-contract: FAIL $rel missing required literal (contract-core position check): $s" >&2
        fail=1; return 0
    fi
    if [ "${m:--1}" -lt 0 ]; then
        echo "lint-skill-contract: FAIL $rel lacks the '<!-- CONTRACT-CORE-END -->' marker, so the contract-core position of this literal cannot be proven: $s" >&2
        fail=1; return 0
    fi
    if [ "$p" -ge "$m" ]; then
        echo "lint-skill-contract: FAIL $rel has a contract-core literal at char $p, BELOW the marker at char $m (a post-compaction agent never sees it): $s" >&2
        fail=1
    fi
}

M="commands/mission.md"
# The permission allowlist byte-matches this invocation prefix. Pre-edit the file
# carries 25 true invocation lines with the full literal prefix (9 further lines
# mention mission-write.sh in prose - those are fine without it).
req "$M" "bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh" 25
# tilde/$HOME variants of the invocation would MISS the allowlist byte-match and
# permission-prompt an autonomous run - forbid them outright.
if staged_has "$M"; then
    mf="$(resolve_content "$M")"
    if [ -z "$mf" ]; then
        echo "lint-skill-contract: FAIL $M is missing/deleted (cannot check mission-write.sh invocation shape)" >&2
        fail=1
    else
        bad=$(grep -nE '(~|\$HOME)/\.claude-dotfiles/scripts/hooks/mission-write\.sh' "$mf" || true)
        if [ -n "$bad" ]; then
            echo "lint-skill-contract: FAIL $M has ~/\$HOME mission-write.sh invocation variant(s) (allowlist requires the absolute literal path):" >&2
            echo "$bad" >&2
            fail=1
        fi
    fi
fi
for tok in "[mission] criticer" "[mission] FAIL" "[mission] live-verify" \
           "[mission] MISSION-CLEARED" "[mission] MISSION-REBASELINED" "[mission] MISSION-START" \
           "[mission] PART-DONE" "[mission] PART-RETIRED" "[mission] PART-START" \
           "[mission] SNAPSHOT" "[mission] test-trust" "[mission] VOID" \
           "panel-unavailable-3x"; do
    req "$M" "$tok"
done

P="commands/post-compact-resume.md"
for tok in "no-handoff" "arg-not-my-session" "self-unverifiable" "oversize" \
           "already-resumed" "multi-marker-detected" "handoff-mutated-mid-read" \
           "sid-known-hardlinked" "snapshot-failed" "invalid-handoff-name" \
           "invalid-session-arg" "no-session-arg"; do
    req "$P" "$tok"
done

C="commands/pre-compact.md"
for tok in "handoff_canonical_root" "ac_resolve_session_id" "_resolver_extract_marker_sid" \
           "writer_verify_marker_sid" "END-OF-HANDOFF" "CLAUDE_SESSION_ID" \
           "pre-compact-template.md" "Halt" "HALT_TRIPPED"; do
    req "$C" "$tok"
done
# All 24 step headings must survive (renumbering forbidden)
for h in "## Step 1:" "## Step 2:" "## Step 3:" "### Step 3.A:" "### Step 3.B:" \
         "### Step 3.C:" "### Step 3.D:" "### Step 3.E:" "### Step 3.F:" "### Step 3.G:" \
         "## Step 4:" "### Step 4.G:" "## Step 5:" "## Step 6:" "### Step 6A:" \
         "### Step 6B:" "### Step 6C:" "### Step 6D:" "## Step 7:" "## Step 8:" \
         "## Step 9:" "### Step 9.0:" "### Step 9.1:" "### Step 9.1.x:"; do
    req "$C" "$h"
done

# --------------------------------------------------------------------------------------
# parallelizer v1 (2026-08-02). These three files carry the launch REGISTERS - the
# sentences that make an agent spawn work in one message instead of one at a time - plus
# the mode and timeout contracts the registers depend on. Every failure they exist to
# prevent is silent: a dropped register does not error, it just serializes, and the loss
# is invisible in the transcript. So the literals are pinned here.

I="commands/implement.md"
# Two SEPARATE lines carry it (verified 2026-08-02): the bounded launch register in the
# contract core, and the wave-mode spawn step below the marker. grep -cF counts lines.
req "$I" "in a SINGLE message" 2
req "$I" "NO_REVIEW = true"
req "$I" "--no-review"
req "$I" "verify-parallel-wave"
req "$I" "merge-wave.sh"
req "$I" "chunk-id | phase"
# The register itself must survive INSIDE the re-injected contract core; the wave-mode
# occurrence below the marker is deliberately not position-gated (mid-wave compaction
# resume is out of scope).
req_before "$I" "in a SINGLE message"

X="commands/codex-review.md"
# Every lens invocation must carry the self-timeout: the collection step is a bounded wait
# on the .status sidecars, and a backgrounded pass that never writes one hangs the wait to
# its ceiling instead of degrading to "lens not usable".
req "$X" "CODEX_TIMEOUT_SECS=3600" 4
req "$X" "Codex-passes:"
req "$X" "Report-file:"
req "$X" "EXACTLY 6 tool calls"
req "$X" "EXACTLY 1 Agent call"
req "$X" "EXACTLY 3 Agent calls"
req "$X" "NON-CODE TARGETS ONLY"
# The counts and the non-code scoping are what an agent reads BEFORE it launches, and
# Step 4 is entered by both target classes - a count that drifts below the marker is a
# count nobody applies.
req_before "$X" "EXACTLY 6 tool calls"
req_before "$X" "EXACTLY 1 Agent call"
req_before "$X" "EXACTLY 3 Agent calls"
req_before "$X" "NON-CODE TARGETS ONLY"
# Swept wording: the old four-Bash schedule. It contradicts the six-call schedule that
# replaced it, and re-grows by copy-paste from an older revision.
absent "$X" "Spawn ALL FOUR Bash calls in a SINGLE message"

L="commands/plan.md"
# plan.md's register carries no EXACTLY-count (the third explorer is conditional), so the
# register sentence and the same-message literal ARE the contract.
req "$L" "CRITICAL - research is a parallel fan-out"
req "$L" "in a SINGLE message"

[ $fail -eq 0 ] && echo "lint-skill-contract: OK"
exit $fail
