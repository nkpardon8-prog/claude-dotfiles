#!/usr/bin/env python3
"""parallel-stats.py - transcript parallelism instrumentation.

Usage:
    parallel-stats.py <transcript.jsonl|dir>... [--json] [--replay]

Measures how much of a Claude Code session's tool traffic was issued SERIALLY
when it could have been issued in one message. Produces the baseline the
parallelizer work is judged against, plus an opt-in `--replay` that answers two
counterfactuals: "would a nudge have fired?" and "would the wave gate have
opened?".

COUNTING RULES (single source of truth - the baseline artifact quotes these):

  R1  INPUT SET. A directory argument contributes its TOP-LEVEL `*.jsonl` files
      only (no recursion). Any path containing `/subagents/` is EXCLUDED, even
      when passed explicitly: subagent transcripts are a subagent's own tool
      traffic and would double-count the orchestrator's decisions.

  R2  TURN = message.id GROUP. Tool calls are grouped by `message.id`, NOT by
      JSONL record. A single assistant message routinely spans SEVERAL JSONL
      records, each carrying part of the same message's content blocks
      (measured: 24 of 69 tool-bearing messages in a sampled session span 2-3
      records). Grouping per record would report same-message batches as
      separate solo turns - the exact metric this tool exists to measure. A
      group's position in the session is the index of its FIRST record.

  R3  SPAWN TURN = a group containing >=1 `Task` or `Agent` tool_use.
      width = number of those blocks in the group. width 1 => solo,
      width >=2 => batched. (Diagnosis only: a solo spawn is not automatically
      waste - a genuinely single-item step is correctly solo.)

  R4  CODEX TURN = a group containing >=1 `Bash` tool_use whose `command`
      contains "codex exec" or "codex-exec.sh".
        RAW SOLO      - exactly one codex Bash block in the group (whatever
                        else the group contains).
        REFINED SOLO  - RAW SOLO **and** the group contains NO other tool_use
                        block at all **and** no data dependency on the previous
                        codex turn. Dependency heuristic: the command mentions a
                        file path token that also appeared in the immediately
                        preceding codex turn's command (report chaining - e.g.
                        pass 2 reads pass 1's report file). A dependent call
                        COULD NOT have been batched, so it is not waste.
      Both numbers are always printed. RAW is the upper bound on waste; REFINED
      is the defensible one.

  R5  SURFACE ATTRIBUTION. Each group is attributed to the nearest PRECEDING
      command-invocation marker in the same transcript, from the closed set
      {codex-review, god-review, master-review, mission}; none => "ad-hoc".
      Markers, strongest first:
        strong - a `Skill` tool_use whose `skill` names one of the four, or a
                 user record carrying `<command-name>/<one of the four>`;
        weak   - the literal "/<name>" appearing in user or assistant TEXT
                 (tool_result payloads are never scanned).
      Weak markers are counted and reported separately so a reader can discount
      attribution that rests on a passing mention. The --replay wave-gate
      denominator uses STRONG markers ONLY: "/implement" appears constantly in
      ordinary prose, and counting those mentions as invocations inflated the
      phase count 49x on the 2026-08-02 baseline sample (1512 vs 31 real runs).

  R6  WALL-CLOCK. Per-surface phases run from a marker to the next marker.
      "span" = last minus first record timestamp; "active" = the same sum with
      inter-record gaps > 30 min dropped (idle time is not work).

  R7  REWORK EVENTS. `$PARALLEL_WAVES_DIR/rework.log` (default
      `~/.claude/parallel-waves/rework.log`), JSONL, one event per line. Absent
      file is normal (pre-machinery) and is not an error. Events whose
      `repo_root` contains "-assumptions/fixtures" are DROPPED - those come from
      hermetic test runs, not real work.

Exit codes: 0 ok, 2 usage error.
Python 3 standard library only.
"""

from __future__ import annotations

import bisect
import collections
import datetime as _dt
import json
import os
import re
import sys

# ---------------------------------------------------------------- constants

SPAWN_TOOLS = ("Task", "Agent")
CODEX_MARKERS = ("codex exec", "codex-exec.sh")

# R5 - the closed surface set for codex/spawn attribution.
SURFACES = ("codex-review", "god-review", "master-review", "mission")

# A wider set used ONLY to segment phases for the --replay wave-gate question
# (the wave gate lives in /implement, which is deliberately NOT a codex surface).
PHASE_COMMANDS = SURFACES + ("implement", "plan", "script", "prepare-pr", "god-report")

