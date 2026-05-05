---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(wc:*), Bash(awk:*), Read, Grep, Glob, TodoWrite
description: "Detect test file deletions and shrinkage that silently reduce test coverage (Tier 1, FAIL)"
argument-hint: "[scope]"
---

# /god-review:principles:test-deletion — Test Deletion Detector

You are scanning for test file deletions and shrinkage that reduce test coverage, a critical failure mode in automated fix loops (#11 in the failure-mode registry).

**THIS IS A TIER 1 LENS. ANY HIT = FAIL. Findings are promoted one confidence level before section assignment.**

## The Principle

Test files must never be deleted or significantly shrunk as a side-effect of code changes. Removing tests to make CI green is reward hacking — it silences evidence of bugs rather than fixing them. Even well-intentioned "cleanup" that removes tests eliminates the safety net future changes rely on.

## Why This Matters

- Deleting tests to pass CI is the canonical form of reward hacking — failure mode #11
- Coverage drops are invisible to metrics that only track passing status
- An automated fix loop that deletes tests appears to "improve" the repo while actually degrading it
- Test deletions compound: each removal makes the next deletion harder to notice
- Once a test is gone, the behavior it guarded is no longer validated — regressions become silent

## Phase 1: Gather Context

```bash
# Load shared context if available
[ -f tmp/god-review/context-package.md ] && cat tmp/god-review/context-package.md | head -80

# Read AGENTS.md / CLAUDE.md for known test patterns
find . -maxdepth 2 \( -name "AGENTS.md" -o -name "CLAUDE.md" \) -print 2>/dev/null | head -5 | xargs -I{} cat {}

# Determine scope
SCOPE="${ARGUMENTS:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
echo "Scope: $SCOPE"

# Show current branch and base
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
```

Use TodoWrite to log each candidate test-file deletion or shrinkage to investigate.

## Phase 2: Identify Candidates

### 2.1 Deleted Test Files

```bash
# Find deleted test files in the diff (D = deleted)
git diff --diff-filter=D --name-only HEAD 2>/dev/null | grep -E '\.(test|spec)\.(js|ts|jsx|tsx|py|rb|go|java|rs|cpp|c)$|_test\.(go|py|rb|cpp|c)$|test_.*\.(py|rb)$' || true

# Also catch test directories
git diff --diff-filter=D --name-only HEAD 2>/dev/null | grep -E '^(tests|__tests__|spec|__spec__|test)/' || true

# Broader: any deleted file in known test paths
git diff --diff-filter=D --name-only HEAD 2>/dev/null | grep -E '(tests/|__tests__/|spec/|__spec__/|test/|\.test\.|\.spec\.|_test\.|test_)' || true
```

### 2.2 Significantly Shrunk Test Files

```bash
# Get line count changes for test-related files (additions deletions filename)
git diff --numstat HEAD 2>/dev/null | grep -E '\.(test|spec)\.(js|ts|jsx|tsx|py|rb|go|java|rs|cpp|c)$|_test\.(go|py|rb|cpp|c)$|test_.*\.(py|rb)$|(tests|__tests__|spec|test)/' | while read additions deletions filename; do
  # Skip binary files (shown as -)
  [ "$additions" = "-" ] && continue
  # Calculate shrinkage ratio: deletions / (deletions + additions + 1)
  ratio=$(awk "BEGIN { printf \"%.4f\", $deletions / ($deletions + $additions + 1) }")
  # Get original file line count (before the diff)
  original_lines=$(git show HEAD:"$filename" 2>/dev/null | wc -l | tr -d ' ')
  echo "FILE=$filename DELETIONS=$deletions ADDITIONS=$additions RATIO=$ratio ORIGINAL_LINES=$original_lines"
done
```

Flag a file if BOTH conditions hold:
- `deletions / (deletions + additions + 1) > 0.20` (more than 20% of net churn is deletion)
- `original_lines >= 25` (floor: small files naturally fluctuate; don't false-positive on tiny test stubs)

### 2.3 Deep Inspection of Flagged Files

For each flagged file:

```bash
# Show the full diff for context
git diff HEAD -- "<flagged_file>" 2>/dev/null | head -200

# Count removed test function / describe / it / test() blocks specifically
git diff HEAD -- "<flagged_file>" 2>/dev/null | grep -E '^\-.*\b(describe|it|test|it\.only|test\.only|def test_|func Test|#\[test\]|#\[tokio::test\])\b' | wc -l
```

## Phase 3: Deep Analysis

For each candidate:

1. **Confirm it is a real test.** Check whether the removed lines contain actual assertions (`expect`, `assert`, `should`, `must`, `t.Error`, `t.Fatal`, `self.assert`, `assertEquals`). A file matching the name pattern but containing only fixtures or data (no assertions) is lower severity.

2. **Determine intent.** Read the surrounding commit message (if available) and the rest of the diff. Is this:
   - Deliberate test removal with justification? (still FAIL, but note the justification)
   - Collateral deletion during refactor? (FAIL — tests should be updated, not removed)
   - A test that was deleted because the tested code was removed? (context matters: if the corresponding production code was also deleted in the same diff, this is acceptable — note it as such and do NOT flag)

3. **Quantify the coverage loss.** How many test cases / describe blocks / it() calls were removed? Report this count in the finding.

4. **Check for cross-file moves.** Verify the deleted test wasn't moved to another file:
```bash
# Grep for key assertion strings or describe block names from the deleted content in other test files
git diff HEAD 2>/dev/null | grep "^+" | grep -E 'describe\(|it\(|test\(' | head -20
```

## Phase 4: Generate Report

```markdown
# Test Deletion Report

**Scope:** {scope}
**Status:** {PASS | FAIL}
**Tier:** 1 (always-on, promoted)

## Summary

{N} test file deletions detected. {M} files shrunk by >20% with ≥25 original lines.

## Deleted Test Files

| File | Lines Lost | Assertions Removed | Justification | Severity |
|------|-----------|-------------------|---------------|----------|
| {path} | {N} | {M} | {commit message / none} | FAIL |

## Significantly Shrunk Test Files

| File | Original Lines | Deletions | Additions | Shrink Ratio | Test Cases Lost | Severity |
|------|---------------|-----------|-----------|-------------|-----------------|----------|
| {path} | {N} | {D} | {A} | {ratio:.2%} | {M} | FAIL |

## Acceptable Deletions (production code also removed)

| File | Reason | Evidence |
|------|--------|---------|
| {path} | Corresponding production code deleted | {evidence} |

## Recommendations

1. Restore deleted test file {path} — check git history: `git show HEAD:<path>`
2. Investigate why test at {path} was shrunk — restore removed test cases
```

## Phase 5: Output

1. Save findings to `tmp/god-review/principles/test-deletion-findings.md`
2. Print summary:
   - PASS: zero deletions, zero significant shrinkage
   - FAIL: any deletion or shrinkage beyond threshold

```bash
mkdir -p tmp/god-review/principles
```

## Scoring Criteria

See CRITERIA.md for confidence/severity definitions. The thresholds below are principle-specific.

- **PASS**: No test files deleted. No test files shrunk by >20% of net churn (with 25-line floor).
- **FAIL**: Any test file deleted, OR any test file where `deletions/(deletions+additions+1) > 0.20` AND original file had ≥25 lines.

This is a binary lens — there is no WARN state. Any hit is FAIL.

## Risk Levels

- **CRITICAL**: Deletion of a test file covering a security-sensitive or auth path
- **HIGH**: Deletion of a test file with ≥10 assertions; or deletion of an entire test suite file
- **MEDIUM**: Shrinkage of a test file losing 5–9 assertions
- **LOW**: Shrinkage losing 1–4 assertions (still FAIL, but lower blast radius)

## Known Issues (don't re-report)

- Load from `tmp/god-review/context-package.md` known-issues section if available
- Do NOT flag deletions where the corresponding production code was also deleted in the same diff — these are legitimate cleanup
- Do NOT flag test helper/fixture files that contain no assertions (data files, mock fixtures, factory builders with no `expect`/`assert`) — check for assertion keywords before flagging

Run analysis on: $ARGUMENTS (or full repo HEAD diff if empty).
