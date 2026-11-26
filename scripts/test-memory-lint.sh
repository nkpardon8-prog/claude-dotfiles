#!/usr/bin/env bash
# test-memory-lint.sh - fixture test for scripts/memory-lint.py.
# One case per check, plus a clean note; asserts exact counts and names, and that no note
# content (a canary string) ever reaches the output.
set -euo pipefail

LINT="$(cd "$(dirname "$0")" && pwd)/memory-lint.py"
CANARY="CANARY-7f3a9e-do-not-print"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL %s\n--- expected\n%s\n--- got\n%s\n' "$1" "$2" "$3"; fi; }

D="$T/memory"; mkdir -p "$D"
LONG="- [Long](clean.md) - $(printf 'x%.0s' $(seq 1 120))"
cat > "$D/MEMORY.md" <<EOF
# Memory Index $CANARY
- [Clean](clean.md) - fine
- [Old project](proj-old.md) - old
- [Old meta project](proj-meta-old.md) - old, metadata form
- [New project](proj-new.md) - recent
- [Gone](gone.md) - missing target
- [Web](https://example.com/x.md) - external, ignored
- [Archive](MEMORY-archive.md)
$LONG
EOF
printf -- '- [Archived](archived.md)\n' > "$D/MEMORY-archive.md"
printf -- '---\nname: clean\ntype: feedback\n---\n%s\n' "$CANARY" > "$D/clean.md"
printf -- '---\nname: old\ntype: project\n---\n%s\n' "$CANARY" > "$D/proj-old.md"
printf -- '---\nname: meta\nmetadata:\n  type: project\n---\n%s\n' "$CANARY" > "$D/proj-meta-old.md"
printf -- '---\nname: new\ntype: "project"\n---\n%s\n' "$CANARY" > "$D/proj-new.md"
printf -- '---\ntype: project\n---\n%s\n' "$CANARY" > "$D/archived.md"
printf -- '%s\n' "$CANARY" > "$D/orphan.md"
printf -- '%s\n' "$CANARY" > "$D/orphan.md.bak-2026"
touch -t 202501010000 "$D/proj-old.md" "$D/proj-meta-old.md"
touch "$D/archived.md"

OUT="$(python3 "$LINT" --dir "$D")"
LONG_LEN=${#LONG}
EXPECTED="== $D
missing-link: 1
  gone.md
orphan: 1
  orphan.md
index-size: 1
  MEMORY.md line 9 is $LONG_LEN chars (max 120)
stale-project: 2
  proj-meta-old.md (DAYS)
  proj-old.md (DAYS)"
check "fixture output" "$EXPECTED" "$(printf '%s\n' "$OUT" | sed -E 's/\([0-9]+ days\)/(DAYS)/')"
case "$OUT" in *"$CANARY"*) check "canary absent" "absent" "present";; *) check "canary absent" "absent" "absent";; esac

# Byte cap: a clean index over 17,000 bytes, short lines only.
B="$T/big"; mkdir -p "$B"
for i in $(seq 1 400); do printf -- '- [n](n.md) - %s line %03d padding text\n' "$CANARY" "$i"; done > "$B/MEMORY.md"
printf 'x\n' > "$B/n.md"
SIZE=$(wc -c < "$B/MEMORY.md" | tr -d ' ')
OUT2="$(python3 "$LINT" --dir "$B")"
check "byte cap" "index-size: 1
  MEMORY.md is $SIZE bytes (max 17000)" "$(printf '%s\n' "$OUT2" | sed -n '/^index-size/,/^stale/p' | sed '$d')"
case "$OUT2" in *"$CANARY"*) check "canary absent (big)" "absent" "present";; *) check "canary absent (big)" "absent" "absent";; esac

# Report-only: exit 0 even on a missing dir.
python3 "$LINT" --dir "$T/nope" >/dev/null; check "exit 0" "0" "$?"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
