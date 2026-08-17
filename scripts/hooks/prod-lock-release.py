#!/usr/bin/env python3
"""
PostToolUse(Bash) — release THIS session's ~/.claude/prod.lock when the command
that took it has finished.

WHY THIS EXISTS. prod-coordination-gate.py (PreToolUse) claims a machine-wide
lock for a command it classifies as production-mutating. Until this hook, NOTHING
ever released it. Its only exit was aging past a TTL into "stale", and stale
BLOCKS and preserves the file for a human to delete. Measured consequence: a lock
held 2 days 17 hours, another 18h52m, another 4h+ — every one of them taken by a
command that did nothing to production at all. 100% of the measured damage was
DURATION, not misclassification, and duration is what this file removes.

DESIGN — IDENTITY, NOT CLASSIFICATION (constraint F).
The release half must know whether THIS command took the lock. It could re-run
the classifier; it deliberately does not:
  * the gate and the ledger already carry the classifier as two byte-pinned
    copies under a drift guard in the fixture suite. A third copy is a third
    thing to drift, and a drift that made the PRE and POST halves disagree would
    leak the lock — the exact bug being fixed.
  * identity is strictly MORE correct than re-classification. "Does the lock on
    disk record MY session id?" is precisely the question "am I the holder?".
    Re-classification only ever approximates it, and answers a different question
    if the payload the two hooks see ever differs.
  * it needs no classifier at all, so it cannot drift by construction.

DESIGN — RELEASE POLARITY IS INVERTED vs prod-ledger.py (constraint E).
The ledger SKIPS a command whose tool_response reports isError or interrupted —
correctly, since it records what actually happened. This hook must do the
OPPOSITE and release on those too: a failed or user-interrupted command is
precisely the case that strands the lock today. So `tool_response` is read for
nothing. It is not consulted anywhere below, and that is the whole point.

RACE SAFETY. Reading the lock and then unlinking it is a check-then-act, so in
principle we could unlink a lock some other session took in between. That cannot
happen, by construction: the only way another session takes a lock it does not
own is the gate's auto-reclaim, and that fires ONLY on a positive "this pid is
gone" reading for the recorded holder. This process is a live descendant of the
holder session, so the holder cannot read as dead while we are running. Stale
alone never transfers a lock — it blocks.

FAILURE POSTURE. A PostToolUse hook must never break the session, and a release
that fails is only ever a return to the (bad) status quo of a held lock. So every
path here exits 0 and stays silent. It NEVER blocks, and it never removes a lock
that is absent, unreadable, malformed, or another session's.
"""
import json
import os
import sys

LOCK = os.path.expanduser("~/.claude/prod.lock")


def main():
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        return
    if not isinstance(payload, dict):
        return

    sid = payload.get("session_id")
    if not isinstance(sid, str) or not sid.strip():
        return

    try:
        with open(LOCK) as stream:
            lock = json.load(stream)
    except FileNotFoundError:
        return
    except Exception:
        # Unreadable or malformed. Leave it EXACTLY as it is: the gate fails
        # closed on this shape and preserves it as evidence for a human, and we
        # cannot show it is ours.
        return

    if not isinstance(lock, dict) or lock.get("sid") != sid:
        return

    try:
        os.unlink(LOCK)
    except FileNotFoundError:
        pass
    except Exception:
        pass


try:
    main()
except Exception:
    pass
sys.exit(0)
