#!/bin/bash
# lint-skill-contract.sh - fail-closed contract-survival lint for the three
# restructured skill files. Inventories captured 2026-08-01 PRE-restructure;
# any edit that drops a required literal fails here, converting "the slim kept
# every check" from a one-shot /tmp diff into a durable, re-runnable guard.
#
# bash 3.2 compatible. Exit 1 on any missing literal.

set -u
ROOT="$HOME/.claude-dotfiles"
fail=0

req() { # req <file> <fixed-string> [min-count]
    local f="$ROOT/$1" s="$2" min="${3:-1}" n
    n=$(grep -cF -- "$s" "$f" 2>/dev/null || true)
    if [ "${n:-0}" -lt "$min" ]; then
        echo "lint-skill-contract: FAIL $1 missing required literal (need >=$min, have ${n:-0}): $s" >&2
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
bad=$(grep -nE '(~|\$HOME)/\.claude-dotfiles/scripts/hooks/mission-write\.sh' "$ROOT/$M" || true)
if [ -n "$bad" ]; then
    echo "lint-skill-contract: FAIL $M has ~/\$HOME mission-write.sh invocation variant(s) (allowlist requires the absolute literal path):" >&2
    echo "$bad" >&2
    fail=1
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

[ $fail -eq 0 ] && echo "lint-skill-contract: OK"
exit $fail
