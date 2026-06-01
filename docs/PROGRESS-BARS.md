# Statusline Line 2 — Progress Bar

A single progress bar on line 2 of the Claude Code statusline, driven by a small per-session state machine. It shows an elapsed timer + one bar while a prompt runs, and a human label (or `idle`) between prompts. **Line 2 is always present and never flickers** — there is no mid-task vanish and no flip between "versions."

## What it looks like

```
ctx 42%  3h 11m left  87% sess  37% wk  Opus 4.8  wk→6th 4pm  my-repo   ← line 1
31:46  ▰▰▰▱▱▱▱▱  chunk 1b: email transport + routes                      ← line 2 (active)
```

| Element | Meaning |
|---|---|
| `31:46` | Elapsed time since the prompt started (mm:ss) |
| `▰▰▰▱▱▱▱▱` | The single bar — see source priority below |
| `chunk 1b: …` | Label: the current in-progress to-do's `activeForm`, or a beacon label |

**Bar source — chosen by specificity (most specific real signal wins):**
1. **Determinate beacon** — a command that publishes real inner-step progress (e.g. `/god-review` via `emit-beacon.sh`) → `step/total`.
2. **Determinate to-dos** — from TodoWrite (`done/total`).
3. **Spinner** — no determinate beacon or to-do list → honest animated `▰▱` window, *not* a fake percentage.

**Label source — DECOUPLED from the bar; shows what it's doing *right now* (most current wins):**
1. **Beacon label** — the explicit command phase, when a beacon is active.
2. **Live tool activity** — the last tool action (`Edit migration.sql`, `Bash: run tests`, `Read foo.ts`,
   `Grep "sendEmail"`, `Task: codebase-explorer`), written by `on-tool-activity.sh` to a per-session sidecar.
   This is the always-populated signal that makes line 2 useful even when no to-do list exists.
3. **To-do `activeForm`** — the current step, when a determinate to-do list exists but no fresher activity.
4. **`working`** — nothing else available.

**States:**
- **Active**: timer + bar (green).
- **Stalled** (no tool call for 30s): bar dims to **yellow** — Claude is thinking, not calling tools.
- **Idle** (between prompts / at session open): the per-session label (`Internal › repo › what's happening`), else the literal `idle`.
- **Never blank**: a hard bash fallback prints `idle` even if the renderer crashes or no state file exists. Line 2 is present in every session, every repo, from the moment it opens.
- **Stale-active demote**: if a prompt somehow runs >30 min with no tick (a misfired Stop hook), the bar demotes to the idle line rather than showing a runaway timer.

## How it works

Line 2's renderer (`scripts/statusline.sh`) reads `~/.claude/progress/<session_id>.json` and `~/.claude/session-status/<session_id>.txt`. The state file is maintained by four hook scripts in `scripts/progress/`:

| Hook | Event | What it does |
|---|---|---|
| `on-prompt-submit.sh` | `UserPromptSubmit` | Creates the state file as `{active:true, prompt_started_at, last_tick, overall:indeterminate}`. Starts the timer. |
| `on-todo-write.sh` | `PostToolUse[TodoWrite]` | Reads the todos array, computes `done/total`, sets `overall` + `active:true` + `last_tick`. |
| `on-task-spawn.sh` | `PostToolUse[Task]` | Bumps `last_tick`. Atomically claims any beacon scratch file and writes `current` with `source:"beacon"`. No beacon → just the tick. |
| `on-stop.sh` | `Stop` | Marks the session **idle** (`active:false`, drops `prompt_started_at`/`current`/`overall`) — does **not** delete the file, so line 2 falls cleanly to the idle label with no flicker. |

`on-session-start-cleanup.sh` (`SessionStart`) GCs state files older than 7 days; it is not part of the render path.

All hooks `exit 0` always. Failures degrade silently; Claude Code's main flow is never blocked.

## Universality — it works for every command

Nothing per-command is required:

- **The bar fills from the to-do list** Claude already maintains for any non-trivial task — no extra bookkeeping, no UI babysitting.
- **One-shot tasks** (no to-do list) show an honest spinner — there's no sub-structure to measure, so the bar doesn't pretend to have one.
- **Commands that publish beacons** (`/god-review`, etc.) get real inner-step progress for free.

## Optional: fine-grained beacons

For commands with discrete phases (loading → analyzing → reviewing → reporting), emit a beacon at each phase boundary so the bar reflects the actual phase.

**Bash-fenced commands** — call the helper:

```bash
bash $HOME/.claude-dotfiles/scripts/progress/emit-beacon.sh 3 5 "reviewing"
```

The helper auto-discovers the session_id from the project's transcript dir. For sub-agents whose pwd may differ, pass `SESSION_ID=...` explicitly:

```bash
SESSION_ID="$MY_SID" bash $HOME/.claude-dotfiles/scripts/progress/emit-beacon.sh 3 5 "reviewing"
```

