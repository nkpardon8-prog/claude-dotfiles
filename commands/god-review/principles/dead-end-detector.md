---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git rev-parse:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Detect computed values never consumed (dead-end variables, unused functions, parsed flags never honored, state fields written but never read)
argument-hint: "[scope]"
---

# /god-review:principles:dead-end-detector — Dead-End Value Detection

**Tier 1. Always promoted. Findings promoted one confidence level before section assignment.**

## The Principle

Every value that is computed, assigned, or produced must be consumed somewhere. Variables set but never read, functions defined but never called, flags parsed but never honored, state fields written but never read, and tool-call outputs discarded — all represent dead-ends where work is done but the result goes nowhere. Dead-ends are especially dangerous in agent/orchestrator codebases where silent data loss is indistinguishable from a successful no-op.

## Why This Matters

- Dead-end variables create a false impression of correctness: the code "does something" but the result is thrown away
- Parsed flags that are never honored give users a false sense of control
- State fields written but never read cause state.json bloat and mislead future maintainers
- Tool-call outputs discarded at the call site mean the tool ran for nothing — the finding/result is lost
- In multi-phase orchestrators, dead-ends in early phases silently corrupt later phases that expected those values

Reference: failure mode #7 (hallucination cascade), #14 (overcomplication) in `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md`

## Phase 1: Gather Context

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$WORKDIR/tmp/god-review/.env.sh" ] && source "$WORKDIR/tmp/god-review/.env.sh"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"
```

- Read `$WORKDIR/tmp/god-review/context-package.md` if it exists; otherwise use the context gathered above
- Get scope: `$ARGUMENTS` if provided, otherwise full changed-file list from git diff

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$WORKDIR/tmp/god-review/.env.sh" ] && source "$WORKDIR/tmp/god-review/.env.sh"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"

# Determine target file set
if [ -n "$ARGUMENTS" ]; then
  echo "Scope: $ARGUMENTS"
else
  git -C "$WORKDIR" diff main...HEAD --name-only 2>/dev/null | head -100 || \
    find "$WORKDIR" \( -name "*.md" -o -name "*.sh" -o -name "*.ts" -o -name "*.py" \) \
      ! -path "*/node_modules/*" ! -path "*/.git/*" | head -100
fi
```

Use TodoWrite to track each category of dead-end candidates identified.

## Phase 2: Identify Candidates

**This phase uses Claude-agent reasoning, NOT mechanical grep.** The agent reads the target files and reasons about data flow. Fixed regex patterns produce massive false positives on markdown — especially on documentation that describes code rather than executes it.

For each target file, read its contents and reason through the following categories:

### 2.1 Variable Assignments

Read the file and identify every place a variable is assigned a value. For each assignment, ask:
- Is this variable referenced elsewhere in the file (other than the assignment line)?
- Is this variable written to a shared state store (e.g., `.env.sh`, `state.json`, exported) so it can be consumed in another scope?
- If neither — flag it as a candidate dead-end variable.

Use Grep selectively when a variable name is short/common: search for `$VARNAME`, `${VARNAME}`, `"$VARNAME"` across the scope. The agent decides what to search for based on what it read, not a fixed pattern.

### 2.2 Function Definitions

Read each function definition and identify:
- Is the function name referenced anywhere in the codebase (excluding the definition itself)?
- Is it exported or added to a dispatch table?
- If neither — flag as a candidate unused function.

Use Grep to search for the function name across the scope when uncertain.

### 2.3 Flag Declarations

Identify every flag/argument parsed (e.g., `--flag` → `FLAG=true`, `argparse.add_argument`, flag parsing blocks). For each flag:
- Trace the variable through the code: is its value read to affect runtime behavior?
- A flag that is parsed and stored but never checked at decision points is a dead-end.
- Pay special attention to flags added to documentation/usage but absent from runtime logic.

### 2.4 State Field Writes

Identify every write to a shared state store (state.json fields, `.env.sh` exports, config hashes). For each write:
- Is this field read back by any subsequent phase or block?
- If a field is initialized and overwritten but never read between writes — it is a dead-end write.

