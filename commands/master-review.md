---
description: "Master Review — autonomous review + fix pipeline. Reviewers: 3 Claude Opus + 3 OpenAI Codex CLI (GPT-5.4) + 2 Antigravity (Google AI) agents in parallel. Fixer: Claude via /implement. Verification loop: 2 Claude Opus + 2 Codex + 2 Antigravity agents until 3 consecutive clean passes. Works on code or features."
argument-hint: "[file/dir/feature description, or blank for auto-detect]"
model: opus
---

# Master Review — Autonomous Review & Fix Pipeline

## Engines

- **Review — OpenAI Codex CLI (GPT-5.4):** 3 parallel agents in Phase 1, 2 parallel agents in every Phase 3 verification round. Invoked via `codex exec -s read-only --ephemeral` so Codex can read the repo but never writes.
- **Review — Antigravity (Google AI):** 2 parallel agents in Phase 1 (google-pro-1 and google-pro-2), 2 parallel agents in every Phase 3 verification round. Invoked via the Antigravity CLI in agent mode with isolated profiles. Read-only — findings only, never writes files. If Antigravity times out (30s) or is unavailable, agents are marked "unavailable" and the loop continues with the remaining agents.
- **Review — Claude Opus:** 3 parallel agents in Phase 1 (Deep Correctness, Architecture/Prod-Readiness, Security/Resilience), 2 parallel agents in every Phase 3 verification round.
- **Fix — Claude:** The synthesis agent (you) validates findings, builds a fix plan, and invokes `/implement` to apply code changes. Claude is the only writer. Codex and Antigravity never modify files.
- **Browser — Chrome DevTools MCP:** Active UI testing, console/network checks, Lighthouse, Core Web Vitals, regression detection after every fix round.

**Requires:** OpenAI Codex CLI on PATH (the `codex` binary). Install via OpenAI's official instructions (e.g. `npm i -g @openai/codex`). If `codex` is missing, Codex agents are marked "unavailable" and the loop continues with Claude Opus and Antigravity agents.

**Requires:** Antigravity app at `/Applications/Antigravity.app` with google-pro-1 and google-pro-2 profiles authenticated. Use `/antigravity open google-pro-1` to authenticate a profile. If Antigravity is missing or unauthenticated, those agents are marked "unavailable" and the loop continues with Claude Opus and Codex agents.

You are the Master Review orchestrator. You run an iterative multi-agent review-and-fix loop that does NOT stop until the codebase is genuinely clean. You coordinate Claude Opus agents, Codex (GPT-5.4) agents, a synthesis agent, and the /plan + /implement skills in a continuous improvement loop.

**This is NOT a report-only skill. You find issues AND fix them.**

---

## Phase 0: Connect Browser & Identify Target

### 0a: Connect to Chrome DevTools FIRST

**This must happen BEFORE anything else.** The user expects to fire this command and walk away, so establish the browser connection immediately.

1. Call `mcp__chrome-devtools__list_pages` to connect and see what's open.
2. If the app is already loaded (look for localhost:8080 or the project URL), select that page.
3. If no app page is open, call `mcp__chrome-devtools__navigate_page` to open `http://localhost:8080` (or whatever the frontend dev server URL is).
4. Take an initial snapshot: `mcp__chrome-devtools__take_snapshot` — this is your baseline for the UI state.
5. Check for console errors immediately: `mcp__chrome-devtools__list_console_messages` with types `["error", "warn"]`.
6. Store any existing console errors as `$BASELINE_CONSOLE_ERRORS` — these are pre-existing issues to include in the review.

**If the browser connection fails:** Continue with code-only review but note: "Browser DevTools unavailable — skipping live UI/network checks."

Output to user: **"Browser connected. [N] pages open. App loaded at [URL]. [N] existing console errors."**

### 0b: Determine review target

**If `$ARGUMENTS` is provided:**
- File or directory path → that's the review scope
- Feature description → that's the review focus (e.g., "the auth system", "scenario estimation flow")
- PR number or branch name → review that diff

**If `$ARGUMENTS` is empty:**
- Check conversation context for what the user is working on
- Check `git diff --stat` and `git status --short` for recent changes
- If nothing is obvious, stop and ask: "What should I review? Provide a file, directory, feature name, or description."

### 0c: Detect review mode

```bash
BASE_BRANCH=$(git rev-parse --verify main 2>/dev/null && echo "main" || (git rev-parse --verify master 2>/dev/null && echo "master" || echo ""))
WORKDIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

Determine MODE:
- Specific files/dirs → MODE="targeted"
- Feature description → MODE="feature" (agents search the codebase for relevant code)
- Branch diff exists (`git diff $BASE_BRANCH...HEAD --stat`) → MODE="branch"
- Uncommitted changes → MODE="uncommitted"
- No diff but feature description → MODE="feature"

### 0d: Build context package

Gather context that ALL agents will receive:
1. **Code scope**: The relevant files, diff, or feature area
2. **Project context**: Read CLAUDE.md and any relevant docs
3. **Git context**: Recent commits in the area (`git log --oneline -20 -- [relevant paths]`)
4. **Browser context**: Baseline console errors from 0a, initial page snapshot, any network failures seen during initial load

For large diffs (>500 lines), use `git diff --stat` + targeted reads of the most-changed files.

Store this as `$CONTEXT_PACKAGE` — every agent prompt includes it.

### 0e: Initial Browser Audit

Before agents launch, run a quick automated browser sweep:

1. **Console errors**: `mcp__chrome-devtools__list_console_messages` with types `["error", "warn"]` — log every error
2. **Network failures**: `mcp__chrome-devtools__list_network_requests` — scan for any requests with 4xx/5xx status codes or failed requests
3. **Lighthouse quick audit**: `mcp__chrome-devtools__lighthouse_audit` with mode "snapshot" — get accessibility, SEO, best practices scores
4. **Performance trace**: `mcp__chrome-devtools__performance_start_trace` with autoStop=true and reload=true — capture Core Web Vitals (LCP, INP, CLS)
5. **Screenshot**: `mcp__chrome-devtools__take_screenshot` with fullPage=true — save to `/tmp/master-review-baseline.png` for visual reference
6. **Key page navigation**: Navigate through 3-5 critical routes of the app (home, main feature pages, settings) and at each:
   - Take a snapshot (`take_snapshot`)
   - Check console for new errors (`list_console_messages`)
   - Check network for failed requests (`list_network_requests`)

Compile all browser findings into `$BROWSER_FINDINGS` — include these in agent context packages AND as standalone findings.

### 0f: Active Browser Bug Hunting

Don't just passively check — actively USE the app to find bugs:

1. **Test user flows**: Based on the review target, interact with the relevant features:
   - Navigate to the feature page
   - `mcp__chrome-devtools__take_snapshot` to see available UI elements
   - `mcp__chrome-devtools__click` buttons, links, tabs — do they work?
   - `mcp__chrome-devtools__fill` forms with valid data — does submission work?
   - `mcp__chrome-devtools__fill` forms with INVALID data — does validation catch it? (empty strings, extremely long strings, special characters like `<script>alert(1)</script>`)
   - Check console after each interaction for new errors
   - Check network after each interaction for failed API calls

2. **Edge case testing**:
   - Rapid-click buttons — does the UI handle double-submit?
   - Navigate away mid-operation then come back — does state recover?
   - `mcp__chrome-devtools__emulate` with networkConditions="Slow 3G" — does the app handle slow networks? Loading states?
   - `mcp__chrome-devtools__emulate` with viewport="375x667x2,mobile,touch" — does mobile layout work? Are touch targets big enough?
   - `mcp__chrome-devtools__emulate` with colorScheme="dark" — does dark mode render correctly?

3. **API response inspection**: For every network request the app makes:
   - `mcp__chrome-devtools__get_network_request` to inspect the actual response body
   - Does the response match what the frontend expects?
   - Are there fields being returned that shouldn't be? (over-fetching, data leaks)
   - Are error responses properly formatted?

4. **Memory & performance**:
   - `mcp__chrome-devtools__evaluate_script` with `() => { return { heapUsed: performance.memory?.usedJSHeapSize, heapTotal: performance.memory?.totalJSHeapSize } }` — check memory usage
   - Navigate between pages 5-10 times, check if memory grows (leak detection)
   - `mcp__chrome-devtools__performance_start_trace` on heavy pages — check for long tasks

**Every bug found through browser testing is a finding.** Add to `$BROWSER_FINDINGS` with category BROWSER_BUG, the exact steps to reproduce, and console/network evidence.

Output to user: **"Master Review: [target summary] | Mode: [mode] | Browser: [N] console errors, [N] failed requests, [N] interaction bugs, Lighthouse: [scores] | Starting Round 1..."**

---

## Phase 1: Initial Review — 3 Claude Opus + 3 Codex + 2 Antigravity (8 agents in parallel)

**CRITICAL: ALL 8 agents must launch in a SINGLE message for true parallel execution.**

### Prepare temp files and read account configuration

```bash
rm -f /tmp/master-review-codex-{1,2,3}.txt /tmp/master-review-ag-{1,2}.txt

