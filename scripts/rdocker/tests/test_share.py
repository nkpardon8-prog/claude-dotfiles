"""The owner's share switch on a Mac worker: the share-spec block (rr_runner.pl: format, presets, caps, memory
guard), share/rdocker-share.sh (the switch) and its SwiftBar plugin, all run against a temp share file -
never /Users/Shared/rdocker/share - and agreeing with each other and with the worker's own reading
(rd_pool.PROBE) of what they write."""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402

import rd_pool  # noqa: E402

SHARE = os.path.join(rdmods.STAGE, "share", "rdocker-share.sh")
PLUGIN = os.path.join(rdmods.STAGE, "share", "rdocker-share.1m.sh")
RUNNER = os.path.join(rdmods.STAGE, "rr_runner.pl")
BLOCK_RE = re.compile(r"^# >>> share-spec.*?^# <<< share-spec\n", re.S | re.M)
GB = 1 << 30


def block_of(path):
    with open(path) as f:
        m = BLOCK_RE.search(f.read())
    return m.group(0) if m else None


# what each share-file text means: (level, cpu %, ram GB, preset RAM %); None = no file
SPECS = [
    (None, ("max", 100, None, None)),
    ("off\n", ("off", 100, None, None)),
    ("low", ("low", 25, None, 25)),
    ("medium\n", ("medium", 75, None, 50)),
    (" some\r\n", ("medium", 75, None, 50)),          # old word
    ("high", ("high", 100, None, 75)),
    ("max\n", ("high", 100, None, 75)),               # old word
    ("cpu=75 ram=4\n", ("custom", 75, 4, None)),
    ("ram=6", ("custom", 100, 6, None)),
    ("cpu=10", ("custom", 10, None, None)),
    ("  cpu=100   ram=256 \n", ("custom", 100, 256, None)),
    ("ram=4 cpu=25", ("custom", 25, 4, None)),
]
OFF = ["cpu=9", "cpu=101", "ram=0", "ram=257", "cpu=50 cpu=60", "cpu=50,ram=4", "cpu=50 ram=4 x", "MAX",
       " MAX ", "", "maybe", "cpu=", "ram=4GB", "some max", "max" + "0" * 100]


