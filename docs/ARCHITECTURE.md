# Architecture

How `~/.claude-dotfiles` plugs into Claude Code, and what runs when.

---

## On disk

```
~/.claude-dotfiles/                        ← this repo, version-controlled
├── CLAUDE.md                              ← global rules (loaded every session)
├── credentials.md                         ← 1Password op:// catalog (no secrets)
├── commands/                              ← slash commands → /name
│   ├── *.md                               (top-level: /plan, /implement, ...)
│   ├── parsa/                             (namespace: /parsa:*)
│   ├── plan2bid/                          (namespace: /plan2bid:*)
│   └── ui-ux-pro-max/                     (namespace: /ui-ux-pro-max:*)
├── agents/                                ← sub-agents spawned by skills
├── rules/                                 ← global rule files
├── patterns/                              ← /learn-extracted behavioral patterns
│   └── INDEX.md
├── docs/                                  ← long-form docs (this folder)
├── scripts/
│   ├── dotfiles-sync.sh                   (auto-push on edit)
│   ├── clean-dead-processes.sh            (RAM cleanup, cron 2-day)
│   └── whisper-transcribe.sh              (used by /transcribe)
├── .env / .env.example                    (Whisper key, etc.)
└── .gitignore
```

`~/.claude/` is the runtime location Claude Code reads. It's wired to this repo via symlinks:

```
~/.claude/CLAUDE.md   →   ~/.claude-dotfiles/CLAUDE.md
~/.claude/commands    →   ~/.claude-dotfiles/commands
~/.claude/agents      →   ~/.claude-dotfiles/agents
~/.claude/rules       →   ~/.claude-dotfiles/rules
~/.claude/patterns    →   ~/.claude-dotfiles/patterns
```

Edit a file in `~/.claude-dotfiles/`, the change is live in the next session — no copy step.

---

## Sync flow (multi-device)

```
┌──────────────┐         git pull --ff-only          ┌──────────────┐
│  GitHub      │ ──────────────────────────────────▶ │  Device A    │
│  origin/main │                                     │  ~/.claude-  │
│              │ ◀────────────────────────────────── │  dotfiles    │
└──────────────┘         git push (auto)             └──────────────┘
       ▲                                                     │
       │                                                     │ user edits
       │                                                     ▼ a file
       │                                              ┌──────────────┐
       │                                              │ PostToolUse  │
       │                                              │ hook fires   │
       │                                              │ sync script  │
       │                                              └──────┬───────┘
       │                                                     │
       └─────────────────────────────────────────────────────┘
                          push to origin/main
```

Two hooks in `~/.claude/settings.json` make this happen:

| Hook | Trigger | Action |
|---|---|---|
| `SessionStart` | New Claude Code session | `git pull --ff-only` + secret-leak scan against `credentials.md` |
| `PostToolUse` (Edit\|Write) | Any file edit | Run `scripts/dotfiles-sync.sh` — checks if the edit was inside the dotfiles dir, then `git add + commit + push` |

Project repos are **not** auto-pushed. Only this dotfiles repo. The rule lives in `CLAUDE.md` and the script checks the path before pushing.

### Other lifecycle hooks

| Hook | Script | Purpose |
|---|---|---|
| `Stop` (first entry) | `scripts/progress/on-stop.sh` | Progress-bar state cleanup for finished turns. |
| `Stop` (second entry) | `scripts/hooks/auto-compact-after-pre-compact.sh` | Fires `/compact` into the originating Terminal tab when `/pre-compact` armed it (per-session JSON sentinel under `~/.claude/progress/`). Mac/Terminal.app only. Triggered by `/pre-compact` — see [COMMANDS.md](COMMANDS.md) and `scripts/hooks/README.md`. |
| `UserPromptSubmit` | `scripts/progress/on-prompt-submit.sh` | Progress-bar state init. |
| `PostToolUse` (TodoWrite, Task) | `scripts/progress/on-{todo-write,task-spawn}.sh` | Progress-bar advances. |
| `SessionStart` (second entry) | `scripts/progress/on-session-start-cleanup.sh` | Prunes stale progress state + stale auto-compact sentinels (>12h). |

