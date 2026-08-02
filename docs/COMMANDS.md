# Command Reference

Regenerated 2026-08-01 from the live command set; parallelizer-v1 rows and the agents/scripts
section refreshed 2026-08-02.

Every slash command in `~/.claude-dotfiles/commands/`, grouped by purpose. Top-level commands are
invoked as `/<name>`; pack subskills are invoked as `/<dir>:<name>` (e.g. `/desktop:click`,
`/god-review:principles:reuse`). Templates and changelogs live beside the commands but are not
directly invoked - see the note at the bottom.

Cheat sheet of the categories below:

| Category | Commands |
|---|---|
| [Planning & implementation](#planning--implementation) | `/plan`, `/simple-plan`, `/discussion`, `/script`, `/implement`, `/testplan`, `/mission`, `/afk` |
| [Investigation & review](#investigation--review) | `/investigate`, `/codex-review`, `/master-review`, `/god-review`, `/god-report`, `/ui-audit`, `/database-audit` |
| [Git, commits, PRs](#git-commits-prs) | `/commit`, `/checkpoint`, `/prepare-pr`, `/share-fix` |
| [Sessions & context](#sessions--context) | `/pre-compact`, `/post-compact-resume`, `/document`, `/claudemd`, `/skill-improve`, `/line` |
| [Research](#research) | `/research-web`, `/transcribe` |
| [Credentials & setup](#credentials--setup) | `/load-creds` |
| [Remote control & GUI](#remote-control--gui) | `/devtools`, `/desktop`, `/macmini`, `/windows` |
| [Utilities](#utilities) | `/wispralt-update` |

---

## Planning & implementation

| Command | What it does |
|---|---|
| `/plan` | Creates an implementation plan with thorough codebase and web research. Step 1 research is a mandated **parallel fan-out** - all research agents spawn in a SINGLE message, skipped only for a trivially single-file change or when supplied research already exists. Auto-reviews the plan after creation and iterates with user feedback. Use when planning a new feature or significant change. |
| `/simple-plan` | Quick gut-check before implementing when the user directly asks for something ("add X", "fix Y"). Investigates, proposes a lightweight plan, implements after approval. Use instead of `/plan` when the user wants something done, not a formal plan. |
| `/discussion` | Interactive discussion about a topic, approach, or feature. Researches the codebase as needed, talks through options, and saves a brief to `./tmp/briefs/` (consumed by `/plan`). No code changes. |
| `/script` | Generates pre-flight assumption tests that programmatically PROVE a feature's load-bearing assumptions against real infrastructure BEFORE implementation, and re-run as regression catchers after. For high-stakes work (prod, user data, HIPAA / financial / safety-critical). |
| `/implement` | Executes an approved plan by breaking work into parallelizable chunks and spawning implementation sub-agents. Emits a chunk table, then **must** spawn qualifying chunks (file sets determinable, pairwise disjoint, hazard-free) in a SINGLE message - a post-batch overlap check HALTs if any chunk wrote outside its declared set. With >= 2 chunks and review enabled it can escalate to a checked worktree WAVE (`parallelizer` agent -> `verify-parallel-wave.mjs` -> `merge-wave.sh`); every gate falls back to serial. Automatically reviews the result for completeness. |
| `/testplan` | Generates an exhaustive, production-realistic TEST PLAN for any target - discovers available test capabilities, comprehends the program's role, scales coverage to the target's archetype and risk, emits a risk-tiered plan with honest blockers. Plans; never executes. |
| `/mission` | Autonomous long-build conductor (playbook, not an engine). Opt-in and HEAVY: per part it runs research + a full `/plan` reviewer loop + `/implement` + a cross-model `/codex-review` panel to honest convergence, riding the mission-bridge + `/pre-compact` across many compactions. For genuinely large builds only. |
| `/afk` | Fire-and-forget long-running code review. `/afk [hours]` (default 3, 0 = infinite). Single-agent Opus, medium effort. Walk away, come back to a useful report. |

## Investigation & review

| Command | What it does |
|---|---|
| `/investigate` | Investigates bugs through hypothesis-driven root cause analysis. Use when something is broken, failing, or behaving unexpectedly. Finds and explains the problem; does not fix. |
| `/codex-review` | Universal review engine. OpenAI Codex CLI runs 4 specialized review passes (Correctness, Security, Data-integrity, Contracts) plus 1 verification pass; Claude Opus runs 3 lens agents plus meta-review. A binding **Launch schedule** puts the 4 Codex passes (backgrounded) and the 2 Step-4a lenses (Architecture, Integration) in ONE message - 6 tool calls - collected by a bounded wait on the `.status` sidecars; the Adversarial + FP-filter lens (4b) spawns after the Codex merge. Report-only. Works on code, plans, ideas, bugs, anything. |
| `/master-review` | FROZEN (2026-07-12) - kept intact as the parity reference for its browser + Antigravity capabilities. Autonomous review + fix pipeline: 3 Claude + 3 Codex + 2 Antigravity reviewers, Claude fixer, verification loop. Use `/god-review` or `/codex-review` instead. |
| `/god-review` | Autonomous multi-model codebase audit + fix loop. 4 Claude broad + 6 Codex broad + 24 principle agents in parallel; indefinite fix loop until 3 consecutive rounds yield zero new non-deferred findings; hard gates on schema/auth/deps/secrets/CI/tests batched for human review at the end. |
| `/god-report` | Single-pass multi-model codebase review report - same reviewer fleet as `/god-review` but NO fixes applied; pure report. Optional `--rounds N` for de-noising. |
| `/ui-audit` | Audits one tab's UI end-to-end to catch fake or dead elements. Report-only: enumerates the entire rendered surface across every reachable sub-state, gives each element a strict REAL / STATIC-BY-DESIGN / FAKE-OR-DEAD / UNVERIFIED verdict via three reconciled passes (static code trace, live-browser x-ray over raw CDP, screenshot vision). Emits findings.json + AUDIT.md + per-state screenshots. Never edits app code. |
| `/database-audit` | Deep multi-provider database audit (Supabase, Neon, vanilla Postgres) - schema, RLS, security, prod-readiness, client coherence. Read-only; refuses prod without `--env=prod`. Optionally emits DATABASE.md. |

Pack subskills (invoked as `/<pack>:<name>`):

- **god-review** - 37 subskill files: 10 broad reviewers (`broad-reviewers:` `claude-architecture-prod`, `claude-deep-correctness`, `claude-ruthless-redteam`, `claude-security-resilience`, `codex-cross-layer`, `codex-data-integrity`, `codex-deep-correctness`, `codex-prod-scalability`, `codex-ruthless-redteam`, `codex-security-safeguards`); 24 principle lenses (`principles:` `antipatterns`, `architecture-backend`, `architecture-frontend`, `ci-yaml-tampering`, `circular-deps`, `clarity`, `contradiction-detector`, `database-audit`, `dead-code-conservatism`, `dead-end-detector`, `documentation`, `gap-detector`, `hallucinated-imports`, `info-loss-detector`, `perf-benchmark`, `perf-heuristic`, `prompt-injection`, `reuse`, `scope`, `secret-leak`, `self-contained`, `single-pattern`, `tanstack-query`, `test-deletion`); `lib:editor-agent`; plus CHANGELOG, CRITERIA, README.
- **ui-audit** - 7 subskill files: 4 passes (`passes:` `static-trace`, `dynamic-exercise`, `vision-inspect`, `reconcile`), `rubric`, plus CHANGELOG, README.
- **database-audit** - 7 subskill files: `core`, `guards`, `redaction`, 3 provider adapters (`providers:` `supabase`, `neon`, `postgres`), plus `tests:README`.

## Git, commits, PRs

| Command | What it does |
|---|---|
| `/commit` | Selectively stages and commits only the changes related to the current session, skipping unrelated modifications. |
| `/checkpoint` | Named git snapshot (tag) to mark a known-good state. Useful before risky changes, integration work, or major refactors. |
| `/prepare-pr` | Commits changes grouped by done-plans, rebases main, builds the project, then creates or updates a PR. |
| `/share-fix` | After shipping a non-trivial fix, finds related GitHub issues across the ecosystem, drafts helpful human-sounding comments linking the fix and root cause, and optionally files upstream issues. Always asks approval before posting anything public. |

## Sessions & context

| Command | What it does |
|---|---|
| `/pre-compact` | Run before context compaction. Refreshes project docs via `/document`, then writes a SID-tagged `CLAUDE.local.<sid8>.md` handoff (active task, plan, decisions, open issues, gaps) so post-compact Claude picks up the thread without losing info. |
| `/post-compact-resume` | Fired automatically after `/compact` by the Stop-hook chain; locates the SID-tagged handoff file and resumes the thread. |
| `/document` | Audits or creates clear project documentation covering database, backend, frontend, APIs, and external integrations. Updates existing docs or bootstraps a full `docs/` tree. Navigable for both humans and LLMs. |
| `/claudemd` | Captures a lesson from the current moment into the RIGHT instruction surface - investigates what the lesson is and why, routes to the strongest enforcement layer (check > global CLAUDE.md > project AGENTS.md/CLAUDE.md > docs/), proposes the exact edit, applies on approval. |
| `/skill-improve` | Turns the current session into improvements for an existing skill or command - scans the session for direct evidence (what worked, what failed, what confused) and produces copy-ready patches. Report-only by default; `--apply` hands off to `/implement`. |
| `/line` | Sets this window's statusline line 2 to a sentence; no args clears it back to the repo name. |

## Research

| Command | What it does |
|---|---|
| `/research-web` | Conducts extensive web research on technical topics with validated references and citations. Use for external documentation, library comparisons, or best-practices research. |
| `/transcribe` | Transcribes an audio recording (Voice Memos, phone call, etc.) via OpenAI Whisper and generates a project-context-aware analysis report. |

## Credentials & setup

| Command | What it does |
|---|---|
| `/load-creds` | Injects API keys from the user's 1Password vault into the current project's `.env` via `op inject`. Catalog at `~/.config/claude/credentials.md` (local-only, never synced). |

## Remote control & GUI

| Command | What it does |
|---|---|
| `/devtools` | Self-healing chrome-devtools connector. Ensures a debug Chrome (with the user's real profile + tabs) is running on port 9222, kills stale MCP processes, scrubs corrupt npx installs, and prompts `/mcp` reconnect. |
| `/desktop` | Self-resolving local-mac control. Tries CLI/AppleScript first; vision-clicks only when no scriptable handle exists. Handles permission dialogs, confirm modals, and apps without CLI. |
| `/macmini` | Drives a remote Mac mini through Chrome Remote Desktop via the chrome-devtools MCP. Self-resolving; clicks are direct CDP click_at into the CRD canvas. |
| `/windows` | Drives a remote Windows laptop (OpenDental) through Chrome Remote Desktop via the chrome-devtools MCP. Self-resolving; clicks are direct CDP click_at into the CRD canvas. |

Pack subskills (invoked as `/<pack>:<name>`):

- **desktop** - 7 subskills: `shot`, `window`, `click`, `key`, `type`, `status`, `setup`.
- **macmini** - 4 subskills: `connect`, `crd`, `act`, `setup`.
- **windows** - 3 subskills: `connect`, `crd`, `act`.

## Utilities

| Command | What it does |
|---|---|
| `/wispralt-update` | Pulls the latest WisprAlt release and updates the installed app. Handles TCC reset if the code-signing cdhash changed. |

## Agents and scripts the commands are bound to

Not slash commands - listed here because the playbooks above call them by name and fail closed
without them.

| Artifact | Called by | What it does |
|---|---|---|
| `agents/parallelizer.md` | `/implement` (wave gate) | Advisory scheduling subagent. Reads the repo to compute write-sets and read-sets for pending work and returns either a machine-checkable wave plan (FAN_OUT) or SERIAL_CORRECT. Never implements, never spawns agents; low confidence, malformed output, or any failure means serial. |
| `scripts/parallel-stats.py` | manual + the SessionStart cleanup hook | Transcript parallelism instrumentation. Groups tool calls by `message.id` (never by JSONL record), reports solo vs batched spawn turns, raw and refined solo codex turns with per-surface attribution, per-phase wall clock, and the rework log. `--replay` adds would-have-fired nudge counterfactuals and a decomposed wave-gate eligibility table with coverage denominators. `--json` for machine use. |
| `scripts/verify-parallel-wave.mjs` | `/implement` (every gate path), `merge-wave.sh` | Fail-closed wave checker, zero deps. `--validate-plan` schema- and hazard-checks a wave plan; `--wave-state` proves each worktree is clean, ancestral, committed, and wrote only inside its declared paths; `--log-decision` records a serial/fan-out decision from a closed reason-token set. Every invocation appends one capped machine event to `rework.log`. |
| `scripts/merge-wave.sh` | `/implement` (wave barrier) | Incremental, resumable merge of a verified wave. Re-verifies inline, merges chunks in declared order recording each `merge_sha`, skips already-merged chunks on resume, and leaves the tree clean at the last successful merge on conflict. Never deletes worktrees. |

Schema authority for both wave artifacts: **[`docs/wave-plan-schema.md`](wave-plan-schema.md)**.
Assumption suites proving these: `scripts/parallel-stats-assumptions/`,
`scripts/verify-parallel-wave-assumptions/`, `scripts/lint-commands-assumptions/` (each
`bash <dir>/run-all.sh`, hermetic, exits 0/1/2/3).

---

Templates and support files (not invoked directly): `commands/plan_base.md` (base template loaded by
`/plan`), `commands/pre-compact-template.md` (handoff-file template written by `/pre-compact`),
`commands/devtools-CHANGELOG.md` (changelog for `/devtools`). Removed packs (gemini, ui-ux-pro-max,
antigravity, etc.) live in `commands/archive/` and are intentionally excluded.
