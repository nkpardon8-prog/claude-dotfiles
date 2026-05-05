---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: "Detect unused exports and functions, with mandatory reflection-pattern verification before flagging (Tier 2, HUMAN_GATE only)"
argument-hint: "[scope]"
---

# /god-review:principles:dead-code-conservatism — Dead Code Conservatism Checker

You are scanning for unused exports and functions while applying strict verification to avoid false positives. This lens is explicitly conservative — it is better to miss a dead-code finding than to recommend removing live code.

**THIS IS A TIER 2 LENS. Standard severity, no automatic promotion. All dead-code findings are HUMAN_GATE — never AUTO_FIX.**

## The Principle

Apparently-unused code must undergo multi-step verification before being flagged. Reflection patterns, dynamic imports, decorator references, string-literal lookups, and CI/cron configuration files can all reference code without appearing in static import graphs. Dead-code removal is irreversible in practice (git history notwithstanding); conservatism is the correct default.

## Why This Matters

- Dead code removal is failure mode #9 — code that looks unused may be referenced by reflection, dynamic import, cron config, or test harness setup
- False positives in dead-code analysis cause removal of live code, creating silent bugs that don't surface until runtime
- Automated deletion is irreversible at the user's mental level — even with git history, "it was deleted by the review bot" erodes trust
- The recommended remediation is always quarantine to `_deprecated/` (HUMAN_GATE), not deletion — this is hard-coded in Phase 3's gate logic
- This lens deliberately produces HUMAN_GATE-only findings; the orchestrator will never auto-apply dead-code removals

## Phase 1: Gather Context

```bash
# Load shared context if available
[ -f tmp/god-review/context-package.md ] && cat tmp/god-review/context-package.md | head -80

# Read AGENTS.md / CLAUDE.md for export patterns
find . -maxdepth 2 \( -name "AGENTS.md" -o -name "CLAUDE.md" \) -print 2>/dev/null | head -5 | xargs -I{} cat {}

WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Detect project type
ls "$WORKDIR/package.json" 2>/dev/null && echo "NODE_PROJECT=yes"
ls "$WORKDIR/go.mod" 2>/dev/null && echo "GO_PROJECT=yes"
ls "$WORKDIR/Cargo.toml" 2>/dev/null && echo "RUST_PROJECT=yes"
ls "$WORKDIR/requirements.txt" "$WORKDIR/pyproject.toml" 2>/dev/null | head -1 && echo "PYTHON_PROJECT=yes"

# Show current branch
git rev-parse --abbrev-ref HEAD
```

Use TodoWrite to track each dead-code candidate as it is found and verified.

## Phase 2: Identify Candidates

### 2.1 Exported Symbols with No Apparent Importers (Node.js/TypeScript)

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Find exported symbols in changed files (from diff) or all source files
find "$WORKDIR/src" "$WORKDIR/lib" "$WORKDIR/app" "$WORKDIR/pages" "$WORKDIR/components" 2>/dev/null \
  -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" \) \
  -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/dist/*" -not -path "*/build/*" | \
  xargs grep -hE '^export (const|function|class|interface|type|enum) ([A-Za-z_][A-Za-z0-9_]*)' 2>/dev/null | \
  grep -oE '(const|function|class|interface|type|enum) ([A-Za-z_][A-Za-z0-9_]*)' | \
  awk '{print $2}' | sort -u | head -100
```

For each exported symbol, search for importers:

```bash
SYMBOL="ExampleExportedName"  # replace with actual symbol
grep -rn \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  --exclude-dir="node_modules" --exclude-dir=".git" --exclude-dir="dist" \
  -E "(import|from).*\b${SYMBOL}\b" "$WORKDIR" 2>/dev/null | wc -l
