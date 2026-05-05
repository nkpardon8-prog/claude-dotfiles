---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Check for anti-patterns and convention violations, including XSS and log-injection
argument-hint: "[scope]"
---

# /god-review:principles:antipatterns — Anti-Patterns

## The Principle

Avoid async imports mid-code, unused conventions, established pattern violations, and security anti-patterns. Anti-patterns change as a codebase evolves — what was acceptable early may become dangerous at scale. Active research into the codebase's actual established patterns is required before flagging violations.

## Why This Matters

- Failure mode #18 (XSS/log-injection blind spot): models pass 82% on SQL injection but only 13-15% on XSS and log-injection; explicit checks are required because the default reviewer blind spot is exactly here
- Failure mode #1 (error accumulation): anti-patterns compound — each one makes the next anti-pattern easier to introduce
- Failure mode #12 (reward hacking): agents optimize for passing CI but introduce anti-patterns that are invisible to automated checks
- Failure mode #7 (hallucination cascade): agents copy anti-patterns from surrounding code, treating them as authoritative examples

Reference: `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md` failure modes #1, #7, #12, #18

## Phase 1: Gather Context

- Read `tmp/god-review/context-package.md` if it exists; otherwise auto-generate minimal context
- Read repo `AGENTS.md` / `CLAUDE.md` if present — established patterns and conventions are often declared there
- Get scope: `$ARGUMENTS` or full repo via `git diff main...HEAD --name-only` or full file list

```bash
git rev-parse --abbrev-ref HEAD
git diff main...HEAD --name-only 2>/dev/null || find . -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" -o -name "*.go" -o -name "*.rs" | grep -v node_modules | grep -v .git | head -200
git diff main...HEAD 2>/dev/null || true
```

Read the relevant AGENTS.md/CLAUDE.md files to understand established patterns before evaluating any file.

Use TodoWrite to track files to analyze.

## Phase 2: Identify Candidates

### 2.1 Import Anti-Patterns

**Check for:**
- Relative imports when path aliases should be used (detect aliases from tsconfig/pyproject/AGENTS.md)
- Dynamic imports where static would work
- Circular import risks (see also `circular-deps.md` principle)
- Importing from internal module paths instead of public exports

