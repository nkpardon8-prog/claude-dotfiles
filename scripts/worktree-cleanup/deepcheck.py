#!/usr/bin/env python3
"""Second pass: real last-activity per candidate = newest of (any file outside node_modules/build dirs,
the worktree's git index/HEAD log). Updates inventory.json touched_days in place. Read-only on worktrees."""
# Settings come from the environment so one copy serves any repo (see commands/worktree-cleanup.md):
#   WT_ROOT    main checkout of the repo (required)
#   WT_BASE    branch whose history counts as "merged" (default origin/dev, then origin/main)
#   WT_OUT     run folder holding inventory/plan/keep lists/actions.log (default: this script's cwd)
#   WT_ARCHIVE where untracked/ignored files of removed worktrees are copied (default <ROOT>/tmp/worktree-archive-<date>)
import json, os, subprocess, time
HERE = os.environ.get("WT_OUT") or os.getcwd()
ROOT = os.environ["WT_ROOT"].rstrip("/")
rows = json.load(open(os.path.join(HERE, "inventory.json")))
plan = {l.split("\t")[0]: l.split("\t")[1] for l in open(os.path.join(HERE, "plan.tsv")).read().splitlines()[1:]}
now = time.time()
PRUNE = ["node_modules", ".git", "dist", "build", ".next", "coverage", ".turbo", ".vite"]
def newest_within(path, days):
    args = ["find", path]
    for i, d in enumerate(PRUNE):
        args += (["-o"] if i else ["("]) + ["-name", d]
    args += [")", "-prune", "-o", "-type", "f", "-mtime", f"-{days}", "-print", "-quit"]
    r = subprocess.run(args, capture_output=True, text=True)
    return r.stdout.strip()
changed = 0
for r in rows:
    if plan.get(r["name"]) not in ("NM_ONLY", "REMOVE") or not r.get("exists"):
        continue
    gd = subprocess.run(["git", "-C", r["path"], "rev-parse", "--absolute-git-dir"], capture_output=True, text=True).stdout.strip()
    # HEAD moves on commit/checkout/reset. NOT index (any `git status`, incl. this inventory, rewrites
    # it) and NOT logs/HEAD (a repo-wide `git gc`/reflog expire rewrote every worktree's on 10-02).
    head_mt = os.path.getmtime(os.path.join(gd, "HEAD")) if os.path.exists(os.path.join(gd, "HEAD")) else 0
    top = [os.path.getmtime(r["path"])] + [e.stat(follow_symlinks=False).st_mtime for e in os.scandir(r["path"]) if e.name not in ("node_modules", ".git")]
    t = (now - max(top + [head_mt])) / 86400
    t = min(t, r.get("commit_days", t))
    if t >= 3 and newest_within(r["path"], 3):
        t = min(t, 2.9)
    elif t >= 7 and newest_within(r["path"], 7):
        t = min(t, 6.9)
    t = round(t, 1)
    if abs(t - r["touched_days"]) > 0.05:
        changed += 1
        print(f"{r['name']}: touched {r['touched_days']}d -> {t}d")
        r["touched_days"] = t
json.dump(rows, open(os.path.join(HERE, "inventory.json"), "w"), indent=1)
print("adjusted", changed)
