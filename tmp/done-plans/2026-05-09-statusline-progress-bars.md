# Plan: Statusline Line 2 — Dual Progress Bars

> Note: original location `~/Desktop/.../tmp/ready-plans/` lost write permissions mid-session due to a cwd recovery; plan moved here. `/implement` should accept this path.

## Goal

Replace the per-session label rendered on line 2 of the Claude Code statusline with **two compact progress bars**:
1. Overall task progress derived from the active TodoWrite list.
2. Current slash-command progress derived from a beacon protocol, with sub-agent-spawn-count fallback, with indeterminate animation as final fallback.

Keep the existing session label as the **idle fallback** when no prompt is in flight. Add spinner+elapsed prefix and stall-detection color shift.

**Critical universality requirement:** the system must work for **every** command in the dotfiles (147 commands + 10 skills + 12 agents) without per-command code changes. Retrofit is an *optional* optimization that adds a single frontmatter line.

## Summary

- Replace `~/.claude-dotfiles/scripts/statusline.sh:269-288` with an inline python3-driven renderer reading `~/.claude/progress/<session_id>.json`, falling back to `~/.claude/session-status/<session_id>.txt`.
- Add 5 hook scripts (`UserPromptSubmit`, `PostToolUse[TodoWrite]`, `PostToolUse[Task]`, `Stop`, plus a `SessionStart` cleanup) maintaining the progress JSON.
- Hooks fire **regardless of which command runs**. Bar 1 works for any prompt that uses TodoWrite. Bar 2 works for any prompt via Task-spawn-count fallback (indeterminate denominator if no frontmatter hint, which is honest).
- Define a beacon protocol: any command can write a JSON line (LLM-orchestrated commands via Write tool; bash-fenced commands via `emit-beacon.sh` helper).
- **Optional opt-in retrofit**: add `expected_subagents: <N>` frontmatter to commands with deterministic sub-agent counts. Plan starts with ~14 high-confidence retrofits; the protocol is documented so future commands can opt in trivially.
- All existing command behavior is unchanged; retrofit is purely additive frontmatter.

## Intent / Why

- Current line 2 is unreliable — it depends on Claude remembering to write a label file. Most sessions never get one.
- Two bars give two angles: overall (TodoWrite, automatic) + active-command (spawn-count, automatic).
- Truthfulness over completeness: indeterminate animation when no signal exists.
- **Must not touch existing command bodies.** Only optional frontmatter additions.
- **Must work universally.** Every command in `~/.claude-dotfiles/` already benefits without modification; retrofit is opt-in.

## Source Artifacts

- Brief: `./tmp/briefs/2026-05-09-statusline-progress-bars.md`
- Research dossier: None.

## What

### User-visible behavior
- Active prompt: `⠋ 2:14  task ▰▰▰▰▱▱▱▱ 50% 4/8   /plan ▰▰▰▰▰▰▱▱ 75% 3/4`
- Active prompt without plan: `⠋ 0:42  task ▰▰▱▰▰▱▱▱ working   /investigate ▰▰▱▱▱▱▱▱ 25% 1/4`
- Active prompt without plan or known denominator: `⠋ 0:18  task ▰▰▱▰▰▱▱▱ working   ▰▰▱▰▰▱▱▱`
- Stalled: bars dim to yellow.
- Idle: existing session label (or empty).

### Success Criteria
- [ ] Statusline renders correctly with hand-written progress JSON.
- [ ] After UserPromptSubmit fires, `progress/<sid>.json` exists with timestamps.
- [ ] After TodoWrite with 4 todos (1 done), Bar 1 reads `25% 1/4`.
- [ ] After Stop, line 2 reverts to label or vanishes.
- [ ] **Every one of the 147 commands still loads and runs unchanged.**
- [ ] Bar 1+2 work correctly for prompts using ANY command (retrofitted or not).
- [ ] Plain-text prompts (no `/command`) produce a working state file (no regression).

## Verified Repo Truths

### Entry Points / Integrations

- Fact: Statusline at `~/.claude-dotfiles/scripts/statusline.sh`, invoked via `~/.claude/settings.json` `statusLine.command`.
  Evidence: `~/.claude-dotfiles/scripts/statusline.sh:1-22`
  Implication: Single renderer file to modify.

- Fact: Line 2 currently rendered by `statusline.sh:269-288` reading `~/.claude/session-status/<sid>.txt`.
  Evidence: `~/.claude-dotfiles/scripts/statusline.sh:269-288`
  Implication: Sole replacement target.

- Fact: Statusline reads `session_id` via `jq_get '.session_id'` and sanitizes via `tr -cd 'A-Za-z0-9_-' | head -c 128`.
  Evidence: `~/.claude-dotfiles/scripts/statusline.sh:273-275`

- Fact: Statusline already invokes `python3` inline via heredoc at `:46-66` for transcript token counting.
  Evidence: `~/.claude-dotfiles/scripts/statusline.sh:46-66`
  Implication: Inline python3 in the new block matches established pattern.

### Execution / Async Flow

- Fact: `~/.claude/settings.json` `hooks` shape is `{ "<EventName>": [ { "matcher"?: "...", "hooks": [{"type":"command", "command":"...", "async"?: bool}] } ] }`.
  Evidence: existing `PostToolUse` entry with `matcher: "Edit|Write"`, `async: true`, command `$HOME/.claude-dotfiles/scripts/dotfiles-sync.sh`. Existing `SessionStart` uses same shape without `matcher`.

