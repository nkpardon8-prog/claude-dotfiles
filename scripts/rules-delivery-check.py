#!/usr/bin/env python3
"""rules-delivery-check.py - which Claude windows on THIS Mac already hold the current global rules?

rules-in-force.py saves, per session, the exact global rules text that session has been given
(~/.claude/progress/rules-state/<sid>.json). A window gets a rule change as a "RULES CHANGED" diff on
its next prompt (typed, or injected such as a peer message), so a window is up to date exactly when
its saved text equals the rule files on disk. This prints that comparison for sessions whose
transcript changed in the last --hours (default 6), newest first. Read-only. stdlib only.

USAGE. rules-delivery-check.py [--hours N]     exit 0 always; the table is the result.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import time
from pathlib import Path

HOME = Path.home()
HOOK = Path(__file__).resolve().parent / "hooks" / "rules-in-force.py"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=float, default=6.0)
    args = ap.parse_args()
    spec = importlib.util.spec_from_file_location("rif", HOOK)
    rif = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(rif)
    current = rif.global_rules()
    cutoff = time.time() - args.hours * 3600
    logs = {p.stem: p for p in (HOME / ".claude/projects").glob("*/*.jsonl") if p.stat().st_mtime >= cutoff}
    head = subprocess.run(["git", "-C", str(HOOK.parents[2]), "log", "--oneline", "-1"],
                          capture_output=True, text=True).stdout.strip()
    rows = []
    for sid, log in logs.items():
        f = rif.STATE_DIR / f"{sid}.json"
        try:
            ok = json.loads(f.read_text()).get("global") == current
            status = "current" if ok else "BEHIND (gets the diff on its next prompt)"
        except Exception:
            status = "no saved state (gets the full rules on its next prompt)"
        rows.append((log.stat().st_mtime, sid, status, log.parent.name[-40:]))
    rows.sort(reverse=True)
    n_ok = sum(1 for r in rows if r[2] == "current")
    print(f"dotfiles at: {head}")
    print(f"windows active in the last {args.hours:g} h: {len(rows)}   current: {n_ok}   not yet: {len(rows) - n_ok}")
    for mt, sid, status, proj in rows:
        age = int((time.time() - mt) / 60)
        print(f"  {sid[:8]}  last active {age:>4} min ago  {status:<52} ...{proj}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
