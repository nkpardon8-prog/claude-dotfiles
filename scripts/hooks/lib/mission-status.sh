#!/usr/bin/env bash
# mission-status.sh - /mission status lines, per-part token totals and the morning report
# (plan 9). Read-only over the mission state; the only file it writes is MORNING.md.
#
# USAGE (run it, or source it and call the functions)
#   mission-status.sh status  <sid> <root>   mission_status        - one line per part
#   mission-status.sh tokens  <sid> <root>   mission_status_tokens - per-part token breakdown
#   mission-status.sh morning <sid> <root>   mission_morning       - rewrite <root>/tmp/mission/MORNING.md
#                                                                     and print one summary line for
#                                                                     the PushNotification
# The conductor runs `morning` at every PART-DONE or PART-RETIRED and at any sanctioned stop, so the
# report is always current when the owner wakes. Exit 0 on success, 1 when there is no mission log,
# 2 on usage errors.
#
# INPUTS (contracts; see the plan sections named)
#   LOG       <root>/.mission-backups/MISSION.<sid>.log.<utc>.{gz,txt} (oldest first), then
#             <root>/MISSION.<sid>.log. Lines are `<idtag>\t[mission] <entry>`. Only the current
#             generation counts: entries after the last `MISSION-REBASELINED`.
#             Shapes read (section 6): PART-START (at=), RECIPE (tier= budget=), round lines
#             `part=N name= phase=plan|review round=K`, REVIEW-EVIDENCE (scope=plan|delta|close,
#             round=, head=), SWEEP (instances=), FULL-SUITE (sha=), live-verify (status=
#             sent|ok|fail|n/a, sha=, attempt=, at=), FAIL with park= disposition= range=,
#             PART-DONE, PART-RETIRED, MISSION-CLEARED (status= reason=). A terminal line without
#             at= ends the part at the latest at= on any of its lines.
#   ESCAPES   <root>/.mission-escaped.md, `date | part | found-by | TYPE-KEY | area | ...`.
#   TOKENS    by tag, never by time window. Counted = input + cache-write + output tokens
#             (cache reads are left out: every turn re-reads its whole context).
#             - conductor: <projects>/*/<sid>.jsonl. A turn starts at each real user or wake
#               prompt; it is charged to the last part named (part=N, or an m<N>- idtag) in the
#               mission-write.sh commands it ran. A turn that wrote none is unattributed.
#             - helpers: <projects>/*/<sid>/subagents/*.meta.json; the m<N> tag in "description".
#             - Codex: <root>/tmp/mission/codex-runs.<sid>.tsv, one `<m<N>|->\t<path>` line per
#               run (path relative to <root> or absolute). A file is one run; a directory counts
#               each file in it that has a codex-exec.sh `.status` sidecar. The run's total is
#               the number after its last "tokens used" line; a run without one is "tokens
#               unknown", never zero.
#             Streamed duplicates of one API message (same message id) count once.
#   PUSH LIST ${MISSION_PUSH_QUEUE:-~/.claude/push-queue.md}; a line belongs to a part when its
#             SHA field and the part's freeze SHA share a prefix of 7+ characters.
#   PLANTED   ${MISSION_PLANTED_FILE:-~/.claude/mission-planted.jsonl}; last line
#             {"at": <epoch>, "result": "<caught|missed|invalid>", ...}.
#   WATCHDOG  ${MISSION_LIVENESS_DIR:-~/.claude/progress/mission-liveness}/<sid>.watchdog.<label>
#             (mission-watchdog.sh); only stall / deadline / overdue states are shown.
# Test overrides: MISSION_PROJECTS_DIR (default ~/.claude/projects), MISSION_STATUS_NOW (epoch).
# macOS bash 3.2 compatible; the parsing is python3 (stdlib only).

