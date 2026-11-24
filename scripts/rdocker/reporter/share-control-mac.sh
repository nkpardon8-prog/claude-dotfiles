#!/bin/sh
# Turn on dashboard share control on a lent Mac. Runs ON the Mac as its OWNER (the user who owns
# /Users/Shared/rdocker/share), never root, never rd, no sudo. The driver share-control-remote.sh stages
# this file and the new rd-reporter.mjs in $STAGE (default ~/.local/state/rdocker/share-setup: in the
# owner's home, never /tmp) over Pane and runs it; by hand: STAGE=<dir> sh <this>.
#
#   owner NAME            the owner's own reporter (nickmbp, the Air; its reporter.json must say NAME): new
#                         rd-reporter.mjs (old one kept as .bak), "shareControl": true in
#                         ~/.config/rdocker/reporter.json (every other field and mode 0600 kept), restart
#                         its LaunchAgent
#   helper-prepare NAME URL
#                         a control-only helper for a Mac whose stats reporter runs as rd (ethanair): the
#                         reporter in ~/.local/share/rdocker/reporter/, ~/.config/rdocker/reporter-ctl.json
#                         (mode 0600; its key minted here once, kept on re-runs) and the LaunchAgent
#                         com.rdocker.reporter-ctl, NOT started (the dashboard needs the key first)
#   helper-key            print "KEY:<key>" once, for `npx wrangler secret put MACHINE_CTL_KEY_<NAME>`
#   helper-start          (re)start com.rdocker.reporter-ctl, after checking the reporter, config and plist
#   status                versions, labels, --share-check, the last log lines (never a key)
# Never changes a share level.
set -eu
umask 077
STAGE=${STAGE:-$HOME/.local/state/rdocker/share-setup}
die() { echo "$*" >&2; exit 1; }
UID_=$(id -u)
[ "$UID_" -ne 0 ] || die "refused: run as the Mac's owner, not root"
[ "$(id -un)" != rd ] || die "refused: run as the Mac's owner, not rd"
SHARE=/Users/Shared/rdocker/share
[ -f "$SHARE" ] && [ ! -L "$SHARE" ] && [ "$(stat -f %u "$SHARE")" = "$UID_" ] || die "refused: $SHARE is missing or not owned by $(id -un)"

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
[ -n "$NODE" ] || die "no node 22+ found (PATH, /opt/homebrew/bin, /usr/local/bin)"

# A reporter file that has controlOnly and --share-check (1.6.0+). An older one ignores both: it would
# start a full reporter (collector included) where only a helper or a check was meant.
supports() { [ -f "$1" ] && grep -q -- "'--share-check'" "$1" && grep -q 'c.controlOnly === true' "$1"; }

# Would CONFIG's share control accept orders here? (ok or why)
share_check() {
  supports "$MJS" || { echo "unknown (reporter before 1.6.0)"; return 0; }
  "$NODE" "$MJS" --config "$1" --share-check 2>&1 || true
}

# The staged files must sit in a private folder of ours (no link, nobody else can write it).
check_stage() {
  [ -d "$STAGE" ] && [ ! -L "$STAGE" ] || die "refused: $STAGE is not a folder"
  [ "$(stat -f %u "$STAGE")" = "$UID_" ] || die "refused: $STAGE is not owned by $(id -un)"
  case $(stat -f %Lp "$STAGE") in 700 | 500) ;; *) die "refused: $STAGE is open to others (mode $(stat -f %Lp "$STAGE"))" ;; esac
  [ -f "$STAGE/rd-reporter.mjs" ] && [ ! -L "$STAGE/rd-reporter.mjs" ] || die "missing $STAGE/rd-reporter.mjs"
  supports "$STAGE/rd-reporter.mjs" || die "refused: $STAGE/rd-reporter.mjs is older than 1.6.0"
}

install_mjs() {
  check_stage
  want=$("$NODE" "$STAGE/rd-reporter.mjs" --version)
  mkdir -p "$DIR"
  if [ -f "$MJS" ]; then cp -p "$MJS" "$MJS.bak"; fi
  rm -f "$MJS.new"
  cp "$STAGE/rd-reporter.mjs" "$MJS.new"
  chmod 644 "$MJS.new"
  mv -f "$MJS.new" "$MJS"
  got=$("$NODE" "$MJS" --version)
  [ "$got" = "$want" ] || die "install failed: $MJS is $got, wanted $want"
  echo "reporter $got at $MJS$([ -f "$MJS.bak" ] && echo " (previous kept as rd-reporter.mjs.bak)")"
}