### Frontend / UI

- Fact: ANSI vars at `statusline.sh:13-19` (`RED, YELLOW, GREEN, CYAN, BOLD, DIM, RESET`).

### Shared Types / Exports

- Fact: Per-Session Status Label rule documented at `~/.claude-dotfiles/CLAUDE.md:23-50+`.
  Implication: Stays unchanged. New "Progress Beacon Protocol" section appended.

### Command Inventory (verified via `find`)

- Fact: 147 commands at `~/.claude-dotfiles/commands/**/*.md` (verified via `find ... | wc -l`).
- Fact: 10 skills at `~/.claude-dotfiles/skills/**/*.md`.
- Fact: 12 agents at `~/.claude-dotfiles/agents/**/*.md`.
  Implication: Per-command retrofit at this scale is impractical. Architecture must work universally without retrofit, with retrofit as optional optimization.

## Locked Decisions

- Layout: compact two-bar single line, `▰▱`, 8-wide. (Brief)
- Spinner + elapsed prepended; yellow on >30s stall; indeterminate animation when no signal. (Brief)
- Session label survives as idle fallback; CLAUDE.md rule unchanged. (Brief)
- ETA: out of scope. (Brief)
- **Universal architecture, optional retrofit.** Hooks fire for any command; frontmatter retrofit is opt-in.
- **Bar 2 fallback**: Task spawn count vs frontmatter `expected_subagents`. Indeterminate if frontmatter missing.
- **Renderer fully inline in statusline.sh** (no separate lib.sh).
- **Each specific hook (TodoWrite, Task) owns `last_tick`.** No matcherless tick hook.
- **Stop hook is synchronous.**
- **`set -e` / `set -o pipefail` BANNED in hook scripts.**
- **`outer_command` derived by tailing transcript JSONL** (UserPromptSubmit `.prompt` may not be in payload; transcript-derivation is robust).
- **Renderer 5-min `last_tick` failsafe**: hide bars regardless if no tool call in 5 min — saves us if Stop misfires.
- **Beacon TOCTOU fix**: `os.rename(beacon, beacon+'.merging')` atomically claims before reading.
- **`emit-beacon.sh` accepts `$SESSION_ID` env override** for sub-agents.
- **Stale-file cleanup is a separate SessionStart hook entry**, not appended to existing inline command.
- **Initial retrofit list (14 high-confidence commands)** with deterministic sub-agent counts. All other 133 commands work via universal fallback. Protocol documented so any command can opt in later by adding one frontmatter line.

## Known Mismatches / Assumptions

- Assumption: Claude Code hook events `UserPromptSubmit` and `Stop` exist and pass `session_id` + `transcript_path` on stdin.
  Evidence: Existing `PostToolUse` confirms framework. Both events documented in Claude Code hooks reference.
  Planning Decision: Use them. 5-min `last_tick` failsafe ensures bars hide even if `Stop` never fires.

- Assumption: `tool_input.todos[].activeForm` present on TodoWrite calls.
  Planning Decision: Read it; fall back to "working".

- Assumption: Frontmatter loader tolerates new `expected_subagents:` key.
  Planning Decision: Add it. If broken, only Bar 2's denominator falls back to indeterminate — no command behavior breaks. Only 14 commands modified initially, easy to revert.

- Assumption: Two `PostToolUse` entries (existing matched `Edit|Write` + new matched `TodoWrite` + new matched `Task`) all fire independently.
  Planning Decision: All entries are matcher-specific (no matcherless catch-all), so no overlap with `Edit|Write`.

## Critical Codebase Anchors

- `~/.claude-dotfiles/scripts/statusline.sh:269-288` — line 2 renderer block (replace).
- `~/.claude-dotfiles/scripts/statusline.sh:46-66` — inline python3 pattern (reuse).
- `~/.claude/settings.json` `hooks.PostToolUse[0]` — matcher + async pattern (mimic).

## All Needed Context

### Documentation & References

- Repo reference: `~/.claude-dotfiles/scripts/statusline.sh` — sole renderer.
- Repo reference: `~/.claude/settings.json` — hooks config.
- Repo reference: `~/.claude-dotfiles/CLAUDE.md` (Per-Session Status Label section) — coexisting rule.
- External doc: Claude Code hooks reference — https://docs.claude.com/en/docs/claude-code/hooks
  Critical insight: hook stdin is JSON; non-zero exit can block tool — always `exit 0`.

### Files Being Changed

```
~/.claude-dotfiles/
├── scripts/
│   ├── statusline.sh                                    ← MODIFIED  (replace lines 269-288)
│   └── progress/                                        ← NEW
│       ├── on-prompt-submit.sh                          ← NEW
│       ├── on-todo-write.sh                             ← NEW
│       ├── on-task-spawn.sh                             ← NEW
│       ├── on-stop.sh                                   ← NEW
│       ├── on-session-start-cleanup.sh                  ← NEW
│       └── emit-beacon.sh                               ← NEW
├── CLAUDE.md                                            ← MODIFIED  (append "Progress Beacon Protocol" section)
├── docs/
│   └── STATUSLINE.md                                    ← MODIFIED  (rewrite line-2 description)
└── commands/                                            ← MODIFIED  (frontmatter only, 14 files; 133 untouched)
    ├── plan.md
    ├── implement.md
    ├── god-review.md
    ├── god-report.md
    ├── master-review.md
    ├── codex-review.md
    ├── document.md
    ├── afk.md
    ├── ultrareview.md  (if present — verify in Task 9)
    ├── parsa/review/all.md
    ├── plan2bid/run.md
    ├── plan2bid/run-batched.md
    ├── plan2bid/run-group.md
    └── ui-ux-pro-max/design.md

~/.claude/
├── settings.json                                        ← MODIFIED  (merge new hook entries)
└── progress/                                            ← NEW       (runtime, mode 700, gitignored)
```

