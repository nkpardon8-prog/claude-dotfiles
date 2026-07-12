# Global Rules

<!-- 2026-07-12: this file replaced the old dotfiles fossil (recoverable via git history) and became
     the LIVE global rules, symlinked at ~/.claude/CLAUDE.md. Two rules changed under the overnight
     grant (time-prefix scope-down; Reply-style narration) — one word from the user reverts either. -->

## Lead top-level replies with the current time
Begin your FIRST reply of a session — and any reply that follows a >10-minute gap since your
previous one — with the current local time on its own first line, written as `h:mm AM/PM`
(e.g. `2:54 PM`).
- Get the time from the system clock by running `date "+%-I:%M %p"`. Never guess it, estimate
  it, or reuse a time from earlier in the conversation.
- SCOPE: top-level user-facing replies only. Never applies to subagents. Replies inside an
  active back-and-forth (<10 minutes since your last reply) do not need the prefix.

## Reply style
Structured and jargon-free. Default to roughly 250 words per reply unless the user asks for
more or the content genuinely requires it. Before each batch of tool actions, narrate intent
in 1–2 sentences — what you are about to do and why; one narration may cover a whole batch.
SCOPE: top-level user-facing turns only; never applies to subagents.

## Documentation Discipline
After any code change, check and update all relevant .md documentation files. Use the project's file-to-doc map (in docs/OVERVIEW.md if it exists) to identify which docs are affected. Never leave documentation out of sync with code.

## Test Before Done
Before completing a task or pushing code, run both unit/line-level tests and end-to-end tests. Compare output against the project's main documentation to verify changes align with the project's goals and move us closer to them. Skip testing only when explicitly told to.

## Convention timing — when a rule applies, not just what it says
A forward-looking convention ("avoid X", "prefer Y", "keep Z extractable") governs NEW code as you write it — it is NOT a mandate to retroactively rewrite working code that predates it. When you meet a convention, classify WHEN it applies: new-code-only, fix-now, or at-a-coordinated-moment (an extraction, a migration, a planned sweep). A retroactive sweep happens ONCE, at the moment it's actually needed, behind a regression net — never piecemeal across unrelated work. A retrofit whose blast radius (missed callsites, schema-wide renames, broken downstream wiring) outweighs its present value is exactly the over-engineering the quality bar forbids. Surface the timing call; don't silently treat a future-readiness goal as a bug to fix today.

## AskUserQuestion — always state context %
When asking the user a question via the AskUserQuestion popup tool, ALWAYS include the current context-usage percentage inside the question text itself (e.g. end with "(context: 58%)"). The user CANNOT see the statusline context % while the modal popup is open, so it must be in the question or they cannot judge whether to checkpoint. Read the live value from `~/.claude/progress/ctx-<session_id>.txt` right before asking (`<session_id>` = the basename of this session's transcript `.jsonl`). Applies to every agent and subagent that calls AskUserQuestion.

## Push Rules — Two Distinct Policies
**Claude dotfiles repo** (`~/.claude-dotfiles/`): Auto-push freely. Any changes to commands, rules, patterns, or this CLAUDE.md should be committed and pushed automatically without asking. This keeps the config synced across devices.

**All other repos** (project code, applications, libraries): NEVER push to GitHub without explicit user approval. Always show what will be pushed and ask for confirmation first. This applies to all branches and all remotes — unless the project's own instructions (its CLAUDE.md / AGENTS.md) define an explicit, written exception (e.g. a pre-launch "ship per tab to origin/dev" authorization). The project file is the source of truth for its own exception; when in doubt, ask.

## Credentials
The user keeps a personal API-key catalog at `~/.config/claude/credentials.md` (env var names + `op://` references, no secrets). This file is **local-only**, never synced via git. When scaffolding a project that needs API keys:
1. Read `~/.config/claude/credentials.md` to see what's available. If missing, tell the user to copy `~/.claude-dotfiles/credentials.template.md` there and edit.
2. **Always invoke `/load-creds`** — do not inline the bash flow. The slash command enforces gitignore-before-write, abort-on-tracked-secret-files, atomic merge into existing `.env`, partial-resolution checks, and multi-account threading.
3. Use the same env var names as the catalog when generating `.env.example`.
4. Never echo resolved secret values; reference by env var name only.
5. If `op whoami` fails, instruct the user to enable 1Password desktop app integration (Settings → Developer), set `OP_SERVICE_ACCOUNT_TOKEN`, or run `eval $(op signin)` in the parent shell.
6. Vault name is per-user (commonly `Personal`, but also `Private`, team vaults, etc.). If a ref fails, suggest `op vault list`.

## Pre-Compaction Handoffs
When asked to summarize a session, dump context, or save state before compaction, ALWAYS use the `/pre-compact` skill. Never generate freeform handoff-shaped documents.

## GUI Fallback (local Mac)
When you hit a GUI surface no CLI / MCP / native tool can reach (macOS permission dialogs, app modals without CLI equivalents, apps with no scriptable surface), use `/desktop`. Don't ask the user to click — use the skill. It self-routes, applies safety classifiers, and confirms before destructive or ambiguous actions.

## Statusline Line 2 — set manually with `/line`
Line 2 of the statusline is a **per-window label the user sets manually** with the `/line <sentence>`
command (no argument clears it back to the folder/repo name). **Agents do NOT write it automatically** —
there is no per-session status-label rule any more. Command definition: `~/.claude-dotfiles/commands/line.md`.
