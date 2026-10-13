"""rdocker rd_args: docker argv parsing from explicit per-command flag tables (run/create, container
subcommands, compose globals, compose run/up/create), mounts, publish specs, the compose model.

Split out of rdocker.py; see rdocker.py for the overview.
"""
import json
import re

import rd_common


START_LIKE = {"run", "start", "restart", "unpause"}
STOP_LIKE = {"stop", "rm", "kill", "pause"}
COMPOSE_START = {"up", "start", "restart", "run", "create"}
COMPOSE_STOP = {"down", "stop", "rm", "kill", "pause"}
# Subcommands whose first positional is a container (or name:path for cp).
CONTAINER_TARGETED = {
    "exec", "logs", "rm", "stop", "start", "restart", "inspect", "port", "cp", "kill",
    "wait", "top", "attach", "pause", "unpause", "rename", "update", "commit", "diff",
    "export", "stats",
}
MULTI_TARGET = {"rm", "stop", "kill", "start", "restart", "pause", "unpause", "inspect", "wait"}
# Targeted subcommands that only read: when the mini is unreachable and the container is found only on
# the laptop, these may still run there (with a notice); every other targeted subcommand refuses.
READ_ONLY_TARGETED = {"logs", "inspect", "port", "top", "stats", "diff", "wait", "export"}
# `docker <group> <sub>`: only `container` keeps container semantics; image/volume/... inspect/rm
# are not container commands and are never located.
MGMT_GROUPS = {"container", "image", "volume", "network", "system", "builder"}
COMPOSE_TARGETED = {"down", "stop", "start", "restart", "rm", "exec", "logs", "ps", "kill",
                    "pause", "unpause", "top", "port"}
COMPOSE_READ_ONLY = {"ps", "logs", "top", "port"}
COMPOSE_CREATING = {"up", "run", "create"}
RUN_LIKE = {"run", "create"}
NAMED_VOLUME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
DOCKER_SOCKETS = ("/var/run/docker.sock", "/run/docker.sock")
RAW_PASSTHRU = {"context", "login", "logout", "help", "completion", "--help", "-h",
                "--version", "-v", "version", "plugin", "trust", "scout", "init", "desktop",
                "debug", "extension", "sbom", "mcp", "model", "ai", "offload"}
# docker global flags that take a value
GLOBAL_VALUE_FLAGS = {"--config", "-c", "--context", "-H", "--host", "-l", "--log-level",
                      "--tlscacert", "--tlscert", "--tlskey"}


# ---------------------------------------------------------------------------- flag tables
#
# Explicit per-command tables from the local docker 28.5.1 / compose `--help` output
# (docs/docker-cli-semantics.md Q2-Q4). "a/b" is one short/long alias pair; options are recorded under
# their long name. A flag that is in no table is UNKNOWN - never guessed to be a boolean or a value.

class Spec:
    """One command's flags: value-taking vs boolean, aliases, and whether flags may follow
    positionals (cobra's default) or option parsing stops at the first positional (run, create,
    exec, top, compose run: everything after IMAGE / CONTAINER / SERVICE belongs to the container)."""

    def __init__(self, values, bools, interspersed=True, aliases=None):
        self.values, self.bools, self.alias = set(), set(), dict(aliases or {})
        for words, into in ((values, self.values), (bools, self.bools)):
            for w in words.split():
                names = w.split("/")
                into.add(names[-1])
                for n in names[:-1]:
                    self.alias[n] = names[-1]
        self.interspersed = interspersed

    def canon(self, name):
        return self.alias.get(name, name)


_RUN_VALUES = """
--add-host --annotation -a/--attach --blkio-weight --blkio-weight-device --cap-add --cap-drop
--cgroup-parent --cgroupns --cidfile --cpu-count --cpu-percent --cpu-period --cpu-quota
--cpu-rt-period --cpu-rt-runtime -c/--cpu-shares --cpus --cpuset-cpus --cpuset-mems --detach-keys
--device --device-cgroup-rule --device-read-bps --device-read-iops --device-write-bps
--device-write-iops --dns --dns-option --dns-search --domainname --entrypoint -e/--env --env-file
--expose --gpus --group-add --health-cmd --health-interval --health-retries --health-start-interval
--health-start-period --health-timeout -h/--hostname --io-maxbandwidth --io-maxiops --ip --ip6 --ipc
--isolation --kernel-memory -l/--label --label-file --link --link-local-ip --log-driver --log-opt
--mac-address -m/--memory --memory-reservation --memory-swap --memory-swappiness --mount --name
--network --network-alias --oom-score-adj --pid --pids-limit --platform -p/--publish --pull --restart
--runtime --security-opt --shm-size --stop-signal --stop-timeout --storage-opt --sysctl --tmpfs
--ulimit -u/--user --userns --uts -v/--volume --volume-driver --volumes-from -w/--workdir
"""
_CREATE_BOOLS = ("--disable-content-trust --help --init --no-healthcheck --oom-kill-disable "
                 "--privileged -P/--publish-all -q/--quiet --read-only --rm -t/--tty --use-api-socket")
