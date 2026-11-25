"""rdocker rd_logcache: a persistent, append-only copy of the pool's logs on this Mac (2026-11-24).

An optional worker (Nick's MacBook, Ethan's Air, the owner's Air) goes offline for days, and its
~/rr/log/runs.log goes with it, so a measurement window it worked in could not be read. Two writers
keep a copy of every log line seen, one file per log, named as rd-measure's --logs dir names them
(runs.<worker>.log, route.<client>.log), under ~/.local/state/rdocker/logcache:

  rd-measure.py   merges every log it fetches, and reads the copy for a machine that did not answer
  rd_warm         (the client warm daemon, com.rdocker.warm) mirrors each reachable worker's runs.log
                  tail into it at most every MIRROR_EVERY_S, in the background (rd_warm.maybe_mirror)

merge() never drops or rewrites a line: it appends the records not already there, counted as a
multiset - a log may hold the same record twice (two identical route.log lines in one second), so a
record is appended once for each occurrence beyond the copies the cache already has; merging the same
text again adds nothing. A record is a line that starts with a timestamp plus the lines after it that
do not (a route.log command with newlines), so two entries whose continuation lines happen to match are
never merged. (Limit: a mirror tail that cuts through a run of identical same-second records undercounts
that run; it never drops a distinct line.) Stdlib only: rd-measure (share/) imports it with no rdocker
config.
"""
import collections
import datetime as dt
import fcntl
import os
import re
import time

_TS = re.compile(r"^(\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d)([+-]\d{4}|Z)?")


def default_dir():
    """~/.local/state/rdocker/logcache (RDOCKER_HOME moves it, as it moves every rdocker path)."""
    home = os.path.abspath(os.path.expanduser(os.environ.get("RDOCKER_HOME") or "~"))
    return os.path.join(home, ".local", "state", "rdocker", "logcache")


def records(text):
    """Log text -> records (each a str with its trailing newline). Lines before the first timestamped
    line form a record of their own (kept, never lost)."""
    out, cur = [], []
    for line in text.splitlines(True):
        if not line.endswith("\n"):
            line += "\n"
        if _TS.match(line) and cur:
            out.append("".join(cur))
            cur = []
        cur.append(line)
    if cur:
        out.append("".join(cur))
    return out


def path(cache_dir, name):
    return os.path.join(cache_dir, name + ".log")


def merge(cache_dir, name, text):
    """Append text's records missing from the cache file `name` -> how many were added. Concurrent
    writers (rd-measure, the warm daemon) take the file's flock."""
    if not text:
        return 0
    os.makedirs(cache_dir, exist_ok=True)
    p = path(cache_dir, name)
    with open(p, "a+", encoding="utf-8", errors="replace") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        f.seek(0)
        have = f.read()
        have_n = collections.Counter(records(have))
        new = []
        for r in records(text):
            if have_n[r] > 0:
                have_n[r] -= 1           # this occurrence is already in the cache
            else:
                new.append(r)
        if new:                          # one write of whole records, under the lock
            f.seek(0, os.SEEK_END)
            f.write(("" if not have or have.endswith("\n") else "\n") + "".join(new))
            f.flush()
        return len(new)


def epoch(line):
    """A log line's timestamp -> epoch seconds (runs.log carries its zone; route.log is local time)."""
    m = _TS.match(line)
    if not m:
        return None
    s = m.group(1).replace("T", " ")
    try:
        if m.group(2):
            return dt.datetime.strptime(s + m.group(2).replace("Z", "+0000"), "%Y-%m-%d %H:%M:%S%z").timestamp()
        return time.mktime(time.strptime(s, "%Y-%m-%d %H:%M:%S"))
    except ValueError:
        return None


def read(cache_dir, name):
    """-> (text, newest record's epoch or None), or (None, None) when there is no copy. Takes the file's
    shared flock, so a merge in progress is never read half-written."""
    try:
        with open(path(cache_dir, name), encoding="utf-8", errors="replace") as f:
            fcntl.flock(f.fileno(), fcntl.LOCK_SH)
            text = f.read()
    except OSError:
        return None, None
    ts = [e for e in (epoch(r) for r in records(text)) if e is not None]
    return text, (max(ts) if ts else None)
