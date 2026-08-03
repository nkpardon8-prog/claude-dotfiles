---
description: "Single-pass multi-model codebase review report. 4 Claude broad + 6 Codex broad + 24 principle agents (Claude+Codex per principle) in parallel. NO fixes applied — pure report. Use /god-review for autonomous fix-loop. Optional --rounds N for de-noising."
argument-hint: "[scope] [--rounds N] [--ruthless] [--principle <name>] [--online] [--codex-validation-every N]"
allowed-tools: Bash, Read, Grep, Glob, Task, Agent, TodoWrite
expected_subagents: 34
---

# /god-report — Single-Pass Codebase Audit (Report Only)

You are conducting a one-shot codebase review. **No fixes are applied.** The
output is `tmp/god-review/report.md` for the user to read and act on themselves.
For autonomous fix-and-loop behavior, use `/god-review` instead.

## How this differs from /god-review

- **No Phase 3.** No fix loop, no Architect, no Editor, no commits.
- **Optional `--rounds N`** runs the full Phase 0–2 pipeline N times
  independently and aggregates the union of findings (de-noises single-agent
  flukes). Default `N=1`.
- Hard gates are still flagged but never enforced — no auto-apply happens
  regardless of severity.

## Step 0: Argument Parsing + Validation

```bash
set -o pipefail
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"

# Defaults
SCOPE=""; ROUNDS=1; ONLINE=false; RUTHLESS=false; PRINCIPLE=""
CODEX_VALIDATION_EVERY=3

eval set -- $ARGUMENTS
while [ $# -gt 0 ]; do
  case "$1" in
    --online)   ONLINE=true; shift ;;
    --ruthless) RUTHLESS=true; shift ;;
    --rounds)
      [ "$2" -ge 1 ] 2>/dev/null || { echo "Error: --rounds must be an integer >= 1 (got: ${2:-missing})" >&2; exit 1; }
      ROUNDS="$2"; shift 2 ;;
    --principle)
      [ -f "$HOME/.claude-dotfiles/commands/god-review/principles/${2}.md" ] || { echo "Error: unknown principle '${2:-missing}'" >&2; exit 1; }
      PRINCIPLE="$2"; shift 2 ;;
    --codex-validation-every)
      [ "$2" -ge 1 ] 2>/dev/null || { echo "Error: --codex-validation-every must be an integer >= 1" >&2; exit 1; }
      CODEX_VALIDATION_EVERY="$2"; shift 2 ;;
    --*) echo "Error: unknown flag $1 (note: /god-report has no fix-mode flags; use /god-review for that)" >&2; exit 1 ;;
    *) [ -z "$SCOPE" ] && SCOPE="$1" || { echo "Error: extra positional argument '$1'" >&2; exit 1; }
       shift ;;
  esac
done

# Export tunables for codex-invoke.sh subprocess (matches /god-review pattern)
export SPINLOCK_TIMEOUT_SEC="${SPINLOCK_TIMEOUT_SEC:-600}"
export LATE_IMPORT_LINE="${LATE_IMPORT_LINE:-40}"

# Multi-round aggregation mode for Phase 2e STEP 5. With --rounds N (N > 1) the
# per-round reports are union-deduplicated into report.md; with a single round
# report.md is just that round's report.
ROUND=1
GOD_REVIEW_MERGE_ROUNDS=false
[ "$ROUNDS" -gt 1 ] && GOD_REVIEW_MERGE_ROUNDS=true

# PERSIST THE PARSE. Every later bash block is a FRESH shell that rebuilds state
# by sourcing tmp/god-review/.env.sh. Without this, RUTHLESS / ONLINE /
# CODEX_VALIDATION_EVERY / SCOPE / ROUND / GOD_REVIEW_MERGE_ROUNDS all read empty
# in the delegated Phase 0-2 blocks and their gates silently no-op.
write_env

# A previous invocation's per-round reports would be unioned into this run's
# report.md by STEP 5. Clear them; /god-report has no --resume.
rm -f "$WORKDIR/tmp/god-review/report-round-"*.md 2>/dev/null

echo "/god-report: SCOPE=${SCOPE:-<full repo>} ROUNDS=$ROUNDS RUTHLESS=$RUTHLESS ONLINE=$ONLINE CODEX_VALIDATION_EVERY=$CODEX_VALIDATION_EVERY MERGE_ROUNDS=$GOD_REVIEW_MERGE_ROUNDS"
```

## Step 0.5: Single-Principle Delegation

If `$PRINCIPLE` is non-empty, delegate to that principle file and exit.

