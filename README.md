# Claude Dotfiles

**A multi-model web of commands, built to be driven dynamically by an agent — the answer to vibe coding. This is agentic engineering.**

This is a web of specialized commands that agents call as they work. Each command can trigger
multiple specialist subagents for research, planning, implementation, testing, or review. Work
flows through a chain of experts instead of a single model. And with a system built to preserve
context, decisions, and progress across compactions (tested up to 23 hours non-stop), builds can
run for hours without losing track of their mission.

Use each model for what it does best. Claude handles architecture, planning, and big-picture
thinking. Codex handles precision, correctness, security, and verification. No single model carries
the full workload — each is used where it's proven to perform best. The result is higher quality,
more scalable, and much closer to what real software engineering with AI should look like.

*Developed by the team at IntegrateAPI.ai — Omid · Nick*

---

## The loop

Every arrow is a real artifact written to disk and read by the next command. No copy-paste between
stages.

```
  /discussion ──▶  ./tmp/briefs/ ──▶  /plan ──▶  ./tmp/ready-plans/ ──▶  /implement ──▶  ./tmp/done-plans/
   talk it out      a brief          research+        a reviewed         parallel          shipped,
   (no code)                         plan, reviewed    plan              build, reviewed   reviewed

        every stage self-reviews ──▶  plan-reviewer · implementation-reviewer · criticer
        /pre-compact carries the thread across context compaction, indefinitely

  Review ladder — same DNA, escalating power, always Claude + Codex together:
        /codex-review   a diff or idea        report-only
        /god-report     a whole codebase      report-only
        /god-review     a whole codebase      autonomous fix-loop to convergence
        /mission        a multi-part build    conducts the entire loop, autonomously

  Power tools:  /script  prove assumptions   ·  /database-audit  ·  /devtools
```

---

## The skills

### Build

**`/discussion`** — Conversation-only mode. It researches the codebase, talks through tradeoffs
with you, and writes a brief to `./tmp/briefs/`. It never touches code. The brief is the input to
`/plan`, so the thinking carries forward into a fresh context.

**`/plan`** — Builds a real implementation plan with codebase *and* web research. It auto-loads the
latest brief, then runs a `plan-reviewer` and a generative `criticer` and iterates with you until
the plan is sound. Output lands in `./tmp/ready-plans/` — approved and ready to execute.

**`/implement`** — Takes an approved plan and executes it through parallel `implementer` sub-agents,
then auto-runs an `implementation-reviewer` and `criticer` against the plan. When it's done the plan
moves to `./tmp/done-plans/`. You hand it a plan; you get back reviewed, finished work.

### Stay alive

**`/pre-compact`** — The continuity spine. Before Claude compacts the conversation, this writes a
structured handoff (`CLAUDE.local.<sid>.md`) with a `Seq:`/`Parent:` chain, a *What We Tried* log,
and an *Evidence & Data* section, then auto-fires `/compact`. The next session picks up exactly
where you left off. Multi-day builds stop losing the thread.

### Review — multi-model

The review ladder is the same idea at four sizes. Every rung fields a **mixed Claude + Codex fleet**
so the two models cross-check each other instead of one model grading its own homework.

**`/codex-review`** — The universal review engine, **report-only**. Codex (GPT-5.5) runs 4 specialist
passes — Correctness, Security, Data-integrity, Contracts — plus a verification pass; Claude Opus
runs 3 lens agents (Architecture, Integration, Adversarial + false-positive filter) plus a meta
review. Point it at a diff, a plan, an idea, a bug — anything.

**`/god-report`** — The whole-codebase review, **no fixes, pure report.** 4 Claude broad reviewers +
6 Codex broad reviewers + 24 principle agents (Claude *and* Codex per principle) run in parallel.
Add `--rounds N` to de-noise. Use it when you want the truth about a codebase without anything
changing underneath you.

**`/god-review`** — The same fleet as `/god-report`, but an **autonomous fix loop**: it reviews,
fixes, and re-reviews until 3 consecutive rounds turn up zero new findings. Hard gates
(schema, auth, deps, secrets, CI, tests) are batched for you to approve at the end. Set it loose and
come back to a cleaner codebase.

### Conduct

**`/mission`** — The conductor for genuinely large, multi-part builds. For *each* part it runs
research → `/plan` (with the full reviewer loop) → `/implement` → a 4-Codex + 3-Claude code-review
panel, driving each part to honest convergence before moving on — across many parts and many
compactions, riding `/pre-compact` so it never loses the thread. Opt-in and heavy; overkill for
small work, unbeatable for big ones.

### Prove & connect

**`/script`** — Generates pre-flight tests that **prove the load-bearing assumptions** of a plan
against real infrastructure *before* you implement, then re-run as regression catchers *after*. The
tests are idempotent, self-cleaning, and deterministic, with synthetic data tagged by a stable
namespace marker + per-run UUID. For when the stakes are real — prod, user data, HIPAA, financial,
safety-critical — and "find out by deploying" isn't an option.

**`/database-audit`** — A deep, **read-only** audit across Supabase, Neon, and vanilla Postgres:
schema, RLS, security, prod-readiness, and client/code coherence. It refuses to touch prod without
an explicit `--env=prod`, and can emit a `DATABASE.md` for the repo.

**`/devtools`** — A self-healing connector for the chrome-devtools MCP. It ensures a debug Chrome
(your real profile and tabs) is live on port 9222, kills stale MCP processes, scrubs corrupt npx
installs, and prompts a reconnect. Run it whenever devtools calls hang — it makes browser debugging
actually connect.

---

## Why a web beats a pile of prompts

- **Artifacts web together.** `briefs → ready-plans → done-plans` is a literal file chain. Each
  command reads the previous one's output, so context survives the jump between stages.
- **Every stage reviews itself.** `/plan` runs a reviewer + critic before you sign off; `/implement`
  reviews against the plan; the review ladder loops until clean. Quality is built in, not bolted on.
- **No single model is the bottleneck.** Claude and Codex are used where each is strongest and made
  to cross-check each other. Two strong, different models catch what one model alone never will.
- **It survives compaction.** `/pre-compact` + the mission-bridge mean a build that spans days and
  many context windows never loses the plot.

---

## Setup

```bash
git clone https://github.com/nkpardon8-prog/claude-dotfiles.git "$HOME/.claude-dotfiles"
chmod +x "$HOME/.claude-dotfiles/scripts/dotfiles-sync.sh"

# symlink into ~/.claude (back up any existing targets first)
for d in CLAUDE.md commands agents rules patterns; do
  rm -rf "$HOME/.claude/$d"; ln -sf "$HOME/.claude-dotfiles/$d" "$HOME/.claude/$d"
done
```

Then add the SessionStart pull + PostToolUse auto-push hooks to `~/.claude/settings.json`. The repo
auto-syncs across devices — pulls at session start, pushes after any edit (behind a pre-push secret
scan). **Project code repos are never pushed without explicit approval.**

Full install, credentials (1Password-backed), and troubleshooting → **[`docs/SETUP.md`](docs/SETUP.md)**.

---

## More

- **[`docs/COMMANDS.md`](docs/COMMANDS.md)** — the full reference for every command, including the
  industry suites (construction estimation, drug discovery, UI/UX) not covered above.
- **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)** — how the pieces wire together: load order,
  sync flow, credential flow, skill routing.
- **[`docs/SETUP.md`](docs/SETUP.md)** — install, auto-sync, credentials, troubleshooting.
