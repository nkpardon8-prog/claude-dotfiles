#!/usr/bin/env python3
"""
line-agent-communicator — one command names a window three ways at once.

Claude Code keeps two unrelated names for every window:

  1. the statusline caption   ~/.claude/session-status/<sessionId>.txt   (cosmetic; /line wrote this)
  2. the peer address         ~/.claude/sessions/<pid>.json .name        (what ListAgents shows and
                                                                          SendMessage resolves)

Because nothing joined them, a window you called "summit admin hub" was addressable only as
"dentall-ae", and no agent could make that leap. This script closes the gap: `set` writes BOTH,
deriving a short handle from your sentence, so the name you type IS the address other agents use.

`list` is the directory half — it enumerates every live window with its caption, its address, and
whether it can actually receive a message, so an agent can find a peer on its own.

On writing .name directly
-------------------------
Setting the peer address is not a documented API; the supported paths are `claude -n <name>` at
startup and `/rename` typed by a human. Neither can be driven by a slash command, so this writes the
registry file itself. That is safe in practice but unsupported in principle, so every write here is
defensive: we locate our own file by sessionId (never by pid guessing or mtime), preserve every
field we do not own, write atomically, and no-op rather than corrupt if the schema ever changes
shape. Verified on 2.1.227/2.1.228: the harness re-saves the file on each status change and
PRESERVES a name carrying nameSource="explicit" — that is the flag that marks a name as
human-chosen rather than auto-derived, and it is why this survives.

If a future version stops honouring it, `set` degrades to caption-only and says so; the caption and
the directory keep working, so discovery never silently breaks.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HOME = Path.home()
SESSIONS_DIR = HOME / ".claude" / "sessions"
STATUS_DIR = HOME / ".claude" / "session-status"
SOCK_DIR = Path("/tmp/cc-socks")

# Cross-session messaging landed in 2.1.224; older windows bind no socket and cannot receive.
MESSAGING_MIN_VERSION = (2, 1, 224)

HANDLE_MAX = 40


# --------------------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------------------

def safe_sid(raw: str) -> str:
    """Same sanitisation the statusline and /line already apply, so paths agree."""
    return re.sub(r"[^A-Za-z0-9_-]", "", raw or "")[:128]


def slugify(sentence: str) -> str:
    """
    Turn a human sentence into a short peer handle.

    "Internal > dentall > summit admin hub" -> "internal-dentall-summit-admin-hub"

    Handles are what a person types into SendMessage, so they stay lowercase and hyphenated.
    """
    s = (sentence or "").lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    s = re.sub(r"-{2,}", "-", s)
    if len(s) > HANDLE_MAX:
        # Trim on a word boundary so the handle stays pronounceable.
        s = s[:HANDLE_MAX].rsplit("-", 1)[0] or s[:HANDLE_MAX]
    return s.strip("-")


def parse_version(v: str) -> tuple:
    nums = re.findall(r"\d+", v or "")
    return tuple(int(n) for n in nums[:3]) or (0,)


def pid_alive(pid: int) -> bool:
    """Alive AND still a claude process — a recycled pid must not impersonate a dead window."""
    if not pid:
        return False
    try:
        out = subprocess.run(
            ["ps", "-p", str(pid), "-o", "comm="],
            capture_output=True, text=True, timeout=5,
        )
    except Exception:
        return False
    return "claude" in out.stdout.lower()


def load_sessions() -> list[dict]:
    """Every registry entry we can parse. Unreadable/foreign files are skipped, never fatal."""
    out = []
    if not SESSIONS_DIR.is_dir():
        return out
    for f in sorted(SESSIONS_DIR.glob("*.json")):
        try:
            d = json.loads(f.read_text())
        except Exception:
            continue
        if not isinstance(d, dict) or "sessionId" not in d:
            continue
        d["_file"] = str(f)
        out.append(d)
    return out


def label_for(session_id: str) -> str:
    f = STATUS_DIR / f"{safe_sid(session_id)}.txt"
    try:
        return f.read_text().strip().splitlines()[0]
    except Exception:
        return ""


def reachable(d: dict) -> tuple[bool, str]:
    """
    Can this window RECEIVE a message right now?

    Receiving needs a live unix socket bound at startup, so an old window cannot gain it by
    upgrading alone - it has to be reopened. We report the reason so the caller can act.
    """
    if not pid_alive(int(d.get("pid") or 0)):
        return False, "not running"
    if parse_version(d.get("version", "")) < MESSAGING_MIN_VERSION:
        return False, f"v{d.get('version')} predates messaging - reopen window"
    sock = d.get("messagingSocketPath") or str(SOCK_DIR / f"{d.get('pid')}.sock")
    if not Path(sock).exists():
        return False, "no socket - reopen window"
    return True, ""


def atomic_write_json(path: Path, data: dict) -> None:
    """Write in the harness's own compact form, atomically, so a reader never sees a half file."""
    payload = {k: v for k, v in data.items() if not k.startswith("_")}
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".lac-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(payload, fh, separators=(",", ":"))
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except Exception:
            pass
        raise


