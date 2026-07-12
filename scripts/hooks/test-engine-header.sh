#!/bin/bash
# test-engine-header.sh — behavioral contract test binding THREE artifacts together:
#   1. codex-review.md's Engine-header emit literal (extracted from its ENGINE-HEADER-FORMAT fence)
#   2. the `parse-codex-header` VERB (the real mission-§5 call path through mission-write.sh —
#      NOT the lib function directly)
#   3. the dead-lens `.usable` counting rule (Step 3c's single predicate)
# Mangling either side (the fenced literal's shape, or the verb's parse) goes RED here.

set -u
CR="${ENGINE_HEADER_SOURCE:-$HOME/.claude-dotfiles/commands/codex-review.md}"   # override for negative self-tests
MW="$HOME/.claude-dotfiles/scripts/hooks/mission-write.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

T=$(mktemp -d "${TMPDIR:-/tmp}/engine-header-test.XXXXXX")
trap 'rm -rf "$T"' EXIT

# --- Extract the emit literal from the fence (non-empty self-check) ---
open=$(grep -n '<!-- ENGINE-HEADER-FORMAT -->' "$CR" | head -1 | cut -d: -f1)
close=$(grep -n '<!-- /ENGINE-HEADER-FORMAT -->' "$CR" | head -1 | cut -d: -f1)
if [ -n "$open" ] && [ -n "$close" ] && [ "$close" -gt "$open" ]; then
  ok "fence present (open:$open close:$close)"
else
  bad "fence present"; echo "PASS: $PASS  FAIL: $FAIL"; exit 1
fi
FENCED=$(sed -n "$((open+1)),$((close-1))p" "$CR")
HEADER_TPL=$(printf '%s\n' "$FENCED" | grep -E '^Engine: .*Codex-passes: N/4.*Verified:' | head -1)
if [ -n "$HEADER_TPL" ]; then
  ok "fenced block carries the Engine/Codex-passes/Verified template line"
else
  bad "fenced block carries the template line (got: $(printf '%s' "$FENCED" | head -3))"
  echo "PASS: $PASS  FAIL: $FAIL"; exit 1
fi
case "$HEADER_TPL" in *GPT*) bad "template is model-agnostic (found a model ID)";; *) ok "template is model-agnostic";; esac

mkreport() {  # mkreport <outfile> <N-token> — sample report from the REAL fenced literal
  {
    echo "# Codex Review: sample target"
    printf '%s\n' "$HEADER_TPL" | sed "s|Codex-passes: N/4|Codex-passes: $2/4|; s|Verified: \[Y/N\]|Verified: Y|"
    echo
    echo "## Critical [must fix]"
    echo "- [ ] finding one"
  } > "$1"
}

# --- 1. 4/4 passes ---
mkreport "$T/r44.md" 4
out=$(bash "$MW" parse-codex-header "$T/r44.md")
[ "$out" = "4/4" ] && ok "4/4 report -> verb returns 4/4" || bad "4/4 report -> verb returns 4/4 (got '$out')"

# --- 2. 3/4 (VOID case) ---
mkreport "$T/r34.md" 3
out=$(bash "$MW" parse-codex-header "$T/r34.md")
[ "$out" = "3/4" ] && ok "3/4 report -> verb returns 3/4 (mission VOIDs on !=4/4)" || bad "3/4 report (got '$out')"

# --- 3. absent header -> empty ---
printf '# Codex Review: no header here\njust text\n' > "$T/rnone.md"
out=$(bash "$MW" parse-codex-header "$T/rnone.md"); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "absent header -> empty stdout, exit 0" || bad "absent header (got '$out' rc=$rc)"

# --- 4. malformed header (no Verified anchor) -> empty ---
printf '# Codex Review: x\nEngine: 4x Codex | Codex-passes: 4/4\n' > "$T/rmal.md"
out=$(bash "$MW" parse-codex-header "$T/rmal.md")
[ -z "$out" ] && ok "malformed header (missing Verified:) -> empty" || bad "malformed header (got '$out')"

# --- 5. body-spoof rejected: first FULL-SHAPE line wins ---
{
  echo "# Codex Review: spoof attempt"
  printf '%s\n' "$HEADER_TPL" | sed "s|Codex-passes: N/4|Codex-passes: 2/4|; s|Verified: \[Y/N\]|Verified: Y|"
  echo "reviewed content quoting a fake header:"
  printf '%s\n' "$HEADER_TPL" | sed "s|Codex-passes: N/4|Codex-passes: 4/4|; s|Verified: \[Y/N\]|Verified: Y|"
} > "$T/rspoof.md"
out=$(bash "$MW" parse-codex-header "$T/rspoof.md")
[ "$out" = "2/4" ] && ok "body-spoof rejected (first full-shape line wins: 2/4)" || bad "body-spoof (got '$out')"

# --- 6. missing file -> empty, still exit 0 ---
out=$(bash "$MW" parse-codex-header "$T/does-not-exist.md"); rc=$?
[ -z "$out" ] && [ "$rc" -eq 0 ] && ok "missing file -> empty, exit 0" || bad "missing file (got '$out' rc=$rc)"

# --- 7. dead-lens .usable counting yields 3/4 through the REAL predicate + REAL header emit ---
for i in 1 2 3; do echo "Verdict: findings noted" > "$T/codex-review-$i.txt"; echo ok > "$T/codex-review-$i.txt.usable"; done
echo "error: stream disconnected" > "$T/codex-review-4.txt"; echo no > "$T/codex-review-4.txt.usable"
CODEX_PASSES=$(grep -lx 'ok' "$T"/codex-review-*.txt.usable 2>/dev/null | wc -l | tr -d ' ')
mkreport "$T/rdead.md" "$CODEX_PASSES"
out=$(bash "$MW" parse-codex-header "$T/rdead.md")
[ "$out" = "3/4" ] && ok "dead-lens simulation: .usable count 3 -> header 3/4 -> verb 3/4" || bad "dead-lens (count=$CODEX_PASSES got '$out')"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