### Known Gotchas & Library Quirks

- macOS bash 3.2: no `printf '%q'`, no associative arrays. Use python3 inline for non-trivial parsing.
- `jq` available throughout statusline.sh.
- **Hook scripts must NOT use `set -e` or `set -o pipefail`.** A failing `grep` in a pipeline kills the script and no state file gets written, regressing plain-text prompts.
- Hook stdin must be `cat`-once: `INPUT=$(cat); SID=$(echo "$INPUT" | jq -r '.session_id // empty')`.
- Atomic file writes via `.tmp.$$` + `mv`.
- Spinner: `(date +%s) % 8` indexes into `⠋⠙⠹⠸⠼⠴⠦⠧`.
- Indeterminate bar: 3-cell sliding window with wraparound (single cell looks like 12% bar).
- TodoWrite payload: `tool_input.todos = [{content, status, activeForm}, ...]`.
- Task payload: `tool_input.subagent_type` identifies agent.
- Beacon claim atomic via `os.rename(beacon, beacon+'.merging')`.
- `outer_command`: tail transcript JSONL for latest `human` turn, parse first `^/[a-z][a-z0-9-:_/]*` token. (Includes `/` for namespaced commands like `/parsa/review/all`.)

## Reconciliation Notes

None.

## Delta Design

### Data / State Changes

Existing:
- `~/.claude/session-status/<sid>.txt` — single-line label.

Change:
- New runtime dir `~/.claude/progress/` (mode 700).
- New per-session state JSON `~/.claude/progress/<sid>.json`:
  ```json
  {
    "schema_version": 1,
    "prompt_started_at": <ts>,
    "last_tick": <ts>,
    "outer_command": "/plan" | "/parsa/review/all" | null,
    "overall": {"done": <n>, "total": <n>, "label": <str>, "indeterminate": <bool>},
    "current": {"cmd": <str>, "step": <n>, "total": <n>|null, "label": <str>, "indeterminate": <bool>, "source": "init"|"beacon"|"task-count"},
    "task_spawns": <n>
  }
  ```
- New beacon scratch JSON `~/.claude/progress/<sid>.current.json`.

Risks:
- Stale state files. Mitigation: Stop deletes; SessionStart cleanup removes >7-day-old; renderer 5-min `last_tick` failsafe.

### Entry Point / Integration Flow

Existing:
- `statusLine` invokes `~/.claude/statusline.sh`.

Change:
- Same entry. Line 2 = bars (if state present and fresh) → label → empty.
- **Final merged `~/.claude/settings.json` `hooks` block** (the literal JSON to write):
  ```json
  "hooks": {
    "SessionStart": [
      { "hooks": [ /* existing dotfiles-sync + secret-detector command — UNTOUCHED */ ] },
      { "hooks": [ { "type": "command", "command": "$HOME/.claude-dotfiles/scripts/progress/on-session-start-cleanup.sh", "async": true } ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$HOME/.claude-dotfiles/scripts/progress/on-prompt-submit.sh" } ] }
    ],
    "PostToolUse": [
      { "matcher": "Edit|Write", "hooks": [ /* existing dotfiles-sync.sh — UNTOUCHED */ ] },
      { "matcher": "TodoWrite", "hooks": [ { "type": "command", "command": "$HOME/.claude-dotfiles/scripts/progress/on-todo-write.sh", "async": true } ] },
      { "matcher": "Task", "hooks": [ { "type": "command", "command": "$HOME/.claude-dotfiles/scripts/progress/on-task-spawn.sh", "async": true } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$HOME/.claude-dotfiles/scripts/progress/on-stop.sh" } ] }
    ]
  }
  ```
  (All matcher-specific entries — zero overlap with existing `Edit|Write`. No write-write races. No match-order ambiguity.)

### Execution / Control Flow

Existing: statusline renders on demand.

Change:
- Renderer reads progress JSON if present **and** `now - last_tick <= 300`; else falls back to label; else empty.
- Indeterminate 3-cell sliding window:
  ```python
  pos = now % WIDTH
  cells = ["▱"] * WIDTH
  for i in range(3): cells[(pos + i) % WIDTH] = "▰"
  ```

### User-Facing / Operator-Facing Surface

Existing: line 2 = label or empty.

Change: bars when active; label when idle; empty otherwise.

### External / Operational Surface

Existing: CLAUDE.md "Per-Session Status Label" rule.

Change: New CLAUDE.md "Progress Beacon Protocol" section explaining:
1. **Universality**: line 2 already shows progress for ANY command via TodoWrite + Task-spawn-count. No retrofit needed.
2. **Opt-in optimization**: add `expected_subagents: <N>` frontmatter to give Bar 2 a real denominator.
3. **Beacon protocol** (advanced): write `{"step": N, "total": M, "label": "..."}` to `~/.claude/progress/<sid>.current.json` for finer granularity at phase boundaries.
   - LLM-orchestrated commands: use the Write tool.
   - Bash-fenced commands: use `bash $HOME/.claude-dotfiles/scripts/progress/emit-beacon.sh <step> <total> "<label>"`.
