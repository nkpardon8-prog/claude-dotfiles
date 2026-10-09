#!/usr/bin/env python3
"""Read-only inventory of every worktree of WT_ROOT -> TSV + JSON. Touches nothing."""
# Settings come from the environment so one copy serves any repo (see commands/worktree-cleanup.md):
#   WT_ROOT    main checkout of the repo (required)
#   WT_BASE    branch whose history counts as "merged" (default origin/dev, then origin/main)
#   WT_OUT     run folder holding inventory/plan/keep lists/actions.log (default: this script's cwd)
#   WT_ARCHIVE where untracked/ignored files of removed worktrees are copied (default <ROOT>/tmp/worktree-archive-<date>)
import json, os, subprocess, sys, time, glob
ROOT = os.environ["WT_ROOT"].rstrip("/")
OUT = os.environ.get("WT_OUT") or os.getcwd()
BASE = os.environ.get("WT_BASE") or ("origin/dev" if subprocess.run(["git","-C",ROOT,"rev-parse","-q","--verify","origin/dev"],capture_output=True).returncode == 0 else "origin/main")
now = time.time()

def git(*a, cwd=ROOT):
    r = subprocess.run(["git", "-C", cwd, *a], capture_output=True, text=True)
    return r.returncode, r.stdout.strip()

# live users: every process's cwd (lsof), plus Claude session registry cwds of live pids
live = {}
r = subprocess.run(["lsof", "-a", "-d", "cwd", "-Fpcn"], capture_output=True, text=True)
pid = cmd = None
for line in r.stdout.splitlines():
    if line.startswith("p"): pid = line[1:]
    elif line.startswith("c"): cmd = line[1:]
    elif line.startswith("n"): live.setdefault(line[1:], []).append(f"{cmd}:{pid}")
reg = {}
for f in glob.glob(os.path.expanduser("~/.claude/sessions/*.json")):
    try:
        d = json.load(open(f)); p = int(d.get("pid", 0))
        os.kill(p, 0)
        reg.setdefault(d.get("cwd", ""), []).append(d.get("name") or d.get("sessionId", "")[:8])
    except Exception:
        pass

def users_of(path):
    u = []
    for c, who in list(live.items()) + [(c, w) for c, w in reg.items()]:
        if c == path or c.startswith(path + "/"):
            u += who
    return sorted(set(u))

def nm_dirs(p):
    """node_modules at the worktree root and one level down (monorepo packages)."""
    return [d for d in [os.path.join(p, "node_modules")] + glob.glob(os.path.join(p, "*", "node_modules"))
            if os.path.isdir(d) and not os.path.islink(d)]

def du_kb(p):
    if not os.path.exists(p): return 0
    r = subprocess.run(["du", "-sk", p], capture_output=True, text=True)
    try: return int(r.stdout.split()[0])
    except Exception: return 0

_, por = git("worktree", "list", "--porcelain")
wts, cur = [], {}
for line in por.splitlines() + [""]:
    if not line:
        if cur: wts.append(cur); cur = {}
        continue
    k, _, v = line.partition(" ")
    cur[k] = v or True

rows = []
for w in wts:
    p = w["worktree"]
    if p == ROOT: continue
    name = os.path.basename(p)
    branch = (w.get("branch") or "").replace("refs/heads/", "") or "(detached)"
    exists = os.path.isdir(p)
    row = {"name": name, "path": p, "branch": branch, "exists": exists}
    if exists:
        _, st = git("status", "--porcelain", cwd=p)
        lines = [l for l in st.splitlines() if l]
        row["tracked_changes"] = sum(1 for l in lines if not l.startswith("??"))
        row["untracked"] = sum(1 for l in lines if l.startswith("??"))
        rc, _ = git("merge-base", "--is-ancestor", "HEAD", BASE, cwd=p)
        row["in_dev"] = rc == 0
        rc, up = git("branch", "-r", "--contains", "HEAD", cwd=p)
        row["on_remote"] = bool(up.strip())
        _, ct = git("log", "-1", "--format=%ct", cwd=p)
        row["commit_days"] = round((now - int(ct or now)) / 86400, 1)
        # last activity = newest mtime among top-level entries + git index (cheap proxy)
        mt = [os.path.getmtime(p)]
        for e in os.scandir(p):
            if e.name != "node_modules":
                try: mt.append(e.stat(follow_symlinks=False).st_mtime)
                except Exception: pass
        idx = os.path.join(p, ".git")
        row["touched_days"] = round((now - max(mt)) / 86400, 1)
        nm = sum(du_kb(d) for d in nm_dirs(p))
        row["node_modules_gb"] = round(nm / 1048576, 2)
        row["total_gb"] = round(du_kb(p) / 1048576, 2)
        row["users"] = users_of(p)
    rows.append(row)

json.dump(rows, open(os.path.join(OUT, "inventory.json"), "w"), indent=1)
cols = ["name","branch","tracked_changes","untracked","in_dev","on_remote","commit_days","touched_days","node_modules_gb","total_gb","users"]
with open(os.path.join(OUT, "inventory.tsv"), "w") as f:
    f.write("\t".join(cols) + "\n")
    for r in rows:
        f.write("\t".join(str(r.get(c, "")) for c in cols) + "\n")
print(len(rows), "worktrees inventoried")
