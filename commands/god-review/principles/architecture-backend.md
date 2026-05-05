---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Check for backend architecture pattern violations (stack-gated: HAS_AUTHED_HANDLER OR HAS_BACKEND_PROJECT)
argument-hint: "[scope]"
---

# /god-review:principles:architecture-backend — Backend Architecture

**Stack gate:** This principle self-skips if neither `HAS_AUTHED_HANDLER` nor `HAS_BACKEND_PROJECT` is detected.

## Stack Gate Check

In Phase 1, run:
```bash
HAS_AUTHED_HANDLER=$(grep -r "authenticatedHandler\|requireAuth\|withAuth\|@authenticated\|authMiddleware\|protectedRoute\|authenticated_route\|login_required\|requires_auth" --include="*.ts" --include="*.js" --include="*.py" --include="*.go" --include="*.rs" --include="*.java" -l 2>/dev/null | grep -v node_modules | head -1)
HAS_BACKEND_PROJECT=$(ls main.go go.mod Cargo.toml requirements.txt pyproject.toml setup.py 2>/dev/null | head -1; find . -maxdepth 3 -name "*.go" -o -name "*.py" -o -name "*.rs" -o -name "*.java" 2>/dev/null | grep -v node_modules | grep -v .git | head -1)
```

If both `HAS_AUTHED_HANDLER` and `HAS_BACKEND_PROJECT` are empty: output "(skipped — no backend project detected)" and exit.

## The Principles

### Authenticated Route / Handler Wrapper Pattern

Authenticated routes should use a project-specific wrapper that handles authentication, populates user context, and catches errors automatically. The wrapper name varies by project — search the codebase for the established pattern.

Common names include: `authenticatedHandler`, `requireAuth`, `withAuth`, `@authenticated` (decorator), `authMiddleware`, `protectedRoute`, `login_required` (Python), `requires_auth` (Go/Python), `Auth()` (Go middleware).

**Controllers/handlers using the wrapper should NOT have manual try/catch blocks** — the wrapper is responsible for error handling. Find the project's actual wrapper before flagging violations.

### Controller/Handler — Service Separation

- Controllers/handlers: Extract params, delegate to services, return response
- Services: Contain ALL business logic, database queries, data transformation
- No business logic in controllers. No database queries in controllers.

This applies across languages:
- TypeScript/JavaScript: controllers call services
- Python: views/endpoints call services or use cases
- Go: handlers call service layer
- Rust: handlers call service/domain layer
- Java: controllers call service beans

### Service Layer Pattern

Services access data through a repository or ORM layer. Search the codebase for the established pattern — it may be a base class (`BaseService`, `Repository`), a function-based pattern (Go-style), or dependency injection (Java/Spring).

### Error Handling Pattern

Backend code should throw/return project-specific error types with proper status codes, not generic errors. Common names: `ApiError`, `AppError`, `HttpError`, `DomainError`, `ServiceError`. Search for custom error types in the codebase.

### Input Validation

Validate at API boundaries using the project's established validation library (Zod, Joi, Pydantic, `validator` struct tags in Go, Hibernate Validator in Java). Manual validation in controllers or services is a violation.

## Why This Matters

- Failure mode #1 (error accumulation): no auth wrapper = silent authentication bypass risk per future edit
- Failure mode #10 (full autonomy on irreversibles): auth code is in the hard-gate category — violations here are HUMAN_GATE findings
- Failure mode #6 (single-agent reasoning): without service layer separation, business logic scattered across controllers makes the codebase's intent opaque to reviewing agents
- Failure mode #13 (tangled commits): controller/service blur makes it impossible to review auth changes in isolation

Reference: `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md` failure modes #1, #6, #10, #13

## Phase 1: Gather Context

- Read `tmp/god-review/context-package.md` if it exists; otherwise auto-generate minimal context
- Read repo `AGENTS.md` / `CLAUDE.md` if present
- Read backend-specific AGENTS.md/CLAUDE.md (detect path from project structure)
- Run stack gate check above — if both signals empty, skip and output "(skipped)"
- Get scope: `$ARGUMENTS` or backend files from `git diff main...HEAD --name-only`

```bash
git rev-parse --abbrev-ref HEAD
# Backend files only — detect directory pattern from project structure
git diff main...HEAD --name-only 2>/dev/null | grep -E "(api|server|backend|cmd|internal|src|app)" | head -100 || true
git diff main...HEAD 2>/dev/null || true
```

**Discover the project's actual wrapper / base service / error type names** by reading existing files before evaluating any changed file. Do not assume specific names — they vary per project.

Use TodoWrite to track each file to analyze.

## Phase 2: Identify Candidates

### 2.1 Handler/Controller Pattern

For each handler/controller file in scope:

**Check for the project's authentication wrapper:**
```
# TypeScript example (substitute project's actual wrapper)
router.get('/', authenticatedHandler(async (req, res) => { ... }))

# Python example (substitute project's actual decorator)
@login_required
def my_view(request): ...

# Go example (substitute project's actual middleware)
r.With(authMiddleware).Get("/", myHandler)
```