_mission_status_py() {
  python3 - "$@" <<'PY'
import glob, gzip, json, os, re, sys, time

verb, sid, root = sys.argv[1], sys.argv[2], sys.argv[3]
HOME = os.path.expanduser("~")
NOW = int(os.environ.get("MISSION_STATUS_NOW") or time.time())
PROJECTS = os.environ.get("MISSION_PROJECTS_DIR") or os.path.join(HOME, ".claude", "projects")
PUSHQ = os.environ.get("MISSION_PUSH_QUEUE") or os.path.join(HOME, ".claude", "push-queue.md")
PLANTED = os.environ.get("MISSION_PLANTED_FILE") or os.path.join(HOME, ".claude", "mission-planted.jsonl")
LIVE_DIR = os.environ.get("MISSION_LIVENESS_DIR") or os.path.join(HOME, ".claude", "progress", "mission-liveness")
TAG_RE = re.compile(r"(?<![A-Za-z0-9])m(\d+)(?![0-9])")
KV_RE = re.compile(r"(?:^|\s)([A-Za-z][\w-]*)=(\S+)")


def read_text(path):
    try:
        if path.endswith(".gz"):
            with gzip.open(path, "rt", encoding="utf-8", errors="replace") as f:
                return f.read()
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


# ---------- LOG ----------
def log_entries():
    bk = os.path.join(root, ".mission-backups")
    arch = glob.glob(os.path.join(bk, "MISSION.%s.log.*.gz" % sid)) + glob.glob(os.path.join(bk, "MISSION.%s.log.*.txt" % sid))
    arch.sort(key=lambda p: os.path.basename(p).rsplit(".", 1)[0])
    paths = arch + [p for p in [os.path.join(root, "MISSION.%s.log" % sid)] if os.path.isfile(p)]
    if not paths:
        return None
    out = []
    for p in paths:
        for line in (read_text(p) or "").splitlines():
            entry = line.split("\t", 1)[1] if "\t" in line else line
            if entry.startswith("[mission] "):
                out.append(entry[len("[mission] "):])
    last = -1
    for i, e in enumerate(out):
        if e.startswith("MISSION-REBASELINED"):
            last = i
    return out[last + 1:]


def kv(entry):
    return {k: v for k, v in KV_RE.findall(entry)}


def num(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        return None


class Part:
    def __init__(self, n):
        self.n = n
        self.name = ""
        self.start_at = None
        self.end_at = None
        self.ats = []
        self.recipe = {}
        self.plan = 0
        self.review = 0
        self.closes = set()
        self.sweeps = 0
        self.dirty = 0
        self.live = {}
        self.done = False
        self.park = None
        self.retired = False
        self.started = False
        self.freeze = ""
        self.suite_sha = ""


def parse(entries):
    parts, cleared = {}, None
    for e in entries:
        d = kv(e)
        head = e.split(" ", 1)[0]
        if head == "MISSION-CLEARED":
            cleared = d
            continue
        n = num(d.get("part"))
        if n is None:
            continue
        p = parts.setdefault(n, Part(n))
        at = num(d.get("at"))
        if at is not None:
            p.ats.append(at)
        if d.get("name") and not p.name:
            p.name = d["name"]
        rnd = num(d.get("round")) or 0
        if head == "PART-START":
            p.started = True
            p.start_at = at
            p.name = d.get("name", p.name)
        elif head == "RECIPE":
            if (num(d.get("v")) or 0) >= (num(p.recipe.get("v")) or 0):
                p.recipe = d
        elif head.startswith("part="):
            if d.get("phase") == "plan":
                p.plan = max(p.plan, rnd)
            elif d.get("phase") == "review":
                p.review = max(p.review, rnd)
        elif head == "REVIEW-EVIDENCE":
            scope = d.get("scope", "delta")
            if scope == "plan":
                p.plan = max(p.plan, rnd)
            elif scope == "close":
                p.closes.add(rnd)
                p.freeze = d.get("head") or d.get("sha") or p.freeze
            else:
                p.review = max(p.review, rnd)
        elif head == "SWEEP":
            p.sweeps += 1
            if (num(d.get("instances")) or 0) > 0:
                p.dirty += 1
        elif head == "FULL-SUITE":
            p.suite_sha = d.get("sha", p.suite_sha)
        elif head == "live-verify":
            key = (d.get("sha", ""), d.get("attempt", ""))
            rec = p.live.setdefault(key, {})
            if d.get("status") == "sent":
                rec["sent"] = at
            elif d.get("status") in ("ok", "fail"):
                rec["result"] = at
        elif head == "FAIL" and "park" in d:
            p.park = d
            p.end_at = p.end_at or at
        elif head == "PART-DONE":
            p.done = True
            p.end_at = at or p.end_at
        elif head == "PART-RETIRED":
            p.retired = True
            if p.end_at is None:
                p.end_at = at
    started = [n for n, p in parts.items() if p.started]
    top = max(started) if started else 0
    for p in parts.values():
        p.freeze = (p.freeze or p.suite_sha)[:12]
        if p.done:
            p.outcome = "done"
        elif p.park:
            p.outcome = "parked"
        elif p.retired:
            p.outcome = "retired"
        elif p.started:
            p.outcome = "open"
        elif p.n < top:
            p.outcome = "deferred"
        else:
            p.outcome = "queued"
    return parts, cleared


def wall(p):
    if p.start_at is None:
        return None
    if p.outcome == "open":
        end = NOW
    else:
        end = p.end_at if p.end_at is not None else max(p.ats or [p.start_at])
    return max(0, end - p.start_at) // 60


def live_wait(p):
    total, waiting = 0, False
    for rec in p.live.values():
        s = rec.get("sent")
        if s is None:
            continue
        if rec.get("result") is not None:
            total += max(0, rec["result"] - s)
        elif p.outcome == "open":
            total += max(0, NOW - s)
            waiting = True
    return total // 60, waiting


def escapes():
    counts = {}
    for line in (read_text(os.path.join(root, ".mission-escaped.md")) or "").splitlines():
        f = [x.strip() for x in line.split("|")]
        if len(f) < 3 or line.lstrip().startswith("#"):
            continue
        m = re.search(r"\d+", f[1])
        if m:
            counts[int(m.group())] = counts.get(int(m.group()), 0) + 1
    return counts


# ---------- TOKENS ----------
def usage_total(u):
    return sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "output_tokens"))


