#!/usr/bin/env python3
"""
line-ensure-settings.py - make THIS Mac's ~/.claude/settings.json carry what cross-Mac messaging needs.

Why it exists: ~/.claude/settings.json is per-Mac and never synced, so a Mac set up from a partial
copy silently lacks the naming hooks. That is exactly how the Mac mini ended up with no
line-reassert-identity hook, so its windows were unreachable by name from the MacBook (2026-10-16).
A rule in a doc does not fix drift; this runs on every session start (from line-reassert-identity.sh)
and from install-transfer.sh, so each Mac converges on its own.

What it ensures (adds what is missing, never reorders or touches anything else):
  - remoteControlAtStartup: true, crossSessionInbound: "accept"   (windows reachable across Macs)
  - UserPromptSubmit + SessionStart(startup|resume|fork): line-agent-communicator.py session-title
                                       (Remote Control title = peer address, so SendMessage by name works)
  - SessionStart: line-reassert-identity.sh                       (address restored after a reopen,
                                                                   and this script re-run from it)
  - SessionEnd: address-book publish                              (a closed window leaves the list)
  - PreToolUse(SendMessage): line-agent-communicator.py route-send (a name on the other Mac is sent to
                                       its bridge address, so agents just use names)
  - Stop: relink.py --heal               (a /line-named window not on Remote Control under its name -
                                       new, renamed, resumed, Pane-restored - relinks itself when idle)
  - SessionStart(startup|resume|clear|compact) + UserPromptSubmit + SubagentStart:
        hooks/rules-in-force.py            (every window and subagent follows the CURRENT CLAUDE.md:
                                       a stale checkout gets the base branch's copy, a rule edit
                                       reaches open windows as a diff; added 2026-11-17)
and REMOVES the hook entries listed in RETIRED.
Once per Mac (done-marker ~/.claude/progress/settings-once.json, so a hand undo stays undone): hides
internal sub-files and owner-only commands from agents (skillOverrides "user-invocable-only", still
typeable), sets skillListingBudgetFraction 0.01 and blocks the Apollo/Google Drive/Google Calendar
connectors (deniedMcpServers). Owner-approved 2026-11-21. Tests: scripts/test-line-ensure-settings.sh.

Safety: refuses a symlinked or unparseable settings file (prints why, changes nothing); takes a lock
so windows starting together cannot interleave writes; backs the file up before the first change;
writes atomically with the original mode. Prints one summary line (nothing with --quiet unless it
changed something or failed). Exit 0 always, so a hook calling it can never break a session start.
"""
import fcntl
import json
import os
import sys
import time
from pathlib import Path

HOME = Path(os.environ.get("HOME", str(Path.home())))
SETTINGS = Path(os.environ.get("LINE_SETTINGS_FILE", str(HOME / ".claude" / "settings.json")))
LOG = HOME / ".claude" / "logs" / "line-settings.log"

LAC = "python3 $HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
TITLE_CMD = f"{LAC} session-title"
REASSERT_CMD = "bash $HOME/.claude-dotfiles/scripts/hooks/line-reassert-identity.sh"
PUBLISH_CMD = f"{LAC} publish --background --delay 3"
ROUTE_CMD = f"{LAC} route-send"
HEAL_CMD = "python3 $HOME/.claude-dotfiles/scripts/relink.py --heal"
# Not a /line feature: this script is the one place each Mac converges its own settings.json, so every
# hook that must exist on every machine is listed here.
RIF = "python3 $HOME/.claude-dotfiles/scripts/hooks/rules-in-force.py"

# (event, matcher or None, hook entry). Identity is the command string.
REQUIRED = [
    ("UserPromptSubmit", None, {"type": "command", "command": TITLE_CMD, "timeout": 5}),
    ("SessionStart", "startup|resume|fork", {"type": "command", "command": TITLE_CMD, "timeout": 5}),
    ("SessionStart", "startup|resume|clear|compact",
     {"type": "command", "command": REASSERT_CMD, "timeout": 10, "async": True}),
    ("SessionEnd", None, {"type": "command", "command": PUBLISH_CMD, "timeout": 5}),
    ("PreToolUse", "SendMessage", {"type": "command", "command": ROUTE_CMD, "timeout": 5}),
    ("Stop", None, {"type": "command", "command": HEAL_CMD, "timeout": 5}),
    ("SessionStart", "startup|resume|clear|compact",
     {"type": "command", "command": f"{RIF} session-start", "timeout": 15}),
    ("UserPromptSubmit", None, {"type": "command", "command": f"{RIF} prompt", "timeout": 5}),
    ("SubagentStart", None, {"type": "command", "command": f"{RIF} subagent", "timeout": 5}),
]
REQUIRED_KEYS = {"remoteControlAtStartup": True, "crossSessionInbound": "accept"}
# Commands whose hook entries are removed wherever they appear.
RETIRED = [
    # Typed /rename into a Terminal.app tab; never ran in Pane/iTerm/tmux. Replaced 2026-10-16 by
    # the session-title hook (an official sessionTitle output, every terminal).
    "$HOME/.claude-dotfiles/scripts/hooks/line-apply-rename.sh",
]


