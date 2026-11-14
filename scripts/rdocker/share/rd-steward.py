#!/usr/bin/env python3
"""rd-steward: the pool's off-laptop supervisor (runs on the always-on agent Mac via launchd).

Install on the always-on agent Mac (user LaunchAgent, no sudo; runs the dotfiles copy, so a git pull
updates it):  python3 rd-steward.py --install    |  --uninstall  |  --once (run now, print the report)

Every run (default every 30 min):
  1. collect, per enabled worker: reachability, rd-doctor status, last-hour job outcomes (runs.log);
     and this Mac's own route.log (its rrun results: `fallback-local` = the pool failed, ran here);
  2. apply fixed rules -> a list of findings (empty = healthy);
  3. write a report + state under ~/.local/state/rd-steward/;
  4. only when there are findings whose signature has not been handed off within COOLDOWN_S, start a
     headless Claude agent with the runbook in RUNBOOK (safe, reversible fixes only; escalate the rest).

The rules here are deterministic and cheap; the agent only pays for problems the rules see but the
on-host rd-doctor did not already fix. Stdlib only. Exit 0 always (launchd must not throttle it).
"""
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
FLEET = os.environ.get("RD_STEWARD_FLEET") or os.path.join(HERE, "..", "fleet.json")
STATE = os.path.expanduser(os.environ.get("RD_STEWARD_STATE", "~/.local/state/rd-steward"))
COOLDOWN_S = int(os.environ.get("RD_STEWARD_COOLDOWN_S", str(3 * 3600)))
AGENT = os.environ.get("RD_STEWARD_AGENT", "1") == "1"
SSH_TIMEOUT = 20

# Infrastructure outcomes: the job did not get a fair run. rc=124 = hard cap, 134/137 = OOM/killed.
# Truthful labels (rr_runner.pl, 2026-11-11): only a STARTED run whose client never came back is
# "lost rc=N"; a client that left during the prepare is "abandoned-setup", a re-plan "moved", a
# background prepare "warm" - none is the worker's fault. A bare "lost" / "interrupted" (no rc) is
# the pre-2026-11-11 label of those same pre-start cases: never counted either.
INFRA = re.compile(r"^(lost rc=\d+|busy|deps-failed|(error|refused) rc=\d+|(timeout )?rc=(124|134|137)|rc=(72|73|75|76|77))$")
# the client left before the command started (or a background prepare): not a run, so not in the rate
NOT_A_RUN = re.compile(r"^(abandoned-setup|moved|warm|lost|interrupted)$")
# The outcomes that push a job off the pool (rd_run host_loop "fallback": a started run lost, the
# runner failing or the repo missing (69 / 70), a tool missing on the worker (127), SIGILL (132)).
# They are what a worker's runs.log shows of the fallbacks the agent Macs' route.logs record.
POOL_FAIL = re.compile(r"^(lost rc=\d+|(error|refused) rc=(69|70)|rc=(127|132))$")
# route.log rc of an infra-class result (rd_run EXIT_CODES "infra"); `exec` = ran here (no rc)
ROUTE_INFRA_RC = {"69", "70", "72", "73", "75", "76", "78", "124", "127", "132"}
ROUTE_RC_WHY = {"69": "repo missing on the worker", "70": "the worker's runner failed", "72": "worktree busy",
                "73": "every worker busy", "75": "never ran (no worker)", "76": "result lost after the start",
                "78": "deps install failed", "124": "hit its time cap", "127": "command not found on the worker",
                "132": "SIGILL on the worker"}