def jsonl_rows(path):
    for line in (read_text(path) or "").splitlines():
        try:
            yield json.loads(line)
        except ValueError:
            continue


def is_prompt(row):
    c = (row.get("message") or {}).get("content")
    if isinstance(c, str):
        return True
    return isinstance(c, list) and any(isinstance(b, dict) and b.get("type") != "tool_result" for b in c)


def tagged_part(text):
    m = TAG_RE.search(text or "")
    return int(m.group(1)) if m else None


def tokens():
    """returns ({part|None: {"conductor":n,"helpers":n,"codex":n,"unknown":n}}, have_transcript)"""
    tot = {}

    def add(part, kind, n):
        tot.setdefault(part, {"conductor": 0, "helpers": 0, "codex": 0, "unknown": 0})[kind] += n

    mains = sorted(glob.glob(os.path.join(PROJECTS, "*", sid + ".jsonl")))
    if mains:
        seen, turn_tok, turn_part = set(), 0, None
        for row in jsonl_rows(mains[0]):
            if row.get("isSidechain"):
                continue
            if row.get("type") == "user" and is_prompt(row):
                if turn_tok:
                    add(turn_part, "conductor", turn_tok)
                turn_tok, turn_part = 0, None
            elif row.get("type") == "assistant":
                msg = row.get("message") or {}
                mid = msg.get("id")
                if mid not in seen:
                    seen.add(mid)
                    turn_tok += usage_total(msg.get("usage") or {})
                for b in msg.get("content") or []:
                    if not isinstance(b, dict) or b.get("type") != "tool_use":
                        continue
                    cmd = str((b.get("input") or {}).get("command") or "")
                    if "mission-write.sh" not in cmd:
                        continue
                    after = cmd.split("mission-write.sh", 1)[1]
                    nums = re.findall(r"part=(\d+)", after)
                    tp = int(nums[-1]) if nums else tagged_part(after)
                    if tp is not None:
                        turn_part = tp
        if turn_tok:
            add(turn_part, "conductor", turn_tok)
    for meta in sorted(glob.glob(os.path.join(PROJECTS, "*", sid, "subagents", "*.meta.json"))):
        try:
            desc = json.loads(read_text(meta) or "{}").get("description", "")
        except ValueError:
            desc = ""
        seen, n = set(), 0
        for row in jsonl_rows(meta[: -len(".meta.json")] + ".jsonl"):
            msg = row.get("message") or {}
            if row.get("type") == "assistant" and msg.get("id") not in seen:
                seen.add(msg.get("id"))
                n += usage_total(msg.get("usage") or {})
        add(tagged_part(desc), "helpers", n)
    idx = os.path.join(root, "tmp", "mission", "codex-runs.%s.tsv" % sid)
    for line in (read_text(idx) or "").splitlines():
        if "\t" not in line:
            continue
        tag, path = line.split("\t", 1)
        part = tagged_part(tag)
        path = path.strip()
        path = path if os.path.isabs(path) else os.path.join(root, path)
        if os.path.isdir(path):
            runs = [os.path.join(path, f) for f in sorted(os.listdir(path))
                    if os.path.isfile(os.path.join(path, f + ".status"))]
        else:
            runs = [path]
        for r in runs:
            lines = (read_text(r) or "").splitlines()
            total = None
            for i, l in enumerate(lines):
                if l.strip() == "tokens used" and i + 1 < len(lines):
                    v = num(lines[i + 1].strip().replace(",", ""))
                    if v is not None:
                        total = v
            if total is None:
                add(part, "unknown", 1)
            else:
                add(part, "codex", total)
    return tot, bool(mains)


