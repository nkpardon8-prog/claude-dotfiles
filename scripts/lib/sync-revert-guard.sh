#!/bin/bash
# sync-revert-guard.sh - refuse to auto-commit a file that silently reverts ANOTHER host's work.
#
# Run by scripts/dotfiles-sync.sh from the repo root, BEFORE `git add -A`. Invoked through
# `bash` (never the exec bit), like secret-scan.sh.
#
# INCIDENT (2026-11-09). Commit 4bac4e0c (made on another machine, pulled onto the MacBook Air
# by `pull --ff-only` on 11-07) added 77 lines to scripts/rdocker/rr_runner.pl and 101 to
# scripts/rdocker/tests/test_runner.py. Two days later an agent on the Air copied in rdocker work
# that had been built on the PRE-4bac4e0c copies of those files; auto-sync 5e15bea6 committed it
# and every line 4bac4e0c added was gone. Not an exact old blob - the Air's own 60 new lines rode
# on top - so it looked like an ordinary edit. Nobody noticed for 6 days, until worker builds broke.
#
# For each tracked file the commit would MODIFY (working tree vs HEAD, status M):
#   (a) EXACT REVERT   - the working blob equals the file's blob from BEFORE a commit in the last
#                        30 days (max 20 commits), and that span includes another host's commit.
#   (b) PARTIAL REVERT - the working copy net-deletes at least half of the lines another host's
#                        commit (last 14 days, max 20 commits) added and HEAD still has. Text files
#                        under 2 MB only; lines are compared trimmed, and trivial ones (`fi`, `}`,
#                        under 6 characters or no letter/digit) are ignored.
# MEASURED (2026-11-17, replaying all 109 commits the Air made in the 12 days to 11-16 through this
# guard with the Air's own reflog): "refuse if ANY such line is deleted" also refused 4 ordinary doc
# rewrites (commands/docker.md x3, commands/load-creds.md) - a halt every ~3 days. They removed 8-18%
# of the foreign commit's lines still in HEAD; the incident files removed 100%, 100% and 99% (a stale
# copy predates the whole commit, so it drops all of it). Hence (b) needs >= PARTIAL_MIN_PCT (50%).
# At 50% the replay refuses exactly the three 5e15bea6 files (rr_runner.pl, test_runner.py and
# rd_run.py, whose 1-line 4bac4e0c message fix was also undone) and nothing else.
#
# A refused file is copied to $SRG_QUAR_ROOT/<stamp>/<path> (with REASONS.txt) and only THEN
# restored with `git checkout HEAD -- <path>`, so nothing is lost. The rest commits as usual.
#
# WHO IS "ANOTHER HOST". An `auto-sync: ... from <host>` subject names its host. Any other commit
# is THIS machine's only if this clone's reflog shows it being CREATED here (commit / cherry-pick /
# revert / rebase pick); a commit that arrived by pull, merge or fast-forward is foreign. The
# reflog is the one local record of authorship: author and committer name are the same person on
# every Mac, and this host makes most of its commits by hand (156 of 207 reflog entries on the Air
# were local commits), so "every manual commit is foreign" would refuse ordinary self-iteration.
#
# OVERRIDE (intentional revert): list the repo-relative path, one per line, in $SRG_ALLOW_FILE,
# or colon-separated in $DOTFILES_SYNC_ALLOW_REVERT. A file-listed path is consumed the first
# time that path is part of a commit (one use), and the file is deleted when it empties.
#
# Env:    SRG_HOST (required)   SRG_QUAR_ROOT (required)   SRG_ALLOW_FILE   DOTFILES_SYNC_ALLOW_REVERT
# stdout: one line per refused path: <path>\t<check a|b>\t<reverted sha>\t<quarantine dir>
# exit:   0 = ran (zero or more files refused); anything else = could not run - the caller must
#         NOT commit (fail closed). A file is never restored unless its copy was saved first.

set -u
set -o pipefail
export LC_ALL=C

: "${SRG_HOST:?SRG_HOST is required}"
: "${SRG_QUAR_ROOT:?SRG_QUAR_ROOT is required}"
SRG_ALLOW_FILE="${SRG_ALLOW_FILE:-}"

EXACT_DAYS=30
PARTIAL_DAYS=14
MAX_COMMITS=20
MAX_BYTES=$((2 * 1024 * 1024))
PARTIAL_MIN_PCT=50   # share of a foreign commit's surviving lines that must go - see MEASURED above

die() { echo "sync-revert-guard: $*" >&2; exit 2; }

git rev-parse --verify --quiet HEAD >/dev/null || exit 0   # unborn branch: nothing to revert