```

A symbol with 0 importers (excluding its own definition file) is a candidate.

### 2.2 Python Unused Functions

```bash
# Find functions defined but not called in the same or other modules
find "$WORKDIR" -type f -name "*.py" -not -path "*/.git/*" -not -path "*/venv/*" -not -path "*/__pycache__/*" | \
  xargs grep -hE '^def ([a-z_][a-z0-9_]*)' 2>/dev/null | \
  grep -oE '\b[a-z_][a-z0-9_]+\b' | sort -u | while read funcname; do
    count=$(grep -rn "\b${funcname}\b" "$WORKDIR" --include="*.py" 2>/dev/null | grep -v "^def ${funcname}" | wc -l)
    [ "$count" -eq 0 ] && echo "CANDIDATE: $funcname"
  done | head -30
```

## Phase 3: Deep Analysis — Mandatory Verification Before Flagging

**CRITICAL: For every candidate, ALL of the following checks must be performed. Flag ONLY if ALL checks pass (i.e., all show zero evidence of live usage). If ANY check finds evidence, drop the candidate entirely.**

### Check 1: String-literal / reflection lookup

```bash
SYMBOL="CandidateSymbol"  # replace
# Look for string-literal references (dynamic property access, eval, module federation, etc.)
grep -rn \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  --include="*.py" --include="*.rb" --include="*.go" \
  --include="*.json" --include="*.yaml" --include="*.yml" \
  --exclude-dir="node_modules" --exclude-dir=".git" --exclude-dir="dist" \
  -F "\"${SYMBOL}\"" "$WORKDIR" 2>/dev/null | wc -l

grep -rn \
  --include="*.ts" --include="*.tsx" --include="*.js" \
  --exclude-dir="node_modules" --exclude-dir=".git" \
  -F "'${SYMBOL}'" "$WORKDIR" 2>/dev/null | wc -l
```

### Check 2: Dynamic import / require

```bash
# Dynamic imports with string interpolation or template literals
grep -rn \
  --include="*.ts" --include="*.tsx" --include="*.js" \
  --exclude-dir="node_modules" --exclude-dir=".git" \
  -E "import\(['\`].*${SYMBOL}|require\(['\`].*${SYMBOL}" "$WORKDIR" 2>/dev/null | wc -l
```

### Check 3: Decorator and framework registration

```bash
# Check for decorator-based registration patterns (Injectable, Controller, Component, etc.)
grep -rn \
  --include="*.ts" --include="*.tsx" --include="*.js" \
  --exclude-dir="node_modules" --exclude-dir=".git" \
  -E "@[A-Za-z]+\(.*${SYMBOL}|module\.(exports|register).*${SYMBOL}" "$WORKDIR" 2>/dev/null | wc -l
```

### Check 4: CI/cron config file references

```bash
# CI YAML and cron config might reference module names or function names by string
grep -rn \
  --include="*.yml" --include="*.yaml" --include="*.json" \
  --exclude-dir="node_modules" --exclude-dir=".git" \
  -F "$SYMBOL" "$WORKDIR" 2>/dev/null | grep -v "test\|spec" | wc -l
```

### Check 5: Re-export barrel files

```bash
# Check if the symbol is re-exported from an index/barrel file (even if the barrel isn't directly imported in current grep)
grep -rn \
  --include="*.ts" --include="*.tsx" --include="*.js" \
  --exclude-dir="node_modules" --exclude-dir=".git" \
  -E "export.*\b${SYMBOL}\b" "$WORKDIR" 2>/dev/null | grep -v "^$(grep -rn "^export" "$WORKDIR" --include="*.ts" -l 2>/dev/null | grep "${SYMBOL_FILE}" | head -1):" | wc -l
```

### Check 6: Test file usage (not just unit tests — integration, e2e, fixtures)

```bash
grep -rn \
  --include="*.test.ts" --include="*.test.tsx" --include="*.test.js" \
  --include="*.spec.ts" --include="*.spec.tsx" --include="*.spec.js" \
  --include="*.e2e.ts" --include="*.e2e.js" \
  --exclude-dir="node_modules" --exclude-dir=".git" \
  -E "\b${SYMBOL}\b" "$WORKDIR" 2>/dev/null | wc -l
