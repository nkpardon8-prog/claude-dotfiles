---
description: Set up THIS machine (macOS or Linux Mint / Ubuntu) as a client of the Mac mini Docker host - plain `docker` / `docker compose` and heavy test runs (`rrun`) then go to the mini, the local engine stays off. Run it once per new device; safe to re-run (idempotent). Windows is not supported yet.
---

# /dockersetup — join this machine to the Mac mini Docker host

**Arguments:** `$ARGUMENTS` (optional: `check` = report only, change nothing).

The mini (`macmini-docker` -> Nick's Mac mini, Tailscale `nicholass-mac-mini` 100.112.247.23) runs every container; this machine only runs
a `docker` shim, a background forwarder and the `rrun` client. Full reference: `/docker` (read its
"Linux client" and "Setup record" sections if anything below is unclear). Work through the steps in
order, report each result in one line, and stop at the first step that needs the user.

## 1. Detect the platform
`uname -s` -> `Darwin` (macOS) or `Linux`. On Linux also read `/etc/os-release` (Mint 21/22,
Ubuntu 22.04/24.04 are supported). Anything else (Windows, WSL, other distros): stop and say it is not
supported yet.

## 2. Prerequisites (check; install only with the user's OK - these need their password)
| Need | Check | macOS | Linux |
|---|---|---|---|
| Tailscale up, same tailnet | `tailscale status` lists `nicholass-mac-mini` | Tailscale app, signed in | `sudo tailscale up` |
| docker CLI (engine may stay off) | `command -v docker` (not `~/.local/bin/docker`) | Docker Desktop's CLI or `brew install docker` | `sudo apt install docker.io` |
| git, ssh, python3 | `git --version; ssh -V; /usr/bin/python3 --version` (>= 3.9) | built in | `sudo apt install git openssh-client python3` |
| the dotfiles | `~/.claude-dotfiles/scripts/rdocker/rdocker.py` exists | see the dotfiles README | same |

Never start a local Docker engine (Docker Desktop, `systemctl start docker`): the policy is "the mini is
the default"; a hook blocks it.

## 3. Install
```bash
/usr/bin/python3 ~/.claude-dotfiles/scripts/rdocker/rdocker.py install
```
It creates `~/.ssh/rdocker_ed25519` + the `~/.ssh/config.d/rdocker` alias + the `Include` line in
`~/.ssh/config` when missing (never overwriting; it backs the config up first), then the docker
context, the shims in `~/.local/bin` and the forwarder (launchd on macOS, the systemd user unit
`rdocker-forwarder.service` on Linux).

**Exit 2 with "Authorize this public key ..."** = the mini does not know this machine yet. Show the
user the printed `rdocker authorize-client '<key>'` line: it must run on a machine that can ALREADY
reach the mini (e.g. the MacBook Air - its Docker steward window can run it if the user asks there).
Never paste the key into the mini by any other route. Then re-run the install command above.

## 4. PATH and hooks
- `~/.local/bin` must come first on PATH in the login shell (`~/.zshrc` / `~/.bashrc`), so `docker`,
  `rrun`, `npm` and `rdocker` are the shims. Add `export PATH="$HOME/.local/bin:$PATH"` if missing,
  with the user's OK.
- Claude Code hooks: `~/.claude/settings.json` must register `scripts/hooks/rrun-route.py` and
  `scripts/hooks/no-docker-desktop.py` as `PreToolUse` Bash hooks (as `settings.json.template` does).
  If they are missing, show the user the block from the template; merge only with their OK.
- Linux, optional: `sudo loginctl enable-linger $USER` once keeps the forwarder running while logged
  out (only if the user wants it).

## 5. Verify (all must pass)
```bash
rdocker status                                   # every row OK; "commands go to MINI"
docker run --rm alpine:3.20 uname -m             # runs on the mini (aarch64)
N=dsetup-$$; docker run -d --rm --name $N -e POSTGRES_PASSWORD=x -p 127.0.0.1::5432 postgres:16-alpine \
  && sleep 5 && docker port $N 5432 && docker rm -f $N   # a mini port mirrored to localhost
```
In a git repo with a commit: `rrun sh -c 'hostname'` prints the mini's hostname.

## 6. Report
One short block: platform, what was installed or changed (files written, backups made), anything the
user still has to do (authorize the key, PATH, hooks, linger), and the verify results. `check` mode:
steps 1-2 and 5 only, no changes.
