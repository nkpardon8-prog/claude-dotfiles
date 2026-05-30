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

---

# 2026-05-29 (PM) — THE ACTUAL ROOT CAUSE: MCP `npx …@latest` network spawn on every launch

## The tell that cracked it
**Codex CLI opens instantly; Claude Code hangs.** Both are Node CLIs, so the machine / Node / RAM
are NOT the difference. The difference: Claude Code spawns its configured **MCP servers** at launch;
Codex spawns none. So the hang lives in MCP startup.

## Root cause (confirmed)
`~/.claude.json` configured both MCP servers as `npx -y <pkg>@latest …`:
- `chrome-devtools` → `npx -y chrome-devtools-mcp@latest …`
- `supabase` → `npx -y @supabase/mcp-server-supabase@latest …`

`@latest` forces `npx` to hit the npm registry **on every launch** to re-resolve "latest". On a
slow/flaky/offline network that stalls for many seconds (~8.7s measured for chrome-devtools even when
it eventually worked) and the TUI does not render until the MCP handshake proceeds. Intermittent
network = intermittent "type claude, press enter, nothing happens." NOT $HOME-git (still fixed), NOT
iCloud (still fixed), NOT RAM (amplifier only).

## THE FIX (applied 2026-05-29 — the permanent "never again")
Eliminated `npx` AND `@latest` from the launch path entirely:
1. **Global-installed both MCP servers, pinned:** `npm i -g chrome-devtools-mcp@1.1.1
   @supabase/mcp-server-supabase@0.8.1` (Homebrew node prefix `/opt/homebrew`).
2. **Rewrote every MCP server in `~/.claude.json`** (global + per-project) from `command:"npx",
   args:["-y","<pkg>@latest",…]` to **absolute node + absolute entry script:**
   - chrome-devtools → `/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js …`
   - supabase → `/opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@supabase/mcp-server-supabase/dist/transports/stdio.js …`
   Result: **zero npx, zero @latest, zero network** at launch — node execs a local file. Can't hang.
   Verified `npx-in-file=0`, `@latest-in-mcp=0`, both entry files exist + run `--version` rc=0.
3. **`brew pin node`** so a future `brew upgrade` can never churn the node those MCP paths point at.
4. Backup of the pre-fix config: `~/.claude.json.bak-mcpfix-<ts>`.

## Node-environment audit (done 2026-05-29, recorded so it isn't re-investigated)
There is **NO version-manager mess** (the natural next suspect — ruled out):
- `.zshrc` loads **no nvm / fnm / asdf / volta** (just anaconda + `~/.local/bin` on PATH).
- Node is **single + identical everywhere**: `v25.6.0` (Homebrew, now pinned) in interactive +
  non-interactive shells, hooks, MCP, and every cwd. No per-dir switching, no `.nvmrc`/`.node-version`.
- A dormant `/usr/local/bin/node` (v24) sits at lower PATH priority; nothing uses it. Left alone.
- `claude` is a **standalone Mach-O arm64 binary** (`~/.local/bin/claude` → `~/.local/share/claude/versions/<v>`)
  — node version cannot affect whether it launches. So we did NOT install fnm / downgrade node
  (user constraint: do not disturb other parts of the machine). There was nothing to consolidate.

## Diagnostic playbook (fast path next time)
1. Does **Codex** (or any non-MCP Node CLI) open instantly while Claude hangs? → it's MCP, not the machine.
2. `grep -c '"npx"' ~/.claude.json` + grep `@latest` → any hit = a per-launch network resolve = the bug.
3. Fix = global-install the MCP pkg pinned + point config at `node <abs-entry>` (no npx, no @latest); `brew pin node`.
4. Confirm: every `mcpServers[].command` is an absolute `node`, never `npx`.
