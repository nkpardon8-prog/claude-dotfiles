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

# Fingerprint the generator BEFORE the lock and before writing any hook. Both paths need it:
# the contention path compares another run's stamp against it, and the stamping path must
# describe only the bodies THIS run produced. Hashing $0 afterwards could stamp a newer
# generator's fingerprint over hooks written from an older one.
GEN_FP=$(shasum "$0" 2>/dev/null | awk '{print $1}')

# Serialize installs. SessionStart and the async PostToolUse sync can both invoke this, and
# two concurrent runs spanning a generator edit could interleave hook bodies and stamps.
LOCK="$HOOK_DIR/.install.lock"
STAMP="$HOOK_DIR/.secret-chain-version"

# NO AGE-BASED LOCK BREAKING. Round 5 added an orphan-reclaim that broke any lock older than
# 120s; round 6 produced three separate findings from it across two independent reviewers - it
# can steal a LIVE lock from a stalled owner, whose EXIT trap then removes the NEW owner's
# lock, letting two installs interleave hook bodies under one matching stamp. Every fix for
# that needs real lock ownership (pid + liveness + atomic compare-and-delete), which is a lot
# of machinery to protect against a SIGKILLed installer.
#
# So it is DELETED rather than patched. An orphaned lock now simply means the contention path
# below cannot verify freshness, which exits 4 - LOUD, surfaced as a pause marker naming the
# lock. A rare manual `rm -rf` beats three classes of silent concurrency bug, and a loud stop
# is the correct direction for a gate that is supposed to fail closed.
_lock_held=0
_i=0
while [ "$_i" -lt 50 ]; do
    _i=$((_i + 1))
    if mkdir "$LOCK" 2>/dev/null; then _lock_held=1; break; fi
    sleep 0.1
done

if [ "$_lock_held" -eq 1 ]; then
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    trap 'rmdir "$LOCK" 2>/dev/null; exit 3' HUP INT TERM
else
    # Could not acquire. The other run writes the same bytes, so skipping is safe ONLY if that
    # run actually finished and stamped the fingerprint this run would have written. Returning
    # 0 without that proof is exactly what let an interrupted or stale install be certified as
    # fresh by dotfiles-sync and SessionStart (round-5 finding, all three reviewers).
    if [ -n "$GEN_FP" ] && [ -r "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$GEN_FP" ]; then
        echo "install-git-hooks: another install already produced this generator's hooks - nothing to do" >&2
        exit 0
    fi
    echo "install-git-hooks: could not acquire $LOCK and the hooks are NOT verified current - install NOT performed." >&2
    echo "install-git-hooks: if no install is actually running, that lock is orphaned (killed installer or power loss) - remove it with: rm -rf '$LOCK'" >&2
    exit 4
fi

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

# EVERY rc=3 path prints this exact token. dotfiles-sync classifies a rejected push by reading
# the hook's stderr, and it previously grepped the PROSE "failing closed" - which the mktemp
# and trap paths never printed, so a disk-full or unusable-TMPDIR failure was recorded as a
# routine `kind: other` instead of `unproven` (round-6 finding, two reviewers). Classify on a
# stable machine token, never on prose - the same rule the `kind:` field already follows.
_unproven() { echo "pre-push: RANGE-NOT-PROVEN-CLEAN${1:+ - $1}" >&2; exit 3; }

[ -r "$SCAN" ] || _unproven "scanner missing at $SCAN"

Z=0000000000000000000000000000000000000000
TMPBASE="${TMPDIR:-/tmp}"
# Belt only - `--composite` ignores path rules entirely, so a temp dir under .git can no
# longer silence the scan. Kept because a TMPDIR inside a repository is worth refusing on
# its own merits. `.git` must be listed literally: the bare relative form matches neither
# `.git/*` nor `*/.git`.
case "$TMPBASE" in
    .git|.git/*|*/.git/*|*/.git) _unproven "TMPDIR resolves inside a .git directory" ;;
esac
TMP=$(mktemp "$TMPBASE/prepush-scan.XXXXXX") || _unproven "could not create a temp file under $TMPBASE"
# Two separate traps: a single `trap ... EXIT HUP INT TERM` resumes after the handler
# and exits 0, which would turn an interrupted scan into a successful push.
trap 'rm -f "$TMP"' EXIT
trap 'rm -f "$TMP"; echo "pre-push: RANGE-NOT-PROVEN-CLEAN - interrupted" >&2; exit 3' HUP INT TERM

# Scoping the NEW-branch exclusion to this remote's tracking refs. A bare `--not --remotes`
# would also excuse commits that exist only on some OTHER remote.
#
# There is deliberately NO further classification here. Earlier revisions tried to detect
# `pushurl`, multiple `remote.<name>.url` entries and `url.*.pushInsteadOf` in order to
# decide when tracking refs could be trusted; each partial heuristic simply produced another
# finding, and none of them can be made complete. Multi-remote and URL-rewriting setups are
# documented as an out-of-scope configuration in docs/SECURITY-secret-chain.md, beside the
# existing caveat that tracking refs are trusted at all. Honest scope beats a half-check.
REMOTE_NAME="${1:-}"
EXCLUDE=""
if [ -n "$REMOTE_NAME" ] && git config --get "remote.$REMOTE_NAME.url" >/dev/null 2>&1; then
    EXCLUDE="--not --remotes=$REMOTE_NAME"
fi

