---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git rev-parse:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Detect same fact stated differently in 2+ files — README vs code drift, same algorithm implemented twice with subtle differences, flag definitions that don't match across documentation sites, exit codes documented vs emitted
argument-hint: "[scope]"
---

# /god-review:principles:contradiction-detector — Contradiction Detection

**Tier 1. Always promoted. Findings promoted one confidence level before section assignment.**

## The Principle

When the same fact is stated in more than one place, the versions will drift. A README that says a flag does X while the code does Y is a contradiction. The same regex pattern appearing five times in five files with subtle variations is a contradiction. Exit codes documented as 3 but emitted as 4 are a contradiction. Hard-gate lists duplicated across three files that diverge silently are a contradiction. Contradictions erode trust, cause incorrect behavior when one source is updated without updating the others, and cause LLMs to pick the wrong version as canonical.

## Why This Matters

- When the same concept is defined in N places, LLM-assisted edits update only the one they happen to read, leaving the others stale
- README/code drift creates a false specification: developers (human and AI) follow the README and implement behavior the code doesn't actually have
- Exit code drift causes orchestrators and CI to misinterpret success/failure
- Hard-gate list drift causes some files to be incorrectly auto-modified in some contexts and protected in others, depending on which copy of the list was consulted
- Regex variation across N files means each site catches slightly different cases, creating inconsistent behavior across the codebase

Reference: failure mode #3 (specification drift), #11 (canonical-source fragmentation) in `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md`

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
    find "$WORKDIR" \( -name "*.md" -o -name "*.sh" -o -name "*.ts" -o -name "*.py" \) \
      ! -path "*/node_modules/*" ! -path "*/.git/*" | head -100
fi
```

Use TodoWrite to track each shared concept identified and the files that reference it.

## Phase 2: Identify Candidates

**This phase uses Claude-agent reasoning, NOT mechanical grep.** The agent reads the target files and identifies "shared concepts" — facts, values, patterns, or algorithms that appear in more than one file — then cross-references each for divergence. Mechanical grep on markdown produces false positives because documentation prose describing code triggers the same patterns as executable code.

Read all target files completely before beginning cross-referencing. Then reason through the following categories:

### 2.1 Flag / Option Definitions

Identify every CLI flag, argument, or option that appears anywhere in the scope (README, orchestrator code, help strings, docstrings, argparse declarations, usage blocks). Build a mental inventory: `{flag-name: [list of files where it appears with its described behavior]}`.

For each flag that appears in more than one file:
- Compare the description: does the README description match the actual parsed default? Does the help string match the argparse declaration?
- Compare the behavior documented vs the behavior implemented
- Flag any divergence as a contradiction candidate

Use Grep selectively when a flag name needs to be found across the wider codebase beyond the diff scope.

### 2.2 Exit Codes

Identify every exit code documented anywhere (README, docstrings, comments) and every exit code actually emitted in code (`exit N`, `sys.exit(N)`, `process.exit(N)`). Build an inventory: `{exit-code: {documented-meaning, emitted-at}}`.

For each exit code that is both documented and emitted:
- Does the documented meaning match where it is actually emitted?
- Are there exit codes documented but never emitted (documentation fiction)?
- Are there exit codes emitted but never documented (undocumented behavior)?

### 2.3 Regex / Pattern Definitions

Identify every regex pattern or glob pattern that appears in more than one file. Common examples: test-file detection patterns (*.test.ts, *_spec.rb), secret detection patterns, file extension lists.

For each pattern cluster:
- Compare them character-by-character: are they identical, or do they have subtle variations?
- If they vary: which is correct? Is one a superset of the other? Do they disagree on edge cases?
- Flag divergences as contradiction candidates

### 2.4 Hard-Gate / Protected-File Lists

Identify every list of files or paths that should be protected from auto-modification (hard gates, safety lists, excluded-from-fix patterns). These often appear in: README, orchestrator code, editor-agent prompts, CI config.

For each site where such a list appears:
- Compare the lists across sites
- Flag any entry present in one site but missing from another
- Flag any entry present in all sites but with different syntax (glob vs regex vs string match)

### 2.5 Algorithm / Implementation Duplicates

Read the code and identify cases where the same algorithm is implemented more than once. Examples: glob-to-regex conversion appearing in two places, JSON merge logic duplicated, argument parsing logic duplicated between an orchestrator and a subcommand.

For each suspected duplicate:
- Compare the implementations: are they semantically identical?
- If they differ: which is correct? Do they handle edge cases differently?
- Flag any behavioral divergence as a contradiction

### 2.6 Count / Quantity Claims

Identify any numeric claims in documentation ("19 principles", "8 broad reviewers", "exit code range 1-7"). Verify these against the actual codebase state. Flag where the documented count no longer matches reality.

## Phase 3: Deep Analysis

For each contradiction candidate:

1. Read both (or all N) sources carefully in full context — not just the contradicting line
2. Determine which version is correct: look for the most recently updated source, the one closest to actual execution, or the one declared as canonical in AGENTS.md/CLAUDE.md
3. Assess impact: is this contradiction currently causing wrong behavior, or is it latent (will cause wrong behavior next time someone reads the wrong source)?
4. Check if there is an authoritative single-source file that all others should reference — if so, the fix is to make others point at it rather than duplicating the definition

Apply confidence levels per CRITERIA.md:
- `definite`: two files state the same fact in contradictory terms with no ambiguity
- `likely`: two files state the same fact in ways that are almost certainly in conflict; requires reading both in full context to confirm
- `investigate`: potential contradiction that depends on interpretation; flag for human review

## Phase 4: Generate Report

Save findings to `$WORKDIR/tmp/god-review/principles/contradiction-detector-findings.md`:

```markdown
# Contradiction Detector Report