# Applied ONCE per Mac (owner-approved 2026-11-21, context trim Phase 1), then never re-applied, so the owner
# can undo any of it by hand and it stays undone. Done-marker: ~/.claude/progress/settings-once.json.
# Hidden skills stay typeable by the owner ("user-invocable-only"); agents stop seeing them in the list.
#   - internal sub-files their parent reads by PATH (god-review, ui-audit, database-audit, macmini, windows...)
#   - commands only the owner starts. Never hide pre-compact, post-compact-resume or mission.
HIDE_SUBFILES = [
    "database-audit:core", "database-audit:guards", "database-audit:providers:neon",
    "database-audit:providers:postgres", "database-audit:providers:supabase", "database-audit:redaction",
    "database-audit:tests:README", "devtools-CHANGELOG",
    "god-review:broad-reviewers:claude-architecture-prod",
    "god-review:broad-reviewers:claude-deep-correctness",
    "god-review:broad-reviewers:claude-ruthless-redteam",
    "god-review:broad-reviewers:claude-security-resilience",
    "god-review:broad-reviewers:codex-cross-layer", "god-review:broad-reviewers:codex-data-integrity",
    "god-review:broad-reviewers:codex-deep-correctness",
    "god-review:broad-reviewers:codex-prod-scalability",
    "god-review:broad-reviewers:codex-ruthless-redteam",
    "god-review:broad-reviewers:codex-security-safeguards", "god-review:CHANGELOG", "god-review:CRITERIA",
    "god-review:lib:editor-agent", "god-review:principles:antipatterns",
    "god-review:principles:architecture-backend", "god-review:principles:architecture-frontend",
    "god-review:principles:ci-yaml-tampering", "god-review:principles:circular-deps",
    "god-review:principles:clarity", "god-review:principles:contradiction-detector",
    "god-review:principles:database-audit", "god-review:principles:dead-code-conservatism",
    "god-review:principles:dead-end-detector", "god-review:principles:documentation",
    "god-review:principles:gap-detector", "god-review:principles:hallucinated-imports",
    "god-review:principles:info-loss-detector", "god-review:principles:perf-benchmark",
    "god-review:principles:perf-heuristic", "god-review:principles:prompt-injection",
    "god-review:principles:reuse", "god-review:principles:scope", "god-review:principles:secret-leak",
    "god-review:principles:self-contained", "god-review:principles:single-pattern",
    "god-review:principles:tanstack-query", "god-review:principles:test-deletion", "god-review:README",
    "macmini:act", "macmini:connect", "macmini:crd", "macmini:setup", "plan_base", "pre-compact-template",
    "speedeval:README", "ui-audit:CHANGELOG", "ui-audit:passes:dynamic-exercise",
    "ui-audit:passes:quality", "ui-audit:passes:reconcile", "ui-audit:passes:static-trace",
    "ui-audit:passes:vision-inspect", "ui-audit:README", "ui-audit:rubric", "windows:act",
    "windows:connect", "windows:crd",
]
HIDE_OWNER_ONLY = [
    "outreach", "master-review", "afk", "transcribe", "wispralt-update", "share-fix", "skill-improve",
    "claudemd", "dockersetup", "simple-plan", "commit", "investigate", "prepare-pr",
]
# Connectors kept off unless the owner turns one back on (remove its entry from deniedMcpServers).
DENY_SERVERS = ["claude.ai Apollo.io", "claude.ai Google Drive", "claude.ai Google Calendar"]
ONCE_ID = "context-trim-phase1-2026-11-21"
ONCE_MARKER = HOME / ".claude" / "progress" / "settings-once.json"


def once_done() -> bool:
    try:
        return ONCE_ID in json.loads(ONCE_MARKER.read_text())
    except Exception:
        return False


def mark_once() -> None:
    try:
        d = json.loads(ONCE_MARKER.read_text()) if ONCE_MARKER.exists() else {}
    except Exception:
        d = {}
    d[ONCE_ID] = int(time.time())
    ONCE_MARKER.parent.mkdir(parents=True, exist_ok=True)
    tmp = ONCE_MARKER.with_suffix(".tmp")
    tmp.write_text(json.dumps(d, indent=1))
    os.replace(tmp, ONCE_MARKER)


