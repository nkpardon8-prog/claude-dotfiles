---
description: Capture a lesson from the current moment into the RIGHT instruction surface — investigates what the lesson is and WHY, reads the existing files so it doesn't duplicate, routes to the strongest enforcement layer (check > global ~/.claude/CLAUDE.md > project AGENTS.md/CLAUDE.md > docs/), proposes the exact edit, applies on approval. Use mid-situation whenever something worth remembering just happened (a bug pattern, a convention, a gotcha, a correction, a decision). Works in any repo, malleably.
---

# /claudemd — capture a lesson into the right instruction file

A lesson just appeared (a bug you fixed, a convention you settled, a gotcha that bit you, a correction
the user gave). `/claudemd` turns that moment into a durable instruction in the RIGHT place — without
bloating anything. The whole point: the agent genuinely **goes and understands** what to add and why,
then puts it where it will actually be read and enforced. Works in any project; degrades gracefully if
a file doesn't exist.

`$ARGUMENTS` (optional): a hint at the lesson. If empty, infer it from the recent session.

## Step 1 — Understand the lesson (the WHY, not just the WHAT)
- If `$ARGUMENTS` describes it, start there. Otherwise infer from the recent conversation: the last bug
  fixed, decision made, surprise hit, or correction the user gave.
- State it in one line: **"The lesson is X — because Y"** where Y is the concrete wrong-turn it prevents
  (what broke, or what a future agent would get wrong without it).
- If you can't articulate Y, you don't understand it yet — **ask the user one sharp question** rather than
  capturing a vague rule. A rule with no clear failure-mode it prevents is bloat.

## Step 2 — Load the existing instruction surface (so you place it right, don't duplicate)
Read what already exists before deciding where the lesson goes:
- **Global:** `~/.claude/CLAUDE.md` (auto-loads into every project).
- **Project (if present):** `./AGENTS.md`, `./CLAUDE.md`, `./docs/ENGINEERING.md`, `./docs/OVERVIEW.md`,
  `./docs/reference/COORDINATION.md`, and (via `docs/OVERVIEW.md`'s file→doc map) the area doc the lesson touches.
- Note which sections already cover adjacent ground. If the lesson is already stated somewhere, SHARPEN that
  line instead of adding a second one (one way to do everything).

## Step 3 — Route to the strongest home (the enforcement ladder)
Decide WHERE and in WHAT FORM, strongest-enforcement-first:
1. **Can it be a CHECK?** (lint rule / test / hook / CI gate) → propose THAT first. A gate the build can't
   skip beats prose that degrades after compaction. (e.g. "never import X" → an ESLint `no-restricted-imports`
   rule + where it wires in; "this op must never hit prod" → a PreToolUse hook.)
2. **Is it UNIVERSAL** (how-we-build, a rigor principle, a coding convention that holds in ANY repo)?
   → `~/.claude/CLAUDE.md` (the reusable core — auto-loads everywhere). This is a dotfiles file.
3. **Is it PROJECT-SPECIFIC** (this repo's structure, a repo-only hard rule, a convention, a gotcha)?
   → the project's `AGENTS.md` (map-level rule/convention), `CLAUDE.md` (Claude-specific working note),
   `docs/ENGINEERING.md` (a principle's depth/backlog), or the area doc per `docs/OVERVIEW.md` (reference depth).
4. Pick the **single best home**. Don't duplicate across files (the only intentional mirror is the
   safety-critical Hard-rules block some projects keep in both AGENTS.md + CLAUDE.md).

Decision aids: *applies to every repo?* → global. *only makes sense here?* → project. *enforceable by code?*
→ check. *deep rationale/backlog, not an always-loaded rule?* → docs/.

## Step 4 — Propose the exact edit (then apply)
- Name the **file + section + exact line(s)** to add or change. Keep it tight: one load-bearing line/bullet,
  matching that file's existing voice and brevity. For a check, give the rule + the file it wires into.
- Show the proposed edit and get a quick confirmation before writing (skip the confirm only if the user said
  to just do it).
- Apply it. Then handle the destination's git norms:
  - Touched `~/.claude/CLAUDE.md` or another **dotfiles** file → that's the auto-push dotfiles repo; commit + push
    per the global dotfiles rule.
  - Touched **project** files → a normal project change; do NOT push without explicit approval.
- **Modular fallback:** if the ideal home doesn't exist (e.g. no `AGENTS.md`, or this project has no `docs/`),
  put it in the next-best existing surface and note the gap (offer to scaffold the missing file).

## Principles
- One lesson → one home. Prefer a check over prose. Match the target file's voice and brevity.
- Don't bloat: if a line isn't preventing a specific wrong turn or teaching something non-obvious, don't add it.
- Universal vs project is the core routing call — get it right so the reusable core stays clean and each
  project's files stay tuned to that project.
