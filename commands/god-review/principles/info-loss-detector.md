---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git rev-parse:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Detect scope-crossing data that doesn't propagate — cross-block bash vars, subagent outputs the orchestrator can't read back, findings produced but not aggregated, state fields initialized then overwritten without merging
argument-hint: "[scope]"
---

# /god-review:principles:info-loss-detector — Information Loss Across Boundaries

**Tier 1. Always promoted. Findings promoted one confidence level before section assignment.**

## The Principle

Data produced in one scope must have a verified propagation path to every scope that expects it. When a variable is set in one bash fence and the next fence never sources it, information is silently lost. When a subagent writes findings to stdout but the orchestrator never captures that stdout, the findings are gone. When state.json is initialized and then overwritten without merging, prior state is destroyed. These are not crashes — they are silent correctness failures that produce misleading output while appearing to succeed.

## Why This Matters

- Cross-block bash variable loss is the most common orchestrator failure mode: each bash fence in a Claude slash command is a separate shell invocation. Variables assigned in block N are gone in block N+1 unless persisted to a file and sourced.
- Subagent output loss means review findings are silently dropped: if a principle agent writes results only to stdout and the orchestrator never captures stdout, the entire principle's work is wasted.
- State field overwrite-without-merge means multi-round reviews lose intermediate findings: a second write of `state.json["round"]` that doesn't merge with existing fields destroys everything else in state.json.
- Aggregation gaps mean the final report is incomplete: findings produced by one agent that are never included in the final report = findings that don't exist from the user's perspective.

Reference: failure mode #1 (silent data loss), #10 (scope boundary bugs) in `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md`

## Phase 1: Gather Context

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$WORKDIR/tmp/god-review/.env.sh" ] && source "$WORKDIR/tmp/god-review/.env.sh"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"
```

- Read `$WORKDIR/tmp/god-review/context-package.md` if it exists; otherwise use context gathered above
- Get scope: `$ARGUMENTS` if provided, otherwise full changed-file list

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$WORKDIR/tmp/god-review/.env.sh" ] && source "$WORKDIR/tmp/god-review/.env.sh"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"

if [ -n "$ARGUMENTS" ]; then
  echo "Scope: $ARGUMENTS"
else
  git -C "$WORKDIR" diff main...HEAD --name-only 2>/dev/null | head -100 || \
    find "$WORKDIR" \( -name "*.md" -o -name "*.sh" \) \
      ! -path "*/node_modules/*" ! -path "*/.git/*" | head -100
fi
```

Use TodoWrite to track each scope boundary identified and each data flow to verify.

## Phase 2: Identify Candidates

**This phase uses Claude-agent reasoning, NOT mechanical grep.** The agent reads the target files and traces data across scope boundaries. Fixed regex patterns on markdown produce massive false positives — prose describing code triggers the same patterns as actual code.

Read each target file completely. Then reason through each of the following boundary types:

### 2.1 Bash Fence Boundaries