Auto-compact is the only `Stop` hook that crosses the Claude/Terminal boundary; everything else is read-only state-file plumbing.

---

## What loads when

```
┌────────────────────────────────────────────────────────────────────┐
│  Claude Code session starts                                        │
└────────────────────────────────────────────────────────────────────┘
   │
   ├─▶ SessionStart hook: git pull dotfiles
   │
   ├─▶ Loads global rules:
   │     • ~/.claude/CLAUDE.md  (→ dotfiles CLAUDE.md)
   │     • ~/.claude-dotfiles/rules/*.md
   │
   ├─▶ Discovers slash commands from:
   │     • ~/.claude/commands/*.md           → /name
   │     • ~/.claude/commands/parsa/*.md     → /parsa:name
   │     • ~/.claude/commands/plan2bid/*.md  → /plan2bid:name
   │     • ~/.claude/commands/ui-ux-pro-max/*.md  → /ui-ux-pro-max:name
   │
   ├─▶ Discovers sub-agents from ~/.claude/agents/
   │
   ├─▶ Detects FRAIM project (if fraim/ dir exists or repo matches)
   │
   ├─▶ Loads project memory:
   │     ~/.claude/projects/<project>/memory/MEMORY.md
   │
   └─▶ Resolves the SID-tagged handoff CLAUDE.local.<session_id>.md
       ← written by /pre-compact at the repo's canonical anchor; the primer
         probes cwd → show-toplevel → canonical anchor and accepts only a
         file whose END-OF-HANDOFF marker sid= matches this session (no @import)
```

---

## Skill routing

`CLAUDE.md` contains a Skill Trigger Table. On each user prompt, Claude scans it for a natural-language match. When a row triggers, Claude announces "using /skill-name" and runs it. Some skills have `Consequence = YES` (writes git, deploys, mutates DB) and require explicit confirmation.

Three categories of entries in the table:

| Form | Example | What it does |
|---|---|---|
| `/skill-name` | `/plan` | Loads the slash-command file |
| `fraim → job-name` | `fraim → recommend-next-job` | Calls `get_fraim_job` via the FRAIM MCP server |
| Cascade | `/parsa:review:all`, `/plan2bid` | Owns sub-commands; triggers them internally |

Adding a new skill = one row in the table.

---

## Credential flow

```
┌─────────────────┐      catalog (op:// only,        ┌─────────────────┐
│  1Password app  │ ───── no secret values) ───────▶ │ credentials.md  │
│  (vault)        │                                   │ (committed)     │
└────────┬────────┘                                   └────────┬────────┘
         │                                                     │
         │ op inject -i .env.op -o .env                        │ /load-creds
         │ ◀───────────────────────────────────────────────────┘ reads catalog
         ▼
┌──────────────────────────┐
│  project/.env (gitignored)│
└──────────────────────────┘
```

Rules:
- `credentials.md` only ever holds `op://` references and env var names. A SessionStart hook scans it for `sk-*`, `AIza*`, full JWTs and warns on commit-time leaks.
- `/load-creds` is the canonical way to populate a project `.env`.
- New credentials shared in chat get offered to 1Password first, fallback to `~/.zshrc`, never to a repo.

Full rules: `CLAUDE.md` → "Credential and MCP Handling".

---

## Session continuity (`/pre-compact` chain)

When Claude Code's context fills up and triggers compaction, you lose the live conversation. `/pre-compact` writes a structured handoff into a SID-tagged `CLAUDE.local.<session_id>.md` so the next session picks up cleanly.

```
Session 1 ─────┐
   work, work, │   writes CLAUDE.local.<sid>.md (Seq: 1)
   work, /pre- │   ← at the CANONICAL ANCHOR (dirname(git-common-dir)) —
   compact ────┤     identical from every worktree, so cwd-flip never relocates it
                │   resume: primer/step2 probe cwd → show-toplevel → canonical anchor,
                │     accept only if the file's marker sid= matches this session
   /pre-       │   writes CLAUDE.local.<sid>.md (Seq: 2, Parent: <ts of Seq:1>)
   compact ────┤   ← parent = the same-sid file at the anchor (marker-bound, never by mtime)
                │     "Since Last Compact" section diffs prior plan vs reality
Session 3 ─────┘   ...
```

