#!/usr/bin/env python3
"""fleet_lib.py - stdlib-only engine behind fleet-move.sh (the one-time move of every live Claude
chat on this Mac to another Mac at the same absolute paths).

Runs on BOTH Macs from the same dotfiles checkout. The source Mac calls it directly; the
destination is reached as
    ssh $FLEET_DEST python3 ~/.claude-dotfiles/scripts/transfer/fleet_lib.py <cmd> [args]
with any structured input on stdin (JSON, or a tar stream for the state copy). Python 3.9+ (the
system /usr/bin/python3 on macOS), no third-party modules.

Source-side commands
  self-sha                     sha256 of this file (both Macs must run the same version)
  guard-path <path>            rc 2 if <path> sits inside the dotfiles repo or inside a git repo
  inventory --out F            live sessions (registry + liveness), their repo roots, extra roots
  plan --mode M --run-dir D    gates + roots + exclude lists for seed|backup|final|verify|land
  excludes <root>              the rsync exclude rules for one root (rule 1), for inspection
  manifest [--fsck]            stdin plan -> gzipped byte manifest + git fingerprints (rule 12)
  compare A B                  two manifests -> receipt JSON (mismatches by path hash, rule 13)
  pack-state                   stdin plan -> tar stream of per-sid state + merge/append inputs
  state-digest                 stdin plan -> what the destination must now contain (verify)
  tar-roots                    stdin plan -> tar stream of the roots minus excludes (backup)
  setup-payload                this Mac's settings/MCP/trust/git identity for dest-setup
  dest-check --local           the same tool report dest-check produces, for this Mac
  dest-compare A B             two dest-check reports + fleet.json -> what is missing per chat
  resolve-only <list>          --only tokens (full ids or unique 8+ char prefixes) -> full sids
Destination-side commands
  dest-check                   tool parity report (rule 14)
  dest-gate                    stdin plan -> refusals (version, aliases, symlinked paths, rule 7)
  place-state [--dry-run]      stdin tar -> staging, sha check, refuse-on-conflict, merges, mv
  state-check                  stdin digest -> mismatches (verify, rule 12)
  land-dest                    stdin land request -> transfer-arrived markers + landed.json
  rollback-dest --sid S        only while the dest transcript sha equals the landed sha
  dest-setup [--apply]         settings/.claude.json/git identity/installs (diff unless --apply)
  write-stream --path REL      stdin -> a new file under ~/fleet-backup-*/ (backup)
  write-receipt --name N       stdin -> ~/.claude/logs/fleet/receipts/N (mode 600)
  npm-ci                       stdin dir list -> npm ci --legacy-peer-deps where node_modules is absent

Exit codes: 0 ok | 2 refused (reason on stderr) | 1 error.

Dev-only hooks, honored ONLY under TRANSFER_TESTS_ALLOW_DEV=true (tests cannot write /Users or
/private/tmp/claude-<uid>, and run both "Macs" on one machine):
  FLEET_TEST_DEST_PREFIX   destination-side absolute paths (roots, scratchpads) live under it
  FLEET_TEST_SCRATCH_BASE  replaces /private/tmp/claude-<uid> on both sides
  TX_TEST_ALIAS_HOMES_BASE replaces /Users in alias_homes() (same knob as transfer-lib.sh)
"""
import argparse
import calendar
import difflib
import fnmatch
import glob
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tarfile
import time

DEV = os.environ.get("TRANSFER_TESTS_ALLOW_DEV") == "true"
SELF = os.path.realpath(__file__)
REPO_DIR = os.path.dirname(os.path.dirname(os.path.dirname(SELF)))

# Rule 1: rebuildable heavy dirs. transfer-lib.sh TX_HEAVY_DIRS minus ".git" (fleet copies .git).
HEAVY = ("node_modules", "dist", ".next", "coverage", ".turbo", ".venv", "__pycache__")
# transfer-lib.sh tx_is_never_name, ported 1:1 (basename patterns + per-component *.lock rule with
# the package-manager lockfile allowlist).
NEVER_BASE = ("auto-compact-*", "mission-liveness-*", "resumed-*", ".ctx-zone-bucket-*",
              "transferred-*", "transfer-arrived-*", "prod.lock", ".DS_Store", "*.pid", "*.sock",
              "*.socket", "*.keychain", "*.keychain-db")
LOCKFILE_OK = ("yarn.lock", "bun.lock", "Cargo.lock", "Gemfile.lock", "poetry.lock", "Pipfile.lock",
               "composer.lock", "flake.lock", "pdm.lock", "uv.lock", "Podfile.lock", "mix.lock",
               "pubspec.lock")
