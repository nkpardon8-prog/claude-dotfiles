---
description: Remote Docker on the always-on Mac mini (rdocker). Plain `docker` / `docker compose` on this laptop already run on the mini over Tailscale, with published ports mirrored to laptop localhost, and a janitor cleans up after agents — so use docker normally. Invoke this BEFORE starting test databases or other containers (it has the database playbook: ports, readiness, lifetime labels, keeping data), when docker errors / hangs / "cannot connect", when a container port on localhost is unreachable, to check where a container runs, to switch remote/local mode, or to set up / repair the mini Docker host.
---

# /docker — Docker on the Mac mini, transparently

**Arguments:** `$ARGUMENTS` (optional: `status`, `doctor`, `clean`, `use <mode>`, `where <name>`, or plain English).

## The mental model

The laptop (16 GB) offloads container CPU+RAM to the always-on **Mac mini** (`macmini-docker` on
Tailscale; Colima VM: 6 CPU / 8 GB RAM / 30 GB disk, amd64 via Rosetta). Agent/test-runner CPU stays
on the laptop; only the containers move.

- `docker` on PATH is a **shim** (`~/.local/bin/docker` → `scripts/rdocker/docker-shim`). Each call is
  routed: normal work → **mini**; laptop-only needs → **laptop Docker Desktop** (started on demand,
  quit after 15 idle min).
- One SSH ControlMaster carries the mini's Docker socket **and** every port mirror. Each port a mini
  container publishes appears on the laptop's `127.0.0.1` and `[::1]` **at the same number**.
  `docker run -d`, `start`, `compose up` return only after the mirror is live.
- A launchd agent (`com.rdocker.forwarder`) follows `docker events`, re-checks health every 15 s,
  self-heals the tunnel / Tailscale / the mini engine, and runs the **janitor** every 10 min.
- Nothing is reachable from the internet or the mini's LAN: mini ports bind its loopback only; the only
  way in is SSH over Tailscale with the dedicated key `~/.ssh/rdocker_ed25519`.
- Tailscale carries only traffic to the user's own devices (no exit node), so the laptop's normal
  internet is unchanged. Nothing to switch on: Tailscale launches at login, and the forwarder restarts
  it if it is ever stopped.

**Use `docker` exactly as normal.** Never add `--context`, set `DOCKER_HOST`/`DOCKER_CONTEXT`, or swap
`localhost` for the mini's hostname — each deliberately bypasses routing.

## Database playbook (for agents)

1. **Publish on loopback, let Docker pick the port, read it back:**
   `docker run -d --name <proj>-<purpose>-<rand> -e POSTGRES_PASSWORD=postgres -p 127.0.0.1::5432 postgres:17`
   then `docker port <name> 5432` → connect to `127.0.0.1:<port>` / `localhost:<port>`. Fixed ports
   (`-p 127.0.0.1:55433:5432`) also work; localhost-only safety guards keep passing.
2. **Wait for readiness, don't sleep:** `until docker exec <name> pg_isready -U postgres -q; do sleep 1; done`
   (MySQL: `mysqladmin ping`; Redis: `redis-cli ping`). The port answers before the DB accepts queries.
3. **Seed / migrate by streaming, not bind-mounting:** `docker exec -i <name> psql -U postgres -v ON_ERROR_STOP=1 < migration.sql`
   or `docker cp file.sql <name>:/tmp/ && docker exec <name> psql -f /tmp/file.sql`.
   A bind mount (`-v ./init.sql:/docker-entrypoint-initdb.d/...`) forces the container onto the *laptop*.
4. **Say how long it should live** (the janitor enforces it):
   - throwaway test DB → `--rm` and/or `--label rdocker.ttl=2h` (`30m`, `6h`, `1d`) — removed when
     the TTL passes, even if still running.
   - keep across days (dev/preview DB with data you care about) → `--label rdocker.keep=1` **and a
     named volume** `-v <proj>-pgdata:/var/lib/postgresql/data`. Label the volume too:
     `docker volume create --label rdocker.keep=1 <proj>-pgdata`.
   - no label → normal lifecycle below.
5. **Clean up what you start:** `docker rm -f -v <name>` (the `-v` drops its anonymous volume). Then the
   mirror disappears within seconds.
6. **Speed:** each query pays the laptop↔mini round-trip (~1-5 ms at home; ~75 ms measured away from
   home, 50 sequential queries = 3.6 s). Prefer one `exec -i ... < file` over many small round-trips; for a
   query-heavy suite away from home, run it with `RDOCKER_MODE=local`.
7. Other engines (MySQL, Redis, Mongo, MinIO, ClamAV, ...) behave the same. `docker build`
   (incl. `--platform linux/amd64`) runs on the mini.

## Automatic lifecycle (janitor, mini only, every 10 min, logged)

| Thing | Rule |
|---|---|
| running container with `rdocker.ttl` | removed (`rm -f -v`) once older than the TTL |
| running container, zero TCP connections | stopped after **12 h** idle |
| stopped / exited container | removed with its anonymous volumes after **24 h** |
| named volume not used by any container | removed after **30 days** unused |
| anything labelled `rdocker.keep=1` | never touched |
| dangling images / images unused 14 d / build cache > 7 d or > 5 GB | pruned |
| container logs | capped per container: 10 MB × 3 files (json-file) |
| mini Colima/Lima log files | truncated past 50 MB; VM journald capped at 200 MB |
| VM disk ≥ 80 % or mini free < 8 GB | prune ALL unused images + build cache, log a WARNING |
| VM disk ≥ 90 % | also remove every stopped container + anonymous volume |
| freed VM blocks | `fstrim` hands them back to macOS each run |

