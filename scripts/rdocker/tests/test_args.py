"""docker argv parsing (rd_args) against the research flag tables (docs/docker-cli-semantics.md Q2-Q4),
plus shim-level checks of `compose -f -` stdin replay and `compose config` failure.

The flag lists below are copied from the research doc on purpose: they are an independent statement
of docker 28.5.1's `--help`, so a table edit in rd_args that drifts from it fails here.

Run: /usr/bin/python3 -m unittest discover -s tests -v
"""
import hashlib
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_shim_safety import ShimCase, r  # noqa: E402
import rdmods  # noqa: E402

# Q3: run value-taking flags (create: same), and run booleans (create lacks -d -i --sig-proxy).
RUN_VALUES = """
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
""".split()
RUN_BOOLS = ("-d/--detach --disable-content-trust --help --init -i/--interactive --no-healthcheck "
             "--oom-kill-disable --privileged -P/--publish-all -q/--quiet --read-only --rm --sig-proxy "
             "-t/--tty --use-api-socket").split()
CREATE_ONLY_MISSING = {"-d", "--detach", "--sig-proxy"}   # docker 28.5.1 `create --help` does list -i/--interactive

# Q2: per container subcommand (value flags, boolean flags).
Q2 = {
    "exec": ("--detach-keys -e/--env --env-file -u/--user -w/--workdir",
             "-d/--detach -i/--interactive --privileged -t/--tty"),
    "logs": ("--since -n/--tail --until", "--details -f/--follow -t/--timestamps"),
    "rm": ("", "-f/--force -l/--link -v/--volumes"),
    "stop": ("-s/--signal -t/--timeout", ""),
    "start": ("--checkpoint --checkpoint-dir --detach-keys", "-a/--attach -i/--interactive"),
    "restart": ("-s/--signal -t/--timeout", ""),
    "kill": ("-s/--signal", ""),
    "inspect": ("-f/--format --type", "-s/--size"),
    "port": ("", ""), "wait": ("", ""), "top": ("", ""), "pause": ("", ""), "unpause": ("", ""),
    "rename": ("", ""), "diff": ("", ""),
    "cp": ("", "-a/--archive -L/--follow-link -q/--quiet"),
    "attach": ("--detach-keys", "--no-stdin --sig-proxy"),
    "update": ("--blkio-weight --cpu-period --cpu-quota --cpu-rt-period --cpu-rt-runtime "
               "-c/--cpu-shares --cpus --cpuset-cpus --cpuset-mems -m/--memory --memory-reservation "
               "--memory-swap --pids-limit --restart", ""),
    "commit": ("-a/--author -c/--change -m/--message", "-p/--pause"),
    "export": ("-o/--output", ""),
    "stats": ("--format", "-a/--all --no-stream --no-trunc"),
}

# Q4: compose globals; compose run.
COMPOSE_VALUES = "--ansi --env-file -f/--file --parallel --profile --progress --project-directory -p/--project-name"
COMPOSE_BOOLS = "--all-resources --compatibility --dry-run"
COMPOSE_RUN_VALUES = ("--cap-add --cap-drop --entrypoint -e/--env --env-from-file -l/--label --name "
                      "-p/--publish --pull -u/--user -v/--volume -w/--workdir")
COMPOSE_RUN_BOOLS = ("--build -d/--detach -i/--interactive --no-deps -T/--no-TTY -q/--quiet --rm "
                     "-P/--service-ports --use-aliases --remove-orphans --quiet-pull")


def names(words):
    """"-e/--env --rm" (or a list of such words) -> ["-e", "--env", "--rm"]."""
    if isinstance(words, str):
        words = words.split()
    return [n for w in words for n in w.split("/")]


