#!/usr/bin/env python3
"""
Fixture suite for the fail-closed prod classifier shared (duplicated) by:
  * prod-coordination-gate.py  — PreToolUse gate; BLOCKS a prod op while another
                                 session holds a fresh prod lock.
  * prod-ledger.py             — PostToolUse ledger; LOGS a prod op.

Every case is checked against BOTH hooks by TWO independent paths:

  (A) DIRECT — source-exec each hook file's module body UP TO (but not including)
      its `main()` call, so we obtain the file's real `is_prod()` without firing
      the live hook, then call it on the command the hook would extract from the
      real stdin JSON payload.

  (B) END-TO-END — run the REAL hook as a subprocess fed the REAL stdin hook JSON
      payload (PreToolUse shape for the gate, PostToolUse `record` shape for the
      ledger), with $HOME redirected to a throwaway dir so the real
      ~/.claude/prod.lock and ~/.claude/prod-ledger are NEVER touched:
        - gate:   a fresh foreign lock is pre-seeded, so a PROD op => exit 2
                  (blocked) and a SAFE op => exit 0 (early allow, lock untouched).
        - ledger: `record` => a PROD op appends a ledger line; a SAFE op does not.

  Both paths must agree with the expected classification for a case to PASS.

Usage:  test-prod-classifier-fixtures.py [GATE_PATH] [LEDGER_PATH]
        (defaults to the in-place hook files; scratch runs pass the .new copies)

Prints PASS/FAIL per (case, hook); prints a final tally; exits non-zero on any FAIL.

NOTE (deliberate): the prod-pattern strings live ONLY in this file's content,
executed by python. They are NEVER emitted into a Bash command line — the live
PreToolUse gate inspects Bash commands, so putting these strings in a shell
command would (ironically) trip the very gate under test.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GATE = os.path.abspath(sys.argv[1]) if len(sys.argv) > 1 else os.path.join(HERE, "prod-coordination-gate.py")
LEDGER = os.path.abspath(sys.argv[2]) if len(sys.argv) > 2 else os.path.join(HERE, "prod-ledger.py")

PROD = "PROD"
SAFE = "SAFE"


def load_isprod(path):
    """Exec the hook's module body up to its `main()` invocation so we get the
    real is_prod() without running the live hook."""
    with open(path) as f:
        src = f.read()
    marker = "\ntry:\n    main()"
    idx = src.find(marker)
    if idx != -1:
        src = src[:idx]
    ns = {"__name__": "hook_under_test"}
    exec(compile(src, path, "exec"), ns)  # noqa: S102 — trusted local hook source
    if "is_prod" not in ns:
        raise RuntimeError(f"{path}: no is_prod() found")
    return ns["is_prod"]


GATE_ISPROD = load_isprod(GATE)
LEDGER_ISPROD = load_isprod(LEDGER)


def direct_gate(cmd):
    return PROD if GATE_ISPROD(cmd) else SAFE


def direct_ledger(cmd):
    return PROD if LEDGER_ISPROD(cmd) else SAFE


def _pretooluse_payload(cmd):
    # exact PreToolUse Bash shape the gate reads from stdin
    return {"tool_name": "Bash", "tool_input": {"command": cmd}, "session_id": "MY-SESSION"}


def _posttooluse_payload(cmd, cwd):
    # exact PostToolUse Bash shape the ledger `record` verb reads from stdin
    return {
        "tool_name": "Bash",
        "tool_input": {"command": cmd},
        "tool_response": {"isError": False, "interrupted": False},
        "cwd": cwd,
        "session_id": "MY-SESSION",
    }


def e2e_gate(cmd):
    """Run the real gate with real stdin; HOME redirected. A pre-seeded fresh
    foreign lock makes a PROD op block (exit 2). Returns (verdict, stdout, stderr)."""
    with tempfile.TemporaryDirectory() as home:
        claude = os.path.join(home, ".claude")
        os.makedirs(claude, exist_ok=True)
        with open(os.path.join(claude, "prod.lock"), "w") as f:
            json.dump({"sid": "OTHER-SESSION", "op": "seed", "ts": int(time.time())}, f)
        env = dict(os.environ, HOME=home)
        r = subprocess.run(
            [sys.executable, GATE],
            input=json.dumps(_pretooluse_payload(cmd)),
            capture_output=True, text=True, env=env, timeout=30,
        )
        if r.returncode == 2:
            return PROD, r.stdout, r.stderr
        if r.returncode == 0:
            return SAFE, r.stdout, r.stderr
        raise RuntimeError(f"gate unexpected exit {r.returncode}: {r.stderr!r}")


def e2e_ledger(cmd):
    """Run the real ledger `record` with real stdin; HOME + cwd redirected to a
    throwaway dir. Returns PROD if a ledger line was written, else SAFE."""
    with tempfile.TemporaryDirectory() as home:
        env = dict(os.environ, HOME=home)
        subprocess.run(
            [sys.executable, LEDGER, "record"],
            input=json.dumps(_posttooluse_payload(cmd, home)),
            capture_output=True, text=True, env=env, cwd=home, timeout=30,
        )
        ledger_dir = os.path.join(home, ".claude", "prod-ledger")
        if os.path.isdir(ledger_dir):
            for fn in os.listdir(ledger_dir):
                p = os.path.join(ledger_dir, fn)
                if os.path.isfile(p) and os.path.getsize(p) > 0:
                    return PROD
        return SAFE


# ---------------------------------------------------------------------------
# Fixture cases: (name, command, gate_expected, ledger_expected)
# Some cases differ per hook (the ledger tracks `git push`; the gate does not) —
# that is intentional and asserted explicitly.
LOCAL = "postgresql://localhost:5432/summit"
LOCAL_127 = "postgresql://127.0.0.1:5432/summit"
LOCAL_PG = "postgresql://postgres:5432/summit"
SPOOF_USERHOST = "postgresql://user:localhost@prod.internal/summit"
SPOOF_SUBDOM = "postgresql://user@localhost.evil.example/summit"
NEON = "postgresql://user@ep-cool-tree-123.us-east-2.aws.neon.tech/neondb"

CASES = [
    # inline local-URL migrates -> exempted (NOT prod) on both
    ("inline-localhost migrate",   f"DATABASE_URL={LOCAL} npx prisma migrate deploy",     SAFE, SAFE),
    ("inline-127.0.0.1 migrate",   f"DATABASE_URL={LOCAL_127} npx prisma migrate deploy", SAFE, SAFE),
    ("inline-postgres-host migrate", f"DATABASE_URL={LOCAL_PG} prisma migrate deploy",     SAFE, SAFE),

    # bare / marked / docker migrates -> stay PROD on both
    ("env-var bare migrate",       "DATABASE_URL=$PROD_URL npx prisma migrate deploy",     PROD, PROD),
    ("db:migrate:deploy bare",     "npm run db:migrate:deploy",                            PROD, PROD),
    ("docker exec w/o URL",        "docker exec summit-pg prisma migrate deploy",          PROD, PROD),
    ("ALLOW_PROD-marked migrate",  "ALLOW_PROD_MIGRATE_DEPLOY=1 npm run db:migrate:deploy", PROD, PROD),

    # non-migrate prod signals
    ("gcloud run deploy",          "gcloud run deploy summit-api --region us-central1",    PROD, PROD),
    ("neon.tech URL",              f"psql {NEON}",                                          PROD, PROD),

    # spoof shapes -> parse to a non-local host -> PROD on both
    ("spoof user:localhost@prod",  f"DATABASE_URL={SPOOF_USERHOST} prisma migrate deploy", PROD, PROD),
    ("spoof @localhost.evil",      f"DATABASE_URL={SPOOF_SUBDOM} prisma migrate deploy",   PROD, PROD),

    # compound: a non-migrate prod signal in another clause keeps it PROD (both)
    ("cloud-deploy && local migrate",
     f"gcloud run deploy summit-api && DATABASE_URL={LOCAL} prisma migrate deploy", PROD, PROD),

    # ledger tracks git push; the gate does not gate push -> per-hook expectation
    ("git push alone",             "git push origin dev",                                  SAFE, PROD),
    ("push && local migrate (ledger side)",
     f"git push origin dev && DATABASE_URL={LOCAL} prisma migrate deploy",           SAFE, PROD),

    # mixed-migrate masking: two migrate patterns -> exactly-one rule fails closed
    ("local-URL migrate && bare db:migrate:deploy",
     f"DATABASE_URL={LOCAL} prisma migrate deploy && npm run db:migrate:deploy", PROD, PROD),

    # historical false-positive the OLD gate wrongly blocked: docker-exec LOCAL
    # migration with an inline localhost URL -> now correctly exempted
    ("docker-exec inline-localhost migrate (historical FP)",
     f'docker exec summit-pg sh -lc "DATABASE_URL={LOCAL} prisma migrate deploy"', SAFE, SAFE),

    # plain safe command -> never prod, gate stays silent (asserted separately too)
    ("plain safe command",         "ls -la",                                               SAFE, SAFE),
]

# gate-21 unrelated-URL masking repro: an unrelated localhost URL in a DIFFERENT
# clause than a BARE migrate must never exempt it. One case per separator the
# clause-splitter names: && ; | & newline. All -> PROD on both hooks.
for sepname, sep in [("&&", " && "), (";", " ; "), ("|", " | "), ("&", " & "), ("newline", "\n")]:
    CASES.append((
        f"masking repro sep={sepname}",
        f"echo postgresql://localhost/x{sep}prisma migrate deploy",
        PROD, PROD,
    ))


def main():
    passed = 0
    failed = 0
    print(f"prod-classifier fixtures")
    print(f"  gate  : {GATE}")
    print(f"  ledger: {LEDGER}")
    print("-" * 72)

    for name, cmd, gate_exp, ledger_exp in CASES:
        for hook, expected, direct_fn, e2e_fn in (
            ("gate", gate_exp, direct_gate, lambda c: e2e_gate(c)[0]),
            ("ledger", ledger_exp, direct_ledger, e2e_ledger),
        ):
            d = direct_fn(cmd)
            e = e2e_fn(cmd)
            ok = (d == expected and e == expected)
            if ok:
                passed += 1
                print(f"PASS [{hook:6s}] {name}  -> {expected}")
            else:
                failed += 1
                print(f"FAIL [{hook:6s}] {name}  expected={expected} direct={d} e2e={e}")
                print(f"       cmd={cmd!r}")

    # Dedicated silence check: a plain safe command must pass the gate with NO
    # stdout/stderr (the DoD "passes the gate silently" requirement).
    verdict, out, err = e2e_gate("ls")
    if verdict == SAFE and out == "" and err == "":
        passed += 1
        print("PASS [gate  ] safe command 'ls' passes gate SILENTLY (exit 0, no output)")
    else:
        failed += 1
        print(f"FAIL [gate  ] safe 'ls' not silent: verdict={verdict} out={out!r} err={err!r}")

    # DRIFT-GUARD (god-report 2026-07-12, single-pattern lens): the SHARED classifier logic
    # (MIGRATE, PRODMARK, _all_urls_local, is_prod) is copy-pasted verbatim into both hook files
    # with no import path — a silent divergence would let one hook block a migrate the other allows.
    # Assert the shared region is byte-identical. NOTE: the `PROD` regex ABOVE this region is
    # DELIBERATELY per-file (the ledger tracks a broader op set — git push / builds submit /
    # migrate resolve --applied — than the gate blocks), so it is EXCLUDED from this guard on purpose.
    here = os.path.dirname(os.path.abspath(__file__))

    def _shared_logic(fname):
        with open(os.path.join(here, fname)) as fh:
            src = fh.read()
        m = re.search(r"(?ms)^MIGRATE = re\.compile.*?unknown/unparseable target = prod-risk", src)
        return m.group(0) if m else None

    g_logic = _shared_logic("prod-coordination-gate.py")
    l_logic = _shared_logic("prod-ledger.py")
    if g_logic and l_logic and g_logic == l_logic:
        passed += 1
        print("PASS [drift ] shared classifier logic (MIGRATE..is_prod) byte-identical across both hooks")
    else:
        failed += 1
        reason = "region not found in one file" if not (g_logic and l_logic) else "regions DIVERGED"
        print(f"FAIL [drift ] shared classifier logic differs between the two hooks ({reason}) — "
              "a fix to one hook's is_prod/_all_urls_local was not mirrored to the other")

    print("-" * 72)
    total = passed + failed
    print(f"TALLY: {passed}/{total} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
