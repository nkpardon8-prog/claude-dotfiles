---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Check for frontend architecture pattern violations (stack-gated: HAS_APP_ROUTER)
argument-hint: "[scope]"
---

# /god-review:principles:architecture-frontend — Frontend Architecture

**Stack gate:** This principle self-skips if `HAS_APP_ROUTER` is not detected.

## Stack Gate Check

In Phase 1, run:
```bash
HAS_APP_ROUTER=$(find . -name "page.tsx" -o -name "page.jsx" -o -name "layout.tsx" 2>/dev/null | grep -v node_modules | grep -v .git | head -1)
```

If `HAS_APP_ROUTER` is empty: output "(skipped — Next.js App Router not detected)" and exit.

## The Principles

### Thin Pages + Orchestration Hooks

Pages should be JSX composition only. All business logic, state management, and event handlers live in orchestration hooks (e.g., `usePageName`, `useFeatureName`).

### Underscore-Prefix Locality

- `_components/` — Components used only by this page/feature
- `_hooks/` — Hooks used only by this page/feature
- `_types/` — Types used only by this page/feature
- `_providers/` — Providers used only by this page/feature

Shared code (used by 2+ features) goes in the project's shared `src/components/`, `src/hooks/`, etc. (detect actual shared paths from project structure or AGENTS.md).

### Hooks Never Return JSX

Hooks return data and callback functions only. Components render JSX. A hook that returns a JSX element is both patterns mixed — a violation of React's rules of hooks and a clarity failure.

### TanStack Query Patterns

See also `tanstack-query.md` principle. At minimum here:
- Query keys must include ALL dependencies
- Mutations must invalidate related queries on success
- Use `enabled` option for conditional queries; never call hooks conditionally

## Why This Matters

- Failure mode #14 (overcomplication): fat pages with co-mingled logic, state, and rendering are the frontend equivalent of monolithic controllers
- Failure mode #7 (hallucination cascade): when patterns are inconsistent, agents copy whichever pattern they see first — fat pages beget more fat pages
- Failure mode #6 (single-agent reasoning): dense pages with embedded business logic are harder for reviewing agents to reason about correctly
- Failure mode #2 (churn/oscillation): logic placed in pages tends to get extracted and re-embedded across review rounds

Reference: `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md` failure modes #2, #6, #7, #14

## Phase 1: Gather Context

- Read `tmp/god-review/context-package.md` if it exists; otherwise auto-generate minimal context
- Read repo `AGENTS.md` / `CLAUDE.md` if present
- Read frontend-specific AGENTS.md/CLAUDE.md (detect path from project structure)
- Run stack gate check above — if `HAS_APP_ROUTER` is empty, skip and output "(skipped)"
- Get scope: `$ARGUMENTS` or frontend files from `git diff main...HEAD --name-only`

```bash
git rev-parse --abbrev-ref HEAD
# Frontend files only — adjust pattern for this project's structure
git diff main...HEAD --name-only 2>/dev/null | grep -E "(app/|webapp/|frontend/|web/|client/)" | head -100 || true
git diff main...HEAD 2>/dev/null || true
```

Use TodoWrite to track each file to analyze.

## Phase 2: Identify Candidates

### 2.1 Page Pattern (page.tsx / page.jsx files)

For each page file changed:

**Check for thin composition:**
```typescript
// CORRECT — thin page
'use client';

export default function FeaturePage() {
  const { items, isLoading, handleAction } = useFeaturePage();
  if (isLoading) return <LoadingSpinner />;
  return (
    <PageLayout>
      <FeatureList items={items} onAction={handleAction} />
    </PageLayout>
  );
}

// WRONG — fat page with inline logic
'use client';

export default function FeaturePage() {
  const [items, setItems] = useState([]);
  const [isLoading, setIsLoading] = useState(true);
  useEffect(() => {
    fetch('/api/items').then(res => res.json()).then(setItems);
    setIsLoading(false);
  }, []);
  // 30+ more lines of logic...
  return <div>...</div>;
}
```

**Check for 'use client' directive** — most interactive pages using hooks or event handlers need it.

**Study the codebase's canonical exemplar** — check AGENTS.md or CLAUDE.md if declared, otherwise find a representative existing page file.

### 2.2 Orchestration Hook Pattern

For orchestration hooks (`usePageName.ts`, `useFeatureName.ts`):

**Check for proper structure:**
- Data hooks
- Local state
- Mutations
- Handlers
- Return object (NEVER JSX)

```typescript
// CORRECT
export function useFeaturePage() {
  const { data: items, isLoading } = useItems();
  const [filter, setFilter] = useState('all');
  const { mutate: createItem } = useCreateItem();
  const handleCreate = useCallback((data) => createItem(data), [createItem]);
  return { items, isLoading, filter, setFilter, handleCreate };
}

// WRONG — returns JSX
export function useFeaturePage() {
  // ...
  return <div>This is wrong</div>;
}
```

