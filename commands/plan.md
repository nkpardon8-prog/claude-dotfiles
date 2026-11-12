---
description: Creates an implementation plan with thorough codebase and web research. Auto-reviews the plan after creation and iterates with user feedback. Use when planning a new feature or significant change.
argument-hint: "[feature description or ticket reference] [--no-tests] [--roadmap] [--mission --round <K> --ledger <file> --report <path>]"
allowed-tools: Read, Grep, Glob, WebFetch, WebSearch, Write, Agent, Bash
expected_subagents: 4
---

# Plan Agent

## Feature: $ARGUMENTS

**Parse arguments first.** Check `$ARGUMENTS` for a `--no-tests` token (opt-in, additive):
- If `--no-tests` is present: set `NO_TESTS = true`, then STRIP the `--no-tests` token from `$ARGUMENTS`
  before treating the remainder as the feature description (otherwise the flag pollutes the feature text).
- If `--no-tests` is absent (the default): set `NO_TESTS = false` — tests are planned in (Step 2 default-IN rule).
- `/mission` never passes `--no-tests`, so autonomous runs always keep `NO_TESTS = false`.

**Mode flags (used by `/mission`; absent = the interactive flow below, unchanged).** Strip them the same way:
- `--roadmap` - the strategist: run "Roadmap mode" at the end of this file instead of Steps 2-5.
- `--mission --round <K> --ledger <file> --report <path>` - one autonomous, design-level plan round: follow "Mission mode" at the end of this file; it overrides Steps 1-5 where it says so.

The remaining (flag-stripped) `$ARGUMENTS` is the feature description used below.

Generate a complete plan for feature implementation with thorough research. The plan must contain enough context for an AI agent to implement the feature in a single pass.

## Step 0: Load Discussion Briefs

Check `./tmp/briefs/` for any existing brief files. If briefs exist, read them all. These contain prior decisions, rejected alternatives, context, and direction from `/discussion` sessions. Incorporate them as **settled decisions** — do not re-litigate what was already decided unless you spot a clear technical problem.

If no briefs exist, skip this step.

## Step 1: Research (parallel fan-out - skip only per the exceptions below)

If the approach is genuinely unclear (and not already covered by briefs), ask the user 1-3 targeted design questions.

**CRITICAL - research is a parallel fan-out, not orchestrator reading: spawn ALL research agents in a SINGLE message.** Reading the codebase yourself instead of fanning out is a playbook violation, not a shortcut.

### Skip conditions (the only two)

- **(a) Trivially single-file** - the change is confined to one already-identified file. Say so explicitly in the plan (e.g. "Research skipped: single-file change to `<path>`").
- **(b) Supplied research exists** - the invocation names a dossier / research path, OR any `./tmp/briefs/*-research/` directory shares a name token with the feature. Read that instead of re-deriving it.

When in doubt, fan out: a redundant explorer costs minutes, a memory-built plan costs a bad plan.

### The fan-out (all calls in one message)

- **`codebase-explorer` #1 - files, patterns, conventions** for the feature itself: where this kind of thing already lives, what the house pattern is, what the plan must follow.
- **`codebase-explorer` #2 - integration points + prior art**: callers, wiring, config/registration surfaces, and the nearest adjacent feature that already solved a similar problem.
- **`researcher` - ONLY if external libraries/docs are involved**: library documentation (with specific URLs), version quirks, published implementation examples. Omit this call entirely when the work is in-repo only.

Every research prompt MUST:

- Pass the Step 0 brief path(s) (or the literal `none`) so the agent inherits the settled decisions.
- Require the report shape `Fact / Evidence file:line / Implication`, plus a **Search Evidence** line (the exact searches run and what came back empty) behind every negative claim such as "no existing pattern for this".
- Cap the report at **<= 12 verbatim excerpts, most-relevant first** - a dump is not a report.
- Cite `~/.claude/agents/codebase-explorer.md:47-49` for the `file:line` + read-before-you-claim mandate rather than restating it.

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

**Review-round defaults:** stop after 2 rounds in a row that find no NEW design problem (usually 2-3 rounds); fix design problems by simplifying, not by adding machinery, and keep the plan design-level (code review catches code detail). Each round runs FOUR lanes in parallel, each attacking a different failure class: one Claude breadth reviewer, one Claude `criticer` (value), one Codex executability pass and one Codex value-critic pass, both `gpt-6.1-sol` at high (both via codex-exec.sh; graceful degrade when codex is unavailable or refuses — mark the degrade in the presented review, never drop it silently). When two or more lanes return, an anonymized meta-review runs as a Codex pass (`gpt-6.1-sol` at high, backgrounded; skipped silently on failure).

