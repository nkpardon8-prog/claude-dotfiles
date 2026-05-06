---
allowed-tools: Bash(git diff:*), Bash(git log:*), Bash(git rev-parse:*), Bash(grep:*), Bash(find:*), Read, Grep, Glob, TodoWrite
description: Detect required functionality referenced but not implemented — flags parsed but never honored at runtime, documentation describing behavior the code doesn't have, required state fields read but never written, Phase pseudocode never becoming real shell
argument-hint: "[scope]"
---

# /god-review:principles:gap-detector — Implementation Gap Detection

**Tier 1. Always promoted. Findings promoted one confidence level before section assignment.**

## The Principle

A gap is when something is expected to exist but doesn't. The README describes a flag's behavior, but the orchestrator never acts on it. The architecture doc says Phase 3 does X, but the actual Phase 3 does not contain X. A state.json field is read with `jq .field_name` but no code ever writes that field. A function is called at line 200 but never defined. Gaps differ from dead-ends (values produced but not consumed) and info-loss (data that exists but doesn't propagate) — a gap is the absence of something that should exist.

Gaps are the hardest failure class to detect because the missing code leaves no trace in the codebase. You have to infer what should be there from what references it.

## Why This Matters

- Users or downstream systems depend on behavior that is claimed to exist but doesn't
- Flags parsed and stored but never honored at runtime give users false confidence they are controlling something they are not
- State fields read but never written cause runtime KeyError / null-dereference in exactly the paths that need them most
- "Phase X does Y" in documentation creates a false specification that future developers implement based on, compounding the gap
- Pseudocode blocks that look like implementation are the most dangerous gaps: they pass grep-based reviews because the text is present, but they never execute

Reference: failure mode #5 (specification fiction), #8 (unimplemented scaffolding) in `~/.claude/projects/-Users-omidzahrai/memory/god_review_problems.md`

## Phase 1: Gather Context

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$WORKDIR/tmp/god-review/.env.sh" ] && source "$WORKDIR/tmp/god-review/.env.sh"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"
```

- Read `$WORKDIR/tmp/god-review/context-package.md` if it exists; otherwise use context gathered above
- Get scope: `$ARGUMENTS` if provided, otherwise full changed-file list

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$WORKDIR/tmp/god-review/.env.sh" ] && source "$WORKDIR/tmp/god-review/.env.sh"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"

if [ -n "$ARGUMENTS" ]; then
  echo "Scope: $ARGUMENTS"
else
  git -C "$WORKDIR" diff main...HEAD --name-only 2>/dev/null | head -100 || \
    find "$WORKDIR" \( -name "*.md" -o -name "*.sh" -o -name "*.ts" -o -name "*.py" \) \
      ! -path "*/node_modules/*" ! -path "*/.git/*" | head -100
fi
```

Use TodoWrite to track each "expected functionality" signal identified and whether it has a corresponding implementation.

## Phase 2: Identify Candidates

**This phase uses Claude-agent reasoning, NOT mechanical grep.** The agent reads the target files and looks for "expected functionality" signals — references to behavior that should exist — then searches for the corresponding implementation. Mechanical grep produces false positives on markdown documentation that describes expected behavior in prose.

Read all target files completely. Then reason through the following categories:

### 2.1 Flags Parsed But Never Honored

Identify every flag or argument that is parsed from the command line or argument string (look for argument parsing blocks, flag-to-variable assignments, getopt/argparse/manual parsing). For each flag:
- Trace the variable the flag is stored in through the rest of the codebase
- Ask: is there any conditional branch (`if [ "$FLAG" = "true" ]`, `if args.flag:`, etc.) that reads this variable and changes runtime behavior?
- A flag that is parsed into a variable but that variable is never read in a conditional = a gap

Use Grep selectively to search for the variable name in conditional contexts across the scope when uncertain.

### 2.2 Documentation Describing Absent Behavior

Read all documentation files (README, AGENTS.md, CLAUDE.md, comments, docstrings) for behavioral claims. For each behavioral claim:
- "When --flag is set, the orchestrator will X" — does the code actually do X when the flag is set?
- "Phase N does X" — does Phase N actually contain code that does X?
- "The system supports Y" — is there code that implements Y?

Do NOT flag claims that are clearly aspirational or future-planned (look for "TODO", "planned", "future"). Flag claims stated as current fact that have no corresponding implementation.

### 2.3 State Fields Read But Never Written

Identify every read from a shared state store (state.json reads with `jq`, Python dict reads, `.env.sh` variable references with `$VAR`). For each field that is read:
- Is there code that writes that exact field to the store before the read?
- Does the write happen in the correct phase ordering (written before it is read, not after)?
- Does the write happen in all code paths that lead to the read, or only some?

Flag as gap: any field read from state that is never written to it; any field that is only written in some paths but read unconditionally.

### 2.4 Called Functions / Referenced Entities That Don't Exist

Identify every function call, import, source command, or reference to an external file. For each:
- Does the referenced function/file/module actually exist in the codebase?
- Is the function defined before it is called (in a single-pass interpreter context)?

Use Grep to search for definitions when uncertain. Flag any reference to a non-existent function, file, or module.

### 2.5 Pseudocode Blocks That Are Not Real Implementation

In markdown orchestrator files, identify fenced code blocks (` ```bash `, ` ```python `, etc.) and assess whether they are:
- Real implementation: executable code that will actually run when the slash command is invoked
- Pseudocode / example: explanatory code that is never executed (typically in documentation sections, "Delta Design" sections, plan descriptions)

For pseudocode blocks that describe functionality: verify that there is a corresponding real implementation block elsewhere in the same file. If the pseudocode describes a feature and no corresponding real bash block implements it, flag as an implementation gap.

This is particularly important for multi-phase orchestrators where a "Phase N" prose description with a pseudocode block may be the only representation of that phase — with no actual shell that runs during execution.

### 2.6 Extension Points Without Implementation

Identify any declared extension point (plugin system, hook system, event system, "add your principle here" instructions) and verify that the extension mechanism actually exists in the runtime code. Documentation that says "to add a principle, create a file in principles/" is a gap if the orchestrator's principle-loading logic doesn't actually scan that directory.

## Phase 3: Deep Analysis

For each candidate:

1. Read the full implementation context — the gap may be implemented in a different file or a different phase than expected
2. For flags: search both the same file and related files (subagent prompts, lib scripts) for the flag variable being used in conditionals
3. For state fields: trace the full execution path — the write may happen in a subagent that is spawned, not in the main orchestrator
4. For missing functions: check all sourced files and imported modules — the function may be defined externally
5. Distinguish between: (a) complete gap — not implemented anywhere, (b) partial gap — implemented but only in some paths, (c) hidden implementation — implemented in a sourced file or subagent not visible in the target scope

Apply confidence levels per CRITERIA.md:
- `definite`: flag parsed, variable clearly never read in any conditional; function called, demonstrably not defined anywhere in scope
- `likely`: referenced behavior or field appears to have no implementation after thorough search; may exist in unseen scope
- `investigate`: implementation may exist but is hard to trace; flag for manual verification

## Phase 4: Generate Report

Save findings to `$WORKDIR/tmp/god-review/principles/gap-detector-findings.md`:

```markdown
# Gap Detector Report

**Scope:** {scope}
**Status:** {PASS | WARN | FAIL}
**Risk Level:** {LOW | MEDIUM | HIGH | CRITICAL}

## Summary

{Overall assessment — count of gaps by category, severity}

## Findings

### Flags Parsed But Never Honored

| Flag | Parsed At | Variable | Searched For Runtime Use | Result | Confidence |
|------|-----------|----------|--------------------------|--------|------------|
| --flag | file:line | $FLAG | searched all conditionals | 0 reads | definite |

### Documentation Describing Absent Behavior

| Claim | Source | Implementation Expected | Found? | Confidence |
|-------|--------|------------------------|--------|------------|
| "Phase N does X" | README:line | code block in Phase N | no | likely |

### State Fields Read But Never Written

| Store | Field | Read At | Written At | Gap Description | Confidence |
|-------|-------|---------|-----------|-----------------|------------|

### Called Functions / Files That Don't Exist

| Reference | Called At | Definition Found? | Confidence |
|-----------|-----------|-------------------|------------|

### Pseudocode Without Implementation

| Pseudocode Block | File:Line | Describes | Real Implementation? | Confidence |
|------------------|-----------|----------|----------------------|------------|

### Extension Points Without Runtime Support

| Extension Claim | Documented At | Runtime Code | Gap | Confidence |
|----------------|---------------|-------------|-----|------------|

## False Positives Ruled Out

{List candidates verified to have implementations — shows analysis was exhaustive}
```

## Phase 5: Output

```bash
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
[ -f "$WORKDIR/tmp/god-review/.env.sh" ] && source "$WORKDIR/tmp/god-review/.env.sh"
[ -f "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh" ] && source "$HOME/.claude-dotfiles/commands/god-review/lib/gather-context.sh"

mkdir -p "$WORKDIR/tmp/god-review/principles"
echo "gap-detector: complete. Results in $WORKDIR/tmp/god-review/principles/gap-detector-findings.md"
```

Print PASS/WARN/FAIL summary with count of gaps by category.

## Scoring Criteria

See `~/.claude-dotfiles/commands/god-review/CRITERIA.md` for confidence/severity definitions; thresholds below are principle-specific.

- PASS: All flags honored at runtime; all documented behavior implemented; all state reads have corresponding writes; all referenced functions exist
- WARN: 1–2 documentation claims that are overstated but have partial implementation; pseudocode blocks that describe non-critical paths with no real implementation
- FAIL: Any flag parsed but never used in any conditional; any state field read unconditionally but never written; any function called that doesn't exist; any Phase N described as doing X with no corresponding implementation

## Risk Levels

- LOW: Documentation slightly overstates behavior in non-critical areas; pseudocode describes aspirational behavior clearly labeled as future
- MEDIUM: Flag has no runtime effect (user thinks they are controlling behavior they aren't); state field written in some paths but not all paths that read it
- HIGH: Core feature described in README has no implementation; state field that drives phase logic is never written (causes runtime failure on first use)
- CRITICAL: Flag that is supposed to activate safety behavior (e.g., hard-gate checking) is parsed but never triggers any gate logic; multiple Phase N descriptions with pseudocode but no real bash that executes

## Known Issues (don't re-report)

Loaded from `$WORKDIR/tmp/god-review/context-package.md` known-issues section if present. Skip any gap already flagged in prior rounds per `$WORKDIR/tmp/god-review/state.json`.

Run analysis on: $ARGUMENTS (or full repo if empty).
