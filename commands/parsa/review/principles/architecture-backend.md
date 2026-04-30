---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Read, Grep, Glob, TodoWrite
description: Check for backend architecture pattern violations
---

# /review:architecture-backend - Backend Architecture Checker

You are reviewing code changes for violations of **backend architecture patterns**.

This skill is stack-agnostic. Discover the project's specific patterns by reading
its backend `CLAUDE.md`, `docs/`, and existing controller/service/validator files
before flagging violations.

## The Principles

### Authenticated Route Wrapper Pattern

Authenticated routes should use a project-specific wrapper that handles
authentication, populates the user context, and catches errors automatically.

Search the codebase for the project's wrapper. Common names include:
`authenticatedHandler`, `requireAuth`, `withAuth`, `@authenticated`,
`authMiddleware`, `protectedRoute`, etc.

**Controllers using the wrapper should NEVER have try/catch blocks** — the
wrapper is responsible for error handling.

### Base Service Pattern

Services that access the database typically extend a project-specific base
class (e.g. `BaseService`, `Repository`, `DataService`) that provides shared
infrastructure like `this.db` or `this.context`. Search the codebase for the
established pattern before flagging direct DB imports as violations.

### Error Class Pattern

Backend code should throw a project-specific error class with proper status
codes, not generic `Error`. Common names include `ApiError`, `AppError`,
`HttpError`, `DomainError`. Search for custom Error subclasses.

### Controller-Service Separation

- Controllers: Extract params, delegate to services, return response
- Services: Contain ALL business logic, database queries, validation

**No business logic in controllers. No database queries in controllers.**

## Phase 1: Gather Context

```bash
# Get current branch
git rev-parse --abbrev-ref HEAD

# Get changed files (backend only — adjust pattern for the current project)
git diff main...HEAD --name-only | grep -E "(api|server|backend)"

# Get full diff for backend
git diff main...HEAD -- "$(detect backend directory from project structure)"
```

Read the backend patterns:
- Backend `CLAUDE.md` (detect path from project structure — e.g. `apps/api/CLAUDE.md`, `server/CLAUDE.md`, `backend/CLAUDE.md`, etc.)
- Root `CLAUDE.md` — import conventions
- `docs/OVERVIEW.md` if present

**Discover the project's actual wrapper / base service / error class names**
before evaluating any file. Do not assume `authenticatedHandler`, `BaseService`,
or `ApiError` — those are example names.

## Phase 2: Check Backend Patterns

### 2.1 Controller Pattern

For each controller file changed:

**Check for the project's authenticated route wrapper:**
```typescript
// CORRECT (illustrative — substitute the project's wrapper name)
router.get('/', authenticatedHandler(async (req, res) => {
  const userId = req.user.id;
  // ...
}));

// WRONG - Missing wrapper, raw try/catch
router.get('/', async (req, res) => {
  try {
    // ...
  } catch (e) {
    // ...
  }
});
```

**Check for try/catch blocks:**
- Controllers should NOT have try/catch
- The project's wrapper handles errors

**Check for business logic:**
- Controllers should only: extract params, call service, return response
- Flag any: database queries, complex logic, data transformations

**Study exemplar:** Find a representative controller in the project's backend directory. Analyze the codebase to identify the established controller pattern (check backend CLAUDE.md and existing controller files).

### 2.2 Service Pattern

For each service file changed:

**Check for base service extension:**
```typescript
// CORRECT (illustrative — substitute the project's base class name)
export class FeedService extends BaseService {
  async getItems() {
    const items = await this.db.query...
  }
}

// WRONG - Direct db import that bypasses the base service pattern
import { db } from '@/shared/db';
export class FeedService {
  async getItems() {
    const items = await db.query...
  }
}
```

If the project does not use a base service pattern, skip this check.

**Check for the project's error class:**
```typescript
// CORRECT (illustrative — substitute the project's error class name)
throw new ApiError(404, 'Item not found');

// WRONG - Generic Error
throw new Error('Item not found');
```

