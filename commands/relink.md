---
description: "Reconnect Remote Control in every /line-named window on this Mac (and ask the other Mac to do the same) so the Claude app shows each window under its /line name."
argument-hint: "[--only NAME ...] [--here-only]"
allowed-tools: Bash, SendMessage
---

# /relink - put every window on Remote Control under its /line name

Run it after switching Claude accounts, after opening or renaming windows with /line, or whenever the
Claude app shows wrong names. Safe to run any time: it remembers the Remote Control session it made for
each window (~/.claude/relink-state.json) and skips windows already linked under their current name, so
only new, renamed, or re-connected windows are touched (`--force` redoes all). Locks are per window, so runs never type into the same window.

## Usually you do not need it
Every Mac carries a Stop hook (`relink.py --heal`, installed by line-ensure-settings.py at session
start): when a /line-named window finishes a turn and is not on Remote Control under its name - a new
window after /line, a rename, a /resume, a Pane restore, an account switch - it relinks itself once it
is idle. /relink is the manual sweep for everything at once, or for a window that never finishes a turn.

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
3. Other Mac (skip with `--here-only`): run the same script there over ssh, also in the background:
   `ssh <host> 'PATH=/opt/homebrew/bin:$PATH; python3 ~/.claude-dotfiles/scripts/relink.py'`
   (`git -C ~/.claude-dotfiles pull --rebase -q` there first if it lacks the script). Hosts: Nick's Mac
   mini = `nickmini-docker`. Over ssh only Pane windows can be typed into (`runpane panels input`); macOS
   blocks AppleScript control of Terminal from an ssh login, so Terminal windows there are listed as
   skipped - ask a window on that Mac to run this command for those. If `line-agent-communicator.py list`
   says that Mac is on a DIFFERENT claude.ai account, tell the user: its windows show in that account's
   app until it signs into the same account.
4. When the background run finishes, show the user its table: each window, relinked or why not.