# route.log rrun line (rd_run.record): "<date> <time> <target> rrun <argv> rc=<rc> <secs>s | <cwd>[\t<k=v ...>]"
ROUTE_LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) +(\S+) +rrun +.* rc=(\S*) [0-9.]+s \| [^\t]*(?:\t(.*))?$")
ROUTE_TAIL_BYTES = 4 << 20       # route.log grows ~2 MB/day: the last hour is well inside this
THRESH = {
    "doctor_stale_s": 300,      # rd-doctor writes every 30 s
    "infra_rate": 0.10,         # > 10 % of last-hour jobs failed for infra reasons ...
    "infra_min": 4,             # ... and at least this many
    "disk_free_pct": 10,
    "mem_free_pct": 8,
    "drained_s": 15 * 60,
    "pool_fail_min": 3,         # pool-failing: >= this many fallbacks (route.log) / POOL_FAIL runs in 1 h ...
    "pool_rate": 0.20,          # ... or more than 20 % of the last hour's runs failed by the pool ...
    "pool_rate_runs": 10,       # ... over at least this many runs
}

REMOTE = r"""
now=$(date +%s)
st=$(cat /run/rdocker/doctor 2>/dev/null || cat ~/rr/state/doctor.json 2>/dev/null || echo null)
# runs.log stamps are the worker's LOCAL time (+offset), so the cutoff must be local too
since=$(date -d @$((now-3600)) +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -r $((now-3600)) +%Y-%m-%dT%H:%M:%S)
printf 'NOW %s\nDOCTOR %s\n' "$now" "$st"
for f in rd-doctor rd-tune rd-verify; do p=/usr/local/bin/$f; [ -f "$p" ] || p=/usr/local/libexec/$f; [ -f "$p" ] && printf 'SHA %s %s\n' "$f" "$( (sha256sum "$p" 2>/dev/null || shasum -a 256 "$p") | cut -c1-16)"; done
# Every field is read from its own part of the line, never from argv (a job's argv is free text, e.g.
# `sh -c 'echo node=24 outcome=busy'`): outcome= / cmd_s= only before the first " argv=", the v2 fields
# (pred_s=, node=) only after the TAB (redact_argv turns control characters into spaces, so the first TAB
# is the runner's own separator).
tail -n 3000 ~/rr/log/runs.log 2>/dev/null | awk -v s="$since" 'substr($1,1,19) >= s' | sed 's/ prepare_s=.*//' | grep -oE 'outcome=([a-z-]+ rc=[0-9]+|[^ ]+)$' | sort | uniq -c | sed 's/^/OUT /'
# prediction accuracy, last 24 h: "PRED <pred_s> <cmd_s>" for completed runs that logged a prediction
day=$(date -d @$((now-86400)) +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -r $((now-86400)) +%Y-%m-%dT%H:%M:%S)
tail -n 3000 ~/rr/log/runs.log 2>/dev/null | awk -v s="$day" 'substr($1,1,19) >= s {
  t = index($0, "\t"); if (!t) next
  h = substr($0, 1, t - 1); a = index(h, " argv="); if (a) h = substr(h, 1, a - 1)
  if (h !~ / outcome=rc=[01] prepare_s=/) next
  c = ""; p = ""
  n = split(h, f, " "); for (k = 1; k <= n; k++) if (f[k] ~ /^cmd_s=[0-9]/) c = substr(f[k], 7)
  n = split(substr($0, t + 1), f, " "); for (k = 1; k <= n; k++) if (f[k] ~ /^pred_s=[0-9]/) p = substr(f[k], 8)
  if (c != "" && p != "") print "PRED " p " " c }'
# node majors jobs ran with, last 24 h: "NODE <major> <count>" (runs.log node=, 2026-11-12; node=- or no
# field = skipped; 1-3 digits only)
tail -n 3000 ~/rr/log/runs.log 2>/dev/null | awk -v s="$day" 'substr($1,1,19) >= s {
  t = index($0, "\t"); if (!t) next
  n = split(substr($0, t + 1), f, " "); for (k = 1; k <= n; k++) if (f[k] ~ /^node=[0-9][0-9]?[0-9]?$/) m[substr(f[k], 6)]++ }
  END { for (k in m) print "NODE " k " " m[k] }'
"""


def cooldown(n):
    """Seconds before the same finding set is handed to the agent again: doubles per repeat, max 24 h."""
    return min(COOLDOWN_S * 2 ** max(n - 1, 0), 86400) if n else 0


def now_iso():
    return dt.datetime.now().strftime("%Y-%m-%d %H:%M")


