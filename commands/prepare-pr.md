---
description: Commits changes grouped by done-plans, rebases main, builds the project, then creates or updates a PR. Replaces the commit command. Use when you're ready to open or update a pull request.
argument-hint: "[optional: PR title or description]"
---

# Prepare PR Agent

Commit, rebase, build, and open/update a pull request — all in one step.

## Step 1: Commit Changes Grouped by Done-Plans

### Gather info

1. List all done plans: `ls ./tmp/done-plans/`
2. Read each done-plan to understand what files and features it covers.
3. Run `git diff` and `git diff --cached` to see all staged and unstaged changes.

### Associate changes with plans

For each changed file:
1. Read the diff to understand what changed.
2. Match to a done-plan by topic, referenced files, or feature area.
3. Group into logical commit units — one commit per plan.

**Grouping rules**:
- Files related to the same done-plan go in one commit.
- Infrastructure/config supporting a plan goes with that plan's commit.
- `./tmp/` doc changes associated with a plan go in that plan's commit.
- Unrelated changes (no matching plan) get their own commit with a descriptive message.

### Create commits

For each group:
1. `git add <specific files>` — **never** `git add .` or `git add -A`
2. Review staged diff for secrets or credentials — warn the user if found.
3. Commit with message: `type: short description` (feat, fix, refactor, docs, chore). Under 72 chars. Imperative mood.

**Conventions**: Reference the plan name in the commit body if helpful. Keep subjects concise.

## Step 2: Rebase the Base Branch onto Current Branch

Detect the project's base branch first — do not assume `main`. Check
`origin/main`, `origin/master`, `origin/develop`, `origin/trunk` in that order
and use the first one that exists.

```bash
BASE_BRANCH=""
# Try origin/HEAD first — this is the actual remote default branch (works for `release`, `production`, etc.).
if git symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1; then
  BASE_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
fi
# Fall back to common conventional names if origin/HEAD is unset.
if [ -z "$BASE_BRANCH" ]; then
  for cand in origin/main origin/master origin/develop origin/trunk origin/release origin/production main master develop trunk; do
    if git rev-parse --verify "$cand" >/dev/null 2>&1; then BASE_BRANCH="$cand"; break; fi
  done
fi
[ -z "$BASE_BRANCH" ] && echo "No base branch found — abort. Set origin/HEAD with: git remote set-head origin --auto" && exit 1
```

1. Fetch latest base — only when an `origin` remote exists AND the detected base actually came from `origin/` (local-only repos and repos with a non-`origin` remote name should skip the fetch entirely instead of hitting an unconditional `git fetch origin` that errors out):

   ```bash
   if git remote get-url origin >/dev/null 2>&1 && [[ "$BASE_BRANCH" == origin/* ]]; then
     git fetch origin "${BASE_BRANCH#origin/}"
   fi
   ```
2. Rebase: `git rebase "$BASE_BRANCH"`
3. If conflicts occur:
   - Read the conflicting files and the incoming vs current changes.
   - If the resolution is **obvious** (e.g., non-overlapping additions, trivial formatting), resolve it yourself, `git add` the resolved files, and `git rebase --continue`.
   - If the resolution is **ambiguous** (e.g., both sides changed the same logic, semantic conflicts), show the user the conflict with context and ask them how to resolve it. Wait for their response before continuing.
4. After rebase completes, verify with `git log --oneline -10` that history looks correct.

## Step 2.5: Generate Production Migration SQL (If Schema Changed)

Check if a schema file was modified in any commit on this branch vs the detected `$BASE_BRANCH` from Step 2.
Discover the schema source-of-truth from the project (common patterns:
`schema.ts`, `schema.prisma`, `migrations/`, `db/schema/`, `models.py`, etc.):

```bash
git diff "$BASE_BRANCH"...HEAD --name-only | grep -E 'schema\.(ts|prisma|sql|py|rb|kt|swift)$|models?/.*\.(py|rb)$|migrations/|db/schema/|alembic/versions/'
```

If a schema file was changed: **HALT** the workflow here. Do not proceed to Step 3 or beyond until the user has provided the actual generated SQL.

1. **Tell the user to run** the project's prod schema-diff command (e.g.
   `npm run db:diff:prod`, `npx prisma migrate diff --to-schema-datamodel`,
   `alembic upgrade --sql head`, etc. — discover from package manifest or
   project scripts) and capture the actual output SQL. **Do not run prod
   schema-diff commands automatically** — they may hit a production database.
2. Wrap the captured SQL in a transaction block (`BEGIN; ... COMMIT;`).
3. Include the **actual SQL** in the PR description under the **Schema Changes**
   section — not instructions to run a command.
4. Only include additive SQL (CREATE, ADD). If destructive SQL (DROP, ALTER
   type) appears, flag it for the user to review and confirm.

If no schema file was changed, omit the **Schema Changes** section from the PR
template entirely.

## Step 3: Build and Fix Errors

Run all builds and fix any errors.

### Detect build commands

