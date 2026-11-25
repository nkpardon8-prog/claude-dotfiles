#!/usr/bin/env python3
"""token-usage-report.py - where did the Claude tokens go? (before/after measurement)

PURPOSE. Token-saving changes (agent model/effort, subagent cache TTL, the /mission 3300s wake
cap, smaller /implement chunks) must be VERIFIED from the session logs, not assumed. This script
reads one project's Claude Code transcripts (~/.claude/projects/<encoded-cwd>/), or every project
with --all-projects, and prints the same breakdown the 2026-09-26 token-usage brief was built on, so a run before a change and a run
after it can be compared line for line.

WHAT IT READS. <project-dir>/<sid>.jsonl (main sessions) and <project-dir>/<sid>/subagents/*.jsonl
(subagent runs; the sibling .meta.json carries agentType). Assistant rows are de-duplicated by
message.id (a streamed message is logged once per content block; a resumed/forked log repeats
history), so every API call is counted once.

WEIGHTS. Spend is an APPROXIMATE RELATIVE WEIGHT, not dollars: input 1, cache-read 0.1,
cache-write 2, output 5 (per token). Good for "what share went where", not for billing.

SECTIONS. spend by component | main vs subagent by agentType (runs, avg cost, avg peak context) |
model mix | big cache re-writes (>50k tokens) by cause (idle>1h, idle>5m, after compact_boundary,
first call in a log, other) | cache-write TTL split (ephemeral_5m vs ephemeral_1h, main vs sub) |
loop-tick gap buckets (the API call answering an "Autonomous loop tick" / "MISSION WAKE" prompt,
bucketed by the gap since the previous call: <55m / 55-60m / 60-65m / >65m, with avg cache-write).
A tick landing past the 1h prompt-cache TTL re-caches the whole context; one landing inside it
re-caches ~1k.
Then (context of a step = input + cache-write + cache-read tokens of that API call):
per agent type (runs, steps, avg context per step, median/max peak context per run, spend, share,
spend per finished worker job from meta.json finished=true, unfinished runs) | wait steps: check
loops (a Bash sleep/until/while-sleep loop) and wake-ups (ScheduleWakeup, stop=true ignored), count
and share by what is waited on (push gate, Codex, tests/typecheck/build, another agent, other;
classified on the command / wake-up reason with absolute-path directories stripped) | main-window
checkpoints (a step under 60% of the previous step's context while that one was > 150k: count,
context before median/min/max, after median) | main steps at >= 400k context and how many had no
human-typed prompt since the previous step (after an injected prompt vs mid-turn), then the same
question per prompt boundary (typed or injected; each is one chance for a UserPromptSubmit hook to
fire) and per climb past 400k (did a boundary arrive before 500k). stdlib only.

USAGE. token-usage-report.py [--project-dir DIR | --all-projects] [--days N]
  --project-dir   default: ~/.claude/projects/<current cwd with every non-alphanumeric -> '-'>
  --all-projects  aggregate every directory under ~/.claude/projects
  --days          default 3 (API calls whose timestamp is within the last N days; logs not
                  modified within N days are skipped unread)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
import time
from collections import defaultdict
from datetime import datetime
from pathlib import Path

W_INPUT, W_READ, W_WRITE, W_OUTPUT = 1.0, 0.1, 2.0, 5.0
BIG_REWRITE = 50_000
TICK_MARKERS = ("Autonomous loop tick", "MISSION WAKE", "mission wake")
HOUR, FIVE_MIN = 3600.0, 300.0
UNATTENDED_CTX = 400_000  # 40% of a 1M context window
CLIMB_BAND = 100_000  # a prompt boundary this soon after crossing counts as a timely nudge chance
CKPT_PREV_MIN, CKPT_RATIO = 150_000, 0.6
CHECK_LOOP = re.compile(r"\bsleep\s+\d|until\s.+;\s*do|while\s.+sleep")
WAIT_CAUSES = (
    ("push gate", re.compile(r"safe-push|safe_push")),
    ("Codex", re.compile(r"codex")),
    (
        "tests/typecheck/build",
        re.compile(r"rrun|tsc|vitest|jest|playwright|test:db|npm (run |test)|check:|docker|build"),
    ),
    ("another agent", re.compile(r"agent|helper|worker|workflow|implementer|review")),
)
# The directory part of an absolute path ("/Users/x/", "~/.claude/") - stripped before classifying
# so a word inside a path ("Users", "build/") never decides the cause; the basename is kept.
ABS_DIRS = re.compile(r"(?<![\w.~-])~?/(?:[^\s/'\"`;|&()<>]+/)*")
INJECTED_MARKERS = (
    "<system-reminder>",
    "<task-notification>",
    "<cross-session-message",
    "Autonomous loop tick",
    "Autonomous loop check",
    "MISSION WAKE",
    "<command-name>",
    "<local-command-",
    "This session is being continued",
    "[Request interrupted",
    "Stop hook feedback",
    "prior /loop wakeup",
)


def default_project_dir() -> Path:
    enc = re.sub(r"[^A-Za-z0-9]", "-", os.getcwd())
    return Path.home() / ".claude" / "projects" / enc


def parse_ts(s: object) -> float | None:
    if not isinstance(s, str):
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def user_text(msg: object) -> str:
    """Human/injected prompt text only - tool_result blocks are excluded so a Read of mission.md
    (which mentions 'mission wake') is never mistaken for a wake prompt."""
    if not isinstance(msg, dict):
        return ""
    c = msg.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(
            b.get("text", "") for b in c if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def prompt_kind(d: dict) -> str | None:
    """'human' for a prompt a person typed, 'injected' for a harness-made one (wake-up, task
    notification, peer message, hook/skill text, compact summary), None for a tool_result row.
    Explicit row metadata wins (promptSource 'typed' / origin.kind 'human' - a typed slash command
    counts as human); the text markers are the fallback for rows without it."""
    msg = d.get("message")
    c = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(c, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c):
        return None
    origin = d.get("origin")
    okind = origin.get("kind") if isinstance(origin, dict) else None
    if d.get("promptSource") == "typed" or okind == "human":
        return "human"
    if d.get("promptSource") == "system" or okind or d.get("isMeta") or d.get("isCompactSummary"):
        return "injected"
    text = user_text(msg)
    if not text.strip():
        return None
    return "injected" if any(mk in text for mk in INJECTED_MARKERS) else "human"


def wait_cause(text: str) -> str:
    s = ABS_DIRS.sub("", text.lower())
    for name, rx in WAIT_CAUSES:
        if rx.search(s):
            return name
    return "other"


def wait_tag(content: object) -> str | None:
    """'check loop: <cause>' / 'wake-up: <cause>' for the first waiting tool_use in an assistant
    row's content, else None."""
    if not isinstance(content, list):
        return None
    for b in content:
        if not isinstance(b, dict) or b.get("type") != "tool_use":
            continue
        inp = b.get("input") if isinstance(b.get("input"), dict) else {}
        if b.get("name") == "Bash":
            cmd = str(inp.get("command") or "")
            if CHECK_LOOP.search(cmd):
                return "check loop: " + wait_cause(cmd)
        elif b.get("name") == "ScheduleWakeup" and not inp.get("stop"):
            why = str(inp.get("reason") or "") or str(inp.get("prompt") or "")[:200]
            return "wake-up: " + wait_cause(why)
    return None