### Loop:

1. **Spawn THREE INDEPENDENT reviewers in parallel**, plus the criticer, in a SINGLE message: one Claude breadth lane (`Agent`), and TWO Codex lanes with **materially different prompts** (see the Codex-plan-pass block below).

   **The lanes must attack DIFFERENT failure classes.** Until 2026-08-17 this step spawned two
   `plan-reviewer` calls whose prompts were byte-identical, which buys correlated findings and calls
   them independent. Two reviewers asking the same question is one reviewer with error bars. If you
   ever find yourself pasting the same prompt twice, the lane is not earning its cost.

```
Agent tool (call 1) - BREADTH lane, Claude:
  subagent_type: "plan-reviewer"
  prompt: "Review the plan at [path]. Cover CORRECTNESS, ARCHITECTURE, BRIEF FIDELITY,
    and INTEGRATION GAPS: is the design right, does it match the brief's settled
    decisions, and does it wire into what already exists? Verify the plan's file:line
    anchors actually say what it claims. Produce a numbered list of specific,
    actionable recommendations."

Agent tool (call 2, sent in the SAME message as call 1) - VALUE lane, Claude:
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

   **TWO Codex plan lanes (per round, in the same batch as the Agent calls).** They exist to
   attack DIFFERENT failure classes and their prompts must stay materially different - near-identical
   prompts are the failure this whole design prevents. Lane A runs on Sol at `high` because executability
   review is where a missed dependency costs a whole implementation round; lane B runs at `high`.

```bash
PROMPT_A=$(mktemp "${TMPDIR:-/tmp}/plan-codex-exec.XXXXXX")
OUT_A=$(mktemp "${TMPDIR:-/tmp}/plan-codex-exec-out.XXXXXX")
cat > "$PROMPT_A" <<'EOF'
Review this implementation plan for EXECUTABILITY. The failure you are hunting is "this plan
cannot actually be run as written, or it breaks a contract it did not know about": missing
dependencies, unstated runtime assumptions, missing wiring, wrong ordering between steps,
violated contracts, and whether its tests would actually catch the thing they claim to catch.
Verify its file:line anchors say what it claims. List each finding on its own line with a
severity (CRITICAL/IMPORTANT/MINOR) and a category tag
(GAP/LOGIC/ARCHITECTURE/CONTRADICTION/ASSUMPTION/SIMPLIFY). The plan text follows.
EOF
cat [path] >> "$PROMPT_A"   # [path] = the Step 3 saved-plan path

PROMPT_B=$(mktemp "${TMPDIR:-/tmp}/plan-codex-value.XXXXXX")
OUT_B=$(mktemp "${TMPDIR:-/tmp}/plan-codex-value-out.XXXXXX")
cat > "$PROMPT_B" <<'EOF'
Critique this implementation plan on VALUE, not fidelity. Is the premise even right - is it
solving the real problem? Where is it over-engineered, too rigid, or gold-plating a
non-problem? What is the cheap win it is skipping? What is the single biggest thing it missed?
What hidden costs does it not price? Do NOT list style nits or restate the plan back. List each
finding on its own line with a severity (CRITICAL/IMPORTANT/MINOR) and a category tag
(PREMISE/OVERBUILT/CHEAP-WIN/MISSED/COST). The plan text follows.
EOF
cat [path] >> "$PROMPT_B"

