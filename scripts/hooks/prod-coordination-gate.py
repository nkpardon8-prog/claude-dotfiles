#!/usr/bin/env python3
"""
PreToolUse gate — serialize prod-mutating ops across parallel Claude instances.

Why: multiple agents share the same prod DB + Cloud Run. Two running an
irreversible prod op at once can overwrite each other (e.g. a blanket
`migrate deploy` sweeping another agent's pending migration). This makes that
structurally impossible without over-constraining normal/local work.

Design:
  * FAIL-OPEN. Any unexpected condition -> exit 0 (allow). A bug here must never
    block the user's work. We only ever BLOCK on a confirmed, fresh lock held by
    a DIFFERENT session.
  * NARROW. Only genuinely prod-mutating commands are gated (Cloud Run deploy,
    prod migration apply, role BYPASSRLS flips). Everything else exits instantly.
  * SELF-EXPIRING. The lock auto-expires after TTL so a crashed/abandoned agent
    never wedges prod forever. The holder refreshes it on each prod op.
"""
import sys, json, os, time, re

LOCK = os.path.expanduser("~/.claude/prod.lock")
TTL = 900  # seconds (15 min) — stale locks are ignored/overwritten

# Narrow set of genuinely prod-mutating, hard-to-undo operations.
PROD = re.compile(
    r"gcloud\s+run\s+deploy"
    r"|gcloud\s+run\s+services\s+update"
    r"|prisma\s+migrate\s+deploy"
    r"|ALLOW_PROD_MIGRATE_DEPLOY"
    r"|db:migrate:deploy"
    r"|ALTER\s+ROLE\b[^;]*\b(?:BYPASSRLS|NOBYPASSRLS)\b",
    re.IGNORECASE,
)


def allow():
    sys.exit(0)


def main():
    try:
        raw = sys.stdin.read()
        d = json.loads(raw) if raw.strip() else {}
    except Exception:
        allow()

    try:
        cmd = (d.get("tool_input") or {}).get("command", "") or ""
        sid = d.get("session_id") or "unknown"
    except Exception:
        allow()

    # Not a prod-mutating op -> never gate.
    if not cmd or not PROD.search(cmd):
        allow()

    now = int(time.time())

    holder, op_desc, ts = None, "", 0
    try:
        if os.path.exists(LOCK):
            with open(LOCK) as f:
                j = json.load(f)
            holder = j.get("sid")
            op_desc = j.get("op", "")
            ts = int(j.get("ts", 0))
    except Exception:
        holder = None  # unreadable lock -> treat as free (fail-open)

    fresh = bool(holder) and (now - ts) < TTL

    if fresh and holder != sid:
        age = now - ts
        remain = max(0, TTL - age)
        print(
            "PROD-COORDINATION: a prod-mutating op is blocked. Another Claude "
            f"instance (session {str(holder)[:8]}…) holds the prod lock "
            f"[op: {op_desc or 'prod op'}, {age}s ago]. Two agents must not run "
            "irreversible prod ops at once. STOP and tell the user; resume once "
            f"that instance is done (lock auto-clears in ~{remain}s). "
            f"If you are sure it is abandoned: rm {LOCK}",
            file=sys.stderr,
        )
        sys.exit(2)  # exit 2 blocks the tool call; stderr is shown to Claude

    # Free / stale / already mine -> acquire-or-refresh, then allow.
    try:
        snippet = cmd.strip().replace("\n", " ")[:80]
        tmp = LOCK + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"sid": sid, "op": snippet, "ts": now}, f)
        os.replace(tmp, LOCK)
    except Exception:
        pass  # can't write -> still allow (fail-open)
    allow()


try:
    main()
except SystemExit:
    raise
except Exception:
    sys.exit(0)  # absolute fail-open backstop