T=$(mktemp -d "${TMPDIR:-/tmp}/srg.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$T"' EXIT

# --- modified tracked files (NUL-safe) -------------------------------------------------------
git diff -z --name-only --no-renames --diff-filter=M HEAD -- > "$T/modified" || die "git diff HEAD failed"
[ -s "$T/modified" ] || exit 0

# --- override list ---------------------------------------------------------------------------
: > "$T/allow"
if [ -n "${DOTFILES_SYNC_ALLOW_REVERT:-}" ]; then
    printf '%s\n' "$DOTFILES_SYNC_ALLOW_REVERT" | tr ':' '\n' >> "$T/allow"
fi
if [ -n "$SRG_ALLOW_FILE" ] && [ -f "$SRG_ALLOW_FILE" ]; then
    cat "$SRG_ALLOW_FILE" >> "$T/allow"
fi
is_allowed() { grep -qxF -- "$1" "$T/allow"; }
: > "$T/consumed"

# --- this machine's own commits (from the reflog), built once --------------------------------
_gcd=$(git rev-parse --git-common-dir) || die "cannot locate the git dir"
{
    find "$_gcd/logs" -type f 2>/dev/null
    find "$_gcd/worktrees" -path '*/logs/*' -type f 2>/dev/null
} | while IFS= read -r _lf; do
    awk -F'\t' '{
        split($1, a, " "); m = $2
        if (m ~ /^(commit|cherry-pick|revert)/ || m ~ /\((pick|reword|edit|squash|fixup)\)/) print a[2]
    }' "$_lf"
done | sort -u > "$T/own"

# is_own <sha> <subject>
is_own() {
    case "$2" in
        "auto-sync: "*" from "*) [ "${2##* from }" = "$SRG_HOST" ]; return ;;
    esac
    grep -qxF -- "$1" "$T/own"
}
# who <subject> - a human label for the commit's origin
who() {
    case "$1" in
        "auto-sync: "*" from "*) printf 'host %s' "${1##* from }" ;;
        *) printf 'a commit not created on this machine' ;;
    esac
}

# diff_lines: hunk body of a -U0 diff on stdin -> significant trimmed +/- lines, as <sign>\t<line>.
# Header lines are skipped by position (before the first @@), never by pattern: a deleted
# content line "-- x" renders as "--- x" and must not be mistaken for a header.
diff_lines() {
    awk '
        /^@@/ { body = 1; next }
        !body { next }
        /^[+-]/ {
            s = substr($0, 1, 1); k = substr($0, 2)
            gsub(/^[ \t]+|[ \t\r]+$/, "", k)
            # Trivial lines (fi, }, done, blank) recur everywhere and prove nothing.
            if (length(k) >= 6 && k ~ /[[:alnum:]]/) print s "\t" k
        }'
}

QDIR=""
now=$(date +%s)

# refuse <path> <check> <sha> <detail>
refuse() {
    local f="$1" check="$2" sha="$3" detail="$4"
    if [ -z "$QDIR" ]; then
        QDIR="$SRG_QUAR_ROOT/$(date +%Y%m%d-%H%M%S)-$$"
        mkdir -p "$QDIR" || die "cannot create quarantine dir $QDIR - refusing to touch $f"
    fi
    mkdir -p "$QDIR/$(dirname -- "$f")" || die "cannot create quarantine subdir for $f"
    # SAVE FIRST. If the copy fails the file is left exactly as it was and the run fails closed.
    cp -p -- "$f" "$QDIR/$f" || die "could not save $f to quarantine - left untouched, nothing committed"
    {
        printf '%s\n' "FILE:     $f"
        printf '%s\n' "CHECK:    ($check) $detail"
        printf '%s\n' "REVERTED: $sha  ($(git log -1 --format='%ad %s' --date=iso "$sha" 2>/dev/null | cut -c1-140))"
        printf '%s\n' "HOST:     $SRG_HOST   at $(date '+%Y-%m-%d %H:%M:%S')"
        printf '%s\n' "SAVED:    $QDIR/$f   (this is the working copy that was refused)"
        printf '%s\n' "If this revert was INTENDED, put it back and allow it once:"
        printf '%s\n' "  echo '$f' >> ${SRG_ALLOW_FILE:-~/.claude/.dotfiles-sync-allow-revert}"
        printf '%s\n' "  cp '$QDIR/$f' '$PWD/$f'"
        printf '%s\n' "Otherwise merge your intended edits onto the current file by hand. Then clear the pause marker."
        printf '\n'
    } >> "$QDIR/REASONS.txt" || die "could not write $QDIR/REASONS.txt - $f left untouched"
    git checkout HEAD -- "$f" || die "saved $f to $QDIR but could not restore it from HEAD"
    printf '%s\t%s\t%s\t%s\n' "$f" "$check" "$sha" "$QDIR"
}

