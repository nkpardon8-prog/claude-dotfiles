# /user:architect — Interactive Project Documentation Scaffolding

Scaffold a structured documentation web for a project. This is designed to be run BEFORE starting a new project or when adding documentation to an existing one.

Uses a three-tier progressive disclosure architecture so Claude loads only what's needed per session.

## CRITICAL: This Command Is Highly Interactive

Ask ONE question at a time. Wait for each answer before proceeding. Do NOT batch questions. Do NOT skip the interview.

## Phase 1: Interview

Ask these questions one at a time:

**Q1:** "What's the project name and a one-line description?"

**Q2:** "What's the tech stack?" *(Also check package.json/Cargo.toml/go.mod if they exist and merge detected info with the user's answer)*

**Q3:** "List the main features — just names and one-liners for each."

**Q4:** "Any non-obvious conventions? Things a linter won't catch — naming patterns, file organization rules, architectural constraints?"

**Q5:** "What are the build, test, dev, and lint commands?"

**Q6:** "Any critical architecture decisions already made? (auth approach, state management, hosting, database, API style, etc.)"

**Q7:** "Anything else I should know before I scaffold the docs?"

## Phase 2: Analyze Codebase

Read the project's existing files to supplement interview answers:
- `package.json` / `Cargo.toml` / `go.mod` — dependencies, scripts
- Directory structure — `ls -R` top 3 levels
- Existing `README.md`, `CLAUDE.md`, `docs/` — don't duplicate what exists
- `.env.example` or `.env.local` — environment variable patterns
- Database schema files — entity relationships

Merge detected information with user's answers. User answers take precedence on conflicts.

## Phase 3: Scaffold the Documentation Web

Create files with REAL content from phases 1-2. No placeholder text.

### Hot Tier (loaded every session — keep lean)

**`CLAUDE.md`** (< 60 lines):
- One-line project description
- `@docs/OVERVIEW.md` import
- Stack summary (frameworks, key libraries)
- Critical rules only (things that cause bugs if violated)
- Build/test/dev commands
- Pointer to docs/ for everything else

### Warm Tier (loaded when touching relevant files)

**`.claude/rules/`** — Create path-scoped rules relevant to the detected stack:

```yaml
---
paths:
  - "src/api/**/*.ts"
---
# API rules here
```

Only create rules files for areas the project actually has. Common ones:
- `api.md` — API layer conventions
- `components.md` — UI component rules
- `database.md` — Schema and query patterns
- `testing.md` — Test conventions

### Cold Tier (read on demand)

**`docs/OVERVIEW.md`** — Master index containing:
1. Application summary (3-5 sentences, current state)
2. Route/page table (path → page → feature doc)
3. Feature index (name, doc link, status, one-line description)
4. File-to-documentation map (source file → which doc to update)
5. Major changes log (date, what changed, affected features)

**`docs/ARCHITECTURE.md`** — Technical architecture:
- Stack with version numbers
- Key patterns (state management, data fetching, auth)
- Deployment and infrastructure
- Directory structure explanation

**`docs/DATA-MODEL.md`** — Data layer:
- Entity list with relationships
- Key database tables/collections
- Schema overview (not full DDL — point to migration files)

**`docs/features/[name].md`** — One per feature from interview:
- What the feature does (user-facing behavior)
- Key files involved (file:line pointers, not code snippets)
- How it works (data flow, state management)
- Edge cases and known limitations
- Changelog (initially empty)

**`docs/decisions/DECISIONS.md`** — ADR index (initially empty):
```markdown
# Architecture Decision Records

| Date | Decision | Status | File |
|------|----------|--------|------|
```

**`docs/decisions/`** — Empty directory for future ADRs

## Phase 4: Report

Show the tree of created files with line counts. Tell the user:

- "Your global CLAUDE.md rules automatically keep these docs updated after code changes."
- "For architecture decisions, create ADRs in `docs/decisions/` following the template in DECISIONS.md."
- "The file-to-doc map in OVERVIEW.md tells you (and Claude) which docs to update when you change a file."

## Phase 5: Auto-Push Dotfiles (if any global config changed)

If this command created or modified any files in `~/.claude/` (rules, etc.):
```bash
cd ~/dotfiles/claude && git add -A && git commit -m "architect: add rules for [project-name]" && git push
```