# --net / --net-alias: docker's hidden legacy spellings of --network / --network-alias.
_RUN_ALIASES = {"--net": "--network", "--net-alias": "--network-alias"}
_STOP = "-s/--signal -t/--timeout"

SPECS = {
    "run": Spec(_RUN_VALUES, _CREATE_BOOLS + " -d/--detach -i/--interactive --sig-proxy",
                interspersed=False, aliases=_RUN_ALIASES),
    "create": Spec(_RUN_VALUES, _CREATE_BOOLS, interspersed=False, aliases=_RUN_ALIASES),
    "exec": Spec("--detach-keys -e/--env --env-file -u/--user -w/--workdir",
                 "-d/--detach -i/--interactive --privileged -t/--tty --help", interspersed=False),
    "logs": Spec("--since -n/--tail --until", "--details -f/--follow -t/--timestamps --help"),
    "rm": Spec("", "-f/--force -l/--link -v/--volumes --help"),
    "stop": Spec(_STOP, "--help"),
    "restart": Spec(_STOP, "--help"),
    "start": Spec("--checkpoint --checkpoint-dir --detach-keys", "-a/--attach -i/--interactive --help"),
    "kill": Spec("-s/--signal", "--help"),
    # generic `docker inspect` (adds --type); `container inspect` lacks it, harmless here
    "inspect": Spec("-f/--format --type", "-s/--size --help"),
    "port": Spec("", "--help"),
    "cp": Spec("", "-a/--archive -L/--follow-link -q/--quiet --help"),
    "wait": Spec("", "--help"),
    "top": Spec("", "--help", interspersed=False),      # `top CONTAINER [ps OPTIONS]`: ps args opaque
    "attach": Spec("--detach-keys", "--no-stdin --sig-proxy --help"),
    "pause": Spec("", "--help"),
    "unpause": Spec("", "--help"),
    "rename": Spec("", "--help"),
    "update": Spec("--blkio-weight --cpu-period --cpu-quota --cpu-rt-period --cpu-rt-runtime "
                   "-c/--cpu-shares --cpus --cpuset-cpus --cpuset-mems -m/--memory "
                   "--memory-reservation --memory-swap --pids-limit --restart", "--help"),
    "commit": Spec("-a/--author -c/--change -m/--message", "-p/--pause --help"),
    "diff": Spec("", "--help"),
    "export": Spec("-o/--output", "--help"),
    "stats": Spec("--format", "-a/--all --no-stream --no-trunc --help"),
    # compose globals (before the compose subcommand); --workdir / --no-ansi / --verbose are
    # compose's hidden legacy flags
    "compose": Spec("--ansi --env-file -f/--file --parallel --profile --progress --project-directory "
                    "-p/--project-name", "--all-resources --compatibility --dry-run -h/--help "
                    "--no-ansi --verbose", interspersed=False,
                    aliases={"--workdir": "--project-directory"}),
    "compose run": Spec("--cap-add --cap-drop --entrypoint -e/--env --env-from-file -l/--label --name "
                        "-p/--publish --pull -u/--user -v/--volume -w/--workdir",
                        "--build -d/--detach -i/--interactive --no-deps -T/--no-TTY -t/--tty "
                        "-q/--quiet --quiet-build --quiet-pull --remove-orphans --rm "
                        "-P/--service-ports --use-aliases -h/--help", interspersed=False),
    "compose up": Spec("--attach --exit-code-from --no-attach --pull --scale -t/--timeout "
                       "--wait-timeout",
                       "--abort-on-container-exit --abort-on-container-failure "
                       "--always-recreate-deps --build -d/--detach --force-recreate --menu "
                       "--no-build --no-color --no-deps --no-log-prefix --no-recreate --no-start "
                       "--quiet-build --quiet-pull --remove-orphans -V/--renew-anon-volumes "
                       "--timestamps --wait -w/--watch -y/--yes -h/--help"),
    "compose create": Spec("--pull --scale", "--build --force-recreate --no-build --no-recreate "
                           "--quiet-build --quiet-pull --remove-orphans -y/--yes -h/--help"),
}
_TRUE = {"1", "t", "T", "true", "TRUE", "True"}      # pflag's ParseBool


