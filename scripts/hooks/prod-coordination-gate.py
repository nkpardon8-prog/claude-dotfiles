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
    r"|MIGRATOR_DIRECT_URL"
    r"|neon\.tech"
    r"|db:migrate:deploy"
    r"|ALTER\s+ROLE\b[^;]*\b(?:BYPASSRLS|NOBYPASSRLS)\b",
    re.IGNORECASE,
)

# --- Fail-closed prod classifier (duplicated verbatim in prod-ledger.py) ------
# A migrate is a prod op UNLESS every postgres URL in the migrate's OWN shell
# clause PARSES (urlparse hostname — never substring) to exactly localhost /
# 127.0.0.1 / the docker service hostname `postgres`. Anything unknown, spoofed
# (user:localhost@prod.internal, @localhost.evil.example), or unparseable stays
# PROD. `docker exec` / `POSTGRES_` tokens / env-var bare migrates do NOT exempt.
# Spec: tmp/ready-plans/2026-07-10-skill-stack-top-fixes.md — "Prod narrowing"
# (Key Pseudocode 6). These hook scripts have no shared import path, so the
# classifier is duplicated in both by design; the fixture suite pins them equal.
MIGRATE = re.compile(r"prisma\s+migrate\s+deploy|db:migrate:deploy", re.I)
PRODMARK = re.compile(r"ALLOW_PROD_MIGRATE_DEPLOY|MIGRATOR_DIRECT_URL|neon\.tech", re.I)


# DB-connection env vars — a migrate's REAL target is whatever one of these points at.
CONN_VAR = re.compile(
    r"\b(?:[A-Z][A-Z0-9_]*_)?(?:DATABASE_URL|DB_URL|POSTGRES[A-Z0-9_]*|PG[A-Z0-9_]*|MIGRATOR[A-Z0-9_]*)"
    r"\s*=\s*(\S+)", re.I)


def _url_is_local(u):
    # Exact hostname equality only; parse failure = NOT local (prod-risk).
    from urllib.parse import urlparse
    try:
        host = (urlparse(u).hostname or "").lower()
    except ValueError:
        return False
    return host in ("localhost", "127.0.0.1", "postgres")


def _strip_comment(clause):
    # Drop an inline shell comment (` #...` to end of the clause): a postgres URL that appears
    # ONLY in a comment is a DECOY, never a real connection argument (codex-review CRITICAL 2026-07-12:
    # `DATABASE_URL=$PROD_URL <migrate> # postgresql://localhost/x` was wrongly exempted).
    return re.sub(r"(?:^|\s)#.*$", "", clause)


def _all_urls_local(cmd):
    urls = re.findall(r"postgres(?:ql)?://[^\s\"']+", cmd, re.I)
    if not urls:
        return False
    return all(_url_is_local(u) for u in urls)


def _migrate_target_provably_local(clause):
    # A migrate is exempt ONLY when its clause's connection target is PROVABLY local. Comments are
    # stripped first (decoy URLs don't count). Then BOTH must hold:
    #   (a) every remaining literal postgres URL is local AND there is >= 1 (no URL => unknown => prod),
    #   (b) every DB-connection env assignment resolves to a proven-local LITERAL — a var ref
    #       (`$PROD_URL`) or a non-local literal means the real target is not provably local => prod.
    c = _strip_comment(clause)
    if not _all_urls_local(c):
        return False
    for val in CONN_VAR.findall(c):
        val = val.strip().strip("'\"")
        if not (re.match(r"postgres(?:ql)?://", val, re.I) and _url_is_local(val)):
            return False
    return True


def is_prod(cmd):
    if not PROD.search(cmd):
        return False
    # NON-MIGRATE prod signals win FIRST — a compound like
    # `<cloud-deploy> && <local migrate>` (or ledger-side `<push> && <local
    # migrate>`) must stay PROD; the local exemption applies ONLY when the
    # migrate pattern is the SOLE prod signal present.
    if PROD.search(MIGRATE.sub("", cmd)):
        return True
    # EXACTLY-ONE-MIGRATE rule (mixed-migrate masking): fail closed on multiples.
    if len(MIGRATE.findall(cmd)) != 1:
        return True
    # PER-CLAUSE BINDING: the local URL must live in the SAME shell clause as the
    # migrate — an unrelated local URL elsewhere in the compound never exempts.
    # Split on ALL clause boundaries (alternation order: && before &, || before |).
    clauses = re.split(r"&&|\|\||;|\||&|\n|\r", cmd)
    migrate_clauses = [c for c in clauses if MIGRATE.search(c)]
    if len(migrate_clauses) != 1:
        return True
    if _migrate_target_provably_local(migrate_clauses[0]) and not PRODMARK.search(cmd):
        return False
    return True  # unknown/unparseable target = prod-risk


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
    if not cmd or not is_prod(cmd):
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
