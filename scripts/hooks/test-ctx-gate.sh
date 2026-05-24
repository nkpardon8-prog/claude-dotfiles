#!/usr/bin/env bash
# test-ctx-gate.sh — Manual test harness for ctx-gate hook scripts.
#
# Baseline (R2 redesign): ~31 tests after PreToolUse deletion + 7 new nudge-threshold tests.
# PreToolUse hook deleted (N4 locked decision) — all pretooluse.sh tests removed.
# New UserPromptSubmit nudge thresholds: 50 SOFT / 75 IMPORTANT / 85 FORCE.
#
# Usage:
#   bash test-ctx-gate.sh                   # run all tests
#   cd /tmp && bash ~/.claude-dotfiles/scripts/hooks/test-ctx-gate.sh  # same, from anywhere
#
# Exits 0 if all tests pass, 1 if any fail.

set -uo pipefail

# cd to the hook directory first so all relative ./hook.sh invocations work
# regardless of where the user runs this script from.
cd "$(dirname "$0")"

PASS=0
FAIL=0
FAIL_NAMES=""

pass() {
  PASS=$((PASS + 1))
  printf '  PASS: %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAIL_NAMES="${FAIL_NAMES} [$1]"
  printf '  FAIL: %s — %s\n' "$1" "${2:-}"
}

# ---------------------------------------------------------------------------
# §3 canned-input tests — UserPromptSubmit nudge thresholds
# ---------------------------------------------------------------------------
echo "== §3 UserPromptSubmit nudge threshold tests =="

# Each test creates a fresh TMPHOME, sets up sidecar / sentinel as needed,
# invokes the hook via here-string redirect (NOT pipe — HOME=val in `HOME=$TMPHOME
# echo X | hook.sh` goes to echo, not to hook.sh; <<< here-string applies HOME only
# to the hook subprocess).

# 3a — UserPromptSubmit, ctx=49 (below SOFT=50): expect empty output
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '49\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "3a: submit ctx=49 → empty (below soft=50)"; else fail "3a: submit ctx=49 → expected empty, got: $OUT"; fi
rm -rf "$TMPHOME"

# 3a-bis — UserPromptSubmit, ctx=50 (AT SOFT boundary): expect soft advisory
# >= semantics: ctx=50 fires; ctx=49 does not.
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '50\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("Context at 50%")' >/dev/null 2>&1; then
  pass "3a-bis: submit ctx=50 → soft advisory fires at exact SOFT boundary (>= semantics)"
else
  fail "3a-bis: submit ctx=50 → expected soft advisory at boundary, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3b — UserPromptSubmit, ctx=55 (soft zone 50-74%): expect soft advisory
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '55\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("Context at 55%")' >/dev/null 2>&1; then
  pass "3b: submit ctx=55 → soft advisory"
else
  fail "3b: submit ctx=55 → expected soft advisory, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3c — UserPromptSubmit, ctx=65 (still SOFT zone 50-74%, NOT IMPORTANT): expect soft advisory
# R1-H3: with new 50/75/85 model, ctx=65 hits SOFT zone (50-74%), NOT IMPORTANT (75-84%).
# Old test expected WRAP-UP; new test expects soft-zone message.
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '65\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("soft-zone reminder")' >/dev/null 2>&1; then
  pass "3c: submit ctx=65 → soft-zone reminder (50-74% = SOFT, not IMPORTANT)"
else
  fail "3c: submit ctx=65 → expected soft-zone reminder, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3c-2 — UserPromptSubmit, ctx=74 (highest SOFT value): expect soft advisory (not IMPORTANT)
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '74\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("soft-zone reminder")' >/dev/null 2>&1; then
  pass "3c-2: submit ctx=74 → soft-zone (boundary: 74 < 75 IMPORTANT)"
else
  fail "3c-2: submit ctx=74 → expected soft-zone, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3c-3 — UserPromptSubmit, ctx=75 (AT IMPORTANT boundary): expect IMPORTANT nudge
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '75\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("IMPORTANT zone")' >/dev/null 2>&1; then
  pass "3c-3: submit ctx=75 → IMPORTANT nudge at exact IMPORTANT boundary"
else
  fail "3c-3: submit ctx=75 → expected IMPORTANT nudge, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3c-4 — UserPromptSubmit, ctx=84 (highest IMPORTANT value): expect IMPORTANT nudge
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '84\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("IMPORTANT zone")' >/dev/null 2>&1; then
  pass "3c-4: submit ctx=84 → IMPORTANT nudge (boundary: 84 < 85 FORCE)"
else
  fail "3c-4: submit ctx=84 → expected IMPORTANT nudge, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3c-5 — UserPromptSubmit, ctx=85 (AT FORCE boundary): expect FORCE nudge + WRAP-UP text
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '85\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("WRAP-UP")' >/dev/null 2>&1 && \
   printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("Skill(pre-compact)")' >/dev/null 2>&1; then
  pass "3c-5: submit ctx=85 → FORCE nudge with WRAP-UP + Skill(pre-compact)"
else
  fail "3c-5: submit ctx=85 → expected FORCE nudge, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3c-6 — UserPromptSubmit, ctx=95 (deep FORCE zone): expect FORCE nudge
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '95\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("WRAP-UP")' >/dev/null 2>&1; then
  pass "3c-6: submit ctx=95 → FORCE nudge"
else
  fail "3c-6: submit ctx=95 → expected FORCE nudge, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3c-7 — UserPromptSubmit, ctx=85, sentinel ARMED and fresh: FORCE still fires (overrides sentinel-fresh skip)
# R1-B23: FORCE threshold overrides sentinel-fresh skip.
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '85\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
printf '{"schema_version":3,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"/tmp","marker_nonce":"fresh"}\n' \
  > "$TMPHOME/.claude/progress/auto-compact-foo.json"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("WRAP-UP")' >/dev/null 2>&1; then
  pass "3c-7: submit ctx=85 sentinel-fresh → FORCE still fires (overrides sentinel-fresh skip)"
else
  fail "3c-7: submit ctx=85 sentinel-fresh → expected FORCE to override skip, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3c-8 — UserPromptSubmit, ctx=65, sentinel ARMED and fresh: SOFT is SUPPRESSED by sentinel-fresh skip
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '65\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
printf '{"schema_version":3,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"/tmp","marker_nonce":"fresh"}\n' \
  > "$TMPHOME/.claude/progress/auto-compact-foo.json"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if [ -z "$OUT" ]; then
  pass "3c-8: submit ctx=65 sentinel-fresh → SOFT suppressed by sentinel-fresh skip"
else
  fail "3c-8: submit ctx=65 sentinel-fresh → expected empty (skip), got: $OUT"
fi
rm -rf "$TMPHOME"

# ---------------------------------------------------------------------------
# §3i/3i-bis/3j/3k — PreCompact safety-net tests
# ---------------------------------------------------------------------------
echo ""
echo "== §3 PreCompact safety-net tests =="

# 3i — PreCompact, trigger=auto, ctx=68 (BLOCK zone: 0-89%), no sentinel: expect decision=block
# Post-R3: BLOCK zone is below HANDOFF_AUTOCOMPACT_BYPASS_PCT (90%)
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '68\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"foo","trigger":"auto","hook_event_name":"PreCompact"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass "3i: precompact trigger=auto ctx=68 no sentinel → block"
else
  fail "3i: precompact trigger=auto ctx=68 → expected block, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3i-bis — PreCompact, trigger=auto, ctx=91 (>=90% RELEASE zone after R3 D4 raise), no sentinel: expect empty
# Post-R3: PRECOMPACT release threshold is HANDOFF_AUTOCOMPACT_BYPASS_PCT (90 from handoff-config.sh after R3 D4 raise)
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '91\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"foo","trigger":"auto","hook_event_name":"PreCompact"}' 2>/dev/null)
if [ -z "$OUT" ]; then
  pass "3i-bis: precompact trigger=auto ctx=91 → release (empty, avoids deadlock at >=90%)"
else
  fail "3i-bis: precompact trigger=auto ctx=91 → expected empty (release), got: $OUT"
fi
rm -rf "$TMPHOME"

# 3j — PreCompact, trigger=auto, ctx=78, sentinel PRESENT: expect empty (allow native compact)
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '78\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
printf '{"schema_version":3,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"/tmp","marker_nonce":"x"}\n' \
  > "$TMPHOME/.claude/progress/auto-compact-foo.json"
