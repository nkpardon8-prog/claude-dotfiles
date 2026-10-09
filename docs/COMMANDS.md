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
| [Sessions & context](#sessions--context) | `/pre-compact`, `/post-compact-resume`, `/transfer`, `/document`, `/claudemd`, `/skill-improve`, `/line`, `/pickup`, `/recap` |
| [Research](#research) | `/research-web`, `/transcribe` |
| [Credentials & setup](#credentials--setup) | `/load-creds` |
| [Remote control & GUI](#remote-control--gui) | `/devtools`, `/desktop`, `/macmini`, `/windows` |
| [Utilities](#utilities) | `/wispralt-update`, `/worktree-cleanup` |

---

## Planning & implementation

| Command | What it does |
|---|---|
| `/plan` | Creates an implementation plan with thorough codebase and web research. Step 1 research is a mandated **parallel fan-out** - all research agents spawn in a SINGLE message, skipped only for a trivially single-file change or when supplied research already exists. Auto-reviews the plan after creation (parallel Claude + Codex lanes, then an anonymized meta-review run as a Codex pass on `gpt-6-sol` at xhigh) and iterates with user feedback. Use when planning a new feature or significant change. |
| `/simple-plan` | Quick gut-check before implementing when the user directly asks for something ("add X", "fix Y"). Investigates, proposes a lightweight plan, implements after approval. Use instead of `/plan` when the user wants something done, not a formal plan. |
| `/discussion` | Interactive discussion about a topic, approach, or feature. Researches the codebase as needed, talks through options, and saves a brief to `./tmp/briefs/` (consumed by `/plan`). No code changes. |
| `/script` | Generates pre-flight assumption tests that programmatically PROVE a feature's load-bearing assumptions against real infrastructure BEFORE implementation, and re-run as regression catchers after. For high-stakes work (prod, user data, HIPAA / financial / safety-critical). |
| `/implement` | Executes an approved plan by breaking work into small parallelizable chunks (1-3 tasks each) and spawning implementation sub-agents - every implementer runs Opus 5.5 at medium effort and gets only its chunk's task text plus the plan's shared invariants, not the whole plan. Emits a chunk table, then **must** spawn qualifying chunks (file sets determinable, pairwise disjoint, hazard-free) in a SINGLE message - a post-batch overlap check HALTs if any chunk wrote outside its declared set. With >= 2 chunks and review enabled it can escalate to a checked worktree WAVE (`parallelizer` agent -> `verify-parallel-wave.mjs` -> `merge-wave.sh`); every gate falls back to serial. Automatically reviews the result for completeness. |
| `/testplan` | Generates an exhaustive, production-realistic TEST PLAN for any target - discovers available test capabilities, comprehends the program's role, scales coverage to the target's archetype and risk, emits a risk-tiered plan with honest blockers. Plans; never executes. |
| `/mission` | Autonomous long-build conductor (playbook, not an engine). Opt-in and HEAVY: per part it runs research + a full `/plan` reviewer loop + `/implement` + a cross-model `/codex-review` panel to honest convergence, riding the mission-bridge + `/pre-compact` across many compactions. Scheduled wakes are capped at 3300s so each lands inside the 1h prompt-cache TTL. For genuinely large builds only. |
| `/afk` | Fire-and-forget long-running code review. `/afk [hours]` (default 3, 0 = infinite). Single-agent Opus, medium effort. Walk away, come back to a useful report. |

## Investigation & review

| Command | What it does |
|---|---|
| `/investigate` | Investigates bugs through hypothesis-driven root cause analysis. Use when something is broken, failing, or behaving unexpectedly. Finds and explains the problem; does not fix. |
| `/codex-review` | Universal review engine. OpenAI Codex CLI runs 4 specialized review passes (Correctness, Security, Data-integrity, Contracts) plus 1 verification pass; Claude Opus runs 3 lens agents plus meta-review. A binding **Launch schedule** puts the 4 Codex passes (backgrounded) and the 2 Step-4a lenses (Architecture, Integration) in ONE message - 6 tool calls - collected by a bounded wait on the `.status` sidecars; the Adversarial + FP-filter lens (4b) spawns after the Codex merge. Report-only. Works on code, plans, ideas, bugs, anything. |
| `/master-review` | FROZEN (2026-07-12) - kept intact as the parity reference for its browser + Antigravity capabilities. Autonomous review + fix pipeline: 3 Claude + 3 Codex + 2 Antigravity reviewers, Claude fixer, verification loop. Use `/god-review` or `/codex-review` instead. |
| `/god-review` | Autonomous multi-model codebase audit + fix loop. 9 broad reviewers by default (3 Claude + 6 Codex; `--ruthless` adds a 4th Claude red-team reviewer for 10) + 24 principle agents in parallel; indefinite fix loop until 3 consecutive rounds yield zero new non-deferred findings; hard gates on schema/auth/deps/secrets/CI/tests batched for human review at the end. Claude-side spawns (reviewers, synthesis, Architect, Editor) use the `review-worker` agent (Opus 5.5, medium effort). |
| `/god-report` | Single-pass multi-model codebase review report - same reviewer fleet as `/god-review` (Claude spawns via `review-worker`) but NO fixes applied; pure report. Optional `--rounds N` for de-noising. |
| `/ui-audit` | Audits one tab's UI end-to-end to catch fake or dead elements. Report-only: enumerates the entire rendered surface across every reachable sub-state, gives each element a strict REAL / STATIC-BY-DESIGN / FAKE-OR-DEAD / UNVERIFIED verdict via three reconciled passes (static code trace, live-browser x-ray over raw CDP, screenshot vision). Emits findings.json + AUDIT.md + per-state screenshots. Never edits app code. |
| `/database-audit` | Deep multi-provider database audit (Supabase, Neon, vanilla Postgres) - schema, RLS, security, prod-readiness, client coherence. Read-only; refuses prod without `--env=prod`. Optionally emits DATABASE.md. |

Pack subskills (invoked as `/<pack>:<name>`):

- **god-review** - 38 subskill files: 10 broad-reviewer prompts, of which 9 spawn on a default run - the 4th Claude one, `claude-ruthless-redteam`, is `--ruthless`-only (`broad-reviewers:` `claude-architecture-prod`, `claude-deep-correctness`, `claude-ruthless-redteam`, `claude-security-resilience`, `codex-cross-layer`, `codex-data-integrity`, `codex-deep-correctness`, `codex-prod-scalability`, `codex-ruthless-redteam`, `codex-security-safeguards`); 24 principle lenses (`principles:` `antipatterns`, `architecture-backend`, `architecture-frontend`, `ci-yaml-tampering`, `circular-deps`, `clarity`, `contradiction-detector`, `database-audit`, `dead-code-conservatism`, `dead-end-detector`, `documentation`, `gap-detector`, `hallucinated-imports`, `info-loss-detector`, `perf-benchmark`, `perf-heuristic`, `prompt-injection`, `reuse`, `scope`, `secret-leak`, `self-contained`, `single-pattern`, `tanstack-query`, `test-deletion`); `lib:editor-agent`; plus CHANGELOG, CRITERIA, README.
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
| `/pre-compact` | Run before context compaction. Refreshes project docs via `/document`, then writes a SID-tagged `CLAUDE.local.<sid8>.md` handoff (active task, plan, decisions, open issues, gaps) so post-compact Claude picks up the thread without losing info. Tokens: `no-document`, `no-mission` (never create a mission; `/transfer` passes both), `no-auto-compact`, `no-gitignore`, `auto-confirm`. |
| `/post-compact-resume` | Fired automatically after `/compact` by the Stop-hook chain; locates the SID-tagged handoff file and resumes the thread. |
| `/transfer` | Moves THIS live chat (or, with `codex <session-id>`, a closed Codex chat) to your other Mac, terminal only. Writes a fresh handoff, packs the transcript, `/line` name, handoff/mission files and the git worktree (unpushed commits, uncommitted edits, every untracked or ignored file - `.env` and credential files included) into one encrypted file in iCloud Drive, then prints a one-time code. Machine-bound state (locks, liveness, pid files, sockets, logins) and `node_modules`/`dist`/`.next`/`coverage` never move; secret-scan hits are FYI only (listed by file and rule in the TRANSFER notes), never a refusal. Running things (servers, containers, background tasks) do not move - they're written into a restart checklist instead. On the other Mac, `resumework <code>` downloads, decrypts, verifies every checksum, restores everything, and execs `claude --resume` (or `codex resume`). `--dry-run` lists what would be sent without writing anything. **Delta sends:** after the first transfer between the two Macs, a later send leaves out every untracked/ignored file the other Mac already has (same sha256 as recorded in `~/.claude/transfer-state/` by the last successful send or `resumework`) and lists it in the bundle as "assumed present"; `resumework` checks each one and lists any that is missing or different on its Mac (never a failure, never touched). The chat's own files and git state always travel. `--full` re-sends everything; a missing or damaged record, or a previous send nobody collected, also means a full send. A file deleted on the receiving Mac after the last transfer is not re-sent while it is unchanged on the sender - it appears in that "missing here" list (a `--full` send brings it back). Inside Codex the same move is the hand-written `claude-command-transfer` skill (type `$transfer`): it writes the TRANSFER notes, sends with `--seal-after-exit` (escalated permissions), shows the code, and the file seals once the Codex chat is closed (source `codex/overrides/command-transfer/SKILL.md`). Bound scripts: `resumework`, `transfer-doctor`, `install-transfer.sh`, `make-home-alias.sh` (see "Agents and scripts" below). |
| `/document` | Audits or creates clear project documentation covering database, backend, frontend, APIs, and external integrations. Updates existing docs or bootstraps a full `docs/` tree. Navigable for both humans and LLMs. |
| `/claudemd` | Captures a lesson from the current moment into the RIGHT instruction surface - investigates what the lesson is and why, routes to the strongest enforcement layer (check > global CLAUDE.md > project AGENTS.md/CLAUDE.md > docs/), proposes the exact edit, applies on approval. |
| `/skill-improve` | Turns the current session into improvements for an existing skill or command - scans the session for direct evidence (what worked, what failed, what confused) and produces copy-ready patches. Report-only by default; `--apply` hands off to `/implement`. |
| `/line` | Names this window once, setting BOTH its statusline line-2 caption and its peer address - the name `ListAgents` shows and `SendMessage` resolves. Also sets the display name Remote Control shows for this chat on your other Macs, to that same short handle, so the name you see there is the name you message it by. No args clears the caption (the address is deliberately left alone). Its script also carries the peer protocol: `list`/`find` to resolve a window the user named in prose, `card` to introduce yourself, `whois <pid>` to look up (never authenticate) an inbound sender, `reply`/`replies` for the fallback dropbox, `note`/`notes` for shared answers. |
| `/pickup` | `/pickup <time>` (any natural form: `5:40pm`, `5 30 am`, `10 min`, `2 hours`, `tomorrow 6am`; or `cancel`) arms this tab to prompt itself once the usage limit resets - a one-shot resume plus a 20-minute-later backup, both session-only (`CronCreate`/`CronList`/`CronDelete`, deferred tools). With no argument it reads the cached `~/.claude/ratelimit.json` reset time (`scripts/pickup-time.py`, tested by `scripts/hooks/test-pickup-time.sh`). Esc out of a running task first, then run `/pickup` - once armed, it continues that task in the same turn. `/pickup cancel` removes this tab's jobs and its resume note. Per-tab, and lost if the tab closes or the app restarts before the fire time; a sleeping Mac may miss or delay it. |
| `/recap` | Catches you up on everything the agent did since your last message, in plain language, 250 words max. Reads the session transcript on disk (`scripts/recap-extract.py`), so it survives compactions and includes helper agents' work; checks git and anything load-bearing before claiming it, and labels a from-memory fallback if the transcript can't be read. `/recap <focus>` weights it toward one topic. Shadows Claude Code's built-in `/recap`; the built-in "welcome back" auto recap is turned off with `awaySummaryEnabled: false` (see SETUP.md). If the agent is busy it waits for the current step to end - press Esc first to get it immediately. |

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
| `/outreach` | HubSpot -> Salesmsg SMS draft pipeline (Arc Boats). Opens with an intake (which report/list, campaign goal, message phrasing, HubSpot decision rules - no default lead source). Vets contacts via the internal HubSpot API, reads message history to tailor copy, drafts unsent texts into the Salesmsg widget one Chrome tab per contact, and maintains a never-contact ledger so a declined or dead-number contact is never re-drafted. Draft-only: never sends, never edits HubSpot. Scripts in `commands/outreach/scripts/` (raw CDP over WebSocket, no chrome-devtools MCP dependency). |

Pack subskills (invoked as `/<pack>:<name>`):

- **desktop** - 7 subskills: `shot`, `window`, `click`, `key`, `type`, `status`, `setup`.
- **macmini** - 4 subskills: `connect`, `crd`, `act`, `setup`.
- **windows** - 3 subskills: `connect`, `crd`, `act`.

## Utilities

| Command | What it does |
|---|---|
| `/wispralt-update` | Pulls the latest WisprAlt release and updates the installed app. Handles TCC reset if the code-signing cdhash changed. |
| `/worktree-cleanup` | Frees disk by clearing old git worktrees without breaking anyone's work: read-only inventory (edits, merged-ness, real last activity, node_modules size, who has it open), asks every live agent window in the repo what it needs kept, writes keep lists, then deletes `node_modules` in idle kept worktrees and removes finished ones (clean and merged, or idle 7+ days) after archiving their untracked/ignored files to `<repo>/tmp/worktree-archive-<date>/`. Never deletes branches; re-checks each worktree at the moment it acts. Scripts: `scripts/worktree-cleanup/` (`inventory.py`, `deepcheck.py`, `classify.py`, `execute.py`, driven by `WT_ROOT`). |

## Agents and scripts the commands are bound to

Not slash commands - listed here because the playbooks above call them by name and fail closed
without them.

| Artifact | Called by | What it does |
|---|---|---|
| `agents/parallelizer.md` | `/implement` (wave gate) | Advisory scheduling subagent. Reads the repo to compute write-sets and read-sets for pending work and returns either a machine-checkable wave plan (FAN_OUT) or SERIAL_CORRECT. Never implements, never spawns agents; low confidence, malformed output, or any failure means serial. |
| `agents/review-worker.md` | `/god-review`, `/god-report` (every Claude spawn) | Worker agent (Opus 5.5, medium effort) that executes the reviewer, synthesis, Architect, or Editor prompt it is handed. Replaces `general-purpose` + a per-call `model: "opus"`. |
| `agents/devtools-worker.md` | `/devtools` (Step 4 delegation) | Sonnet 5.5 browser worker at high effort. Drives chrome-devtools for the goal the parent hands it and returns a short self-contained report; stuck after ~2 attempts = an "inconclusive" report, never a bigger model. No `tools:` line, so it inherits the MCP tools. |
| `agents/crd-clicker.md` | `/devtools`, `/windows`, `/macmini` (CRD precision click loop) | Sonnet 5.5 at medium effort. Owns the whole coarse-locate -> loupe -> crosshair-confirm -> clear -> `click_at` -> verify loop, JPEG screenshots in batches of ~10 targets. No `tools:` line, so it inherits the MCP tools. |
| `agents/review-lane-sonnet.md` | `/codex-review` (Architecture + Integration lanes) | Read-only Sonnet 5.5 review lane at medium effort; runs the lens prompt it is handed. Replaces `general-purpose` + a per-call `model: "sonnet"`, which could not carry effort. |
| `scripts/token-usage-report.py` | manual (before/after a token-saving change) | Reads one project's transcripts (main + subagent logs, de-duplicated by `message.id`) and prints relative token spend by component, agent type, and model, big cache re-writes by cause, 5m vs 1h cache-write TTL split, and loop-tick gap buckets around the 1h cache TTL. `--project-dir`, `--days N` (default 3). stdlib only. |
| `scripts/recap-extract.py` | `/recap` (step 1) | Reads this session's transcript (main + subagent logs) and prints a budgeted fact sheet of everything since the user's last real message: HEADER (anchor message, focus), LIMITS (dropped events, skipped lines, unreadable logs, freshness), ROLLUP (files changed via Edit/Write, commits/pushes, tests run, failed commands), SUBAGENTS, TIMELINE, FINAL ASSISTANT TEXT (head + tail, so a closing question survives; the last few commands keep their output tails). Anchor is chosen by line position, skipping ticks, notifications, peer messages, compaction summaries and earlier `/recap` turns. `--session`, `--transcript`, `--budget` (default 20000 chars), `--focus-stdin`; exit 2 with one stderr line when unreadable. stdlib only; tested by `scripts/hooks/test-recap-extract.sh`. |
| `scripts/parallel-stats.py` | manual + the SessionStart cleanup hook | Transcript parallelism instrumentation. Groups tool calls by `message.id` (never by JSONL record), reports solo vs batched spawn turns, raw and refined solo codex turns with per-surface attribution, per-phase wall clock, and the rework log. `--replay` adds would-have-fired nudge counterfactuals and a decomposed wave-gate eligibility table with coverage denominators. `--json` for machine use. |
| `scripts/verify-parallel-wave.mjs` | `/implement` (every gate path), `merge-wave.sh` | Fail-closed wave checker, zero deps. `--validate-plan` schema- and hazard-checks a wave plan; `--wave-state` proves each worktree is clean, ancestral, committed, and wrote only inside its declared paths; `--log-decision` records a serial/fan-out decision from a closed reason-token set. Every invocation appends one capped machine event to `rework.log`. |
| `scripts/merge-wave.sh` | `/implement` (wave barrier) | Incremental, resumable merge of a verified wave. Re-verifies inline, merges chunks in declared order recording each `merge_sha`, skips already-merged chunks on resume, and leaves the tree clean at the last successful merge on conflict. Never deletes worktrees. |
| `scripts/transfer/resumework` | the owner, in Terminal on the RECEIVING Mac | Terminal command for `/transfer`'s other half. Downloads and decrypts the transfer bundle, verifies every file's checksum, restores git state (worktree, uncommitted patch, untracked files) and session files, prints the restart checklist, then execs `claude --resume <sid>` (or `codex resume <id>`). Reports delta-send files it was assumed to have that are missing or different here. While waiting for the bundle it runs `brctl monitor com.apple.CloudDocs` in the background so iCloud delivers promptly (stopped on every exit). `--dry-run` / `--no-exec` for a safe rehearsal. |
| `scripts/transfer/transfer-doctor` | `/transfer` (preflight, `--local`) and the owner, in Terminal on either Mac | Machine-readiness checker: username/home, dotfiles checkout, `~/.claude` symlinks, settings keys (`remoteControlAtStartup`, `crossSessionInbound`), CLI versions and logins, iCloud drop dir, `openssl`/`git`/`gh`. Also runs the iCloud canary round-trip (`canary-write` on one Mac, `canary-read <name> <sha256>` on the other) that proves both Macs share one iCloud account. |
| `scripts/transfer/install-transfer.sh` | the owner, once per Mac | Idempotently symlinks `resumework` and `transfer-doctor` onto `~/.local/bin`, creates the iCloud `claude-transfers/` drop dir, and builds a clickable "Resume Chat" app on the Desktop. |
| `scripts/transfer/make-home-alias.sh` | the owner, once, only when the two Macs use different usernames | Run with `sudo` on the receiving Mac; creates a verified home-alias directory (marked `.home-alias-of`) so repo paths written under the sending Mac's username still resolve on this one, in both transfer directions. |

Schema authority for both wave artifacts: **[`docs/wave-plan-schema.md`](wave-plan-schema.md)**.
Assumption suites proving these: `scripts/parallel-stats-assumptions/`,
`scripts/verify-parallel-wave-assumptions/`, `scripts/lint-commands-assumptions/` (each
`bash <dir>/run-all.sh`, hermetic, exits 0/1/2/3).

---

Templates and support files (not invoked directly): `commands/plan_base.md` (base template loaded by
`/plan`), `commands/pre-compact-template.md` (handoff-file template written by `/pre-compact`),
`commands/devtools-CHANGELOG.md` (changelog for `/devtools`). Retired material lives in `archive/` at
the repo root - currently the `gemini/` pack, `antigravity.md`, and the
`PRECOMPACT-STARTUP-HANG-FIX.md` write-up - and is intentionally excluded from command discovery
(`archive/` is not under `commands/`, so Claude Code never loads it).
