---
description: "Extract behavioral patterns from this session and save to global patterns directory."
---

# /user:learn — Extract Behavioral Patterns

Extract reusable behavioral patterns from the current session and save them to the global patterns directory. Run this at the end of a productive session.

## What This Does

Patterns are behavioral rules: "when [trigger], do [action], because [reasoning]." They are NOT facts or preferences — auto-memory handles those. Patterns capture *how to work* based on what succeeded in this session.

## Step 1: Gather Context

Review the conversation and git diff to identify what worked well:

```bash
git diff --stat HEAD~3..HEAD 2>/dev/null || git diff --stat
```

Look for:
- Debugging approaches that found the root cause quickly
- Architecture decisions that avoided problems
- Workflow sequences that were efficient
- Testing strategies that caught bugs
- Code patterns that the user confirmed or praised
- Mistakes that were corrected (negative patterns to avoid)

## Step 2: Extract Patterns

For each pattern identified, define it as a YAML structure:

```yaml
name: descriptive-kebab-case
domain: testing|architecture|debugging|workflow|security|performance
confidence: 0.6
trigger: "when [specific condition]"
action: "then [specific behavior]"
reasoning: "because [why this works, what went wrong without it]"
learned_from: "[project name] — [brief context]"
date: YYYY-MM-DD
```

Present each pattern to the user for confirmation before saving. The user may refine, reject, or approve each one.

## Step 3: Check for Duplicates

Read `~/.claude/patterns/INDEX.md`. For each new pattern:
- If a similar pattern already exists: bump its confidence by 0.1 (max 1.0), update the YAML file, and update the INDEX.md row
- If truly new: create `~/.claude/patterns/[domain]-[name].yaml` and add a new row to INDEX.md

## Step 4: Save Pattern Files

For each approved pattern, write a YAML file:

```bash
# Example: ~/.claude/patterns/debugging-check-rls-before-api.yaml
```

Update `~/.claude/patterns/INDEX.md` with the new or updated entry:

```
| pattern-name | domain | 0.6 | domain-pattern-name.yaml | 2026-03-26 |
```

## Step 5: Auto-Push to GitHub

After saving all patterns, sync the dotfiles repo:

```bash
cd ~/dotfiles/claude && git add -A && git commit -m "learn: [summary of patterns] ([domain], confidence [score])" && git push
```

This is an auto-push to the dotfiles repo — no user approval needed (per global CLAUDE.md push rules).

## Step 6: Report

Tell the user:
- How many patterns were saved (new vs reinforced)
- Current pattern count and average confidence
- Remind them patterns auto-sync across devices
