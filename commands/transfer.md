---
description: "Move this chat to your other Mac. Prints a one-time code; run resumework <code> in Terminal there and the same chat reopens with its history, files and worktree."
argument-hint: "[codex <session-id>] [--dry-run]"
allowed-tools: Bash, Skill, Read, Write, Edit, CronList, CronDelete, TaskStop
---

# /transfer - move a live chat to your other Mac

`/transfer` packs THIS Claude Code chat (or, with `codex <id>`, a closed Codex chat) into one
encrypted file in iCloud Drive and prints a code like `TX-XXXX-XXXX-XXXX-XXXX`. On the other Mac the
owner types `resumework <code>` in Terminal and the same chat reopens: verbatim history, `/line` name,
handoff and mission files, and the git worktree (unpushed commits, uncommitted edits, untracked files).
Running things (servers, containers, background tasks, scheduled wakes) do NOT move; they are
written down so the new Mac can restart them.

This is a planned move: this Mac must be healthy enough to finish the steps below.
The heavy lifting lives in tested scripts under `~/.claude-dotfiles/scripts/transfer/`; this file
only orders the steps.

**Talking to the owner:** plain words, no jargon. Say "your other Mac", "the code", "this window".

**Arguments:** `$ARGUMENTS` arrives as one string. If it was not substituted (for example when this
runs as a Codex skill), use the words you were given in its place.
- nothing: move THIS Claude chat.
- `codex <session-id>`: move that Codex chat instead (see "Codex path").
- `--dry-run`: show what would be sent; write, park and release nothing.
- `--sid <id>`: override the session id read from the environment.

## Step 1 - Preflight (every path)

```bash
set -uo pipefail
set -f; set -- ${ARGUMENTS:-}; set +f
MODE=claude; DRY=""; SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
while [ $# -gt 0 ]; do
  case "$1" in
    codex)     MODE=codex; SID="${2:-}"; [ $# -gt 1 ] && shift ;;
    --sid)     SID="${2:-}"; [ $# -gt 1 ] && shift ;;
    --dry-run) DRY=--dry-run ;;
    *) echo "transfer: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$SID" in ''|*[!A-Za-z0-9_-]*) echo "transfer: no usable session id (got '${SID}')" >&2; exit 2 ;; esac
[ "${#SID}" -le 128 ] || { echo "transfer: session id too long" >&2; exit 2; }
. "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-locate.sh"
ROOT="$(handoff_canonical_root)"
if [ "$MODE" = claude ]; then
  case "$(cd "$ROOT" && pwd -P)/" in "$(cd "$HOME/.claude-dotfiles" && pwd -P)/"*)
    echo "transfer: REFUSED - this chat's project is the public dotfiles repo; nothing may be written there" >&2; exit 2 ;;
  esac
fi
# The chat's own launch folder (claude --resume needs it) - from the session registry, else $PWD.
CWD=""
for f in "$HOME"/.claude/sessions/*.json; do
  [ -f "$f" ] || continue
  [ "$(jq -r '.sessionId // empty' "$f" 2>/dev/null)" = "$SID" ] && { CWD="$(jq -r '.cwd // empty' "$f")"; break; }
done
[ -n "$CWD" ] || CWD="$PWD"
echo "MODE=$MODE SID=$SID DRY=${DRY:-no} ROOT=$ROOT CWD=$CWD"
"$HOME/.claude-dotfiles/scripts/transfer/transfer-doctor" --local; echo "doctor_rc=$?"
```

- Carry the printed `SID`, `ROOT` and `CWD` values as literals into every later step (each Bash
  call is a fresh shell).
- If the block exits non-zero, `doctor_rc` is not 0, or any line says FAIL: STOP. Tell the owner, in
  one or two plain sentences per item, what is not ready and how to fix it. Change nothing.
- No session id in `claude` mode (for example running as a Codex skill with no `codex <id>`): stop
  and explain that a Codex chat is moved with `/transfer codex <id>` (see below).

**`--dry-run` on either path:** run the Step 5 or Codex send command with `--dry-run` added (no
`--seal-after-exit`), relay what it lists, and stop. Skip everything else. A line "A real run would
refuse: no handoff ..." is expected here (a dry run skips Step 2) and is not a problem; any
"A real run would REFUSE" at the end is.

## Step 2 - Fresh handoff (Claude path)

Invoke the Skill tool: `skill: pre-compact`, args `no-document no-auto-compact no-gitignore auto-confirm`.
Let it run to completion. If it reports a FATAL, an unverified END-OF-HANDOFF marker, or no handoff
written, STOP and tell the owner the chat was not moved.

## Step 3 - Write the transfer notes (Claude path)

Gather facts first; do not guess:

