---
description: Install WisprAlt on this Mac via the latest GitHub Release. Walks the employee through 4 macOS permissions and the API-key paste.
---

# WisprAlt Setup (first-time install)

Installs WisprAlt from the latest GitHub Release at `omdiidi/miniWhisper`.
Verifies SHA256, copies the app to `/Applications`, strips the quarantine
attribute, then opens the app so its built-in `PermissionGate.swift` can
walk the user through the four macOS permissions.

Run this command verbatim from a Claude Code session. Claude executes the
bash block; the user just answers macOS prompts.

## Steps

Run this single bash block. It is idempotent (re-runs are safe).

```bash
set -euo pipefail

# Make brew/gh discoverable even if the employee's $PATH is bare.
# Apple Silicon brew lives at /opt/homebrew, Intel at /usr/local.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_SLUG="omdiidi/miniWhisper"
DMG_DIR="/tmp/wispralt-dmg"
MOUNT_POINT="/tmp/wispralt-mount"

# 1. macOS >= 14 check.
OS_VER="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VER%%.*}"
if (( OS_MAJOR < 14 )); then
    echo "WisprAlt requires macOS 14 (Sonoma) or newer. You have ${OS_VER}." >&2
    exit 1
fi
echo "macOS ${OS_VER}: OK"

# 2. Install Homebrew if missing.
if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew not found — installing (you may be prompted for sudo)..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Re-export PATH after install in case shellenv hasn't been run yet.
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

# 3. Install gh if missing.
if ! command -v gh >/dev/null 2>&1; then
    echo "Installing GitHub CLI..."
    brew install gh
fi

# 4. gh auth check.
if ! gh auth status >/dev/null 2>&1; then
    echo "" >&2
    echo "GitHub CLI is not authenticated." >&2
    echo "Run this in a terminal first, then re-run /wispralt-setup:" >&2
    echo "" >&2
    echo "    gh auth login" >&2
    echo "" >&2
    exit 1
fi

# 5. Pick latest tag.
TAG="$(gh release list --repo "${REPO_SLUG}" --limit 1 \
        --json tagName --jq '.[0].tagName')"
if [[ -z "${TAG}" ]]; then
    echo "Could not find any release on ${REPO_SLUG}." >&2
    exit 1
fi
echo "Latest release: ${TAG}"

# 6. Download DMG + sidecar to a clean dir.
rm -rf "${DMG_DIR}" && mkdir -p "${DMG_DIR}"
cd "${DMG_DIR}"
gh release download "${TAG}" --repo "${REPO_SLUG}" \
    --pattern '*.dmg' --pattern '*.dmg.sha256' --clobber

# 7. Verify SHA256 — fail loud if mismatch.
echo "Verifying SHA256..."
if ! shasum -a 256 -c WisprAlt-*.dmg.sha256; then
    echo "SHA256 verification failed — refusing to install." >&2
    exit 1
fi

# 8. Mount, copy to /Applications, unmount.
# Detach any prior mount left behind by a previous failed run.
hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || true
DMG_FILE="$(ls -1 "${DMG_DIR}"/WisprAlt-*.dmg | head -n1)"
hdiutil attach "${DMG_FILE}" -nobrowse -mountpoint "${MOUNT_POINT}"

# Replace any existing app cleanly.
if [[ -d /Applications/WisprAlt.app ]]; then
    rm -rf /Applications/WisprAlt.app
fi
cp -R "${MOUNT_POINT}/WisprAlt.app" /Applications/
hdiutil detach "${MOUNT_POINT}"

# 9. Strip quarantine so Gatekeeper doesn't block first-launch.
xattr -dr com.apple.quarantine /Applications/WisprAlt.app || true

# 10. Open the app — its PermissionGate.swift walks the 4 permissions.
open /Applications/WisprAlt.app

echo ""
echo "WisprAlt ${TAG} installed."
echo "The app is now opening — follow the on-screen prompts to grant:"
echo "  1. Accessibility"
echo "  2. Input Monitoring (Listen to keyboard events)"
echo "  3. Screen Recording (for meeting capture)"
echo "  4. Microphone"
echo ""
echo "Now paste the API key Omid texted you in Settings → API Key."
```