In slash-command markdown files (`.md` files containing fenced bash blocks), each ` ```bash ` block is a separate shell invocation. Identify every bash fence boundary by reading the file top-to-bottom.

For each fence:
- What variables does it assign?
- Does it write those variables to a persistence file (`.env.sh`, `state.json`, a temp file) before the fence closes?
- Does the NEXT bash fence source that persistence file at its very first lines before using any of those variables?

Flag as info-loss candidate: any variable assigned in fence N that is referenced in fence N+1 without a visible source/read of the persistence store.

Verify the persistence mechanism is correct: a `cat > .env.sh` that uses unquoted variables will expand at write time (correct). A sourced file that references `$VAR` without quoting may lose the value if it contains spaces. Note these as secondary issues.

### 2.2 Subagent Invocation Boundaries

Identify every place a subagent is spawned (subagent_type blocks, Agent tool calls, delegated Claude invocations). For each:
- Does the subagent's prompt instruct it to write output to a specific file path?
- Does the orchestrator, after the subagent returns, read from that file path?
- If the subagent is expected to write stdout and the orchestrator captures it — is there actually a capture mechanism (e.g., output stored to variable, piped, redirected)?

Flag as info-loss candidate: any subagent spawn where the output path is unspecified, or where the orchestrator never reads the specified path.

### 2.3 Aggregation Gaps

Identify every per-agent or per-principle output file (findings/*.txt, principles/*-findings.md). For each:
- Is there an aggregation step that reads these files and incorporates them into the final report?
- Does the aggregation step reference each output file by the exact path the agent was instructed to write to?

Flag as info-loss candidate: any findings file that is written but never incorporated into the final report.

### 2.4 State Field Overwrite Without Merge

Identify every write to a shared state store (state.json, .env.sh, config objects). For each write:
- Is the write a full replacement (truncating the file, assigning the whole object) or a merge (reading first, updating specific keys, writing back)?
- If it is a full replacement: does it first read and re-include all existing fields?
- If it is a merge: does it use a safe merge pattern (read → update specific key → write) or an unsafe one (construct from scratch with only currently-known fields)?

Flag as info-loss candidate: any state store write that does not preserve fields written by previous phases.

### 2.5 Return Value Discard

Identify every function call or command invocation whose return value carries meaningful data. For each:
- Is the return value / exit code / stdout captured?
- If a command fails and its exit code is unchecked, do subsequent lines assume it succeeded?

Flag as info-loss candidate: commands whose output is needed but not captured; commands whose failure is undetected.

## Phase 3: Deep Analysis

For each candidate:

1. Trace the full lifecycle of the data: produced at X, expected at Y — what is the path between X and Y?
2. Look for the bridging mechanism: is there a `source`, a file read, a JSON merge, an aggregation loop?
3. If the bridging mechanism exists but is conditional, verify the condition covers all paths where the data is needed
4. Check for off-by-one in multi-round systems: does round N's state get persisted before round N+1 starts? Does it get read at the start of round N+1 before any operations that depend on it?

Apply confidence levels per CRITERIA.md:
- `definite`: no persistence mechanism exists; data cannot possibly cross the boundary
- `likely`: persistence mechanism exists but is incomplete (missing fields, wrong path, conditional with gaps)
- `investigate`: persistence mechanism looks correct but the path is complex enough to warrant manual verification

## Phase 4: Generate Report

Save findings to `$WORKDIR/tmp/god-review/principles/info-loss-detector-findings.md`:

```markdown
# Info-Loss Detector Report

**Scope:** {scope}
**Status:** {PASS | WARN | FAIL}
**Risk Level:** {LOW | MEDIUM | HIGH | CRITICAL}

## Summary

{Overall assessment of data propagation integrity}

## Findings

### Bash Fence Boundary Losses

| Fence Location | Variable | Set In Block | Read In Block | Persistence Mechanism | Gap |
|----------------|----------|-------------|---------------|-----------------------|-----|
| file:line | $VAR | block N (line X) | block N+1 (line Y) | none / incomplete | description |

### Subagent Output Losses

| Subagent Spawn | Expected Output | Capture Mechanism | Gap |
|----------------|----------------|-------------------|-----|
| file:line | findings file / stdout | none found | description |

### Aggregation Gaps

| Findings File | Written By | Read By Aggregator? | Gap |
|---------------|-----------|---------------------|-----|

### State Overwrite Without Merge

| Store | Write Location | Merge Pattern | Fields Lost |
|-------|---------------|---------------|-------------|

### Return Value Discards

| Location | Command | Return Value Used? | Impact |
|----------|---------|-------------------|--------|

## False Positives Ruled Out

{List candidates checked and ruled out — demonstrates analysis was exhaustive}
```

## Phase 5: Output

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$WORKDIR/tmp/god-review/.env.sh" ] && source "$WORKDIR/tmp/god-review/.env.sh"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"

mkdir -p "$WORKDIR/tmp/god-review/principles"
echo "info-loss-detector: complete. Results in $WORKDIR/tmp/god-review/principles/info-loss-detector-findings.md"
```

Print PASS/WARN/FAIL summary with count of info-loss findings by boundary type.

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; thresholds below are principle-specific.

- PASS: All scope-crossing data has verified persistence mechanisms; all subagent outputs are captured; state writes are merge-safe
- WARN: 1–2 bash-fence variable losses in non-critical paths; subagent output captured but path is fragile
- FAIL: Any subagent output with no capture mechanism; any bash fence that loses a cross-phase variable in the critical path; any state.json full-replacement write that destroys prior round data

## Risk Levels

- LOW: Variable loss in a non-critical informational path; no behavioral impact
- MEDIUM: Variable loss in a conditional branch that controls feature activation; subagent output partially captured
- HIGH: Cross-phase variable death at a bash fence boundary in the critical path; aggregation gap that omits one principle's findings from the final report
- CRITICAL: Subagent spawned with no output capture (entire agent's work silently discarded); state.json overwritten without merge in a multi-round loop (all prior findings lost each round)

## Known Issues (don't re-report)

Loaded from `$WORKDIR/tmp/god-review/context-package.md` known-issues section if present. Skip any info-loss already flagged in prior rounds per `$WORKDIR/tmp/god-review/state.json`.

Run analysis on: $ARGUMENTS (or full repo if empty).
