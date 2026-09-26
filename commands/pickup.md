---
description: "Schedule this session to resume itself when your usage limit resets. /pickup [5:40pm | +90m] arms a one-shot resume for THIS tab (plus a 20-minute-later backup); with no argument it reads the cached rate-limit reset time. Esc out of a running task first, then run /pickup - once armed, it continues that task in the same turn. /pickup cancel removes this tab's jobs."
argument-hint: "[5:40pm | +90m | cancel]"
allowed-tools: Bash, Write, ToolSearch, CronCreate, CronList, CronDelete
---

# /pickup — auto-resume this session after the usage limit resets

Run this while you still have credits, right before (or right after) a usage-limit error stops
you. It schedules this tab to prompt itself once the limit resets, so you do not have to sit and
watch a clock. `CronCreate`/`CronList`/`CronDelete` are **deferred tools** — load them first with:

```
ToolSearch select:CronCreate,CronList,CronDelete
```

Do this once, before the first call to any of the three, in every branch below.

Arguments: `$ARGUMENTS`

## Step 1 — resolve the session, read prior state, compute the fire time

Run exactly this one Bash block. It resolves the session id the same way `/line` does
(`$CLAUDE_SESSION_ID` then `$CLAUDE_CODE_SESSION_ID`), prints any state this tab saved from a
previous `/pickup`, and — unless the argument is `cancel` — calls `pickup-time.py` to turn the
argument (or the cached rate-limit data) into a fire time. `"$ARGUMENTS"` is quoted so a spaced
argument like `5 pm` survives as one string.

```bash
set -uo pipefail

export CLAUDE_SESSION_ID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
SID="${CLAUDE_SESSION_ID:-nosid}"
mkdir -p "$HOME/.claude/pickup"
STATE="$HOME/.claude/pickup/$SID.json"
NOTE="$HOME/.claude/pickup/$SID.md"

echo "SID=$SID"
echo "STATE_FILE=$STATE"
echo "NOTE_FILE=$NOTE"
echo "PRIOR_STATE:"
if [ -f "$STATE" ]; then cat "$STATE"; else echo "none"; fi

ARG_NORM="$(printf '%s' "${ARGUMENTS:-}" | tr '[:upper:]' '[:lower:]' | sed -e 's/^ *//' -e 's/ *$//')"

if [ "$ARG_NORM" = "cancel" ]; then
  echo "MODE=cancel"
  rm -f "$NOTE"
  exit 0
fi

echo "MODE=schedule"
OUT=$(python3 "$HOME/.claude-dotfiles/scripts/pickup-time.py" "${ARGUMENTS:-}" 2>&1)
RC=$?
echo "PICKUP_TIME_RC=$RC"
echo "PICKUP_TIME_OUT=$OUT"
```

If `SID` came back `nosid`, the state/note files land under `nosid.json` / `nosid.md` instead of a
session id — the cron jobs still work, but a second tabless `/pickup` in the same shape would
collide with the first. Say so in the report; don't block on it.

## Step 2 — cancel path (`MODE=cancel`)

1. If `PRIOR_STATE` was not `none`, parse its `ids` array and call `CronDelete` on each.
2. Fallback, always run: `CronList`, then `CronDelete` any job whose `prompt` starts with the
   literal text `[pickup` — this catches jobs from a state file that was lost, renamed, or never
   written (e.g. an interrupted prior `/pickup`).
3. `rm -f` the state file (`STATE_FILE` from Step 1) via a small Bash call.
4. Report in one line: `Cancelled: removed N job(s) for this tab.` (N = ids deleted across both
   steps; N=0 → `Nothing to cancel — no pickup jobs found for this tab.`)
5. Stop. Do not continue any interrupted task after a cancel — cancelling is the whole request.

## Step 3 — schedule path (`MODE=schedule`)

If `PICKUP_TIME_RC` was not `0`: report `PICKUP_TIME_OUT` verbatim (it is already the one-line
error message) and **stop**. Nothing is scheduled, no cron jobs, no note file.

Otherwise `PICKUP_TIME_OUT` is a JSON object:
`{fire_epoch, fire_human, cron, backup_epoch, backup_human, backup_cron, source, warnings}`.

