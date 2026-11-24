#!/bin/sh
# Turn on dashboard share control on a lent Mac. Runs ON the Mac as its OWNER (the user who owns
# /Users/Shared/rdocker/share), never root, never rd, no sudo. The driver share-control-remote.sh stages
# this file and the new rd-reporter.mjs in $STAGE (default ~/.local/state/rdocker/share-setup: in the
# owner's home, never /tmp) over Pane and runs it; by hand: STAGE=<dir> sh <this>.
#
#   owner                 the owner's own reporter (nickmbp, the Air): new rd-reporter.mjs (old one kept as
#                         .bak), "shareControl": true in ~/.config/rdocker/reporter.json (every other field
#                         and mode 0600 kept), restart its LaunchAgent
#   helper-prepare NAME URL
#                         a control-only helper for a Mac whose stats reporter runs as rd (ethanair): the
#                         reporter in ~/.local/share/rdocker/reporter/, ~/.config/rdocker/reporter-ctl.json
#                         (mode 0600; its key minted here once, kept on re-runs) and the LaunchAgent
#                         com.rdocker.reporter-ctl, NOT started (the dashboard needs the key first)
#   helper-key            print "KEY:<key>" once, for `npx wrangler secret put MACHINE_CTL_KEY_<NAME>`
#   helper-start          (re)start com.rdocker.reporter-ctl
#   status                versions, labels, --share-check, the last log lines (never a key)
set -eu
umask 077
STAGE=${STAGE:-$HOME/.local/state/rdocker/share-setup}
UID_=$(id -u)
[ "$UID_" -ne 0 ] || { echo "refused: run as the Mac's owner, not root" >&2; exit 1; }
[ "$(id -un)" != rd ] || { echo "refused: run as the Mac's owner, not rd" >&2; exit 1; }
SHARE=/Users/Shared/rdocker/share
[ -f "$SHARE" ] && [ "$(stat -f %u "$SHARE")" = "$UID_" ] || { echo "refused: $SHARE is missing or not owned by $(id -un)" >&2; exit 1; }

DIR="$HOME/.local/share/rdocker/reporter"
MJS="$DIR/rd-reporter.mjs"
CFG="$HOME/.config/rdocker/reporter.json"
CTL_CFG="$HOME/.config/rdocker/reporter-ctl.json"
CTL_LABEL=com.rdocker.reporter-ctl
CTL_PLIST="$HOME/Library/LaunchAgents/$CTL_LABEL.plist"

NODE=""
for n in "$(command -v node 2>/dev/null || true)" /opt/homebrew/bin/node /usr/local/bin/node "$HOME"/.local/share/mise/shims/node; do
  [ -n "$n" ] && [ -x "$n" ] && "$n" -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)' 2>/dev/null && { NODE=$n; break; }
done
[ -n "$NODE" ] || { echo "no node 22+ found (PATH, /opt/homebrew/bin, /usr/local/bin)" >&2; exit 1; }

# Would CONFIG's share control accept orders here? Only asks a reporter that knows --share-check (1.6.0+):
# an older one would ignore the flag and start a second reporter.
share_check() {
  grep -q -- "'--share-check'" "$MJS" 2>/dev/null || { echo "unknown (reporter before 1.6.0)"; return 0; }
  "$NODE" "$MJS" --config "$1" --share-check || true
}

install_mjs() {
  [ -f "$STAGE/rd-reporter.mjs" ] || { echo "missing $STAGE/rd-reporter.mjs" >&2; exit 1; }
  "$NODE" "$STAGE/rd-reporter.mjs" --version >/dev/null
  mkdir -p "$DIR"
  [ -f "$MJS" ] && cp -p "$MJS" "$MJS.bak"
  cp "$STAGE/rd-reporter.mjs" "$MJS.new" && chmod 644 "$MJS.new" && mv "$MJS.new" "$MJS"
  echo "reporter $("$NODE" "$MJS" --version) at $MJS$([ -f "$MJS.bak" ] && echo " (previous kept as rd-reporter.mjs.bak)")"
}