**Study the codebase's canonical exemplar** — check AGENTS.md or CLAUDE.md if declared.

### 2.3 Underscore-Prefix Locality

**Check file locations:**
```
# Correct structure (adapt paths for this project)
app/feature/
  page.tsx
  _components/     # Local to this page/feature
    FeatureList.tsx
  _hooks/          # Local to this page/feature
    useFeaturePage.ts

src/components/    # Shared across features (detect actual shared path)
  Button.tsx
```

**Flag violations:**
- Shared component (used by 2+ features) in a local `_components/` folder
- Local component (used by only 1 feature) in the shared components directory
- Underscore folders placed in the shared `src/` directory

### 2.4 TanStack Query Patterns

**Check query keys:**
```typescript
// CORRECT — all dependencies in key
const { data } = useQuery({
  queryKey: ['feature', workspaceId, filter],
  queryFn: () => fetchFeature(workspaceId, filter),
});

// WRONG — missing dependency
const { data } = useQuery({
  queryKey: ['feature'],
  queryFn: () => fetchFeature(workspaceId, filter),
});
```

**Check mutation invalidation:**
```typescript
// CORRECT — invalidates on success
const { mutate } = useMutation({
  mutationFn: createItem,
  onSuccess: () => {
    queryClient.invalidateQueries({ queryKey: ['feature'] });
  },
});

// WRONG — no invalidation
const { mutate } = useMutation({ mutationFn: createItem });
```

**Check conditional queries:**
```typescript
// CORRECT
const { data } = useQuery({
  queryKey: ['item', itemId],
  queryFn: () => fetchItem(itemId),
  enabled: !!itemId,
});

// WRONG — conditional hook call
if (itemId) { const { data } = useQuery(...); }
```

### 2.5 Hook Return Values

Confirm that hooks never return JSX elements — grep for hooks that contain `return <` or `return (` followed by JSX tags.

## Phase 3: Deep Analysis

For each candidate:
1. Read the file and find the codebase's canonical exemplar for comparison
2. Assess severity — a 5-line page with one `useQuery` inline is different from a 100-line page with 8 state variables
3. For locality violations: confirm the actual usage count (is the component really shared, or is it local?)

## Phase 4: Generate Report

Markdown table format:
| Location | Issue | Severity | Recommendation | Evidence |

Full report structure:

```markdown
# Frontend Architecture Report

**Scope:** {scope or "full repo"}
**Status:** {PASS | WARN | FAIL | skipped}

## Summary

{One sentence assessment of frontend architecture compliance}

## Patterns Checked

- [x] Thin pages (JSX only)
- [x] Orchestration hooks
- [x] Underscore-prefix locality
- [x] TanStack Query patterns
- [x] Hooks return data only (no JSX)
- [x] 'use client' directives

## Violations Found

### Critical (Must Fix)

| Location | Pattern Violated | Fix | Severity |
|----------|------------------|-----|----------|
| {file:line} | {pattern} | {how to fix} | definite/likely |

### Warnings

| Location | Issue | Recommendation | Severity |
|----------|-------|----------------|----------|
| {file:line} | {description} | {suggestion} | investigate |

## Page Issues

| Page | Issue | Fix |
|------|-------|-----|
| {file} | {business logic in page / missing orchestration hook} | {fix} |

## Hook Issues

| Hook | Issue | Fix |
|------|-------|-----|
| {file} | {returns JSX / missing query invalidation / wrong query keys} | {fix} |

## Locality Issues

| File | Current Location | Should Be |
|------|------------------|-----------|
| {file} | {current path} | {correct path based on usage count} |

## TanStack Query Issues

| Location | Issue | Fix |
|----------|-------|-----|
| {file:line} | {missing dep in key / no invalidation / conditional call} | {fix} |

## Exemplars to Study

The codebase's canonical exemplar — check AGENTS.md or CLAUDE.md if declared. Otherwise:
- A well-structured thin page in the codebase's frontend directory
- A well-structured orchestration hook co-located with a page
- Examples of correct locality: local `_components/` vs shared components directory

## Recommendations

1. {specific action with file reference}
2. {specific action with file reference}
```

## Phase 5: Output

1. Save to `tmp/god-review/principles/architecture-frontend-findings.md`
2. Print PASS/WARN/FAIL/skipped summary with count of violations by pattern

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- PASS: All frontend patterns followed correctly; pages are thin; hooks don't return JSX; locality is correct; query patterns are sound
- WARN: Minor deviations — slightly fat page with isolated logic that could stay, isolated missing invalidation, borderline locality
- FAIL: Core patterns violated — business logic in pages, hooks returning JSX, systematic wrong locality, missing query invalidation on mutations

## Known Issues (don't re-report)

Loaded from `tmp/god-review/context-package.md` known-issues section if present. Skip any finding already in `tmp/god-review/state.json` from prior rounds.

Run analysis on: $ARGUMENTS (or full frontend file set if empty).
