---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Check comments and docs against the comment policy
argument-hint: "[scope]"
---

# /god-review:principles:documentation - Comment and Documentation Policy

## The Principle

A comment says what the code cannot: an outside system's quirk, or a safety, privacy, clinical or
tenant reason, ideally linked to the test or doc that proves it. Everything else belongs in names,
types and tests. Comments carry no history (dates, review rounds, phase tags, line pointers), and a
"for now" or "known limitation" names its tracked item. This is the comment section of
`rules/code-quality.md`, applied as a review.

This principle is **report-only**: it recommends, it never edits or deletes.

**Key requirements:**
- No history comments: dates, review rounds, phase tags, "fixed in round 3", `see line 120`.
- No stale or misleading comments: the comment must match what the code does now (params, return,
  behavior, referenced files).
- No narration: a comment that restates the next line (`// set loading to true`) adds nothing.
- A reason is present where the code alone cannot carry it: an outside-system quirk (OpenDental, a
  vendor API, a browser bug) or a safety, privacy, clinical or tenant rule.
- "For now", "temporary", "known limitation" and TODOs name the tracked item (issue, plan, doc).

**Never:**
- Fail or warn for "too few comments". Missing comments are not a finding unless a required reason
  (above) is missing.
- Recommend deleting a safety, HIPAA/PHI, clinical or tenant-isolation note. If one is stale,
  recommend correcting it, not removing it.

## Why This Matters

- Stale and misleading comments are worse than none: agents and humans trust them over the code and
  build wrong fixes on them (failure modes #6, #7).
- History comments rot on the next change and bury the few comments that matter.
- The comments that do matter (why an OD quirk is handled this way, why a tenant check sits here)
  are the ones a future agent cannot re-derive after compaction (failure mode #8).

Reference: `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md` failure modes #6, #7, #8

## Phase 1: Gather Context

- Read `tmp/god-review/context-package.md` if it exists; otherwise auto-generate minimal context
- Read repo `AGENTS.md` / `CLAUDE.md` if present - the project may add its own comment rules
- Get scope: `$ARGUMENTS` or full repo via `git diff main...HEAD --name-only` or full file list

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"
git rev-parse --abbrev-ref HEAD
git diff main...HEAD --name-only 2>/dev/null || find . -name "*.tsx" -o -name "*.ts" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.go" -o -name "*.rs" | grep -v node_modules | grep -v .git | head -200
git diff main...HEAD 2>/dev/null || true
```

Use TodoWrite to track candidate comments.

## Phase 2: Identify Candidates

### 2.1 History comments

```bash
CHANGED=( $(git diff main...HEAD --name-only 2>/dev/null) )
[ "${#CHANGED[@]}" -gt 0 ] && grep -nEi "(20[0-9]{2}-[0-9]{2}-[0-9]{2}|round [0-9]+|phase [0-9A-Z]+|\bR[0-9]+\b|review fix|see line [0-9]+|was changed|previously|used to)" -- "${CHANGED[@]}"
```

Matches are candidates only; read each one before reporting it.

```typescript
// WRONG - history
// 2026-10-03: fixed in review round 2 (see line 140)
// Phase 3B: switched from polling

// CORRECT - the reason, no history
// OpenDental returns every patient when Birthdate is malformed, so validate before querying.
```

### 2.2 Stale or misleading comments

Compare each comment in or near changed code with what the code does now: a JSDoc naming params that
no longer exist, a "returns null" over code that throws, a comment pointing at a moved file or a
removed flag.

### 2.3 Narration

```typescript
// WRONG - narrates the code
// Call the API
const result = await api.fetch();
```

### 2.4 Missing required reason

Flag only code whose reason cannot be read from the code: a workaround for an outside system, or a
safety, privacy, clinical or tenant guard with no comment or linked test/doc saying why it exists.

### 2.5 Untracked "for now"

`TODO`, `for now`, `temporary`, `known limitation`, `HACK` with no issue, plan or doc named.

## Phase 3: Deep Analysis

For each candidate:
1. Read the surrounding code - confirm the comment really is stale, history or narration.
2. A safety, HIPAA, clinical or tenant note is never a deletion candidate; if wrong, the
   recommendation is a correction.
3. Severity follows `CRITERIA.md`; a stale comment that would mislead a fix on a safety path is
   higher than a narrating one.

## Phase 4: Generate Report

Markdown table format:
| Location | Issue | Severity | Recommendation | Evidence |

Full report structure:

```markdown
# Comment Policy Report

**Scope:** {scope or "full repo"}
**Status:** {PASS | WARN | FAIL}

## Summary

{One sentence assessment}

## Findings

| Location | Kind (history / stale / narration / missing-reason / untracked) | Severity | Recommendation | Evidence |
|----------|-----|----------|----------------|----------|
| {file:line} | {kind} | {definite/likely/investigate} | {reword / correct / remove narration / add reason / name the item} | {quoted comment + what the code does} |

## Recommendations

1. {specific action with file reference}
```

## Phase 5: Output

1. Save to `tmp/god-review/findings/${GOD_REVIEW_AGENT_ID:-claude-principle-documentation}.txt`
2. Print PASS/WARN/FAIL summary with counts per kind

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- PASS: no history, stale, misleading or narrating comments in scope; every outside-system quirk and
  safety/privacy/clinical/tenant guard carries its reason; every "for now" names its item
- WARN: a few narrating comments or untracked "for now" notes
- FAIL: any history comment, any stale or misleading comment, or a missing reason on an
  outside-system quirk or a safety/privacy/clinical/tenant rule

"Too few comments" is never a WARN or FAIL.

## Known Issues (don't re-report)

Loaded from `tmp/god-review/context-package.md` known-issues section if present. Skip any finding already in `tmp/god-review/state.json` from prior rounds.

Run analysis on: $ARGUMENTS (or full repo if empty).