4. **Beacons are optional.** Without them, Bar 2 falls back gracefully.

## Implementation Blueprint

### Architecture Overview

```
USER PROMPT (any command, or none)
   ↓
[UserPromptSubmit]  on-prompt-submit.sh
   - tail transcript → extract first slash-command (handles namespaced like /parsa/review/all)
   - mkdir progress/, write <sid>.json
   ↓
TOOL CALLS (any command's execution)
   ↓
[PostToolUse TodoWrite]  on-todo-write.sh
   - parse todos → state.overall + state.last_tick
[PostToolUse Task]  on-task-spawn.sh
   - state.task_spawns++; state.last_tick
   - claim beacon (atomic rename), parse, merge as state.current source=beacon
   - else: derive state.current from spawn count + frontmatter expected_subagents
   ↓
RENDER (every ~1-2s)
   - if state and last_tick fresh: bars + spinner + elapsed
   - else: label or empty
   ↓
[Stop]  on-stop.sh (sync)
   - rm -f progress/<sid>.{json,current.json}
```

### Key Pseudocode

**`statusline.sh` line-2 replacement** (replaces lines 269-288, fully inline — no lib.sh):
```bash
# ── 7. Line 2: progress bars (active) or session label (idle) ─────────────
SESSION_ID=$(jq_get '.session_id')
SAFE_SID=$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9_-' | head -c 128 || true)
LINE2=""

if [ -n "$SAFE_SID" ]; then
  PROGRESS_FILE="$HOME/.claude/progress/$SAFE_SID.json"
  if [ -f "$PROGRESS_FILE" ]; then
    LINE2=$(python3 - "$PROGRESS_FILE" <<'PY' 2>/dev/null
import json, sys, time
try:
    with open(sys.argv[1]) as fh: s = json.load(fh)
except Exception: sys.exit(0)
now = int(time.time())
# 5-min failsafe: hide bars if no tool call in 5 min (Stop may have misfired)
if now - s.get("last_tick", now) > 300: sys.exit(0)

elapsed = now - s.get("prompt_started_at", now)
mins, secs = divmod(elapsed, 60)
spinner = "⠋⠙⠹⠸⠼⠴⠦⠧"[now % 8]
stalled = (now - s.get("last_tick", now)) > 30
color = "\033[0;33m" if stalled else "\033[2m"
reset = "\033[0m"
WIDTH = 8

def bar(spec):
    if spec.get("indeterminate") or not spec.get("total"):
        pos = now % WIDTH
        cells = ["▱"] * WIDTH
        for i in range(3): cells[(pos + i) % WIDTH] = "▰"
        return "".join(cells), spec.get("label") or "working", None
    done, total = int(spec["done"]), int(spec["total"])
    if total <= 0: total = 1
    filled = max(0, min(WIDTH, (done * WIDTH) // total))
    return "▰"*filled + "▱"*(WIDTH-filled), spec.get("label") or "", f"{(100*done)//total}% {done}/{total}"

ov = s.get("overall", {"indeterminate": True})
cu = s.get("current", {"indeterminate": True})
ovb, ovl, ovp = bar(ov)
cub, cul, cup = bar(cu)
ov_str = f"task {ovb} {ovp}" if ovp else f"task {ovb} {ovl}"
cu_label = s.get("outer_command") or cul or "cmd"
cu_str = f"{cu_label} {cub} {cup}" if cup else f"{cu_label} {cub} {cul}"
print(f"{color}{spinner} {mins}:{secs:02d}  {ov_str}   {cu_str}{reset}")
PY
    )
  fi

  # Fallback to existing session label
  if [ -z "$LINE2" ]; then
    LABEL_FILE="$HOME/.claude/session-status/$SAFE_SID.txt"
    if [ -f "$LABEL_FILE" ]; then
      LABEL=$(head -n 1 "$LABEL_FILE" 2>/dev/null \
        | python3 -c "import sys; s=sys.stdin.readline().rstrip(); print(s[:99]+'…' if len(s) > 100 else s)" \
        2>/dev/null || true)
      [ -n "$LABEL" ] && LINE2="${DIM}${LABEL}${RESET}"
    fi
  fi
fi

[ -n "$LINE2" ] && printf "%b\n" "$LINE2"
```

**`on-prompt-submit.sh`** (init state; transcript-derived outer_command):
```bash
#!/usr/bin/env bash
# NOTE: NO `set -e`, NO `set -o pipefail` — failing greps must not abort
INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9_-' | head -c 128)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
[ -z "$SID" ] && exit 0

mkdir -p "$HOME/.claude/progress" 2>/dev/null
chmod 700 "$HOME/.claude/progress" 2>/dev/null

# Extract latest human turn's first slash-command from transcript
# Includes `/` in pattern to capture namespaced commands like /parsa/review/all
OUTER=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  OUTER=$(tail -50 "$TRANSCRIPT" 2>/dev/null \
    | jq -rs '[.[] | select(.type=="user" or .message.role=="user")] | last | (.message.content // .content // "")' 2>/dev/null \
    | head -c 1000 \
    | grep -oE '/[a-z][a-z0-9:_/-]*' 2>/dev/null \
    | head -1)
  OUTER=${OUTER:-}
fi

NOW=$(date +%s)
F="$HOME/.claude/progress/$SID.json"
TMP="$F.tmp.$$"

python3 - "$TMP" "$NOW" "$OUTER" <<'PY' 2>/dev/null
import json, sys
out = {
    "schema_version": 1,
    "prompt_started_at": int(sys.argv[2]),
    "last_tick": int(sys.argv[2]),
    "outer_command": sys.argv[3] or None,
    "overall": {"indeterminate": True, "label": "working"},
    "current": {"indeterminate": True, "label": "starting", "source": "init"},
    "task_spawns": 0,
}
with open(sys.argv[1], "w") as fh: json.dump(out, fh)
PY
[ -f "$TMP" ] && mv "$TMP" "$F"
exit 0
```

