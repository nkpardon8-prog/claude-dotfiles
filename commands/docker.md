---
description: Remote Docker on the always-on Mac mini (rdocker). Plain `docker` / `docker compose` on this laptop already run on the mini over Tailscale, with published TCP ports mirrored to laptop localhost, and a janitor cleans up after agents — so use docker normally. Invoke this BEFORE starting test databases or other containers (it has the database playbook: ports, readiness, lifetime labels, keeping data), when docker errors / hangs / "cannot connect" / refuses with "cannot tell where … lives" or "not a throwaway container", when a container port on localhost is unreachable, to check where a container runs, to switch remote/local mode, or to set up / repair the mini Docker host.
---

# /docker — Docker on the Mac mini, transparently

**Arguments:** `$ARGUMENTS` (optional: `status`, `doctor`, `clean`, `use <mode>`, `where <name>`, or plain English).

## The mental model

The laptop (16 GB) offloads container CPU+RAM to the always-on **Mac mini** (`macmini-docker` on
Tailscale; Colima VM: 6 CPU / 8 GB RAM / 30 GB disk, amd64 via Rosetta). Agent/test-runner CPU stays
on the laptop; only the containers move.

- `docker` on PATH is a **shim** (`~/.local/bin/docker` → `scripts/rdocker/docker-shim`). Each call is
  routed: normal work → **mini**; laptop-only needs → **laptop Docker Desktop** (started on demand and
  used only once `docker info` answers; quit after 15 idle min = no running laptop container, no live
  shim using it, no laptop-routed command for 15 min — laptop containers are fallback-pinned first so
  later commands still find them). Every rdocker notice goes to **stderr** (`rdocker: ...`), never stdout.
- One SSH ControlMaster carries the mini's Docker socket **and** every port mirror. Each TCP port a mini
  container publishes appears on the laptop's `127.0.0.1` and `[::1]` **at the same number**.
  `docker run -d`, `start`, `compose up` return only after the mirror is live.
- A launchd agent (`com.rdocker.forwarder`) follows `docker events`, re-checks health every 15 s,
  self-heals the tunnel / Tailscale / the mini engine, and runs the **janitor** every 10 min (as a
  detached, flock-guarded `rdocker janitor-run` / `kick` job, so a hung job never stalls it). It
  re-execs itself when the code on disk changes, but only if the new code imports cleanly.
- Tailscale carries only traffic to the user's own devices (no exit node), so the laptop's normal
  internet is unchanged. Nothing to switch on: Tailscale launches at login, and the forwarder restarts
  it if it is ever stopped.

**Use `docker` exactly as normal.** Never add `--context`, set `DOCKER_HOST`/`DOCKER_CONTEXT`, or swap
`localhost` for the mini's hostname — each deliberately bypasses routing.

**One laptop only.** Install rdocker on exactly one laptop: a second install would janitor and mirror
the first one's containers on the same mini.

**SDK callers bypass the shim.** dockerode, docker-py, testcontainers and anything that talks to a Docker
socket or calls docker by absolute path (not via PATH) get no routing: they use whatever the global
docker context points at (the daemon keeps it on `mini` while the mini is healthy). The daemon still
mirrors their published ports, but only after the fact (event-driven, not before the call returns).

## Database playbook (for agents)

> **Label every DB you need to outlive a pause.** The mini janitor **stops any running container with
> no traffic and no open connection for 12 h** (then removes it 24 h after it stops). A dev/test DB you
> come back to tomorrow, or one that sits quiet while you wait on a user, will be gone unless it carries
> a lifetime label:
> - `--label rdocker.keep=1` **plus a named volume** (label the volume too) — never idle-stopped, never
>   removed by the janitor; for data you care about.
> - `--label rdocker.ttl=<30m|6h|2d>` — lives exactly that long (the idle rule does not apply), then is
>   removed even if running; for throwaways that must survive a quiet spell.
>
> No label = the 12 h idle stop applies. See step 4.

1. **Publish on loopback, let Docker pick the port, read it back:**
   `docker run -d --name <proj>-<purpose>-<rand> -e POSTGRES_PASSWORD=postgres -p 127.0.0.1::5432 postgres:17`
   then `docker port <name> 5432` → connect to `127.0.0.1:<port>` / `localhost:<port>`. Fixed ports
   (`-p 127.0.0.1:55433:5432`) also work if that port is free **on the laptop**; localhost-only safety
   guards keep passing. Port details: see "Ports" below.