IDLE_GAP_S = 30 * 60          # R6 - gap above which time is idle, not work
NUDGE_DEDUPE_S = 15 * 60      # replay - one nudge per window per trigger
ACTIVE_GAP_S = 5 * 60         # replay - gap that ends an "active stretch"
ACTIVE_FALLBACK_S = 30 * 60   # replay - 30-min-activity fallback trigger
OPEN_TASK_THRESHOLD = 3       # replay - 3+ open tasks
CONSECUTIVE_SOLO_K = 2        # replay - K consecutive solo spawn groups
WAVE_WIDTH_MAX = 4
PCT_CEILING = 60              # wave gate: PCT empty or > 60 => serial

# R7 - the CLOSED rework.log reason vocabulary, mirroring wave-plan-schema.md s7.2
# (schema_version parallelizer.v1.1). A reason outside this set is a DRIFTED token and is
# counted separately so a silent new category is visible rather than blending into by_reason.
# The v1.1 de-aliasing lets analytics tell a merged wave (merge_success) from a verify pass
# (fan_out), and a rule violation from a merge conflict from a usage/io error.
REWORK_REASONS = frozenset((
    "lt2_chunks", "no_review", "dirty_repo_root", "merge_in_progress", "pct_unknown",
    "pct_over_60", "stale_wave", "dotfiles_unpaused", "serial_correct",
    "low_confidence", "fan_out",
    "rule_violation", "usage_error", "io_error", "merge_success", "merge_conflict",
    "malformed",
))

_TS_RE = re.compile(r'"timestamp":"([^"]+)"')
_CMDNAME_RE = re.compile(r"<command-name>\s*/([a-z0-9][a-z0-9-]*)")
_PATH_TOKEN_RE = re.compile(r"[A-Za-z0-9_./~-]*/[A-Za-z0-9_.-]+\.[A-Za-z0-9]{1,6}")

# Lines worth a full json.loads. Transcripts reach hundreds of MB and are
# dominated by tool_result payloads that carry nothing we count; everything we
# do count leaves one of these fingerprints in the raw line.
_PARSE_HINTS = (
    '"type":"tool_use"',
    '"type": "tool_use"',
    "command-name",
    '"usage"',
)
_TEXT_HINTS = tuple("/" + c for c in PHASE_COMMANDS)


# ---------------------------------------------------------------- utilities

def _parse_ts(raw):
    if not raw:
        return None
    try:
        s = raw[:-1] + "+00:00" if raw.endswith("Z") else raw
        return _dt.datetime.fromisoformat(s).timestamp()
    except (ValueError, TypeError):
        return None


def _iter_text(content):
    """Yield human/assistant TEXT only. tool_result payloads are never text."""
    if isinstance(content, str):
        yield content
    elif isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                txt = block.get("text")
                if isinstance(txt, str):
                    yield txt


def _path_tokens(command):
    return {t.lstrip("./") for t in _PATH_TOKEN_RE.findall(command or "")}


