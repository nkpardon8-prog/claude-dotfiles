---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Check for TanStack Query pattern violations (stack-gated: HAS_TANSTACK_QUERY)
argument-hint: "[scope]"
---

# /god-review:principles:tanstack-query — TanStack Query Patterns

**Stack gate:** This principle self-skips if `HAS_TANSTACK_QUERY` is not detected.

## Stack Gate Check

In Phase 1, run:
```bash
HAS_TANSTACK_QUERY=$(grep -r "@tanstack/react-query\|@tanstack/query" package.json packages/*/package.json apps/*/package.json 2>/dev/null | head -1)
```

If `HAS_TANSTACK_QUERY` is empty: output "(skipped — @tanstack/react-query not detected)" and exit.

## The Principles

### 1. Global Configuration — No Per-Query Overrides

The global `QueryClient` defaults handle freshness. Do NOT add per-query overrides unless the exception is truly warranted.

**Rules:**
- Do NOT add per-query `staleTime` unless data is truly immutable (write-once, content-addressed). Only valid constant: `STALE_TIME.IMMUTABLE` (`Infinity`).
- Do NOT add per-query `refetchOnWindowFocus` or `refetchOnReconnect` — global defaults apply.
- Do NOT add `retry` overrides unless the query has documented special failure semantics.

### 2. Domain-Specific Hierarchical Query Key Factories

Every domain gets its own `<domain>Keys.ts` factory with hierarchical, self-referential keys. Never use raw string arrays directly in query options.

**Required structure:**
```typescript
export const domainKeys = {
  all: ['domain'] as const,
  lists: (workspaceId, params?) => [...domainKeys.all, 'list', workspaceId ?? null, normalizeParams(params)] as const,
  detail: (id) => [...domainKeys.all, 'detail', id ?? null] as const,
};
```

Find existing domain factory files: search for `*Keys.ts` in the frontend's hooks directory.

### 3. Cache Invalidation — Predicate Helpers for Parameterized Lists

`invalidateQueries({ queryKey: factoryCall(workspaceId) })` includes trailing default params — it misses other param variants. Use predicate-based invalidation helpers for parameterized lists.

```typescript
// BAD — misses param variants
queryClient.invalidateQueries({ queryKey: domainKeys.lists(workspaceId) });

// GOOD — predicate matches all variants
invalidateWorkspaceDomain(queryClient, workspaceId);
```

### 4. Optimistic Updates via `onMutate`

All optimistic state changes happen inside `useMutation`'s `onMutate` with snapshot + rollback. Never mutate cache from component handlers or `useEffect`.

**Required 6-step pattern:**
1. `cancelQueries` — prevent race conditions
2. Snapshot current state
3. Optimistically update cache
4. Return context for rollback
5. `onError` — restore from snapshot
6. `onSettled` — invalidate to ensure server truth

### 5. `initialData` Cache Seeding for List-to-Detail Navigation

Detail queries should use `initialData` to pull from list cache for instant loading (no spinner on navigation).

### 6. WebSocket Cache Updates

WebSocket handlers can update cache via `setQueryData` (server-sourced data, not optimistic). Pair with debounced invalidation. On reconnect: use predicate-based helpers, not specific key variants.

### 7. ESLint Suppression Format

Any `@tanstack/query/exhaustive-deps` suppression must include a `--` explanation:
```typescript
// eslint-disable-next-line @tanstack/query/exhaustive-deps -- workspaceId is for API auth only; id is globally unique
```

### 8. Prefetching Key Matching

Prefetch keys must be **identical** to the page hook's query keys. Mismatched keys create a separate cache entry — the prefetch is wasted.

## Why This Matters

- Failure mode #7 (hallucination cascade): raw string query keys cause silent cache invalidation failures — data appears stale with no errors, agents invent explanations
- Failure mode #2 (churn/oscillation): prefix matching trap and missing invalidation cause data refresh issues that agents "fix" by adding staleTime overrides → more oscillation
- Failure mode #1 (error accumulation): missing `onMutate` rollback causes UI to show stale optimistic state after server errors — compounds across multiple mutations
- These bugs are invisible in development and only surface under real-world latency or failure conditions

Reference: `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md` failure modes #1, #2, #7

## Phase 1: Gather Context

- Read `tmp/god-review/context-package.md` if it exists; otherwise auto-generate minimal context
- Read repo `AGENTS.md` / `CLAUDE.md` if present
- Run stack gate check above — if `HAS_TANSTACK_QUERY` is empty, skip and output "(skipped)"
- Read `tmp/research/tanstack-query-guidelines.md` if it exists for project-specific context
- Get scope: `$ARGUMENTS` or frontend files from `git diff main...HEAD --name-only`

```bash
git rev-parse --abbrev-ref HEAD
git diff main...HEAD --name-only 2>/dev/null | grep -E '\.(ts|tsx)$' | head -100 || true
git diff main...HEAD 2>/dev/null || true
```

Find existing domain factory files:
```bash
find . -name "*Keys.ts" -not -path "*/node_modules/*" -not -path "*/.git/*" | head -20
```

Use TodoWrite to track each violation to investigate.

## Phase 2: Check Global Config Violations

### 2.1 Per-Query `staleTime` Overrides

Search changed files for `staleTime`. For each occurrence:
- Is it `STALE_TIME.IMMUTABLE` for truly immutable data? → OK
- Any other value? → FAIL: remove it, global `staleTime: 0` handles freshness

### 2.2 Per-Query `refetchOnWindowFocus` / `refetchOnReconnect`

Any per-query override → FAIL: remove it, these are set globally.

### 2.3 Per-Query `retry` Overrides

Flag unless the query has documented special failure semantics.

## Phase 3: Check Query Key Violations