2. **Wait for readiness, don't sleep:** `until docker exec <name> pg_isready -U postgres -q; do sleep 1; done`
   (MySQL: `mysqladmin ping`; Redis: `redis-cli ping`). The port answers before the DB accepts queries.
3. **Seed / migrate by streaming, not bind-mounting:** `docker exec -i <name> psql -U postgres -v ON_ERROR_STOP=1 < migration.sql`
   or `docker cp file.sql <name>:/tmp/ && docker exec <name> psql -f /tmp/file.sql`.
   A bind mount (`-v ./init.sql:/docker-entrypoint-initdb.d/...`) forces the container onto the *laptop*.
4. **Say how long it should live** (the janitor enforces it):
   - throwaway test DB → `--rm` and/or `--label rdocker.ttl=2h` (`30m`, `6h`, `1d`) — removed when
     the TTL passes, even if still running; never idle-stopped before that.
   - keep across days (dev/preview DB with data you care about) → `--label rdocker.keep=1` **and a
     named volume** `-v <proj>-pgdata:/var/lib/postgresql/data`. Label the volume too:
     `docker volume create --label rdocker.keep=1 <proj>-pgdata`.
   - no label → normal lifecycle below: **stopped after 12 h quiet**, removed 24 h later.
   Throwaway shape also matters when the mini is down: only throwaway containers fall back to the laptop.
5. **Clean up what you start:** `docker rm -f -v <name>` (the `-v` drops its anonymous volume). Then the
   mirror disappears within seconds.
6. **Speed:** each query pays the laptop↔mini round-trip (~1-5 ms at home; ~75 ms measured away from
   home, 50 sequential queries = 3.6 s). Prefer one `exec -i ... < file` over many small round-trips; for a
   query-heavy suite away from home, run it with `RDOCKER_MODE=local`.
7. Other engines (MySQL, Redis, Mongo, MinIO, ClamAV, ...) behave the same. `docker build`
   (incl. `--platform linux/amd64`) runs on the mini.

## What runs where (automatic)

Commands that name an existing container / compose project are **located first** (asked on both
engines), then routed to wherever it actually lives. If its location cannot be established, the shim
**refuses** (exit 1, `cannot tell where <name> lives ... - refusing to guess`) rather than run on the
wrong engine.

| Command shape | Goes to |
|---|---|
| `exec/logs/rm/stop/start/port/cp/inspect/...`, compose `down/stop/logs/ps/...` | the engine that holds it (multi-name `rm`/`stop`/... split across both) |
| ...found on both engines | mini, unless it is pinned to the laptop |
| ...found on neither | default engine (docker prints its normal "No such" error) |
| ...found only on the laptop while the mini can't answer | read-only (`logs inspect port top stats diff wait export`, compose `ps logs top port`): laptop, with a notice. Mutating: **refused, exit 1** |
| ...mini can't answer and the laptop doesn't have it | **refused, exit 1** |
| `run`/`create` with named volumes, ports, env | mini |
| `run`/`create` with a laptop bind mount, or `--network host` | laptop |
| `compose up/run/create` whose rendered config has bind mounts or `network_mode: host`; `compose run -v <laptop path>` | laptop |
| `run`/`create`, `compose run`, or compose global flags with a flag rdocker's tables don't know | **refused, exit 1** (`unrecognized flag <f> ... will not pick an engine`) — see Self-resolution |
| compose whose `compose config` render fails | **exit 1**, compose's own error shown, nothing run |
| containers / compose projects in the **pin list** (incl. fallback pins) | laptop (a pin is a hint; the real location wins) |
| `ps` | both engines merged while the laptop engine runs (one header; exit non-zero if either failed) |
| other commands (`ps`, `images`, `build`, `pull`, ...) when the mini is unreachable / engine down | laptop, with a notice |
| any command except a **new throwaway** container, while the mini is reachable but slow (round-trip > 300 ms, `max_rtt_ms`) | mini — RTT never moves `ps`/`rm`/`inspect`/`build`/... to the laptop |
| anything with `RDOCKER_MODE=mini` while the mini is unavailable | **refused, exit 1** — never falls back |
| anything with `RDOCKER_MODE=local` | laptop |

