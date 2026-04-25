---
description: Fire-and-forget long-running code review. /afk [hours] (default 3, 0=infinite). Single-agent Opus 4.7 medium effort. Walk away, come back to a useful report.
argument-hint: "[hours] [--force|--takeover]"
---

# AFK — Unattended Code Review Session

You are running the `/afk` command. The user invoked this because they are **leaving their computer**. They will not answer questions. Every default is baked in below.

**Model: Opus 4.7, medium effort. Single-agent. NO sub-agent fanout. NO calls to other review skills.**

Arguments: `$ARGUMENTS`

---

## HARD RULES — read these first, never violate

1. **No follow-up questions.** Never use `AskUserQuestion`. Every decision below is final.
2. **No commits, no pushes.** Read-only git. Auto-fixes are written to disk and left uncommitted for the user to review.
3. **Runtime requirement (state this in the status line):** Claude Code must remain open for the session to keep ticking. `ScheduleWakeup` only fires while the harness is alive. Closing Claude Code ends the session.
4. **Single-agent.** Do not spawn sub-agents. Do not invoke `/master-review`, `/codex-review`, `/local-review`, `/ultrareview`, or any other review skill. The whole point is *cheap-per-hour*.
5. **Conservative fix gate** (see below). If in doubt: write to `findings.md`, don't touch the code.
6. **Never self-terminate on empty queue.** Refill (with dedup that uses `refill_generation`) and keep going. Empty queue means "haven't looked hard enough yet," not "done."
7. **Stop conditions** (the *only* ways the session ends):
   - Finite mode: `now >= deadline_at`
   - Sentinel: `<session_dir>/STOP` exists
   - Three consecutive tick errors (`errors_streak >= 3`)
8. **All file paths are absolute.** Resolve `<git_root>/tmp/afk/...` once at bootstrap; do not rely on cwd in later ticks.

---

## Step 1 — Parse arguments

Tokens in `$ARGUMENTS` (whitespace-separated):
- First non-flag token: `raw_hours` (default `"3"` if absent).
- Flags: `--force` (bypass concurrency guard), `--takeover` (STOP existing active session and start fresh).

```
mode = "infinite" if raw_hours == "0" else "finite"   # raw STRING equality
hours = float(raw_hours)                               # accepts "3", "0.05", "5.5"
```

The `"0"` sentinel must be checked by raw-string equality, *before* float parsing, to avoid float-zero ambiguity.

---

## Step 2 — Resolve paths

```
git_root = `git rev-parse --show-toplevel` (fallback: $HOME/.claude)
base_dir = <git_root>/tmp/afk            (fallback: $HOME/.claude/afk)
session_id = current ISO-8601 timestamp, colons replaced with hyphens
session_dir = <base_dir>/<session_id>-session
```

Use the Bash tool to run `mkdir -p <session_dir>`.

---

## Step 3 — Concurrency guard

For each existing `<base_dir>/*-session/state.json`:
- If its `deadline_at > now` AND no `STOP` file in that session dir, it is **active**.

If any active session exists:
- `--takeover` provided → `touch <other_session>/STOP`, continue.
- `--force` provided → log warning, continue (DO NOT touch the other STOP).
- Neither → print:
  ```
  Active /afk session exists at <path>.
    --force      run a parallel session anyway
    --takeover   stop the existing session and start fresh
  ```
  EXIT.

---

## Step 4 — Detect default branch

Order (first that succeeds):
1. `git symbolic-ref refs/remotes/origin/HEAD --short` → strip `origin/`
2. `git rev-parse --verify main` → `main`
3. `git rev-parse --verify master` → `master`
4. `git rev-parse --verify develop` → `develop`
5. None → `null` (skip diff-based tasks)

Store in `state.default_branch`.

---

## Step 5 — Survey the repo (one-time)

Run these **exact** commands. Do not "fix" the regex.

```bash
# Diff vs default branch
if default_branch is non-null:
  git diff <default_branch>...HEAD --shortstat

# TODOs — extended regex, alternation with |, pinned excludes
grep -RInE "TODO|FIXME|XXX" \
  --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=tmp \
  --exclude-dir=vendor --exclude-dir=dist --exclude-dir=build .

# Markdown files
find . -name "*.md" -not -path "*/node_modules/*" -not -path "*/tmp/*"

# Recent commits (context only)
git log --oneline -20
```