class RunCreateTables(unittest.TestCase):
    """Every Q3 flag: a value flag consumes the next word, a boolean does not (so IMAGE is found)."""

    def first(self, sub, args):
        return r.parse_sub(sub, args).first_pos

    def test_every_value_flag_takes_a_value(self):
        for sub in ("run", "create"):
            for f in names(RUN_VALUES):
                p = r.parse_sub(sub, [f, "X", "img", "cmd"])
                self.assertEqual((p.first_pos, p.unknown), (2, []), (sub, f))
                if f.startswith("--"):
                    self.assertEqual(self.first(sub, [f + "=X", "img"]), 1, (sub, f))

    def test_every_boolean_takes_none(self):
        for sub in ("run", "create"):
            for f in names(RUN_BOOLS):
                p = r.parse_sub(sub, [f, "img", "cmd"])
                if sub == "create" and f in CREATE_ONLY_MISSING:
                    self.assertEqual(p.unknown, [f], f)
                    continue
                self.assertEqual((p.first_pos, p.unknown), (1, []), (sub, f))
        for f in ("-a", "-c", "-e", "-h", "-l", "-m", "-p", "-u", "-v", "-w"):
            self.assertEqual(self.first("run", [f, "X", "img"]), 2, f)
        for f in ("-d", "-i", "-P", "-q", "-t"):
            self.assertEqual(self.first("run", [f, "img"]), 1, f)

    def test_short_clusters(self):
        for c in ("-dit", "-itd"):
            p = r.parse_sub("run", [c, "img"])
            self.assertEqual(sorted(o.name for o in p.opts), ["--detach", "--interactive", "--tty"])
            self.assertEqual(p.first_pos, 1)
        p = r.parse_sub("run", ["-p5432:5432", "-eFOO=1", "img"])
        self.assertEqual((p.values("--publish"), p.values("--env"), p.first_pos),
                         (["5432:5432"], ["FOO=1"], 2))
        # once a value letter is reached, the rest of the cluster is its value
        p = r.parse_sub("run", ["-itv/x:/y", "img"])
        self.assertEqual((p.values("--volume"), p.first_pos), (["/x:/y"], 1))
        self.assertEqual(r.parse_sub("run", ["-dp", "80:80", "img"]).values("--publish"), ["80:80"])
        self.assertEqual(r.parse_sub("logs", ["-n=5", "db"]).values("--tail"), ["5"])
        self.assertEqual(r.parse_sub("run", ["-a", "stdout", "-p", "80", "img"]).first_pos, 4)

    def test_long_equals_and_aliases(self):
        p = r.parse_sub("run", ["--name=x", "--env", "A=1", "--net=host", "img"])
        self.assertEqual((p.last("--name"), p.values("--env"), p.last("--network")), ("x", ["A=1"], "host"))
        self.assertTrue(r.parse_sub("run", ["--rm", "img"]).flag("--rm"))
        self.assertFalse(r.parse_sub("run", ["--rm=false", "img"]).flag("--rm"))
        self.assertFalse(r.parse_sub("run", ["--rm", "--rm=false", "img"]).flag("--rm"))

    def test_double_dash_and_image_terminate_options(self):
        p = r.parse_sub("run", ["--rm", "--", "img", "-v", "/x:/y"])
        self.assertEqual((p.positionals[0], p.values("--volume")), ("img", []))
        p = r.parse_sub("run", ["--rm", "img", "-v", "/x:/y", "--network", "host"])
        self.assertEqual((p.positionals, p.values("--volume")), (["img", "-v", "/x:/y", "--network", "host"], []))

    def test_unknown_flags_are_reported_not_guessed(self):
        self.assertEqual(r.unknown_flags("run", ["--bogus", "x", "img"]), ["--bogus"])
        self.assertEqual(r.unknown_flags("run", ["-dZ", "img"]), ["-Z"])
        self.assertEqual(r.unknown_flags("run", ["--rm", "img", "--bogus"]), [])   # container's arg
        self.assertEqual(r.unknown_flags("create", ["-d", "img"]), ["-d"])


