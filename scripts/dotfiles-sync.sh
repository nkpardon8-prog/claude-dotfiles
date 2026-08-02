#!/bin/bash
# Auto-sync claude dotfiles to GitHub.
# Called by PostToolUse hook when files in ~/.claude-dotfiles/ are modified.
#
# Defense in depth:
#   - Local git pre-commit hook blocks staged secrets (see install-git-hooks.sh)
#   - This script blocks pre-push via secret-scan.sh
#   - Native git pre-push hook also blocks (belt-and-suspenders for manual `git push`)
#   - GitHub Actions runs the same scan on the server side
# All four layers share the same regex from scripts/secret-scan.sh.

# PAUSE GUARD: an out-of-repo marker silences auto-sync entirely (used while agents batch-edit
# the dotfiles machinery, or while pushes are held). Out-of-repo so `git add -A` can never stage it.
_MARKER="$HOME/.claude/.dotfiles-sync-paused"
[ -f "$_MARKER" ] && exit 0

set -o pipefail
# EXPORTED: the push classifier below reads English git stderr, and an unexported
# LC_ALL does not reach the git child (clean-shell probed).
export LC_ALL=C

# _pause <reason> - record a durable, human-readable reason for a held or blocked sync.
# This script runs from an `async: true` PostToolUse hook, so its stderr AND its exit
# status reach nobody. The marker is the only channel that survives; SessionStart and
# UserPromptSubmit both surface it. Marker presence also halts further auto-sync (above),
# which is deliberate - a blocked sync must stop stacking commits on a poisoned HEAD.
# Consequence, accepted: a transient network failure holds sync until a human clears it.
# The alternative was `|| true`, which lost the failure entirely.
# _pause <reason> [kind]   kind: secret | unproven | other   (default: other)
#   secret   - a secret was detected or could not be ruled out; rotate before clearing
#   unproven - the gate could not PROVE the pushed range clean (scanner/TMPDIR/range failure)
#   other    - routine failure (network, unresolved target); fix the cause and retry
# `kind` is a machine field on purpose. The reader must NOT infer severity by grepping the
# prose - the reason text routinely contains the word "secret" for entirely benign reasons
# (this repo's own work is named "secret-chain"), and mis-reporting a routine pause as a
# credential leak trains people to ignore the one message that matters.
_pause() {
    # Redact any userinfo in a URL before it reaches disk: git's stderr can echo a remote
    # URL, and a remote URL can embed a token. Redacting at the choke point means no caller
    # can leak one into the marker by accident. Also collapse to a single line.
    _reason=$(printf '%s' "$1" | tr '\n' ' ' | sed -e 's#://[^/@[:space:]]*@#://REDACTED@#g' | cut -c1-300)
    _kind="${2:-other}"
    # NEVER DOWNGRADE a recorded leak, and do it ATOMICALLY. Both writers used to overwrite
    # unconditionally, so a routine later failure (network down, installer missing) replaced an
    # existing `kind: secret` with `kind: other` - and because both readers route on that field,
    # the guidance silently flipped from "rotate the credential, then clear" to "just clear it".
    # A check-then-write does not fix it either: this script runs from an `async: true`
    # PostToolUse hook, so two jobs can interleave between the test and the truncate (round-6
    # finding, two reviewers). `set -C` makes the redirect an O_EXCL create, so a non-secret
    # pause can NEVER clobber an existing marker - first pause wins, no window.
    if [ "$_kind" != secret ]; then
        if ( set -C; printf 'kind: %s\nreason: %s\nset_at: %s\nset_by: dotfiles-sync\nclear_with: rm %s\n' \
                "$_kind" "$_reason" "$(date '+%Y-%m-%d %H:%M:%S')" "$_MARKER" > "$_MARKER" ) 2>/dev/null; then
            return 0
        fi
        echo "dotfiles-sync: $_reason (a pause marker is already present and was left intact)" >&2
        return 0
    fi
    # kind=secret is the ONLY upgrade allowed to overwrite: a confirmed leak must replace any
    # lesser record, and losing that record is far worse than losing a routine one.
    if ! printf 'kind: %s\nreason: %s\nset_at: %s\nset_by: dotfiles-sync\nclear_with: rm %s\n' \
            "$_kind" "$_reason" "$(date '+%Y-%m-%d %H:%M:%S')" "$_MARKER" > "$_MARKER" 2>/dev/null; then
        echo "dotfiles-sync: CRITICAL - could not write the pause marker at $_MARKER (reason: $_reason). This failure now has NO visible channel." >&2
    fi
}

DOTFILES_DIR="$HOME/.claude-dotfiles"
cd "$DOTFILES_DIR" || exit 0

# SELF-HEALING HOOK INSTALL. .git/hooks/ is untracked, so a `git pull` that brings in a
# fixed install-git-hooks.sh leaves the ALREADY-GENERATED hooks untouched - a clone would
# keep an outdated, possibly fail-open, pre-push indefinitely with no signal. Compare the
# stamped fingerprint against the current generator and reinstall when they disagree.
_installer="$DOTFILES_DIR/scripts/install-git-hooks.sh"
_stamp="$DOTFILES_DIR/.git/hooks/.secret-chain-version"
if [ ! -r "$_installer" ]; then
    # FAIL CLOSED. Skipping the check because the installer is missing is backwards: that is
    # the state in which the local hooks are most likely stale or absent entirely.
    echo "dotfiles-sync: installer missing or unreadable at $_installer - cannot verify the local secret gate." >&2
    _pause "install-git-hooks.sh missing or unreadable - local secret gate unverifiable"
    exit 9
