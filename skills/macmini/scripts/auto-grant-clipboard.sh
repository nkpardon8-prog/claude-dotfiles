#!/bin/bash
# auto-grant-clipboard.sh — pre-grant clipboard-read on remotedesktop.google.com
#
# Modes:
#   grant            — append origin to user-recommended policy (idempotent, anchored grep)
#   --mandatory      — write mandatory policy (requires sudo)
#   --revert         — surgical removal of OUR origin only (via plistlib)
#   --revert-mandatory — remove mandatory policy file (requires sudo)
#   --status         — print whether policies are in place
#
# Args:
#   --bundle-id <id>  — defaults to com.google.Chrome; pass for Beta/Canary/Chromium

set -eu

ORIGIN="https://remotedesktop.google.com"
USER_DOMAIN="com.google.Chrome"
MANDATORY_PLIST="/Library/Managed Preferences/com.google.Chrome.plist"
KEY="ClipboardAllowedForUrls"

# Parse args
MODE="${1:-grant}"; shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle-id)
      USER_DOMAIN="$2"
      if ! [[ "$USER_DOMAIN" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "ERROR: invalid bundle-id: $USER_DOMAIN (expected ^[A-Za-z0-9._-]+$)"
        exit 2
      fi
      MANDATORY_PLIST="/Library/Managed Preferences/${USER_DOMAIN}.plist"
      shift 2
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

case "$MODE" in
  grant)
    # Idempotency: anchored exact-line check (pass-2 rec #5)
    existing=$(defaults read "$USER_DOMAIN" "$KEY" 2>/dev/null || echo "")
    # Match the entry as a quoted standalone line (defaults output format)
    if echo "$existing" | grep -qFx "    \"$ORIGIN\"," || echo "$existing" | grep -qFx "    \"$ORIGIN\""; then
      echo "SKIP: $ORIGIN already in $KEY"
      exit 0
    fi
    defaults write "$USER_DOMAIN" "$KEY" -array-add "$ORIGIN"
    echo "OK: appended $ORIGIN to $KEY (domain=$USER_DOMAIN)"
    echo "Restart Chrome for the policy to take effect."
    ;;
  --mandatory)
    [ "$EUID" -ne 0 ] && { echo "ERROR: --mandatory needs sudo"; exit 2; }
    if [ ! -f "$MANDATORY_PLIST" ]; then
      plutil -create xml1 "$MANDATORY_PLIST" || { echo "ERROR: cannot create $MANDATORY_PLIST"; exit 3; }
    fi
    /usr/libexec/PlistBuddy -c "Add :$KEY array" "$MANDATORY_PLIST" 2>/dev/null || true
    if /usr/libexec/PlistBuddy -c "Print :$KEY" "$MANDATORY_PLIST" 2>/dev/null | grep -qFx "    $ORIGIN"; then
      echo "SKIP: $ORIGIN already in mandatory $KEY"
      exit 0
    fi
    /usr/libexec/PlistBuddy -c "Add :$KEY: string $ORIGIN" "$MANDATORY_PLIST"
    plutil -lint "$MANDATORY_PLIST"
    echo "OK: appended $ORIGIN to mandatory $KEY at $MANDATORY_PLIST"
    echo "Restart Chrome."
    ;;
  --revert)
    # Surgical removal via plistlib (pass-2 rec #6)
    PLIST="$HOME/Library/Preferences/${USER_DOMAIN}.plist"
    if [ ! -f "$PLIST" ]; then
      echo "SKIP: no plist at $PLIST"
      exit 0
    fi
    python3 - "$PLIST" "$KEY" "$ORIGIN" <<'PY'
import plistlib, sys
plist_path, key, origin = sys.argv[1:]
try:
    with open(plist_path, 'rb') as f:
        data = plistlib.load(f)
except Exception as e:
    print(f"ERROR: cannot read {plist_path}: {e}")
    sys.exit(1)
arr = data.get(key, [])
if origin not in arr:
    print(f"SKIP: {origin} not in {key}")
    sys.exit(0)
arr.remove(origin)
if arr:
    data[key] = arr
else:
    del data[key]
with open(plist_path, 'wb') as f:
    plistlib.dump(data, f)
print(f"OK: surgically removed {origin} from {key}")
print(f"  Remaining entries in {key}: {len(arr)}")
PY
    # cfprefsd cache invalidation. Note: Chrome itself caches policies in
    # process memory; a Chrome restart is required for the revert to take
    # full effect. We document this in the slash command's revert mode.
    killall cfprefsd 2>/dev/null || true
    echo "OK: revert written. Restart Chrome for the change to take effect."
    ;;
  --revert-mandatory)
    [ "$EUID" -ne 0 ] && { echo "ERROR: --revert-mandatory needs sudo"; exit 2; }
    rm -f "$MANDATORY_PLIST"
    echo "OK: removed mandatory policy file"
    ;;
  --status)
    if defaults read "$USER_DOMAIN" "$KEY" 2>/dev/null | grep -qFx "    \"$ORIGIN\"," || \
       defaults read "$USER_DOMAIN" "$KEY" 2>/dev/null | grep -qFx "    \"$ORIGIN\""; then
      echo "user-policy: ALLOWED (bundle=$USER_DOMAIN)"
    else
      echo "user-policy: NOT SET (bundle=$USER_DOMAIN)"
    fi
    if [ -f "$MANDATORY_PLIST" ] && /usr/libexec/PlistBuddy -c "Print :$KEY" "$MANDATORY_PLIST" 2>/dev/null | grep -qFx "    $ORIGIN"; then
      echo "mandatory-policy: PRESENT"
    elif [ -f "$MANDATORY_PLIST" ]; then
      echo "mandatory-policy: PRESENT (different origins)"
    else
      echo "mandatory-policy: NOT PRESENT"
    fi
    ;;
  *)
    echo "Usage: $0 {grant|--mandatory|--revert|--revert-mandatory|--status} [--bundle-id <id>]"
    exit 1
    ;;
esac
