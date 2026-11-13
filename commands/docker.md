---
description: Remote Docker on the fleet's always-on Docker host (the `home` machine in scripts/rdocker/fleet.json), still called "the mini" throughout (rdocker). Plain `docker` / `docker compose` on this laptop already run on the mini over Tailscale, with published TCP ports mirrored to laptop localhost, and a janitor cleans up after agents — so use docker normally. Heavy DB test jobs (`npm run test:db` and similar) run code + DB together on the mini via `rrun <cmd>`, usually rewritten automatically by a hook. Invoke this BEFORE starting test databases or other containers (it has the database playbook: ports, readiness, lifetime labels, keeping data), when docker errors / hangs / "cannot connect" / refuses with "cannot tell where … lives" or "not a throwaway container", when a container port on localhost is unreachable, to check where a container runs, to switch remote/local mode, or to set up / repair the mini Docker host.
---

# /docker — Docker on the fleet's Docker host, transparently

**Arguments:** `$ARGUMENTS` (optional: `status`, `doctor`, `clean`, `use <mode>`, `where <name>`, or plain English).

**Naming:** the Docker server is the fleet's Docker host: the machine with the `home` role in
`scripts/rdocker/fleet.json` (the source of truth for which machine that is). This file and `rdocker`
output still call it "the mini", and "the laptop" means the Mac you are on. Every Mac is a client.