Inspect `package.json` (and any monorepo config such as `nx.json`, `turbo.json`, or `pnpm-workspace.yaml`) at the project root to determine the correct build commands. Common patterns:
- Single-package project: `npm run build` / `bun run build` / `yarn build`
- Nx monorepo: `npx nx run-many -t build` or `npx nx build <project-name>`
- Turborepo: `npx turbo build`
- Multiple apps: run the build for each app (frontend, API, etc.) separately
- Non-JS projects: discover via `Makefile`, `Cargo.toml`, `pyproject.toml`, `go.mod`, etc.

Run each applicable build command, for example:

```bash
# Example — replace with the actual commands detected from the project
npm run build        # or the project's equivalent
```

For each build:
1. If it **passes**, move on.
2. If it **fails**, read the error output carefully:
   - Fix type errors, missing imports, and build issues.
   - After fixing, re-run the failing build to confirm the fix.
   - Repeat until all builds pass.
3. If a fix requires non-trivial changes (architectural issues, missing dependencies), tell the user and ask how to proceed.

**Commit build fixes** as a separate commit: `fix: resolve build errors`

## Step 4: Codex Review Loop (If Codex Available) — runs BEFORE push

If Codex is available in this session (`command -v codex` succeeds), run the
review loop here, **before pushing or opening any PR**. The whole point of this
gate is that nothing reaches the remote until Codex has signed off. If Codex is
unavailable, skip this step and continue to Step 5.

### Review loop