# The label of the LaunchAgent that runs $MJS without --config (the owner's stats reporter).
owner_label() {
  for p in "$HOME"/Library/LaunchAgents/*.plist; do
    [ -f "$p" ] || continue
    grep -q 'rd-reporter.mjs' "$p" && ! grep -q -- '--config' "$p" && { /usr/libexec/PlistBuddy -c 'Print :Label' "$p"; return 0; }
  done
  return 1
}

case "${1:-}" in
owner)
  [ -f "$CFG" ] || { echo "no $CFG: this Mac has no owner reporter" >&2; exit 1; }
  install_mjs
  # Set shareControl in place: every other field kept, never printed, mode 0600, atomic rename.
  "$NODE" -e '
    const fs = require("fs"); const f = process.argv[1];
    const c = JSON.parse(fs.readFileSync(f, "utf8")); c.shareControl = true;
    fs.writeFileSync(f + ".tmp", JSON.stringify(c, null, 2) + "\n", { mode: 0o600 }); fs.renameSync(f + ".tmp", f);
    console.log("reporter.json: shareControl true (name " + c.name + ")");' "$CFG"
  chmod 600 "$CFG"
  echo "share-check: $(share_check "$CFG")"
  L=$(owner_label) || { echo "no LaunchAgent runs $MJS; load units/com.rdocker.reporter.plist" >&2; exit 1; }
  launchctl kickstart -k "gui/$UID_/$L" && echo "restarted gui/$UID_/$L"
  ;;
helper-prepare)
  NAME=${2:?name}; URL=${3:?wss url}
  case $URL in wss://*/ingest) ;; *) echo "url must be wss://<host>/ingest" >&2; exit 1 ;; esac
  install_mjs
  mkdir -p "$HOME/.config/rdocker" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  # The key is minted here once and never leaves this Mac except through helper-key.
  "$NODE" -e '
    const fs = require("fs"); const crypto = require("crypto"); const [f, name, url] = process.argv.slice(1);
    let key = null; try { const o = JSON.parse(fs.readFileSync(f, "utf8")); if (o.name === name) key = o.key; } catch {}
    if (typeof key !== "string" || key.length < 32) key = crypto.randomBytes(32).toString("base64url");
    const c = { name, url, key, shareControl: true, controlOnly: true };
    fs.writeFileSync(f + ".tmp", JSON.stringify(c, null, 2) + "\n", { mode: 0o600 }); fs.renameSync(f + ".tmp", f);
    console.log("reporter-ctl.json: " + name + " control-only, " + url);' "$CTL_CFG" "$NAME" "$URL"
  chmod 600 "$CTL_CFG"
  cat > "$CTL_PLIST.tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$CTL_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>$MJS</string>
    <string>--config</string>
    <string>$CTL_CFG</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/rd-reporter-ctl.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/rd-reporter-ctl.log</string>
</dict>
</plist>
PLIST
  chmod 644 "$CTL_PLIST.tmp" && mv "$CTL_PLIST.tmp" "$CTL_PLIST"
  echo "share-check: $(share_check "$CTL_CFG")"
  echo "prepared $CTL_PLIST (not started)"
  ;;
helper-key)
  "$NODE" -e 'const c = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write("KEY:" + c.key + "\n");' "$CTL_CFG"
  ;;
helper-start)
  [ -f "$CTL_PLIST" ] || { echo "run helper-prepare first" >&2; exit 1; }
  launchctl bootout "gui/$UID_/$CTL_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_" "$CTL_PLIST" && echo "started gui/$UID_/$CTL_LABEL"
  ;;
status)
  [ ! -f "$MJS" ] || echo "reporter $("$NODE" "$MJS" --version) at $MJS"
  for f in "$CFG" "$CTL_CFG"; do
    if [ -f "$f" ]; then echo "$(basename "$f"): mode $(stat -f %Lp "$f"), share-check $(share_check "$f")"; fi
  done
  launchctl print "gui/$UID_" 2>/dev/null | grep -E 'com\.rdocker\.reporter' || echo "no com.rdocker.reporter* in gui/$UID_"
  for l in rd-reporter rd-reporter-ctl; do
    if [ -f "$HOME/Library/Logs/$l.log" ]; then echo "--- $l.log"; tail -n 6 "$HOME/Library/Logs/$l.log"; fi
  done
  ;;
*)
  sed -n '2,20p' "$0" >&2; exit 64 ;;
esac
