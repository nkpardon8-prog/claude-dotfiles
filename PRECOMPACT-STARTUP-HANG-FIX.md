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

---

# 2026-05-29 — SECOND occurrence, DIFFERENT cause (`$HOME`-git fix was still holding)

## Symptom (recurrence)
`claude` in a fresh terminal → press enter → nothing loads / hangs, intermittently.
Same surface symptom as the original, but the user was already working entirely from
the LOCAL (off-iCloud) `~/Developer/CODEBASES/...` copy.

## What was RULED OUT (all still fixed from the original)
- `~/.git` is ABSENT (the `mv ~/.git ~/.git-DISABLED` fix held; `~/.git-DISABLED` still present).
- `git status` at `$HOME` = ~19ms; inside the local repo = ~39ms. Not a git-walk hang.
- `claude --version` = 52ms; binary at `~/.local/bin/claude` -> `~/.local/share/claude/versions/...`
  (off iCloud). `~/.claude` is a real dir (not a symlink), no iCloud xattrs, 0 `.icloud` stubs.
- No MCP server in `~/.claude.json` points at an iCloud or dead path.
- `~/.zshrc` does not source anything on Desktop/Documents/iCloud.

## The TWO actual contributors this time
1. **Synchronous startup `git pull` hook (the real fix).** `~/.claude/settings.json`
   `SessionStart[0].hooks[0]` ran `cd ~/.claude-dotfiles && git pull --ff-only` with
   **`async` UNSET (= blocking)** and `timeout=10`. It blocks the launch screen until the
   network git-pull returns (measured 1.8–2.5s on a good network; up to the full 10s on a
   slow/offline one). This is the intermittent "nothing happens" with no other cause present.
   **FIX APPLIED 2026-05-29:** set `async: true` on that hook (Python-edited the JSON; backup
   at `~/.claude/settings.json.bak-launchfix-<ts>`). The pull now runs in the background; the
   TUI renders immediately. This is exactly the robustness improvement the note above predicted.
2. **RAM saturation (amplifier, not a hard block).** 16 GB physical RAM, ~9–10 concurrent
   `claude --dangerously-skip-permissions` TUI instances, **swap 8.6 GB used / 1.6 GB free**.
   A new launch pages a fresh ~200MB+ Node process against nearly-full swap → tens of seconds
   to render. NOT a hard block (the user correctly pushed back: low RAM slows, doesn't prevent),
   but it compounds contributor #1. Mitigation: close idle instances (Ctrl-C/exit, not kill -9);
   a comfortable count on 16 GB is ~3–4 concurrent.

## Diagnostic playbook addition (reuse)
- `pgrep -x claude | wc -l` (instance count) + `sysctl -n vm.swapusage` (swap pressure) — if
  swap "used" is most of total and instances are many, that's the amplifier.
- Audit SessionStart hooks: `async` UNSET on any network/git command = blocks the launch screen.
  Make them `async:true`. Check `~/.claude/settings.json` -> `.hooks.SessionStart[].hooks[]`.
