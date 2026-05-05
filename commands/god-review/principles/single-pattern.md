---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Check for violations of the Single Way to Do Things principle (MOST IMPORTANT — Tier 1, always promoted)
argument-hint: "[scope]"
---

# /god-review:principles:single-pattern — Single Way to Do Things

**THIS IS THE MOST IMPORTANT PRINCIPLE. Tier 1. All findings are promoted one confidence level before section assignment.**

## The Principle

There should be only ONE implementation pattern per feature/behavior in the codebase. Multiple ways to accomplish the same thing guarantee LLM proliferation — the next AI-assisted change will create a third variant because it sees two existing ones.

## Why This Matters

- Failure mode #7 (hallucination cascade): when agent A creates a parallel hook/utility, agent B treats it as the canonical one and builds on it
- Failure mode #2 (churn/oscillation): duplicate patterns get rewritten back and forth across review rounds
- Failure mode #14 (overcomplication): each additional pattern is its own maintenance surface
- Every duplicate pattern confuses future developers (human and AI), increases maintenance burden, leads to inconsistent behavior, makes refactoring harder, and causes LLMs to create even more patterns
- One way to do things = scalable, maintainable codebase

Reference: `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md` failure modes #2, #7, #14

## Phase 1: Gather Context

- Read `tmp/god-review/context-package.md` if it exists; otherwise auto-generate minimal context from git
- Read repo `AGENTS.md` / `CLAUDE.md` if present — these declare canonical patterns explicitly
- Get scope: `$ARGUMENTS` if provided, otherwise full repo via `git diff main...HEAD --name-only` or full file list

```bash
git rev-parse --abbrev-ref HEAD
git diff main...HEAD --name-only 2>/dev/null || find . -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.go" -o -name "*.rs" | grep -v node_modules | grep -v .git | head -200
git diff main...HEAD 2>/dev/null || true
```

Use TodoWrite to track each new pattern to investigate.

## Phase 2: Identify New Patterns

For each changed file (or file in $ARGUMENTS scope), identify:

### 2.1 New Hooks / Composables

Search the diff for:
- `function use[A-Z]` — custom hook definitions
- `const use[A-Z]` — custom hook definitions
- `export.*use[A-Z]` — exported hooks

For each new hook found:
1. Note its purpose and functionality
2. Grep codebase for existing hooks with similar purpose
3. Flag if multiple hooks now do similar things

### 2.2 New Components

Search for:
- New UI component files
- New component definitions exported

For each new component:
1. Note what it renders/does
2. Search for existing similar components
3. Flag if this could have extended an existing component

### 2.3 New Utilities / Helpers

Search for:
- New functions in `utils/`, `helpers/`, `lib/` directories
- New exported functions that could be utilities

For each:
1. Note the functionality
2. Search the project's shared directory (detect from project structure or AGENTS.md/CLAUDE.md)
3. Search local utils for similar functions
4. Flag duplication

### 2.4 New API / Service Patterns

For backend changes, check:
- New endpoint patterns
- New service patterns
- New middleware patterns
- New repository/data-access patterns

Compare to existing patterns in the same module.

### 2.5 New State Management Patterns

Check for:
- New ways of managing state
- New context providers
- New store patterns

## Phase 3: Deep Pattern Analysis

For EACH new pattern identified:

### 3.1 Search for Existing Alternatives

```
1. Grep for similar function/component names
2. Grep for similar functionality (key terms from implementation)
3. Read similar files to understand existing patterns
4. Check the codebase's shared/canonical directory (detect from project structure or AGENTS.md)
5. Check for any exemplar declared in AGENTS.md or CLAUDE.md
```

### 3.2 Document Pattern Proliferation Risk

For each new pattern, answer:
- Does this introduce a second way to do something?
- Will future LLM-assisted development create a third way?
- Should this pattern be unified with an existing one?

## Phase 4: Generate Report

Markdown table format:
| Location | Issue | Severity | Recommendation | Evidence |

Full report structure:

```markdown
# Single Way to Do Things Report

**Scope:** {scope or "full repo"}
**Status:** {PASS | WARN | FAIL}
**Risk Level:** {LOW | MEDIUM | HIGH | CRITICAL}

## Summary

{Assessment of pattern proliferation risk}

## New Patterns Introduced

### Pattern N: {name}

**Type:** {hook | component | utility | API | state | service}
**Location:** {file:line}
**Purpose:** {what it does}

**Existing Alternatives Found:**
| Alternative | Location | Similarity |
|-------------|----------|------------|
| {name} | {path} | {how similar} |

**Assessment:** {Should this use existing pattern? Should patterns be unified?}

## Pattern Proliferation Risks

### Critical (Multiple Ways Now Exist)

| Feature/Behavior | Implementations | Risk |
|------------------|-----------------|------|
| {what it does} | {list of implementations} | {assessment} |

### Warnings (Potential Duplication)

| New Pattern | Similar To | Recommendation |
|-------------|------------|----------------|
| {new} | {existing} | {unify/keep separate/other} |

## Existing Patterns That Should Have Been Used

1. **{pattern name}** at `{path}`
   - Already handles: {functionality}
   - New code should: {how to use it instead}

## Pattern Inventory

After this review, here are the ways to do {common thing}:

| Implementation | Location | Notes |
|----------------|----------|-------|
| {impl 1} | {path} | {original/new/should deprecate} |
```

## Phase 5: Output

1. Save to `tmp/god-review/principles/single-pattern-findings.md`
2. Print PASS/WARN/FAIL summary with pattern proliferation risk level

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- PASS: No new patterns introduced, or new patterns don't duplicate existing functionality
- WARN: New pattern introduced where existing alternative exists, but not critical — different enough use cases to justify
- FAIL: Multiple ways to do the same thing now exist in codebase, or this PR creates a direct duplicate of existing functionality

## Risk Levels

- LOW: New pattern is truly unique, no existing alternatives anywhere in codebase
- MEDIUM: Similar patterns exist but serve demonstrably different use cases
- HIGH: New pattern duplicates existing functionality with only superficial differences
- CRITICAL: This change creates a second or third way to do something already fully handled by an existing abstraction; future LLM edits will proliferate this further

## Known Issues (don't re-report)

Loaded from `tmp/god-review/context-package.md` known-issues section if present. Skip any pattern already flagged in prior rounds per `tmp/god-review/state.json`.

Run analysis on: $ARGUMENTS (or full repo if empty).
