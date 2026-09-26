#!/bin/bash
# Idempotently link the transfer terminal commands onto PATH and make sure
# the iCloud drop dir exists. Modeled on scripts/install-codex.sh.
#
# Links:
#   ~/.local/bin/resumework      -> scripts/transfer/resumework
#   ~/.local/bin/transfer-doctor -> scripts/transfer/transfer-doctor
#
# Refuses (does not overwrite) if a non-symlink file already sits at either
# target path. Safe to re-run.

set -euo pipefail

REPO="${CLAUDE_DOTFILES_DIR:-$HOME/.claude-dotfiles}"
BIN_DIR="${TRANSFER_BIN_DIR:-$HOME/.local/bin}"
ICLOUD_BASE="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
DROP_DIR="$ICLOUD_BASE/claude-transfers"

[ -d "$REPO" ] || { echo "missing repo: $REPO" >&2; exit 1; }

mkdir -p "$BIN_DIR"

link_one() {
    local src="$1" name="$2" dest
    dest="$BIN_DIR/$name"

    if [ ! -e "$src" ]; then
        echo "  skip $name: source missing at $src" >&2
        return 1
    fi
    chmod +x "$src" 2>/dev/null || true

    if [ -L "$dest" ]; then
        rm -f "$dest"
    elif [ -e "$dest" ]; then
        echo "refuse: $dest exists and is not a symlink; remove it by hand and re-run" >&2
        exit 1
    fi

    ln -s "$src" "$dest"
    echo "  linked $name -> $src"
    return 0
}

echo "Installing transfer commands from $REPO into $BIN_DIR"
# `|| true` only covers the non-fatal "source missing" return; the refuse
# case (a non-symlink already at the destination) calls `exit 1` directly
# inside link_one and still terminates the whole script under set -e.
link_one "$REPO/scripts/transfer/resumework" "resumework" || true
link_one "$REPO/scripts/transfer/transfer-doctor" "transfer-doctor" || true

if [ ! -d "$DROP_DIR" ]; then
    mkdir -p "$DROP_DIR"
    echo "  created iCloud drop dir: $DROP_DIR"
else
    echo "  iCloud drop dir already present: $DROP_DIR"
fi

case ":$PATH:" in
    *":$BIN_DIR:"*)
        echo "$BIN_DIR is on PATH."
        ;;
    *)
        echo "WARNING: $BIN_DIR is not on PATH." >&2
        echo "  Add this to your shell rc file: export PATH=\"$BIN_DIR:\$PATH\"" >&2
        ;;
esac

echo "Done."