CODEX_MODEL=gpt-6.1-sol CODEX_EFFORT=high bash ~/.claude-dotfiles/scripts/codex-exec.sh "$PROMPT_A" "$OUT_A" "$(pwd)"
CODEX_MODEL=gpt-6.1-sol CODEX_EFFORT=high bash ~/.claude-dotfiles/scripts/codex-exec.sh "$PROMPT_B" "$OUT_B" "$(pwd)"
```

   When the batch returns, read each `"$OUT_*"` and its `.status`:
   - `.status == ok` → fold that lane's findings into the merged review, labeled
     **Codex executability** / **Codex value-critic**.
   - `.status != ok` (any of `unavailable` / `timeout` / `nonzero-<rc>`) → **graceful
     degrade**: present the literal line `(Codex plan pass: unavailable)` for that lane and
     continue with whatever returned. The degrade is marked in the presented review - never
     silently dropped, because a round that lost a lane is measurably weaker, not equivalent.
   - **A Codex refusal is a degrade, not a failure.** Codex declines content-wise on
     security-adjacent plans (measured: it refused a classifier review outright). Substitute a
     Claude lane, say so in the presented review, and do not retry the refused prompt shape.

   `criticer` is a **Claude value-critic lane that ALWAYS runs**, deliberately overlapping the Codex
   value lane. The redundancy is the point: Codex can refuse or die, and a value critique that only
   sometimes happens is one nobody can rely on. It is advisory only — it never asks, gates, or
   blocks, so it is safe under autonomous `/mission` runs.

   When the lanes return, merge the findings:
   - Raised by MORE THAN ONE lane → list once, mark `(N lanes)`. Agreement across lanes attacking
     different failure classes is the strongest signal available here.
   - Raised by one → keep it, mark which lane. A finding only the executability lane could have
     found is not weaker for being unique; it is why that lane exists.
   - Dedupe near-duplicates by topic, not by exact wording
   - **Union the `## Assumption-Test Candidates` sections** from every lane that emits one (dedup by finding). Retain this merged candidate list — Step 5 reads it from the FINAL review pass. (`criticer` never emits this section.)
   - Hold the `criticer` output (its `## Criticer Notes` block) separately for rendering + persistence in item 3 below.

2. **Anonymized peer-review meta-pass.**

   Skip this entire item if FEWER THAN TWO lanes returned usable content — a meta-pass over one
   review is just that review again.

   - Label the returned lanes anonymously as Review A / B / C in a non-positional order: if
     `($(date +%s) % 2) == 0` keep source order, else reverse it. The meta-agent never learns which
     letter was Claude and which was Codex, so it cannot defer to a model instead of to an argument.

   - Run ONE meta-reviewer as a **Codex pass** (`gpt-6.1-sol` at `high`). This lane judges other
     reviewers' judgment, which is the hardest read in the loop, and a model outside the Claude
     lanes it is judging is the least likely to share their blind spots. Write the prompt to a temp
     file, then launch `codex-exec.sh` in the FOREGROUND of a Bash call made with
     `run_in_background: true` (never `nohup`/`&` - a guard hook rejects detached codex; and a plain
     foreground Bash call caps at 10 min while `codex-exec.sh` may run up to 30). When that
     background call completes, read `"$OUT_M"` and `"$OUT_M.status"`:

```bash
PROMPT_M=$(mktemp "${TMPDIR:-/tmp}/plan-codex-meta.XXXXXX")
OUT_M=$(mktemp "${TMPDIR:-/tmp}/plan-codex-meta-out.XXXXXX")
cat > "$PROMPT_M" <<'EOF'
Independent reviewers reviewed the plan at [path], attacking different failure classes.
Their full anonymized outputs are below as Review A, Review B (and Review C when present).
Answer:
(a) Which review raises the strongest concern, and why?
(b) Which review has the biggest blind spot, and what is it?
(c) Where do the reviews DISAGREE, and which side is right?
(d) What did ALL of them miss that matters for this plan?
Reference reviews by their wrapper letter and individual findings by the reviewer's own
numbering (e.g. 'Review A finding #3'). Do NOT simply average them - name the
disagreements, do not smooth them. Keep under 250 words.

Review A:
[paste one lane's full numbered findings here]

Review B:
[paste another lane's full numbered findings here]

Review C (omit this block entirely if only two lanes returned):
[paste the third lane's full numbered findings here]
EOF

# Bash tool call with run_in_background: true - this line runs in its FOREGROUND:
CODEX_MODEL=gpt-6.1-sol CODEX_EFFORT=high bash ~/.claude-dotfiles/scripts/codex-exec.sh "$PROMPT_M" "$OUT_M" "$(pwd)"
```

   The `[path]` placeholder uses the same literal-placeholder convention as the two parallel reviewer prompts above — the orchestrator substitutes the actual saved-plan path at runtime.

   - If `"$OUT_M.status"` is not `ok` (`unavailable` / `timeout` / `nonzero-<rc>`), Codex refused, or `"$OUT_M"` is empty: skip silently and proceed to step 3 with only the merged review (preserves existing behavior).

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

## Roadmap mode (`--roadmap`)