RUN_HELP = """
Usage:  docker container run [OPTIONS] IMAGE [COMMAND] [ARG...]

Create and run a new container from an image

Aliases:
  docker container run, docker run

Options:
      --add-host list                    Add a custom host-to-IP mapping
                                         (host:ip)
  -a, --attach list                      Attach to STDIN, STDOUT or STDERR
  -d, --detach                           Run container in background and
                                         print container ID
      --gpus gpu-request                 GPU devices to add to the container
      --frobnicate string                A flag from a future docker
  -Z                                     A short-only future flag
"""
COMPOSE_RUN_HELP = """
Usage:  docker compose run [OPTIONS] SERVICE [COMMAND] [ARGS...]

Options:
      --build                       Build image before starting container
  -d, --detach                      Run container in background
  -h, --help                        Help for run
      --dry-run                     Execute command in dry run mode (compose global)
      --sparkle                     A future compose run flag
"""


class CreateInteractive(unittest.TestCase):
    def test_create_accepts_interactive(self):
        # found by the live flag-drift check against docker 28.5.1: `create -i` was missing
        for argv in (["-i", "alpine"], ["--interactive", "alpine"], ["-it", "alpine", "sh"]):
            self.assertEqual(r.unknown_flags("create", argv), [], argv)


class RealDockerSkipsShim(unittest.TestCase):
    def test_any_docker_shim_is_skipped(self):
        import tempfile
        d = tempfile.mkdtemp()
        shim = os.path.join(d, "docker-shim")
        with open(shim, "w") as f:
            f.write("#!/bin/sh\n")
        os.chmod(shim, 0o755)
        os.symlink(shim, os.path.join(d, "docker"))
        old = os.environ["PATH"]
        os.environ["PATH"] = d + ":" + old
        try:
            self.assertNotEqual(os.path.realpath(r.real_docker()), shim)
        except SystemExit:
            pass   # no other docker on PATH in the hermetic env is also fine: never the shim
        finally:
            os.environ["PATH"] = old


class FlagDrift(unittest.TestCase):
    """The daemon/doctor diff of the laptop CLI's --help flags against rd_args.SPECS."""

    def test_help_flags_ignore_global_options_section(self):
        text = ("Usage:  docker compose up [OPTIONS]\n\nOptions:\n"
                "  -d, --detach        Detached mode\n      --wait          Wait\n\n"
                "Global Options:\n  -c, --context string   Name of the context\n"
                "  -H, --host string      Daemon socket\n      --tls          Use TLS\n")
        self.assertEqual(r.help_flags(text), {"-d", "--detach", "--wait"})

    def test_help_flags_parses_long_short_and_skips_descriptions(self):
        self.assertEqual(r.help_flags(RUN_HELP), {"--add-host", "-a", "--attach", "-d", "--detach",
                                                  "--gpus", "--frobnicate", "-Z"})

    def test_drift_lists_only_unknown_flags(self):
        texts = {("run", "--help"): RUN_HELP, ("compose", "run", "--help"): COMPOSE_RUN_HELP}
        drift = r.flag_drift(lambda argv: texts.get(tuple(argv)))
        self.assertEqual(drift, ["compose run --sparkle", "run --frobnicate", "run -Z"])

    def test_no_help_text_is_none_not_clean(self):
        self.assertIsNone(r.flag_drift(lambda argv: None))
        self.assertEqual(r.flag_drift(lambda argv: "Options:\n  -d, --detach  x\n"
                                      if argv[0] == "run" else None), [])

    def test_check_raises_and_clears_attention(self):
        import tempfile
        import shutil
        from unittest import mock
        rd_common, rd_daemon = rdmods.owner("ATTENTION_PATH"), rdmods.owner("flag_drift_check")
        tmp = tempfile.mkdtemp(prefix="rdk-drift-")
        self.addCleanup(shutil.rmtree, tmp, True)
        texts = {"run": RUN_HELP}
        with mock.patch.object(rd_common, "ATTENTION_PATH", os.path.join(tmp, "att.json")), \
                mock.patch.object(rd_common, "log"), \
                mock.patch.object(rd_common, "real_docker", lambda: "/x/docker"), \
                mock.patch.object(rd_common, "run", lambda argv, timeout=30: (
                    (0, texts[argv[1]], "") if argv[1] in texts and argv[2] == "--help"
                    else (1, "", "no"))):
            self.assertEqual(rd_daemon.flag_drift_check(), ["run --frobnicate", "run -Z"])
            msg = rd_common.attention_items()[0]["msg"]
            self.assertIn("docker CLI has 2 flag(s) rdocker doesn't know: run --frobnicate, run -Z",
                          msg)
            self.assertIn("add them to rd_args.SPECS", msg)
            texts["run"] = "Options:\n  -d, --detach  x\n"
            self.assertEqual(rd_daemon.flag_drift_check(), [])
            self.assertEqual(rd_common.attention_items(), [])

    def test_installed_tables_cover_their_own_names(self):
        """Every SPECS key has a --help argv (a new table without one would never be checked)."""
        self.assertTrue(set(r.HELP_ARGV) <= set(r.SPECS))


