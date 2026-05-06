#!/bin/bash
# gather-context.sh — single canonical context-fallback for principle agents.
# Sourced by every principle file when tmp/god-review/context-package.md is missing.
# Per Locked Decision #5 in 2026-05-05-god-review-fixes-plus-second-review plan.

# Bootstrap WORKDIR (per Locked Decision #18)
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export WORKDIR

# Source persisted env if available (per Locked Decision #1, absolute path)
[ -f "$WORKDIR/tmp/god-review/.env.sh" ] && source "$WORKDIR/tmp/god-review/.env.sh"

# Fallback context: if no shared context-package.md exists, gather minimal context here.
if [ ! -f "$WORKDIR/tmp/god-review/context-package.md" ]; then
  echo "(no shared context-package.md — gathering inline)"
  echo "WORKDIR: $WORKDIR"
  echo "Branch: $(git -C "$WORKDIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  echo "Recent diff scope (changed files):"
  git -C "$WORKDIR" diff main...HEAD --name-only 2>/dev/null | head -20 || echo "(no diff)"
fi

# Make context-package path available to caller
export CONTEXT_PACKAGE="$WORKDIR/tmp/god-review/context-package.md"
