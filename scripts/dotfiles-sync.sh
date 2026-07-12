#!/bin/bash
# Auto-sync claude dotfiles to GitHub.
# Called by PostToolUse hook when files in ~/.claude-dotfiles/ are modified
# and by /user:learn after saving patterns.
#
# Defense in depth:
#   - Local git pre-commit hook blocks staged secrets (see install-git-hooks.sh)
#   - This script blocks pre-push via secret-scan.sh
#   - Native git pre-push hook also blocks (belt-and-suspenders for manual `git push`)
#   - GitHub Actions runs the same scan on the server side
# All four layers share the same regex from scripts/secret-scan.sh.

# PAUSE GUARD: an out-of-repo marker silences auto-sync entirely (used while agents batch-edit
# the dotfiles machinery, or while pushes are held). Out-of-repo so `git add -A` can never stage it.
[ -f "$HOME/.claude/.dotfiles-sync-paused" ] && exit 0

set -o pipefail
LC_ALL=C

DOTFILES_DIR="$HOME/.claude-dotfiles"
cd "$DOTFILES_DIR" || exit 0

# Bail if no changes
if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    exit 0
fi

# Pre-push secret scan (working tree + untracked files about to be staged)
"$DOTFILES_DIR/scripts/secret-scan.sh" --working
rc=$?
case "$rc" in
    0) ;;  # clean — proceed
    2) echo "(secret-scan blocked auto-push)" >&2; exit 2 ;;
    *) echo "(secret-scan failed with exit $rc — refusing to push)" >&2; exit 3 ;;
esac

# VISIBILITY-AWARE PUSH GUARD (2026-07-12). The user EXPLICITLY accepts this repo being PUBLIC
# (informed choice after a private-vs-public review + a clean secret audit), so a public target
# WARNS but PROCEEDS — the pre-push secret-scan above is the real "nothing private" gate, and it
# hard-blocks any actual secret regardless of visibility. The guard still FAILS CLOSED on genuine
# UNCERTAINTY (gh error / unresolvable target): it can't confirm the push target is the repo the
# user meant, so it holds rather than push blind. A held push is never silent — the SessionStart
# guard surfaces a PAUSED/held notice with the unpushed count.
# SAME-REMOTE BINDING (codex-review CRITICAL 2026-07-12): a bare `gh repo view` resolves its repo
# from $GH_REPO or cwd's default remote, while a bare `git push` targets the branch's tracking
# remote — these can DIFFER, so a private result for some OTHER repo could authorize pushing THIS
# one to a public origin. Bind both to ONE explicitly-resolved remote: derive owner/repo from the
# exact remote we will push to, query THAT repo's visibility, and push to THAT remote by name.
_remote=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null | cut -d/ -f1)
[ -n "$_remote" ] || _remote=origin
_url=$(git remote get-url "$_remote" 2>/dev/null)
# owner/repo from either https://github.com/OWNER/REPO(.git) or git@github.com:OWNER/REPO(.git).
# Portable (BSD/GNU sed): strip a trailing .git and slash, THEN the host prefix — no non-greedy ops.
_slug=$(printf '%s' "$_url" | sed -e 's#\.git$##' -e 's#/$##' -e 's#^.*github\.com[:/]##')
git add -A
git commit -m "auto-sync: $(date +%Y-%m-%d-%H:%M) from $(hostname -s)" 2>/dev/null
# Empty $GH_TOKEN-free env is fine; -R pins the query to the push target so $GH_REPO can't hijack it.
if [ -n "$_slug" ]; then
    _vis=$(GH_REPO= gh repo view "$_slug" --json isPrivate -q .isPrivate 2>/dev/null)
else
    _vis=""   # could not resolve the push target's slug — fail closed (hold)
fi
case "$_vis" in
  true)
    git push "$_remote" 2>/dev/null || true ;;                     # private — silent push
  false)
    echo "(dotfiles-sync: pushing to a PUBLIC repo ${_slug:-$_remote} — you accepted this; secret-scan passed above.)" >&2
    git push "$_remote" 2>/dev/null || true ;;                     # public — warn + push (user's choice)
  *)
    echo "(dotfiles-sync: PUSH HELD — could not resolve/confirm the push target ${_slug:-$_remote} (isPrivate='${_vis:-unknown}'); committed locally only. Re-run this script once gh can see the repo.)" >&2
    exit 4 ;;                                                       # genuine uncertainty — fail closed
esac
