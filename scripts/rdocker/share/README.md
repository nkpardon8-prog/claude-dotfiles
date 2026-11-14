# rdocker share switch (for the owner of a Mac worker)

Your Mac runs rdocker jobs as a separate non-admin user `rd`. You decide how much it gets:

```sh
rdocker-share max      # all job slots; Docker VM 12 CPU / 24 GB
rdocker-share some     # half the job slots; Docker VM 6 CPU / 12 GB
rdocker-share off      # no new jobs (running ones finish); the Docker VM stops once idle
rdocker-share status   # current level and how many jobs run right now
```

It takes effect on the next job, with no restart and no admin password. The level is stored in
`/Users/Shared/rdocker/share` (one word; delete the file = max). It is **sticky**: sleep, a wifi change,
a Tailscale reconnect or a reboot never change it, and no timer, idle rule or battery rule turns it off.
Only you do (`rdocker-share off` or the menu's Off). `rdocker-share level` prints just the word.
What can lower capacity on its own, temporarily: the pool's overload hold-off (a busy Mac gets fewer
jobs) and the doctor's health pause (below), which reopens by itself.

## Everything in one go (once, with sudo; safe to re-run)

```sh
sudo sh install-worker-mac.sh     # from the unpacked bundle: share/ + server/rd-doctor.sh + reporter/
```

It installs `rdocker-share` in `/usr/local/bin`, the doctor and power daemons (below), refreshes your
reporter (LaunchAgent `com.rdocker.reporter`) when it is installed, and adds `com.rdocker.worker`
(`rd-worker-mac.sh`, a root LaunchDaemon, RunAtLoad + KeepAlive, a 15 s loop):

- **Awake while lent out:** share some/max -> it holds `caffeinate -s`, an assertion that is valid only on
  AC power: plugged in, the Mac does not idle-sleep; on battery, or with the lid closed, it sleeps as usual
  (asleep = unreachable, and the pool routes around it). Share off -> released.
- **ssh back after Tailscale:** the worker's sshd (`com.rdocker.sshd`) listens on the Tailscale address only,
  and Tailscale comes up after the boot daemons and can drop and return on wake or a wifi change. When that
  address is up but nothing listens on it for 2 ticks, it runs `launchctl kickstart -k system/com.rdocker.sshd`
  (or bootstraps the plist when the job is not loaded). Log: `/var/log/rd-worker-mac.log` (changes only).

It never touches the share level, the `rd` user, the sshd config or Tailscale.

## Install (once, as yourself)

```sh
sudo install -m 755 rdocker-share.sh /usr/local/bin/rdocker-share   # or any dir on your PATH
```

Optional menu-bar toggle: install [SwiftBar](https://swiftbar.app) (or xbar), then copy
`rdocker-share.1m.sh` into its plugin folder and `chmod +x` it. The menu shows the level and has
Off / Some / Max items. The plugin finds the command next to itself or at `/usr/local/bin/rdocker-share`.

Nothing is installed for you; both scripts are plain shell and touch only the share file.

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