**Fallback policy for creating commands** (`run`, `create`, compose `up/run/create`) when the mini is
unavailable: they fall back to the laptop **only if throwaway** — `--rm`, or no named-volume mount and no
`rdocker.keep` label (compose: no named volumes, and the model must be readable). Otherwise exit 1 with
the reason ("... not a throwaway container ..."); retry when the mini is back, add `--rm`, or force the
laptop with `RDOCKER_MODE=local`. A slow (but reachable) mini still gets non-throwaway containers and
every non-creating command; only new throwaway containers move to the laptop for speed. Containers / compose projects created by a fallback are
recorded in `pins.fallback` (so later commands find them on the laptop) and removed from it when the shim
removes them (`docker rm` / `compose down` on the laptop).

Compose routing reads the rendered model (`docker compose config`, client-side). `docker compose -f -`
works: stdin is buffered once and replayed to both the render and the real command.

Pinned at install (2026-10-12): the containers that already lived on the laptop (`david_db`,
`owner-view-pg`, `summit-owner-preview-pg`, ...) and compose project `david`. Moving one is a data
migration — **ask the user first**, copy the volume, then `rdocker unpin <name>`.

## Ports (mini containers — emulates local Docker)

- **Fixed host port** (`-p 127.0.0.1:55433:5432`, `-p 8080:80`): must be free on the laptop (both
  `127.0.0.1` and `[::1]`), else the shim exits **125** with docker's own `port is already allocated`
  message (`... (on the laptop - rdocker)`) and creates nothing.