**Parallel-track / concurrency safety:** the handoff filename carries the full session id and lives at
one deterministic per-repo location, so any number of agents — across worktrees, from any cwd — can run
`/pre-compact` concurrently and repeatedly without colliding. Parent selection is bound strictly by
`marker.sid == this session` (never mtime), so a foreign chain's handoff can never be adopted. Every
resolution failure degrades to "refuse / no-handoff," never a wrong-load. The `.gitignore` update is
guarded by an atomic `mkdir` lock under the shared git common dir plus an idempotent converge.

**Overnight autonomy — chain primitives:** each `/pre-compact` ALSO updates per-session chain state
at `~/.claude/chains/<session_id>.{json,log}`. The manifest (slim 9-field JSON, atomic `tmp+rename`)
holds the chain's `started_at`, `current_seq`, `north_star` (the immutable original goal cached
verbatim at chain birth), `last_heartbeat_at`, and `status`. The ledger is append-only TSV — one
line per `/pre-compact` invocation, never overwritten — and survives every compaction so a chain
can read its full forward-progress trail at any link. Every handoff opens with a `## Chain Status`
banner injected by Step 6A from the manifest + last 5 ledger entries (chain id, elapsed time, link
N, north star, current active task, recent progress). The SessionStart primer also prepends a
one-line chain banner to its `additionalContext` advisory. A **narrow** halt-advisory detector
runs over each link's transcript (5+ identical Bash failures with no progress, 2+ permission
denials, self-blocked patterns, repeated API errors) — when it trips, the next handoff opens with
a `## Halt Advisory` block; this is purely informational, the agent has full agency, and the halt
auto-clears on the next user-input turn. **Chain primitives never gate or refuse anything.** A
manifest write failure logs a warning and the skill continues; the SID-tagged handoff is the
load-bearing artifact, chain state is recovery aid. Corrupted manifests auto-rebuild from the
ledger (which carries `north_star_first_120` for goal recovery). See `commands/pre-compact.md` and
`scripts/hooks/lib/handoff-chain.sh` for the full design.

Each `/pre-compact` run mines the conversation at a calibrated depth (Quick / Deep / Chunked) based on size, captures every approach tried (with results and reasons), and validates the output hit a per-pass line floor before it claims done. See `commands/pre-compact.md` for the full skill spec.

---

## Adding things

| What | Where | Naming |
|---|---|---|
| Top-level command | `commands/foo.md` | `/foo` |
| Namespaced command | `commands/<ns>/foo.md` | `/<ns>:foo` |
| Sub-agent | `agents/foo.md` | `subagent_type: "foo"` |
| Global rule | `rules/foo.md` | Loaded on every session |
| Behavioral pattern | `patterns/foo.md` (or via `/learn`) | Indexed in `patterns/INDEX.md` |
| MCP server | Edit `CLAUDE.md` MCP Catalog + ask user to define before editing `.mcp.json` | Per-project |

The PostToolUse hook auto-pushes after the edit lands.

---

## Files you should know

| File | Purpose |
|---|---|
| `CLAUDE.md` | Master config: rules, skill routing, credentials, MCP, FRAIM, MoleCopilot context, writing style |
| `credentials.md` | 1Password catalog (env var names + `op://`) |
| `README.md` | Setup-on-a-new-machine guide |
| `docs/COMMANDS.md` | Full command reference (categorized) |
| `docs/ARCHITECTURE.md` | This file |
| `docs/transcribe.md` | `/transcribe` setup details |
| `patterns/INDEX.md` | Learned-pattern index (filled by `/learn`) |
| `scripts/dotfiles-sync.sh` | Auto-push hook script |

---

## Push policy summary

| Repo | Policy |
|---|---|
| `~/.claude-dotfiles/` | Auto-push freely (this repo only) |
| Any other repo | NEVER push without explicit approval |

This split is enforced by `CLAUDE.md` and by `dotfiles-sync.sh` (path check before push).