class Block(unittest.TestCase):
    """The block itself, run by perl exactly as the runner and the switch run it."""

    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="share-blk-", dir=rdmods.TEST_HOME)
        self.addCleanup(shutil.rmtree, self.d, True)
        self.block = block_of(RUNNER)

    def pl(self, code, **env):
        prog = "use strict; use warnings; use JSON::PP; use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK);\n" \
               + self.block + code
        e = rdmods.child_env(self.d, **env)
        r = subprocess.run(["/usr/bin/perl", "-e", prog], capture_output=True, text=True, env=e, timeout=30)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, "")
        return json.loads(r.stdout)

    def spec(self, text):
        f = os.path.join(self.d, "share")
        if os.path.lexists(f):
            os.unlink(f)
        if text is not None:
            with open(f, "w") as fh:
                fh.write(text)
        return self.pl('my $s = share_spec(share_read(shift)); print encode_json([@$s{qw(level cpu ram ram_pct)}]);'
                       .replace("shift", '"%s"' % f))

    def test_the_block_is_one_copy_everywhere(self):
        self.assertIsNotNone(self.block)
        self.assertEqual(block_of(SHARE), self.block)               # the switch: byte for byte
        self.assertNotIn("'", self.block)                            # it runs inside a quoted sh string
        self.assertIn(rd_pool.share_spec_pl(), rd_pool.PROBE)        # the probe: spliced from the runner

    def test_old_and_new_formats_parse_the_same_in_every_reader(self):
        for text, want in SPECS:
            self.assertEqual(tuple(self.spec(text)), want, repr(text))
        for text in OFF:
            self.assertEqual(self.spec(text)[0], "off", repr(text))

    def test_a_symlink_fifo_or_unreadable_file_is_off_and_never_blocks(self):
        f = os.path.join(self.d, "share")
        target = os.path.join(self.d, "elsewhere")
        with open(target, "w") as fh:
            fh.write("high\n")
        os.symlink(target, f)
        self.assertEqual(self.pl('print encode_json(share_spec(share_read("%s")));' % f)["level"], "off")
        os.unlink(f)
        os.mkfifo(f)
        self.assertEqual(self.pl('print encode_json(share_spec(share_read("%s")));' % f)["level"], "off")
        os.unlink(f)
        os.mkdir(f)
        self.assertEqual(self.pl('print encode_json(share_spec(share_read("%s")));' % f)["level"], "off")

    def caps(self, text, slots, heavy, ncpu, tot_gb):
        spec = "share_spec(undef)" if text is None else 'share_spec("%s")' % text
        c = self.pl('my $c = share_caps(%s, %s, %s, %d, %d); print encode_json([@$c{qw(slots heavy cores ram_mb vm_cpu vm_mem)}]);'
                    % (spec, slots, "undef" if heavy is None else heavy, ncpu, tot_gb * 1024))
        return tuple(c)

    def test_cap_math_on_nicks_macbook(self):
        # nickmbp: fleet 8 slots / 6 heavy, M5 Max (18 threads), 64 GB. some (= medium, 75 % CPU since
        # 2026-11-25) = 3/4 of the slots + VM 9 / 18,
        # max = everything + VM 12 / 24 (the old %VM table); the RAM cap of the preset never bites there
        for text, want in (("some", (6, 4, 13, 32768, 9, 18)), ("max", (8, 6, 18, 49152, 12, 24)),
                           (None, (8, 6, 18, None, 12, 24))):
            self.assertEqual(self.caps(text, 8, 6, 18, 64), want, text)
        self.assertEqual(self.caps("some", 1, 1, 18, 64)[:2], (1, 1))       # floor, at least 1
        self.assertEqual(self.caps("some", 3, 0, 18, 64)[:2], (2, 0))       # 0 heavy stays 0

    def ram_cap(self, heavy, tot_mb, need=None, fleet_gb=None):
        return self.pl('print encode_json([ram_heavy_cap(%s, %s, %s, %s)]);' % tuple(
            "undef" if v is None else v for v in (heavy, tot_mb, need, fleet_gb)))[0]

    def test_heavy_cap_follows_the_live_ram(self):
        """2026-11-25: fleet heavy_slots is a ceiling; the RAM decides floor((GB - 4) / 8), 0 at least, so hp's
        upgrade (24 -> 32 GB) needs no fleet edit. A Linux MemTotal a little under the size counts as the size."""
        for gb, want in ((24, 2), (32, 3), (40, 4), (48, 5), (64, 7), (12, 1), (11, 0), (8, 0), (2, 0)):
            self.assertEqual(self.ram_cap(99, gb * 1024), want, gb)
        self.assertEqual(self.ram_cap(99, 23840), 2)                         # hp as Linux reads 24 GB
        self.assertEqual(self.ram_cap(99, 32030), 3)                         # ... and 32 GB
        self.assertEqual(self.ram_cap(6, 64 * 1024), 6)                      # the fleet ceiling
        self.assertEqual(self.ram_cap(0, 64 * 1024), 0)                      # heavy_slots 0 stays 0
        self.assertEqual(self.ram_cap(6, 32 * 1024, 12), 2)                  # a job needing 12 GB: (32-4)/12
        self.assertEqual(self.ram_cap(6, 32 * 1024, 6), 3)                   # a smaller need never lowers 8 GB
        self.assertIsNone(self.ram_cap(None, 32 * 1024))                     # no heavy_slots: none
        self.assertEqual(self.ram_cap(6, 11 * 1024 + 4 / 1024.0), 1)      # 11 GiB + 4 KiB: 12 GB
        self.assertEqual(self.ram_cap(6, 11 * 1024), 0)                      # exactly 11 GiB: 11 GB
        # an unreadable total never restores the bare ceiling: the fleet mem_gb, else at most 1
        self.assertEqual(self.ram_cap(6, None, None, 24), 2)
        self.assertEqual(self.ram_cap(6, 0, 12, 32), 2)
        self.assertEqual(self.ram_cap(6, None, None, 8.5), 0)
        self.assertEqual(self.ram_cap(6, None), 1)
        self.assertEqual(self.ram_cap(0, None), 0)
        self.assertEqual(self.ram_cap(6, 64 * 1024, None, 8), 6)            # a live reading wins over mem_gb
        # share_caps applies it first; the share level can only lower it further
        self.assertEqual(self.caps(None, 6, 6, 8, 24)[1], 2)                 # hp today, no switch
        self.assertEqual(self.caps(None, 6, 6, 8, 32)[1], 3)                 # hp after the upgrade
        self.assertEqual(self.caps("medium", 6, 6, 8, 32)[1], 2)             # 3 x 75 % = 2; RAM cap 16 GB: 2
        self.assertEqual(self.caps("cpu=100 ram=12", 6, 6, 8, 64)[1], 2)     # RAM 7 -> 6; ram=12: 2
        self.assertEqual(self.caps("cpu=100 ram=40", 6, 6, 8, 32)[1], 3)     # a big ram= never raises it

    def test_cap_math_on_the_air(self):
        # airm4: fleet 4 slots / 1 heavy, 10 cores, 16 GB
        for text, want in (("low", (1, 0, 2, 4096, 2, 4)),           # no heavy job under 6 GB
                           ("medium", (3, 1, 7, 8192, 7, 8)),
                           ("high", (4, 1, 10, 12288, 10, 8)),        # VM: at most half the machine
                           ("cpu=75 ram=4", (2, 0, 7, 4096, 7, 4)),   # 3 slots by CPU, 2 by RAM
                           ("ram=2", (1, 0, 10, 2048, 10, 2)),
                           ("cpu=10", (1, 1, 1, None, 1, 2)),
                           ("ram=8", (4, 1, 10, 8192, 10, 8))):
            self.assertEqual(self.caps(text, 4, 1, 10, 16), want, text)
        self.assertEqual(self.caps("high", 4, None, 10, 16)[1], None)       # no heavy_slots in the header

    def guard(self, need_mb=2048, os_="darwin", **sysctl):
        env = {"RR_SYSCTL_" + k: str(v) for k, v in sysctl.items()}
        return self.pl('print encode_json([share_guard("%s", %d), share_floor_mb(16384)]);' % (os_, need_mb),
                       **env)[0]

    def test_memory_guard_takes_a_job_only_while_pressure_is_normal_and_free_memory_stays_over_the_floor(self):
        mem16 = dict(hw_memsize=16 * GB)
        self.assertEqual(self.guard(kern_memorystatus_vm_pressure_level=1, kern_memorystatus_level=60, **mem16), "")
        for lvl in (2, 4):                                                   # warn / critical
            self.assertEqual(self.guard(kern_memorystatus_vm_pressure_level=lvl, kern_memorystatus_level=90,
                                        **mem16), "pressure")
        # 16 GB: floor 3.2 GB; 30 % free = 4.9 GB - a 2 GB job < floor; a 1 GB job still fits
        self.assertEqual(self.guard(kern_memorystatus_vm_pressure_level=1, kern_memorystatus_level=30, **mem16),
                         "memory")
        self.assertEqual(self.guard(1024, kern_memorystatus_vm_pressure_level=1, kern_memorystatus_level=30,
                                    **mem16), "")
        # 64 GB: the floor stops at 4 GB
        big = dict(hw_memsize=64 * GB, kern_memorystatus_vm_pressure_level=1)
        self.assertEqual(self.guard(kern_memorystatus_level=10, **big), "")     # 6.4 GB - 2 >= 4
        self.assertEqual(self.guard(kern_memorystatus_level=9, **big), "memory")
        # a reading that cannot be had does not block; Linux never
        self.assertEqual(self.guard(kern_memorystatus_vm_pressure_level="", kern_memorystatus_level="", **mem16), "")
        self.assertEqual(self.guard(os_="linux", kern_memorystatus_vm_pressure_level=4, **mem16), "")
        self.assertEqual(self.pl('print encode_json([share_floor_mb(16384), share_floor_mb(65536), share_floor_mb(8192)]);'),
                         [3276, 4096, 1638])

    def test_used_memory_is_this_users_processes(self):
        self.assertEqual(self.pl('print encode_json([share_used_mb()]);', RR_USED_MB="1234"), [1234])
        e = rdmods.child_env(self.d)
        del e["RR_USED_MB"]
        prog = "use strict; use warnings; use JSON::PP; use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK);\n" \
               + self.block + 'print encode_json([share_used_mb()]);'
        r = subprocess.run(["/usr/bin/perl", "-e", prog], capture_output=True, text=True, env=e, timeout=30)
        used = json.loads(r.stdout)[0]
        self.assertIsInstance(used, int)
        self.assertGreater(used, 0)                                    # at least this perl itself


