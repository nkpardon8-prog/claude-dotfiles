---
description: Creates an implementation plan with thorough codebase and web research. Auto-reviews the plan after creation and iterates with user feedback. Use when planning a new feature or significant change.
argument-hint: "[feature description or ticket reference] [--no-tests]"
allowed-tools: Read, Grep, Glob, WebFetch, WebSearch, Write, Agent
expected_subagents: 4
---

# Plan Agent

## Feature: $ARGUMENTS

**Parse arguments first.** Check `$ARGUMENTS` for a `--no-tests` token (opt-in, additive):
- If `--no-tests` is present: set `NO_TESTS = true`, then STRIP the `--no-tests` token from `$ARGUMENTS`
  before treating the remainder as the feature description (otherwise the flag pollutes the feature text).
- If `--no-tests` is absent (the default): set `NO_TESTS = false` — tests are planned in (Step 2 default-IN rule).
- `/mission` never passes `--no-tests`, so autonomous runs always keep `NO_TESTS = false`.

The remaining (flag-stripped) `$ARGUMENTS` is the feature description used below.

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

Using `~/.claude/commands/plan_base.md` as template.

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
- **Tests default-IN**: Include test creation in the plan by default — a plan's test coverage is part of its deliverable, and `plan-reviewer` now flags any changed behavior the plan leaves uncovered. `--no-tests` is the explicit (and only) opt-out for omitting tests; `/mission` never passes `--no-tests`, so autonomous runs always plan tests.
- **Flag Uncertainty**: When uncertain about a requirement, design decision, or implementation detail, do NOT guess or assume. Insert a `[NEEDS CLARIFICATION]` marker with a brief explanation of what's unclear and why it matters. These markers must be resolved with the user before the plan is finalized.

## Step 3: Save the Plan

Save as: `./tmp/ready-plans/YYYY-MM-DD-description.md`

## Step 4: Iterative Review Loop

After saving the plan, enter an iterative review cycle. **Do not skip this step.** Repeat until the user confirms the plan is ready.

**Review-round defaults:** substantial plans default to 4-6 total review rounds (two parallel plan-reviewers + criticer per round) to diminishing returns, plus ONE parallel Codex plan pass per round via codex-exec.sh (graceful degrade when codex is unavailable — mark the degrade in the presented review).

### Loop:

1. **Spawn TWO fresh plan-reviewer sub-agents in parallel** (single message, two `Agent` tool calls) AND, in the SAME batch, kick off ONE parallel Codex plan pass (see the Codex-plan-pass block below). Two independent reviews catch more than one — overlap is signal, divergence is signal too — and the Codex pass adds a cross-model lens per round.

```
Agent tool (call 1):
  subagent_type: "plan-reviewer"
  prompt: "Review the plan at [path]. Produce a numbered list of specific,
    actionable recommendations covering gaps, simplification opportunities,
    correctness issues, and better alternatives."

Agent tool (call 2, sent in the same message as call 1):
  subagent_type: "plan-reviewer"
  prompt: "Review the plan at [path]. Produce a numbered list of specific,
    actionable recommendations covering gaps, simplification opportunities,
    correctness issues, and better alternatives."

Agent tool (call 3, sent in the SAME message as calls 1 & 2):
  subagent_type: "criticer"
  prompt: "Critique the plan at [path] as a generative value-critic. Apply up to
    5 lenses — (1) biggest gap, (2) honest assessment of where it quietly fails,
    (3) cheap win being skipped, (4) premise check (right problem?), (5) over-built
    (gold-plated / too rigid / solving non-problems). Return a `## Criticer Notes`
    block, at most 5 findings ranked by value, fewer is better, empty is fine.
    NEVER ask the user anything — state, don't ask. Do NOT emit an `## Assumption-
    Test Candidates` section. Brief(s) for intent: [resolved brief path(s) from
    Step 0, or 'none']."
```

   **Codex plan pass (one per round, in the same batch as calls 1–3).** Write the
   plan-review prompt to a temp file, then invoke the house Codex wrapper in the
   same message as the three Agent calls above so the pass runs in parallel:

