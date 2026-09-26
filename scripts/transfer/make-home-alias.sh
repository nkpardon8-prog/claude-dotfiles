#!/usr/bin/env bash
# make-home-alias.sh - let a chat that was packaged under ONE username restore on a Mac that
# logs in as a DIFFERENT one (real case: A is `omidzahrai`, the Mac mini is `omidsmacmini`).
#
# A transfer places Claude/Codex state under the receiving Mac's OWN $HOME, but places repo
# files (handoff, MISSION/TRANSFER notes, untracked files, tmp/ context, the git worktree) at the
# SAME absolute path as on the sender, e.g. /Users/omidzahrai/Developer/... That path must exist
# on this Mac. This script creates a "home alias": a directory named after A's username that
#   - is owned by the Mac's real (SUDO_USER) account, not a second real user,
#   - carries the marker .home-alias-of (alias_of=<real account>), which is what makes it a
#     VERIFIED alias to transfer-send.sh, resumework and transfer-doctor (transfer-lib.sh
#     tx_alias_homes: marker owned by this account and naming it),
#   - has a REAL (non-symlinked) Developer directory, so absolute project paths land as normal
#     files/directories on disk and `pwd` inside them reads as A's original path, not B's, and
#   - symlinks .claude, .claude-dotfiles, .codex and .config/claude back to the real account's
#     own copies, so a path written with A's home (e.g. in a doc or a tool config) still works.
#
# With it, transfers work in BOTH directions: resumework here accepts repo paths under the alias,
# and transfer-send here accepts a chat whose working directory is under the alias.
#
# Usage (run ONCE by the owner, who types their password):
#   sudo ~/.claude-dotfiles/scripts/transfer/make-home-alias.sh <other_username>
#
# Idempotent: re-running is a no-op except for filling in anything missing.
set -euo pipefail

PROG="make-home-alias.sh"
die() { echo "$PROG: ERROR: $*" >&2; exit 1; }
refuse() { echo "$PROG: REFUSED: $*" >&2; exit 2; }

[ $# -eq 1 ] || { echo "usage: sudo $PROG <other_username>" >&2; exit 2; }
OTHER="$1"

case "$OTHER" in
  "" | *[!A-Za-z0-9._-]* ) refuse "not a plausible username: '$OTHER'" ;;
  . | .. ) refuse "not a plausible username: '$OTHER'" ;;
esac

# Must run as root, via sudo, so we know WHICH real account to alias into (root's own $HOME is
# /var/root - useless here; SUDO_USER is the account that invoked sudo).
[ "$(id -u)" -eq 0 ] || refuse "must run via sudo (needs root to create /Users/$OTHER): sudo $PROG $OTHER"
[ -n "${SUDO_USER:-}" ] || refuse "no \$SUDO_USER - run this with sudo, not as root directly: sudo $PROG $OTHER"
[ "$SUDO_USER" != "root" ] || refuse "\$SUDO_USER is root; run this as your own account: sudo $PROG $OTHER"

ME="$SUDO_USER"
[ "$ME" != "$OTHER" ] || refuse "the alias target ($OTHER) is the same as your own account ($ME) - nothing to do"

ME_HOME=$(dscl . -read "/Users/$ME" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
[ -n "$ME_HOME" ] && [ -d "$ME_HOME" ] || die "could not resolve a home directory for $ME"
ME_UID=$(id -u "$ME") || die "could not resolve a uid for $ME"
ME_GID=$(id -g "$ME") || die "could not resolve a gid for $ME"

ALIAS_DIR="/Users/$OTHER"
MARKER="$ALIAS_DIR/.home-alias-of"

# Refuse to touch a REAL account's home. /Users/$OTHER existing is fine ONLY if it is already an
# alias this script made (marker present, and no /Users/$OTHER account entry in Directory Services).
if dscl . -read "/Users/$OTHER" NFSHomeDirectory >/dev/null 2>&1; then
  refuse "$OTHER is a real account on this Mac (found in Directory Services) - refusing to alias over it"
fi
if [ -e "$ALIAS_DIR" ] && [ ! -e "$MARKER" ]; then
  refuse "$ALIAS_DIR already exists and was not created by this script (no $MARKER) - remove or rename it by hand first"
fi

echo "$PROG: aliasing '$OTHER' -> this Mac's own account '$ME' ($ME_HOME)"

mkdir -p "$ALIAS_DIR"
chown "$ME_UID:$ME_GID" "$ALIAS_DIR"
chmod 755 "$ALIAS_DIR"

link_one() {  # link_one <name-under-alias-dir> <real-target-under-ME_HOME>
  local name="$1" target="$ME_HOME/$2" dest="$ALIAS_DIR/$1"
  [ -e "$target" ] || { echo "  skip $name: $ME has no $2 yet"; return 0; }
  if [ -L "$dest" ]; then
    local cur
    cur=$(readlink "$dest")
    if [ "$cur" = "$target" ]; then
      echo "  ok     $name -> $target (already linked)"
      return 0
    fi
    rm -f "$dest"
  elif [ -e "$dest" ]; then
    refuse "$dest exists and is not a symlink this script controls - remove it by hand first"
  fi
  ln -s "$target" "$dest"
  chown -h "$ME_UID:$ME_GID" "$dest"
  echo "  linked $name -> $target"
}

link_one ".claude" ".claude"
link_one ".claude-dotfiles" ".claude-dotfiles"
link_one ".codex" ".codex"
if [ -d "$ME_HOME/.config/claude" ]; then
  mkdir -p "$ALIAS_DIR/.config"
  chown "$ME_UID:$ME_GID" "$ALIAS_DIR/.config"
  link_one ".config/claude" ".config/claude"
fi

# A REAL directory, never a symlink: absolute project paths (e.g. /Users/<other>/Developer/...)
# must exist as ordinary files on disk so `pwd`, `git`, and Claude's own project-folder-name
# matching all see A's original path - a symlinked Developer would make `pwd -P` resolve to
# $ME_HOME/Developer instead, which is exactly the divergence this script exists to avoid.
if [ -L "$ALIAS_DIR/Developer" ]; then
  refuse "$ALIAS_DIR/Developer is a symlink - remove it by hand; this script needs a real directory there"
fi
mkdir -p "$ALIAS_DIR/Developer"
chown -R "$ME_UID:$ME_GID" "$ALIAS_DIR/Developer"
echo "  ok     Developer (real directory, owned by $ME)"

{
  echo "alias_of=$ME"
  echo "created_or_verified_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "host=$(hostname -s 2>/dev/null || hostname)"
} > "$MARKER"
chown "$ME_UID:$ME_GID" "$MARKER"
chmod 644 "$MARKER"

echo "$PROG: done. $ALIAS_DIR is a verified home alias of $ME: it has a real Developer/ directory"
echo "  owned by $ME, and transfers to and from this Mac can use repo paths under $ALIAS_DIR."
