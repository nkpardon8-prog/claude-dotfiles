---
description: "Single-pass multi-model codebase review report. 3 Claude broad + 3 Codex broad + 23 principle agents (Claude+Codex per principle) in parallel. NO fixes applied — pure report. Use /god-review for autonomous fix-loop. Optional --rounds N for de-noising."
argument-hint: "[scope] [--rounds N] [--ruthless] [--principle <name>] [--online] [--codex-validation-every N]"
allowed-tools: Bash, Read, Grep, Glob, Task, TodoWrite
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

echo "/god-report: SCOPE=${SCOPE:-<full repo>} ROUNDS=$ROUNDS RUTHLESS=$RUTHLESS"
```

## Step 0.5: Single-Principle Delegation

If `$PRINCIPLE` is non-empty, delegate to that principle file and exit.

```
IF $PRINCIPLE is non-empty:
  Read the principle file content from:
    ~/.claude-dotfiles/commands/god-review/principles/<PRINCIPLE>.md
  Spawn ONE Agent tool call:
    subagent_type: "general-purpose"
    model: "claude-opus-4-7"
    prompt: [content of the principle file] + "\n\nScope: " + ($SCOPE if non-empty, else "full repo")
  After the agent returns, write its result to tmp/god-review/principles/<PRINCIPLE>-findings.md.
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

3. **If `$ROUNDS > 1`**, after Phase 2 completes, repeat Phase 0–2 `($ROUNDS - 1)`
   more times. Each round writes a separate `tmp/god-review/report-round-N.md`.
   At the end, merge all round reports into one `tmp/god-review/report.md`,
   union-deduplicating findings by hash (compute_finding_hash from
   `lib/env-helpers.sh`). Findings present in 2+ rounds get the
   `(consistent across rounds)` tag.

4. **After Phase 2** (or after the multi-round merge if `$ROUNDS > 1`), write
   the final `tmp/god-review/report.md` and print a summary:
   ```
   /god-report complete.
   Rounds run: $ROUNDS
   Total findings: <N>
   Report at: tmp/god-review/report.md
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
