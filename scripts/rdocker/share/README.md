# rdocker share switch (for the owner of a Mac worker)

Your Mac runs rdocker jobs as a separate non-admin user `rd`. You decide how much it gets, from the menu
bar or the command line:

```sh
rdocker-share off       # no new jobs (running ones finish); the Docker VM stops once idle
rdocker-share low       # 25 % of the cores, jobs may use up to 25 % of the memory together
rdocker-share medium    # 75 % of the cores, up to 50 % of the memory      (old word: some)
rdocker-share high      # all the cores, up to 75 % of the memory          (old word: max)
rdocker-share cpu 75    # custom: 75 % of the cores (keeps the RAM cap you have)
rdocker-share ram 4     # custom: jobs may use at most 4 GB together (keeps the CPU share)
rdocker-share stop      # off now AND stop the jobs running here (within about 15 s)
rdocker-share status    # what it is now, jobs running, paused-for-memory
```

On a 16 GB, 10-core Air: low = 2 cores / 4 GB, medium = 5 / 8 GB, high = 10 / 12 GB. On Nick's 64 GB
MacBook the old `some` / `max` give exactly what they gave before (half / all the job slots, the Docker VM
6 CPU / 12 GB or 12 / 24).

It takes effect on the next job, with no restart and no admin password. The setting is stored in
`/Users/Shared/rdocker/share`, one line: a preset word, or `cpu=<10-100> ram=<GB>` (either or both; no
`cpu=` = 100, no `ram=` = no cap). No file = everything (how Linux workers run); anything it cannot read =
off. It is **sticky**: sleep, a wifi change, a Tailscale reconnect or a reboot never change it, and no
timer, idle rule or battery rule turns it off. Only you do.

What a setting means for the jobs (the runner and the pool's probe read the same rules: the `share-spec`
block of `rr_runner.pl`, copied verbatim into `rdocker-share.sh`):

