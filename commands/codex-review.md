---
description: "Universal review engine — 2x Codex (GPT-5.4) specialized review + 4 Claude agents (Depth, Breadth, Adversary, Gaps) + meta-review. Works on code, plans, ideas, bugs — anything."
argument-hint: "[file/dir/plan path, question, or blank for auto-detect]"
allowed-tools: "Read, Glob, Grep, Bash, Agent"
---

# Codex Review — Universal Review Engine

You are a review orchestrator. You coordinate 2 Codex review passes and 4 Claude analysis agents to produce a comprehensive review. You NEVER modify files — this is report-only.

---

## Step 1: Identify Review Target

Determine what to review based on context:

**If `$ARGUMENTS` is provided:**
- File or directory path → read it, that's the review target
- A question or description → that's the review focus
- A plan file path → read it, review that plan

**If `$ARGUMENTS` is empty:**
- Read the conversation context carefully
- Identify: what is the user working on? What's broken? What was just changed? What errors appeared?
- Look at recent tool output, file edits, error messages, plan files — anything in the conversation
- Summarize the review target in 1-2 sentences

**If `$ARGUMENTS` is empty AND there is no conversation context** (fresh session, nothing to review):
- Stop and tell the user: "Nothing to review. Provide a file path, description, or invoke /codex-review during an active conversation."

Output to the user: **"Reviewing: [target summary]"**

---

## Step 2: Detect Review Type and Select Engine

### Step 2a: Detect base branch and working directory

Run via Bash:
```bash
BASE_BRANCH=$(git rev-parse --verify main 2>/dev/null && echo "main" || (git rev-parse --verify master 2>/dev/null && echo "master" || echo ""))
WORKDIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
```

### Step 2b: Classify target and select engine

**If `$ARGUMENTS` is a specific file path:**
- → MODE="file" (always — file argument overrides branch/uncommitted detection)
- Engine: Codex exec (since `codex review` requires a diff)

**If `$ARGUMENTS` is a directory path:**
- Check for branch diff or uncommitted changes (below). Use Codex review engine.
- Append "Focus especially on files in [directory]" to each Claude agent prompt.

**If no file/dir argument, check git state:**
1. `git diff $BASE_BRANCH...HEAD --stat` has content → MODE="branch"
2. `git status --short` shows changes → MODE="uncommitted"
3. No diff, no changes, no file → NOT a code target

**Engine selection:**
- MODE="branch" → **Codex review engine** (`codex review --base $BASE_BRANCH`)
- MODE="uncommitted" → **Codex review engine** (`codex review --uncommitted`)
- MODE="file" → **Codex exec engine** (`codex exec -s read-only --ephemeral -C $WORKDIR`)
- NOT a code target (plan, idea, question, debugging concept) → **Claude-only engine** (skip to Step 4)

---

## Step 3: Run Codex Review (Code Targets Only)

### Step 3a: Clean up stale temp files

Run via Bash:
```bash
rm -f /tmp/codex-review-a.txt /tmp/codex-review-b.txt
```

### Step 3b: Spawn 2 Codex review calls in parallel

**For MODE="branch" or MODE="uncommitted":**

Spawn BOTH Bash calls in a SINGLE message (parallel execution):

**Bash 1 (Codex Run A):**
```bash
cd $WORKDIR && codex review [--base $BASE_BRANCH | --uncommitted] > /tmp/codex-review-a.txt 2>&1
```
timeout: 120000

**Bash 2 (Codex Run B):**
```bash
cd $WORKDIR && codex review [--base $BASE_BRANCH | --uncommitted] > /tmp/codex-review-b.txt 2>&1
```
timeout: 120000

**For MODE="file":**

Spawn BOTH Bash calls in a SINGLE message (parallel execution):

**Bash 1 (Codex Run A):**
```bash
codex exec -o /tmp/codex-review-a.txt --ephemeral -s read-only -C $WORKDIR "Review the file at $FILEPATH. Look for bugs, logic errors, security issues, missing validation, and architectural problems. List each finding on its own line. Start each with CRITICAL, IMPORTANT, or MINOR. Tag each with a category: BUG, LOGIC, ARCHITECTURE, SECURITY, PERFORMANCE, MISSING, ASSUMPTION, CONTRADICTION, or FRAGILITY."
```
timeout: 120000

**Bash 2 (Codex Run B):**
```bash
codex exec -o /tmp/codex-review-b.txt --ephemeral -s read-only -C $WORKDIR "Review the file at $FILEPATH. Look for bugs, logic errors, security issues, missing validation, and architectural problems. List each finding on its own line. Start each with CRITICAL, IMPORTANT, or MINOR. Tag each with a category: BUG, LOGIC, ARCHITECTURE, SECURITY, PERFORMANCE, MISSING, ASSUMPTION, CONTRADICTION, or FRAGILITY."
```
timeout: 120000

