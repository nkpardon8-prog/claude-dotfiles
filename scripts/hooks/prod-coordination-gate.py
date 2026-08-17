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
  * RELEASED ON COMPLETION. The PostToolUse half (prod-lock-release.py) removes
    THIS session's lock the instant the command returns — success, error, or
    user interrupt alike. Before that existed, NOTHING ever released the lock:
    every claim, including every false positive, was held until a human deleted
    the file (measured holds: 2d17h, 18h52m, 4h+). 100% of the measured damage
    was DURATION, and that is what the release half removes.
  * AUTO-RECLAIM ONLY FROM A PROVABLY DEAD HOLDER. The lock now records the
    holder's session `claude` pid AND its start time. A holder that `ps`
    positively reports as gone (or whose pid has been REUSED by a
    different-start-time process) is dead, and its lock is reclaimed regardless
    of age. Anything less certain — a live holder, a `ps` that failed, or a
    legacy lock with no pid — is NEVER reclaimed and still needs a human.
  * NO IN-PLACE STALE TAKEOVER. Reclaim is unlink-THEN-link, never os.replace:
    a pathname-level replace has no compare-and-swap and can erase a renewal
    that landed between the read and the write.
"""
import os
import json
import re
import secrets
import subprocess
import sys
import time

LOCK = os.path.expanduser("~/.claude/prod.lock")
# Seconds. A lock older than this is STALE. Stale does NOT mean ignored and does
# NOT mean overwritten — the comment that used to claim that here was simply
# false, and it papered over the whole defect: a stale lock BLOCKS and is left
# byte-for-byte in place for a human to reconcile (see `block()` below). Lowered
# 900 -> 300 once the PostToolUse release covered the ordinary case in seconds:
# the TTL is now only the worst case for a holder we cannot prove dead, and 15
# minutes of machine-wide blockage was a far too generous worst case.
TTL = 300

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


# --- Inert-data stripping (part of the shared, duplicated classifier) ---------
# The classifier reads the TEXT of a Bash command, so a dangerous phrase that is
# merely DATA - a commit message, a mission-bridge note, a heredoc body - used to
# be classified as PERFORMING the operation. Measured 2026-08-13: 11 of 1344
# prod-ledger entries were `mission-write.sh` bridge writes filed as push/migrate,
# and two sessions took ~/.claude/prod.lock for a note-write (one held it 2d17h,
# blocking every other agent's prod work until a human reconciled it).
#
# So quoted string literals and quoted/plain heredoc bodies are removed BEFORE
# classification: the shell never EXECUTES their contents. Fail-closed carve-outs
# leave the text INTACT (still scanned) when:
#   * an interpreter-style token is present, where a quoted string IS code
#     (`bash -c '...'`, `ssh host '...'`, `psql -c 'ALTER ROLE ...'`, `... | sh`,
#     `eval`, `xargs`, any `-c '` / `-e "` / `--command=`);
#   * the quoted run or heredoc body contains a command substitution (`$(` or a
#     backtick), which executes regardless of the quoting;
#   * the quoting/heredoc is unbalanced (no match => nothing is stripped).
# This does NOT lower the classifier's ceiling: text matching was always blind to
# indirection (write a script in one call, run it in the next), so the operations
# this can newly miss were already invisible to it.
# Alt-3 is NAME-AGNOSTIC and that is why it never regresses: no interpreter list, no gap walker,
# no path prefix - so an unnamed interpreter, a quoted executable name (`"/bin/bash" -c`) and a
# redirect before the flag (`bash 2>/tmp/err -c`) all stay caught. Four attempts to replace it with
# a closed name list each lost real executions it already covered. So the ONLY change is a
# SUBTRACTION: a search tool cannot trigger alt-3. `grep -niE "..."` - a SEARCH - held the
# machine-wide lock 4+ hours because IGNORECASE lets [ce] match the E.
# Spec + full measured record: tmp/ready-plans/2026-08-16-prod-classifier-residual-fix.md
#
# Three things here are load-bearing and each was learned by measurement, not reasoning:
#  * the blanks live INSIDE the lookahead. A standalone `[ \t]*` BACKTRACKS, so the guard gets
#    re-evaluated at a whitespace position where no denied name can match - which silently reduced
#    this to "only works when the tool name is the first byte of the command".
#  * the lookahead is PREFIX-AWARE, so a tool reached through sudo/git/env X=1//usr/bin//./ is seen.
#  * a BACKTICK and a `(` are in the anchor class AND excluded from the scan class. Either one in
#    the anchor class ALONE is QUADRATIC, because the scan must exclude what it anchors on.
#  * the name ends with (?=[ \t]|$), not \b: `\b` is satisfied by `=`, so `GREP=1 psql -c '...'`
#    would exempt its whole clause - a silent false negative shipped catches.
#
# A name is denied only when removing it is MEASURED to fix a real false positive, and a name whose
# own flags can EXECUTE another program is admitted only with that loss DECLARED:
#   grep/egrep/fgrep  no execution channel at all -> denying them cannot create a false negative.
#   rg/sed            have one (`rg --pre=CMD`, `sed -e '1e CMD'`, `s///e`) but each is measured to
#                     fix a real false positive -> kept, and the channel is GIVEN UP knowingly.
#                     Reversing that is one name in the alternation below.
#   ag/ack            have one (`--pager=CMD`) and fix nothing -> NOT denied.
#   awk               shells out via system() and takes program text via -e -> NOT denied.
INTERP = re.compile(
    r"(?:^|[\s|;&(])(?:eval|xargs|ssh)\b"
    r"|sh\s+-[a-z]*c\b"               # bash / zsh / dash / sh  -c, -lc, -ec
    r"|(?:^|[\n;|&(`])(?![ \t]*(?:(?:sudo|env|command|time|nohup|git)[ \t]+"
    r"|[A-Za-z_][A-Za-z0-9_]*=[^\s]*[ \t]+)*(?:[A-Za-z0-9_.~$-]*/)*"
    r"(?:grep|egrep|fgrep|rg|sed)(?=[ \t]|$))"
    r"[^\n;|&`(]*?\s-[a-z]*[ce]\s+['\"]"   # psql -c '...', python -c, node -e, sh -lc "..."
    r"|--(?:command|eval)="
    r"|\|\s*(?:ba|z|da|k)?sh\b",
    re.IGNORECASE,
)
SUBST = re.compile(r"\$\(|`")
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", re.S)
HEREDOC_OPEN = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def _strip_heredocs(cmd):
    out, pos = [], 0
    while True:
        m = HEREDOC_OPEN.search(cmd, pos)
        if not m:
            out.append(cmd[pos:])
            return "".join(out)
        nl = cmd.find("\n", m.end())
        if nl == -1:                                  # no body on this call
            out.append(cmd[pos:])
            return "".join(out)
        end = re.compile(r"^[ \t]*" + re.escape(m.group(2)) + r"[ \t]*$",
                         re.M).search(cmd, nl + 1)
        if not end:                                   # unterminated => fail closed
            out.append(cmd[pos:])
            return "".join(out)
        # QUOTED heredocs (<<'TAG') do NOT expand substitutions - `$(` and a backtick are
        # literal text there. Keeping the body on their account was unsound, and the kept
        # body's PROSE then reached the classifier: a note-write merely DESCRIBING a deploy
        # took the machine-wide lock (observed twice, 2026-08-17). m.group(1) is the opener's
        # quote, so an empty group means unquoted, which is the only case that can execute.
        if not m.group(1) and SUBST.search(cmd[nl + 1:end.start()]):  # unquoted only => keep
            out.append(cmd[pos:end.end()])
        else:
            # The `#` is the SPLICE GUARD. Deleting the body joins the opener line's tail directly
            # to the terminator tag, and `cat <<'SH' |` + `SH` matched branch 5 (`\|\s*sh\b`) in
            # the STRIPPED text while the ORIGINAL matched nothing - so stripping a note-write
            # CREATED a production verdict, the exact harm this stripping exists to remove.
            # `#` is monotone-SAFE: it is in no lead class, no anchor class and no literal of any
            # branch, so no branch can REQUIRE it - inserting it can only destroy a match, never
            # create one. It also leaves what remains reading as a shell comment.
            out.append(cmd[pos:nl + 1])
            out.append("#")
            out.append(cmd[end.start():end.end()])
        pos = end.end()


def _strip_inert_data(cmd):
    # ORDER MATTERS, and so does WHICH TEXT each half looks at. Decide the interpreter question on
    # the heredoc-STRIPPED text, so a body's PROSE cannot veto the stripping of its own container
    # (that is how a `cat > tmp/briefs/...` write was filed as a push and held the lock 2d17h).
    # When an interpreter fires, return the ORIGINAL so a body it may consume stays scannable
    # (`ssh box <<EOF ... EOF` really does run its body). Deliberately FAIL-CLOSED and deliberately
    # imprecise: in a multi-clause command the interpreter may live in a DIFFERENT clause from the
    # heredoc, so `ssh box 'true' && cat > notes.md <<EOF ... EOF` scans the note body and can file
    # a note-write as production. That is the safe direction, but it IS a false-positive source -
    # do not read this branch as proof that the interpreter owns the heredoc.
    stripped = _strip_heredocs(cmd)
    if INTERP.search(stripped):
        return cmd
    return QUOTED.sub(lambda m: m.group(0) if SUBST.search(m.group(0)) else " ", stripped)



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
    # Classify what the command RUNS, not every phrase it mentions.
    cmd = _strip_inert_data(cmd)
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


# --- Holder liveness ---------------------------------------------------------
# DECISION (D): these ~30 lines are PORTED from shell, not shelled out to. The
# prior art (ac_resolve_own_claude_pid / ac_pid_starttime,
# scripts/hooks/lib/auto-compact-sentinel.sh ~:225-245) is short, but calling it
# would mean spawning bash and sourcing a ~900-line library on the fail-closed
# path of a machine-wide safety gate — and, decisively, a shell function can only
# hand back a STRING, which COLLAPSES the tri-state: "ps answered, the pid is
# gone" and "ps itself failed" both arrive as empty. That is exactly the
# distinction that decides whether we are allowed to reclaim, so it must not be
# flattened. We need `subprocess` for `ps` either way, so the port costs nothing.
#
# Anchored `claude` argv matcher, same rationale as _AC_CLAUDE_ERE: matches
# `claude`, `/path/to/claude`, `claude --flags`; rejects `.claude-dotfiles`,
# `claude-cli.js`, `claudette`. Matched against `ps -o args=`, NEVER ucomm.
CLAUDE_ARGV = re.compile(r"(?:^|[\s/])claude(?:\s|$)")


def _norm_lstart(text):
    # `ps -o lstart=` double-spaces single-digit days ("Aug  5") and pads the
    # tail. Collapse to a deterministic comparison key, or a whitespace/locale
    # quirk turns "same process" into "pid reuse" and licenses a wrong reclaim.
    return " ".join((text or "").split())


def _probe_pid(pid):
    """Tri-state process probe — NEVER a boolean (constraint C).

      ("dead",     "")      ps ANSWERED and the pid is not there
      ("live",     lstart)  ps answered and the pid exists
      ("unusable", "")      ps itself failed; NO conclusion may be drawn

    Prior art: line-agent-communicator.py (~:230-235). On macOS `ps -p` exits 1
    for a pid that is simply not there, and that IS an answer; ANY other nonzero
    means ps failed. rc 0 with no row is ambiguous, so it is also `unusable` —
    reclaim happens only on a positive dead reading.
    """
    try:
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)],
                             capture_output=True, text=True, timeout=5)
    except Exception:
        return "unusable", ""
    if out.returncode == 1:
        return "dead", ""
    if out.returncode != 0:
        return "unusable", ""
    lstart = _norm_lstart(out.stdout)
    return ("live", lstart) if lstart else ("unusable", "")


def _resolve_session_pid():
    """(pid, lstart) of THIS session's `claude` process, or (None, None).

    os.getpid() is NOT it — that is this python hook, dead milliseconds from now,
    so a lock stamped with it would read as dead to the very next command. We
    walk the PPID chain up to 8 hops looking for the anchored `claude` argv, the
    way ac_resolve_own_claude_pid does. We deliberately do NOT read
    ~/.claude/sessions/<pid>.json: it is a plain file any local process can
    write and is documented FORGEABLE, so it can vouch for nothing.

    Failing to resolve is not an error: the lock is then written WITHOUT pid
    keys, i.e. as a legacy lock that simply cannot be liveness-checked and falls
    back to TTL behaviour.
    """
    pid = os.getppid()
    for _ in range(8):
        if not pid or pid <= 1:
            return None, None
        try:
            args = subprocess.run(["ps", "-ww", "-o", "args=", "-p", str(pid)],
                                  capture_output=True, text=True, timeout=5)
        except Exception:
            return None, None
        if args.returncode == 0 and CLAUDE_ARGV.search(args.stdout or ""):
            state, lstart = _probe_pid(pid)
            return (pid, lstart) if state == "live" else (None, None)
        try:
            up = subprocess.run(["ps", "-o", "ppid=", "-p", str(pid)],
                                capture_output=True, text=True, timeout=5)
        except Exception:
            return None, None
        if up.returncode != 0:
            return None, None
        try:
            pid = int((up.stdout or "").strip())
        except ValueError:
            return None, None
    return None, None


def _holder_provably_dead(lock):
    """True ONLY on a positive dead reading. Everything else is False:

      * a LEGACY lock with no/invalid pid keys (constraint H) — not checkable;
      * a LIVE holder whose start time matches — obviously not dead;
      * an UNUSABLE `ps` — liveness UNKNOWN, so we fail closed and leave it.

    A live pid whose start time DIFFERS is dead: macOS recycles pids, so the
    process now wearing that number is not the one that took the lock.
    """
    pid = lock.get("pid")
    start = lock.get("pid_start")
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    if not isinstance(start, str) or not start.strip():
        return False
    state, observed = _probe_pid(pid)
    if state == "dead":
        return True
    if state == "live" and observed != _norm_lstart(start):
        return True
    return False


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
    # BACKWARD COMPAT (constraint H): `pid` / `pid_start` are OPTIONAL and are
    # deliberately NOT validated here. A lock written by an un-upgraded window
    # carries neither — that is a LEGACY lock, not a malformed one, and treating
    # it as malformed would strand exactly the windows we are trying to unstick.
    # _holder_provably_dead() type-checks both itself and answers False for
    # anything it cannot read, so an absent or garbled pid can only ever COST us
    # a reclaim (falling back to TTL), never license a wrong one.
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

    # AUTO-RECLAIM a lock whose holder is PROVABLY dead. This is the second half
    # of the duration fix: release covers a session that finishes, reclaim covers
    # one that dies (crash, kill, closed window) with the lock still held.
    # Age is irrelevant here — a dead holder's lock is garbage at 10 seconds just
    # as much as at 2 days — so this runs BEFORE the freshness/stale branches.
    #
    # unlink-THEN-link, NEVER os.replace (constraint B): the refresh path's
    # read-then-compare is a TOCTOU, so reclaiming in place could clobber a
    # renewal that landed in between. Unlinking drops us onto the FREE path,
    # where os.link is no-clobber: a concurrent live claimant that got there
    # first makes us lose the race loudly with FileExistsError, already handled.
    if existing and existing["sid"] != sid and _holder_provably_dead(existing):
        try:
            os.unlink(LOCK)
        except FileNotFoundError:
            pass
        except Exception as exc:
            block(f"could not reclaim a dead holder's prod lock ({exc}); failing closed.")
        existing = None

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
