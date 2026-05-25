# FIX BRIEF: `/pre-compact` SessionStart hook hangs `claude` startup (blank screen)

> For a fresh agent: this documents a startup-hang bug introduced by the
> `/pre-compact` + ctx-gate hook system. **Goal: stop the hang WITHOUT removing
> `/pre-compact` functionality** (auto-compact, primer/resume, ctx-gate). Written
> 2026-05-25 after a long live diagnosis. Source of truth for hooks = this repo
> (`~/.claude-dotfiles`), which auto-syncs to `~/.claude`.

## Symptom
Typing `claude` in a terminal → **totally blank screen, blinking cursor, never
renders the TUI.** Happens from any directory, including fresh terminals. Started
after the `/pre-compact` / ctx-gate hook stack was installed in
`~/.claude/settings.json`.

## Diagnosis (already done — all confirmed live)
Ruled OUT (each verified):
- Binary fine: `claude --version` → `2.1.150` instantly.
- `~/.claude.json` and `~/.claude/settings.json` are valid JSON.
- Shell init (conda) = 0.9s — not the cause.
- Global MCP servers (`chrome-devtools`, `supabase`) removed from `~/.claude.json`
  → did NOT fix the hang (so MCP is not it).
- CWD git-status is fast in a normal repo (the wedged-iCloud `~/Desktop` is a
  separate, already-handled problem — see memory `project_icloud_sync_corruption`).
- Each SessionStart hook, run in isolation with realistic stdin + a 12s cap, exits
  0 — none hangs by itself.

**Decisive isolation:** `CLAUDE_CONFIG_DIR=/tmp/claude-clean-test claude` (a throwaway
config dir with NO hooks/settings/MCP) **renders fine.** Therefore the hang is 100%
in `~/.claude` config — specifically the **SessionStart hooks**, which Claude runs
(the `async:false` ones serially) and BLOCKS the first UI render until they return.

## The SessionStart hooks (in `~/.claude/settings.json` → `hooks.SessionStart`)
1. **`cd ~/.claude-dotfiles && git pull --ff-only ...; <credentials-grep>; true`**
   — `async:false, timeout:10`. **PRIME SUSPECT.** Does a NETWORK `git pull` on
   EVERY session start, synchronously, gating the UI. On a degraded/slow/offline
   network, or under git-lock contention (many concurrent `claude` instances + the
   PostToolUse `dotfiles-sync.sh` auto-commit/push all hit `~/.claude-dotfiles/.git`),
   this stalls and the screen stays blank. (It returns fast when run by hand on a
   healthy network — so the bug is environmental/timeout-enforcement, not the script
   logic.)
2. **`post-compact-primer.sh`** — `async:false, timeout:5`. Injects resume/handoff
   context; reads the session JSON on stdin. Must remain synchronous (SessionStart
   context injection has to be sync to add to the model context). Verify it cannot
   block; it already has timeout 5.
3. **`on-session-start-cleanup.sh`** — `async:true` (non-blocking; fine).

## Root cause (most likely)
Hook #1 (`git pull`) is `async:false`, so Claude waits for it before drawing the UI.
A synchronous network op at startup is the wrong design — when the network is slow
or git is lock-contended, it blocks the whole TUI. The other instances + dotfiles
auto-sync make lock contention on `~/.claude-dotfiles/.git` likely. Whether Claude
Code actually hard-kills at the `timeout:10` is suspect (the observed hang is longer
than 10s of patience).

## FIX (do NOT delete the hooks — keep all `/pre-compact` features)
1. **Make the dotfiles `git pull` non-blocking.** Best: move it OUT of a
   `async:false` SessionStart hook into the existing `async:true`
   `on-session-start-cleanup.sh` (which already runs non-blocking), OR set that
   SessionStart entry to `async:true`. The auto-sync `git pull` is a background
   convenience and must NEVER gate the UI.
2. **Hard-bound it regardless.** Wrap the git op so it self-kills:
   `perl -e 'alarm 8; exec @ARGV' git -C ~/.claude-dotfiles pull --ff-only` (or
   `timeout 8 ...` if coreutils `gtimeout`/`timeout` is available — note macOS has no
   bare `timeout`). Also add `git -c gc.auto=0` and avoid blocking on locks
   (`--no-optional-locks`), and consider skipping the pull entirely when offline.
3. **Leave the primer (#2) synchronous** but confirm it never blocks (bounded stdin
   read `head -c 1048576` is fine; its libs must not do unbounded git/network).
4. Apply the change in THIS repo (`~/.claude-dotfiles`) — both the
   `settings.json` template that seeds `~/.claude/settings.json` AND, if the hook
   command lives inline in settings, update it there. Then re-sync to `~/.claude`.

## Verify the fix
- Before: normal `claude` → blank hang.
- `CLAUDE_CONFIG_DIR=/tmp/claude-clean-test claude` → renders (control).
- Removing `hooks.SessionStart` from `~/.claude/settings.json` → normal `claude`
  renders (proves it's a SessionStart hook).
- After fix (git pull made async/bounded): normal `claude` renders immediately even
  with the network throttled (test by temporarily blocking GitHub, e.g. unplug wifi).

## Interim workaround for the human (until fixed)
Either:
- `CLAUDE_CONFIG_DIR=/tmp/claude-clean-test claude` (works now; needs re-login; no
  hooks/MCP), OR
- Back up + remove SessionStart hooks:
  `cp ~/.claude/settings.json ~/.claude/settings.json.bak`
  `python3 -c "import json,os;p=os.path.expanduser('~/.claude/settings.json');d=json.load(open(p));d.get('hooks',{}).pop('SessionStart',None);json.dump(d,open(p,'w'),indent=2)"`
  (restore: `cp ~/.claude/settings.json.bak ~/.claude/settings.json`)

## Files
- Hook registration: `~/.claude/settings.json` (synced copy) + the seed/template in
  this repo (`~/.claude-dotfiles`).
- Hook scripts: `~/.claude-dotfiles/scripts/hooks/` and `~/.claude-dotfiles/scripts/progress/`.
- `/pre-compact` skill: `~/.claude-dotfiles/commands/` (do not regress it).