class Opt:
    """One parsed option. `value` is None for a bare boolean. When the value can be rewritten in
    place, `args[index] == prefix + value` (-p v: index of v, prefix ""; --publish=v, -dp5432:5432)."""
    __slots__ = ("name", "value", "index", "prefix")

    def __init__(self, name, value, index, prefix):
        self.name, self.value, self.index, self.prefix = name, value, index, prefix


class Parsed:
    def __init__(self):
        self.opts, self.positionals, self.unknown = [], [], []
        self.first_pos = None      # argv index of the first positional (run: the image)

    def values(self, name):
        return [o.value for o in self.opts if o.name == name and o.value is not None]

    def last(self, name):
        vals = self.values(name)
        return vals[-1] if vals else None

    def flag(self, name):
        """Boolean flag state; the last occurrence wins (`--rm --rm=false` is off)."""
        state = False
        for o in self.opts:
            if o.name == name:
                state = o.value is None or o.value in _TRUE
        return state


def parse(args, spec):
    """pflag-style parse of `args` against `spec`: `--x v`, `--x=v`, boolean short clusters (-dit),
    attached short values (-p5432:5432, -eA=1, -n=5: once a value-taking letter is reached the rest of
    the cluster is its value), `--` ends options. Flags absent from `spec` land in `.unknown` (width 1,
    the remainder of a short cluster is not interpreted); callers decide what unknown means."""
    p, i = Parsed(), 0
    while i < len(args):
        a = args[i]
        if a == "--":
            p.first_pos = i + 1 if i + 1 < len(args) and p.first_pos is None else p.first_pos
            p.positionals.extend(args[i + 1:])
            break
        if a == "-" or not a.startswith("-"):
            if p.first_pos is None:
                p.first_pos = i
            if not spec.interspersed:
                p.positionals.extend(args[i:])
                break
            p.positionals.append(a)
            i += 1
            continue
        if a.startswith("--"):
            raw, eq, val = a.partition("=")
            name = spec.canon(raw)
            if name in spec.values:
                if eq:
                    p.opts.append(Opt(name, val, i, raw + "="))
                elif i + 1 < len(args):
                    p.opts.append(Opt(name, args[i + 1], i + 1, ""))
                    i += 1
                else:
                    p.unknown.append(a)            # value missing: docker will reject it
            elif name in spec.bools:
                p.opts.append(Opt(name, val if eq else None, i, None))
            else:
                p.unknown.append(a)
            i += 1
            continue
        j = 1
        while j < len(a):
            name = spec.canon("-" + a[j])
            if name in spec.values:
                rest = a[j + 1:]
                cut = j + 2 if rest.startswith("=") else j + 1
                if rest:
                    p.opts.append(Opt(name, a[cut:], i, a[:cut]))
                elif i + 1 < len(args):
                    p.opts.append(Opt(name, args[i + 1], i + 1, ""))
                    i += 1
                else:
                    p.unknown.append(a)
                break
            if name in spec.bools:
                if a[j + 1:j + 2] == "=":          # -d=false
                    p.opts.append(Opt(name, a[j + 2:], i, None))
                    break
                p.opts.append(Opt(name, None, i, None))
                j += 1
                continue
            p.unknown.append("-" + a[j])
            break
        i += 1
    if p.first_pos is None:
        p.first_pos = len(args)
    return p


def parse_sub(sub, args):
    """Parse a docker subcommand's args with its table; None when there is no table for `sub`."""
    spec = SPECS.get(sub)
    return parse(args, spec) if spec is not None else None


def split_global(argv):
    """-> (global_flags, rest). rest[0] is the subcommand (if any)."""
    i = 0
    while i < len(argv):
        a = argv[i]
        if not a.startswith("-") or a == "-":
            break
        if a in GLOBAL_VALUE_FLAGS:
            i += 2
            continue
        i += 1
    return argv[:i], argv[i:]


def is_detached(args, sub="run"):
    """-d/--detach among the flags BEFORE the first positional (after the image it is the
    container's own argument). `sub` may be "compose up" / "compose run"."""
    p = parse_sub(sub, args)
    return bool(p and p.flag("--detach"))


def unknown_flags(sub, args):
    """Flags of `sub` absent from its table (before the image for run/create)."""
    p = parse_sub(sub, args)
    return p.unknown if p else []


# ---------------------------------------------------------------------------- mounts / placement