- **CPU %** = how many cores the jobs may keep busy together (each test job gets cores / slots workers)
  and how many jobs at once (the fleet's slots x the percent, at least 1).
- **RAM cap** = the most memory the jobs may use together: at most one job per 2 GB of it and one heavy job
  (a full `tsc`, ~6 GB) per 6 GB (under 6 GB: no heavy job at all - the pool never plans one there, and the
  runner refuses one at once, `UNAVAIL ram-cap`), one job's node heap at most 3/4 of it, and a new job waits while the
  jobs already here use it up (the `rd` user's memory, measured). A Docker VM is never bigger than the cap.
- **Your apps first, always:** a new job starts only while macOS memory pressure is normal and free memory
  stays above a floor (20 % of RAM, at most 4 GB) after the job's own need. Otherwise the Mac refuses it at
  once (`UNAVAIL memory`) and the pool sends it elsewhere; the menu shows "paused for memory". Running jobs
  are never stopped for this.

What can lower capacity on its own, temporarily: the memory guard above, the pool's overload hold-off (a
busy Mac gets fewer jobs) and the doctor's health pause (below), which reopens by itself.

## Disk cap (every Mac worker)

`sudo sh share/rd-disk-cap-mac.sh <CAP e.g. 40g> [--docker] [--reporter <fleet name>]` puts everything the
pool keeps on a Mac (`/Users/rd/rr`: checkouts, package caches, logs, and the Colima VM + npm cache via
symlinks) on its own APFS volume `rdocker-rr` with a hard quota, mounted at `/Users/rd/rr` at every boot
(`/etc/fstab`). The pool can never use more than CAP of the SSD (Linux workers: rd-rrfs's fixed-size image).
It pauses the share while it moves the files (running jobs finish first) and restores the level. The Colima
VM disk is 20 GB (rr_runner.pl `$VM_DISK_GB`). A worker whose disk is under 5 % free drains itself
(rd-doctor), so a full Mac is routed around, never a blocker.

## The menu bar (SwiftBar)

`rdocker-share.1m.sh` is a [SwiftBar](https://swiftbar.app) (or xbar) plugin, refreshed every minute and
after each click. Title: `⚙ 75% · 4G` (CPU share · RAM cap), `· 2▶` while 2 team jobs run here, `⏸` while
the memory guard holds new jobs back, `⚙ off` when off. The menu:

- what is set now (cores, RAM cap), team jobs running here, paused-for-memory with the reason
- Off / Low / Medium / High, one click each (the current one ticked; labels in cores and GB)
- **CPU: <now>** and **RAM: <now>** submenus whose titles show what is in force: CPU 25 / 50 / 75 / 100 %
  and RAM up to 2 / 4 / 6 / 8 / 12 ... GB (up to this Mac's memory less 2 GB). Picking one makes the
  setting custom and keeps the other value (from Off they start from Medium's). The ticks always show
  what is in force, a preset's own values included; nothing is ticked while off.
- Stop the jobs running here now

The fleet dashboard offers the same choices on the Mac's page, but only when you opt in on this Mac:
`"shareControl": true` in `~/.config/rdocker/reporter.json` (your own reporter, not one running as `rd`),
then `launchctl kickstart -k gui/$(id -u)/com.rdocker.reporter`. If this Mac's stats reporter runs as `rd`
(a LaunchDaemon), a small control-only helper in your own session takes the orders instead
(`reporter/share-control-remote.sh <workspace> helper <name>`, or on this Mac
`reporter/share-control-mac.sh helper-prepare|helper-start`). Every change made there is logged on that
page with who made it (dashboard README, "Share control").

The jobs count comes from `rd-worker-mac` (root), which writes `/Users/Shared/rdocker/status` every 15-45 s:
you cannot read the `rd` user's files yourself.

## Setting up a Mac worker (once, with sudo; safe to re-run)

One way for every Mac (a new one, or re-provisioning Nick's), from the unpacked bundle (`share/` +
`server/rd-doctor.sh` + `reporter/` + `fleet.json`):

```sh
sudo sh share/setup-mac-worker.sh            # add --docker on a Mac that takes db jobs (Colima)
```

**First**, before any account, key or sshd: `/Users/Shared/rdocker` (yours or root's, no group/world write;
owned by anyone else = it refuses) with the switch seeded **off** when there is none, checked, or the install
stops (no file means everything on a Mac, so an install cut short can never leave a worker nobody opted
into). An existing setting is kept, so re-running it on a Mac that has **no** share file (Nick's, if it was
deleted) turns that Mac **off** until its owner picks a level. Then it creates the hidden standard user `rd`
(random password nobody knows), writes its `authorized_keys` from fleet.json `client_keys` (as `rd`: root
never writes inside its home), and runs a separate key-only sshd for `rd` alone on port 2222 **bound to this
Mac's Tailscale address only** (it refuses any address outside 100.64.0.0/10 or not up right now; no TCP,
socket, agent or X11 forwarding, no tunnels; LaunchDaemon `com.rdocker.sshd`, reloaded only when its config
changed, so running jobs keep their links). macOS Remote Login is not switched on or off, but its sshd gets
`DenyUsers rd` (drop-in `/etc/ssh/sshd_config.d/100-rdocker-deny-rd.conf`; the install refuses when the
main config does not read that folder), so `rd` can only ever log in through its own sshd. Then: node for `rd`'s jobs (brew's
node; fleet.json `pool_node_major`, a mismatch is reported, never upgraded for you), with `--docker` colima +
docker via brew, SwiftBar (brew cask when missing) with the plugin in its plugin folder, and finally
`install-worker-mac.sh` (below). It ends with `LISTEN-OK <ip>:2222 only` and a status summary. It never
changes system settings (sleep, firewall, Remote Login).

Without `--docker` the Mac has no Docker for jobs: its fleet.json entry leaves out the `db` class (the Air).

`install-worker-mac.sh` (also on its own, to refresh the daemons; it makes the same share-folder owner
check) installs `rdocker-share` in `/usr/local/bin` (for you and the menu) and a root-owned copy in
`/usr/local/libexec` that the root daemon runs (never through PATH: `/usr/local/bin` is yours on an Intel
Homebrew Mac), the doctor and power daemons (below), refreshes your reporter (LaunchAgent
`com.rdocker.reporter`) when it is installed, installs `server/rd-tune.sh` as `/usr/local/libexec/rd-tune`
(root-owned; the daemon runs it as `rd`), and adds `com.rdocker.worker` (`rd-worker-mac.sh`, a root
LaunchDaemon, RunAtLoad + KeepAlive, a 15 s loop):

- **Awake while lent out:** sharing on (any level but off) -> it holds `caffeinate -s`, an assertion that is
  valid only on AC power: plugged in, the Mac does not idle-sleep; on battery, or with the lid closed, it
  sleeps as usual (asleep = unreachable, and the pool routes around it). Share off -> released.
- **ssh back after Tailscale:** the worker's sshd (`com.rdocker.sshd`) listens on the Tailscale address only,
  and Tailscale comes up after the boot daemons and can drop and return on wake or a wifi change. When that
  address is up but nothing listens on it for 2 ticks, it runs `launchctl kickstart -k system/com.rdocker.sshd`
  (or bootstraps the plist when the job is not loaded). Log: `/var/log/rd-worker-mac.log` (changes only).
- **Menu status and Off now:** it writes the jobs count for the menu, and on `rdocker-share stop` (the menu's
  "Stop the jobs running here now") sends USR1 to `rd`'s runners only (never your own local `rrun`): a job that had not
  started is refused like share off (the pool moves it elsewhere), a running one is stopped (runs.log
  `interrupted`, not a pool failure).
- **~/rr prune (disk):** at start and every 10 min (`RD_PRUNE_EVERY_S`) it runs `rd-tune prune` as `rd`
  in the background: the Linux workers' own prune (`server/rd-tune.sh`, installed as
  `/usr/local/libexec/rd-tune`), single instance (`~/rr/state/prune.lock`), at nice 19 + `taskpolicy -b`.
  Mirrors (`~/rr/w`, `~/rr/w2`) and store entries (`~/rr/deps`) unused 2 days go every 30 min; below
  **25 % free** on the `~/rr` volume (an 80 GB APFS quota on the Air) the least recently used go, one at a
  time, until 30 % is free - anything not used in the last 10 min, never a mirror a running job uses
  (its slot is held, or its `.who` pid is alive). Under that pressure, and only when no job holds a slot (it
  then holds them all, so none starts meanwhile), it also prunes the worker's own Colima (its VM disk lives on `~/rr` too: `~/.colima` ->
  `~/rr/home/colima`) through `rd`'s socket, only when Colima already runs (never started for it): stopped
  containers > 24 h, images no container uses, anonymous volumes no container uses, never anything labelled
  `rdocker.keep`, then `fstrim` in the VM so the sparse disk gives the space back. What it removes is
  logged in `/var/log/rd-worker-mac.log`. Without the root daemon (a Mac not yet re-installed), `rd` can run
  the same as its own detached loop: `rd-tune prune-loop [600]` (one per Mac:
  `~/rr/state/prune-loop.lock`; log `~/rr/log/prune.log`).

It never touches the share level, the `rd` user, the sshd config or Tailscale.

## This Mac is a worker AND an agent (the Air, Nick's MacBook Pro)

Owner decision 2026-11-21: while this Mac's share switch is ON (the share file exists and its level is
low / medium / high / custom), agents on it run their own jobs on its own capped `rd` worker FIRST: the pool
plan keeps the fleet worker whose ip is one of this Mac's addresses (`rd_pool.is_self` + `self_share`, the
runner's own share-spec rules read locally), probes it over ssh like any worker (`rd-airm4` to its own
Tailscale ip) and runs the job there under the same share caps. It ranks on its real predicted finish
(queue + setup + run) with no `rr_optional_margin`, and wins a tie (nothing is copied to another machine).
Jobs overflow to the pool when its own slots are full or its classes do not take the job (db: `airm4` has
no db class, so db jobs from the Air still go to the pool). `rrun --where` marks it "this Mac's own worker
(sharing on)".