If the project does not have a custom error class, skip this check.

**Check for single responsibility:**
- Each service should handle one domain concept
- Flag services doing unrelated things

**Study exemplar:** Find a representative service in the project's backend directory. Analyze the codebase to identify the established service pattern (check backend CLAUDE.md and existing service files).

### 2.3 Validator Pattern

For validator files:

**Check for schema-based validation (Zod, Joi, Yup, etc.):**
```typescript
// CORRECT (Zod illustration)
import { z } from 'zod';

export const createItemSchema = z.object({
  name: z.string().min(1),
  type: z.enum(['A', 'B']),
});

export type CreateItemInput = z.infer<typeof createItemSchema>;

// WRONG - Manual validation in controller/service
if (!name || name.length < 1) {
  throw new Error('Invalid name');
}
```

If the project uses a different validation library, swap in its idiom.

**Study exemplar:** Find a representative validator in the project's backend directory. Analyze the codebase to identify the established validation pattern (check backend CLAUDE.md and existing validator files).

### 2.4 Complex Service Organization

For large services:

**Check folder structure (typical pattern):**
```
services/
  recording/
    index.ts           # Main service, re-exports
    recording.service.ts
    helpers/
      audio-processor.ts
```

## Phase 3: Generate Report

```markdown
# Backend Architecture Report

**Branch:** {branch}
**Status:** {PASS | WARN | FAIL}

## Summary

{One sentence assessment of backend architecture compliance}

## Patterns Checked

- [x] Authenticated route wrapper usage
- [x] No try/catch in controllers
- [x] Controller-service separation
- [x] Base service extension (if project uses this pattern)
- [x] Custom error class usage (if project uses this pattern)
- [x] Schema-based validation
- [x] Single responsibility

## Violations Found

### Critical (Must Fix)

| Location | Pattern Violated | Fix |
|----------|------------------|-----|
| {file:line} | {pattern} | {how to fix} |

### Warnings

| Location | Issue | Recommendation |
|----------|-------|----------------|
| {file:line} | {description} | {suggestion} |

## Controller Issues

| Controller | Issue | Fix |
|------------|-------|-----|
| {file} | {try/catch found / business logic / missing wrapper} | {fix} |

## Service Issues

| Service | Issue | Fix |
|---------|-------|-----|
| {file} | {not extending base service / throwing generic Error / multiple responsibilities} | {fix} |

## Exemplars to Study

Analyze the project's codebase to find exemplar files. Read the backend CLAUDE.md and docs/OVERVIEW.md if they exist for established patterns. Look for:
- A well-structured controller in the backend directory
- A well-structured service in the backend directory
- A well-structured validator in the backend directory
- A complex service with subfolder organization (if applicable)

## Recommendations

1. {specific action with file reference}
2. {specific action with file reference}
```

## Phase 4: Output

1. Save report to `tmp/review-architecture-backend-{branch}.md`
2. Present summary:
   - PASS/WARN/FAIL status
   - Count of violations by pattern
   - Most critical issues

## Scoring Criteria

- **PASS**: All backend patterns followed correctly
- **WARN**: Minor deviations (e.g., missing documentation, but patterns correct)
- **FAIL**: Core patterns violated (try/catch in controller despite wrapper being available, business logic in controller, services bypassing the established base pattern)

## Pattern Quick Reference

(Substitute the project's actual wrapper / base / error names where shown.)

| Pattern | Correct | Wrong |
|---------|---------|-------|
| Controller auth | `<project wrapper>(async (req, res) => ...)` | `async (req, res) => { try {...} catch {...} }` |
| Controller logic | Delegates to service | Contains business logic |
| Service DB | `extends <project base service>`, uses `this.db` | Direct `db` import |
| Service errors | `throw new <project error class>(404, 'msg')` | `throw new Error('msg')` |
| Validation | Schema in validators/ | Manual validation in controller |

Run this analysis now on the current branch.