**`on-todo-write.sh`**:
```bash
#!/usr/bin/env bash
INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && exit 0
F="$HOME/.claude/progress/$SID.json"
[ ! -f "$F" ] && exit 0

DONE=$(echo "$INPUT" | jq '[.tool_input.todos[]? | select(.status=="completed")] | length' 2>/dev/null)
TOTAL=$(echo "$INPUT" | jq '[.tool_input.todos[]?] | length' 2>/dev/null)
ACTIVE=$(echo "$INPUT" | jq -r '[.tool_input.todos[]? | select(.status=="in_progress")][0].activeForm // empty' 2>/dev/null)
{ [ -z "$TOTAL" ] || [ "$TOTAL" = "0" ]; } && exit 0

NOW=$(date +%s)
TMP="$F.tmp.$$"
python3 - "$F" "$TMP" "$DONE" "$TOTAL" "$NOW" "${ACTIVE:-working}" <<'PY' 2>/dev/null
import json, sys
src, tmp, done, total, now, active = sys.argv[1:7]
try:
    with open(src) as fh: s = json.load(fh)
except Exception: sys.exit(0)
s["overall"] = {"done": int(done), "total": int(total), "label": active, "indeterminate": False}
s["last_tick"] = int(now)
with open(tmp, "w") as fh: json.dump(s, fh)
PY
[ -f "$TMP" ] && mv "$TMP" "$F"
exit 0
```

**`on-task-spawn.sh`** (Bar 2 + atomic beacon claim + spawn-count fallback):
```bash
#!/usr/bin/env bash
INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && exit 0
F="$HOME/.claude/progress/$SID.json"
[ ! -f "$F" ] && exit 0
SUBAGENT=$(echo "$INPUT" | jq -r '.tool_input.subagent_type // "agent"' 2>/dev/null)
NOW=$(date +%s)
BEACON="$HOME/.claude/progress/$SID.current.json"
TMP="$F.tmp.$$"

python3 - "$F" "$TMP" "$NOW" "$SUBAGENT" "$BEACON" <<'PY' 2>/dev/null
import json, sys, os, re, glob
src, tmp, now, sub, beacon = sys.argv[1:6]
try:
    with open(src) as fh: s = json.load(fh)
except Exception: sys.exit(0)

s["task_spawns"] = s.get("task_spawns", 0) + 1
s["last_tick"] = int(now)

# Atomic beacon claim
beacon_data = None
claimed = beacon + ".merging"
try:
    os.rename(beacon, claimed)
    with open(claimed) as fh: beacon_data = json.load(fh)
    os.remove(claimed)
except FileNotFoundError: pass
except Exception:
    try: os.remove(claimed)
    except Exception: pass

if beacon_data:
    s["current"] = {
        "cmd": s.get("outer_command") or beacon_data.get("cmd","cmd"),
        "step": int(beacon_data.get("step", 0)),
        "total": int(beacon_data["total"]) if beacon_data.get("total") else None,
        "label": beacon_data.get("label") or "working",
        "indeterminate": not beacon_data.get("total"),
        "source": "beacon",
    }
elif s.get("current", {}).get("source") != "beacon":
    # Frontmatter fallback. Handles namespaced commands: /parsa/review/all → parsa/review/all.md
    total = None
    cmd = (s.get("outer_command") or "").lstrip("/")
    if cmd:
        home = os.path.expanduser("~")
        # Try namespaced direct path first, then recursive glob
        direct = f"{home}/.claude-dotfiles/commands/{cmd}.md"
        candidates = [direct] if os.path.exists(direct) else \
                     glob.glob(f"{home}/.claude-dotfiles/commands/{cmd}.md") + \
                     glob.glob(f"{home}/.claude-dotfiles/commands/**/{os.path.basename(cmd)}.md", recursive=True)
        for c in candidates:
            try:
                txt = open(c).read()
                m = re.search(r"^expected_subagents:\s*(\d+)", txt, re.M)
                if m: total = int(m.group(1)); break
            except Exception: pass
    s["current"] = {
        "cmd": s.get("outer_command") or "agent",
        "step": s["task_spawns"],
        "total": total,
        "label": sub,
        "indeterminate": total is None,
        "source": "task-count",
    }

with open(tmp, "w") as fh: json.dump(s, fh)
PY
[ -f "$TMP" ] && mv "$TMP" "$F"
exit 0
```

**`on-stop.sh`**:
```bash
#!/usr/bin/env bash
INPUT=$(cat)
SID=$(echo "$INPUT" | jq -r '.session_id // empty' | tr -cd 'A-Za-z0-9_-' | head -c 128)
[ -z "$SID" ] && exit 0
rm -f "$HOME/.claude/progress/$SID.json" "$HOME/.claude/progress/$SID.current.json" 2>/dev/null
exit 0
```

**`on-session-start-cleanup.sh`** (separate hook entry):
```bash
#!/usr/bin/env bash
mkdir -p "$HOME/.claude/progress" 2>/dev/null
find "$HOME/.claude/progress" -type f -mtime +7 -delete 2>/dev/null
exit 0
```