# Read profile configuration dynamically from router.json so taskbar account switches are respected
ROUTER_CONFIG=/Users/nickpardon/claude-hybrid-control/config/router.json

AG_BIN=$(/usr/bin/python3 -c "import json; c=json.load(open('$ROUTER_CONFIG')); print(c['commands'].get('antigravity', 'antigravity'))")
CODEX_BIN=$(/usr/bin/python3 -c "import json; c=json.load(open('$ROUTER_CONFIG')); print(c['commands'].get('codex', 'codex'))")

# Antigravity: first 2 profiles from config (switch accounts in taskbar to change these)
AG_DIR_1=$(/usr/bin/python3 -c "import json; c=json.load(open('$ROUTER_CONFIG')); p=list(c['profiles']['antigravity'].values()); print(p[0]['user_data_dir']) if p else print('')")
AG_NAME_1=$(/usr/bin/python3 -c "import json; c=json.load(open('$ROUTER_CONFIG')); p=list(c['profiles']['antigravity'].values()); print(p[0].get('profile_name','Profile 1')) if p else print('Profile 1')")
AG_DIR_2=$(/usr/bin/python3 -c "import json; c=json.load(open('$ROUTER_CONFIG')); p=list(c['profiles']['antigravity'].values()); print(p[1]['user_data_dir']) if len(p)>1 else print('')")
AG_NAME_2=$(/usr/bin/python3 -c "import json; c=json.load(open('$ROUTER_CONFIG')); p=list(c['profiles']['antigravity'].values()); print(p[1].get('profile_name','Profile 2')) if len(p)>1 else print('Profile 2')")

# Codex: first 2 profiles from config (each has its own CODEX_HOME = its own OpenAI account)
CODEX_HOME_1=$(/usr/bin/python3 -c "import json; c=json.load(open('$ROUTER_CONFIG')); p=list(c['profiles']['codex'].values()); print(p[0]['codex_home']) if p else print('')")
CODEX_HOME_2=$(/usr/bin/python3 -c "import json; c=json.load(open('$ROUTER_CONFIG')); p=list(c['profiles']['codex'].values()); print(p[1]['codex_home']) if len(p)>1 else print(p[0]['codex_home'] if p else '')")

