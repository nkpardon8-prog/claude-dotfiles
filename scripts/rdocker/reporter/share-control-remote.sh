#!/bin/sh
# Turn on dashboard share control on another lent Mac over Pane (`runpane workspace <ws> exec` runs there as
# its owner, no sudo). Stages share-control-mac.sh + rd-reporter.mjs in ~/.local/state/rdocker/share-setup on
# the Mac (the owner's home, not /tmp: another local user such as rd could plant a link there), then runs
# share-control-mac.sh there (see it for what each step does).
#
#   share-control-remote.sh <workspace> owner <name>   the Mac's own owner-run reporter (nickmbp)
#   share-control-remote.sh <workspace> helper <name>  a control-only helper beside an rd stats reporter
#                                                       (ethanair): prepare, mint its key there, pipe it into
#                                                       `wrangler secret put MACHINE_CTL_KEY_<NAME>` (never
#                                                       printed), then start it
#   share-control-remote.sh <workspace> status <name>
#
# <name> is the fleet name; the workspace must hold that machine's fleet.json Tailscale IP (so a wrong
# workspace cannot take over another machine's orders). Never changes a share level.
# Env: DASHBOARD_DIR (the dashboard repo, for wrangler), RD_INGEST_URL (default: this Mac's reporter.json url).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
RUNPANE=${RUNPANE:-$HOME/.pane/bin/runpane}
DASHBOARD_DIR=${DASHBOARD_DIR:-$HOME/Developer/CODEBASES/random/tools/online docker/dashboard}
FLEET=${FLEET:-$HERE/../fleet.json}
WS=${1:?workspace (runpane workspace list)}
MODE=${2:?owner | helper | status}
NAME=${3:?fleet name, e.g. ethanair}
die() { echo "$*" >&2; exit 1; }

# Every value that reaches the remote shell is checked whole (no newlines, nothing but these characters)
# and then single-quoted.
case $WS in '' | *[!A-Za-z0-9._-]*) die "bad workspace: $WS" ;; esac
case $NAME in '' | -* | *[!a-z0-9-]*) die "bad name: $NAME" ;; esac
[ ${#NAME} -le 32 ] || die "bad name: $NAME"
IP=$(node -e '
  const [f, n] = process.argv.slice(1);
  const m = (JSON.parse(require("fs").readFileSync(f, "utf8")).machines ?? []).find((x) => x.name === n && x.os === "mac");
  if (m && /^100\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(m.ip ?? "")) process.stdout.write(m.ip);' "$FLEET" "$NAME")
[ -n "$IP" ] || die "$NAME is not a Mac in $FLEET"

rp() { "$RUNPANE" workspace "$WS" exec --yes -- "$1"; }
# The Mac's home and whether it holds $NAME's address (runpane prints its own status lines around the output).
PROBE=$(rp "printf 'HOME:%s\n' \"\$HOME\"; /sbin/ifconfig | grep -qF 'inet $IP ' && echo IP:yes || echo IP:no")
RHOME=$(printf '%s\n' "$PROBE" | sed -n 's/^HOME://p')
case $RHOME in /Users/[A-Za-z0-9._-]*) ;; *) die "could not read the Mac's home (got '$RHOME')" ;; esac
case $RHOME in *[!A-Za-z0-9._/-]* | */../* | */..) die "unexpected home: $RHOME" ;; esac
printf '%s\n' "$PROBE" | grep -qx 'IP:yes' || die "workspace $WS does not hold $NAME's address $IP: wrong Mac?"
STAGE="$RHOME/.local/state/rdocker/share-setup"

stage() {
  rp "umask 077 && mkdir -p '$STAGE' && chmod 700 '$STAGE' && test -O '$STAGE' && test ! -L '$STAGE'"
  "$RUNPANE" workspace "$WS" write "$STAGE/rd-reporter.mjs" --yes < "$HERE/rd-reporter.mjs" >/dev/null
  "$RUNPANE" workspace "$WS" write "$STAGE/share-control-mac.sh" --yes < "$HERE/share-control-mac.sh" >/dev/null
}
# Arguments are pre-validated (no quote can occur in them).
on_mac() {
  cmd="STAGE='$STAGE' sh '$STAGE/share-control-mac.sh'"
  for a in "$@"; do cmd="$cmd '$a'"; done
  rp "$cmd"
}

case $MODE in
owner)
  stage
  on_mac owner "$NAME"
  ;;
helper)
  URL=${RD_INGEST_URL:-$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(require("os").homedir()+"/.config/rdocker/reporter.json","utf8")).url)')}
  case $URL in wss://*/ingest) ;; *) die "url must be wss://<host>/ingest: $URL" ;; esac
  case $URL in *[!A-Za-z0-9.:/-]*) die "bad url: $URL" ;; esac
  VAR="MACHINE_CTL_KEY_$(printf '%s' "$NAME" | tr 'a-z-' 'A-Z_')"
  stage
  on_mac helper-prepare "$NAME" "$URL"
  # Read the key ONCE into memory, check it, hand it to wrangler on stdin; never echoed, logged or stored here.
  KEY=$(on_mac helper-key | sed -n 's/^KEY://p')
  case $KEY in '' | *[!A-Za-z0-9_-]*) KEY=; die "could not read exactly one well-formed key from the Mac" ;; esac
  [ ${#KEY} -ge 32 ] || { KEY=; die "the key from the Mac is too short"; }
  printf '%s' "$KEY" | (cd "$DASHBOARD_DIR" && WRANGLER_LOG=warn WRANGLER_LOG_SANITIZE=true npx wrangler secret put "$VAR")
  KEY=
  on_mac helper-start
  ;;
status)
  stage
  on_mac status
  ;;
*)
  sed -n '2,16p' "$0" >&2; exit 64 ;;
esac