**Scope:** {scope}
**Status:** {PASS | WARN | FAIL}
**Risk Level:** {LOW | MEDIUM | HIGH | CRITICAL}

## Summary

{Overall assessment — how many contradictions, which categories, impact level}

## Findings

### Flag / Option Contradictions

| Flag | Source A | Source B | Divergence | Confidence |
|------|----------|----------|------------|------------|
| --flag | README:line says "..." | orchestrator:line does ... | description vs behavior | definite |

### Exit Code Contradictions

| Exit Code | Documented Meaning | Emitted At | Divergence | Confidence |
|-----------|--------------------|------------|------------|------------|

### Regex / Pattern Contradictions

| Pattern Purpose | File A Pattern | File B Pattern | Difference | Confidence |
|----------------|----------------|----------------|------------|------------|

### Hard-Gate List Contradictions

| Entry | Present In | Absent From | Impact | Confidence |
|-------|-----------|-------------|--------|------------|

### Algorithm / Implementation Contradictions

| Algorithm | Implementation A | Implementation B | Behavioral Difference | Confidence |
|-----------|-----------------|-----------------|----------------------|------------|

### Count / Quantity Contradictions

| Claim | Documented Value | Actual Value | File | Confidence |
|-------|-----------------|--------------|------|------------|

## False Positives Ruled Out

{List candidates checked and confirmed identical — demonstrates analysis was exhaustive}

## Recommended Canonical Sources

{For each contradiction: which source should be considered canonical and why}
```

## Phase 5: Output

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$WORKDIR/tmp/god-review/.env.sh" ] && source "$WORKDIR/tmp/god-review/.env.sh"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"

mkdir -p "$WORKDIR/tmp/god-review/principles"
echo "contradiction-detector: complete. Results in $WORKDIR/tmp/god-review/principles/contradiction-detector-findings.md"
```

Print PASS/WARN/FAIL summary with count of contradictions by category.

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; thresholds below are principle-specific.

- PASS: All shared concepts are consistent across all sites where they appear, or duplicates are intentional with a clear canonical-source pointer
- WARN: 1–2 documentation contradictions that don't affect runtime behavior; count claims that are off but not load-bearing
- FAIL: Any exit code documented differently from where it is emitted; any hard-gate list that disagrees across sites; any flag documented with different behavior than implemented; any algorithm implemented twice with behavioral divergence

## Risk Levels

- LOW: Documentation-only contradiction (prose describes old behavior); no runtime impact
- MEDIUM: Regex/pattern divergence in non-critical paths; hard-gate lists partially mismatched
- HIGH: Exit code documented incorrectly (orchestrators will misinterpret failure); algorithm implemented twice with different edge-case handling; flag behavior contradicts documentation
- CRITICAL: Hard-gate list missing a file in one site means that file gets auto-modified when it shouldn't be; contradiction actively causes wrong behavior in the current execution path

## Known Issues (don't re-report)

Loaded from `$WORKDIR/tmp/god-review/context-package.md` known-issues section if present. Skip any contradiction already flagged in prior rounds per `$WORKDIR/tmp/god-review/state.json`.

Run analysis on: $ARGUMENTS (or full repo if empty).
