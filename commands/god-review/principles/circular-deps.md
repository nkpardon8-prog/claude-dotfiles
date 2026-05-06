---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Check for circular dependencies and late imports past line 40
argument-hint: "[scope]"
---

# /god-review:principles:circular-deps — Circular Dependencies

## The Principle

Imports should appear at the top of files (within the first 40 lines). Late imports indicate circular dependencies, missing dependency injection, or structural architectural smells. This codebase has **zero tolerance for late imports past line 40**.

**What counts as a late import:**
- ES6 static imports (`import ... from`) after line 40
- CommonJS `require()` after line 40
- Non-lazy `await import(...)` mid-function (not in `React.lazy` or Next.js `dynamic()` context)

**Acceptable late imports (do NOT flag):**
- `const Modal = dynamic(() => import('@/components/Modal'), { ssr: false })` — Next.js dynamic for code splitting
- `const Chart = React.lazy(() => import('@/components/Chart'))` — React.lazy for code splitting
- `import type { T } from '...'` anywhere — type-only imports have no runtime effect

## Why This Matters

- Failure mode #1 (error accumulation): circular dependencies cause undefined module references at runtime — silent until a specific import order is triggered
- Failure mode #7 (hallucination cascade): agents diagnosing circular dep crashes often introduce more late imports as "fixes" without understanding the underlying structure
- Failure mode #5 (no rollback): circular dep bugs are notoriously hard to revert because the symptom appears far from the cause
- Runtime errors from circular deps can appear non-deterministically based on module load order
- Build tools may fail silently or produce incorrect output with circular deps
- Testing becomes difficult — mocking fails unpredictably with circular deps

Reference: `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md` failure modes #1, #5, #7

## Phase 1: Gather Context

- Read `tmp/god-review/context-package.md` if it exists; otherwise auto-generate minimal context
- Read repo `AGENTS.md` / `CLAUDE.md` if present
- Get scope: `$ARGUMENTS` or full repo via `git diff main...HEAD --name-only` or full file list

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"
git rev-parse --abbrev-ref HEAD
git diff main...HEAD --name-only 2>/dev/null || find . -name "*.tsx" -o -name "*.ts" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.go" | grep -v node_modules | grep -v .git | head -200
git diff main...HEAD 2>/dev/null || true
```

Use TodoWrite to track files to analyze.

## Phase 2: Identify Candidates

### 2.1 Quick Scan for Late Imports

```bash
# Find potential late imports in changed or scoped files (TypeScript/JavaScript)
for file in $(git diff main...HEAD --name-only 2>/dev/null | grep -E '\.(ts|tsx|js|jsx)$'); do
  awk 'NR > 40 && /^import .* from|require\(/' "$file" 2>/dev/null && printf "^^^ %s\n" "$file"
done

# Python late imports (inside functions/classes)
for file in $(git diff main...HEAD --name-only 2>/dev/null | grep '\.py$'); do
  awk 'NR > 40 && /^\s+import |^\s+from .* import/' "$file" 2>/dev/null && printf "^^^ %s\n" "$file"
done
```

### 2.2 Read Each Candidate File

For each file flagged by the scan, read it fully and scan line by line after line 40.

**After line 40, flag any:**

1. ES6 static imports:
   ```
   /^import\s+.*\s+from\s+['"].*['"];?$/
   ```

2. CommonJS require:
   ```
   /require\s*\(['"].*['"]\)/
   ```

3. Dynamic imports (non-lazy):
   ```
   /await\s+import\s*\(/  (not inside React.lazy or dynamic() call)
   ```

4. Python mid-function imports:
   ```
   /^\s{4,}import |^\s{4,}from .* import/  (inside a function body, not top-level)
   ```

### 2.3 Exceptions — Do NOT Flag

```typescript
// ACCEPTABLE — Next.js dynamic for code splitting
const Modal = dynamic(() => import('@/components/Modal'), { ssr: false });

// ACCEPTABLE — React.lazy for code splitting
const Chart = React.lazy(() => import('@/components/Chart'));

// ACCEPTABLE — type-only import (no runtime effect)
import type { SomeType } from '@/types';
```

### 2.4 Diagnose Root Cause

For each late import found:

**Check if inside a constructor (circular dep pattern):**
```typescript
class ServiceA {
  constructor() {
    // Line 55 — Circular dependency!
    const { ServiceB } = require('./service-b');
    this.b = new ServiceB();
  }
}
```
→ Root cause: Module A needs B, B needs A. Fix: dependency injection or extract shared code.

**Check if conditional:**
```typescript
async function handleRequest() {
  if (needsParser) {
    const { parser } = await import('@/utils/parser'); // Line 60 — smell
  }
}
```
→ Root cause: Dependency should be injected or imported at top.

**Check if inside a plain function (not code splitting):**
```typescript
function processData() {
  const { transform } = require('@/utils/transform'); // Line 70 — wrong
}
```
→ Root cause: Should be a top-level import.

## Phase 3: Deep Analysis

For each confirmed late import:
1. Trace the import chain — does A → B → A exist?
2. Identify whether DI, extract-shared-module, or lazy-resolver is the right fix
3. Assess risk: is this in a hot path, test-only code, or rarely executed branch?

## Phase 4: Generate Report

Markdown table format:
| Location | Issue | Severity | Recommendation | Evidence |

Full report structure:

```markdown
# Circular Dependency Report

**Scope:** {scope or "full repo"}
**Status:** {PASS | WARN | FAIL}

## Summary

{One sentence assessment}

## Late Imports Found

### Critical (Must Fix)

| File | Line | Import | Root Cause | Severity |
|------|------|--------|------------|----------|
| {file} | {line} | `{import statement}` | {circular dep / missing DI / structural smell} | definite/likely |

### Acceptable (Lazy Loading — Do Not Fix)

| File | Line | Import | Reason Acceptable |
|------|------|--------|-------------------|
| {file} | {line} | `{import}` | Next.js dynamic / React.lazy / type-only |

## Circular Dependency Analysis

### Detected Cycles

```
{file A} → imports → {file B} → imports → {file A}
```

### Fix Options

**Option 1: Dependency Injection**
- Before: constructor imports at runtime to break the cycle
- After: inject the dependency from the outside

**Option 2: Extract Shared Code**
- Before: A imports from B, B imports from A
- After: both import from a new shared module C

**Option 3: Lazy Resolver (last resort)**
- Use a DI container or service locator that resolves on first use

## Recommended DI Pattern

Find the project's service bootstrap or DI wiring file (where services are composed). Check AGENTS.md or CLAUDE.md if it exists to locate it.

## Files to Refactor

| File | Issue | Recommended Fix |
|------|-------|-----------------|
| {file} | {late import description} | {specific fix approach} |

## Recommendations

1. {specific action with file reference}
2. {specific action with file reference}
```

## Phase 5: Output

1. Save to `tmp/god-review/principles/circular-deps-findings.md`
2. Print PASS/WARN/FAIL summary with count of late imports and identified circular cycles

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- PASS: No late imports found (excluding acceptable lazy loading); all imports at top of files
- WARN: Late imports found in test files or rarely-executed non-critical paths; no confirmed circular dependency cycles
- FAIL: Late imports in production code — any confirmed circular dependency cycle is automatic FAIL regardless of whether it currently manifests at runtime

## Known Issues (don't re-report)

Loaded from `tmp/god-review/context-package.md` known-issues section if present. Skip any finding already in `tmp/god-review/state.json` from prior rounds.

Run analysis on: $ARGUMENTS (or full repo if empty).
