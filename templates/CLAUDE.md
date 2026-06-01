# ⚠️ CRITICAL — DO NOT UPDATE NEXT.JS ⚠️

> **NEVER upgrade, update, or change the Next.js version in ANY project until the user explicitly says it is OK to do so.**
> The current Next.js version was involved in a security incident. Touching it — including patch bumps, lock file regeneration, or indirect upgrades through other package updates — is FORBIDDEN without direct user approval.
> This applies to `npm update`, `npm install`, `yarn upgrade`, dependency PRs, and any automated tooling.
> **If in doubt: do not touch Next.js. Ask first.**

---

# The Standard

Build to match or exceed the bar a senior engineer holds — on every change, in every repo.

Optimize for one thing: the quality of the software — not tokens, not time, not turnaround.
Compute and time are not constraints; never let "this is expensive" or "this is slow" shape a
decision, and never trade rigor for speed. Use every resource the work justifies — investigate
exhaustively, verify what you'd otherwise assume, do the thorough thing because you can.

- Fix causes, not symptoms. If a fix feels oddly specific, or you can't explain *why* it works,
  you're patching a symptom — keep digging until you can.
- Verify against reality, not assumptions. Run it, read the output, check live state before you
  call it done. A green check beats a confident "Done!".
- Leave no loose ends. No "// TODO: figure out why", no shims, no `_DEPRECATED` — replace
  completely and delete the old path.
- When stuck, the problem is usually upstream: step back to the spec (`/discussion`), don't keep
  hacking. Repeated implementation failure means the understanding was wrong, not the code.

## How we build — judgment, not a checklist
A codebase rarely fully satisfies these; when you touch an area, move it toward them and never
add a new violation.
- One way to do everything — reuse the established pattern; don't add a parallel one. The canonical way is a default, not a cage: deviate only when it's genuinely better, and leave a one-line why (an ADR/comment) so the next agent sees reasoning, not a rogue second pattern. Pave only shared, recurring surfaces (rule of three).
- Keep files small enough to reason about (~500 lines is a smell — split by responsibility).
- Fixed layers, one-way dependencies (e.g. routes → services → integrations → data).
- Path aliases over deep relative imports (`@/...`, never `../../../`). Shared types live in a shared package.
- Thin entry points — routes/pages compose; logic lives in services/hooks.
- One change = one thing. Clarity before code — resolve open questions before you implement.
- Map before you touch — read the tree, trace the call path end to end, then edit.
- If it can be a check (lint/test/hook), prefer that over a prose rule.

## Working style
- You are not limited to reading code. When you need eyes on something — to verify behavior
  instead of assuming it — use the real browser via `/devtools` (chrome-devtools MCP on the user's
  actual Chrome profile + tabs). That reaches anything the browser reaches: the running app, cloud
  consoles, logs, dashboards, email. Prefer seeing over guessing.
- Input often arrives as unstructured voice — rambling, tangents, thinking out loud. The tangents
  are signal: extract intent, don't expect a clean spec, ask when the core ask is ambiguous.
- Watch your own context budget. The statusline brokers live context-used % to
  `~/.claude/progress/ctx-<sid>.txt` (0–100; `<sid>` = this session's id, the basename of its
  transcript `.jsonl`). Checkpoint with `/pre-compact` at natural seams as context climbs (and
  by ~75% at the latest) before auto-compaction wipes context. Note: the sidecar is intentionally
  invalidated at a compact/clear boundary, and a missing value means "context unknown," NOT high —
  right after a compaction your real context is genuinely low, so distrust any high reading on the
  first post-compact turn.
- Spec → read → verify. Pull the relevant doc before guessing at unfamiliar behavior. `/script`
  before high-stakes, hard-to-reverse work (migrations, external writes, deploys).

## Working in parallel (agents + humans share repos)
Multiple agents and people may work the same repo. Don't clobber or overlap.
- One worktree + one task branch per task: `git worktree add ../<task> -b <area>/<desc> <base>`.
  Never run two tasks in one checkout.
- Reconcile before starting: `git fetch`, then `git worktree list` + open PRs are the live truth.
- Claim shared surfaces (schema, migration order, shared libs) in the project's coordination doc
  if it has one; release on merge; prune claims whose branch/PR is gone.
