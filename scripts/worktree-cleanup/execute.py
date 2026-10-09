#!/usr/bin/env python3
"""Carry out plan.tsv. Usage: execute.py [--dry-run] [--only NM_ONLY|REMOVE]
Per worktree, immediately before acting, re-checks: no live process has its cwd inside it, no Claude
session registry entry points into it, (REMOVE) no uncommitted tracked edits. REMOVE first archives
every untracked + ignored file (except build/package dirs) to ARCHIVE/<name>/, then
`git worktree remove --force`. Branches are never deleted. Every step is appended to actions.log."""
# Settings come from the environment so one copy serves any repo (see commands/worktree-cleanup.md):
#   WT_ROOT    main checkout of the repo (required)
#   WT_BASE    branch whose history counts as "merged" (default origin/dev, then origin/main)
#   WT_OUT     run folder holding inventory/plan/keep lists/actions.log (default: this script's cwd)
#   WT_ARCHIVE where untracked/ignored files of removed worktrees are copied (default <ROOT>/tmp/worktree-archive-<date>)
import glob, json, os, shutil, subprocess, sys, time
HERE = os.environ.get("WT_OUT") or os.getcwd()
ROOT = os.environ["WT_ROOT"].rstrip("/")
ARCHIVE = os.environ.get("WT_ARCHIVE") or os.path.join(ROOT, "tmp", "worktree-archive-" + time.strftime("%Y-%m-%d"))
DRY = "--dry-run" in sys.argv
ONLY = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
HEAVY = {"node_modules", "dist", "build", ".next", "coverage", ".turbo", ".vite", ".cache"}
inv = {r["name"]: r for r in json.load(open(os.path.join(HERE, "inventory.json")))}
log = open(os.path.join(HERE, "actions.log"), "a")
def L(msg):
    line = time.strftime("%H:%M:%S ") + ("[dry] " if DRY else "") + msg
    print(line); log.write(line + "\n"); log.flush()

def live_cwds():
    r = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fn"], capture_output=True, text=True)
    c = {l[1:] for l in r.stdout.splitlines() if l.startswith("n")}
    for f in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
        try:
            d = json.load(open(f)); os.kill(int(d["pid"]), 0); c.add(d.get("cwd", ""))
        except Exception: pass
    return c
def in_use(path, cwds):
    return [c for c in cwds if c == path or c.startswith(path + "/")]
def recently_edited(path):
    args = ["find", path, "(", "-name", "node_modules", "-o", "-name", ".git", "-o", "-name", "dist", "-o", "-name", "build", ")",
            "-prune", "-o", "-type", "f", "-mtime", "-3", "-print", "-quit"]
    return bool(subprocess.run(args, capture_output=True, text=True).stdout.strip())
def du_kb(p):
    r = subprocess.run(["du", "-sk", p], capture_output=True, text=True)
    try: return int(r.stdout.split()[0])
    except Exception: return 0

def archive(name, path):
    """Copy untracked + ignored files (minus HEAVY dirs) to ARCHIVE/name. Returns (files, kb)."""
    r = subprocess.run(["git", "-C", path, "ls-files", "-z", "--others", "--directory"], capture_output=True, text=True)
    r2 = subprocess.run(["git", "-C", path, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"], capture_output=True, text=True)
    entries = sorted(set(filter(None, (r.stdout + "\0" + r2.stdout).split("\0"))))
    n = kb = 0
    dest_root = os.path.join(ARCHIVE, name)
    for e in entries:
        parts = e.rstrip("/").split("/")
        if any(p in HEAVY for p in parts): continue
        src = os.path.join(path, e.rstrip("/"))
        if os.path.islink(src) or not os.path.exists(src): continue
        files = []
        if os.path.isdir(src):
            for dp, dns, fns in os.walk(src):
                dns[:] = [d for d in dns if d not in HEAVY]
                files += [os.path.join(dp, f) for f in fns]
        else:
            files = [src]
        for f in files:
            if os.path.islink(f): continue
            rel = os.path.relpath(f, path)
            n += 1; kb += os.path.getsize(f) // 1024
            if not DRY:
                d = os.path.join(dest_root, rel); os.makedirs(os.path.dirname(d), exist_ok=True)
                shutil.copy2(f, d)
    return n, kb

cwds = live_cwds()
freed = 0
count = 0
for line in open(os.path.join(HERE, "plan.tsv")).read().splitlines()[1:]:
    name, action, reason, _ = line.split("\t")
    count += 1
    if count % 10 == 0: cwds = live_cwds()
    if action not in ("NM_ONLY", "REMOVE") or (ONLY and action != ONLY): continue
    r = inv[name]; path = r["path"]
    if not os.path.isdir(path): L(f"SKIP {name}: folder gone"); continue
    u = in_use(path, cwds)
    if u: L(f"SKIP {name}: in use now ({u[0]})"); continue
    if recently_edited(path): L(f"SKIP {name}: a file changed in the last 3 days"); continue
    if action == "NM_ONLY":
        got = 0
        for nm in [os.path.join(path, "node_modules")] + glob.glob(os.path.join(path, "*", "node_modules")):
            if os.path.isdir(nm) and not os.path.islink(nm):
                if not DRY: shutil.rmtree(nm, ignore_errors=True)
        got = r["node_modules_gb"] * 1048576
        freed += got; L(f"NM_ONLY {name}: node_modules removed, ~{got/1048576:.2f} GB")
        continue
    # REMOVE
    st = subprocess.run(["git", "-C", path, "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True).stdout.strip()
    if st: L(f"SKIP {name}: uncommitted edits appeared"); continue
    size = r["total_gb"] * 1048576
    n, kb = archive(name, path)
    if not DRY:
        rr = subprocess.run(["git", "-C", ROOT, "worktree", "remove", "--force", path], capture_output=True, text=True)
        if rr.returncode != 0:
            L(f"FAIL {name}: git worktree remove: {rr.stderr.strip()[:200]}"); continue
    freed += size
    L(f"REMOVE {name} [{r['branch']}]: archived {n} files ({kb/1024:.1f} MB), freed {size/1048576:.2f} GB")
L(f"DONE {'(dry run) ' if DRY else ''}freed {freed/1048576:.1f} GB")