def workers(fleet):
    for m in fleet.get("machines", []):
        if m.get("enabled", True) and "worker" in m.get("roles", []) and m.get("alias"):
            yield m


def probe(m):
    """-> dict(name, reachable, doctor, outcomes, err)."""
    r = {"name": m["name"], "os": m.get("os"), "reachable": False, "doctor": None, "outcomes": {}, "err": ""}
    try:
        p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", m["alias"], "sh", "-s"],
                           input=REMOTE, capture_output=True, text=True, timeout=SSH_TIMEOUT)
    except subprocess.TimeoutExpired:
        r["err"] = "ssh timeout"
        return r
    if p.returncode != 0 and "NOW " not in p.stdout:
        r["err"] = (p.stderr.strip().splitlines() or ["ssh failed"])[-1][:200]
        return r
    r["reachable"] = True
    parse_answer(r, p.stdout)
    return r


def whole(s, digits):
    """A whole number of 1..digits ASCII digits, else None: a malformed or hostile field is unknown,
    never an exception (one bad runs.log line must not stop the collection)."""
    s = s.strip()
    return int(s) if re.fullmatch(r"[0-9]{1,%d}" % digits, s) else None


def secs(s):
    """A seconds field (at most 7 integer digits, optional fraction) -> float, else None."""
    return float(s) if re.fullmatch(r"[0-9]{1,7}(\.[0-9]{1,6})?", s) else None


def parse_answer(r, out):
    """The REMOTE script's lines -> r (now, doctor, sha, pred, node, outcomes). Anything malformed is
    skipped line by line."""
    for line in out.splitlines():
        if line.startswith("NOW "):
            r["now"] = whole(line[4:], 12) or 0
        elif line.startswith("DOCTOR "):
            try:
                d = json.loads(line[7:])
            except (ValueError, RecursionError):
                d = None
            r["doctor"] = d if isinstance(d, dict) else None
        elif line.startswith("SHA "):
            parts = line.split()
            if len(parts) == 3:
                r.setdefault("sha", {})[parts[1]] = parts[2]
        elif line.startswith("PRED "):
            parts = line.split()
            pc = (secs(parts[1]), secs(parts[2])) if len(parts) == 3 else (None, None)
            if None not in pc:
                r.setdefault("pred", []).append(pc)
        elif line.startswith("NODE "):
            parts = line.split()
            major, n = (whole(parts[1], 3), whole(parts[2], 7)) if len(parts) == 3 else (None, None)
            if major is not None and n is not None:
                r.setdefault("node", {})[major] = n
        elif line.startswith("OUT "):
            mm = re.match(r"OUT\s+([0-9]{1,7})\s+outcome=(\S+(?: rc=[0-9]{1,3})?)\s*$", line)
            if mm:
                r["outcomes"][mm.group(2)] = int(mm.group(1))


PRED_MIN_N = 30          # jobs in 24 h before the prediction error counts
PRED_MAX_ERR = 50.0      # median absolute % error above which the model is flagged
PRED_FLOOR_S = 2.0       # sub-2 s commands: % error is noise there