- **Ephemeral host port** (`-p 127.0.0.1::5432`, `-p 5432`): the shim picks a free laptop port from
  **20000-29999** (`ephemeral_port_range`) and writes it into the command explicitly. Ports are reserved
  under a lock until the shim finishes (re-extended every minute while docker runs, so a long image
  pull cannot let it lapse; a crashed shim's reservation expires after 15 min), so **parallel runs
  never collide**. If the mini reports the
  picked port as allocated, the just-created container is removed and the run is retried once with
  another port. `docker port` afterwards returns the real port — the playbook above stays correct.
- Compose: published ports from the rendered model get the same laptop preflight; entries without a host
  port are left to the mini and checked after start. `-P` (publish all) ports are chosen by the mini's
  Docker and mirrored after start.
- **Mirror required:** if a mirror cannot be established after start (laptop port taken meanwhile, tunnel
  failure), the container **this command created** is removed (`rm -f`) and the command exits 1; a
  container that already existed (`docker start`) is left running. Foreground `run` / `compose up` are
  watched the same way.
- **UDP** (or any non-TCP) publish → exit **125** `UDP publishes are not mirrored to the laptop`.
- Only host IPs `127.0.0.1`, `0.0.0.0`, `::` or none are mirrored; `[::1]:<p>:<cp>` (or a specific
  other IP) runs on the mini with **no** laptop mirror.

## Automatic lifecycle (janitor, mini only, every 10 min, logged)

| Thing | Rule |
|---|---|
| protection | `rdocker.keep` with **any value except `0`/`false`/`no`** (empty counts as keep) protects containers, volumes and images. The label is re-checked by a fresh inspect **immediately before every destructive call**. No `container prune` is ever issued; volume prunes carry `--filter label!=rdocker.keep` |
| running container with `rdocker.ttl` | removed (`rm -f`, plus `-v` unless a volume is keep-labelled) once running longer than the TTL; the idle rule below does not apply to it |
| running container, idle (no keep / ttl label) | stopped after **12 h** idle. Idle = no eth traffic (`docker stats` NetIO unchanged) **and** no established TCP connection. Each sample adds at most 2 janitor intervals (sleep / outage never counts fully); unreadable samples hold the clock. Uses the mini's clock |
| stopped / exited container | removed after **24 h** with `rm -v` — or plain `rm` (volumes kept) if any of its volumes is keep-labelled |
| named volume not used by any container | removed after **30 days** unused |
| anonymous volumes not used by any container | pruned each run (keep-labelled exempt) |
| image | removed after **14 days** unused by any container (running or stopped) — tracked in a last-use ledger, first seen = now. Removed tag by tag (`image rm <repo:tag>`; an image tagged in several repositories cannot be removed by id), then by id if an untagged remainder is left; never `-f`. Docker's refusals (in use, dependent child images, multi-repo) are skips, not errors. Dangling images pruned |
| build cache | pruned when older than 7 d, and capped at **5 GB** |
| container logs | capped per container: 10 MB × 3 files (json-file) |
| mini Colima/Lima log files | truncated past 50 MB; VM journald capped at 200 MB |
| VM disk ≥ 80 % or mini free < 8 GB | remove unused images **oldest-unused first** (never in-use ones) until below, prune all build cache, log a WARNING |
| VM disk ≥ 90 % | also remove every stopped non-keep container (keep-checked) + prune anonymous volumes |
| failed action | logged; clocks are kept (not reset); `last_error` is written to `janitor.json` and raised as an attention item. The next clean full pass clears both |
| freed VM blocks | `fstrim` hands them back to macOS each run |

Run it now: `rdocker clean [--dry-run] [--only PREFIX] [--force-critical]` (`--only` limits the
container/volume rules to a name prefix and skips global prunes and image GC; `--force-critical` applies
the disk-critical stopped-container removal now — keep-labelled still exempt). Exit codes: 0 = the pass
ran; 1 = it did not run: mini lock still held after 90 s, mini unreachable over ssh, or the mini's
docker engine not answering (also with `--dry-run`). The background janitor just skips such a pass.
Hard ceilings: VM disk 30 GB, VM RAM 8 GB, VM CPU 6 — the mini itself can never be filled or starved.
Laptop logs (`daemon.log`, `route.log`) rotate at 2 MB (one `.1` generation, under a lock). Containers on the laptop are not janitored.

## Health

Health = raw HTTP `GET /_ping` (then `GET /version` for the server version) straight to the forwarded
mini docker socket over the SSH tunnel - no docker CLI subprocess, whose start-up used to add ~250 ms
(4 s timeout; the `/_ping` round-trip is the RTT),
never a raw probe of the mini's `:22`. A reading is reused for 30 s. If the probe fails, `ssh true` over
the existing master decides: tunnel alive → engine problem (tunnel and mirrors left alone); tunnel dead →
the master is rebuilt and the probe retried once. Auto mode treats round-trips over **300 ms**
(`max_rtt_ms`) as slow, which only sends new throwaway containers to the laptop.

**Engine recovery (the forwarder, never a laptop guess alone).** VM down → started (only if the Colima
profile exists). VM up but the engine silent → `colima restart` **only when all hold**: engine-probe
failures continuous for **10 min** (any success resets the clock; tunnel-class failures never count);
then, on the mini under the mini lock, `docker info` fails there too (30 s timeout — a slow tunnel or
laptop is not a dead engine) **and** `docker ps -q` lists no running container (or itself fails/hangs).
Never while the engine still answers `ps` with running containers. At most one restart per 30 min.
When it declines, it raises an attention item instead.

**Attention items (walk-away).** Conditions a human must act on are kept in
`~/.local/state/rdocker/attention.json` while they hold and cleared when they resolve: engine
unresponsive but not restarted (and why), no Colima profile, start failed, restart rate-limited / lock
lost / failed, `restart_pending` older than 24 h, janitor error, docker-CLI flag drift. `rdocker status`
shows each as a `WARN` row; every `docker` call prints **one stderr line per item at most once per
hour**: `rdocker: needs attention: <msg> (run rdocker status)` — never on stdout, exit code unchanged.

**Flag-table drift.** rdocker parses `run`/`create`/`compose [run|up|create]` with explicit flag tables
(`rd_args.SPECS`) and refuses flags it doesn't know. Once a day the forwarder (and every
`rdocker doctor`) diffs the laptop docker CLI's `--help` against them; new flags raise
`docker CLI has N flag(s) rdocker doesn't know: … - add them to rd_args.SPECS`.

## Exposure (honest)

- Container ports bind the **mini's loopback only**; the way in is SSH over Tailscale with the dedicated
  key `~/.ssh/rdocker_ed25519`. Nothing is reachable from the internet.
- On the **home LAN**, the mini's macOS sshd (`:22`, Remote Login) and Lima's DNS helper (`*:53`, DNS
  answers only) are visible.
