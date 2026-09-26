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

# Clickable "Resume Chat" app on the Desktop: asks for the code, opens Terminal, runs resumework.
# Only ever (re)builds an app THIS script made: the marker below lives inside the bundle, so an app
# of the same name that the owner made or installed some other way is never overwritten. Built in
# a scratch dir first, so a failed compile never leaves a half-replaced app behind.
APP="$HOME/Desktop/Resume Chat.app"
APP_MARKER_REL="Contents/Resources/.built-by-install-transfer"
if [ -e "$APP" ] && [ ! -f "$APP/$APP_MARKER_REL" ]; then
    echo "WARNING: $APP exists and was not built by this script (no $APP_MARKER_REL inside it) - left untouched." >&2
    echo "  Move or rename it and re-run to get the transfer version; resumework still works from Terminal." >&2
else
    APP_TMP=$(mktemp -d "${TMPDIR:-/tmp}/resume-chat-app.XXXXXX")
    if osacompile -o "$APP_TMP/Resume Chat.app" "$REPO/scripts/transfer/resume-chat.applescript" 2>/dev/null \
        && mkdir -p "$APP_TMP/Resume Chat.app/Contents/Resources" \
        && printf 'built by %s at %s\n' "scripts/transfer/install-transfer.sh" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            > "$APP_TMP/Resume Chat.app/$APP_MARKER_REL"; then
        mkdir -p "$(dirname "$APP")"
        rm -rf "$APP"
        mv "$APP_TMP/Resume Chat.app" "$APP"
        echo "  built $APP (first launch: allow it to control Terminal)"
    else
        echo "WARNING: could not build $APP (osacompile failed); resumework still works from Terminal." >&2
    fi
    rm -rf "$APP_TMP"
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