# node: write JSON to FILE through an exclusive 0600 temp file, then rename (no links followed, no
# stale temp reused). Errors name the file only: a config's text (its key) is never printed.
JSON_WRITE='
  const fs = require("fs");
  const writeJson = (f, c) => {
    const tmp = f + ".tmp";
    fs.rmSync(tmp, { force: true });
    const fd = fs.openSync(tmp, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try { fs.writeSync(fd, JSON.stringify(c, null, 2) + "\n"); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    fs.renameSync(tmp, f);
  };
  const readJson = (f) => {
    try { return JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { throw new Error(f + " is not readable JSON (" + (e.code ?? "parse error") + ")"); }
  };
  const fail = (e) => { console.error(String(e?.message ?? e).slice(0, 300)); process.exit(1); };
'

# The label of the LaunchAgent that runs $MJS without --config (the owner's stats reporter).
owner_label() {
  for p in "$HOME"/Library/LaunchAgents/*.plist; do
    [ -f "$p" ] || continue
    if grep -q 'rd-reporter.mjs' "$p" && ! grep -q -- '--config' "$p"; then /usr/libexec/PlistBuddy -c 'Print :Label' "$p"; return 0; fi
  done
  return 1
}

case "${1:-}" in
owner)
  NAME=${2:?name}
  [ -f "$CFG" ] || die "no $CFG: this Mac has no owner reporter"
  install_mjs
  # Set shareControl in place: every other field kept, never printed, mode 0600, atomic rename.
  "$NODE" -e "$JSON_WRITE"'
    try {
      const [f, name] = process.argv.slice(1);
      const c = readJson(f);
      if (c.name !== name) throw new Error("reporter.json is for " + String(c.name).slice(0, 40) + ", not " + name + ": wrong Mac?");
      if (c.controlOnly === true) throw new Error("reporter.json is a control-only helper config");
      writeJson(f, { ...c, shareControl: true });
      console.log("reporter.json: shareControl true (name " + name + ")");
    } catch (e) { fail(e); }' "$CFG" "$NAME"
  chmod 600 "$CFG"
  echo "share-check: $(share_check "$CFG")"
  L=$(owner_label) || die "no LaunchAgent runs $MJS; load units/com.rdocker.reporter.plist"
  launchctl kickstart -k "gui/$UID_/$L" && echo "restarted gui/$UID_/$L"
  ;;
helper-prepare)
  NAME=${2:?name}; URL=${3:?wss url}
  case $NAME in '' | -* | *[!a-z0-9-]*) die "bad name: $NAME" ;; esac
  case $URL in wss://*/ingest) ;; *) die "url must be wss://<host>/ingest" ;; esac
  case $URL in *[!A-Za-z0-9.:/-]*) die "bad url" ;; esac
  install_mjs
  mkdir -p "$HOME/.config/rdocker" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  # The key is minted here once and never leaves this Mac except through helper-key.
  "$NODE" -e "$JSON_WRITE"'
    try {
      const crypto = require("crypto"); const [f, name, url] = process.argv.slice(1);
      let key = null;
      if (fs.existsSync(f)) { const o = readJson(f); if (o.name === name && typeof o.key === "string" && /^[A-Za-z0-9_-]{32,}$/.test(o.key)) key = o.key; }
      key ??= crypto.randomBytes(32).toString("base64url");
      writeJson(f, { name, url, key, shareControl: true, controlOnly: true });
      console.log("reporter-ctl.json: " + name + " control-only, " + url);
    } catch (e) { fail(e); }' "$CTL_CFG" "$NAME" "$URL"
  chmod 600 "$CTL_CFG"
  rm -f "$CTL_PLIST.tmp"
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
  /usr/bin/plutil -lint "$CTL_PLIST.tmp" >/dev/null
  chmod 644 "$CTL_PLIST.tmp"
  mv -f "$CTL_PLIST.tmp" "$CTL_PLIST"
  echo "share-check: $(share_check "$CTL_CFG")"
  echo "prepared $CTL_PLIST (not started)"
  ;;
helper-key)
  "$NODE" -e "$JSON_WRITE"'
    try {
      const c = readJson(process.argv[1]);
      if (typeof c.key !== "string" || !/^[A-Za-z0-9_-]{32,}$/.test(c.key) || c.controlOnly !== true) throw new Error("reporter-ctl.json has no well-formed helper key");
      process.stdout.write("KEY:" + c.key + "\n");
    } catch (e) { fail(e); }' "$CTL_CFG"
  ;;
helper-start)
  [ -f "$CTL_PLIST" ] && /usr/bin/plutil -lint "$CTL_PLIST" >/dev/null || die "run helper-prepare first (no valid $CTL_PLIST)"
  supports "$MJS" || die "refused: $MJS is older than 1.6.0 (it would run a full reporter)"
  /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$CTL_PLIST" | grep -qxF "$MJS" || die "refused: $CTL_PLIST does not run $MJS"
  why=$(share_check "$CTL_CFG")
  [ "$why" = ok ] || die "refused: the helper would not accept orders here: $why"
  launchctl bootout "gui/$UID_/$CTL_LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_" "$CTL_PLIST"
  echo "started gui/$UID_/$CTL_LABEL"
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
  sed -n '2,19p' "$0" >&2; exit 64 ;;
esac
