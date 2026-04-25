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
   └─▶ Reads CLAUDE.local.md  (if @CLAUDE.local.md import in CLAUDE.md)
       ← post-compact handoff, written by /pre-compact
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

When Claude Code's context fills up and triggers compaction, you lose the live conversation. `/pre-compact` writes a structured handoff into `CLAUDE.local.md` so the next session picks up cleanly.

```
Session 1 ─────┐
   work, work, │
   work, /pre- │   writes CLAUDE.local.md (Seq: 1)
   compact ────┤   ← @CLAUDE.local.md import in CLAUDE.md
                │     auto-loads on next session
Session 2 ─────┤   reads Seq:1, runs again
   /pre-       │   writes CLAUDE.local.md (Seq: 2, Parent: <ts of Seq:1>)
   compact ────┤   ← "Since Last Compact" section diffs prior plan vs reality
                │
Session 3 ─────┘   ...
```

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
