#!/usr/bin/env python3
"""rd-measure: the pool's turnaround numbers for one time window, the same way every time (2026-11-21,
the before/after check of "place by net time": the cold-setup veto removed).

    rd-measure.py --hours 10                      # the last 10 h
    rd-measure.py --since "2026-11-21 21:50"      # from a local time to now (--until for an end)
    rd-measure.py --since ... --logs DIR          # reuse logs fetched before (--keep DIR saves them)

Read-only. It fetches (ssh cat) every client's route.log (+ .1) - this Mac and --client aliases
(default nickmini-docker) - and every fleet.json worker's ~/rr/log/runs.log (+ .1); a machine that does
not answer is listed and skipped. Per job class (runs.log cls: light / normal / heavy / db / build):

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
enabled in fleet.json and online (a runs.log row within ONLINE_S of it). Weighted utilization =
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
worktree (wt=) there (pessimistic); `_mini_db` adds db to the minis' classes.
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FLEET = os.path.join(HERE, "..", "fleet.json")
CLASSES = ("light", "normal", "heavy", "db", "build")
JOIN_S = 90.0
COLD_BUDGET_OLD = 60.0
STARTED = re.compile(r"^(?:(?:timeout|lost|interrupted) )?rc=\d+$")
RUNS_RE = re.compile(r"^(\S+) repo=(\S*) wt=(\S*) sha=\S* outcome=(.+?) prepare_s=(\S+) cmd_s=(\S+) argv=([^\t\n]*)(?:\t(.*))?$")
ROUTE_HEAD = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (\S+)\s+(\S+)\s+(.*)$", re.S)
ROUTE_RRUN = re.compile(r"rc=(\d+) ([\d.]+)s \| ([^\t]*)\t(.*)$", re.S)


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
                     "spred": num(kv.get("spred_s")), "started": bool(STARTED.match(out))})
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
        kv = dict(x.split("=", 1) for x in r.group(4).split() if "=" in x)
        end = dt.datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").timestamp()   # the client's local zone
        out.append({"client": client, "end": end, "host": m.group(2), "rc": int(r.group(1)), "wall": float(r.group(2)),
                    "pred": num(kv.get("pred_s")), "slot": num(kv.get("slot_s"), 0.0), "lock": num(kv.get("lock_s"), 0.0)})
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


def timeline(runs, fleet, lo, hi):
    ms = {m["name"]: m for m in fleet["machines"] if "worker" in (m.get("roles") or []) and m.get("enabled", True)}
    byw = {}
    for r in runs:
        if r["w"] in ms:
            byw.setdefault(r["w"], []).append(r)
    busy_iv, wait_iv, seen = {w: [] for w in ms}, [], {w: sorted(r["end"] for r in rs) for w, rs in byw.items()}
    for w, rs in byw.items():
        for r in rs:
            b0 = r["end"] - (r["cmd"] if r["started"] else 0.0) - r["prep"]
            if r["started"] or r["out"] == "warm":
                busy_iv[w].append((b0, r["end"]))
            q = r["slot"] + r["lock"]
            if q > 0 and r["out"] != "warm":
                wait_iv.append((b0 - q, b0))
    import bisect
    mins = []
    t = lo + 30.0
    while t < hi:
        cap = used = 0.0
        slots_idle = 0
        for w, m in ms.items():
            e = seen.get(w) or []
            i = bisect.bisect_left(e, t - ONLINE_S)
            if i >= len(e) or e[i] > t + ONLINE_S:
                continue                                        # offline (or no log) at this minute
            n, sp = m.get("max_slots", 1), float(m.get("speed", 1.0))
            b = min(n, sum(1 for a, z in busy_iv[w] if a <= t < z))
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
            if not any(abs(r["end"] - arrive) < 6 * 3600 for r in rows):     # not up then (no rows near)
                continue
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


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--hours", type=float)
    ap.add_argument("--since", help="local time 'YYYY-MM-DD HH:MM'")
    ap.add_argument("--until", help="local time 'YYYY-MM-DD HH:MM' (default now)")
    ap.add_argument("--client", action="append", help="ssh alias of another client Mac (default nickmini-docker)")
    ap.add_argument("--logs", help="read logs from this dir (route.<c>.log, runs.<w>.log) instead of fetching")
    ap.add_argument("--keep", help="save the fetched logs here")
    ap.add_argument("--spike-s", type=float, default=20.0, help="replay: hp jobs that waited this long for a slot")
    ap.add_argument("--mini-db", action="store_true", help="replay: as if the minis took db jobs")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--save", help="also write this run's JSON here (a BEFORE for --compare)")
    ap.add_argument("--compare", help="a saved BEFORE JSON: per-group change and the median change")
    a = ap.parse_args()
    now = dt.datetime.now().timestamp()
    hi = dt.datetime.strptime(a.until, "%Y-%m-%d %H:%M").timestamp() if a.until else now
    lo = dt.datetime.strptime(a.since, "%Y-%m-%d %H:%M").timestamp() if a.since else hi - 3600 * (a.hours or 10)
    fleet = json.load(open(FLEET))
    workers = [(m["name"], m.get("alias")) for m in fleet["machines"] if "worker" in (m.get("roles") or [])]
    clients = [("this-mac", None)] + [(c, c) for c in (a.client or ["nickmini-docker"])]
    texts, missing = {}, []
    for name, alias in clients:
        p = os.path.join(a.logs, "route.%s.log" % name) if a.logs else None
        t = open(p, errors="replace").read() if p and os.path.exists(p) else None if a.logs else \
            fetch(alias, ["~/.local/state/rdocker/route.log.1", "~/.local/state/rdocker/route.log"])
        texts["route." + name] = t
    for name, alias in workers:
        p = os.path.join(a.logs, "runs.%s.log" % name) if a.logs else None
        t = open(p, errors="replace").read() if p and os.path.exists(p) else None if a.logs else \
            fetch(alias, ["~/rr/log/runs.log.1", "~/rr/log/runs.log"])
        texts["runs." + name] = t
    if a.keep:
        os.makedirs(a.keep, exist_ok=True)
        for k, t in texts.items():
            if t is not None:
                open(os.path.join(a.keep, k + ".log"), "w").write(t)
    missing = [k for k, t in texts.items() if t is None]
    runs = [r for name, _ in workers if texts.get("runs." + name) for r in parse_runs(texts["runs." + name], name)]
    route = [e for name, _ in clients if texts.get("route." + name) for e in parse_route(texts["route." + name], name)]
    route = [e for e in route if lo <= e["end"] <= hi]
    join(route, runs)
    win = [r for r in runs if lo <= r["end"] <= hi]
    started = [r for r in win if r["started"]]
    out = {"window": [dt.datetime.fromtimestamp(lo).strftime("%Y-%m-%d %H:%M"),
                      dt.datetime.fromtimestamp(hi).strftime("%Y-%m-%d %H:%M")], "missing": missing, "classes": {}}
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
    if a.save:
        with open(a.save, "w") as f:
            json.dump(out, f, indent=1, sort_keys=True)
    if a.json:
        print(json.dumps(out, indent=1, sort_keys=True))
        return
    print("window %s -> %s (local)%s" % (out["window"][0], out["window"][1],
                                         ("   NOT READ: " + ", ".join(missing)) if missing else ""))
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


if __name__ == "__main__":
    sys.exit(main())