def pred_error(pairs):
    """[(pred_s, cmd_s)] -> (median abs % error, n) over jobs of at least PRED_FLOOR_S, or None."""
    errs = sorted(abs(p - c) / c * 100 for p, c in (pairs or []) if c >= PRED_FLOOR_S)
    if not errs:
        return None
    return errs[len(errs) // 2], len(errs)


def rules(r, m, pool_node=None):
    """-> list of (key, text). key is stable so repeats share a signature. pool_node = fleet.json's
    pool_node_major (None = not declared: no node rule)."""
    n = r["name"]
    out = []
    if not r["reachable"]:
        # an "optional": true worker (often away, e.g. a laptop) being unreachable is normal: no finding
        return [] if m.get("optional") is True else [(f"{n}:unreachable", f"{n} unreachable over ssh ({r['err']})")]
    d = r.get("doctor")
    if d is None:
        if m.get("os") == "linux":
            out.append((f"{n}:no-doctor", f"{n} has no rd-doctor status (doctor not installed or not running)"))
    else:
        age = r.get("now", int(time.time())) - int(d.get("ts") or 0)
        if age > THRESH["doctor_stale_s"]:
            out.append((f"{n}:doctor-stale", f"{n} rd-doctor status is {age}s old (timer stopped?)"))
        if d.get("drained") and d.get("drain_since"):
            since = int(d["drain_since"]) if str(d["drain_since"]).isdigit() else 0
            if since and r.get("now", 0) - since > THRESH["drained_s"]:
                out.append((f"{n}:drained", f"{n} drained for {(r['now'] - since) // 60} min: {d.get('drain_reason', '')}"))
        if (d.get("disk_free_pct") or 100) < THRESH["disk_free_pct"]:
            out.append((f"{n}:disk", f"{n} disk {d.get('disk_free_pct')}% free"))
        if (d.get("mem_free_pct") or 100) < THRESH["mem_free_pct"]:
            out.append((f"{n}:mem", f"{n} memory {d.get('mem_free_pct')}% free"))
    for name, have in sorted((r.get("sha") or {}).items()):
        want = REPO_SHA.get(name)
        if want and have != want:
            out.append((f"{n}:outdated-{name}", f"{n} runs an outdated {name} (installed {have}, repo {want}): "
                                               "re-run the server installer (needs sudo)"))
    err = pred_error(r.get("pred"))
    if err is not None and err[1] >= PRED_MIN_N and err[0] > PRED_MAX_ERR:
        out.append((f"{n}:pred-drift", f"{n} placement predictions are off by a median {err[0]:.0f}% over "
                                       f"{err[1]} jobs in 24 h (pred_s vs cmd_s): the routing model needs a look"))
    off = {k: c for k, c in sorted((r.get("node") or {}).items()) if pool_node is not None and k != pool_node}
    if off:
        ran = ", ".join(f"node {k} x{c}" for k, c in off.items())
        out.append((f"{n}:node-mismatch", f"{n} ran jobs on a different node major than the pool's ({ran} in 24 h; "
                                          f"fleet.json pool_node_major is {pool_node}): its results are not "
                                          "shared - fix the worker's node or bump pool_node_major"))
    total = sum(c for o, c in r["outcomes"].items() if not NOT_A_RUN.match(o))
    infra = sum(c for o, c in r["outcomes"].items() if INFRA.match(o))
    bad = {o: c for o, c in r["outcomes"].items() if POOL_FAIL.match(o) or INFRA.match(o)}
    pf = pool_failing(n, sum(c for o, c in bad.items() if POOL_FAIL.match(o)), sum(bad.values()), total,
                      top_reason(bad), "runs.log")
    if pf:
        out.append(pf)          # the stronger statement of the same problem: no second `infra` finding
    elif total and infra >= THRESH["infra_min"] and infra / total > THRESH["infra_rate"]:
        kinds = ", ".join(f"{o}x{c}" for o, c in sorted(r["outcomes"].items()) if INFRA.match(o))
        out.append((f"{n}:infra", f"{n} {infra}/{total} jobs in the last hour failed for infra reasons ({kinds})"))
    return out


def top_reason(counts):
    """{reason: count} -> "reason xN" of the most common one (ties: alphabetical), or ""."""
    if not counts:
        return ""
    o, c = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))[0]
    return f"{o} x{c}"


def pool_failing(name, fails, bad, runs, top, src):
    """The pool-failing rule, one machine's last hour -> (key, text) or None. fails = fallbacks
    (route.log) or POOL_FAIL runs (runs.log); bad = every pool-caused failure (fails + infra results);
    runs = the runs they are out of."""
    rate = bad / runs if runs else 0.0
    if fails < THRESH["pool_fail_min"] and not (runs >= THRESH["pool_rate_runs"] and rate > THRESH["pool_rate"]):
        return None
    what = "fallback(s) to local" if src == "route.log" else "pool failure(s)"
    return (f"{name}:pool-failing", f"{name} pool failing ({src}, last hour): {fails} {what}, {bad}/{runs} runs "
                                    f"({rate * 100:.0f}%) failed by the pool; top reason: {top or '-'}")


