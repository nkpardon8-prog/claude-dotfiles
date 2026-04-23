---
description: Audit or create clear project documentation covering database, backend, frontend, APIs, and external integrations. Updates existing docs or bootstraps a full docs/ tree if none exist. Output is navigable for both humans and LLMs.
argument-hint: "[optional: area to focus on, e.g. 'backend only']"
---

# Document

Audit existing documentation or create it from scratch. Output lives in `./docs/` with a fixed skeleton that adapts to what the project actually has.

**Focus (optional):** $ARGUMENTS

## Step 1: Detect current state

Run in parallel:
- `Glob docs/**/*.md` and `Glob **/README.md` and `Glob CLAUDE.md` — find existing docs
- Detect stack: check for `package.json`, `pyproject.toml`, `Cargo.toml`, `supabase/`, `next.config.*`, `vite.config.*`, framework markers
- Check for DB: `supabase/`, `prisma/`, `drizzle/`, `migrations/`, `*.sql`
- Check for API surface: `app/api/`, `pages/api/`, `routes/`, `src/api/`, `functions/`, edge functions
- Check for external integrations: grep `.env.example` keys, search code for fetch calls to non-local URLs, look for SDK imports (stripe, supabase, openai, anthropic, netlify, etc.)

## Step 2: Classify

- **No docs exist** (no `docs/` dir, no substantive README) → BOOTSTRAP mode
- **Docs exist** → AUDIT mode
- If `$ARGUMENTS` specifies an area, scope both modes to that area only

## Step 3a: BOOTSTRAP mode

Create `./docs/` with this skeleton, skipping files for areas that don't apply:

```
docs/
  README.md          index, "start here" for humans and LLMs
  architecture.md    system overview, data flow, major components
  database.md        schema, migrations, RLS (if applicable)
  backend.md         services, routes, business logic
  frontend.md        components, state, routing, build
  apis.md            internal API surface, request/response shapes
  integrations.md    external services, webhooks, credentials
```

Each file starts with frontmatter:
```yaml
---
title: [Area]
source_files: [list of files/dirs this doc describes]
last_verified: YYYY-MM-DD
---
```

`docs/README.md` is the index. It lists every doc file with a one-line summary and a "Start here if you want to..." section pointing to the right entry point for common tasks.

Spawn parallel `Explore` agents (one per applicable area) to gather source material. Each agent returns: purpose of the area, key files and their roles, data shapes, entry points, gotchas. Write each doc from the agent's findings.

For `integrations.md`: list each external service, what it's used for, which env vars it needs, and where in the code it's invoked. Never write actual credential values.

## Step 3b: AUDIT mode

For each existing doc:
1. Read the doc and its `source_files` frontmatter (if present).
2. Spawn an `Explore` agent to verify: do the referenced files still exist, do the described behaviors match current code, are there new files in that area not covered.
3. Report drift per doc (green = accurate, yellow = partial drift, red = substantially wrong).
4. Update affected sections. Bump `last_verified`. Add new subsections for new behavior.

If an area has no doc but has substantial code, create the missing doc using BOOTSTRAP logic for that area only.

If `CLAUDE.md` exists, cross-reference it and flag conflicts between `CLAUDE.md` and `docs/` so the user can reconcile.

## Step 4: Index refresh

Rewrite `docs/README.md` so it accurately reflects the current set of files and their summaries. Keep it short. One line per file plus a small "Start here if..." map.

## Step 5: Report

Output a compact summary:
- Mode used (BOOTSTRAP or AUDIT)
- Files created or updated (list with paths)
- Drift found and fixed (AUDIT only)
- Anything skipped and why
- Anything the user should verify manually (ambiguous behavior, inferred intent)

## Rules

- Do not touch `CLAUDE.md` unless the user asks. It is user-managed.
- Do not write credential values, only the env var names.
- Do not fabricate behavior. If something is unclear from the code, write "unclear, verify with maintainer" rather than guessing.
- Keep each doc under 400 lines. If it would be longer, split by subtopic and link from the index.
- Write in short declarative sentences. No marketing adjectives. No em dashes.
