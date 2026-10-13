"""Test access to the split rdocker modules (rd_common, rd_args, ... - see rdocker.py).

`r.X` reads X from the one module that defines it. Assigning through `r` raises: every module
reads its peers' names as `rd_common.X` at call time, so a patch only takes effect when it is set
on the defining module - use `owner("X")` (or the module itself) as the patch target.
"""
import importlib
import os
import sys
import types

STAGE = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
sys.path.insert(0, STAGE)
NAMES = ("rd_common", "rd_args", "rd_tunnel", "rd_route", "rd_janitor", "rd_daemon", "rd_setup")
MODULES = [importlib.import_module(n) for n in NAMES]


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
