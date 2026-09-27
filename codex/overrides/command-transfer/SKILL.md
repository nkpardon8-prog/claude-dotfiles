---
name: claude-command-transfer
description: >-
  Use when the user invokes $claude-command-transfer, $transfer or /transfer, or asks to move, send
  or hand this Codex chat over to their other Mac. Prints a one-time code; on the other Mac
  `resumework <code>` (or the Resume Chat app) reopens this same Codex chat with its history, files
  and worktree. The bundle seals itself after this Codex chat is closed.
metadata:
  short-description: "Move this Codex chat to your other Mac"
---

# /transfer - move THIS Codex chat to your other Mac

Hand-written Codex skill (source: `codex/overrides/command-transfer/SKILL.md` in
`~/.claude-dotfiles`; it replaces the automatic port of the Claude `/transfer` command, whose steps
only work inside Claude Code). It packs the chat you are in right now into one encrypted file in
iCloud Drive and prints a code like `TX-XXXX-XXXX-XXXX-XXXX`. The owner then closes Codex, the file
seals itself, and on the other Mac `resumework <code>` reopens this same chat - full history,
uncommitted edits, unpushed commits, and every untracked or ignored file in the project (including
`.env` and credential files; they travel inside the encrypted file).

**Talking to the owner:** plain words, no jargon. Say "your other Mac", "the code", "this chat".
Never show the LOCATOR line, never paste a secret value.

**Arguments:** text after `/transfer` or `$transfer`. Two are understood. `--dry-run`: show what would
be sent and stop (Step 3 with `--dry-run` in place of `--seal-after-exit`; skip Steps 2 and 4).
`--full`: add `--full` to the Step 3 send, so every untracked/ignored repo file travels again even if
the other Mac already has it (normally a later send leaves those out). To
move a DIFFERENT, already closed Codex chat, use `/transfer codex <id>` from a Claude window instead.

## Step 1 - Check where we are

Run this (the normal sandbox is fine):

```bash
SID="${CODEX_THREAD_ID:-}"
case "$SID" in ''|*[!A-Za-z0-9_-]*) echo "transfer: no usable Codex chat id (CODEX_THREAD_ID='${SID}')" >&2; exit 2 ;; esac
. "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-locate.sh"
ROOT="$(handoff_canonical_root)"
case "$(cd "$ROOT" && pwd -P)/" in "$(cd "$HOME/.claude-dotfiles" && pwd -P)/"*)
  echo "transfer: REFUSED - this chat works inside the public dotfiles repo; nothing may be sent from there" >&2; exit 2 ;;
esac
echo "SID=$SID ROOT=$ROOT CWD=$PWD"
docker ps --format '{{.Names}}  {{.Image}}  {{.Status}}' 2>&1 | head -20
lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $1, $2, $9}' | sort -u | head -30
find "$PWD" -maxdepth 3 -type d -name node_modules -prune 2>/dev/null
```

- Carry the printed `SID`, `ROOT` and `CWD` as literal values into the later steps.
- If it exits non-zero, stop and tell the owner in one plain sentence why (no chat id means this is
  not running inside a Codex chat; the dotfiles refusal means this project cannot be moved).
- `docker` / `lsof` output that says "not permitted" or is empty just means "could not check"; write
  that in the notes rather than guessing.

## Step 2 - Write the transfer notes

Create (or overwrite) `<ROOT>/TRANSFER.<SID>.md` with your file-editing tool. If the sandbox blocks
the write (ROOT can sit outside this chat's folder), write it with escalated permissions. Names
only, never a secret value. No other handoff document is needed: Codex's own chat log travels in
full and carries the whole history.

```markdown
# Transfer notes - <SID>
Written <local date and time> on <this Mac's name> by the Codex /transfer skill.

## What was in progress
- <the task, where it stands, and the very next step - 3 to 6 short lines>

## Left behind on this Mac
- Background commands or long-running jobs started in this chat: <each one; or "none">
- Docker containers: <from docker ps; or "none" / "could not check">
- Dev servers and ports: <from lsof; or "none" / "could not check">
- Anything else running: <or "none">

## Restart checklist on the new Mac
- [ ] Logins that live outside the project (not moved): <e.g. gcloud, `codex login`, shell-exported keys; or "none">
- [ ] `npm ci --legacy-peer-deps` in: <each folder that had node_modules; or "none">
- [ ] `npx prisma generate` from the repo root <only if this project uses Prisma>
- [ ] Restart: <each server / container / job above that is still needed>
```

## Step 3 - Send (needs escalated permissions)

Run this ONE command **with escalated permissions** (outside the sandbox): it has to look at running
processes and write into iCloud Drive, which the sandbox blocks. Tell the owner in one line that you
are asking for permission to pack the chat, then request it:

```bash
TX="$HOME/.claude-dotfiles/scripts/transfer"
if DOC=$("$TX/transfer-doctor" --local 2>&1); then
  bash "$TX/transfer-send.sh" --tool codex --sid "<SID>" --cwd "<CWD>" --seal-after-exit; echo "send_rc=$?"
else
  printf '%s\n' "$DOC" | grep FAIL; echo "send_rc=not-run (readiness check failed)"
fi
```

- It prints `CODE=TX-...` and `LOCATOR=...` right away; the packing itself happens later, after this
  chat closes. A "secret scan: ... hit(s)" line is FYI only.
- `send_rc=not-run` with `FAIL` lines: this Mac is not ready; explain each FAIL plainly. Nothing was sent.
- A non-zero `send_rc` (2 = refused, the reason is on the line before): tell the owner plainly why
  and that nothing was sent; this chat is untouched. If the reason is the size limit (untracked and
  ignored files over 5 GB), run the same command with `--dry-run` instead of `--seal-after-exit`,
  show the 10 largest items, and only on the owner's yes re-run Step 3 with `--force` added.
- If it was denied permission, say that the chat cannot be packed without it and stop.

## Step 4 - Hand over

Show the code in a fenced block, then the closing instructions, in these plain words:

```
On your other Mac:
resumework <CODE>
(or double-click the Resume Chat app on the Desktop and type the code)
```

"Now close this Codex chat: type /quit (or press Ctrl-C twice). The chat is packed a minute or so
after it closes, and `resumework` on the other Mac simply waits for it. The code works once and,
together with your iCloud, opens this chat, so keep it to yourself."

After that, run nothing else in this chat: anything said after the code was printed still travels,
but work started now would be cut off when the chat closes.
