---
description: Pull the latest WisprAlt release and update the installed app. Handles TCC reset if cdhash changed.
---

# WisprAlt Update (pull latest release)

Compares the installed `/Applications/WisprAlt.app` version against the
latest GitHub Release tag, downloads + verifies + replaces if outdated, and
runs the TCC reset cycle if the code-signing cdhash changed (which happens
on annual cert renewal or any new signing identity).

If WisprAlt isn't installed yet, this command bails out and points the
user at `/wispralt-setup`.

## Steps

Run this single bash block. It is idempotent and safe to re-run.

```bash
set -euo pipefail

# Make brew/gh discoverable even if the employee's $PATH is bare.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_SLUG="omdiidi/miniWhisper"
APP_PATH="/Applications/WisprAlt.app"
DMG_DIR="/tmp/wispralt-dmg"
MOUNT_POINT="/tmp/wispralt-mount"

# 0. First-install fallback.
if [[ ! -d "${APP_PATH}" ]]; then
    echo "WisprAlt isn't installed yet. Run /wispralt-setup instead."
    exit 0
fi

# Sanity: gh must be installed + authed (setup did this; update assumes it).
if ! command -v gh >/dev/null 2>&1; then
    echo "GitHub CLI (gh) is not installed. Run /wispralt-setup first." >&2
    exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
    echo "" >&2
    echo "GitHub CLI is not authenticated." >&2
    echo "Run: gh auth login" >&2
    exit 1
fi

# 1. Read installed version.
INSTALLED_VER="$(plutil -extract CFBundleShortVersionString xml1 -o - \
    "${APP_PATH}/Contents/Info.plist" \
    | sed -n 's:.*<string>\(.*\)</string>.*:\1:p')"
if [[ -z "${INSTALLED_VER}" ]]; then
    echo "Could not read installed CFBundleShortVersionString." >&2
    exit 1
fi
echo "Installed: ${INSTALLED_VER}"

# 2. Read latest release tag.
TAG="$(gh release list --repo "${REPO_SLUG}" --limit 1 \
        --json tagName --jq '.[0].tagName')"
if [[ -z "${TAG}" ]]; then
    echo "Could not find any release on ${REPO_SLUG}." >&2
    exit 1
fi
LATEST_VER="${TAG#v}"
echo "Latest:    ${LATEST_VER} (${TAG})"

# 3. If installed >= latest, exit cleanly.
# `sort -V` gives us a version-aware compare; the highest line wins.
HIGHEST="$(printf '%s\n%s\n' "${INSTALLED_VER}" "${LATEST_VER}" | sort -V | tail -n1)"
if [[ "${INSTALLED_VER}" == "${LATEST_VER}" ]] || [[ "${HIGHEST}" == "${INSTALLED_VER}" ]]; then
    echo "Already up to date."
    exit 0
fi

# 4. Capture pre-update cdhash.
PRE_HASH="$(codesign -dvvv "${APP_PATH}" 2>&1 | awk '/CDHash=/ {print $2}' | head -n1)"
echo "Pre-update cdhash: ${PRE_HASH:-<none>}"

# 5. Download + verify + replace (same pattern as setup).
rm -rf "${DMG_DIR}" && mkdir -p "${DMG_DIR}"
cd "${DMG_DIR}"
gh release download "${TAG}" --repo "${REPO_SLUG}" \
    --pattern '*.dmg' --pattern '*.dmg.sha256' --clobber

echo "Verifying SHA256..."
if ! shasum -a 256 -c WisprAlt-*.dmg.sha256; then
    echo "SHA256 verification failed — refusing to install." >&2
    exit 1
fi

# Quit the running app so we can replace its bundle.
osascript -e 'tell application "WisprAlt" to quit' >/dev/null 2>&1 || true
pkill -f "${APP_PATH}/Contents/MacOS/WisprAlt" >/dev/null 2>&1 || true
sleep 1

hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || true
DMG_FILE="$(ls -1 "${DMG_DIR}"/WisprAlt-*.dmg | head -n1)"
hdiutil attach "${DMG_FILE}" -nobrowse -mountpoint "${MOUNT_POINT}"

rm -rf "${APP_PATH}"
cp -R "${MOUNT_POINT}/WisprAlt.app" /Applications/
hdiutil detach "${MOUNT_POINT}"

xattr -dr com.apple.quarantine "${APP_PATH}" || true

# 6. Capture post-update cdhash; if changed, reset TCC for all 4 perms.
POST_HASH="$(codesign -dvvv "${APP_PATH}" 2>&1 | awk '/CDHash=/ {print $2}' | head -n1)"
echo "Post-update cdhash: ${POST_HASH:-<none>}"

if [[ -n "${PRE_HASH}" && -n "${POST_HASH}" && "${PRE_HASH}" != "${POST_HASH}" ]]; then
    echo ""
    echo "Code signature cdhash changed — resetting TCC permissions."
    for tcc in Accessibility ListenEvent ScreenCapture Microphone; do
        tccutil reset "${tcc}" co.wispralt.WisprAlt || true
    done
    open "x-apple.systempreferences:com.apple.preference.security?Privacy" || true
    echo ""
    echo "Permissions were reset because the app's signature changed."
    echo "Please re-grant all four in System Settings → Privacy & Security:"
    echo "  - Accessibility"
    echo "  - Input Monitoring"
    echo "  - Screen Recording"
    echo "  - Microphone"
fi

# 7. Open the updated app.
open "${APP_PATH}"

echo ""
echo "WisprAlt updated: ${INSTALLED_VER} → ${LATEST_VER}."
```