Hard ceilings: VM disk 30 GB, VM RAM 8 GB, VM CPU 6 — the mini itself can never be filled or starved.
Laptop logs (`daemon.log`, `route.log`) rotate at 2 MB. Containers pinned to the laptop are not janitored.

## What runs where (automatic)

| Command shape | Goes to |
|---|---|
| `run`/`create` with named volumes, ports, env | mini |
| `run`/`create` with a laptop bind mount, or `--network host` | laptop |
| `compose` whose rendered config has bind mounts or `network_mode: host` | laptop |
| `exec/logs/rm/stop/port/cp/...` | wherever that container lives |
| containers / compose projects in the **pin list** | laptop |
| `ps` | both engines merged while the laptop engine runs |
| anything when the mini is unreachable or RTT > 150 ms (auto mode) | laptop (one-line notice) |

Pinned at install (2026-10-12): the containers that already lived on the laptop (`david_db`,
`owner-view-pg`, `summit-owner-preview-pg`, ...) and compose project `david`. Moving one is a data
migration — **ask the user first**, copy the volume, then `rdocker unpin <name>`.

## Commands (`rdocker`, on PATH)

| Command | Does |
|---|---|
| `rdocker status` | health, RTT, where commands go, mirrored ports, conflicts |
| `rdocker doctor` | status **+ repair** (Tailscale, mini engine, tunnel, forwarder, mirrors) |
| `rdocker clean [--dry-run]` | run the janitor now |
| `rdocker use auto\|mini\|local\|off` | routing mode (`off` = raw Docker Desktop behaviour) |
| `rdocker where <container>` | which engine holds it |
| `rdocker pin\|unpin <name> [--compose]` | keep a container / compose project on the laptop |
| `rdocker logs [--route]` | forwarder + janitor log / per-command routing log |
| `rdocker sync` | reconcile port mirrors now |

Per call: `RDOCKER_MODE=local|mini`, `RDOCKER_BYPASS=1` (raw docker), `RDOCKER_VERBOSE=1` (say why local).
Logs: `~/.local/state/rdocker/{daemon,route}.log`; state: `health.json`, `forwards.json`, `janitor.json`.
Config: `~/.config/rdocker/config.json` (every threshold above is a key there).

## Self-resolution (when invoked)

1. Starting containers → follow the database playbook above; nothing else needed.
2. Trouble → `rdocker status`; any `--` line → `rdocker doctor`, then re-check:
   - **mini unreachable** → laptop Tailscale off (doctor starts it) or the mini is down/offline. Work
     continues on the laptop automatically; tell the user the mini is offline.
   - **mini engine not responding** → doctor/forwarder runs `colima start` over SSH (works with no one
     logged in on the mini).
   - **port conflict** → a laptop process holds that port; free it or pick another port.
   - **shim not first on PATH** → `~/.local/bin` must precede `/usr/local/bin` (it does via `~/.zshrc`).
3. Never move pinned data, delete `rdocker.keep` things, or resize the mini VM without the user.

## Verify

- Unit: `/usr/bin/python3 -m unittest discover -s ~/.claude-dotfiles/scripts/rdocker/tests`
- Live end-to-end (self-cleaning, `rde2e-*` only): `bash ~/.claude-dotfiles/scripts/rdocker/tests/e2e.sh`
  — 16 checks: routing, mirrors, parallel DBs, 20 concurrent calls, tunnel-death self-heal, loopback-only.

## Setup record (done 2026-10-12 — for a rebuild)

Mini: Tailscale as a system daemon (`sudo brew services start tailscale`, hostname `macmini-docker`),
Remote Login on, laptop keys in `~/.ssh/authorized_keys`. Laptop: `~/.ssh/config` → `Include
~/.ssh/config.d/*` (`rdocker` block); `rdocker setup-mini 6 8 30`; `rdocker install` (context `mini` =
`unix://~/.local/state/rdocker/mini-docker.sock`, shims, launch agent, pins). Mini Colima config:
`~/.colima/default/colima.yaml` `docker:` ip 127.0.0.1, log caps, BuildKit GC 5 GB;
`~/.colima/_lima/_config/override.yaml` port-forwards → 127.0.0.1, guest port 53 ignored.
Config changes that need a Colima restart are applied by the janitor only when no container runs
(`restart_pending` in `janitor.json`).

**Known limits:** Lima's DNS helper listens on the mini's `*:53` (LAN-only, DNS answers only). Homebrew
owns the mini's tailscale paths as root (upgrading it there needs `sudo`). `host.docker.internal` inside
a mini container is the mini, not the laptop.

Source: `scripts/rdocker/rdocker.py` (stdlib, /usr/bin/python3 3.9). Brief:
`random/tools/online docker/tmp/briefs/2026-10-12-remote-docker-on-mac-mini.md`.