def apply_once(d: dict) -> list[str]:
    """The one-time context-trim settings. Merges; never removes anything the owner set."""
    changed = []
    ov = d.get("skillOverrides")
    ov = dict(ov) if isinstance(ov, dict) else {}
    added = [n for n in HIDE_SUBFILES + HIDE_OWNER_ONLY if n not in ov]
    for n in added:
        ov[n] = "user-invocable-only"
    if added:
        d["skillOverrides"] = ov
        changed.append(f"skillOverrides +{len(added)}")
    if d.get("skillListingBudgetFraction", 0.01) != 0.01:
        d["skillListingBudgetFraction"] = 0.01
        changed.append("skillListingBudgetFraction 0.01")
    deny = d.get("deniedMcpServers")
    deny = list(deny) if isinstance(deny, list) else []
    have = {e.get("serverName") for e in deny if isinstance(e, dict)}
    new = [{"serverName": n} for n in DENY_SERVERS if n not in have]
    if new:
        d["deniedMcpServers"] = deny + new
        changed.append(f"deniedMcpServers +{len(new)}")
    return changed


def log(msg: str) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        if LOG.exists() and LOG.stat().st_size > 65536:
            LOG.write_bytes(LOG.read_bytes()[-32768:])
        with open(LOG, "a") as fh:
            fh.write(time.strftime("%Y-%m-%dT%H:%M:%SZ ", time.gmtime()) + msg + "\n")
    except Exception:
        pass


def has_command(blocks, cmd: str) -> bool:
    return any(isinstance(b, dict) and any(isinstance(h, dict) and h.get("command") == cmd
                                           for h in b.get("hooks") or [])
               for b in blocks)


def converge(d: dict) -> list[str]:
    """Mutates the parsed settings toward REQUIRED/RETIRED. Returns what changed."""
    changed = []
    for key, value in REQUIRED_KEYS.items():
        if d.get(key) != value:
            d[key] = value
            changed.append(key)
    hooks = d.setdefault("hooks", {})
    for event in list(hooks):
        blocks = hooks[event] if isinstance(hooks[event], list) else []
        for b in blocks:
            if not isinstance(b, dict):
                continue
            kept = [h for h in b.get("hooks") or [] if not (isinstance(h, dict) and h.get("command") in RETIRED)]
            if len(kept) != len(b.get("hooks") or []):
                b["hooks"] = kept
                changed.append(f"removed retired {event} hook")
        pruned = [b for b in blocks if not (isinstance(b, dict) and not b.get("hooks"))]
        if len(pruned) != len(blocks):
            hooks[event] = pruned
    for event, matcher, entry in REQUIRED:
        blocks = hooks.setdefault(event, [])
        if not isinstance(blocks, list):
            raise ValueError(f"hooks.{event} is not a list")
        if has_command(blocks, entry["command"]):
            continue
        target = next((b for b in blocks if isinstance(b, dict) and b.get("matcher") == matcher), None)
        if target is None:
            target = {"matcher": matcher, "hooks": []} if matcher is not None else {"hooks": []}
            blocks.append(target)
        target.setdefault("hooks", []).append(dict(entry))
        changed.append(f"{event} {entry['command'].split('/')[-1]}")
    return changed


def main() -> int:
    quiet = "--quiet" in sys.argv[1:]
    dry = "--dry-run" in sys.argv[1:]

    def say(msg: str, always: bool = False) -> None:
        if always or not quiet:
            print(f"line-ensure-settings: {msg}")

    if SETTINGS.is_symlink():
        say(f"{SETTINGS} is a symlink - not editing it; add the hooks by hand (docs/SETUP.md).", True)
        return 0
    if not SETTINGS.exists():
        say(f"{SETTINGS} is missing - copy settings.json.template there first (docs/SETUP.md).", True)
        return 0
    lock_path = SETTINGS.with_name(".line-ensure-settings.lock")
    try:
        with open(lock_path, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            raw = SETTINGS.read_text()
            try:
                d = json.loads(raw)
                if not isinstance(d, dict):
                    raise ValueError("top level is not an object")
                changed = converge(d)
                once = [] if once_done() else apply_once(d)
                changed += once
            except ValueError as e:
                say(f"{SETTINGS} could not be read as settings ({e}) - changed nothing.", True)
                log(f"refused unparseable settings: {e}")
                return 0
            if not changed:
                if not once_done() and not dry:
                    mark_once()
                say("already configured")
                return 0
            if dry:
                say("would change: " + ", ".join(changed), True)
                return 0
            stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
            backup = SETTINGS.with_name(f"{SETTINGS.name}.bak-line-{stamp}")
            backup.write_text(raw)
            mode = SETTINGS.stat().st_mode & 0o777
            tmp = SETTINGS.with_name(f".{SETTINGS.name}.line-tmp")
            tmp.write_text(json.dumps(d, indent=2) + "\n")
            os.chmod(tmp, mode)
            os.replace(tmp, SETTINGS)
            if not once_done():
                mark_once()
            say("updated: " + ", ".join(changed) + f" (backup {backup.name})", True)
            log("updated: " + ", ".join(changed) + f" backup={backup.name}")
    except OSError as e:
        say(f"could not update {SETTINGS} ({e.__class__.__name__}: {e})", True)
        log(f"error {e.__class__.__name__}: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
