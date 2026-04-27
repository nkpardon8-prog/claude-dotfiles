#!/bin/bash
# open-tcc-pane.sh — open the right macOS Privacy & Security pane
# Anchors are macOS-version-aware (Sonoma+ uses Privacy_InputMonitoring,
# pre-Sonoma uses Privacy_ListenEvent).

set -eu

# Detect macOS version (Sonoma is 14, Sequoia 15+; both use Privacy_InputMonitoring)
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
INPUT_ANCHOR="Privacy_InputMonitoring"
[ "$MAJOR" -lt 14 ] && INPUT_ANCHOR="Privacy_ListenEvent"

case "${1:-}" in
  screencapture)
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    echo "Opened: Privacy & Security -> Screen Recording"
    echo "Toggle 'Chrome Remote Desktop' OFF then ON to re-grant."
    ;;
  accessibility)
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    echo "Opened: Privacy & Security -> Accessibility"
    echo "Toggle 'ChromeRemoteDesktopHost' OFF then ON to re-grant."
    ;;
  inputmonitoring|listenevent)
    open "x-apple.systempreferences:com.apple.preference.security?$INPUT_ANCHOR"
    echo "Opened: Privacy & Security -> Input Monitoring (anchor=$INPUT_ANCHOR)"
    echo "Toggle 'ChromeRemoteDesktopHost' OFF then ON to re-grant."
    ;;
  *)
    echo "Usage: $0 <screencapture|accessibility|inputmonitoring>"
    exit 1
    ;;
esac