class ContainerSubcommandTables(unittest.TestCase):
    def test_q2_every_flag(self):
        for sub, (vals, bools) in Q2.items():
            for f in names(vals):
                p = r.parse_sub(sub, [f, "X", "c1"])
                self.assertEqual((p.positionals[:1], p.unknown), (["c1"], []), (sub, f))
            for f in names(bools):
                p = r.parse_sub(sub, [f, "c1"])
                self.assertEqual((p.positionals[:1], p.unknown), (["c1"], []), (sub, f))

    def test_container_targets(self):
        T = r.container_targets
        self.assertEqual(T("exec", ["-i", "-e", "A=1", "db", "psql"]), ["db"])
        self.assertEqual(T("exec", ["-it", "-u", "0", "db", "sh", "-c", "x"]), ["db"])
        self.assertEqual(T("rm", ["-f", "a", "b"]), ["a", "b"])
        self.assertEqual(T("rm", ["a", "-f", "b"]), ["a", "b"])           # cobra: interspersed
        self.assertEqual(T("cp", ["db:/x.sql", "./x.sql"]), ["db"])
        self.assertEqual(T("logs", ["--tail", "5", "db"]), ["db"])
        self.assertEqual(T("logs", ["-n", "5", "db"]), ["db"])
        self.assertEqual(T("logs", ["-n5", "-f", "db"]), ["db"])
        self.assertEqual(T("logs", ["--tail=5", "-ft", "db"]), ["db"])
        self.assertEqual(T("stop", ["-t", "0", "a", "b"]), ["a", "b"])
        self.assertEqual(T("kill", ["-s", "KILL", "a"]), ["a"])
        self.assertEqual(T("inspect", ["-f", "{{.Id}}", "db"]), ["db"])
        self.assertEqual(T("top", ["db", "-o", "pid"]), ["db"])             # ps args are opaque
        self.assertEqual(T("commit", ["-m", "msg", "db", "img"]), ["db"])
        self.assertEqual(r.parse_sub("inspect", ["--type", "image", "x"]).last("--type"), "image")

    def test_split_global(self):
        self.assertEqual(r.split_global(["--context", "x", "ps", "-a"]), (["--context", "x"], ["ps", "-a"]))
        self.assertEqual(r.split_global(["-D", "run", "img"]), (["-D"], ["run", "img"]))
        self.assertEqual(r.split_global(["-l", "debug", "stop", "db"]), (["-l", "debug"], ["stop", "db"]))