# Rule 1: the only things excluded inside a git dir.
GIT_DIR_NEVER = ("index.lock", "fsmonitor--daemon.ipc")
# Alias homes: make-home-alias.sh's marker and the top-level symlinks it creates.
ALIAS_MARKER = ".home-alias-of"
ALIAS_LINKS = (".claude", ".claude-dotfiles", ".codex", ".config")
# Tools a landed (look-only) chat may use on the destination without counting as an edit (rule 7).
READ_ONLY_TOOLS = ("Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "TodoWrite", "ToolSearch")
# Ported from line-agent-communicator.py START_TIME_TOLERANCE_SEC (registry write lag + skew).
START_TIME_TOLERANCE_SEC = 120.0
SHELLS = ("zsh", "-zsh", "bash", "-bash", "sh", "-sh", "fish", "tcsh", "login")
INDEXERS = ("mds", "mds_stores", "mdworker", "mdworker_shared", "fseventsd", "revisiond")


class Refused(Exception):
    pass


def die(msg, rc=1):
    sys.stderr.write("fleet: %s\n" % msg)
    sys.exit(rc)


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def home():
    return os.path.realpath(os.environ.get("HOME") or os.path.expanduser("~"))


def claude_dir():
    return os.path.join(home(), ".claude")


def logdir(create=True):
    d = os.path.join(claude_dir(), "logs", "fleet")
    if create:
        guard_write(d)
        os.makedirs(d, mode=0o700, exist_ok=True)
        os.chmod(d, 0o700)
    return d


def dpath(p):
    """A destination-side absolute path (dev tests put the 'other Mac' under a prefix)."""
    pre = os.environ.get("FLEET_TEST_DEST_PREFIX", "") if DEV else ""
    return pre + p if pre else p


def scratch_base():
    if DEV and os.environ.get("FLEET_TEST_SCRATCH_BASE"):
        return os.path.realpath(os.environ["FLEET_TEST_SCRATCH_BASE"])
    return "/private/tmp/claude-%d" % os.getuid()


def slug(p):
    return re.sub(r"[^A-Za-z0-9]", "-", p)


def phash(root, rel):
    """Path hash used in every receipt and mismatch line (rule 13: never a full filename)."""
    return hashlib.sha256(("%s\0%s" % (root, rel)).encode("utf-8", "surrogateescape")).hexdigest()[:16]


def sha_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def sha_bytes(b):
    return hashlib.sha256(b).hexdigest()


def write_json_atomic(path, obj, mode=0o600):
    guard_write(path)
    d = os.path.dirname(path)
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w") as fh:
        json.dump(obj, fh, indent=1, sort_keys=True)
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def load_json(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def read_stdin_json():
    try:
        return json.load(sys.stdin)
    except ValueError as e:
        die("stdin is not valid JSON: %s" % e)


# ---------------------------------------------------------------------------------------------
# Path guards
# ---------------------------------------------------------------------------------------------
def _resolve_partial(p):
    """realpath of the nearest existing ancestor + the not-yet-existing tail (like _tx_resolve_path)."""
    p = os.path.abspath(p)
    tail = []
    while not os.path.lexists(p) and p != "/":
        tail.insert(0, os.path.basename(p))
        p = os.path.dirname(p)
    return os.path.join(os.path.realpath(p), *tail) if tail else os.path.realpath(p)


def dotfiles_dirs():
    out = []
    for d in (os.path.join(home(), ".claude-dotfiles"), REPO_DIR):
        if os.path.lexists(d):
            out.append(os.path.realpath(d))
    return out


def inside(path, parent):
    return path == parent or path.startswith(parent.rstrip("/") + "/")


def guard_write(path):
    """Refuse (Refused) a write target inside the public dotfiles repo or inside any git repo
    (transfer-lib.sh tx_guard_path, plus the git-repo rule: logs and receipts never land in a repo)."""
    if "/../" in "/%s/" % path:
        raise Refused("path contains '..': %s" % path)
    r = _resolve_partial(path)
    for d in dotfiles_dirs():
        if inside(r, d):
            raise Refused("%s is inside the public dotfiles repo (%s); fleet artifacts never go there" % (path, d))
    p = r
    while True:
        if os.path.lexists(os.path.join(p, ".git")):
            raise Refused("%s is inside a git repo (%s); fleet artifacts never go there" % (path, p))
        if p == "/":
            break
        p = os.path.dirname(p)


def alias_homes():
    """transfer-lib.sh tx_alias_homes, ported: <base>/<name> real dirs owned by this account whose
    .home-alias-of marker (a real file owned by this account) names `id -un`."""
    base = "/Users"
    if DEV and os.environ.get("TX_TEST_ALIAS_HOMES_BASE"):
        base = os.environ["TX_TEST_ALIAS_HOMES_BASE"]
    import pwd
    try:
        me = pwd.getpwuid(os.getuid()).pw_name
    except KeyError:
        return []
    out = []
    for d in sorted(glob.glob(os.path.join(base, "*"))):
        try:
            if os.path.islink(d) or not os.path.isdir(d) or os.lstat(d).st_uid != os.getuid():
                continue
            m = os.path.join(d, ALIAS_MARKER)
            if os.path.islink(m) or not os.path.isfile(m) or os.lstat(m).st_uid != os.getuid():
                continue
            who = ""
            with open(m) as fh:
                for line in fh:
                    if line.startswith("alias_of="):
                        who = line[len("alias_of="):].strip()
                        break
            if who == me:
                out.append(os.path.realpath(d))
        except OSError:
            continue
    return out


def source_alias_homes():
    """On the source side fleet-move.sh passes tx_alias_homes (the bash original) via env."""
    raw = os.environ.get("FLEET_ALIAS_HOMES")
    if raw is None:
        return alias_homes()
    return [os.path.realpath(a) for a in raw.splitlines() if a.strip()]


# ---------------------------------------------------------------------------------------------
# Never-names (rule 1)
# ---------------------------------------------------------------------------------------------
def comp_never(name):
    if name in LOCKFILE_OK:
        return False
    return name == "node_modules" or fnmatch.fnmatchcase(name, "*.lock")


def is_never_name(rel):
    """transfer-lib.sh tx_is_never_name <relpath>, 1:1."""
    base = rel.rsplit("/", 1)[-1]
    for pat in NEVER_BASE:
        if fnmatch.fnmatchcase(base, pat):
            return True
    for comp in rel.split("/"):
        if comp and comp_never(comp):
            return True
    return False


def heavy_component(rel):
    return any(c in HEAVY for c in rel.split("/"))


# ---------------------------------------------------------------------------------------------
# git
# ---------------------------------------------------------------------------------------------
def git_env():
    env = dict((k, v) for k, v in os.environ.items() if not k.startswith("GIT_"))
    env["GIT_OPTIONAL_LOCKS"] = "0"     # rule 11: never write the index or take optional locks
    env["LC_ALL"] = "C"
    return env


def git(cwd, *args):
    try:
        r = subprocess.run(["git", "-C", cwd, "-c", "core.quotePath=true"] + list(args),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=git_env())
    except OSError:
        return 127, b""
    return r.returncode, r.stdout


def git_out(cwd, *args):
    rc, out = git(cwd, *args)
    return out.decode("utf-8", "surrogateescape").strip() if rc == 0 else ""


def is_bare_gitdir(d):
    return (os.path.isfile(os.path.join(d, "HEAD")) and os.path.isdir(os.path.join(d, "objects"))
            and os.path.isdir(os.path.join(d, "refs")) and not os.path.lexists(os.path.join(d, ".git")))


def repo_roots_for(cwd):
    """Rule 2: the git repo owning cwd (main checkout) + every worktree; else <cwd>/tmp."""
    notes = []
    top = git_out(cwd, "rev-parse", "--show-toplevel")
    if not top:
        t = os.path.join(cwd, "tmp")
        if os.path.isdir(t) and not os.path.islink(t):
            return [os.path.realpath(t)], "tmp", notes
        notes.append("not a git repo and has no tmp/ folder: only its chat state moves")
        return [], "none", notes
    common = git_out(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir")
    roots = []
    if common:
        common = os.path.realpath(common)
        main = os.path.dirname(common) if os.path.basename(common) == ".git" else common
        roots.append(main)
    else:
        roots.append(os.path.realpath(top))
    rc, out = git(cwd, "worktree", "list", "--porcelain", "-z")
    if rc == 0:
        for rec in out.split(b"\0\0"):
            path, prunable = None, False
            for line in rec.split(b"\0"):
                if line.startswith(b"worktree "):
                    path = os.fsdecode(line[9:])
                elif line.startswith(b"prunable"):
                    prunable = True
            if not path:
                continue
            if prunable or not os.path.isdir(path):
                notes.append("worktree %s is missing on disk (prunable); nothing to copy there" % path)
                continue
            roots.append(os.path.realpath(path))
    return roots, "git", notes


def validate_root(r, homes, aliases):
    """-> (status, reason): ok | refuse | skip (dotfiles: travels by git)."""
    if r == "/" or not r.startswith("/"):
        return "refuse", "is / or not absolute"
    for h in homes + aliases:
        if r == h:
            return "refuse", "is a home folder"
        if inside(h, r):
            return "refuse", "is an ancestor of a home folder"
    for d in dotfiles_dirs():
        if inside(r, d):
            return "skip", "the dotfiles checkout travels by git push/pull, never by copy"
    if not any(inside(r, h) for h in homes + aliases):
        return "refuse", "is not under $HOME or a verified home alias, so it cannot be mirrored"
    return "ok", ""


def dedupe_roots(roots):
    out = []
    for r in sorted(set(roots), key=lambda x: (len(x), x)):
        if not any(inside(r, k) for k in out):
            out.append(r)
    return sorted(out)


# ---------------------------------------------------------------------------------------------
# Liveness. The registry read follows transfer-send.sh py_registry (transfer-send.sh:236-254:
# ~/.claude/sessions/*.json, dicts with a string sessionId and an int pid, newest file wins per sid).
# The liveness/identity judgement is ported from line-agent-communicator.py (_ps_probe,
# is_claude_process, process_start_epoch, registry_start_epochs, identity_state: startedAt is epoch
# ms, procStart is UTC TEXT parsed with timegm, ps lstart is LOCAL, tolerance 120 s, comm basename
# "claude" or .../claude/versions/<v>), because py_registry itself only finds the newest entry and
# never judges liveness.
# ---------------------------------------------------------------------------------------------
_PS = {}


def ps_probe(pid):
    if pid in _PS:
        return _PS[pid]
    try:
        r = subprocess.run(["ps", "-p", str(pid), "-o", "lstart=,comm="], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, universal_newlines=True, timeout=10)
    except Exception:
        _PS[pid] = None
        return None
    if r.returncode not in (0, 1):
        _PS[pid] = None
        return None
    toks = r.stdout.split()
    res = {"comm": "", "lstart": ""} if len(toks) < 5 else {"lstart": " ".join(toks[:5]), "comm": " ".join(toks[5:])}
    _PS[pid] = res
    return res


def is_claude_process(pid):
    p = ps_probe(pid)
    if p is None:
        return None
    comm = p["comm"]
    if not comm:
        return False
    if os.path.basename(comm).lower() == "claude":
        return True
    parts = [x.lower() for x in comm.split("/") if x]
    return len(parts) >= 3 and parts[-2] == "versions" and parts[-3] == "claude"


def process_start_epoch(pid):
    p = ps_probe(pid)
    raw = p["lstart"] if p else ""
    if not raw:
        return None
    try:
        return time.mktime(time.strptime(raw, "%a %b %d %H:%M:%S %Y"))
    except ValueError:
        return None


def registry_start_epochs(d):
    out = []
    ms = d.get("startedAt")
    if isinstance(ms, (int, float)) and ms > 0:
        out.append(float(ms) / 1000.0)
    raw = " ".join(str(d.get("procStart") or "").split())
    if raw:
        try:
            out.append(float(calendar.timegm(time.strptime(raw, "%a %b %d %H:%M:%S %Y"))))
        except ValueError:
            pass
    return out


def identity_state(d):
    pid = d.get("pid")
    if not isinstance(pid, int) or pid <= 1:
        return "dead"
    c = is_claude_process(pid)
    if c is None:
        return "unverified"          # ps could not answer: liveness unknown, treated as live
    if not c:
        return "dead"
    live = process_start_epoch(pid)
    readings = registry_start_epochs(d)
    if live is None or not readings:
        return "unverified"
    for stamp in readings:
        if abs(stamp - live) <= START_TIME_TOLERANCE_SEC:
            return "verified"
    return "mismatch"


def registry_entries():
    out = []
    for f in glob.glob(os.path.join(claude_dir(), "sessions", "*.json")):
        try:
            with open(f) as fh:
                j = json.load(fh)
            m = os.path.getmtime(f)
        except (OSError, ValueError):
            continue
        if not isinstance(j, dict) or not isinstance(j.get("sessionId"), str) or not isinstance(j.get("pid"), int):
            continue
        j["_mtime"] = m
        out.append(j)
    return out


def live_sessions():
    """-> {sid: [entries, newest first]} for every entry whose process is still that window."""
    by = {}
    stale = 0
    for e in registry_entries():
        st = identity_state(e)
        if st in ("verified", "unverified"):
            e["_state"] = st
            by.setdefault(e["sessionId"], []).append(e)
        else:
            stale += 1
    for sid in by:
        by[sid].sort(key=lambda x: -x["_mtime"])
    return by, stale


def ps_table():
    """pid -> (ppid, comm) for every process (one fork)."""
    out = {}
    try:
        r = subprocess.run(["ps", "-axo", "pid=,ppid=,comm="], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, universal_newlines=True, timeout=30)
    except Exception:
        return out
    for line in r.stdout.splitlines():
        t = line.split(None, 2)
        if len(t) >= 2 and t[0].isdigit() and t[1].isdigit():
            out[int(t[0])] = (int(t[1]), t[2] if len(t) > 2 else "")
    return out


def ancestors(table, pid):
    seen = set()
    while pid and pid not in seen and pid > 1:
        seen.add(pid)
        pid = table.get(pid, (0, ""))[0]
    return seen


def descendants_of(table, roots):
    kids = {}
    for p, (pp, _c) in table.items():
        kids.setdefault(pp, []).append(p)
    out, stack = set(), list(roots)
    while stack:
        p = stack.pop()
        for k in kids.get(p, []):
            if k not in out:
                out.add(k)
                stack.append(k)
    return out


# ---------------------------------------------------------------------------------------------
# Transcripts
# ---------------------------------------------------------------------------------------------
def find_transcript(sid, cwd):
    """transfer-send.sh find_transcript: prefer the project dir whose slug matches cwd, else first hit."""
    hits = sorted(glob.glob(os.path.join(claude_dir(), "projects", "*", sid + ".jsonl")))
    want = slug(cwd) if cwd else None
    for h in hits:
        if want and os.path.basename(os.path.dirname(h)) == want:
            return h
    return hits[0] if hits else ""


def tool_uses(rec):
    msg = rec.get("message") if isinstance(rec, dict) else None
    content = msg.get("content") if isinstance(msg, dict) else None
    if not isinstance(content, list):
        return []
    return [c for c in content if isinstance(c, dict) and c.get("type") == "tool_use"]


def parse_jsonl_tail(data):
    """-> (records, complete) for appended bytes; complete False when a line does not parse."""
    recs = []
    for line in data.split(b"\n"):
        if not line.strip():
            continue
        try:
            recs.append(json.loads(line))
        except ValueError:
            return recs, False
    return recs, True


def last_uuid_in(data):
    u = None
    for line in data.split(b"\n"):
        if not line.strip():
            continue
        try:
            j = json.loads(line)
        except ValueError:
            continue
        if isinstance(j, dict) and isinstance(j.get("uuid"), str):
            u = j["uuid"]
    return u


def check_marker(sid, transcript):
    """Rule 4: the fleet-ready marker must match the transcript; growth after it is accepted only
    when no appended record holds a tool_use - except the pack step's own marker-writing Bash call
    (its tool_use record can land after the size was measured)."""
    mf = os.path.join(claude_dir(), "progress", "fleet-ready-" + sid)
    m = load_json(mf)
    if not isinstance(m, dict):
        return "not packed: no fleet-ready marker (run /transfer pack in that window)"
    if m.get("sid") != sid or not isinstance(m.get("transcript_bytes"), int) or not isinstance(m.get("last_uuid"), str):
        return "fleet-ready marker is malformed"
    if not transcript or not os.path.isfile(transcript):
        return "no transcript found"
    n = m["transcript_bytes"]
    with open(transcript, "rb") as fh:
        data = fh.read()
    if len(data) < n:
        return "transcript is SHORTER than when it was packed"
    pre, tail = data[:n], data[n:]
    if n and not pre.endswith(b"\n"):
        return "the marker does not sit on a record boundary"
    if last_uuid_in(pre) != m["last_uuid"]:
        return "transcript does not match its marker (last record id differs)"
    recs, complete = parse_jsonl_tail(tail)
    if not complete:
        return "transcript ends mid-record after packing: wait until the window has closed"
    token = "fleet-ready-" + sid
    for r in recs:
        for t in tool_uses(r):
            cmd = (t.get("input") or {}).get("command") if isinstance(t.get("input"), dict) else None
            if isinstance(cmd, str) and token in cmd:
                continue
            return "the chat kept working after it was packed (a %s call): pack it again" % (t.get("name") or "tool")
    return ""


def appended_mutations(path, n, sha):
    """Rule 7 for a landed chat on the destination: the first n bytes must still hash to sha and every
    appended tool call must be read-only. -> '' or a reason."""
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return "its transcript is missing on this Mac"
    if len(data) < n or sha_bytes(data[:n]) != sha:
        return "its transcript was rewritten (not just appended to) since it landed"
    recs, _ = parse_jsonl_tail(data[n:])
    for r in recs:
        for t in tool_uses(r):
            if t.get("name") not in READ_ONLY_TOOLS:
                return "it was used for more than questions since it landed (a %s call)" % (t.get("name") or "tool")
    return ""


# ---------------------------------------------------------------------------------------------
# Excludes (rule 1)
# ---------------------------------------------------------------------------------------------
class Excl(object):
    def __init__(self):
        self.items = {}

    def add(self, p, is_dir):
        self.items[p] = bool(is_dir)


def _special(full):
    try:
        m = os.lstat(full).st_mode
    except OSError:
        return False
    return not (stat.S_ISREG(m) or stat.S_ISDIR(m) or stat.S_ISLNK(m))


def scan_gitdir(g, ex):
    """Inside a git dir only index.lock, fsmonitor--daemon.ipc and *.sock are excluded. The two
    literal lock paths are emitted even when absent, so a lock that appears later is still left out."""
    ex.add(os.path.join(g, "index.lock"), False)
    wtd = os.path.join(g, "worktrees")
    if os.path.isdir(wtd):
        for n in os.listdir(wtd):
            ex.add(os.path.join(wtd, n, "index.lock"), False)
    for dp, dn, fn in os.walk(g):
        dn[:] = [n for n in dn if not os.path.islink(os.path.join(dp, n))]
        for n in fn:
            if n in GIT_DIR_NEVER or n.endswith(".sock") or _special(os.path.join(dp, n)):
                ex.add(os.path.join(dp, n), False)


def scan_plain(d, ex):
    """Every file under a non-git dir is untracked: heavy dirs, never-names and specials go."""
    for dp, dn, fn in os.walk(d):
        keep = []
        for n in dn:
            full = os.path.join(dp, n)
            if os.path.islink(full):
                if is_never_name(n):
                    ex.add(full, False)
                continue
            if n in HEAVY or comp_never(n):
                ex.add(full, True)
            elif os.path.lexists(os.path.join(full, ".git")) or is_bare_gitdir(full):
                scan_root(full, ex)
            else:
                keep.append(n)
        dn[:] = keep
        for n in fn:
            full = os.path.join(dp, n)
            if is_never_name(n) or _special(full):
                ex.add(full, False)


def scan_repo(wt, ex):
    g = os.path.join(wt, ".git")
    if os.path.isdir(g) and not os.path.islink(g):
        scan_gitdir(g, ex)
    # Untracked AND ignored, wholly-untracked dirs (and nested repos) collapsed to one entry.
    rc, raw = git(wt, "ls-files", "-o", "--directory", "--no-empty-directory", "-z")
    if rc != 0:
        raise Refused("git ls-files failed in %s" % wt)
    for e in raw.split(b"\0"):
        if not e:
            continue
        is_dir = e.endswith(b"/")
        rel = os.fsdecode(e.rstrip(b"/"))
        full = os.path.join(wt, rel)
        if heavy_component(rel):
            ex.add(full, is_dir)
            continue
        if is_dir and os.path.isdir(full) and not os.path.islink(full):
            if any(comp_never(c) for c in rel.split("/")):
                ex.add(full, True)
            elif os.path.lexists(os.path.join(full, ".git")) or is_bare_gitdir(full):
                scan_root(full, ex)
            else:
                scan_plain(full, ex)
            continue
        if is_never_name(rel) or _special(full):
            ex.add(full, False)


def scan_root(root, ex):
    if os.path.lexists(os.path.join(root, ".git")):
        scan_repo(root, ex)
    elif is_bare_gitdir(root):
        scan_gitdir(root, ex)
    else:
        scan_plain(root, ex)


def exclude_list(root, aliases):
    ex = Excl()
    scan_root(root, ex)
    for a in aliases:                       # rule 2: never an alias marker or an alias's symlinks
        if inside(a, root) or inside(root, a):
            ex.add(os.path.join(a, ALIAS_MARKER), False)
            for n in ALIAS_LINKS:
                ex.add(os.path.join(a, n), False)
    return sorted([p, d] for p, d in ex.items.items() if inside(p, root))


def rsync_escape(p):
    if "\n" in p or "\\" in p:
        return None
    return re.sub(r"([*?\[])", r"\\\1", p)


def rsync_rules(excl):
    lines, bad = [], 0
    for p, is_dir in excl:
        e = rsync_escape(p)
        if e is None:
            bad += 1
            continue
        lines.append("- %s%s" % (e, "/" if is_dir else ""))
    return lines, bad


# ---------------------------------------------------------------------------------------------
# Manifest + git fingerprint (rules 11, 12)
# ---------------------------------------------------------------------------------------------
def _git_internal_skip(parts):
    """.git/index (covered by the staged-diff sha) and git lock/socket files never enter the manifest."""
    if ".git" not in parts:
        return False
    i = parts.index(".git")
    rest = parts[i + 1:]
    if rest == ["index"] or (len(rest) == 3 and rest[0] == "worktrees" and rest[2] == "index"):
        return True
    return bool(rest) and (rest[-1] in GIT_DIR_NEVER or rest[-1].endswith(".sock"))


class Walk(object):
    """Walks <scan> (the root on this Mac, or its dest-side path) skipping the root's excludes."""

    def __init__(self, root, scan, excl):
        self.root, self.scan = root, scan
        self.files = set(p for p, d in excl if not d)
        self.dirs = set(p for p, d in excl if d)
        self.excl_all = self.files | self.dirs

    def excluded(self, abs_root_path, is_dir):
        return abs_root_path in self.excl_all

    def entries(self):
        """yield (rel, full_scan_path, lstat) for every kept entry, root first."""
        try:
            st = os.lstat(self.scan)
        except OSError:
            return
        yield ".", self.scan, st
        for dp, dn, fn in os.walk(self.scan):
            reld = os.path.relpath(dp, self.scan)
            keep = []
            for n in sorted(dn):
                full = os.path.join(dp, n)
                rel = n if reld == "." else reld + "/" + n
                if os.path.join(self.root, rel) in self.excl_all:
                    continue
                try:
                    s = os.lstat(full)
                except OSError:
                    continue
                yield rel, full, s
                if not stat.S_ISLNK(s.st_mode):
                    keep.append(n)
            dn[:] = keep
            for n in sorted(fn):
                full = os.path.join(dp, n)
                rel = n if reld == "." else reld + "/" + n
                if os.path.join(self.root, rel) in self.excl_all:
                    continue
                try:
                    s = os.lstat(full)
                except OSError:
                    continue
                yield rel, full, s


def manifest_root(root, scan, excl):
    w = Walk(root, scan, excl)
    files, inodes, worktrees, locks = {}, {}, [], []
    for rel, full, st in w.entries():
        parts = rel.split("/")
        m = st.st_mode
        if parts[-1] == ".DS_Store":       # Finder writes these on either Mac at will
            continue
        if _git_internal_skip(parts):
            if parts[-1] == "index.lock":
                locks.append(phash(root, rel))
            continue
        if stat.S_ISLNK(m):
            d = "l:" + os.readlink(full)
        elif stat.S_ISDIR(m):
            d = "d:%o" % stat.S_IMODE(m)
            if os.path.lexists(os.path.join(full, ".git")):
                worktrees.append((rel, full))
        elif stat.S_ISREG(m):
            d = "f:%s:%d:%o" % (sha_file(full), st.st_size, stat.S_IMODE(m))
            if st.st_nlink > 1:
                inodes.setdefault((st.st_dev, st.st_ino), []).append(phash(root, rel))
        else:
            continue                        # sockets, fifos, devices never travel
        files[phash(root, rel)] = d
    hard = sorted(sorted(v) for v in inodes.values() if len(v) > 1)
    return files, hard, worktrees, locks


def git_fingerprint(root, rel, scan_wt, excl_all):
    """Rule 12 per worktree: HEAD, branch, porcelain v2, staged/worktree diff shas, untracked list,
    stash list, for-each-ref sha. Untracked entries the copy leaves out are filtered on both Macs."""
    def h(*args):
        rc, out = git(scan_wt, *args)
        return "rc%d:%s" % (rc, sha_bytes(out))
    fp = {
        "head": git_out(scan_wt, "rev-parse", "-q", "--verify", "HEAD"),
        "branch": git_out(scan_wt, "symbolic-ref", "-q", "HEAD"),
        "status": h("status", "--porcelain=v2", "--untracked-files=no", "-z"),
        "staged": h("-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false", "-c", "diff.relative=false",
                    "diff", "--cached", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames",
                    "--full-index", "--binary"),
        "worktree": h("-c", "diff.noprefix=false", "-c", "diff.mnemonicPrefix=false", "-c", "diff.relative=false",
                      "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames",
                      "--full-index", "--binary"),
        "stash": h("log", "-g", "--format=%H", "refs/stash", "--"),
        "refs": h("for-each-ref", "--format=%(objectname) %(refname)"),
    }
    rc, raw = git(scan_wt, "ls-files", "-o", "--exclude-standard", "-z")
    keep = []
    base = os.path.join(root, rel) if rel != "." else root
    for e in raw.split(b"\0"):
        if not e:
            continue
        r = os.fsdecode(e)
        ab = os.path.join(base, r)
        if ab in excl_all or any(inside(ab, x) for x in excl_all if inside(x, base) and x != ab and ab.startswith(x + "/")):
            continue
        if r.rsplit("/", 1)[-1] == ".DS_Store":
            continue
        keep.append(r)
    fp["untracked"] = "rc%d:%s" % (rc, sha_bytes("\0".join(sorted(keep)).encode("utf-8", "surrogateescape")))
    return fp


def cmd_manifest(a):
    plan = read_stdin_json()
    dest_side = a.dest
    out = {"format": 1, "host": socket.gethostname().split(".")[0], "side": "dest" if dest_side else "source",
           "roots": {}}
    fsck_done = {}
    for r in plan.get("roots", []):
        root = r["path"]
        scan = dpath(root) if dest_side else root
        excl = r.get("excludes", [])
        if not os.path.isdir(scan):
            out["roots"][root] = {"missing": True}
            continue
        files, hard, wts, locks = manifest_root(root, scan, excl)
        excl_all = set(p for p, _d in excl)
        gits = {}
        for rel, full in wts:              # rule 11: hashed first, git fingerprints after
            gits[rel] = git_fingerprint(root, rel, full, excl_all)
            if a.fsck:
                common = git_out(full, "rev-parse", "--path-format=absolute", "--git-common-dir")
                if common and common not in fsck_done:
                    rc, _ = git(full, "fsck", "--connectivity-only", "--no-progress")
                    fsck_done[common] = rc
                gits[rel]["fsck"] = fsck_done.get(common, -1)
        out["roots"][root] = {"files": files, "hard": hard, "git": gits, "locks": locks}
    sys.stdout.buffer.write(gzip.compress(json.dumps(out, sort_keys=True).encode()))


def load_gz(p):
    with open(p, "rb") as fh:
        return json.loads(gzip.decompress(fh.read()).decode())


def cmd_compare(a):
    src, dst = load_gz(a.source), load_gz(a.dest_manifest)
    plan = load_json(a.plan, {}) if a.plan else {}
    live_shared = set(r["path"] for r in plan.get("roots", []) if r.get("live_other_sids"))
    mism, drift = [], []
    for root, s in sorted(src["roots"].items()):
        d = dst["roots"].get(root, {"missing": True})
        bucket = drift if root in live_shared else mism

        def add(kind, ph):
            bucket.append({"root": root, "kind": kind, "path": ph})
        if s.get("missing"):
            add("missing-on-source", "-")
            continue
        if d.get("missing"):
            add("root-missing-on-dest", "-")
            continue
        sf, df = s["files"], d["files"]
        for ph in sorted(set(sf) | set(df)):
            if ph not in df:
                add("missing-on-dest", ph)
            elif ph not in sf:
                add("extra-on-dest", ph)
            elif sf[ph] != df[ph]:
                a1, b1 = sf[ph].split(":"), df[ph].split(":")
                if a1[0] != b1[0]:
                    k = "type"
                elif a1[0] == "f" and a1[1] != b1[1]:
                    k = "content"
                elif a1[0] == "l":
                    k = "symlink-target"
                else:
                    k = "mode"
                add(k, ph)
        if s.get("hard") != d.get("hard"):
            add("hardlink-groups", "-")
        for ph in d.get("locks", []):
            add("stray-git-lock-on-dest", ph)
        for wt in sorted(set(s.get("git", {})) | set(d.get("git", {}))):
            gs, gd = s.get("git", {}).get(wt), d.get("git", {}).get(wt)
            if gs is None or gd is None:
                add("git-worktree-missing", wt)
                continue
            for k in ("head", "branch", "status", "staged", "worktree", "untracked", "stash", "refs"):
                if gs.get(k) != gd.get(k):
                    add("git-" + k, wt)
            if gd.get("fsck", 0) not in (0, -1):
                add("git-fsck-failed", wt)
    for root in sorted(set(dst["roots"]) - set(src["roots"])):
        mism.append({"root": root, "kind": "root-only-on-dest", "path": "-"})
    rec = {"format": 1, "kind": "verify-files", "at": now_iso(), "mismatches": mism, "drift": drift,
           "roots": len(src["roots"]), "files": sum(len(v.get("files", {})) for v in src["roots"].values())}
    json.dump(rec, sys.stdout, indent=1, sort_keys=True)


# ---------------------------------------------------------------------------------------------
# Inventory + plan
# ---------------------------------------------------------------------------------------------
def extra_roots():
    raw = os.environ.get("FLEET_EXTRA_ROOTS", "")
    out = []
    for pat in [x for x in raw.split(":") if x.strip()]:
        hits = sorted(glob.glob(pat))
        out.extend(os.path.realpath(h) for h in hits if os.path.isdir(h) and not os.path.islink(h))
    return out


def build_inventory():
    homes = [home()]
    aliases = source_alias_homes()
    live, stale = live_sessions()
    sessions, root_owner, notes_all = [], {}, []
    for sid in sorted(live):
        ents = live[sid]
        e = ents[0]
        cwd = os.path.realpath(e.get("cwd") or "") if e.get("cwd") else ""
        tr = find_transcript(sid, cwd)
        roots, kind, notes = repo_roots_for(cwd) if cwd and os.path.isdir(cwd) else ([], "none", ["cwd missing"])
        sessions.append({
            "sid": sid, "name": e.get("name") or "", "cwd": cwd, "pids": [x["pid"] for x in ents],
            "states": [x["_state"] for x in ents], "duplicate": len(ents) > 1, "transcript": tr,
            "transcript_bytes": os.path.getsize(tr) if tr else 0, "roots": roots, "root_kind": kind,
            "notes": notes})
        for r in roots:
            root_owner.setdefault(r, set()).add(sid)
    for r in extra_roots():
        root_owner.setdefault(r, set())
    ok, refused, skipped = [], [], []
    for r in sorted(root_owner):
        st, why = validate_root(r, homes, aliases)
        rec = {"path": r, "sids": sorted(root_owner[r]), "reason": why}
        (ok if st == "ok" else refused if st == "refuse" else skipped).append(rec)
    kept = dedupe_roots([x["path"] for x in ok])
    owners = {}
    for x in ok:
        k = next(c for c in kept if inside(x["path"], c))
        owners.setdefault(k, set()).update(x["sids"])
    return {"format": 1, "created_at": now_iso(), "host": socket.gethostname().split(".")[0],
            "home": home(), "alias_homes": aliases, "sessions": sessions,
            "roots": [{"path": k, "sids": sorted(owners.get(k, []))} for k in kept],
            "refused_roots": refused, "skipped_roots": skipped, "stale_registry_entries": stale}


def cmd_inventory(a):
    inv = build_inventory()
    if a.out:
        write_json_atomic(a.out, inv)
    print("Live chats: %d   (stale registry entries ignored: %d)" % (len(inv["sessions"]), inv["stale_registry_entries"]))
    for s in inv["sessions"]:
        flag = "  DUPLICATE: %d live windows on one chat - close all but one" % len(s["pids"]) if s["duplicate"] else ""
        print("  %s  %-30s %s%s" % (s["sid"][:8], (s["name"] or "-")[:30], s["cwd"], flag))
        for n in s["notes"]:
            print("      note: %s" % n)
    print("Roots to copy: %d" % len(inv["roots"]))
    for r in inv["roots"]:
        print("  %s  (%s)" % (r["path"], ", ".join(x[:8] for x in r["sids"]) or "extra root"))
    for r in inv["skipped_roots"]:
        print("  SKIPPED %s - %s" % (r["path"], r["reason"]))
    for r in inv["refused_roots"]:
        print("  REFUSED %s - %s" % (r["path"], r["reason"]))
    if any(s["duplicate"] for s in inv["sessions"]) or inv["refused_roots"]:
        sys.exit(2)


def resolve_only(tokens, candidates):
    out = []
    for t in [x.strip() for x in tokens.split(",") if x.strip()]:
        if not re.match(r"^[A-Za-z0-9_-]+$", t):
            raise Refused("--only: %r is not a session id" % t)
        hits = sorted(set(c for c in candidates if c == t or c.startswith(t)))
        if t in candidates:
            hits = [t]
        elif len(t) < 8:
            raise Refused("--only: %r is shorter than 8 characters; give the full id or 8+ characters" % t)
        if not hits:
            raise Refused("--only: no known chat matches %r" % t)
        if len(hits) > 1:
            raise Refused("--only: %r matches %d chats (%s); give more characters" % (t, len(hits), ", ".join(h[:12] for h in hits)))
        if hits[0] not in out:
            out.append(hits[0])
    if not out:
        raise Refused("--only: no session ids given")
    return out


def markers():
    out = {}
    for f in glob.glob(os.path.join(claude_dir(), "progress", "fleet-ready-*")):
        sid = os.path.basename(f)[len("fleet-ready-"):]
        m = load_json(f)
        if isinstance(m, dict) and m.get("sid") == sid:
            out[sid] = m
    return out


def landed_local():
    return load_json(os.path.join(logdir(create=False), "landed-local.json"), {"sids": {}}) or {"sids": {}}


def candidate_sids(inv):
    c = set(s["sid"] for s in inv.get("sessions", []))
    c |= set(markers())
    c |= set(landed_local().get("sids", {}))
    return c


def cmd_resolve_only(a):
    inv = load_json(a.fleet_json, {}) or {}
    print("\n".join(resolve_only(a.tokens, candidate_sids(inv))))


def lsof_findings(roots):
    """pid -> {"comm", "cwd": [roots], "files": [roots]} for processes using anything inside roots."""
    try:
        r = subprocess.run(["lsof", "-nP", "-w", "-Fpcfn"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=180)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Refused("cannot run lsof to prove nothing is using the folders (%s)" % e.__class__.__name__)
    found, pid, comm, fd = {}, None, "", ""
    pref = [(rt, rt.rstrip("/") + "/") for rt in roots]
    for line in r.stdout.decode("utf-8", "surrogateescape").splitlines():
        if not line:
            continue
        k, v = line[0], line[1:]
        if k == "p":
            pid, comm = int(v), ""
        elif k == "c":
            comm = v
        elif k == "f":
            fd = v
        elif k == "n" and pid is not None:
            name = v
            for a, b in (("/var/", "/private/var/"), ("/tmp/", "/private/tmp/"), ("/etc/", "/private/etc/")):
                if name.startswith(a):
                    name = b + name[len(a):]
            for rt, rp in pref:
                if name == rt or name.startswith(rp):
                    f = found.setdefault(pid, {"comm": comm, "cwd": set(), "files": set()})
                    (f["cwd"] if fd == "cwd" else f["files"]).add(rt)
                    break
    return found


def compute_roots_for(cwds_by_sid, homes, aliases, with_extra):
    owner, notes, refused, skipped = {}, [], [], []
    for sid, cwd in sorted(cwds_by_sid.items()):
        if not cwd or not os.path.isdir(cwd):
            notes.append("%s: working folder %s is missing; only its chat state moves" % (sid[:8], cwd))
            continue
        roots, _k, n = repo_roots_for(cwd)
        notes.extend("%s: %s" % (sid[:8], x) for x in n)
        for r in roots:
            owner.setdefault(r, set()).add(sid)
    if with_extra:
        for r in extra_roots():
            owner.setdefault(r, set())
    ok = []
    for r in sorted(owner):
        st, why = validate_root(r, homes, aliases)
        if st == "ok":
            ok.append(r)
        elif st == "skip":
            skipped.append({"path": r, "reason": why})
        else:
            refused.append({"path": r, "reason": why, "sids": sorted(owner[r])})
    kept = dedupe_roots(ok)
    owners = dict((k, set()) for k in kept)
    for r in ok:
        k = next(c for c in kept if inside(r, c))
        owners[k] |= owner[r]
    return owners, notes, refused, skipped


def cmd_plan(a):
    """Everything a run needs, decided once on this Mac: sids, roots, exclude lists, gates."""
    mode = a.mode
    inv = load_json(a.fleet_json, {}) or {}
    homes, aliases = [home()], source_alias_homes()
    refusals, warnings = [], []
    live, _stale = live_sessions()
    table = ps_table()
    me = ancestors(table, os.getpid())
    operator_sids = set(sid for sid, ents in live.items() if any(e["pid"] in me for e in ents))
    inv_cwd = dict((s["sid"], s["cwd"]) for s in inv.get("sessions", []))
    inv_tr = dict((s["sid"], s["transcript"]) for s in inv.get("sessions", []))
    inv_name = dict((s["sid"], s.get("name", "")) for s in inv.get("sessions", []))
    mk = markers()
    landed = set(landed_local().get("sids", {}))
    for sid, ents in sorted(live.items()):
        if len(ents) > 1:
            refusals.append("chat %s (%s) is open in %d windows at once (pids %s): close all but one first"
                            % (sid[:8], ents[0].get("name") or "-", len(ents), ", ".join(str(e["pid"]) for e in ents)))
    only = []
    if a.only:
        try:
            only = resolve_only(a.only, candidate_sids(inv))
        except Refused as e:
            refusals.append(str(e))
    if mode in ("seed", "backup"):
        sids = sorted(set(inv_cwd) | set(live))
    elif only:
        sids = only
    else:
        sids = sorted((set(inv_cwd) | set(mk)) - landed) if mode == "final" else sorted(set(inv_cwd) | set(mk) | landed)
    cwds, trs = {}, {}
    for sid in sids:
        cwd = inv_cwd.get(sid) or (mk.get(sid) or {}).get("cwd") or (live.get(sid, [{}])[0].get("cwd") or "")
        cwd = os.path.realpath(cwd) if cwd else ""
        cwds[sid] = cwd
        tr = (mk.get(sid) or {}).get("transcript") or inv_tr.get(sid) or ""
        if not tr or not os.path.isfile(tr):
            tr = find_transcript(sid, cwd)
        trs[sid] = tr
        if mode in ("final", "verify", "land") and not tr:
            refusals.append("chat %s: no transcript under ~/.claude/projects/*/" % sid[:8])
    state_sids = [s for s in sids if s not in landed] if mode == "final" else list(sids)
    if mode == "final":
        if only and any(s in landed for s in only):
            warnings.append("already landed (state not re-copied, roots re-synced): %s"
                            % ", ".join(s[:8] for s in only if s in landed))
        for sid in state_sids:
            if sid in live:
                refusals.append("chat %s (%s) is still open: run /transfer pack in it, then /exit" % (sid[:8], inv_name.get(sid) or "-"))
                continue
            why = check_marker(sid, trs.get(sid))
            if why:
                refusals.append("chat %s (%s): %s" % (sid[:8], inv_name.get(sid) or "-", why))
        for sid in operator_sids:
            if sid in sids:
                refusals.append("this command is running inside chat %s, which is being moved: run it from a plain Terminal" % sid[:8])
    owners, notes, refused, skipped = compute_roots_for(cwds, homes, aliases, with_extra=not only)
    warnings.extend(notes)
    for r in refused:
        refusals.append("root %s %s" % (r["path"], r["reason"]))
    for r in skipped:
        warnings.append("not copied: %s (%s)" % (r["path"], r["reason"]))
    roots = []
    other_live = dict((sid, ents) for sid, ents in live.items() if sid not in sids and sid not in operator_sids)
    for path in sorted(owners):
        excl = exclude_list(path, aliases)
        lo = sorted(sid for sid, ents in other_live.items()
                    if ents[0].get("cwd") and inside(os.path.realpath(ents[0]["cwd"]), path))
        roots.append({"path": path, "sids": sorted(owners[path]), "excludes": excl, "live_other_sids": lo})
    if mode == "final":
        # Rule 5: quiescence. A full final refuses ANY other live chat; a pilot (--only) lets the
        # chats that are not moving keep running (their shared roots are re-synced by the full final).
        for sid, ents in sorted(other_live.items()):
            msg = "chat %s (%s) is still open on this Mac" % (sid[:8], ents[0].get("name") or "-")
            if only:
                warnings.append(msg + " - its folders are copied as a live snapshot; the full final re-syncs them")
            else:
                refusals.append(msg + ": pack and close every window first")
        live_pids = set(e["pid"] for ents in other_live.values() for e in ents) if only else set()
        allowed = descendants_of(table, live_pids) | live_pids
        for pid, f in sorted(lsof_findings([r["path"] for r in roots]).items()):
            if pid in me:
                continue
            comm = os.path.basename(f["comm"] or table.get(pid, (0, ""))[1] or "?")
            where = ", ".join(sorted(f["cwd"] | f["files"]))
            if pid in allowed:
                continue
            if comm in INDEXERS:
                warnings.append("system indexer %s (pid %d) is reading inside %s" % (comm, pid, where))
            elif not f["files"] and comm in SHELLS:
                warnings.append("an idle %s (pid %d) has its working folder inside %s" % (comm, pid, where))
            else:
                refusals.append("process %s (pid %d) is using files inside %s: stop it first" % (comm, pid, where))
    if mode == "final" and os.environ.get("FLEET_DOCKER_OK") != "1" and not a.dry_run:
        refusals.append("set FLEET_DOCKER_OK=1 once the owner confirms Docker has moved off the destination")
    rules = []
    bad = 0
    for r in roots:
        lines, b = rsync_rules(r["excludes"])
        rules.extend(lines)
        bad += b
    if bad:
        warnings.append("%d excluded path(s) contain a newline or backslash and cannot be expressed to rsync" % bad)
    plan = {"format": 1, "mode": mode, "created_at": now_iso(), "host": socket.gethostname().split(".")[0],
            "home": home(), "lib_sha": sha_file(SELF), "dry_run": bool(a.dry_run), "only": only,
            "sids": [{"sid": s, "cwd": cwds[s], "transcript": trs.get(s, ""), "name": inv_name.get(s, ""),
                      "state": s in state_sids} for s in sids],
            "roots": roots, "refusals": refusals, "warnings": warnings,
            "scratch_base": scratch_base()}
    d = a.run_dir
    guard_write(d)
    os.makedirs(d, mode=0o700, exist_ok=True)
    write_json_atomic(os.path.join(d, "plan.json"), plan)
    with open(os.path.join(d, "excludes.rsync"), "w") as fh:
        fh.write("\n".join(rules) + ("\n" if rules else ""))
    os.chmod(os.path.join(d, "excludes.rsync"), 0o600)
    with open(os.path.join(d, "roots.txt"), "w") as fh:
        fh.write("".join(r["path"] + "\n" for r in roots))
    for w in warnings:
        sys.stderr.write("fleet: WARN: %s\n" % w)
    for r in refusals:
        sys.stderr.write("fleet: REFUSE: %s\n" % r)
    sys.exit(2 if refusals else 0)


def cmd_excludes(a):
    root = os.path.realpath(a.root)
    lines, _ = rsync_rules(exclude_list(root, source_alias_homes()))
    print("\n".join(lines))


# ---------------------------------------------------------------------------------------------
# Per-sid state (rules 8, 9, 10, 17)
# ---------------------------------------------------------------------------------------------
def _tree(base):
    out = []
    if os.path.isdir(base) and not os.path.islink(base):
        for dp, dn, fn in os.walk(base):
            dn[:] = [n for n in dn if not os.path.islink(os.path.join(dp, n))] + \
                [n for n in dn if os.path.islink(os.path.join(dp, n)) and out.append(os.path.join(dp, n))]
            for n in fn:
                out.append(os.path.join(dp, n))
    return sorted(out)


def collect_state(plan):
    """-> list of (kind, arcname, source path, sid). Ported from transfer-send.sh collect_claude
    (transfer-send.sh:549-588) with the memory dir, plans and paste-cache as MERGE inputs (shared
    between chats), history.jsonl + prod-ledger/*.jsonl as APPEND inputs (rule 9) and the
    scratchpad (rule 17)."""
    cd = claude_dir()
    items, seen = [], set()

    def add(kind, path, sid, arc=None):
        if not (os.path.isfile(path) or os.path.islink(path)):
            return
        if arc is None:
            arc = "claude/" + os.path.relpath(path, cd)
        if arc in seen:
            return
        rel = arc.split("/", 1)[1]
        if is_never_name(rel) or rel.startswith("sessions/") or rel.startswith(".credentials"):
            return
        seen.add(arc)
        items.append((kind, arc, path, sid))

    slugs = set()
    hist = os.path.join(cd, "history.jsonl")
    for s in plan.get("sids", []):
        if not s.get("state"):
            continue
        sid, tr, cwd = s["sid"], s.get("transcript") or "", s.get("cwd") or ""
        if tr:
            pdir = os.path.dirname(tr)
            add("state", tr, sid)
            for f in _tree(os.path.join(pdir, sid)):
                add("state", f, sid)
            slugs.add(pdir)
        if cwd:
            slugs.add(os.path.join(cd, "projects", slug(cwd)))
        for sub in ("file-history", "session-env", "tasks"):
            for f in _tree(os.path.join(cd, sub, sid)):
                add("state", f, sid)
        for f in ("chains/%s.json" % sid, "chains/%s.log" % sid, "progress/ctx-%s.txt" % sid,
                  "session-status/%s.txt" % sid):
            add("state", os.path.join(cd, f), sid)
        if tr:
            with open(tr, "rb") as fh:
                names = set(re.findall(rb"\.claude/plans/([A-Za-z0-9._-]+\.md)", fh.read()))
            for n in sorted(names):
                add("merge", os.path.join(cd, "plans", os.fsdecode(n)), sid)
        if os.path.isfile(hist):
            with open(hist, "rb") as fh:
                for line in fh:
                    if sid.encode() not in line:
                        continue
                    try:
                        j = json.loads(line)
                    except ValueError:
                        continue
                    if j.get("sessionId") != sid:
                        continue
                    for v in (j.get("pastedContents") or {}).values():
                        hsh = v.get("contentHash") if isinstance(v, dict) else None
                        if isinstance(hsh, str) and re.match(r"^[0-9a-f]{8,64}$", hsh):
                            add("merge", os.path.join(cd, "paste-cache", hsh + ".txt"), sid)
        sb = scratch_base()
        for d in sorted(glob.glob(os.path.join(sb, "*", sid))):
            for f in _tree(d):
                add("scratch", f, sid, "scratch/" + os.path.relpath(f, sb))
    for p in sorted(slugs):
        for f in _tree(os.path.join(p, "memory")):
            add("merge", f, "")
    if any(s.get("state") for s in plan.get("sids", [])) or plan.get("mode") == "final":
        add("append", hist, "")
        for f in sorted(glob.glob(os.path.join(cd, "prod-ledger", "*.jsonl"))):
            add("append", f, "")
    return items


class HashReader(object):
    def __init__(self, fh):
        self.fh, self.h = fh, hashlib.sha256()

    def read(self, n=-1):
        b = self.fh.read(n)
        self.h.update(b)
        return b


def cmd_pack_state(a):
    plan = read_stdin_json()
    items = collect_state(plan)
    man = []
    tf = tarfile.open(fileobj=sys.stdout.buffer, mode="w|", format=tarfile.PAX_FORMAT)
    for kind, arc, path, sid in items:
        ti = tf.gettarinfo(path, arcname=arc)
        ti.uname = ti.gname = ""
        ti.uid = ti.gid = 0
        ent = {"arc": arc, "kind": kind, "sid": sid, "mode": ti.mode, "mtime": int(ti.mtime)}
        if ti.issym():
            ent["link"] = ti.linkname
            tf.addfile(ti)
        elif ti.isreg():
            with open(path, "rb") as fh:
                hr = HashReader(fh)
                tf.addfile(ti, hr)
            ent["sha"], ent["size"] = hr.h.hexdigest(), ti.size
        else:
            continue
        man.append(ent)
    body = json.dumps({"format": 1, "host": plan.get("host") or socket.gethostname().split(".")[0],
                       "members": man}).encode()
    ti = tarfile.TarInfo("__fleet__/manifest.json")
    ti.size, ti.mode, ti.mtime = len(body), 0o600, int(time.time())
    tf.addfile(ti, io.BytesIO(body))
    tf.close()


def state_target(arc):
    kind, rel = arc.split("/", 1)
    if kind == "claude":
        return os.path.join(claude_dir(), rel)
    if kind == "scratch":
        return os.path.join(dpath(scratch_base()), rel)
    raise Refused("unexpected member %s" % arc)


def _safe_arc(name):
    parts = name.split("/")
    if name.startswith("/") or ".." in parts or "" in parts or parts[0] not in ("claude", "scratch", "__fleet__"):
        raise Refused("unsafe member name in the state stream: %r" % name)
    return name


def _same(target, ent):
    if not os.path.lexists(target):
        return None
    if "link" in ent:
        return os.path.islink(target) and os.readlink(target) == ent["link"]
    return os.path.isfile(target) and not os.path.islink(target) and sha_file(target) == ent["sha"]


def _write_file(dst, src_path, mode, mtime):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = "%s.fleet-tmp-%d" % (dst, os.getpid())
    shutil.copyfile(src_path, tmp)
    os.chmod(tmp, mode & 0o7777)
    os.utime(tmp, (mtime, mtime))
    os.replace(tmp, dst)


def _place(dst, staged, ent):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if "link" in ent:
        os.symlink(ent["link"], dst)
        return
    try:
        os.rename(staged, dst)
    except OSError:
        _write_file(dst, staged, ent["mode"], ent["mtime"])


def merge_lines(dst, src_path, dry):
    """Rule 9: append source lines the destination lacks, one O_APPEND write each; never rewrite."""
    have = set()
    tail_nl = True
    if os.path.isfile(dst):
        with open(dst, "rb") as fh:
            data = fh.read()
        have = set(l for l in data.split(b"\n") if l)
        tail_nl = (not data) or data.endswith(b"\n")
    add = []
    with open(src_path, "rb") as fh:
        for l in fh.read().split(b"\n"):
            if l and l not in have:
                have.add(l)
                add.append(l)
    if dry or not add:
        return len(add)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    fd = os.open(dst, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        if not tail_nl:
            os.write(fd, b"\n")
        for l in add:
            os.write(fd, l + b"\n")
    finally:
        os.close(fd)
    return len(add)


def merge_file(dst, staged, ent, host, ts, written, dry):
    """Rule 8: absent -> copy; identical -> skip; dest is what the fleet last wrote -> overwrite with
    source; else keep dest and put the source beside it as .from-<host> (resumework:797-804:
    then .from-<host>-<ts> when that exists and differs)."""
    if not os.path.lexists(dst):
        if not dry:
            _write_file(dst, staged, ent["mode"], ent["mtime"])
            written[dst] = ent["sha"]
        return "copied"
    if os.path.isfile(dst) and not os.path.islink(dst):
        cur = sha_file(dst)
        if cur == ent["sha"]:
            if not dry:
                written[dst] = cur
            return "same"
        if written.get(dst) == cur:
            if not dry:
                _write_file(dst, staged, ent["mode"], ent["mtime"])
                written[dst] = ent["sha"]
            return "updated"
    alt = "%s.from-%s" % (dst, host)
    if os.path.isfile(alt) and not os.path.islink(alt) and sha_file(alt) == ent["sha"]:
        return "beside"
    if os.path.lexists(alt):
        alt = "%s.from-%s-%s" % (dst, host, ts)
        if os.path.isfile(alt) and sha_file(alt) == ent["sha"]:
            return "beside"
    if not dry:
        _write_file(alt, staged, ent["mode"], ent["mtime"])
        written[alt] = ent["sha"]
    return "beside"


def cmd_place_state(a):
    host = re.sub(r"[^A-Za-z0-9._-]", "-", a.host) or "other-mac"
    ts = a.ts
    if not re.match(r"^[0-9TZ-]+$", ts):
        raise Refused("bad --ts")
    stage = os.path.join(claude_dir(), "fleet-staging", ts)
    if not a.dry_run:
        guard_write(stage)
        if os.path.lexists(stage):
            shutil.rmtree(stage)
        os.makedirs(stage, mode=0o700)
    got, manifest = {}, None
    tf = tarfile.open(fileobj=sys.stdin.buffer, mode="r|")
    for m in tf:
        name = _safe_arc(m.name)
        if name == "__fleet__/manifest.json":
            manifest = json.loads(tf.extractfile(m).read().decode())
            continue
        if m.issym():
            got[name] = {"link": m.linkname}
            continue
        if not m.isreg():
            raise Refused("unexpected member type in the state stream: %s" % name)
        src = tf.extractfile(m)
        h = hashlib.sha256()
        if a.dry_run:
            for chunk in iter(lambda: src.read(1 << 20), b""):
                h.update(chunk)
        else:
            out = os.path.join(stage, name)
            p = stage
            for comp in name.split("/")[:-1]:
                p = os.path.join(p, comp)
                if os.path.islink(p):
                    raise Refused("state stream tried to write through a link: %s" % name)
                if not os.path.isdir(p):
                    os.mkdir(p, 0o700)
            with open(out, "wb") as fh:
                for chunk in iter(lambda: src.read(1 << 20), b""):
                    h.update(chunk)
                    fh.write(chunk)
        got[name] = {"sha": h.hexdigest(), "size": m.size}
    tf.close()
    if manifest is None:
        raise Refused("state stream has no manifest (truncated?)")
    ents = manifest["members"]
    for e in ents:
        g = got.get(e["arc"])
        if g is None or ("link" in e) != ("link" in g) or g.get("sha") != e.get("sha") or g.get("link") != e.get("link"):
            if not a.dry_run:
                shutil.rmtree(stage, ignore_errors=True)
            raise Refused("state member failed its checksum or is missing: %s" % phash("state", e["arc"]))
    # Rule 10: decide everything before touching anything.
    conflicts, place, skip = [], [], 0
    for e in ents:
        if e["kind"] not in ("state", "scratch"):
            continue
        t = state_target(e["arc"])
        s = _same(t, e)
        if s is None:
            place.append((e, t))
        elif s:
            skip += 1
        else:
            conflicts.append(e)
    summary = {"members": len(ents), "placed": 0, "would_place": len(place), "same": skip,
               "conflicts": [{"sid": e["sid"][:8], "path": phash("state", e["arc"])} for e in conflicts],
               "merge": {}, "appended_lines": 0, "dry_run": a.dry_run}
    if conflicts:
        if not a.dry_run:
            shutil.rmtree(stage, ignore_errors=True)
        json.dump(summary, sys.stdout, indent=1, sort_keys=True)
        print()
        raise Refused("%d chat file(s) already exist on this Mac with different content; nothing was placed" % len(conflicts))
    wpath = os.path.join(logdir(create=not a.dry_run), "fleet-written.json")
    written = load_json(wpath, {}) or {}
    for e in ents:
        if e["kind"] == "merge":
            r = merge_file(state_target(e["arc"]), os.path.join(stage, e["arc"]), e, host, ts, written, a.dry_run)
            summary["merge"][r] = summary["merge"].get(r, 0) + 1
        elif e["kind"] == "append":
            if a.dry_run:
                continue
            summary["appended_lines"] += merge_lines(state_target(e["arc"]), os.path.join(stage, e["arc"]), False)
    if not a.dry_run:
        for e, t in place:
            _place(t, os.path.join(stage, e["arc"]), e)
            summary["placed"] += 1
        write_json_atomic(wpath, written)
        shutil.rmtree(stage, ignore_errors=True)
    json.dump(summary, sys.stdout, indent=1, sort_keys=True)
    print()


def cmd_state_digest(a):
    plan = read_stdin_json()
    out = []
    for kind, arc, path, sid in collect_state(plan):
        e = {"arc": arc, "kind": kind, "sid": sid}
        if os.path.islink(path):
            e["link"] = os.readlink(path)
        elif kind == "append":
            with open(path, "rb") as fh:
                e["lines"] = sorted(set(sha_bytes(l)[:20] for l in fh.read().split(b"\n") if l))
        else:
            e["sha"] = sha_file(path)
        out.append(e)
    json.dump({"format": 1, "host": socket.gethostname().split(".")[0], "members": out}, sys.stdout)


def cmd_state_check(a):
    d = read_stdin_json()
    host = re.sub(r"[^A-Za-z0-9._-]", "-", d.get("host") or "") or "other-mac"
    mism, ok = [], 0
    for e in d["members"]:
        t = state_target(e["arc"])
        if e["kind"] == "append":
            have = set()
            if os.path.isfile(t):
                with open(t, "rb") as fh:
                    have = set(sha_bytes(l)[:20] for l in fh.read().split(b"\n") if l)
            missing = [x for x in e["lines"] if x not in have]
            if missing:
                mism.append({"root": "state", "kind": "lines-missing(%d)" % len(missing), "path": phash("state", e["arc"])})
            else:
                ok += 1
            continue
        s = _same(t, e)
        if not s and e["kind"] == "merge":
            alts = [t + ".from-" + host] + sorted(glob.glob(glob.escape(t + ".from-" + host + "-") + "*"))
            s = any(_same(x, e) for x in alts)
        if s:
            ok += 1
        else:
            mism.append({"root": "state", "kind": "state-" + ("missing" if s is None else "different"),
                         "path": phash("state", e["arc"]), "sid": e.get("sid", "")[:8]})
    json.dump({"format": 1, "kind": "verify-state", "at": now_iso(), "ok": ok, "mismatches": mism}, sys.stdout,
              indent=1, sort_keys=True)


# ---------------------------------------------------------------------------------------------
# Destination gate, fingerprints, landing (rules 6, 7, 15)
# ---------------------------------------------------------------------------------------------
def fingerprint(root, excl):
    """Stat-level fingerprint of a root on this Mac (no content hashing): any edit, add, delete or
    chmod changes it. .git/index is left out (a plain `git status` refreshes it)."""
    h = hashlib.sha256()
    n = 0
    for rel, full, st in Walk(root, dpath(root), excl).entries():
        parts = rel.split("/")
        if parts[-1] == ".DS_Store" or _git_internal_skip(parts):
            continue
        link = os.readlink(full) if stat.S_ISLNK(st.st_mode) else ""
        size = st.st_size if stat.S_ISREG(st.st_mode) else 0
        mt = st.st_mtime_ns if not stat.S_ISDIR(st.st_mode) else 0
        h.update(("%s\0%o\0%d\0%d\0%s\n" % (rel, st.st_mode, size, mt, link)).encode("utf-8", "surrogateescape"))
        n += 1
    return "%d:%s" % (n, h.hexdigest())


def landed_path():
    return os.path.join(logdir(create=False), "landed.json")


def _root_key(root):
    return hashlib.sha256(root.encode()).hexdigest()[:16]


def cmd_dest_gate(a):
    plan = read_stdin_json()
    refusals, warnings = [], []
    if plan.get("lib_sha") != sha_file(SELF):
        refusals.append("this Mac's fleet_lib.py differs from the source Mac's: pull the dotfiles here first")
    aliases = alias_homes()
    pre = os.environ.get("FLEET_TEST_DEST_PREFIX", "") if DEV else ""
    for r in plan.get("roots", []):
        root = r["path"]
        p = pre or "/"
        for comp in [c for c in root.split("/") if c]:
            p = os.path.join(p, comp)
            if os.path.islink(p):
                refusals.append("on this Mac %s is a symlink; copying %s through it is refused" % (p[len(pre):] or p, root))
                break
            if not os.path.lexists(p):
                break
        under = [h for h in aliases if inside(root, h) and root != h]
        if not under:
            refusals.append("%s is not inside a verified home alias on this Mac: run "
                            "sudo ~/.claude-dotfiles/scripts/transfer/make-home-alias.sh %s"
                            % (root, root.split("/")[2] if root.startswith("/Users/") and len(root.split("/")) > 2 else "<name>"))
    landed = load_json(landed_path(), None)
    landed_sids, landed_roots = [], []
    if isinstance(landed, dict):
        for sid, info in sorted((landed.get("sids") or {}).items()):
            landed_sids.append(sid)
            why = appended_mutations(os.path.join(claude_dir(), info["transcript_rel"]), info["bytes"], info["prefix_sha"])
            if why:
                refusals.append("landed chat %s: %s; a re-copy could overwrite that work, so stop and decide" % (sid[:8], why))
        roots_now = dict((r["path"], r) for r in plan.get("roots", []))
        for root, info in sorted((landed.get("roots") or {}).items()):
            landed_roots.append(root)
            if root not in roots_now:
                continue
            ef = os.path.join(logdir(create=False), "landed-excludes", _root_key(root) + ".json")
            excl = load_json(ef, None)
            if excl is None:
                refusals.append("landed root %s has no saved exclude list on this Mac" % root)
                continue
            if fingerprint(root, excl) != info["fp"]:
                refusals.append("files under %s changed on THIS Mac since it landed; a re-copy would overwrite "
                                "them (rule 7): find out what changed before running final" % root)
    try:
        sv = os.statvfs(home())
        free = sv.f_bavail * sv.f_frsize
    except OSError:
        free = -1
    json.dump({"refusals": refusals, "warnings": warnings, "landed_sids": landed_sids,
               "landed_roots": landed_roots, "free_bytes": free, "alias_homes": aliases}, sys.stdout, indent=1)


def cmd_land_dest(a):
    req = read_stdin_json()
    ld = logdir()
    landed = load_json(landed_path(), None) or {"format": 1, "sids": {}, "roots": {}}
    prog = os.path.join(claude_dir(), "progress")
    out = {"sids": {}, "roots": {}}
    for s in req.get("sids", []):
        rel = s["transcript_rel"]
        p = os.path.join(claude_dir(), rel)
        if not os.path.isfile(p):
            raise Refused("chat %s has no transcript on this Mac (%s): run final first" % (s["sid"][:8], phash("state", rel)))
    for s in req.get("sids", []):
        p = os.path.join(claude_dir(), s["transcript_rel"])
        with open(p, "rb") as fh:
            data = fh.read()
        info = {"transcript_rel": s["transcript_rel"], "bytes": len(data), "prefix_sha": sha_bytes(data),
                "sha": sha_bytes(data), "landed_at": now_iso(), "run": req.get("run", "")}
        out["sids"][s["sid"]] = info
        if not a.dry_run:
            landed["sids"][s["sid"]] = info
            os.makedirs(prog, exist_ok=True)
            f = os.path.join(prog, "transfer-arrived-" + s["sid"])
            fd = os.open(f, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.close(fd)
            try:
                os.unlink(os.path.join(prog, "transferred-" + s["sid"]))
            except OSError:
                pass
    for r in req.get("roots", []):
        fp = fingerprint(r["path"], r["excludes"])
        out["roots"][r["path"]] = fp
        if not a.dry_run:
            landed["roots"][r["path"]] = {"fp": fp, "landed_at": now_iso(), "run": req.get("run", "")}
            write_json_atomic(os.path.join(ld, "landed-excludes", _root_key(r["path"]) + ".json"), r["excludes"])
    if not a.dry_run:
        write_json_atomic(landed_path(), landed)
    json.dump(out, sys.stdout, indent=1, sort_keys=True)


def cmd_rollback_dest(a):
    landed = load_json(landed_path(), None) or {}
    info = (landed.get("sids") or {}).get(a.sid)
    if not info:
        raise Refused("chat %s is not recorded as landed on this Mac" % a.sid[:8])
    p = os.path.join(claude_dir(), info["transcript_rel"])
    cur = sha_file(p) if os.path.isfile(p) else ""
    if cur != info["sha"] or (a.expect and a.expect != info["sha"]):
        raise Refused("chat %s was used on this Mac after it landed (its transcript changed): rolling back "
                      "would lose that; continue it here instead" % a.sid[:8])
    if not a.dry_run:
        del landed["sids"][a.sid]
        write_json_atomic(landed_path(), landed)
        prog = os.path.join(claude_dir(), "progress")
        try:
            os.unlink(os.path.join(prog, "transfer-arrived-" + a.sid))
        except OSError:
            pass
        with open(os.path.join(prog, "transferred-" + a.sid), "w") as fh:
            fh.write("sid=%s\ntool=claude\nvia=fleet-rollback\nrolled_back_at=%s\n" % (a.sid, now_iso()))
        os.chmod(os.path.join(prog, "transferred-" + a.sid), 0o600)
    print("ok")


def cmd_write_receipt(a):
    if not re.match(r"^[A-Za-z0-9._-]+$", a.name):
        raise Refused("bad receipt name")
    body = sys.stdin.read()
    p = os.path.join(logdir(), "receipts", a.name)
    guard_write(p)
    os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
    with open(p, "w") as fh:
        fh.write(body)
    os.chmod(p, 0o600)
    print(p)


def cmd_write_stream(a):
    if not re.match(r"^fleet-backup-[0-9TZ-]+/[A-Za-z0-9._-]+$", a.path):
        raise Refused("write-stream only writes ~/fleet-backup-<ts>/<name>")
    p = os.path.join(home(), a.path)
    guard_write(p)
    if os.path.lexists(p):
        raise Refused("%s already exists" % a.path)
    os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
    h, n = hashlib.sha256(), 0
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as fh:
        for chunk in iter(lambda: sys.stdin.buffer.read(1 << 20), b""):
            h.update(chunk)
            n += len(chunk)
            fh.write(chunk)
        fh.flush()
        os.fsync(fh.fileno())
    print("%d %s" % (n, h.hexdigest()))


def cmd_tar_roots(a):
    plan = read_stdin_json()
    h = hashlib.sha256()
    n = [0]

    class Tee(object):
        def write(self, b):
            h.update(b)
            n[0] += len(b)
            return sys.stdout.buffer.write(b)

        def flush(self):
            sys.stdout.buffer.flush()
    tf = tarfile.open(fileobj=Tee(), mode="w|", format=tarfile.PAX_FORMAT)
    for r in plan.get("roots", []):
        for rel, full, st in Walk(r["path"], r["path"], r.get("excludes", [])).entries():
            if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode) or stat.S_ISLNK(st.st_mode)):
                continue
            arc = (full if rel != "." else r["path"]).lstrip("/")
            try:
                tf.add(full, arcname=arc, recursive=False)
            except OSError as e:
                sys.stderr.write("fleet: WARN: could not read %s (%s)\n" % (phash(r["path"], rel), e.__class__.__name__))
    tf.close()
    sys.stdout.buffer.flush()
    if a.sha_out:
        with open(a.sha_out, "w") as fh:
            fh.write("%d %s\n" % (n[0], h.hexdigest()))


# ---------------------------------------------------------------------------------------------
# Tool parity (rule 14) and dest-setup
# ---------------------------------------------------------------------------------------------
TOOLS = ("claude", "codex", "gh", "gcloud", "op", "node", "npm", "rsync", "docker", "runpane")


def tool_path():
    extra = [os.path.join(home(), ".local", "bin"), "/opt/homebrew/bin", "/usr/local/bin",
             os.path.join(home(), ".npm-global", "bin")]
    try:
        r = subprocess.run(["/bin/zsh", "-lc", 'printf %s "$PATH"'], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, universal_newlines=True, timeout=20)
        login = r.stdout.strip().split(":") if r.returncode == 0 else []
    except Exception:
        login = []
    parts = []
    for p in login + extra + os.environ.get("PATH", "").split(":"):
        if p and p not in parts:
            parts.append(p)
    return ":".join(parts)


def run_tool(args, path, t=20):
    env = dict(os.environ)
    env["PATH"] = path
    try:
        r = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
                           universal_newlines=True, timeout=t)
        return r.returncode, (r.stdout.strip().splitlines() or [""])[0][:120]
    except Exception as e:
        return 127, e.__class__.__name__


def tool_report():
    path = tool_path()
    tools = {}
    for t in TOOLS:
        p = shutil.which(t, path=path)
        if not p:
            tools[t] = None
            continue
        rc, v = run_tool([p, "--version"], path)
        tools[t] = {"path": p, "version": v if rc == 0 else ""}
    rep = {"host": socket.gethostname().split(".")[0], "home": home(), "uid": os.getuid(),
           "alias_homes": alias_homes(), "tools": tools, "lib_sha": sha_file(SELF),
           "dotfiles_head": git_out(os.path.join(home(), ".claude-dotfiles"), "rev-parse", "HEAD"),
           "python": sys.version.split()[0]}
    if tools.get("codex"):
        rc, line = run_tool([tools["codex"]["path"], "login", "status"], path)
        rep["codex_login"] = "logged in" if rc == 0 else "not logged in"
    if tools.get("gh"):
        rc, _ = run_tool([tools["gh"]["path"], "auth", "status"], path)
        rep["gh_auth"] = "logged in" if rc == 0 else "not logged in"
    rep["git_user_name"] = git_out(home(), "config", "--global", "user.name")
    rep["git_user_email"] = git_out(home(), "config", "--global", "user.email")
    cj = load_json(os.path.join(home(), ".claude.json"), {}) or {}
    rep["mcp_servers"] = sorted((cj.get("mcpServers") or {}).keys())
    rep["credentials_md"] = os.path.isfile(os.path.join(home(), ".config", "claude", "credentials.md"))
    rep["docker"] = {"shim": os.path.exists(os.path.join(home(), ".local", "bin", "docker")),
                     "docker_host_env": bool(os.environ.get("DOCKER_HOST"))}
    try:
        sv = os.statvfs(home())
        rep["free_bytes"] = sv.f_bavail * sv.f_frsize
    except OSError:
        rep["free_bytes"] = -1
    return rep


def cmd_dest_check(a):
    json.dump(tool_report(), sys.stdout, indent=1, sort_keys=True)


CHAT_TOOL_RE = re.compile(r"(?:^|[\s;&|(`$])(codex|gh|gcloud|op|node|npm|docker|runpane)(?=\s|$)")


def chat_tools(transcript):
    used = set()
    try:
        with open(transcript, "rb") as fh:
            for line in fh:
                if b'"tool_use"' not in line or b'"Bash"' not in line:
                    continue
                try:
                    j = json.loads(line)
                except ValueError:
                    continue
                for t in tool_uses(j):
                    cmd = (t.get("input") or {}).get("command") if isinstance(t.get("input"), dict) else None
                    if isinstance(cmd, str):
                        used.update(CHAT_TOOL_RE.findall(cmd))
    except OSError:
        pass
    return sorted(used)


def cmd_dest_compare(a):
    src, dst = load_json(a.source, {}), load_json(a.dest_report, {})
    inv = load_json(a.fleet_json, {}) or {}
    st, dt = src.get("tools", {}), dst.get("tools", {})
    print("Destination %s (home %s)" % (dst.get("host"), dst.get("home")))
    print("  fleet_lib.py: %s" % ("same version" if src.get("lib_sha") == dst.get("lib_sha") else
                                  "DIFFERENT - pull the dotfiles there before final"))
    print("  dotfiles HEAD: here %s, there %s%s" % ((src.get("dotfiles_head") or "?")[:8], (dst.get("dotfiles_head") or "?")[:8],
          "" if src.get("dotfiles_head") == dst.get("dotfiles_head") else "  (differ)"))
    print("  free space there: %.1f GB" % (max(dst.get("free_bytes", 0), 0) / 1e9))
    missing = sorted(t for t in TOOLS if st.get(t) and not dt.get(t))
    for t in TOOLS:
        print("  %-8s here: %-4s there: %s" % (t, "yes" if st.get(t) else "no",
              (dt[t]["version"] or "yes") if dt.get(t) else "MISSING"))
    for k in ("codex_login", "gh_auth"):
        if k in src or k in dst:
            print("  %-12s here: %s, there: %s" % (k, src.get(k, "-"), dst.get(k, "-")))
    print("  git identity there: %s" % ("set" if dst.get("git_user_email") else "NOT SET"))
    mcp = sorted(set(src.get("mcp_servers", [])) - set(dst.get("mcp_servers", [])))
    print("  MCP servers missing there: %s" % (", ".join(mcp) or "none"))
    print("  credentials.md there: %s" % ("yes" if dst.get("credentials_md") else "no"))
    print("  docker routing shim there: %s" % ("yes" if (dst.get("docker") or {}).get("shim") else "no"))
    need = set([src.get("home")] + list(inv.get("alias_homes", [])))
    have = set(dst.get("alias_homes", []))
    for h in sorted(x for x in need if x and x not in have):
        print("  ALIAS MISSING there: %s  -> sudo ~/.claude-dotfiles/scripts/transfer/make-home-alias.sh %s" % (h, os.path.basename(h)))
    print("Per chat (tools its history uses that the destination lacks):")
    for s in inv.get("sessions", []):
        lack = [t for t in chat_tools(s.get("transcript") or "") if t in missing]
        print("  %s  %-30s %s" % (s["sid"][:8], (s.get("name") or "-")[:30], ", ".join(lack) or "nothing missing"))


def _rewrite(obj, src_home, dst_home):
    if isinstance(obj, str):
        return re.sub(re.escape(src_home) + r"(?=/|$)", dst_home, obj)
    if isinstance(obj, list):
        return [_rewrite(x, src_home, dst_home) for x in obj]
    if isinstance(obj, dict):
        return dict((k, _rewrite(v, src_home, dst_home)) for k, v in obj.items())
    return obj


PROJECT_KEYS = ("hasTrustDialogAccepted", "hasCompletedProjectOnboarding", "allowedTools", "mcpServers",
                "enabledMcpjsonServers", "disabledMcpjsonServers", "hasClaudeMdExternalIncludesApproved",
                "hasClaudeMdExternalIncludesWarningShown")


def cmd_setup_payload(a):
    inv = load_json(a.fleet_json, {}) or {}
    sp = os.path.join(claude_dir(), "settings.json")
    with open(sp) as fh:
        settings = fh.read()
    cj = load_json(os.path.join(home(), ".claude.json"), {}) or {}
    paths = set(s.get("cwd") for s in inv.get("sessions", []) if s.get("cwd"))
    paths |= set(r["path"] for r in inv.get("roots", []))
    projects = {}
    for k, v in (cj.get("projects") or {}).items():
        if k in paths and isinstance(v, dict):
            projects[k] = dict((x, v[x]) for x in PROJECT_KEYS if x in v)
    json.dump({"format": 1, "src_home": home(), "settings": settings, "mcpServers": cj.get("mcpServers") or {},
               "projects": projects, "git_user_name": git_out(home(), "config", "--global", "user.name"),
               "git_user_email": git_out(home(), "config", "--global", "user.email")}, sys.stdout)


SECRETISH = re.compile(r"(token|secret|password|api[_-]?key|auth)", re.I)


def cmd_dest_setup(a):
    pay = read_stdin_json()
    ts = a.ts
    src_home, dst_home = pay["src_home"], home()
    sp = os.path.join(claude_dir(), "settings.json")
    cur = open(sp).read() if os.path.isfile(sp) else ""
    new = re.sub(re.escape(src_home) + r"(?=/|\"|$)", dst_home, pay["settings"])
    json.loads(new)
    print("== settings.json (%s -> %s rewritten; other paths kept literally) ==" % (src_home, dst_home))
    diff = list(difflib.unified_diff(cur.splitlines(), new.splitlines(), "settings.json (now)", "settings.json (new)", lineterm=""))
    for line in diff:
        print(line if not SECRETISH.search(line) else line.split(":", 1)[0] + ": <redacted>")
    if not diff:
        print("(no change)")
    cjp = os.path.join(home(), ".claude.json")
    cj = load_json(cjp, {}) or {}
    have = cj.get("mcpServers") or {}
    add_mcp = dict((k, _rewrite(v, src_home, dst_home)) for k, v in pay["mcpServers"].items() if k not in have)
    projects = cj.get("projects") or {}
    add_proj, trust = [], []
    for k, v in pay["projects"].items():
        if k not in projects:
            add_proj.append(k)
        elif v.get("hasTrustDialogAccepted") and not projects[k].get("hasTrustDialogAccepted"):
            trust.append(k)
    print("== ~/.claude.json ==")
    print("  MCP servers to add: %s" % (", ".join(sorted(add_mcp)) or "none"))
    print("  project entries to add: %d; trust to set on existing: %d" % (len(add_proj), len(trust)))
    gi = []
    for key, val in (("user.name", pay.get("git_user_name")), ("user.email", pay.get("git_user_email"))):
        if val and git_out(home(), "config", "--global", key) != val:
            gi.append((key, val))
    print("== git identity ==")
    for key, val in gi:
        print("  %s -> %s" % (key, val))
    if not gi:
        print("  (no change)")
    path = tool_path()
    inst = [p for t, p in (("codex", "@openai/codex"), ("runpane", "runpane")) if not shutil.which(t, path=path)]
    print("== installs == %s" % (" ".join("npm i -g " + p for p in inst) or "(none needed)"))
    if not a.apply:
        print("Dry run: nothing written. Re-run with --apply after the owner approves this diff.")
        return
    for p in (sp, cjp):
        if os.path.islink(p):
            raise Refused("%s is a symlink; not writing through it" % p)
        guard_write(p)
    if diff:
        if os.path.isfile(sp):
            shutil.copy2(sp, sp + ".bak-" + ts)
        tmp = sp + ".fleet-tmp"
        with open(tmp, "w") as fh:
            fh.write(new)
        os.replace(tmp, sp)
    if add_mcp or add_proj or trust:
        if os.path.isfile(cjp):
            shutil.copy2(cjp, cjp + ".bak-" + ts)
        cj = load_json(cjp, {}) or {}       # re-read: a running chat may have written it meanwhile
        cj.setdefault("mcpServers", {})
        for k, v in add_mcp.items():
            cj["mcpServers"].setdefault(k, v)
        pj = cj.setdefault("projects", {})
        for k in add_proj:
            pj.setdefault(k, pay["projects"][k])
        for k in trust:
            if k in pj:
                pj[k]["hasTrustDialogAccepted"] = True
        mode = stat.S_IMODE(os.stat(cjp).st_mode) if os.path.isfile(cjp) else 0o600
        tmp = cjp + ".fleet-tmp"
        with open(tmp, "w") as fh:
            json.dump(cj, fh, indent=2)
        os.chmod(tmp, mode)
        os.replace(tmp, cjp)
    for key, val in gi:
        subprocess.run(["git", "config", "--global", key, val], env=git_env())
    npm = shutil.which("npm", path=path)
    for p in inst:
        if npm:
            rc, line = run_tool([npm, "i", "-g", p], path, t=900)
            print("  npm i -g %s -> rc %d" % (p, rc))
        else:
            print("  npm missing: install node first, then npm i -g %s" % p)
    print("Applied (backups: *.bak-%s)." % ts)


def cmd_npm_ci(a):
    dirs = read_stdin_json()
    path = tool_path()
    npm = shutil.which("npm", path=path)
    for d in dirs:
        dd = dpath(d)
        if os.path.isdir(os.path.join(dd, "node_modules")):
            print("SKIP (node_modules already there) %s" % d)
            continue
        if not os.path.isfile(os.path.join(dd, "package-lock.json")):
            print("SKIP (no package-lock.json yet) %s" % d)
            continue
        if a.dry_run or not npm:
            print("%s npm ci --legacy-peer-deps in %s" % ("WOULD RUN" if npm else "NPM MISSING:", d))
            continue
        env = dict(os.environ)
        env["PATH"] = path
        r = subprocess.run([npm, "ci", "--legacy-peer-deps"], cwd=dd, env=env, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, universal_newlines=True)
        print("%s npm ci in %s%s" % ("OK" if r.returncode == 0 else "FAILED", d,
              "" if r.returncode == 0 else ": " + (r.stderr.strip().splitlines() or [""])[-1][:160]))


def cmd_npm_dirs(a):
    """Rule 18: each chat's launch worktree, folders (depth <= 3) that have node_modules + package-lock."""
    plan = load_json(a.plan, {}) or {}
    out = []
    for s in plan.get("sids", []):
        cwd = s.get("cwd") or ""
        top = git_out(cwd, "rev-parse", "--show-toplevel") if cwd and os.path.isdir(cwd) else ""
        if not top:
            continue
        top = os.path.realpath(top)
        for dp, dn, fn in os.walk(top):
            depth = 0 if dp == top else dp[len(top) + 1:].count("/") + 1
            if "node_modules" in dn and "package-lock.json" in fn and dp not in out:
                out.append(dp)
            dn[:] = [n for n in dn if depth < 3 and n not in HEAVY and n != ".git" and not os.path.islink(os.path.join(dp, n))]
    json.dump(sorted(out), sys.stdout)


def cmd_guard_path(a):
    guard_write(a.path)


def cmd_self_sha(a):
    print(sha_file(SELF))


def main():
    ap = argparse.ArgumentParser(prog="fleet_lib.py")
    sub = ap.add_subparsers(dest="cmd")

    def sp(name, fn):
        p = sub.add_parser(name)
        p.set_defaults(fn=fn)
        return p
    sp("self-sha", cmd_self_sha)
    sp("guard-path", cmd_guard_path).add_argument("path")
    sp("inventory", cmd_inventory).add_argument("--out")
    p = sp("plan", cmd_plan)
    p.add_argument("--mode", required=True, choices=("seed", "backup", "final", "verify", "land"))
    p.add_argument("--run-dir", required=True)
    p.add_argument("--fleet-json", required=True)
    p.add_argument("--only", default="")
    p.add_argument("--dry-run", action="store_true")
    sp("excludes", cmd_excludes).add_argument("root")
    p = sp("manifest", cmd_manifest)
    p.add_argument("--fsck", action="store_true")
    p.add_argument("--dest", action="store_true")
    p = sp("compare", cmd_compare)
    p.add_argument("source")
    p.add_argument("dest_manifest")
    p.add_argument("--plan")
    sp("pack-state", cmd_pack_state)
    sp("state-digest", cmd_state_digest)
    sp("state-check", cmd_state_check)
    p = sp("place-state", cmd_place_state)
    p.add_argument("--ts", required=True)
    p.add_argument("--host", required=True)
    p.add_argument("--dry-run", action="store_true")
    p = sp("tar-roots", cmd_tar_roots)
    p.add_argument("--sha-out")
    sp("dest-check", cmd_dest_check).add_argument("--local", action="store_true")
    p = sp("dest-compare", cmd_dest_compare)
    p.add_argument("source")
    p.add_argument("dest_report")
    p.add_argument("--fleet-json", required=True)
    sp("dest-gate", cmd_dest_gate)
    sp("land-dest", cmd_land_dest).add_argument("--dry-run", action="store_true")
    p = sp("rollback-dest", cmd_rollback_dest)
    p.add_argument("--sid", required=True)
    p.add_argument("--expect", default="")
    p.add_argument("--dry-run", action="store_true")
    sp("write-receipt", cmd_write_receipt).add_argument("--name", required=True)
    sp("write-stream", cmd_write_stream).add_argument("--path", required=True)
    sp("setup-payload", cmd_setup_payload).add_argument("--fleet-json", required=True)
    p = sp("dest-setup", cmd_dest_setup)
    p.add_argument("--apply", action="store_true")
    p.add_argument("--ts", required=True)
    sp("npm-ci", cmd_npm_ci).add_argument("--dry-run", action="store_true")
    sp("npm-dirs", cmd_npm_dirs).add_argument("--plan", required=True)
    p = sp("resolve-only", cmd_resolve_only)
    p.add_argument("tokens")
    p.add_argument("--fleet-json", required=True)
    a = ap.parse_args()
    if not getattr(a, "fn", None):
        ap.print_help()
        sys.exit(1)
    try:
        a.fn(a)
    except Refused as e:
        sys.stderr.write("fleet: REFUSED: %s\n" % e)
        sys.exit(2)
    except BrokenPipeError:
        sys.exit(1)


if __name__ == "__main__":
    main()