**Pattern (adapt to the project's configured aliases):**
```typescript
// CORRECT — use the project's configured path aliases
import { Something } from '@/modules/feature/service';

// WRONG — deep relative traversal
import { Something } from '../../../modules/feature/service';
```

### 2.2 Async/Await Anti-Patterns

**Check for:**
- Mixed async/await and `.then()` chains in the same function
- Missing error handling on async operations
- Async functions that don't need to be async
- `Promise.all` where sequential would be safer (or vice versa)
- Fire-and-forget async calls without error handling

### 2.3 Error Handling Anti-Patterns

**Check for:**
- Empty catch blocks (`catch (e) {}`)
- Catching and silently ignoring errors
- Inconsistent error handling patterns within the same module
- Missing try/catch on async operations that can throw
- Throwing generic `Error` instead of typed/domain errors

### 2.4 State Management Anti-Patterns (Frontend)

**Check for:**
- Direct state mutation
- State stored in the wrong location (local vs global vs server)
- Missing loading/error states for async operations
- Stale closure issues in hooks
- Missing dependency arrays in `useEffect`/`useCallback`/`useMemo`

### 2.5 API Anti-Patterns (Backend)

**Check for:**
- Business logic in controllers or route handlers (should be in services)
- Direct database access outside repository/service layer
- Missing input validation at system boundaries
- Inconsistent response formats within the same API surface
- Missing error responses or swallowed exceptions

### 2.6 Language-Specific Anti-Patterns

**TypeScript/JavaScript:**
- Using `any` type without justification
- Type assertions (`as`) that could be avoided with proper typing
- Missing return types on exported functions
- Overly complex generic types
- Using `!` non-null assertion excessively

**Python:**
- Bare `except:` clauses catching `BaseException`
- Mutable default arguments
- Using `type(x) == Y` instead of `isinstance`
- Missing type annotations on public functions

**Go:**
- Ignoring returned errors (`_, err := ...` followed by unused `err`)
- Panicking instead of returning errors
- Goroutine leaks (goroutine launched without cleanup path)

**Rust:**
- `.unwrap()` in non-test production code
- `unsafe` blocks without safety comments

### 2.7 File Structure Anti-Patterns

**Check for:**
- Files in wrong directories per the project's declared structure
- Naming inconsistencies (camelCase vs snake_case mixing within same layer)
- Missing index/barrel exports where expected by convention
- Components or modules in wrong abstraction layers

### 2.8 XSS and Log-Injection Checks (EXPLICIT — failure mode #18)

**XSS checks:**
- `innerHTML` assignment with user-controlled data (JS/TS): flag any `element.innerHTML = userInput` or equivalent
- `dangerouslySetInnerHTML` in React with unsanitized input
- Template literals interpolated into HTML strings without escaping
- `document.write(userInput)` or equivalent
- Missing `Content-Security-Policy` headers in server-rendered responses
- Absence of HTML encoding on user-supplied data rendered to the DOM

**Log-injection checks:**
- User-controlled data interpolated directly into log messages: `logger.info("User: " + req.body.name)` — attacker can inject newlines to forge log entries
- Structured loggers receiving unsanitized objects that contain user input as top-level keys
- Stack traces written to logs including raw request body values
- Absence of log sanitization for newline characters (`\n`, `\r`, `%0a`, `%0d`) in user-supplied fields

```typescript
// XSS — WRONG
element.innerHTML = user.bio;

// XSS — CORRECT
element.textContent = user.bio;

// Log injection — WRONG
logger.info(`Login attempt: ${req.body.username}`);

// Log injection — CORRECT
logger.info('Login attempt', { username: sanitizeForLog(req.body.username) });
```

## Phase 3: Deep Analysis

For each candidate:
1. Read the file in context — confirm the anti-pattern is genuinely present, not a false positive
2. Check AGENTS.md/CLAUDE.md for any explicit allowances or project-specific conventions
3. For XSS/log-injection: verify if there is upstream sanitization that the local code depends on; note if found but document the dependency

## Phase 4: Generate Report

Markdown table format:
| Location | Issue | Severity | Recommendation | Evidence |

Full report structure:

```markdown
# Anti-Pattern Report

**Scope:** {scope or "full repo"}
**Status:** {PASS | WARN | FAIL}

## Summary

{One sentence assessment}

## Conventions Checked

- [x] Import style (path aliases)
- [x] Async/await patterns
- [x] Error handling
- [x] State management (if frontend detected)
- [x] API patterns (if backend detected)
- [x] Language-specific patterns ({language(s) detected})
- [x] File structure
- [x] XSS injection checks (failure mode #18)
- [x] Log-injection checks (failure mode #18)

## Anti-Patterns Found

### Critical (Must Fix)

| Location | Anti-Pattern | Fix | Severity |
|----------|--------------|-----|----------|
| {file:line} | {description} | {how to fix} | definite/likely |

### Warnings

| Location | Anti-Pattern | Recommendation | Severity |
|----------|--------------|----------------|----------|
| {file:line} | {description} | {suggestion} | investigate |

## XSS / Log-Injection Issues (Explicit Scan — Failure Mode #18)

| Location | Type | User Input Source | Fix |
|----------|------|-------------------|-----|
| {file:line} | {XSS/log-injection} | {where the user data comes from} | {how to sanitize/escape} |

## Import Issues

| File | Current Import | Should Be |
|------|----------------|-----------|
| {file:line} | `{bad import}` | `{correct import}` |

## Error Handling Issues

| Location | Issue | Fix |
|----------|-------|-----|
| {file:line} | {description} | {how to fix} |

## Recommendations

1. {specific action with file reference}
2. {specific action with file reference}
```

## Phase 5: Output

1. Save to `tmp/god-review/principles/antipatterns-findings.md`
2. Print PASS/WARN/FAIL summary with count of anti-patterns by category; call out XSS/log-injection findings explicitly even if severity is low

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- PASS: Code follows established patterns and conventions; no XSS or log-injection vulnerabilities; no empty catch blocks or fire-and-forget async
- WARN: Minor deviations from conventions — shallow anti-patterns that don't present security risk and have low impact
- FAIL: Significant anti-patterns or convention violations; ANY XSS or log-injection vulnerability (regardless of count — even one is a FAIL); empty catch blocks swallowing errors; business logic in wrong layer

## Known Issues (don't re-report)

Loaded from `tmp/god-review/context-package.md` known-issues section if present. Skip any finding already in `tmp/god-review/state.json` from prior rounds.

Run analysis on: $ARGUMENTS (or full repo if empty).