**`emit-beacon.sh`** (helper):
```bash
#!/usr/bin/env bash
# Usage: emit-beacon.sh <step> <total> "<label>"
# Optional env: SESSION_ID (override auto-discovery for sub-agents)
STEP=${1:-0}
TOTAL=${2:-0}
LABEL=${3:-working}

SID="${SESSION_ID:-}"
if [ -z "$SID" ]; then
  PROJ_DIR="$HOME/.claude/projects/$(pwd | sed 's|/|-|g; s|^|-|')"
  SID=$(ls -t "$PROJ_DIR"/*.jsonl 2>/dev/null | head -1 | xargs -I {} basename {} .jsonl 2>/dev/null)
fi
[ -z "$SID" ] && exit 0

mkdir -p "$HOME/.claude/progress" 2>/dev/null
F="$HOME/.claude/progress/$SID.current.json"
python3 - "$F" "$STEP" "$TOTAL" "$LABEL" <<'PY' 2>/dev/null
import json, sys
with open(sys.argv[1], "w") as fh:
    json.dump({"step": int(sys.argv[2]), "total": int(sys.argv[3]), "label": sys.argv[4]}, fh)
PY
exit 0
```

### Tasks (in implementation order)

Task 1:
Goal: Land renderer + state schema with hand-written test data.
Files:
- MODIFY `~/.claude-dotfiles/scripts/statusline.sh` (replace lines 269-288 with new inline-python3 block)
- Manually create `~/.claude/progress/` (mkdir + chmod 700) for testing
Pattern to copy: existing inline-python3 at `statusline.sh:46-66`.
Gotchas:
- NEVER let statusline error. `2>/dev/null` on python3 + `[ -n "$LINE2" ] &&` guard.
- Heredoc `'PY'` quoted to prevent bash interpolation.
- File must be UTF-8 for `▰▱`.
DOD:
- Hand-write `~/.claude/progress/test123.json`; `bash ~/.claude/statusline.sh < <(echo '{"session_id":"test123"}')` shows two bars.
- Delete file → falls back to label or empty.

Task 2:
Goal: UserPromptSubmit hook initializes state with transcript-derived outer_command.
Files:
- CREATE `~/.claude-dotfiles/scripts/progress/on-prompt-submit.sh` (chmod +x)
- MODIFY `~/.claude/settings.json` (add `UserPromptSubmit`, sync, no `async`)
Pattern to copy: existing `SessionStart` entry shape.
Gotchas: NO `set -e`/`set -o pipefail`. Plain-text prompts must produce a state file.
DOD:
- `/foo` prompt → state file with `outer_command="/foo"`.
- `/parsa/review/all` prompt → state file with `outer_command="/parsa/review/all"` (namespaced).
- Plain-text prompt → state file with `outer_command=null`. **No regression.**

Task 3:
Goal: TodoWrite hook drives Bar 1.
Files:
- CREATE `~/.claude-dotfiles/scripts/progress/on-todo-write.sh` (chmod +x)
- MODIFY `~/.claude/settings.json` (add `PostToolUse` matcher `TodoWrite`, async: true)
Pattern to copy: existing `Edit|Write` PostToolUse entry.
DOD: TodoWrite with 4 items (1 completed) → Bar 1 = 25% 1/4 with activeForm label.

Task 4:
Goal: Task spawn hook with atomic beacon claim + spawn-count fallback.
Files:
- CREATE `~/.claude-dotfiles/scripts/progress/on-task-spawn.sh` (chmod +x)
- MODIFY `~/.claude/settings.json` (add `PostToolUse` matcher `Task`, async: true)
Gotchas: `os.rename` atomic; namespaced command resolution (try direct path before glob).
DOD:
- 3 Task spawns with `expected_subagents: 3` → Bar 2: 1/3, 2/3, 3/3.
- Beacon write + Task spawn → `source: "beacon"` overrides.
- Untracked command (no frontmatter) → indeterminate Bar 2 with spawn count visible elsewhere (just "step 1" ish).

Task 5:
Goal: Stop hook deletes state.
Files:
- CREATE `~/.claude-dotfiles/scripts/progress/on-stop.sh` (chmod +x)
- MODIFY `~/.claude/settings.json` (add `Stop`, synchronous)
DOD: After Claude finishes, state file is gone; line 2 reverts.

Task 6:
Goal: SessionStart cleanup as separate hook entry.
Files:
- CREATE `~/.claude-dotfiles/scripts/progress/on-session-start-cleanup.sh` (chmod +x)
- MODIFY `~/.claude/settings.json` (add second object inside `SessionStart` array)
Gotchas: DO NOT touch existing SessionStart command string. Add sibling.
DOD: Files >7 days deleted; existing dotfiles-sync + secret-detector unchanged.

Task 7:
Goal: Beacon emit helper.
Files:
- CREATE `~/.claude-dotfiles/scripts/progress/emit-beacon.sh` (chmod +x)
DOD:
- `bash ... 2 5 "writing"` writes valid scratch JSON.
- `SESSION_ID=foo bash ...` writes to `progress/foo.current.json`.

