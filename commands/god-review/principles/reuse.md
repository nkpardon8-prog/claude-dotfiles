---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Check for violations of the Reuse Over Recreation principle
argument-hint: "[scope]"
---

# /god-review:principles:reuse — Reuse Over Recreation

## The Principle

Minimize lines of code. Reuse existing patterns. Avoid duplicating functionality. The key question is: "Did we implement this with the least amount of lines by leveraging what already exists?"

## Why This Matters

- Failure mode #14 (overcomplication/bloat): writing 1000 lines when 100 would do by reusing existing code
- Failure mode #7 (hallucination cascade): agent creates new utilities without checking what already exists, downstream agents treat duplicates as canonical
- More code = larger maintenance surface area
- Duplicate implementations diverge over time — one gets fixed, the other doesn't
- Reduces onboarding difficulty and cognitive load for future reviewers

Reference: `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md` failure modes #7, #14

## Phase 1: Gather Context

- Read `tmp/god-review/context-package.md` if it exists; otherwise auto-generate minimal context
- Read repo `AGENTS.md` / `CLAUDE.md` if present — shared directories and canonical utilities are often declared there
- Get scope: `$ARGUMENTS` or full repo via `git diff main...HEAD --name-only` or full file list

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"
git rev-parse --abbrev-ref HEAD
git diff main...HEAD --name-only 2>/dev/null || find . -name "*.tsx" -o -name "*.ts" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.go" -o -name "*.rs" | grep -v node_modules | grep -v .git | head -200
git diff main...HEAD 2>/dev/null || true
```

Use TodoWrite to track files to analyze.

## Phase 2: Identify Candidates

For each new function, hook, component, or utility in scope:

### 2.1 Search for Similar Implementations

1. Extract the function/hook/component name and key terms from implementation
2. Grep for similar names across the codebase
3. Grep for similar functionality (key terms, patterns, algorithm structure)
4. Check these locations specifically (detect actual paths from project structure or AGENTS.md/CLAUDE.md):
   - The project's shared utilities directory (e.g., `libs/shared/`, `packages/shared/`, `src/shared/`, `internal/shared/`, `pkg/`)
   - The codebase's hooks directory
   - The codebase's components directory
   - The codebase's backend shared utilities directory

### 2.2 Check for Copy-Paste

1. Look for blocks of code >10 lines that appear elsewhere verbatim or near-verbatim
2. Search for distinctive string literals or patterns from the new code
3. Flag any near-identical implementations — even if renamed

### 2.3 Evaluate Abstractions

For each new abstraction (class, hook, utility, module):
- Could an existing abstraction be extended instead?
- Is this solving a problem already solved elsewhere?
- Could this live in the project's shared directory for reuse? (Detect from project structure or AGENTS.md)
- Is the new code 3x longer than it would be if it extended existing code?

## Phase 3: Deep Analysis

For each candidate:
1. Read the candidate and the potential duplicate
2. Assess functional overlap — does the new code handle a subset/superset/identical behavior?
3. Determine if the existing code is actually reusable for this use case (don't force reuse when specialization is genuinely warranted)
4. Assess whether the new code should be added to the shared directory instead of remaining local

## Phase 4: Generate Report

Markdown table format:
| Location | Issue | Severity | Recommendation | Evidence |

Full report structure:

```markdown
# Reuse Over Recreation Report

**Scope:** {scope or "full repo"}
**Status:** {PASS | WARN | FAIL}

## Summary

{One sentence assessment}

## Violations Found

### Critical (Must Fix)

| Location | Issue | Existing Alternative | Severity |
|----------|-------|---------------------|----------|
| {file:line} | {description} | {what to use instead} | definite/likely |

### Warnings

| Location | Issue | Recommendation | Severity |
|----------|-------|----------------|----------|
| {file:line} | {description} | {suggestion} | investigate |

## Existing Patterns That Should Be Used

1. **{pattern name}** at `{path}`
   - What it does: {description}
   - Should be used for: {use case from this review}

## Code That Could Be Shared

{List any new code that should move to the project's shared directory rather than remain local}

## Recommendations

1. {specific action}
2. {specific action}
```

## Phase 5: Output

1. Save to `tmp/god-review/principles/reuse-findings.md`
2. Print PASS/WARN/FAIL summary with count of violations

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- PASS: No new code duplicates existing functionality; all shared utilities are used when applicable
- WARN: Minor duplication or missed opportunity for reuse — functional overlap is partial or the existing pattern would require non-trivial adaptation
- FAIL: Significant duplication detected, or new code reimplements patterns that exist and would work directly

## Known Issues (don't re-report)

Loaded from `tmp/god-review/context-package.md` known-issues section if present. Skip any finding already in `tmp/god-review/state.json` from prior rounds.

Run analysis on: $ARGUMENTS (or full repo if empty).
