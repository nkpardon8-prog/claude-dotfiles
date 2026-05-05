---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Check for violations of the Correct Scope principle (one PR / one change = one thing)
argument-hint: "[scope]"
---

# /god-review:principles:scope — Correct Scope

## The Principle

A PR or a single code change should address ONE thing, not three bundled together. One objective equals clearer, more reviewable, more safely revertible changes.

**Problems with multi-objective changes:**
- Harder to review — reviewers must disentangle unrelated intent
- Confusing rollback — must revert a bug fix to undo a feature
- Masks impact of individual changes — performance regression of one change is hidden by refactor of another
- Failure modes proliferate — each tangled concern has independent ways to go wrong

## Why This Matters

- Failure mode #13 (tangled commits): ~54% of refactors hide inside "bug fix" commits; scope creep slips past review
- Failure mode #10 (full autonomy on irreversibles): bundled changes obscure which part touched the auth layer or schema
- Failure mode #1 (error accumulation): wide-scope changes touch more code = higher probability of introducing errors per change
- Failure mode #5 (no rollback): multi-objective changes cannot be selectively reverted

Reference: `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md` failure modes #1, #5, #10, #13

## Phase 1: Gather Context

- Read `tmp/god-review/context-package.md` if it exists; otherwise auto-generate minimal context
- Read repo `AGENTS.md` / `CLAUDE.md` if present
- Get scope: `$ARGUMENTS` or full repo via git diff stats

```bash
git rev-parse --abbrev-ref HEAD
git diff main...HEAD --stat 2>/dev/null || true
git diff main...HEAD --name-only 2>/dev/null || true
git log main...HEAD --oneline 2>/dev/null || true
```

## Phase 2: Identify Candidates

### 2.1 List All Changed Files

Group files by type and purpose:
- **Feature files**: New functionality being added
- **Bug fix files**: Fixing specific existing issues
- **Refactor files**: Code restructuring without behavior change
- **Config files**: Configuration or build changes
- **Test files**: Test additions or modifications
- **Documentation**: Docs-only changes

### 2.2 Identify Distinct Objectives

For each changed file, ask:
- What is the purpose of this change?
- What feature, fix, or improvement does this support?

List each distinct objective found and which files belong to it.

### 2.3 Check for Scope Creep

Red flags:
- **"While I was in here..."** changes unrelated to the main objective
- **Opportunistic refactors** mixed with feature work
- **Multiple unrelated bug fixes** in a single change set
- **Feature + refactor + bugfix** all bundled together
- **Changes to completely unrelated modules** — files in separate domains that share no logical relationship to the stated objective

### 2.4 Analyze File Relationships

- Do all changed files relate to the same feature, module, or domain?
- Are there changes to completely separate parts of the codebase?
- Could this change set be split into independent, separately-reviewable units with no coupling between the split parts?

## Phase 3: Deep Analysis

For each candidate mixed-objective set:
1. Determine if the changes are genuinely coupled (one cannot ship without the other) or merely co-located in time
2. Assess revert complexity — if the feature turned out to be wrong, how much unrelated work would be lost?
3. Check commit messages for signs of bundling: "also fixed X", "while here", "minor cleanup"

## Phase 4: Generate Report

Markdown table format:
| Location | Issue | Severity | Recommendation | Evidence |

Full report structure:

```markdown
# Correct Scope Report

**Scope:** {scope or "full repo"}
**Status:** {PASS | WARN | FAIL}

## Summary

{One sentence assessment of change scope}

## Change Statistics

- **Files changed:** {count}
- **Insertions:** {count}
- **Deletions:** {count}
- **Modules touched:** {list}

## Objectives Identified

### Primary Objective
{Main purpose of this change}

### Secondary Objectives (if any)
1. {objective 2}
2. {objective 3}

## Scope Assessment

### Files by Objective

**Objective 1: {name}**
- {file1}
- {file2}

**Objective 2: {name}** (if multiple objectives detected)
- {file3}
- {file4}

### Scope Issues Found

| Issue | Files Involved | Recommendation |
|-------|----------------|----------------|
| {issue type} | {files} | {what to do} |

## "While I Was In Here" Changes

| File | Change | Belongs To |
|------|--------|------------|
| {file} | {what changed} | {which objective, or "unrelated"} |

## Recommendations

### If Should Be Split

Suggested split:
1. **Change 1: {objective}**
   - {file list}

2. **Change 2: {objective}**
   - {file list}

### If Scope Is Acceptable

{Explanation of why bundling is justified — e.g., changes are tightly coupled and cannot safely ship independently}
```

## Phase 5: Output

1. Save to `tmp/god-review/principles/scope-findings.md`
2. Print PASS/WARN/FAIL summary with number of distinct objectives identified

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- PASS: Change addresses one clear objective; all changed files are logically related to that objective
- WARN: Minor scope creep present but the change is still reviewable as a unit — the secondary change is small and tightly related
- FAIL: Multiple unrelated objectives that should be separate changes; refactor mixed with feature work; bug fixes bundled with new features with no logical dependency between them

## Important Notes

- Small, focused changes are ALWAYS preferred
- A change touching 50 files all related to one feature is better than a change touching 5 files addressing 5 different features
- Refactors should generally be separate from feature work
- Bug fixes should generally be separate from new features
- The test: could each part ship independently to production without the other part? If yes, they should be split

## Known Issues (don't re-report)

Loaded from `tmp/god-review/context-package.md` known-issues section if present. Skip any finding already in `tmp/god-review/state.json` from prior rounds.

Run analysis on: $ARGUMENTS (or full repo if empty).