```

**Flag the candidate ONLY if ALL 6 checks return 0 (no references found).**

## Phase 4: Generate Report

```markdown
# Dead Code Conservatism Report

**Scope:** {scope}
**Status:** {PASS | WARN}
**Tier:** 2 (always-on, no promotion)
**Remediation:** HUMAN_GATE only (quarantine to `_deprecated/`, never delete)

## Summary

{N} candidates investigated. {M} confirmed unused after all reflection checks. {K} candidates cleared by at least one check.

## Confirmed Unused (all 6 checks passed)

| Symbol | File | Lines | Checks Passed | Proposed Action | Severity |
|--------|------|-------|--------------|-----------------|----------|
| `{name}` | `{file}:{line}` | {count} | all 6 | Quarantine to `_deprecated/` (HUMAN_GATE) | investigate |

### Quarantine Diff (proposed, human applies)

```diff
# Move {file} to _deprecated/{file} and update all import references
# This is a multi-file change — apply manually
git mv {file} _deprecated/{file}
# Then update all files that import from {original_path} to import from _deprecated/{original_path}
# Verify no imports remain: grep -rn "{symbol_name}" src/
```

## Candidates Cleared (evidence of live usage found)

| Symbol | File | Check That Cleared It | Evidence |
|--------|------|----------------------|---------|
| `{name}` | `{file}` | {check number + name} | `{found reference}` |

## Recommendations

1. For `{symbol}`: move to `_deprecated/{file}` — do NOT delete. Review after 2 sprints; if still unused, delete then.
2. Add a `// @deprecated — quarantined {date}` comment before moving to aid future cleanup
3. After quarantine: run typecheck to confirm all import references were updated
```

## Phase 5: Output

1. Save findings to `tmp/god-review/principles/dead-code-conservatism-findings.md`
2. Print summary:
   - PASS: no confirmed unused exports/functions
   - WARN: confirmed unused symbols found (all require HUMAN_GATE quarantine, never auto-apply)

```bash
mkdir -p tmp/god-review/principles
```

## Scoring Criteria

See CRITERIA.md for confidence/severity definitions. The thresholds below are principle-specific.

- **PASS**: No exports or functions confirmed unused after all 6 verification checks.
- **WARN**: One or more symbols confirmed unused after all verification checks. All are `investigate`-level confidence (dead code is often intentional or will be used soon).

Dead-code findings are always `investigate` confidence — they are surfaced for human review, not acted upon automatically. The orchestrator never downgrades this to AUTO_FIX.

## Risk Levels

- **HIGH**: An exported class or module that is completely unused across the entire repo (no static or dynamic references, no test usage, no reflection) — strong signal this is truly dead
- **MEDIUM**: An exported function with no direct call sites but present in a barrel/index file (may be part of a public API that consumers haven't used yet)
- **LOW**: An internal utility function that appears unused but was recently added (may be for upcoming features)

Even HIGH risk findings are HUMAN_GATE — this lens never produces AUTO_FIX candidates.

## Known Issues (don't re-report)

- Load from `tmp/god-review/context-package.md` known-issues section if available
- Do NOT flag symbols in `_deprecated/` — they are already quarantined and pending deletion
- Do NOT flag symbols in files ending with `.d.ts` — these are type declaration files for external consumers
- Do NOT flag `main()`, `handler()`, `app`, or framework entrypoints (Express app, Next.js page exports, FastAPI app, etc.) — these are called by the framework, not imported
- Do NOT flag symbols marked with `// @public` or documented in JSDoc/TSDoc with `@public` — these are intentional public API surface
- Do NOT flag symbols in a `public/` directory or an `api/` directory at the project root — these are likely public-facing
- Do NOT flag symbols exported from `index.ts`/`index.js` barrel files without also verifying the barrel itself is unused — a barrel that IS imported makes all its re-exports live
- Do NOT recommend deletion — always recommend quarantine to `_deprecated/` with a comment

Run analysis on: $ARGUMENTS (or full repo if empty).
