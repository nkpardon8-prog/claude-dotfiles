---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Check for documentation standards violations
argument-hint: "[scope]"
---

# /god-review:principles:documentation — Documentation Standards

## The Principle

All major files, classes, and functionality must have documentation. Documentation helps both humans and AI agents understand code purpose, usage, and intent. The "why" matters more than the "what" — good inline comments explain reasoning, not mechanics.

**Key requirements:**
- File-level comments explaining purpose and responsibilities
- JSDoc/docstrings for complex functions, hooks, and classes
- Inline comments for non-obvious logic explaining the "why"
- TODOs with context (issue number or reason)

## Why This Matters

- Failure mode #8 (compaction amnesia): after context compressions, AI agents re-explore code they already understood — good documentation anchors intent across compressions
- Failure mode #6 (single-agent reasoning): undocumented code forces agents to infer intent, leading to wrong assumptions that propagate into wrong fixes
- Failure mode #7 (hallucination cascade): agents that can't read intent from code generate plausible-sounding but wrong documentation and docstrings
- Failure mode #22 (no pushback): agents cannot identify contradictions or ask clarifying questions if there is no expressed intent to contradict or clarify
- New developers (human and AI) understand code faster with documentation; maintenance cost drops

Reference: `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md` failure modes #6, #7, #8, #22

## Phase 1: Gather Context

- Read `tmp/god-review/context-package.md` if it exists; otherwise auto-generate minimal context
- Read repo `AGENTS.md` / `CLAUDE.md` if present — documentation standards may be declared there
- Get scope: `$ARGUMENTS` or full repo via `git diff main...HEAD --name-only` or full file list

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"
git rev-parse --abbrev-ref HEAD
git diff main...HEAD --name-only 2>/dev/null || find . -name "*.tsx" -o -name "*.ts" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.go" -o -name "*.rs" | grep -v node_modules | grep -v .git | head -200
# Get new files — these MUST have documentation
git diff main...HEAD --name-status 2>/dev/null | grep "^A" || true
git diff main...HEAD 2>/dev/null || true
```

Use TodoWrite to track files needing documentation review.

## Phase 2: Identify Candidates

### 2.1 File-Level Documentation

Every new file should have a top comment explaining its purpose:

```typescript
// CORRECT — file with purpose
/**
 * FeatureService handles all feature-related operations including
 * fetching, filtering, and updating feature items.
 */
export class FeatureService { ... }

// WRONG — no documentation on a new, non-trivial file
export class FeatureService { ... }
```

New files (git status `A`) with no file-level comment are automatic candidates.

### 2.2 Complex Function Documentation

Functions/methods with non-obvious behavior need JSDoc/docstrings:

```typescript
// CORRECT
/**
 * Calculates the optimal batch size for processing.
 *
 * Uses a heuristic based on available memory and input size
 * to prevent OOM errors while maximizing throughput.
 *
 * @param inputSize - Size of input in bytes
 * @param availableMemory - Available memory in bytes
 * @returns Optimal batch size (1-100)
 */
function calculateBatchSize(inputSize: number, availableMemory: number): number { ... }

// WRONG — complex logic without explanation
function calculateBatchSize(inputSize: number, availableMemory: number): number {
  return Math.min(100, Math.max(1, Math.floor(availableMemory / (inputSize * 1024))));
}
```

### 2.3 Inline Comments for Non-Obvious Logic

The rule: explain the "why", not the "what".

```typescript
// CORRECT — explains why
// Wait 150ms for final WebSocket message before completing to avoid race with transcript update
await new Promise(resolve => setTimeout(resolve, 150));

// Use ref to prevent rapid double-clicks from starting multiple sessions
if (processingRef.current) return;
processingRef.current = true;

// WRONG — states the obvious
// Set loading to true
setLoading(true);

// Call the API
const result = await api.fetch();
```

### 2.4 TODO Standards

TODOs must have context — bare `// TODO: fix this` is not actionable:

```typescript
// CORRECT
// TODO(#123): Add retry logic for transient network failures
// TODO(@username): Refactor after v2 API migration is complete

// WRONG
// TODO: fix this
// TODO: do something here
```

### 2.5 Hook and Component Documentation

```typescript
// CORRECT hook
/**
 * useFeature manages feature state and actions.
 *
 * Handles data fetching, user interactions, and error states.
 *
 * @param options.workspaceId - Workspace context for data scoping
 * @param options.onComplete - Called when the action completes
 *
 * @returns {Object} Feature controls and state
 */
export function useFeature(options: UseFeatureOptions): UseFeatureReturn { ... }
```

### 2.6 Check for Documentation Drift

Find cases where code was changed but related documentation was NOT updated:
- Function signature changed but JSDoc params still reflect old signature
- New parameters added but not documented
- Return type changed but docstring still describes old return

## Phase 3: Deep Analysis

For each candidate:
1. Read the full file — a single missing comment on a 5-line pure-function utility is different from zero documentation on a 200-line service
2. Consider the file type — test files and simple index/barrel files don't need file-level JSDoc
3. Distinguish "no documentation" from "minimal documentation that is actually sufficient" (a self-explanatory function named `getUserById` with a single db call needs no comment)

## Phase 4: Generate Report

Markdown table format:
| Location | Issue | Severity | Recommendation | Evidence |

Full report structure:

```markdown
# Documentation Standards Report

**Scope:** {scope or "full repo"}
**Status:** {PASS | WARN | FAIL}

## Summary

{One sentence assessment of documentation quality}

## Files Checked

- **New files:** {count}
- **Modified files:** {count}
- **Files needing documentation:** {count}

## Documentation Issues

### Critical (Must Fix)

| File | Issue | Severity |
|------|-------|----------|
| {file} | New file missing file-level documentation | definite |
| {file} | Complex function without JSDoc | likely |

### Warnings

| Location | Issue | Suggestion | Severity |
|----------|-------|------------|----------|
| {file:line} | {description} | {what to add} | investigate |

## New Files Missing Documentation

| File | Type | Required Documentation |
|------|------|------------------------|
| {file} | {service/hook/component/handler} | File-level JSDoc explaining purpose |

## Complex Code Lacking Comments

| Location | Complexity | Suggestion |
|----------|------------|------------|
| {file:line} | {what makes it complex} | {what to document} |

## Orphaned TODOs

| Location | Current | Should Be |
|----------|---------|-----------|
| {file:line} | `// TODO: fix` | `// TODO(#issue): description` |

## Documentation Drift

| Location | What Changed | Documentation Status |
|----------|-------------|---------------------|
| {file:line} | {signature change / new param} | {docstring not updated} |

## Recommendations

1. {specific action with file reference}
2. {specific action with file reference}
```

## Phase 5: Output

1. Save to `tmp/god-review/principles/documentation-findings.md`
2. Print PASS/WARN/FAIL summary with count of undocumented files and complex code without comments

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- PASS: All new files have file-level documentation; complex logic is explained; TODOs have context; no documentation drift on changed function signatures
- WARN: Some documentation gaps — major files covered but minor functions or hooks lack comments; orphaned TODOs present
- FAIL: New non-trivial files missing documentation; complex functions completely undocumented; systematic absence of "why" comments in non-obvious code

## What Requires Documentation

| File Type | Required | Optional |
|-----------|----------|----------|
| New service/repository | File-level JSDoc | Method-level JSDoc |
| New hook | File-level JSDoc with returns | Usage example |
| New component | File-level comment | Props JSDoc |
| Complex function (>20 lines of logic) | JSDoc with params/returns | - |
| Non-obvious inline logic | Inline "why" comment | - |
| TODO | Issue number or context | - |
| Simple utility (5-10 lines, self-explanatory) | None required | Brief comment |

## Known Issues (don't re-report)

Loaded from `tmp/god-review/context-package.md` known-issues section if present. Skip any finding already in `tmp/god-review/state.json` from prior rounds.

Run analysis on: $ARGUMENTS (or full repo if empty).