**Modules** = top-level subdirs of `src/`, `packages/`, `apps/`, `lib/`, `internal/` that exist. If none exist, modules = `["."]`.

**Dependency manifests** = presence of any: `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `requirements.txt`.

---

## Step 6 — Build the task plan

### Complexity weights (USE THIS TABLE — DO NOT THINK)

These are **complexity weights for packing/ordering**, NOT wall-clock minutes. Wall-clock duration is enforced by `deadline_at` + queue refill.

```
TASK_COMPLEXITY_WEIGHTS:
  diff_review (≤200 LOC):                      15
  diff_review (200–1000 LOC):                  45
  diff_review (>1000 LOC):                     90
  full_file_deep_review (file <500 LOC):       20
  full_file_deep_review (file 500–2000 LOC):   45
  architectural_drift_scan (whole repo):       60
  todo_triage:                                 30
  test_gap_audit (per module):                 25
  doc_drift_check (per .md file):               5
  dependency_audit:                            20
  bug_hunt (per module):                       40
  dead_code_hunt (per module):                 25
  naming_audit (per module):                   20
```

**Fallback rule:** for any task not listed, pick the closest analogous entry above and use that weight. Do NOT estimate from scratch. Between two plausible matches, pick the LARGER one.

### Packing

```
budget = hours * 60          (finite mode)
budget = 360                 (infinite mode — pre-pack ~6h-equivalent, refill as consumed)

Greedy-fill tasks_pending up to budget, diversifying across kinds.
Compute hash for each task (see hashing rule).
```

### Hashing rule (used everywhere)

```
hash(task) = sha1(
  task.kind + "|" +
  task.target + "|" +
  state.refill_generation + "|" +
  (head_sha if task.kind == "diff_review" else "")
)
```

Diff tasks tie to HEAD so they re-fire when commits land. Non-diff tasks tie to `refill_generation` so they re-fire after a refill cycle.

---

## Step 7 — Write initial files

Create (all under `<session_dir>/`):

**`state.json`:**
```json
{
  "session_id": "<id>",
  "started_at": "<iso>",
  "deadline_at": "<iso or null>",
  "mode": "finite|infinite",
  "git_root": "<abs>",
  "default_branch": "<branch or null>",
  "last_tick_at": null,
  "tick_count": 0,
  "errors_streak": 0,
  "refill_generation": 0,
  "module_rotation_offset": 0,
  "tasks_done": [],
  "tasks_pending": [ /* packed list */ ],
  "tasks_done_hashes": [],
  "fixes_applied_count": 0,
  "findings_count": 0,
  "last_survey_at": "<iso>"
}
```

**`plan.md`:** human-readable summary — session metadata, packed task list with weights and targets, the runtime warning.

**`findings.md`:** header `# /afk findings — <session_id>` then a blank line.

**`fixes.md`:** header `# /afk auto-fixes — <session_id>` then a blank line. Every entry must include `file:line`, the rationale, and explicit gate-clauses-satisfied proof.

**`errors.md`:** header `# /afk errors — <session_id>` then a blank line.

---

## Step 8 — Print the status line (single block, last user-facing output)

Print **only** this block, then schedule the first tick. Do not print anything else after this.

```
/afk session started: <session_id>
  Mode:         <finite Nh | infinite>
  Output:       <session_dir>
  Findings:     <session_dir>/findings.md
  Fixes:        <session_dir>/fixes.md  (auto-fixes only — uncommitted)

  To stop:      touch <session_dir>/STOP

  REQUIREMENT:  Keep Claude Code open. Closing it ends the session.
                ScheduleWakeup only fires while the harness is alive.

  First tick in 60s. Subsequent ticks every ~240s.
```

---

## Step 9 — Schedule the first tick

Call `ScheduleWakeup` directly (no `/loop` indirection):
- `delaySeconds`: 60
- `prompt`: the full **AFK_TICK_PROMPT** below, with `<session_dir>` substituted with the absolute path.
- `reason`: `"afk session <session_id> first tick"`

Then **return immediately**. Do nothing else in this turn.

---

## AFK_TICK_PROMPT (the per-tick body — must be cold-start safe)

The `prompt` field passed to `ScheduleWakeup` should be exactly the following template, with `<SESSION_DIR>` replaced by the absolute session directory path:

```
You are running an AFK code-review tick for session <SESSION_DIR>.

You have NO conversation memory from prior ticks. Treat this as a cold start.
Read all state from <SESSION_DIR>/state.json.

HARD RULES (re-stated each tick — never violate):
- No follow-up questions to the user.
- No commits, no pushes.
- Single-agent. Do NOT spawn sub-agents. Do NOT invoke other review skills.
- Conservative fix gate (see below). When in doubt, write a finding instead.
- Model: Opus 4.7, medium effort.

PROCEDURE:

1. Read <SESSION_DIR>/state.json. Call it `state`.

2. Stop conditions (in order — first match wins):
   a. state.mode == "finite" AND now >= state.deadline_at
   b. <SESSION_DIR>/STOP exists
   c. state.errors_streak >= 3
   If any: write <SESSION_DIR>/summary.md (rollup of tick_count,
   findings_count, fixes_applied_count, top 10 findings, reason for stop)
   and RETURN WITHOUT calling ScheduleWakeup. Session ends here.

3. Throttle (cost guard, especially for infinite mode):
   If state.last_tick_at is set AND (now - state.last_tick_at) < 60s:
     ScheduleWakeup(
       delaySeconds = max(60, 240 - (now - state.last_tick_at)),
       prompt = THIS SAME PROMPT,
       reason = "afk throttle"
     )
     RETURN.

4. Refill if queue empty:
   If state.tasks_pending is empty:
     state.refill_generation += 1                       # bumped EXACTLY ONCE per refill
     Re-run the survey (same commands as bootstrap).
     Compute hashes with the new refill_generation.
     new = [t for t in survey_tasks if t.hash not in state.tasks_done_hashes]
     If new is empty:
       new = generate_alt_tasks(state)                  # does NOT bump again
     state.tasks_pending = greedy-pack(new, weights, budget=120)
     state.last_survey_at = now

5. Pop the first task from state.tasks_pending.

6. Execute the task wrapped in try/except:

   Read context: tail of <SESSION_DIR>/findings.md (last 200 lines).
   If the file is shorter than 200 lines, read the whole file.

   Dispatch by task.kind to one of these per-kind instructions:

   - diff_review(target):
       "Review the diff at <target>. Identify bugs, regressions, missed
        edge cases, poor naming, dead code introduced. For each, cite
        file:line. Do NOT summarize what changed — only flag problems
        and improvements."

   - todo_triage(target=repo):
       "For each TODO/FIXME/XXX, classify as still-valid /
        already-resolved / load-bearing-keep. Cite file:line.
        Recommend action."

   - doc_drift_check(target=path/to/file.md):
       "Read <target> and verify every code claim still matches the
        codebase. Cite file:line for any drift. Suggest corrected wording."

   - test_gap_audit(target=module):
       "List untested public functions in <target>. Rank by risk
        (complexity × blast radius). Recommend the top 3 worth testing.
        Do NOT write tests."

   - bug_hunt(target=module):
       "Read <target> adversarially. Hypothesize plausible bugs
        (off-by-one, race, null deref, unhandled error, auth gap).
        Cite file:line. Mark confidence (low/med/high)."

   - dead_code_hunt(target=module):
       "Find unreferenced exports/functions/variables in <target>.
        Verify non-reference via repo-wide grep. List with file:line.
        Mark which qualify for the auto-fix gate."

   - naming_audit(target=module):
       "Find inconsistent or misleading names in <target>. Cite
        file:line. Recommend renames."

   - architectural_drift_scan(target=.):
       "Identify structural rot: files past their purpose, inconsistent
        sibling patterns, missing abstractions, layering violations.
        Cite file:line. Keep findings concrete."

   - dependency_audit(target=.):
       "List declared deps not imported, imported deps not declared,
        deps significantly behind latest. Read manifest + lockfile only.
        Do NOT make network calls."

   - full_file_deep_review(target=path):
       "Read <target> top-to-bottom. Flag bugs, dead code, unclear names,
        missing error handling, suspect logic. Cite file:line."

   Output schema (uniform): a markdown section beginning with
     ## <kind>: <target>
   followed by bulleted findings each citing file:line, optionally
   followed by a `### Proposed fix` block per finding.