```
IF $PRINCIPLE is non-empty:
  Read the principle file content from:
    ~/.claude-dotfiles/commands/god-review/principles/<PRINCIPLE>.md
  Spawn ONE Agent tool call:
    subagent_type: "general-purpose"
    model: "opus"
    prompt: [content of the principle file] + "\n\nScope: " + ($SCOPE if non-empty, else "full repo")
  After the agent returns, persist its result with the shared helper:
    source ~/.claude-dotfiles/commands/god-review/lib/env-helpers.sh
    write_agent_finding "claude-principle-<PRINCIPLE>" "<result text>"
  which writes tmp/god-review/findings/claude-principle-<PRINCIPLE>.txt - the one
  output path the whole pipeline reads (write_agent_finding keeps the agent's own
  richer self-written report if it already created that file).
  Exit.
```

Do not proceed to Phase 0 when `--principle` is set.

## Phases 0, 1, 2 — Mirrored from /god-review

**The mechanics for Phase 0 (Context Map), Phase 1 (Probe + Snapshot), and
Phase 2 (Parallel Review + Validation + Aggregation) are IDENTICAL to those
in `/god-review`.** To execute them:

1. **Read the spec.** Open `~/.claude-dotfiles/commands/god-review.md` and
   execute exactly the contents of:
   - `## Phase 0: Context Map`
   - `## Phase 1: Probe`
   - `## Phase 2: Review (the heart)`
   These sections are the canonical specification. Both `/god-review` and
   `/god-report` execute them identically.

2. **Skip Phase 3.** When you reach `## Phase 3: Fix Loop` in god-review.md,
   STOP. Do not enter Phase 3. Phase 3 is /god-review's domain only.

3. **If `$ROUNDS > 1`**, repeat Phase 0–2 `($ROUNDS - 1)` more times. The
   per-round artifact and the union are already mechanized in Phase 2e STEP 4 +
   STEP 5 - you do not hand-roll the merge. Between rounds, bump `$ROUND` so
   STEP 4 writes to a fresh file:

   ```bash
   WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
   [ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
   ROUND=$(( ${ROUND:-1} + 1 ))
   write_env
   echo "Starting /god-report round $ROUND of $ROUNDS"
   ```

   Because Step 0 set `GOD_REVIEW_MERGE_ROUNDS=true` for `$ROUNDS > 1`, STEP 5's
   `merge-round-reports.sh` call at the end of every round rebuilds
   `tmp/god-review/report.md` as the union of every `report-round-*.md` written
   so far, deduplicated by `compute_finding_hash(file, line_range/5, category)`,
   tagging anything seen in 2+ rounds `(consistent across rounds)`. Re-running it
   each round is idempotent, so `report.md` is always valid mid-run.

   Note: `/god-review`'s Phase 3 stale-file cleanup does not run here (no Phase 3),
   so before each extra round clear the reviewer outputs yourself, or the previous
   round's files will be re-consolidated as if they were fresh:

   ```bash
   rm -f "$WORKDIR/tmp/god-review/findings/"claude-*.txt "$WORKDIR/tmp/god-review/findings/"codex-*.txt 2>/dev/null
   rm -f /tmp/codex-principle-*.txt /tmp/codex-broad-*.txt 2>/dev/null
   ```

4. **After the final round**, verify the artifacts exist and print the summary:

   ```bash
   WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
   [ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
   echo "/god-report complete."
   echo "Rounds run: ${ROUNDS:-1}"
   echo "Per-round reports: $(ls "$WORKDIR/tmp/god-review"/report-round-*.md 2>/dev/null | wc -l | tr -d ' ')"
   echo "Total findings: $(grep -c '^### ' "$WORKDIR/tmp/god-review/report.md" 2>/dev/null || echo 0)"
   echo "Report at: $WORKDIR/tmp/god-review/report.md"
   ```

   Then exit.

## Why this command is split from /god-review

The two operational shapes are too different to share one entry point:

- `/god-report` is fast and bounded (one Phase 0–2 pass, ~15-30 minutes).
  Read the report, decide what to do.
- `/god-review` is slow and indefinite (rounds until 3 consecutive clean,
  potentially hours). Walk away, come back to a clean codebase + a batch of
  HUMAN_GATE items.

Different invocation patterns, different cost expectations, different mental
models. Same backbone (`commands/god-review/{lib,principles,broad-reviewers}/`)
to avoid drift.

## Drift Check (advisory)

After any edit to `god-review.md` Phase 0/1/2, run:
```bash
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/env-helpers.sh"
check_phase_drift
```
This compares Phase 0–2 sections between `god-review.md` and `god-report.md`
and warns on drift. Phase 0/1/2 specs in this file are **delegated** (we read
god-review.md), so drift between the two is currently impossible — but the
helper is in place if a future refactor inlines either side.
