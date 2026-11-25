#!/usr/bin/env python3
"""rd-measure: the pool's turnaround numbers for one time window, the same way every time (2026-11-21,
the before/after check of "place by net time": the cold-setup veto removed).

    rd-measure.py --hours 10                      # the last 10 h
    rd-measure.py --since "2026-11-21 21:50"      # from a local time to now (--until for an end)
    rd-measure.py --since ... --logs DIR          # reuse logs fetched before (--keep DIR saves them)

Read-only on the pool. It fetches (ssh cat) every client's route.log (+ .1) - this Mac and --client
aliases (default nickmini-docker) - and every fleet.json worker's ~/rr/log/runs.log (+ .1) (--fleet: another
fleet.json, e.g. the one in force in an old window). Log cache (2026-11-24): every fetched log is merged
into ~/.local/state/rdocker/logcache/<runs.W|route.C>.log (rd_logcache: append-only, deduped by record,
never loses a line; the warm daemon also mirrors reachable workers' runs.log there every 30 min), and
the report reads that copy, so lines older than the remote's rotation still count. A machine that does
not answer is read from the cache alone and listed as CACHE ONLY with the age of its newest line; with
no copy either it is listed as NOT READ and skipped. `--cache ''` turns the cache off; --logs never
touches it. Per job class (runs.log cls: light / normal / heavy / db / build):

  queue wait      slot_s + lock_s of each started job (runs.log), p50 / p90
  submit->finish  the client's wall seconds of each rrun (route.log "rc=N S s"), joined to its
                  runs.log row (same worker, same pred_s, end within JOIN_S) for the class, p50 / p95
  jobs per worker started commands (outcome rc=N, incl. timeout / lost / interrupted)
  cold            jobs whose setup was cold (npm install ran: setup=cold); clone = from the store
  cold estimate   for cold jobs: actual prepare_s vs the logged setup estimate spred_s (runs.log, from
                  the client that logs it) and cmd_s vs pred_s

Wasted capacity (owner, 2026-11-21): a per-minute timeline rebuilt from runs.log. Busy = a slot held
by a started run or a warm ([end - cmd_s - prepare_s, end]); waiting = a job's slot_s + lock_s before
that (incl. runs that then moved or were abandoned). A worker counts at a minute only when it is
enabled in fleet.json and online (busy then, or a started / warm runs.log row in the ONLINE_S before
it, up to 5 min after - never judged on later rows; a busy / refused / moved row is a worker turning
work away, not capacity: 2026-11-24, airm4's refusals had counted as idle slots). Weighted utilization =
sum(busy slots x speed) / sum(max_slots x speed), speed = fleet.json `speed` (the bench speed rd_pool's
Model falls back to and calibrates its learned per-kind ratios on; the live ~/rr/speed is not
logged), busy capped at max_slots. Backlog = jobs waiting at that minute. Headline: idle-while-waiting
minutes = backlog >= 1 and utilization < 80 %, with the weighted idle capacity then (slot-minutes x
speed, and plain slot-minutes); plus utilization and backlog p50 / p90 over the window.

Headline first (owner): 1. jobs finished per hour across the pool (started runs.log commands that
ended in the window / its hours), 2. time per job, submit to finish (route.log wall seconds of every
rrun on both clients, cache hits included): average and median, 3. the idle-while-waiting minutes.

Time per job (owner, 2026-11-21), comparable before / after: rrun jobs (route.log joined to runs.log)
grouped by repo + normalized command (norm_cmd: file / path arguments, `--shard` values and the words
after a `--` that are not flags are dropped, so `npm run test:db -- a.ts b` is `npm run test:db`). Per
group with >= GROUP_MIN runs: submit->finish p50 / p90, its parts (wait = slot_s + lock_s, setup =
prepare_s, run = cmd_s; p50 each) and the worker mix. `--save F` writes this run's JSON; `--compare F`
(a saved BEFORE) prints each group with >= GROUP_MIN runs in both windows and ONE pool-wide number:
the median over those groups of the change in submit->finish p50 (a job-mix shift cannot fake a win).

Replay (the hp queue spikes): every hp job that waited >= --spike-s for a slot is re-placed on the
other workers as they were then (slots busy from their runs.log), WITHOUT the cold veto: a worker is
a candidate when its fleet classes / heavy_slots take the job and it had a free slot of the kind. Its
finish = its setup (warm if it ran this repo in the prior 48 h, else cold: its measured prepare p75 of
that kind, else 2 s / 90 s) + the run there (its own median of the command, else hp's run x the
paired-command ratio, x 1.25 uncertain) + 15 % for an optional worker; one over its max_cost_s must
win by 25 % + 15 s (rd_pool.slow_wins). It wins when that beats what hp really took from arrival
(slot wait + prepare + run). A won slot is held for the replayed run, so one idle slot is not counted
twice. "veto" marks a win the old rule forbade (cold there and its cold p75 over 60 s). The logs do
not say which lockfile a worker had prepared, so the replay is bounded: `replay` calls a worker warm
when it ran this repo in the prior 48 h (optimistic), `replay_strict` only when it ran the same client
worktree (wt=) there (pessimistic); `_mini_db` adds db to the minis' classes. A replay candidate must
be online by the same started / warm rule as the timeline.

Interrupted runs (2026-11-24, research P10): runs.log rows ended by a signal or a lost link - outcome
`interrupted ...`, `lost ...`, or rc 130 / 137 / 143 - with their job-hours (prepare + run), by kind;
cap kills (`timeout rc=124`) beside them. Of those, how many had an identical successor: a run of the
same repo + argv (from the same owner session - a real `session:` id - or from any) whose arrival (end
- run - prepare - slot wait - lock wait) is after the interrupted run's arrival (it arrived while that
one ran) and at most SUCCESSOR_S after its end, on any worker, under another run id (not rrun's own
retry). A "join the in-flight identical run" feature could save, per such run, min(its work, the
rerun's work): the thrown-away work that was then redone (an upper bound). argv is runs.log's display
form (redacted, cut at ~120 chars), so near-identical commands can compare equal. route.log times are
read in this Mac's zone (every client is in the same one today).

Worker contention (research section 5, the hp table): each finished run (rc 0 / 1, run >= 5 s) gets the
mean number of slots busy on its worker during its run phase (itself included; started runs and warms,
prepare included), bucketed <= 3 / 4-6 / 7+. Per worker and repo + norm_cmd group: run p50 per bucket,
and the slowdown 4-6 vs <= 3 and 7+ vs <= 3 where both buckets have >= CONT_MIN runs; the worker's
headline is the median slowdown over those groups. An estimate: cmd_s runs to the runner's final log
line (cleanup included) and the group key is norm_cmd (file arguments dropped), so one group can mix a
few different test files.
"""
import argparse
import bisect
import datetime as dt
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import rd_logcache  # noqa: E402  (stdlib only)

