#!/bin/bash
# End-to-end harness for the dotfiles-sync REVERT GUARD (scripts/lib/sync-revert-guard.sh).
#
# Run: bash scripts/hooks/test-sync-revert-guard.sh      (exit 0 = all pass, 1 = failure)
#
# Drives the REAL scripts/dotfiles-sync.sh on two sandboxed "Macs" (host-a, host-b) that share a
# bare remote, the way the fleet does. Each host has its own $HOME and clone; `hostname` and `gh`
# are PATH shims (the sync reads `hostname -s` for its commit subject and asks `gh` whether the
# target is private). Everything the sync and its generated git hooks execute is copied from THIS
# checkout, so the harness tests the code beside it, not the live ~/.claude-dotfiles.
#
# Incident it reproduces: auto-sync 5e15bea6 (2026-11-09, macbookair-m4) committed rdocker files
# built on copies that predated 4bac4e0c, a fix pulled from another machine, and deleted every
# line that fix added. HERMETIC in the same way as test-secret-scan.sh.

set -u
exec </dev/null

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0; FAIL=0
chk() { # chk <name> <got> <want>
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"
    else
        FAIL=$((FAIL + 1)); printf '  FAIL  %s   got=<%s> want=<%s>\n' "$1" "$2" "$3"
    fi
}