def unique_handle(base: str, my_session_id: str, sessions: list[dict]) -> str:
    """
    Keep handles unambiguous.

    Two live windows sharing a name is exactly the case that forces callers to disambiguate with an
    opaque ref, which defeats the point of naming them. Dead windows never block a name.
    """
    taken = set()
    for d in sessions:
        if d.get("sessionId") == my_session_id:
            continue
        if not pid_alive(int(d.get("pid") or 0)):
            continue
        n = (d.get("name") or "").strip().lower()
        if n:
            taken.add(n)
    if base not in taken:
        return base
    for i in range(2, 100):
        cand = f"{base}-{i}"
        if cand not in taken:
            return cand
    return base


# --------------------------------------------------------------------------------------
# contacts
#
# The live registry only knows windows that are RUNNING, which makes "message my insurance
# agent" unanswerable the moment that window closes - indistinguishable from a name that never
# existed. Contacts is the remembered half: every window we have ever seen named, with when we
# last saw it. It turns "no such agent" into "that one is closed, last seen Tuesday", which is
# the difference between a dead end and a next step.
#
# It is a cache, never an authority. Reachability is always recomputed from the live registry,
# so a stale contact can misname a window but can never make a dead one look alive.
# --------------------------------------------------------------------------------------

CONTACTS = HOME / ".claude" / "agent-contacts.json"


def load_contacts() -> dict:
    try:
        d = json.loads(CONTACTS.read_text())
        return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_contacts(c: dict) -> None:
    try:
        CONTACTS.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(CONTACTS.parent), prefix=".lac-c-", suffix=".tmp")
        with os.fdopen(fd, "w") as fh:
            json.dump(c, fh, indent=2, sort_keys=True)
        os.replace(tmp, CONTACTS)
    except Exception:
        pass  # a contacts write must never break naming or listing


def now_stamp() -> str:
    import datetime
    return datetime.datetime.now().replace(microsecond=0).isoformat()


def remember(session_id: str, label: str, handle: str, cwd: str) -> None:
    """Record one window. Keyed by sessionId so a rename updates rather than duplicates."""
    c = load_contacts()
    prev = c.get(session_id, {})
    c[session_id] = {
        "label": label or prev.get("label", ""),
        "handle": handle or prev.get("handle", ""),
        "cwd": cwd or prev.get("cwd", ""),
        "firstSeen": prev.get("firstSeen") or now_stamp(),
        "lastSeen": now_stamp(),
    }
    save_contacts(c)


def sync_contacts(rows: list[dict]) -> None:
    """Learn from whatever is live, so contacts fill in without anyone running /line."""
    c = load_contacts()
    changed = False
    for r in rows:
        sid = r.get("sessionId")
        if not sid:
            continue
        prev = c.get(sid, {})
        entry = {
            "label": r.get("label") or prev.get("label", ""),
            "handle": r.get("name") or prev.get("handle", ""),
            "cwd": r.get("cwd") or prev.get("cwd", ""),
            "firstSeen": prev.get("firstSeen") or now_stamp(),
            "lastSeen": now_stamp(),
        }
        if entry != prev:
            c[sid] = entry
            changed = True
    if changed:
        save_contacts(c)


def score_match(query: str, *fields: str) -> int:
    """
    Rank a contact against what the user actually said.

    People name windows in prose ("my summit admin hub agent") and recall them loosely, so exact
    matching is the wrong test - overlap of meaningful words is. Returns 0 for no match.
    """
    q = re.sub(r"[^a-z0-9 ]+", " ", (query or "").lower())
    words = [w for w in q.split() if w not in {"the", "my", "agent", "window", "session", "a", "an"}]
    if not words:
        return 0
    hay = " ".join(re.sub(r"[^a-z0-9 ]+", " ", (f or "").lower()) for f in fields)
    if not hay.strip():
        return 0
    if " ".join(words) in hay:
        return 100 + len(words)
    return sum(4 if w in hay.split() else (2 if w in hay else 0) for w in words)


# --------------------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------------------