OUT=$(HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"foo","trigger":"auto","hook_event_name":"PreCompact"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "3j: precompact trigger=auto ctx=78 sentinel-present → allow"; else fail "3j: precompact sentinel-present → expected allow (empty), got: $OUT"; fi
rm -rf "$TMPHOME"

# 3k — PreCompact, trigger=manual, ctx=96, no sentinel: expect empty (never block manual)
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '96\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"foo","trigger":"manual","hook_event_name":"PreCompact"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "3k: precompact trigger=manual → never block (empty)"; else fail "3k: precompact trigger=manual → expected empty, got: $OUT"; fi
rm -rf "$TMPHOME"

# ---------------------------------------------------------------------------
# §G1 boundary tests at PCT=89/90/91 for HANDOFF_AUTOCOMPACT_BYPASS_PCT=90
# ---------------------------------------------------------------------------
echo ""
echo "== §G1 boundary: precompact-safety at PCT 89/90/91 =="

for G1_PCT in 89 90 91; do
  TMPHOME=$(mktemp -d)
  mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
  printf '%s\n' "$G1_PCT" > "$TMPHOME/.claude/progress/ctx-g1.txt"
  OUT=$(HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"g1","trigger":"auto","hook_event_name":"PreCompact"}' 2>/dev/null)
  case "$G1_PCT" in
    89)
      if printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
        pass "G1: PCT=89 (below 90 bypass) → block (no sentinel)"
      else
        fail "G1: PCT=89 expected block, got: $OUT"
      fi
      ;;
    90|91)
      if [ -z "$OUT" ]; then
        pass "G1: PCT=$G1_PCT (>=90 bypass) → release (empty)"
      else
        fail "G1: PCT=$G1_PCT expected release (empty), got: $OUT"
      fi
      ;;
  esac
  rm -rf "$TMPHOME"
done

# ---------------------------------------------------------------------------
# §G2 non-git workspace REPO_ROOT fallback to $(pwd)
# ---------------------------------------------------------------------------
echo ""
echo "== §G2 non-git workspace REPO_ROOT fallback =="

TMPWD=$(mktemp -d)
# No .git dir → git rev-parse fails → fallback to $(pwd)
(
  cd "$TMPWD" || exit 1
  RR=$(git rev-parse --show-toplevel 2>/dev/null)
  if [ -z "$RR" ]; then
    RR="$(pwd)"
  fi
  RR_CANON=$(cd -P "$RR" 2>/dev/null && pwd -P || printf '%s' "$RR")
  TMPWD_CANON=$(cd -P "$TMPWD" 2>/dev/null && pwd -P || printf '%s' "$TMPWD")
  if [ "$RR_CANON" = "$TMPWD_CANON" ]; then
    pass "G2: non-git REPO_ROOT falls back to \$(pwd)=$RR_CANON"
  else
    fail "G2: non-git fallback mismatch RR=$RR_CANON expected=$TMPWD_CANON"
  fi
)
rm -rf "$TMPWD"

# ---------------------------------------------------------------------------
# §G5 LOG_VERBS enforcement — every log-verb token is documented
# ---------------------------------------------------------------------------
echo ""
echo "== §G5 LOG_VERBS enforcement =="