**LLM-orchestrated commands** — use the Write tool directly:

```
Write ~/.claude/progress/<session_id>.current.json with content:
{"step": 3, "total": 5, "label": "reviewing"}
```

The beacon scratch file is consumed (deleted) on the next Task tool call and merged into `current`. A determinate beacon outranks the to-do bar; an indeterminate one (no `total`) does not.

> **Deprecated:** the old `expected_subagents:` command-frontmatter hint and the Task-spawn-**count** bar are gone. `on-task-spawn.sh` no longer reads frontmatter or counts spawns for display. Any leftover `expected_subagents:` keys in command frontmatter are inert and harmless (not swept).

## State schema

`~/.claude/progress/<session_id>.json` (schema v2):

```json
{
  "schema_version": 2,
  "active": true,
  "prompt_started_at": 1715000000,
  "last_tick": 1715000123,
  "overall": { "done": 4, "total": 8, "label": "implementing", "indeterminate": false },
  "current": { "source": "beacon", "step": 3, "total": 5, "label": "reviewing", "indeterminate": false }
}
```

Idle file (after `on-stop.sh`): `{"schema_version":2,"active":false}`.

Beacon scratch (`<sid>.current.json`): `{ "step": 3, "total": 5, "label": "reviewing" }`.

The renderer treats a missing `active` key (pre-upgrade v1 files) as active only when `prompt_started_at` exists and `last_tick` is within 30 min, so live sessions don't blink to idle across the upgrade.

## Global scope — works in every repo

Configured at the **global** Claude Code level, not per-repo:

- `~/.claude/settings.json` applies to every session in every repo on this machine.
- All hook commands reference `$HOME/.claude-dotfiles/scripts/progress/...` so they resolve from any cwd.
- The renderer keys state by `session_id`, not by repo — multiple windows in different repos each get their own state file.

**Only shadowed if** a specific repo's `<repo>/.claude/settings.json` sets its own `hooks`/`statusLine` block.

## Files

- `scripts/statusline.sh` — renderer (line-2 block near the bottom)
- `scripts/progress/on-prompt-submit.sh` — UserPromptSubmit hook
- `scripts/progress/on-todo-write.sh` — TodoWrite hook
- `scripts/progress/on-task-spawn.sh` — Task hook (beacon-claim + tick)
- `scripts/progress/on-stop.sh` — Stop hook (mark idle)
- `scripts/progress/on-session-start-cleanup.sh` — SessionStart GC (>7d)
- `scripts/progress/emit-beacon.sh` — opt-in beacon helper
- `~/.claude/progress/` — runtime state directory (mode 700, gitignored)

## Troubleshooting

**Line 2 shows `idle` during a prompt**
- The progress file isn't being updated. Confirm `UserPromptSubmit` fired: `ls ~/.claude/progress/` while a prompt runs. Reload Claude Code (Ctrl+R) — hooks register on startup only.

**Bar yellow when not stalled**
- `last_tick > 30s` ago — Claude is thinking with no recent tool call. Yellow is the intended signal.

**A one-shot task shows a spinner, not a filled bar**
- Expected. With no to-do list there's no sub-structure to measure; the spinner is the honest signal.

**Renderer errors**
- Run manually: `bash ~/.claude/statusline.sh < <(echo '{"session_id":"test"}')`. Errors print to stderr; line 2 still prints at least `idle`.
- Hand-write a state file: `echo '{"schema_version":2,"active":true,"prompt_started_at":'$(date +%s)',"last_tick":'$(date +%s)',"overall":{"done":2,"total":4,"label":"x","indeterminate":false}}' > ~/.claude/progress/test.json && bash ~/.claude/statusline.sh < <(echo '{"session_id":"test"}')`

## Design decisions

- **One bar, by specificity.** Beacon-with-total → todos-with-total → indeterminate beacon → spinner. A bare beacon must never shadow a real to-do bar.
- **Always present, never blank.** A bash-level fallback guarantees a line even on a crash or with no state file. This is the core requirement: line 2 loads every time, everywhere.
- **No mid-task vanish.** The old 5-minute `sys.exit` failsafe (which caused the bar to flip to the idle label mid-task) is gone, replaced by a 30-minute demote-to-idle guard that only catches a genuinely misfired Stop hook.
- **Idle, not deleted.** `on-stop.sh` marks the file idle instead of deleting it, so there's no flicker between prompts.
- **Accuracy comes from the to-do list, not inference.** A hook can't know the task; the to-do list Claude already keeps is the honest, zero-cost source. (The old slash-command scrape mis-captured typed file paths — removed.)
- **Atomic writes everywhere.** `os.replace`/tmp+`mv` so the renderer never reads a truncated file.
- **No `set -e`/`pipefail` in hooks; all `exit 0`.** Failures degrade silently.