Share off, no share file, or a file that cannot be read safely: it is left out of this Mac's own plan, as
before; `rrun --where` shows it as `self` with the reason, and its own agents' jobs go to the other workers
(or locally, as on any agent Mac). Other machines' jobs still come in under the switch either way. The
Air's entry (`airm4`) is `"optional": true`: when it is away or asleep nothing waits for it or warns about
it, and for OTHER machines it ranks on its predicted finish + 15 %, so it never wins a tie with hp or the
laptop there.

## Self-healing watchdog (rd-doctor, once, with sudo)

```sh
sudo sh install-doctor-mac.sh            # LaunchDaemon com.rdocker.doctor, runs as rd every 30 s
sudo sh install-doctor-mac.sh --uninstall # removes it and lifts any drain it set
```

It clears stale slot files of dead jobs, stops a job past its hard cap, removes leftover run containers
(never `rdocker.keep` ones), restarts a reporter loaded in rd's own launchd domain (yours, in your login session,
is kept alive by launchd's KeepAlive instead), pauses new jobs while the Mac is unhealthy (memory, disk,
repeated lost jobs; jobs cut by a lid close and logged in the 5 min after the wake do not count, and the
pause lifts itself after 3 healthy checks), stops a Colima VM that came back from sleep with an engine that
no longer answers (2 checks; the stop runs only while it holds every job slot, so no job can start under it;
the next job starts it fresh) and moves `~rd/rr` to `~rd/rr.noindex` (a symlink stays) while no job runs, so Spotlight
skips it. Log: `~rd/rr/log/doctor.log`; status: `~rd/rr/state/doctor.json`. Off switch: `DOCTOR_DISABLE=1` in
`/etc/rdocker/doctor.conf`. It never touches your share switch.

