# RESOLVED: `claude` startup hang (blank screen) — root cause was `$HOME` being a git repo

> **CORRECTION:** an earlier version of this file blamed the `/pre-compact` SessionStart
> `git pull` hook. That was WRONG — ruled out by testing. The real cause is below.
> Fixed 2026-05-25.

## Symptom
`claude` → totally blank screen + blinking cursor, hangs ~1 minute, then sometimes
renders. From any directory / fresh terminal.

## CONFIRMED root cause (via `sample` on the hung process)
Claude Code runs **`git --no-optional-locks status --short` in the launch directory
at startup** (to build its context block). The user's **`$HOME` (`/Users/omidzahrai`)
was itself a stray git repo** — `git remote` = `connect-crm`, ~14 tracked files, an
accidental checkout. So launching from a fresh terminal (cwd = `$HOME`) made
`git status` scan the **entire home tree, including the iCloud-wedged `~/Desktop`**,
which took ~60s. The blank screen was Claude's event loop idling in `kevent64`
waiting on that child `git status` process. It "loaded" only after git status
eventually finished.

## How it was proven (diagnostic playbook — reuse this)
1. `claude --version` → fine (not the binary). Config JSON valid. Shell init 0.9s.
2. `CLAUDE_CONFIG_DIR=/tmp/clean claude` → renders fine ⇒ it's in `~/.claude` profile.
3. Subtracting individual settings (MCP, SessionStart hooks, remoteControl,
   pushNotif, plugin) → NONE fixed it ⇒ not those.
4. **Decisive:** launch claude, LEAVE IT HUNG (no Ctrl+C). Then from another shell:
   - `ps -eo pid,etime,command | grep claude | sort -k2 | head` → youngest = hung PID.
   - `sample <pid> 3 -file /tmp/sample.txt` → main thread idle in `kevent64` (waiting on async).
   - `pgrep -P <pid>` → revealed child `git --no-optional-locks status --short` (held ~57s).
   - `lsof -nP -p <pid>` → only normal API sockets; the git child was the blocker.

## THE FIX (applied)
```
mv ~/.git ~/.git-DISABLED
```
`$HOME` is no longer a git repo ⇒ startup `git status` there returns instantly ⇒
claude opens fast from any folder. Reversible (`mv ~/.git-DISABLED ~/.git`). Deletes
nothing; connect-crm history is on GitHub; the dotfiles auto-sync uses the SEPARATE
`~/.claude-dotfiles` repo, so it is unaffected.

## Note for a future agent
- The `/pre-compact` SessionStart `git pull` hook is NOT the cause, but it IS still
  `async:false` and does a synchronous network git-pull on startup — worth making
  `async:true` / hard-bounded as a robustness improvement (it can add a few seconds
  on a slow network), but it does not blank the screen.
- The underlying amplifier was the iCloud-wedged `~/Desktop` making file stats slow
  (see the dentalai memory `project_icloud_sync_corruption`). Any tool that does a
  recursive `git status` / file walk over a tree containing the wedged Desktop will
  crawl until iCloud is healthy. Keeping dev repos out of `~/Desktop` (off iCloud)
  avoids this class of problem.
