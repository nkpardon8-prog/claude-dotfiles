#!/bin/bash
# Installs native git hooks in ~/.claude-dotfiles/.git/hooks/.
# Native hooks live in .git/ which is NOT tracked, so they need explicit installation
# on each clone. Run this once after `git clone`.

set -e
DIR="$HOME/.claude-dotfiles"
HOOK_DIR="$DIR/.git/hooks"

mkdir -p "$HOOK_DIR"

# pre-commit: skill-size guard, then block secrets from entering local history.
# ORDER + STRUCTURE are load-bearing: the size lint runs first and its failure
# aborts the commit; secret-scan stays the TERMINAL check via exec (anything
# appended after an exec is unreachable - do not add steps below it).
cat > "$HOOK_DIR/pre-commit" <<'EOF'
#!/bin/bash
# 1) 20k-char re-injection-ceiling guard (staged files only).
"$HOME/.claude-dotfiles/scripts/lint-commands/lint-skill-size.sh" --staged || exit 1
# 2) Block commit if any staged file contains a recognized secret pattern.
exec "$HOME/.claude-dotfiles/scripts/secret-scan.sh" --staged
EOF
chmod +x "$HOOK_DIR/pre-commit"

# pre-push: belt-and-suspenders — block manual `git push` even if pre-commit was bypassed
cat > "$HOOK_DIR/pre-push" <<'EOF'
#!/bin/bash
# Block push if any commit being pushed contains a recognized secret.
# Reads (local-ref local-sha remote-ref remote-sha) lines from stdin.
EXIT=0
while read -r local_ref local_sha remote_ref remote_sha; do
    if [ "$local_sha" = "0000000000000000000000000000000000000000" ]; then
        continue  # branch deletion
    fi
    if [ "$remote_sha" = "0000000000000000000000000000000000000000" ]; then
        # New branch — scan all commits being pushed
        range="$local_sha"
    else
        range="$remote_sha..$local_sha"
    fi
    HITS=$(git diff "$range" --name-only --diff-filter=ACMR | while IFS= read -r f; do
        [ -f "$f" ] || continue
        "$HOME/.claude-dotfiles/scripts/secret-scan.sh" "$f" || EXIT=2
    done)
    [ -n "$HITS" ] && echo "$HITS" >&2
done
exit $EXIT
EOF
chmod +x "$HOOK_DIR/pre-push"

echo "Installed pre-commit and pre-push hooks at $HOOK_DIR/"
echo "Test: stage a file containing an AWS-style key (AKIA followed by 16 caps/digits) — git commit should block."