def is_bind_source(src):
    """A -v source that is a laptop path (absolute, ./relative, ~/, $VAR). The docker socket is not:
    every engine has its own, so mounting it is engine-local, not a laptop file."""
    if src in DOCKER_SOCKETS:
        return False
    return src.startswith(("/", ".", "~", "$"))


def volume_bind(v):
    """A -v/--volume value -> its laptop bind source, or None (named or anonymous volume)."""
    if ":" not in v:
        return None                 # `-v /data`: anonymous volume
    src = v.split(":", 1)[0]
    return src if is_bind_source(src) else None


def volume_named(v):
    src = v.split(":", 1)[0] if ":" in v else ""
    return src if src and NAMED_VOLUME_RE.match(src) else None


def _mount_kv(v):
    return dict(part.split("=", 1) for part in v.split(",") if "=" in part)


def run_needs_local(args, sub="run"):
    """run/create: bind mounts of laptop paths or host networking must run on the laptop."""
    p = parse_sub(sub, args)
    for v in p.values("--volume"):
        src = volume_bind(v)
        if src:
            return "bind mount " + src
    for v in p.values("--mount"):
        kv = _mount_kv(v)
        if kv.get("type") == "bind" and (kv.get("source") or kv.get("src")) not in DOCKER_SOCKETS:
            return "bind mount (--mount)"
    if p.last("--network") == "host":
        return "--network host"
    return None


def run_named_volumes(args, sub="run"):
    """Named volumes mounted by run/create flags (bind paths and anonymous volumes excluded)."""
    p = parse_sub(sub, args)
    vols = [n for n in (volume_named(v) for v in p.values("--volume")) if n]
    for v in p.values("--mount"):
        kv = _mount_kv(v)
        src = kv.get("source") or kv.get("src") or ""
        if kv.get("type", "volume") == "volume" and NAMED_VOLUME_RE.match(src):
            vols.append(src)
    return vols


def run_not_throwaway(args, sub="run"):
    """None when a run/create is throwaway (--rm, or no named volume and no rdocker.keep label);
    otherwise the reason it must not silently land on the laptop."""
    p = parse_sub(sub, args)
    if p.flag("--rm"):
        return None
    vols = run_named_volumes(args, sub)
    if vols:
        return "it mounts named volume %s" % vols[0]
    if any(lbl.split("=", 1)[0] == "rdocker.keep" for lbl in p.values("--label")):
        return "it carries the rdocker.keep label"
    return None


def container_targets(sub, args):
    p = parse_sub(sub, args)
    pos = p.positionals if p else [a for a in args if not a.startswith("-")]
    if not pos:
        return []
    if sub == "cp":
        return [x.split(":", 1)[0] for x in pos if ":" in x and not x.startswith(("/", "."))][:1]
    if sub in MULTI_TARGET:
        return pos
    return pos[:1]       # top: the rest is opaque ps args; exec/run-like: the rest is the command


# ---------------------------------------------------------------------------- compose

class ComposeConfigError(Exception):
    """`docker compose ... config` failed; str() is compose's own error output."""

    def __init__(self, rc, stderr):
        Exception.__init__(self, stderr)
        self.rc, self.stderr = rc, stderr


def compose_split(args):
    """compose args -> (compose_global_flags, compose_subcommand, rest, unknown_global_flags)."""
    p = parse(args, SPECS["compose"])
    i = p.first_pos
    sub = args[i] if i < len(args) else ""
    return args[:i], sub, args[i + 1:], p.unknown


def compose_reads_stdin(cflags):
    """True when a compose file comes from stdin (`-f -`, `--file=-`, `-f-`)."""
    return "-" in parse(cflags, SPECS["compose"]).values("--file")


def compose_stdin(cflags):
    """The compose file bytes read from stdin, buffered ONCE per shim call so every compose
    invocation (model render and the user's real command) gets the same bytes; None without `-f -`."""
    if not compose_reads_stdin(cflags):
        return None
    return rd_common.buffer_stdin()


def compose_run_needs_local(crest):
    """`compose run -v <laptop path>:...` mounts a laptop path, same rule as docker run."""
    p = parse(crest, SPECS["compose run"])
    for v in p.values("--volume"):
        src = volume_bind(v)
        if src:
            return "compose run bind mount " + src
    return None


def compose_run_named_volumes(crest):
    p = parse(crest, SPECS["compose run"])
    return [n for n in (volume_named(v) for v in p.values("--volume")) if n]


_COMPOSE_MODELS = {}