```bash
PROMPT=$(mktemp "${TMPDIR:-/tmp}/plan-codex-prompt.XXXXXX")
OUT=$(mktemp "${TMPDIR:-/tmp}/plan-codex-out.XXXXXX")
cat > "$PROMPT" <<'EOF'
Review this implementation plan for gaps, correctness issues, simplification
opportunities, hidden assumptions, and contradictions. List each finding on its
own line with a severity (CRITICAL/IMPORTANT/MINOR) and a category tag
(GAP/LOGIC/ARCHITECTURE/CONTRADICTION/ASSUMPTION/SIMPLIFY). The plan text follows.
EOF
cat [path] >> "$PROMPT"   # append the saved-plan file ([path] = the Step 3 saved-plan path) so Codex reviews the real text
bash ~/.claude-dotfiles/scripts/codex-exec.sh "$PROMPT" "$OUT" "$(pwd)"
```

   When the batch returns, read `"$OUT"` and `"$OUT".status`:
   - `.status == ok` → fold the Codex findings into the merged review as a third
     lens, labeled **Codex plan pass**.
   - `.status != ok` (any of `unavailable` / `timeout` / `nonzero-<rc>`) → **graceful
     degrade**: present the literal line `(Codex plan pass: unavailable)` in place of
     Codex findings and continue with the two plan-reviewers + criticer. The degrade
     is marked in the presented review — never silently dropped.

   `criticer` is the **generative value-critic lane** — the opposite axis from the
   two fidelity reviewers. It is advisory only: it never asks, gates, or blocks, so
   it is safe under autonomous `/mission` runs. It is NOT fed into the item-2
   meta-pass (that A/B compares only the two `plan-reviewer` outputs).

   When the reviewers return, merge the findings:
   - If both reviewers raised the same issue → list it once, mark as `(both reviewers)` for higher confidence
   - If only one raised it → keep it, mark as `(reviewer 1)` or `(reviewer 2)`
   - Dedupe near-duplicates by topic, not by exact wording
   - **Union the `## Assumption-Test Candidates` sections** from the two `plan-reviewer` outputs (dedup by finding). Retain this merged candidate list — Step 5 reads it from the FINAL review pass. (`criticer` never emits this section.)
   - Hold the `criticer` output (its `## Criticer Notes` block) separately for rendering + persistence in item 3 below.

2. **Anonymized peer-review meta-pass.**

   Skip this entire item if either reviewer's Agent call failed or returned empty content — fall back to presenting the merged review as before (preserves existing feel when degraded).

   - Decide A/B assignment by simple non-positional ordering: if `($(date +%s) % 2) == 0` then reviewer-1 → Review A and reviewer-2 → Review B, else swap. The meta-agent never sees the reviewer-1/reviewer-2 mapping.

   - Spawn ONE additional plan-reviewer sub-agent in the same Agent-tool style as the existing two reviewers in step 1:

   ```
   Agent tool:
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

   **Criticer:** When the `criticer` call (item 1, call 3) returned content, render it here as `**Criticer:** [the findings]` — immediately after the `**Meta-pass:**` line if present, otherwise as the first advisory block; in both cases BEFORE sub-item a) Plan Summary. **Strip the leading `## Criticer Notes` header** for this inline render (bold prose, NOT a level-2 H2 — same H2-collision constraint as the meta-pass). Then **persist** the block into the plan file: locate a line matching `^## Criticer Notes$`; if present, replace from that line up to (but not including) the next `^## ` line or EOF; if absent, append the full `## Criticer Notes` block at end of file (idempotent — re-running the loop replaces, never duplicates). If `criticer` failed or returned empty, skip this prefix and the persist silently (same as the meta-pass skip-on-failure rule). The criticer block is advisory: never treat it as a gate, and never auto-apply its findings.

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