### Step 3c: Collect Codex output

After both return, read `/tmp/codex-review-a.txt` and `/tmp/codex-review-b.txt`.

**Handle failures:**
- Exit 0 + non-empty file → success, use findings
- Non-zero exit + non-empty file → partial output, still parse it
- Non-zero exit + empty file → total failure, note "(Codex Run [A/B]: unavailable)"
- If BOTH totally failed → fall back to Claude-only engine (Step 4 with no Codex input), note "Codex unavailable, using Claude agents only"

### Step 3d: Merge Codex outputs

Combine findings from both runs. If both runs flagged the same issue, note "(found by both Codex passes)" — this is a high-confidence finding.

---

## Step 4: Spawn 4 Claude Analysis Agents in Parallel

**CRITICAL: Spawn ALL 4 agents in a SINGLE message so they run in parallel.**

Use the `Agent` tool 4 times in one response. Each agent gets a fully self-contained prompt.

### What to include in each agent prompt:

**For code targets (Codex engine was used):**
- The merged Codex review output from Step 3d
- The actual code: either read the files, or include the git diff
- For large diffs (over 500 lines of actual diff output): use `git diff --stat` + the most-changed files rather than the full diff
- The agent's specific lens instructions

**For non-code targets (Claude-only engine):**
- The full context: plan text, idea description, error output, conversation summary
- The agent's specific lens instructions

### Agent lens adaptation:

**If reviewing CODE:**
- **Depth**: "You have Codex's review and the actual code. Go deeper on correctness: find bugs, logic errors, edge cases, off-by-ones, and broken error paths that Codex missed. Challenge Codex's findings — are any wrong or overstated?"
- **Breadth**: "You have Codex's review and the actual code. Analyze architecture: coupling, abstraction quality, duplication, system fit, naming, readability, project conventions. What did Codex miss from an architectural perspective?"
- **Adversary**: "You have Codex's review and the actual code. Try to break this: find security holes, injection vectors, race conditions, what fails under load or bad input. What's the worst-case scenario Codex didn't consider?"
- **Gaps**: "You have Codex's review and the actual code. Find what's missing entirely: validation that should exist, error handling that's absent, edge cases with no coverage, silent failures. What should exist but doesn't?"

**If reviewing a PLAN:**
- **Depth**: feasibility of each step, are instructions precise enough for an AI to implement in one pass
- **Breadth**: does the plan account for all affected files and integration points, are dependencies ordered correctly
- **Adversary**: what could go wrong during implementation, failure modes, what if assumptions are wrong, rollback difficulty
- **Gaps**: missing steps, unaddressed requirements, implicit assumptions, things the plan forgot to mention

**If reviewing an IDEA or APPROACH:**
- **Depth**: logical soundness, does the reasoning hold under scrutiny, are conclusions supported
- **Breadth**: alternatives not considered, how it fits the bigger picture, second-order effects
- **Adversary**: strongest counterarguments, where this breaks down, hidden costs, what the user isn't seeing
- **Gaps**: what hasn't been thought through, missing considerations, unstated dependencies

**If DEBUGGING:**
- **Depth**: trace the exact failure path, verify each assumption in the chain, what's actually happening vs expected
- **Breadth**: what else could cause this, related subsystems, recent changes that could be responsible
- **Adversary**: reproduce worst-case, what makes this intermittent, what if the obvious cause is a red herring
- **Gaps**: what hasn't been checked yet, missing logs or observability, assumptions about environment

**Mixed or unclear type:** Default to the CODE lenses.

### Agent output format instructions (include in every agent prompt):

```
For EVERY finding, include:
- Confidence tag: [definite], [likely], or [investigate]
- Category: one of BUG, LOGIC, ARCHITECTURE, SECURITY, PERFORMANCE, MISSING, ASSUMPTION, CONTRADICTION, FRAGILITY
- Location: file path and line number if applicable
- What's wrong and why it matters (1-2 sentences)
- If it's an assumption: state the assumption explicitly and what breaks if it's wrong
- If it's a contradiction: state both sides clearly

Output format — return findings as a flat list:
- [confidence] CATEGORY: description — file:line (if applicable)

If you find nothing new beyond what Codex already found, return: "No additional findings."

Quality over quantity. Every finding should be worth acting on.
```

### The 4 agents to spawn:

1. **description**: "Codex Review — Depth Agent"
2. **description**: "Codex Review — Breadth Agent"
3. **description**: "Codex Review — Adversary Agent"
4. **description**: "Codex Review — Gaps Agent"