```bash
CWD="<CWD>"
docker ps --format '{{.Names}}  {{.Image}}  {{.Status}}' 2>&1 | head -20
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $1, $2, $9}' | sort -u | head -30
lsof -nP -iTCP:9222 -sTCP:LISTEN 2>/dev/null | head -3
ls -ld "$HOME/.claude/prod.lock" 2>&1
find "$CWD" -maxdepth 3 \( -name node_modules -prune -o -name '.env*' -print \) 2>/dev/null | grep -v node_modules
find "$CWD" -maxdepth 3 -type d -name node_modules -prune 2>/dev/null
```

Then use the Write tool to create (or overwrite) `<ROOT>/TRANSFER.<SID>.md`. Names only, never a
secret value. The send script does not edit this file; `resumework` appends a "Restored on this
Mac" record (what it copied, checksums, how git moved) when the chat arrives on the other Mac.

```markdown
# Transfer notes - <SID>
Written <local date and time> on <this Mac's name> by /transfer.

## Left behind on this Mac
- Background tasks, scheduled wakes, Monitors: <each one, what it was for; or "none">
- Docker containers: <from docker ps; or "none">
- Dev servers and ports: <from lsof; or "none">
- Chrome on port 9222: <running or not>
- Open peer conversations: <window name, what was asked, what we are waiting for>
- Prod lock: <held by this chat or not>
- Anything else running: <or "none">

## Restart checklist on the new Mac
- [ ] Reload credentials by file NAME (the files were not copied): <each .env / creds file path>; use /load-creds
- [ ] `npm ci --legacy-peer-deps` in: <each folder that had node_modules>
- [ ] `npx prisma generate` from the repo root <if this project uses Prisma>
- [ ] Docker test database <if needed>; always remove with `docker rm -f -v`
- [ ] Mission <if active>: answer its "transferred" question to unpark it, then re-schedule its wake
- [ ] Re-open peer conversations: <who, about what>
- [ ] Restart: <each server / container / background task above that is still needed>
- [ ] prod-ledger is machine-local - check `prod-ledger.py show` on the old Mac before any prod work
```

## Step 4 - Stop this chat's own timers and park the mission (Claude path)

- CronList; CronDelete every job THIS chat created. Schedule no new wake: one already scheduled
  only fires while this window is open, so closing it ends that too.
- Stop background tasks and Monitors you started (already listed in the notes).
- If a mission is active, put it in a human park so nothing advances it here:

```bash
. "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"; mission_resolve_path "<SID>" "<ROOT>"
```

  Non-empty output means active. Read its current part, round, attempt and phase the way
  `/mission status` does (mission.md §H resume read), then:

```bash
q=$(cat <<'Q'
This chat was moved to another Mac with /transfer. Answer here, on the Mac it now runs on, to continue the mission.
Q
)
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh pending-stop <SID> <ROOT> transferred <part> <round> <attempt> <phase> "$q"
```

  If it refuses (for example a decision is already waiting), leave it: the mission is already
  stopped. Add one line about it under "Left behind" in the notes.

## Step 5 - Send (Claude path)

```bash
"$HOME/.claude-dotfiles/scripts/transfer/transfer-send.sh" --tool claude --sid "<SID>" --cwd "<CWD>" --seal-after-exit; echo "send_rc=$?"
```

It prints `CODE=TX-...` and `LOCATOR=...` (the locator is for logs; do not show it). On a non-zero
`send_rc` (2 = refused, reason on stderr): tell the owner plainly why, say that nothing was sent and
the chat is still here, and that if the mission was parked, answering its question here resumes it.
Do NOT continue to Step 6.

## Step 6 - Hand over (Claude path)

Show the code in a fenced block:

```
On the Mac mini, in Terminal:
resumework <CODE>
```

Add in plain words: the chat is packed the moment this window closes; `resumework` waits for it;
the code works once, and together with your iCloud it opens the chat, so keep it to yourself.

Then, as the LAST command (it lifts the mission's "don't stop" guard so the window can close):

```bash
rm -f "$HOME/.claude/progress/mission-liveness-<SID>.json"
```

Tell the owner exactly: "Type /exit now. The bundle is sealed the moment this window closes."
After that line, run nothing else and write no mission state.

## Codex path (`/transfer codex <session-id>`)

1. Tell the owner: "Close that Codex chat first (type /exit in it or close its Terminal tab), then
   tell me it is closed." Wait for their answer. Do not send while it may still be open.
2. Send (no handoff step, no seal-after-exit):

```bash
"$HOME/.claude-dotfiles/scripts/transfer/transfer-send.sh" --tool codex --sid "<SID>"; echo "send_rc=$?"
```

3. Handle `send_rc` as in Step 5, then show the code block from Step 6. This window stays open;
   there is nothing to release here.

If you ARE Codex running this as a skill: the chat being moved must be a different, already closed
Codex chat, never the one running this. To move the chat you are in, the owner closes it and runs
`~/.claude-dotfiles/scripts/transfer/transfer-send.sh --tool codex --sid <id>` in Terminal, or runs
`/transfer codex <id>` from a Claude window.
