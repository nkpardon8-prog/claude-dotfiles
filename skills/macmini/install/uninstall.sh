#!/usr/bin/env bash
# uninstall.sh — Remove the macmini-server LaunchAgent.
#
# Usage:
#   uninstall.sh            # bootout + remove plist (preserves binaries and token)
#   uninstall.sh --purge    # also remove /usr/local/bin/macmini-{server,client} and ~/.config/macmini-server
#   uninstall.sh --help
#
# Always idempotent: safe to run when nothing is installed.

set -euo pipefail

LABEL="com.macmini-skill.server"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
CONFIG_DIR="$HOME/.config/macmini-server"
SERVER_BIN="/usr/local/bin/macmini-server"
CLIENT_BIN="/usr/local/bin/macmini-client"

PURGE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --purge)
            PURGE=1
            shift
            ;;
        -h|--help)
            sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown flag: $1" >&2
            echo "See --help." >&2
            exit 2
            ;;
    esac
done

removed=()
kept=()

# --- launchd: bootout (ignore failure if not loaded) ---
if launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null; then
    removed+=("launchd service ${LABEL} (bootout)")
else
    kept+=("launchd service ${LABEL} was not loaded")
fi

# --- plist file ---
if [[ -f "$PLIST" ]]; then
    rm -f "$PLIST"
    removed+=("$PLIST")
else
    kept+=("$PLIST (already absent)")
fi

if [[ $PURGE -eq 1 ]]; then
    # --- binaries (require sudo) ---
    if [[ -e "$SERVER_BIN" || -e "$CLIENT_BIN" ]]; then
        echo "Purge requested. Removing /usr/local/bin/macmini-{server,client} (sudo required)."
        if sudo rm -f "$SERVER_BIN" "$CLIENT_BIN"; then
            removed+=("$SERVER_BIN")
            removed+=("$CLIENT_BIN")
        else
            echo "WARN: sudo rm failed; binaries left in place." >&2
            kept+=("$SERVER_BIN (sudo failed)")
            kept+=("$CLIENT_BIN (sudo failed)")
        fi
    else
        kept+=("$SERVER_BIN (already absent)")
        kept+=("$CLIENT_BIN (already absent)")
    fi

    # --- token + config dir ---
    if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR"
        removed+=("$CONFIG_DIR (token + config)")
    else
        kept+=("$CONFIG_DIR (already absent)")
    fi
fi

# --- report ---
echo
echo "=== uninstall report ==="
if [[ ${#removed[@]} -eq 0 ]]; then
    echo "Removed: (nothing)"
else
    echo "Removed:"
    for item in "${removed[@]}"; do
        echo "  - $item"
    done
fi

if [[ ${#kept[@]} -gt 0 ]]; then
    echo "Untouched:"
    for item in "${kept[@]}"; do
        echo "  - $item"
    done
fi

if [[ $PURGE -eq 0 ]]; then
    echo
    echo "Note: binaries and token preserved. Run with --purge to remove everything."
fi
