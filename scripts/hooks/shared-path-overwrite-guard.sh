#!/bin/bash
# shared-path-overwrite-guard.sh — PreToolUse hook on the Write tool.
# Invoked by Claude Code as a direct subprocess (stdin = the hook payload JSON) before
# every Write. Purpose: in shared, human-owned paths with NO undo, turn an overwrite into
# a reversible act by snapshotting the prior version to <file>.bak-<UTC-minute> first.
#
# WHY THIS EXISTS (the concrete failure):
# An agent found errors in ~/Downloads/insurance-agent-relay-prompt.md — a file authored by a
# DIFFERENT agent — offered twice to fix it, got no answer, and overwrote it in place with no
# backup. The original survived only because the acting agent still happened to hold the text in
# its context. That is luck, not a procedure. The rule now lives at
# ~/.claude-dotfiles/rules/destructive-actions.md ("Never destroy a prior version in a shared or
# human-owned path") — but a rule is prose in a context window and enforces nothing; an adversarial
# review of that very change set said so. The standing gate in rules/verify-by-mechanism.md allows
# machine-enforcement only when the failure is SILENT and the shape can RECUR. This one is both
# (nothing errors, nothing goes red, and any agent in any window can redo it tomorrow) — which is
# exactly why it earns a machine and most bugs do not.
#
# BOUNDED ON PURPOSE — this is not a policy engine:
#   * It NEVER blocks, denies, or asks. ~18 concurrent windows run in front of this on a sleeping
#     user's machine; a hook that stalls or refuses is far worse than the bug it prevents. Always
#     exit 0. It converts a destructive act into a reversible one; it does not police intent.
#   * Only $HOME/Downloads, $HOME/Desktop, $HOME/Documents — paths where a prior version exists
#     nowhere else once it is gone.
#   * NOT inside a git working tree, even under those roots. Version control already preserves the
#     prior version, and .bak files beside tracked work are clutter, not safety. That exemption
#     mirrors the SCOPE clause of rules/destructive-actions.md verbatim in intent.
#   * Fails OPEN on everything: no jq, unreadable payload, unset $HOME, unwritable dir, a directory
#     or ANY symlink as the target, a permission error on the copy. Any doubt -> exit 0.

# -e is deliberately OMITTED: under `set -e` a single non-fatal non-zero (a `grep` with no match, a
# `cp` onto a read-only dir, a `stat` on a vanished file) would abort mid-script with a non-zero
# status, which is the ONE outcome this hook must never produce. Failure has to fall through to the
# explicit `exit 0` at the bottom, so every step is individually guarded instead.
set -uo pipefail

# Kill-switch (matches the sibling hooks' idiom): one env var disables the guard entirely.
[ "${SHARED_PATH_GUARD_DISABLED:-0}" = "1" ] && exit 0

MAX_BACKUP_BYTES=52428800  # 50MB — above this, say so out loud rather than stall the Write.
BAK_RETENTION_DAYS=14      # prune our OWN .bak-<stamp> files past this age; see the prune block.

# --- payload -----------------------------------------------------------------------------------
command -v jq >/dev/null 2>&1 || exit 0            # no jq -> fail open, silently

# A terminal on fd 0 means nobody is piping us a payload (hand-run, or a harness that left fd 0
# open). Reading it blocks until EOF that never comes: measured, this hung ~8s until killed, and it
# is the one path that can stall a Write. Mirrors hooks/line-replies-notice.sh:38.
[ -t 0 ] && exit 0

# Read stdin to EOF and let jq bound the work, deliberately NOT `head -c <cap>`. The cap used to be
# 256KB, but a Write payload carries the WHOLE `content`, so any file over ~256KB yielded truncated
# JSON -> jq failed -> exit 0 with NO backup, i.e. the guard was absent for exactly the largest
# overwrites. Worse, head closing the pipe early gave the writer EPIPE (a 600KB producer died with
# BrokenPipeError), so we stopped reading mid-payload on every large Write.
FILE_PATH=$(jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "${FILE_PATH:-}" ] || exit 0
case "$FILE_PATH" in /*) ;; *) exit 0 ;; esac       # non-absolute -> we cannot reason about it
[ -n "${HOME:-}" ] || exit 0

# Never chain backups off our own backups: repeated writes must not grow unbounded .bak-*.bak-*.
case "${FILE_PATH##*/}" in *.bak-*) exit 0 ;; esac

# --- canonicalize -------------------------------------------------------------------------------
# The target may not exist yet, so canonicalize its DIRECTORY (which must) and re-attach the
# basename. This resolves symlinks and ../ segments — ~/Downloads/../Downloads/x still matches,
# while /some/project/Downloads-notes/x does not, because we compare resolved prefixes, not text.
DIR=${FILE_PATH%/*}; [ -n "$DIR" ] || DIR=/
BASE=${FILE_PATH##*/}
[ -n "$BASE" ] || exit 0                            # trailing slash = a directory, not our business
DIR_CANON=$(cd -P -- "$DIR" 2>/dev/null && pwd -P) || exit 0   # missing dir -> nothing to preserve
[ -n "${DIR_CANON:-}" ] || exit 0
TARGET="${DIR_CANON%/}/$BASE"