### 2.5 Tool-Call Outputs

Identify every external tool invocation (Bash calls, subagent spawns, API calls). For each:
- Is the return value / stdout captured and used?
- Does the tool write to a file that is subsequently read?
- If the output goes nowhere — flag as discarded tool output.

## Phase 3: Deep Analysis

For each candidate identified in Phase 2:

1. Read the surrounding context more carefully — the consumption may be in a different conditional branch
2. Search the wider codebase (not just the diff) for usage if the identifier looks like it could be consumed elsewhere
3. Consider lifecycle: is this value set in Phase N and consumed in Phase N+1 of a multi-phase system? If so, verify the handoff mechanism exists and actually propagates it
4. Distinguish between: (a) genuinely dead — never consumed anywhere, (b) conditionally dead — consumed only in a branch that is unreachable, (c) cross-scope dead — set in one bash fence but the next fence never sources it

Apply confidence levels per CRITERIA.md:
- `definite`: assigned and demonstrably never referenced anywhere in scope
- `likely`: assigned, referenced zero times in current scope, no visible cross-scope handoff
- `investigate`: assigned, referenced rarely, pattern suggests it was intended to be used more broadly

## Phase 4: Generate Report

Save findings to `$WORKDIR/tmp/god-review/principles/dead-end-detector-findings.md`:

```markdown
# Dead-End Detector Report

**Scope:** {scope}
**Status:** {PASS | WARN | FAIL}
**Risk Level:** {LOW | MEDIUM | HIGH | CRITICAL}

## Summary

{Overall assessment of dead-end severity}

## Findings

### Variables Set But Never Read

| Location | Variable | Assignment | Evidence of Non-Use | Confidence |
|----------|----------|------------|---------------------|------------|
| file:line | $VAR | VAR=... | searched scope, 0 non-assignment refs | definite |

### Functions Defined But Never Called

| Location | Function | Evidence | Confidence |
|----------|----------|----------|------------|

### Flags Parsed But Never Honored

| Flag | Parsed At | Expected Runtime Check | Confidence |
|------|-----------|------------------------|------------|

### State Fields Written But Never Read

| Store | Field | Written At | Read At | Confidence |
|-------|-------|------------|---------|------------|

### Tool Outputs Discarded

| Location | Tool/Command | Return Value Fate | Confidence |
|----------|-------------|-------------------|------------|

## False Positives Ruled Out

{List any candidates that were checked and ruled out — shows analysis was thorough}
```

## Phase 5: Output

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$WORKDIR/tmp/god-review/.env.sh" ] && source "$WORKDIR/tmp/god-review/.env.sh"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"

mkdir -p "$WORKDIR/tmp/god-review/principles"
# (Report written by Phase 4 above)
echo "dead-end-detector: complete. Results in $WORKDIR/tmp/god-review/principles/dead-end-detector-findings.md"
```

Print PASS/WARN/FAIL summary with count of dead-end findings by category.

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; thresholds below are principle-specific.

- PASS: No dead-end values found, or candidates are ruled out by cross-scope handoff verification
- WARN: 1–3 dead-end variables or one unused function; no flags or state fields affected
- FAIL: Any flag parsed but never honored at runtime; any state field written in a critical path but never read; 4+ dead-end variables

## Risk Levels

- LOW: Dead-end variables in non-critical paths; no behavioral impact
- MEDIUM: Dead-end variables in phase-boundary code; could indicate missing handoff
- HIGH: Flag parsed but never honored (user-facing behavioral gap); state field overwritten without read (phase data lost)
- CRITICAL: Multiple flags dead-end; tool-call output discarded in critical path (findings silently lost); cross-phase variable dies at a bash fence boundary

## Known Issues (don't re-report)

Loaded from `$WORKDIR/tmp/god-review/context-package.md` known-issues section if present. Skip any dead-end already flagged in prior rounds per `$WORKDIR/tmp/god-review/state.json`.

Run analysis on: $ARGUMENTS (or full repo if empty).
