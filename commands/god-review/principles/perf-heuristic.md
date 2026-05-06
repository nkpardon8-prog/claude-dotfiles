---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git show:*), Bash(git rev-parse:*), Bash(git branch:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: "Detect heuristic performance smells: nested loops, synchronous I/O in hot paths, missing memoization (Tier 2, LIKELY)"
argument-hint: "[scope]"
---

# /god-review:principles:perf-heuristic — Performance Heuristic Smell Detector

You are scanning for heuristic performance anti-patterns: nested loops with non-constant bounds, synchronous I/O in hot-looking code paths, and missing memoization on computationally expensive functions called from render or hot loops.

**THIS IS A TIER 2 LENS. Standard severity, no automatic promotion. Severity is LIKELY (heuristic — no benchmarks run).**

## The Principle

Certain code patterns reliably indicate performance problems without needing a benchmark to confirm. Nested loops over dynamic data structures are O(n²) by default. Synchronous I/O on a hot path blocks the event loop. A missing `useMemo` on an expensive calculation inside a React render causes unnecessary recomputation on every parent re-render. These patterns are worth flagging as LIKELY issues even without timing data, so the developer can make an informed decision.

## Why This Matters

- Performance regressions introduced silently are failure mode #20 — perf regression blindness
- Nested loops with dynamic bounds are the most common source of O(n²) bugs in LLM-generated code
- Synchronous I/O (`fs.readFileSync`, `requests.get`, `time.sleep`) inside request handlers or process loops blocks all concurrent work
- Missing memoization in React renders causes cascading re-renders that compound as component trees grow
- These are heuristic smells, not benchmarks — the severity is LIKELY, not definite. The developer decides whether to optimize; this lens ensures the pattern is visible.

## Phase 1: Gather Context

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"

# Load shared context if available
[ -f tmp/god-review/context-package.md ] && head -80 tmp/god-review/context-package.md

# Read AGENTS.md / CLAUDE.md for hot-path conventions
find . -maxdepth 2 \( -name "AGENTS.md" -o -name "CLAUDE.md" \) -print 2>/dev/null | head -5 | xargs -I{} cat {}

# Detect stack
ls "$WORKDIR/package.json" 2>/dev/null && echo "NODE=yes"
ls "$WORKDIR/requirements.txt" "$WORKDIR/pyproject.toml" 2>/dev/null | head -1 && echo "PYTHON=yes"
ls "$WORKDIR/go.mod" 2>/dev/null && echo "GO=yes"
ls "$WORKDIR/Cargo.toml" 2>/dev/null && echo "RUST=yes"

# Show current branch
git rev-parse --abbrev-ref HEAD
```

Use TodoWrite to log each smell candidate found.

## Phase 2: Identify Candidates

### 2.1 Nested Loops with Non-Constant Bounds

Non-constant bounds means the loop iteration count depends on a variable (array length, map size, query result count), not a literal number.

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# JavaScript/TypeScript: for...of inside for...of, or forEach inside forEach/for
grep -rn \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  --exclude-dir="node_modules" --exclude-dir=".git" --exclude-dir="dist" --exclude-dir=".next" \
  -E "for\s*\(.*of\s+[a-zA-Z]|\.forEach\(|\.map\(|\.filter\(|\.reduce\(" \
  "$WORKDIR" 2>/dev/null | grep -v "^\s*//" | head -200

# Python: nested for loops
grep -rn \
  --include="*.py" \
  --exclude-dir=".git" --exclude-dir="venv" --exclude-dir=".venv" --exclude-dir="__pycache__" \
  -E "^\s{4,}for\s+\w+\s+in\s+" "$WORKDIR" 2>/dev/null | head -100

# Go: nested range loops
grep -rn \
  --include="*.go" \
  --exclude-dir=".git" --exclude-dir="vendor" \
  -E "^\t\tfor\s+.*range\s+" "$WORKDIR" 2>/dev/null | head -50
```

For each candidate location, read the surrounding 20 lines to assess:
- Is the outer loop bounded by a literal (e.g., `for i in range(10)`)? → skip
- Is the outer loop bounded by a variable/slice/array/query result? → flag

### 2.2 Synchronous I/O in Hot-Looking Paths

"Hot-looking path" = function names matching: `process*`, `handle*`, `loop*`, `each*`, `on*`, `middleware`, `handler`, `controller`, `request`, `route`, `render`, `update`, `tick`, `run`.

```bash
# Node.js: synchronous I/O in hot paths
grep -rn \
  --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
  --exclude-dir="node_modules" --exclude-dir=".git" --exclude-dir="dist" \
  -E "fs\.readFileSync|fs\.writeFileSync|fs\.appendFileSync|fs\.existsSync|fs\.statSync|fs\.readdirSync|fs\.mkdirSync|fs\.unlinkSync|fs\.copyFileSync|execSync|spawnSync|child_process\.execSync" \
  "$WORKDIR" 2>/dev/null | head -50

# Python: blocking I/O patterns (no async)
grep -rn \
  --include="*.py" \
  --exclude-dir=".git" --exclude-dir="venv" --exclude-dir=".venv" \
  -E "requests\.(get|post|put|delete|patch|head)\(|time\.sleep\(|subprocess\.call\(|os\.system\(" \
  "$WORKDIR" 2>/dev/null | head -50

# Node: fetch without await (common accident)
grep -rn \
  --include="*.ts" --include="*.tsx" --include="*.js" \
  --exclude-dir="node_modules" --exclude-dir=".git" \
  -E "[^a]wait\s+fetch\(|[^a]wait\s+axios\." "$WORKDIR" 2>/dev/null | head -20
```

Cross-reference with hot-path function names:
```bash
# For each sync I/O hit, check if it's inside a function with a hot-looking name
for hitfile in $(grep -rln "fs\.readFileSync\|execSync\|requests\.get\|time\.sleep" "$WORKDIR" --include="*.ts" --include="*.js" --include="*.py" --exclude-dir="node_modules" 2>/dev/null | head -20); do
  grep -n "function \(process\|handle\|loop\|each\|on\|middleware\|handler\|controller\|request\|route\|render\|update\|tick\|run\)\|def \(process\|handle\|loop\|each\|on\|handle_\|process_\|run_\)" "$hitfile" 2>/dev/null | head -5
done
```

### 2.3 Missing Memoization on Expensive Function Calls from React Render or Hot Loops

```bash
# Functions named compute*, calculate*, *Heavy* that are called without useMemo
grep -rn \
  --include="*.tsx" --include="*.jsx" --include="*.ts" --include="*.js" \
  --exclude-dir="node_modules" --exclude-dir=".git" --exclude-dir="dist" \
  -E "(compute|calculate|derive|transform|aggregate|process)[A-Z][A-Za-z]*\(" "$WORKDIR" 2>/dev/null | \
  grep -v "useMemo\|useCallback\|memo(" | head -30

# Also check for *Heavy* naming convention
grep -rn \
  --include="*.tsx" --include="*.jsx" \
  --exclude-dir="node_modules" --exclude-dir=".git" \
  -E "[A-Za-z]+Heavy[A-Za-z]*\(" "$WORKDIR" 2>/dev/null | grep -v "useMemo\|memo(" | head -20
```

## Phase 3: Deep Analysis

For each candidate:

### Nested Loop Verification

1. **Confirm both bounds are non-constant.** Read the actual code, not just the grep match. If the outer loop bound is a literal number, skip.
2. **Estimate the data size.** Is this over a small enum (always ≤ 10 items)? Or over user data that could be N=10,000? Small fixed sets are not performance concerns.
3. **Check for an existing optimization.** Is there a `Map`/`Set`/`dict` lookup that could replace the inner loop?
4. **Check whether this is inside a React render, request handler, or hot update loop.** O(n²) in a startup initialization is fine; O(n²) per API request is not.

### Sync I/O Verification

1. **Confirm it's not in a build script, CLI tool, or one-time initialization.** `fs.readFileSync` in a build script is acceptable. `fs.readFileSync` inside an Express route handler is not.
2. **Confirm the enclosing function is truly a hot path.** Read the surrounding function name and its call sites.
3. **Check for an async alternative.** Does `fs.readFile` (async) or `fs.promises.readFile` exist in the codebase already?

### Memoization Verification

1. **Confirm the function is called from a component render or a hot update loop.** If it's called once at startup or in a background job, memoization isn't needed.
2. **Estimate the computation cost.** A function that iterates over <100 items and does arithmetic is fast enough to not need memoization. A function that parses large JSON or runs a complex sort over unbounded data is a candidate.
3. **Check whether memoization is already applied at the call site** via `useMemo`, `useCallback`, `memo()`, or an explicit cache variable.

## Phase 4: Generate Report

```markdown
# Performance Heuristic Smell Report

**Scope:** {scope}
**Status:** {PASS | WARN}
**Tier:** 2 (always-on, no promotion)
**Confidence:** LIKELY (heuristic — no benchmarks run; see perf-benchmark.md for measured detection)

## Summary

{N} nested loop smells. {M} synchronous I/O in hot paths. {K} missing memoization candidates.

## Nested Loops with Non-Constant Bounds

| Location | Outer Bound | Inner Bound | Hot Path? | Complexity | Recommendation | Severity |
|----------|------------|------------|-----------|-----------|---------------|----------|
| `{file}:{line}` | `{expr}` | `{expr}` | {yes/no} | O(n²) | {use Map/Set lookup, or confirm data is small} | likely |

### Detail: {file}:{line}

```{lang}
{code snippet showing the nested loop}
```

**Fix suggestion:** Replace inner loop with a pre-built `Map<{key_type}, {value_type}>` lookup. Build the map once before the outer loop (O(n) build + O(n) scan = O(n) total instead of O(n²)).

## Synchronous I/O in Hot Paths

| Location | Sync Call | Enclosing Function | Is Hot Path? | Severity |
|----------|----------|--------------------|-------------|----------|
| `{file}:{line}` | `{fn}()` | `{handler_name}` | yes | likely |

### Detail: {file}:{line}

**Fix suggestion:** Replace `{syncFn}(path)` with `await {asyncFn}(path)` and make the enclosing function `async`.

## Missing Memoization

| Location | Function Call | Enclosing Context | Estimated Cost | Severity |
|----------|--------------|-------------------|---------------|----------|
| `{file}:{line}` | `{computeFn}(...)` | React render / hot loop | {O(n) sort / JSON parse / etc.} | likely |

### Detail: {file}:{line}

**Fix suggestion:** Wrap with `useMemo(() => {computeFn}(deps), [deps])` to cache result between renders when deps haven't changed.

## Not Flagged (cleared by analysis)

| Candidate | Reason Not Flagged |
|-----------|-------------------|
| `{file}:{line}` | Outer loop over constant-size enum (≤10 items) |
| `{file}:{line}` | fs.readFileSync in build script, not request handler |
```

## Phase 5: Output

1. Save findings to `tmp/god-review/principles/perf-heuristic-findings.md`
2. Print summary:
   - PASS: no heuristic performance smells found
   - WARN: smells found (LIKELY severity — requires human judgment to confirm whether optimization is worthwhile)

```bash
mkdir -p tmp/god-review/principles
```

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; the thresholds below are principle-specific.

- **PASS**: No nested loops with non-constant bounds in hot paths, no synchronous I/O in request/event handlers, no unguarded expensive computations in React renders.
- **WARN**: Any of the above patterns found after verification. All findings are `likely` confidence — they are heuristic signals, not confirmed performance bugs.

This lens does NOT run benchmarks. For measured perf detection, see `perf-benchmark.md`.

## Risk Levels

- **HIGH**: Nested O(n²) loop inside a request handler or React render with user-controlled data sizes
- **MEDIUM**: Synchronous I/O (`readFileSync`, `requests.get`) inside an event handler or route — blocks event loop
- **LOW**: Missing memoization on a computation that is probably fast enough in practice, but would benefit from caching

## Known Issues (don't re-report)

- Load from `tmp/god-review/context-package.md` known-issues section if available
- Do NOT flag nested loops where the inner loop is over a constant-size collection (array literals, known-small enums, range(10))
- Do NOT flag `fs.readFileSync` in files that are clearly build scripts (`scripts/`, `tools/`, `build/`, `webpack.config.*`, `vite.config.*`, `rollup.config.*`)
- Do NOT flag `time.sleep` in test files — test delays are intentional
- Do NOT flag `useMemo` absence on functions that return constants or tiny computations (string concatenation, arithmetic on 2-3 fields)
- Do NOT flag synchronous patterns in CLI tools (entry points that run once and exit) — they have no concurrent work to block

Run analysis on: $ARGUMENTS (or full repo if empty).