class Detached(unittest.TestCase):
    def test_run_detached_only_before_image(self):
        self.assertTrue(r.is_detached(["-dit", "--rm", "alpine"]))
        self.assertTrue(r.is_detached(["--name", "x", "-d", "alpine"]))
        self.assertFalse(r.is_detached(["--rm", "alpine", "sh", "-d"]))
        self.assertFalse(r.is_detached(["-e", "d=1", "alpine"]))
        self.assertFalse(r.is_detached(["-a", "stdout", "alpine"]))
        self.assertFalse(r.is_detached(["--detach=false", "alpine"]))

    def test_compose_detached(self):
        self.assertTrue(r.is_detached(["-d"], "compose up"))
        self.assertTrue(r.is_detached(["--build", "-d", "web"], "compose up"))
        self.assertTrue(r.is_detached(["-d", "web", "sh"], "compose run"))
        self.assertFalse(r.is_detached(["web", "sh", "-d"], "compose run"))
        self.assertFalse(r.is_detached([], "compose start"))


class Placement(unittest.TestCase):
    def needs(self, cmd):
        return r.run_needs_local(cmd.split())

    def test_named_volume_and_ports_stay_remote(self):
        self.assertIsNone(self.needs("-d --name x -e A=1 -p 127.0.0.1::5432 -v pgdata:/var/lib/postgresql/data postgres:17"))

    def test_bind_sources(self):
        for src in ("/tmp/x", "./init.sql", "~/p", "$PWD", "../up"):
            self.assertTrue(self.needs("--rm -v %s:/w alpine true" % src), src)
        self.assertTrue(self.needs("--rm --volume=/Users/me/p:/p alpine ls"))
        self.assertTrue(self.needs("-it --rm -v/tmp:/t alpine sh"))
        self.assertIsNone(self.needs("--rm -v /anon alpine true"))                  # anonymous
        for s in ("/abs", "./rel", "~/h", "$PWD"):
            self.assertTrue(r.is_bind_source(s))
        for s in ("pgdata", "/var/run/docker.sock", "/run/docker.sock"):
            self.assertFalse(r.is_bind_source(s))

    def test_mount_flag(self):
        self.assertTrue(self.needs("--rm --mount type=bind,src=/tmp,dst=/t alpine ls"))
        self.assertTrue(self.needs("--rm --mount=type=bind,source=./x,target=/t alpine ls"))
        self.assertIsNone(self.needs("--rm --mount type=bind,src=/var/run/docker.sock,dst=/s alpine"))
        self.assertIsNone(self.needs("--rm --mount type=volume,src=data,dst=/d alpine"))

    def test_host_network(self):
        self.assertTrue(self.needs("--rm --network host postgres:17 pg_dump x"))
        self.assertTrue(self.needs("--rm --network=host alpine true"))
        self.assertTrue(self.needs("--rm --net=host alpine true"))
        self.assertTrue(self.needs("--rm --net host alpine true"))
        self.assertIsNone(self.needs("--rm --network bridge alpine true"))

    def test_docker_socket_mount_is_not_a_laptop_bind(self):
        self.assertIsNone(self.needs("--rm -v /var/run/docker.sock:/var/run/docker.sock alpine true"))

    def test_flags_after_image_belong_to_the_container(self):
        self.assertIsNone(self.needs("--rm postgres:17 psql -v /x:/y --network host"))
        self.assertIsNone(self.needs("--rm -- postgres:17 -v /x:/y"))

    def test_combined_short_flags(self):
        self.assertIsNone(self.needs("-dit --rm -p5432:5432 postgres:17"))
        self.assertTrue(self.needs("-itv/tmp:/t --rm alpine sh"))
        # -e's value is "-v/x:/y", not a volume
        self.assertIsNone(self.needs("-e -v/x:/y --rm alpine"))

    def test_create_uses_its_own_table(self):
        self.assertTrue(r.run_needs_local(["-v", "/x:/y", "img"], "create"))

    def test_throwaway(self):
        T = r.run_not_throwaway
        self.assertIsNone(T(["--rm", "-v", "data:/d", "pg"]))
        self.assertIsNone(T(["-d", "-v", "/var/run/docker.sock:/s", "x"]))
        self.assertIsNone(T(["-d", "-v", "/anon", "x"]))
        self.assertTrue(T(["-d", "-v", "data:/d", "pg"]))
        self.assertTrue(T(["--rm=false", "-v", "data:/d", "pg"]))
        self.assertTrue(T(["-d", "--mount", "source=data,target=/d", "pg"]))
        self.assertTrue(T(["-d", "--label", "rdocker.keep=1", "pg"]))
        self.assertTrue(T(["-dl", "rdocker.keep", "pg"]))
        self.assertIsNone(T(["alpine", "-v", "data:/d"]))   # after the image