def median(xs: list[float]) -> float:
    return statistics.median(xs) if xs else 0


def cost(u: dict) -> float:
    return (
        u["input"] * W_INPUT + u["read"] * W_READ + u["write"] * W_WRITE + u["output"] * W_OUTPUT
    )


def norm_usage(u: dict) -> dict:
    cc = u.get("cache_creation") or {}
    return {
        "input": int(u.get("input_tokens") or 0),
        "read": int(u.get("cache_read_input_tokens") or 0),
        "write": int(u.get("cache_creation_input_tokens") or 0),
        "output": int(u.get("output_tokens") or 0),
        "w5m": int(cc.get("ephemeral_5m_input_tokens") or 0),
        "w1h": int(cc.get("ephemeral_1h_input_tokens") or 0),
    }


def read_calls(path: Path) -> list[dict]:
    """One record per distinct assistant message.id, in log order, with the context needed to
    classify it: gap since the previous call, compact_boundary in between, tick prompt before it,
    the kind of prompt since the previous call (human > injected > none), and its waiting tool call."""
    calls: dict[str, dict] = {}
    order: list[str] = []
    prev_ts: float | None = None
    compact_pending = False
    last_user_is_tick = False
    saw_human = saw_injected = False
    try:
        fh = open(path, "rb")
    except OSError:
        return []
    with fh:
        for raw in fh:
            # Cheap pre-filter: skip bookkeeping rows without paying for json.loads.
            if b'"assistant"' not in raw and b'"user"' not in raw and b"compact_boundary" not in raw:
                continue
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            t = d.get("type")
            if t == "system":
                if d.get("subtype") == "compact_boundary":
                    compact_pending = True
                continue
            if t == "user":
                pk = prompt_kind(d)
                saw_human = saw_human or pk == "human"
                saw_injected = saw_injected or pk == "injected"
                text = user_text(d.get("message"))
                if text or not isinstance((d.get("message") or {}).get("content"), list):
                    last_user_is_tick = any(m in text for m in TICK_MARKERS)
                else:
                    last_user_is_tick = False  # a tool_result row: the turn is mid-flight
                continue
            if t != "assistant":
                continue
            m = d.get("message")
            if not isinstance(m, dict):
                continue
            mid = m.get("id")
            u = m.get("usage")
            if not mid or not isinstance(u, dict):
                continue
            if mid in calls:  # later block of the same streamed message: keep the latest usage
                calls[mid]["u"] = norm_usage(u)
                calls[mid]["wait"] = calls[mid]["wait"] or wait_tag(m.get("content"))
                continue
            ts = parse_ts(d.get("timestamp"))
            calls[mid] = {
                "id": mid,
                "ts": ts,
                "model": m.get("model") or "?",
                "u": norm_usage(u),
                "gap": (ts - prev_ts) if (ts is not None and prev_ts is not None) else None,
                "after_compact": compact_pending,
                "tick": last_user_is_tick,
                "prompt": "human" if saw_human else ("injected" if saw_injected else None),
                "wait": wait_tag(m.get("content")),
            }
            order.append(mid)
            compact_pending = False
            last_user_is_tick = False
            saw_human = saw_injected = False
            if ts is not None:
                prev_ts = ts
    return [calls[i] for i in order]


