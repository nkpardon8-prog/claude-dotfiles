#!/usr/bin/env bash
# 26 - install-transfer.sh installs the address-book LaunchAgent, and only ever replaces its OWN plist.
#
# Runs the REAL installer against a sandbox $HOME. launchctl is a PATH stub that only records its
# argv: the real launchctl and the real ~/Library/LaunchAgents are never touched.
#
#   L1 sandbox HOME, no opt-in: plist written (marker, label, publish every 60s, background
#      priority, valid plist) and launchctl NEVER called - a test HOME must not reach the real
#      login session. The installer also published this Mac's file into the sandbox iCloud folder.
#   L2 opt-in (stubbed launchctl), not loaded yet: bootout + bootstrap gui/<uid> <plist>.
#   L3 re-run, plist unchanged and already loaded: no bootstrap.
#   L4 its own plist with stale content: replaced and reloaded.
#   L5 a FOREIGN plist of the same name (no marker): byte-identical afterwards, warning printed,
#      never bootstrapped, installer still exits 0.
#
# NEGATIVE CONTROL (TX_NEG_CONTROL=true): a copy of the installer with the marker check and the
# real-HOME guard removed. L1 (launchctl called from a sandbox) and L5 (foreign plist replaced) must
# go red.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
command -v plutil >/dev/null 2>&1 || { echo "INFRA: plutil not available" >&2; exit 3; }

HOME_T=$(tx_sandbox 26)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
INSTALL="$TX_REPO/scripts/transfer/install-transfer.sh"
if [ "${TX_NEG_CONTROL:-}" = "true" ]; then
  INSTALL="$HOME_T/regressed-install.sh"
  python3 - "$TX_REPO/scripts/transfer/install-transfer.sh" "$INSTALL" <<'PY'
import sys
s = open(sys.argv[1]).read()
for a, b in [('elif [ -e "$LA_PLIST" ] && ! grep -qF "$LA_MARKER" "$LA_PLIST" 2>/dev/null; then', 'elif false; then'),
             ('if [ "$HOME" = "$REAL_HOME" ]; then', 'if true; then')]:
    assert s.count(a) == 1, a
    s = s.replace(a, b)
open(sys.argv[2], "w").write(s)
PY
fi

LABEL="com.claude-dotfiles.windows-publish"
PLIST="$HOME_T/Library/LaunchAgents/$LABEL.plist"
STUBS="$HOME_T/stubs"; LOG="$HOME_T/launchctl.log"
mkdir -p "$STUBS"
# `launchctl print` answers from a flag file, so a test can say "loaded" or "not loaded".
cat > "$STUBS/launchctl" <<EOF
#!/bin/sh
echo "\$*" >> "$LOG"
if [ "\$1" = print ]; then [ -f "$HOME_T/loaded" ] && exit 0; exit 113; fi
exit 0
EOF
chmod +x "$STUBS/launchctl"

run_install() {  # run_install [extra env assignments...]
  ( env HOME="$HOME_T" CLAUDE_DOTFILES_DIR="$TX_REPO" TRANSFER_BIN_DIR="$HOME_T/bin" PATH="$STUBS:$PATH" \
        LAC_HOST_ID="test-mac" LAC_HOST_LABEL="Test Mac" "$@" bash "$INSTALL" ) >"$HOME_T/.out" 2>"$HOME_T/.err"
}
said() { cat "$HOME_T/.out" "$HOME_T/.err"; }

# --- L1 --------------------------------------------------------------------------------------------
run_install || fail "L1: installer failed: $(said)"
if [ -f "$PLIST" ]; then
  grep -qF "built-by: scripts/transfer/install-transfer.sh" "$PLIST" || fail "L1: plist has no ownership marker"
  plutil -lint "$PLIST" >/dev/null 2>&1 || fail "L1: generated plist does not lint"
  python3 - "$PLIST" "$LABEL" <<'PY' || fail "L1: plist content wrong"
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
assert d["Label"] == sys.argv[2]
assert d["ProgramArguments"][-1] == "publish" and d["ProgramArguments"][-2].endswith("line-agent-communicator.py")
assert d["StartInterval"] == 60 and d["RunAtLoad"] is True and d["ProcessType"] == "Background"
assert d["StandardErrorPath"].endswith("/.claude/logs/windows-publish.launchd.log")
PY
else
  fail "L1: no plist written"