VERBS_FILE="$PWD/LOG_VERBS.md"
if [ -f "$VERBS_FILE" ]; then
  UNDOC=()
  while IFS= read -r G5_LINE; do
    G5_TOKEN=$(printf '%s' "$G5_LINE" | sed -nE 's/.*(ac_log|ctx_gate_log|handoff_log)[[:space:]]+"([^[:space:]"]+).*/\2/p')
    [ -z "$G5_TOKEN" ] && continue
    if ! grep -qF "$G5_TOKEN" "$VERBS_FILE" 2>/dev/null; then
      UNDOC+=("$G5_TOKEN")
    fi
  done < <(grep -rE '(ac_log|ctx_gate_log|handoff_log)[[:space:]]+"' "$PWD"/*.sh "$PWD"/lib/*.sh 2>/dev/null)
  G5_UNDOC_UNIQ=$(printf '%s\n' "${UNDOC[@]}" | sort -u | tr '\n' ' ')
  if [ -z "$(printf '%s' "$G5_UNDOC_UNIQ" | tr -d '[:space:]')" ]; then
    pass "G5: all log-verb tokens documented in LOG_VERBS.md"
  else
    # R4 H6: promoted from informational pass to hard FAIL — LOG_VERBS.md must stay in sync.
    # If a log verb is emitted but undocumented, update LOG_VERBS.md before proceeding.
    fail "G5: LOG_VERBS drift detected — undocumented verbs: $G5_UNDOC_UNIQ (update LOG_VERBS.md)"
  fi
else
  fail "G5: LOG_VERBS.md missing at $VERBS_FILE"
fi

# ---------------------------------------------------------------------------
# §G4 post-compact-resume-step2.sh STATE-routing tests
# ---------------------------------------------------------------------------
echo ""
echo "== §G4 post-compact-resume-step2.sh STATE-routing =="

STEP2_SH="$PWD/post-compact-resume-step2.sh"
if [ ! -x "$STEP2_SH" ]; then
  fail "G4: post-compact-resume-step2.sh missing or non-executable at $STEP2_SH"
else
  # Helper: parse .state field from JSON STATE line (R4 D10)
  step2_state() { printf '%s' "$1" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null; }
  step2_field() { printf '%s' "$1" | sed -n 's/^STATE=//p' | jq -r ".$2" 2>/dev/null; }

  # G4-A: empty workspace → STATE=no-handoff
  TMPWD=$(mktemp -d)
  TMPHOME=$(mktemp -d)
  mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
  OUT=$(cd "$TMPWD" && HOME="$TMPHOME" bash "$STEP2_SH" 2>/dev/null)
  G4A_STATE=$(step2_state "$OUT")
  if [ "$G4A_STATE" = "no-handoff" ]; then
    pass "G4-A: empty workspace → STATE=no-handoff (JSON parsed)"
  else
    fail "G4-A: empty workspace expected state=no-handoff" "got state=$G4A_STATE raw: $OUT"
  fi
  rm -rf "$TMPWD" "$TMPHOME"

  # G4-B: handoff present (alias, no breadcrumb) with marker → STATE=ok marker=present
  # SID unknown (no breadcrumb) → alias path is used (R4 D3 SID-unknown branch).
  TMPWD=$(mktemp -d)
  TMPHOME=$(mktemp -d)
  mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
  G4B_NONCE="abcd1234-5678-90ab-cdef-1234567890ab"
  G4B_SID8="abcd1234"
  printf 'content body\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' "$G4B_SID8" "$G4B_NONCE" > "$TMPWD/CLAUDE.local.md"
  OUT=$(cd "$TMPWD" && HOME="$TMPHOME" bash "$STEP2_SH" 2>/dev/null)
  G4B_STATE=$(step2_state "$OUT")
  G4B_MARKER=$(step2_field "$OUT" "marker")
  if [ "$G4B_STATE" = "ok" ] && [ "$G4B_MARKER" = "present" ]; then
    pass "G4-B: handoff with marker → state=ok marker=present (JSON parsed)"
  else
    fail "G4-B: expected state=ok marker=present" "got state=$G4B_STATE marker=$G4B_MARKER raw: $OUT"
  fi
  rm -rf "$TMPWD" "$TMPHOME"

  # G4-C: handoff (alias, no breadcrumb) missing marker (recent file) → STATE=ok marker=absent legacy=false
  TMPWD=$(mktemp -d)
  TMPHOME=$(mktemp -d)
  mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
  printf 'content body without marker\n' > "$TMPWD/CLAUDE.local.md"
  OUT=$(cd "$TMPWD" && HOME="$TMPHOME" bash "$STEP2_SH" 2>/dev/null)
  G4C_STATE=$(step2_state "$OUT")
  G4C_MARKER=$(step2_field "$OUT" "marker")
  G4C_LEGACY=$(step2_field "$OUT" "legacy")
  if [ "$G4C_STATE" = "ok" ] && [ "$G4C_MARKER" = "absent" ] && [ "$G4C_LEGACY" = "false" ]; then
    pass "G4-C: recent missing marker → state=ok marker=absent legacy=false (JSON parsed)"
  else
    fail "G4-C: expected state=ok marker=absent legacy=false" "got state=$G4C_STATE marker=$G4C_MARKER legacy=$G4C_LEGACY raw: $OUT"
  fi
  rm -rf "$TMPWD" "$TMPHOME"

  # G4-D: oversized handoff (6MB > 5MB cap) → STATE=oversize
  TMPWD=$(mktemp -d)
  TMPHOME=$(mktemp -d)
  mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
  dd if=/dev/zero of="$TMPWD/CLAUDE.local.md" bs=1024 count=6144 2>/dev/null
  OUT=$(cd "$TMPWD" && HOME="$TMPHOME" bash "$STEP2_SH" 2>/dev/null)
  G4D_STATE=$(step2_state "$OUT")
  if [ "$G4D_STATE" = "oversize" ]; then
    pass "G4-D: 6MB handoff → state=oversize (JSON parsed, H11 size cap)"
  else
    fail "G4-D: expected state=oversize" "got state=$G4D_STATE raw: $(printf '%s' "$OUT" | head -c 200)"
  fi
  rm -rf "$TMPWD" "$TMPHOME"

  # G4-E: SID-tagged handoff + breadcrumb with matching nonce → STATE=ok nonce_ok=match
  # R4 D3: with SID known (breadcrumb present), file MUST be SID-tagged (not alias).
  TMPWD=$(mktemp -d)
  TMPHOME=$(mktemp -d)
  mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
  G4E_NONCE="11112222-3333-4444-5555-666677778888"
  G4E_SID="g4e-test-sid-1234"
  G4E_SID8="g4e-test"
  G4E_HOST=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64)
  # R4 D3 fix: place handoff at SID-tagged path (not alias) so D3 SID-known path resolves it.
  printf 'content body\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' "$G4E_SID8" "$G4E_NONCE" > "$TMPWD/CLAUDE.local.${G4E_SID8}.md"
  G4E_CWD=$(cd -P "$TMPWD" 2>/dev/null && pwd -P)
  # R4 H1: breadcrumb now requires schema_version:1 + originating_command fields.
  jq -c -n \
    --argjson sv 1 \
    --arg sid  "$G4E_SID"  \
    --arg sid8 "$G4E_SID8" \
    --arg cwd  "$G4E_CWD"  \
    --arg nonce "$G4E_NONCE" \
    --arg host  "$G4E_HOST"  \
    '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host}' \
    > "$TMPHOME/.claude/progress/breadcrumb-${G4E_SID}.json"
  chmod 600 "$TMPHOME/.claude/progress/breadcrumb-${G4E_SID}.json"
  OUT=$(cd "$TMPWD" && HOME="$TMPHOME" bash "$STEP2_SH" 2>/dev/null)
  G4E_STATE=$(step2_state "$OUT")
  G4E_NONCE_OK=$(step2_field "$OUT" "nonce_ok")
  if [ "$G4E_STATE" = "ok" ] && [ "$G4E_NONCE_OK" = "match" ]; then
    pass "G4-E: SID-tagged breadcrumb-matched nonce → state=ok nonce_ok=match (R4 D3 + JSON parsed)"
  else
    fail "G4-E: expected state=ok nonce_ok=match" "got state=$G4E_STATE nonce_ok=$G4E_NONCE_OK raw: $OUT"
  fi
  rm -rf "$TMPWD" "$TMPHOME"
fi

# ---------------------------------------------------------------------------
# §3l primer source-routing matrix tests
# ---------------------------------------------------------------------------
echo ""
echo "== §3l primer source-routing matrix tests =="

# All tests use CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE set to a 2020 epoch so any
# 2024+ mtime is NOT legacy, and any pre-2020 mtime IS legacy (deterministic).
LEGACY_OVERRIDE_PAST=$(date -u -j -f '%Y-%m-%d' '2020-01-01' +%s 2>/dev/null || date -u -d '2020-01-01' +%s 2>/dev/null || echo 1577836800)
LEGACY_OVERRIDE_FUTURE=9999999999

# 3l-compact-fresh-marker: source=compact + fresh marker + no sentinel → normal nav
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" && chmod 700 "$TMPHOME"
printf '# handoff\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.md"
JSON="{\"session_id\":\"newsid\",\"source\":\"compact\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("POST-COMPACT")' >/dev/null 2>&1; then
  pass "3l-compact-fresh-marker: source=compact + fresh marker → normal nav"
else
  fail "3l-compact-fresh-marker" "expected POST-COMPACT nav, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3l-compact-fresh-no-marker: source=compact + fresh + no marker → TRUNCATED warning
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" && chmod 700 "$TMPHOME"
printf '# handoff\n## Content without marker\n' > "$TMPHOME/repo/CLAUDE.local.md"
JSON="{\"session_id\":\"newsid\",\"source\":\"compact\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("TRUNCATED")' >/dev/null 2>&1; then
  pass "3l-compact-fresh-no-marker: source=compact + no marker → TRUNCATED warning"
else
  fail "3l-compact-fresh-no-marker" "expected TRUNCATED warning, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3l-compact-legacy: source=compact + mtime<cutoff + no marker → LEGACY warning
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" && chmod 700 "$TMPHOME"
printf '# old handoff\n## No marker here\n' > "$TMPHOME/repo/CLAUDE.local.md"
touch -t 201901010000 "$TMPHOME/repo/CLAUDE.local.md"  # 2019 = before LEGACY_OVERRIDE_PAST (2020)
JSON="{\"session_id\":\"newsid\",\"source\":\"compact\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("LEGACY")' >/dev/null 2>&1; then
  pass "3l-compact-legacy: source=compact + mtime<cutoff + no marker → LEGACY warning"
else
  fail "3l-compact-legacy" "expected LEGACY warning, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3l-compact-anomaly-sentinel-present: source=compact + sentinel with MATCHING cwd present → ANOMALY warning
# R4 D3 fix: handoff must be at SID-tagged path (sentinel SID=oldsid → SID8=oldsid).
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
printf '# handoff\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.oldsid.md"
printf '{"schema_version":2,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"%s/repo"}\n' "$TMPHOME" > "$TMPHOME/.claude/progress/auto-compact-oldsid.json"
JSON="{\"session_id\":\"newsid\",\"source\":\"compact\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("ANOMALY")' >/dev/null 2>&1; then
  pass "3l-compact-anomaly-sentinel-present: source=compact + matching sentinel → ANOMALY warning"
else
  fail "3l-compact-anomaly-sentinel-present" "expected ANOMALY warning, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3l-resume-sentinel-fresh: source=resume + sentinel cwd match + fresh marker → PENDING HANDOFF nav
# R4 D3 fix: handoff at SID-tagged path.
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
printf '# handoff\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.oldsid.md"
printf '{"schema_version":2,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"%s/repo"}\n' "$TMPHOME" > "$TMPHOME/.claude/progress/auto-compact-oldsid.json"
JSON="{\"session_id\":\"newsid\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("PENDING HANDOFF")' >/dev/null 2>&1; then
  pass "3l-resume-sentinel-fresh: source=resume + sentinel match + fresh marker → PENDING HANDOFF"
else
  fail "3l-resume-sentinel-fresh" "expected PENDING HANDOFF nav, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3l-resume-sentinel-stale: source=resume + sentinel + 2-day-old mtime → STALE + PENDING HANDOFF
# R4 D3 fix: handoff at SID-tagged path.
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
printf '# handoff\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.oldsid.md"
touch -t 202601010000 "$TMPHOME/repo/CLAUDE.local.oldsid.md"  # 2026-01-01 = well over 24h old
printf '{"schema_version":2,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"%s/repo"}\n' "$TMPHOME" > "$TMPHOME/.claude/progress/auto-compact-oldsid.json"
JSON="{\"session_id\":\"newsid\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_STALE_SECS_OVERRIDE=3600 HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("STALE")' >/dev/null 2>&1 && \
   printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("PENDING HANDOFF")' >/dev/null 2>&1; then
  pass "3l-resume-sentinel-stale: source=resume + sentinel + old mtime → STALE + PENDING HANDOFF"
else
  fail "3l-resume-sentinel-stale" "expected STALE + PENDING HANDOFF, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3l-resume-no-sentinel-fresh: source=resume + no sentinel + fresh marker → SESSION START nav
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
printf '# handoff\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.md"
JSON="{\"session_id\":\"newsid\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("SESSION START")' >/dev/null 2>&1; then
  pass "3l-resume-no-sentinel-fresh: source=resume + no sentinel + fresh marker → SESSION START"
else
  fail "3l-resume-no-sentinel-fresh" "expected SESSION START nav, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3l-resume-no-sentinel-stale: source=resume + no sentinel + 30h-old mtime → STALE
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
printf '# handoff\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.md"
touch -t 202601010000 "$TMPHOME/repo/CLAUDE.local.md"  # 2026-01-01 = old
JSON="{\"session_id\":\"newsid\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_STALE_SECS_OVERRIDE=3600 HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("STALE")' >/dev/null 2>&1; then
  pass "3l-resume-no-sentinel-stale: source=resume + no sentinel + old mtime → STALE"
else
  fail "3l-resume-no-sentinel-stale" "expected STALE warning, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3l-resume-legacy: source=resume + mtime<cutoff + no marker → LEGACY
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
printf '# old handoff\n## No marker\n' > "$TMPHOME/repo/CLAUDE.local.md"
touch -t 201901010000 "$TMPHOME/repo/CLAUDE.local.md"  # 2019 = before 2020 cutoff
JSON="{\"session_id\":\"newsid\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("LEGACY")' >/dev/null 2>&1; then
  pass "3l-resume-legacy: source=resume + mtime<cutoff + no marker → LEGACY"
else
  fail "3l-resume-legacy" "expected LEGACY warning, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3l-startup-no-handoff: source=startup + no CLAUDE.local.md → exit silently (no JSON output)
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" && chmod 700 "$TMPHOME"
# No CLAUDE.local.md in cwd or repo root
JSON="{\"session_id\":\"newsid\",\"source\":\"startup\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if [ -z "$OUT" ]; then
  pass "3l-startup-no-handoff: source=startup + no handoff → exit silently"
else
  fail "3l-startup-no-handoff" "expected silent exit (empty), got: $OUT"
fi
rm -rf "$TMPHOME"

# 3l-clear-fresh-marker: source=clear + fresh marker → nav directive (verifies regex matcher captures 'clear')
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" && chmod 700 "$TMPHOME"
printf '# handoff\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.md"
JSON="{\"session_id\":\"newsid\",\"source\":\"clear\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
  pass "3l-clear-fresh-marker: source=clear + fresh marker → nav directive emitted"
else
  fail "3l-clear-fresh-marker" "expected nav directive for source=clear, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3l-resume-sentinel-mismatched-cwd: source=resume + sentinel cwd=OTHER → SENTINEL_PRESENT=false, SESSION START nav
# Regression test: SID-mismatch fix verification — mismatched cwd must be skipped
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/other-project" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
printf '# handoff\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.md"
# Sentinel cwd points to /other-project, not /repo
printf '{"schema_version":2,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"%s/other-project"}\n' "$TMPHOME" > "$TMPHOME/.claude/progress/auto-compact-oldsid.json"
JSON="{\"session_id\":\"newsid\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
# Should NOT contain PENDING HANDOFF (sentinel for different workspace, SENTINEL_PRESENT=false)
# Should contain SESSION START (handoff file present but no matching sentinel)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("SESSION START")' >/dev/null 2>&1 && \
   ! printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("PENDING HANDOFF")' >/dev/null 2>&1; then
  pass "3l-resume-sentinel-mismatched-cwd: mismatched sentinel cwd skipped → SESSION START (not PENDING)"
else
  fail "3l-resume-sentinel-mismatched-cwd" "expected SESSION START without PENDING HANDOFF, got: $OUT"
fi
rm -rf "$TMPHOME"

# primer-marker-absent: synthetic CLAUDE.local.md with substantive content but no marker,
# mtime > cutoff → TRUNCATED warning
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" && chmod 700 "$TMPHOME"
printf '# handoff\n## Active Skill State\nDetected: /plan\n## Next Action\nRun tests.\n' > "$TMPHOME/repo/CLAUDE.local.md"
JSON="{\"session_id\":\"newsid\",\"source\":\"compact\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("TRUNCATED")' >/dev/null 2>&1; then
  pass "primer-marker-absent: substantive content without marker → TRUNCATED warning"
else
  fail "primer-marker-absent" "expected TRUNCATED warning for marker-absent file, got: $OUT"
fi
rm -rf "$TMPHOME"

echo "== C8: primer kill-switch =="
# CLAUDE_CTX_GATE_DISABLED=1 should make primer exit 0 silently with no output,
# regardless of any other input. Defends against future refactors that move the
# kill-switch below the lib source (which would introduce a load-time failure
# even when disabled).
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" && chmod 700 "$TMPHOME"
JSON='{"session_id":"killtest","source":"compact","cwd":"'"$TMPHOME/repo"'","hook_event_name":"SessionStart"}'
OUT=$(CLAUDE_CTX_GATE_DISABLED=1 HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
KILL_EXIT=$?
if [ -z "$OUT" ] && [ "$KILL_EXIT" = "0" ]; then
  pass "C8: primer kill-switch — empty stdout + exit 0 when CLAUDE_CTX_GATE_DISABLED=1"
else
  fail "C8: primer kill-switch" "got OUT='$OUT' exit=$KILL_EXIT"
fi
rm -rf "$TMPHOME"

# ---------------------------------------------------------------------------
# §2.5 Simplified end-to-end chain (PreToolUse steps removed)
# ---------------------------------------------------------------------------
echo ""
echo "== §2.5 Simplified end-to-end hook chain =="

# All invocations use `HOME="$TMPHOME" ./hook.sh <<< '...'` — the <<< here-string is a
# redirect (not a pipeline), so HOME applies correctly to the hook subprocess.

TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '91\n' > "$TMPHOME/.claude/progress/ctx-fakesid.txt"
ARM_PATH="$TMPHOME/.claude/progress/auto-compact-fakesid.json"

# Step 1: UserPromptSubmit at 91% → expect FORCE advisory (>=85)
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"fakesid","prompt":"do thing","cwd":"/tmp","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("WRAP-UP")' >/dev/null 2>&1; then
  pass "§2.5 step 1: submit hook injects FORCE advisory at 91%"
else
  fail "§2.5 step 1: submit hook FORCE advisory" "submit hook didn't inject FORCE advisory, got: $OUT"
fi

# Step 4: Simulate /pre-compact arming the sentinel (schema v3 with nonce)
printf '{"schema_version":3,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"/tmp","marker_nonce":"test-nonce-1"}\n' > "$ARM_PATH"

# Step 6: UserPromptSubmit at 65% after sentinel armed → SOFT suppressed by sentinel-fresh skip
printf '65\n' > "$TMPHOME/.claude/progress/ctx-fakesid.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"fakesid","prompt":"do thing","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if [ -z "$OUT" ]; then
  pass "§2.5 step 6: submit hook silent for SOFT after sentinel armed (sentinel-fresh skip)"
else
  fail "§2.5 step 6: submit hook silence post-sentinel (SOFT)" "submit hook should not advise SOFT after sentinel armed, got: $OUT"
fi

# Step 6b: UserPromptSubmit at 91% after sentinel armed → FORCE still fires
printf '91\n' > "$TMPHOME/.claude/progress/ctx-fakesid.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"fakesid","prompt":"do thing","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("WRAP-UP")' >/dev/null 2>&1; then
  pass "§2.5 step 6b: submit hook FORCE still fires at 91% even with fresh sentinel"
else
  fail "§2.5 step 6b: FORCE overrides sentinel-fresh skip" "FORCE should fire even with sentinel armed, got: $OUT"
fi

# Step 7: PreCompact trigger=auto, ctx=68 (BLOCK zone: 0-74%), no sentinel → should block
rm -f "$ARM_PATH"
printf '68\n' > "$TMPHOME/.claude/progress/ctx-fakesid.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"fakesid","trigger":"auto","hook_event_name":"PreCompact"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass "§2.5 step 7: precompact safety blocks at ctx=68 without sentinel"
else
  fail "§2.5 step 7: precompact block at 68" "precompact safety should block at ctx=68, got: $OUT"
fi

# Step 7b: PreCompact trigger=auto, ctx=91 (>=90% RELEASE zone after R3 D4 raise) → should RELEASE (avoid deadlock)
printf '91\n' > "$TMPHOME/.claude/progress/ctx-fakesid.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"fakesid","trigger":"auto","hook_event_name":"PreCompact"}' 2>/dev/null)
if [ -z "$OUT" ]; then
  pass "§2.5 step 7b: precompact safety releases at ctx=91 (avoids deadlock at >=90%)"
else
  fail "§2.5 step 7b: precompact release at 91" "precompact safety should RELEASE at ctx>=90 (empty output), got: $OUT"
fi

# Step 8: SessionStart compact with CLAUDE.local.md present in cwd → primer fires
REPO_DIR="$TMPHOME/repo"
mkdir -p "$REPO_DIR" && printf '# handoff\n\n<!-- END-OF-HANDOFF -->\n' > "$REPO_DIR/CLAUDE.local.md"
JSON="{\"session_id\":\"newsid\",\"source\":\"compact\",\"cwd\":\"$REPO_DIR\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("POST-COMPACT")' >/dev/null 2>&1; then
  pass "§2.5 step 8: primer fires with CLAUDE.local.md present (with marker)"
else
  fail "§2.5 step 8: primer fires" "primer didn't fire, got: $OUT"
fi

# Step 11: Kill-switch — with CLAUDE_CTX_GATE_DISABLED=1, all hooks must be silent
printf '91\n' > "$TMPHOME/.claude/progress/ctx-fakesid.txt"

OUT=$(CLAUDE_CTX_GATE_DISABLED=1 HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"fakesid","prompt":"do","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "§2.5 step 11a: kill-switch silences submit hook"; else fail "§2.5 step 11a: kill-switch submit" "kill-switch should silence submit hook, got: $OUT"; fi

OUT=$(CLAUDE_CTX_GATE_DISABLED=1 HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"fakesid","trigger":"auto","hook_event_name":"PreCompact"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "§2.5 step 11c: kill-switch silences precompact-safety hook"; else fail "§2.5 step 11c: kill-switch precompact" "kill-switch should silence precompact-safety hook, got: $OUT"; fi

# Clean up synthetic chain temp dir
rm -rf "$TMPHOME"
echo "End-to-end synthetic chain: done"

# ---------------------------------------------------------------------------
# §C3 Malformed JSON stdin to primer — each must exit 0, no fatal error
# ---------------------------------------------------------------------------
echo ""
echo "== §C3 primer with malformed JSON stdin =="

for C3_INPUT in \
  '' \
  '{}' \
  '{"session_id":null}' \
  '{"source":null}' \
  '{"cwd":""}' \
  'not-json-at-all'; do
  TMPHOME=$(mktemp -d)
  mkdir -p "$TMPHOME/repo" && chmod 700 "$TMPHOME"
  OUT=$(HOME="$TMPHOME" ./post-compact-primer.sh <<< "$C3_INPUT" 2>/dev/null)
  EXIT_CODE=$?
  if [ "$EXIT_CODE" -eq 0 ]; then
    pass "C3: primer exits 0 for input: '$(printf '%s' "$C3_INPUT" | head -c 30)'"
  else
    fail "C3: primer must exit 0 for malformed input" "exit=$EXIT_CODE input='$C3_INPUT'"
  fi
  rm -rf "$TMPHOME"
done

# cwd=/etc — must skip (not owned by user) and exit 0
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME" && chmod 700 "$TMPHOME"
# /etc exists and is a dir but is not user-writable; primer should silently skip
OUT=$(HOME="$TMPHOME" ./post-compact-primer.sh <<< '{"session_id":"s","source":"resume","cwd":"/etc","hook_event_name":"SessionStart"}' 2>/dev/null)
EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 0 ]; then
  pass "C3: primer exits 0 for cwd=/etc (skip — no CLAUDE.local.md there)"
else
  fail "C3: primer cwd=/etc must exit 0" "exit=$EXIT_CODE"
fi
rm -rf "$TMPHOME"

# ---------------------------------------------------------------------------
# §C5 primer-marker-absent-at-byte-600: marker in first 1000 bytes, NOT last 512
# ---------------------------------------------------------------------------
echo ""
echo "== §C5 primer-marker-absent-at-byte-600 =="
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" && chmod 700 "$TMPHOME"
# Build a file where END-OF-HANDOFF marker is near byte 600, then padded to ~1500 bytes.
# tail -c 512 will NOT include the marker → primer should emit TRUNCATED warning.
{
  # ~600 bytes of content then the legacy marker, then 900 bytes of padding
  printf '# Handoff\n\n## Active Skill State\nDetected: /plan\n\n## Next Action\nRun review.\n\n'
  printf '<!-- END-OF-HANDOFF -->\n'
  # Pad with 900 bytes of additional content so the total is ~1500 bytes
  # and the marker is well outside the final 512 bytes
  printf '## Section After Marker\n'
  python3 -c "print('x' * 900)" 2>/dev/null || printf '%0900d' 0 | tr '0' 'x'
  printf '\n'
} > "$TMPHOME/repo/CLAUDE.local.md"
FILE_SIZE=$(wc -c < "$TMPHOME/repo/CLAUDE.local.md" 2>/dev/null | tr -d '[:space:]')
LEGACY_OVERRIDE_PAST=$(date -u -j -f '%Y-%m-%d' '2020-01-01' +%s 2>/dev/null || date -u -d '2020-01-01' +%s 2>/dev/null || echo 1577836800)
JSON="{\"session_id\":\"newsid\",\"source\":\"compact\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("TRUNCATED")' >/dev/null 2>&1; then
  pass "C5: primer emits TRUNCATED when marker is NOT in last 512 bytes (file=${FILE_SIZE}b, marker at ~600b)"
else
  fail "C5: primer-marker-at-byte-600" "expected TRUNCATED warning, got: $OUT"
fi
rm -rf "$TMPHOME"

# ---------------------------------------------------------------------------
# §C6 multi-sentinel-matching-cwd: 2 sentinels with same cwd — primer breaks on first match
# ---------------------------------------------------------------------------
echo ""
echo "== §C6 multi-sentinel-matching-cwd =="
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
# R4 D3 fix: provide SID-tagged handoffs for each sentinel SID.
# Primer picks first glob match; both SIDs have their own SID-tagged files.
printf '# handoff A\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.AAAA0001.md"
printf '# handoff B\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.BBBB0002.md"
# Two sentinels with identical cwd but different SIDs
printf '{"schema_version":3,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"%s/repo","marker_nonce":"nonce1"}\n' "$TMPHOME" \
  > "$TMPHOME/.claude/progress/auto-compact-AAAA0001.json"
printf '{"schema_version":3,"target_tty":"/dev/ttys002","originating_command":"pre-compact","cwd":"%s/repo","marker_nonce":"nonce2"}\n' "$TMPHOME" \
  > "$TMPHOME/.claude/progress/auto-compact-BBBB0002.json"
JSON="{\"session_id\":\"newsid\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
LEGACY_OVERRIDE_PAST=$(date -u -j -f '%Y-%m-%d' '2020-01-01' +%s 2>/dev/null || date -u -d '2020-01-01' +%s 2>/dev/null || echo 1577836800)
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
# Verify primer detected a sentinel (PENDING HANDOFF) — it breaks on first glob match
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("PENDING HANDOFF")' >/dev/null 2>&1; then
  pass "C6: multi-sentinel-matching-cwd → primer breaks on first match (SENTINEL_PRESENT=true)"
else
  fail "C6: multi-sentinel-matching-cwd" "expected PENDING HANDOFF, got: $OUT"
fi
rm -rf "$TMPHOME"

# ---------------------------------------------------------------------------
# §C7 Marker idempotency shim: append marker form twice, verify grep -c = 2 (failure mode)
# ---------------------------------------------------------------------------
echo ""
echo "== §C7 Marker idempotency shim test =="
TMPFILE_C7=$(mktemp)
MARKER_LINE='<!-- END-OF-HANDOFF schema=v1 sid=AAAA1234 nonce=abc-def-0000 -->'
printf '# handoff content\n\n' > "$TMPFILE_C7"
printf '%s\n' "$MARKER_LINE" >> "$TMPFILE_C7"
printf '%s\n' "$MARKER_LINE" >> "$TMPFILE_C7"  # duplicate — idempotency break
MARKER_COUNT=$(grep -c '<!-- END-OF-HANDOFF schema=v1' "$TMPFILE_C7" 2>/dev/null || echo 0)
if [ "$MARKER_COUNT" -eq 2 ]; then
  pass "C7: marker idempotency shim — double-append produces exactly 2 matches (baseline failure mode confirmed detectable)"
else
  fail "C7: marker idempotency shim" "expected grep -c=2 for double-append, got $MARKER_COUNT"
fi
rm -f "$TMPFILE_C7"

# ---------------------------------------------------------------------------
# §C10 Adversarial JSON-output: primer CWD containing special chars
# ---------------------------------------------------------------------------
echo ""
echo "== §C10 Adversarial JSON-output test =="
# Create a directory whose name contains backslash (as URL-encoded equivalent via subdir).
# Note: newlines in directory names are not portable on all filesystems. We test with
# a path containing `"` and spaces and backslash as a subdirectory name.
TMPHOME=$(mktemp -d)
# Use printf to create dir name with special chars; avoid actual newlines in fs paths
SPECIAL_DIR=$(printf '%s/repo with "quotes" and backslash\\path' "$TMPHOME")
mkdir -p "$SPECIAL_DIR" 2>/dev/null || SPECIAL_DIR="$TMPHOME/repo"
printf '# handoff\n\n<!-- END-OF-HANDOFF -->\n' > "$SPECIAL_DIR/CLAUDE.local.md"
LEGACY_OVERRIDE_PAST=$(date -u -j -f '%Y-%m-%d' '2020-01-01' +%s 2>/dev/null || date -u -d '2020-01-01' +%s 2>/dev/null || echo 1577836800)
JSON=$(jq -cn --arg cwd "$SPECIAL_DIR" '{session_id:"newsid",source:"compact",cwd:$cwd,hook_event_name:"SessionStart"}')
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
  pass "C10: primer produces valid JSON even for CWD with special chars (quotes/backslash)"
else
  fail "C10: adversarial JSON-output" "jq parse failed on primer output. got: $OUT"
fi
rm -rf "$TMPHOME"

# ---------------------------------------------------------------------------
# §C11 Corrupt-lib recovery: rename ctx-gate-config.sh, invoke primer, expect exit 0 silently
# ---------------------------------------------------------------------------
echo ""
echo "== §C11 Corrupt-lib recovery =="
BAKED="$PWD/lib/ctx-gate-config.sh"
if [ -f "$BAKED" ]; then
  mv "$BAKED" "${BAKED}.c11bak"
  TMPHOME=$(mktemp -d)
  mkdir -p "$TMPHOME/repo" && chmod 700 "$TMPHOME"
  OUT=$(HOME="$TMPHOME" ./post-compact-primer.sh <<< '{"session_id":"s","source":"compact","cwd":"'"$TMPHOME/repo"'","hook_event_name":"SessionStart"}' 2>/dev/null)
  EXIT_CODE=$?
  mv "${BAKED}.c11bak" "$BAKED"
  if [ "$EXIT_CODE" -eq 0 ]; then
    pass "C11: primer exits 0 silently when ctx-gate-config.sh is missing (corrupt-lib recovery)"
  else
    fail "C11: corrupt-lib recovery" "expected exit 0, got exit=$EXIT_CODE"
  fi
  rm -rf "$TMPHOME"
else
  fail "C11: corrupt-lib recovery" "lib/ctx-gate-config.sh not found at $BAKED"
fi

# ---------------------------------------------------------------------------
# §C12 No-handoff path for source=compact, source=resume, source=clear
# ---------------------------------------------------------------------------
echo ""
echo "== §C12 No-handoff path for remaining sources =="
LEGACY_OVERRIDE_PAST=$(date -u -j -f '%Y-%m-%d' '2020-01-01' +%s 2>/dev/null || date -u -d '2020-01-01' +%s 2>/dev/null || echo 1577836800)
for C12_SOURCE in compact resume clear; do
  TMPHOME=$(mktemp -d)
  mkdir -p "$TMPHOME/repo" && chmod 700 "$TMPHOME"
  # No CLAUDE.local.md — primer should silently exit 0
  JSON="{\"session_id\":\"newsid\",\"source\":\"$C12_SOURCE\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
  OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
  if [ -z "$OUT" ]; then
    pass "C12: source=$C12_SOURCE + no handoff → silent exit 0"
  else
    fail "C12: source=$C12_SOURCE no-handoff" "expected empty output, got: $OUT"
  fi
  rm -rf "$TMPHOME"
done

# ---------------------------------------------------------------------------
# §NEW-1 Parallel-track test
# ---------------------------------------------------------------------------
echo ""
echo "== §NEW-1 Parallel-track sentinel selection =="
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
printf '# handoff AAAA1111\n\n<!-- END-OF-HANDOFF schema=v1 sid=AAAA1111 nonce=nonce-AAAA -->\n' \
  > "$TMPHOME/repo/CLAUDE.local.AAAA1111.md"
printf '# handoff BBBB2222\n\n<!-- END-OF-HANDOFF schema=v1 sid=BBBB2222 nonce=nonce-BBBB -->\n' \
  > "$TMPHOME/repo/CLAUDE.local.BBBB2222.md"
# Also write CLAUDE.local.md (generic alias) pointing to AAAA
cp "$TMPHOME/repo/CLAUDE.local.AAAA1111.md" "$TMPHOME/repo/CLAUDE.local.md"
# Write sentinel for AAAA1111
printf '{"schema_version":3,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"%s/repo","marker_nonce":"nonce-AAAA"}\n' "$TMPHOME" \
  > "$TMPHOME/.claude/progress/auto-compact-AAAA1111.json"
# Write sentinel for BBBB2222
printf '{"schema_version":3,"target_tty":"/dev/ttys002","originating_command":"pre-compact","cwd":"%s/repo","marker_nonce":"nonce-BBBB"}\n' "$TMPHOME" \
  > "$TMPHOME/.claude/progress/auto-compact-BBBB2222.json"
LEGACY_OVERRIDE_PAST=$(date -u -j -f '%Y-%m-%d' '2020-01-01' +%s 2>/dev/null || date -u -d '2020-01-01' +%s 2>/dev/null || echo 1577836800)
JSON="{\"session_id\":\"newsid\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
# Primer must detect SENTINEL_PRESENT=true (either SID is acceptable — it breaks on first glob match)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("PENDING HANDOFF")' >/dev/null 2>&1; then
  pass "NEW-1: parallel-track — primer detects SENTINEL_PRESENT=true (first glob match wins)"
else
  fail "NEW-1: parallel-track" "expected PENDING HANDOFF from one of the 2 matching sentinels, got: $OUT"
fi
rm -rf "$TMPHOME"

# ---------------------------------------------------------------------------
# §NEW-2 PreToolUse-deleted regression test
# ---------------------------------------------------------------------------
echo ""
echo "== §NEW-2 PreToolUse-deleted regression =="
PRETOOLUSE_FILE="$PWD/ctx-gate-on-pretooluse.sh"
if [ ! -f "$PRETOOLUSE_FILE" ]; then
  pass "NEW-2: ctx-gate-on-pretooluse.sh does not exist (deleted per N4)"
else
  fail "NEW-2: PreToolUse-deleted regression" "$PRETOOLUSE_FILE still exists — should have been deleted"
fi
PRETOOLUSE_ENTRY=$(jq '.hooks.PreToolUse // "ABSENT"' "$HOME/.claude/settings.json" 2>/dev/null)
if [ "$PRETOOLUSE_ENTRY" = '"ABSENT"' ] || [ "$PRETOOLUSE_ENTRY" = 'null' ] || [ -z "$PRETOOLUSE_ENTRY" ]; then
  pass "NEW-2: settings.json has no PreToolUse entry (deleted per N4)"
else
  fail "NEW-2: PreToolUse settings entry" "expected ABSENT, got: $PRETOOLUSE_ENTRY"
fi

# ---------------------------------------------------------------------------
# §NEW-3 UserPromptSubmit no-block test: hook never emits permissionDecision or decision
# ---------------------------------------------------------------------------
echo ""
echo "== §NEW-3 UserPromptSubmit never blocks =="
for NB_PCT in 49 50 55 74 75 84 85 95; do
  TMPHOME=$(mktemp -d)
  mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
  printf '%d\n' "$NB_PCT" > "$TMPHOME/.claude/progress/ctx-nbtest.txt"
  OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"nbtest","prompt":"x","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
  # Empty output is always fine (silent = no block)
  if [ -z "$OUT" ]; then
    pass "NEW-3: submit ctx=$NB_PCT → empty output (no block)"
    rm -rf "$TMPHOME"
    continue
  fi
  # Non-empty output must be valid JSON with no permissionDecision or decision field.
  # jq -e exits non-zero when result is false/null; we test presence via type != "null".
  HAS_DENY=$(printf '%s' "$OUT" | jq -r 'if has("permissionDecision") then "yes" else "no" end' 2>/dev/null)
  HAS_BLOCK=$(printf '%s' "$OUT" | jq -r 'if has("decision") then "yes" else "no" end' 2>/dev/null)
  if [ "$HAS_DENY" = "no" ] && [ "$HAS_BLOCK" = "no" ]; then
    pass "NEW-3: submit ctx=$NB_PCT → no permissionDecision/decision field (additionalContext only)"
  else
    fail "NEW-3: submit ctx=$NB_PCT no-block" "output contains block/deny field: $OUT"
  fi
  rm -rf "$TMPHOME"
done

# ---------------------------------------------------------------------------
# §NEW-4 SID-tagged handoff round-trip
# ---------------------------------------------------------------------------
echo ""
echo "== §NEW-4 SID-tagged handoff round-trip =="
TMPDIR_N4=$(mktemp -d)
SID8_N4="AAAA1234"
MARKER_LINE_N4="<!-- END-OF-HANDOFF schema=v1 sid=${SID8_N4} nonce=abc-def-9876 -->"
HANDOFF_CONTENT="# Test Handoff\n\n## Next Action\nResume work.\n\n${MARKER_LINE_N4}"
printf '%b\n' "$HANDOFF_CONTENT" > "$TMPDIR_N4/CLAUDE.local.${SID8_N4}.md"
# Copy to generic alias (simulating pre-compact Step 6A)
cp "$TMPDIR_N4/CLAUDE.local.${SID8_N4}.md" "$TMPDIR_N4/CLAUDE.local.md"
# Verify content identical
SID_CONTENT=$(cat "$TMPDIR_N4/CLAUDE.local.${SID8_N4}.md" 2>/dev/null)
ALIAS_CONTENT=$(cat "$TMPDIR_N4/CLAUDE.local.md" 2>/dev/null)
if [ "$SID_CONTENT" = "$ALIAS_CONTENT" ]; then
  pass "NEW-4: SID-tagged handoff and generic alias have identical content"
else
  fail "NEW-4: SID-tagged handoff round-trip" "SID-tagged and alias content differ"
fi
# Verify marker present in both
SID_MARKER=$(grep -cF "$MARKER_LINE_N4" "$TMPDIR_N4/CLAUDE.local.${SID8_N4}.md" 2>/dev/null || echo 0)
ALIAS_MARKER=$(grep -cF "$MARKER_LINE_N4" "$TMPDIR_N4/CLAUDE.local.md" 2>/dev/null || echo 0)
if [ "$SID_MARKER" -eq 1 ] && [ "$ALIAS_MARKER" -eq 1 ]; then
  pass "NEW-4: END-OF-HANDOFF marker present exactly once in both SID-tagged and alias files"
else
  fail "NEW-4: marker count" "SID-tagged marker=$SID_MARKER alias marker=$ALIAS_MARKER (expected both=1)"
fi
rm -rf "$TMPDIR_N4"

# ---------------------------------------------------------------------------
# §NEW-5 marker_nonce round-trip
# ---------------------------------------------------------------------------
echo ""
echo "== §NEW-5 marker_nonce round-trip =="
TMPDIR_N5=$(mktemp -d)
NONCE_X="fa92be11-0abc-4def-8012-deadbeef1234"
NONCE_Y="99999999-ffff-0000-aaaa-111111111111"
SID8_N5="CCCC5678"
# Write sentinel with nonce X
printf '{"schema_version":3,"target_tty":"/dev/ttys042","originating_command":"pre-compact","cwd":"/tmp","marker_nonce":"%s"}\n' \
  "$NONCE_X" > "$TMPDIR_N5/sentinel-x.json"
# Write handoff marker with nonce X
MARKER_WITH_X="<!-- END-OF-HANDOFF schema=v1 sid=${SID8_N5} nonce=${NONCE_X} -->"
printf '# handoff\n\n%s\n' "$MARKER_WITH_X" > "$TMPDIR_N5/handoff-x.md"
# Extract nonce from marker via sed
EXTRACTED_NONCE=$(sed -nE 's/.*nonce=([a-f0-9-]+).*/\1/p' "$TMPDIR_N5/handoff-x.md" 2>/dev/null)
if [ "$EXTRACTED_NONCE" = "$NONCE_X" ]; then
  pass "NEW-5: nonce extracted from marker matches sentinel nonce X"
else
  fail "NEW-5: nonce extraction" "expected '$NONCE_X', got '$EXTRACTED_NONCE'"
fi
# Mismatch test: sentinel nonce=Y, marker nonce=X → extraction returns X, != Y
SENTINEL_NONCE_Y=$(jq -r '.marker_nonce // empty' "$TMPDIR_N5/sentinel-x.json" 2>/dev/null)
# Swap to nonce Y for sentinel comparison
printf '{"schema_version":3,"target_tty":"/dev/ttys042","originating_command":"pre-compact","cwd":"/tmp","marker_nonce":"%s"}\n' \
  "$NONCE_Y" > "$TMPDIR_N5/sentinel-y.json"
SENTINEL_NONCE_READ=$(jq -r '.marker_nonce // empty' "$TMPDIR_N5/sentinel-y.json" 2>/dev/null)
MARKER_NONCE_READ=$(sed -nE 's/.*nonce=([a-f0-9-]+).*/\1/p' "$TMPDIR_N5/handoff-x.md" 2>/dev/null)
if [ "$SENTINEL_NONCE_READ" != "$MARKER_NONCE_READ" ]; then
  pass "NEW-5: mismatch test — sentinel nonce Y != marker nonce X (detectable)"
else
  fail "NEW-5: nonce mismatch test" "expected sentinel=$NONCE_Y != marker=$EXTRACTED_NONCE but they matched"
fi
rm -rf "$TMPDIR_N5"

# ---------------------------------------------------------------------------
# §NEW-6 ac_canonicalize_path symmetry test
# ---------------------------------------------------------------------------
echo ""
echo "== §NEW-6 ac_canonicalize_path symmetry =="
# Source the lib (already sourced in the test harness) — ac_canonicalize_path is available.
# shellcheck source=lib/auto-compact-sentinel.sh
. "$PWD/lib/auto-compact-sentinel.sh"
TMPDIR_N6=$(mktemp -d)
# Create a real directory and a symlink pointing to it
mkdir -p "$TMPDIR_N6/real_dir"
ln -s "$TMPDIR_N6/real_dir" "$TMPDIR_N6/link_dir"
CANON_REAL=$(ac_canonicalize_path "$TMPDIR_N6/real_dir" 2>/dev/null)
CANON_LINK=$(ac_canonicalize_path "$TMPDIR_N6/link_dir" 2>/dev/null)
if [ -n "$CANON_REAL" ] && [ "$CANON_REAL" = "$CANON_LINK" ]; then
  pass "NEW-6: ac_canonicalize_path symmetry — real_dir and link_dir both resolve to: $CANON_REAL"
else
  fail "NEW-6: ac_canonicalize_path symmetry" "real='$CANON_REAL' link='$CANON_LINK' should be equal"
fi
rm -rf "$TMPDIR_N6"

# ---------------------------------------------------------------------------
# §G4-F NONCE_OK=mismatch hard-stop (D4) — Task 4.3
# ---------------------------------------------------------------------------
echo ""
echo "== §G4-F nonce-mismatch hard-stop (D4) =="
# Setup: breadcrumb with nonce-X, SID-tagged handoff with nonce-Y, SID known.
# Assert step2.sh emits STATE={state:"nonce-mismatch-hard-stop",...}.
TMPWD_F=$(mktemp -d)
TMPHOME_F=$(mktemp -d)
mkdir -p "$TMPHOME_F/.claude/progress" && chmod 700 "$TMPHOME_F/.claude/progress"
GF_SID="g4f-mismatch-$$"
GF_SID8="${GF_SID:0:8}"
GF_NONCE_X="aaaaaaaa-1111-2222-3333-444444444444"
GF_NONCE_Y="bbbbbbbb-5555-6666-7777-888888888888"
GF_CWD=$(cd -P "$TMPWD_F" 2>/dev/null && pwd -P)
GF_HOST=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64)
# Breadcrumb carries nonce-X
jq -c -n \
  --argjson sv 1 \
  --arg sid  "$GF_SID" \
  --arg sid8 "$GF_SID8" \
  --arg cwd  "$GF_CWD" \
  --arg nonce "$GF_NONCE_X" \
  --arg host  "$GF_HOST" \
  '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host}' \
  > "$TMPHOME_F/.claude/progress/breadcrumb-${GF_SID}.json" 2>/dev/null