while IFS= read -r -d '' f <&3; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    if is_allowed "$f"; then
        printf '%s\n' "$f" >> "$T/consumed"
        allowed=1
    else
        allowed=0
    fi

    # One history read per file: subject, time and before/after blobs for each commit.
    if ! git log --no-merges --no-renames --since="$EXACT_DAYS.days" -n "$MAX_COMMITS" \
            --no-abbrev --raw --format=$'\001%H\t%ct\t%s' -- "$f" > "$T/log"; then
        die "git log failed for $f - cannot prove it is not a revert"
    fi
    awk -F'\t' '
        /^\001/ { if (sha != "") print sha "\t" ct "\t" ob "\t" subj; sha = substr($1, 2); ct = $2; subj = $3; ob = ""; next }
        /^:/    { split($1, r, " "); ob = r[3] }
        END     { if (sha != "") print sha "\t" ct "\t" ob "\t" subj }
    ' "$T/log" > "$T/commits"
    [ -s "$T/commits" ] || continue

    hit_check=""; hit_sha=""; hit_detail=""

    # (a) EXACT REVERT: working blob == the blob before commit i, and commits 0..i include a
    #     foreign one. A revert of nothing but this host's own commits is a self-undo - allowed.
    wb=$(git hash-object -- "$f") || die "git hash-object failed for $f"
    first_foreign=""
    while IFS=$'\t' read -r sha ct ob subj <&4; do
        if [ -z "$first_foreign" ] && ! is_own "$sha" "$subj"; then first_foreign="$sha"; fi
        if [ "$ob" = "$wb" ]; then
            if [ -n "$first_foreign" ]; then
                hit_check=a; hit_sha="$first_foreign"
                hit_detail="working copy is byte-identical to the version before ${sha:0:8}, undoing ${first_foreign:0:8} ($(who "$(git log -1 --format=%s "$first_foreign")"))"
            fi
            break
        fi
    done 4< "$T/commits"

    # (b) PARTIAL REVERT: net-deleted lines vs lines a foreign commit added in the window.
    if [ -z "$hit_check" ]; then
        size=$(wc -c < "$f" | tr -d ' ')
        numstat=$(git diff --numstat HEAD -- "$f" | head -1)
        if [ "${size:-0}" -lt "$MAX_BYTES" ] && [ "${numstat%%$'\t'*}" != "-" ]; then
            # Net deletion: a line removed AND re-added (a move, a reindent) is not a deletion.
            git diff --no-color --no-ext-diff -U0 HEAD -- "$f" | diff_lines | awk -F'\t' '
                { k = substr($0, 3); if ($1 == "-") n[k]++; else n[k]-- }
                END { for (k in n) if (n[k] > 0) print k }' > "$T/deleted"
            if [ -s "$T/deleted" ]; then
                # Lines of the HEAD version, same normalisation: the denominator below.
                git cat-file -p "HEAD:$f" | awk '{ k = $0; gsub(/^[ \t]+|[ \t\r]+$/, "", k)
                    if (length(k) >= 6 && k ~ /[[:alnum:]]/) print k }' | sort -u > "$T/head" \
                    || die "cannot read HEAD:$f"
                cutoff=$((now - PARTIAL_DAYS * 86400))
                while IFS=$'\t' read -r sha ct ob subj <&4; do
                    [ "$ct" -ge "$cutoff" ] || continue
                    is_own "$sha" "$subj" && continue
                    git show --format= --no-color --no-ext-diff --no-renames -U0 "$sha" -- "$f" \
                        | diff_lines | awk -F'\t' '$1 == "+" { print substr($0, 3) }' | sort -u > "$T/added" \
                        || die "git show $sha failed for $f"
                    [ -s "$T/added" ] || continue
                    # live: that commit's lines still present in HEAD; n: how many of them this
                    # working copy deletes. A stale copy predates the whole commit, so it drops
                    # (nearly) all of them; an edit rewrites a few.
                    live=$(grep -cxF -f "$T/added" "$T/head")
                    n=$(grep -cxF -f "$T/added" "$T/deleted")
                    if [ "${live:-0}" -gt 0 ] && [ "${n:-0}" -gt 0 ] && [ $((n * 100)) -ge $((live * PARTIAL_MIN_PCT)) ]; then
                        hit_check=b; hit_sha="$sha"
                        ex=$(grep -xF -f "$T/added" "$T/deleted" | head -1 | cut -c1-80)
                        hit_detail="working copy deletes $n of the $live surviving line(s) added by ${sha:0:8} ($(who "$subj")), e.g. \"$ex\""
                        break
                    fi
                done 4< "$T/commits"
            fi
        fi
    fi

    [ -n "$hit_check" ] || continue
    if [ "$allowed" -eq 1 ]; then
        echo "sync-revert-guard: ALLOWED by override - $f: $hit_detail" >&2
        continue
    fi
    refuse "$f" "$hit_check" "$hit_sha" "$hit_detail"
done 3< "$T/modified"

# One use: drop every allow-file entry whose path was part of this commit.
if [ -n "$SRG_ALLOW_FILE" ] && [ -f "$SRG_ALLOW_FILE" ] && [ -s "$T/consumed" ]; then
    grep -vxF -f "$T/consumed" "$SRG_ALLOW_FILE" > "$T/allow.new" || true
    if grep -q '[^[:space:]]' "$T/allow.new"; then
        cat "$T/allow.new" > "$SRG_ALLOW_FILE.tmp.$$" && mv -f "$SRG_ALLOW_FILE.tmp.$$" "$SRG_ALLOW_FILE"
    else
        rm -f "$SRG_ALLOW_FILE"
    fi
fi
exit 0
