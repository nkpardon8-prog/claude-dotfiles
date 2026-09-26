#!/usr/bin/env python3
"""token-usage-report.py - where did the Claude tokens go? (before/after measurement)

PURPOSE. Token-saving changes (agent model/effort, subagent cache TTL, the /mission 3300s wake
cap, smaller /implement chunks) must be VERIFIED from the session logs, not assumed. This script
reads one project's Claude Code transcripts (~/.claude/projects/<encoded-cwd>/) and prints the
same breakdown the 2026-09-26 token-usage brief was built on, so a run before a change and a run
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
re-caches ~1k. stdlib only.

USAGE. token-usage-report.py [--project-dir DIR] [--days N]
  --project-dir  default: ~/.claude/projects/<current cwd with every non-alphanumeric -> '-'>
  --days         default 3 (API calls whose timestamp is within the last N days)
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from collections import defaultdict
from datetime import datetime
from pathlib import Path

W_INPUT, W_READ, W_WRITE, W_OUTPUT = 1.0, 0.1, 2.0, 5.0
BIG_REWRITE = 50_000
TICK_MARKERS = ("Autonomous loop tick", "MISSION WAKE", "mission wake")
HOUR, FIVE_MIN = 3600.0, 300.0


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
    classify it: gap since the previous call, compact_boundary in between, tick prompt before it."""
    calls: dict[str, dict] = {}
    order: list[str] = []
    prev_ts: float | None = None
    compact_pending = False
    last_user_is_tick = False
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
            }
            order.append(mid)
            compact_pending = False
            last_user_is_tick = False
            if ts is not None:
                prev_ts = ts
    return [calls[i] for i in order]


def discover(project_dir: Path, cutoff: float) -> list[tuple[Path, str]]:
    """(path, agent kind) for every log touched since cutoff. kind = 'main' or the agentType."""
    out: list[tuple[Path, str]] = []
    for p in project_dir.glob("*.jsonl"):
        if p.stat().st_mtime >= cutoff:
            out.append((p, "main"))
    for p in project_dir.glob("*/subagents/**/*.jsonl"):
        if p.stat().st_mtime < cutoff:
            continue
        kind = "subagent:?"
        meta = p.with_suffix(".meta.json")
        try:
            kind = json.loads(meta.read_text()).get("agentType") or kind
        except (OSError, ValueError, AttributeError):
            pass
        out.append((p, kind))
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
    ap.add_argument("--days", type=float, default=3.0)
    args = ap.parse_args()
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
    files = discover(pdir, cutoff)

    for path, kind in files:
        side = "main" if kind == "main" else "sub"
        run_cost, peak, run_calls = 0.0, 0, 0
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
            peak = max(peak, u["input"] + u["read"] + u["write"])
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
    return 0


if __name__ == "__main__":
    sys.exit(main())