Task 8:
Goal: Document protocol; update STATUSLINE.md.
Files:
- MODIFY `~/.claude-dotfiles/CLAUDE.md` (append "Progress Beacon Protocol" section AFTER "Per-Session Status Label")
- MODIFY `~/.claude-dotfiles/docs/STATUSLINE.md` (rewrite line-2 description; add "How to opt in for any command" section)
Critical content for CLAUDE.md section:
- Universality: works for ALL 147+ commands automatically.
- Opt-in: add `expected_subagents: <N>` to any command's frontmatter for known denominator.
- Beacon protocol for finer granularity (Write tool for LLM-orchestrated; helper for bash).
- Beacons OPTIONAL.
DOD: A new contributor reading CLAUDE.md alone can opt any command in via single frontmatter line.

Task 9:
Goal: **Initial frontmatter retrofit of 14 high-confidence commands.** All other 133 commands work via universal fallback unchanged.
Files (all MODIFY, frontmatter only):
- `~/.claude-dotfiles/commands/plan.md` — `expected_subagents: 3` (2 plan-reviewers + 1 meta-pass)
- `~/.claude-dotfiles/commands/implement.md` — `expected_subagents: 4` (typical chunk count; conservative estimate)
- `~/.claude-dotfiles/commands/god-review.md` — `expected_subagents: 30` (3 broad Claude + 3 broad Codex + 23 principles + ~1 architect)
- `~/.claude-dotfiles/commands/god-report.md` — `expected_subagents: 29` (no architect)
- `~/.claude-dotfiles/commands/master-review.md` — `expected_subagents: 8` (3 Opus + 3 Codex + 2 Antigravity)
- `~/.claude-dotfiles/commands/codex-review.md` — `expected_subagents: 7` (2 Codex review + 1 verify + 4 Claude lens)
- `~/.claude-dotfiles/commands/document.md` — `expected_subagents: 5`
- `~/.claude-dotfiles/commands/afk.md` — `expected_subagents: 1`
- `~/.claude-dotfiles/commands/parsa/review/all.md` — `expected_subagents: 11` (11 principle reviewers)
- `~/.claude-dotfiles/commands/plan2bid/run.md` — `expected_subagents: 6` (typical trade-group fan-out; estimate)
- `~/.claude-dotfiles/commands/plan2bid/run-batched.md` — `expected_subagents: 4`
- `~/.claude-dotfiles/commands/plan2bid/run-group.md` — `expected_subagents: 3`
- `~/.claude-dotfiles/commands/ui-ux-pro-max/design.md` — `expected_subagents: 4`
- `~/.claude-dotfiles/commands/supabase-audit.md` — `expected_subagents: 4`
Gotchas:
- DO NOT change any other frontmatter or body content. ONLY add the one key.
- If `expected_subagents` already exists (sanity check), leave existing value alone.
- All 133 other commands UNTOUCHED — they work via universal architecture's indeterminate fallback.
- Counts are estimates; conservative is fine. Bar will show 100%+ if exceeded (capped to width).
DOD:
- All 14 files have the new frontmatter key; YAML still parses.
- Each command still loads and runs unchanged (smoke-test by listing it via Claude Code).
- Running any command (retrofitted or not) shows working line 2.

### Integration Points

- Renderer: `~/.claude/statusline.sh`
- Hooks: `~/.claude/settings.json` `hooks.{SessionStart,UserPromptSubmit,PostToolUse,Stop}`
- State: `~/.claude/progress/` (mode 700, runtime-only)
- Helper: `~/.claude-dotfiles/scripts/progress/emit-beacon.sh`
- Documentation: `~/.claude-dotfiles/CLAUDE.md` + `~/.claude-dotfiles/docs/STATUSLINE.md`
- Frontmatter: 14 of 147 commands (the rest work via fallback)

## Validation

