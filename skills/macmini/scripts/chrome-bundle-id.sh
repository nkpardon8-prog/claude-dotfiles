#!/bin/bash
# chrome-bundle-id.sh — print the bundle ID of the running Chrome instance.
# Falls back to com.google.Chrome if nothing matches.
#
# macOS BSD pgrep DOES NOT include cmdline like Linux. Use ps -axo command=
# (column "command" with trailing equals to suppress header) to get the
# full path of every running process, then grep for Chrome app paths
# specifically (anchor on /Contents/MacOS/ to avoid matching unrelated
# processes like ChromeRemoteDesktopHost).

set -eu

# Get the path of any running Chrome-flavor binary
BIN=$(ps -axo command= 2>/dev/null \
       | grep -E '/(Google Chrome|Google Chrome Beta|Google Chrome Canary|Google Chrome Dev|Chromium)\.app/Contents/MacOS/' \
       | grep -v ' Helper' \
       | head -n1 || true)

if [ -z "$BIN" ]; then
  echo "com.google.Chrome"
  exit 0
fi

case "$BIN" in
  *"Google Chrome Canary.app"*) echo "com.google.Chrome.canary" ;;
  *"Google Chrome Beta.app"*)   echo "com.google.Chrome.beta" ;;
  *"Google Chrome Dev.app"*)    echo "com.google.Chrome.dev" ;;
  *"Chromium.app"*)             echo "org.chromium.Chromium" ;;
  *"Google Chrome.app"*)        echo "com.google.Chrome" ;;
  *)                            echo "com.google.Chrome" ;;
esac
