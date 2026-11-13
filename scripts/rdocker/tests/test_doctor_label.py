"""rd-doctor must recognise a LIVE run's containers (2026-11-13).

Found live: the doctor's orphan-container rule removed run containers at ~130 s (hp's doctor.log, all night;
the DAVID lane's Postgres mid-suite on the laptop worker). Its two liveness signals were both dead: the
runner never wrote `label=` into slots/<i>.own, and the shim fallback regex expected `LABEL='...'` while
the runner writes `my $LABEL = '...';`. The old test fixture used the regex's own format, so nothing failed.
These tests tie the doctor to what the runner REALLY writes, so the two cannot drift silently again.
"""
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rdmods  # noqa: E402
import test_doctor as td  # noqa: E402
import test_runner as tr  # noqa: E402

RUNNER_SRC = os.path.join(rdmods.STAGE, "rr_runner.pl")


def shim_label_line(token):
    """The LABEL line of the docker shim exactly as rr_runner.pl's write_shim generates it."""
    with open(RUNNER_SRC) as f:
        src = f.read()
    m = re.search(r"^my \$LABEL = '@LABEL@';$", src, re.M)
    assert m, "rr_runner.pl's shim template changed: update rd-doctor's CT_PL regex and this test"
    return m.group(0).replace("@LABEL@", "rdocker.rrun=" + token) + "\n"


class DoctorSeesTheRealShim(td.OrphanContainers):
    """Only the new test runs here (the inherited ones are skipped: test_doctor runs them)."""

    def run(self, result=None):
        if self._testMethodName != "test_a_live_runs_real_shim_keeps_its_container":
            return None
        return super().run(result)

    def test_a_live_runs_real_shim_keeps_its_container(self):
        live, dead = "5" * 32, "6" * 32
        lock = self.who(0, os.getpid())
        self.hold(lock)
        td.write(os.path.join(self.rr, "tmp", "run-live0000", "docker"), shim_label_line(live))
        with open(self.fix, "w") as f:
            f.write(self.ct("a", 600, "rdocker.rrun=%s" % live))     # live: its shim is the runner's own text
            f.write(self.ct("b", 600, "rdocker.rrun=%s" % dead))     # nobody's
        self.doctor(RD_DOCKER=self.docker)
        self.assertEqual(self.removed().strip(), "rm -f -v " + "b" * 64)


class RunnerNamesItsLabel(unittest.TestCase):
    """The runner's slots/<i>.own carries label=<its container label> while the command runs (the
    doctor's primary liveness signal)."""
    run_runner, env, git, calls, header = (tr.RunnerTest.run_runner, tr.RunnerTest.env, tr.RunnerTest.git,
                                           tr.RunnerTest.calls, tr.RunnerTest.header)

    def setUp(self):
        tr.RunnerTest.setUp(self)
        self.addCleanup(__import__("shutil").rmtree, self.d, True)

    def tearDown(self):
        pass

    def test_own_has_the_label(self):
        r = self.run_runner(["/bin/sh", "-c", 'cat "%s"/slots/*.own; echo; echo "L=$RRUN_DOCKER_LABEL"' % self.root])
        self.assertEqual(r.rc, 0, r.err)
        own = dict(kv.split("=", 1) for kv in r.out.splitlines()[0].split("\t"))
        label = r.out.split("L=rdocker.rrun=")[1].strip()
        self.assertRegex(label, r"^[0-9a-f]{32}$")
        self.assertEqual(own["label"], label)
        self.assertTrue(r.out.splitlines()[0].split("\t")[-1].startswith("cmd="))   # cmd stays last


if __name__ == "__main__":
    unittest.main()