# --- is it a guarded, human-owned path? ---------------------------------------------------------
# Roots are canonicalized too: ~/Documents is commonly a symlink into iCloud Drive.
GUARDED=0
for ROOT in "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents"; do
  RC=$(cd -P -- "$ROOT" 2>/dev/null && pwd -P) || continue
  [ -n "${RC:-}" ] || continue
  case "$DIR_CANON" in "$RC"|"$RC"/*) GUARDED=1; break ;; esac
done
[ "$GUARDED" -eq 1 ] || exit 0

# --- git exemption -------------------------------------------------------------------------------
# Walk up from the target's directory looking for .git. Done in pure bash (no `git` subprocess) so
# the hot path stays a handful of stat calls, and so the exemption still holds if git is absent.
P="$DIR_CANON"
while [ -n "$P" ] && [ "$P" != "/" ]; do
  if [ -e "$P/.git" ]; then exit 0; fi            # tracked tree -> git IS the backup
  P=${P%/*}
done

# --- a symlink is never ours to copy -------------------------------------------------------------
# CONCRETE FAILURE: `[ -f ]` and `cp -p` both FOLLOW symlinks, so ~/Downloads/innocent.md pointing at
# a secret file produced innocent.md.bak-<stamp> as a new PLAINTEXT regular file in Downloads holding
# that secret - the guard materialised the target's content into a browser-facing, cloud-synced
# directory. Any local process can plant such a link. A symlink also has no prior contents OF ITS OWN
# to preserve, so there is nothing to lose by skipping. The sibling dropbox code (line-agent-
# communicator.py: is_symlink() first, then O_NOFOLLOW) treats a link in a shared path as an attack
# signal and refuses; this does the same.
[ -L "$TARGET" ] && exit 0

# --- is there a prior version to preserve? -------------------------------------------------------
# -f is false for a directory, which correctly skips. -s means non-empty: an empty file has nothing
# to lose. Symlinks are already gone by here, so neither test can follow one.
[ -f "$TARGET" ] && [ -s "$TARGET" ] || exit 0

# Minute-granularity stamp doubles as the "at most one backup per file per minute" limiter: a
# rewrite loop within the same minute lands on a name that already exists and is skipped.
STAMP=$(date -u +%Y%m%dT%H%MZ 2>/dev/null) || exit 0
BAK="${TARGET}.bak-${STAMP}"
[ -e "$BAK" ] && exit 0

SIZE=$(stat -f %z "$TARGET" 2>/dev/null || stat -c %s "$TARGET" 2>/dev/null || echo 0)
SIZE=$(printf '%s' "$SIZE" | tr -cd '0-9'); [ -n "$SIZE" ] || SIZE=0
if [ "$SIZE" -gt "$MAX_BACKUP_BYTES" ]; then
  # Loud, not silent: the write still proceeds, but nobody gets to believe a backup was taken.
  jq -n --arg p "$TARGET" '{systemMessage:("shared-path-overwrite-guard: NO BACKUP TAKEN for " + $p + " (over 50MB). This path has no version history - the prior contents will be gone. Copy it aside yourself first if it matters.")}' 2>/dev/null
  exit 0
fi

# cp -p preserves mtime, so the backup keeps the ORIGINAL file's timestamp - which is what tells you
# it is the prior author's version, not ours.
if cp -p -- "$TARGET" "$BAK" 2>/dev/null; then
  jq -n --arg p "$TARGET" --arg b "$BAK" '{systemMessage:("shared-path-overwrite-guard: " + $p + " already existed in a shared, human-owned path (no version history), so its prior contents were copied to " + $b + " before this Write. If you did not author that file, say in your reply that you overwrote someone else'"'"'s work and where the backup is.")}' 2>/dev/null
else
  jq -n --arg p "$TARGET" '{systemMessage:("shared-path-overwrite-guard: could NOT back up " + $p + " (copy failed - permissions or disk). The Write proceeds; the prior contents are not recoverable from here.")}' 2>/dev/null
fi

# --- prune our own old backups --------------------------------------------------------------------
# Otherwise this accumulates one copy per file per minute, up to 50MB each, forever - a guard that
# fills the disk it is protecting. Deliberately narrow:
#   * only runs right after WE took a backup (rare + already-warm path, never a cost on the hot path);
#   * only in $DIR_CANON, which is already proven to be inside a guarded root and outside any git tree;
#   * only names matching *.bak-<YYYYmmddTHHMMZ> - the exact shape THIS hook writes - and never a
#     symlink or a directory;
#   * age comes from the STAMP IN THE NAME, not mtime: `cp -p` preserves the ORIGINAL file's mtime, so
#     an mtime-based prune (`find -mtime +N`) would delete a backup of an old file the moment it was
#     taken. The stamp is fixed-width UTC, so a lexical compare is a chronological one.
# Fail-soft throughout: any missing tool or unreadable entry just leaves the file alone.
CUTOFF=$(date -u -v-${BAK_RETENTION_DAYS}d +%Y%m%dT%H%MZ 2>/dev/null) \
  || CUTOFF=$(date -u -d "${BAK_RETENTION_DAYS} days ago" +%Y%m%dT%H%MZ 2>/dev/null) \
  || CUTOFF=""
case "$CUTOFF" in
  ????????T????Z)
    for OLD in "$DIR_CANON"/*.bak-*; do
      case "${OLD##*/}" in *.bak-????????T????Z) ;; *) continue ;; esac  # also eats the no-match glob
      [ -L "$OLD" ] && continue
      [ -f "$OLD" ] || continue
      [ "${OLD##*.bak-}" \< "$CUTOFF" ] || continue
      rm -f -- "$OLD" 2>/dev/null
    done
    ;;
esac

exit 0
