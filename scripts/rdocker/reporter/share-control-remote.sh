#!/bin/sh
# Turn on dashboard share control on another lent Mac over Pane (`runpane workspace <ws> exec` runs there as
# its owner, no sudo). Stages share-control-mac.sh + rd-reporter.mjs in ~/.local/state/rdocker/share-setup on
# the Mac (the owner's home, not /tmp: another local user such as rd could plant a link there), then runs
# share-control-mac.sh there (see it for what each step does).
#
#   share-control-remote.sh <workspace> owner          the Mac's own owner-run reporter (nickmbp)
#   share-control-remote.sh <workspace> helper <name>  a control-only helper beside an rd stats reporter
#                                                       (ethanair): prepare, mint its key there, pipe it into
#                                                       `wrangler secret put MACHINE_CTL_KEY_<NAME>` (never
#                                                       printed), then start it
#   share-control-remote.sh <workspace> status
#
# Env: DASHBOARD_DIR (the dashboard repo, for wrangler), RD_INGEST_URL (default: this Mac's reporter.json url).
# Never changes a share level.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
RUNPANE=${RUNPANE:-$HOME/.pane/bin/runpane}
DASHBOARD_DIR=${DASHBOARD_DIR:-$HOME/Developer/CODEBASES/random/tools/online docker/dashboard}
WS=${1:?workspace (runpane workspace list)}
MODE=${2:?owner | helper <name> | status}

rp() { "$RUNPANE" workspace "$WS" exec --yes -- "$1"; }
# The Mac's own home (runpane prints its own status lines around the command's output).
RHOME=$(rp 'printf "HOME:%s\n" "$HOME"' | sed -n 's/^HOME://p')
case $RHOME in /Users/?*) ;; *) echo "could not read the Mac's home (got '$RHOME')" >&2; exit 1 ;; esac
STAGE="$RHOME/.local/state/rdocker/share-setup"
stage() {
  rp "umask 077 && mkdir -p '$STAGE' && chmod 700 '$STAGE' && test -O '$STAGE' && test ! -L '$STAGE'"
  "$RUNPANE" workspace "$WS" write "$STAGE/rd-reporter.mjs" --yes < "$HERE/rd-reporter.mjs" >/dev/null
  "$RUNPANE" workspace "$WS" write "$STAGE/share-control-mac.sh" --yes < "$HERE/share-control-mac.sh" >/dev/null
}
on_mac() { rp "STAGE='$STAGE' sh '$STAGE/share-control-mac.sh' $*"; }

case $MODE in
owner)
  stage
  on_mac owner
  ;;
helper)
  NAME=${3:?machine name, e.g. ethanair}
  printf '%s' "$NAME" | grep -Eq '^[a-z0-9][a-z0-9-]{0,31}$' || { echo "bad name: $NAME" >&2; exit 64; }
  URL=${RD_INGEST_URL:-$(node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(require("os").homedir()+"/.config/rdocker/reporter.json","utf8")).url)')}
  VAR="MACHINE_CTL_KEY_$(printf '%s' "$NAME" | tr 'a-z-' 'A-Z_')"
  stage
  on_mac helper-prepare "$NAME" "$URL"
  # The key goes Mac -> pipe -> wrangler's stdin; it is never echoed or stored here.
  KEYLINES=$(on_mac helper-key | sed -n 's/^KEY://p' | wc -l | tr -d ' ')
  [ "$KEYLINES" = 1 ] || { echo "could not read exactly one key from the Mac (got $KEYLINES lines)" >&2; exit 1; }
  on_mac helper-key | sed -n 's/^KEY://p' | (cd "$DASHBOARD_DIR" && npx wrangler secret put "$VAR")
  on_mac helper-start
  ;;
status)
  stage
  on_mac status
  ;;
*)
  sed -n '2,15p' "$0" >&2; exit 64 ;;
esac
