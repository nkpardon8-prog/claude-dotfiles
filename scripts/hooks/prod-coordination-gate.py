#!/usr/bin/env python3
"""
PreToolUse gate — serialize prod-mutating ops across parallel Claude instances.

Why: multiple agents share the same prod DB + Cloud Run. Two running an
irreversible prod op at once can overwrite each other (e.g. a blanket
`migrate deploy` sweeping another agent's pending migration). This makes that
structurally impossible without over-constraining normal/local work.

Design:
  * FAIL-CLOSED FOR PROD. Once a command is classified as production-mutating,
    malformed/unreadable lock state or a failed lock write blocks the command.
  * NARROW. Only genuinely prod-mutating commands are gated (Cloud Run deploy,
    prod migration apply, role BYPASSRLS flips). Everything else exits instantly.
  * MANUAL STALE RECOVERY. A stale lock is never auto-replaced: pathname-level
    stale takeover has no compare-and-swap and can erase a concurrent renewal.
"""
import sys, json, os, time, re, secrets

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


def block(message):
    print(f"PROD-COORDINATION: {message}", file=sys.stderr)
    sys.exit(2)


def _validated_lock():
    try:
        with open(LOCK) as f:
            value = json.load(f)
    except FileNotFoundError:
        return None
    except Exception as exc:
        block(f"prod lock is unreadable/malformed ({exc}); failing closed. Reconcile {LOCK} manually.")
    if (
        not isinstance(value, dict)
        or not isinstance(value.get("sid"), str)
        or not value["sid"].strip()
        or not isinstance(value.get("op"), str)
        or not isinstance(value.get("ts"), int)
        or isinstance(value.get("ts"), bool)
        or value["ts"] <= 0
    ):
        block(f"prod lock has an invalid shape; failing closed. Reconcile {LOCK} manually.")
    return value


def _write_complete_temp(value):
    os.makedirs(os.path.dirname(LOCK), exist_ok=True)
    temp = f"{LOCK}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    fd = None
    try:
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as stream:
            fd = None
            json.dump(value, stream, separators=(",", ":"))
            stream.flush()
            os.fsync(stream.fileno())
        return temp
    except Exception:
        if fd is not None:
            os.close(fd)
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass
        raise


def _atomic_claim_or_refresh(value, expected):
    temp = _write_complete_temp(value)
    try:
        if expected is None:
            os.link(temp, LOCK)
        else:
            current = _validated_lock()
            if current != expected:
                block("prod lock changed during refresh; no production command was allowed.")
            os.replace(temp, LOCK)
            temp = None
        directory_fd = os.open(os.path.dirname(LOCK), os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temp is not None:
            try:
                os.unlink(temp)
            except FileNotFoundError:
                pass


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

    existing = _validated_lock()
    holder = existing["sid"] if existing else None
    op_desc = existing["op"] if existing else ""
    ts = existing["ts"] if existing else 0

    age = now - ts if existing else 0
    fresh = bool(holder) and 0 <= age < TTL

    if existing and not fresh:
        block(
            f"prod lock is stale or time-invalid ({age}s; session {str(holder)[:8]}…). "
            f"It is never auto-reclaimed. Prove the operation stopped, then remove {LOCK} manually."
        )

    if fresh and holder != sid:
        remain = max(0, TTL - age)
        block(
            "a prod-mutating op is blocked. Another Claude "
            f"instance (session {str(holder)[:8]}…) holds the prod lock "
            f"[op: {op_desc or 'prod op'}, {age}s ago]. Two agents must not run "
            "irreversible prod ops at once. STOP and tell the user; resume once "
            f"that instance is done (about {remain}s remain before manual stale reconciliation)."
        )

    # Free / already mine -> atomically publish a complete lock record.
    try:
        snippet = cmd.strip().replace("\n", " ")[:80]
        _atomic_claim_or_refresh({"sid": sid, "op": snippet, "ts": now}, existing)
    except FileExistsError:
        block("another actor claimed the prod lock concurrently; retry only after reconciling its owner.")
    except Exception as exc:
        block(f"could not durably claim the prod lock ({exc}); failing closed.")
    allow()


try:
    main()
except SystemExit:
    raise
except Exception:
    print("PROD-COORDINATION: unexpected gate failure; production command blocked.", file=sys.stderr)
    sys.exit(2)
