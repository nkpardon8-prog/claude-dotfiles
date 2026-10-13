---
description: Remote Docker on the always-on Mac mini (rdocker). Plain `docker` / `docker compose` on this laptop already run on the mini over Tailscale, with published ports mirrored to laptop localhost — so agents just use docker normally. Invoke this when about to start test databases or containers, when docker errors / hangs / "cannot connect", when a container port on localhost is unreachable, to check where a container runs, to switch remote/local mode, or to set up / repair the mini Docker host.
---

# /docker — Docker on the Mac mini, transparently

**Arguments:** `$ARGUMENTS` (optional: `status`, `doctor`, `use <mode>`, `where <name>`, `setup`, or plain English).

## The mental model (read this, then mostly do nothing special)

The laptop (16 GB) offloads container CPU+RAM to the always-on **Mac mini** (`macmini-docker` on
Tailscale, Colima engine: 6 CPU / 8 GB / 30 GB disk, amd64 via Rosetta).

- `docker` on PATH is a **shim** (`~/.local/bin/docker` → `scripts/rdocker/docker-shim`). Every call
  is routed: normal work → **mini**; laptop-only needs → **laptop Docker Desktop** (started on demand,
  auto-quit after 15 idle min).
- Every port a mini container publishes is **mirrored to the laptop's 127.0.0.1 and [::1] at the same
  port number** (one SSH ControlMaster; a launchd agent `com.rdocker.forwarder` follows `docker events`).
  `docker run -d -p ...` returns only after the mirror is live, so `localhost:<port>` works immediately
  — including `-p 127.0.0.1::5432` + `docker port`, `freePort()` harnesses, prisma, pg, psql.
- Nothing is reachable from the internet or the mini's LAN: mini-side ports bind the mini loopback
  only; the only path in is SSH over Tailscale with a dedicated key.

**So: use `docker` exactly as you normally would.** Do not add `--context`, do not rewrite `localhost`
to the mini's hostname, do not set `DOCKER_HOST`. (Doing any of those bypasses routing on purpose.)

## What runs where (automatic)

| Command shape | Goes to | Why |
|---|---|---|
| `run`/`create` with named volumes, `-p`, env, images | mini | the point |
| `run`/`create` with a laptop bind mount (`-v /abs:`, `-v ./x:`, `--mount type=bind`) | laptop | needs laptop files |
| `run --network host` | laptop | "host" must mean the laptop |
| `compose ...` whose rendered config has bind mounts or `network_mode: host` | laptop | same |
| `exec/logs/rm/stop/port/cp/...` on a container | wherever that container lives | looked up per call |
| containers / compose projects in the **pin list** | laptop | their data lives there |
| `build` (incl. `--platform linux/amd64`) | mini | context is uploaded; heavy CPU leaves the laptop |
| `ps` | both engines merged while the laptop engine is running | one view |
| anything, when the mini is unreachable or round-trip > `max_rtt_ms` (auto mode) | laptop | fallback, one-line notice on a TTY |

Pinned at install (2026-10-12): every container that already existed on the laptop engine
(`david_db`, `owner-view-pg`, `summit-owner-preview-pg`, ...) and compose project `david` — their data
volumes are on the laptop. Moving one is a data migration: **ask the user first**, then
`docker run --rm -v <vol>:/v alpine tar c -C /v . | ...` style copy, then `rdocker unpin <name>`.

## Latency — the one real trade-off

Every query pays the laptop↔mini round-trip. At home (same LAN, direct Tailscale path): ~1-5 ms.
Away from home: measured ~70-80 ms (50 sequential `select 1` = 3.6 s). Query-heavy suites are
noticeably slower remotely when away. Auto mode falls back to the laptop above `max_rtt_ms`
(default 150). For a speed-critical suite away from home, run it with `RDOCKER_MODE=local` (one
command) or `rdocker use local` (sticky) — and back with `rdocker use auto`.

## Commands (`rdocker`, on PATH)