class Publish(unittest.TestCase):
    def test_publish_forms(self):
        P = r.parse_publish
        self.assertEqual(P("5432")["host"], None)
        self.assertEqual(P("5432/udp")["proto"], "udp")
        self.assertEqual(P("8080:80")["host"], (8080, 8080))
        self.assertEqual(P("127.0.0.1::5432")["ip"], "127.0.0.1")
        self.assertEqual(P("[::1]:7000:7000")["ip"], "::1")
        s = P("127.0.0.1:8000-8002:8000-8002")
        self.assertEqual((s["host"], s["cport"]), ((8000, 8002), (8000, 8002)))
        self.assertIsNone(P("a:b:c:d"))
        self.assertEqual(r.format_publish(dict(P("127.0.0.1::5432/tcp"), host=(20001, 20001))),
                         "127.0.0.1:20001:5432/tcp")
        self.assertEqual(r.format_publish(dict(P("[::]::80"), host=(9, 9))), "[::]:9:80")

    def test_publish_slots_rewrite_in_place(self):
        args = ["-p", "1:1", "-p2:2", "-dp", "3:3", "-dp4:4", "-p=5:5", "--publish", "6:6",
                "--publish=7:7", "img", "-p", "8:8"]
        slots = r.publish_slots(args)
        self.assertEqual([v for _, _, v in slots], ["1:1", "2:2", "3:3", "4:4", "5:5", "6:6", "7:7"])
        for i, pre, v in slots:
            self.assertEqual(args[i], pre + v)


class Compose(unittest.TestCase):
    def test_globals_table(self):
        for f in names(COMPOSE_VALUES):
            cf, sub, rest, unk = r.compose_split([f, "X", "up", "-d"])
            self.assertEqual((cf, sub, rest, unk), ([f, "X"], "up", ["-d"], []), f)
            if f.startswith("--"):
                self.assertEqual(r.compose_split([f + "=X", "up"])[1], "up", f)
        for f in names(COMPOSE_BOOLS):
            self.assertEqual(r.compose_split([f, "up"])[:3], ([f], "up", []), f)
        self.assertEqual(r.compose_split(["-f", "a.yml", "-p", "p", "up", "-d"]),
                         (["-f", "a.yml", "-p", "p"], "up", ["-d"], []))
        self.assertEqual(r.compose_split(["-fa.yml", "ps"])[:2], (["-fa.yml"], "ps"))
        self.assertEqual(r.compose_split(["--bogus", "x", "up"])[3], ["--bogus"])

    def test_stdin_file_detection(self):
        for cf in (["-f", "-"], ["--file", "-"], ["--file=-"], ["-f-"], ["-f", "a.yml", "-f", "-"]):
            self.assertTrue(r.compose_reads_stdin(cf), cf)
        for cf in ([], ["-f", "a.yml"], ["-p", "-"], ["--env-file", "-"]):
            self.assertFalse(r.compose_reads_stdin(cf), cf)

    def test_compose_run_table(self):
        for f in names(COMPOSE_RUN_VALUES):
            p = r.parse_sub("compose run", [f, "X", "web", "cmd"])
            self.assertEqual((p.positionals[:1], p.unknown), (["web"], []), f)
        for f in names(COMPOSE_RUN_BOOLS):
            p = r.parse_sub("compose run", [f, "web"])
            self.assertEqual((p.positionals, p.unknown), (["web"], []), f)
        self.assertEqual(r.unknown_flags("compose run", ["--bogus", "web"]), ["--bogus"])

    def test_compose_run_volume(self):
        N = r.compose_run_needs_local
        self.assertTrue(N(["--rm", "-v", "./src:/app", "web"]))
        self.assertTrue(N(["--volume=/Users/me:/m", "web"]))
        self.assertTrue(N(["-v/tmp:/t", "web"]))
        self.assertIsNone(N(["-v", "data:/d", "web"]))
        self.assertIsNone(N(["-v", "/var/run/docker.sock:/s", "web"]))
        self.assertIsNone(N(["web", "-v", "/x:/y"]))                     # the service's command
        self.assertEqual(r.compose_run_named_volumes(["-v", "data:/d", "web"]), ["data"])

    def test_services_and_publish(self):
        self.assertEqual(r.compose_services_and_publish("run", ["-P", "-p", "8080:80", "web", "sh"]),
                         (["web"], ["8080:80"], True, False))
        self.assertEqual(r.compose_services_and_publish("up", ["-d", "--no-deps", "--scale", "a=2", "b"]),
                         (["b"], [], False, True))