### 3.1 Raw String Query Keys

Search diff for raw arrays in query options (`queryKey: ['`). For each:
- Factory exists for domain → FAIL: should use factory
- No factory exists → WARN: factory should be created

### 3.2 `qk` Flat Object for Domain-Owned Keys

If changed files use a flat `qk` object for keys that belong to an existing domain factory → FAIL.

### 3.3 Missing Domain Factory

If new hooks introduced for a domain without its own `<domain>Keys.ts`, and the domain has 3+ query key usages → WARN.

### 3.4 Key Structure Consistency

For each query key: spreads from base `all` key? normalizes params (undefined → null)? uses `as const`? arrays sorted for deterministic keys?

## Phase 4: Check Cache Invalidation Violations

### 4.1 Prefix Matching Trap (CRITICAL)

Search for `invalidateQueries` in changed files. For each call using a factory with params (e.g., `domainKeys.lists(wsId)`): does that factory produce trailing default params? If yes → FAIL: misses other param variants.

### 4.2 Missing Predicate Helper

For domains with parameterized lists: does `<domain>Invalidation.ts` exist with predicate-based helpers?

### 4.3 Mismatched Keys

For each invalidation: does the targeted key share a common prefix with the corresponding `useQuery`/`useInfiniteQuery` key?

## Phase 5: Check Optimistic Update Violations

### 5.1 Cache Mutations Outside `onMutate`

Search for `queryClient.setQueryData` outside of `onMutate`, `onSuccess` server response caching, or WebSocket handlers → flag.

### 5.2 Missing Rollback

For each `onMutate`, verify all 6 steps are present.

### 5.3 Missing `cancelQueries`

For each `onMutate`, verify `cancelQueries` is called before reading cache state.

## Phase 6: Check Cache Seeding

### 6.1 Detail Hooks Without `initialData`

New detail query hooks with an existing list query — does it use `initialData` from list cache?

### 6.2 `placeholderData` Instead of `initialData`

Warn: `initialData` is preferred — it caches and counts as "real" data.

## Phase 7: Check ESLint Suppression Format

Any `eslint-disable.*tanstack` without `--` explanation → WARN.

## Phase 8: Check Prefetching Key Matching

`prefetchQuery`/`prefetchInfiniteQuery` keys must be identical to the page hook's keys.

## Phase 9: Check WebSocket Cache Update Patterns

`setQueryData` in WebSocket handlers must be paired with debounced invalidation. Reconnect handlers must use predicate-based helpers.

## Phase 10: Generate Report

Markdown table format:
| Location | Issue | Severity | Recommendation | Evidence |

Full report structure:

```markdown
# TanStack Query Patterns Report

**Scope:** {scope or "full repo"}
**Status:** {PASS | WARN | FAIL | skipped}

## Summary

{One sentence assessment of TanStack Query pattern adherence}

## Global Config Violations

| Location | Override | Rule | Severity |
|----------|---------|------|----------|
| {file:line} | `staleTime: 30000` | Remove — global handles freshness | definite |

## Query Key Violations

### Raw String Keys

| Location | Raw Key | Should Use | Severity |
|----------|---------|------------|----------|
| {file:line} | `['domain', id]` | `domainKeys.detail(id)` | definite |

### Missing Domain Factory

| Domain | Key Count | Recommendation |
|--------|-----------|----------------|
| {domain} | {count} | Create `domainKeys.ts` factory |

## Cache Invalidation Violations

### Prefix Matching Trap (CRITICAL)

| Location | Invalidation Key | Misses | Severity |
|----------|-----------------|--------|----------|
| {file:line} | `domainKeys.lists(wsId)` | Variants with non-default params | definite |

### Mismatched Keys (CRITICAL)

| Invalidation | Targets | Query Uses | Match? |
|-------------|---------|------------|--------|
| {file:line} | {key} | {key} | no |

## Optimistic Update Violations

| Location | Missing Step | Severity |
|----------|-------------|----------|
| {file:line} | {no snapshot/no onError rollback/no cancelQueries} | definite/likely |

## Cache Seeding Violations

| Hook | Has List Query? | Has `initialData`? | Severity |
|------|-----------------|-------------------|----------|
| {hook} | yes | no | investigate |

## ESLint Suppression Issues

| Location | Issue |
|----------|-------|
| {file:line} | Missing `--` explanation in suppression |

## Recommendations

1. {specific action with file reference}
2. {specific action with file reference}

## Pattern Health

- Query key factory coverage: {X}/{Y} domains have dedicated factories
- Optimistic update compliance: {X}/{Y} mutations follow full 6-step pattern
- Cache seeding coverage: {X}/{Y} detail hooks use initialData
- Global config compliance: {X}/{Y} queries use global defaults
```

## Phase 11: Output

1. Save to `tmp/god-review/principles/tanstack-query-findings.md`
2. Print PASS/WARN/FAIL/skipped summary with count of violations by category; call out prefix matching trap and mismatched keys explicitly

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- PASS: All TanStack Query patterns followed correctly; no raw string keys; no per-query staleTime; mutations use predicate invalidation helpers; optimistic updates have full 6-step pattern
- WARN: Minor deviations — missing `as const`, missing `initialData` on low-traffic hook, ESLint suppression without explanation
- FAIL: Per-query staleTime/refetchOnWindowFocus overrides; raw string keys where factory exists; cache mutations outside `onMutate`; mismatched invalidation keys; factory calls for parameterized list invalidation (prefix matching trap)

## Known Issues (don't re-report)

Loaded from `tmp/god-review/context-package.md` known-issues section if present. Skip any finding already in `tmp/god-review/state.json` from prior rounds.

Run analysis on: $ARGUMENTS (or full frontend file set if empty).