| Command | Does |
|---|---|
| `rdocker status` | health, round-trip, where commands go now, mirrored ports, conflicts |
| `rdocker doctor` | status **+ repair**: starts Tailscale, starts Colima on the mini, reloads the forwarder, re-syncs mirrors |
| `rdocker use auto\|mini\|local\|off` | routing mode (`off` = shim is a no-op, raw Docker Desktop behaviour) |
| `rdocker where <container>` | which engine holds it |
| `rdocker pin\|unpin <name> [--compose]` | keep a container / compose project on the laptop |
| `rdocker sync` | reconcile port mirrors now |
| `rdocker logs` | forwarder log (`~/.local/state/rdocker/daemon.log`) |
| `rdocker install` / `rdocker setup-mini [cpu mem disk]` | (re)install laptop side / mini side |

Per-call env: `RDOCKER_MODE=local|mini` (force), `RDOCKER_BYPASS=1` (raw docker, no routing),
`RDOCKER_VERBOSE=1` (print why a command ran locally).

## Self-resolution (when invoked)

1. Run `rdocker status`. All `OK` → answer the user's actual question / proceed with their docker task.
2. Any `--` line → run `rdocker doctor` (it repairs what it can), then re-check. Map what remains:
   - **mini unreachable** → laptop Tailscale off (doctor starts it) or the mini is down/asleep/offline.
     Work continues on the laptop automatically; tell the user the mini is offline.
   - **mini docker engine not responding** → doctor runs `colima start` over SSH. If the mini rebooted
     and nobody is logged in, Colima (a user LaunchAgent) is not running and SSH-started Colima may
     still work; if not, the user must log in on the mini (`/macmini` can drive the screen, but the
     password is user-only).
   - **port conflict** → a laptop process already holds that port; the mini container is reachable as
     `macmini-docker:<port>` only via `ssh -L`. Free the laptop port, or use another port.
   - **shim not first on PATH** → `~/.local/bin` must precede `/usr/local/bin` (it does in `~/.zshrc`).
3. "Where did my container go?" → `rdocker where <name>`; `docker ps` already shows both engines.
4. Never move pinned data, delete mini volumes, or change the mini's Colima size without the user.

## Setup (already done 2026-10-12 — for a rebuild or a second laptop)

Laptop: Tailscale.app (no exit node — normal internet untouched). Mini: Tailscale as a **system**
daemon (`sudo brew services start tailscale`, survives reboot without login), Remote Login on.
1. `ssh-keygen -t ed25519 -N "" -f ~/.ssh/rdocker_ed25519` and add the `.pub` to the mini's
   `~/.ssh/authorized_keys` (public key — safe to type through `/macmini`). The user's main key has a
   passphrase, which a background agent cannot use — that is why the dedicated key exists.
2. `~/.ssh/config` → `Include ~/.ssh/config.d/*`; `~/.ssh/config.d/rdocker` = Host `macmini-docker`,
   User `omidsmacmini`, IdentityFile `~/.ssh/rdocker_ed25519`, ControlMaster auto/ControlPersist 10m.
3. `rdocker setup-mini 6 8 30` — brew colima+docker, PATH in the mini's `~/.zshenv` (docker over SSH
   runs `docker system dial-stdio` in a non-interactive shell), Colima VM with Rosetta, `brew services`.
4. Mini hardening (done): `~/.colima/default/colima.yaml` `docker: {ip: 127.0.0.1}` and
   `~/.colima/_lima/_config/override.yaml` portForwards → hostIP 127.0.0.1, guestPort 53 ignored.
   Remaining: Lima's own DNS helper listens on the mini's `*:53` (LAN-only, DNS answers only).
5. `rdocker install` — creates context `mini`, shims, launch agent, pins existing laptop containers.

**Known limits:** mini has no auto-login → after a power cut Colima waits for a login (laptop
fallback covers it). Homebrew took root ownership of the mini's tailscale paths, so upgrading Tailscale
there needs `sudo`. Containers that call back into laptop services via `host.docker.internal` reach
the *mini*, not the laptop (none observed in the 2026-10-12 usage scan).

Source: `scripts/rdocker/rdocker.py` (stdlib, /usr/bin/python3). Design brief:
`random/tools/online docker/tmp/briefs/2026-10-12-remote-docker-on-mac-mini.md`.