def _fmt_hms(seconds):
    if seconds is None:
        return "n/a"
    seconds = int(seconds)
    return "%dh%02dm" % (seconds // 3600, (seconds % 3600) // 60)


def _pct(part, whole):
    return 0.0 if not whole else round(100.0 * part / whole, 1)


# ---------------------------------------------------------------- data model

class Group:
    """R2 - one message.id worth of tool calls, merged across JSONL records."""

    __slots__ = ("mid", "first_index", "first_ts", "names", "codex_cmds",
                 "spawn_types", "records")

    def __init__(self, mid, index, ts):
        self.mid = mid
        self.first_index = index
        self.first_ts = ts
        self.names = []
        self.codex_cmds = []
        self.spawn_types = []
        self.records = 0

    @property
    def spawn_width(self):
        return sum(1 for n in self.names if n in SPAWN_TOOLS)

    @property
    def codex_width(self):
        return len(self.codex_cmds)

    @property
    def is_spawn(self):
        return self.spawn_width >= 1

    @property
    def is_codex(self):
        return self.codex_width >= 1


class Session:
    __slots__ = ("path", "sid", "cwd", "groups", "surface_markers",
                 "phase_markers", "weak_marker_count", "ts_by_index",
                 "task_events", "usage_points", "no_review_indices",
                 "records", "tool_counts", "marker_keys", "no_review_at")

    def __init__(self, path):
        self.path = path
        self.sid = os.path.basename(path)[:-6]
        self.cwd = None
        self.groups = []
        self.surface_markers = []      # [(index, surface, strength)]
        self.phase_markers = []        # [(index, command, strength)]
        self.weak_marker_count = 0
        self.ts_by_index = []
        self.task_events = []          # [(index, 'create'|'complete', key)]
        self.usage_points = []         # [(index, ctx_tokens)]
        self.no_review_at = set()   # indices whose INVOCATION carries --no-review
        self.records = 0
        self.tool_counts = collections.Counter()
        self.marker_keys = None      # lazily built index cache for attribute()


# ---------------------------------------------------------------- parsing

def parse_session(path):
    s = Session(path)
    groups = {}
    seen_completed = set()
    created = 0

    with open(path, encoding="utf-8", errors="replace") as fh:
        for index, line in enumerate(fh):
            s.records += 1
            ts = None

            hinted = any(h in line for h in _PARSE_HINTS)
            if not hinted:
                hinted = any(h in line for h in _TEXT_HINTS)
            if not hinted:
                m = _TS_RE.search(line)
                ts = _parse_ts(m.group(1)) if m else None
                s.ts_by_index.append(ts)
                continue

            try:
                rec = json.loads(line)
            except (ValueError, TypeError):
                m = _TS_RE.search(line)
                s.ts_by_index.append(_parse_ts(m.group(1)) if m else None)
                continue

            ts = _parse_ts(rec.get("timestamp"))
            s.ts_by_index.append(ts)
            if s.cwd is None and rec.get("cwd"):
                s.cwd = rec.get("cwd")

            rtype = rec.get("type")
            if rtype not in ("user", "assistant"):
                continue
            message = rec.get("message") or {}
            content = message.get("content")

            # --- markers (R5) -------------------------------------------
            for text in _iter_text(content):
                for cm in _CMDNAME_RE.finditer(text):
                    name = cm.group(1)
                    if name in SURFACES:
                        s.surface_markers.append((index, name, "strong"))
                    if name in PHASE_COMMANDS:
                        s.phase_markers.append((index, name, "strong"))
                for name in PHASE_COMMANDS:
                    if "/" + name in text:
                        if name in SURFACES:
                            s.surface_markers.append((index, name, "weak"))
                            s.weak_marker_count += 1
                        s.phase_markers.append((index, name, "weak"))
                if "--no-review" in text and "<command-args>" in text:
                    s.no_review_at.add(index)

            if rtype != "assistant" or not isinstance(content, list):
                continue

            usage = message.get("usage")
            if isinstance(usage, dict):
                ctx = 0
                for key in ("input_tokens", "cache_read_input_tokens",
                            "cache_creation_input_tokens"):
                    val = usage.get(key)
                    if isinstance(val, int):
                        ctx += val
                if ctx:
                    s.usage_points.append((index, ctx))

            blocks = [b for b in content
                      if isinstance(b, dict) and b.get("type") == "tool_use"]
            if not blocks:
                continue

            mid = message.get("id") or rec.get("uuid") or "idx-%d" % index
            grp = groups.get(mid)
            if grp is None:
                grp = Group(mid, index, ts)
                groups[mid] = grp
                s.groups.append(grp)
            grp.records += 1

            for block in blocks:
                name = block.get("name") or "?"
                inp = block.get("input") if isinstance(block.get("input"), dict) else {}
                s.tool_counts[name] += 1
                grp.names.append(name)

                if name in SPAWN_TOOLS:
                    grp.spawn_types.append(inp.get("subagent_type") or "?")
                elif name == "Bash":
                    cmd = inp.get("command")
                    if isinstance(cmd, str) and any(m in cmd for m in CODEX_MARKERS):
                        grp.codex_cmds.append(cmd)
                elif name == "Skill":
                    skill = inp.get("skill")
                    if skill in SURFACES:
                        s.surface_markers.append((index, skill, "strong"))
                    if skill in PHASE_COMMANDS:
                        s.phase_markers.append((index, skill, "strong"))
                    args = inp.get("args")
                    if isinstance(args, str) and "--no-review" in args:
                        s.no_review_at.add(index)
                elif name == "TaskCreate":
                    created += 1
                    s.task_events.append((index, "create", "auto-%d" % created))
                elif name == "TaskUpdate":
                    if inp.get("status") == "completed":
                        key = str(inp.get("taskId"))
                        if key not in seen_completed:
                            seen_completed.add(key)
                            s.task_events.append((index, "complete", key))

    s.surface_markers.sort(key=lambda t: t[0])
    s.phase_markers.sort(key=lambda t: t[0])
    s.groups.sort(key=lambda g: g.first_index)
    return s


# ---------------------------------------------------------------- inputs (R1)

def collect_inputs(args):
    out, skipped = [], []
    for arg in args:
        if os.path.isdir(arg):
            for name in sorted(os.listdir(arg)):
                if not name.endswith(".jsonl"):
                    continue
                path = os.path.join(arg, name)
                if os.path.isfile(path):
                    out.append(path)
        elif os.path.isfile(arg):
            out.append(arg)
        else:
            skipped.append((arg, "not found"))
    kept, excluded = [], []
    for path in out:
        real = os.path.abspath(path)
        if "/subagents/" in real:
            excluded.append(real)
        else:
            kept.append(real)
    return kept, excluded, skipped


# ---------------------------------------------------------------- attribution

def attribute(session, index):
    """R5 - nearest preceding surface marker.

    The marker index list is cached on the session: attribution runs once per
    group and a long session carries thousands of both, so rebuilding the list
    per call would be quadratic.
    """
    markers = session.surface_markers
    if not markers:
        return "ad-hoc", "none"
    if session.marker_keys is None:
        session.marker_keys = [m[0] for m in markers]
    pos = bisect.bisect_right(session.marker_keys, index) - 1
    if pos < 0:
        return "ad-hoc", "none"
    _, surface, strength = markers[pos]
    return surface, strength


# ---------------------------------------------------------------- metrics

def analyse(sessions):
    spawn_total = spawn_solo = 0
    width_hist = collections.Counter()
    codex_total = 0
    raw_solo = refined_solo = 0
    dependent = 0
    codex_by_surface = collections.defaultdict(
        lambda: {"turns": 0, "raw_solo": 0, "refined_solo": 0, "weak_attr": 0})
    spawn_by_surface = collections.defaultdict(
        lambda: {"turns": 0, "solo": 0})
    tool_counts = collections.Counter()
    per_session = []

    for s in sessions:
        tool_counts.update(s.tool_counts)
        prev_codex_paths = set()
        s_spawn = s_solo = s_codex = s_raw = s_ref = 0

        for grp in s.groups:
            if grp.is_spawn:
                spawn_total += 1
                s_spawn += 1
                width_hist[grp.spawn_width] += 1
                surface, _ = attribute(s, grp.first_index)
                spawn_by_surface[surface]["turns"] += 1
                if grp.spawn_width == 1:
                    spawn_solo += 1
                    s_solo += 1
                    spawn_by_surface[surface]["solo"] += 1

            if grp.is_codex:
                codex_total += 1
                s_codex += 1
                surface, strength = attribute(s, grp.first_index)
                bucket = codex_by_surface[surface]
                bucket["turns"] += 1
                if strength == "weak":
                    bucket["weak_attr"] += 1

                cmd = grp.codex_cmds[0]
                this_paths = _path_tokens(cmd)
                is_dependent = bool(this_paths & prev_codex_paths)

                if grp.codex_width == 1:
                    raw_solo += 1
                    s_raw += 1
                    bucket["raw_solo"] += 1
                    alone = len(grp.names) == 1
                    if alone and not is_dependent:
                        refined_solo += 1
                        s_ref += 1
                        bucket["refined_solo"] += 1
                if is_dependent:
                    dependent += 1
                prev_codex_paths = set()
                for c in grp.codex_cmds:
                    prev_codex_paths |= _path_tokens(c)

        per_session.append({
            "session": s.sid,
            "records": s.records,
            "tool_calls": sum(s.tool_counts.values()),
            "spawn_turns": s_spawn,
            "spawn_solo": s_solo,
            "codex_turns": s_codex,
            "codex_raw_solo": s_raw,
            "codex_refined_solo": s_ref,
            "wall_clock_s": session_span(s),
        })

    return {
        "tool_inventory": dict(sorted(tool_counts.items(),
                                      key=lambda kv: (-kv[1], kv[0]))),
        "spawn": {
            "turns": spawn_total,
            "solo": spawn_solo,
            "batched": spawn_total - spawn_solo,
            "solo_pct": _pct(spawn_solo, spawn_total),
            "width_histogram": dict(sorted(width_hist.items())),
            "by_surface": {k: v for k, v in sorted(spawn_by_surface.items())},
        },
        "codex": {
            "turns": codex_total,
            "raw_solo": raw_solo,
            "raw_solo_pct": _pct(raw_solo, codex_total),
            "refined_solo": refined_solo,
            "refined_solo_pct": _pct(refined_solo, codex_total),
            "dependency_flagged": dependent,
            "by_surface": {k: v for k, v in sorted(codex_by_surface.items())},
        },
        "per_session": per_session,
    }


def session_span(s):
    stamps = [t for t in s.ts_by_index if t]
    return round(stamps[-1] - stamps[0], 1) if len(stamps) >= 2 else None


def phase_wall_clock(sessions):
    """R6 - per-surface span and active time."""
    out = collections.defaultdict(lambda: {"phases": 0, "span_s": 0.0, "active_s": 0.0})
    for s in sessions:
        boundaries = [(-1, "ad-hoc")] + [(i, n) for i, n, _ in s.surface_markers]
        for pos, (start, surface) in enumerate(boundaries):
            end = boundaries[pos + 1][0] if pos + 1 < len(boundaries) else len(s.ts_by_index)
            stamps = [t for t in s.ts_by_index[max(start, 0):end] if t]
            if len(stamps) < 2:
                continue
            bucket = out[surface]
            bucket["phases"] += 1
            bucket["span_s"] += stamps[-1] - stamps[0]
            bucket["active_s"] += sum(
                b - a for a, b in zip(stamps, stamps[1:]) if 0 <= b - a <= IDLE_GAP_S)
    return {k: {"phases": v["phases"],
                "span_s": round(v["span_s"], 1),
                "active_s": round(v["active_s"], 1)}
            for k, v in sorted(out.items())}


# ---------------------------------------------------------------- rework log

def read_rework_log():
    base = os.environ.get("PARALLEL_WAVES_DIR") or os.path.expanduser(
        "~/.claude/parallel-waves")
    path = os.path.join(base, "rework.log")
    result = {"path": path, "present": False, "events": 0, "dropped_fixture": 0,
              "malformed": 0, "by_reason": {}, "by_repo_root": {},
              "recognized_reason": 0, "unrecognized_reason": 0,
              "unrecognized_reasons": {}}
    if not os.path.isfile(path):
        return result
    result["present"] = True
    reasons = collections.Counter()
    roots = collections.Counter()
    unrecognized = collections.Counter()
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except (ValueError, TypeError):
                result["malformed"] += 1
                continue
            if not isinstance(ev, dict):
                result["malformed"] += 1
                continue
            root = str(ev.get("repo_root") or "")
            if "-assumptions/fixtures" in root:      # R7
                result["dropped_fixture"] += 1
                continue
            result["events"] += 1
            reason = str(ev.get("reason") or ev.get("verdict") or "unknown")
            reasons[reason] += 1
            if reason in REWORK_REASONS:
                result["recognized_reason"] += 1
            else:
                result["unrecognized_reason"] += 1
                unrecognized[reason] += 1
            roots[root or "unknown"] += 1
    result["by_reason"] = dict(sorted(reasons.items()))
    result["by_repo_root"] = dict(sorted(roots.items()))
    result["unrecognized_reasons"] = dict(sorted(unrecognized.items()))
    return result


# ---------------------------------------------------------------- replay

def replay_nudges(sessions):
    fired = {"open_tasks_3plus": 0, "consecutive_solo_spawns": 0,
             "activity_30min": 0}
    detail = []

    for s in sessions:
        per = collections.Counter()

        # trigger 1 - 3+ open tasks while spawning solo
        events = sorted(s.task_events, key=lambda e: e[0])
        ei, open_tasks, last_fire = 0, 0, None
        for grp in s.groups:
            while ei < len(events) and events[ei][0] <= grp.first_index:
                open_tasks += 1 if events[ei][1] == "create" else -1
                ei += 1
            if grp.is_spawn and grp.spawn_width == 1 and open_tasks >= OPEN_TASK_THRESHOLD:
                ts = grp.first_ts
                if last_fire is None or ts is None or ts - last_fire >= NUDGE_DEDUPE_S:
                    per["open_tasks_3plus"] += 1
                    last_fire = ts if ts is not None else last_fire

        # trigger 2 - K consecutive solo spawn groups
        run = 0
        for grp in s.groups:
            if not grp.is_spawn:
                continue
            if grp.spawn_width == 1:
                run += 1
                if run >= CONSECUTIVE_SOLO_K:
                    per["consecutive_solo_spawns"] += 1
                    run = 0
            else:
                run = 0

        # trigger 3 - 30 minutes of activity with no batched spawn
        stamps = [(i, t) for i, t in enumerate(s.ts_by_index) if t]
        batched_at = sorted(g.first_ts for g in s.groups
                            if g.is_spawn and g.spawn_width >= 2 and g.first_ts)
        window_start = None
        prev = None
        for _, t in stamps:
            if prev is None or t - prev > ACTIVE_GAP_S:
                window_start = t
            elif window_start is not None and t - window_start >= ACTIVE_FALLBACK_S:
                lo = bisect.bisect_left(batched_at, window_start)
                hi = bisect.bisect_right(batched_at, t)
                if hi - lo == 0:
                    per["activity_30min"] += 1
                window_start = t
            prev = t

        for key in fired:
            fired[key] += per[key]
        detail.append({"session": s.sid, **{k: per[k] for k in fired}})

    return {"totals": fired, "per_session": detail,
            "thresholds": {"open_tasks": OPEN_TASK_THRESHOLD,
                           "consecutive_solo_spawns": CONSECUTIVE_SOLO_K,
                           "activity_window_s": ACTIVE_FALLBACK_S,
                           "dedupe_s": NUDGE_DEDUPE_S}}


WAVE_CONDITIONS = (
    ("chunks_ge_2", ">=2 pending chunks"),
    ("not_no_review", "NO_REVIEW is false"),
    ("repo_root_clean", "repo_root tracked-clean, no merge underway"),
    ("pct_known_le_60", "context PCT known and <= 60"),
    ("no_stale_wave", "no stale wave-state for this repo_root"),
    ("repo_root_ok", "repo_root not an unpaused ~/.claude-dotfiles"),
)


def replay_wave_gate(sessions):
    """Would the wave gate have opened, per implement phase?

    Decomposed per condition. An implement phase counts as OPEN only if every
    condition is open; conditions we cannot evaluate from a transcript are
    ASSUMED open and reported separately - that is why the headline is an
    UPPER BOUND, never a measurement.
    """
    rows = {key: {"label": label, "evaluated_open": 0, "evaluated_closed": 0,
                  "assumed_open": 0, "sessions_evaluable": 0}
            for key, label in WAVE_CONDITIONS}
    total_phases = 0
    open_phases = 0
    weak_mentions = 0
    phases_detail = []
    sessions_with_phases = 0

    for s in sessions:
        strong_bounds = sorted({i for i, _, strength in s.phase_markers
                                if strength == "strong"})
        phases = [(i, n) for i, n, strength in s.phase_markers
                  if n == "implement" and strength == "strong"]
        weak_mentions += sum(1 for _, n, strength in s.phase_markers
                             if n == "implement" and strength == "weak")
        if not phases:
            continue
        sessions_with_phases += 1
        evaluable_here = set()

        for pos, (start, _) in enumerate(phases):
            nxt = bisect.bisect_right(strong_bounds, start)
            end = (strong_bounds[nxt] if nxt < len(strong_bounds)
                   else len(s.ts_by_index))
            total_phases += 1

            impl_spawns = [g for g in s.groups
                           if start <= g.first_index < end and g.is_spawn
                           and any(t == "implementer" for t in g.spawn_types)]
            any_spawns = [g for g in s.groups
                          if start <= g.first_index < end and g.is_spawn]

            verdict = {}

            # c1 - >=2 chunks. A batched implementer spawn, or >=2 implementer
            # spawns in the phase, PROVES >=2 chunks existed. A single lone
            # implementer spawn is ambiguous (one chunk, or a chunk-at-a-time
            # serial run) => not evaluable.
            if any(g.spawn_width >= 2 for g in impl_spawns) or len(impl_spawns) >= 2:
                verdict["chunks_ge_2"] = "evaluated_open"
                evaluable_here.add("chunks_ge_2")
            elif impl_spawns or any_spawns:
                verdict["chunks_ge_2"] = "assumed_open"
            else:
                verdict["chunks_ge_2"] = "assumed_open"

            # c2 - NO_REVIEW, evaluable from the invocation text/args.
            evaluable_here.add("not_no_review")
            if start in s.no_review_at:
                verdict["not_no_review"] = "evaluated_closed"
            else:
                verdict["not_no_review"] = "evaluated_open"

            # c3 - working-tree state: not recorded in transcripts.
            verdict["repo_root_clean"] = "assumed_open"

            # c4 - context PCT. Estimated from assistant `usage` at the phase
            # start. The model's real context window is not recorded, so the
            # condition closes only when the estimate exceeds 60% under BOTH
            # the 200k and the 1M window (conservative: fewer false closes).
            pct = _phase_pct(s, start, end)
            if pct is None:
                verdict["pct_known_le_60"] = "assumed_open"
            else:
                evaluable_here.add("pct_known_le_60")
                closed = pct["pct_200k"] > PCT_CEILING and pct["pct_1m"] > PCT_CEILING
                verdict["pct_known_le_60"] = ("evaluated_closed" if closed
                                              else "evaluated_open")

            # c5 - stale wave-state: the machinery did not exist historically.
            verdict["no_stale_wave"] = "assumed_open"

            # c6 - repo_root, evaluable from the record `cwd`.
            evaluable_here.add("repo_root_ok")
            cwd = s.cwd or ""
            verdict["repo_root_ok"] = ("evaluated_closed"
                                       if cwd.rstrip("/").endswith(".claude-dotfiles")
                                       else "evaluated_open")

            for key, state in verdict.items():
                rows[key][state] += 1
            phase_open = all(v != "evaluated_closed" for v in verdict.values())
            if phase_open:
                open_phases += 1
            phases_detail.append({"session": s.sid, "start_record": start,
                                  "implementer_spawns": len(impl_spawns),
                                  "open": phase_open, "verdict": verdict})

        for key in evaluable_here:
            rows[key]["sessions_evaluable"] += 1

    for row in rows.values():
        row["coverage"] = "%d/%d" % (row["sessions_evaluable"], len(sessions))

    return {
        "sessions_total": len(sessions),
        "weak_implement_mentions_ignored": weak_mentions,
        "sessions_with_implement_phases": sessions_with_phases,
        "implement_phases": total_phases,
        "phases_gate_open_upper_bound": open_phases,
        "conditions": rows,
        "phases": phases_detail,
        "wave_width_max": WAVE_WIDTH_MAX,
    }


def _phase_pct(s, start, end):
    """Context estimate AT the invocation - the moment the gate would read it.

    The real context window is not recorded, so a caller may only treat the
    condition as closed when the estimate exceeds the ceiling under BOTH the
    200k and the 1M window.
    """
    points = [c for i, c in s.usage_points if start <= i < end]
    if not points:
        return None
    ctx = points[0]
    return {"ctx_tokens": ctx,
            "pct_200k": round(100.0 * ctx / 200_000, 1),
            "pct_1m": round(100.0 * ctx / 1_000_000, 1)}


# ---------------------------------------------------------------- reporting

def render_text(report, out):
    w = out.write
    inputs = report["inputs"]

    w("=" * 72 + "\n")
    w("parallel-stats - transcript parallelism baseline\n")
    w("=" * 72 + "\n\n")

    w("OBSERVED TOOL-NAME INVENTORY (all counted transcripts)\n")
    inv = report["metrics"]["tool_inventory"]
    if not inv:
        w("  (none)\n")
    for name, count in inv.items():
        w("  %-42s %7d\n" % (name, count))
    w("\n")

    w("INPUTS\n")
    w("  transcripts counted : %d\n" % len(inputs["counted"]))
    for path in inputs["counted"]:
        w("    - %s\n" % path)
    w("  excluded (/subagents/): %d\n" % len(inputs["excluded_subagents"]))
    for path in inputs["excluded_subagents"]:
        w("    - %s\n" % path)
    for path, why in inputs["skipped"]:
        w("    ! skipped %s (%s)\n" % (path, why))
    w("\n")

    spawn = report["metrics"]["spawn"]
    w("SPAWN TURNS (Task|Agent tool_use grouped by message.id) [diagnosis only]\n")
    w("  total          : %d\n" % spawn["turns"])
    w("  solo (width 1) : %d  (%.1f%%)\n" % (spawn["solo"], spawn["solo_pct"]))
    w("  batched (>=2)  : %d\n" % spawn["batched"])
    w("  width histogram:\n")
    for width, count in spawn["width_histogram"].items():
        w("    width %-3d %5d  %s\n" % (width, count, "#" * min(count, 50)))
    if spawn["by_surface"]:
        w("  by surface:\n")
        for surface, data in spawn["by_surface"].items():
            w("    %-14s turns %4d  solo %4d (%.1f%%)\n"
              % (surface, data["turns"], data["solo"],
                 _pct(data["solo"], data["turns"])))
    w("\n")

    codex = report["metrics"]["codex"]
    w("CODEX TURNS (Bash command contains \"codex exec\" or \"codex-exec.sh\")\n")
    w("  total codex turns      : %d\n" % codex["turns"])
    w("  RAW solo               : %d  (%.1f%%)\n"
      % (codex["raw_solo"], codex["raw_solo_pct"]))
    w("  REFINED solo           : %d  (%.1f%%)\n"
      % (codex["refined_solo"], codex["refined_solo_pct"]))
    w("  dependency-flagged     : %d  (chained on the previous codex call)\n"
      % codex["dependency_flagged"])
    w("  REFINED = solo AND nothing else in the same message.id group AND no\n")
    w("            path-token overlap with the previous codex command.\n")
    if codex["by_surface"]:
        w("  by surface:\n")
        w("    %-14s %6s %8s %10s %10s\n"
          % ("surface", "turns", "raw", "refined", "weak-attr"))
        for surface, data in codex["by_surface"].items():
            w("    %-14s %6d %8d %10d %10d\n"
              % (surface, data["turns"], data["raw_solo"],
                 data["refined_solo"], data["weak_attr"]))
        w("    (weak-attr = attributed via a plain \"/name\" text mention rather\n")
        w("     than a Skill call or <command-name> marker.)\n")
    w("\n")

    w("PER-SURFACE WALL-CLOCK (span vs active; gaps > 30m counted as idle)\n")
    w("  %-14s %7s %12s %12s\n" % ("surface", "phases", "span", "active"))
    for surface, data in report["wall_clock"].items():
        w("  %-14s %7d %12s %12s\n"
          % (surface, data["phases"], _fmt_hms(data["span_s"]),
             _fmt_hms(data["active_s"])))
    w("\n")

    w("PER-SESSION\n")
    w("  %-38s %7s %7s %7s %7s %8s\n"
      % ("session", "spawn", "solo", "codex", "refsolo", "span"))
    for row in report["metrics"]["per_session"]:
        w("  %-38s %7d %7d %7d %7d %8s\n"
          % (row["session"], row["spawn_turns"], row["spawn_solo"],
             row["codex_turns"], row["codex_refined_solo"],
             _fmt_hms(row["wall_clock_s"])))
    w("\n")

    rework = report["rework"]
    w("REWORK LOG (%s)\n" % rework["path"])
    if not rework["present"]:
        w("  absent - no wave machinery has run yet (not an error)\n")
    else:
        w("  events kept          : %d\n" % rework["events"])
        w("  dropped (fixtures)   : %d\n" % rework["dropped_fixture"])
        w("  malformed lines      : %d\n" % rework["malformed"])
        w("  recognized reasons   : %d\n" % rework["recognized_reason"])
        w("  drifted reasons      : %d\n" % rework["unrecognized_reason"])
        for reason, count in rework["by_reason"].items():
            tag = "" if reason in REWORK_REASONS else "  (drifted - not in the v1.1 closed set)"
            w("    reason %-24s %5d%s\n" % (reason, count, tag))
    w("\n")

    if "replay" in report:
        render_replay(report["replay"], w)


def render_replay(replay, w):
    w("=" * 72 + "\n")
    w("REPLAY - counterfactuals (nothing was actually nudged or gated)\n")
    w("=" * 72 + "\n\n")

    nudges = replay["nudges"]
    w("WOULD-HAVE-FIRED NUDGES\n")
    w("  %-28s %8s\n" % ("trigger", "fires"))
    for key, count in nudges["totals"].items():
        w("  %-28s %8d\n" % (key, count))
    w("  thresholds: %s\n\n" % json.dumps(nudges["thresholds"]))

    gate = replay["wave_gate"]
    w("WOULD THE WAVE GATE HAVE OPENED?\n")
    w("  UPPER BOUND: %d of %d /implement phases (%.1f%%)\n"
      % (gate["phases_gate_open_upper_bound"], gate["implement_phases"],
         _pct(gate["phases_gate_open_upper_bound"], gate["implement_phases"])))
    w("  Labelled UPPER BOUND because conditions marked assumed-open below are\n")
    w("  not recorded in transcripts and are credited as open.\n")
    w("  sessions with /implement phases: %d/%d\n"
      % (gate["sessions_with_implement_phases"], gate["sessions_total"]))
    w("  a phase = a real invocation (Skill call / <command-name>); %d prose\n"
      % gate["weak_implement_mentions_ignored"])
    w("  mentions of \"/implement\" were ignored as phase boundaries.\n\n")
    w("  %-18s %-42s %9s %9s %9s %10s\n"
      % ("condition", "meaning", "eval-open", "eval-shut", "assumed", "coverage"))
    for key, _ in WAVE_CONDITIONS:
        row = gate["conditions"][key]
        w("  %-18s %-42s %9d %9d %9d %10s\n"
          % (key, row["label"][:42], row["evaluated_open"],
             row["evaluated_closed"], row["assumed_open"], row["coverage"]))
    w("  coverage = sessions in which this condition was EVALUABLE / sessions counted.\n\n")


# ---------------------------------------------------------------- main

def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    flags = {a for a in argv if a.startswith("--")}
    unknown = flags - {"--json", "--replay"}
    if unknown or not args:
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        if unknown:
            sys.stderr.write("unknown flag(s): %s\n" % ", ".join(sorted(unknown)))
        return 2

    counted, excluded, skipped = collect_inputs(args)
    if not counted:
        sys.stderr.write("no countable top-level *.jsonl transcripts in: %s\n"
                         % ", ".join(args))
        return 2

    sessions = [parse_session(p) for p in counted]

    report = {
        "inputs": {"counted": counted, "excluded_subagents": excluded,
                   "skipped": skipped},
        "counting_rules": [line.strip() for line in __doc__.splitlines()
                           if line.strip().startswith("R")][:7],
        "metrics": analyse(sessions),
        "wall_clock": phase_wall_clock(sessions),
        "rework": read_rework_log(),
    }
    if "--replay" in flags:
        report["replay"] = {"nudges": replay_nudges(sessions),
                            "wave_gate": replay_wave_gate(sessions)}

    if "--json" in flags:
        json.dump(report, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        render_text(report, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
