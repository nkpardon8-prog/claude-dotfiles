---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Check for violations of the Clarity and Readability principle
argument-hint: "[scope]"
---

# /god-review:principles:clarity — Clarity & Readability

## The Principle

Code should be easy to understand. Good code feels clean. The standard: if a junior developer would have to re-read a block more than once to understand it, that is a clarity failure — but often the code is the problem, not the developer.

Thresholds (principle-specific):
- **Function length** — Warning: >50 lines; Critical: >100 lines; Severe: >200 lines
- **Nesting depth** — Warning: >3 levels; Critical: >4 levels

## Why This Matters

- Failure mode #14 (overcomplication/bloat): dense, nested, over-engineered code that makes future edits dangerous
- Failure mode #6 (single-agent reasoning): agents reviewing unclear code make wrong assumptions about behavior, producing hallucinated fixes
- Failure mode #8 (compaction amnesia): dense code loses meaning across context compressions — agents re-explore the same misunderstanding repeatedly
- Unclear code is a forcing function for more unclear code: the next change adds another layer rather than refactoring

Reference: `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md` failure modes #6, #8, #14

## Phase 1: Gather Context

- Read `tmp/god-review/context-package.md` if it exists; otherwise auto-generate minimal context
- Read repo `AGENTS.md` / `CLAUDE.md` if present — coding style standards may be declared there
- Get scope: `$ARGUMENTS` or full repo via `git diff main...HEAD --name-only` or full file list

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"
git rev-parse --abbrev-ref HEAD
git diff main...HEAD --name-only 2>/dev/null || find . -name "*.tsx" -o -name "*.ts" -o -name "*.jsx" -o -name "*.js" -o -name "*.py" -o -name "*.go" -o -name "*.rs" | grep -v node_modules | grep -v .git | head -200
git diff main...HEAD 2>/dev/null || true
```

Use TodoWrite to track files to analyze.

## Phase 2: Identify Candidates

Read each file in scope fully and check for:

### 2.1 Function Length

- **Warning**: Functions over 50 lines
- **Critical**: Functions over 100 lines
- **Severe**: Functions over 200 lines

For long functions, note:
- Could this be broken into smaller, named functions?
- Are there distinct logical sections that deserve their own name?
- Would a helper with a descriptive name make the intent clearer?

### 2.2 Nesting Depth

- **Warning**: Conditionals nested >3 levels deep
- **Critical**: Conditionals nested >4 levels deep

Look for:
- Nested if/else chains
- Nested ternaries
- Callbacks within callbacks within callbacks
- Loop bodies containing multiple levels of conditional logic

### 2.3 Naming Quality

Flag unclear names:
- Single-letter variables (except conventional loop indices `i`, `j`, `k`, `n`)
- Abbreviations that are not obvious (`usr`, `cnt`, `tmp`, `val`, `res`)
- Generic names that convey no domain meaning (`data`, `info`, `stuff`, `obj`, `thing`)
- Misleading names where the name doesn't match the behavior

### 2.4 Magic Values

Find hardcoded values without explanation:
- Magic numbers: `if (count > 42)`, `timeout(5000)`, `slice(0, 20)`
- Magic strings: `if (status === 'xyz')`, `role === 'admin'` without a constant
- Unexplained timeouts or delays
- Arbitrary limits without comments explaining their rationale

### 2.5 Complex Logic

Identify code that is hard to follow:
- Complex boolean expressions without explaining variable names or comments
- Multiple mutations on a single line
- Implicit type coercion
- Unclear data transformations with no intermediate named variables
- Operator precedence reliance without parentheses

### 2.6 Hot Spots

Use judgment to identify code that "feels wrong":
- Dense blocks that are hard to scan visually
- Inconsistent formatting or indentation
- Mixed abstraction levels within a single function (low-level file I/O next to high-level business logic)
- Code that makes you re-read it multiple times to understand control flow

## Phase 3: Deep Analysis

For each candidate:
1. Verify the length/depth count precisely (line numbers)
2. Assess whether refactoring would genuinely improve comprehension vs. being purely cosmetic
3. Consider whether the language/paradigm makes this pattern acceptable (e.g., functional chains in Haskell, method chaining in builders)
4. Check AGENTS.md/CLAUDE.md for any declared style standards before flagging conventions

## Phase 4: Generate Report

Markdown table format:
| Location | Issue | Severity | Recommendation | Evidence |

Full report structure:

```markdown
# Clarity & Readability Report

**Scope:** {scope or "full repo"}
**Status:** {PASS | WARN | FAIL}

## Summary

{One sentence assessment of overall code clarity}

## Hot Spots Identified

### Critical (Must Fix)

| Location | Issue | Severity |
|----------|-------|----------|
| {file:line} | {description} | critical/severe |

### Warnings

| Location | Issue | Suggestion |
|----------|-------|------------|
| {file:line} | {description} | {how to improve} |

## Function Length Issues

| Function | File | Lines | Recommendation |
|----------|------|-------|----------------|
| {name} | {file} | {count} | {suggestion} |

## Nesting Issues

| Location | Depth | Suggestion |
|----------|-------|------------|
| {file:line} | {depth} | {how to flatten} |

## Naming Issues

| Current Name | Location | Suggested Name |
|--------------|----------|----------------|
| {name} | {file:line} | {better name} |

## Magic Values

| Value | Location | Should Be |
|-------|----------|-----------|
| {value} | {file:line} | {named constant or comment} |

## Recommendations

1. {specific action with file reference}
2. {specific action with file reference}
```

## Phase 5: Output

1. Save to `tmp/god-review/principles/clarity-findings.md`
2. Print PASS/WARN/FAIL summary with count of hot spots by category

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- PASS: Code is clear, well-named, easy to follow; no functions exceed 100 lines, nesting stays ≤3 levels deep
- WARN: Some readability issues present — functions between 50-100 lines, nesting at 3 levels, occasional magic values — but nothing that fundamentally blocks comprehension
- FAIL: Significant clarity problems — functions >100 lines, nesting >4 levels, systematic poor naming, or multiple hot spots that make the code materially harder to understand and safely modify

## Known Issues (don't re-report)

Loaded from `tmp/god-review/context-package.md` known-issues section if present. Skip any finding already in `tmp/god-review/state.json` from prior rounds.

Run analysis on: $ARGUMENTS (or full repo if empty).