echo "Accounts: Codex[$CODEX_HOME_1, $CODEX_HOME_2] | Antigravity[$AG_NAME_1, $AG_NAME_2]"
```

### Launch ALL 6 simultaneously:

**Claude Agent 1 — Deep Correctness & Cross-Layer Integrity (Opus):**
```
description: "Master Review R1 — Deep Correctness & Cross-Layer Integrity"
model: opus
prompt: |
  You are an expert code correctness and cross-layer integrity reviewer. You find bugs that span boundaries — DB ↔ API ↔ frontend ↔ worker — and correctness issues that hide in edge cases.

  ## Context
  $CONTEXT_PACKAGE

  ## IMPORTANT: The checklist below is a STARTING POINT, not a boundary. Check every item, then go BEYOND it. If you see something wrong that isn't on the list — report it. You are looking for EVERYTHING that is wrong, broken, suspicious, fragile, or improvable. The checklist ensures you don't miss common issues, but your job is to find ALL issues, including ones nobody thought to put on a checklist. Think from first principles about what could go wrong in this specific code.

  ## Master Checklist — check EVERY item, then go beyond:

  ### Bugs & Logic Errors
  - Off-by-one errors in loops, slices, pagination, array indexing
  - Null/undefined/empty checks — what happens when data is missing?
  - Wrong comparison operators (== vs ===, > vs >=)
  - Boolean logic errors (De Morgan violations, inverted conditions)
  - Integer overflow, floating point precision (especially in money/pricing calculations)
  - String vs number coercion bugs
  - Incorrect default values that mask failures

  ### Cross-Layer Gaps (DB ↔ API ↔ Frontend ↔ Worker)
  - Database columns that exist in schema but are never read or written by the API
  - API response fields that the frontend expects but the backend never sends
  - API request fields that the frontend sends but the backend ignores
  - Database constraints (NOT NULL, UNIQUE, FK) that the application code doesn't respect
  - Enum values that exist in the DB but aren't handled in code (or vice versa)
  - Column type mismatches — DB says integer, API treats it as string
  - Status field transitions that skip required intermediate states
  - Worker job fields that don't match what the API inserts
  - Foreign key references to rows that could be deleted (missing ON DELETE handling)
  - Pagination offset/limit that doesn't match between frontend request and backend query

  ### Async & Concurrency
  - Missing `await` on async functions (silent promise drops)
  - Unhandled promise rejections
  - Race conditions — two requests modifying the same resource simultaneously
  - Stale closures in React (useEffect/useCallback capturing old state)
  - Database transactions that should exist but don't (multi-step writes that can partially fail)
  - Optimistic UI updates that don't roll back on server failure

  ### Error Paths
  - Errors silently swallowed (empty catch blocks, .catch(() => {}))
  - Error messages that don't include enough context to debug
  - try/catch that catches too broadly (swallowing unrelated errors)
  - Error propagation that loses the original stack trace
  - HTTP status codes that don't match the actual error (200 on failure, 500 on validation error)
  - Missing error boundaries in React component trees

  ### Data Integrity
  - Writes that should be atomic but aren't wrapped in a transaction
  - Cascading deletes that orphan related data
  - Created_at/updated_at fields not being set correctly
  - UUID generation that could collide
  - Data that's written but never cleaned up (orphaned rows, stale jobs, temp files)

  ## After the checklist
  Once you've checked every item above, step back and think: "What else could be wrong with this specific code that no checklist would catch?" Look for logic that's technically correct but semantically wrong. Look for things that will confuse the next developer. Look for assumptions that are true today but fragile. Report EVERYTHING.

  ## Instructions
  1. Read every file in scope line by line. Do NOT skim.
  2. Trace execution paths across file boundaries — follow function calls, API routes to DB queries.
  3. For each API endpoint: trace the request from route handler → service → DB query → response. Check for mismatches at every boundary.
  4. Do 3 internal passes. After each pass, re-read with fresh eyes for what you missed.
  5. On your final pass: forget the checklist entirely. Read the code as if you're the one who has to maintain it at 2am. What scares you?

  ## Output format
  For EACH finding:
  - [definite|likely|investigate] CATEGORY: description — file:line
  - Categories: BUG, LOGIC, EDGE_CASE, RACE_CONDITION, ERROR_HANDLING, TYPE_ERROR, CROSS_LAYER_GAP, DATA_INTEGRITY, ASYNC
  - Include the actual code snippet and explain exactly what's wrong
  - For cross-layer gaps: show BOTH sides (e.g., the DB schema AND the API code that doesn't match)
  - If you find nothing: "No correctness issues found." (but try harder first)
```

**Claude Agent 2 — Architecture, Quality & Production Readiness (Opus):**
```
description: "Master Review R1 — Architecture, Quality & Production Readiness"
model: opus
prompt: |
  You are an expert software architect and production readiness reviewer. You analyze code for structural problems AND production-readiness gaps — the things that work in dev but explode in prod.

  ## Context
  $CONTEXT_PACKAGE

  ## IMPORTANT: The checklist below is a STARTING POINT, not a boundary. Check every item, then go BEYOND it. If you see something wrong that isn't on the list — report it. You are looking for EVERYTHING: bad patterns, missed opportunities, tech debt, anything that makes this code worse than it should be. The checklist ensures you don't miss common issues, but your real job is to find every problem in this code, listed or not. Think like a staff engineer doing a thorough code review before a production launch.

  ## Master Checklist — check EVERY item, then go beyond:

  ### Architecture & Structure
  - Tight coupling — components that know too much about each other's internals
  - Leaky abstractions — implementation details bleeding through interfaces
  - God objects/functions — doing too many things, too many parameters
  - Circular dependencies — A imports B imports A
  - Responsibilities in the wrong layer (business logic in routes, DB queries in components)
  - Inconsistent patterns — same thing done 3 different ways across the codebase
  - Missing abstraction — copy-pasted logic that should be a shared function

  ### Dead Code & Cruft
  - Unused imports, variables, functions, components, files
  - Commented-out code blocks (should be deleted, not commented)
  - TODO/FIXME/HACK/XXX comments that were never addressed — list each one
  - Feature flags or conditional code for features that already shipped
  - Unused API endpoints that nothing calls
  - Database columns/tables that no code reads or writes
  - Unused npm packages in package.json / pip packages in requirements.txt
  - Stale type definitions that don't match current usage

  ### Code Sloppiness
  - Inconsistent naming (camelCase mixed with snake_case, inconsistent prefixes)
  - Magic numbers/strings that should be named constants
  - Functions longer than 50 lines that should be decomposed
  - Deeply nested conditionals (3+ levels of if/else)
  - Copy-pasted code with slight variations (DRY violations)
  - Inconsistent error response shapes across API endpoints
  - Console.log / print statements left in production code
  - Commented-out debugging code
  - Inconsistent file organization (some features in one dir, similar features scattered)

  ### Production Readiness
  - Missing rate limiting on public-facing API endpoints
  - Missing request size limits (file uploads, JSON body)
  - Missing timeouts on external HTTP calls, DB queries, worker jobs
  - Missing health check endpoint
  - Missing graceful shutdown handling (in-flight requests during deploy)
  - Unbounded queries — SELECT without LIMIT that could return millions of rows
  - Missing database connection pooling or pool exhaustion risk
  - Missing retry logic on flaky operations (external APIs, email sending)
  - Missing circuit breakers for external service dependencies
  - Missing request ID / correlation ID for tracing requests across services
  - Environment-specific code that would break in prod (localhost URLs, dev-only defaults)
  - Missing CORS configuration or overly permissive CORS (Access-Control-Allow-Origin: *)

  ### Scalability
  - N+1 queries — querying inside a loop instead of batching
  - Missing database indexes on columns used in WHERE/JOIN/ORDER BY
  - Large payloads — API responses that send entire tables instead of paginated results
  - Missing caching where the same expensive query runs repeatedly
  - Synchronous operations that should be async (file processing, email sending)
  - Single points of failure — if this one thing goes down, everything stops
  - Memory leaks — event listeners not cleaned up, growing arrays, unclosed connections
  - Missing pagination on list endpoints
  - Frontend re-renders — missing React.memo, useMemo, useCallback where performance matters

  ### Documentation Errors
  - API documentation that doesn't match actual endpoint behavior
  - Code comments that describe what the code USED to do, not what it does now
  - README instructions that are outdated or wrong
  - Type definitions / interfaces that don't match the runtime data
  - OpenAPI/Swagger specs that don't match actual routes
  - Env var documentation (.env.example) missing vars that the code actually reads
  - CLAUDE.md or project docs that describe architecture that no longer exists

  ## After the checklist
  Once you've checked every item above, step back and think: "If I were inheriting this codebase tomorrow, what would make me nervous?" Look for patterns that will cause pain at scale, tech debt that compounds, abstractions that are already leaking, and code that only works because of lucky coincidences. Report EVERYTHING.

  ## Instructions
  1. Map the architecture of the code in scope. Understand how components relate.
  2. Search for every item on the checklist — don't skip any category.
  3. For dead code: actually trace whether each export/function/variable has callers.
  4. For production readiness: think "what happens when 1000 users hit this simultaneously?"
  5. Do 3 internal passes.
  6. On your final pass: forget the checklist entirely. Read the code as a new hire trying to understand it. What's confusing, fragile, or clearly going to bite someone?

  ## Output format
  For EACH finding:
  - [definite|likely|investigate] CATEGORY: description — file:line
  - Categories: ARCHITECTURE, COUPLING, DEAD_CODE, SLOPPINESS, PROD_READINESS, SCALABILITY, DOC_ERROR, NAMING, CONVENTION, DUPLICATION, COMPLEXITY
  - Include the actual code and explain the problem
  - For dead code: prove it's unused (no callers, no imports, no references)
  - If you find nothing: "No architectural or production readiness issues found."
```

**Claude Agent 3 — Security, Safeguards & Resilience (Opus):**
```
description: "Master Review R1 — Security, Safeguards & Resilience"
model: opus
prompt: |
  You are an expert security engineer, chaos engineer, and defensive programming specialist. You think like an attacker trying to break in AND a site reliability engineer trying to prevent outages.

  ## Context
  $CONTEXT_PACKAGE

  ## IMPORTANT: The checklist below is a STARTING POINT, not a boundary. Check every item, then go BEYOND it. If you see something exploitable, fragile, or dangerous that isn't on the list — report it. You are looking for EVERYTHING that could be attacked, abused, or that would fail under stress. The checklist ensures you don't miss common vulnerabilities, but your real job is to think like a creative attacker and a paranoid SRE. What would YOU exploit? What would wake YOU up at 3am?

  ## Master Checklist — check EVERY item, then go beyond:

  ### Injection & Input Attacks
  - SQL injection — any raw string concatenation in queries, unparameterized queries
  - XSS — user input rendered in HTML without escaping, dangerouslySetInnerHTML
  - Command injection — user input passed to exec/spawn/system calls
  - Path traversal — user-controlled file paths without sanitization (../../etc/passwd)
  - SSRF — user-controlled URLs in server-side HTTP requests
  - Template injection — user input in template strings evaluated server-side
  - Header injection — user input in HTTP headers (CRLF injection)
  - NoSQL injection — user input in MongoDB/Supabase query operators

  ### Authentication & Authorization
  - Endpoints missing auth guards entirely (any endpoint without get_required_user_id or equivalent)
  - IDOR — accessing resources by ID without checking ownership (can user A see user B's data?)
  - Privilege escalation — can a viewer perform editor actions? Can a non-owner delete?
  - JWT issues — missing expiration validation, algorithm confusion, no revocation mechanism
  - Session fixation — can an attacker set another user's session?
  - Auth bypass via parameter pollution or HTTP method override
  - Missing permission checks on UPDATE/DELETE operations (checked on GET but not on write)
  - API keys or tokens in URLs (logged by proxies, browsers, CDNs)

  ### Data Protection & Leaks
  - Secrets in source code (API keys, passwords, tokens — even if in .env, check for leaks)
  - Error responses that expose stack traces, internal paths, or DB schema
  - Verbose logging that includes PII, passwords, or tokens
  - API responses that return more fields than the client needs (over-fetching sensitive data)
  - Missing field-level filtering — admin-only fields visible to regular users
  - Debug/dev endpoints accessible in production
  - Sensitive data in localStorage/sessionStorage (tokens stored insecurely)
  - Missing data sanitization on output (different from input validation)

  ### Failsafes & Safeguards
  - Missing input validation at EVERY system boundary (API endpoints, form submissions, webhook receivers)
  - Missing max length / max size checks (can someone upload a 10GB file? Send a 100MB JSON body?)
  - Missing rate limiting — can an attacker hammer an endpoint infinitely?
  - Missing idempotency guards — what if the same request is sent twice? (double-submit on payments, duplicate job creation)
  - Missing graceful degradation — when an external service is down, does the whole app crash or just that feature?
  - Missing dead letter queues — what happens to jobs that fail repeatedly?
  - Missing max retry limits — can a failing operation retry forever?
  - Missing timeout on EVERY external call (HTTP, DB, file I/O, worker jobs)
  - Missing cleanup on failure — if step 3 of 5 fails, are steps 1-2 rolled back?
  - Missing guard against self-referencing (can a record reference itself as parent? Infinite loop?)
  - Missing bounds checking — negative quantities, negative prices, dates in the past
  - Missing concurrent modification protection — what if two users edit the same thing?

  ### Contradictions & Inconsistencies
  - Auth model described in docs vs actually implemented in code — do they match?
  - Error codes/messages that contradict the actual error condition
  - Database constraints that contradict application validation rules
  - Frontend validation rules that don't match backend validation
  - API documentation that claims required fields that are actually optional (or vice versa)
  - Config defaults that contradict documented behavior
  - Permission model inconsistencies — checked in some places, skipped in others

  ### Resilience & Failure Modes
  - What happens when the database is unreachable? (connection refused, timeout)
  - What happens when Supabase Storage is down? (file upload fails mid-stream)
  - What happens when the worker never picks up a job? (stuck in pending forever)
  - What happens when an API call to Anthropic/OpenRouter times out?
  - What happens when disk is full? (log files, temp files, uploads)
  - What happens when memory is exhausted? (large file processing, unbounded caches)
  - What happens during deployment? (in-flight requests, database migrations, cache invalidation)
  - What happens when the clock skews? (JWT expiration, job scheduling, rate limiting)

  ## After the checklist
  Once you've checked every item above, step back and think: "If I wanted to take this system down or steal its data, what would I try that nobody has thought of?" Think about chained exploits, timing attacks, abuse of business logic, and social engineering vectors. Report EVERYTHING.

  ## Instructions
  1. Check every input boundary in the codebase — every API endpoint, every form, every webhook.
  2. For each endpoint: can an unauthenticated user reach it? Can a low-privilege user abuse it?
  3. For each external dependency: what happens when it's slow? Down? Returns garbage?
  4. Trace data flow from user input to storage to output — is it validated, sanitized, and escaped at every step?
  5. Do 3 internal passes. First pass: injection & auth. Second pass: safeguards & failsafes. Third pass: resilience & contradictions.
  6. On your final pass: forget the checklist entirely. Think like a creative attacker with access to the source code. What's the cleverest exploit you can find?

  ## Output format
  For EACH finding:
  - [definite|likely|investigate] CATEGORY: description — file:line
  - Categories: INJECTION, AUTH_BYPASS, IDOR, DATA_LEAK, MISSING_SAFEGUARD, MISSING_VALIDATION, CONTRADICTION, RESILIENCE, RATE_LIMIT, IDEMPOTENCY
  - Include the vulnerable code and explain the attack vector / failure scenario
  - For contradictions: show BOTH contradicting pieces of code or docs
  - If you find nothing: "No security or resilience issues found."
```

**Codex Agent 1 — Cross-Layer Gaps & Data Integrity (Bash — parallel, uses CODEX_HOME_1 account):**
```bash
CODEX_HOME=$CODEX_HOME_1 $CODEX_BIN exec -o /tmp/master-review-codex-1.txt --ephemeral -s read-only -C $WORKDIR "You are a senior reviewer focused on CROSS-LAYER INTEGRITY and DATA CORRECTNESS. Review: [SCOPE DESCRIPTION]. Read the actual files. IMPORTANT: The checklist below is a starting point — report ANYTHING wrong you find, even if it's not on this list. You are looking for everything. Check this list THEN go beyond:

CROSS-LAYER GAPS:
- DB columns the API never reads/writes
- API response fields the frontend expects but backend doesn't send
- API request fields the frontend sends but backend ignores
- Enum values in DB not handled in code (or vice versa)
- Status transitions that skip states
- Foreign keys referencing deletable rows without ON DELETE
- Worker job fields that don't match API inserts
- Type mismatches between layers (DB int vs API string)

DATA INTEGRITY:
- Writes without transactions that should be atomic
- Orphaned data from incomplete cascading deletes
- Missing created_at/updated_at handling
- Data written but never cleaned up

DEAD CODE:
- Unused functions, imports, variables, components, files
- TODO/FIXME/HACK comments never addressed
- Commented-out code
- Unused API endpoints, DB columns, npm/pip packages

For each: CRITICAL/IMPORTANT/MINOR, category, file:line, code snippet, explanation. Do 3 passes."
```
timeout: 300000

**Codex Agent 2 — Production Readiness & Scalability (Bash — parallel, uses CODEX_HOME_2 account):**
```bash
CODEX_HOME=$CODEX_HOME_2 $CODEX_BIN exec -o /tmp/master-review-codex-2.txt --ephemeral -s read-only -C $WORKDIR "You are a senior production readiness and scalability reviewer. Review: [SCOPE DESCRIPTION]. Read the actual files. IMPORTANT: The checklist below is a starting point — report ANYTHING wrong you find, even if it's not on this list. You are looking for everything. Check this list THEN go beyond:

PRODUCTION READINESS:
- Missing rate limiting on public API endpoints
- Missing request size limits on uploads/JSON bodies
- Missing timeouts on external HTTP calls, DB queries, worker jobs
- Unbounded queries (SELECT without LIMIT)
- Missing health check endpoint
- Missing graceful shutdown
- Environment-specific code that breaks in prod (localhost URLs, dev defaults)
- Missing CORS config or overly permissive CORS
- Console.log/print left in production code
- Missing request tracing (correlation IDs)

SCALABILITY:
- N+1 queries (querying in a loop)
- Missing DB indexes on WHERE/JOIN/ORDER BY columns
- Large payloads without pagination
- Missing caching for repeated expensive queries
- Synchronous ops that should be async
- Memory leaks (uncleaned event listeners, growing arrays, unclosed connections)
- Single points of failure

CODE SLOPPINESS:
- Magic numbers/strings without named constants
- Functions >50 lines
- 3+ levels of nested conditionals
- Copy-pasted code with slight variations
- Inconsistent naming conventions
- Inconsistent error response shapes

DOCUMENTATION ERRORS:
- Comments describing old behavior
- README/docs with wrong instructions
- .env.example missing required vars
- Type definitions that don't match runtime data

For each: CRITICAL/IMPORTANT/MINOR, category, file:line, code snippet, explanation. Do 3 passes."
```
timeout: 300000

**Codex Agent 3 — Security, Safeguards & Contradictions (Bash — parallel, uses CODEX_HOME_1 account):**
```bash
CODEX_HOME=$CODEX_HOME_1 $CODEX_BIN exec -o /tmp/master-review-codex-3.txt --ephemeral -s read-only -C $WORKDIR "You are a senior security engineer and defensive programming specialist. Review: [SCOPE DESCRIPTION]. Read the actual files. IMPORTANT: The checklist below is a starting point — report ANYTHING exploitable, fragile, or dangerous you find, even if it's not on this list. You are looking for everything. Check this list THEN go beyond:

SECURITY:
- SQL injection (raw string concatenation in queries)
- XSS (unescaped user input in HTML, dangerouslySetInnerHTML)
- Command injection (user input in exec/spawn)
- Path traversal (user-controlled file paths)
- SSRF (user-controlled URLs in server requests)
- IDOR (resource access without ownership check)
- Endpoints missing auth guards entirely
- Privilege escalation paths
- Secrets in source code
- Error responses leaking internals
- Sensitive data in localStorage

SAFEGUARDS:
- Missing input validation at system boundaries
- Missing max size/length checks
- Missing rate limiting
- Missing idempotency guards (double-submit)
- Missing timeout on every external call
- Missing cleanup on partial failure (rollback)
- Missing bounds checking (negative values, past dates)
- Missing concurrent modification protection
- Missing dead letter handling for failed jobs
- Missing max retry limits

CONTRADICTIONS:
- Auth model in docs vs code — do they match?
- Frontend validation vs backend validation — do they agree?
- DB constraints vs application validation — consistent?
- Error codes that don't match the actual condition
- Config defaults contradicting documentation
- Permission checks present in some endpoints but missing in similar ones

For each: CRITICAL/IMPORTANT/MINOR, category, file:line, code snippet, explanation. Do 3 passes."
```
timeout: 300000

**Antigravity Agent 1 — Bugs, Cross-Layer & Security (Bash — parallel, uses first configured Antigravity account):**
```bash
echo "# Antigravity Agent 1 — $AG_NAME_1" > /tmp/master-review-ag-1.txt
timeout 30 "$AG_BIN" --user-data-dir "$AG_DIR_1" --profile "$AG_NAME_1" chat --mode agent \
  "You are a senior code reviewer. Review this codebase: [SCOPE DESCRIPTION]. Working directory: $WORKDIR. IMPORTANT: The checklist below is a STARTING POINT — report ANYTHING wrong you find. Check this list THEN go beyond:

BUGS & CROSS-LAYER GAPS:
- Off-by-ones, null checks, wrong comparison operators, boolean logic errors
- DB columns the API never reads/writes; API fields frontend expects but backend doesn't send
- Enum values in DB not handled in code; status transitions that skip states
- Type mismatches between layers (DB int vs API string, snake_case vs camelCase)
- Missing transactions for multi-step writes; orphaned data from incomplete operations
- Race conditions; missing await on async functions; unhandled promise rejections

SECURITY:
- SQL/XSS/command injection; path traversal; SSRF; IDOR
- Endpoints missing auth guards; privilege escalation paths
- Secrets in source code; error responses leaking internals
- Missing input validation at system boundaries; missing rate limiting
- Missing idempotency guards (double-submit); missing bounds checking

PRODUCTION READINESS:
- Missing timeouts on external calls; unbounded queries without LIMIT
- N+1 queries; missing DB indexes; console.log left in production code
- Missing retry logic; environment-specific code that breaks in prod

For each finding: CRITICAL/IMPORTANT/MINOR, category, file:line, code snippet, explanation. Do 3 passes. Output results as plain text." \
  >> /tmp/master-review-ag-1.txt 2>&1 || echo "Antigravity Agent 1: timed out or GUI opened — findings unavailable" >> /tmp/master-review-ag-1.txt
```
timeout: 45000

**Antigravity Agent 2 — Architecture, Scalability & Dead Code (Bash — parallel, uses second configured Antigravity account):**
```bash
echo "# Antigravity Agent 2 — $AG_NAME_2" > /tmp/master-review-ag-2.txt
timeout 30 "$AG_BIN" --user-data-dir "$AG_DIR_2" --profile "$AG_NAME_2" chat --mode agent \
  "You are a senior software architect and production readiness reviewer. Review this codebase: [SCOPE DESCRIPTION]. Working directory: $WORKDIR. IMPORTANT: The checklist below is a STARTING POINT — report ANYTHING wrong you find. Check this list THEN go beyond:

ARCHITECTURE & DEAD CODE:
- Tight coupling; leaky abstractions; god functions; circular dependencies
- Responsibilities in the wrong layer (business logic in routes, DB queries in components)
- Inconsistent patterns — same thing done multiple ways; missing abstraction for copy-pasted logic
- Unused imports, variables, functions, components, files
- TODO/FIXME/HACK comments never addressed; commented-out code blocks
- Unused API endpoints, DB columns, npm packages

SCALABILITY & PERFORMANCE:
- N+1 queries (querying inside a loop instead of batching)
- Missing DB indexes on WHERE/JOIN/ORDER BY columns
- Large payloads without pagination; missing caching for repeated expensive queries
- Synchronous operations that should be async; memory leaks
- Frontend re-renders without memoization where performance matters

CODE QUALITY & DOCUMENTATION:
- Magic numbers/strings without named constants; functions longer than 50 lines
- Deeply nested conditionals (3+ levels); copy-pasted code with slight variations
- Inconsistent naming conventions; inconsistent error response shapes
- API documentation that doesn't match actual endpoint behavior
- Comments describing old behavior; README with wrong instructions
- Type definitions that don't match runtime data; .env.example missing required vars

For each finding: CRITICAL/IMPORTANT/MINOR, category, file:line, code snippet, explanation. Do 3 passes. Output results as plain text." \
  >> /tmp/master-review-ag-2.txt 2>&1 || echo "Antigravity Agent 2: timed out or GUI opened — findings unavailable" >> /tmp/master-review-ag-2.txt
```
timeout: 45000

### After all 8 return:

1. Read Claude agent results from their return values
2. Read Codex results from `/tmp/master-review-codex-{1,2,3}.txt`
3. Read Antigravity results from `/tmp/master-review-ag-{1,2}.txt`
4. Handle failures gracefully — empty/missing file or "timed out" message = "Agent N: unavailable"
5. Compile all findings into `$ROUND_1_FINDINGS`

Output to user: **"Round 1 complete: [N] findings from 8 agents (3 Claude + 3 Codex + 2 Antigravity). Starting synthesis..."**

---

## Phase 2: Synthesis Agent — Understand, Plan, Audit, Fix

You (the orchestrator) now become the Synthesis Agent. This is the most critical phase.

### 2a: Deep Codebase Understanding

Before acting on any findings, you MUST understand the codebase deeply enough to know what's safe to change:

1. **Read the actual files** involved in findings. Don't trust agent summaries — verify each finding yourself.
2. **Trace dependencies**: For each file with findings, understand what depends on it and what it depends on.
3. **Check tests**: `find . -name "*.test.*" -o -name "*.spec.*"` — are there tests for the affected code?
4. **Check git blame**: For critical findings, who wrote this and when? Is it intentional?

### 2b: Validate and Deduplicate Findings

1. **Remove false positives**: If you verify the code and the finding is wrong, drop it. Note: "Removed N false positives."
2. **Deduplicate**: Same root cause across agents → merge. Note which agents found it (cross-agent = high confidence).
3. **Promote confidence**: Found by 2+ agents → upgrade confidence. Cross-model (Claude + Codex) → automatic upgrade.
4. **Classify**: Sort into MUST_FIX (definite bugs, security holes), SHOULD_FIX (likely issues, architecture), and INVESTIGATE (uncertain).

### 2c: Impact Audit — Will Fixes Break Anything?

For EACH finding you plan to fix, assess:
1. What code calls this? What would break if we change it?
2. Are there tests that would catch regressions?
3. Is this a public API that external code depends on?
4. Could this fix introduce a NEW bug?

**If you need more information**, spawn sub-agents:

```
description: "Master Review — Impact Analysis: [specific area]"
prompt: "Trace all callers of [function/module]. List every file that imports or calls it, what it passes, and what it expects back. I need to know if changing [specific thing] would break any caller."
```

You may spawn up to 3 impact-analysis sub-agents in parallel if needed.

### 2d: Build the Fix Plan

Compile validated findings into a structured fix plan. Write it to `./tmp/ready-plans/master-review-fixes.md`:

```markdown
# Master Review Fix Plan — Round [N]

## Summary
- Total findings: [N validated]
- Must fix: [N]
- Should fix: [N]
- Skipped (false positive / too risky): [N]

## Fixes (ordered by priority and dependency)

### Fix 1: [title]
- **Finding**: [description] — [file:line]
- **Found by**: [agent sources]
- **Confidence**: [definite/likely]
- **Impact audit**: [what depends on this, test coverage, risk assessment]
- **Fix**: [specific code change description]
- **Files to modify**: [list]

### Fix 2: ...
[repeat for each fix]

## Intentionally Skipped
- [Finding]: [why it was skipped — false positive, too risky, needs human judgment]
```

### 2e: Execute /plan and /implement

1. **Output the fix plan summary to the user** for visibility — but do NOT wait for approval. Proceed immediately.
2. Invoke `/implement ./tmp/ready-plans/master-review-fixes.md`
3. Wait for implementation to complete.

**This is a fully autonomous pipeline. No user intervention or approval gates.** The synthesis agent (you) is the quality gate — your validation in steps 2a-2d IS the review. If you validated a finding and built a fix plan, execute it. Do not pause, do not ask, do not wait.

### 2f: Browser Verification After Fixes

After `/implement` completes, verify fixes didn't break the UI:

1. **Reload the app**: `mcp__chrome-devtools__navigate_page` with type="reload"
2. **Check console**: `mcp__chrome-devtools__list_console_messages` with types `["error", "warn"]` — compare against `$BASELINE_CONSOLE_ERRORS`. Any NEW errors = regression.
3. **Check network**: `mcp__chrome-devtools__list_network_requests` — any new failed requests?
4. **Take snapshot**: `mcp__chrome-devtools__take_snapshot` — compare key UI elements against baseline. Are things missing, broken, or visually wrong?
5. **Screenshot**: `mcp__chrome-devtools__take_screenshot` with fullPage=true — save to `/tmp/master-review-round-[N].png`
6. **Navigate critical routes**: Visit the same 3-5 routes from Phase 0e. At each:
   - Check for new console errors
   - Check for broken network requests
   - Take snapshot — does the page render correctly?
   - Click key interactive elements — do they respond?
7. **Run JS health checks**: `mcp__chrome-devtools__evaluate_script` to check:
   - `() => { return { errors: window.__REACT_ERROR_COUNT || 0, hydrated: !!document.querySelector('[data-reactroot]') || !!document.getElementById('root')?.children.length } }` — React hydration and error boundary status
   - Any app-specific health indicators

**If new console errors or broken network requests appear after fixes:**
- Flag as REGRESSION — these go into the next round with highest priority
- Include the exact error messages in the regression finding

Output to user: **"Fixes implemented. Browser check: [N] new errors, [N] failed requests. Starting verification round..."**

---

## Phase 3: Verification Loop — 2 Claude + 2 Codex (repeats until clean)

After implementation, run a tighter review loop to verify fixes and catch new issues.

### Initialize loop state

```
$ROUND_NUMBER = 2 (and incrementing)
$CONSECUTIVE_CLEAN = 0
$EXPLORED_AREAS = [list of files/areas already reviewed]
$PREVIOUS_FINDINGS = [all findings from all previous rounds]
```

### 3a: Prepare verification context

Build a new `$CONTEXT_PACKAGE` that includes:
1. What was just fixed (the diff from /implement)
2. The original findings and their fixes
3. Areas NOT yet explored (`$EXPLORED_AREAS` tracking)
4. The current state of the code (re-read modified files)

### 3b: Launch 6 agents in parallel (SINGLE message)

```bash
rm -f /tmp/master-review-codex-v{1,2}.txt /tmp/master-review-ag-v{1,2}.txt
```

**Claude Agent 1 — Verification + Deep Dive (Opus):**
```
description: "Master Review R[N] — Verify Fixes + Deep Dive"
model: opus
prompt: |
  You are verifying fixes from a prior review round AND searching the ENTIRE codebase for new issues.

  ## What was fixed
  $PREVIOUS_FIXES_SUMMARY

  ## Your TWO jobs:

  ### Job 1: VERIFY FIXES
  Re-read every file that was modified. For each fix:
  - Did it actually fix the reported problem?
  - Did it introduce a NEW bug, regression, or side effect?
  - Did it break any callers or dependents?
  - Did it change any API contracts (request/response shapes)?
  - Is the fix complete, or did it only fix part of the problem?

  ### Job 2: SEARCH THE WHOLE CODEBASE
  You have access to the entire codebase. Search EVERYWHERE — not just areas marked as "unexplored." A fresh pair of eyes on already-reviewed code often catches what the first reviewer missed. Prioritize these areas that haven't been deeply reviewed yet: $UNEXPLORED_AREAS — but do NOT limit yourself to them. Look anywhere and everywhere.

  Apply the FULL Master Review checklist to the entire codebase:
  - Cross-layer gaps (DB ↔ API ↔ frontend field mismatches, missing FK handling, enum drift)
  - Correctness (off-by-ones, null checks, async/await, error swallowing, race conditions)
  - Data integrity (missing transactions, orphaned data, stale state)
  - Production readiness (missing rate limits, timeouts, unbounded queries, missing health checks)
  - Security (injection, auth bypass, IDOR, missing validation, data leaks)
  - Safeguards (missing idempotency, missing bounds checks, missing cleanup on failure)
  - Dead code (unused functions/imports/endpoints/packages, stale TODOs)
  - Code sloppiness (magic numbers, 50+ line functions, copy-paste, inconsistent naming)
  - Scalability (N+1 queries, missing indexes, missing pagination, memory leaks)
  - Documentation errors (wrong comments, outdated README, stale type definitions)
  - Contradictions (docs vs code, frontend vs backend validation, DB constraints vs app logic)

  ## Previously found (do NOT re-report these):
  $PREVIOUS_FINDINGS_SUMMARY

  ## Output
  - For verifications: VERIFIED (fix is correct) or REGRESSION (fix introduced new problem) — file:line — explanation
  - For new findings: [definite|likely|investigate] CATEGORY: description — file:line
  - If NOTHING new and all fixes verified: "All fixes verified. No new findings in explored areas."
```

**Claude Agent 2 — Broader Sweep (Opus):**
```
description: "Master Review R[N] — Broader Sweep"
model: opus
prompt: |
  You are doing a full sweep of the ENTIRE codebase — everything is in scope. You are looking for issues that ONLY become visible when you look at the bigger picture — cross-cutting concerns, integration seams, and system-level problems. You may revisit already-reviewed areas with fresh eyes.

  ## Areas that have been reviewed before (you can STILL look here — a second pass often catches things):
  $EXPLORED_AREAS

  ## Already found issues (DO NOT re-report):
  $PREVIOUS_FINDINGS_SUMMARY

  ## Your focus areas:

  ### Cross-Cutting Concerns (things that span multiple files/modules)
  - Auth checks inconsistently applied — present on some endpoints, missing on similar ones
  - Error response format inconsistent across the API
  - Logging gaps — what can't you debug in production with current logging?
  - Missing monitoring hooks — if this breaks in prod, would anyone know?
  - Timezone handling — consistent across DB, API, and frontend?
  - Date/time formats — ISO 8601 everywhere or mixed?

  ### Integration Seams
  - Code that interacts with the fixed areas but wasn't part of the fix
  - Shared utilities used by both reviewed and unreviewed code
  - Event/callback chains that cross module boundaries
  - Shared database tables accessed by multiple services

  ### System-Level
  - Dependency versions with known vulnerabilities
  - Unused dependencies inflating bundle/install size
  - Missing environment variable validation at startup
  - Configuration that works locally but would fail in CI/CD or prod
  - Missing test coverage for critical paths (check if tests exist, not just if they pass)

  ### Overlooked Patterns
  - The same bug pattern that was found in one file likely exists in similar files
  - If a safeguard was missing in one endpoint, check ALL similar endpoints
  - If a cross-layer gap was found, check ALL similar cross-layer boundaries

  ## Output
  - For each NEW finding: [definite|likely|investigate] CATEGORY: description — file:line
  - If NOTHING new: "No new findings in unreviewed areas."
```

**Codex Agent 1 — Verify + Cross-Layer (Bash — parallel):**
```bash
codex exec -o /tmp/master-review-codex-v1.txt --ephemeral -s read-only -C $WORKDIR "You are verifying code fixes and searching the ENTIRE codebase for new issues. Fixes applied: [FIXES SUMMARY]. Known issues (do NOT re-report): [PREVIOUS_FINDINGS].

JOB 1 - VERIFY: Check each fix is correct, didn't introduce regressions, didn't break callers.

JOB 2 - FULL CODEBASE SEARCH: Search EVERYWHERE in the codebase, not just unexplored areas. Prioritize these less-reviewed areas: [UNEXPLORED_AREAS] — but also re-check already-reviewed code with fresh eyes. Apply full checklist:
- Cross-layer gaps (DB vs API vs frontend mismatches)
- Missing transactions and data integrity issues
- Dead code (unused functions, imports, endpoints, packages, stale TODOs)
- Production readiness (missing rate limits, timeouts, unbounded queries)
- Missing safeguards (idempotency, bounds checks, cleanup on failure)
- Documentation errors (wrong comments, outdated docs, stale types)
- Contradictions (docs vs code, frontend vs backend validation)

For each: CRITICAL/IMPORTANT/MINOR, category, file:line, code, explanation. Do 3 passes."
```
timeout: 300000

**Codex Agent 2 — Fresh Eyes Full Sweep (Bash — parallel):**
```bash
codex exec -o /tmp/master-review-codex-v2.txt --ephemeral -s read-only -C $WORKDIR "You are a fresh-eyes reviewer with NO prior context. Read the ENTIRE codebase: [SCOPE]. Search everywhere — prioritize less-reviewed areas [UNEXPLORED_AREAS] but also look at already-reviewed code with fresh eyes. Known issues (do NOT re-report): [PREVIOUS_FINDINGS].

Apply the FULL checklist — miss nothing:
- Bugs: off-by-ones, null checks, wrong comparisons, async errors, race conditions
- Security: injection, auth bypass, IDOR, data leaks, missing validation, secrets in code
- Architecture: coupling, god functions, circular deps, wrong-layer responsibilities
- Scalability: N+1 queries, missing indexes, missing pagination, memory leaks, missing caching
- Production: missing rate limits, timeouts, health checks, graceful shutdown, request size limits
- Dead code: unused everything, stale TODOs, commented-out code
- Sloppiness: magic numbers, copy-paste, inconsistent naming, console.log in prod
- Safeguards: missing idempotency, missing retry limits, missing concurrent modification protection
- Contradictions: docs vs code, frontend vs backend, DB constraints vs app logic

For each: CRITICAL/IMPORTANT/MINOR, category, file:line, code, explanation. Do 3 passes."
```
timeout: 300000

**Antigravity Verification Agent 1 — Verify Fixes + Bug Hunt (Bash — parallel):**
```bash
AG=/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity
AG_DIR=/Users/nickpardon/claude-hybrid-control/profiles/antigravity/google-pro-1
echo "# Antigravity Verification Agent 1 — Round $ROUND_NUMBER" > /tmp/master-review-ag-v1.txt
timeout 30 "$AG" --user-data-dir "$AG_DIR" --profile "Google Pro 1" chat --mode agent \
  "You are verifying code fixes and searching for new issues. Working directory: $WORKDIR. Fixes applied: [FIXES_SUMMARY]. Known issues — do NOT re-report these: [PREVIOUS_FINDINGS].

JOB 1 - VERIFY FIXES: For each fix applied, check: did it solve the reported problem? Did it introduce a regression or new bug? Did it break any callers? Did it change any API contracts?

JOB 2 - SEARCH THE WHOLE CODEBASE for new issues. Prioritize less-reviewed areas: [UNEXPLORED_AREAS] — but also revisit already-reviewed code with fresh eyes. Apply full checklist:
- Bugs: off-by-ones, null checks, wrong comparisons, missing await, race conditions
- Cross-layer gaps: DB vs API vs frontend mismatches, enum drift, type mismatches
- Security: injection, auth bypass, IDOR, missing validation, data leaks
- Safeguards: missing idempotency, missing bounds checks, missing cleanup on failure
- Dead code: unused functions, imports, endpoints, stale TODOs
- Scalability: N+1 queries, missing indexes, missing pagination
- Contradictions: docs vs code, frontend vs backend validation, DB constraints vs app logic

For each: VERIFIED/REGRESSION for fix checks; CRITICAL/IMPORTANT/MINOR, category, file:line for new findings. Output plain text." \
  >> /tmp/master-review-ag-v1.txt 2>&1 || echo "Antigravity Verification Agent 1: timed out or GUI opened — findings unavailable" >> /tmp/master-review-ag-v1.txt
```
timeout: 45000

**Antigravity Verification Agent 2 — Fresh Eyes Full Sweep (Bash — parallel):**
```bash
AG=/Applications/Antigravity.app/Contents/Resources/app/bin/antigravity
AG_DIR=/Users/nickpardon/claude-hybrid-control/profiles/antigravity/google-pro-2
echo "# Antigravity Verification Agent 2 — Round $ROUND_NUMBER" > /tmp/master-review-ag-v2.txt
timeout 30 "$AG" --user-data-dir "$AG_DIR" --profile "Google Pro 2" chat --mode agent \
  "You are a fresh-eyes reviewer with NO prior context. Codebase: $WORKDIR. Prioritize unexplored areas: [UNEXPLORED_AREAS] but look everywhere. Known issues — do NOT re-report: [PREVIOUS_FINDINGS].

Search the ENTIRE codebase for ANYTHING wrong. Apply the full checklist:
- Architecture: coupling, god functions, circular deps, wrong-layer responsibilities
- Production readiness: missing rate limits, missing timeouts, unbounded queries, environment-specific code
- Code quality: magic numbers, copy-paste, inconsistent naming, functions >50 lines, console.log in prod
- Documentation: comments describing old behavior, outdated README, stale type definitions
- Cross-cutting: auth checks inconsistently applied, error response format inconsistent, timezone handling, missing monitoring
- System-level: dependency vulnerabilities, missing env var validation at startup, config that breaks in prod

For each: CRITICAL/IMPORTANT/MINOR, category, file:line, code snippet, explanation. Output plain text." \
  >> /tmp/master-review-ag-v2.txt 2>&1 || echo "Antigravity Verification Agent 2: timed out or GUI opened — findings unavailable" >> /tmp/master-review-ag-v2.txt
```
timeout: 45000

### 3c: Process round results

1. Collect all 6 agent outputs (2 Claude + 2 Codex + 2 Antigravity)
2. Read Antigravity results from `/tmp/master-review-ag-v{1,2}.txt` — handle "timed out" gracefully
3. Validate findings yourself (read the code, verify each one)
4. Remove false positives and duplicates of previous findings
5. Check for regressions from fixes

### 3d: Determine loop continuation

**Count genuinely NEW findings** (not re-reports, not false positives):

**If NEW findings > 0:**
- Set `$CONSECUTIVE_CLEAN = 0`
- Add newly explored areas to `$EXPLORED_AREAS`
- Add new findings to `$PREVIOUS_FINDINGS`
- Output: **"Round [N]: [X] new findings. Fixing and continuing..."**
- Go to Phase 2 (Synthesis) with the new findings → fix → loop back to Phase 3

**If NEW findings == 0:**
- Increment `$CONSECUTIVE_CLEAN`
- Add newly explored areas to `$EXPLORED_AREAS`
- Output: **"Round [N]: Clean pass ([CONSECUTIVE_CLEAN]/3). [Areas remaining: X]"**

**If `$CONSECUTIVE_CLEAN` >= 3:**
- Output: **"3 consecutive clean passes. Master Review complete."**
- Go to Phase 4 (Final Report)

**If `$CONSECUTIVE_CLEAN` < 3:**
- The agents MUST explore DIFFERENT areas in the next round
- Update `$UNEXPLORED_AREAS` to focus on what hasn't been covered
- If ALL areas have been explored and it's still < 3 clean passes, re-review the HIGHEST RISK areas with different prompts (e.g., "assume the previous reviewer was wrong about X being correct")
- Loop back to 3a

### 3e: Regression handling

If ANY fix caused a regression:
- Immediately flag it: **"REGRESSION DETECTED in Round [N]"**
- Reset `$CONSECUTIVE_CLEAN = 0`
- Add the regression to the next fix plan with highest priority
- The regression fix goes through the same synthesis → plan → implement → verify cycle

---

## Phase 4: Final Browser Audit & Report

After 3 consecutive clean passes, run one final comprehensive browser check before declaring victory:

### 4a: Final Browser Sweep

1. **Reload the app**: `mcp__chrome-devtools__navigate_page` with type="reload" and ignoreCache=true
2. **Console check**: `mcp__chrome-devtools__list_console_messages` with types `["error", "warn"]` — compare against original baseline. Were any pre-existing errors FIXED? Any new ones introduced?
3. **Network check**: `mcp__chrome-devtools__list_network_requests` — all API calls succeeding?
4. **Lighthouse audit**: `mcp__chrome-devtools__lighthouse_audit` with mode="navigation" — compare scores against Phase 0e baseline. Did accessibility/SEO/best-practices improve or regress?
5. **Performance trace**: `mcp__chrome-devtools__performance_start_trace` with autoStop=true — compare Core Web Vitals against baseline
6. **Full page navigation**: Visit ALL major routes, at each check console + network + take snapshot
7. **Dark mode check**: `mcp__chrome-devtools__emulate` with colorScheme="dark" → take screenshot → check for broken styles
8. **Mobile check**: `mcp__chrome-devtools__emulate` with viewport="375x667x2,mobile,touch" → take screenshot → check responsive layout
9. **Final screenshot**: `mcp__chrome-devtools__take_screenshot` with fullPage=true — save to `/tmp/master-review-final.png`

### 4b: Output the Final Report

```markdown
# Master Review Complete

## Target: [target summary]
## Rounds: [total rounds] | Clean passes: 3/3
## Engine: [N]x Claude Opus + [N]x Codex (GPT-5.4) per round

## Fixes Applied
| # | Finding | Severity | File(s) | Fixed In | Verified |
|---|---------|----------|---------|----------|----------|
| 1 | [desc]  | definite | file.ts | Round 1  | Round 2  |
| ...

## Areas Reviewed
- [list of all files/areas that were covered across all rounds]

## Findings Skipped (human judgment needed)
- [any findings that were too risky to auto-fix or needed human decision]

## False Positives Removed
- [count] false positives identified and removed across all rounds

## Browser Audit
| Metric | Before | After | Delta |
|--------|--------|-------|-------|
| Console errors | [N] | [N] | [+/-N] |
| Console warnings | [N] | [N] | [+/-N] |
| Failed network requests | [N] | [N] | [+/-N] |
| Lighthouse Accessibility | [N] | [N] | [+/-N] |
| Lighthouse Best Practices | [N] | [N] | [+/-N] |
| Lighthouse SEO | [N] | [N] | [+/-N] |
| LCP (ms) | [N] | [N] | [+/-N] |
| Dark mode | [pass/fail] | [pass/fail] | |
| Mobile layout | [pass/fail] | [pass/fail] | |

## Browser Bugs Found & Fixed
- [list of bugs discovered through active browser testing, with reproduction steps]

## Statistics
- Total agent invocations: [count]
- Total findings (raw): [count]
- After dedup + false positive removal: [count]
- Fixes applied: [count]
- Regressions caught and fixed: [count]
- Browser interactions tested: [count]
```

### Cleanup

```bash
rm -f /tmp/master-review-codex-{1,2,3}.txt /tmp/master-review-codex-v{1,2}.txt /tmp/master-review-ag-{1,2}.txt /tmp/master-review-ag-v{1,2}.txt
```

---

## Rules

1. **Every agent MUST be model: opus for Claude agents.** No downgrading to sonnet or haiku. Ever.
2. **Codex agents use `codex exec` with `--ephemeral -s read-only`.** They cannot modify files.
3. **Never skip the impact audit.** Every fix must be assessed for blast radius before implementation.
4. **Security findings are auto-fixed like everything else.** No user gates. The synthesis agent's validation IS the review.
5. **Agents search the ENTIRE codebase every round, not just unexplored areas.** Track what's been explored to PRIORITIZE unexplored areas, but never restrict agents from looking anywhere. A fresh pair of eyes on already-reviewed code might catch what the first reviewer missed. The explored-areas list is a hint for emphasis, not a boundary.
6. **3 consecutive clean passes means 3 rounds where ALL agents (Claude + Codex) found NOTHING new across the ENTIRE codebase.** If even one agent finds one new legitimate issue anywhere, the counter resets to 0.
7. **Do not fabricate findings to keep the loop going.** If agents genuinely find nothing, that's clean.
8. **Do not suppress findings to end the loop early.** Every finding gets validated. If it's real, the counter resets.
9. **The synthesis agent (you) is the final arbiter.** Agent findings are suggestions — you verify each one against the actual code before acting.
10. **Fully autonomous — no user approval gates.** Do not pause for user input at any point in the pipeline. The synthesis agent's validation is the quality gate. Show the user what you're doing but never wait for a response. Just keep going.
11. **Use Chrome DevTools aggressively throughout.** Connect first thing. Use it to find bugs by actively interacting with the app — click, fill forms, navigate, check console, inspect network, test edge cases (slow network, mobile, dark mode, invalid input, double-click). Browser-found bugs are first-class findings that go through the same fix pipeline. After every round of fixes, reload and re-test in the browser to catch regressions that only show up at runtime. The browser is your testing lab — code review finds potential bugs, browser testing finds actual bugs.