## Pool steward (rd-steward, on the always-on agent Mac only)
`rd-steward.py` is the pool's supervisor; it runs on Nick's Mac mini, not on workers. Every 30 min it
reads each enabled worker's rd-doctor status and last-hour job outcomes over ssh, applies fixed rules
(unreachable, except an `"optional": true` worker: reported `away`, no finding; doctor missing or
stale, drained over 15 min, disk under 10 %, memory under 8 %,
infra failures over 10 % of the hour: `lost`/`busy`/`refused`/caps/OOM, never test failures or
`interrupted`), and writes `~/.local/state/rd-steward/reports/`. When there are findings it starts one
headless Claude agent with a strict runbook (safe, reversible fixes only; "Needs a human" for anything
else). The same finding set is handed off again after 3 h, then 6, 12, max 24 h.
It also checks versions: a worker whose installed rd-doctor/rd-tune/rd-verify differs from the repo, and
this Mac's dotfiles autopull (`scripts/dotfiles-autopull.sh`: a 2-minute fast-forward-only pull that the
rrun-route hook self-installs on every Mac that uses the pool) being stale or stuck behind origin.
Routing accuracy: every report line shows each worker's median prediction error over the last 24 h
(`pred_s` the router logged vs the real `cmd_s`, jobs of 2 s or more); over 50 % across 30+ jobs is a
`pred-drift` finding.
Node version: a worker whose last-24 h jobs ran on a node major other than fleet.json's top-level
`pool_node_major` (runs.log `node=`, the `node -v` major on the job's PATH) is a `node-mismatch` finding naming
the worker and both majors (its results are not shared by the pool cache). Rows without `node=`, or with
`node=-`, are ignored; no `pool_node_major` = no check.
Every field is read from its own part of a runs.log line, never from the job's argv, and only bounded numbers
count. A worker whose answer cannot be read is a `steward-error` finding; the other workers are still checked.
Pool failing (2026-11-13): a job the pool failed now runs locally on the agent Mac (route.log
`fallback-local`), so it would be silent. `pool-failing` fires for a machine whose last hour has 3 or more
pool failures, or more than 20 % of at least 10 runs failed by the pool, and names the machine and the top
reason. Two sources: this Mac's own `route.log` (+ `.1`): `fallback-local` lines (their `why=` field is the
reason) and infra-class rcs (69 70 72 73 75 76 78 124 127 132); the other agent Macs have no ssh alias, so
for them each worker's runs.log stands in: `lost rc=N`, `error`/`refused rc=69|70`, `rc=127`, `rc=132` count as
pool failures, plus every infra outcome for the rate. On a worker it replaces the `infra` finding (one problem,
one finding). Set `RD_STEWARD_SELF` to name this Mac in the finding (default: its host name).

    python3 ~/.claude-dotfiles/scripts/rdocker/share/rd-steward.py --install     # user LaunchAgent, no sudo
    python3 .../rd-steward.py --once        # run now (RD_STEWARD_AGENT=0: report only)
    python3 .../rd-steward.py --uninstall

