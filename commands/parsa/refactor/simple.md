# Simple Refactor

**Read-only code quality analysis for small to medium changes.**

Safe to run anytime. Analyzes code against codebase patterns and writes refactor plan without modifying files.

## What This Does

Fast, focused code quality analysis that:
1. Classifies your changes (size, type, complexity)
2. Checks applicable patterns from CLAUDE.md files
3. Identifies code smells and pattern violations
4. Generates refactor plan with auto-fixable and manual issues
5. Writes plan to `./tmp/` for review

## When to Use

- **Small changes** (2-5 files, 50-200 lines)
- **Medium changes** (5-10 files, 200-500 lines)
- **Bug fixes** and **enhancements**
- Quick pre-PR quality check

For large features (>10 files, >500 lines), use `/deep-refactor` instead.

## Process

### 1. Classify Changes

```bash
git diff main --name-status
git diff main --numstat
git diff main --stat
```

**Determine:**
- **Size**: Tiny (<50) | Small (50-200) | Medium (200-500)
- **Type**: Bug Fix | Enhancement | Refactor
- **Complexity**: Trivial | Simple | Moderate
- **Layers**: Backend | Frontend | Both

### 2. Select Applicable Patterns

**Pattern Matrix:**
- **Tiny/Bug Fix** → Universal patterns only (imports, errors)
- **Small/Enhancement** → Universal + Basic architecture
- **Medium** → Universal + Architecture + Documentation (new files)

**Universal Patterns (Always Checked):**
- Zero relative imports (`../` is a bug)
- Proper error handling
- No commented-out code
- No TODOs without context

**Architecture Patterns (Medium+):**
- Controller-service separation
- BaseService extension
- TanStack Query for server state
- Proper hook patterns

### 3. Analyze Files

**Read changed files:**
```bash
git diff main --name-only
```

**Check patterns from:**

Find all CLAUDE.md files in the project: `find . -name 'CLAUDE.md' -not -path '*/node_modules/*'`

Read each one to understand the project's conventions for imports, backend architecture, frontend architecture, hook patterns, and component patterns.

**Study exemplar files:**

Find exemplar files by analyzing the codebase — look for well-structured controllers, services, pages, and hooks in the project's source directories (detect from project structure). Use these as the reference for what good code looks like in this specific project.

### 4. Detect Code Smells

**Universal Smells:**
- ❌ Relative imports (`../`, `../../`) - codebase has ZERO
- ❌ Long functions (>100 lines)
- ❌ Deep nesting (>3 levels)
- ❌ Magic numbers/strings
- ❌ Missing error handling
- ❌ Unused imports/variables
- ❌ Missing file-level documentation

**Backend Smells:**
- ❌ Business logic in controllers (should be in services)
- ❌ Controllers not using `authenticatedHandler` wrapper
- ❌ Services not extending `BaseService` when using DB
- ❌ Services not throwing `ApiError` for errors
- ❌ Multiple responsibilities in one service (SRP violation)

**Frontend Smells:**
- ❌ Business logic in pages (should be in hooks)
- ❌ Direct API calls instead of TanStack Query
- ❌ Hooks returning JSX (hooks return data/functions only)
- ❌ Missing `'use client'` directive
- ❌ Query mutations not invalidating related queries
- ❌ Local code NOT in underscore folders (`_components/`, `_hooks/`, `_types/`)
- ❌ Shared code used in only one place

**Configuration Object Pattern Violations:**
- ❌ Multiple similar functions (e.g., `formatTime`, `formatTimeCompact`) → consolidate with options
- ❌ Similar hooks with slight variations (e.g., `useGetItems`, `useGetArchivedItems`) → consolidate with options
- ❌ Importing multiple utilities for same purpose (e.g., `formatDistanceToNow` + custom `formatRelativeTime`)
- ❌ Duplicate interface/type definitions across files → single source of truth
- ❌ Similar services with minor differences → consolidate with configuration

### 5. Generate Report

Write refactor plan to `./tmp/simple-refactor-plan-[timestamp].md`:

```markdown
# Simple Refactor Plan

## Classification
- Size: [X]
- Type: [X]
- Complexity: [X]
- Patterns Applied: [List]

## Quality Score: X/10

## Issues Found

### Critical (Must Fix)
- [file:line] Description
  → Fix: How to fix
  → Auto-fixable: Yes/No

### Warnings (Should Fix)
- [file:line] Description
  → Suggestion: Improvement
  → Auto-fixable: Yes/No

### Info (Nice to Have)
- [file:line] Suggestion

## Auto-Fixable Issues: X

- Convert relative imports to @/ aliases
- Remove unused imports
- Fix formatting issues

## Manual Fixes Required: Y

- [Specific issues requiring human judgment]

## Pattern Compliance

✓/✗ Import conventions
✓/✗ Controller-service separation
✓/✗ TanStack Query usage
✓/✗ File documentation

## Recommendations

1. Run `/refactor-apply --plan=./tmp/simple-refactor-plan-[TS].md --auto-only`
2. Manually fix [specific issues]
3. Re-run `/simple-refactor` to verify improvements

## References

Similar patterns to study:
- [Exemplar file paths from codebase — find via analysis of project source directories]

Documentation:
- Find all CLAUDE.md files in the project: `find . -name 'CLAUDE.md' -not -path '*/node_modules/*'`
```

### 6. Show Next Steps

**Show results:**
```bash
📊 Analysis complete!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Plan written to: ./tmp/simple-refactor-plan-[timestamp].md

Quality Score: X/10 (target: 9.8)
Auto-fixable: X issues
Manual fixes: Y issues

Issues found:
- [Critical issues summary]
- [Warnings summary]

Would you like me to run `/refactor-apply` to implement the fixes?
(This will apply auto-fixable changes and guide you through manual fixes)
```

**IMPORTANT:** Always ask the user before proceeding with fixes. Do not automatically run refactor-apply.

## Critical Patterns (Verified from Codebase)

These patterns are enforced by reading the CLAUDE.md files:

1. **Zero relative imports** - Any `../` is a bug (verified via grep)
2. **authenticatedHandler wrapper** - Controllers never have try/catch
3. **BaseService extension** - Services using DB must extend BaseService
4. **TanStack Query for server state** - No direct API calls in components
5. **Thin pages + orchestration hooks** - Pages are JSX only
6. **Underscore-prefix locality** - `_components/`, `_hooks/`, `_types/` = local only
7. **File-level documentation** - All major files have top comment

## Command Arguments

- `--strict`: Treat Medium as Large (stricter enforcement)
- `--classify-as=<type>`: Override type classification
- `--size=<size>`: Override size classification

## Success Checklist

- [ ] Changes classified (size/type/complexity)
- [ ] Applicable patterns selected
- [ ] Changed files analyzed
- [ ] Code smells identified
- [ ] Auto-fixable vs manual separated
- [ ] Quality score calculated
- [ ] Plan written to ./tmp/
- [ ] No files modified (read-only)
- [ ] Next steps shown

---

**This command is read-only and safe.** It analyzes code against YOUR codebase's actual patterns (from CLAUDE.md files) and writes a refactor plan for you to review.

Run `/refactor-apply` after reviewing the plan to apply fixes.
