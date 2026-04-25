# Command Reference

Every slash command in this repo, grouped by purpose. Type any of these in a Claude Code session.

Cheat sheet of the categories below:

| Category | Commands |
|---|---|
| [Planning & implementation](#planning--implementation) | `/plan`, `/simple-plan`, `/discussion`, `/implement` |
| [Investigation & review](#investigation--review) | `/investigate`, `/codex-review`, `/master-review`, `/local-review`, `/afk`, `/supabase-audit` |
| [Git, commits, PRs](#git-commits-prs) | `/commit`, `/checkpoint`, `/prepare-pr` |
| [Sessions & context](#sessions--context) | `/pre-compact`, `/learn`, `/document`, `/architect` |
| [Verification](#verification) | `/verify`, `/tdd` |
| [Research](#research) | `/research-web`, `/transcribe` |
| [Credentials & setup](#credentials--setup) | `/load-creds` |
| [Skills toolkit](#skills-toolkit) | `/skillset`, `/buildskill` |
| [Account & mode](#account--mode) | `/antigravity`, `/hybrid-status`, `/set-primary-cloud`, `/set-primary-local`, `/toggle-local-review` |
| [Deployment](#deployment) | `/netlifydeploy`, `/renderdeploy` |
| [CRM](#crm) | `/crm` |
| [Construction estimation (`plan2bid`)](#construction-estimation-plan2bid) | `/plan2bid` and ~16 sub-commands |
| [UI/UX (`ui-ux-pro-max`)](#uiux-ui-ux-pro-max) | `/ui-ux-pro-max` and 6 sub-commands |
| [MoleCopilot (drug discovery)](#molecopilot-drug-discovery) | `/dock`, `/screen`, `/admet`, `/optimize`, `/prep-target`, `/dashboard` |
| [FRAIM](#fraim) | `/fraim` |
| [Partner suite (`parsa`)](#partner-suite-parsa) | 25+ commands |

Templates and base files (not invoked directly): `commands/plan_base.md`.

---

## Planning & implementation

| Command | What it does |
|---|---|
| `/plan` | Build a thorough implementation plan with codebase + web research. Auto-runs the plan-reviewer and iterates with you before saving to `./tmp/ready-plans/`. |
| `/simple-plan` | Lightweight gut-check before doing something the user just asked for. Investigates, proposes, implements after approval. |
| `/discussion` | Conversation-only mode. Researches the codebase, talks through tradeoffs, saves a brief to `./tmp/briefs/` for `/plan` to consume. No code changes. |
| `/implement <plan path>` | Executes an approved plan from `./tmp/ready-plans/`. Breaks work into chunks, spawns implementer sub-agents, runs implementation-reviewer at the end, moves the plan to `./tmp/done-plans/`. |

Typical flow: `/discussion` → `/plan` → `/implement <path>`.

---

## Investigation & review

| Command | What it does |
|---|---|
| `/investigate` | Hypothesis-driven root cause analysis. Auto-invoked when you report a bug or "X isn't working." |
| `/codex-review` | Universal review engine. OpenAI Codex CLI runs 2 specialized passes + 1 verify; Claude Opus runs 4 lens agents (Depth, Breadth, Adversary, Gaps) + meta. Report-only. |
| `/master-review` | Autonomous review + fix pipeline. 3 Opus + 3 Codex + 2 Antigravity reviewers in parallel; Claude fixes via `/implement`; verification loop until 3 consecutive clean passes. |
| `/local-review` | Send the current diff to LM Studio for an offline second opinion (requires `/toggle-local-review` enabled). |
| `/supabase-audit` | Read-only audit of a Supabase repo: schema, RLS, security, prod-readiness, client coherence. Refuses prod without `--env=prod`. Optionally writes `DATABASE.md`. |

---

## Git, commits, PRs

| Command | What it does |
|---|---|
| `/commit` | Selectively stage and commit only changes related to the current session. Skips unrelated modifications. |
| `/checkpoint <name>` | Create a named git tag to mark a known-good state. Useful before risky changes. |
| `/prepare-pr` | Commit by-plan, rebase main, build API + webapp, create or update a PR. Replaces the older `/commit` workflow for PR-ready work. |

`/prepare-pr` is the right exit door at the end of a feature.

---

## Sessions & context

| Command | What it does |
|---|---|
| `/pre-compact` | Manual handoff before context compaction. Writes `CLAUDE.local.md` so post-compact Claude resumes cleanly. **Mining-pass calibration** (Quick/Deep/Chunked), **chain tracking** across compactions (`Seq:` + `Parent:`), **two-phase write** with floors, **What We Tried** and **Evidence & Data** sections, and a **Since Last Compact** diff vs prior session. Manual-only by design. |
| `/learn` | Extract behavioral patterns from this session and write them to `patterns/`. Auto-pushes. |
| `/document` | Audit or bootstrap project docs in `docs/` (database, backend, frontend, APIs, integrations). Both human- and LLM-navigable. |
| `/architect` | Interactive scaffolding for a new project's documentation tier. Run BEFORE starting a project. Asks one question at a time. |

`/pre-compact` is the single dialed-in tool for session-to-session continuity. Don't write freeform handoffs — `CLAUDE.md` enforces this globally.

---

## Verification

| Command | What it does |
|---|---|
| `/verify` | Full pipeline: build → typecheck → lint → test → security. Hard-gates each step. |
| `/tdd` | RED → GREEN → REFACTOR cycle for a feature or fix. |

---

## Research

| Command | What it does |
|---|---|
| `/research-web` | Web research with validated references and citations. |
| `/transcribe` | Audio (Voice Memos, calls) → Whisper transcript → project-aware analysis report. See [docs/transcribe.md](transcribe.md) for setup. |

---

## Credentials & setup

| Command | What it does |
|---|---|
| `/load-creds [VAR1,VAR2]` | Inject API keys from 1Password into the project's `.env` via `op inject`. With no args, auto-detects vars referenced by the project. Reads the catalog at `credentials.md`. |

The credential flow lives in `CLAUDE.md` → "Credential and MCP Handling". Full diagram in [ARCHITECTURE.md](ARCHITECTURE.md#credential-flow).

---

## Skills toolkit

| Command | What it does |
|---|---|
| `/skillset` | Initialize or load `SKILLSET.md` for the current industry project. Tracks which skills are available and enforces cross-industry isolation. |
| `/buildskill` | Conductor for designing a new industry-specific slash command. Loads `SKILLSET.md` context, asks targeted questions, hands off to `/plan`. |

---

## Account & mode

| Command | What it does |
|---|---|
| `/antigravity` | Manage Google AI (Antigravity) profiles — switch active, open profile for auth, show status. Used by review loops that need Google-Pro accounts. |
| `/hybrid-status` | Show current Cloud/Local routing mode and review-feature state for the hybrid control system. |
| `/set-primary-cloud` | Switch Claude Code to Cloud mode (Anthropic). Restart needed. |
| `/set-primary-local` | Switch Claude Code to Local mode (LM Studio at localhost:1234). Restart needed. |
| `/toggle-local-review` | Toggle the on-demand local-review feature (used by `/local-review`). |

---

## Deployment

| Command | What it does |
|---|---|
| `/netlifydeploy` | One-shot Netlify deploy. Researches Netlify docs and the codebase in parallel, synthesizes a strategy, deploys via the Netlify MCP. |
| `/renderdeploy` | One-shot Render deploy of frontend (static site) + backend (web service) via Render MCP + REST API. |

Both confirm before deploying. See `CLAUDE.md` → "Netlify Safety" for the rules.

---

## CRM

| Command | What it does |
|---|---|
| `/crm` | Manage leads, deals, emails, campaigns, prospect via Apollo. Real data only. Confirms before destructive or credit-burning actions. |

---

## Construction estimation (`plan2bid`)

Construction-estimation suite. Top-level orchestrator + ~16 sub-commands.

| Command | What it does |
|---|---|
| `/plan2bid` | Orchestrator. Routes to the right sub-command for takeoffs, bids, blueprints, pricing, scope, comparisons. |
| `/plan2bid:run` | Full pipeline: read documents → extract quantities → price materials → estimate labor → apply markups → structured estimate. |
| `/plan2bid:run-batched` | Variant B: parent reads ALL docs and extracts scope; sub-agents only do pricing math. Higher-fidelity. |
| `/plan2bid:run-group` | Trade-group estimation. One specific set of trades from documents. Used by the multi-terminal worker pattern. |
| `/plan2bid:run-merge` | Merge trade-group results into a final estimate. Validates, deduplicates, saves to DB. |
| `/plan2bid:doc-reader` | Read/classify construction PDFs and blueprints; extract schedules; vision-analyze drawings. |
| `/plan2bid:rag` | Semantic search across construction documents. Returns chunks with citations. |
| `/plan2bid:scope` | Per-trade IN/OUT scope lists with source citations. Resolves document hierarchy and flags ambiguity. |
| `/plan2bid:validate` | Pre-flight check for the 6 critical gaps that cause silent pricing failures. Run before `/plan2bid:run`. |
| `/plan2bid:price-check` | Verify material pricing against web sources + your pricing profile. Flags low-confidence items. |
| `/plan2bid:pricing-profile` | Manage labor rates, material prices, markups, vendor preferences, company info. |
| `/plan2bid:scenarios` | What-if generator. Re-prices an estimate with changed context (material swap, scope change, value engineering). Auto-compares to base. |
| `/plan2bid:compare` | Side-by-side comparison of two estimates. Flags missing items, quantity diffs, pricing variance. |
| `/plan2bid:grade` | Grade an estimate against a known-good human reference. 5-category score with miss explanations. |
| `/plan2bid:reverse-engineer` | Extract a human estimator's methodology from their completed estimate. |
| `/plan2bid:pdf` | Export to GC-submission PDF. Three detail levels: summary / standard / detailed. |
| `/plan2bid:excel` | Export to styled Excel with Summary tab + per-trade tabs. |
| `/plan2bid:save-to-db` | Save line items + metadata to Supabase. |
| `/plan2bid:save-scenario-to-db` | Save scenario re-pricings to Supabase mirror tables. |

---

## UI/UX (`ui-ux-pro-max`)

| Command | What it does |
|---|---|
| `/ui-ux-pro-max` | Top-level UI/UX intelligence. 50+ styles, 161 palettes, 57 font pairings, 25 chart types across 10 stacks. Plan, build, design, review. |
| `/ui-ux-pro-max:design` | Comprehensive design: brand identity, design tokens, UI styling, logo (55 styles), CIP mockups, presentations, banners, icons, social photos. |
| `/ui-ux-pro-max:design-system` | Token architecture (primitive → semantic → component), CSS vars, spacing/typography scales, component specs. |
| `/ui-ux-pro-max:brand` | Brand voice, visual identity, messaging frameworks, asset management. |
| `/ui-ux-pro-max:ui-styling` | shadcn/ui + Tailwind + canvas. Accessible components, dark mode, design tokens. |
| `/ui-ux-pro-max:slides` | Strategic HTML presentations with Chart.js, design tokens, copywriting formulas. |
| `/ui-ux-pro-max:banner-design` | Banners for social, ads, hero, print. 13+ styles. AI-generated visuals. |

---

## MoleCopilot (drug discovery)

Computational drug-discovery toolkit at `~/molecopilot/`. Calls the `molecopilot` MCP server (22 tools).

| Command | What it does |
|---|---|
| `/dock` | Run a docking job. Parses compound (name/SMILES/CID) + target (PDB ID) + parameters; runs the full pipeline (fetch → prep → dock → analyze). |
| `/screen` | Virtual screening campaign. Search PubChem → batch prep → batch dock → rank top hits. |
| `/admet` | ADMET / drug-likeness on a compound. Lipinski + Veber + radar plot. |
| `/optimize` | NVIDIA MolMIM AI optimizes a hit into better drug candidates. CMA-ES, 20 analogs, ADMET-rescored. |
| `/prep-target` | Fetch a protein from RCSB PDB → clean → PDBQT → detect binding site. |
| `/dashboard` | Launch the MoleCopilot Streamlit dashboard. Auto-picks a free port (8501–8510) and opens the browser. |

Pharmacology context (binding energy thresholds, Lipinski rules, IC50 vs Ki vs EC50, etc.) lives in `CLAUDE.md` → "MoleCopilot".

---

## FRAIM

| Command | What it does |
|---|---|
| `/fraim [job or topic]` | Discover or run a FRAIM job via the `fraim` MCP server. With no arg, lists jobs grouped by business function and suggests starting points. With an arg, calls `get_fraim_job` for the matching job. |

FRAIM jobs also auto-route from natural language. See `CLAUDE.md` → "Skill Routing" → `fraim → ...` rows for triggers (e.g., `fraim → recommend-next-job`, `fraim → end-of-day-debrief`).

---

## Partner suite (`parsa`)

A second slash-command set used in partner projects. Same shape as the core suite but with the `parsa:` namespace.

### Planning & implementation

| Command | What it does |
|---|---|
| `/parsa:simple-plan` | Quick plan to address a user question. |
| `/parsa:create-prp` | Create a PRP (project requirements/plan) document. |
| `/parsa:review-prp` | Review a PRP for simplification, gaps, bugs, alternatives. |
| `/parsa:review-plan` | Review an implementation plan. |
| `/parsa:implement-plan` | Execute implementation from a plan file. |
| `/parsa:fix-bug` | Hypothesis-driven debug → logging → analysis → PRP generation. |

### Continuous-loop variants (`parsa:cl:`)

| Command | What it does |
|---|---|
| `/parsa:cl:create_plan` | Interactive plan creation with back-and-forth on approach. |
| `/parsa:cl:iterate_plan` | Update or revise an existing plan based on feedback. |
| `/parsa:cl:implement_plan` | Run a plan from `ready-plans/` end-to-end. |
| `/parsa:cl:research_codebase` | Deep codebase research with file-level references. |
| `/parsa:cl:research_web` | Web research with validated references. |
| `/parsa:cl:describe_pr` | Generate PR descriptions following the repo template. |
| `/parsa:cl:commit` | Commit with user approval, no Claude attribution. |

### Code review by principle

`/parsa:review:all` is the cascade — runs all 11 in parallel.

| Command | Principle |
|---|---|
| `/parsa:review:all` | Run all 11 below |
| `/parsa:review:principles:single-pattern` | Single Way to Do Things (most important) |
| `/parsa:review:principles:reuse` | Reuse Over Recreation |
| `/parsa:review:principles:self-contained` | Self-Contained Components |
| `/parsa:review:principles:scope` | Correct Scope |
| `/parsa:review:principles:clarity` | Clarity & Readability |
| `/parsa:review:principles:documentation` | Documentation standards |
| `/parsa:review:principles:antipatterns` | Anti-patterns and convention violations |
| `/parsa:review:principles:circular-deps` | Circular dependencies and late imports |
| `/parsa:review:principles:architecture-frontend` | Frontend architecture patterns |
| `/parsa:review:principles:architecture-backend` | Backend architecture patterns |
| `/parsa:review:principles:tanstack-query` | TanStack Query patterns |

### Linting

| Command | What it does |
|---|---|
| `/parsa:linter:codebase` | Fix all TS type errors + ESLint warnings across the repo, parallel agents. |
| `/parsa:linter:local-changes` | Fix lint/type errors only in files changed on the current branch. Sequential. |
| `/parsa:linter:commit` | Commit with lint validation gate. |
| `/parsa:linter:update-claude-docs` | Update `CLAUDE.md` to reflect current code patterns. |
| `/parsa:linter:validate-codebase-docs` | Verify docs match the actual codebase. |

### Refactor

| Command | Scope |
|---|---|
| `/parsa:refactor:simple` | Small change quick check. |
| `/parsa:refactor:medium` | Medium-sized change quality score. |
| `/parsa:refactor:deep` | Architectural review of a large change. |
| `/parsa:refactor:refactor-full` | Comprehensive multi-dimensional refactor analysis. |

---

## What's not a slash command

Things that look like commands but aren't directly callable:

| File | What it is |
|---|---|
| `commands/plan_base.md` | Base template for new plans. Copied by `/plan`. |
| `agents/*.md` | Sub-agent definitions (codebase-explorer, implementer, plan-reviewer, implementation-reviewer, researcher). Spawned by skills via `subagent_type:`. |
| `rules/backend-patterns.md` | Global rule. Auto-loaded every session. |
| `patterns/*.md` | Behavioral patterns from `/learn`. Indexed in `patterns/INDEX.md`. |

---

## Adding a new command

```bash
# Top-level: becomes /foo
$EDITOR ~/.claude-dotfiles/commands/foo.md

# Namespaced: becomes /myteam:foo
mkdir -p ~/.claude-dotfiles/commands/myteam
$EDITOR ~/.claude-dotfiles/commands/myteam/foo.md
```

Command files are markdown with optional frontmatter:

```markdown
---
description: One-line summary for slash-menu autocomplete.
argument-hint: "[optional argument format]"
---

# /foo — Title

Body of the command. Claude executes this when the user runs /foo.
```

If the new command needs a Skill Routing trigger, add one row to the table in `CLAUDE.md` (slash command, natural-language trigger, Consequence YES/No).

The PostToolUse hook auto-pushes after you save.
