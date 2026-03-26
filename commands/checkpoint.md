# /user:checkpoint — Named Git Snapshot

Create a named checkpoint (git tag) to mark a known-good state. Useful before risky changes, integration work, or major refactors.

## Usage

`/user:checkpoint [name]` — name is required via $ARGUMENTS

## Step 1: Validate

If no name provided via $ARGUMENTS, ask the user: "What should this checkpoint be called? (e.g., pre-apollo-integration, working-email-system)"

## Step 2: Check State

```bash
git status --short
git log --oneline -3
```

If there are uncommitted changes, warn the user:
"You have uncommitted changes. Checkpoint will tag the last commit, not your working tree. Want to commit first?"

If user wants to commit first, help them commit (following the no-push-without-approval rule for project repos).

## Step 3: Create Tag

```bash
git tag "checkpoint/YYYY-MM-DD-[name]" -m "Checkpoint: [name] — [current branch], [commit count] commits"
```

## Step 4: Report

Show:
- Tag name: `checkpoint/YYYY-MM-DD-[name]`
- Tagged commit: `[hash] [message]`
- Branch: `[current branch]`
- How to restore: `git checkout checkpoint/YYYY-MM-DD-[name]`
- How to list checkpoints: `git tag -l "checkpoint/*"`
- How to delete: `git tag -d checkpoint/YYYY-MM-DD-[name]`
