---
description: Remote Docker on the always-on Mac mini (rdocker). Plain `docker` / `docker compose` on this laptop already run on the mini over Tailscale, with published TCP ports mirrored to laptop localhost, and a janitor cleans up after agents — so use docker normally. Heavy DB test jobs (`npm run test:db` and similar) run code + DB together on the mini via `rrun <cmd>`, usually rewritten automatically by a hook. Invoke this BEFORE starting test databases or other containers (it has the database playbook: ports, readiness, lifetime labels, keeping data), when docker errors / hangs / "cannot connect" / refuses with "cannot tell where … lives" or "not a throwaway container", when a container port on localhost is unreachable, to check where a container runs, to switch remote/local mode, or to set up / repair the mini Docker host.
---

# /docker — Docker on the Mac mini, transparently

**Arguments:** `$ARGUMENTS` (optional: `status`, `doctor`, `clean`, `use <mode>`, `where <name>`, or plain English).

**Running ON the Mac mini?** (`~/.local/bin/docker` missing, `docker context show` = `colima`.) Then docker is
the mini's own local engine and nothing here routes it: no shim, no port mirrors, no `rrun`, no `rdocker`
command. Use docker normally. The laptop's janitor still sweeps this engine, so a DB that must survive
3 h of quiet needs `--label rdocker.keep=1` + a named volume (or `rdocker.ttl=...`), as below.

## The mental model

The laptop (16 GB) offloads container CPU+RAM to the always-on **Mac mini** (ssh alias `macmini-docker` ->
Tailscale `nicholass-mac-mini`, 100.112.247.23 - Nick's Mac mini since 2026-10-22; before that Omid's `macminim4`; Colima VM: 6 CPU / 5 GB RAM / 30 GB disk, amd64 via Rosetta). Normally agent/test-runner
CPU stays on the laptop and only the containers move. **Heavy test jobs** (test runner + its DB) move
whole: `rrun <cmd>` runs the command itself on the mini next to its DB, usually without asking (a hook
rewrites known heavy commands) — see "Heavy test jobs on the mini" below.

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
  internet is unchanged. On macOS, Tailscale launches at login, and the forwarder restarts it if it
  is ever stopped. On Linux, bring it up with `sudo tailscale up`.

**Use `docker` exactly as normal.** Never add `--context`, set `DOCKER_HOST`/`DOCKER_CONTEXT`, or swap
`localhost` for the mini's hostname — each deliberately bypasses routing.

**One laptop only.** Install rdocker on exactly one laptop: a second install would janitor and mirror
the first one's containers on the same mini.

## Linux client (Linux Mint / Ubuntu)

Mint 21/22 and Ubuntu 22.04/24.04 can run the client role. Install Tailscale and bring it up on the
same tailnet as the mini, then install the client tools:

```sh
sudo apt install docker.io git openssh-client python3
```

The local Docker engine may stay off. Clone these dotfiles and run
`/usr/bin/python3 /path/to/dotfiles/scripts/rdocker/rdocker.py install`. Install creates a dedicated
`~/.ssh/rdocker_ed25519` key, the `~/.ssh/config.d/rdocker` host alias, and a first-line
`Include ~/.ssh/config.d/*` in `~/.ssh/config` (backing up an existing config first). If the new
key cannot yet reach the mini, install prints the public key and stops. On an existing client that
can reach the mini, run the printed `rdocker authorize-client '<public key line>'`, then rerun
`rdocker install` on Linux. The authorization command safely adds the key to the mini's
`~/.ssh/authorized_keys` once. Ensure `~/.local/bin` is first on PATH so `docker` uses the shim.

The forwarder runs as a systemd user unit, `rdocker-forwarder.service`, instead of a launchd agent.
To keep it active while logged out, optionally run `sudo loginctl enable-linger $USER` once. Linux
has no Docker Desktop, and rdocker never starts or stops the local engine. If a command truly needs
the local engine, start it yourself with `sudo systemctl start docker`.

**SDK callers bypass the shim.** dockerode, docker-py, testcontainers and anything that talks to a Docker
socket or calls docker by absolute path (not via PATH) get no routing: they use whatever the global
docker context points at (the daemon keeps it on `mini` while the mini is healthy). The daemon still
mirrors their published ports, but only after the fact (event-driven, not before the call returns).

## Database playbook (for agents)