def compose_model(cflags):
    """The compose model rendered client-side (`compose config --format json`, no daemon needed).
    Rendered once per shim call. Raises ComposeConfigError when compose itself fails (bad file,
    unknown flag, missing file); None when it succeeds but prints something that is not a model."""
    key = tuple(cflags)
    if key not in _COMPOSE_MODELS:
        rc, out, err = rd_common.run([rd_common.real_docker(), "compose"] + cflags
                                     + ["config", "--format", "json"],
                                     timeout=20, input_=compose_stdin(cflags))
        if rc != 0:
            _COMPOSE_MODELS[key] = ComposeConfigError(rc, err)
        else:
            try:
                model = json.loads(out)
            except ValueError:
                model = None
            _COMPOSE_MODELS[key] = model if isinstance(model, dict) else None
    cached = _COMPOSE_MODELS[key]
    if isinstance(cached, ComposeConfigError):
        raise cached
    return cached


def compose_inspect(cflags):
    """-> (project, needs_local_reason, named_volumes) from the compose model. named_volumes is None
    if the model is unreadable."""
    model = compose_model(cflags)
    if not isinstance(model, dict):
        return parse(cflags, SPECS["compose"]).last("--project-name"), None, None
    project = model.get("name")
    named = sorted((model.get("volumes") or {}).keys())
    for name, svc in (model.get("services") or {}).items():
        if svc.get("network_mode") == "host":
            return project, "service %s uses network_mode: host" % name, named
        for vol in svc.get("volumes") or []:
            if not isinstance(vol, dict):
                continue
            if vol.get("type") == "bind" and is_bind_source(vol.get("source", "")):
                return project, "service %s bind-mounts %s" % (name, vol.get("source")), named
            if vol.get("type") == "volume" and vol.get("source") and vol["source"] not in named:
                named.append(vol["source"])
    return project, None, named


def compose_services_and_publish(csub, crest):
    """compose up/create/run -> (service positionals, `-p` values of compose run, --service-ports,
    --no-deps). For run only the first positional is the service; the rest is its command."""
    p = parse_sub("compose " + csub, crest)
    if p is None:
        return [], [], False, False
    pos = p.positionals[:1] if csub == "run" else p.positionals
    return pos, p.values("--publish"), p.flag("--service-ports"), p.flag("--no-deps")


def _port_range(text):
    """'5432' -> (5432, 5432); '8000-8010' -> (8000, 8010); '' -> None. ValueError on junk."""
    if text == "":
        return None
    lo, _, hi = text.partition("-")
    lo, hi = int(lo), int(hi) if hi else int(lo)
    if not (0 < lo <= hi <= 65535):
        raise ValueError(text)
    return lo, hi


def parse_publish(value):
    """A `-p` value -> {"ip", "host": (lo, hi)|None, "cport": (lo, hi), "proto", "proto_given"};
    None when unparsable (docker then reports it). Forms: cport, cport/tcp, hp:cp, ip:hp:cp,
    ip::cp, [v6]:hp:cp, and ranges h1-h2:c1-c2 / c1-c2."""
    v, proto, given = value, "tcp", False
    if "/" in v:
        v, proto = v.rsplit("/", 1)
        given = True
    ip = ""
    try:
        if v.startswith("["):
            close = v.index("]")
            ip, rest = v[1:close], v[close + 1:]
            if not rest.startswith(":"):
                return None
            parts = rest[1:].split(":")
            if len(parts) != 2:
                return None
            host, cport = parts
        else:
            parts = v.split(":")
            if len(parts) == 1:
                host, cport = "", parts[0]
            elif len(parts) == 2:
                host, cport = parts
            elif len(parts) == 3:
                ip, host, cport = parts
            else:
                return None
        h, c = _port_range(host), _port_range(cport)
    except ValueError:
        return None
    if c is None:
        return None
    return {"ip": ip, "host": h, "cport": c, "proto": proto.lower() or "tcp", "proto_given": given}


def format_publish(s):
    ip = ("[%s]:" % s["ip"] if ":" in s["ip"] else s["ip"] + ":") if s["ip"] else ""
    rng = lambda r: str(r[0]) if r[0] == r[1] else "%d-%d" % r  # noqa: E731
    host = rng(s["host"]) if s["host"] else ""
    out = "%s%s:%s" % (ip, host, rng(s["cport"])) if (ip or host) else rng(s["cport"])
    return out + ("/" + s["proto"] if s["proto_given"] else "")


def publish_slots(args, sub="run"):
    """run/create `-p` occurrences before the image -> [(argv index, prefix, value)], so a value can
    be rewritten in place as args[index] = prefix + new_value. Handles -p v, -pv, -dp v, -p=v,
    --publish v, --publish=v."""
    return [(o.index, o.prefix, o.value) for o in parse_sub(sub, args).opts if o.name == "--publish"]
