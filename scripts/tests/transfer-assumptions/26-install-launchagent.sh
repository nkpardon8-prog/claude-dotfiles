#!/usr/bin/env bash
# 26 - install-transfer.sh retires the address-book LaunchAgent safely and wires the SessionEnd publish.
#
# The LaunchAgent publisher (com.claude-dotfiles.windows-publish) was retired on 2026-10-15: a
# background launchd job could not keep this Mac's iCloud file current, so publishing now runs from
# Claude Code (statusline trigger, SessionStart, /line, SessionEnd). Runs the REAL installer against a
# sandbox $HOME; launchctl is a PATH stub that only records its argv.
#
#   L1 no plist: none is created, launchctl is never called, and the installer publishes this Mac's
#      address-book file into the sandbox iCloud folder.
#   L2 our marked plist, sandbox HOME without opt-in: the plist is removed, launchctl NOT called.
#   L3 our marked plist with the dev opt-in (stubbed launchctl): bootout, then removed.
#   L4 a FOREIGN plist of the same name (no marker): byte-identical afterwards, warning printed,
#      installer still exits 0.
#   L5 settings.json gains the SessionEnd publish hook exactly once (re-run adds no duplicate).
#
# NEGATIVE CONTROL (TX_NEG_CONTROL=true): a copy of the installer with the marker check and the
# real-HOME guard removed. L2 (launchctl called from a sandbox) and L4 (foreign plist deleted) go red.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 26)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
INSTALL="$TX_REPO/scripts/transfer/install-transfer.sh"
if [ "${TX_NEG_CONTROL:-}" = "true" ]; then
  INSTALL="$HOME_T/regressed-install.sh"
  python3 - "$TX_REPO/scripts/transfer/install-transfer.sh" "$INSTALL" <<'PY'
import sys
s = open(sys.argv[1]).read()
for a, b in [('    if grep -qF "$LA_MARKER" "$LA_PLIST" 2>/dev/null; then', '    if true; then'),
             ('if [ "$HOME" = "$REAL_HOME" ]; then', 'if true; then')]:
    assert s.count(a) == 1, a
    s = s.replace(a, b)
open(sys.argv[2], "w").write(s)
PY
fi

LABEL="com.claude-dotfiles.windows-publish"
PLIST="$HOME_T/Library/LaunchAgents/$LABEL.plist"
STUBS="$HOME_T/stubs"; LOG="$HOME_T/launchctl.log"
mkdir -p "$STUBS" "$HOME_T/Library/LaunchAgents" "$HOME_T/.claude"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$LOG" > "$STUBS/launchctl"
chmod +x "$STUBS/launchctl"
printf '{"hooks": {}}\n' > "$HOME_T/.claude/settings.json"
our_plist() { printf '<?xml version="1.0"?>\n<!-- built-by: scripts/transfer/install-transfer.sh -->\n<plist version="1.0"><dict><key>Label</key><string>%s</string></dict></plist>\n' "$LABEL" > "$PLIST"; }

run_install() {  # run_install [extra env assignments...]
  ( env HOME="$HOME_T" CLAUDE_DOTFILES_DIR="$TX_REPO" TRANSFER_BIN_DIR="$HOME_T/bin" PATH="$STUBS:$PATH" \
        LAC_HOST_ID="test-mac" LAC_HOST_LABEL="Test Mac" LAC_NO_AUTOPUBLISH=1 "$@" bash "$INSTALL" ) \
        >"$HOME_T/.out" 2>"$HOME_T/.err"
}
said() { cat "$HOME_T/.out" "$HOME_T/.err"; }

# --- L1 --------------------------------------------------------------------------------------------
: > "$LOG"
run_install || fail "L1: installer failed: $(said)"
[ -e "$PLIST" ] && fail "L1: the installer created a LaunchAgent plist"
[ -s "$LOG" ] && fail "L1: launchctl was called with nothing to remove: $(cat "$LOG")"
[ -f "$HOME_T/Library/Mobile Documents/com~apple~CloudDocs/claude-windows/test-mac.json" ] \
  || fail "L1: the installer did not publish this Mac's address-book file"

# --- L2 --------------------------------------------------------------------------------------------
: > "$LOG"; our_plist
run_install || fail "L2: installer failed: $(said)"
[ -e "$PLIST" ] && fail "L2: our retired plist was not removed"
[ -s "$LOG" ] && fail "L2: launchctl was called from a sandbox HOME without opt-in: $(tr '\n' ';' < "$LOG")"

# --- L3 --------------------------------------------------------------------------------------------
: > "$LOG"; our_plist
run_install LAC_LAUNCHCTL_ALLOW_SANDBOX=1 || fail "L3: installer failed: $(said)"
grep -q "^bootout gui/$(id -u)/$LABEL$" "$LOG" || fail "L3: the retired agent was not booted out (launchctl saw: $(tr '\n' ';' < "$LOG"))"
[ -e "$PLIST" ] && fail "L3: our retired plist was not removed"

# --- L4 --------------------------------------------------------------------------------------------
: > "$LOG"
printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>Label</key><string>someone-else</string></dict></plist>\n' > "$PLIST"
BEFORE=$(tx_sha "$PLIST")
run_install LAC_LAUNCHCTL_ALLOW_SANDBOX=1 || fail "L4: installer failed with a foreign plist present: $(said)"
[ -f "$PLIST" ] && [ "$(tx_sha "$PLIST")" = "$BEFORE" ] || fail "L4: the foreign plist was modified or deleted"
grep -q "not made by this script" "$HOME_T/.err" || fail "L4: no warning that the foreign plist was left alone"
rm -f "$PLIST"

# --- L5 --------------------------------------------------------------------------------------------
run_install || fail "L5: installer failed: $(said)"
python3 - "$HOME_T/.claude/settings.json" <<'PY' || fail "L5: SessionEnd publish hook missing or duplicated"
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [h.get("command", "") for blk in d.get("hooks", {}).get("SessionEnd", []) for h in blk.get("hooks", [])]
n = sum(1 for c in cmds if "line-agent-communicator.py publish --background" in c)
sys.exit(0 if n == 1 else 1)
PY

if [ "${TX_NEG_CONTROL:-}" = "true" ]; then
  MISSING=""
  for tag in L2 L4; do case "$FAIL_MSGS" in *"${tag}:"*) ;; *) MISSING="${MISSING} ${tag}" ;; esac; done
  if [ -z "$MISSING" ]; then
    echo "NEG-CONTROL OK: with the marker check and the HOME guard removed, L2 and L4 went RED (${FAIL_N} failed)"
    printf '%s' "$FAIL_MSGS"; exit 0
  fi
  echo "NEG-CONTROL BROKEN: did not go red:${MISSING}" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
ok_report "26-install-launchagent" "creates no LaunchAgent, removes only its own retired plist (launchctl only with a real HOME or the dev opt-in), never touches a foreign plist, adds the SessionEnd publish once, publishes this Mac"