fi
[ -s "$LOG" ] && fail "L1: launchctl was called from a sandbox HOME without opt-in: $(cat "$LOG")"
[ -f "$HOME_T/Library/Mobile Documents/com~apple~CloudDocs/claude-windows/test-mac.json" ] \
  || fail "L1: the installer did not publish this Mac's address-book file"

# --- L2 --------------------------------------------------------------------------------------------
: > "$LOG"
run_install LAC_LAUNCHCTL_ALLOW_SANDBOX=1 || fail "L2: installer failed: $(said)"
grep -q "^bootstrap gui/$(id -u) $PLIST$" "$LOG" || fail "L2: not bootstrapped (launchctl saw: $(tr '\n' ';' < "$LOG"))"
grep -q "^bootout gui/$(id -u)/$LABEL$" "$LOG" || fail "L2: no bootout before bootstrap"

# --- L3 --------------------------------------------------------------------------------------------
: > "$LOG"; touch "$HOME_T/loaded"
run_install LAC_LAUNCHCTL_ALLOW_SANDBOX=1 || fail "L3: installer failed: $(said)"
grep -q "^bootstrap" "$LOG" && fail "L3: an unchanged, loaded agent was bootstrapped again"
grep -q "already loaded" "$HOME_T/.out" || fail "L3: did not report the agent as already loaded"

# --- L4 --------------------------------------------------------------------------------------------
: > "$LOG"
python3 - "$PLIST" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read().replace("<integer>60</integer>", "<integer>999</integer>"); open(p, "w").write(s)
PY
run_install LAC_LAUNCHCTL_ALLOW_SANDBOX=1 || fail "L4: installer failed: $(said)"
grep -q "<integer>999</integer>" "$PLIST" && fail "L4: its own stale plist was not replaced"
grep -q "^bootstrap" "$LOG" || fail "L4: a replaced plist was not reloaded"

# --- L5 --------------------------------------------------------------------------------------------
: > "$LOG"; rm -f "$HOME_T/loaded"
printf '<?xml version="1.0"?>\n<plist version="1.0"><dict><key>Label</key><string>someone-else</string></dict></plist>\n' > "$PLIST"
BEFORE=$(tx_sha "$PLIST")
run_install LAC_LAUNCHCTL_ALLOW_SANDBOX=1 || fail "L5: installer failed with a foreign plist present: $(said)"
[ "$(tx_sha "$PLIST")" = "$BEFORE" ] || fail "L5: the foreign plist was modified"
grep -q "not made by this script" "$HOME_T/.err" || fail "L5: no warning that the foreign plist was left alone"
grep -q "^bootstrap" "$LOG" && fail "L5: a foreign plist was bootstrapped"

if [ "${TX_NEG_CONTROL:-}" = "true" ]; then
  MISSING=""
  for tag in L1 L5; do case "$FAIL_MSGS" in *"${tag}:"*) ;; *) MISSING="${MISSING} ${tag}" ;; esac; done
  if [ -z "$MISSING" ]; then
    echo "NEG-CONTROL OK: with the marker check and the HOME guard removed, L1 and L5 went RED (${FAIL_N} failed)"
    printf '%s' "$FAIL_MSGS"; exit 0
  fi
  echo "NEG-CONTROL BROKEN: did not go red:${MISSING}" >&2; printf '%s' "$FAIL_MSGS" >&2; exit 1
fi
ok_report "26-install-launchagent" "writes a valid marked plist, never drives launchctl from a sandbox HOME, loads/reloads only when needed, never touches a foreign plist"