class ShareScript(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp(prefix="share-", dir=rdmods.TEST_HOME)
        self.addCleanup(shutil.rmtree, self.d, True)
        self.file = os.path.join(self.d, "Shared", "rdocker", "share")
        self.slots = os.path.join(self.d, "slots")
        # a 10-core 16 GB Mac (the Air), whatever runs the suite
        self.env = rdmods.child_env(self.d, RR_SHARE_FILE=self.file, RR_SLOTS_DIR=self.slots, RR_OS="darwin",
                                    RR_SYSCTL_hw_logicalcpu="10", RR_SYSCTL_hw_memsize=str(16 * GB))

    def share(self, *args, cmd=SHARE, **env):
        return subprocess.run(["/bin/sh", cmd] + list(args), capture_output=True, text=True,
                              env=dict(self.env, **env), timeout=30)

    def info(self, **env):
        return dict(ln.split("=", 1) for ln in self.share("info", **env).stdout.splitlines())

    def content(self):
        with open(self.file) as f:
            return f.read()

    def probe(self):
        root = os.path.join(self.d, "rr")
        os.makedirs(root, exist_ok=True)
        env = dict(self.env, RR_ROOT=root, RR_OS="linux", RR_PROC=os.path.join(self.d, "noproc"))
        p = subprocess.run(["/usr/bin/perl", "-e", rd_pool.PROBE], input="{}", env=env,
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(p.returncode, 0, p.stderr)
        return json.loads(p.stdout)

    def test_presets_are_written_atomically_and_read_back_by_the_worker(self):
        r = self.share("status")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Sharing is MAX", r.stdout)                      # no file = everything
        self.assertNotIn("Jobs running", r.stdout)                     # slots unreadable: level only
        for word, level, line in (("off", "off", "Sharing is OFF"),
                                  ("low", "low", "Sharing is LOW: jobs may use 25 % of the cores (2 of 10) and up to 4 GB"),
                                  ("medium", "medium", "Sharing is MEDIUM: jobs may use 75 % of the cores (7 of 10) and up to 8 GB"),
                                  ("high", "high", "Sharing is HIGH: jobs may use 100 % of the cores (10 of 10) and up to 12 GB"),
                                  ("some", "medium", "Sharing is MEDIUM"), ("max", "high", "Sharing is HIGH")):
            r = self.share(word)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(line, r.stdout)
            self.assertEqual(self.content(), word + "\n")              # the word as typed: old runners read some/max
            self.assertEqual(os.stat(self.file).st_mode & 0o777, 0o644)    # the rd user must read it
            self.assertEqual(self.share("level").stdout, level + "\n")
            self.assertEqual(self.probe()["share"], level)
        self.assertEqual(os.stat(os.path.dirname(self.file)).st_mode & 0o777, 0o755)
        self.assertEqual([n for n in os.listdir(os.path.dirname(self.file)) if n != "share"], [])  # no temp left
        self.assertEqual(self.share("bogus").returncode, 2)
        with open(self.file, "w") as f:
            f.write("whatever\n")
        self.assertIn("Sharing is OFF", self.share("status").stdout)  # same rule as the worker
        self.assertEqual(self.probe()["share"], "off")

    def test_custom_cpu_and_ram_are_picked_independently(self):
        self.share("off")
        r = self.share("cpu", "75")                                    # from off: medium's RAM cap
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.content(), "cpu=75 ram=8\n")
        self.assertIn("Sharing is CUSTOM: jobs may use 75 % of the cores (7 of 10) and up to 8 GB", r.stdout)
        self.share("ram", "4")                                         # keeps the CPU share
        self.assertEqual(self.content(), "cpu=75 ram=4\n")
        self.share("cpu", "25")                                        # keeps the RAM cap
        self.assertEqual(self.content(), "cpu=25 ram=4\n")
        self.share("high")
        self.share("ram", "6")                                         # from a preset: its CPU share
        self.assertEqual(self.content(), "cpu=100 ram=6\n")
        o = self.probe()
        self.assertEqual((o["share"], o["share_cpu"], o["ram_cap_mb"]), ("custom", 100, 6144))
        for bad in (("cpu", "5"), ("cpu", "101"), ("ram", "0"), ("ram", "300"), ("cpu", "x"), ("ram",)):
            r = self.share(*bad)
            self.assertEqual(r.returncode, 2, bad)
            self.assertEqual(self.content(), "cpu=100 ram=6\n", bad)  # nothing written
        i = self.info()
        self.assertEqual((i["level"], i["cpu"], i["ram_gb"], i["cores"], i["ncpu"], i["mem_gb"]),
                         ("custom", "100", "6", "10", "10", "16"))
        self.assertEqual((i["p_low"], i["p_medium"], i["p_high"]), ("25 4", "75 8", "100 12"))

    def test_stop_turns_off_and_asks_the_root_daemon_to_stop_the_jobs(self):
        self.share("medium")
        r = self.share("stop")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.content(), "off\n")
        req = os.path.join(os.path.dirname(self.file), "stop-jobs")
        self.assertTrue(os.path.isfile(req) and not os.path.islink(req))
        self.assertIn("being stopped", r.stdout)

    def test_status_counts_jobs_from_the_daemon_status_or_readable_slots_and_shows_the_guard(self):
        os.makedirs(self.slots)
        with open(os.path.join(self.slots, "0.who"), "w") as f:
            f.write("app.1234 1700000000 %d 0123456789ab\n" % os.getpid())   # alive
        with open(os.path.join(self.slots, "1.who"), "w") as f:
            f.write("app.1234 1700000000 999999 0123456789ab\n")              # gone
        self.share("medium")
        self.assertIn("Jobs running now: 1", self.share("status").stdout)
        self.assertIn("1 job(s) still running will finish.", self.share("off").stdout)
        # rd-worker-mac's status file wins while fresh (the owner cannot read rd's slots)
        st = os.path.join(os.path.dirname(self.file), "status")
        with open(st, "w") as f:
            f.write("jobs=3\nts=%d\n" % time.time())
        self.assertEqual(self.info()["jobs"], "3")
        with open(st, "w") as f:
            f.write("jobs=3\nts=%d\n" % (time.time() - 600))                    # stale: not trusted
        self.assertEqual(self.info()["jobs"], "1")
        self.share("medium")
        self.assertEqual(self.info()["guard"], "")
        r = self.share("status", RR_SYSCTL_kern_memorystatus_vm_pressure_level="4")
        self.assertIn("Paused for memory: macOS memory pressure is up", r.stdout)
        self.assertEqual(self.info(RR_SYSCTL_kern_memorystatus_level="20")["guard"], "memory")
        self.share("off")
        self.assertEqual(self.info(RR_SYSCTL_kern_memorystatus_vm_pressure_level="4")["guard"], "")  # off: no pause

    # ---- the menu bar
    def plugin(self, **env):
        bindir = os.path.join(self.d, "plugin")
        if not os.path.isdir(bindir):
            os.makedirs(bindir)
            shutil.copy(PLUGIN, os.path.join(bindir, "rdocker-share.1m.sh"))
            shutil.copy(SHARE, os.path.join(bindir, "rdocker-share.sh"))
            os.chmod(os.path.join(bindir, "rdocker-share.sh"), 0o755)
        return self.share(cmd=os.path.join(bindir, "rdocker-share.1m.sh"), **env).stdout.splitlines()

    def test_menu_without_the_switch_never_guesses(self):
        bindir = os.path.join(self.d, "lonely")
        os.makedirs(bindir)
        shutil.copy(PLUGIN, os.path.join(bindir, "rdocker-share.1m.sh"))
        out = self.share(cmd=os.path.join(bindir, "rdocker-share.1m.sh"), RDOCKER_SHARE_CMD="",
                         RDOCKER_SHARE_PATHS=os.path.join(bindir, "none")).stdout
        self.assertIn("rdocker-share not installed", out)

    def test_menu_title_presets_limits_and_stop(self):
        self.share("cpu", "75")
        self.share("ram", "4")
        out = self.plugin()
        self.assertEqual(out[0], "⚙ 75% · 4G | color=#36D399")
        self.assertIn("Sharing: Custom - 7 of 10 cores (75 %), up to 4 GB | color=#36D399", out)
        cmd = r'bash="[^"]+rdocker-share\.sh"'
        presets = [l for l in out if l.startswith(("Off - ", "Low - ", "Medium - ", "High - "))]
        self.assertEqual([p.split(" |")[0] for p in presets],
                         ["Off - no new jobs (running ones finish)", "Low - 2 cores, up to 4 GB",
                          "Medium - 7 cores, up to 8 GB", "High - all 10 cores, up to 12 GB"])
        for p, word in zip(presets, ("off", "low", "medium", "high")):
            self.assertRegex(p, r" \| %s param1=%s terminal=false refresh=true$" % (cmd, word))   # one click
        self.assertFalse(any("checked=true" in p for p in presets))    # custom: no preset ticked
        self.assertIn("CPU: 75 % (7 cores)", out)                     # submenu titles show what is in force
        self.assertIn("RAM: up to 4 GB", out)
        cpu = [l for l in out if l.startswith("--") and "param1=cpu" in l]
        ram = [l for l in out if l.startswith("--") and "param1=ram" in l]
        self.assertEqual([l.split(" |")[0] for l in cpu], ["--25 % (2 cores)", "--50 % (5 cores)",
                                                           "--75 % (7 cores)", "--100 % (10 cores)"])
        self.assertEqual([l.split(" |")[0] for l in ram], ["--up to 2 GB", "--up to 4 GB", "--up to 6 GB",
                                                           "--up to 8 GB", "--up to 12 GB"])   # 16 GB Mac: <= 14
        self.assertRegex(cpu[2], r"param1=cpu param2=75 terminal=false refresh=true checked=true$")
        self.assertRegex(ram[1], r"param1=ram param2=4 terminal=false refresh=true checked=true$")
        self.assertEqual(sum("checked=true" in l for l in cpu + ram), 2)
        stop = [l for l in out if l.startswith("Stop the jobs running here now |")]
        self.assertEqual(len(stop), 1)
        self.assertRegex(stop[0], r"param1=stop terminal=false refresh=true$")
        # a click on an item = the command it names: the file follows
        self.share("cpu", "50")
        self.assertEqual(self.plugin()[0], "⚙ 50% · 4G | color=#36D399")

    def test_menu_preset_ticks_its_own_values(self):
        self.share("high")
        out = self.plugin()
        self.assertTrue(any(l.startswith("High - ") and l.endswith("checked=true") for l in out))
        self.assertIn("CPU: 100 % (10 cores)", out)
        self.assertIn("RAM: up to 12 GB", out)
        ticked = [l.split(" |")[0] for l in out if l.startswith("--") and "checked=true" in l]
        self.assertEqual(ticked, ["--100 % (10 cores)", "--up to 12 GB"])   # never a contradiction

    def test_menu_shows_jobs_paused_and_off(self):
        self.share("medium")
        st = os.path.join(os.path.dirname(self.file), "status")
        with open(st, "w") as f:
            f.write("jobs=2\nts=%d\n" % time.time())
        out = self.plugin()
        self.assertEqual(out[0], "⚙ 75% · 8G · 2▶ | color=#36D399")
        self.assertIn("Team jobs running here now: 2 | color=gray", out)
        self.assertTrue(any(l.startswith("Medium - ") and l.endswith("checked=true") for l in out))
        out = self.plugin(RR_SYSCTL_kern_memorystatus_vm_pressure_level="2")
        self.assertEqual(out[0], "⚙ 75% · 8G · 2▶ ⏸ | color=#F5A623")
        self.assertTrue(any(l.startswith("Paused for memory: macOS memory pressure is up") for l in out))
        self.share("off")
        out = self.plugin()
        self.assertEqual(out[0], "⚙ off · 2▶ | color=#8a8a8a")
        self.assertIn("Sharing is OFF: no new jobs start here | color=gray", out)
        self.assertFalse(any(l.startswith("--") and "checked=true" in l for l in out))   # nothing ticked when off
        self.assertIn("CPU: -", out)
        self.assertIn("RAM: -", out)


if __name__ == "__main__":
    unittest.main()
