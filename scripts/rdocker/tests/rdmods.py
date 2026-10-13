"""Test access to the split rdocker modules (rd_common, rd_args, ... - see rdocker.py).

`r.X` reads X from the one module that defines it. Assigning through `r` raises: every module
reads its peers' names as `rd_common.X` at call time, so a patch only takes effect when it is set
on the defining module - use `owner("X")` (or the module itself) as the patch target.
"""
import atexit
import importlib
import os
import shutil
import sys
import tempfile
import types

# ---------------------------------------------------------------------------- hermetic test home
# Set BEFORE any rd_* import: rd_common computes every path from RDOCKER_HOME at import, so the
# whole suite (and every child it spawns, which inherits os.environ or uses child_env()) writes
# into a throwaway home, never the real ~/.config/rdocker or ~/.local/state/rdocker. A child that
# imports rdmods again reuses the parent's home (recognised by MARKER) instead of making its own.
# Guarded by tests/test_zz_hermetic.py.
MARKER = ".rdocker-test-home"
# Real binaries no test may reach: the ssh master / the mini, launchd, AppleScript, `open -a`,
# Tailscale, and any real docker (~/.local/bin/docker is the LIVE shim -> the mini).
GUARDED = ("ssh", "osascript", "launchctl", "open", "colima", "tailscale", "Tailscale", "docker")
STUB_EXIT = 97


def _test_home():
    h = os.environ.get("RDOCKER_HOME")
    if h and os.path.isfile(os.path.join(h, MARKER)):
        return h, False
    h = tempfile.mkdtemp(prefix="rdk-home-", dir="/tmp")   # short: unix socket paths cap at 104
    open(os.path.join(h, MARKER), "w").close()
    return h, True


TEST_HOME, _OWNED = _test_home()
STUB_BIN = os.path.join(TEST_HOME, "stub-bin")
STUB_LOG = os.path.join(TEST_HOME, "stub-calls.log")
if _OWNED:
    os.makedirs(STUB_BIN)
    for _name in GUARDED:
        _p = os.path.join(STUB_BIN, _name)
        with open(_p, "w") as _f:
            _f.write('#!/bin/sh\necho "$0 $*" >> "%s"\n'
                     'echo "rdocker tests: real $(basename "$0") is blocked" >&2\nexit %d\n'
                     % (STUB_LOG, STUB_EXIT))
        os.chmod(_p, 0o755)
    atexit.register(shutil.rmtree, TEST_HOME, True)
os.environ["RDOCKER_HOME"] = TEST_HOME
if not os.environ.get("PATH", "").startswith(STUB_BIN + ":"):
    os.environ["PATH"] = STUB_BIN + ":" + os.environ.get("PATH", "")


def safe_path(*dirs):
    """PATH for a child: the test's own stub dirs first, then the fail-closed GUARDED stubs, then
    the system dirs - so an unstubbed ssh/launchctl/osascript/docker can never fall through."""
    return ":".join(list(dirs) + [STUB_BIN, "/usr/bin", "/bin"])


def child_env(home, *bins, **extra):
    """Environment for a spawned rdocker under its own temp `home` (HOME and RDOCKER_HOME both
    point there). Drops caller RDOCKER_*/DOCKER_HOST/DOCKER_CONTEXT; PATH = safe_path(*bins)."""
    e = {k: v for k, v in os.environ.items()
         if not k.startswith("RDOCKER_") and k not in ("DOCKER_HOST", "DOCKER_CONTEXT")}
    open(os.path.join(home, MARKER), "a").close()   # a child that imports rdmods keeps `home`
    e.update(HOME=home, RDOCKER_HOME=home, PATH=safe_path(*bins))
    e.update(extra)
    return e


STAGE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, STAGE)
NAMES = ("rd_common", "rd_args", "rd_tunnel", "rd_route", "rd_janitor", "rd_daemon", "rd_setup")
MODULES = [importlib.import_module(n) for n in NAMES]
# Tailscale is invoked by absolute path, not via PATH: point it at the stub too.
vars(MODULES[NAMES.index("rd_daemon")])["TS_CLI"] = os.path.join(STUB_BIN, "Tailscale")


def owner(name):
    """The module that defines `name` (stdlib modules they import resolve to the first importer)."""
    found = [m for m in MODULES if name in vars(m)]
    if not found:
        raise AttributeError("no rdocker module defines %r" % name)
    if len(found) > 1 and not isinstance(vars(found[0])[name], types.ModuleType):
        raise AttributeError("%r is bound in %s; expected one owner" % (name, [m.__name__ for m in found]))
    return found[0]


class _Reader:
    def __getattr__(self, name):
        return getattr(owner(name), name)

    def __setattr__(self, name, value):
        raise AttributeError("patch %s.%s, not r.%s" % (owner(name).__name__, name, name))


r = _Reader()
