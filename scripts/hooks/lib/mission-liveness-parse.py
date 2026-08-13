#!/usr/bin/env python3
"""Decide whether the just-ended assistant turn booked its next wake.

Reads a slice of a Claude Code session transcript (JSONL) on stdin and prints exactly one token:

    yes      the turn called ScheduleWakeup and it did not fail  -> the mission is continuing
    no       the turn is complete and contains no successful ScheduleWakeup -> a NAKED YIELD
    unknown  we cannot establish the turn boundary or its contents -> caller MUST fail silent

Extracted from mission-liveness.sh so it can be unit-tested directly; the hook is a thin caller.

WHY THE TURN BOUNDARY IS THE HARD PART (this is the bug that shipped in review round 1):
a turn is NOT "a contiguous run of assistant records". In a real transcript a tool call and its
result alternate, and **the result is stored as a `user` record**:

    user(str prompt) -> assistant(tool_use) -> user(tool_result) -> assistant(tool_use)
                     -> user(tool_result) -> assistant(text)

so scanning backwards and stopping at the first non-assistant record stops at a tool_result and
never reaches the ScheduleWakeup that was genuinely called. Replayed against a real transcript that
mistake returned "no" for a healthy turn - i.e. it would have blocked exactly the runs behaving
correctly. The real boundary is the last `user` record that is an actual PROMPT: content is a bare
string, or a list carrying no tool_result block. Everything after it belongs to this turn.
"""
import json
import sys


def _content(rec):
    return (rec.get("message") or {}).get("content")


def _is_tool_result_carrier(rec):
    """True for a `user` record that is a tool RESULT, not a human/tick prompt."""
    c = _content(rec)
    if isinstance(c, list):
        return any(isinstance(b, dict) and b.get("type") == "tool_result" for b in c)
    return False


def _is_prompt(rec):
    """True for a `user` record that starts a turn (a real prompt: human, or a scheduled tick)."""
    if rec.get("type") != "user":
        return False
    c = _content(rec)
    if isinstance(c, str):
        return True
    if isinstance(c, list):
        return not _is_tool_result_carrier(rec)
    return False


def _prompt_text(rec):
    c = _content(rec)
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(
            b.get("text") or "" for b in c if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def decide(rows, sid=None):
    # Subagent (sidechain) records interleave into the same file. A subagent's turn is not this
    # session's turn, and its tool calls are not ours to credit or blame.
    rows = [r for r in rows if isinstance(r, dict) and r.get("isSidechain") is not True]

    boundary = None
    for i in range(len(rows) - 1, -1, -1):
        if _is_prompt(rows[i]):
            boundary = i
            break
    if boundary is None:
        # No prompt in view: the slice was truncated mid-turn, or this is a fresh/odd transcript.
        return "unknown"

    # TURN ORIGIN. A guard that blocks a turn the HUMAN started is worse than the freeze it prevents:
    # it interrupts a real conversation and orders the model to go do mission work instead. Arming is
    # per-session, which scopes the damage to the right window but does not prevent it - the user can
    # interrupt an autonomous run and keep using that same window for hours.
    # The discriminator is evidence we already hold: a wake turn is started by the self-contained tick
    # prompt that /mission itself authored (mission.md section 12.2), and that prompt carries the sid.
    # A human does not type the sid. So: no sid in the boundary prompt => not a wake turn => never
    # block. Deliberately STRICT - a wake source whose prompt omits the sid (e.g. a background-job
    # completion) is treated as human and skipped, costing at most one missed catch, which the
    # mandatory fallback heartbeat already covers. Missing a catch is cheap; blocking a human is not.
    if sid and sid not in _prompt_text(rows[boundary]):
        return "human"

    window = rows[boundary + 1:]
    if not any(r.get("type") == "assistant" for r in window):
        # A prompt with no assistant reply after it: the turn has not been flushed (the documented
        # transcript lag). Never judge an unwritten turn.
        return "unknown"

    call_ids = []
    for r in window:
        if r.get("type") != "assistant":
            continue
        c = _content(r)
        if not isinstance(c, list):
            continue
        for b in c:
            if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "ScheduleWakeup":
                call_ids.append(b.get("id"))
    if not call_ids:
        return "no"

    # A ScheduleWakeup that FAILED is not a booking - the playbook is explicit that a failed
    # schedule must not be treated as continuation. Only an explicit is_error result disqualifies:
    # a call whose result has not been written yet is credited, because the bias is against
    # blocking, and an in-flight result is the transcript-lag case.
    errored = set()
    for r in window:
        c = _content(r)
        if not isinstance(c, list):
            continue
        for b in c:
            if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("is_error"):
                errored.add(b.get("tool_use_id"))
    return "no" if all(cid in errored for cid in call_ids) else "yes"


def main():
    sid = sys.argv[1] if len(sys.argv) > 1 else None
    rows = []
    for line in sys.stdin:
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            rows.append(json.loads(line))
        except Exception:
            continue  # a partial leading line from a byte-bounded tail is expected
    if not rows:
        print("unknown")
        return
    print(decide(rows, sid))


if __name__ == "__main__":
    main()
