#!/usr/bin/env bash
# 19 - the Codex /transfer skill is the hand-written override, not the automatic port, all the way to
# ~/.codex/skills; and /pre-compact's `no-mission` token (passed by /transfer) is honored.
#
#   A  generate-codex-layer.py (run on a throwaway copy of the repo) emits
#      command-transfer/SKILL.md byte-identical to codex/overrides/command-transfer/SKILL.md; other
#      commands are still ported; an override with no matching command fails the generator.
#   B  install-codex.sh (sandboxed CODEX_HOME, --skip-shell) delivers that override to
#      $CODEX_HOME/skills/claude-dotfiles/command-transfer/SKILL.md.
#   C  pre-compact.md: the token is documented; the north-star strip removes it (both forms); the
#      NO_MISSION switch reads it; mission-write.sh create is gated on it; transfer.md passes it.
set -uo pipefail
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"

HOME_T=$(tx_sandbox 19)
cleanup() { rm -rf "$HOME_T"; }
trap cleanup EXIT
OVR="$TX_REPO/codex/overrides/command-transfer/SKILL.md"
[ -f "$OVR" ] || { fail "A: the override $OVR is missing"; ok_report "19-codex-skill-and-no-mission" "-"; }

# ---------------------------------------------------------------- A: generator
R="$HOME_T/repo"
mkdir -p "$R/scripts" "$R/codex"
cp -R "$TX_REPO/commands" "$TX_REPO/skills" "$R/" 2>/dev/null
cp -R "$TX_REPO/codex/overrides" "$R/codex/"
cp "$TX_REPO/scripts/generate-codex-layer.py" "$TX_REPO/scripts/install-codex.sh" "$R/scripts/"
if ! python3 "$R/scripts/generate-codex-layer.py" >"$HOME_T/gen.out" 2>&1; then
  fail "A: the generator failed: $(tr '\n' '|' < "$HOME_T/gen.out")"
else
  GEN="$R/codex/generated/skills/claude-dotfiles"
  if [ ! -f "$GEN/command-transfer/SKILL.md" ]; then
    fail "A: no command-transfer skill was generated"
  else
    cmp -s "$GEN/command-transfer/SKILL.md" "$OVR" || fail "A: generated command-transfer/SKILL.md is not the override"
    grep -q "## Original Command" "$GEN/command-transfer/SKILL.md" && fail "A: command-transfer is still the automatic port"
    grep -q "pre-compact" "$GEN/command-transfer/SKILL.md" && fail "A: the Codex transfer skill still tells Codex to run Claude's /pre-compact"
    grep -q '^name: claude-command-transfer$' "$GEN/command-transfer/SKILL.md" || fail "A: the override does not keep the port's skill name"
    grep -q 'seal-after-exit' "$GEN/command-transfer/SKILL.md" || fail "A: the Codex transfer skill does not send with --seal-after-exit"
    grep -q 'CODEX_THREAD_ID' "$GEN/command-transfer/SKILL.md" || fail "A: the Codex transfer skill does not read CODEX_THREAD_ID"
  fi
  grep -q "## Original Command" "$GEN/command-commit/SKILL.md" 2>/dev/null || fail "A: ordinary commands (command-commit) are no longer ported"
  grep -q '`/transfer`' "$GEN/command-index/SKILL.md" || fail "A: the command index lost /transfer"
  grep -q "override" "$R/codex/generated/SUMMARY" || fail "A: SUMMARY does not report the override"
fi
mkdir -p "$R/codex/overrides/command-no-such-thing"
printf -- '---\nname: x\ndescription: y\n---\n' > "$R/codex/overrides/command-no-such-thing/SKILL.md"
python3 "$R/scripts/generate-codex-layer.py" >/dev/null 2>&1 && fail "A: an override with no matching command did not fail the generator"
rm -rf "$R/codex/overrides/command-no-such-thing"

# ---------------------------------------------------------------- B: delivery to CODEX_HOME
CH="$HOME_T/codex-home"
if ! CLAUDE_DOTFILES_DIR="$R" CODEX_HOME="$CH" HOME="$HOME_T" bash "$R/scripts/install-codex.sh" --quiet --skip-shell >"$HOME_T/inst.out" 2>&1; then
  fail "B: install-codex.sh failed: $(tr '\n' '|' < "$HOME_T/inst.out")"
else
  cmp -s "$CH/skills/claude-dotfiles/command-transfer/SKILL.md" "$OVR" \
    || fail "B: install-codex.sh did not deliver the override to \$CODEX_HOME/skills/claude-dotfiles/command-transfer/SKILL.md"
fi

# ---------------------------------------------------------------- C: pre-compact no-mission
PC="$TX_REPO/commands/pre-compact.md"; TR="$TX_REPO/commands/transfer.md"
grep -q '^- `no-mission` (or `--no-mission`)' "$PC" || fail "C: no-mission is not documented under Argument tokens"
PAT=$(grep -oE "grep -vE '\^\([^']*\)\\\$'" "$PC" | grep 'no-document' | head -1 | sed "s/^grep -vE '//; s/'\$//")
if [ -z "$PAT" ]; then
  fail "C: could not find the north-star strip pattern in pre-compact.md"
else
  GOT=$(printf '%s' "no-document no-mission fix the login bug --no-mission auto-confirm" | tr ' ' '\n' | grep -vE "$PAT" | tr '\n' ' ' | sed 's/  */ /g;s/^ //;s/ $//')
  [ "$GOT" = "fix the login bug" ] || fail "C: the north-star strip leaves '$GOT' (expected 'fix the login bug')"
fi
SW=$(grep -E '^ *case " \$\{ARGUMENTS:-\} " in \*" no-mission "\*' "$PC" | head -1)
if [ -z "$SW" ]; then
  fail "C: the NO_MISSION switch is missing from Step 3.B"
else
  for a in "no-document no-mission auto-confirm:1" "--no-mission:1" "no-document auto-confirm:0" "no-missionary work:0"; do
    got=$(ARGUMENTS="${a%:*}" bash -c "NO_MISSION=0; $SW; echo \$NO_MISSION")
    [ "$got" = "${a##*:}" ] || fail "C: ARGUMENTS='${a%:*}' gave NO_MISSION=$got (expected ${a##*:})"
  done
fi
grep -B2 'mission-write.sh create' "$PC" | grep -q '"\$NO_MISSION" = 0' || fail "C: mission-write.sh create is not gated on NO_MISSION"
grep -q 'skill: pre-compact`, args `[^`]*no-mission' "$TR" || fail "C: /transfer does not pass no-mission to /pre-compact"

ok_report "19-codex-skill-and-no-mission" "generator + install deliver the hand-written Codex transfer skill (not the port) to CODEX_HOME, an orphan override fails loud; pre-compact's no-mission token is documented, stripped from the north star, read by the NO_MISSION switch, gates the mission create, and /transfer passes it"
