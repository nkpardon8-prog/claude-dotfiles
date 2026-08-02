#!/bin/bash
# Installs native git hooks in ~/.claude-dotfiles/.git/hooks/.
# Native hooks live in .git/ which is NOT tracked, so they need explicit installation
# on each clone. Run this once after `git clone` (SETUP.md lists it as a required step).
#
# SCOPE: these hooks defend against ACCIDENTAL secret exposure. They are NOT a defense
# against deliberate circumvention by the person pushing - `--no-verify`, `core.hooksPath`,
# `BASH_ENV`, a PATH shim, or simply editing scripts/secret-scan.sh all defeat them, and a
# fresh clone that never runs this installer has no local gate at all. See
# docs/SECURITY-secret-chain.md for the full threat model.

set -e
DIR="$HOME/.claude-dotfiles"
HOOK_DIR="$DIR/.git/hooks"

mkdir -p "$HOOK_DIR"

# Write a hook ATOMICALLY: an interrupted install must never leave a half-written
# (and therefore silently permissive) hook behind. Body arrives on stdin.
install_hook() {
    _name="$1"
    _tmp="$HOOK_DIR/.$_name.tmp.$$"
    if ! cat > "$_tmp"; then
        echo "install-git-hooks: FAILED writing $_name" >&2; rm -f "$_tmp"; exit 1
    fi
    chmod +x "$_tmp" || { rm -f "$_tmp"; exit 1; }
    mv -f "$_tmp" "$HOOK_DIR/$_name" || { rm -f "$_tmp"; exit 1; }
}

# pre-commit: skill-size guard, then block secrets from entering local history.
# ORDER + STRUCTURE are load-bearing: the size lint runs first and its failure
# aborts the commit; secret-scan stays the TERMINAL check via exec (anything
# appended after an exec is unreachable - do not add steps below it).
install_hook pre-commit <<'EOF'
#!/bin/bash
# 1) 20k-char re-injection-ceiling guard (staged files only).
"$HOME/.claude-dotfiles/scripts/lint-commands/lint-skill-size.sh" --staged || exit 1
# 2) Block commit if any staged file contains a recognized secret pattern.
#    secret-scan --staged reads INDEX BLOBS, so overwriting the worktree copy after
#    `git add` no longer hides the staged secret.
exec "$HOME/.claude-dotfiles/scripts/secret-scan.sh" --staged
EOF

# pre-push: block a push whose commits carry a secret in a BLOB or a COMMIT MESSAGE.
#
# The previous version was fail-OPEN in three independent ways: it set EXIT=2 inside a
# `while` inside a pipeline inside a command substitution (so the outer EXIT stayed 0);
# it captured stdout, which is empty by contract because secret-scan writes hits to
# stderr; and on a new branch it ran `git diff <sha>` against the WORKTREE, enumerating
# zero files on a clean checkout. It printed "BLOCKED" and pushed anyway.
#
# `git log -p -m` over the range is probe-confirmed to catch a secret that was added and
# then deleted before the tip - the case that motivated the far larger blob-enumeration
# design this replaces. `-m` covers merge commits; `rev-list --format=%B` covers messages.
install_hook pre-push <<'EOF'
#!/bin/bash
# Blocks a push whose commits contain a recognized secret (blob OR commit message).
# Reads (local-ref local-sha remote-ref remote-sha) lines from stdin.
# Exit 0 clean, 2 secret found, 3 could not prove clean. See docs/SECURITY-secret-chain.md.
set -o pipefail
# EXPORTED: this hook pipes raw repository bytes through sed, and BSD sed exits 1 on an
# invalid multibyte sequence. Under pipefail that fails the push closed for the wrong
# reason - any commit touching a non-UTF-8 file would be unpushable.
export LC_ALL=C
SCAN="$HOME/.claude-dotfiles/scripts/secret-scan.sh"
[ -r "$SCAN" ] || { echo "pre-push: scanner missing at $SCAN - failing closed" >&2; exit 3; }

Z=0000000000000000000000000000000000000000
TMPBASE="${TMPDIR:-/tmp}"
# A temp dir inside a .git directory would make the scanner treat its own input as a
# repository internal and skip it. Refuse rather than scan nothing.
case "$TMPBASE" in
    .git/*|*/.git/*|*/.git) echo "pre-push: TMPDIR resolves inside a .git directory - failing closed" >&2; exit 3 ;;
esac
TMP=$(mktemp "$TMPBASE/prepush-patch.XXXXXX")  || exit 3
TMPMSG=$(mktemp "$TMPBASE/prepush-msg.XXXXXX") || { rm -f "$TMP"; exit 3; }
# Two separate traps: a single `trap ... EXIT HUP INT TERM` resumes after the handler
# and exits 0, which would turn an interrupted scan into a successful push.
trap 'rm -f "$TMP" "$TMPMSG"' EXIT
trap 'rm -f "$TMP" "$TMPMSG"; exit 3' HUP INT TERM

