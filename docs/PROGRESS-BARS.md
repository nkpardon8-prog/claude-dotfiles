# Statusline Line 2 — Progress Bars

Dual progress bars on line 2 of the Claude Code statusline. Show overall task progress (TodoWrite-driven) and current command progress (Task-spawn or beacon-driven). Replaces the old per-session label, which now only appears when no prompt is running.

## What it looks like

```
ctx 42%  3h 11m left  87% sess  37% wk  Opus 4.7  my-repo     ← line 1 (unchanged)
⠋ 2:14  task ▰▰▰▰▱▱▱▱ 50% 4/8   /plan ▰▰▰▰▰▰▱▱ 75% 3/4       ← line 2 (new)
```

| Element | Meaning |
|---|---|
| `⠋⠙⠹⠸⠼⠴⠦⠧` | Spinner — cycles each render so you can tell the line is live |
| `2:14` | Elapsed time since the prompt started (mm:ss) |
| `task ▰▰▰▰▱▱▱▱ 50% 4/8` | **Bar 1**: overall task — driven by TodoWrite (`done/total`) |
| `/plan ▰▰▰▰▰▰▱▱ 75% 3/4` | **Bar 2**: current command — beacon or Task-spawn count |

**States:**
- **Active**: bars + spinner + elapsed (dim).
- **Stalled** (no tool call for 30s): bars switch to **yellow**.
- **Idle** (no prompt running): line 2 falls back to the existing per-session label.
- **Empty**: no progress + no label = no line 2.
- **Failsafe**: if no tool call for 5 min, line 2 hides regardless (in case the Stop hook misfires).

## How it works

Line 2's renderer (`scripts/statusline.sh`) reads `~/.claude/progress/<session_id>.json`. That file is maintained by 5 hook scripts in `scripts/progress/`:

| Hook | Event | What it does |
|---|---|---|
| `on-prompt-submit.sh` | `UserPromptSubmit` | Creates state file. Tails the transcript for the latest user turn, extracts the first `/<slash-command>`, sets `outer_command`. |
| `on-todo-write.sh` | `PostToolUse[TodoWrite]` | Reads the new todos array, computes `done/total`, updates Bar 1 + `last_tick`. |
| `on-task-spawn.sh` | `PostToolUse[Task]` | Increments spawn count + `last_tick`. Atomically claims any beacon scratch file. Falls back to `expected_subagents` from the command's frontmatter for Bar 2's denominator. |
| `on-stop.sh` | `Stop` | Deletes the state file when the prompt completes. |
| `on-session-start-cleanup.sh` | `SessionStart` | Removes stale state files older than 7 days. |

All hooks `exit 0` always. Failures degrade silently (line 2 falls back to the label or empty); Claude Code's main flow is never blocked.

## Universality — it works for every command

You don't need to do anything for any command to show progress. The hooks fire regardless of which command runs:

- **Bar 1 fills automatically** for any prompt where Claude uses TodoWrite.
- **Bar 2 fills automatically** for any prompt that spawns sub-agents via the Task tool. Without an `expected_subagents` hint it stays indeterminate (animated `▰▱` window) — honest "we're working" signal, not a fake percentage.

This means all 147 commands in `commands/` work today without modification. Frontmatter retrofit (next section) is purely an optional optimization.

## Optional: give Bar 2 a real denominator

Add one line to a command's frontmatter to tell the renderer how many sub-agents it typically spawns:

```yaml
---
name: ...
description: ...
expected_subagents: 5
---
```

Now Bar 2 shows `step N/5` instead of indeterminate. The 14 commands already retrofitted:

| Command | `expected_subagents` |
|---|---:|
| `/plan` | 3 |
| `/implement` | 4 |
| `/god-review` | 30 |
| `/god-report` | 29 |
| `/master-review` | 8 |
| `/codex-review` | 7 |
| `/document` | 5 |
| `/afk` | 1 |
| `/supabase-audit` | 4 |
| `/parsa/review/all` | 11 |
| `/plan2bid/run` | 6 |
| `/plan2bid/run-batched` | 4 |
| `/plan2bid/run-group` | 3 |
| `/ui-ux-pro-max/design` | 4 |

Counts are estimates — conservative is fine. Bar caps at 100% if exceeded.

## Optional: fine-grained beacons

For commands with discrete phases (loading → analyzing → reviewing → reporting), emit a beacon at each phase boundary so Bar 2 reflects the actual phase, not just spawn count.

**Bash-fenced commands** — call the helper:

```bash
bash $HOME/.claude-dotfiles/scripts/progress/emit-beacon.sh 3 5 "reviewing"
```

The helper auto-discovers the session_id from the project's transcript dir. For sub-agents whose pwd may differ, pass `SESSION_ID=...` explicitly:

```bash
SESSION_ID="$MY_SID" bash $HOME/.claude-dotfiles/scripts/progress/emit-beacon.sh 3 5 "reviewing"
```

**LLM-orchestrated commands** (`/god-review`, `/master-review`, etc.) — use the Write tool directly:

```
Write ~/.claude/progress/<session_id>.current.json with content:
{"step": 3, "total": 5, "label": "reviewing"}
```

Discover `<session_id>` the same way the Per-Session Status Label rule does (basename of the most-recently-modified transcript JSONL).

The beacon scratch file is consumed (deleted) on the next Task tool call. Beacons override the spawn-count fallback. Both are optional.

## State schema

`~/.claude/progress/<session_id>.json`:

```json
{
  "schema_version": 1,
  "prompt_started_at": 1715000000,
  "last_tick": 1715000123,
  "outer_command": "/plan",
  "overall": {
    "done": 4,
    "total": 8,
    "label": "implementing",
    "indeterminate": false
  },
  "current": {
    "cmd": "/plan",
    "step": 3,
    "total": 5,
    "label": "reviewing",
    "indeterminate": false,
    "source": "beacon"
  },
  "task_spawns": 3
}
```

Beacon scratch (`<sid>.current.json`):

```json
{ "step": 3, "total": 5, "label": "reviewing" }
```

`current.source` is `"init"`, `"beacon"`, or `"task-count"` — beacons always win.

## Global scope — works in every repo

This is configured at the **global** Claude Code level, not per-repo:

- `~/.claude/settings.json` is Claude Code's user-global config. It applies to every session in every repo on this machine.
- All 5 hook commands reference `$HOME/.claude-dotfiles/scripts/progress/...` so they resolve from any cwd.
- The renderer reads `~/.claude/progress/<session_id>.json` — keyed by session, not by repo. Multiple windows open in different repos each get their own state file.

**The only way this gets shadowed:** if a specific repo has `<repo>/.claude/settings.json` that sets its own `hooks` or `statusLine` block. Project-level settings override global. As of writing, none of the user's project-level settings touch either key, so the global setup wins everywhere.

To verify on a new machine: open Claude Code in any directory and check that line 2 starts showing bars after sending a prompt. If not, run `bash ~/.claude/statusline.sh < <(echo '{"session_id":"test"}')` to confirm the renderer works, then check `~/.claude/settings.json` for the hook entries.

## Files

- `scripts/statusline.sh` — renderer. Line-2 block lives near the bottom.
- `scripts/progress/on-prompt-submit.sh` — UserPromptSubmit hook
- `scripts/progress/on-todo-write.sh` — TodoWrite hook
- `scripts/progress/on-task-spawn.sh` — Task hook
- `scripts/progress/on-stop.sh` — Stop hook
- `scripts/progress/on-session-start-cleanup.sh` — SessionStart cleanup
- `scripts/progress/emit-beacon.sh` — opt-in beacon helper
- `~/.claude/settings.json` — hook wiring (in user's home, not in dotfiles)
- `~/.claude/progress/` — runtime state directory (mode 700, gitignored)

## Troubleshooting

**No bars showing during a prompt**
- Reload Claude Code (Ctrl+R or restart). Hooks only register on startup; recent settings.json changes don't take effect mid-session.
- Confirm the state file is being created: `ls ~/.claude/progress/` while a prompt runs. If empty, `UserPromptSubmit` hook isn't firing.
- Check the state file content: `jq . ~/.claude/progress/*.json` — should have `prompt_started_at` and `last_tick`.

**Bars hidden but you'd expect them**
- The 5-min `last_tick` failsafe hides bars after 5 min idle. Normal — no fix needed unless you see this during active work.

**Line 2 stuck on the old label**
- Likely no progress file. Check `ls ~/.claude/progress/` — empty? `UserPromptSubmit` hook isn't firing. Try `bash ~/.claude-dotfiles/scripts/progress/on-prompt-submit.sh < <(echo '{"session_id":"test","transcript_path":""}')` and inspect output.

**Bars yellow when not stalled**
- `last_tick > 30s` ago. Usually means no tool call has fired recently — Claude is just thinking. Yellow is the intended signal.

**`/some-command` shows indeterminate Bar 2 but you want a number**
- Add `expected_subagents: <N>` to that command's frontmatter. See "Optional: give Bar 2 a real denominator" above.

**Renderer rendering wrong / errors**
- Run manually: `bash ~/.claude/statusline.sh < <(echo '{"session_id":"test"}')`. Errors print to stderr; output is always safe.
- Hand-write a state file to test: `echo '{"schema_version":1,"prompt_started_at":'$(date +%s)',"last_tick":'$(date +%s)',"overall":{"done":2,"total":4,"indeterminate":false},"current":{"step":1,"total":3,"indeterminate":false,"label":"x"},"task_spawns":1}' > ~/.claude/progress/test.json && bash ~/.claude/statusline.sh < <(echo '{"session_id":"test"}')`

**Settings.json malformed after manual edit**
- Validate: `python3 -c "import json; json.load(open('$HOME/.claude/settings.json'))"`. If broken, line 2 + everything else may stop working. Restore from `~/.claude/settings.json.backup` if available.

## Design decisions

- **No fake percentages.** When there's no real signal (no todo list, no `expected_subagents`, no beacon), bars show animated indeterminate sliding-window — honest "working" state.
- **5-min `last_tick` failsafe.** If the Stop hook never fires (event name change, hook crash), bars auto-hide after 5 min. Keeps line 2 from getting stuck on stale state across prompts.
- **Atomic beacon claim.** `os.rename(beacon, beacon+'.merging')` before reading eliminates the TOCTOU window where a fresh beacon could be lost.
- **No `set -e` / `set -o pipefail` in hooks.** A failing `grep` (e.g. on a plain-text prompt with no slash command) must not abort the hook. All hooks `exit 0` always.
- **Each specific hook owns `last_tick`.** No matcherless tick hook — that would race with TodoWrite/Task hooks and risk clobbering their writes.
- **Stop hook is synchronous.** Async would risk a flash of stale bars before the file is deleted.