1. Launch a **Bash subagent** (via the Agent tool) and recompute the base branch inside it (the parent shell's `BASE_BRANCH` does not propagate to a fresh subagent shell). The subagent should run:

```bash
WORKDIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
BASE_BRANCH=""
if git symbolic-ref --quiet refs/remotes/origin/HEAD >/dev/null 2>&1; then
  BASE_BRANCH=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
fi
if [ -z "$BASE_BRANCH" ]; then
  for cand in origin/main origin/master origin/develop origin/trunk origin/release origin/production main master develop trunk; do
    if git rev-parse --verify "$cand" >/dev/null 2>&1; then BASE_BRANCH="$cand"; break; fi
  done
fi
# Build the review prompt into a temp file (never inline it as a double-quoted arg — a branch name or
# diff excerpt can carry shell metacharacters), then run it through the house wrapper. codex-exec.sh
# feeds stdin from the file, inherits the config's authoritative effort (unpinned = newest-model
# default), and writes a machine-readable `.status` sidecar; read BOTH the output and the status.
PROMPT=$(mktemp "${TMPDIR:-/tmp}/prepare-pr-codex-prompt.XXXXXX")
OUT=$(mktemp "${TMPDIR:-/tmp}/prepare-pr-codex-out.XXXXXX")
printf '%s\n' "Review the diff between $BASE_BRANCH and HEAD. Look for bugs, logic errors, security issues, missing validation, and architectural problems. List each finding on its own line with CRITICAL/IMPORTANT/MINOR severity and a category tag (BUG/LOGIC/ARCHITECTURE/SECURITY/PERFORMANCE/MISSING/ASSUMPTION/CONTRADICTION/FRAGILITY)." > "$PROMPT"
bash "$HOME/.claude-dotfiles/scripts/codex-exec.sh" "$PROMPT" "$OUT" "$WORKDIR"
cat "$OUT.status"; echo "--- review ---"; cat "$OUT"
```
   Wait for the full output. `"$OUT.status"` is `ok | timeout | unavailable | nonzero-<rc>`; a
   `timeout`/`unavailable` status means Codex could not run — treat it as "Codex unavailable" and skip
   the gate per the Step-4 preamble rather than looping on an empty review.
2. Read the response carefully.
3. **If codex reports issues**:
   - Fix every issue it raised in the codebase.
   - Commit the fixes locally: `fix: address codex review feedback` (no push yet — the gate is still open).
   - Go back to step 1 — re-launch the Bash subagent with the same `WORKDIR`/`BASE_BRANCH` recomputation block so the fresh shell does not inherit stale or empty `$BASE_BRANCH` from the parent. Do not call `codex-exec.sh` directly without first recomputing both vars.
4. **If codex reports no issues** (e.g., "no defects", "no issues", "changes appear consistent"), the loop is done. Continue to Step 5.

**Important**: Do not summarize or skip the codex output. Read it in full each iteration so you can act on every finding. The review gate stays in effect — code does not reach the remote until this loop finishes clean.

## Step 5: Push to Remote (REQUIRES USER APPROVAL — must run before Step 6 PR creation)

`gh pr create` requires the head branch to exist on the remote, so push first.
Per the global push policy in `~/.claude/CLAUDE.md`: **NEVER push to GitHub
without explicit user approval** for non-dotfiles repos.

### Step 5.0: Fetch + divergence check (never overwrite another agent's work)

**Before showing anything or pushing**, fetch the remote and confirm the local branch has NOT diverged unexpectedly from its upstream. Another agent or teammate may have pushed to the same branch while we worked; force-pushing over them would destroy their commits. This is the machine half of "never overwrite another agent's work."

```bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
# Fetch the base branch (from Step 2's $BASE_BRANCH) AND our own branch, when an origin remote exists.
if git remote get-url origin >/dev/null 2>&1; then
  [[ "$BASE_BRANCH" == origin/* ]] && git fetch origin "${BASE_BRANCH#origin/}"
  git fetch origin "$BRANCH" 2>/dev/null || true
fi
# Compare local HEAD against its upstream — @{u} if tracking is configured, ELSE the explicit
# origin/<branch> we just fetched. The explicit fallback matters: a branch can lack upstream
# tracking config while origin/<branch> still exists with commits (codex-review 2026-07-12) — an
# @{u}-only check would silently skip and let the force-with-lease below overwrite them.
CMP=""
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  CMP='@{u}'
elif git rev-parse --verify "origin/$BRANCH" >/dev/null 2>&1; then
  CMP="origin/$BRANCH"
fi
if [ -n "$CMP" ]; then
  AHEAD=$(git rev-list --count "$CMP..HEAD" 2>/dev/null || echo 0)
  BEHIND=$(git rev-list --count "HEAD..$CMP" 2>/dev/null || echo 0)
  echo "branch $BRANCH: ahead $AHEAD / behind $BEHIND vs $CMP"
else
  echo "branch $BRANCH: no upstream and no origin/$BRANCH — first push of a new branch (nothing to diverge from)"
fi
```

- **`behind == 0`, or genuinely no remote ref exists** (`$CMP` empty — first push of a brand-new branch): proceed to the push-approval flow below.
- **`behind > 0`** (the remote ref `$CMP` has commits the local branch does not — unexpected divergence): **STOP. Do NOT push, and NEVER `--force` / `--force-with-lease` over them** — that would overwrite another agent's or teammate's work. Surface the divergence to the user: show `git log HEAD..$CMP --oneline` (what the remote has that you don't) and `git log $CMP..HEAD --oneline` (what you have that the remote doesn't), and ask how to proceed (rebase onto the new upstream commits, or abort). Only continue once the divergence is resolved and `behind == 0`.

1. Show pending commits: `git log @{u}..HEAD --oneline 2>/dev/null` (or `git log "$BASE_BRANCH"..HEAD --oneline` if no upstream is set) — including any `fix: address codex review feedback` commits added in Step 4.
2. Show the branch and remote: `git rev-parse --abbrev-ref HEAD` and `git remote get-url origin`
3. **Ask the user**: "Push <branch> to <remote-url>? This is a force-with-lease push since we rebased — type 'yes' to push or 'no' to stop here."
4. Only after the user confirms: `git push -u origin <branch> --force-with-lease`
   - Use `--force-with-lease` since we rebased (safer than `--force`).
5. If `--force-with-lease` fails (remote has new commits not in local), tell the user and ask how to proceed.

## Step 6: Create or Update Pull Request

1. Check for existing PR: `gh pr view --json number,title,body,url,state 2>/dev/null`

### If no PR exists — create one

```bash
gh pr create --title "<title>" --body "$(cat <<'EOF'
<body>
EOF
)"
```

### If PR already exists — update it

```bash
gh pr edit --title "<title>" --body "$(cat <<'EOF'
<body>
EOF
)"
```

### PR Description Template

Build the PR description from the done-plans. List work in **chronological order** based on plan dates (the `YYYY-MM-DD` prefix in filenames). When updating an existing PR, **append** new work to the existing description — never overwrite previous entries.

```markdown
## Summary
[1-3 sentence overview derived from done-plans and any briefs/intent artifacts]

## Work Completed
### 1. [Plan/Feature Name from earliest done-plan]
- Key changes and what they accomplish

### 2. [Plan/Feature Name from next done-plan]
- Key changes and what they accomplish

### 3. [Plan/Feature Name from latest done-plan]
- Key changes and what they accomplish

## Pre-Merge Testing
- [ ] [Short, specific thing to test based on the changes — e.g., "Verify new endpoint returns 200 with valid payload"]
- [ ] [Another key behavior to verify]
- [ ] [Edge case or integration point worth checking]

## Schema Changes
<!-- Only include this section if a schema file was modified -->
- [ ] Migration SQL reviewed
- [ ] Migration applied to staging
- [ ] Migration applied to production

### Production Migration SQL
⚠️ Run this SQL against the production database BEFORE deploying:
```sql
BEGIN;
-- actual generated SQL from the project's prod schema-diff command
COMMIT;
```

## Build Verification
- [x] All project builds pass (commands detected from project config)
```

Use `$ARGUMENTS` as the PR title if provided, otherwise derive one from the done-plans.

## Step 7: Summary

Present the final result:

```
PR ready.

Commits:
- <commit summaries>

Build:
  <app/target name>: PASS
  <app/target name>: PASS

Codex Review: PASS (no issues) | SKIPPED (codex unavailable)

PR: <url>
Branch: <branch name> (rebased on main)

Done-plans included:
- <list of plan files>
```
