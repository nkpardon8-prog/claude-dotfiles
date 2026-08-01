#!/bin/bash
# test-handoff-smoke-check.sh - fixture test for handoff-smoke-check.sh.
# True-positive (missing file -> WARN appended), true-negative (prose with
# periods, existing files -> no section), idempotency (re-run replaces).
set -u
SCRIPT="$HOME/.claude-dotfiles/scripts/handoff-smoke-check.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/smoke-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass+1)); else echo "FAIL: $1 (want '$2' got '$3')" >&2; fail=$((fail+1)); fi; }

mkdir -p "$TMP/repo/server/src"
printf 'x' > "$TMP/repo/server/src/real.ts"

# Fixture 1: one real path, one missing path, prose with a period (no slash - ignored)
cat > "$TMP/repo/h.md" <<'EOF'
## Active Task
Working on the thing. This sentence v2.1 has a period but no path.

## Next Action
Edit server/src/real.ts:42 then create server/src/ghost.ts per the plan.

## Build Plan
- [done] step one at server/src/real.ts
- [in progress] wire up client/src/missing.tsx
- [pending] later work in totally/fake/file.md

<!-- END-OF-HANDOFF schema=v1 sid=test nonce=abc -->
EOF

bash "$SCRIPT" "$TMP/repo/h.md" "$TMP/repo" 2>/dev/null
rc=$?
check "always exits 0" 0 "$rc"
grep -q "## Smoke Check" "$TMP/repo/h.md"; check "section appended on miss" 0 $?
grep -q "ghost.ts" "$TMP/repo/h.md"; check "missing Next Action path warned" 0 $?
grep -q "missing.tsx" "$TMP/repo/h.md"; check "in-progress missing path warned" 0 $?
# pending lines are out of scope - they must not produce a WARN
n=$(grep -c "WARN.*fake/file.md" "$TMP/repo/h.md"); check "pending line produces no WARN" 0 "$n"
n=$(grep -c "WARN.*real.ts" "$TMP/repo/h.md"); check "existing path produces no WARN" 0 "$n"
# marker still last line
tail -1 "$TMP/repo/h.md" | grep -q "END-OF-HANDOFF"; check "marker still terminal" 0 $?

# Fixture 2: idempotency - re-run must not duplicate the section
bash "$SCRIPT" "$TMP/repo/h.md" "$TMP/repo" 2>/dev/null
n=$(grep -c "^## Smoke Check" "$TMP/repo/h.md"); check "idempotent (one section after re-run)" 1 "$n"

# Fixture 3: clean handoff gets NO section
cat > "$TMP/repo/clean.md" <<'EOF'
## Next Action
Edit server/src/real.ts:1 now.

<!-- END-OF-HANDOFF schema=v1 sid=test nonce=abc -->
EOF
bash "$SCRIPT" "$TMP/repo/clean.md" "$TMP/repo" 2>/dev/null
n=$(grep -c "^## Smoke Check" "$TMP/repo/clean.md"); check "clean handoff untouched" 0 "$n"

echo "test-handoff-smoke-check: $pass passed, $fail failed"
exit $([ $fail -eq 0 ] && echo 0 || echo 1)