> **Label every DB you need to outlive a pause.** The mini janitor **stops any running container with
> no traffic and no open connection for 3 h** (then removes it 24 h after it stops). A dev/test DB you
> come back to tomorrow, or one that sits quiet while you wait on a user, will be gone unless it carries
> a lifetime label:
> - `--label rdocker.keep=1` **plus a named volume** (label the volume too) — never idle-stopped, never
>   removed by the janitor; for data you care about.
> - `--label rdocker.ttl=<30m|6h|2d>` — lives exactly that long (the idle rule does not apply), then is
>   removed even if running; for throwaways that must survive a quiet spell.
>
> No label = the 3 h idle stop applies. See step 4. A janitor-stopped container is **started again
> automatically** the next time you `exec`/`cp`/`attach`/`top`/`port`/`logs -f` it (one stderr line
> `rdocker: restarted <name> (the janitor stopped it after 3 h idle)`) — but it is removed 24 h after the
> stop, so label anything you need longer. A `--rm` container is **deleted** by its idle stop and cannot
> be restarted.
>
> **On the laptop too:** a throwaway container the shim puts on laptop Docker Desktop (fallback, slow
> mini, `RDOCKER_MODE=local`, bind mount, `--network host`) gets `rdocker.placed=laptop-throwaway` and
> the laptop janitor applies the same idle/24 h/ttl rules to it. To keep a laptop DB, give it
> `--label rdocker.keep=1` **and a named volume** (that also makes it non-throwaway, so it is never
> stamped), or `rdocker pin` it.

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
   - no label → normal lifecycle below: **stopped after 3 h quiet**, removed 24 h later.
   Throwaway shape also matters when the mini is down: only throwaway containers fall back to the laptop.
5. **Clean up what you start:** `docker rm -f -v <name>` (the `-v` drops its anonymous volume). Then the
   mirror disappears within seconds.
6. **Speed:** each query pays the laptop↔mini round-trip (~1-5 ms at home; ~75 ms measured away from
   home, 50 sequential queries = 3.6 s). Prefer one `exec -i ... < file` over many small round-trips.
   A **query-heavy test suite** or a chatty write-heavy backend (row-by-row ORM writes, statement/lease
   timeouts) should not talk to a mini DB across that link: run the whole job on the mini with
   `rrun <cmd>` (next section; the known `test:db` commands are routed there automatically). Don't
   reach for `RDOCKER_MODE=local` for those.
7. Other engines (MySQL, Redis, Mongo, MinIO, ClamAV, ...) behave the same. `docker build`
   (incl. `--platform linux/amd64`) runs on the mini.

## Heavy test jobs on the mini (`rrun`)

`rrun [-e NAME[=VALUE]]... [--] <command> [args...]` (same as `rdocker run ...`) runs the command **on the
mini**, in a mirror of the current git worktree, so the test runner and its DB sit on the same machine
(measured: a 15-test DB file went from 673 s split across the link to ~12 s). Output streams back, the
exit code is the command's own, Ctrl-C works (1st: interrupt the remote command; 2nd: kill it; 3rd: drop
the connection).

- **Automatic:** a `PreToolUse` hook (`scripts/hooks/rrun-route.py`) rewrites known heavy commands
  (`rr_route_patterns`: `npm [--prefix X] run test:db[:rls]`, `release:rehearse:migrations`,
  `node .../test-with-db.mjs`, `check:db-all`, `node .../run-guard-tier.mjs`,
  `check:server-test-typecheck`, `tsc ... --noEmit`, a WHOLE `vitest run` suite - flags only, no file
  args; `vitest run a.test.ts` stays on the laptop) to `rrun <cmd>`. **By category**, so new script names
  need no new rule: every `check*` / `lint*` / `typecheck` / `verify*` and `test:*` npm script, a whole
  `jest`, and `eslint .` - except names with `e2e` / `playwright` / `browser` / `watch` / `:ui` (they need
  the laptop's browser or terminal). Dev servers (`dev`, `start`) and `build` stay local. Heads may also be
  `./node_modules/.bin/tsc|vitest`. The push also mirrors the local
  `origin/dev|main|master` (`rr_base_branches`), so diff-based guards resolve their base on the mini. It leaves anything unsure alone (`$(`, backticks,
  heredocs, pipes into it, non-`npm/node/npx/pnpm/yarn/bun` heads), and drops `RDOCKER_MODE=local`.
  Leading `K=V` assignments stay an env prefix and each name gets `-e K` (`FOO=1 npm run test:db` →
  `FOO=1 rrun -e FOO npm run test:db`), so values never enter rrun's argv; `RRUN_*`/`RDOCKER_*` only
  configure the laptop side. It also leaves the command alone when an assignment value has anything
  beyond `[A-Za-z0-9_./:@%+,=-]` (globs, `~`, `$`...), when it holds whitespace other than space/tab
  (`\v`, NBSP, ...), or when an earlier segment sets shell state (`export`, `set -a`, `source`/`.`,
  a bare `FOO=1;`) that would not reach the mini.
- **Opt out:** `RRUN=0 <cmd>` (the hook skips it, and `rrun` itself then runs locally). The hook also
  skips commands containing `real-od/`, `doctor-drive` or `--approve=browser`.
- **npm shim (catches scripts):** only a TOP-LEVEL npm (parent is a shell) is routed - npm spawned by a
  node runner / git hook / another npm script stays local (the parent job is the routed unit; 150 tiny
  `check:x` round trips cost more than they save). `rdocker install` also links `~/.local/bin/npm` (first on PATH) to
  `scripts/rdocker/npm-shim`: `npm [flags] run test:db|test:db:rls|release:rehearse:migrations|check:db-all|check:server-test-typecheck ...`,
  and a whole `npm test` / `npm run test` (no file args after `--`; with files it stays local) from
  ANYWHERE - a script, `bash -c "..."`, a subagent, a Makefile - becomes `rrun npm ...`, even with
  `RDOCKER_MODE=local` set. Every other npm call execs the real npm untouched. Skipped for `RRUN=0`, the
  hook's skip markers, on the mini, and inside rrun's own laptop fallback (it sets `RRUN=0`).
- **Wrappers:** `heavy-slot.sh <cmd>` (a laptop-only queue) is dropped - the job runs on the mini, which
  has its own slots. `timeout N` / `time` / `nice` / `caffeinate` stay outside: `timeout 600 rrun npm ...`.
  A `bash -c '<script>'` (single-quoted, only output redirects after it) has its script routed by the
  same rules, `RDOCKER_MODE=local` inside it included; a double-quoted script is left alone.
- **Safety net:** if a heavy npm script starts a container without going through `rrun`, the shim puts
  that container on the laptop (fast, instead of the slow split) and prints one hint to use `rrun`.
- **Logs:** laptop `~/.local/state/rdocker/route.log` (one line per decision, rrun lines with rc and
  seconds; rotated at 10 MB, ~1 week) and `daemon.log`; mini `~/rr/log/runs.log` (one line per run: time,
  repo, worktree, sha, argv head with env values redacted, outcome, prepare/command seconds; 0600,
  rotated at 5 MB).
- **Git state on the mini:** `git rev-parse HEAD` is the laptop's HEAD SHA; the checkout is detached
  (`--abbrev-ref HEAD` prints `HEAD`, not the branch); the working tree equals the laptop's (dirty files
  included), but the index is plain HEAD, so staged changes show as unstaged. Clean laptop -> clean mini.