WORK=$(mktemp -d) || { echo "mktemp failed"; exit 1; }
WORK=$(cd "$WORK" && pwd -P)
cleanup() { chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap 'cleanup' EXIT
trap 'cleanup; exit 3' HUP INT TERM

# A run from inside a git hook inherits GIT_DIR / GIT_INDEX_FILE; never let the sandbox use them.
for _v in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$_v"; done
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

SHIM="$WORK/bin"; mkdir -p "$SHIM"
printf '#!/bin/sh\necho "$FAKE_HOST"\n' > "$SHIM/hostname"
printf '#!/bin/sh\necho true\n' > "$SHIM/gh"
chmod +x "$SHIM/hostname" "$SHIM/gh"

# --- fixture --------------------------------------------------------------------------------
git init -q --bare -b main "$WORK/remote.git"
SEED="$WORK/seed"; git clone -q "$WORK/remote.git" "$SEED" 2>/dev/null
for f in scripts/dotfiles-sync.sh scripts/lib/sync-revert-guard.sh scripts/lib/portable-timeout.sh \
         scripts/install-git-hooks.sh scripts/secret-scan.sh \
         scripts/lint-commands/lint-skill-size.sh scripts/lint-commands/lint-skill-contract.sh; do
    mkdir -p "$SEED/$(dirname "$f")"; cp -p "$REPO/$f" "$SEED/$f" || { echo "fixture: cannot copy $f"; exit 1; }
done
base_file() { # base_file <name>: the version both hosts start from
    printf '%s\n' '#!/usr/bin/perl' 'use strict;' '' "sub build_$1 {" '    my ($dir) = @_;' \
        '    my $status = run_install($dir);' '    return $status;' '}' '' '1;'
}
for t in t1 t2 t3 t4 t5 t6 t7 t8 t9 t10 t11; do base_file "$t" > "$SEED/$t.pl"; done
echo notes > "$SEED/notes.txt"
( cd "$SEED" && git checkout -q -b main 2>/dev/null; git add -A && git commit -qm "seed" && git push -q origin main ) \
    || { echo "fixture seed failed"; exit 1; }

mkhost() { mkdir -p "$WORK/$1/.claude"; git clone -q "$WORK/remote.git" "$WORK/$1/.claude-dotfiles" 2>/dev/null; }
mkhost host-a; mkhost host-b
A="$WORK/host-a/.claude-dotfiles"; B="$WORK/host-b/.claude-dotfiles"
MA="$WORK/host-a/.claude/.dotfiles-sync-paused"
QA="$WORK/host-a/.claude/.sync-quarantine"
ALLOW_A="$WORK/host-a/.claude/.dotfiles-sync-allow-revert"

# sync <host> [env...]: run the real sync script as that host; prints its exit code.
sync() {
    local h="$1"; shift
    git -C "$WORK/$h/.claude-dotfiles" rev-parse HEAD > "$WORK/$h.before"
    env "$@" HOME="$WORK/$h" FAKE_HOST="$h" PATH="$SHIM:$PATH" \
        bash "$WORK/$h/.claude-dotfiles/scripts/dotfiles-sync.sh" > "$WORK/$h.log" 2>&1
    echo $?
}
# hgit <host> <git args>: git in that host's clone with that host's $HOME. The generated hooks
# resolve "$HOME/.claude-dotfiles/...", so a bare `git push` here would run the REAL repo's
# scanner on a Mac and find none on Linux (caught by the Linux proof run, 2026-11-17).
hgit() { local h="$1"; shift; HOME="$WORK/$h" git -C "$WORK/$h/.claude-dotfiles" "$@"; }
pull() { hgit "$1" pull -q --ff-only 2>/dev/null; }
# commit_push <host> <message> [date]: a MANUAL commit (not an auto-sync), pushed; prints ok/failed.
commit_push() {
    local h="$1" m="$2" d="${3:-}"
    if [ -n "$d" ]; then
        GIT_AUTHOR_DATE="$d" GIT_COMMITTER_DATE="$d" hgit "$h" commit -qam "$m" --no-verify
    else
        hgit "$h" commit -qam "$m" --no-verify
    fi && hgit "$h" push -q origin main >/dev/null 2>&1 && echo ok || echo failed
}
kind() { sed -n 's/^kind: //p' "$MA" 2>/dev/null; }
reason() { sed -n 's/^reason: //p' "$MA" 2>/dev/null; }
# committed <path>: did A's last sync commit that path? (diff against the HEAD it started from)
committed() { git -C "$A" diff --name-only "$(cat "$WORK/host-a.before")" HEAD | grep -cxF "$1"; }
clean_vs_head() { git -C "$A" diff --quiet HEAD -- "$1" && echo yes || echo no; }
pushed() { [ "$(git -C "$A" rev-parse HEAD)" = "$(git --git-dir="$WORK/remote.git" rev-parse main)" ] && echo yes || echo no; }
reset_a() { rm -f "$MA"; }

# B's fix: four lines inserted into the sub (the shape of 4bac4e0c).
b_fix() {
    perl -0pi -e 's/(    my \$status = run_install\(\$dir\);\n)/$1    rebuild_local_links(\$dir) if has_local_links(\$dir);\n    warn "rebuilt local packages in \$dir\\n";\n    \$status ||= verify_links(\$dir);\n    record_link_state(\$dir, \$status);\n/' "$B/$1"
}

echo "== B commits a fix to every test file (auto-sync from host-b) =="
pull host-b
for t in t1 t2 t3 t4 t7 t8; do b_fix "$t.pl"; done
chk "host-b sync commits and pushes" "$(sync host-b)" "0"
chk "host-b commit subject names host-b" \
    "$(git -C "$B" log -1 --format=%s | grep -c ' from host-b$')" "1"
pull host-a
chk "host-a has B's fix after pulling" "$(grep -c rebuild_local_links "$A/t1.pl")" "1"

echo "== T1 incident, exact copy: A's agent copies the pre-fix file back (check a) =="
reset_a
base_file t1 > "$A/t1.pl"; echo "a's unrelated edit" >> "$A/notes.txt"
B_FIX=$(git -C "$B" rev-parse --short=8 HEAD)
chk "sync still succeeds (the rest commits and pushes)" "$(sync host-a)" "0"
chk "the stale t1.pl is NOT in A's commit" "$(committed t1.pl)" "0"
chk "the unrelated edit IS in A's commit" "$(committed notes.txt)" "1"
chk "A's commit was pushed" "$(pushed)" "yes"
chk "t1.pl restored to HEAD (B's fix intact)" "$(clean_vs_head t1.pl)" "yes"
chk "pause marker kind is revert" "$(kind)" "revert"
chk "pause reason names the file" "$(reason | grep -c 't1.pl')" "1"
chk "pause reason names the commit it would undo" "$(reason | grep -c "undoes $B_FIX")" "1"
_q=$(find "$QA" -path '*/t1.pl' | head -1)
chk "refused copy saved outside the repo, byte-for-byte" "$(cmp -s "$_q" <(base_file t1) && echo same)" "same"
chk "REASONS.txt records check (a) and the override" \
    "$(grep -c -e '(a) working copy is byte-identical' -e 'dotfiles-sync-allow-revert' "$(dirname "$_q")/REASONS.txt")" "2"
chk "the per-prompt notice explains the revert pause" \
    "$(HOME="$WORK/host-a" bash "$REPO/scripts/hooks/dotfiles-sync-pause-notice.sh" | grep -c 'REVERT GUARD')" "1"
echo x >> "$A/notes.txt"
chk "while paused, the next sync does nothing" "$(sync host-a):$(committed notes.txt)" "0:0"

echo "== T2 incident, real shape: stale pre-fix copy PLUS A's own new work (check b) =="
reset_a
{ base_file t2; printf '%s\n' 'sub a_new_feature { return fleet_schedule(@_); }'; } > "$A/t2.pl"
chk "sync succeeds" "$(sync host-a)" "0"
chk "t2.pl is not committed" "$(committed t2.pl)" "0"
chk "pause kind revert, check (b) in REASONS.txt" \
    "$(kind):$(grep -c '(b) working copy deletes 4 of the 4' "$(find "$QA" -path '*/t2.pl' -exec dirname {} \; | head -1)/REASONS.txt")" "revert:1"
chk "the pending notes.txt edit was committed alongside" "$(committed notes.txt)" "1"

echo "== T2 override: allow file, one use =="
reset_a
cp "$(find "$QA" -path '*/t2.pl' | head -1)" "$A/t2.pl"
echo t2.pl > "$ALLOW_A"
chk "sync commits the allowed revert" "$(sync host-a):$(committed t2.pl)" "0:1"
chk "no pause marker" "$([ -f "$MA" ] && echo present || echo absent)" "absent"
chk "allow file consumed (deleted when empty)" "$([ -f "$ALLOW_A" ] && echo present || echo absent)" "absent"

echo "== T3 partial revert: A deletes 3 of the 4 lines B just added =="
reset_a
grep -v -e 'warn "rebuilt' -e verify_links -e record_link_state "$A/t3.pl" > "$WORK/t3" && cat "$WORK/t3" > "$A/t3.pl"
chk "sync succeeds" "$(sync host-a)" "0"
chk "t3.pl refused (not committed, restored)" "$(committed t3.pl):$(clean_vs_head t3.pl)" "0:yes"
chk "pause kind revert" "$(kind)" "revert"

echo "== T4 legitimate edit: A changes other lines =="
reset_a
perl -pi -e 's{return \$status;}{return \$status || 0;}' "$A/t4.pl"
chk "sync commits it" "$(sync host-a):$(committed t4.pl)" "0:1"
chk "no pause marker" "$([ -f "$MA" ] && echo present || echo absent)" "absent"

echo "== T4b ordinary edit of ONE of B's four lines (below the 50% bar) =="
reset_a
perl -pi -e 's/warn "rebuilt local packages/warn "rebuilt local file: packages/' "$A/t4.pl"
chk "sync commits it" "$(sync host-a):$(committed t4.pl)" "0:1"
chk "no pause marker" "$([ -f "$MA" ] && echo present || echo absent)" "absent"

echo "== T5 A deletes its OWN recent lines (auto-sync from host-a) =="
reset_a
perl -pi -e 's/(    return \$status;)/    log_status(\$status, "build finished");\n    notify_owner(\$status, "build finished");\n$1/' "$A/t5.pl"
chk "A's addition commits" "$(sync host-a):$(committed t5.pl)" "0:1"
base_file t5 > "$A/t5.pl"   # byte-identical to the pre-add version: (a) and (b) both see it
chk "A's own removal commits" "$(sync host-a):$(committed t5.pl)" "0:1"
chk "no pause marker" "$([ -f "$MA" ] && echo present || echo absent)" "absent"

echo "== T6 A deletes lines from its own MANUAL commit (recognised via the reflog) =="
reset_a
perl -pi -e 's/(    return \$status;)/    log_status(\$status, "manual commit line");\n$1/' "$A/t6.pl"
chk "A's manual commit pushed" "$(commit_push host-a "t6: manual commit on host-a")" "ok"
base_file t6 > "$A/t6.pl"
chk "A's removal of its own manual lines commits" "$(sync host-a):$(committed t6.pl)" "0:1"
chk "no pause marker" "$([ -f "$MA" ] && echo present || echo absent)" "absent"

echo "== T7 env override: DOTFILES_SYNC_ALLOW_REVERT =="
reset_a
base_file t7 > "$A/t7.pl"
chk "sync commits the allowed exact revert" "$(sync host-a DOTFILES_SYNC_ALLOW_REVERT=t0.pl:t7.pl):$(committed t7.pl)" "0:1"
chk "no pause marker" "$([ -f "$MA" ] && echo present || echo absent)" "absent"

echo "== T8 a MANUAL (non-auto-sync) commit from B counts as another host =="
reset_a; pull host-b
perl -pi -e 's/(    return \$status;)/    audit_trail(\$dir, "manual fix from host b");\n    audit_flush(\$dir, "manual fix from host b");\n$1/' "$B/t9.pl"
chk "B's manual commit pushed" "$(commit_push host-b "t9: manual fix on host-b")" "ok"
pull host-a
chk "A pulled B's manual fix" "$(grep -c audit_trail "$A/t9.pl")" "1"
grep -v audit_ "$A/t9.pl" > "$WORK/t9"; cat "$WORK/t9" > "$A/t9.pl"; echo "# a's tweak" >> "$A/t9.pl"
chk "sync succeeds" "$(sync host-a)" "0"
chk "t9.pl refused (not committed, restored)" "$(committed t9.pl):$(clean_vs_head t9.pl):$(kind)" "0:yes:revert"

echo "== T9 windows: B's lines from 20 days ago may be removed (not exact) =="
reset_a; pull host-b
perl -pi -e 's/(    return \$status;)/    legacy_shim(\$dir, "twenty days old");\n$1/' "$B/t10.pl"
_old=$(( $(date +%s) - 20 * 86400 ))
chk "B's 20-day-old commit pushed" "$(commit_push host-b "auto-sync: old from host-b" "@$_old")" "ok"
pull host-a
chk "A pulled it" "$(grep -c legacy_shim "$A/t10.pl")" "1"
grep -v legacy_shim "$A/t10.pl" > "$WORK/t10"; echo "# a's tweak" >> "$WORK/t10"; cat "$WORK/t10" > "$A/t10.pl"
chk "a 20-day-old foreign line is outside the 14-day partial window" "$(sync host-a):$(committed t10.pl)" "0:1"

echo "== T10 fail closed: guard missing -> nothing committed =="
reset_a
_head=$(git -C "$A" rev-parse HEAD)
mv "$A/scripts/lib/sync-revert-guard.sh" "$WORK/guard.bak"
echo "edit while guard missing" >> "$A/t11.pl"
chk "sync exits 12" "$(sync host-a)" "12"
chk "HEAD unchanged" "$(git -C "$A" rev-parse HEAD)" "$_head"
chk "pause marker names the missing guard" "$(reason | grep -c 'revert guard missing')" "1"
mv "$WORK/guard.bak" "$A/scripts/lib/sync-revert-guard.sh"
reset_a
chk "with the guard back, the edit commits" "$(sync host-a):$(committed t11.pl)" "0:1"

echo "== T11 a refused path is unstaged even if rewritten before git add -A =="
# Structural: the race window (agent rewrites the file between guard and add) cannot be timed
# from outside, so pin the mechanism that closes it.
chk "sync unstages every refused path after git add -A" \
    "$(grep -c 'git reset -q HEAD -- "\$_rp"' "$REPO/scripts/dotfiles-sync.sh")" "1"
_add_ln=$(grep -n 'if git add -A; then _add_ok=1' "$REPO/scripts/dotfiles-sync.sh" | cut -d: -f1)
_rst_ln=$(grep -n 'git reset -q HEAD -- "\$_rp"' "$REPO/scripts/dotfiles-sync.sh" | cut -d: -f1)
_cmt_ln=$(grep -n 'git commit -m "auto-sync:' "$REPO/scripts/dotfiles-sync.sh" | cut -d: -f1)
chk "unstage sits between git add -A and git commit" \
    "$([ "$_add_ln" -lt "$_rst_ln" ] && [ "$_rst_ln" -lt "$_cmt_ln" ] && echo yes)" "yes"

echo
echo "---- $PASS passed, $FAIL failed ----"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