def route_log_paths():
    """This Mac's route.log (+ its one rotated generation), oldest first. RDOCKER_HOME as rd_common."""
    state = os.path.join(os.path.abspath(os.path.expanduser(os.environ.get("RDOCKER_HOME") or "~")),
                         ".local", "state", "rdocker")
    return [os.path.join(state, "route.log.1"), os.path.join(state, "route.log")]


def read_tail(path, limit=ROUTE_TAIL_BYTES):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - limit))
            return f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return []


def route_stats(lines, since):
    """route.log lines -> the last hour's rrun results: {runs, fallback, infra, reasons} (reasons: the
    fallbacks' `why=` and the infra rcs' meaning, with counts). Lines before `since` (local time, like
    route.log's own stamps) and lines that are not rrun results are skipped."""
    cut = dt.datetime.fromtimestamp(since).strftime("%Y-%m-%d %H:%M:%S")
    s = {"runs": 0, "fallback": 0, "infra": 0, "reasons": {}}
    for line in lines:
        m = ROUTE_LINE.match(line)
        if not m or m.group(1) < cut:
            continue
        target, rc, extra = m.group(2), m.group(3), m.group(4) or ""
        s["runs"] += 1
        if target == "fallback-local":
            s["fallback"] += 1
            why = next((f[4:] for f in extra.split(" ") if f.startswith("why=")), "")
            why = why.replace("_", " ")[:80] or "pool unavailable (no reason logged)"
            s["reasons"][why] = s["reasons"].get(why, 0) + 1
        elif rc in ROUTE_INFRA_RC:
            s["infra"] += 1
            why = f"rc={rc} {ROUTE_RC_WHY[rc]}"
            s["reasons"][why] = s["reasons"].get(why, 0) + 1
    return s


def self_name():
    return os.environ.get("RD_STEWARD_SELF") or (os.uname().nodename.split(".")[0] or "this Mac")


def route_rules(now=None):
    """This Mac's own route.log (the steward runs on an agent Mac): -> (stats, findings). The other
    agent Macs (fleet.json, no ssh alias) are not reachable: their fallbacks show on the workers'
    runs.log as POOL_FAIL outcomes (rules())."""
    now = now or time.time()
    lines = []
    for p in route_log_paths():
        lines += read_tail(p)
    s = route_stats(lines, now - 3600)
    f = pool_failing(self_name(), s["fallback"], s["fallback"] + s["infra"], s["runs"], top_reason(s["reasons"]),
                     "route.log")
    return s, [f] if f else []


def pool_node_major(fleet):
    """fleet.json's top-level pool_node_major as an int, or None (absent / not a whole number)."""
    v = fleet.get("pool_node_major")
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def repo_sha():
    """sha256[:16] of the server scripts in this checkout, keyed by installed name."""
    import hashlib
    out = {}
    for name, rel in (("rd-doctor", "server/rd-doctor.sh"), ("rd-tune", "server/rd-tune.sh"),
                      ("rd-verify", "server/rd-verify.sh")):
        try:
            with open(os.path.join(HERE, "..", rel), "rb") as f:
                out[name] = hashlib.sha256(f.read()).hexdigest()[:16]
        except OSError:
            pass
    return out


REPO_SHA = repo_sha()
AUTOPULL = os.path.expanduser("~/.claude/.dotfiles-autopull.json")


def self_rules(now=None):
    """This Mac (the always-on agent host) must track origin/main: autopull alive and not behind."""
    now = now or time.time()
    try:
        a = json.load(open(AUTOPULL))
    except (OSError, ValueError):
        return [("self:no-autopull", "this Mac has no dotfiles autopull status (run scripts/dotfiles-autopull.sh --install)")]
    if now - int(a.get("ts") or 0) > 15 * 60:
        return [("self:autopull-stale", f"dotfiles autopull has not run for {int((now - a.get('ts', 0)) // 60)} min")]
    if a.get("state") == "skipped" and int(a.get("behind") or 0) > 0:
        return [("self:behind", f"dotfiles {a.get('behind')} commit(s) behind origin and not updating: {a.get('why')}")]
    return []