MODEL = {"name": "proj", "services": {"web": {"image": "nginx"}}}


class ComposeStdinShim(ShimCase):
    """`compose -f -`: stdin is buffered once and the SAME bytes reach every compose invocation."""

    def stdin_rows(self):
        try:
            with open(self.log + ".stdin") as f:
                return [json.loads(line) for line in f if line.strip()]
        except OSError:
            return []

    def check_every_compose_call_got(self, data, n_calls):
        sha = hashlib.sha256(data).hexdigest()
        rows = self.stdin_rows()
        self.assertEqual(len(rows), n_calls, rows)
        self.assertEqual({(x["len"], x["sha256"]) for x in rows}, {(len(data), sha)})
        self.assertEqual(len([a for _, a in self.calls() if "compose" in a]), n_calls)

    def test_compose_up_from_stdin_replays_to_config_and_real_command(self):
        self.scenario()
        data = json.dumps(MODEL).encode()
        p = self.shim("compose", "-f", "-", "up", "-d", input=data)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.check_every_compose_call_got(data, 2)
        real = [a for c, a in self.calls() if c and "compose" in a]
        self.assertEqual(real, [["compose", "-f", "-", "up", "-d"]])
        self.assertEqual([c for c, a in self.calls() if c and "compose" in a], ["mini"])

    def test_compose_targeted_from_stdin_replays_on_the_exec_path(self):
        self.scenario(mini={"containers": {}, "compose_projects": {"proj": ["c1"]}})
        data = json.dumps(MODEL).encode()
        p = self.shim("compose", "--file=-", "ps", input=data)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.check_every_compose_call_got(data, 2)

    def test_failing_compose_config_exits_1_with_its_error(self):
        self.scenario()                              # no model: fake compose config exits 1
        p = self.shim("compose", "up", "-d")
        self.assertEqual(p.returncode, 1, p.stderr)
        self.assertIn("no configuration file provided: not found", p.stderr)
        self.assertEqual(self.calls(), [(None, ["compose", "config", "--format", "json"])])

    def test_unknown_run_flag_refuses_without_docker(self):
        self.scenario()
        p = self.shim("run", "--bogus", "x", "-v", "/tmp:/t", "alpine")
        self.assertEqual(p.returncode, 1)
        self.assertIn("unrecognized flag --bogus", p.stderr)
        self.assertEqual(self.calls("run"), [])
        p = self.shim("run", "--bogus", "x", "alpine", env={"RDOCKER_MODE": "local"})
        self.assertEqual([c for c, _ in self.calls("run")], ["desktop-linux"])

    def test_compose_run_bind_goes_to_laptop(self):
        self.scenario(compose_model=MODEL)
        p = self.shim("compose", "run", "--rm", "-v", "./src:/app", "web", "true")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([c for c, a in self.calls() if c and "compose" in a], ["desktop-linux"])


if __name__ == "__main__":
    unittest.main()
