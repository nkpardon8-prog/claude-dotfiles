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
SCAN="$HOME/.claude-dotfiles/scripts/secret-scan.sh"
[ -r "$SCAN" ] || { echo "pre-push: scanner missing at $SCAN - failing closed" >&2; exit 3; }

Z=0000000000000000000000000000000000000000
TMP=$(mktemp "${TMPDIR:-/tmp}/prepush-scan.XXXXXX") || exit 3
# Two separate traps: a single `trap ... EXIT HUP INT TERM` resumes after the handler
# and exits 0, which would turn an interrupted scan into a successful push.
trap 'rm -f "$TMP"' EXIT
trap 'rm -f "$TMP"; exit 3' HUP INT TERM

rc=0
while read -r local_ref local_sha remote_ref remote_sha; do
    [ "$local_sha" = "$Z" ] && continue          # branch deletion: nothing new is published
    if [ "$remote_sha" = "$Z" ]; then
        set -- "$local_sha" --not --remotes      # new branch: everything the remote lacks
    else
        set -- "$remote_sha..$local_sha"
    fi
    # </dev/null on every git call: this loop is reading the ref list from stdin, and a
    # child that consumed it would silently skip the remaining refs.
    if ! { git log -p -m --no-color "$@" </dev/null &&
           git rev-list "$@" --format=%B </dev/null; } > "$TMP"; then
        echo "pre-push: could not enumerate commits for ${local_ref:-?} - failing closed" >&2
        exit 3
    fi
    "$SCAN" "$TMP"; s=$?
    if [ "$s" -ne 0 ]; then
        echo "pre-push: above finding is in the commits being pushed to ${remote_ref:-?} (range: $*)" >&2
    fi
    [ "$s" -gt "$rc" ] && rc=$s                  # precedence 3 > 2 > 0
done
exit $rc
EOF

echo "Installed pre-commit and pre-push hooks at $HOOK_DIR/"
echo "Test: stage a file containing an AWS-style key (AKIA followed by 16 caps/digits) - git commit should block."
echo "Note: .git/hooks/ is untracked, so re-run this script after every clone."
