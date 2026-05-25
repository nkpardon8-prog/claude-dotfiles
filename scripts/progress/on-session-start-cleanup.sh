#!/usr/bin/env bash
# SessionStart cleanup — removes progress files older than 7 days.
mkdir -p "$HOME/.claude/progress" 2>/dev/null
chmod 700 "$HOME/.claude/progress" 2>/dev/null
find "$HOME/.claude/progress" -type f -mtime +7 -delete 2>/dev/null
# Prune stale auto-compact sentinels (and abandoned claim files) older than 720 minutes (12h).
# Covers cases where /pre-compact armed auto-compact but Terminal was killed, or the user
# walked away for an afternoon before the Stop hook fired. 12h is the realistic
# "I'll be back later today" upper bound; shorter would race against long sessions.
find "$HOME/.claude/progress" -maxdepth 1 \( -name 'auto-compact-*.json' -o -name 'auto-compact-*.json.claim.*' -o -name 'pre-compact-parent-*.json' \) -mmin +720 -delete 2>/dev/null || true
# R7-INC-03 (F3): GC stale PID-keyed pre-compact scratch files (>720 min / 12h old).
# Scratch files are normally removed by Step 9.1 (orchestrator self-cleanup) or by the
# Stop hook (if PRECOMPACT_PID is exported). The 720-min GC here is a final safety net
# covering cases where /pre-compact was killed before Step 9.1 ran.
find "$HOME/.claude/progress" -maxdepth 1 -name 'pre-compact-scratch-*.json' -mmin +720 -delete 2>/dev/null || true
exit 0