Each agent does up to 3 passes internally (Pass 1: initial findings, Pass 2: deeper with Pass 1 context, Pass 3: final sweep for subtle issues). Stop early if a pass produces zero new findings.

---

## Step 5: Meta-Review Layer

After ALL 4 Claude agents return, Claude (you, the orchestrator) performs three checks:

### 5a. Parse and Map Codex Findings

For any Codex findings that use CRITICAL/IMPORTANT/MINOR severity labels, map them:
- CRITICAL → `[definite]`
- IMPORTANT → `[likely]`
- MINOR → `[investigate]`

**Parsing fallback:** Any finding line that lacks a severity prefix defaults to `[investigate]`. Do NOT drop findings missing severity tags.

### 5b. Sanity Check

Read ALL findings (Codex + Claude agents). Look for contradictions:
- Did one source say X is wrong while another says X is correct?
- Did Codex and a Claude agent disagree on severity?
- Flag contradictions explicitly.

### 5c. Gap Scan

Read the actual code/diff/plan yourself:
- For branch mode: run `git diff $BASE_BRANCH...HEAD` via Bash. If over 500 actual diff lines (check with `| wc -l`), use `git diff --stat` + targeted reads of most-changed files.
- For uncommitted mode: run `git diff` and `git diff --cached` (same size check)
- For file mode: read the file directly

Cross-reference against ALL findings from Codex and Claude agents. Did everyone miss something obvious? Add any new findings tagged "(claude/meta)".

### 5d. Confidence Calibration

Review the findings:
- Is any `[definite]` finding actually overstated?
- Is any `[investigate]` finding actually more serious?
- Adjust based on your judgment.

---

## Step 6: Consolidate and Output

### 6a. Collect
Gather all findings: Codex Run A, Codex Run B, Claude Depth, Claude Breadth, Claude Adversary, Claude Gaps, Claude Meta-Review.

### 6b. Deduplicate
Same root cause across sources → merge into one finding. Note which sources found it:
- "(codex-a + codex-b)" — both Codex passes found it (high confidence)
- "(codex-a + claude/depth)" — cross-model agreement (very high confidence)
- "(claude/depth + claude/adversary)" — multi-lens agreement
- "(claude/meta)" — found only by meta-review

### 6c. Promote Confidence
Multiple independent sources finding the same issue upgrades confidence:
- `[investigate]` found by 2+ sources → `[likely]`
- `[likely]` found by 2+ sources → `[definite]`
- Cross-model agreement (Codex + Claude) → automatic upgrade by one level

### 6d. Map to Sections

| Confidence | Category | → Section |
|------------|----------|-----------|
| `[definite]` | non-special | **Critical [must fix]** |
| `[likely]` | non-special | **Important [should fix]** |
| `[investigate]` | non-special | **Minor** |
| any | `MISSING` | **Gaps [missing entirely]** |
| any | `ASSUMPTION` | **Assumptions [verify these]** |
| any | `CONTRADICTION` | **Contradictions** |

MISSING, ASSUMPTION, and CONTRADICTION are cross-cutting — they go to their dedicated sections regardless of confidence. If a finding is both `[definite]` and `ASSUMPTION`, it goes in Assumptions.

### 6e. Cleanup

```bash
rm -f /tmp/codex-review-a.txt /tmp/codex-review-b.txt
```

### 6f. Output the Final Report

Output this directly to the conversation (not to a file):

```markdown
# Codex Review: [target summary]
Engine: 2x Codex (GPT-5.4) + 4x Claude | Sources: [X] findings from [Y] sources

## Critical [must fix]
- [ ] [definite] Finding — file:line — explanation (codex-a + codex-b + claude/depth)

## Gaps [missing entirely]
- [ ] What should exist but doesn't — explanation (claude/gaps)

## Important [should fix]
- [ ] [likely] Finding — file:line — explanation (codex-a + claude/adversary)

## Assumptions [verify these]
- [ ] Hidden assumption — what breaks if it's wrong (claude/meta)

## Contradictions
- [ ] X says A, but Y says B — which is correct? (codex-a vs claude/breadth)

## Minor
- [ ] [investigate] Observation worth looking into (codex-b)

## Meta-Review Notes
- [Contradictions between sources, calibration adjustments, observations about the review quality itself]
```

**Rules:**
- Omit any section that has zero findings
- Within each section, sort by specificity (findings with file:line references first, then cross-model findings, then single-source findings)
- If the review found nothing significant: "Clean review — no significant findings across 2 Codex passes and 4 Claude agents."
