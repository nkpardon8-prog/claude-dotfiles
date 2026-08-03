#!/usr/bin/env python3
"""
PreToolUse gate - block a shell-detach wrapping a codex launch.

Why: an autonomous /mission that launches a review shell-detached
(`nohup codex ... &`) sees the wrapper exit in ~1s; the harness then tracks the
launcher, NOT codex. codex finishes orphaned and nothing wakes the idle agent -
the mission silently stalls (road 1 of the mission-stall root cause, e.g.
f71c8667 idle 3h38m). This nudges the agent to launch codex in the FOREGROUND of
a `run_in_background: true` Bash so its completion re-invokes the idle agent.

Design (mirror of prod-coordination-gate.py's skeleton, opposite harm-direction):
  * FAILS OPEN. The harm here is a false POSITIVE (wedging normal Bash), so ANY
    parse error, empty command, or unexpected exception -> allow(). This gate
    only ever BLOCKS on a confident positive match; it never fails closed.
  * NARROW + DOCUMENTED KNOWN-OPENS. It backstops the common literal
    nohup / & / disown / setsid forms wrapping a `codex` token. Bypasses
    (`bash -c '...'`, `( codex ) &` inside quotes, `$CODEX_BIN`, aliases,
    `& sleep`/`& somecmd`) are ACCEPTED and documented - it does not "remove
    discretion", it catches the foot-gun.
  * `wait` is deliberately NOT in the detach alternation: `codex & wait` blocks
    until codex exits, which is SAFE and must not be blocked.
  * `&&` is correctly allowed via the `(?<!&)` negative-lookbehind
    (e.g. `codex && echo` is a sequence, not a detach).
"""
import sys, json, re

# A shell-detach: nohup/disown/setsid, or a bare `&` that ends the command or is
# followed by a trivial no-op (disown/echo/true/printf/comment). `wait` is
# intentionally absent (`codex & wait` blocks -> safe). The `(?<!&)` before the
# alternation keeps `&&` (a sequence operator) from matching.
DETACH = re.compile(
    r'(^|\s)(nohup|disown|setsid)(\s|$)'
    r'|(?<!&)&\s*(disown|echo|true|printf|#|$)'
)
# The classic redirect-then-detach form: `... >/dev/null 2>&1 &` (not `&&`).
REDIR_DETACH = re.compile(r'>\s*/dev/null\s+2>&1\s*&(?!&)')
# A codex launch token. Case-sensitive by design: `$CODEX_BIN` deliberately does
# NOT match (accepted known-open).
CODEX = re.compile(r'\bcodex\b|codex-exec\.sh|codex-invoke\.sh')


def allow():
    sys.exit(0)


def block(message):
    print(f"NO-DETACH: {message}", file=sys.stderr)
    sys.exit(2)


def is_detached_codex(cmd):
    return bool((DETACH.search(cmd) or REDIR_DETACH.search(cmd)) and CODEX.search(cmd))


def main():
    try:
        raw = sys.stdin.read()
        d = json.loads(raw) if raw.strip() else {}
    except Exception:
        allow()

    try:
        cmd = (d.get("tool_input") or {}).get("command", "") or ""
    except Exception:
        allow()

    # Empty command or not a detached-codex launch -> never gate (fail open).
    if not cmd or not is_detached_codex(cmd):
        allow()

    block(
        "this shell-detaches a codex launch (nohup / trailing & / disown / setsid). "
        "The wrapper exits immediately, the harness tracks the launcher not codex, "
        "codex finishes orphaned, and an idle /mission never wakes. Instead run codex "
        "in the FOREGROUND of a `run_in_background: true` Bash, wrapped in `pt_run` so it "
        "is bounded - the wrapper's completion re-invokes the idle agent. "
        "See commands/codex-review.md."
    )


try:
    main()
except SystemExit:
    raise
except Exception:
    # Fail OPEN: a nudge gate must never wedge Bash.
    allow()
