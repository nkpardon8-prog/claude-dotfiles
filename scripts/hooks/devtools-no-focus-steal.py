#!/usr/bin/env python3
"""
PreToolUse rewrite - stop chrome-devtools agents from yanking the user's screen to Chrome.

Why: `select_page {bringToFront:true}` and `new_page` (foreground by default) activate the
tab AND raise Chrome over whatever app the user is in (macOS activates the window). Agents
reached for both ~25 times across past sessions; the user can be anywhere and gets pulled
into the browser. The MCP's own click/fill/type never raise the window (it emulates focus
for every page), so these two params are the whole problem. A rule in the skill alone does
not hold - agents already ignore the `background` default - so this rewrites the input.

Behavior:
  * select_page -> bringToFront forced to false.
  * new_page    -> background forced to true.
  * Skipped for sessions that loaded /macmini or /windows: driving a Chrome Remote Desktop
    canvas is out of scope for this guard (owner call, 2026-09-18).
  * FAILS OPEN: any parse error or unexpected input -> exit 0 with no output (call unchanged).
"""
import json, re, sys

CRD_SKILL = re.compile(r'<command-name>/(macmini|windows)\b|"skill"\s*:\s*"(macmini|windows)\b')


def session_uses_crd(transcript_path):
    try:
        with open(transcript_path, errors="ignore") as f:
            return any(CRD_SKILL.search(line) for line in f)
    except (OSError, TypeError):
        return False


def main():
    try:
        data = json.load(sys.stdin)
        tool = data.get("tool_name", "")
        tool_input = data.get("tool_input") or {}
    except Exception:
        return

    if tool.endswith("__select_page"):
        if not tool_input.get("bringToFront"):
            return
        updated = {**tool_input, "bringToFront": False}
    elif tool.endswith("__new_page"):
        if tool_input.get("background") is True:
            return
        updated = {**tool_input, "background": True}
    else:
        return

    if session_uses_crd(data.get("transcript_path")):
        return

    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "updatedInput": updated,
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
