#!/bin/bash
# dotfiles-autopull: keep ~/.claude-dotfiles at origin/main on every agent Mac, every 2 minutes.
#
#   dotfiles-autopull.sh            one pull (what the LaunchAgent runs)
#   dotfiles-autopull.sh --install  install/refresh the LaunchAgent (no sudo); idempotent
#   dotfiles-autopull.sh --ensure   install only when missing (the rrun-route hook calls this, detached)
#   dotfiles-autopull.sh --uninstall
#
# Fast-forward ONLY: it never merges, rebases, stashes or touches uncommitted work. If the local branch
# has its own commits, or a dirty file conflicts, the pull is skipped and the reason recorded. The
# dotfiles-sync hook pushes local commits; this only brings other machines' commits in.
# Status: ~/.claude/.dotfiles-autopull.json {"ts","head","origin","behind","state","why"}.
set -u
REPO="$HOME/.claude-dotfiles"
LABEL=com.claude.dotfiles-autopull
PL="$HOME/Library/LaunchAgents/$LABEL.plist"
STAT="$HOME/.claude/.dotfiles-autopull.json"
SELF="$REPO/scripts/dotfiles-autopull.sh"

status() {  # state why
  local head origin behind
  head=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo "")
  origin=$(git -C "$REPO" rev-parse --short origin/main 2>/dev/null || echo "")
  behind=$(git -C "$REPO" rev-list --count HEAD..origin/main 2>/dev/null || echo -1)
  mkdir -p "$(dirname "$STAT")"
  printf '{"ts":%s,"head":"%s","origin":"%s","behind":%s,"state":"%s","why":"%s"}\n' \
    "$(date +%s)" "$head" "$origin" "$behind" "$1" "$(printf '%s' "$2" | tr '"\\\n' "'/ " | cut -c1-200)" > "$STAT.tmp" \
    && mv -f "$STAT.tmp" "$STAT"
}

install() {
  [ "$(uname)" = Darwin ] || { echo "dotfiles-autopull: macOS only"; return 0; }
  mkdir -p "$(dirname "$PL")"
  cat > "$PL.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SELF</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
  <key>StartInterval</key><integer>120</integer>
  <key>RunAtLoad</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
EOF
  mv -f "$PL.tmp" "$PL"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PL" && echo "AUTOPULL-INSTALLED"
}

case "${1:-}" in
  --install) install; exit $? ;;
  --ensure) [ -f "$PL" ] && exit 0; install >/dev/null 2>&1; exit 0 ;;
  --uninstall) launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null; rm -f "$PL"; echo "AUTOPULL-REMOVED"; exit 0 ;;
  "") ;;
  *) echo "dotfiles-autopull: unknown argument $1" >&2; exit 2 ;;
esac

cd "$REPO" 2>/dev/null || exit 0
G=$(git rev-parse --git-dir 2>/dev/null) || exit 0
# Another git operation (an agent's commit, the sync hook's rebase) is in flight: try next round.
for f in index.lock rebase-merge rebase-apply MERGE_HEAD; do
  [ -e "$G/$f" ] && { status skipped "git busy ($f)"; exit 0; }
done
[ "$(git symbolic-ref --short HEAD 2>/dev/null)" = main ] || { status skipped "not on main"; exit 0; }
# Bounded fetch: an unreachable remote must not pile up runs.
git fetch -q origin main 2>/dev/null & FP=$!
( sleep 60; kill $FP 2>/dev/null ) & KP=$!
wait $FP; RC=$?; kill $KP 2>/dev/null
[ $RC = 0 ] || { status offline "fetch failed rc=$RC"; exit 0; }
if git merge-base --is-ancestor origin/main HEAD; then status current ""; exit 0; fi
if ! git merge-base --is-ancestor HEAD origin/main; then status skipped "local commits not yet pushed (sync hook pushes them)"; exit 0; fi
ERR=$(git merge --ff-only -q origin/main 2>&1) && status updated "" || status skipped "ff blocked: $ERR"
exit 0