rc=0
while read -r local_ref local_sha remote_ref remote_sha; do
    [ "$local_sha" = "$Z" ] && continue          # branch deletion: nothing new is published
    if [ "$remote_sha" = "$Z" ]; then
        # New branch: no authoritative answer exists locally, so approximate with this
        # remote's tracking refs (unquoted: EXCLUDE may legitimately be empty).
        set -- "$local_sha" $EXCLUDE
    else
        # Existing branch: git already negotiated `remote_sha` with the destination, so this
        # range is authoritative and needs no heuristic at all. It can RE-scan commits that
        # reached the remote through some other ref (an ordinary merge), which may block a
        # push over an already-public secret. That false positive is accepted deliberately:
        # a blocked push is visible and diagnosable, a missed secret is permanent.
        set -- "$remote_sha..$local_sha"
    fi
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
    # ONE stream: added patch lines followed by commit messages, scanned once as composite
    # text. An earlier revision split these to give messages the path-aware PIN lane, but
    # the message file's own temp path then decided whether that lane ran at all - so the
    # split created two new holes instead of closing one.
    #
    # --text  forces a textual diff, so a binary blob or a path marked `-diff` in
    #         .gitattributes cannot hide behind "Binary files differ".
    # --root  emits the initial commit's patch; `log.showRoot=false` is an ordinary setting
    #         that otherwise makes a first push carry its root commit unscanned.
    # ^+ only scans ADDED lines. Deleted and context lines describe content already on the
    #         remote, and scanning them blocks the very commit that removes a leaked secret.
    # </dev/null on every git call: this loop reads the ref list from stdin.
    # --no-textconv is REQUIRED alongside --text: a textconv diff driver is a legitimate,
    # ordinary configuration (readable diffs for binary or noisy files), and it rewrites what
    # `git log -p` prints. Probed: a driver that scrubs tokens hid a plaintext secret
    # completely while git still published the real blob.
    # `--no-replace-objects`: git log and rev-list are replacement-aware by default, so a
    # refs/replace entry makes them print the REPLACEMENT while pack transfer still ships the
    # original object. Scanning the replacement would prove the wrong bytes clean. Creating a
    # replace ref takes a deliberate `git replace`, so reachability is low - but the flag is
    # free and removes the whole question.
    if ! { git --no-replace-objects log -p -m --text --no-textconv --root --no-color "$@" </dev/null | sed -n 's/^+//p' &&
           git --no-replace-objects rev-list "$@" --format=%B </dev/null; } > "$TMP"; then
        _unproven "could not enumerate commits for ${local_ref:-?}"
    fi
    "$SCAN" --composite "$TMP"; s=$?
    [ "$s" -gt "$rc" ] && rc=$s                  # precedence 3 > 2 > 0
    if [ "$s" -ne 0 ]; then
        echo "pre-push: the finding above is in commits being pushed to ${remote_ref:-?} (range: $*)" >&2
    fi
done
exit $rc
EOF

# Stamp LAST, and only the fingerprint captured before the hooks were written. `.git/hooks/`
# is NOT tracked, so `git pull` updates THIS script without touching the hooks it already
# generated: every other clone would keep running an older - possibly fail-open - pre-push
# forever, with nothing to indicate it. dotfiles-sync.sh and SessionStart compare this marker
# against the current generator and reinstall on mismatch, so the repair propagates on sync
# instead of needing a manual install per machine.
# Re-hash and require the generator to be UNCHANGED before stamping. `shasum "$0"` hashes the
# PATHNAME, not the bytes bash is currently executing, so an atomic replacement landing
# mid-run (a `git pull`, an editor save) could stamp the NEW generator's fingerprint over
# hooks built from the OLD one. The stamp would then match forever and no future run would
# ever reinstall - permanent, silent staleness. Refusing to stamp converts that into a
# self-correcting reinstall on the very next invocation.
GEN_FP_AFTER=$(shasum "$0" 2>/dev/null | awk '{print $1}')
if [ -n "$GEN_FP" ] && [ "$GEN_FP" = "$GEN_FP_AFTER" ]; then
    printf '%s\n' "$GEN_FP" > "$STAMP"
else
    # No fingerprint, or the generator moved under us: either way the freshness check cannot
    # be trusted. Remove any stale stamp so the mismatch is detected and this reinstalls,
    # rather than leaving a lie on disk.
    rm -f "$STAMP"
    if [ -z "$GEN_FP" ]; then
        # Hooks ARE current here - only the stamp is unobtainable (no shasum). Deliberately
        # still exit 0: failing closed on this would make EVERY install non-zero on such a
        # system, so SessionStart would write a pause marker forever and auto-sync would be
        # permanently dead. The cost of exit 0 is a redundant reinstall each sync, which is
        # harmless. Asymmetry with the branch below is intentional.
        echo "install-git-hooks: could not fingerprint $0 - freshness stamp not written" >&2
    else
        # The generator MOVED under us, so the hooks on disk were built from the OLD one and
        # may be the fail-open version. Removing the stamp alone is not enough: exiting 0 tells
        # dotfiles-sync and SessionStart "the gate is fresh", and dotfiles-sync would push
        # immediately, through stale hooks, before any reinstall could happen.
        echo "install-git-hooks: $0 changed during install - hooks are from the OLD generator and are NOT verified current" >&2
        exit 4
    fi
fi

echo "Installed pre-commit and pre-push hooks at $HOOK_DIR/"
echo "Test: stage a file containing an AWS-style key (AKIA followed by 16 caps/digits) - git commit should block."
echo "Note: .git/hooks/ is untracked, so re-run this script after every clone."