**Check for manual try/catch in controllers when a wrapper is available:**
- If the project's wrapper exists and a controller has its own try/catch → flag as violation
- If the project has no wrapper → this is a WARN-level gap, not a controller violation

**Check for business logic in handlers:**
- Database queries directly in handler/controller body
- Complex data transformation in handler/controller body
- Multiple levels of conditional logic that should live in a service
- More than ~15-20 lines of logic beyond param extraction and response formatting

### 2.2 Service Layer

For each service file in scope:

**Check for direct database access bypassing the service/repository layer:**
```
# Detect based on project's ORM/DB driver — adapt pattern:
# TypeScript/Prisma: import { db } from '@/db' directly in a non-service file
# Python/SQLAlchemy: db.session.query(...) in a view
# Go: direct sql.DB usage in handler
```

**Check for the project's error type:**
- Generic `new Error('...')`, `errors.New(...)`, `Exception(...)`, `panic(...)` in service methods that should use the project's typed error class → flag as violation (if project has a custom error type)

**Check for single responsibility:**
- Each service should handle one domain concept
- Services calling other unrelated services extensively is a smell

### 2.3 Validator / Schema Layer

**Check for schema-based validation:**
- Is input validated at the API boundary using the project's validation library?
- Manual `if (!name || name.length < 1)` checks in handlers/services → flag as violation

### 2.4 Language-Specific Patterns

**Go:** Check for error returns being ignored (`_`), goroutines without cleanup paths in service code, context propagation (is `ctx` threaded through service calls?)

**Python:** Check for synchronous blocking I/O in async routes, missing `async`/`await` in FastAPI/Django async views, bare `except:` clauses in service code

**Rust:** Check for `.unwrap()` in non-test service code, unhandled `Result` types in service functions

**Java:** Check for missing `@Transactional` on service methods that modify data, business logic in `@Controller` vs `@Service` layer

## Phase 3: Deep Analysis

For each candidate:
1. Read the file and the canonical exemplar (check AGENTS.md or find a representative existing file)
2. Verify the violation against the project's actual pattern — a file may be old code predating the wrapper pattern, not a new violation
3. For auth-related violations: tag as HUMAN_GATE regardless of AUTO_FIX eligibility (per locked decision #9)

## Phase 4: Generate Report

Markdown table format:
| Location | Issue | Severity | Recommendation | Evidence |

Full report structure:

```markdown
# Backend Architecture Report

**Scope:** {scope or "full repo"}
**Stack:** {detected languages and frameworks}
**Status:** {PASS | WARN | FAIL | skipped}

## Summary

{One sentence assessment of backend architecture compliance}

## Patterns Discovered

- Authentication wrapper: `{name or "not found"}`
- Base service/repository: `{name or "not found"}`
- Error type: `{name or "not found"}`
- Validation library: `{name or "not found"}`

## Patterns Checked

- [x] Authentication wrapper usage
- [x] No manual try/catch in handlers when wrapper available
- [x] Handler/controller-service separation
- [x] Service layer error types
- [x] Schema-based validation at boundaries
- [x] Language-specific patterns ({languages})

## Violations Found

### Critical (Must Fix)

| Location | Pattern Violated | Fix | Severity |
|----------|------------------|-----|----------|
| {file:line} | {pattern} | {how to fix} | definite/likely |

### Warnings

| Location | Issue | Recommendation | Severity |
|----------|-------|----------------|----------|
| {file:line} | {description} | {suggestion} | investigate |

## Handler/Controller Issues

| File | Issue | Fix |
|------|-------|-----|
| {file} | {try/catch without wrapper / business logic / missing auth} | {fix} |

## Service Issues

| File | Issue | Fix |
|------|-------|-----|
| {file} | {bypassing service layer / generic error / multiple responsibilities} | {fix} |

## Exemplars to Study

The codebase's canonical exemplar — check AGENTS.md or CLAUDE.md if declared. Otherwise:
- A well-structured handler/controller in the codebase's API directory
- A well-structured service in the codebase's service directory
- A well-structured validator in the codebase's validation directory

## Recommendations

1. {specific action with file reference}
2. {specific action with file reference}
```

## Phase 5: Output

1. Save to `tmp/god-review/principles/architecture-backend-findings.md`
2. Print PASS/WARN/FAIL/skipped summary with count of violations by pattern

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- PASS: All backend patterns followed correctly; auth wrapper used where available; no business logic in handlers; service layer respected
- WARN: Minor deviations — slightly fat handler, missing documentation, patterns mostly correct with isolated exceptions
- FAIL: Core patterns violated — try/catch in handler despite wrapper being available; business logic in handler; services bypassing established data-access layer; missing input validation at boundaries

## Known Issues (don't re-report)

Loaded from `tmp/god-review/context-package.md` known-issues section if present. Skip any finding already in `tmp/god-review/state.json` from prior rounds.

Run analysis on: $ARGUMENTS (or full backend file set if empty).