7. For each Proposed fix from step 6, evaluate the FIX GATE.
   The fix is allowed iff ALL of these are true:
     (1) Local change (one function/block).
     (2) No externally observable behavior change (return values, side
         effects, error types, timing, async semantics).
     (3) Change is one of:
           - Dead code removal (verified unreferenced via repo-wide grep)
           - Typo in comments only
           - Typo in a user-facing string that is NOT used as a key/identifier
           - Pure formatting/whitespace
           - Removal of a provably-redundant operation
             (duplicate import, duplicate assignment to same value)
     (4) No need to run tests, type-checker, or build to be sure.
     (5) You can articulate in one sentence why the program is IDENTICAL
         except for the named improvement.
     (6) File is NOT in: generated/, dist/, build/, vendor/, node_modules/,
         any *.lock or *.lockfile, anything matching .gitignore.
         Verify gitignore membership with `git check-ignore -q <file>`
         (exit 0 = ignored = SKIP the fix). Path-prefix checks for
         the directory exclusions are sufficient (no shell needed).
   NEVER auto-fix: logic, control flow, error handling, async code,
   constants in conditionals (reachability is unprovable without execution).

   If gate passes: apply the fix with Edit. Append to <SESSION_DIR>/fixes.md:
     ### <iso>: <file>:<line>
     **Rationale:** <one sentence>
     **Gate proof:** clauses (1)–(6) all satisfied because <one sentence>.
     **Diff:** <before> → <after>
   Increment state.fixes_applied_count.

   If gate fails: append the proposed fix as a finding in findings.md
   with the gate-failure reason. Do NOT modify any code.

8. Append the task's findings section to <SESSION_DIR>/findings.md.
   Increment state.findings_count by the count of bullet findings.
   Reset state.errors_streak = 0.

9. On any exception during steps 5–8:
   Append to <SESSION_DIR>/errors.md:
     ### <iso>: task=<kind>(<target>)
     <error message + brief context>
   Increment state.errors_streak.
   The errored task IS still moved to tasks_done (step 10) so it does not
   retry forever. This is intentional — broken tasks shouldn't churn.
   Do NOT crash the tick — proceed to step 10.

10. Update state:
    state.tasks_done.append(task)
    state.tasks_done_hashes.append(task.hash)
    state.tick_count += 1
    state.last_tick_at = now
    Write state.json atomically: write to <SESSION_DIR>/state.json.tmp,
    fsync if available, then `mv` over <SESSION_DIR>/state.json.
    This prevents corruption if the tick is interrupted mid-write.

11. Re-check stop conditions (deadline may have passed mid-task):
    If any stop condition is true, write summary.md and RETURN
    without rescheduling.

12. ScheduleWakeup(
      delaySeconds = 240,
      prompt = THIS SAME PROMPT,
      reason = "afk tick <state.tick_count>"
    )
    RETURN.

generate_alt_tasks(state):
  # Caller (step 4) has ALREADY bumped state.refill_generation. Do NOT bump again.
  modules = list_modules(state.git_root)   (same heuristic as survey)
  if not modules: modules = ["."]
  kinds_cycle = ["bug_hunt", "dead_code_hunt", "naming_audit",
                 "test_gap_audit", "architectural_drift_scan"]
  offset = state.module_rotation_offset
  new_tasks = []
  for i, kind in enumerate(kinds_cycle):
    m = modules[(offset + i) % len(modules)]
    target = m if kind != "architectural_drift_scan" else "."
    new_tasks.append({
      kind: kind,
      target: target,
      # weight is the value for this kind from the TASK_COMPLEXITY_WEIGHTS
      # table above (e.g. bug_hunt=40, dead_code_hunt=25, naming_audit=20,
      # test_gap_audit=25, architectural_drift_scan=60).
      weight: <look up in TASK_COMPLEXITY_WEIGHTS>,
      hash: sha1(kind + "|" + target + "|" + state.refill_generation + "|" + "")
    })
  state.module_rotation_offset = (offset + len(kinds_cycle)) % max(1, len(modules))
  return new_tasks
```

---

## Final reminders to the agent running `/afk` at bootstrap

- Resolve **all paths to absolutes** before scheduling the tick.
- The `prompt` argument to `ScheduleWakeup` is the AFK_TICK_PROMPT above with `<SESSION_DIR>` substituted to the actual absolute path. The tick prompt re-schedules itself.
- After scheduling the first tick, your bootstrap turn is **done**. Do not loop, do not poll, do not narrate further.
- The user has walked away. They will return to find the report.
