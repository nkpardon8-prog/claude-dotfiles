---
description: Turn the current Claude Code session into improvements for an existing skill or command. Reads the target skill's source, scans this session for direct evidence (what worked, what failed, what was confusing), and produces copy-ready patches. Report-only by default — pass --apply to hand off to /implement. Accepts one or more target skills.
argument-hint: "[target-skill] [more-targets...] [--apply] (e.g. 'optimize-website', 'pdf-extractor estimate-builder', 'parsa:fix-bug --apply')"
---

# /skill-improve — Session-Driven Skill Refinement

Take an existing skill name (or multiple) and use the current Claude Code session as a real usage log to improve it. The session is **evidence**, not a template — the goal is general, reusable improvements, not overfit rules.

## Core Idea

Most skills drift from reality. They were written once, then real sessions revealed: missing instructions, weak defaults, fragile assumptions, confusing steps, manual fixes the skill should have done automatically. This command harvests that.

This is the **inverse** of `/learn`:
- `/learn` extracts behavioral patterns into `~/.claude/patterns/`.
- `/skill-improve` patches a specific skill file based on this session's evidence.

## Behavior Rules (non-negotiable)

- **Do not invent session details.** Every claim must trace to actual session evidence. If a section has no signal, write "no signal from this session" rather than padding.
- **Do not auto-edit the target skill.** Report-only by default. `--apply` is opt-in and hands off to `/implement` against the brief.
- **Do not blindly rewrite.** Prefer the smallest patch with the highest leverage.
- **Do not overfit.** If a finding only applies to today's specific task, mark it in the **Overfitting Warning** section and exclude it from the patch.
- **Tag every claim with evidence weight**:
  - `[direct]` — the target skill was actually invoked this session
  - `[adjacent]` — the session did work the skill would have covered, but the skill wasn't run
  - `[inferred]` — a general principle, not grounded in this session's events (use sparingly)
- **Surface skill-vs-harness-vs-user-pref**. If a friction point really belongs in hooks, settings.json, or a user CLAUDE.md, say so — don't stuff it into the skill body.

## Step 1: Parse Arguments

`$ARGUMENTS` may contain:
- A single skill name: `optimize-website`
- Multiple names: `optimize-website pdf-extractor`
- Plugin-namespaced names: `parsa:fix-bug`, `god-review:principles:reuse`, `ui-ux-pro-max:design`
- Comma-separated: `"foo, bar"`
- An optional `--apply` flag (anywhere in the argument string)

Extract:
- `TARGETS` — list of target skill names (strip the `--apply` token)
- `APPLY` — boolean, true iff `--apply` is present

**If `TARGETS` is empty:**
- Scan this conversation for skills referenced by name, invoked via the Skill tool, or mentioned in slash form (`/foo`, `/foo:bar`).
- List up to 10 candidates with a one-line reason each ("invoked twice", "mentioned in user request", "tool result references it").
- Ask: *"Which skill(s) should I improve? (name(s) or numbers, optionally `--apply`)"*
- **Wait** for the answer; re-parse it as `$ARGUMENTS`.

## Step 2: Locate Each Target Skill File

For each `target` in `TARGETS`, resolve to a file path. Try in order:

1. `~/.claude-dotfiles/commands/{target}.md`
2. `~/.claude-dotfiles/commands/{target.replace(':', '/')}.md` *(handles `parsa:fix-bug` → `parsa/fix-bug.md`, `god-review:principles:reuse` → `god-review/principles/reuse.md`)*
3. `~/.claude-dotfiles/skills/{target}.md` and `{target.replace(':','/')}/SKILL.md`
4. `~/.claude/commands/{target}.md` (mirror)
5. `~/.claude/skills/{target}/SKILL.md`

If none resolve:
```
Could not locate "{target}". Searched:
- ~/.claude-dotfiles/commands/{target}.md
- ~/.claude-dotfiles/commands/{target.path}.md
- ~/.claude-dotfiles/skills/{target}/SKILL.md
- ~/.claude/commands/{target}.md
- ~/.claude/skills/{target}/SKILL.md

Provide the exact path, or run /skill-improve without arguments to pick from candidates discovered in this session.
```
**Stop** for that target (continue with others if any).

