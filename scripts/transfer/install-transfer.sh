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
#
# Also sets up the shared window address book: creates iCloud Drive/claude-windows/ and adds a
# SessionEnd hook to settings.json. Publishing itself is driven from Claude Code (statusline trigger,
# SessionStart, /line, SessionEnd), which can write iCloud Drive. An earlier LaunchAgent
# (com.claude-dotfiles.windows-publish) could not keep the file current, so this script now REMOVES
# it - only a plist carrying this script's marker.

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

# Settings this machine needs for cross-Mac messaging and /line names: one implementation, shared
# with the SessionStart self-heal in line-reassert-identity.sh. Idempotent, backs up before a change.
python3 "$REPO/scripts/line-ensure-settings.py" | sed 's/^line-ensure-settings: /  settings: /'

# Shared window address book: every Mac writes its live windows to iCloud Drive/claude-windows/
# (one file per Mac) so `line-agent-communicator.py list`/`find` on the OTHER Mac can see them.
# Publishing runs from Claude Code itself (scripts/line-publish-trigger.sh via the statusline, at most
# once a minute; SessionStart; /line; SessionEnd) because it can write iCloud Drive.
WIN_DIR="$ICLOUD_BASE/claude-windows"
mkdir -p "$WIN_DIR" && echo "  shared window address book: $WIN_DIR"
LAC="$REPO/scripts/line-agent-communicator.py"

# Remove the retired LaunchAgent (2026-10-15): a launchd job could not keep this Mac's file current.
# Only a plist carrying this script's marker is removed; launchctl is only driven when $HOME is this
# account's real home (LAC_LAUNCHCTL_ALLOW_SANDBOX=1 lets a test with a stubbed launchctl opt in, and
# only under the transfer suite's TRANSFER_TESTS_ALLOW_DEV=true gate).
LA_LABEL="com.claude-dotfiles.windows-publish"
LA_PLIST="$HOME/Library/LaunchAgents/$LA_LABEL.plist"
LA_MARKER="built-by: scripts/transfer/install-transfer.sh"
REAL_HOME=$(python3 -c 'import os,pwd; print(pwd.getpwuid(os.getuid()).pw_dir)' 2>/dev/null || true)
LA_CAN_LOAD=0
if [ "$HOME" = "$REAL_HOME" ]; then
    LA_CAN_LOAD=1
elif [ "${LAC_LAUNCHCTL_ALLOW_SANDBOX:-}" = "1" ] && [ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ]; then
    LA_CAN_LOAD=1   # dev-only test hook: a sandbox run whose launchctl is a PATH stub
fi
if [ -e "$LA_PLIST" ]; then
    if grep -qF "$LA_MARKER" "$LA_PLIST" 2>/dev/null; then
        if [ "$LA_CAN_LOAD" -eq 1 ]; then
            launchctl bootout "gui/$(id -u)/$LA_LABEL" >/dev/null 2>&1 || true
        fi
        rm -f "$LA_PLIST" && echo "  removed the retired address-book LaunchAgent ($LA_LABEL)"
    else
        echo "WARNING: $LA_PLIST exists and was not made by this script - left untouched." >&2
    fi
fi

# Publish once now (with the prefetch of the other Macs' files), so this Mac appears right away.
python3 "$LAC" publish -v || echo "WARNING: publish failed - see ~/.claude/logs/windows-publish.log" >&2

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