RUNBOOK = """You are the rdocker compute-pool steward, running unattended on Nick's Mac mini.
The deterministic checker found the problems listed below. The full report is at {report}.
Code and docs: ~/.claude-dotfiles/scripts/rdocker (fleet.json, docs/, server/rd-doctor.sh).
Reach workers with: ssh <alias> (aliases are in fleet.json). Worker logs: ~/rr/log/runs.log, ~/rr/log/doctor.log.

Investigate each problem to its cause, then:
- FIX only with safe, reversible actions: restart rd-doctor / rd-reporter / docker services you can
  restart without a password, re-run `rd-tune` pruning, remove containers that carry an rdocker.run
  label whose run is dead, release slot files whose pid is dead.
- NEVER: delete volumes or named containers, edit code or fleet.json, git push, touch files outside
  ~/rr on workers, touch Nick's or Omid's personal files, type or request passwords, reboot a machine.
- Anything needing hardware, a password, a reboot or a destructive decision: do NOT attempt it.
  Write it under "## Needs a human" in your report.
Append one line per action to {actions} ("<time> <worker> <action> <result>").
Finish by writing your report to {out} : problems, cause, what you did, what still needs a human.
Keep it short. Problems:
{problems}
"""


def handoff(findings, report_path):
    claude = shutil.which("claude") or "/opt/homebrew/bin/claude"
    if not os.path.exists(claude):
        return "claude CLI not found; not handed off"
    stamp = dt.datetime.now().strftime("%Y-%m-%d-%H%M")
    out = os.path.join(STATE, "agent", f"{stamp}.md")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    prompt = RUNBOOK.format(report=report_path, actions=os.path.join(STATE, "actions.log"), out=out,
                            problems="\n".join(f"- {t}" for _, t in findings))
    log = open(os.path.join(STATE, "agent", f"{stamp}.log"), "w")
    subprocess.Popen([claude, "-p", prompt, "--permission-mode", "bypassPermissions", "--max-turns", "60"],
                     cwd=STATE, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                     start_new_session=True)
    return f"handed off to claude agent -> {out}"