Runs at mission start, at every part boundary, and once when a part goes over budget (the re-plan). Inputs: the goal (the mission PLAN zone), the Step 1 explorer fan-out (both `codebase-explorer` calls), `<root>/.mission-escaped.md`, per-part metrics so far, the latest planted-bug result. It assigns a recipe per part; it never merges, splits or reorders parts.

| Tier | Typical scope | plan= | review= | budget= (min) | live= |
|---|---|---|---|---|---|
| low | config, docs, scaffolding | 3 | 3 | 120 | yes only if UI is touched |
| normal | features | 5 | 8 | 300 | yes if UI |
| high | money, PHI, auth, OD writes, migrations | 7 | 15 | 480 | yes if UI or data effect |

- `floor=` names each built-in category the part touches (`money`, `phi`, `auth`, `odwrite`, `migration`); any floor means `tier=high`. Unsure means high. An area in the escaped-bug log goes up one tier.
- `needs=` lists the earlier parts whose code this part builds on (unsure: the previous part). `overlap=plan-next` lets the next part's research run while this part is in review.
- Write `<root>/tmp/mission/recipes.md`: per part one machine line (no `at=`; the writer stamps it when the conductor banks v1 at PART-START, v2 only for a re-plan) plus a note (why this tier, the floor reason, the test scope, the live checklist path `tmp/mission/p<N>/e2e-for-devtools.md`):
  `[mission] RECIPE part=<N> v=<1|2> tier=<low|normal|high> floor=<none|money|phi|auth|odwrite|migration>[,...] plan=<cap> review=<budget> budget=<min> live=<yes|no> overlap=<none|plan-next> needs=<none|N[,N...]>`
  Then print a one-screen owner summary (part, tier, why, budgets). Never ask the user here; the conductor owns the first-start OK. The writer refuses budgets above the table.

## Mission mode (`--mission`)

One review round per call; the conductor banks each round and decides whether to run another. Never ask the user: no Step 1 design questions, no `[NEEDS CLARIFICATION]` asks (record the assumption in the plan), no Step 4 items 3-5, no Step 5.

- **Round 1** runs Steps 0-3 to write the plan; later rounds re-read the saved plan. The plan is design level: contracts, invariants, the PHI and security model, the test list ("Key Pseudocode" becomes "Design contracts"). Mark independent chunks `parallel` with disjoint declared file sets, and name the part worktree.
- **Panel:** Step 4 item 1's four lanes, unchanged. A Codex refusal or non-`ok` status is a missing lane here, never a substitute.
- **Sol verify replaces the meta-pass (item 2):** number every merged finding `F1..Fn` and run one Codex pass (`CODEX_MODEL=gpt-6.1-sol CODEX_EFFORT=high`, backgrounded like the meta-pass) over the plan, the findings (fenced as untrusted data) and codex-review.md Step 6e's LEDGER MODE addendum with the `--ledger` file. Per confirmed blocking finding it emits `TAG | <TYPE-KEY> | new|repeat | DESIGN|IMPL|PROOF | <area> | <one line>`. Count with the Step 6e block, off the file. Verify failed = non-zero exit, no `Verdict:` line, or a draft finding without its `F<n> |` row.
- **Fold:** fix each blocking DESIGN finding by simplifying the design, or record it under `## Descoped` with the reason; any DESIGN finding still open counts in `Open-design`. IMPL and PROOF findings go to `## Builder notes` as `IMPL | <line>` / `PROOF | <line>` and never cause another round.
- **Report:** write `--report <path>` atomically (tmp + `mv`), output it, and print `Report-file: <path>` as the LAST line. First line:
  `Plan-review: round=<K> | Model: gpt-6.1-sol | Plan-lanes: N/4 | Verify: ok tagged=<t> blocking=<b> | Ledger: new=<n> repeat=<n> | Areas-new: <csv or -> | Design-new: <n> | Open-design: <n>`
  (`Plan-lanes: N/4 (<missing lanes>)` when short; `Verify: failed` replaces the Verify, Ledger and Areas-new tokens on failure), then `Plan-file: <path>` and a `## Verify tags` section with the TAG rows verbatim. `Plan-lanes` counts lanes that returned usable content; `Design-new` counts TAG rows reading `new | DESIGN`.
- **Caller rules (the writer enforces them):** a round is VOID unless `Plan-lanes: 4/4` and `Verify: ok` with `tagged == blocking`. Stop discovery after 2 consecutive banked rounds with `Design-new: 0`, or at the recipe's `plan=` cap. Implementation starts only at `Open-design: 0`; otherwise the part is parked.

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
