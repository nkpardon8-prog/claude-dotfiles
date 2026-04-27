#!/bin/bash
# NO `set -e` — idempotent cleanup must continue on partial state.
set -u

REMOVE_TAILSCALE=0
INTERACTIVE=0
for arg in "$@"; do
  case "$arg" in
    --remove-tailscale) REMOVE_TAILSCALE=1 ;;
    --interactive) INTERACTIVE=1 ;;
    --help|-h)
      echo "Usage: $0 [--remove-tailscale] [--interactive]"
      echo "  Default: do NOT remove tailscale, do NOT prompt."
      echo "  --remove-tailscale: also uninstall tailscaled."
      echo "  --interactive: prompt for tailscale removal if not specified via flag."
      exit 0 ;;
  esac
done

echo "Removing macmini server LaunchAgent (if present)..."
launchctl bootout "gui/$(id -u)/com.macmini-skill.server" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.macmini-skill.server.plist"

echo "Removing binaries and config (both userspace and cask install paths)..."
# userspace install path (no sudo needed)
rm -f "$HOME/.local/bin/macmini-server"
rm -f "$HOME/.local/bin/macmini-client"
# legacy cask install path — needs sudo. Best-effort; print hint if not available.
if [ -e "/usr/local/bin/macmini-server" ] || [ -e "/usr/local/bin/macmini-client" ]; then
  if sudo -n true 2>/dev/null; then
    sudo rm -f "/usr/local/bin/macmini-server" "/usr/local/bin/macmini-client"
    echo "  ✓ Removed cask-mode binaries from /usr/local/bin/"
  else
    echo "  ⚠ Cask-mode binaries in /usr/local/bin/ — needs sudo. Run:"
    echo "      sudo rm -f /usr/local/bin/macmini-server /usr/local/bin/macmini-client"
  fi
fi
# config + log (userspace, no sudo)
rm -rf "$HOME/.config/macmini-server/"
rm -f "$HOME/Library/Logs/macmini-server.log"

# Tailscale removal — DEFAULT IS NO. Only remove if --remove-tailscale OR
# --interactive AND user confirms. Never prompt by default.
#
# IMPORTANT: the userspace tailscaled is started by `nohup` (not as a
# LaunchAgent) per install.sh. So `launchctl bootout` is a no-op for
# userspace mode — we need pkill instead. The cask install DOES use a
# LaunchAgent at com.tailscale.tailscaled, so launchctl bootout is also
# tried (harmless if the label isn't loaded).
should_remove_ts=0
if [ "$REMOVE_TAILSCALE" = "1" ]; then
  should_remove_ts=1
elif [ "$INTERACTIVE" = "1" ] && [ -t 0 ]; then
  read -r -p "Also remove userspace tailscaled? [y/N] " yn
  [[ "$yn" =~ ^[Yy]$ ]] && should_remove_ts=1
fi

if [ "$should_remove_ts" = "1" ]; then
  # Stop userspace tailscaled (nohup-started)
  pkill -u "$(id -u)" -f "tailscaled.*--tun=userspace-networking" 2>/dev/null || true
  # Stop cask-installed LaunchAgent (no-op if not present)
  launchctl bootout "gui/$(id -u)/com.tailscale.tailscaled" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.tailscale.tailscaled.plist"
  # Remove userspace state + logs
  rm -rf "$HOME/.config/tailscaled/"
  rm -f "$HOME/Library/Logs/tailscaled.log"
  # Uninstall the formula or cask
  brew uninstall tailscale 2>/dev/null || true
  echo "  ✓ Tailscale removed (userspace process killed, state cleared)."
else
  echo "  ⓘ Leaving Tailscale installed. Pass --remove-tailscale to remove."
fi

echo "✓ Mac mini cleaned. CRD itself untouched — keep it enabled for the new skill."
echo "Verify: ps aux | grep -v grep | grep macmini-server  (should be empty)"
