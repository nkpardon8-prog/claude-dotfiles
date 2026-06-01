---
description: Creates an implementation plan with thorough codebase and web research. Auto-reviews the plan after creation and iterates with user feedback. Use when planning a new feature or significant change.
argument-hint: "[feature description or ticket reference]"
allowed-tools: Read, Grep, Glob, WebFetch, WebSearch, Write, Task
expected_subagents: 4
---

# Plan Agent

## Feature: $ARGUMENTS

Generate a complete plan for feature implementation with thorough research. The plan must contain enough context for an AI agent to implement the feature in a single pass.

## Step 0: Load Discussion Briefs

Check `./tmp/briefs/` for any existing brief files. If briefs exist, read them all. These contain prior decisions, rejected alternatives, context, and direction from `/discussion` sessions. Incorporate them as **settled decisions** — do not re-litigate what was already decided unless you spot a clear technical problem.

If no briefs exist, skip this step.

## Step 1: Research (Only If Needed)

If the approach is **genuinely unclear** (and not already covered by briefs), ask the user 1-3 targeted design questions. Otherwise, proceed directly.

### Codebase Analysis
- Search for similar features/patterns in the codebase
- Identify files to reference in the plan
- Note existing conventions to follow

### External Research
- Library documentation (include specific URLs)
- Implementation examples
- Best practices and common pitfalls

## Step 2: Write the Plan

Using `.claude/commands/plan_base.md` as template.

### Critical Context to Include

The AI agent only gets the context in the plan plus codebase access. Include:
- **Documentation**: URLs with specific sections
- **Code Examples**: Real snippets from codebase
- **Gotchas**: Library quirks, version issues
- **Patterns**: Existing approaches to follow

### Implementation Blueprint

- Start with pseudocode showing approach
- Reference real files for patterns
- Include error handling strategy
- List tasks in implementation order

### Plan Guidelines

- **Required Sections** (never leave empty): Files Being Changed (tree with ← NEW / ← MODIFIED markers), Architecture Overview (proportional to complexity), Key Pseudocode (hot spots and tricky logic only), and Tasks (concrete file-level steps in order).

- **No Backwards Compatibility**: Replace things completely. No shims, fallbacks, re-exports, or compatibility layers unless user explicitly requests it.
- **Deprecated Code**: Include a section at the end to remove code we no longer use as a result of this plan.
- **No Unit/Integration Tests**: Do not include test creation in the plan.
- **Flag Uncertainty**: When uncertain about a requirement, design decision, or implementation detail, do NOT guess or assume. Insert a `[NEEDS CLARIFICATION]` marker with a brief explanation of what's unclear and why it matters. These markers must be resolved with the user before the plan is finalized.

## Step 3: Save the Plan

Save as: `./tmp/ready-plans/YYYY-MM-DD-description.md`

## Step 4: Iterative Review Loop

After saving the plan, enter an iterative review cycle. **Do not skip this step.** Repeat until the user confirms the plan is ready.

### Loop:

1. **Spawn TWO fresh plan-reviewer sub-agents in parallel** (single message, two `Task` tool calls). Two independent reviews catch more than one — overlap is signal, divergence is signal too.

```
Task tool (call 1):
  subagent_type: "plan-reviewer"
  prompt: "Review the plan at [path]. Produce a numbered list of specific,
    actionable recommendations covering gaps, simplification opportunities,
    correctness issues, and better alternatives."

Task tool (call 2, sent in the same message as call 1):
  subagent_type: "plan-reviewer"
  prompt: "Review the plan at [path]. Produce a numbered list of specific,
    actionable recommendations covering gaps, simplification opportunities,
    correctness issues, and better alternatives."
```

   When both return, merge the findings:
   - If both reviewers raised the same issue → list it once, mark as `(both reviewers)` for higher confidence
   - If only one raised it → keep it, mark as `(reviewer 1)` or `(reviewer 2)`
   - Dedupe near-duplicates by topic, not by exact wording
   - **Union the `## Assumption-Test Candidates` sections** from both reviewers (dedup by finding). Retain this merged candidate list — Step 5 reads it from the FINAL review pass.

2. **Anonymized peer-review meta-pass.**

   Skip this entire item if either reviewer's Task call failed or returned empty content — fall back to presenting the merged review as before (preserves existing feel when degraded).

   - Decide A/B assignment by simple non-positional ordering: if `($(date +%s) % 2) == 0` then reviewer-1 → Review A and reviewer-2 → Review B, else swap. The meta-agent never sees the reviewer-1/reviewer-2 mapping.

   - Spawn ONE additional plan-reviewer sub-agent in the same Task-tool style as the existing two reviewers in step 1:

   ```
   Task tool:
     subagent_type: "plan-reviewer"
     prompt: "Two reviewers independently reviewed the plan at [path].
              Their full anonymized outputs are below as Review A and Review B
              (the same numbered findings format the parallel reviewers produced).
              Answer:
              (a) Which review (A or B) raises the strongest concern, and why?
              (b) Which review (A or B) has the biggest blind spot, and what is it?
              (c) What did BOTH reviews miss that matters for this plan?
              Reference reviews by their wrapper letter (A/B) and individual
              findings by the reviewer's own numbering (e.g. 'Review A finding #3').
              Keep under 250 words.

              Review A:
              [paste full text of one reviewer's numbered findings here]

              Review B:
              [paste full text of the other reviewer's numbered findings here]"
   ```

   The `[path]` placeholder uses the same literal-placeholder convention as the two parallel reviewer prompts above — the orchestrator substitutes the actual saved-plan path at runtime.

   - If the meta-pass agent fails or times out: skip silently and proceed to step 3 with only the merged review (preserves existing behavior).

   - The meta-pass output is rendered to the user inside step 3 (Present the merged review summary) as a single bold-prose section placed BEFORE existing sub-item a) Plan Summary. Format as: `**Meta-pass:** [the meta-agent's response, lightly formatted]`. Use bold prose, NOT a level-2 H2 heading — H2 inside a numbered list item conflicts with the file's H2 hierarchy.

