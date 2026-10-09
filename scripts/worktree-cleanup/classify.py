#!/usr/bin/env python3
"""Sort inventory.json into KEEP / NM_ONLY / REMOVE -> plan.tsv. Read-only."""
# Settings come from the environment so one copy serves any repo (see commands/worktree-cleanup.md):
#   WT_ROOT    main checkout of the repo (required)
#   WT_BASE    branch whose history counts as "merged" (default origin/dev, then origin/main)
#   WT_OUT     run folder holding inventory/plan/keep lists/actions.log (default: this script's cwd)
#   WT_ARCHIVE where untracked/ignored files of removed worktrees are copied (default <ROOT>/tmp/worktree-archive-<date>)
import fnmatch, json, os, subprocess
HERE = os.environ.get("WT_OUT") or os.getcwd()
rows = json.load(open(os.path.join(HERE, "inventory.json")))
def pats(f):
    p = os.path.join(HERE, f)
    return [l.split("#")[0].strip() for l in open(p) if l.split("#")[0].strip()] if os.path.exists(p) else []
KEEP, KEEP_WT = pats("keep.txt"), pats("keep-worktree-nm-ok.txt")
match = lambda n, ps: any(fnmatch.fnmatch(n, p) for p in ps)
def on_a_branch(path):
    r = subprocess.run(["git", "-C", path, "branch", "--contains", "HEAD"], capture_output=True, text=True)
    return bool(r.stdout.strip())
out = []
for r in rows:
    n = r["name"]
    if not r.get("exists"):
        out.append((n, "PRUNE", "folder already gone; registry entry only", 0)); continue
    nm, tot = r["node_modules_gb"], r["total_gb"]
    if match(n, KEEP):
        out.append((n, "KEEP", "on a keep list", 0)); continue
    if r["users"]:
        out.append((n, "KEEP", "in use now: " + ",".join(r["users"])[:60], 0)); continue
    if r["touched_days"] < 3:
        out.append((n, "KEEP", f"active {r['touched_days']}d ago", 0)); continue
    reason = []
    can_remove = not match(n, KEEP_WT)
    if not can_remove: reason.append("owner keeps worktree")
    if r["tracked_changes"]:
        can_remove = False; reason.append(f"{r['tracked_changes']} uncommitted edits")
    if not (r["in_dev"] or r["touched_days"] >= 7):
        can_remove = False; reason.append("not in dev and idle <7d")
    if can_remove and not r["in_dev"] and not on_a_branch(r["path"]):
        can_remove = False; reason.append("commits on no branch")
    if can_remove:
        out.append((n, "REMOVE", ("in dev" if r["in_dev"] else f"idle {r['touched_days']}d, branch kept"), tot))
    elif nm > 0:
        out.append((n, "NM_ONLY", "; ".join(reason), nm))
    else:
        out.append((n, "KEEP", "; ".join(reason) + "; no node_modules", 0))
with open(os.path.join(HERE, "plan.tsv"), "w") as f:
    f.write("name\taction\treason\tfrees_gb\n")
    for o in out: f.write("\t".join(map(str, o)) + "\n")
from collections import Counter
c, g = Counter(), Counter()
for _, a, _, gb in out: c[a] += 1; g[a] += gb
for a in ("KEEP", "NM_ONLY", "REMOVE", "PRUNE"):
    print(f"{a:8} {c[a]:4} worktrees  frees {g[a]:7.1f} GB")
print(f"TOTAL frees {sum(g.values()):.1f} GB; worktrees left after: {c['KEEP'] + c['NM_ONLY']}")