def discover(project_dir: Path, cutoff: float) -> list[tuple[Path, str, bool | None]]:
    """(path, agent kind, finished) for every log touched since cutoff. kind = 'main' or the
    agentType; finished = the meta.json flag for a subagent (False when absent), None for main."""
    out: list[tuple[Path, str, bool | None]] = []
    for p in project_dir.glob("*.jsonl"):
        if p.stat().st_mtime >= cutoff:
            out.append((p, "main", None))
    for p in project_dir.glob("*/subagents/**/*.jsonl"):
        if p.stat().st_mtime < cutoff:
            continue
        kind, finished = "subagent:?", False
        meta = p.with_suffix(".meta.json")
        try:
            md = json.loads(meta.read_text())
            kind = md.get("agentType") or kind
            finished = md.get("finished") is True
        except (OSError, ValueError, AttributeError):
            pass
        out.append((p, kind, finished))
    return out


def pct(a: float, b: float) -> str:
    return f"{(100.0 * a / b):5.1f}%" if b else "  n/a"


def fmt(n: float) -> str:
    n = float(n)
    for unit, div in (("B", 1e9), ("M", 1e6), ("k", 1e3)):
        if abs(n) >= div:
            return f"{n / div:.1f}{unit}"
    return f"{n:.0f}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--project-dir", type=Path, default=None)
    ap.add_argument("--all-projects", action="store_true")
    ap.add_argument("--days", type=float, default=3.0)
    args = ap.parse_args()
    if args.all_projects and args.project_dir:
        print("token-usage-report: --all-projects and --project-dir are exclusive", file=sys.stderr)
        return 2
    if args.all_projects:
        pdir = Path.home() / ".claude" / "projects"
    else:
        pdir = (args.project_dir or default_project_dir()).expanduser()
    if not pdir.is_dir():
        print(f"token-usage-report: no such project dir: {pdir}", file=sys.stderr)
        return 2
    now = time.time()
    cutoff = now - args.days * 86400

    seen: set[str] = set()
    comp = defaultdict(float)  # weighted spend by component
    by_kind = defaultdict(lambda: {"runs": 0, "cost": 0.0, "peak_sum": 0, "calls": 0})
    by_model = defaultdict(lambda: {"calls": 0, "cost": 0.0, "main": 0.0, "sub": 0.0})
    rewrites = defaultdict(lambda: {"n": 0, "tok": 0, "cost": 0.0, "main": 0, "sub": 0})
    ttl = {"main": {"w5m": 0, "w1h": 0}, "sub": {"w5m": 0, "w1h": 0}}
    ticks = {k: {"n": 0, "write": 0} for k in ("<55m", "55-60m", "60-65m", ">65m", "no-gap")}
    total = 0.0
    n_calls = 0
    pdirs = sorted(d for d in pdir.iterdir() if d.is_dir()) if args.all_projects else [pdir]
    files = [f for d in pdirs for f in discover(d, cutoff)]
    # New sections: per-type runs, wait steps, main checkpoints, main high-context steps.
    types = defaultdict(
        lambda: {"runs": 0, "steps": 0, "ctx_sum": 0, "peaks": [], "cost": 0.0,
                 "fin_n": 0, "fin_cost": 0.0, "unfin": 0}
    )
    waits = defaultdict(lambda: {"n": 0, "cost": 0.0})
    ckpt_before: list[int] = []
    ckpt_after: list[int] = []
    high = {"n": 0, "human": 0, "injected": 0, "midturn": 0}
    # A "climb" is one passage of a main window from under UNATTENDED_CTX to at or over it.
    climbs = {"n": 0, "with_boundary": 0}

    for path, kind, finished in files:
        side = "main" if kind == "main" else "sub"
        run_cost, peak, run_calls = 0.0, 0, 0
        run_ctx_sum, prev_ctx = 0, None
        climb_open = climb_hit = False
        for c in read_calls(path):
            if c["id"] in seen or c["ts"] is None or c["ts"] < cutoff:
                continue
            seen.add(c["id"])
            u = c["u"]
            if not (u["input"] or u["read"] or u["write"] or u["output"]):
                continue  # synthetic/error rows carry no usage
            cst = cost(u)
            total += cst
            n_calls += 1
            run_calls += 1
            run_cost += cst
            ctx = u["input"] + u["read"] + u["write"]
            peak = max(peak, ctx)
            run_ctx_sum += ctx
            if c["wait"]:
                waits[c["wait"]]["n"] += 1
                waits[c["wait"]]["cost"] += cst
            if side == "main":
                if prev_ctx is not None and prev_ctx > CKPT_PREV_MIN and ctx < CKPT_RATIO * prev_ctx:
                    ckpt_before.append(prev_ctx)
                    ckpt_after.append(ctx)
                prev_ctx = ctx
                if ctx >= UNATTENDED_CTX:
                    high["n"] += 1
                    high[{"human": "human", "injected": "injected"}.get(c["prompt"], "midturn")] += 1
                    if not climb_open:
                        climb_open, climb_hit = True, False
                        climbs["n"] += 1
                    if c["prompt"] and ctx < UNATTENDED_CTX + CLIMB_BAND and not climb_hit:
                        climb_hit = True
                        climbs["with_boundary"] += 1
                else:
                    climb_open = False
            comp["input"] += u["input"] * W_INPUT
            comp["cache-read"] += u["read"] * W_READ
            comp["cache-write"] += u["write"] * W_WRITE
            comp["output"] += u["output"] * W_OUTPUT
            bm = by_model[c["model"]]
            bm["calls"] += 1
            bm["cost"] += cst
            bm[side] += cst
            ttl[side]["w5m"] += u["w5m"]
            ttl[side]["w1h"] += u["w1h"]
            if u["write"] > BIG_REWRITE:
                g = c["gap"]
                if c["after_compact"]:
                    cause = "after compact_boundary"
                elif g is None:
                    cause = "first call in log"
                elif g > HOUR:
                    cause = "idle > 1h"
                elif g > FIVE_MIN:
                    cause = "idle > 5m"
                else:
                    cause = "other (<5m gap)"
                r = rewrites[cause]
                r["n"] += 1
                r["tok"] += u["write"]
                r["cost"] += u["write"] * W_WRITE
                r[side] += 1
            if c["tick"]:
                g = c["gap"]
                if g is None:
                    b = "no-gap"
                elif g < 55 * 60:
                    b = "<55m"
                elif g < HOUR:
                    b = "55-60m"
                elif g < 65 * 60:
                    b = "60-65m"
                else:
                    b = ">65m"
                ticks[b]["n"] += 1
                ticks[b]["write"] += u["write"]
        if run_calls:
            k = by_kind[kind]
            k["runs"] += 1
            k["cost"] += run_cost
            k["peak_sum"] += peak
            k["calls"] += run_calls
            ty = types[kind]
            ty["runs"] += 1
            ty["steps"] += run_calls
            ty["ctx_sum"] += run_ctx_sum
            ty["peaks"].append(peak)
            ty["cost"] += run_cost
            if finished:
                ty["fin_n"] += 1
                ty["fin_cost"] += run_cost
            elif finished is False:
                ty["unfin"] += 1

    print(f"token-usage-report  dir={pdir}")
    print(
        f"window: last {args.days:g} day(s)  logs scanned: {len(files)}  "
        f"API calls (deduped): {n_calls}  weighted spend: {fmt(total)}"
    )
    print(
        "weights are APPROXIMATE RELATIVE costs per token: input 1, cache-read 0.1, "
        "cache-write 2, output 5 (shares, not dollars)"
    )

    print("\n== Spend by component")
    for k in ("cache-read", "cache-write", "output", "input"):
        print(f"  {k:<12} {pct(comp[k], total)}  {fmt(comp[k])}")

    print("\n== Main vs subagent (by agentType)")
    print(f"  {'kind':<28} {'runs':>5} {'share':>7} {'avg cost':>9} {'avg peak ctx':>13}")
    for kind, k in sorted(by_kind.items(), key=lambda kv: -kv[1]["cost"]):
        print(
            f"  {kind[:28]:<28} {k['runs']:>5} {pct(k['cost'], total):>7} "
            f"{fmt(k['cost'] / k['runs']):>9} {fmt(k['peak_sum'] / k['runs']):>13}"
        )

    print("\n== Model mix")
    print(f"  {'model':<24} {'calls':>7} {'share':>7} {'main':>7} {'sub':>7}")
    for model, m in sorted(by_model.items(), key=lambda kv: -kv[1]["cost"]):
        print(
            f"  {model[:24]:<24} {m['calls']:>7} {pct(m['cost'], total):>7} "
            f"{pct(m['main'], total):>7} {pct(m['sub'], total):>7}"
        )

    print(f"\n== Big cache re-writes (>{BIG_REWRITE // 1000}k tokens in one call) by cause")
    rw_total = sum(r["cost"] for r in rewrites.values())
    print(f"  all big re-writes: {pct(rw_total, total)} of spend")
    print(f"  {'cause':<24} {'count':>6} {'main':>5} {'sub':>5} {'tokens':>8} {'share':>7}")
    for cause, r in sorted(rewrites.items(), key=lambda kv: -kv[1]["cost"]):
        print(
            f"  {cause:<24} {r['n']:>6} {r['main']:>5} {r['sub']:>5} "
            f"{fmt(r['tok']):>8} {pct(r['cost'], total):>7}"
        )

    print("\n== Cache-write TTL split (tokens written)")
    for side in ("main", "sub"):
        t5, t1 = ttl[side]["w5m"], ttl[side]["w1h"]
        print(
            f"  {side:<5} 5m: {fmt(t5):>8} ({pct(t5, t5 + t1).strip()})   "
            f"1h: {fmt(t1):>8} ({pct(t1, t5 + t1).strip()})"
        )

    print("\n== Loop-tick / mission-wake calls by gap since the previous call")
    print(f"  {'gap':<8} {'count':>6} {'avg cache-write':>16}")
    for b in ("<55m", "55-60m", "60-65m", ">65m", "no-gap"):
        t = ticks[b]
        if b == "no-gap" and not t["n"]:
            continue
        avg = fmt(t["write"] / t["n"]) if t["n"] else "-"
        print(f"  {b:<8} {t['n']:>6} {avg:>16}")

    print("\n== Per agent type: context and spend per finished worker job")
    print(
        f"  {'kind':<28} {'runs':>5} {'steps':>6} {'avg ctx':>8} {'med peak':>9} {'max peak':>9} "
        f"{'spend':>8} {'share':>7} {'per fin job':>12} {'unfin':>6}"
    )
    for kind, ty in sorted(types.items(), key=lambda kv: -kv[1]["cost"]):
        per_job = fmt(ty["fin_cost"] / ty["fin_n"]) if ty["fin_n"] else "-"
        unfin = "-" if kind == "main" else str(ty["unfin"])
        print(
            f"  {kind[:28]:<28} {ty['runs']:>5} {ty['steps']:>6} "
            f"{fmt(ty['ctx_sum'] / ty['steps']):>8} {fmt(median(ty['peaks'])):>9} "
            f"{fmt(max(ty['peaks'])):>9} {fmt(ty['cost']):>8} {pct(ty['cost'], total):>7} "
            f"{per_job:>12} {unfin:>6}"
        )

    print("\n== Wait steps (check loops and wake-ups) by what is waited on")
    w_n = sum(w["n"] for w in waits.values())
    w_cost = sum(w["cost"] for w in waits.values())
    print(f"  all wait steps: {w_n}  {pct(w_cost, total).strip()} of spend")
    print(f"  {'step: waiting on':<40} {'steps':>6} {'share':>7}")
    for tag, w in sorted(waits.items(), key=lambda kv: (-kv[1]["cost"], kv[0])):
        print(f"  {tag:<40} {w['n']:>6} {pct(w['cost'], total):>7}")

    print(
        f"\n== Main-window checkpoints (context < {CKPT_RATIO:.0%} of the previous step, "
        f"previous > {CKPT_PREV_MIN // 1000}k)"
    )
    print(f"  count: {len(ckpt_before)}")
    if ckpt_before:
        print(
            f"  context before: median {fmt(median(ckpt_before))}  min {fmt(min(ckpt_before))}  "
            f"max {fmt(max(ckpt_before))}   after: median {fmt(median(ckpt_after))}"
        )

    print(f"\n== Main steps at >= {UNATTENDED_CTX // 1000}k context: was a prompt typed before them?")
    print(f"  steps >= {UNATTENDED_CTX // 1000}k: {high['n']}")
    print(f"  with no human-typed prompt since the previous step: {high['injected'] + high['midturn']}")
    print(f"    after an injected prompt (wake-up, notification, hook text): {high['injected']}")
    print(f"    mid-turn (only tool results since the previous step): {high['midturn']}")
    print(f"  after a human-typed prompt: {high['human']}")
    lo, hi = UNATTENDED_CTX // 1000, (UNATTENDED_CTX + CLIMB_BAND) // 1000
    print(
        f"  prompt boundaries at >= {lo}k (each is one chance for a prompt hook to fire): "
        f"{high['human'] + high['injected']}  typed {high['human']}  injected {high['injected']}"
    )
    print(
        f"  climbs past {lo}k: {climbs['n']}  with a prompt boundary between {lo}k and {hi}k: "
        f"{climbs['with_boundary']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
