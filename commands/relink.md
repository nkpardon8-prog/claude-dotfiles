---
description: "Reconnect Remote Control in every /line-named window on this Mac (and ask the other Mac to do the same) so the Claude app shows each window under its /line name."
argument-hint: "[--only NAME ...] [--here-only]"
allowed-tools: Bash, SendMessage
---

# /relink - put every window on Remote Control under its /line name

Run once after switching Claude accounts, or whenever the Claude app shows windows under wrong names.

## Why it works this way
The Claude app shows a Remote Control session under the name it was CONNECTED with. `/rename` does not
reach it, and `/rc NAME` while already connected does nothing. A disconnect (`/remote-control` while
connected) followed by `/rc NAME` creates a fresh session with the right name, and it overrides a name
set by hand in the app (proven 2026-11-11 on the MacBook Air).

## Steps
1. Show the plan: `python3 ~/.claude-dotfiles/scripts/relink.py --dry-run` (pass through any `--only`).
   Windows without a /line name, or not in Terminal.app, are listed as skipped.
2. Run it in the BACKGROUND (Bash `run_in_background: true`, never `&`):
   `python3 ~/.claude-dotfiles/scripts/relink.py [--only NAME ...]`
   It types only into IDLE windows (never mid-task, never over a permission prompt), waits up to 45 min
   for busy ones, and confirms each reconnect from the window's session file. This window is relinked
   too, once this turn ends and it goes idle.
3. Other Mac (skip with `--here-only`): typing into another Mac's Terminal over ssh is blocked by macOS,
   so the script must run THERE. Send one message to a named window on the other Mac (find one with
   `python3 ~/.claude-dotfiles/scripts/line-agent-communicator.py list`), asking it to run steps 1-2 and
   reply with its result table. If `list` says the other Mac is on a DIFFERENT claude.ai account, say so:
   its windows will show in that account's app, not this one, until it signs into the same account.
4. When the background run finishes, show the user its table: each window, relinked or why not.