If found, read the **full file** (and any sibling lib files, sub-commands, or CHANGELOG.md if they exist in the skill's directory). Note: read, don't summarize from memory — your prior knowledge of the file may be stale.

## Step 3: Gather Session Evidence

Before producing recommendations, build an evidence pool by scanning **only** what actually happened in this session:

### 3a. Direct invocations
- Was the target skill invoked via the Skill tool, slash command, or referenced verbatim? If yes, record where and what happened (success, failure, midway-correction, user dissatisfaction, etc.).

### 3b. Adjacent work
- Did the session do work the target skill is supposed to cover (e.g., bug-hunting for `/investigate`, plan-writing for `/plan`)? Record file paths, tool calls, and outcomes.

### 3c. User corrections
- Where did the user push back, redirect, or correct the agent? These are gold — they often reveal a missing instruction or weak default in whichever skill was active.

### 3d. Manual fixes
- What did the user (or the agent under user direction) fix by hand that a better skill would have handled automatically? Examples: re-running with different flags, repairing malformed output, restating a constraint.

### 3e. Confusion / re-asks
- Where did the agent ask a clarifying question that better skill defaults could have answered, or re-ask something the skill should have remembered?

### 3f. Assumptions that bit
- Where did an unspoken assumption cause a wrong turn? (e.g., assumed dev server was running, assumed file existed, assumed user wanted X.)

### 3g. Tool/file/workflow patterns
- Which tools, files, or sequences came up repeatedly? Repetition is a signal the skill should encode.

For each evidence item, capture: **what happened**, **where in the session**, **which target skill it bears on**.

If evidence is thin (e.g., the skill was never invoked and the session did nothing adjacent), say so explicitly in Section 2 of the output and skip to Section 9 (Overfitting Warning) plus Section 10 (Final Recommendation) with "insufficient evidence for patch".

## Step 4: Produce the Report

For each target skill, produce a section using exactly this 10-part structure:

```markdown
# Skill Improvement Report: /{target}

**File:** {resolved-path}
**Evidence weight:** {N direct events, M adjacent events, K user corrections}
**Was the skill invoked this session?** Yes / No

---

## 1. Target Skill
{name + one-line purpose pulled from the skill's frontmatter `description`}

## 2. Session Summary
{2-4 sentences: what was the session trying to do, and how does it relate to this skill?}

## 3. What Worked
- [{direct|adjacent|inferred}] {worked item} — {brief evidence pointer}
- ...

(If no signal: "No clear positive signal from this session.")

## 4. What Did Not Work
- [{tag}] {failure / friction / confusion / manual fix} — {evidence pointer}
- ...

(If no signal: "No clear negative signal from this session.")

## 5. What the Skill Should Learn
General, reusable lessons (NOT session-specific facts):
- {lesson 1} — confidence: high/med/low
- {lesson 2} — confidence: high/med/low

## 6. Skill Improvement Ideas
Prioritized list. Highest-leverage first. Each item declares:
- **Category**: instructions | defaults | examples | validation | recovery | file-handling | tool-usage | logging | edge-cases | command-examples
- **Layer**: skill-body | harness/hooks | user-prefs (CLAUDE.md)
- **Confidence**: high | med | low
- **Evidence**: [direct|adjacent|inferred] + one-line pointer

Example:
- **(skill-body, defaults, high) [direct]** Set `MAX_ROUNDS` default to 5 instead of 3 — session ran out of rounds twice with no progress signal.

## 7. Proposed Skill Patch
Section-replace format. Each patch entry:

```
### Patch {N}: {short title}
**File:** {path}
**Anchor:** {section heading or line range, e.g. "## Step 2: Locate Each Target Skill File" or "L120-L135"}
**Change type:** add | replace | delete
**Confidence:** high | med | low

**Before:**
```
{exact current text — or "(new section)" for an add}
```

**After:**
```
{exact new text}
```

**Rationale:** {one sentence linking to the evidence pointer}
```

Produce 1-5 patches max. If you cannot produce a concrete patch, say so — do not pad with vague suggestions.

## 8. Do Not Change
- {thing that worked, or that changing would overconstrain the skill}
- ...

## 9. Overfitting Warning
Things that seemed like signals but are too specific to this session to generalize:
- {item} — why it's session-specific

## 10. Final Recommendation
**Verdict:** small patch | medium rewrite | major rewrite | insufficient evidence
**One thing to do first:** {single concrete next action}
```

If multiple targets were given, produce one full report per target, separated by `---`.

## Step 5: Write the Brief Artifact

After producing the report(s), save them to:
```
./tmp/skill-improve/YYYY-MM-DD-{first-target-name}.md
```
(Use the first target's name; if multi-target, append `-plus-N` where N is the count of additional targets.)

Create `./tmp/skill-improve/` if it doesn't exist. If the file already exists, append `-2`, `-3`, etc.

The brief contains the full report(s) plus a machine-readable patch list at the bottom:

```markdown
---
## Patch Manifest (for /implement)

For each patch, repeat:
- target_file: {absolute path}
- anchor: {heading or line range}
- change_type: add | replace | delete
- before: |
    {exact text}
- after: |
    {exact text}
- confidence: high | med | low
```

## Step 6: Hand-Off

**If `APPLY` is false (default):**
Output:
```
Report saved to ./tmp/skill-improve/{filename}

Patches proposed: {N high, M med, K low confidence}

To apply, run:
/skill-improve {targets} --apply

Or pick patches manually and run /implement against the brief.
```

**If `APPLY` is true:**
Before applying anything, output the patch manifest summary and ask:
*"Apply all {N} patches? (yes / pick-by-number / no)"*

On `yes` or a pick-list:
- Hand off the selected patches to `/implement` with the brief path as input.
- `/implement` is responsible for the actual edits, type-checks, and verification.
- Do **not** edit the skill file directly from this command. The separation is intentional: `/skill-improve` is the analyst, `/implement` is the editor.

On `no`: stop. Brief remains on disk for later.

## Notes

- This command never touches code outside the target skill file(s) and the brief in `./tmp/skill-improve/`.
- For plugin-namespaced skills (`foo:bar`), the resolved path may live in a subdirectory — be precise about which file the patches target.
- If the target skill has a `CHANGELOG.md` in its directory, check whether a proposed change already shipped before recommending it.
- If the session was largely off-topic from every target skill, the honest output is a short report with "insufficient evidence" — that's a feature, not a failure.
- Multi-skill calls: each target gets its own evidence pool. Don't cross-contaminate findings.

Target skill(s) to improve: $ARGUMENTS