fi
if [ -r "$_installer" ]; then
    _want=$(shasum "$_installer" 2>/dev/null | awk '{print $1}')
    _have=$(cat "$_stamp" 2>/dev/null)
    if [ -z "$_want" ]; then
        # Cannot compute the fingerprint, so cannot tell whether the installed hooks are
        # the current ones. Silently skipping here would let a stale fail-open hook survive
        # exactly when the check that exists to catch it stopped working.
        echo "dotfiles-sync: could not fingerprint $_installer - cannot verify the local secret gate." >&2
        _pause "could not verify the installed git hooks are current"
        exit 8
    fi
    if [ "$_want" != "$_have" ]; then
        if bash "$_installer" >/dev/null 2>&1; then
            echo "(dotfiles-sync: git hooks were stale - reinstalled from $_installer)" >&2
        else
            echo "dotfiles-sync: FAILED to refresh the git hooks - the local secret gate may be stale or absent." >&2
            _pause "git hook reinstall failed - the local secret gate may be stale"
            exit 7
        fi
    fi
fi

# Bail only when there is genuinely nothing to do. A clean tree does NOT mean nothing is
# pending: a previously blocked or failed push leaves commits sitting locally, and exiting
# here would strand them forever once the pause was cleared.
if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    if _ahead=$(git rev-list --count '@{u}..HEAD' 2>/dev/null); then
        [ "${_ahead:-0}" -eq 0 ] && exit 0
        echo "(dotfiles-sync: tree clean but ${_ahead} commit(s) unpushed - attempting to deliver them.)" >&2
    else
        # No upstream, or the lookup failed. Collapsing that to "0 unpushed" would strand
        # local commits permanently on exactly the branches least likely to be noticed.
        echo "(dotfiles-sync: tree clean and no usable upstream for the current branch - attempting a push anyway.)" >&2
    fi
fi

# Pre-push secret scan (working tree + untracked files about to be staged)
"$DOTFILES_DIR/scripts/secret-scan.sh" --working
rc=$?
case "$rc" in
    0) ;;  # clean — proceed
    2) echo "(secret-scan blocked auto-push)" >&2; _pause "secret-scan detected a secret in the working tree" secret; exit 2 ;;
    *) echo "(secret-scan failed with exit $rc — refusing to push)" >&2; _pause "secret-scan could not prove the tree clean (exit $rc)" secret; exit 3 ;;
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
if git diff --cached --quiet; then
    : # nothing staged — benign, fall through (push may still deliver an earlier held commit)
elif ! git commit -m "auto-sync: $(date +%Y-%m-%d-%H:%M) from $(hostname -s)"; then
    # LOUD fail-closed: a rejected commit (e.g. a pre-commit lint) must never silently
    # strand staged changes while pushing stale HEAD. Surface it and stop.
    echo "dotfiles-sync: COMMIT FAILED (pre-commit hook rejected or git error) — staged changes are NOT committed and NOT pushed. Fix the cause, then re-run scripts/dotfiles-sync.sh." >&2
    _pause "commit failed (pre-commit hook rejected or git error) - staged changes are NOT committed"
    exit 5
fi
# Empty $GH_TOKEN-free env is fine; -R pins the query to the push target so $GH_REPO can't hijack it.
if [ -n "$_slug" ]; then
    _vis=$(GH_REPO= gh repo view "$_slug" --json isPrivate -q .isPrivate 2>/dev/null)
else
    _vis=""   # could not resolve the push target's slug — fail closed (hold)
fi
# A failed push used to be `|| true` — the single worst line in this script: the commit
# stays local, the next edit re-fires the sync, and nothing anywhere says the push died.
_push_or_pause() {
    if ! _perr=$(git push "$_remote" 2>&1); then
        echo "dotfiles-sync: PUSH FAILED to ${_slug:-$_remote} — committed locally only." >&2
        # A push rejected by our own pre-push hook means a secret is in the commits being
        # pushed - a materially different situation from a network failure, and the reader
        # must be told to rotate rather than to clear the marker and retry.
        if printf '%s' "$_perr" | grep -q 'BLOCKED: secret detected'; then
            _pause "pre-push rejected the push: a secret is present in the commits being pushed" secret
        elif printf '%s' "$_perr" | grep -q 'RANGE-NOT-PROVEN-CLEAN'; then
            # rc=3 from the gate: it could not PROVE the range clean (scanner missing, TMPDIR
            # unusable, commits unenumerable). That is not a confirmed leak, but it is also not
            # a routine network failure - clearing it and retrying just pushes unproven bytes.
            # It needs its own machine kind so the readers can say the right thing.
            _pause "pre-push could not prove the pushed range clean: $(printf '%s' "$_perr" | grep -m1 'failing closed')" unproven
        else
            _pause "push to ${_slug:-$_remote} failed: $(printf '%s' "$_perr" | head -1)"
        fi
        exit 6
    fi
}

case "$_vis" in
  true)
    _push_or_pause ;;                                               # private — silent push
  false)
    echo "(dotfiles-sync: pushing to a PUBLIC repo ${_slug:-$_remote} — you accepted this; secret-scan passed above.)" >&2
    _push_or_pause ;;                                               # public — warn + push (user's choice)
  *)
    echo "(dotfiles-sync: PUSH HELD — could not resolve/confirm the push target ${_slug:-$_remote} (isPrivate='${_vis:-unknown}'); committed locally only. Re-run this script once gh can see the repo.)" >&2
    _pause "could not resolve/confirm the push target ${_slug:-$_remote} (isPrivate=${_vis:-unknown})"
    exit 4 ;;                                                       # genuine uncertainty — fail closed
esac
