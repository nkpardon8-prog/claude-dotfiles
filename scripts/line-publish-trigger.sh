#!/bin/bash
# line-publish-trigger.sh - keep the shared window address book fresh, from the statusline.
#
# Called by scripts/statusline.sh on every render, in every window. It must cost almost nothing and
# can never block or print, so it does ONE cheap check (the publish stamp's age, plain bash + stat)
# and, at most once a minute per Mac, starts `line-agent-communicator.py publish --throttle 60`
# fully DETACHED (nohup + disown, all I/O to /dev/null) and returns at once - even if iCloud hangs,
# the statusline never waits. The Python side claims the minute atomically (a lock plus the same
# stamp), so many windows rendering together still produce one publish.
#
# Why from Claude Code and not a LaunchAgent: publishing has to run where it can write iCloud Drive,
# and Claude Code windows (Terminal) can. A background launchd job could not keep this Mac's file
# current (2026-10-15), so it was removed.
#
# Test hooks: LAC_SCRIPT (script under test), LAC_TRIGGER_INTERVAL (seconds), and the same
# LAC_CACHE_DIR / LAC_WINDOWS_DIR overrides the Python side honours.
set -u

LAC="${LAC_SCRIPT:-$HOME/.claude-dotfiles/scripts/line-agent-communicator.py}"
INTERVAL="${LAC_TRIGGER_INTERVAL:-60}"
[ -f "$LAC" ] || exit 0

# Same rule as cache_dir() in line-agent-communicator.py - keep the two in step.
if [ -n "${LAC_CACHE_DIR:-}" ]; then
    CACHE="$LAC_CACHE_DIR"
elif [ -n "${LAC_WINDOWS_DIR:-}" ]; then
    CACHE="$(dirname "$LAC_WINDOWS_DIR")/.$(basename "$LAC_WINDOWS_DIR")-cache"
else
    [ -d "$HOME/Library/Mobile Documents/com~apple~CloudDocs" ] || exit 0   # no iCloud Drive: nothing to do
    CACHE="$HOME/.claude/claude-windows-cache"
fi

STAMP="$CACHE/.publish-stamp"
if [ -f "$STAMP" ]; then
    m=$(stat -f %m "$STAMP" 2>/dev/null || echo 0)
    [ $(( $(date +%s) - m )) -lt "$INTERVAL" ] && exit 0
fi

nohup python3 "$LAC" publish --throttle "$INTERVAL" </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