1. **Re-arm, not duplicate.** If `PRIOR_STATE` was not `none`, `CronDelete` its saved `ids` first.
   Then, always, `CronList` and `CronDelete` any job whose `prompt` starts with `[pickup` (the
   same fallback as the cancel path — covers a lost or pre-existing state file).
2. **Write the resume note** to `NOTE_FILE` (absolute path from Step 1), ≤10 lines, in your own
   words from the actual conversation so far:
   ```
   Goal: <one line>
   Where I am: <one or two lines>
   Next step: <one line>
   Key files: <paths, if any>
   ```
   If nothing in this session looks unfinished, write `Nothing in flight — /pickup was armed
   pre-emptively.` instead.
3. **Schedule two one-shot jobs**, both `recurring: false`, with `<note>` below replaced by the
   absolute `NOTE_FILE` path:

   MAIN (`CronCreate(cron=<cron from JSON>, recurring=false, prompt=...)`) → save as `id1`:
   > `[pickup] Automatic resume scheduled by /pickup. You most likely stopped because the Claude
   > usage limit ran out; it has reset now. This is not a new request from the user. Continue
   > exactly the work you were doing: your conversation above is intact, and your last turn was
   > probably cut off by the limit error. Resume note (written when /pickup was armed, so it may
   > be older than your last turn; live context wins): <note>. If you were not mid-task, reply
   > "pickup: nothing to resume" and stop.`

   BACKUP (`CronCreate(cron=<backup_cron from JSON>, recurring=false, prompt=...)`) → save as `id2`:
   > `[pickup backup] If a [pickup] resume already ran in this session and got a normal response,
   > reply only "pickup: already resumed" and stop. Otherwise treat this as the [pickup] resume:
   > <MAIN text after the tag>.`

   ("`<MAIN text after the tag>`" means the BACKUP prompt repeats the MAIN prompt's text starting
   from "Automatic resume scheduled by /pickup." — write it out in full; don't rely on the model
   receiving the backup prompt to have the MAIN prompt in view.)
4. **Save state.** `Write` `STATE_FILE` with
   `{"ids": [id1, id2], "fire_human": <fire_human>, "backup_human": <backup_human>}`.
5. **Report**, 4 lines or fewer, plus any warnings from the JSON's `warnings` array (one line each,
   prefixed `Warning:`):
   ```
   Armed: resumes at <fire_human> (backup <backup_human>). Source: <source>.
   Note: <NOTE_FILE>
   ```
6. **Continue the interrupted task.** If the turn immediately before this `/pickup` call was
   interrupted mid-task (you were cut off — by Esc, by the usage limit, or otherwise — while doing
   something), resume that work now, in this same turn, right after the report above. If nothing
   was interrupted, the report from step 5 is the whole response.

After a resume prompt (`[pickup]` or `[pickup backup]`) gets a normal response and the model has
actually picked the work back up (not the "nothing to resume" / "already resumed" short-circuits),
delete both `<sid>.md` and `<sid>.json` for this session — the prompts above say this explicitly,
but do it as an explicit step: the jobs already fired and won't fire again (`recurring: false`),
so the files are stale from that point on.

## Limits

- **Per tab.** `/pickup` only knows about the session it runs in. Two tabs need two `/pickup` calls.
- **Lost if the tab closes, the app restarts, or the Mac goes to sleep or shuts down before the
  fire time.** Cron jobs here are session-only and in-memory — nothing persists them.
- **One-shots only fire while this tab is idle.** A job that comes due while you're mid-conversation
  fires at the next idle moment, not necessarily on the second.
- **Running `/pickup` after the limit has already hit costs credits you don't have.** Arm it
  *before* you hit the wall, ideally as soon as you notice usage climbing.
- **`:00`/`:30` explicit times may fire up to 90s early** (a `CronCreate` quirk); the 20-minute
  backup exists mainly to cover this and a missed idle window, not to hedge a wrong reset time.
- **Weekly-limit resumes are days out.** They only work if this exact tab stays open and the Mac
  stays on the whole time — `pickup-time.py` warns about this, and the report should carry the
  warning forward, not silently drop it.
