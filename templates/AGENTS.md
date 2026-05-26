# <Project> — Agent Guide

<One-line description.> This file is the map every agent reads first. Depth lives in `docs/` —
follow the pointers below, don't guess.

> The cross-project standard ("The Standard", "How we build", working style, working in parallel)
> auto-loads from the global `~/.claude/CLAUDE.md`. This file is the per-project tuning on top of it:
> what THIS repo is, where things live, how to run it, and its hard rules.

## Structure
<Top-level layout — apps, packages, where the entry points are. A few lines.>

## Where things live (write to the right place)
- `docs/` — committed, durable knowledge: architecture, runbooks, conventions, post-mortems. Decisions go here.
- `tmp/` — GITIGNORED working state: plans, briefs, scratch. Never the source of truth.
- A durable lesson goes in `docs/` or a rule/check — never left only in `tmp/` or chat.

## Commands
- Dev: `<...>`   Build: `<...>`   Install: `<...>`
- Test: `<...>`   Lint/typecheck: `<...>`

## Definition of Done — all must hold
- Typecheck + lint clean in every app you touched; the project's check suite exits 0.
- Docs updated for what changed (see `docs/OVERVIEW.md` if present).
- Reviewed — self-review is too generous on non-trivial work.
- "Merged" ≠ "shipped" if deploys are manual — say which.

## Hard rules (non-negotiable)
- **No `git push` or external deploy without explicit approval** — all branches, all remotes, every time.
- Never log or commit secrets. <Project-specific safety invariants here.>
- No `git add -A`; no emojis.
- Commit trailer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.

## Read-on-demand (progressive disclosure)
- <Area> → `docs/<file>.md`
- Current work queue → `tmp/<...>` (gitignored)
