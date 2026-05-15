#!/bin/bash
# Best-effort refresh before launching Codex.

set -euo pipefail

REPO="${CLAUDE_DOTFILES_DIR:-$HOME/.claude-dotfiles}"
QUIET=0

for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET=1 ;;
        *)
            echo "usage: $0 [--quiet]" >&2
            exit 2
            ;;
    esac
done

log() {
    [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"
}

[ -d "$REPO/.git" ] || { log "not a git repo: $REPO"; exit 0; }

run_sync() {
    cd "$REPO"
    git pull --ff-only --quiet >/dev/null 2>&1 || true
    "$REPO/scripts/install-codex.sh" --quiet --skip-shell >/dev/null 2>&1 || true
}

if command -v flock >/dev/null 2>&1; then
    (
        flock -n 9 || exit 0
        run_sync
    ) 9>/tmp/claude-dotfiles-codex-sync.lock
else
    LOCKDIR=/tmp/claude-dotfiles-codex-sync.lock.d
    if mkdir "$LOCKDIR" 2>/dev/null; then
        trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT
        run_sync
    fi
fi

log "Codex dotfiles refreshed."
