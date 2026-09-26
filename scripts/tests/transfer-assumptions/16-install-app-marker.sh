#!/usr/bin/env bash
# 16 - install-transfer.sh only ever (re)builds ~/Desktop/Resume Chat.app when it made it.
#
#   C1 no app yet: built, with the ownership marker Contents/Resources/.built-by-install-transfer.
#   C2 re-run over its OWN app: rebuilt (a sentinel dropped inside the old bundle is gone).
#   C3 a FOREIGN app of the same name (no marker): left byte-for-byte untouched, with a warning, and
#      the installer still succeeds (the terminal commands are what matter).
#
# Runs the REAL installer against a sandbox $HOME (Desktop, ~/.local/bin, iCloud drop folder all
# land in the sandbox); the source checkout is the real one via CLAUDE_DOTFILES_DIR.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
command -v osacompile >/dev/null 2>&1 || { echo "INFRA: osacompile not available" >&2; exit 3; }

HOME_T=$(tx_sandbox 16)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
INSTALL="$TX_REPO/scripts/transfer/install-transfer.sh"
APP="$HOME_T/Desktop/Resume Chat.app"
MARK="$APP/Contents/Resources/.built-by-install-transfer"

run_install() {
  ( HOME="$HOME_T" CLAUDE_DOTFILES_DIR="$TX_REPO" TRANSFER_BIN_DIR="$HOME_T/bin" bash "$INSTALL" ) \
    >"$HOME_T/.out" 2>"$HOME_T/.err"
}

# --- C1 --------------------------------------------------------------------------------------------
run_install || fail "C1: installer failed: $(cat "$HOME_T/.out" "$HOME_T/.err")"
[ -f "$MARK" ] || fail "C1: the app was not built with its ownership marker"
[ -L "$HOME_T/bin/resumework" ] || fail "C1: resumework was not linked (the rest of the installer broke)"

# --- C2 --------------------------------------------------------------------------------------------
if [ -d "$APP" ]; then
  printf 'old build\n' > "$APP/Contents/old-build-sentinel"
  run_install || fail "C2: re-run failed: $(cat "$HOME_T/.out" "$HOME_T/.err")"
  [ -e "$APP/Contents/old-build-sentinel" ] && fail "C2: its own app was not rebuilt on re-run"
  [ -f "$MARK" ] || fail "C2: the rebuilt app lost its ownership marker"
fi

# --- C3 --------------------------------------------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents"
printf 'someone else'"'"'s app\n' > "$APP/Contents/Info.plist"
BEFORE=$(find "$APP" -type f -exec shasum -a 256 {} + | sort)
run_install || fail "C3: installer failed when a foreign app was present: $(cat "$HOME_T/.out" "$HOME_T/.err")"
[ "$(find "$APP" -type f -exec shasum -a 256 {} + | sort)" = "$BEFORE" ] || fail "C3: the foreign app was modified"
[ -e "$MARK" ] && fail "C3: the installer wrote its marker into a foreign app"
grep -q "not built by this script" "$HOME_T/.err" || fail "C3: no warning that the existing app was left alone: $(cat "$HOME_T/.err")"

ok_report "16-install-app-marker" "builds the app with its marker, rebuilds only its own app, never touches a foreign app of the same name"
