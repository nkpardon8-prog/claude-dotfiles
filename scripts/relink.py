#!/usr/bin/env python3
"""relink - reconnect Remote Control in every /line-named Claude window on THIS Mac, under its /line name.

Why: the Claude app shows a Remote Control session under the name it was connected with. /rename does
not reach it, and `/rc NAME` while already connected is a no-op. A disconnect (`/remote-control` while
connected) followed by `/rc NAME` makes a fresh RC session with the right name (proven 2026-11-11).

How: reads ~/.claude/sessions/<pid>.json for each live window (name, nameSource, status, bridgeSessionId),
finds where it runs - a Pane panel (PANE_PANEL_ID in its environment; typed via `runpane panels input`,
which also works over ssh) or a Terminal.app tab (by TTY; typed via AppleScript) - and types the commands ONLY while the window is idle (never mid-task, never
over a permission prompt). Each step is confirmed by watching bridgeSessionId in the session file.
Windows without a /line name (nameSource != "explicit"), or in neither Pane nor Terminal, are skipped and listed.
Another Mac: `ssh <host> python3 ~/.claude-dotfiles/scripts/relink.py` (Pane windows only; macOS blocks
AppleScript control of Terminal from an ssh login).

Self-heal: `relink.py --heal` is a Stop hook (installed on every Mac by line-ensure-settings.py). When a
window finishes a turn it checks itself in milliseconds; if it is /line-named but not linked under that
name (new window, /line rename, /resume, Pane restore, account switch), it starts a detached relink of
itself, which types once the window is idle. Retries at most every HEAL_BACKOFF seconds per window.

Usage: relink.py [--dry-run] [--only NAME ...] [--timeout-min N] [--force] | --heal (hook, JSON on stdin)
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

STATE = Path(os.environ.get("RELINK_STATE", Path.home() / ".claude" / "relink-state.json"))
SESS = Path(os.environ.get("RELINK_SESSIONS_DIR", Path.home() / ".claude" / "sessions"))
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
POLL = 3.0
HEAL_BACKOFF = 300
HEAL_LOG = Path.home() / ".claude" / "logs" / "relink-heal.log"
STEP_TIMEOUT = 90.0


def read_sessions():
    rows = []
    for f in sorted(SESS.glob("*.json")):
        try:
            d = json.loads(f.read_text())
            pid = int(d["pid"])
        except Exception:
            continue
        if d.get("kind") not in (None, "interactive"):
            continue
        try:
            os.kill(pid, 0)
        except (ProcessLookupError, PermissionError):
            continue
        rows.append(d)
    return rows


def load_state():
    """{sessionId: {"name", "bridge"}} for windows this script already linked. Never raises."""
    try:
        d = json.loads(STATE.read_text())
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_linked(sid, name, bridge):
    st = load_state()
    st[sid] = {"name": name, "bridge": bridge, "at": int(time.time())}
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, indent=1))
    os.replace(tmp, STATE)


def session(pid):
    try:
        return json.loads((SESS / f"{pid}.json").read_text())
    except Exception:
        return {}


def tty_of(pid):
    p = subprocess.run(["ps", "-o", "tty=", "-p", str(pid)], capture_output=True, text=True)
    t = p.stdout.strip()
    return f"/dev/{t}" if t and t not in ("?", "??") else ""


def pane_panel(pid):
    """The Pane panel a window runs in, from its process environment, or ""."""
    p = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True)
    m = re.search(r"(?:^|\s)PANE_PANEL_ID=([0-9a-f-]{8,})", p.stdout)
    return m.group(1) if m else ""


def runpane_bin():
    for c in (os.environ.get("PANE_RUNPANE_BIN"), "/opt/homebrew/bin/runpane", "/usr/local/bin/runpane",
              str(Path.home() / ".pane" / "bin" / "runpane")):
        if c and os.access(c, os.X_OK):
            return c
    return ""


def terminal_ttys():
    """TTYs of Terminal.app tabs, or None when Terminal cannot be scripted (not running, Automation
    permission pending, or an ssh login). Never raises."""
    ps = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True).stdout
    if "/Terminal.app/Contents/MacOS/Terminal" not in ps:   # never let osascript LAUNCH Terminal
        return None
    script = 'tell application "Terminal" to get tty of every tab of every window'
    try:
        p = subprocess.run(["/usr/bin/osascript", "-e", script], capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        return None
    if p.returncode != 0:
        return None
    return {t.strip() for t in p.stdout.replace("\n", ",").split(",") if t.strip()}


TYPE_SCRIPT = '''on run argv
  set targetTTY to item 1 of argv
  set txt to item 2 of argv
  tell application "Terminal"
    repeat with w in windows
      repeat with t in tabs of w
        try
          if (tty of t) is targetTTY then
            do script txt in t
            return "typed"
          end if
        end try
      end repeat
    end repeat
  end tell
  return "no-tab"
end run'''


def type_into(w, text):
    if w["panel"]:
        rp = runpane_bin()
        try:
            a = subprocess.run([rp, "panels", "input", "--panel", w["panel"], "--text", text, "--yes"],
                               capture_output=True, text=True, timeout=20)
            time.sleep(0.5)
            b = subprocess.run([rp, "panels", "input", "--panel", w["panel"], "--keys", "enter", "--yes"],
                               capture_output=True, text=True, timeout=20)
        except (subprocess.TimeoutExpired, OSError):
            return False
        return a.returncode == 0 and b.returncode == 0
    tty = w["tty"]
    try:
        p = subprocess.run(["/usr/bin/osascript", "-", tty, text], input=TYPE_SCRIPT,
                       capture_output=True, text=True, timeout=20)
    except subprocess.TimeoutExpired:
        return False
    return p.stdout.strip() == "typed"


def plan(rows, tabs, only, force=False):
    todo, skipped = [], []
    linked = {} if force else load_state()
    for d in rows:
        name = d.get("name") or ""
        if only and name not in only:
            continue
        if d.get("nameSource") != "explicit":
            skipped.append((name or f"pid {d['pid']}", "no /line name"))
            continue
        if not NAME_RE.match(name):
            skipped.append((name, "name has characters /rc cannot take"))
            continue
        prev = linked.get(d.get("sessionId") or "")
        if prev and prev.get("name") == name and d.get("bridgeSessionId") and prev.get("bridge") == d.get("bridgeSessionId"):
            skipped.append((name, "already linked under this name"))
            continue
        panel = pane_panel(d["pid"]) if runpane_bin() else ""
        tty = "" if panel else tty_of(d["pid"])
        if not panel and (tabs is None or tty not in tabs):
            why = "not a Pane panel or Terminal tab" if tabs is not None else \
                "not a Pane panel, and Terminal cannot be scripted from here"
            skipped.append((name, why))
            continue
        todo.append({"sid": d.get("sessionId") or "", "pid": d["pid"], "name": name, "tty": tty, "panel": panel, "state": "start", "t": 0.0,
                     "old": d.get("bridgeSessionId"), "result": ""})
    return todo, skipped


def idle(d):
    return d.get("status") == "idle"


def step(w, now):
    d = session(w["pid"])
    if not d:
        w["state"], w["result"] = "done", "FAILED: window closed"
        return
    bridge = d.get("bridgeSessionId")
    if w["state"] == "start":
        if not idle(d):
            return
        if bridge:
            if type_into(w, "/remote-control"):
                w["state"], w["t"], w["old"] = "disconnecting", now, bridge
            else:
                w["state"], w["result"] = "done", "FAILED: could not type into its tab"
        else:
            if type_into(w, "/rc " + w["name"]):
                w["state"], w["t"] = "connecting", now
            else:
                w["state"], w["result"] = "done", "FAILED: could not type into its tab"
    elif w["state"] == "disconnecting":
        if not bridge and idle(d):
            if type_into(w, "/rc " + w["name"]):
                w["state"], w["t"] = "connecting", now
            else:
                w["state"], w["result"] = "done", "FAILED: could not type the reconnect"
        elif now - w["t"] > STEP_TIMEOUT:
            w["state"], w["result"] = "done", "FAILED: did not disconnect (check the tab)"
    elif w["state"] == "connecting":
        if bridge and bridge != w["old"]:
            w["state"], w["result"] = "done", f"relinked ({bridge})"
            if w["sid"]:
                save_linked(w["sid"], w["name"], bridge)
        elif now - w["t"] > STEP_TIMEOUT:
            w["state"], w["result"] = "done", "FAILED: no new Remote Control session (check the tab)"


def heal():
    """Stop-hook entry. Must be fast and must never fail the hook: always exits 0."""
    try:
        sid = str(json.loads(sys.stdin.read() or "{}").get("session_id") or "")
        if not sid or os.environ.get("RELINK_CHILD"):
            return 0
        me = next((d for d in read_sessions() if d.get("sessionId") == sid), None)
        if not me or me.get("nameSource") != "explicit" or not NAME_RE.match(me.get("name") or ""):
            return 0
        st = load_state()
        prev = st.get(sid) or {}
        bridge = me.get("bridgeSessionId")
        if bridge and prev.get("name") == me["name"] and prev.get("bridge") == bridge:
            return 0
        if time.time() - float(prev.get("tried") or 0) < HEAL_BACKOFF:
            return 0
        prev = dict(prev, tried=int(time.time()))
        st[sid] = prev
        tmp = STATE.with_suffix(".tmp")
        tmp.write_text(json.dumps(st, indent=1))
        os.replace(tmp, STATE)
        HEAL_LOG.parent.mkdir(parents=True, exist_ok=True)
        log = open(HEAL_LOG, "a")
        log.write(time.strftime("%Y-%m-%d %H:%M:%S ") + f"heal {me['name']} pid {me['pid']}\n")
        log.flush()
        subprocess.Popen([sys.executable, os.path.abspath(__file__), "--only", me["name"], "--timeout-min", "10"],
                         stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
                         env=dict(os.environ, RELINK_CHILD="1"))
    except Exception:
        pass
    return 0


def main():
    if "--heal" in sys.argv[1:]:
        return heal()
    ap = argparse.ArgumentParser(description="Reconnect Remote Control under each window's /line name.")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--force", action="store_true", help="relink even windows already linked under their name")
    ap.add_argument("--timeout-min", type=float, default=45.0, help="how long to wait for busy windows")
    a = ap.parse_args()
    tabs = terminal_ttys()
    todo, skipped = plan(read_sessions(), tabs, set(a.only), a.force)
    host = subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True).stdout.strip()
    if a.dry_run:
        for w in todo:
            act = "disconnect, then /rc " if w["old"] else "/rc "
            via = "Pane" if w["panel"] else "Terminal"
            print(f"{host} | {w['name']} | {act}{w['name']} via {via} (when idle)")
        for n, why in skipped:
            print(f"{host} | {n} | skip: {why}")
        return 0
    lock = STATE.with_name("relink.lock")
    try:
        other = int(lock.read_text().strip() or 0)
        os.kill(other, 0)
        print(f"relink: another relink is already running (pid {other}); it will finish these windows.")
        return 0
    except (FileNotFoundError, ValueError, ProcessLookupError):
        pass
    except PermissionError:
        return 0
    lock.write_text(str(os.getpid()))
    try:
        return run(todo, skipped, host, a)
    finally:
        try:
            if lock.read_text().strip() == str(os.getpid()):
                lock.unlink()
        except Exception:
            pass


def run(todo, skipped, host, a):
    deadline = time.time() + a.timeout_min * 60
    while any(w["state"] != "done" for w in todo) and time.time() < deadline:
        for w in todo:
            if w["state"] != "done":
                step(w, time.time())
        time.sleep(POLL)
    for w in todo:
        if w["state"] != "done":
            w["result"] = "NOT DONE: stayed busy past the timeout" if w["state"] == "start" else \
                f"NOT DONE: stuck at {w['state']}"
    print(f"relink on {host}")
    for w in todo:
        print(f"  {w['name']:<40} {w['result']}")
    for n, why in skipped:
        print(f"  {n:<40} skipped: {why}")
    if not todo:
        print("  nothing to relink")
    return 0 if all(w["result"].startswith("relinked") for w in todo) else 1


if __name__ == "__main__":
    sys.exit(main())
