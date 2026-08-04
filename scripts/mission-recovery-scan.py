#!/usr/bin/env python3
"""
mission-recovery-scan.py - a MINIMAL, read-only reporter for frozen /mission chains.

Purpose (one-time operator aid, NOT durable machinery): after the mission-stall fix
lands, the ~5 already-frozen missions still need a human to look at them and decide
whether to resume. This script SURVEYS them and prints a table. It executes NOTHING -
it reads the chain ledgers, the chain manifests, and each mission's on-disk state, and
shells out ONLY to the read-only `mission-write.sh await-state` verb. It never resumes,
never writes, never touches a lock, never reaches the network / OD / a DB.

For each ~/.claude/chains/<sid>.log:
  * status= / next=  -> from the LAST ledger line. Parsed by KEY (not by fixed column),
    because real ledger rows omit optional fields (elapsed/files) - see the delta note
    below. The locked TSV positions are documented in
    scripts/hooks/lib/handoff-chain.sh (1=iso_ts .. 5=status= 6=next= .. 9=north_star).
  * mission_path  -> resolved from the chain MANIFEST json (<sid>.json). We do NOT infer
    a repo root from cwd; a manifest with no mission_path is not a mission and is skipped
    with a note.
  * heuristic-dead-gap  -> now - max(last ledger ts, mission-file mtime). LABELLED
    heuristic: last_heartbeat_at is /pre-compact-updated, so it is NOT proof of a stall;
    a long gap is a signal to LOOK, not a verdict.
  * parked-for-human  -> AUTHORITATIVE: an outstanding `AWAIT kind=human` (via await-state). This is
    the ONLY blocking signal - an ordinary non-empty PENDING DECISIONS zone is the away-policy
    NON-blocking case (the loop proceeds loudly on its assumption), so it must NOT read as parked (I14).
  * outstanding-AWAIT?  -> via `mission-write.sh await-state <sid> <mission-root>`.
  * next=  -> the last ledger next= line (truncated).
  * a PINNED manual resume command - stated, never run. `/mission resume` clones the
    frozen state into a NEW sid; the operator runs it by hand from the printed cwd.

Delta from the plan's "status= (field 5) / next= (field 6)" wording (recorded, not
silent): live ledgers in ~/.claude/chains skip optional fields, so a fixed-column read
would misattribute status/next on the shorter rows. This reporter parses each field by
its `key=` token instead, which reads the SAME two fields robustly. Read-only; no
behaviour of the ledger changes.
"""
import glob
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone

HOME = os.path.expanduser("~")
CHAINS_DIR = os.path.join(HOME, ".claude", "chains")
MISSION_WRITE = os.path.join(
    HOME, ".claude-dotfiles", "scripts", "hooks", "mission-write.sh"
)