- Optional manual hardening (needs the user's `sudo` on the mini — ask): disable sshd password auth
  (`PasswordAuthentication no`, `KbdInteractiveAuthentication no` in `/etc/ssh/sshd_config.d/`).

## Commands (`rdocker`, on PATH)

| Command | Does |
|---|---|
| `rdocker status` | health + RTT, where commands go, mirrored ports, conflicts, attention items (exit 1 if any `--` row; `WARN` rows never fail it) |
| `rdocker doctor` | status **+ repair** (Tailscale, mini engine start via the kick path — never a VM-up restart, forwarder, mirrors) + flag-drift check |
| `rdocker clean [--dry-run\|--only P\|--force-critical]` | run the janitor now; exit 1 if it could not run: mini lock held after 90 s, mini unreachable, or mini engine not answering (`--dry-run` too) |
| `rdocker use auto\|mini\|local\|off` | routing mode; also points the global docker context at the target (`off` = raw Docker Desktop behaviour, context → laptop) |
| `rdocker where <container>` | which engine holds it (says which engine could not be asked) |
| `rdocker pin\|unpin <name> [--compose]` | keep a container / compose project on the laptop |
| `rdocker logs [--route]` | forwarder + janitor log / per-command routing log (incl. refusals) |
| `rdocker sync` | reconcile port mirrors now |

`rdocker status` rows: tailscale on laptop · mini reachable (ssh control connection) · mini docker engine
(version, round-trip) · mode → where commands go · docker shim first on PATH · background forwarder ·
daemon process (pid, age, running the code on disk / reload pending / reload NOT picked up) · health
reading age · janitor last run · janitor last error (`--` only if from about the latest pass) · mini
disk · mini engine config (Colima restart pending) · fallback pins · mirrored ports (IPv6 mirror
pending) · port conflicts (busy on laptop) · laptop Docker Desktop · global docker context · (doctor)
docker CLI flags vs `rd_args.SPECS` · one `WARN` row per attention item (with its age). Exit code: 1 only
for `--` rows (real faults); `WARN` rows are for a human and keep it 0.
`rdocker --help` exits 0; an unknown command prints usage and exits 2.

Per call: `RDOCKER_MODE=local|mini`, `RDOCKER_BYPASS=1` (raw docker), `RDOCKER_VERBOSE=1` (say why local).
Logs: `~/.local/state/rdocker/{daemon,route}.log`; state: `health.json`, `forwards.json`, `reserved.json`,
`janitor.json`, `daemon.json` (running daemon pid/start/code mtime), `attention.json` (+
`attention-shown.json`, the shim notice's hourly rate state). Config: `~/.config/rdocker/config.json` (stores only keys that differ from the defaults;
every threshold above is a key there).

## Self-resolution (when invoked)

1. Starting containers → follow the database playbook above; nothing else needed.
2. Trouble → `rdocker status`; any `--` line → `rdocker doctor`, then re-check:
   - **mini unreachable** → laptop Tailscale off (doctor starts it) or the mini is down/offline.
     Throwaway work continues on the laptop; kept data and existing mini containers refuse until it is
     back. Tell the user the mini is offline.
   - **mini engine not responding** → VM down: the forwarder starts it (only if the Colima profile
     exists — else run `rdocker setup-mini`), via `launchctl kickstart` of `sh.brew.colima` when that
     agent is loaded, else `colima start` (works with no one logged in). VM up but docker silent:
     `colima restart` only after 10 min of continuous failures **and** a mini-side check that the
     engine is really dead with nothing running (see "Engine recovery"), at most once per 30 min,
     under the mini lock (`~/.rdocker/janitor.lock` on the mini, heartbeat, stale after 10 min).
     Otherwise a `WARN` row says why it was not restarted — tell the user.
   - **`WARN` rows / "rdocker: needs attention: …" on stderr** → read the message; it names the fix
     (e.g. `rdocker setup-mini`, add flags to `rd_args.SPECS`, stop containers so a pending config
     restart can run). Report it to the user; it clears itself once the condition resolves.
   - **"internal error routing <cmd>"** (exit 1) → an rdocker bug hit before docker ran; read-only
     commands still run, container commands refuse rather than guess an engine. Run `rdocker doctor`,
     see `rdocker logs --route` (traceback), and report it.
   - **"unrecognized flag ... will not pick an engine"** (exit 1) → a newer docker flag rdocker can't
     parse, so it can't see whether the command mounts laptop paths. Use the spelling rdocker knows if
     there is one; otherwise force an engine: `RDOCKER_MODE=local docker ...` (laptop) or
     `docker --context mini ...` (explicit context = unrouted, no port mirroring). Tell the user so the
     flag gets added to `rd_args.SPECS`.
   - **"modules failed to import"** (any import-time exception) → a broken rdocker install: read-only commands (`ps`, `images`,
     `pull`, ...) still run unrouted, anything that targets/creates a container exits 1. Run
     `rdocker doctor` and report it.
   - **exit 125 "port is already allocated"** / **port conflict** → a laptop process holds that port;
     free it or use an ephemeral port (`-p 127.0.0.1::<cport>`).
   - **"cannot tell where ... lives"** → wait for the mini (`rdocker doctor`); don't force the laptop for
     a container that may live on the mini.
   - **shim not first on PATH** → `~/.local/bin` must precede `/usr/local/bin` (it does via `~/.zshrc`).
3. Never move pinned data, delete `rdocker.keep` things, or resize the mini VM without the user.

## Verify

- Unit (245 tests, fake docker `tests/fake_docker.py`, no mini needed, hermetic temp `RDOCKER_HOME` +
  fail-closed stubs via `tests/rdmods.py`; files `test_args`, `test_daemon`, `test_engine`, `test_entry`,
  `test_janitor`, `test_ports`, `test_shim_safety`, `test_state`, `test_tunnel`, `test_zz_hermetic`):
  `cd ~/.claude-dotfiles/scripts/rdocker && /usr/bin/python3 -m unittest discover -s tests`
- Live end-to-end (self-cleaning, removes only the `rde2e-<pid>-*` containers it created, non-disruptive by default):
  `bash ~/.claude-dotfiles/scripts/rdocker/tests/e2e.sh` (incl. a check that `-p <port>:80` with no IP
  still binds only the mini's loopback, i.e. the Lima override wins). `E2E_DISRUPTIVE=1` adds the tunnel-kill
  self-heal case (kills the shared SSH master — other windows' docker calls blip).

## Setup record (done 2026-10-12 — for a rebuild)

Mini: Tailscale as a system daemon (`sudo brew services start tailscale`, hostname `macmini-docker`),
Remote Login on, laptop keys in `~/.ssh/authorized_keys`. Laptop: `~/.ssh/config` → `Include
~/.ssh/config.d/*` (`rdocker` block); `rdocker setup-mini 6 8 30`; `rdocker install` (context `mini` =
`unix://~/.local/state/rdocker/mini-docker.sock`, shims, launch agent, pins). Mini Colima config:
`~/.colima/default/colima.yaml` `docker:` ip 127.0.0.1, log caps, BuildKit GC 5 GB;
`~/.colima/_lima/_config/override.yaml` port-forwards → 127.0.0.1, guest port 53 ignored.
`rdocker setup-mini` rewrites both idempotently and never restarts Colima itself: it sets
`restart_pending` in `janitor.json`, and the janitor restarts Colima only when `docker ps` on the mini
is empty, re-checked under the mini lock right before the restart.

**Known limits:** Homebrew owns the mini's tailscale paths as root (upgrading it there needs `sudo`).
`host.docker.internal` inside a mini container is the mini, not the laptop.

Source: `scripts/rdocker/` (stdlib, /usr/bin/python3 3.9). `rdocker.py` is a thin entry (launchd,
`~/.local/bin/rdocker` and `docker-shim` — which resolves its own real dir through the symlink — all
run it); code in `rd_common` (paths, config/state, locks, logs) → `rd_args` (per-subcommand flag
tables) → `rd_tunnel` (health, SSH master, port mirrors) → `rd_route` (shim routing) → `rd_janitor`
(janitor, mini lock, engine kick/restart) → `rd_daemon` (forwarder loop) → `rd_setup` (install,
setup-mini, CLI). Docker CLI flag research: `docs/docker-cli-semantics.md`. Brief:
`random/tools/online docker/tmp/briefs/2026-10-12-remote-docker-on-mac-mini.md`.
