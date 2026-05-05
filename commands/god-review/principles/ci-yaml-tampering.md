---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Read, Grep, Glob, TodoWrite
description: "Detect modifications to CI/CD pipeline files that could disable gates or enable reward hacking (Tier 1, FAIL)"
argument-hint: "[scope]"
---

# /god-review:principles:ci-yaml-tampering — CI/CD YAML Tampering Detector

You are scanning for any modifications to CI/CD pipeline configuration files. This is the second canonical form of reward hacking — changing the referee instead of fixing the code.

**THIS IS A TIER 1 LENS. ANY MODIFICATION = FAIL. Findings are promoted one confidence level before section assignment.**

## The Principle

CI/CD pipeline files, pre-commit hooks, and build gate configurations must never be modified as a side-effect of automated code changes. These files define the quality gates that guard the codebase. An automated agent that modifies them — even with good intentions — undermines the integrity of the entire verification system.

## Why This Matters

- CI YAML is the referee: changing it to make tests pass is the textbook definition of failure mode #12 (reward hacking)
- Even "innocent" CI changes (disabling a flaky test, loosening a lint rule) create blind spots that persist long after the original motivation is forgotten
- Pre-commit hooks are the first line of defense; disabling them silences the canary
- Automated pipelines that touch CI config cannot be trusted — the change must always be human-reviewed
- This lens activates the hard gate in Phase 3: CI YAML changes are NEVER auto-applied, even with `--fix`

## Phase 1: Gather Context

```bash
# Load shared context if available
[ -f tmp/god-review/context-package.md ] && cat tmp/god-review/context-package.md | head -80

# Read AGENTS.md / CLAUDE.md for CI patterns
find . -maxdepth 2 \( -name "AGENTS.md" -o -name "CLAUDE.md" \) -print 2>/dev/null | head -5 | xargs -I{} cat {}

# Show current branch
git rev-parse --abbrev-ref HEAD
git rev-parse HEAD
```

Use TodoWrite to log each candidate CI file modification.

## Phase 2: Identify Candidates

### 2.1 Modified CI/CD Files

```bash
# Check for any modification (Added, Modified, Deleted, Renamed, Copied) to known CI paths
git diff --name-only HEAD 2>/dev/null | grep -E '^\.(github/workflows/.*\.ya?ml|gitlab-ci\.ya?ml|circleci/config\.ya?ml)$|^azure-pipelines.*\.ya?ml$|^bitbucket-pipelines\.ya?ml$|^Jenkinsfile(\..*)?$|^\.(pre-commit-config\.ya?ml|husky/)' || true

# Also catch files added freshly that match CI patterns (A = added)
git diff --diff-filter=A --name-only HEAD 2>/dev/null | grep -E '^\.(github/workflows/|circleci/).*\.ya?ml$|^Jenkinsfile' || true

# Broader: any .yml/.yaml inside .github/
git diff --name-only HEAD 2>/dev/null | grep -E '^\.(github|gitlab|circleci)/' || true
```

### 2.2 Pre-commit and Hook Configurations

```bash
# Pre-commit configs
git diff --name-only HEAD 2>/dev/null | grep -E '^\.(pre-commit-config\.ya?ml|pre-commit-hooks\.ya?ml)$' || true

# Husky hooks (any file inside .husky/)
git diff --name-only HEAD 2>/dev/null | grep -E '^\.(husky/)' || true

# Lefthook, lint-staged, commitlint
git diff --name-only HEAD 2>/dev/null | grep -E '^(lefthook\.ya?ml|\.lefthook\.ya?ml|lint-staged\.config\.(js|ts|cjs|mjs)|commitlint\.config\.(js|ts|cjs|mjs)|\.commitlintrc\.(js|ya?ml|json))$' || true
```

### 2.3 Deep Inspection of Flagged Files

For each flagged file:

```bash
# Show the full diff
git diff HEAD -- "<flagged_file>" 2>/dev/null

# Show the new content (what it will become)
git show HEAD:"<flagged_file>" 2>/dev/null | head -100

# Classify the change type
git diff --diff-filter=AMDRC --name-status HEAD 2>/dev/null | grep "<flagged_file>"
```