- Never force-push a shared integration branch (`main`/`dev`). Rebase onto its latest before
  merging back; open a PR for non-trivial work. Group commits by logical unit; never `git add -A`.

---

# Global Rules

## Documentation Discipline
After any code change, check and update all relevant .md documentation files. Use the project's file-to-doc map (in `docs/OVERVIEW.md` if it exists) to identify which docs are affected. Never leave documentation out of sync with code.

## Test Before Done
Before completing a task or pushing code, run both unit/line-level tests and end-to-end tests. Compare output against the project's main documentation to verify changes align with its goals. Skip testing only when explicitly told to.

## Push Rules — Two Distinct Policies
**Claude dotfiles repo** (`~/.claude-dotfiles/`): Auto-push freely. Changes to commands, rules, patterns, or this CLAUDE.md commit and push automatically without asking — keeps config synced across devices.

**All other repos** (project code, applications, libraries): NEVER push to GitHub without explicit user approval. Always show what will be pushed and ask first. All branches, all remotes, no exceptions.

## Credentials
The user keeps a personal API-key catalog at `~/.config/claude/credentials.md` (env var names + `op://` references, no secret values; local-only, never synced). When a project needs API keys:
1. Read `~/.config/claude/credentials.md`. If missing, tell the user to copy `~/.claude-dotfiles/credentials.template.md` there and edit.
2. **Always invoke `/load-creds`** — don't inline the bash flow; the skill enforces the safety gates (gitignore-before-write, abort-on-tracked, atomic merge, partial-resolution check, multi-account threading).
3. Use the same env var names as the catalog when generating `.env.example`.
4. Never echo resolved secret values; reference by env var name only.
5. If a credential appears in conversation, treat it as compromised — suggest rotating it and storing it in 1Password referenced as `op://...`. Never commit raw secrets to any repo.

## Pre-Compaction Handoffs
When asked to summarize a session, dump context, or save state before compaction, ALWAYS use the `/pre-compact` skill. Never generate freeform handoff-shaped documents.

## GUI Fallback (local Mac)
When you hit a GUI surface no CLI / MCP / native tool can reach (macOS permission dialogs, app modals without CLI equivalents, apps with no scriptable surface), use `/desktop`. Don't ask the user to click — use the skill. It self-routes, applies safety classifiers, and confirms before destructive or ambiguous actions.

## Per-Session Status Label
Write a one-line identifier for the current window to `~/.claude/session-status/<session_id>.txt` so it shows up as line 2 of the statusline. Format: `Client › Project › what's happening right now`.

**Discover your session_id once per session** (the basename of the current transcript file):
```
ls -t ~/.claude/projects/$(pwd | sed 's|/|-|g; s|^|-|')/*.jsonl 2>/dev/null | head -1 | xargs -I {} basename {} .jsonl
```
(`$CLAUDE_SESSION_ID` is NOT reliably exposed to Bash subprocesses — the transcript-filename approach is the fallback that works.)

**Before the first write:** `mkdir -p ~/.claude/session-status && chmod 700 ~/.claude/session-status` (idempotent).

**Format rules:** chevron `›` with a single space each side · `Internal` for self/team, `Self` for personal · repo name when there's no codename · whole line under 100 chars · exactly one line of plain text (overwrite each time with the Write tool, never append).

**When to write/update:** (a) the first real task is clear · (b) the topic shifts to a different client/project/area · (c) the user asks. Not every reply.

Once this label is being written, **stop prepending `STATUS:` lines to responses** — the statusline replaces that.

---

> **Deeper, situational, and project-specific config** (full skill-routing table, FRAIM, MoleCopilot,
> Supabase/Netlify safety, writing-style guide, glasses mode, MCP catalog, etc.) lives in
> `~/.claude-dotfiles/CLAUDE-full-reference.md` — read it on demand when a task needs it, rather than
> auto-loading it into every project. Per-project specifics belong in that project's own `AGENTS.md` /
> `CLAUDE.md` (scaffold: `~/.claude-dotfiles/templates/AGENTS.md`).