FLEET = os.path.join(HERE, "..", "fleet.json")
CLASSES = ("light", "normal", "heavy", "db", "build")
JOIN_S = 90.0
COLD_BUDGET_OLD = 60.0
STARTED = re.compile(r"^(?:(?:timeout|lost|interrupted) )?rc=\d+$")
RUNS_RE = re.compile(r"^(\S+) repo=(\S*) wt=(\S*) sha=\S* outcome=(.+?) prepare_s=(\S+) cmd_s=(\S+) argv=([^\t\n]*)(?:\t(.*))?$")
ROUTE_HEAD = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (\S+)\s+(\S+)\s+(.*)$", re.S)
ROUTE_RRUN = re.compile(r"rc=(\d+) ([\d.]+)s \| ([^\t]*)(?:\t(.*))?$", re.S)


def num(v, d=None):
    try:
        return float(v)
    except (TypeError, ValueError):
        return d


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(q * len(xs)))] if xs else None


def med(xs):
    xs = sorted(xs)
    n = len(xs)
    return None if not n else xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


def mmss(v):
    return "-" if v is None else "%dm %02ds" % (int(v) // 60, int(round(v)) % 60)


def fs(v):
    return "-" if v is None else "%.0f" % v if v >= 10 else "%.1f" % v


def fetch(alias, paths, timeout=12):
    """-> text of the files (older first) or None when the machine did not answer."""
    cmd = "; ".join("cat %s 2>/dev/null" % p for p in paths) + "; true"
    if alias is None:
        return subprocess.run(["sh", "-c", cmd], capture_output=True, text=True, errors="replace").stdout
    try:
        r = subprocess.run(["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes", alias, cmd],
                           capture_output=True, text=True, errors="replace", timeout=timeout * 10)
    except subprocess.TimeoutExpired:
        return None
    return r.stdout if r.returncode == 0 else None


def parse_runs(text, worker):
    rows = []
    for line in text.splitlines():
        m = RUNS_RE.match(line)
        if not m:
            continue
        t, repo, wt, out, ps, cs, argv, tail = m.groups()
        try:
            end = dt.datetime.strptime(t, "%Y-%m-%dT%H:%M:%S%z").timestamp()
        except ValueError:
            continue
        kv = dict(x.split("=", 1) for x in (tail or "").split(" ") if "=" in x)
        rows.append({"w": worker, "end": end, "repo": repo, "wt": wt, "out": out, "prep": num(ps, 0.0), "cmd": num(cs, 0.0),
                     "argv": re.sub(r" \[cpu_share=[^\]]*\]$", "", argv), "cls": kv.get("cls", "-"),
                     "setup": kv.get("setup", "-"), "slot": num(kv.get("slot_s"), 0.0),
                     "lock": num(kv.get("lock_s"), 0.0), "pred": num(kv.get("pred_s")),
                     "spred": num(kv.get("spred_s")), "started": bool(STARTED.match(out)),
                     "run": kv.get("run"), "owner": kv.get("owner")})
    return rows


def parse_route(text, client):
    """-> rrun entries; an entry spans lines when its command had newlines (a line not starting with a date)."""
    ents, cur = [], None
    for line in text.splitlines():
        if re.match(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d ", line):
            if cur is not None:
                ents.append(cur)
            cur = line
        elif cur is not None:
            cur += "\n" + line
    if cur is not None:
        ents.append(cur)
    out = []
    for e in ents:
        m = ROUTE_HEAD.match(e)
        if not m or m.group(3) != "rrun":
            continue
        r = ROUTE_RRUN.search(m.group(4))
        if not r:
            continue
        kv = dict(x.split("=", 1) for x in (r.group(4) or "").split() if "=" in x)
        end = dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").timestamp()   # the client's local zone
        out.append({"client": client, "end": end, "host": m.group(2), "rc": int(r.group(1)), "wall": float(r.group(2)),
                    "pred": num(kv.get("pred_s")), "slot": num(kv.get("slot_s"), 0.0), "lock": num(kv.get("lock_s"), 0.0),
                    "start": num(kv.get("start_s"))})
    return out


def join(route, runs):
    """Each route entry -> its runs.log row (same worker, same pred_s, nearest end within JOIN_S)."""
    by = {}
    for r in runs:
        if r["started"]:
            by.setdefault(r["w"], []).append(r)
    used = set()
    for e in route:
        best = None
        for r in by.get(e["host"], ()):
            d = e["end"] - r["end"]
            if -5 <= d <= JOIN_S and id(r) not in used and (e["pred"] is None or r["pred"] is None or abs(e["pred"] - r["pred"]) < 0.15):
                if best is None or abs(d) < abs(e["end"] - best["end"]):
                    best = r
        if best is not None:
            used.add(id(best))
        e["row"] = best


def busy_at(rows, t, heavy=False):
    """Slots held at time t on one worker (started runs and warms: [end - cmd - prepare, end])."""
    n = 0
    for r in rows:
        if (r["started"] or r["out"] == "warm") and r["end"] - r["cmd"] - r["prep"] <= t < r["end"]:
            if not heavy or r["cls"] == "heavy":
                n += 1
    return n


GROUP_MIN = 5


def norm_cmd(argv):
    """`npx vitest run src/a.test.ts --shard=2/4` -> `npx vitest run`; see the module doc."""
    out, after = [], False
    for t in argv.replace("...", " ").split():
        if t == "--":
            after = True
            continue
        if out and out[-1] == "node" and "/" in t and not after:
            out.append(os.path.basename(t))             # node scripts/run-guard-tier.mjs: the script names it
            continue
        if t.startswith("--shard") or "/" in t or re.search(r"\.(test|spec|db)\.|\.[cm]?[jt]sx?$", t):
            continue
        if after and not t.startswith("-"):
            continue
        out.append(t)
    return " ".join(out)[:80]


def groups(route):
    g = {}
    for e in route:
        r = e["row"]
        if r is not None:
            g.setdefault("%s | %s" % (r["repo"].split(".")[0], norm_cmd(r["argv"])), []).append((e, r))
    res = {}
    for k, xs in g.items():
        if len(xs) < GROUP_MIN:
            continue
        mix = {}
        for _, r in xs:
            mix[r["w"]] = mix.get(r["w"], 0) + 1
        res[k] = {"n": len(xs), "s2f_p50": pct([e["wall"] for e, _ in xs], 0.5), "s2f_p90": pct([e["wall"] for e, _ in xs], 0.9),
                  "wait_p50": pct([r["slot"] + r["lock"] for _, r in xs], 0.5), "setup_p50": pct([r["prep"] for _, r in xs], 0.5),
                  "run_p50": pct([r["cmd"] for _, r in xs], 0.5), "mix": mix}
    return res


ONLINE_S = 3600.0
UTIL_IDLE = 0.8


REFUSED = re.compile(r"^(?:busy|refused|off)\b")


def online_index(rows):
    """One worker's rows -> what online() reads: the sorted ends of rows that show it taking work
    (started runs and warms) and of its refusals (busy / refused / off: the worker turning a job away -
    its owner's load guard or share switch - never capacity). Other rows (moved, abandoned-setup, lost
    before a start) say nothing either way."""
    return (sorted(r["end"] for r in rows if r["started"] or r["out"] == "warm"),
            sorted(r["end"] for r in rows if REFUSED.match(r["out"])))


def online(idx, t):
    """A worker counts as online at t when it logged a started / warm row in the hour before (or within
    5 min after), and no refusal in that hour came after its latest started / warm row before t (only
    taking work again clears a refusal). Never judged on rows from later alone (a worker that came
    online at 21:50 was no idle capacity at 21:00)."""
    ok, refused = idx
    i = bisect.bisect_left(ok, t - ONLINE_S)
    if not (i < len(ok) and ok[i] <= t + 300):
        return False
    j = bisect.bisect_right(refused, t) - 1
    if j < 0 or refused[j] < t - ONLINE_S:
        return True
    k = bisect.bisect_right(ok, t) - 1
    return k >= 0 and ok[k] > refused[j]


def timeline(runs, fleet, lo, hi):
    ms = {m["name"]: m for m in fleet["machines"] if "worker" in (m.get("roles") or []) and m.get("enabled", True)}
    byw = {}
    for r in runs:
        if r["w"] in ms:
            byw.setdefault(r["w"], []).append(r)
    busy_iv, wait_iv, seen = {w: [] for w in ms}, [], {w: online_index(rs) for w, rs in byw.items()}
    for w, rs in byw.items():
        for r in rs:
            b0 = r["end"] - (r["cmd"] if r["started"] else 0.0) - r["prep"]
            if r["started"] or r["out"] == "warm":
                busy_iv[w].append((b0, r["end"]))
            q = r["slot"] + r["lock"]
            if q > 0 and r["out"] != "warm":
                wait_iv.append((b0 - q, b0))
    mins = []
    t = lo + 30.0
    while t < hi:
        cap = used = 0.0
        slots_idle = 0
        for w, m in ms.items():
            n, sp = m.get("max_slots", 1), float(m.get("speed", 1.0))
            b = min(n, sum(1 for a, z in busy_iv[w] if a <= t < z))
            if not b and not online(seen.get(w) or ([], []), t):
                continue                                        # offline (or no log) at this minute
            cap += n * sp
            used += b * sp
            slots_idle += n - b
        back = sum(1 for a, z in wait_iv if a <= t < z)
        mins.append((used / cap if cap else None, back, cap - used, slots_idle))
        t += 60.0
    util = [u for u, _, _, _ in mins if u is not None]
    bad = [x for x in mins if x[0] is not None and x[1] >= 1 and x[0] < UTIL_IDLE]
    return {"minutes": len(mins), "util_p50": pct(util, 0.5), "util_p90": pct(util, 0.9),
            "backlog_p50": pct([b for _, b, _, _ in mins], 0.5), "backlog_p90": pct([b for _, b, _, _ in mins], 0.9),
            "backlog_max": max([b for _, b, _, _ in mins] or [0]),
            "idle_while_waiting_min": len(bad), "idle_weighted_slot_min": sum(x[2] for x in bad),
            "idle_slot_min": sum(x[3] for x in bad),
            "util_in_those_p50": pct([x[0] for x in bad], 0.5), "backlog_in_those_p50": pct([x[1] for x in bad], 0.5),
            "speed": {w: m.get("speed", 1.0) for w, m in ms.items()}}


def replay(runs, fleet, lo, hi, spike_s, mini_db, strict=False):
    ms = {m["name"]: m for m in fleet["machines"] if "worker" in (m.get("roles") or []) and m.get("enabled", True)}
    byw = {}
    for r in runs:
        byw.setdefault(r["w"], []).append(r)
    if "hp" not in ms:
        return [], []                        # a fleet with no enabled hp: nothing to replay
    hp = [r for r in byw.get("hp", []) if r["started"] and lo <= r["end"] <= hi and r["slot"] >= spike_s]
    hp.sort(key=lambda r: r["end"] - r["cmd"] - r["prep"] - r["slot"])
    medcmd = {}
    for r in runs:
        if r["out"] in ("rc=0", "rc=1"):
            medcmd.setdefault((r["w"], r["repo"], r["argv"]), []).append(r["cmd"])

    def ratio(w):
        rs = [med(v) / med(medcmd[("hp", k[1], k[2])]) for k, v in medcmd.items()
              if k[0] == w and ("hp", k[1], k[2]) in medcmd and med(medcmd[("hp", k[1], k[2])]) > 1]
        if len(rs) >= 3:
            return med(rs)
        return ms["hp"].get("speed", 1) / max(0.01, ms[w].get("speed", 1))
    ratios = {w: ratio(w) for w in ms if w != "hp" and w in byw}
    seen = {w: online_index(rs) for w, rs in byw.items()}
    held = {w: [] for w in ms}
    res = []
    for j in hp:
        arrive = j["end"] - j["cmd"] - j["prep"] - j["slot"]
        actual = j["slot"] + j["prep"] + j["cmd"]
        cands = []
        for w, m in ms.items():
            if w == "hp" or w not in byw:
                continue
            classes = list(m.get("classes") or CLASSES)
            if mini_db and w.startswith("mini") and "db" not in classes:
                classes.append("db")
            if j["cls"] not in classes or (j["cls"] == "heavy" and m.get("heavy_slots") == 0):
                continue
            rows = byw[w]
            if not busy_at(rows, arrive) and not online(seen[w], arrive):
                continue                                                 # not up then
            used = busy_at(rows, arrive) + sum(1 for a, b in held[w] if a <= arrive < b)
            if used >= m.get("max_slots", 1):
                continue
            if j["cls"] == "heavy" and busy_at(rows, arrive, True) >= m.get("heavy_slots", 99):
                continue
            prior = [r for r in rows if arrive - 14 * 86400 <= r["end"] < arrive]
            warm = any(r["repo"] == j["repo"] and (not strict or r["wt"] == j["wt"]) and r["end"] >= arrive - 48 * 3600
                       for r in prior)
            kind = [r["prep"] for r in prior if (r["setup"] == "cold") != warm and r["setup"] in ("cold", "warm", "clone")]
            setup = pct(kind, 0.75) if len(kind) >= 3 else (2.0 if warm else 90.0)
            cold_p75 = pct([r["prep"] for r in prior if r["setup"] == "cold"], 0.75)
            own = medcmd.get((w, j["repo"], j["argv"]))
            run = med(own) if own and len(own) >= 3 else j["cmd"] * ratios.get(w, 2.0) * 1.25
            eta = setup + run
            score = eta * (1.15 if m.get("optional") else 1.0)
            need = actual
            if m.get("max_cost_s") is not None and run > m["max_cost_s"]:
                need = actual - (0.25 * actual + 15)
            if score <= need:
                cands.append((score, w, eta, run, setup, not warm, (not warm) and (cold_p75 or 0) > COLD_BUDGET_OLD))
        if cands:
            score, w, eta, run, setup, cold, veto = min(cands)
            held[w].append((arrive, arrive + eta))
            res.append({"j": j, "w": w, "eta": eta, "actual": actual, "saved": actual - eta, "cold": cold, "veto": veto})
    return hp, res


SUCCESSOR_S = 600.0
SIGNAL_RC = (130, 137, 143)
RC_TAIL = re.compile(r"rc=(\d+)$")


def interrupted_kind(r):
    """-> how a runs.log row was cut short (`interrupted rc=130`, `lost rc=143`, `lost`, `rc=143`, ...),
    or None for a run that ended by itself (cap kills `timeout rc=124` included: counted beside)."""
    o = r["out"]
    if o.startswith(("interrupted", "lost")):
        return o
    m = RC_TAIL.search(o)
    return o if m and not o.startswith("timeout") and int(m.group(1)) in SIGNAL_RC else None


def arrival(r):
    return r["end"] - r["cmd"] - r["prep"] - r["slot"] - r["lock"]


def interrupted(runs, route, lo, hi):
    """Interrupted runs ending in [lo, hi], their job-hours, and those with an identical successor (the
    module doc). Successors come from every worker and may start after hi. `client_side`: the rruns the
    client saw end rc 130 / 143 (route.log, every host incl. workers with no runs.log; job-h = wall -
    start_s, which already holds the slot and lock waits; a row with no start_s has no job-h)."""
    attempts = {}
    for r in runs:
        if r["started"] or interrupted_kind(r):
            attempts.setdefault((r["repo"], r["argv"]), []).append(r)
    for xs in attempts.values():
        xs.sort(key=arrival)
    rows = [r for r in runs if lo <= r["end"] <= hi and interrupted_kind(r)]
    by_kind, same, anys, save = {}, [], [], {"same": 0.0, "any": 0.0}
    work = lambda x: x["prep"] + x["cmd"]  # noqa: E731
    for r in rows:
        k = by_kind.setdefault(interrupted_kind(r), {"n": 0, "job_h": 0.0})
        k["n"] += 1
        k["job_h"] += (r["prep"] + r["cmd"]) / 3600.0
        a0, horizon = arrival(r), r["end"] + SUCCESSOR_S
        succ = [x for x in attempts.get((r["repo"], r["argv"]), ())
                if x is not r and (x["run"] is None or x["run"] != r["run"]) and a0 < arrival(x) <= horizon]
        if succ:                     # the redone work: at most the thrown-away run's, at most the rerun's
            anys.append(r)
            save["any"] += min(work(r), max(work(x) for x in succ))
            own = [x for x in succ if (r["owner"] or "").startswith("session:") and x["owner"] == r["owner"]]
            if own:
                same.append(r)
                save["same"] += min(work(r), max(work(x) for x in own))
    caps = [r for r in runs if lo <= r["end"] <= hi and r["out"].startswith("timeout")]
    jh = lambda xs: sum(x["prep"] + x["cmd"] for x in xs) / 3600.0  # noqa: E731
    return {"runs": len(rows), "job_h": jh(rows), "by_kind": by_kind,
            "successor_same_session": len(same), "successor_same_session_job_h": jh(same),
            "successor_any_session": len(anys), "successor_any_session_job_h": jh(anys),
            "join_saves_same_session_job_h": save["same"] / 3600.0, "join_saves_any_session_job_h": save["any"] / 3600.0,
            "cap_kills": len(caps), "cap_kills_job_h": jh(caps), "successor_s": SUCCESSOR_S,
            "client_side": client_interrupted(route)}


def client_interrupted(route):
    xs = [e for e in route if e["rc"] in (130, 143)]
    h = lambda e: 0.0 if e["start"] is None else max(0.0, e["wall"] - e["start"]) / 3600.0  # noqa: E731
    by = {}
    for e in xs:
        b = by.setdefault(e["host"], {"n": 0, "job_h": 0.0})
        b["n"] += 1
        b["job_h"] += h(e)
    return {"runs": len(xs), "job_h": sum(h(e) for e in xs), "by_host": by}


CONT_BUCKETS = (("<=3", 3.5), ("4-6", 6.5), ("7+", float("inf")))
CONT_MIN = 3
CONT_RUN_MIN_S = 5.0


def busy_integral(rows):
    """-> f(a, b) = slot-seconds busy on one worker in [a, b] (started runs and warms, prepare
    included), from a sorted step function (one pass, no per-run scan)."""
    ev = []
    for r in rows:
        if r["started"] or r["out"] == "warm":
            ev += [(r["end"] - (r["cmd"] if r["started"] else 0.0) - r["prep"], 1), (r["end"], -1)]
    ev.sort()
    ts, area, level = [], [], []
    a = lv = 0.0
    prev = None
    for t, d in ev:
        if prev is not None:
            a += lv * (t - prev)
        lv += d
        ts.append(t)
        area.append(a)
        level.append(lv)
        prev = t

    def at(t):
        i = bisect.bisect_right(ts, t) - 1
        return 0.0 if i < 0 else area[i] + level[i] * (t - ts[i])
    return lambda x, y: at(y) - at(x)


def contention(runs, lo, hi):
    """Per worker: run time of the same command by mean slots busy during the run (module doc)."""
    byw = {}
    for r in runs:
        byw.setdefault(r["w"], []).append(r)
    out = {}
    for w, rs in sorted(byw.items()):
        f = busy_integral(rs)
        g = {}
        for r in rs:
            if r["out"] not in ("rc=0", "rc=1") or not lo <= r["end"] <= hi or r["cmd"] < CONT_RUN_MIN_S:
                continue
            c = f(r["end"] - r["cmd"], r["end"]) / r["cmd"]
            b = next(lab for lab, top in CONT_BUCKETS if c <= top)
            g.setdefault("%s | %s" % (r["repo"].split(".")[0], norm_cmd(r["argv"])), {}).setdefault(b, []).append(r["cmd"])
        res = {}
        for k, bs in g.items():
            n = sum(len(v) for v in bs.values())
            p50 = {lab: med(v) for lab, v in bs.items() if len(v) >= CONT_MIN}
            if n < GROUP_MIN or len(p50) < 2 or "<=3" not in p50:
                continue
            res[k] = {"n": n, "buckets": {lab: {"n": len(v), "p50": med(v)} for lab, v in bs.items()},
                      "slow_mid": p50["4-6"] / p50["<=3"] if "4-6" in p50 and p50["<=3"] else None,
                      "slow_top": p50["7+"] / p50["<=3"] if "7+" in p50 and p50["<=3"] else None}
        if res:
            mids = [v["slow_mid"] for v in res.values() if v["slow_mid"]]
            tops = [v["slow_top"] for v in res.values() if v["slow_top"]]
            out[w] = {"groups": res, "slow_mid_med": med(mids), "slow_mid_groups": len(mids),
                      "slow_top_med": med(tops), "slow_top_groups": len(tops)}
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--hours", type=float)
    ap.add_argument("--since", help="local time 'YYYY-MM-DD HH:MM'")
    ap.add_argument("--until", help="local time 'YYYY-MM-DD HH:MM' (default now)")
    ap.add_argument("--client", action="append", help="ssh alias of another client Mac (default nickmini-docker)")
    ap.add_argument("--logs", help="read logs from this dir (route.<c>.log, runs.<w>.log) instead of fetching")
    ap.add_argument("--keep", help="save the fetched logs here")
    ap.add_argument("--cache", default=rd_logcache.default_dir(),
                    help="persistent log cache dir (default %(default)s; '' = off); unused with --logs")
    ap.add_argument("--fleet", default=FLEET, help="fleet.json to measure against (default: the live one)")
    ap.add_argument("--spike-s", type=float, default=20.0, help="replay: hp jobs that waited this long for a slot")
    ap.add_argument("--mini-db", action="store_true", help="replay: as if the minis took db jobs")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--save", help="also write this run's JSON here (a BEFORE for --compare)")
    ap.add_argument("--compare", help="a saved BEFORE JSON: per-group change and the median change")
    a = ap.parse_args()
    now = dt.datetime.now().timestamp()
    hi = dt.datetime.strptime(a.until, "%Y-%m-%d %H:%M").timestamp() if a.until else now
    lo = dt.datetime.strptime(a.since, "%Y-%m-%d %H:%M").timestamp() if a.since else hi - 3600 * (a.hours or 10)
    with open(a.fleet) as f:
        fleet = json.load(f)
    workers = [(m["name"], m.get("alias")) for m in fleet["machines"] if "worker" in (m.get("roles") or [])]
    clients = [("this-mac", None)] + [(c, c) for c in (a.client or ["nickmini-docker"])]
    srcs = [("route." + n, al, ["~/.local/state/rdocker/route.log.1", "~/.local/state/rdocker/route.log"]) for n, al in clients] + \
        [("runs." + n, al, ["~/rr/log/runs.log.1", "~/rr/log/runs.log"]) for n, al in workers]
    texts, cache_only = {}, {}
    for key, alias, paths in srcs:
        texts[key], newest = load_log(a, key, alias, paths)
        if newest is not False:
            cache_only[key] = newest
    if a.keep:
        os.makedirs(a.keep, exist_ok=True)
        for k, t in texts.items():
            if t is not None:
                open(os.path.join(a.keep, k + ".log"), "w").write(t)
    missing = [k for k, t in texts.items() if t is None]
    out_cache = {k: (None if v is None else now - v) for k, v in cache_only.items()}
    runs = [r for name, _ in workers if texts.get("runs." + name) for r in parse_runs(texts["runs." + name], name)]
    route = [e for name, _ in clients if texts.get("route." + name) for e in parse_route(texts["route." + name], name)]
    route = [e for e in route if lo <= e["end"] <= hi]
    join(route, runs)
    win = [r for r in runs if lo <= r["end"] <= hi]
    started = [r for r in win if r["started"]]
    out = {"window": [dt.datetime.fromtimestamp(lo).strftime("%Y-%m-%d %H:%M"),
                      dt.datetime.fromtimestamp(hi).strftime("%Y-%m-%d %H:%M")], "missing": missing,
           "cache_only_age_s": out_cache, "fleet": os.path.abspath(a.fleet), "classes": {}}
    for c in CLASSES + ("all",):
        js = [r for r in started if c == "all" or r["cls"] == c]
        rs = [e for e in route if e["row"] is not None and (c == "all" or e["row"]["cls"] == c)]
        q = [r["slot"] + r["lock"] for r in js]
        cold = [r for r in js if r["setup"] == "cold"]
        est = [r["prep"] / r["spred"] for r in cold if r["spred"]]
        out["classes"][c] = {
            "jobs": len(js), "per_worker": {w: sum(1 for r in js if r["w"] == w) for w in sorted({r["w"] for r in js})},
            "queue_p50": pct(q, 0.5), "queue_p90": pct(q, 0.9),
            "s2f_n": len(rs), "s2f_p50": pct([e["wall"] for e in rs], 0.5), "s2f_p95": pct([e["wall"] for e in rs], 0.95),
            "cold": len(cold), "clone": sum(1 for r in js if r["setup"] == "clone"),
            "cold_per_worker": {w: sum(1 for r in cold if r["w"] == w) for w in sorted({r["w"] for r in cold})},
            "cold_setup_p50": pct([r["prep"] for r in cold], 0.5),
            "cold_setup_over_est_p50": pct(est, 0.5), "cold_setup_est_n": len(est),
            "cold_run_over_pred_p50": pct([r["cmd"] / r["pred"] for r in cold if r["pred"]], 0.5)}
    out["route"] = {"rrun": len(route), "joined": sum(1 for e in route if e["row"]),
                    "by_host": {h: sum(1 for e in route if e["host"] == h) for h in sorted({e["host"] for e in route})}}
    walls = [e["wall"] for e in route]
    out["headline"] = {"jobs_per_hour": len(started) / max(1e-9, (hi - lo) / 3600.0), "jobs": len(started),
                       "time_mean_s": sum(walls) / len(walls) if walls else None, "time_median_s": med(walls),
                       "rrun_n": len(walls)}
    out["wasted"] = timeline(runs, fleet, lo, hi)
    out["groups"] = groups(route)
    for key, md, strict in (("replay", False, False), ("replay_strict", False, True), ("replay_strict_mini_db", True, True)):
        spikes, res = replay(runs, fleet, lo, hi, a.spike_s, md, strict)
        out[key] = {
            "hp_spike_jobs": len(spikes), "hp_spike_wait_s": sum(r["slot"] for r in spikes),
            "wins": len(res), "veto_blocked_wins": sum(1 for x in res if x["veto"]),
            "cold_wins": sum(1 for x in res if x["cold"]), "saved_s": sum(x["saved"] for x in res),
            "by_worker": {w: sum(1 for x in res if x["w"] == w) for w in sorted({x["w"] for x in res})},
            "by_class": {c: sum(1 for x in res if x["j"]["cls"] == c) for c in sorted({x["j"]["cls"] for x in res})}}
    out["interrupted"] = interrupted(runs, route, lo, hi)
    out["contention"] = contention(runs, lo, hi)
    if a.save:
        with open(a.save, "w") as f:
            json.dump(out, f, indent=1, sort_keys=True)
    if a.json:
        print(json.dumps(out, indent=1, sort_keys=True))
        return
    print("window %s -> %s (local)%s%s" % (
        out["window"][0], out["window"][1], ("   NOT READ: " + ", ".join(missing)) if missing else "",
        ("   CACHE ONLY (machine did not answer; newest cached line): " + ", ".join(
            "%s %s old" % (k, ago(v)) for k, v in sorted(out_cache.items()))) if out_cache else ""))
    hd, wa = out["headline"], out["wasted"]
    prev = json.load(open(a.compare)) if a.compare else None
    ph = (prev or {}).get("headline") or {}
    pw = (prev or {}).get("wasted") or {}
    vs = lambda k, d, f: ("   (before: %s)" % f(d[k]) if d.get(k) is not None else "") if prev else ""  # noqa: E731
    print("\n1. JOBS FINISHED PER HOUR (pool): %.1f  (%d jobs)%s" % (hd["jobs_per_hour"], hd["jobs"], vs("jobs_per_hour", ph, lambda v: "%.1f" % v)))
    print("2. TIME PER JOB, submit to finish: average %s, median %s  (%d rrun jobs)%s" % (
        mmss(hd["time_mean_s"]), mmss(hd["time_median_s"]), hd["rrun_n"],
        "   (before: average %s, median %s)" % (mmss(ph.get("time_mean_s")), mmss(ph.get("time_median_s"))) if prev else ""))
    print("3. IDLE-WHILE-WAITING: %d min, %s weighted slot-min idle%s" % (
        wa["idle_while_waiting_min"], fs(wa["idle_weighted_slot_min"]),
        "   (before: %s min, %s)" % (pw.get("idle_while_waiting_min"), fs(pw.get("idle_weighted_slot_min"))) if prev else ""))
    print("\nDETAIL")
    print("route.log rrun entries: %(rrun)d (joined to runs.log: %(joined)d) by host %(by_host)s" % out["route"])
    print("\n| class | jobs | per worker | queue p50/p90 s | submit->finish p50/p95 s (n) | cold (clone) | cold per worker | cold setup p50 s | cold setup / est p50 (n) | cold run / pred p50 |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for c, v in out["classes"].items():
        print("| %s | %d | %s | %s / %s | %s / %s (%d) | %d (%d) | %s | %s | %s (%d) | %s |" % (
            c, v["jobs"], " ".join("%s %d" % kv for kv in v["per_worker"].items()) or "-",
            fs(v["queue_p50"]), fs(v["queue_p90"]), fs(v["s2f_p50"]), fs(v["s2f_p95"]), v["s2f_n"],
            v["cold"], v["clone"], " ".join("%s %d" % kv for kv in v["cold_per_worker"].items()) or "-",
            fs(v["cold_setup_p50"]), fs(v["cold_setup_over_est_p50"]), v["cold_setup_est_n"], fs(v["cold_run_over_pred_p50"])))
    v = out["wasted"]
    print("\nwasted capacity (%d min; weight = fleet.json speed %s): weighted utilization p50 %s %% p90 %s %%; backlog "
          "p50 %s p90 %s max %d; IDLE-WHILE-WAITING %d min (backlog >= 1 and utilization < 80 %%; there: utilization "
          "p50 %s %%, backlog p50 %s), idle capacity then %s weighted slot-min (%s plain slot-min)" % (
              v["minutes"], v["speed"], fs(100 * v["util_p50"]) if v["util_p50"] is not None else "-",
              fs(100 * v["util_p90"]) if v["util_p90"] is not None else "-", fs(v["backlog_p50"]), fs(v["backlog_p90"]),
              v["backlog_max"], v["idle_while_waiting_min"],
              fs(100 * v["util_in_those_p50"]) if v["util_in_those_p50"] is not None else "-",
              fs(v["backlog_in_those_p50"]), fs(v["idle_weighted_slot_min"]), fs(v["idle_slot_min"])))
    print("\n| repo | command | n | submit->finish p50 / p90 s | wait / setup / run p50 s | workers |")
    print("|---|---|---|---|---|---|")
    for k, v in sorted(out["groups"].items(), key=lambda kv: -kv[1]["n"]):
        repo, cmd = k.split(" | ", 1)
        print("| %s | `%s` | %d | %s / %s | %s / %s / %s | %s |" % (
            repo, cmd, v["n"], fs(v["s2f_p50"]), fs(v["s2f_p90"]), fs(v["wait_p50"]), fs(v["setup_p50"]),
            fs(v["run_p50"]), " ".join("%s %d" % kv for kv in sorted(v["mix"].items()))))
    if a.compare:
        before = json.load(open(a.compare)).get("groups") or {}
        both = sorted(k for k in out["groups"] if k in before)
        print("\ncompare with %s (window %s): %d groups with >= %d runs in both" % (
            a.compare, " -> ".join(json.load(open(a.compare)).get("window") or []), len(both), GROUP_MIN))
        print("| repo | command | n before / after | s2f p50 before -> after s | change | p90 before -> after s |")
        print("|---|---|---|---|---|---|")
        ch = []
        for k in both:
            b, n = before[k], out["groups"][k]
            c = (n["s2f_p50"] - b["s2f_p50"]) / b["s2f_p50"] if b["s2f_p50"] else None
            if c is not None:
                ch.append(c)
            repo, cmd = k.split(" | ", 1)
            print("| %s | `%s` | %d / %d | %s -> %s | %s | %s -> %s |" % (
                repo, cmd, b["n"], n["n"], fs(b["s2f_p50"]), fs(n["s2f_p50"]),
                "-" if c is None else "%+.0f %%" % (100 * c), fs(b["s2f_p90"]), fs(n["s2f_p90"])))
        print("POOL-WIDE: median per-group change in submit->finish p50 = %s over %d groups" % (
            "-" if not ch else "%+.1f %%" % (100 * med(ch)), len(ch)))
    for k in ("replay", "replay_strict", "replay_strict_mini_db"):
        v = out[k]
        print("\n%s (hp jobs that waited >= %ss for a slot): %d jobs, %s s of hp slot wait; idle-worker wins %d "
              "(%d on a cold worker, %d of them forbidden by the old cold veto), %s s saved; by worker %s; by class %s" % (
                  k, fs(a.spike_s), v["hp_spike_jobs"], fs(v["hp_spike_wait_s"]), v["wins"], v["cold_wins"],
                  v["veto_blocked_wins"], fs(v["saved_s"]), v["by_worker"], v["by_class"]))
    print_interrupted(out["interrupted"])
    print_contention(out["contention"])


def ago(s):
    if s is None:
        return "(no timestamp)"
    s = max(0, int(s))
    return "%dd %02dh" % (s // 86400, s % 86400 // 3600) if s >= 86400 else "%dh %02dm" % (s // 3600, s % 3600 // 60)


def load_log(a, key, alias, paths):
    """-> (text or None, False | newest cached epoch when the machine did not answer and the cache stood
    in). --logs: the file in that dir. Else fetch, merge into the cache, and read the merged copy."""
    if a.logs:
        p = os.path.join(a.logs, key + ".log")
        return (open(p, errors="replace").read() if os.path.exists(p) else None), False
    t = fetch(alias, paths)
    if t is not None and not t.strip():
        t = None                     # answered but no log could be read: not a fresh read
    if not a.cache:
        return t, False
    try:
        if t is not None:
            rd_logcache.merge(a.cache, key, t)
        ct, newest = rd_logcache.read(a.cache, key)
    except OSError as e:
        sys.stderr.write("rd-measure: log cache %s unusable for %s: %s\n" % (a.cache, key, e))
        return t, False
    if ct is None:
        return t, False
    return ct, (False if t is not None else newest)


def print_interrupted(v):
    print("\ninterrupted runs (signal or lost link; job-h = prepare + run): %d runs, %.1f job-h; cap kills "
          "(timeout rc=124) %d, %.1f job-h" % (v["runs"], v["job_h"], v["cap_kills"], v["cap_kills_job_h"]))
    print("| kind | runs | job-h |")
    print("|---|---|---|")
    for k, x in sorted(v["by_kind"].items(), key=lambda kv: -kv[1]["job_h"]):
        print("| %s | %d | %.1f |" % (k, x["n"], x["job_h"]))
    cs = v["client_side"]
    print("client side (route.log rc 130 / 143, every host): %d rruns, %.1f job-h; by host %s" % (
        cs["runs"], cs["job_h"], ", ".join("%s %d / %.1f h" % (k, x["n"], x["job_h"]) for k, x in sorted(cs["by_host"].items()))))
    print("identical successor (same repo + argv, arriving while it ran or within %ds after): same owner session "
          "%d runs (%.1f job-h interrupted; joining saves <= %.1f job-h), any session %d runs (%.1f job-h; saves <= %.1f "
          "job-h). Saves = per run min(its work, the rerun's work). argv is runs.log's display form (redacted, "
          "cut at ~120 chars), so it can merge near-identical commands" % (
              v["successor_s"], v["successor_same_session"], v["successor_same_session_job_h"],
              v["join_saves_same_session_job_h"], v["successor_any_session"], v["successor_any_session_job_h"],
              v["join_saves_any_session_job_h"]))


def print_contention(c):
    print("\nworker contention (same command's run time by mean slots busy during it; groups with >= %d runs "
          "in <= 3 and another bucket)" % CONT_MIN)
    for w, v in c.items():
        print("%s: slowdown 4-6 vs <= 3 median %s over %d groups; 7+ vs <= 3 median %s over %d groups" % (
            w, "-" if v["slow_mid_med"] is None else "%.2fx" % v["slow_mid_med"], v["slow_mid_groups"],
            "-" if v["slow_top_med"] is None else "%.2fx" % v["slow_top_med"], v["slow_top_groups"]))
        print("| repo | command | n | <= 3 p50 s (n) | 4-6 | 7+ | 7+ vs <= 3 |")
        print("|---|---|---|---|---|---|---|")
        for k, g in sorted(v["groups"].items(), key=lambda kv: -kv[1]["n"])[:12]:
            repo, cmd = k.split(" | ", 1)
            cell = lambda lab: "%s (%d)" % (fs(g["buckets"][lab]["p50"]), g["buckets"][lab]["n"]) \
                if lab in g["buckets"] else "-"  # noqa: E731
            print("| %s | `%s` | %d | %s | %s | %s | %s |" % (repo, cmd, g["n"], cell("<=3"), cell("4-6"), cell("7+"),
                                                       "-" if g["slow_top"] is None else "%.2fx" % g["slow_top"]))


if __name__ == "__main__":
    sys.exit(main())