## Phase 3: Deep Analysis

For each flagged CI file modification:

1. **Classify the change type:**
   - Job/step disabled (commenting out, `if: false`, `skip: true`, deleted step)
   - Quality gate weakened (threshold lowered, `continue-on-error: true` added, `allow_failure: true`)
   - New permissive job added (bypass pattern, skip-tests workflow, forced-merge gate)
   - Innocent structural change (rename, add new job, update dependency version in CI)
   - Security-relevant change (secrets access, deployment permissions, environment access)

2. **Assess intent.** Does the surrounding diff suggest this CI change was made to make a failing test/lint pass? Look for correlation between CI changes and test/lint changes in the same diff.

3. **Document the specific risk:**
   - What gate does this weaken or remove?
   - What would fail before this change that now passes?
   - Is this a hard security boundary (deploy keys, secrets, environment access)?

## Phase 4: Generate Report

```markdown
# CI/CD YAML Tampering Report

**Scope:** {scope}
**Status:** {PASS | FAIL}
**Tier:** 1 (always-on, promoted, hard gate in Phase 3)

## Summary

{N} CI/CD configuration files modified. All are flagged — CI changes require human review regardless of intent.

## Modified CI/CD Files

| File | Change Type | Gate Impact | Security Concern | Severity |
|------|------------|-------------|-----------------|----------|
| {path} | {added/modified/deleted} | {what gate is affected} | {yes/no + details} | FAIL |

## Change Analysis

### {filename}

**Type:** {job disabled / gate weakened / new job / structural / security-relevant}

**Before:**
```yaml
{relevant before snippet}
```

**After:**
```yaml
{relevant after snippet}
```

**Risk:** {What could now pass that previously failed? What gate is weakened?}

**Correlation with other diff changes:** {Is this CI change correlated with a test failure or lint error in the same diff?}

## Recommended Actions

This finding is always HUMAN_GATE — CI YAML changes are never auto-applied.

1. Review {file}: confirm whether this change was intentional and justified
2. If this change was made to silence a failing gate, revert both the CI change and the code change that caused it
3. If this change is legitimate, document the reason in the commit message
```

## Phase 5: Output

1. Save findings to `tmp/god-review/principles/ci-yaml-tampering-findings.md`
2. Print summary:
   - PASS: zero CI/CD file modifications
   - FAIL: any modification detected (regardless of apparent intent)

```bash
mkdir -p tmp/god-review/principles
```

## Scoring Criteria

See CRITERIA.md for confidence/severity definitions. The thresholds below are principle-specific.

- **PASS**: No CI/CD configuration files modified in the diff.
- **FAIL**: Any modification to any file matching the CI/CD path patterns — added, modified, deleted, or renamed.

This is a binary lens. Any hit is FAIL. There is no WARN state and no threshold to meet — one touched file = FAIL.

## Risk Levels

- **CRITICAL**: Security-relevant CI change (deployment secrets access, environment permissions, branch protection bypass)
- **HIGH**: Quality gate disabled or weakened (step skipped, threshold lowered, `continue-on-error` added, job deleted)
- **MEDIUM**: Structural change with unclear gate impact (renamed job, reordered steps, version update)
- **LOW**: Pure additive change (new job that doesn't gate merges, comment added)

Even LOW risk CI changes are FAIL — the level only affects report prioritization.

## Known Issues (don't re-report)

- Load from `tmp/god-review/context-package.md` known-issues section if available
- Do NOT flag changes to application-level YAML files that are not CI/CD configs (e.g., `docker-compose.yml`, `kubernetes.yml`, `helm/values.yaml`, `ansible/playbook.yml`) — these are infrastructure/deployment config, not CI gates
- Do NOT flag changes to `dependabot.yml` or `renovate.json` — these are dependency update configs, not quality gates (though any resulting CI changes in the same diff should still be flagged)

Run analysis on: $ARGUMENTS (or full repo HEAD diff if empty).