3. **Present the merged review summary to the user.** Provide the user with:

   **Meta-pass:** When the meta-pass from step 2 produced output, paste it here as the first thing the user sees in this presentation, formatted as a single paragraph or short bullet list. Skip this prefix if step 2 was skipped.

   **a) Plan Summary** — Summarize the key points of the plan in 3-5 bullet points so the user can quickly recall what the plan covers without re-reading it.

   **b) Reviewer Feedback with Context** — For each recommendation the reviewer raises, explain:
   - The reviewer's question or concern
   - **Context**: What the surrounding functionality does and why this matters. Reference specific files, patterns, or behaviors in the codebase so the user understands the implications.

   **c) Plan Link** — Provide the plan path so the user can open it:
   ```
   Plan: ./tmp/ready-plans/[filename]
   ```

   **d) Questions** — Ask the user whether they want to incorporate, skip, or modify each recommendation.

4. **Update the plan** based on the user's decisions. Save the updated file.

5. **Check with the user**: Ask if the plan is ready or if they want another review pass.
   - If ready → exit the loop, proceed to Step 5.
   - Otherwise → go back to loop step 1 with a fresh plan-reviewer.

### Important:
- Each review pass uses a **fresh plan-reviewer** so it evaluates the current state without bias.

## Step 5: Explain Next Steps

Once the user confirms the plan is ready:

### 5a. Assumption-test assessment (ALWAYS emit — this is mandatory, not optional)

Read the FINAL review pass's merged `## Assumption-Test Candidates` list (unioned across reviewers in Step 4). **Count the bulleted finding entries** — a section containing the `_None surfaced_` sentinel counts as **0**, NOT 1. Emit exactly ONE visible assessment line in one of three states:

- **bullets ≥ 1:**
  `Assumption-test assessment: N load-bearing assumption(s) surfaced → run /script ./tmp/ready-plans/[filename]`
- **bullets = 0:**
  `Assumption-test assessment: 0 load-bearing runtime assumptions surfaced — skipping assumption tests ([one-line reason, e.g. pure-prose/config/low-stakes change]).`
- **candidates section absent** — key this on the MERGED result after Step 4: if no `## Assumption-Test Candidates` section is present at all (degraded path — every reviewer that should have emitted one failed or returned empty). A single failed reviewer does NOT trigger this as long as the surviving reviewer emitted its section.
  `Assumption-test assessment: unavailable — reviewer output incomplete; re-run the review before relying on this.`

This line makes the de-risking decision a visible, reviewable artifact on every plan. It does NOT auto-generate scripts.

### 5b. Scope + risk

**HIGH-RISK / LARGE-SURFACE criteria** (any of):
- ≥10 files touched in Files Being Changed
- ≥1 new primitive in a critical module (auth, audit, DB layer, queue, payment, secrets)
- ≥3 assumption-test candidates from the 5a count (reuse that count — don't re-scan)
- Production-critical context (HIPAA, financial, safety-critical, real-user-impact)
- User explicitly requested "production-grade" / "lives at stake" / "100% locked in"

The assessment line in 5a already states whether to run `/script`. The messages below add the surrounding next-step framing WITHOUT repeating the bare `/script` instruction. Note HIGH-RISK is determined by the criteria above and is **independent** of the 5a count — a plan can be HIGH-RISK with 0 surfaced assumptions (e.g. ≥10 files or HIPAA context).

If HIGH-RISK **and** 5a surfaced ≥1 assumption, tell the user:

```
Plan finalized. High-risk surface detected — the assumption-test assessment above is
strongly recommended, not optional: /script proves these load-bearing assumptions against
real infrastructure BEFORE implementation, and the same tests re-run as regression catchers
after each ship — bridging the gap between text-review (which caps at a ceiling) and concrete
runtime validation.

Then to implement: /implement ./tmp/ready-plans/[filename]
```

If HIGH-RISK **but** 5a surfaced 0 assumptions (or assessment unavailable), do NOT use the cheerful low-risk message — acknowledge the risk explicitly:

```
Plan finalized. High-risk surface detected, but the reviewer cycle surfaced no
load-bearing runtime assumptions to prove — so there's nothing for /script to test here.
Proceed with care given the risk surface.

To implement: /implement ./tmp/ready-plans/[filename]
```

Otherwise (NOT high-risk):

```
Plan finalized! To implement, run:

/implement ./tmp/ready-plans/[filename]
```

## Quality Checklist

- [ ] All necessary context included
- [ ] Validation gates are executable by AI
- [ ] References existing patterns
- [ ] Clear implementation path
- [ ] Error handling documented
- [ ] Files Being Changed trees are filled in
- [ ] Architecture overview explains the big picture
- [ ] Key pseudocode covers hot spots
- [ ] No unresolved [NEEDS CLARIFICATION] markers

Score the plan 1-10 (confidence for one-pass implementation success).

## Plan Lifecycle

- **Active plans**: `./tmp/ready-plans/`
- **Completed plans**: `./tmp/done-plans/` (moved after successful implementation)
- **Cancelled plans**: `./tmp/cancelled-plans/` (moved if abandoned)