def human(n):
    if n < 1000:
        return str(n)
    if n < 10000:
        return "%.1fk" % (n / 1000.0)
    if n < 1000000:
        return "%dk" % (n // 1000)
    return "%.1fM" % (n / 1000000.0)


def tok_sum(t):
    return t["conductor"] + t["helpers"] + t["codex"]


def unknown_note(k):
    return " (+%d codex run%s, tokens unknown)" % (k, "" if k == 1 else "s") if k else ""


# ---------- shared views ----------
def push_queue():
    rows = []
    for line in (read_text(PUSHQ) or "").splitlines():
        if line.lstrip().startswith("#"):
            continue
        f = [x.strip() for x in line.split("|")]
        if len(f) < 6 or not f[3]:
            continue
        rows.append({"sha": f[3].split()[0], "status": " | ".join(f[5:]), "line": line.strip()})
    return rows


def queue_for(sha, rows):
    if len(sha) < 7:
        return None
    hit = None
    for r in rows:
        s = r["sha"]
        if len(s) >= 7 and (s.startswith(sha) or sha.startswith(s)):
            hit = r
    return hit


def watchdog_problems():
    out = []
    for f in sorted(glob.glob(os.path.join(LIVE_DIR, sid + ".watchdog.*"))):
        if f.endswith(".done") or ".tmp." in f:
            continue
        d = kv(read_text(f) or "")
        st = d.get("state")
        if st in ("stall", "deadline", "overdue"):
            out.append((d.get("label", os.path.basename(f)), st))
    return out


def planted():
    lines = [l for l in (read_text(PLANTED) or "").splitlines() if l.strip()]
    if not lines:
        return "planted-bug: never run"
    try:
        d = json.loads(lines[-1])
    except ValueError:
        return "planted-bug: unreadable record"
    at = num(d.get("at"))
    when = time.strftime("%Y-%m-%d", time.localtime(at)) if at else "date unknown"
    return "planted-bug: %s (%s)" % (d.get("result", "unknown"), when)


def mission_state(cleared):
    if not cleared:
        return "active"
    return "stopped (%s, %s)" % (cleared.get("status", "?"), cleared.get("reason", "?"))


def counts_text(parts):
    order = ["done", "parked", "retired", "deferred", "open", "queued"]
    c = {}
    for p in parts.values():
        c[p.outcome] = c.get(p.outcome, 0) + 1
    return ", ".join("%d %s" % (c[o], o) for o in order if c.get(o))


def part_line(p, tok, esc, have_tx):
    oc = p.outcome
    if p.park:
        oc = "parked (%s, %s, range %s)" % (p.park.get("park", "?"), p.park.get("disposition", "?"), p.park.get("range", "?"))
    w = wall(p)
    budget = p.recipe.get("budget")
    wt = "-" if w is None else ("%dm/%sm" % (w, budget) if budget else "%dm" % w)
    lw, waiting = live_wait(p)
    t = tok.get(p.n, {"conductor": 0, "helpers": 0, "codex": 0, "unknown": 0})
    tt = human(tok_sum(t)) + unknown_note(t["unknown"])
    sw = "%d (%d dirty)" % (p.sweeps, p.dirty) if p.dirty else str(p.sweeps)
    return "part %d %s: %s | tier %s | wall %s | live %dm%s | tokens %s | plan %d review %d close %d | sweeps %s | escapes %d" % (
        p.n, p.name or "?", oc, p.recipe.get("tier", "-"), wt, lw, " (waiting)" if waiting else "",
        tt, p.plan, p.review, len(p.closes), sw, esc.get(p.n, 0))


def status_lines(parts, cleared, tok, have_tx):
    esc = escapes()
    out = ["mission %s: %s, %d parts (%s)" % (sid, mission_state(cleared), len(parts), counts_text(parts))]
    for n in sorted(parts):
        out.append(part_line(parts[n], tok, esc, have_tx))
    un = tok.get(None)
    if un:
        out.append("unattributed tokens: %s%s" % (human(tok_sum(un)), unknown_note(un["unknown"])))
    if not have_tx:
        out.append("conductor and helper tokens unknown (no transcript) for %s" % sid)
    for label, st in watchdog_problems():
        why = "past its deadline, still progressing; note only" if st == "overdue" else "stop the helper"
        out.append("watchdog %s: %s (%s)" % (label, st, why))
    out.append(planted())
    return out


# ---------- verbs ----------
entries = log_entries()
if entries is None:
    sys.stderr.write("mission-status: no mission log for %s in %s\n" % (sid, root))
    sys.exit(1)
parts, cleared = parse(entries)
tok, have_tx = tokens()

if verb == "status":
    print("\n".join(status_lines(parts, cleared, tok, have_tx)))

elif verb == "tokens":
    for k in sorted([k for k in tok if k is not None]) + ([None] if None in tok else []):
        t = tok[k]
        extra = "; %d codex run%s tokens unknown" % (t["unknown"], "" if t["unknown"] == 1 else "s") if t["unknown"] else ""
        print("%s: %d (conductor %d, helpers %d, codex %d%s)" % (
            "unattributed" if k is None else "part %d" % k, tok_sum(t), t["conductor"], t["helpers"], t["codex"], extra))
    if not have_tx:
        print("conductor and helper tokens unknown (no transcript) for %s" % sid)

elif verb == "morning":
    rows = push_queue()
    lines = status_lines(parts, cleared, tok, have_tx)
    landed, waiting, missing, stack, parked, deferred = [], [], [], [], [], []
    for n in sorted(parts):
        p = parts[n]
        label = "part %d %s" % (n, p.name or "?")
        if p.outcome == "done":
            q = queue_for(p.freeze, rows)
            ref = "%s (%s)" % (label, p.freeze or "freeze SHA unknown")
            if q and q["status"].startswith("landed"):
                landed.append(ref)
                continue
            if q:
                waiting.append((ref, q["line"]))
            else:
                missing.append(ref)
            stack.append("part %d (%s)" % (n, p.freeze or "?"))
        elif p.outcome == "parked":
            parked.append("%s - %s; disposition %s; range %s" % (
                label, p.park.get("park", "?"), p.park.get("disposition", "?"), p.park.get("range", "?")))
        elif p.outcome == "deferred":
            deferred.append(label)
    wd = watchdog_problems()
    needs = []
    for ref, qline in waiting:
        needs.append("- Waiting on the push list: %s" % ref)
        needs.append("    %s" % qline)
    needs += ["- Not on the push list yet: %s" % r for r in missing]
    if len(stack) > 0:
        needs.append("- Stacked unlanded parts, in order: %s. Declining an earlier one means the later ones need a rebase." % ", ".join(stack))
    needs += ["- Parked: %s" % r for r in parked]
    needs += ["- Deferred: %s (a part it needs did not finish)" % r for r in deferred]
    needs += ["- Watchdog: %s %s" % (l, s) for l, s in wd]
    summary = "Mission %s: %s." % (sid, counts_text(parts))
    asks = []
    if waiting or missing:
        asks.append("%d push approval%s waiting" % (len(waiting) + len(missing), "" if len(waiting) + len(missing) == 1 else "s"))
    if parked:
        asks.append("%d parked" % len(parked))
    if wd:
        asks.append("%d stuck helper%s" % (len(wd), "" if len(wd) == 1 else "s"))
    if asks:
        summary += " Needs you: " + ", ".join(asks) + "."
    body = ["# Mission morning report - %s" % sid,
            "Updated %s. Mission state: %s." % (time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(NOW)), mission_state(cleared)),
            summary, "", "## Parts"]
    body += ["- " + l for l in lines[1:] if l.startswith("part ")]
    body += ["", "## Landed"] + (["- Landed: %s" % r for r in landed] or ["- nothing yet"])
    body += ["", "## Needs you"] + (needs or ["- nothing"])
    body += ["", "## Other"] + ["- " + l for l in lines[1:] if not l.startswith("part ") and not l.startswith("watchdog ")]
    d = os.path.join(root, "tmp", "mission")
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".MORNING.md.%d" % os.getpid())
    with open(tmp, "w") as f:
        f.write("\n".join(body) + "\n")
    os.replace(tmp, os.path.join(d, "MORNING.md"))
    print(summary + " Report: " + os.path.join(d, "MORNING.md"))
else:
    sys.stderr.write("mission-status: unknown verb %s\n" % verb)
    sys.exit(2)
PY
}

mission_status()        { _mission_status_py status "$1" "$2"; }
mission_status_tokens() { _mission_status_py tokens "$1" "$2"; }
mission_morning()       { _mission_status_py morning "$1" "$2"; }

# Run directly: dispatch the verb. Sourced: only define the functions.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    status|tokens|morning)
      [ $# -eq 3 ] && [ -n "$2" ] && [ -d "$3" ] || { echo "usage: mission-status.sh <status|tokens|morning> <sid> <root>" >&2; exit 2; }
      _mission_status_py "$1" "$2" "$3"; exit $? ;;
    *) echo "usage: mission-status.sh <status|tokens|morning> <sid> <root>" >&2; exit 2 ;;
  esac
fi
