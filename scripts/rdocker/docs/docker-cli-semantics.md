## Q1. Pruning and labels

**Findings.** `docker container prune --filter 'label!=rdocker.keep=1'` removes stopped containers whose label is absent **or has any value other than `1`**. `label!=rdocker.keep` removes stopped containers only when that label key is absent; any value protects the container. The same negative-label forms are supported by `volume prune`. Since API 1.42, `volume prune` removes only unused **anonymous** volumes by default; `--all` also includes unused named volumes. `image prune -a --filter 'until=720h'` tests image **creation time**, not last use. `.Metadata.LastTagTime` exists in some image inspect output, but records tagging time, not container use. [Container prune](https://docs.docker.com/reference/cli/docker/container/prune/), [volume prune](https://docs.docker.com/reference/cli/docker/volume/prune/), [API history](https://docs.docker.com/reference/api/engine/version-history/), [image prune](https://docs.docker.com/reference/cli/docker/image/prune/), [image metadata example](https://github.com/docker/cli/blob/master/man/src/inspect.md).

**Evidence.** The local raw CLI help confirms `--filter` for all three prune commands and `volume prune --all`. For build cache, the [documented `docker builder prune`](https://docs.docker.com/reference/cli/docker/builder/prune/) flag is `--keep-storage`; [Buildx prune](https://docs.docker.com/reference/cli/docker/buildx/prune/) has `--max-used-space`, `--min-free-space`, and `--reserved-space`. Engine API 1.51 calls `keep-storage` deprecated in favor of `reserved-space`. Here, the 28.5.1 CLI’s **`docker builder prune --help` resolves to `docker buildx prune`** and shows the Buildx flags. [API 1.51](https://docs.docker.com/reference/api/engine/version/v1.51/).

**Recommendation.** Scope janitor deletion with a **positive ownership label**, then apply age and protection checks; a negative keep label alone selects everyone else’s unlabeled resources. Track image IDs last seen in use yourself, reconcile against all existing containers before deletion, and remove only currently unused, owned candidates older than your tracked cutoff. Select builder-prune arguments from the actual CLI help or explicitly invoke Buildx; do not assume `--keep-storage` and `--reserved-space` are interchangeable CLI flags.

## Q2. Container subcommand flag table

**Findings.** In this table, “value” means the flag consumes an argument; “boolean” means it does not. Names separated by `/` are one short/long alias pair.

| Command | Value flags | Boolean flags |
|---|---|---|
| `exec` | `--detach-keys`, `-e/--env`, `--env-file`, `-u/--user`, `-w/--workdir` | `-d/--detach`, `-i/--interactive`, `--privileged`, `-t/--tty` |
| `logs` | `--since`, `-n/--tail`, `--until` | `--details`, `-f/--follow`, `-t/--timestamps` |
| `rm` | — | `-f/--force`, `-l/--link`, `-v/--volumes` |
| `stop` | `-s/--signal`, `-t/--timeout` | — |
| `start` | `--checkpoint`, `--checkpoint-dir`, `--detach-keys` | `-a/--attach`, `-i/--interactive` |
| `restart` | `-s/--signal`, `-t/--timeout` | — |
| `kill` | `-s/--signal` | — |
| `container inspect` | `-f/--format` | `-s/--size` |
| `port` | — | — |
| `cp` | — | `-a/--archive`, `-L/--follow-link`, `-q/--quiet` |
| `wait` | — | — |
| `top` | — | — |
| `attach` | `--detach-keys` | `--no-stdin`, `--sig-proxy` |
| `pause`, `unpause`, `rename` | — | — |
| `update` | `--blkio-weight`, `--cpu-period`, `--cpu-quota`, `--cpu-rt-period`, `--cpu-rt-runtime`, `-c/--cpu-shares`, `--cpus`, `--cpuset-cpus`, `--cpuset-mems`, `-m/--memory`, `--memory-reservation`, `--memory-swap`, `--pids-limit`, `--restart` | — |
| `commit` | `-a/--author`, `-c/--change`, `-m/--message` | `-p/--pause` |
| `diff` | — | — |
| `export` | `-o/--output` | — |
| `stats` | `--format` | `-a/--all`, `--no-stream`, `--no-trunc` |

**Evidence.** These are the outputs of `RDOCKER_BYPASS=1 /usr/local/bin/docker <command> --help` on the local 28.5.1 CLI; the commands are indexed in the [Docker container CLI reference](https://docs.docker.com/reference/cli/docker/container/). Generic `docker inspect` additionally has value flag `--type`; `docker container inspect` does not. `docker top CONTAINER [ps OPTIONS]` passes the trailing words to `ps`, so they are not Docker flags.

**Recommendation.** Store each command as `{value_long, value_short, boolean_long, boolean_short, positional_rule}`. Resolve aliases before parsing, and keep `top`’s trailing `ps` arguments opaque. Route `inspect` with `--type` according to that value; otherwise distinguish generic inspect from explicit `container inspect`.

## Q3. `run` and `create`

**Findings.** The local `docker run --help` marks these as **value-taking**:

```text
--add-host --annotation -a/--attach --blkio-weight
--blkio-weight-device --cap-add --cap-drop --cgroup-parent --cgroupns
--cidfile --cpu-count --cpu-percent --cpu-period --cpu-quota
--cpu-rt-period --cpu-rt-runtime -c/--cpu-shares --cpus
--cpuset-cpus --cpuset-mems --detach-keys --device
--device-cgroup-rule --device-read-bps --device-read-iops
--device-write-bps --device-write-iops --dns --dns-option
--dns-search --domainname --entrypoint -e/--env --env-file
--expose --gpus --group-add --health-cmd --health-interval
--health-retries --health-start-interval --health-start-period
--health-timeout -h/--hostname --io-maxbandwidth --io-maxiops
--ip --ip6 --ipc --isolation --kernel-memory -l/--label
--label-file --link --link-local-ip --log-driver --log-opt
--mac-address -m/--memory --memory-reservation --memory-swap
--memory-swappiness --mount --name --network --network-alias
--oom-score-adj --pid --pids-limit --platform -p/--publish
--pull --restart --runtime --security-opt --shm-size
--stop-signal --stop-timeout --storage-opt --sysctl --tmpfs
--ulimit -u/--user --userns --uts -v/--volume
--volume-driver --volumes-from -w/--workdir
```

The **boolean** flags are `-d/--detach`, `--disable-content-trust`, `--help`, `--init`, `-i/--interactive`, `--no-healthcheck`, `--oom-kill-disable`, `--privileged`, `-P/--publish-all`, `-q/--quiet`, `--read-only`, `--rm`, `--sig-proxy`, `-t/--tty`, and `--use-api-socket`. In particular, `-a -c -e -h -l -m -p -u -v -w` take values; `-d -i -P -q -t` are booleans. Local `create --help` has the same lists except it lacks `-d/--detach`, `-i/--interactive`, and `--sig-proxy`.

**Evidence.** Local raw `docker run --help` and `docker create --help`; Docker documents combined short options in its [CLI reference](https://docs.docker.com/reference/cli/docker/), and the parser’s [pflag syntax](https://github.com/spf13/pflag#command-line-flag-syntax) permits combined boolean shorthands.

**Recommendation.** Parse `-dit` and `-itd` as three booleans; `-p5432:5432` as `-p` with attached value `5432:5432`; and `-eFOO=1` as `-e` with attached value `FOO=1`. Within a short cluster, once a value-taking flag is reached, its remaining characters are its value. Stop interpreting Docker options at `IMAGE`; subsequent arguments belong to the container command.

## Q4. Compose

**Findings.** `docker compose run -v/--volume` takes a mount value and can add a bind mount to the service’s mounts. Compose-level value flags are `--ansi`, `--env-file`, `-f/--file`, `--parallel`, `--profile`, `--progress`, `--project-directory`, and `-p/--project-name`. Its booleans are `--all-resources`, `--compatibility`, and `--dry-run`. Ordinary `compose config --format json` parses and renders configuration without needing a running daemon; `-f -` reads the Compose file from stdin. `--resolve-image-digests` is a separate option that can require image resolution. [Compose reference](https://docs.docker.com/reference/cli/docker/compose/), [Compose run](https://docs.docker.com/reference/cli/docker/compose/run/), [Compose config](https://docs.docker.com/reference/cli/docker/compose/config/).

**Evidence.** Local raw `docker compose --help`, `docker compose run --help`, and `docker compose config --help` show those flags. The Compose reference explicitly defines `-f -` as stdin.

**Recommendation.** Parse Compose globals before its subcommand, then parse `run` separately. If the shim invokes `compose config` to inspect mounts and the user supplied `-f -`, buffer the input once and replay the **same bytes** to the final Compose invocation.

## Q5. Events and ports

**Findings.** Container events include `Type:"container"`, `Action` (`start`, `die`, `destroy`), `Actor.ID`, `Actor.Attributes`, `time`, and `timeNano`; CLI JSON may also expose compatibility keys such as `status` and `id`. A `die` event commonly has `Actor.Attributes.exitCode`; attributes such as `name` and `image` are useful context, not a substitute for the ID. `docker ps --format '{{json .}}'` gives a rendered **string** `Ports`, potentially grouped, so it is unsuitable as the canonical port structure. `docker inspect` gives `NetworkSettings.Ports` keyed by `containerPort/protocol`, with binding arrays containing `HostIp` and `HostPort`; an exposed but unpublished port can map to `null`. [Events](https://docs.docker.com/reference/cli/docker/system/events/), [`ps` JSON example](https://docs.docker.com/reference/cli/docker/container/ls/), [inspect port example](https://docs.docker.com/engine/network/port-publishing/).

**Evidence.** Docker’s inspect example renders IPv6 unspecified address as raw JSON `"HostIp":"::"`; `[::]` is the bracketed address form used in CLI publish syntax and display. [Port publishing](https://docs.docker.com/engine/network/port-publishing/).

**Recommendation.** Consume events by `Type`, `Action`, and `Actor.ID`, then inspect/reconcile state after events or reconnects. Parse inspect’s port keys to separate TCP and UDP; preserve each binding’s IP family and host port. Treat empty `HostPort` as no host listener, as can occur with routed IPv6.

## Q6. Automatically allocated host ports

**Findings.** For `-p 127.0.0.1::5432`, Docker chooses a host port from the **Docker host VM’s** ephemeral range, documented as `/proc/sys/net/ipv4/ip_local_port_range`. `32768–60999` is a common Linux default, not a guaranteed Docker or Colima value; read it inside the VM. A historical Docker 20.x regression ignored that sysctl and used `49153–65535`, then was fixed, which reinforces checking the running version. Docker documents a supported **per-publish** host-port range, such as `-p 127.0.0.1:20000-29999:5432`. [Docker run](https://docs.docker.com/reference/cli/docker/container/run/), [host-port range example](https://docs.docker.com/engine/network/links/#connect-using-network-port-mapping), [Moby regression and fix](https://github.com/moby/moby/issues/43054).

**Evidence.** `daemon.json` documents default **binding address** controls, but no documented daemon-wide published-port allocation range. Colima supports VM startup provisioning for sysctls. [Port publishing](https://docs.docker.com/engine/network/port-publishing/#setting-the-default-bind-address-for-containers), [Colima configuration](https://github.com/abiosoft/colima/blob/main/embedded/defaults/colima.yaml).

**Recommendation.** For mini-managed publishes, use an explicit, chosen host-port range in `-p`, inspect the assigned port afterward, and handle allocation failure or laptop forwarding conflicts. A VM `ip_local_port_range` sysctl is a broader system change and still cannot reserve the corresponding macOS ports; choose the range with the laptop’s listeners and ephemeral range in mind.

## Q7. Python 3.9 state and scheduling

**Findings.** `tempfile.mkstemp(dir=state_dir)` securely creates a unique file; same-directory `os.replace` atomically replaces the JSON path on POSIX. `fcntl.flock` can coordinate cooperating writers, while `time.monotonic()` measures intervals without wall-clock jumps. [mkstemp](https://docs.python.org/3.9/library/tempfile.html#tempfile.mkstemp), [os.replace](https://docs.python.org/3.9/library/os.html#os.replace), [flock](https://docs.python.org/3.9/library/fcntl.html#fcntl.flock), [monotonic](https://docs.python.org/3.9/library/time.html#time.monotonic).

**Evidence.** Atomic replacement protects readers from partial JSON, but by itself does **not** prevent two writers from losing each other’s read-modify-write updates.

**Recommendation.** Lock a persistent `state.json.lock` sidecar with `LOCK_EX`; while holding it, read current JSON, update, write a same-directory `mkstemp` file, flush and `fsync` it, `os.replace` it, then `fsync` the directory if crash durability matters. Clean up the temporary file in `finally`. Never lock the JSON inode that gets replaced. Schedule with monotonic deadlines (`next_due += interval`, sleeping only until the next due time); persist real timestamps separately when state must survive restart.

## Q8. SSH master liveness

**Findings.** `ssh -O check` confirms that the **local multiplexing master process** responds; it does not execute a remote request and therefore does not prove the remote session or host is currently responsive. `ServerAliveInterval` sends encrypted probes when idle, and `ServerAliveCountMax` bounds how many unanswered probes precede disconnect. `ConnectTimeout` bounds connection establishment, not an arbitrary stalled remote command. [ssh(1)](https://man.openbsd.org/ssh.1), [ssh_config(5)](https://man.openbsd.org/ssh_config.5).

**Evidence.** OpenSSH 9.8 introduced enabled-by-default server-side `PerSourcePenalties`; `noauth` applies when a client disconnects without attempting authentication. The current manual lists a 1-second `noauth` penalty and a 15-second minimum before enforcement, subject to server configuration. macOS **15 Sequoia shipped `/usr/bin/ssh` 9.8p1** in documented 15.x builds; check `ssh -V` on the exact host and the **remote `sshd` version/config**, because the penalty is imposed by the server. [OpenSSH 9.8 release notes](https://www.openssh.org/txt/release-9.8), [sshd_config(5)](https://man.openbsd.org/sshd_config.5), [macOS 15.1 package record](https://macosdb.com/macos/release/15.1-24B2083/).

**Recommendation.** Configure the master with `ServerAliveInterval` and `ServerAliveCountMax` for routine stale-session detection. For an immediate health check, run a cheap authenticated `ssh -S <socket> -o BatchMode=yes -o ConnectTimeout=... <host> true` with a **subprocess wall-clock timeout**; successful completion proves a remote command ran. Avoid repeated raw TCP connect-and-close probes, which can accrue `noauth` penalties on OpenSSH 9.8+ servers.