```bash
# 1. Renderer dry-test
mkdir -p ~/.claude/progress && chmod 700 ~/.claude/progress
NOW=$(date +%s)
cat > ~/.claude/progress/test123.json <<EOF
{"schema_version":1,"prompt_started_at":$((NOW-120)),"last_tick":$NOW,"outer_command":"/plan","overall":{"done":4,"total":8,"label":"implementing","indeterminate":false},"current":{"cmd":"/plan","step":3,"total":4,"label":"reviewing","indeterminate":false,"source":"beacon"},"task_spawns":3}
EOF
bash ~/.claude/statusline.sh < <(echo '{"session_id":"test123","model":{"display_name":"Opus 4.7"},"workspace":{"current_dir":"'"$PWD"'"}}')
# Expected: line 1 normal, line 2 = spinner + 2:00 + two filled bars

# 2. Indeterminate (3-cell sliding)
cat > ~/.claude/progress/test123.json <<EOF
{"schema_version":1,"prompt_started_at":$NOW,"last_tick":$NOW,"outer_command":null,"overall":{"indeterminate":true,"label":"working"},"current":{"indeterminate":true,"label":"starting","source":"init"},"task_spawns":0}
EOF
bash ~/.claude/statusline.sh < <(echo '{"session_id":"test123"}')
# Expected: 3-cell sliding window animation on both bars

# 3. 5-min failsafe
cat > ~/.claude/progress/test123.json <<EOF
{"schema_version":1,"prompt_started_at":$((NOW-1000)),"last_tick":$((NOW-400)),"outer_command":"/plan","overall":{"done":1,"total":4,"label":"x","indeterminate":false},"current":{"indeterminate":true,"source":"init"},"task_spawns":0}
EOF
bash ~/.claude/statusline.sh < <(echo '{"session_id":"test123"}')
# Expected: bars hidden (last_tick > 5min ago)

# 4. Label fallback
rm ~/.claude/progress/test123.json
mkdir -p ~/.claude/session-status
echo "Internal › my-repo › testing" > ~/.claude/session-status/test123.txt
bash ~/.claude/statusline.sh < <(echo '{"session_id":"test123"}')
# Expected: dimmed label

# 5. Empty
rm ~/.claude/session-status/test123.txt
bash ~/.claude/statusline.sh < <(echo '{"session_id":"test123"}')
# Expected: line 1 only

# 6. Hook smoke test (no transcript = null outer_command, but file written)
echo '{"session_id":"hook-test","transcript_path":"/tmp/no-such-file"}' \
  | bash ~/.claude-dotfiles/scripts/progress/on-prompt-submit.sh
test -f ~/.claude/progress/hook-test.json && jq .outer_command ~/.claude/progress/hook-test.json
# Expected: file exists; outer_command is null (no regression for plain-text prompts)

# 7. Beacon helper
SESSION_ID=hook-test bash ~/.claude-dotfiles/scripts/progress/emit-beacon.sh 2 5 "testing"
jq . ~/.claude/progress/hook-test.current.json
# Expected: {"step":2,"total":5,"label":"testing"}

# 8. Settings.json valid
python3 -c "import json; json.load(open('$HOME/.claude/settings.json'))"
# Expected: no error

# 9. All retrofitted command files still parse (frontmatter sanity)
for f in plan implement god-review god-report master-review codex-review document afk supabase-audit; do
  python3 -c "
import re, sys
txt = open('$HOME/.claude-dotfiles/commands/$f.md').read()
m = re.match(r'^---\n(.*?)\n---', txt, re.S)
if not m: print('NO FRONTMATTER: $f'); sys.exit(0)
import yaml
y = yaml.safe_load(m.group(1))
print(f'$f expected_subagents: {y.get(\"expected_subagents\")}')
" 2>/dev/null
done

# Cleanup
rm -f ~/.claude/progress/{test123,hook-test}.json ~/.claude/progress/hook-test.current.json ~/.claude/session-status/test123.txt
```

### Factuality Checks

- All 14 retrofit MODIFY paths verified via `ls`. (`supabase-audit.md` and `codex-review.md` exist; `afk.md` exists.)
- 147 command count verified via `find ~/.claude-dotfiles/commands -name '*.md' | wc -l`.
- statusline.sh:269-288 verified via Read.
- settings.json hooks structure verified.
- CLAUDE.md "Per-Session Status Label" verified.

### Manual Checks

- Scenario: Type `/plan add feature X`. → bars + spinner + elapsed within 1-2 cycles. Todos created → Bar 1 fills. Plan-reviewers spawn → Bar 2 advances 1/3 → 2/3 → 3/3.
- Scenario: Type plain text. → bars indeterminate (NO REGRESSION).
- Scenario: Run any non-retrofitted command (e.g. `/dock`, `/transcribe`). → bars work; Bar 2 indeterminate (no frontmatter denominator) but Bar 1 + spinner + elapsed all functional.
- Scenario: Run namespaced `/parsa/review/all`. → outer_command captured correctly; Bar 2 hits 11/11.
- Scenario: Pause >30s. → bars yellow.
- Scenario: Claude finishes. → label or empty.

## Open Questions

- Frontmatter loader tolerance of `expected_subagents:` — flagged in Assumptions; verifiable per file. Worst case: drop the key from any file that breaks (no behavior impact beyond losing Bar 2 denominator for that command).

## Final Validation Checklist

- [ ] Renderer renders 2 bars from hand-written state
- [ ] 3-cell sliding indeterminate animation
- [ ] Stall yellow after 30s
- [ ] 5-min last_tick failsafe hides bars
- [ ] UserPromptSubmit creates state for slash AND non-slash prompts
- [ ] TodoWrite updates Bar 1 + last_tick
- [ ] Task updates Bar 2 + last_tick + atomic beacon claim
- [ ] Stop synchronously removes state + scratch
- [ ] SessionStart cleanup is separate array entry (existing command UNTOUCHED)
- [ ] emit-beacon.sh accepts SESSION_ID override
- [ ] CLAUDE.md + STATUSLINE.md updated
- [ ] 14 commands have `expected_subagents:`; 133 untouched
- [ ] **All 147 commands still load and execute identically (no behavior change)**
- [ ] Bars work for ANY command (retrofitted or not)
- [ ] settings.json valid JSON
- [ ] No `set -e`/`set -o pipefail` in any hook
- [ ] Plain-text prompts produce state file (no regression)

## Deprecated / Removed Code

- `~/.claude-dotfiles/scripts/statusline.sh:269-288` — replaced.
- No CLAUDE.md content removed.
- No commands removed.
- No `complete` schema field (Stop deletes; field unnecessary).

## Anti-Patterns to Avoid

- No ETA / rolling average — out of scope.
- No fake percentages.
- No `set -e` / `set -o pipefail` in hooks.
- No matcherless PostToolUse entry.
- No bash fence edits to existing commands.
- No string-concat onto existing SessionStart command — separate sibling entry.
- Hooks always exit 0.
- Don't kill the session label rule.
- Don't introduce a `complete` schema field.
- Don't retrofit all 147 commands — universal fallback handles them.

---

**Plan confidence: 9/10** for one-pass implementation. Universal architecture + minimal additive retrofit means even if 14 frontmatter additions all fail, the system still works for every command. Remaining risk: end-to-end hook event verification (mitigated by 5-min failsafe).