# Exclusion is an OPTIMIZATION, never a correctness requirement: with EXCLUDE empty we scan
# the branch's entire history, which is slow but can never miss anything.
#
# $1 is the remote NAME when pushing by name, the URL when pushing by URL. Tracking refs
# (refs/remotes/<name>/*) describe what the FETCH url holds. Trust them only when this is a
# configured remote whose push destination is that same url - a distinct `pushurl`, extra
# `remote.<name>.url` entries, or a raw-URL push all mean the tracking refs describe a
# DIFFERENT repository than the one about to receive these objects.
REMOTE_NAME="${1:-}"
EXCLUDE=""
if [ -n "$REMOTE_NAME" ] && git config --get "remote.$REMOTE_NAME.url" >/dev/null 2>&1; then
    _pushurl=$(git config --get-all "remote.$REMOTE_NAME.pushurl" 2>/dev/null)
    _urls=$(git config --get-all "remote.$REMOTE_NAME.url" 2>/dev/null | wc -l | tr -d ' ')
    if [ -z "$_pushurl" ] && [ "$_urls" = "1" ]; then
        EXCLUDE="--not --remotes=$REMOTE_NAME"
    else
        echo "pre-push: $REMOTE_NAME has a pushurl or multiple urls - scanning full history" >&2
    fi
fi

rc=0
while read -r local_ref local_sha remote_ref remote_sha; do
    [ "$local_sha" = "$Z" ] && continue          # branch deletion: nothing new is published
    # ONE range shape for both new and existing branches: everything reachable from the tip
    # that the target remote does not already have. `remote_sha..local_sha` looked tighter
    # but rescans commits already public via another ref, so an ordinary merge could block
    # on a secret that is already on the remote - and the cleanup commit with it.
    set -- "$local_sha" $EXCLUDE                 # unquoted on purpose: EXCLUDE may be empty
    # --text forces a textual diff, so a binary blob or a path marked `-diff` in
    # .gitattributes cannot hide its contents behind "Binary files differ".
    #
    # Only ADDED lines are scanned. A raw patch also carries deleted and context lines,
    # which describe content that is ALREADY on the remote - scanning those means the
    # commit that REMOVES a leaked secret is itself blocked, so the cleanup can never be
    # pushed. Commit messages have no +/- prefix and are appended separately.
    #
    # </dev/null on every git call: this loop reads the ref list from stdin, and a child
    # that consumed it would silently skip the remaining refs.
    # TWO streams, scanned differently on purpose.
    #
    # Patch text (--patch, primary patterns only): every original path is gone once hunks
    # are concatenated, so the scanner's path-aware PIN allowlist cannot mean anything -
    # applying it here would block pushes carrying legitimate PIN examples from the
    # allowlisted docs. Per-file PIN coverage stays with the pre-commit hook.
    #
    # Commit messages (ordinary scan, ALL patterns): messages have no path context to lose
    # and no allowlist to honor, so suppressing the PIN lane there just dropped real
    # coverage - a PIN-bearing commit message would have passed both hooks.
    if ! git log -p -m --text --no-color "$@" </dev/null | sed -n 's/^+//p' > "$TMP"; then
        echo "pre-push: could not enumerate patches for ${local_ref:-?} - failing closed" >&2
        exit 3
    fi
    if ! git rev-list "$@" --format=%B </dev/null > "$TMPMSG"; then
        echo "pre-push: could not enumerate commit messages for ${local_ref:-?} - failing closed" >&2
        exit 3
    fi
    "$SCAN" --patch "$TMP"; s=$?
    [ "$s" -gt "$rc" ] && rc=$s
    "$SCAN" -- "$TMPMSG"; s=$?
    [ "$s" -gt "$rc" ] && rc=$s                  # precedence 3 > 2 > 0
    if [ "$rc" -ne 0 ]; then
        echo "pre-push: the finding above is in commits being pushed to ${remote_ref:-?} (range: $*)" >&2
    fi
done
exit $rc
EOF

# Stamp the generator's fingerprint. `.git/hooks/` is NOT tracked, so `git pull` updates
# THIS script without touching the hooks it already generated: every other clone would keep
# running an older - possibly fail-open - pre-push forever, with nothing to indicate it.
# dotfiles-sync.sh compares this marker against the current generator and reinstalls on
# mismatch, so the repair propagates on sync instead of requiring a manual install per machine.
shasum "$0" 2>/dev/null | awk '{print $1}' > "$HOOK_DIR/.secret-chain-version" || true

echo "Installed pre-commit and pre-push hooks at $HOOK_DIR/"
echo "Test: stage a file containing an AWS-style key (AKIA followed by 16 caps/digits) - git commit should block."
echo "Note: .git/hooks/ is untracked, so re-run this script after every clone."
