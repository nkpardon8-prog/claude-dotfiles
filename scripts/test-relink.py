#!/usr/bin/env python3
"""Tests for relink.py's "already linked" decision (no typing, no subprocesses: Popen is stubbed).

Run: python3 ~/.claude-dotfiles/scripts/test-relink.py
"""
import importlib.util
import io
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
fails = 0


def check(label, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + label)
    fails += 0 if cond else 1


def load(home, acct_uuid):
    (home / ".claude").mkdir(parents=True, exist_ok=True)
    (home / ".claude.json").write_text(json.dumps({"oauthAccount": {"accountUuid": acct_uuid}}))
    os.environ["HOME"] = str(home)
    os.environ["RELINK_STATE"] = str(home / ".claude" / "relink-state.json")
    os.environ["RELINK_SESSIONS_DIR"] = str(home / ".claude" / "sessions")
    os.environ.pop("RELINK_CHILD", None)
    spec = importlib.util.spec_from_file_location("relink_under_test", HERE / "relink.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    m.Path.home = staticmethod(lambda: home)
    m.HEAL_LOG = home / "heal.log"
    return m


def run_heal(m, sid):
    spawned = []
    m.subprocess.Popen = lambda *a, **k: spawned.append(a)
    sys.stdin = io.StringIO(json.dumps({"session_id": sid}))
    m.heal()
    return bool(spawned)


with tempfile.TemporaryDirectory() as t:
    home = Path(t)
    m = load(home, "acct-B")
    sess = home / ".claude" / "sessions"
    sess.mkdir(parents=True)
    pid = os.getpid()
    (sess / f"{pid}.json").write_text(json.dumps({"pid": pid, "sessionId": "S1", "name": "billing-tab",
                                                  "status": "busy", "bridgeSessionId": "session_old"}))
    fp_b = m.account_fp()
    fp_a = "a" * 16

    def state(acct):
        Path(os.environ["RELINK_STATE"]).write_text(json.dumps(
            {"S1": {"name": "billing-tab", "bridge": "session_old", "acct": acct, "at": 1}}))

    # linked_ok
    check("same name+bridge+account -> linked",
          m.linked_ok({"name": "x", "bridge": "b", "acct": fp_b}, "x", "b"))
    check("same name+bridge, other account -> NOT linked",
          not m.linked_ok({"name": "x", "bridge": "b", "acct": fp_a}, "x", "b"))
    check("no stored account (old entry) -> linked",
          m.linked_ok({"name": "x", "bridge": "b"}, "x", "b"))
    check("renamed -> NOT linked", not m.linked_ok({"name": "x", "bridge": "b", "acct": fp_b}, "y", "b"))
    check("no bridge -> NOT linked", not m.linked_ok({"name": "x", "bridge": "b", "acct": fp_b}, "x", None))

    # heal: the 2026-11-21 bug - account switched, bridge id unchanged in the session file
    state(fp_a)
    check("heal relinks a window still on the old account's bridge", run_heal(m, "S1"))
    state(fp_b)
    check("heal leaves a window linked under the current account alone", not run_heal(m, "S1"))

    # plan: same rule for the manual sweep
    state(fp_a)
    m.runpane_bin = lambda: ""
    m.tty_of = lambda p: "/dev/ttysTEST"
    todo, skipped = m.plan(m.read_sessions(), {"/dev/ttysTEST"}, set())
    check("plan queues the old-account window", [w["name"] for w in todo] == ["billing-tab"])
    check("plan carries the old account for the reset notice", todo and todo[0]["prev_acct"] == fp_a)
    state(fp_b)
    todo, skipped = m.plan(m.read_sessions(), {"/dev/ttysTEST"}, set())
    check("plan skips a current-account window", not todo and skipped[0][1] == "already linked under this name")

print(f"\n{'all passed' if not fails else f'{fails} FAILED'}")
sys.exit(1 if fails else 0)