def parse_iso(ts):
    """Parse an ISO `2026-07-14T23:32:39Z` stamp to an aware UTC datetime, or None."""
    if not ts:
        return None
    try:
        return datetime.strptime(ts.strip(), "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        return None


def last_ledger_line(path):
    """Return the last non-blank line of the ledger, or ''."""
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            lines = [ln.rstrip("\n") for ln in f if ln.strip()]
    except OSError:
        return ""
    return lines[-1] if lines else ""


def kv(line, key):
    """Extract a `key=<value-up-to-next-tab-or-eol>` token from a TSV line, or ''."""
    m = re.search(re.escape(key) + r"=([^\t]*)", line)
    return m.group(1).strip() if m else ""


def leading_ts(line):
    """The first TAB-delimited field of a ledger row is the ISO timestamp."""
    return line.split("\t", 1)[0].strip() if line else ""


def read_manifest(sid):
    p = os.path.join(CHAINS_DIR, sid + ".json")
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def pending_zone_nonempty(mission_file):
    """AUTHORITATIVE parked-for-human signal: a non-empty PENDING DECISIONS zone.

    Non-empty = at least one `- [pd:...]` decision line between the zone fences. Zone
    fences are `<!-- MZONE:PENDING DECISIONS n=.. -->` / its `/MZONE` close (mirrors
    mission_create in lib/mission-bridge.sh). Read-only.
    """
    try:
        with open(mission_file, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return False
    in_zone = False
    for ln in text.splitlines():
        if ln.startswith("<!-- MZONE:PENDING DECISIONS"):
            in_zone = True
            continue
        if ln.startswith("<!-- /MZONE:PENDING DECISIONS"):
            in_zone = False
            continue
        if in_zone and ln.strip().startswith("- [pd:"):
            return True
    return False


def await_state(sid, root):
    """Call the READ-ONLY mission-write.sh await-state verb. Returns its bare token."""
    if not os.path.exists(MISSION_WRITE):
        return "(await-state unavailable)"
    try:
        r = subprocess.run(
            ["bash", MISSION_WRITE, "await-state", sid, root],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return "(await-state error)"
    out = (r.stdout or "").strip()
    return out if out else "none"


def humanize_gap(seconds):
    if seconds is None:
        return "unknown"
    seconds = int(seconds)
    if seconds < 0:
        seconds = 0
    d, rem = divmod(seconds, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    if d:
        return f"{d}d{h}h"
    if h:
        return f"{h}h{m}m"
    return f"{m}m"


def main():
    now = datetime.now(timezone.utc)
    if not os.path.isdir(CHAINS_DIR):
        print(f"no chains dir at {CHAINS_DIR} - nothing to scan")
        return 0

    rows = []
    skipped = []
    for log_path in sorted(glob.glob(os.path.join(CHAINS_DIR, "*.log"))):
        sid = os.path.basename(log_path)[: -len(".log")]
        manifest = read_manifest(sid)
        if not manifest:
            skipped.append((sid, "no/unreadable manifest json"))
            continue
        mission_path = manifest.get("mission_path")
        if not mission_path:
            skipped.append((sid, "manifest has no mission_path - not a mission"))
            continue
        if not os.path.exists(mission_path):
            skipped.append((sid, f"mission_path missing on disk: {mission_path}"))
            continue

        mission_root = os.path.dirname(mission_path)
        last = last_ledger_line(log_path)
        status = kv(last, "status") or manifest.get("status", "?")
        nxt = kv(last, "next") or "(none)"

        ledger_dt = parse_iso(leading_ts(last))
        try:
            mtime_epoch = os.path.getmtime(mission_path)
        except OSError:
            mtime_epoch = None
        candidates = []
        if ledger_dt is not None:
            candidates.append(ledger_dt.timestamp())
        if mtime_epoch is not None:
            candidates.append(mtime_epoch)
        gap = (now.timestamp() - max(candidates)) if candidates else None

        parked = pending_zone_nonempty(mission_path)
        outstanding = await_state(sid, mission_root)

        rows.append(
            {
                "sid": sid,
                "gap": humanize_gap(gap),
                "status": status,
                "await": outstanding,
                "parked": "yes" if parked else "no",
                "next": nxt,
                "cwd": mission_root,
            }
        )

    if not rows:
        print("No resolvable missions found (no chain has a mission_path on disk).")
    else:
        print(
            "MISSION RECOVERY SCAN (read-only survey; the dead-gap is a HEURISTIC, "
            "not proof of a stall)\n"
        )
        header = f"{'sid':36}  {'dead-gap*':>9}  {'status':10}  {'parked':6}  {'await':6}  next="
        print(header)
        print("-" * len(header))
        for r in rows:
            aw = "yes" if r["await"].startswith("await") else "no"
            nxt = r["next"]
            if len(nxt) > 70:
                nxt = nxt[:67] + "..."
            print(
                f"{r['sid']:36}  {r['gap']:>9}  {r['status']:10}  "
                f"{r['parked']:6}  {aw:6}  {nxt}"
            )
        print("\n* dead-gap = now - max(last ledger ts, mission-file mtime). HEURISTIC:")
        print("  last_heartbeat_at is /pre-compact-updated, so a long gap is a signal to")
        print("  LOOK, not a verdict. 'parked'=yes is authoritative (PENDING DECISIONS")
        print("  zone non-empty). 'await'=yes means an AWAIT lane is still outstanding.\n")
        print("PINNED manual resume commands (NOT run by this script; each clones the")
        print("frozen state into a NEW sid):\n")
        for r in rows:
            print(f"  # {r['sid']}  ({r['status']}, dead-gap {r['gap']})")
            print(f"  cd {r['cwd']} && /mission resume {r['sid']}")
            if r["await"].startswith("await"):
                print(f"    outstanding: {r['await']}")
        print()

    if skipped:
        print(f"Skipped {len(skipped)} chain(s) with no resolvable mission:")
        for sid, why in skipped:
            print(f"  {sid}: {why}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