**Running ON the Docker server (the fleet's Docker host)?** (`~/.local/bin/docker` missing.) Then docker is
its own local engine and nothing here routes it: no shim, no port mirrors, no `rrun`, no `rdocker`
command. Use docker normally. The Macs' janitor still sweeps this engine, so a DB that must survive
3 h of quiet needs `--label rdocker.keep=1` + a named volume (or `rdocker.ttl=...`), as below.

## The mental model

The laptop (16 GB) offloads container CPU+RAM to the always-on **Docker host** (ssh alias `macmini-docker`, a name kept from when it was a Mac; the current host is the `home`
machine in `scripts/rdocker/fleet.json`; earlier Mac hosts are now clients with Colima stopped). It is the ONLY Docker engine; images run natively as linux/amd64, so an arm64-only image will not run. Normally agent/test-runner
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
7. **Repo policy + run-local Postgres lane (`rr_pg_lanes` in rd_common; today one repo: DAVID, top-level
   package.json name `david`).** For EVERY rrun command of such a repo, whatever it runs:
   - no env file reaches a worker's checkout: `.env*` (except `*.example` / `*.sample` / `*.template`) is left out
     of the overlay, and the push itself (rrun's and the warmer's) is refused, exit 65 needs-human, when one is in
     the index, in the commit pushed or in a base commit pushed with it; the worker re-checks its whole mirror
     before installing. Known limit: older commits reachable from those are not scanned, so a secret once
     committed can sit as a git blob in our own worker's bare repo; it is never checked out or sourced.
   - no `*DATABASE_URL*`, `PG*`, `TWILIO_*`, `RETELL_*`, `OPENROUTER_*` or `SEED_ALLOW_REMOTE` variable you pass is
     forwarded (names noted, never values), and a command whose argv sets one (`NAME=value`, also via `env`) is
     refused, 65. A repo's own committed scripts are its code: they are not inspected.
   - every command gets a fresh Postgres unless it is a proven tsc form above (unknown = Postgres). Before the
     command starts: `postgres:16-alpine` on the worker (`rr-pg-<run id>`, tmpfs data, published on 127.0.0.1
     only), `DATABASE_URL=postgres://david:${password}@127.0.0.1:<port>/postgres` (the lane's throwaway password is `david`), `pnpm db:migrate`, `pnpm
     db:provision` (output to a log; only a redacted tail if it fails: exit 79, class fail), then
     `DATABASE_URL_APP` must read exactly `postgres://david_app_login:${pw}@127.0.0.1:<that port>/postgres` or the
     run is refused (65). `MESSAGING_TRANSPORT=CALL_TRANSPORT=echo`. The container is removed by its id at the end,
     pass or fail. The app password is generated per run, exists only inside that container (loopback, tmpfs)
     and dies with it, so test output is relayed as is. Type the normal command (`pnpm --filter @david/hammer
     exec vitest run src/x.test.ts`); `rrun --where` shows `run-local postgres:16-alpine`.
8. Other engines (MySQL, Redis, Mongo, MinIO, ClamAV, ...) behave the same. `docker build`
   (incl. `--platform linux/amd64`) runs on the mini.

## Heavy test jobs on the mini (`rrun`)

`rrun [-e NAME[=VALUE]]... [--] <command> [args...]` (same as `rdocker run ...`) runs the command **on the
mini**, in a mirror of the current git worktree, so the test runner and its DB sit on the same machine
(measured: a 15-test DB file went from 673 s split across the link to ~12 s). Output streams back, the
exit code is the command's own unless rrun itself decided the result (see **Exit codes and result
classes** below: the line `rrun: <class> (...)` right after the output always says which), Ctrl-C works
(1st: interrupt the remote command; 2nd: kill it; 3rd: drop the connection).

**Heavy dev work runs on the compute pool automatically - just type the normal command.** A
`PreToolUse` hook (`scripts/hooks/rrun-route.py`) rewrites every heavy one-shot dev command an agent
types into `rrun <cmd>`, and rrun picks the best worker in the pool (the worker machines listed in
`fleet.json`) and falls back by itself. The hook covers the common commands
listed below; for any other heavy command, prefix `rrun` yourself (`rrun <cmd>`). Do not look for
another way to get compute. `rrun --where <cmd>` shows which worker it would pick and why.

- **Automatic (what is rewritten):** one-shot type-checks, tests, lint and DB jobs, in a git repo:
  - `npx [--prefix X] tsc` with `--noEmit`, or with `-p`/`-b` configs that all set `"noEmit": true`
    (an emitting `tsc` stays here: its output would land on the worker);
  - `npx vitest run ...` (any files), `npx jest ...`, `npx eslint ...`, and the same through
    `./node_modules/.bin/<tool>` or an absolute `/.../node_modules/.bin/<tool>` inside the worktree
    (rewritten relative to the cwd, e.g. `rrun ./node_modules/.bin/tsc ...`: the laptop path does not
    exist on the worker). Only for a `node_modules` rrun installs there (the nearest npm lockfile dir
    at or above the cwd, or from the repo root a first-level package with its own npm lockfile); any
    other path (`/usr/local/bin/vitest`, another repo, a dir with no lockfile) stays here;
  - `npm test` / `npm t` / `npm run test*` / `typecheck*` / `type-check*` / `lint*`, when package.json
    defines the script and its body does not watch, serve, fix or write files;
  - `npm run build` in a package dir `rr_outputs` maps (rrun copies the output back), and everything in
    `rr_route_patterns`: `npm [--prefix X] run test:db[:rls]`, `release:rehearse:migrations`,
    `node .../test-with-db.mjs`, `check:db-all`, `node .../run-guard-tier.mjs`,
    `check:server-test-typecheck`, `tsc ... --noEmit`, a whole `vitest run` / `jest` suite, `eslint .`,
    `node --max-old-space-size=NNNN`, and **by category** every `check*` / `lint*` / `typecheck` /
    `verify*` and `test:*` npm script.
  - **pnpm** (2026-11-13; every pnpm repo, not only DAVID: workers install a pnpm lockfile with `pnpm install
    --frozen-lockfile` through corepack). ONLY these exact shapes, judged on the shell-decoded words, with
    nothing before them and no quoting: `pnpm [-r|--recursive] typecheck`, `pnpm typecheck` (in a package),
    `pnpm --filter|-F <pkg> test|typecheck`, `pnpm --filter <pkg> exec vitest run [args]`, and in a package
    dir `pnpm exec vitest run [args]` / `npx vitest run [args]` / `vitest run [args]` (rewritten `rrun pnpm exec
    vitest run ...`). [args] = test file paths, `-t` / `--testNamePattern <name>`, `--reporter=<x>`. A script
    form reads only the target package's script, which must be exactly `vitest run [files]` or `tsc --noEmit
    [-p X] [--pretty false]`, with no pre/post script. Anything else (root scripts, `pnpm lint`, `-u`,
    `--`, an assignment, a wrapper) runs here; prefix `rrun` yourself if you want it on the pool.
  - Prefixes and plumbing are kept: `cd x && npx tsc --noEmit` -> `cd x && rrun npx tsc --noEmit`;
    `FOO=1 npx vitest run a` -> `FOO=1 rrun -e FOO npx vitest run a` (values stay an env prefix, never in
    rrun's argv; `RRUN_*`/`RDOCKER_*` only configure this side; `RDOCKER_MODE=local` is dropped); pipes
    and redirects after the command (`| tail -20`, `> log 2>&1`) still run here on the streamed output;
    each heavy segment of a `&&` / `;` chain is rewritten on its own; `timeout N` / `time` / `nice` /
    `caffeinate` stay outside rrun; `bash -c '<script>'` (single-quoted) has its script routed by the
    same rules.
- **Never rewritten (they run here, as typed):** watch / interactive runs (bare `vitest`, `--watch*`,
  `-w`, `jest --watch`, `tsc -w`, `--ui`); dev servers (`npm run dev`, `npm start`, `vite`,
  `vite preview`, `next dev`, scripts named `dev` / `start` / `serve` / `preview` / `watch`); installs
  (`npm install` / `ci` / `add`); browser / e2e scripts (`e2e`, `playwright`, `browser`, `:ui`);
  runs that write files you then read here (`--coverage`, `--fix`, `-u` / `--update`, `--outputFile`,
  `eslint -o`, `--outDir`, an emitting `tsc`, `lint:fix` / `format` / `coverage` scripts); builds rrun
  would not copy back (`vite build`, `pnpm build`, `npm run build:*`, an unmapped package dir);
  `yarn` / `bun` and yarn / bun projects; any pnpm command that is not one of the exact shapes above; bare
  `tsc` / `vitest` / `eslint` / `jest` in an npm project (a worker's PATH has no `node_modules/.bin`; use `npx`);
  `ssh ...`, `docker ...`, heredocs, `$(...)` / backticks, a command fed by a pipe, an unknown cwd
  (`cd $D`) or no git repo; an earlier segment that sets shell state (`export`, `set -a`,
  `source`/`.`, a bare `FOO=1;`); an assignment value beyond `[A-Za-z0-9_./:@%+,=-]`; whitespace other
  than space/tab. When the hook is unsure it leaves the whole command alone, and it never breaks a
  command: any internal error passes it through unchanged.
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
  repo, worktree, sha, outcome, prepare/command seconds, argv head with env values redacted; then, since
  2026-11-11, a TAB and `run=<uuid> owner=<session:...|pid:...> cls=<class> wait_s=<s before the slot:
  client waits + slot wait> exit_reason=pass|fail|cap|stalled|lost|busy|refused|abandoned-setup|moved|warm
  setup=warm|clone|cold pred_s=<s> client=<sha> pv=<pool version> node=<node major the job ran, - if unknown>
  lock_s=<s> slot_s=<s>`; `stalled` is reserved. The two waits inside `wait_s`, apart (2026-11-13):
  `lock_s` = the client's wait for a worktree lane on its Mac (`-` from an older client), `slot_s` = the
  worker's own slot wait.
  **Truthful outcomes:** `lost rc=N` = a started command whose client never came back (no reattach);
  `abandoned-setup` = the client left during the prepare or slot wait; `moved` = it left to re-plan
  elsewhere; `warm` = a background prepare (`rdocker warm`). Rows before 2026-11-11 wrote a bare `lost`
  (or `interrupted`) for the pre-start cases: every reader (the scheduler, rd-doctor, the steward)
  counts those as abandoned, never against the worker. Times carry their offset: workers keep
  different time zones, so compare parsed times, never raw strings.
  The new fields come after argv because every existing parser anchors each field to the next one; the
  dashboard reporter shows them at the end of its argv column. 0600, rotated at 5 MB). Each `route.log`
  rrun line ends with a TAB and the client's stage timings (see Timing below).
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
  **Local packages** (`file:` / `link:` dependencies that are directories inside the repo, found in
  that dir's `package.json` and, transitively, in theirs) are linked, not installed, so their build
  output (an ignored `dist/`) lives outside `node_modules` and outside the lockfile. rrun hashes each
  one's source (tracked + untracked-not-ignored files, so dirty edits count; ignored files and
  `node_modules` do not) and, when it changed without an `npm ci` (or `node_modules` came from the
  shared store), reruns what `npm ci` would: each local package's own `preinstall` / `install` /
  `postinstall` / `prepare`, dependencies first, then the depending package's (`rrun: local package
  source changed (...) - rebuilding`). A failed rebuild is exit 78; the command never runs on a stale
  build. Before 2026-11-07 it did (dentall `server` -> `@summit/staff-signin-core`: `... is not a function`).
- **Env:** laptop vars matching `rr_env_pass` (`CI`, `DEBUG`, `TEST_DB_*`, `VITEST_*`, `RR_NODE`) pass
  through; add more with `-e NAME=VALUE`, or `-e NAME` to forward that variable's value from rrun's own
  environment (keeps it out of argv; unset → skipped with a notice). Values travel on stdin, never in `ps`. The remote command sees
  `RRUN_REMOTE=1`, and its `docker` talks to the mini engine directly.
- **Containers it starts** with `docker run` / `docker create` (and networks / volumes from `docker
  network|volume create`) carry `rdocker.rrun=<random per-run token>` (the command has it as
  `$RRUN_DOCKER_LABEL`): removed when the run passes or is interrupted, **kept on failure** for
  inspection (`rrun: the run failed; its containers stay ...`; `docker ps` / `logs` reach them; the 3 h
  idle rule reaps them). A container the job labels `rdocker.keep` is never removed by run cleanup.
  **Compose is not available inside `rrun` pool jobs:** `docker compose ...` there exits 1 with
  `rrun: docker compose is not available in rrun pool jobs (use docker run; see /docker)`. A compose
  project is the one handle that can reach another run's stack, and no argv check held up under review.
  Start test databases with `docker run` (this playbook). Compose on your own Mac is unaffected.
- **Docker scope on the shared worker engine (2026-11-11):** a job may only `rm` / `remove` / `stop` /
  `kill` / `restart` containers and `rm` / `remove` networks and volumes it created itself (its label). Every target is checked with `docker inspect` and only the object's
  immutable id (full 64 hex) is passed on. Another run's object is **refused by name and the command exits 1**:
  ``rrun: refused `docker rm -f pg-other`: container pg-other is not this run's ...`` (its own targets
  in the same command still go). A target that does not exist is dropped (silently with `-f`, like
  docker); an inspect that fails for any other reason refuses the whole command; a command with no
  targets at all goes to docker as it is (its own usage error). `docker container|network|volume prune` is refused
  unless scoped with `--filter label=$RRUN_DOCKER_LABEL`; `docker system prune` is always refused. This
  is what ended "my test DB vanished mid-run": another run's harness cleanup can no longer reach it, so
  `TEST_DB_KEEP_CONTAINERS=1` is no longer needed for that. A harness whose cleanup lists every matching
  container (`docker ps -aq --filter name=...`) now gets exit 1 for the others' - scope it with
  `--filter label=$RRUN_DOCKER_LABEL`.
- **How many at once:** up to **3 runs per laptop worktree** at once (fleet.json top-level `wt_lanes`,
  1-8; 2026-11-13: before, one, and an agent fanning out subagents queued them while workers sat idle).
  Each concurrent run of a worktree is a **lane**: its own lock (`rrun-<wt12>[.<k>].lock` in the state
  dir), its own worker mirror and push ref (`<repo>-<12 hex>` / `refs/rrun/<12 hex>`, lane 0 = the
  worktree's own), so runs never share a checkout. A run that writes into the worktree - a build that
  copies outputs back (`--outputs`), a local fallback - holds the worktree's **gate** (`rrun-<wt12>.gate`)
  exclusive and runs alone; every pool run holds it shared. A run's mode is chosen once and never changes
  (a local fallback gives the pool run's hold back only after it is over, then takes the gate exclusive).
  Pushes to one worker go one at a time from each Mac (they share the base-branch refs); a push that
  cannot get its turn within `rr_push_timeout_s` fails that attempt like an unreachable worker. When
  every lane is busy (or a writer runs) the run polls and says why, how many run and how long it has
  waited: `rrun: waiting for this worktree: this worktree runs at most 3 rrun jobs at once (fleet.json
  wt_lanes); 3 running; waited 1 min (<argv> on hp, running 2 min, owner X, its cap ends it within 28
  min; ...); gives up after 30 min (exit 72)`. There is no queue: the first to poll a freed lane takes it,
  and a writer can wait behind a stream of runs until its wait ends (exit 72). On a worker: always `rr_slots_base` (2)
  runs, and up to `rr_slots` (6) while the mini has room (free memory % >= `rr_spare_min_free_pct` 25
  and 1-min load per CPU <= `rr_spare_max_load` 1.5, re-checked every 5 s). A further run waits and
  says so **every `rr_status_every_s` (60 s)**: `rrun: waiting for a slot on hp: 4 of 4 slots busy; held
  longest by <repo> (<owner>) for 120s; 2 other runs waiting ahead of this one; expected wait ~5 min;
  tries elsewhere after 2 min` (the expected wait is the scheduler's queue estimate for that worker).
  **One worker's slot wait is short:** after `rr_slot_wait_s` (120 s) its runner answers busy and rrun
  re-plans from a fresh probe (another worker may have freed up), round after round, until
  `rr_wait_min` (30) in all → exit 73. A worker that refuses (share off, no Docker) is skipped, never
  waited for. A run waiting for a **worktree lane** says so the same way, naming the runs that hold
  them (command, worker, how long, owner, and when its cap ends it), and waits at most the job's own cap
  (`rr_wt_wait_min` overrides) → exit **72**. The lock file is never deleted.
- **Hung and silent jobs (2026-11-11).** The command's stdout/stderr are pipes the runner relays, never
  the ssh session itself. When the command's **main process exits**, whatever it left behind (a DB,
  a vitest worker, a dev server) gets `rr_exit_grace_s` (10 s) to finish, then the job's process group
  is TERMed, KILLed 10 s later and checked empty before the slot is freed; rrun returns the main
  process's exit code and releases its worktree lane. A leftover that left the group can hold only the
  runner's pipe, which it stops reading. If ssh still stays open 45 s after the exit code arrived,
  rrun closes it itself. `git push` to a worker is capped at `rr_push_timeout_s` (300 s; then that
  worker counts as unreachable and the job moves on).
  **Silence never kills, it only tells:** after `rr_silent_min` (1) minute without output rrun prints
  `rrun: no output for 1 min (worker hp, running 25 min; last test file src/a.db.test.ts, named 1 min
  ago)` on stderr, then every 5 min more (`RRUN_SILENT_MIN=<min>`, 0 = off). The last test file is the
  last `*.test.*` / `*.spec.*` path the output named (vitest / jest per-file lines), so a hang after a
  file says where it is. A slot wait prints one full line, then one short line a minute
  (`rrun: still waiting for a slot on hp (3 min so far; next in line; expected wait ~2 min)`).
  **Hard cap per job class:** light / normal 30 min, heavy 60, db 90, build 60 (`rr_timeout_min`);
  `RRUN_TIMEOUT=<minutes>` sets another cap for one run, `RRUN_TIMEOUT=0` none. Every `test:db:<x>`
  script (`test:db:migrated`, `test:db:rls`, ...) is a db job. At the cap the worker TERMs the
  command's process group (KILL 10 s later, then checks it is empty), frees the slot, logs `outcome=timeout rc=124` in `runs.log`, and
  rrun exits **124** (like `timeout(1)`) with `rrun: infra (exit 124 ...; hit its 30 min wall-clock cap
  on hp ...)`. A command's own `timeout` that exits 124 is reported `fail`, never `infra`: the class
  line tells them apart. Never re-run, never cached. (If the worker never reports it, rrun closes the
  session itself 90 s past the cap, also exit 124.)
- **Who owns a job.** Every job carries its caller: `session:<CLAUDE_CODE_SESSION_ID>` (else
  `pid:<parent pid>`), the window's `/line` caption (`~/.claude/session-status/<id>.txt`, one file
  read) and this machine's name. On the worker it is in `~/rr/slots/<i>.own` (beside `<i>.who`, which
  keeps its 4 fields), the runner's process title (`rrun-runner owner=session:... window=... from=...`)
  and the command's env (`RRUN_OWNER`). **`rrun --jobs`** lists every running job on every worker
  (worker, start, running, owner, from, command); **`rrun --mine`** only yours. `rdocker status` has an
  `rrun job` row per run of this machine (worker, start, owner, pid, command). **Never kill a job that
  is not yours**: check the owner first.
- **Exactly once:** the mini prepares everything (checkout, overlay, `npm ci`, slot), then reports READY
  and waits; the command starts **only** when the laptop answers GO. Mini lost before GO was sent (push
  fails, or the link drops during prepare) → one immediate retry if the mini answers; if it does not
  answer, rrun **waits up to `rr_reconnect_wait_min` (10) for it to come back** and retries there (up
  to 3 tries; `RRUN_RECONNECT_WAIT=<s>` overrides) - only then, or for a repo it cannot send at all
  (not a git repo, no commit yet), it runs **on the laptop**
  with `RDOCKER_MODE=local` and a `rrun: ... - running on the laptop instead` notice - unless rrun was
  already stopped (Ctrl-C, or a tool timeout's TERM, also while waiting for the mini): then it exits
  128+signal and runs nowhere. In a pool (2+ workers) heavy and DB jobs never run on this machine
  (exit 75 instead); light jobs run here only when every worker stayed busy `rr_local_after_s`; a
  normal job runs here only when every worker is unreachable. `RRUN_STRICT=1`
  refuses any local run and exits 75. A local run is the plain command (`exec`): its exit code is the
  command's own and no class line follows it. A shallow clone, or history the mini's `git fsck` rejects, also runs on
  the laptop, with the reason in the notice (`cannot send this repo to the Mac mini: ...`).
- **Link lost once GO was sent → rrun reattaches (2026-11-11).** The started command does not depend
  on the ssh session: on the worker it runs detached (its own session), its output spooled to
  `~/rr/spool/<run-id>.out/.err` and its exit code to `<run-id>.rc` (run id: a uuid4 from the client).
  When the link drops, rrun prints `rrun: lost the link to <worker> mid-run; reconnecting (1 of 3) - the
  command keeps running there`, connects again with a **fresh ssh of its own** (never the shared
  `rr-%C` master, whose death took every session down at once), up to `rr_reattach_tries` (3) within
  `rr_reattach_window_s` (120 s; waits `rr_reattach_backoff_s` 0 / 10 / 30 s first), then `rrun:
  reconnected to <worker>; the output goes on from where it broke off` - the rest of the output (no
  byte twice) and the command's **real exit code**. If GO never arrived there, the runner's own signed
  record says so and it counts as lost *before* the start (safe to run elsewhere). If the worker has
  no proof either way (its spool is gone), rrun says `the run's result is lost there ...; it may have
  run, so it is not re-run automatically` - exit **76**, never a re-run. A Ctrl-C / TERM during the
  reconnect ends it (128+signal), never a re-run. Only when every reconnect fails do the old rules
  apply: exit **76** (`lost hp mid-run and could not reconnect; it may have run there ...`), or one
  re-run on another worker for a job that is safe to repeat (tsc, lint, vitest/jest, builds, DB jobs in
  a pool). The worker side: before GO a lost laptop means nothing runs (`rr_hb_timeout`, 60 s); once
  the command runs it lives on **180 s** without any client (`rr_detach_hb_s`), then it is cancelled
  (process group TERM, KILL 10 s later; `outcome=lost rc=N`). A deliberate stop (second Ctrl-C, a
  hedge's loser) is sent as an explicit KILL and cancels at once (`outcome=interrupted rc=N`). Spool files go 10
  min after their run ended (or 1 h after their last change once no run holds them; a running job
  touches its own every 5 min), swept when a detached run ends and by rd-tune's prune pass (Linux
  workers), so anything in `~/rr/spool` older than 1 h is safe to delete. While such a run still
  works in the worktree's mirror on the worker, the next run of that worktree there waits for it (up
  to its slot wait, `rrun-runner: an earlier run of this worktree still runs here ...`), then answers
  busy and rrun re-plans. Mirrors of these runners live in `~/rr/w2/` (older runners: `~/rr/w/`, which
  they keep using), so an old client's run can never check out under a new detached one; the janitor
  and rd-tune prune both.
- **Current code everywhere (version guarantee, layer 2: a backstop; agents are never blocked).** Every
  job's runner raises the worker's `~/rr/pool_version` to its client's `POOL_VERSION` (rd_common; bumped
  only for a change every client must adopt), under a flock on `~/rr/pool_version.lock` so it never goes
  down, and reports it as its first status, before any prepare (`PV ?` when it cannot tell). A newer
  or unknown worker version never blocks or restarts a job: it runs, and rrun ends with one line:
  `rrun: this Mac's pool code is behind (vN < vM); it updates itself within 2 min` (or `a worker could
  not report its pool version; ran anyway`). Updating is layer 1's job: the 2-min dotfiles autopull.
- **On the mini:** `~/rr` is 0700, excluded from Time Machine (`tmutil addexclusion`, once) and from
  Spotlight (`.metadata_never_index`).
- **Timing:** every job's `route.log` line ends with a tab and its client-side start timings:
  `lock_s cache_s plan_s push_s overlay_s slot_s remote_s` (lock = the wait for a worktree lane; slot =
  the workers' slot waits, summed over attempts and shards; remote = the worker's prepare + slot) and `start_s`
  (command start, from rrun's own start: the time-to-start SLO), plus `pred_s` (the placement's
  predicted command seconds) and `client` (the dotfiles commit). `RRUN_TIMING=1` also prints the stages
  on stderr.
  `rdocker status` has an `rrun` row (last run, runs in flight) and an `rrun job` row per run in flight.
- **Result cache (on the agent Mac, `~/.local/state/rdocker/cache/`, about 200 MB, least recently used out).**
  When the code rrun would ship AND the command match a recent run, rrun replays that run's output and
  exits with its code instead of running it again, with one stderr line: `rrun: cached result (same code +
  command, 3m ago on hp); RRUN_CACHE=0 to run again`. Passes are kept 24 h, failures 20 min (flakes).
  **`RRUN_CACHE=0` always runs** (and saves the fresh result); `rrun --where <cmd>` has a `cache:` line
  (hit / miss / not cached and why). The key is a hash of exactly what the worker gets: the HEAD commit,
  the base branches pushed (as commits), every uncommitted / untracked / env file rrun sends (path, exec
  bit, bytes), the deleted files, the env passed (`rr_env_pass` + `-e`, values included), the deps dirs
  and the runner script, plus the argv, the cwd and the job class. Ignored files that never travel do
  not count. So a fetch that moves origin/dev or origin/main changes the key (two worktrees on one
  commit share only when their base branches match too). Each attempt re-hashes what it really sent; if a file changed in between, nothing is saved.
  Cached: one-shot tsc / vue-tsc / eslint (no `--fix`) / `vitest run` / jest (no watch), directly, via
  npx or `node [--max-old-space-size=N] <their bin>`, and `npm test` / `npm run test|typecheck|lint[:x]`
  whose script (pre/post included, read from the package.json rrun ships) is only those tools joined by
  `&&`. **Never cached:** DB jobs, a DB-looking variable in the env sent or in a shipped env file, a
  script that sets env vars or runs anything else, builds, `--host` runs (they run, then save), local
  runs, a run that called `docker` on the worker, an interrupted or hedged run, a sharded run with a lost
  or local shard, a missing-test-DB run, and exit codes 65/69/70/72/73/75/76/77/78/124 or from a signal. A sharded run is one entry (keyed on
  the unsharded command), saved after every shard ended. Hits show as target `cache` in `route.log`.
- **Pool cache: the same results, shared by every agent Mac (`~rd/rr/rcache/` on the home worker, hp).**
  This Mac's cache is checked first, then the pool's. The pool lookup rides on the placement probe rrun
  already sends to hp, so a miss costs no extra round trip, and a valid hit (signed, current node major)
  is replayed as soon as hp answers, without waiting for the other workers' probes (those probe ssh
  processes are killed and reaped first: none outlives the run). A hit replays the output and exit code with
  the usual class line (`rrun: pass (exit 0 from the pool cache, 0s)`) and one line naming who made it:
  `rrun: cached result from the pool cache (same code + command, 3m ago on nickmbp by <agent>); RRUN_CACHE=0
  to run again`. A pool hit is never copied into this Mac's cache (that cache has no node check), so each
  repeat asks hp again. Same key, same rules and same lifetimes (pass 24 h, failure 20 min) as above.
  Node rule: fleet.json's top-level `"pool_node_major"` (e.g. `25`) declares which node the pool runs. A
  run shares its result only when its runner really ran that major (`node -v`, reported by the runner); a
  result is replayed only when its signed node tag equals it. No `pool_node_major` = no pool cache; an
  unknown runtime = nothing shared; a worker on another major never shares. **When node is upgraded on
  the workers, bump `pool_node_major` in fleet.json** (until then the upgraded workers share nothing).
  rd-steward flags a worker whose last-day runs.log `node=` differs from it (`node-mismatch`).
  Entries over 1 MB are not shared.
  **Signed entries.** Every pool entry carries an HMAC made on the agent Mac with
  `~/.config/rdocker/pool-cache.key` (0600). That secret exists only on agent Macs: never on a worker, never
  in git. It binds the cache key, all metadata (exit code, node, time, who) and the exact output, so a job
  running on hp cannot forge a verdict. Unsigned or wrong entries are misses. **No key file = this Mac uses
  its own cache only.** `rdocker pool-cache-key init` creates the key if missing;
  `rdocker pool-cache-key show-fingerprint` prints a hash of it (never the key). Every agent Mac must hold
  the same key: copy it over ssh, then compare fingerprints.
  **Identical runs at the same time run once.** The first run takes a lease on hp. A second identical run
  (another Mac or agent) prints `rrun: identical run in flight by <agent> on <mac>; waiting for its result`,
  polls hp every few seconds (a status line each minute) and replays the result when it lands. It runs
  the job itself when the lease ends without a result: the first run ended with nothing to share (for
  example an infra exit or it used docker), its owner was killed (no lease refresh for 90 s), or the lease
  expired (the job's cap + 10 min). A waiter also never waits longer than its OWN job's cap (one deadline,
  whoever holds the lease meanwhile); then it runs the job itself. Ctrl-C on a waiter just exits (130). After printing its result the
  owner uploads in one detached ssh and never waits for it; a failed upload only loses the share.
  `RRUN_CACHE=0` skips both tiers (no lookup, no wait, no upload; this Mac's tier still saves). If hp is
  unreachable, only this Mac's tier is used. `rrun --where` adds a `pool cache (hp):` line (hit / in flight /
  miss / did not answer). `route.log`: hits show as target `pcache`, and every pool-eligible run has
  `pcache=hit|miss|inflight|waited-hit|waited-miss` (+ `pwait_s`). rd-tune prunes the store every 30 min:
  expired entries and dead leases, then least recently used over 512 MB (`RCACHE_MAX_MB`). Config:
  `rr_pool_cache` (false = off), `rr_pool_cache_stale_s` 90, `rr_pool_cache_refresh_s` 30,
  `rr_pool_cache_poll_s` 5. Entries are data: printed, never run.

### Exit codes and result classes

Every rrun job ends with ONE line right after the command's output, `rrun: <class> (exit N[ on <worker>,
<secs>][; why]) - <next action>`, then any detail lines (a shard table, a cached-result note). Four
classes, so an agent never has to guess:

- `pass` - exit 0.
- `fail` - the command's own non-zero exit: the code is broken. Fix the code.
- `infra` - the pool, not the code: rerun it, never debug it (76 says it may have run, so check a DB
  job's side effects first).
- `needs-human` - rerunning will not help: tell the owner (who and why are on the line).

rrun's own codes (`rd_run.EXIT_CODES`; `tests/test_contract.py` checks this table against the code
and runs a scenario that emits each one):

| code | class       | meaning |
|------|-------------|---------|
| 72   | infra       | this worktree stayed busy past the wait (every lane, fleet.json `wt_lanes` 3, held; or a run writing into it / runs blocking a writer); never ran (`rrun --mine`) |
| 73   | infra       | every worker stayed busy past `rr_wait_min`; never ran |
| 75   | infra       | never ran: no worker reachable, lost before the start, `RRUN_STRICT=1`, a heavy/DB job with no worker |
| 76   | infra       | may have run: the link (every reconnect) or the worker's record of the result was lost after the start, the runner ended after the start without the command's exit status, or a build's outputs could not be copied back |
| 77   | needs-human | no worker may take this job (fleet.json `classes` / `max_cost_s` / `cold_ok`, or this repo crashed with SIGILL on every candidate) |
| 124  | infra       | hit its wall-clock cap (`RRUN_TIMEOUT`) and was killed |
| 132  | infra       | SIGILL on a worker: its CPU lacks an instruction this repo's code uses (a native package built for a newer x86 level, e.g. x86-64-v3 code on the AVX-only minis). A job safe to repeat (tests, typecheck, lint, build, a DB job's throwaway DB) has already re-run once on a worker whose CPU is not known to be as old; this code means no such rerun was possible. That CPU tier is skipped for this repo for `rr_isa_days` (7) while the pool has a newer one - see the scheduler's eligibility. A SIGILL on the rerun too is `fail` (exit 132, `crashed with SIGILL on every CPU tier tried`): a trap or an explicit exit 132 in the code |
| 65   | needs-human | the worker refused the request (bad input or an unsafe path, e.g. a symlinked mirror) |
| 69   | infra       | the repo was missing on the worker; never ran |
| 70   | infra       | the worker's runner failed; never ran |
| 78   | infra       | installing dependencies on the worker failed (`npm ci` / `pnpm install` / `prisma generate`); never ran - the last 25 lines of its npm log are shown, not the whole log |
| 79   | fail        | the DB lane's setup step (`pnpm db:migrate` / `pnpm db:provision`) failed on the worker; the command was not started - its redacted log tail is shown: fix the migration / provision script |

128+N: stopped by signal N (Ctrl-C, a tool's TERM) - `infra`, rerun if you still need it. A command that
dies of SIGILL on a worker (exit 132) is not the code's result either (row 132); on this machine (local
fallback, `RDOCKER_MODE=local`) a 132 stays the command's own `fail`. Any other
code is the command's own (`fail`): after the start only the worker's authenticated EXIT status is
the command's result. A sharded run is the test result when every shard ran (any real shard failure is
the result), `infra` when a shard gave none.
A failing run whose output mentions a missing test DB (`Environment variable not found:
DATABASE_URL`, `ECONNREFUSED` to a DB port) keeps its exit and class and gets one more line, `rrun: N
failures mention DATABASE_URL - likely no test DB on <worker>; rerun with npm run test:db`: a hint,
never a verdict (a real failure must not hide behind it). The fix is placement: a suite that needs a
DB is a db job.

Troubleshooting: exit 72 → other rruns of this worktree kept it busy (`rrun --mine`); exit 124 →
the command hit its cap (a hung test runner, e.g. vitest kept alive by open DB handles: the silence line
names the last test file; fix the teardown, or `RRUN_TIMEOUT=<min>` if it is really that long). Falls
back to the laptop every time → `rdocker doctor` (the push over ssh is the reachability test). Exit 73 →
every worker stayed busy for `rr_wait_min` (the wait lines name the holders). Exit 75 → no worker could
start it (check `rdocker status`, then rerun). A `... mention DATABASE_URL` line → rerun through `npm
run test:db`, which provisions the DB. Exit 132 → a worker's CPU could not run this repo's code; just
rerun (`rrun --where` lists the skipped workers as `never this repo crashed there with SIGILL ...`).
Exit 76 → the link or the result was lost after the start (rerun; a DB job: check its side effects).
Exit 77 → `rrun: needs-human (exit 77, 0s; no eligible worker for this job (class heavy, predicted ~15m):
laptop takes only light/normal/db jobs (this is heavy); ...` - every worker's fleet.json eligibility
rules it out (tell the owner).
A docker command refused with exit 1 inside a job → it targeted another run's container / network /
volume, or an unscoped prune (see Docker scope above). Exit 78 → `npm ci` / `prisma generate` / a local
package rebuild (`npm run <script>  (in ./<pkg>)` above it) failed on the worker (log tail above it);
fix the lockfile / schema / build, or `RRUN=0` to run locally. Works locally but fails on the worker
with a missing file → it is gitignored and not an allowlisted env file: commit it, or generate it in the
command. First run in a repo is slow (history push + `npm ci`); later runs add ~1-3 s.

## Pool scheduler: finish time, shards, hedges

Every job is re-planned from a fresh probe of every enabled worker (one ssh each, in parallel; nothing
about "down" is remembered between jobs), so a worker that sleeps or drops out is skipped on the next
job and one that comes back (or is added to fleet.json) is used at once.

- **Eligibility first, and hard (2026-11-11).** Optional fleet.json fields per worker: `classes` (the
  job classes it takes: `light` / `normal` / `heavy` / `db` / `build`), `max_cost_s` (the longest
  predicted command it takes, in seconds on that worker: the evidence prediction below, no momentary
  load factor) and `cold_ok` (a manual override for a job whose packages are not prepared there yet:
  `false` = never, `true` = always). Without `cold_ok`, cold eligibility is **measured**: a worker whose
  cold-setup p75 (its own `runs.log` prepares that ran an install) is over `rr_cold_budget_s` (60 s)
  takes warm jobs only, and qualifies again by itself once it measures faster (an SSD) - no fleet
  change. If that rule alone would leave a job nowhere to go, the worker with the fastest measured cold
  setup takes it. No field = no limit. A worker that fails one is **not a candidate at all** for that
  job: not ranked, not the wait host, no shard, no hedge. `rrun --where` lists it as `never <why>`.
  **SIGILL is measured too (2026-11-13), no field:** the probe reads each worker's x86-64 level (1-4)
  from its CPU flags (`/proc/cpuinfo`, macOS `sysctl machdep.cpu`; v2 = cx16 pni ssse3 sse4_1 sse4_2
  lahf_lm popcnt, v3 = + avx avx2 bmi1 bmi2 fma movbe abm f16c, v4 = + AVX-512) and this repo's
  SIGILL runs (`runs.log` `outcome=rc=132`) in the last `rr_isa_days` (7, capped at `rr_history_days`).
  Judged across the pool: a crash on a tier below a newer known tier skips that worker and every worker
  whose CPU is no newer for this repo (other repos still run there) - one crash on mini-a (v2) also
  skips mini-b (v2) while hp (v3) takes it; a crash on a worker whose tier is unknown skips that worker
  only. It skips **nobody** when a higher tier crashed too, when only the top known tier crashed, or
  when it would skip every worker left: a SIGILL everywhere is the code's own, so a repo is never
  locked out. A 132 row is not counted in the worker's infra rate. A new `history_since` forgets it.
  Nothing eligible → exit 77 at once with the reasons. A plan without a probe (`--host`, a one-worker
  fleet) checks the class only. `history_since` (a unix epoch, per worker): its `runs.log` rows before
  it are ignored - set it at a hardware or config change. New fields need the matching code on every
  client first: an older rd_fleet rejects unknown fields and would ignore the whole fleet.
- **Placement = earliest predicted finish, from evidence (2026-11-11).** Every number comes from the
  workers' own `runs.log` (read on the worker by the probe, offsets honoured, rows since `history_since`
  and in the last `rr_history_days` (14); rates over the last `rr_history_rows` (300) of them; timing
  from completed runs only, rc 0/1). `eta = setup + queue + run + rtt + risk`:
  - **run**: this worker's median of the **exact command** (3+ runs); else the pool's median of it,
    scaled by this worker's per-kind ratio learned from commands both it and others ran (3+ pairs;
    without pairs its bench `speed`, calibrated on the workers that have a ratio); else its own 1-2
    runs; else its median for the command's kind (tsc, vitest files / dirs / suite / shard, test:db,
    lint, build, check), then the pool's; the class default (`rr_job_cost_s`) / bench speed is the last
    resort. Then divided by the CPU share and memory factor seen now (the memory factor falls to 0.1
    when free memory is barely the job's need).
  - **setup**: the p75 of its measured warm or cold prepares (as the probe sees the packages), else 2 s
    warm / 90 s cold; + 30 s without the repo's git mirror.
  - **queue**: 0 with a free slot, else when the first holder should end (its own command's median
    there, minus how long it has run).
  - **risk**: p_infra (infra outcomes / fairly started runs, a 3 % prior over 30 runs) x (setup + half
    the run lost + a rerun on the best other worker). An unreliable worker loses only when that costs.
  Each job logs its prediction (`pred_s=` in `runs.log` and `route.log`) next to the real `cmd_s`.
  Order tried: free workers by eta, then busy ones by eta, then low-memory, down, off. A busy worker
  goes FIRST when its eta is at most 0.5x the best free one (`rr_queue_promote_ratio`, 0 = never) and at
  least 120 s sooner (`rr_queue_promote_min_gain_s`), and then waits for its slot only until the free
  one would have finished. `rrun --where` shows `run (from)`, `setup`, `infra` and `eta` per worker.
- **Overloaded workers are held off.** A worker whose 1-min load per CPU thread is at least 1.5 at probe
  time (`rr_overload_ratio`, 0 = off) counts as busy even with a free slot, and its compute estimate is
  multiplied by load/threads: it gets a job only when it would still finish first (2026-11-10: the WSL
  laptop, 8 threads, reached load 19). `rrun --where` marks it `(overloaded: held off)`.
- **Test jobs get a fair CPU share.** The runner caps each vitest/jest job (each shard too) at max(1, threads / slots) workers, using `--maxWorkers=N` for `vitest run` / `jest`, or `VITEST_MAX_WORKERS/_THREADS/_FORKS` for an `npm test`/`npm run` script that is one plain vitest command. It skips the cap when you set a worker/pool flag or those env vars yourself, or when a vitest/jest config in the cwd names a limit (e.g. `fileParallelism: false`), and for an npm script running jest. Capped runs end with `[cpu_share=N ...]` in `runs.log`, and the cache key is unchanged.
- **Vitest shards (default on).** `vitest run` with no file arguments (or only dirs / globs) and 2+
  free workers is split with vitest's own `--shard=i/n`, in shares proportional to each worker's
  **predicted rate** for this job (1 / its predicted run): shards go one at a time to the worker that
  would then finish its share soonest (<= its free slots, 8 in all). A worker whose single shard would
  take over 2x the fastest worker's gets none (2026-11-11: a laptop shard hit the 30-min cap). A second
  shard on the same worker gets its own "lane" mirror (`<repo>-<12 hex>`, reaped like any mirror; one per
  worktree lane and shard, never shared). Output
  lines are prefixed `[shard i/n host]`; a merged `Test Files` / `Tests` summary is printed last; the
  result is the test result when every shard ran (see the exit-code section). A shard whose worker is
  lost before GO moves to the next worker (lost after GO: rerun once, as for any vitest job); if no
  worker takes it, it runs on this machine only when the run holds the worktree alone (a build with
  `--outputs`); in any other sharded run that shard ends with exit 75 (infra: rerun it), because a run's
  hold on its worktree is chosen once at its start and never changes. Never sharded: DB jobs (also a `vitest run` whose suite
  needs a test DB: the package has a `test:db*` script, its vitest setup files read
  `process.env.DATABASE_URL`, or a `*.db.test.*` file is in scope - then the whole run is a db job),
  `--watch`, `--ui`, `--coverage*`, `--shard` already, json/junit/blob reporters, `--outputFile`, named
  test files, `--host`. `RRUN_SHARD=0` = never, `RRUN_SHARD=n` = force n shards (`rr_shard: false`
  turns auto off). A worker with `"shards": false` in fleet.json never gets a shard, nor a shard's
  failover; it still takes whole jobs.
- **Hedged duplicates (default OFF: `RRUN_HEDGE=1` or `rr_hedge: true`).** For tsc / lint / vitest /
  jest only (never DB, never builds): once a run has taken 2x its expected time and a free worker with
  a 3x better eta shows up (re-probed every 15 s, `rr_hedge_poll_s`), one duplicate starts there with
  its output held. The first to finish wins and the other is stopped. If the duplicate wins, the
  original's partial output is already on screen and the duplicate's follows after a marker note.
  That is why it is off by default.

## Rentable Mac workers / share switch

A Mac can be a pool **worker** (never the home): fleet.json `os: "mac"`, role `worker`, e.g. `nickmbp`
(Nick's M5 Max, `rd-nickmbp`, port 2222). Jobs run as a hidden non-admin `rd` user with its own sshd
(key-only, Tailscale-only); nothing touches the owner's account. It stays `enabled: true`: whether it
takes jobs is the **owner's live switch**, read on the worker before every job (no fleet.json push).

- **Switch:** the owner runs `rdocker-share off|some|max|status` (`share/rdocker-share.sh`; optional
  SwiftBar/xbar menu `share/rdocker-share.1m.sh`; install note `share/README.md`). It writes
  `/Users/Shared/rdocker/share` (one word; on Linux `~/rr/share`; `RR_SHARE_FILE` overrides).
  **No file = max**, so Linux workers behave as before. A file with anything else = off.
- **What each level means:** `off` = no new jobs (running ones finish): the probe reports state `off`
  (`rrun --where` shows it, plus a `share` column), it is tried last, and its runner refuses at once
  (exit 73 + `UNAVAIL share=off`, also when switched off while a job waits for a slot), so rrun moves to
  the next worker. `some` = half the slots and heavy slots (floor, min 1). `max` = all.
- **Docker on a Mac worker = Colima as `rd`, on purpose.** This is the scoped exception to "never start
  Colima" (that rule is for CLIENT Macs). Before a db job, or on a job's first docker call through the
  rrun shim, the runner checks `docker info`; if the engine is not answering it runs `colima start
  --vm-type vz --vz-rosetta` (linux/amd64 images work) sized by the level (max 12 CPU / 24 GB, some
  6 / 12; disk 120 GB) under the `~/rr/colima.lock` mkdir lock. No engine within 120 s
  (`RR_COLIMA_TIMEOUT`) = exit 73 + `UNAVAIL docker`, and the job moves on; the start keeps going in
  the background (a cold start is about 90 s), so the next job finds it up. An already-running Colima
  (also one started by hand) is used as is; a level change resizes it only on its next start.
  With the share **off and no slot held**, the probe (and a job's end) runs `colima stop` in the
  background. No root, no LaunchAgent (`rd` has no GUI session). Log: `~/rr/log/colima.log` there.
- **Speed:** `rdocker bench-worker <name>` runs the same benchmark as Linux's `rd-tune bench` over ssh
  (on a Mac the script is piped in, nothing installed) and stores `~/rr/speed` there, which the probe
  prefers over fleet.json's placeholder. `rrun --bench` also creates a missing `~/rr` (0700) now.

## Pre-warmed workers (`rdocker warm`)

A cold worker spends 90-140 s on a repo's first job (the git history, `npm ci`, `prisma generate`).
On every client Mac the launch agent `com.rdocker.warm` (installed by `rdocker install`, template
`units/com.rdocker.warm.plist`) runs `rdocker warm`, which does that work before a job needs it, for the
repos this Mac ran `rrun` in during the last 48 h (`route.log`), at most 2 per pass, newest first.

- **Per enabled fleet worker:** probe it (the same probe rrun uses); if its mirror lacks this HEAD,
  push (rrun's own push); if the current lockfile's packages are not there, run the runner's real
  prepare (slot, checkout, overlay, `npm ci` or a store clone, prisma) and stop at READY - GO is never
  sent, so **no command runs** and the runner exits 130. Warm twice = nothing the second time.
- **Polite:** one worker at a time (a `~/rr/state/warm.lock` dir on the worker keeps two clients
  apart), only on a worker running **no job** and with load/CPU below 0.7, at idle priority there (nice
  19, Linux idle I/O class), never queued for a slot, never a worker whose
  share is off (fleet.json `share` or the owner's switch), never Docker (the warm is not a db job, so
  the runner starts no engine on the home machine or anywhere), no allowlisted env files, no
  `route.log` line. A worktree with an rrun in flight is skipped this pass.
- **Every worker is warmed (2026-11-11)**, slow-disk and warm-only ones included: a warm-only worker
  (`cold_ok: false`, or a measured cold setup over `rr_cold_budget_s`, like the HDD minis) takes only
  jobs whose packages it already has, so warming is how it gets work at all. A detached prepare
  survives a long `npm ci`.
- **When:** a pass every 5 min; between passes an `ssh true` per worker every 60 s, and a worker that
  comes back online (Nick's MacBook waking up) starts a pass at once. And event-driven: a job that
  finds a worker cold for its lockfile queues one background `rdocker warm --once --repo <cwd>
  --after-lock S`, which waits (at most the job's cap + 1 min) for the worktree's lane 0 (the mirror it
  warms; the job's own lane when it runs there) BEFORE it
  takes this Mac's warm-pass lock (so other repos keep warming meanwhile), and warms right after the
  job. If a pass is running then, the request stays queued (`warm-trigger-<key>.pending` in the state
  dir) and the next pass warms it first. One waits per repo + lockfiles at a time; the throttle
  (`rr_warm_trigger_every_s`, 600 s) starts only when a warm really starts; `rr_warm_trigger: false`
  turns it off.
- `rdocker warm --once [--repo PATH]` runs one pass by hand. Log: `~/.local/state/rdocker/warm.log`, one
  line per push / prepare / skip (a repeated skip is logged when its reason changes). Keys:
  `rr_warm_interval_s`, `rr_warm_tick_s`, `rr_warm_window_h`, `rr_warm_max_repos`, `rr_warm_max_load`.
- On the worker, `~/rr/log/runs.log` shows a warm as `outcome=warm ... cmd_s=- argv=true` (stopped at
  READY; nothing ran). Its prepare time is real setup evidence for the scheduler.

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
| `rrun` mirror on the mini (`~/rr/w/<repo>-<wt>`) | removed after **2 d** unused (all unused ones when mini free < `host_min_free_gb`); a mirror whose repo slot is busy is skipped; bare repos in `~/rr/git` are kept, only the removed mirror's ref goes |
| container logs | capped per container: 10 MB × 3 files (json-file) |
| mini Colima/Lima log files | truncated past 50 MB; VM journald capped at 200 MB |
| `rrun` shared package store (`~/rr/deps/<key>/node_modules`) | an entry is published after a real `npm ci` (written whole, then renamed in; never changed after) and **cloned** (APFS `cp -c`, shared blocks) into any mirror of the same repo whose lockfile/package.json/.npmrc/node/npm args match - no `npm ci`; removed after **2 d** unused (10 min under disk pressure) |
| npm cache on the mini (`~/.npm/_cacache`) | cleared above **1 GB**, only while no `rrun` run holds a slot |
| VM disk ≥ 50 % (~15 GB of 30) or mini free < 8 GB | remove unused images **oldest-unused first** (never in-use ones) until below, prune all build cache, log a WARNING |
| VM disk ≥ 60 % (~18 GB) | also remove every stopped non-keep container (keep-checked) + prune anonymous volumes |
| failed action | logged; clocks are kept (not reset); `last_error` is written to `janitor.json` and raised as an attention item. The next clean full pass clears both |
| idle stop record | every idle stop is recorded (`stopped_by_janitor` in `janitor.json` / `laptop_janitor.json`). A later `exec`/`cp`/`attach`/`top`/`port`/`logs -f` at that container starts it first — only if it is still stopped **and has not run since** (`State.StartedAt` not after the stop) — waits up to 15 s for Running (mirrors its ports on the mini), prints `rdocker: restarted <name> (the janitor stopped it after <N> h idle)` (or `rdocker: tried to restart <name> but it did not come up`), then runs the command once. Names match exactly; an id must be >= 12 hex chars. A user `docker stop`/`rm` of the name clears the record, and a janitor pass that sees the container running drops it; a container the user stopped (or started and then stopped any way) is never auto-started. A `--rm` container is deleted by its idle stop and cannot be restarted. `rdocker status` lists the last 24 h of janitor stops |
| freed VM blocks | `fstrim` hands them back to macOS each run |

Run it now: `rdocker clean [--dry-run] [--only PREFIX] [--force-critical]` (`--only` limits the
container/volume rules to a name prefix and skips global prunes and image GC; `--force-critical` applies
the disk-critical stopped-container removal now — keep-labelled still exempt). Exit codes: 0 = the pass
ran; 1 = it did not run: mini lock still held after 90 s, mini unreachable over ssh, or the mini's
docker engine not answering (also with `--dry-run`). The background janitor just skips such a pass.
Hard ceilings: VM disk 30 GB, VM RAM 11 GB (the VM keeps whatever RAM it has touched, so this cap IS its footprint), VM CPU 6 — the mini itself can never be filled or starved.
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
| `rdocker doctor` | status **+ repair** (Tailscale, mini engine start via the kick path — never a VM-up restart, forwarder, mirrors) + flag-drift check |
| `rdocker clean [--dry-run\|--only P\|--force-critical]` | run the janitor now; exit 1 if it could not run: mini lock held after 90 s, mini unreachable, or mini engine not answering (`--dry-run` too) |
| `rdocker use auto\|mini\|local\|off` | routing mode; also points the global docker context at the target (`off` = raw Docker Desktop behaviour, context → laptop) |
| `rdocker where <container>` | which engine holds it (says which engine could not be asked) |
| `rdocker pin\|unpin <name> [--compose]` | keep a container / compose project on the laptop |
| `rdocker logs [--route]` | forwarder + janitor log / per-command routing log (incl. refusals) |
| `rdocker sync` | reconcile port mirrors now |
| `rdocker run [-e K[=V]]... [--] <cmd>` / `rrun ...` | run a heavy job (test runner + its DB) on the mini — see "Heavy test jobs on the mini" |
| `rdocker add-server <name> <tailscale-ip> [--role home,worker] [--admin-user U] [--dry-run]` | provision a Linux box over ssh (`server/provision-linux.sh`) and add it to `fleet.json`; see `/dockersetup server` |
| `rdocker bench-worker <name>` | benchmark one worker (Linux or Mac) over ssh; stores `~/rr/speed` there (the probe prefers it over fleet.json) |
| `rdocker warm [--once] [--repo PATH]` | pre-warm the pool workers for repos used here lately (the `com.rdocker.warm` agent runs it in a loop) — see "Pre-warmed workers" |
| `rdocker sync-fleet [--pull]` | validate `fleet.json`, rewrite `~/.ssh/config.d/rdocker` from it (that file is rdocker-owned; old copies in `~/.ssh/rdocker-backups/`) |

`rdocker status` rows: tailscale on laptop · mini reachable (ssh control connection) · mini docker engine
(version, round-trip) · mode → where commands go · docker shim first on PATH · background forwarder ·
daemon process (pid, age, running the code on disk / reload pending / reload NOT picked up) · health
reading age · janitor last run · janitor last error (`--` only if from about the latest pass) · mini
disk · mini engine config (Colima restart pending) · janitor-stopped in the last 24 h (mini + laptop,
auto-restarted on use) · fallback pins · mirrored ports (IPv6 mirror
pending) · port conflicts (busy on laptop) · laptop Docker Desktop · global docker context · (doctor)
docker CLI flags vs `rd_args.SPECS` · one `WARN` row per attention item (with its age). Exit code: 1 only
for `--` rows (real faults); `WARN` rows are for a human and keep it 0.
`rdocker --help` exits 0; an unknown command prints usage and exits 2.

Per call: `RDOCKER_MODE=local|mini`, `RDOCKER_BYPASS=1` (raw docker), `RDOCKER_VERBOSE=1` (say why local).
Logs: `~/.local/state/rdocker/{daemon,route,warm}.log`; state: `health.json`, `forwards.json`, `reserved.json`,
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
  `test_zz_hermetic`; rrun: `test_run` (laptop side end to end through a fake ssh), `test_pool` /
  `test_sched` (placement eta, shards, hedges, membership), `test_runner`
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

**Earlier host (2026-10-22, historical; the current host is in `fleet.json`): Nick's Mac mini** (`nicholass-mac-mini`, Tailscale 100.112.247.23, user
`nicholaspardon`, macOS 15.6, 16 GB). Set up over ssh with the `setup-mini` script (Homebrew colima +
docker as Nick's user only, VM 6 CPU / 5 GB / 30 GB (raised to 11 GB on 2026-10-26 by editing `memory:` in colima.yaml + `brew services` stop/start; restore running containers after), `brew services` at login, the same docker block +
Lima override; one PATH line in `~/.zshenv`; Nick's `~/.claude` and `~/dotfiles` untouched). The
laptop's `Host macmini-docker` block now says `HostName 100.112.247.23`, `HostKeyAlias
nickmini-docker`, `User nicholaspardon` (config `remote_socket`
`/Users/nicholaspardon/.colima/default/docker.sock`). The 11 long-lived DBs were copied volume by
volume and verified (database list + table counts); the originals stay **stopped, restart=no** on the
old mini (`ssh oldmini-docker`) as a backup. FileVault is on there too: after a reboot someone logs in
once. The VM clock polls NTP every 16-64 s (the janitor writes `/etc/systemd/timesyncd.conf.d/rdocker.conf`): DB tests compare the DB's now() with the host clock, and the VM drifted after the host slept. The host's own clock must be right too (`sntp time.apple.com`). Keep ssh backups OUT of `~/.ssh/config.d/` (everything in it is Included; a stale backup block
there supplied a wrong `HostKeyAlias` during the switch) - they live in `~/.ssh/rdocker-backups/`.

Previous mini (Omid's, until 2026-10-22): the Tailscale app (`brew install --cask tailscale-app`, since 2026-10-16, opens at login; the
Homebrew formula was removed and `/opt/homebrew/bin/tailscale` is a wrapper for the app's CLI), machine name `macminim4`, IP 100.73.250.43, key expiry off;
the laptop's `~/.ssh/config.d/rdocker` maps alias `macmini-docker` -> `HostName macminim4` with
`HostKeyAlias macmini-docker`,
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

**Linux server (`server_os=linux`)**: set config `server_os` to `linux` (default `mac` = Colima/launchd,
unchanged) when the Docker host is Linux (e.g. Ubuntu 24.04, systemd dockerd, user in the
`docker` group). dockerd is the host's own systemd unit, so there is no VM: the disk % is
`df -P /var/lib/docker`, the engine kick is `sudo -n systemctl start docker` (restart is the same with
`restart`; status via `systemctl is-active docker`), housekeeping is `sudo -n journalctl --vacuum-size=50M`
+ `sudo -n fstrim -a`, and the Colima log trim / timesyncd drop-in are skipped. `remote_socket` defaults
to `/var/run/docker.sock` (`setup-mini` itself is mac-only; configure the Linux host by hand).
`server_docker_bin` (default `/usr/bin/docker` on linux) names the server's docker CLI. rr_runner.pl
falls back to `/usr/bin/docker`, reads memory/load from `/proc`, and clones the deps store with
`cp -a --reflink=auto`. Never prompts: only `sudo -n`. sudoers (`visudo -f /etc/sudoers.d/rdocker`):

    <user> ALL=(root) NOPASSWD: /usr/bin/systemctl start docker, /usr/bin/systemctl restart docker, /usr/bin/journalctl --vacuum-size=*, /usr/sbin/fstrim -a