def cmd_set(session_id: str, sentence: str) -> int:
    sid = safe_sid(session_id)
    if not sid:
        print("Could not resolve this window's session id - run /line again.")
        return 0

    sentence = " ".join(sentence.split()).strip()
    if not sentence:
        return cmd_clear(sid)

    # 1) caption (always succeeds; this is ours alone)
    STATUS_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(STATUS_DIR, 0o700)
    (STATUS_DIR / f"{sid}.txt").write_text(sentence + "\n")

    # 2) peer address
    sessions = load_sessions()
    mine = next((d for d in sessions if d.get("sessionId") == sid), None)

    print(f"Caption set: {sentence}")

    if mine is None:
        print("Peer address: UNCHANGED - no registry entry for this window yet.")
        print("  (Other agents can still find it by caption via `line-agent-communicator.py list`.)")
        return 0

    handle = unique_handle(slugify(sentence), sid, sessions)
    if not handle:
        print("Peer address: UNCHANGED - that sentence has no letters or digits to build a name from.")
        return 0

    old = mine.get("name", "")
    if old == handle and mine.get("nameSource") == "explicit":
        remember(sid, sentence, handle, mine.get("cwd", ""))
        print(f"Peer address: already {handle}")
        return 0

    try:
        path = Path(mine["_file"])
        fresh = json.loads(path.read_text())  # re-read: the harness may have saved since we listed
        fresh["name"] = handle
        fresh["nameSource"] = "explicit"
        atomic_write_json(path, fresh)
    except Exception as e:
        print(f"Peer address: UNCHANGED - could not update the registry ({e.__class__.__name__}).")
        print("  Caption and directory still work; use `/rename` to set the address by hand.")
        return 0

    remember(sid, sentence, handle, mine.get("cwd", ""))
    print(f"Peer address: {old} -> {handle}")
    print(f"  Other agents can now reach this window with SendMessage to: {handle}")

    ok, why = reachable(mine)
    if not ok:
        print(f"  NOTE: this window cannot RECEIVE messages yet ({why}).")
    return 0


def cmd_clear(session_id: str) -> int:
    sid = safe_sid(session_id)
    if not sid:
        print("Could not resolve this window's session id - run /line again.")
        return 0
    try:
        (STATUS_DIR / f"{sid}.txt").unlink()
    except FileNotFoundError:
        pass
    except Exception:
        pass
    print(f"Cleared caption for window {sid} - line 2 reverts to the folder name on next render.")
    print("Peer address left as-is (clearing a caption should not make a window unreachable mid-conversation).")
    return 0


def cmd_list(session_id: str = "", json_out: bool = False) -> int:
    me = safe_sid(session_id)
    rows = []
    for d in load_sessions():
        pid = int(d.get("pid") or 0)
        if not pid_alive(pid):
            continue
        ok, why = reachable(d)
        rows.append({
            "name": d.get("name", ""),
            "label": label_for(d.get("sessionId", "")),
            "cwd": d.get("cwd", ""),
            "folder": Path(d.get("cwd", "")).name,
            "status": d.get("status", ""),
            "version": d.get("version", ""),
            "pid": pid,
            "sessionId": d.get("sessionId", ""),
            "named": d.get("nameSource") == "explicit",
            "reachable": ok,
            "why": why,
            "self": d.get("sessionId") == me,
        })

    rows.sort(key=lambda r: (not r["reachable"], r["name"]))
    sync_contacts(rows)

    live_sids = {r["sessionId"] for r in rows}
    offline = [
        {"sessionId": sid, **v}
        for sid, v in load_contacts().items()
        if sid not in live_sids and (v.get("label") or v.get("handle"))
    ]
    offline.sort(key=lambda c: c.get("lastSeen", ""), reverse=True)

    if json_out:
        print(json.dumps({"live": rows, "offline": offline}, indent=2))
        return 0

    if not rows:
        print("No live Claude Code windows found.")
        return 0

    wn = max(12, max(len(r["name"]) for r in rows))
    wl = max(10, min(38, max(len(r["label"] or r["folder"]) for r in rows)))
    print(f"{'ADDRESS'.ljust(wn)}  {'WHAT IT IS'.ljust(wl)}  {'CAN RECEIVE'}")
    print(f"{'-' * wn}  {'-' * wl}  {'-' * 11}")
    for r in rows:
        what = r["label"] or f"({r['folder']})"
        mark = "YES" if r["reachable"] else f"no - {r['why']}"
        me_tag = "  <- this window" if r["self"] else ""
        print(f"{r['name'].ljust(wn)}  {what[:wl].ljust(wl)}  {mark}{me_tag}")

    unnamed = sum(1 for r in rows if not r["named"])
    unreach = sum(1 for r in rows if not r["reachable"])
    print()
    print(f"{len(rows)} live, {len(rows) - unreach} reachable.")
    if unnamed:
        print(f"{unnamed} still carry an auto-generated address - run /line in those windows to name them.")
    return 0


def main() -> int:
    args = sys.argv[1:]
    sid = os.environ.get("CLAUDE_SESSION_ID") or os.environ.get("CLAUDE_CODE_SESSION_ID") or ""

    if not args or args[0] in ("list", "ls", "directory"):
        return cmd_list(sid, json_out="--json" in args)
    if args[0] == "clear":
        return cmd_clear(sid)
    if args[0] == "set":
        return cmd_set(sid, " ".join(args[1:]))
    return cmd_set(sid, " ".join(args))


if __name__ == "__main__":
    sys.exit(main())
