#!/usr/bin/env bash
# test-memory-lint.sh - fixture test for scripts/memory-lint.py.
# Cases per check plus a clean note; asserts exact counts and names, and that no note or index
# content (canary strings, including one inside a link destination) ever reaches the output.
set -euo pipefail

LINT="$(cd "$(dirname "$0")" && pwd)/memory-lint.py"
CANARY="CANARY-7f3a9e-do-not-print"
T="$(mktemp -d)"
trap 'chmod -R u+rw "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n--- expected\n%s\n--- got\n%s\n' "$1" "$2" "$3"; fi; }
no_canary() { case "$2" in *CANARY*) check "$1: no content echoed" "absent" "present";; *) check "$1: no content echoed" "absent" "absent";; esac; }
age() { python3 -c 'import os,sys,time; t=time.time()-float(sys.argv[1]); [os.utime(p,(t,t)) for p in sys.argv[2:]]' "$@"; }

D="$T/memory"; mkdir -p "$D/sub" "$D/adir"
LONG="- [Long](clean.md) - $(printf 'x%.0s' $(seq 1 120))"
cat > "$D/MEMORY.md" <<EOF
# Memory Index $CANARY
- [Clean](clean.md) - fine
- [Old project](proj-old.md) - old
- [Old meta project](proj-meta-old.md) - old, metadata form
- [New project](proj-new.md) - recent
- [Gone]($CANARY-gone.md) - missing target, canary in the destination
- [Web](https://example.com/x.md) - external, ignored
- [Archive](MEMORY-archive.md)
$LONG
- [Sub](sub/a.md) - broken: sub/a.md does not exist, root a.md stays an orphan
- [Dir](adir) - a directory is not a note
- [Spaced](<my note.md>) - angle-bracket destination
- Example only: \`[x]($CANARY-code.md)\` and a bare ]($CANARY-bare) fragment
- [Commented](proj-comment.md) - type with an inline comment
- [Nested](proj-nested.md) - type under a deeper mapping
- [Edge](proj-edge.md) - 60 days and one hour old
EOF
printf -- '- [Archived](archived.md)\n' > "$D/MEMORY-archive.md"
printf -- '---\nname: clean\ntype: feedback\n---\n%s\n' "$CANARY" > "$D/clean.md"
printf -- '---\nname: old\ntype: project\n---\n%s\n' "$CANARY" > "$D/proj-old.md"
printf -- '---\nname: meta\nmetadata:\n  type: project\n---\n%s\n' "$CANARY" > "$D/proj-meta-old.md"
printf -- '---\nname: new\ntype: "project"\n---\n%s\n' "$CANARY" > "$D/proj-new.md"
printf -- '---\ntype: project # tracked in hub\n---\n%s\n' "$CANARY" > "$D/proj-comment.md"
printf -- '---\nmetadata:\n  extra:\n    type: project\n---\n%s\n' "$CANARY" > "$D/proj-nested.md"
printf -- '---\ntype: project\n---\n%s\n' "$CANARY" > "$D/proj-edge.md"
printf -- '---\ntype: project\n---\n%s\n' "$CANARY" > "$D/archived.md"
printf -- '%s\n' "$CANARY" > "$D/my note.md"
printf -- '%s\n' "$CANARY" > "$D/a.md"
printf -- '%s\n' "$CANARY" > "$D/orphan.md"
printf -- '%s\n' "$CANARY" > "$D/orphan.md.bak-2026"
age $((90*86400)) "$D/proj-old.md" "$D/proj-meta-old.md" "$D/proj-comment.md" "$D/proj-nested.md"
age $((60*86400+3600)) "$D/proj-edge.md"

OUT="$(python3 "$LINT" --dir "$D")"
EXPECTED="== $D
missing-link: 3
  MEMORY.md line 6
  MEMORY.md line 10
  MEMORY.md line 11
orphan: 2
  a.md
  orphan.md
index-size: 1
  MEMORY.md line 9 is ${#LONG} chars (max 120)
stale-project: 4
  proj-comment.md (DAYS)
  proj-edge.md (60 days)
  proj-meta-old.md (DAYS)
  proj-old.md (DAYS)"
check "fixture output" "$EXPECTED" "$(printf '%s\n' "$OUT" | sed -E 's/\((9[0-9]) days\)/(DAYS)/')"
no_canary "fixture" "$OUT"

# Byte cap: a clean index over 17,000 bytes, short lines only.
B="$T/big"; mkdir -p "$B"
for i in $(seq 1 400); do printf -- '- [n](n.md) - %s line %03d padding text\n' "$CANARY" "$i"; done > "$B/MEMORY.md"
printf 'x\n' > "$B/n.md"
SIZE=$(wc -c < "$B/MEMORY.md" | tr -d ' ')
OUT2="$(python3 "$LINT" --dir "$B")"
check "byte cap" "index-size: 1
  MEMORY.md is $SIZE bytes (max 17000)" "$(printf '%s\n' "$OUT2" | sed -n '/^index-size/,/^stale/p' | sed '$d')"
no_canary "big" "$OUT2"

# Unreadable index: reported incomplete, the next dir is still scanned, exit 0.
U="$T/unreadable"; mkdir -p "$U"; printf -- '- [n](n.md)\n' > "$U/MEMORY.md"; chmod 000 "$U/MEMORY.md"
set +e; OUT3="$(python3 "$LINT" --dir "$U" --dir "$B")"; rc=$?; set -e
check "unreadable: exit 0" "0" "$rc"
check "unreadable: incomplete" "  incomplete: PermissionError reading MEMORY.md" "$(printf '%s\n' "$OUT3" | sed -n 2p)"
check "unreadable: next dir scanned" "1" "$(printf '%s\n' "$OUT3" | grep -c "^== $B$")"

# Report-only: exit 0 even on a missing dir.
set +e; python3 "$LINT" --dir "$T/nope" >/dev/null; rc=$?; set -e
check "missing dir: exit 0" "0" "$rc"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