## Turnaround numbers (rd-measure, any Mac with the pool's ssh aliases)
`rd-measure.py` prints the pool's turnaround for one time window, the same way every time, so a
placement change can be compared before / after (2026-11-21: the cold-setup veto removed). Read-only on
the pool: it fetches every client's `route.log` (this Mac + `--client` aliases, default `nickmini-docker`)
and every fleet worker's `runs.log` over ssh. Per job class: queue wait (`slot_s` + `lock_s`) p50/p90,
submit-to-finish (the client's wall seconds) p50/p95, jobs per worker, cold jobs per worker and the
cold-setup estimate error (`prepare_s` / `spred_s`); then a replay of hp's queue spikes on the workers
that had a free slot then, with no cold veto (optimistic and strict warm bounds). A worker counts as
online (capacity, in the replay and the wasted-capacity timeline) only from started / warm rows, and not
after it refused (`busy` / `refused` / `off`): an optional Mac turning jobs away is no idle capacity.

Two more sections (2026-11-24): **interrupted runs** - runs.log rows cut short (`interrupted`, `lost`,
rc 130 / 137 / 143) with their job-hours by kind, cap kills (rc 124) beside them, the client-side count
(route.log rc 130 / 143 on every host, incl. workers with no runs.log), and how many had an identical
successor (same repo + argv, same owner session or any) arriving within 10 min: the job-hours a "join
the in-flight identical run" feature could save. **Worker contention** - per worker, the same command's
run time by the mean slots busy during it (<= 3 / 4-6 / 7+) and the median slowdown over the groups.

**Log cache.** Every fetched log is merged into `~/.local/state/rdocker/logcache/<runs.W|route.C>.log`
(append-only, deduped by record, never loses a line), and the report reads that copy. A machine that does
not answer is read from the cache alone and shown as `CACHE ONLY` with the age of its newest line. The
client warm daemon (`com.rdocker.warm`) also mirrors each reachable worker's `runs.log` there every 30 min
in the background, so an optional Mac's jobs survive it going offline. `--logs DIR` never touches the
cache; `--cache ''` turns it off. The cache dir has the `--logs` layout, so `--logs` can read it too.

```sh
python3 ~/.claude-dotfiles/scripts/rdocker/share/rd-measure.py --since "2026-11-21 22:30" --until "2026-11-22 08:30"
python3 .../rd-measure.py --hours 10 --keep /tmp/logs     # the last 10 h, logs saved; --logs DIR re-reads them, --json
python3 .../rd-measure.py --since ... --until ... --fleet old-fleet.json --save before.json   # pin the fleet of an old window
```