def main():
    os.makedirs(os.path.join(STATE, "reports"), exist_ok=True)
    fleet = json.load(open(FLEET))
    results, findings = [], []
    for m in workers(fleet):
        try:
            r = dict(probe(m), optional=m.get("optional") is True)
            found = rules(r, m, pool_node_major(fleet))
        except Exception as e:  # one worker's odd answer must not stop the others
            r = {"name": m.get("name", "?"), "os": m.get("os"), "reachable": True, "doctor": None,
                 "outcomes": {}, "err": repr(e)[:200]}
            found = [(f"{r['name']}:steward-error", f"rd-steward could not read {r['name']}'s answer ({r['err']})")]
        results.append(r)
        findings += found
    try:
        route, found = route_rules()
    except Exception as e:  # a garbled route.log must not stop the report
        route, found = None, [("self:steward-error", f"rd-steward could not read this Mac's route.log ({e!r:.200})")]
    findings += found
    findings += self_rules()
    sig = hashlib.sha256("\n".join(sorted(k for k, _ in findings)).encode()).hexdigest()[:12]
    state_p = os.path.join(STATE, "state.json")
    try:
        st = json.load(open(state_p))
    except (OSError, ValueError):
        st = {}
    lines = [f"# rd-steward {now_iso()}", ""]
    for r in results:
        d = r.get("doctor") or {}
        oc = " ".join(f"{o}x{c}" for o, c in sorted(r["outcomes"].items())) or "no jobs"
        lines.append(f"- **{r['name']}** {'up' if r['reachable'] else 'away (optional)' if r.get('optional') else 'DOWN'}"
                     f" doctor={'-' if not d else ('drained' if d.get('drained') else 'ok')}"
                     f" disk={d.get('disk_free_pct', '?')}% mem={d.get('mem_free_pct', '?')}% | 1h: {oc}"
                     + (lambda e: f" | pred err 24h: {e[0]:.0f}% (n={e[1]})" if e else "")(pred_error(r.get("pred"))))
    if route is not None:
        lines.append(f"- **{self_name()}** (this Mac, route.log) 1h: {route['runs']} rrun, "
                     f"{route['fallback']} fallback-local, {route['infra']} infra")
    lines += ["", "## Findings", ""] + ([f"- {t}" for _, t in findings] or ["- none: pool healthy"])
    report = os.path.join(STATE, "reports", dt.datetime.now().strftime("%Y-%m-%d-%H%M") + ".md")
    action = "healthy"
    if findings:
        h = st.get("handed", {}).get(sig) or {"t": 0, "n": 0}
        wait = cooldown(h["n"])
        if not AGENT:
            action = "findings (agent disabled)"
        elif time.time() - h["t"] < wait:
            action = f"same findings handed off {int((time.time() - h['t']) // 60)} min ago (next after {wait // 60} min)"
        else:
            st.setdefault("handed", {})[sig] = {"t": int(time.time()), "n": h["n"] + 1}
            action = None
    lines += ["", f"Action: {action or 'pending'}"]
    open(report, "w").write("\n".join(lines) + "\n")
    if action is None:
        action = handoff(findings, report)
        with open(report, "a") as f:
            f.write(f"Action: {action}\n")
    st["handed"] = {k: v for k, v in st.get("handed", {}).items()
                    if isinstance(v, dict) and time.time() - v["t"] < 7 * 86400}
    st.update(last_run=int(time.time()), last_sig=sig if findings else "", last_action=action,
              findings=[t for _, t in findings], last_report=report)
    json.dump(st, open(state_p, "w"), indent=1)
    # keep 14 days of reports
    for f in os.listdir(os.path.join(STATE, "reports")):
        p = os.path.join(STATE, "reports", f)
        if time.time() - os.path.getmtime(p) > 14 * 86400:
            os.remove(p)
    print(f"rd-steward: {len(findings)} finding(s); {action}")


LABEL = "com.rdocker.steward"
PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{label}</string>
  <key>ProgramArguments</key><array><string>/usr/bin/python3</string><string>{script}</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>StartInterval</key><integer>{interval}</integer>
  <key>RunAtLoad</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>{state}/launchd.log</string>
  <key>StandardErrorPath</key><string>{state}/launchd.log</string>
</dict>
</plist>
"""


def install(uninstall=False):
    pl = os.path.expanduser(f"~/Library/LaunchAgents/{LABEL}.plist")
    dom = f"gui/{os.getuid()}"
    subprocess.run(["launchctl", "bootout", f"{dom}/{LABEL}"], capture_output=True)
    if uninstall:
        if os.path.exists(pl):
            os.remove(pl)
        print("STEWARD-REMOVED")
        return 0
    os.makedirs(STATE, exist_ok=True)
    os.makedirs(os.path.dirname(pl), exist_ok=True)
    script = os.path.realpath(__file__)
    with open(pl, "w") as f:
        f.write(PLIST.format(label=LABEL, script=script, state=STATE,
                             interval=int(os.environ.get("RD_STEWARD_INTERVAL_S", "1800"))))
    r = subprocess.run(["launchctl", "bootstrap", dom, pl], capture_output=True, text=True)
    print("STEWARD-INSTALLED" if r.returncode == 0 else f"launchctl bootstrap failed: {r.stderr.strip()}")
    return r.returncode


if __name__ == "__main__":
    if sys.argv[1:2] in (["--install"], ["--uninstall"]):
        sys.exit(install(sys.argv[1] == "--uninstall"))
    try:
        main()
    except Exception as e:  # never let launchd see a crash loop
        print(f"rd-steward: error {e!r}", file=sys.stderr)
    sys.exit(0)