- **What is copied:** git `HEAD` (pushed to `~/rr/git/<repo>.git` on the mini; the first push carries
  history, later ones almost nothing) **plus** every tracked file changed vs `HEAD` (staged or not),
  untracked non-ignored files, and deleted tracked files (removed on the mini). Of the gitignored files,
  **only test env files** go: `rr_env_allow` = `.env`, `.env.test*`, `.env.local`, looked up **only** in
  the repo root, the command's cwd and the deps (lockfile / `--prefix`) dirs - not at any other depth; one
  that resolves outside the worktree (e.g. a symlink to `~/secrets/.env`) is skipped with a
  `rrun: not copying ...` notice. Written 0600 and **deleted when the run ends** (leftovers of a killed run are deleted at the start of the next). Nothing else ignored travels:
  `node_modules` is installed on the mini, only in the nearest lockfile dir at or above the cwd plus any
  `--prefix` dir (not the repo root unless the command runs there; a command run AT the repo root also
  gets every first-level subproject that has a lockfile and is installed on the laptop - its scripts
  may load `server/` packages without naming them), and kept between runs: `npm ci` when
  the lockfile / `package.json` / `.npmrc` / node version changes (a lockfile out of sync with
  `package.json`, which `npm ci` refuses, gets `npm install` on the mirror instead); on a schema change (`*.prisma` in
  `./prisma` or the dir its postinstall's `--schema` names) the package's own postinstall reruns if it
  runs `prisma generate`, else `npx prisma generate`; no schema found -> nothing to generate.
- **Env:** laptop vars matching `rr_env_pass` (`CI`, `DEBUG`, `TEST_DB_*`, `VITEST_*`, `RR_NODE`) pass
  through; add more with `-e NAME=VALUE`, or `-e NAME` to forward that variable's value from rrun's own
  environment (keeps it out of argv; unset → skipped with a notice). Values travel on stdin, never in `ps`. The remote command sees
  `RRUN_REMOTE=1`, and its `docker` talks to the mini engine directly.
- **Containers it starts** with `docker run` / `docker create` carry `rdocker.rrun=<random per-run
  token>`: removed when the run passes or is interrupted, **kept on failure** for inspection (`rrun: the
  run failed; its containers stay ...`; `docker ps` / `logs` reach them; the 3 h idle rule reaps them).
  **Compose is not labelled:** containers a run starts with `docker compose up/run` are *not* removed at
  the end of the run and *are* mirrored to laptop localhost like any mini container; the normal janitor
  rules (3 h idle stop, exited 24 h) reap them - `docker compose down` them yourself when done.
- **How many at once:** one run per laptop worktree (a lock); on the mini always `rr_slots_base` (2)
  runs, and up to `rr_slots` (6) while the mini has room (free memory % >= `rr_spare_min_free_pct` 25
  and 1-min load per CPU <= `rr_spare_max_load` 1.5, re-checked every 5 s). A further run waits with
  one line naming the holder, and gives up after `rr_wait_min` (30) → exit 73.
- **Exactly once:** the mini prepares everything (checkout, overlay, `npm ci`, slot), then reports READY
  and waits; the command starts **only** when the laptop answers GO. Mini lost before GO was sent (push
  fails, or the link drops during prepare) → one immediate retry if the mini answers; if it does not
  answer, rrun **waits up to `rr_reconnect_wait_min` (10) for it to come back** and retries there (up
  to 3 tries; `RRUN_RECONNECT_WAIT=<s>` overrides) - only then, or for a repo it cannot send at all
  (not a git repo, no commit yet), it runs **on the laptop**
  with `RDOCKER_MODE=local` and a `rrun: ... - running on the laptop instead` notice - unless rrun was
  already stopped (Ctrl-C, or a tool timeout's TERM, also while waiting for the mini): then it exits
  128+signal and runs nowhere. `RRUN_STRICT=1`
  refuses that and exits 75. A shallow clone, or history the mini's `git fsck` rejects, also runs on
  the laptop, with the reason in the notice (`cannot send this repo to the Mac mini: ...`).
- **Mini lost once GO was sent** (even if it may never have arrived) → exit **75** (`rrun: lost the Mac
  mini mid-run - not re-running ...`). It is **never rerun automatically** (it may have half-run);
  rerun by hand once `rdocker status` is green. If the laptop vanishes, the mini stops waiting (before
  GO: nothing ran) or kills the run after `rr_hb_timeout` (60 s) without a heartbeat.
- **Exit codes of rrun itself** (only before the command started, so never confused with its own):
  65 the runner refused the request (bad input, unsafe path such as a symlinked mirror), 69 repo missing
  on the mini, 70 runner error, 73 slot busy past `rr_wait_min`, 75 lost the mini / strict fallback,
  **78 dependency install failed** (`npm ci` / `prisma generate`; its log is printed), 130 interrupted
  before start.
- **On the mini:** `~/rr` is 0700, excluded from Time Machine (`tmutil addexclusion`, once) and from
  Spotlight (`.metadata_never_index`).
- **Timing:** `RRUN_TIMING=1` prints per-stage times (push, overlay, remote prepare, command) on stderr.
  `rdocker status` has an `rrun` row (last run, runs in flight).

Troubleshooting: falls back to the laptop every time → `rdocker doctor` (the push over ssh is the
reachability test). Exit 73 → another run holds the mini slot (the wait line names it). Exit 75 → the
link dropped; check `rdocker status`, then rerun. Exit 78 → `npm ci` / `prisma generate` failed on the
mini (log above it); fix the lockfile / schema, or `RRUN=0` to run locally. Works locally but fails on the mini with a missing
file → it is gitignored and not an allowlisted env file: commit it, or generate it in the command. First
run in a repo is slow (history push + `npm ci`); later runs add ~1-3 s.

## What runs where (automatic)

Commands that name an existing container / compose project are **located first** (asked on both
engines), then routed to wherever it actually lives. If its location cannot be established, the shim
**refuses** (exit 1, `cannot tell where <name> lives ... - refusing to guess`) rather than run on the
wrong engine.

**Lone engine timeout:** a health reading saying the engine did not answer, right after (<= 2 min) a reading
where it did, is re-probed once before anything routes on it - a starved laptop (load 100+) makes single
probes time out, and that alone must not send throwaways to the laptop.

**Blip wait:** when that refusal is only because the mini's side is unknown (unreachable, engine silent,
or its `inspect` did not answer), the shim first prints `rdocker: mini not answering - waiting up to
30s...` and retries the lookup every ~3 s (a forced health probe each time, not counted toward the slow-
link readings) for up to `blip_wait_s` (default 30, counted from the first lookup). Mini back -> the
command routes normally and runs once; not back -> the same refusal as before. No wait when the ssh
master is alive but the tunnel fails (only the forwarder can rebuild it), for `RDOCKER_MODE=mini`
refusals, for the "not a throwaway container" refusal, or on paths that already work without the mini
(pinned laptop containers, throwaway fallback).

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
| containers / compose projects in the **pin list** (incl. fallback pins) | laptop (a pin is a hint; the real location wins). A pinned name found on the laptop keeps working while the mini is unreachable, slow or its engine silent; an **unpinned** laptop container stays refused for mutating commands then (the mini may hold a same-named one) |
| `ps` | both engines merged while the laptop engine runs (one header; exit non-zero if either failed) |
| other commands (`ps`, `images`, `build`, `pull`, ...) when the mini is unreachable / engine down | laptop, with a notice |
| any command except a **new throwaway** container, while the mini is reachable but slow (round-trip > 300 ms, `max_rtt_ms`, on the last **2 consecutive** health readings) | mini — RTT never moves `ps`/`rm`/`inspect`/`build`/... to the laptop |
| anything with `RDOCKER_MODE=mini` while the mini is unavailable | **refused, exit 1** — never falls back |
| anything with `RDOCKER_MODE=local` | laptop |

**Laptop Docker stays off.** Agents may not start it either: the `no-docker-desktop.py` hook blocks
`open -a Docker` / `open .../Docker.app` / AppleScript activate / `docker desktop start` (four sessions had
the habit, 2026-10-15) unless the command carries `RDOCKER_LOCAL_START=1`. Each block is logged with the
session id to `~/.local/state/rdocker/blocked-desktop.log`. The same hook blocks container sweeps by
pattern (`docker rm $(docker ps ... --filter name=...)`, `... | xargs docker rm`, `docker container|system
prune`): every agent shares the mini's engine, so a name-prefix sweep deletes other agents' containers
(twice on 2026-10-15). Remove only your own, by exact name; `RDOCKER_ALLOW_SWEEP=1` if the user asked. rdocker never opens Docker Desktop for a command (`local_autostart`
false; `RDOCKER_LOCAL_START=1 <cmd>` opts in for that one command), and the daemon quits it after
`local_idle_stop_min` (15) idle minutes. When auto mode would fall back to the laptop but Docker Desktop
is not running, the command instead waits up to `blip_wait_s` (30) for the mini and runs there, or exits 1
with "laptop Docker is off ... `rdocker doctor`"; a slow mini is used rather than booting the laptop.
`RDOCKER_MODE=local` while the mini is healthy prints a once-an-hour (per folder) hint to drop it. The
heavy-script safety net (laptop placement) also yields: with Docker Desktop off the DB goes to the mini.

**Fallback policy for creating commands** (`run`, `create`, compose `up/run/create`) when the mini is
unavailable and Docker Desktop is already running: they fall back to the laptop **only if throwaway** — `--rm`, or no named-volume mount and no
`rdocker.keep` label (compose: no named volumes, and the model must be readable). Otherwise exit 1 with
the reason ("... not a throwaway container ..."); retry when the mini is back, add `--rm`, or force the
laptop with `RDOCKER_MODE=local`. A slow (but reachable) mini still gets non-throwaway containers and
every non-creating command; only new throwaway containers move to the laptop for speed, and only once the
engine answered slower than `max_rtt_ms` on **2 consecutive** health readings (`health.json` keeps the last
3 round-trips in `rtt_hist`) - one slow sample never starts Docker Desktop. An engine that does not answer
at all still falls back at once. Containers / compose projects created by a fallback are
recorded in `pins.fallback` (so later commands find them on the laptop - `exec`, `stop`, `rm` keep working
while the mini is out or slow) and removed from it when the shim removes them (`docker rm` /
`compose down` on the laptop).

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
- **Mirror first:** the laptop side of every reserved port is bound (SSH mirror) right after the
  reservation, BEFORE `docker run` / `compose up` starts the container, and kept while the reservation
  lives. Reason: the Pane desktop app, when connected to the Pane daemon on the mini, mirrors every port
  that starts listening on the mini to laptop `127.0.0.1`/`::1` at the same number - it used to win the
  race and every new mirror failed as "laptop port N is busy" (2026-10-16). Pane steps to the next free
  number when the port is taken, so binding first keeps rdocker's same-number promise. A failed forward
  now logs ssh's own error and names the holding process (`held by <cmd> pid <n>`).
- **Mirror required:** if a mirror cannot be established after start (laptop port taken meanwhile, tunnel
  failure), the container **this command created** is removed (`rm -f`) and the command exits 1; a
  container that already existed (`docker start`) is left running. Foreground `run` / `compose up` are
  watched the same way.
- **UDP** (or any non-TCP) publish → exit **125** `UDP publishes are not mirrored to the laptop`.
- Only host IPs `127.0.0.1`, `0.0.0.0`, `::` or none are mirrored; `[::1]:<p>:<cp>` (or a specific
  other IP) runs on the mini with **no** laptop mirror.

## Automatic lifecycle (janitor, mini every 10 min, logged; laptop: see below)

| Thing | Rule |
|---|---|
| protection | `rdocker.keep` with **any value except `0`/`false`/`no`** (empty counts as keep) protects containers, volumes and images. The label is re-checked by a fresh inspect **immediately before every destructive call**. No `container prune` is ever issued; volume prunes carry `--filter label!=rdocker.keep` |
| running container with `rdocker.ttl` | removed (`rm -f`, plus `-v` unless a volume is keep-labelled) once running longer than the TTL; the idle rule below does not apply to it |
| running container, idle (no keep / ttl label) | stopped after **3 h** idle (`idle_stop_hours`; was 12 h before 2026-10-14). Idle = no eth traffic (`docker stats` NetIO unchanged) **and** no established TCP connection. Each sample adds at most 2 janitor intervals (sleep / outage never counts fully); unreadable samples hold the clock. Uses the mini's clock |
| stopped / exited container | removed after **24 h** with `rm -v` — or plain `rm` (volumes kept) if any of its volumes is keep-labelled |
| named volume not used by any container | removed after **30 days** unused |
| anonymous volumes not used by any container | pruned each run (keep-labelled exempt) |
| image | removed after **3 days** unused by any container (running or stopped) — tracked in a last-use ledger, first seen = now. Removed tag by tag (`image rm <repo:tag>`; an image tagged in several repositories cannot be removed by id), then by id if an untagged remainder is left; never `-f`. Docker's refusals (in use, dependent child images, multi-repo) are skips, not errors. Dangling images pruned |
| build cache | pruned when older than 7 d, and capped at **1 GB** |
| keep-labelled container on the mini with restart policy `no` | `update --restart unless-stopped`, so kept DBs come back after a mini / Colima reboot (`--rm` ones skipped) |
| `rrun` mirror on the mini (`~/rr/w/<repo>-<wt>`) | removed after **2 d** unused (every mirror not in use when mini free < `host_min_free_gb`, except one whose index/HEAD changed in the last 10 min); a mirror a running `rrun` is using is skipped (its slot's `.who` names it; an old-format `.who` without the mirror protects the whole repo, a stale or garbled one protects everything); bare repos in `~/rr/git` are kept, only the removed mirror's ref goes. Needs only ssh + perl, so it also runs while the mini engine is down |
| container logs | capped per container: 10 MB × 3 files (json-file) |
| mini Colima/Lima log files | truncated past 50 MB; VM journald capped at 200 MB |
| `rrun` shared package store (`~/rr/deps/<key>/node_modules`) | an entry is published after a real `npm ci` (written whole, then renamed in; never changed after) and **cloned** (APFS `cp -c`, shared blocks) into any mirror of the same repo whose lockfile/package.json/.npmrc/node/npm args match - no `npm ci`; removed after **2 d** unused (10 min under disk pressure) |
| npm cache on the mini (`~/.npm/_cacache`) | cleared above **1 GB**, only while no `rrun` run holds a slot |
| VM disk ≥ 80 % or mini free < 8 GB | remove unused images **oldest-unused first** (never in-use ones) until below, prune all build cache, log a WARNING |
| VM disk ≥ 90 % | also remove every stopped non-keep container (keep-checked) + prune anonymous volumes |
| failed action | logged; clocks are kept (not reset); `last_error` is written to `janitor.json` and raised as an attention item. The next clean full pass clears both |
| idle stop record | every idle stop is recorded (`stopped_by_janitor` in `janitor.json` / `laptop_janitor.json`). A later `exec`/`cp`/`attach`/`top`/`port`/`logs -f` at that container starts it first — only if it is still stopped **and has not run since** (`State.StartedAt` not after the stop) — waits up to 15 s for Running (mirrors its ports on the mini), prints `rdocker: restarted <name> (the janitor stopped it after <N> h idle)` (or `rdocker: tried to restart <name> but it did not come up`), then runs the command once. Names match exactly; an id must be >= 12 hex chars. A user `docker stop`/`rm` of the name clears the record, and a janitor pass that sees the container running drops it; a container the user stopped (or started and then stopped any way) is never auto-started. A `--rm` container is deleted by its idle stop and cannot be restarted. `rdocker status` lists the last 24 h of janitor stops |
| freed VM blocks | `fstrim` hands them back to macOS each run |

Run it now: `rdocker clean [--dry-run] [--only PREFIX] [--force-critical]` (`--only` limits the
container/volume rules to a name prefix and skips global prunes and image GC; `--force-critical` applies
the disk-critical stopped-container removal now — keep-labelled still exempt). Exit codes: 0 = the pass
ran; 1 = it did not run in full: mini lock still held after 90 s, mini unreachable over ssh, or the mini's
docker engine not answering (also with `--dry-run`). With the engine down but ssh fine, the mini disk
check and the `rrun` mirror housekeeping still run (their lines are printed) and only the
container/volume/image steps are skipped; the background janitor does the same every interval while the
mini is reachable. When the engine is down and mini free disk is below `host_min_free_gb`, the daemon's
engine kick runs the mirror housekeeping (under the mini lock) **before** it starts Colima, and logs it
(`kick: ... mirror housekeeping before the colima start`): a full disk is what kills the engine, and a
start on a full disk times out.
Hard ceilings: VM disk 30 GB, VM RAM 5 GB (the VM keeps whatever RAM it has touched, so this cap IS its footprint), VM CPU 6 — the mini itself can never be filled or starved.
Laptop logs (`daemon.log`, `route.log`) rotate at 2 MB (one `.1` generation, under a lock).

### Laptop janitor (Docker Desktop)

Desktop has no janitor of its own, so throwaways the shim placed there used to pile up. Now:
- **Stamp:** every throwaway-shaped `run`/`create` (`--rm`, or no named volume and no `rdocker.keep`) the
  shim sends to the laptop gets `--label rdocker.placed=laptop-throwaway`, whatever the reason (fallback,
  slow mini, `RDOCKER_MODE=local`, bind mount, `--network host`). Non-throwaway containers and **compose
  services are never stamped** (so the laptop janitor never touches compose projects).
- **Scope:** only stamped containers (`ps -a --filter label=rdocker.placed=laptop-throwaway`). Immediately
  before each stop/rm it re-checks: a manual pin (`rdocker pin`, or the container's compose project
  pinned) or `rdocker.keep` on the container or any of its volumes → skipped.
- **Rules (the mini's):** idle `idle_stop_hours` (3 h: no NetIO change and no established connection,
  checked on the laptop engine) → stop; stopped 24 h → `rm -v` (anonymous volumes only); `rdocker.ttl`
  honoured. Containers only: no volume/image/prune work.
- Daemon job `laptop-janitor-run`, every `janitor_interval_min`, only while Desktop is running (never
  starts it), whatever the mini's health. State `laptop_janitor.json`; `daemon.log` lines start with
  `laptop janitor:`; a failure raises the attention item `laptop-janitor-error`.
- Opt out: `--label rdocker.keep=1` + a named volume, or `rdocker pin <name>`.

## Health

Health = raw HTTP `GET /_ping` (then `GET /version` for the server version) straight to the forwarded
mini docker socket over the SSH tunnel - no docker CLI subprocess, whose start-up used to add ~250 ms
(4 s timeout; the `/_ping` round-trip is the RTT),
never a raw probe of the mini's `:22`. A reading is reused for 30 s. If the probe fails, `ssh true` over
the existing master decides: tunnel alive → engine problem (tunnel and mirrors left alone); no answer →
the master may just be busy (a big image transfer), so it is **kept**: only the forwarder rebuilds a master
that `ssh -O check` still reports alive, and only after the liveness check failed on **3 consecutive**
forwarder checks spanning **≥ 45 s** (then the probe is retried once). A master that is gone (`-O check`
fails, socket dead) is rebuilt at once; a `-O check` that times out on a live control socket counts as
busy, not gone. Master creation is serialized across every process by an exclusive lock
(`~/.local/state/rdocker/master.lock`) and re-checked after the lock is taken, so concurrent shims and the
forwarder start exactly one master. Auto mode treats round-trips over **300 ms** (`max_rtt_ms`) on 2
consecutive readings as slow, which only sends new throwaway containers to the laptop.

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
| `rdocker doctor` | status **+ repair** (Tailscale on macOS, mini engine start via the kick path — never a VM-up restart, forwarder, mirrors) + flag-drift check |
| `rdocker clean [--dry-run\|--only P\|--force-critical]` | run the janitor now; exit 1 if it could not run in full: mini lock held after 90 s, mini unreachable, or mini engine not answering (`--dry-run` too; the disk check + `rrun` mirror housekeeping still run then) |
| `rdocker use auto\|mini\|local\|off` | routing mode; also points the global docker context at the target (`off` = raw local Docker context) |
| `rdocker where <container>` | which engine holds it (says which engine could not be asked) |
| `rdocker pin\|unpin <name> [--compose]` | keep a container / compose project on the laptop |
| `rdocker logs [--route]` | forwarder + janitor log / per-command routing log (incl. refusals) |
| `rdocker sync` | reconcile port mirrors now |
| `rdocker run [-e K[=V]]... [--] <cmd>` / `rrun ...` | run a heavy job (test runner + its DB) on the mini — see "Heavy test jobs on the mini" |
| `rdocker install` | create the SSH key and host alias if missing, verify mini access, then install the Docker context, shims, and background forwarder (launchd on macOS, systemd user unit on Linux) |
| `rdocker authorize-client '<public key line>'` | on an existing client, add a new client's validated SSH key to the mini once |

`rdocker status` rows: tailscale on laptop · mini reachable (ssh control connection) · mini docker engine
(version, round-trip) · mode → where commands go · docker shim first on PATH · background forwarder ·
daemon process (pid, age, running the code on disk / reload pending / reload NOT picked up) · health
reading age · janitor last run · janitor last error (`--` only if from about the latest pass) · mini
disk · mini engine config (Colima restart pending) · janitor-stopped in the last 24 h (mini + laptop,
auto-restarted on use) · fallback pins · mirrored ports (IPv6 mirror
pending) · port conflicts (busy on laptop) · laptop Docker Desktop (local docker engine on Linux) · global docker context · (doctor)
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
   - **"cannot tell where ... lives"** → the shim already waited up to `blip_wait_s` (30 s) for the mini;
     check `rdocker doctor`; don't force the laptop for a container that may live on the mini.
   - **shim not first on PATH** → `~/.local/bin` must precede `/usr/local/bin` (it does via `~/.zshrc`).
3. Never move pinned data, delete `rdocker.keep` things, or resize the mini VM without the user.

## Verify

- Unit (~370 tests, fake docker `tests/fake_docker.py`, no mini needed, hermetic temp `RDOCKER_HOME` +
  fail-closed stubs via `tests/rdmods.py`; files `test_args`, `test_daemon`, `test_engine`, `test_entry`,
  `test_janitor`, `test_laptop_janitor`, `test_ports`, `test_shim_safety`, `test_state`, `test_tunnel`,
  `test_zz_hermetic`; rrun: `test_run` (laptop side end to end through a fake ssh), `test_runner`
  (`rr_runner.pl`: READY/GO handshake, heartbeat kill, INT, env-file deletion, keep-on-failure,
  symlink refusals, tmutil exclusion), `test_hook` (hook rewrite matrix incl. adversarial inputs)):
  `cd ~/.claude-dotfiles/scripts/rdocker && /usr/bin/python3 -m unittest discover -s tests`
- Live end-to-end (self-cleaning, removes only the `rde2e-<pid>-*` containers it created, non-disruptive by default):
  `bash ~/.claude-dotfiles/scripts/rdocker/tests/e2e.sh` (incl. a check that `-p <port>:80` with no IP
  still binds only the mini's loopback, i.e. the Lima override wins, and rrun cases on a throwaway repo:
  exit-code passthrough, `RRUN=0` local, env file copied then deleted, label cleanup on success; skipped
  when `~/.local/bin/rrun` is absent). `E2E_DISRUPTIVE=1` adds the tunnel-kill
  self-heal case (kills the shared SSH master — other windows' docker calls blip).

## Setup record (done 2026-10-12 — for a rebuild)

**Host since 2026-10-22: Nick's Mac mini** (`nicholass-mac-mini`, Tailscale 100.112.247.23, user
`nicholaspardon`, macOS 15.6, 16 GB). Set up over ssh with the `setup-mini` script (Homebrew colima +
docker as Nick's user only, VM 6 CPU / 5 GB / 30 GB, `brew services` at login, the same docker block +
Lima override; one PATH line in `~/.zshenv`; Nick's `~/.claude` and `~/dotfiles` untouched). The
laptop's `Host macmini-docker` block now says `HostName 100.112.247.23`, `HostKeyAlias
nickmini-docker`, `User nicholaspardon` (config `remote_socket`
`/Users/nicholaspardon/.colima/default/docker.sock`). The 11 long-lived DBs were copied volume by
volume and verified (database list + table counts); the originals stay **stopped, restart=no** on the
old mini (`ssh oldmini-docker`) as a backup. FileVault is on there too: after a reboot someone logs in
once. Keep ssh backups OUT of `~/.ssh/config.d/` (everything in it is Included; a stale backup block
there supplied a wrong `HostKeyAlias` during the switch) - they live in `~/.ssh/rdocker-backups/`.

Previous mini (Omid's, until 2026-10-22): the Tailscale app (`brew install --cask tailscale-app`, since 2026-10-16, opens at login; the
Homebrew formula was removed and `/opt/homebrew/bin/tailscale` is a wrapper for the app's CLI), machine name `macminim4`, IP 100.73.250.43, key expiry off;
the laptop's `~/.ssh/config.d/rdocker` maps alias `macmini-docker` -> `HostName macminim4` with
`HostKeyAlias macmini-docker`, `User omidsmacmini`, `IdentityFile ~/.ssh/rdocker_ed25519`,
`ControlMaster auto`, `ControlPath ~/.ssh/rdocker-%C`, `ControlPersist 30m`,
`ServerAliveInterval 15`, `ServerAliveCountMax 3`, `ConnectTimeout 5`, and
`StrictHostKeyChecking accept-new`,
Remote Login on, laptop keys in `~/.ssh/authorized_keys`. Laptop: `~/.ssh/config` → `Include
~/.ssh/config.d/*` (`rdocker` block); `rdocker setup-mini 6 8 30`; `rdocker install` (context `mini` =
`unix://~/.local/state/rdocker/mini-docker.sock`, shims, launch agent, pins). Mini Colima config:
`~/.colima/default/colima.yaml` `docker:` ip 127.0.0.1, log caps, BuildKit GC 1 GB;
`~/.colima/_lima/_config/override.yaml` port-forwards → 127.0.0.1, guest port 53 ignored.
`rdocker setup-mini` rewrites both idempotently and never restarts Colima itself: it sets
`restart_pending` in `janitor.json`, and the janitor restarts Colima only when `docker ps` on the mini
is empty, re-checked under the mini lock right before the restart.

**Known limits:** the Tailscale app starts at login, so after a mini reboot the network comes up only
once someone logs in (FileVault needs that login anyway).
`host.docker.internal` inside a mini container is the mini, not the laptop.

Source: `scripts/rdocker/` (stdlib, /usr/bin/python3 3.9). `rdocker.py` is a thin entry (launchd,
`~/.local/bin/rdocker` and `docker-shim` — which resolves its own real dir through the symlink — all
run it); code in `rd_common` (paths, config/state, locks, logs) → `rd_args` (per-subcommand flag
tables) → `rd_tunnel` (health, SSH master, port mirrors) → `rd_route` (shim routing) → `rd_janitor`
(janitor, mini lock, engine kick/restart) → `rd_daemon` (forwarder loop) → `rd_setup` (install,
setup-mini, CLI). Docker CLI flag research: `docs/docker-cli-semantics.md`. Brief:
`random/tools/online docker/tmp/briefs/2026-10-12-remote-docker-on-mac-mini.md`.