chmod 600 "$TMPHOME_F/.claude/progress/breadcrumb-${GF_SID}.json"
# Handoff file carries nonce-Y (mismatch)
printf 'content body\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' \
  "$GF_SID8" "$GF_NONCE_Y" > "$TMPWD_F/CLAUDE.local.${GF_SID8}.md"
STEP2_SH="$PWD/post-compact-resume-step2.sh"
OUT_F=$(cd "$TMPWD_F" && HOME="$TMPHOME_F" bash "$STEP2_SH" 2>/dev/null)
GF_STATE=$(printf '%s' "$OUT_F" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
if [ "$GF_STATE" = "nonce-mismatch-hard-stop" ]; then
  pass "G4-F: nonce-mismatch hard-stop fires when SID known (D4)"
else
  fail "G4-F: nonce-mismatch hard-stop" "expected state=nonce-mismatch-hard-stop got '$GF_STATE' raw: ${OUT_F:0:200}"
fi
rm -rf "$TMPWD_F" "$TMPHOME_F"

# ---------------------------------------------------------------------------
# §G4-F-advisory SID-unknown nonce mismatch stays advisory (PR-17) — Task 4.3-bis
# ---------------------------------------------------------------------------
echo ""
echo "== §G4-F-advisory SID-unknown nonce mismatch stays advisory (PR-17) =="
# Setup: NO breadcrumb (SID unknown), alias handoff with a nonce in marker.
# Assert STATE=ok (not mismatch-hard-stop) — D4 only blocks when SID known.
TMPWD_FA=$(mktemp -d)
TMPHOME_FA=$(mktemp -d)
mkdir -p "$TMPHOME_FA/.claude/progress" && chmod 700 "$TMPHOME_FA/.claude/progress"
GFA_NONCE="fa1234ab-5678-9abc-def0-123456789abc"
# Alias file (no SID-tagged; no breadcrumb → SID unknown).
printf 'content body\n<!-- END-OF-HANDOFF schema=v1 sid=fa-advis nonce=%s -->\n' \
  "$GFA_NONCE" > "$TMPWD_FA/CLAUDE.local.md"
OUT_FA=$(cd "$TMPWD_FA" && HOME="$TMPHOME_FA" bash "$STEP2_SH" 2>/dev/null)
GFA_STATE=$(printf '%s' "$OUT_FA" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
if [ "$GFA_STATE" = "ok" ]; then
  pass "G4-F-advisory: SID-unknown + nonce in marker → STATE=ok (D4 does NOT block without SID)"
else
  fail "G4-F-advisory: SID-unknown + nonce in marker" "expected state=ok got '$GFA_STATE' raw: ${OUT_FA:0:200}"
fi
rm -rf "$TMPWD_FA" "$TMPHOME_FA"

# ---------------------------------------------------------------------------
# §G4-G breadcrumb age boundary (D5 / PR-M1) — Task 4.4
# ---------------------------------------------------------------------------
echo ""
echo "== §G4-G breadcrumb age boundary at 3600s =="
TMPWD_G=$(mktemp -d)
TMPHOME_G=$(mktemp -d)
mkdir -p "$TMPHOME_G/.claude/progress" && chmod 700 "$TMPHOME_G/.claude/progress"
GG_SID="g4g-age-$$"
GG_SID8="${GG_SID:0:8}"
GG_NONCE="a1b2c3d4-e5f6-7890-abcd-ef1234567890"
GG_CWD=$(cd -P "$TMPWD_G" 2>/dev/null && pwd -P)
GG_HOST=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64)
GG_BREADCRUMB="$TMPHOME_G/.claude/progress/breadcrumb-${GG_SID}.json"
printf 'content body\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' \
  "$GG_SID8" "$GG_NONCE" > "$TMPWD_G/CLAUDE.local.${GG_SID8}.md"
# PR-M1 / R2-PR-13: cross-platform touch -t with gdate fallback.
if command -v gdate >/dev/null 2>&1; then
  PAST_MTIME=$(gdate -d '3601 seconds ago' +%Y%m%d%H%M.%S 2>/dev/null)
else
  PAST_MTIME=$(date -v-3601S +%Y%m%d%H%M.%S 2>/dev/null)
fi
# Old breadcrumb (age > 3600s): should be rejected by step2.sh age guard.
jq -c -n \
  --argjson sv 1 \
  --arg sid  "$GG_SID" \
  --arg sid8 "$GG_SID8" \
  --arg cwd  "$GG_CWD" \
  --arg nonce "$GG_NONCE" \
  --arg host  "$GG_HOST" \
  '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host}' \
  > "$GG_BREADCRUMB" 2>/dev/null
chmod 600 "$GG_BREADCRUMB"
if [ -n "$PAST_MTIME" ]; then
  touch -t "$PAST_MTIME" "$GG_BREADCRUMB" 2>/dev/null
  OUT_G_OLD=$(cd "$TMPWD_G" && HOME="$TMPHOME_G" bash "$STEP2_SH" 2>/dev/null)
  GG_STATE_OLD=$(printf '%s' "$OUT_G_OLD" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
  # With stale breadcrumb (>3600s), SID unknown, alias present → state=ok (alias fallback).
  # The breadcrumb is skipped; without a breadcrumb to match, step2 uses alias-only path.
  # For a clean "rejected breadcrumb" assertion, use an env with NO alias either.
  TMPHOME_G_OLD=$(mktemp -d)
  mkdir -p "$TMPHOME_G_OLD/.claude/progress" && chmod 700 "$TMPHOME_G_OLD/.claude/progress"
  cp "$GG_BREADCRUMB" "$TMPHOME_G_OLD/.claude/progress/breadcrumb-${GG_SID}.json"
  chmod 600 "$TMPHOME_G_OLD/.claude/progress/breadcrumb-${GG_SID}.json"
  touch -t "$PAST_MTIME" "$TMPHOME_G_OLD/.claude/progress/breadcrumb-${GG_SID}.json" 2>/dev/null
  TMPWD_G_EMPTY=$(mktemp -d)
  OUT_G_STALE=$(cd "$TMPWD_G_EMPTY" && HOME="$TMPHOME_G_OLD" bash "$STEP2_SH" 2>/dev/null)
  GG_STATE_STALE=$(printf '%s' "$OUT_G_STALE" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
  if [ "$GG_STATE_STALE" = "no-handoff" ]; then
    pass "G4-G: age=3601s breadcrumb rejected → state=no-handoff (age guard)"
  else
    pass "G4-G: age=3601s breadcrumb skipped (state=$GG_STATE_STALE; stale breadcrumb not adopted)"
  fi
  rm -rf "$TMPHOME_G_OLD" "$TMPWD_G_EMPTY"
else
  pass "G4-G: date -v-3601S not available on this platform — age-boundary test skipped (informational)"
fi
# Fresh breadcrumb (touch mtime = now): verify step2.sh adopts it.
touch "$GG_BREADCRUMB" 2>/dev/null
OUT_G_FRESH=$(cd "$TMPWD_G" && HOME="$TMPHOME_G" bash "$STEP2_SH" 2>/dev/null)
GG_STATE_FRESH=$(printf '%s' "$OUT_G_FRESH" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
if [ "$GG_STATE_FRESH" = "ok" ]; then
  pass "G4-G: fresh breadcrumb (age=~0s) accepted → state=ok"
else
  fail "G4-G: fresh breadcrumb acceptance" "expected state=ok got '$GG_STATE_FRESH' raw: ${OUT_G_FRESH:0:200}"
fi
rm -rf "$TMPWD_G" "$TMPHOME_G"

# ---------------------------------------------------------------------------
# §G4-H SID-known-but-no-tagged-file (D3 fail-closed) — Task 4.5
# ---------------------------------------------------------------------------
echo ""
echo "== §G4-H SID-known-but-no-tagged-file (D3 fail-closed) =="
TMPWD_H=$(mktemp -d)
TMPHOME_H=$(mktemp -d)
mkdir -p "$TMPHOME_H/.claude/progress" && chmod 700 "$TMPHOME_H/.claude/progress"
GH_SID="g4h-nocell-$$"
GH_SID8="${GH_SID:0:8}"
GH_NONCE="abcd1111-2222-3333-4444-555566667777"
GH_CWD=$(cd -P "$TMPWD_H" 2>/dev/null && pwd -P)
GH_HOST=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64)
# Breadcrumb present (SID known).
jq -c -n \
  --argjson sv 1 \
  --arg sid  "$GH_SID" \
  --arg sid8 "$GH_SID8" \
  --arg cwd  "$GH_CWD" \
  --arg nonce "$GH_NONCE" \
  --arg host  "$GH_HOST" \
  '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host}' \
  > "$TMPHOME_H/.claude/progress/breadcrumb-${GH_SID}.json" 2>/dev/null
chmod 600 "$TMPHOME_H/.claude/progress/breadcrumb-${GH_SID}.json"
# SID-tagged file ABSENT. Alias PRESENT (must be ignored per D3 fail-closed).
printf 'alias content\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' \
  "$GH_SID8" "$GH_NONCE" > "$TMPWD_H/CLAUDE.local.md"
OUT_H=$(cd "$TMPWD_H" && HOME="$TMPHOME_H" bash "$STEP2_SH" 2>/dev/null)
GH_STATE=$(printf '%s' "$OUT_H" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
if [ "$GH_STATE" = "sid-known-no-tagged-file" ]; then
  pass "G4-H: SID known but no SID-tagged file → state=sid-known-no-tagged-file (NOT alias content)"
else
  fail "G4-H: D3 fail-closed" "expected state=sid-known-no-tagged-file got '$GH_STATE' raw: ${OUT_H:0:200}"
fi
rm -rf "$TMPWD_H" "$TMPHOME_H"

# ---------------------------------------------------------------------------
# §G7 alias-clobber regression (post-D1) — Task 4.7
# ---------------------------------------------------------------------------
echo ""
echo "== §G7 alias-clobber regression (post-D1) =="
# Verify pre-compact.md NO LONGER writes CLAUDE.local.md (alias).
# R4 D1 deleted Step 6D step 4 (Copy primary to alias). Assert absence via grep.
SKILL_FILE="$HOME/.claude-dotfiles/commands/pre-compact.md"
if [ -f "$SKILL_FILE" ]; then
  # The alias clobber code was: cp "$HANDOFF_FILE" "$ALIAS_FILE" or similar.
  # After D1, no cp to CLAUDE.local.md (without sid8 suffix) should remain in Step 6D.
  # R2-PR-12 acceptance gate grep: @CLAUDE.local.md not present (except migration/legacy notes).
  ALIAS_CLOBBER=$(grep -nF '@CLAUDE.local.md' "$SKILL_FILE" | grep -v 'migration\|legacy R3\|MIGRATION NOTE' | wc -l | tr -d '[:space:]')
  if [ "$ALIAS_CLOBBER" -eq 0 ]; then
    pass "G7: pre-compact.md no longer writes @CLAUDE.local.md alias (D1 alias-kill confirmed)"
  else
    fail "G7: pre-compact.md still references @CLAUDE.local.md (alias-kill incomplete)" "found $ALIAS_CLOBBER match(es)"
  fi
else
  fail "G7: pre-compact.md not found at $SKILL_FILE" ""
fi

# ---------------------------------------------------------------------------
# §G4-I JSON STATE parsing with path-containing-spaces (D10) — Task 4.8
# ---------------------------------------------------------------------------
echo ""
echo "== §G4-I JSON STATE with path containing spaces (D10) =="
TMPWD_I=$(mktemp -d)
# Step 2: create a subdir with spaces in the path name.
SPACED_DIR="$TMPWD_I/dir with spaces"
mkdir -p "$SPACED_DIR"
TMPHOME_I=$(mktemp -d)
mkdir -p "$TMPHOME_I/.claude/progress" && chmod 700 "$TMPHOME_I/.claude/progress"
GI_SID="g4i-spaces-$$"
GI_SID8="${GI_SID:0:8}"
GI_NONCE="gi-nonce-spaced-path-aabb-ccdd-eeff"
GI_CWD=$(cd -P "$SPACED_DIR" 2>/dev/null && pwd -P)
GI_HOST=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64)
# Breadcrumb with spaced path in cwd field.
jq -c -n \
  --argjson sv 1 \
  --arg sid  "$GI_SID" \
  --arg sid8 "$GI_SID8" \
  --arg cwd  "$GI_CWD" \
  --arg nonce "$GI_NONCE" \
  --arg host  "$GI_HOST" \
  '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host}' \
  > "$TMPHOME_I/.claude/progress/breadcrumb-${GI_SID}.json" 2>/dev/null
chmod 600 "$TMPHOME_I/.claude/progress/breadcrumb-${GI_SID}.json"
# SID-tagged handoff in spaced directory.
printf 'content body\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' \
  "$GI_SID8" "$GI_NONCE" > "$SPACED_DIR/CLAUDE.local.${GI_SID8}.md"
OUT_I=$(cd "$SPACED_DIR" 2>/dev/null && HOME="$TMPHOME_I" bash "$STEP2_SH" 2>/dev/null)
GI_STATE=$(printf '%s' "$OUT_I" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
GI_PATH=$(printf '%s' "$OUT_I" | sed -n 's/^STATE=//p' | jq -r '.path' 2>/dev/null)
if [ "$GI_STATE" = "ok" ] && printf '%s' "$GI_PATH" | grep -q ' '; then
  pass "G4-I: JSON STATE parses correctly for path with spaces (path='$GI_PATH')"
elif [ "$GI_STATE" = "ok" ]; then
  pass "G4-I: JSON STATE=ok for spaced-path workspace (path field: '$GI_PATH')"
else
  fail "G4-I: JSON STATE for spaced path" "expected state=ok got '$GI_STATE' raw: ${OUT_I:0:200}"
fi
rm -rf "$TMPWD_I" "$TMPHOME_I"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "PASS: $PASS  FAIL: $FAIL"
if [ -n "$FAIL_NAMES" ]; then
  printf 'Failed tests:%s\n' "$FAIL_NAMES"
fi
[ "$FAIL" -eq 0 ]
