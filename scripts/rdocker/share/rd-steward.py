#!/usr/bin/env python3
"""rd-steward: the pool's off-laptop supervisor (runs on the always-on agent Mac via launchd).

Install on the always-on agent Mac (user LaunchAgent, no sudo; runs the dotfiles copy, so a git pull
updates it):  python3 rd-steward.py --install    |  --uninstall  |  --once (run now, print the report)

Every run (default every 30 min):
  1. collect, per enabled worker: reachability, rd-doctor status, last-hour job outcomes (runs.log);
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
# "interrupted" is the calling agent cancelling its own job: not a pool fault, so not counted.
INFRA = re.compile(r"^(lost|busy|refused|rc=(124|134|137|72|73|75))$")
THRESH = {
    "doctor_stale_s": 300,      # rd-doctor writes every 30 s
    "infra_rate": 0.10,         # > 10 % of last-hour jobs failed for infra reasons ...
    "infra_min": 4,             # ... and at least this many
    "disk_free_pct": 10,
    "mem_free_pct": 8,
    "drained_s": 15 * 60,
}

REMOTE = r"""
now=$(date +%s)
st=$(cat /run/rdocker/doctor 2>/dev/null || cat ~/rr/state/doctor.json 2>/dev/null || echo null)
since=$(date -u -d @$((now-3600)) +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -r $((now-3600)) +%Y-%m-%dT%H:%M:%S)
printf 'NOW %s\nDOCTOR %s\n' "$now" "$st"
tail -n 3000 ~/rr/log/runs.log 2>/dev/null | awk -v s="$since" 'substr($1,1,19) >= s' | grep -o 'outcome=[^ ]*' | sort | uniq -c | sed 's/^/OUT /'
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
    for line in p.stdout.splitlines():
        if line.startswith("NOW "):
            r["now"] = int(line[4:].strip() or 0)
        elif line.startswith("DOCTOR "):
            try:
                r["doctor"] = json.loads(line[7:])
            except ValueError:
                r["doctor"] = None
        elif line.startswith("OUT "):
            mm = re.match(r"OUT\s+(\d+)\s+outcome=(\S+)", line)
            if mm:
                r["outcomes"][mm.group(2)] = int(mm.group(1))
    return r


def rules(r, m):
    """-> list of (key, text). key is stable so repeats share a signature."""
    n = r["name"]
    out = []
    if not r["reachable"]:
        return [(f"{n}:unreachable", f"{n} unreachable over ssh ({r['err']})")]
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
    total = sum(r["outcomes"].values())
    infra = sum(c for o, c in r["outcomes"].items() if INFRA.match(o))
    if total and infra >= THRESH["infra_min"] and infra / total > THRESH["infra_rate"]:
        kinds = ", ".join(f"{o}x{c}" for o, c in sorted(r["outcomes"].items()) if INFRA.match(o))
        out.append((f"{n}:infra", f"{n} {infra}/{total} jobs in the last hour failed for infra reasons ({kinds})"))
    return out


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
        r = probe(m)
        results.append(r)
        findings += rules(r, m)
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
        lines.append(f"- **{r['name']}** {'up' if r['reachable'] else 'DOWN'}"
                     f" doctor={'-' if not d else ('drained' if d.get('drained') else 'ok')}"
                     f" disk={d.get('disk_free_pct', '?')}% mem={d.get('mem_free_pct', '?')}% | 1h: {oc}")
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
