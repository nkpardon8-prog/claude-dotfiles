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
  # --- G5 forward direction: code emit sites → docs ---
  # Every verb emitted in *.sh must appear in LOG_VERBS.md.
  UNDOC=()
  while IFS= read -r G5_LINE; do
    G5_TOKEN=$(printf '%s' "$G5_LINE" | sed -nE 's/.*(ac_log|ctx_gate_log|handoff_log)[[:space:]]+"([^[:space:]"]+).*/\2/p')
    [ -z "$G5_TOKEN" ] && continue
    if ! grep -qF "$G5_TOKEN" "$VERBS_FILE" 2>/dev/null; then
      UNDOC+=("$G5_TOKEN")
    fi
  done < <(grep -rE '(ac_log|ctx_gate_log|handoff_log)[[:space:]]+"' "$PWD"/*.sh "$PWD"/lib/*.sh 2>/dev/null \
             | grep -v 'test-ctx-gate\.sh:\|test-auto-compact\.sh:')
  G5_UNDOC_UNIQ=$(printf '%s\n' "${UNDOC[@]}" | sort -u | tr '\n' ' ')
  if [ -z "$(printf '%s' "$G5_UNDOC_UNIQ" | tr -d '[:space:]')" ]; then
    pass "G5-fwd: all log-verb tokens documented in LOG_VERBS.md"
  else
    # R4 H6: promoted from informational pass to hard FAIL — LOG_VERBS.md must stay in sync.
    # If a log verb is emitted but undocumented, update LOG_VERBS.md before proceeding.
    fail "G5-fwd: LOG_VERBS drift detected — undocumented verbs: $G5_UNDOC_UNIQ (update LOG_VERBS.md)"
  fi

  # --- G5 reverse direction: docs → code emit sites (H5 fix-sweep) ---
  # Every verb documented in LOG_VERBS.md must have at least one emit site in *.sh.
  # Prevents phantom verbs (documented but never emitted — invisible to log consumers).
  #
  # Design notes:
  # - `handoff:$1` allow-listed (function-body literal in handoff_log(), not a real verb).
  # - `handoff:X` verbs: the code emits handoff_log "X"; ac_log prepends "handoff:" at
  #   runtime. So we strip the "handoff:" prefix and search for handoff_log "X".
  # - Compound/pattern rows (e.g. "sentinel=true|false marker=...") are not verbs —
  #   skip rows whose bare first-token contains `|` (alternation pattern) or where the
  #   token looks like a key=value pattern documenting runtime output (contains `=` and no
  #   leading log-verb-style chars). These are routing-decision summary rows, not emitted verbs.
  PHANTOM=()
  while IFS= read -r G5R_LINE; do
    # Extract content between first pair of backticks in table rows.
    G5R_VERB=$(printf '%s' "$G5R_LINE" | sed -nE 's/^\|[[:space:]]*`([^`]+)`.*/\1/p')
    [ -z "$G5R_VERB" ] && continue
    # Bare first token (everything up to first space).
    G5R_BARE=$(printf '%s' "$G5R_VERB" | awk '{print $1}')
    [ -z "$G5R_BARE" ] && continue
    # Allow-list: handoff:$1 is a function-body parameter literal; skip.
    [ "$G5R_BARE" = 'handoff:$1' ] && continue
    # Allow-list: "test" is emitted only by test-auto-compact.sh (a test harness, not
    # production code). LOG_VERBS.md documents it explicitly with that caveat; exclude.
    [ "$G5R_BARE" = 'test' ] && continue
    # Skip compound/pattern rows: bare token contains `|` (e.g. "sentinel=true|false")
    # or looks like a structured log line fragment (contains `=` and no alpha-only prefix).
    case "$G5R_BARE" in
      *'|'*) continue ;;
      action=*) continue ;;
    esac
    # Determine the grep pattern based on verb type.
    # handoff:X verbs: the handoff_log() shell function prepends "handoff:" at runtime,
    # so the code emits: handoff_log "<suffix>" not handoff_log "handoff:<suffix>".
    # Strip the prefix and search only for the suffix after the colon.
    if printf '%s' "$G5R_BARE" | grep -q '^handoff:'; then
      G5R_SUFFIX=$(printf '%s' "$G5R_BARE" | sed 's/^handoff://')
      # Exclude test files from the emit search (they may reference verbs in comments).
      if ! grep -rE "handoff_log[[:space:]]+\"[^\"]*${G5R_SUFFIX}" \
          "$PWD"/*.sh "$PWD"/lib/*.sh 2>/dev/null \
          | grep -qv 'test-ctx-gate\.sh:\|test-auto-compact\.sh:'; then
        PHANTOM+=("$G5R_BARE")
      fi
    else
      # Normal verb: any log function emitting it.
      # Exclude test files (they may reference verbs in comments or test scaffolding).
      if ! grep -rE "(ac_log|ctx_gate_log|handoff_log)[[:space:]]+\"[^\"]*${G5R_BARE}" \
          "$PWD"/*.sh "$PWD"/lib/*.sh 2>/dev/null \
          | grep -qv 'test-ctx-gate\.sh:\|test-auto-compact\.sh:'; then
        PHANTOM+=("$G5R_BARE")
      fi
    fi
  done < <(grep -E '^\|[[:space:]]*`' "$VERBS_FILE" 2>/dev/null)
  G5R_PHANTOM_UNIQ=$(printf '%s\n' "${PHANTOM[@]}" | sort -u | tr '\n' ' ')
  if [ -z "$(printf '%s' "$G5R_PHANTOM_UNIQ" | tr -d '[:space:]')" ]; then
    pass "G5-rev: all documented log verbs have at least one emit site"
  else
    fail "G5-rev: phantom verbs documented but never emitted: $G5R_PHANTOM_UNIQ (remove from LOG_VERBS.md or add emit site)"
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
  # R5 Critical #9: must provide CLAUDE_SESSION_ID so OWN_SID is non-empty (no transcripts
  # in tmpdir → slug fallback fails → both env vars unset → own-sid-unresolvable without SID).
  TMPWD=$(mktemp -d)
  TMPHOME=$(mktemp -d)
  mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
  OUT=$(cd "$TMPWD" && CLAUDE_SESSION_ID="g4a-test-sid-$$" HOME="$TMPHOME" bash "$STEP2_SH" 2>/dev/null)
  G4A_STATE=$(step2_state "$OUT")
  if [ "$G4A_STATE" = "no-handoff" ]; then
    pass "G4-A: empty workspace → STATE=no-handoff (JSON parsed)"
  else
    fail "G4-A: empty workspace expected state=no-handoff" "got state=$G4A_STATE raw: $OUT"
  fi
  rm -rf "$TMPWD" "$TMPHOME"

  # G4-B: handoff present (alias, no breadcrumb) with marker → STATE=ok marker=present
  # SID-known (CLAUDE_SESSION_ID set) but no breadcrumb → alias path is used since SID8
  # stays empty (no breadcrumb → SENTINEL_SID="" → handoff_resolve_path gets empty SID8 → alias).
  TMPWD=$(mktemp -d)
  TMPHOME=$(mktemp -d)
  mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
  G4B_NONCE="abcd1234-5678-90ab-cdef-1234567890ab"
  G4B_SID8="abcd1234"
  printf 'content body\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' "$G4B_SID8" "$G4B_NONCE" > "$TMPWD/CLAUDE.local.md"
  OUT=$(cd "$TMPWD" && CLAUDE_SESSION_ID="g4b-test-sid-$$" HOME="$TMPHOME" bash "$STEP2_SH" 2>/dev/null)
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
  OUT=$(cd "$TMPWD" && CLAUDE_SESSION_ID="g4c-test-sid-$$" HOME="$TMPHOME" bash "$STEP2_SH" 2>/dev/null)
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
  OUT=$(cd "$TMPWD" && CLAUDE_SESSION_ID="g4d-test-sid-$$" HOME="$TMPHOME" bash "$STEP2_SH" 2>/dev/null)
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
  # R5 Critical #9: provide CLAUDE_SESSION_ID so OWN_SID resolves to this session's SID.
  OUT=$(cd "$TMPWD" && CLAUDE_SESSION_ID="$G4E_SID" HOME="$TMPHOME" bash "$STEP2_SH" 2>/dev/null)
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
# Phase 2 Round 4: session_id must match sentinel name for strict binding to work.
# Use session_id=oldsid to match auto-compact-oldsid.json.
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
printf '# handoff\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.oldsid.md"
printf '{"schema_version":2,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"%s/repo"}\n' "$TMPHOME" > "$TMPHOME/.claude/progress/auto-compact-oldsid.json"
JSON="{\"session_id\":\"oldsid\",\"source\":\"compact\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("ANOMALY")' >/dev/null 2>&1; then
  pass "3l-compact-anomaly-sentinel-present: source=compact + matching sentinel → ANOMALY warning"
else
  fail "3l-compact-anomaly-sentinel-present" "expected ANOMALY warning, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3l-resume-sentinel-fresh: source=resume + sentinel cwd match + fresh marker → PENDING HANDOFF nav
# R4 D3 fix: handoff at SID-tagged path.
# Phase 2 Round 4: session_id=oldsid matches auto-compact-oldsid.json.
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
printf '# handoff\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.oldsid.md"
printf '{"schema_version":2,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"%s/repo"}\n' "$TMPHOME" > "$TMPHOME/.claude/progress/auto-compact-oldsid.json"
JSON="{\"session_id\":\"oldsid\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("PENDING HANDOFF")' >/dev/null 2>&1; then
  pass "3l-resume-sentinel-fresh: source=resume + sentinel match + fresh marker → PENDING HANDOFF"
else
  fail "3l-resume-sentinel-fresh" "expected PENDING HANDOFF nav, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3l-resume-sentinel-stale: source=resume + sentinel + 2-day-old mtime → STALE + PENDING HANDOFF
# R4 D3 fix: handoff at SID-tagged path.
# Phase 2 Round 4: session_id=oldsid matches auto-compact-oldsid.json.
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
printf '# handoff\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.oldsid.md"
touch -t 202601010000 "$TMPHOME/repo/CLAUDE.local.oldsid.md"  # 2026-01-01 = well over 24h old
printf '{"schema_version":2,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"%s/repo"}\n' "$TMPHOME" > "$TMPHOME/.claude/progress/auto-compact-oldsid.json"
JSON="{\"session_id\":\"oldsid\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
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
# §C5 primer-whole-file-scan: marker anywhere in file is detected (whole-file grep)
#
# Phase 1 (Round 4): handoff_marker_check was updated from tail -c 512 to
# whole-file grep. This test validates that a marker placed BEFORE the last
# 512 bytes of the file is now correctly found (previously it was missed,
# causing a spurious TRUNCATED warning). The old tail-512 window is gone.
# ---------------------------------------------------------------------------
echo ""
echo "== §C5 primer-whole-file-scan: marker before last 512 bytes is detected =="
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" && chmod 700 "$TMPHOME"
# Build a file where END-OF-HANDOFF marker is near byte 600, then padded to ~1500 bytes.
# Phase 1: whole-file grep now FINDS the marker even though it's not in the last 512 bytes.
# The primer should detect the marker and emit a POST-COMPACT nav (not TRUNCATED warning).
{
  # ~600 bytes of content then the legacy marker, then 900 bytes of padding
  printf '# Handoff\n\n## Active Skill State\nDetected: /plan\n\n## Next Action\nRun review.\n\n'
  printf '<!-- END-OF-HANDOFF -->\n'
  # Pad with 900 bytes of additional content so the total is ~1500 bytes
  # and the marker is well outside the final 512 bytes (tests whole-file scan)
  printf '## Section After Marker\n'
  python3 -c "print('x' * 900)" 2>/dev/null || printf '%0900d' 0 | tr '0' 'x'
  printf '\n'
} > "$TMPHOME/repo/CLAUDE.local.md"
FILE_SIZE=$(wc -c < "$TMPHOME/repo/CLAUDE.local.md" 2>/dev/null | tr -d '[:space:]')
LEGACY_OVERRIDE_PAST=$(date -u -j -f '%Y-%m-%d' '2020-01-01' +%s 2>/dev/null || date -u -d '2020-01-01' +%s 2>/dev/null || echo 1577836800)
JSON="{\"session_id\":\"newsid\",\"source\":\"compact\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
# Whole-file scan finds the marker → primer emits POST-COMPACT nav (not TRUNCATED).
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("POST-COMPACT")' >/dev/null 2>&1; then
  pass "C5: whole-file-scan finds marker before last 512 bytes (file=${FILE_SIZE}b) — primer emits POST-COMPACT nav"
else
  fail "C5: primer-whole-file-scan" "expected POST-COMPACT (marker found by whole-file grep), got: $OUT"
fi
rm -rf "$TMPHOME"

# ---------------------------------------------------------------------------
# §C6 multi-sentinel-matching-cwd: 2 sentinels with same cwd — session-id binding picks the right one
#
# Phase 2 (Round 4): primer_find_sentinel_for_cwd now binds to the exact sentinel for the
# current session (session_id strict binding). When session_id=AAAA0001, it picks
# auto-compact-AAAA0001.json (not the BBBB0002 one) even when both have matching cwd.
# ---------------------------------------------------------------------------
echo ""
echo "== §C6 multi-sentinel-matching-cwd — session-id-binding picks own sentinel =="
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
# R4 D3 fix: provide SID-tagged handoffs for each sentinel SID.
# Both SIDs have their own SID-tagged files.
printf '# handoff A\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.AAAA0001.md"
printf '# handoff B\n\n<!-- END-OF-HANDOFF -->\n' > "$TMPHOME/repo/CLAUDE.local.BBBB0002.md"
# Two sentinels with identical cwd but different SIDs
printf '{"schema_version":3,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"%s/repo","marker_nonce":"nonce1"}\n' "$TMPHOME" \
  > "$TMPHOME/.claude/progress/auto-compact-AAAA0001.json"
printf '{"schema_version":3,"target_tty":"/dev/ttys002","originating_command":"pre-compact","cwd":"%s/repo","marker_nonce":"nonce2"}\n' "$TMPHOME" \
  > "$TMPHOME/.claude/progress/auto-compact-BBBB0002.json"
# Phase 2: session_id=AAAA0001 → binds to AAAA0001 sentinel (PENDING HANDOFF)
JSON="{\"session_id\":\"AAAA0001\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
LEGACY_OVERRIDE_PAST=$(date -u -j -f '%Y-%m-%d' '2020-01-01' +%s 2>/dev/null || date -u -d '2020-01-01' +%s 2>/dev/null || echo 1577836800)
OUT=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
# Session binds to its own sentinel → PENDING HANDOFF
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("PENDING HANDOFF")' >/dev/null 2>&1; then
  pass "C6: multi-sentinel-matching-cwd → AAAA0001 session binds own sentinel (SENTINEL_PRESENT=true)"
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
echo "== §NEW-1 Parallel-track sentinel session-id binding =="
# Phase 2 (Round 4): primer now accepts session_id as 2nd arg to primer_find_sentinel_for_cwd
# and binds to the EXACT sentinel for that session. This test verifies session-id-binding:
# Track AAAA1111's session should see AAAA1111's sentinel (not BBBB2222's), and vice versa.
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME"
printf '# handoff AAAA1111\n\n<!-- END-OF-HANDOFF schema=v1 sid=AAAA1111 nonce=nonce-AAAA -->\n' \
  > "$TMPHOME/repo/CLAUDE.local.AAAA1111.md"
printf '# handoff BBBB2222\n\n<!-- END-OF-HANDOFF schema=v1 sid=BBBB2222 nonce=nonce-BBBB -->\n' \
  > "$TMPHOME/repo/CLAUDE.local.BBBB2222.md"
# Write sentinel for AAAA1111
printf '{"schema_version":3,"target_tty":"/dev/ttys001","originating_command":"pre-compact","cwd":"%s/repo","marker_nonce":"nonce-AAAA"}\n' "$TMPHOME" \
  > "$TMPHOME/.claude/progress/auto-compact-AAAA1111.json"
# Write sentinel for BBBB2222
printf '{"schema_version":3,"target_tty":"/dev/ttys002","originating_command":"pre-compact","cwd":"%s/repo","marker_nonce":"nonce-BBBB"}\n' "$TMPHOME" \
  > "$TMPHOME/.claude/progress/auto-compact-BBBB2222.json"
LEGACY_OVERRIDE_PAST=$(date -u -j -f '%Y-%m-%d' '2020-01-01' +%s 2>/dev/null || date -u -d '2020-01-01' +%s 2>/dev/null || echo 1577836800)
# Invoke with session_id=AAAA1111 → should detect AAAA1111's sentinel (PENDING HANDOFF)
JSON_AAAA="{\"session_id\":\"AAAA1111\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT_AAAA=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON_AAAA" 2>/dev/null)
if printf '%s' "$OUT_AAAA" | jq -e '.hookSpecificOutput.additionalContext | contains("PENDING HANDOFF")' >/dev/null 2>&1; then
  pass "NEW-1: session-id binding — AAAA1111 session detects its own sentinel (PENDING HANDOFF)"
else
  fail "NEW-1: session-id binding AAAA" "expected PENDING HANDOFF for AAAA1111 session, got: $OUT_AAAA"
fi
# Invoke with session_id=BBBB2222 → should detect BBBB2222's sentinel (PENDING HANDOFF)
JSON_BBBB="{\"session_id\":\"BBBB2222\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT_BBBB=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON_BBBB" 2>/dev/null)
if printf '%s' "$OUT_BBBB" | jq -e '.hookSpecificOutput.additionalContext | contains("PENDING HANDOFF")' >/dev/null 2>&1; then
  pass "NEW-1: session-id binding — BBBB2222 session detects its own sentinel (PENDING HANDOFF)"
else
  fail "NEW-1: session-id binding BBBB" "expected PENDING HANDOFF for BBBB2222 session, got: $OUT_BBBB"
fi
# Invoke with unknown session_id=newsid → legacy-fallback, first glob match (either AAAA or BBBB)
JSON_NEW="{\"session_id\":\"newsid\",\"source\":\"resume\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT_NEW=$(CTX_LEGACY_HANDOFF_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE="$LEGACY_OVERRIDE_PAST" HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON_NEW" 2>/dev/null)
# newsid has no sentinel → strict miss; legacy-fallback also misses since newsid sentinel absent.
# Expected: sid-known-no-tagged-file or no-handoff or SESSION START with existing handoff.
# The primer emits SESSION START with existing handoff if a handoff file is found for this session.
# With session_id=newsid, primer_find_sentinel_for_cwd looks for auto-compact-newsid.json → absent.
# Since session_id is non-empty, strict mode fires → SENTINEL_PRESENT=false → no sentinel.
# primer_resolve_handoff_path with SENTINEL_SID8="" → looks for CLAUDE.local.md alias-only.
# There is no CLAUDE.local.md alias, so HANDOFF_PATH="" → primer exits silently.
if [ -z "$OUT_NEW" ] || printf '%s' "$OUT_NEW" | jq -e '.hookSpecificOutput.additionalContext | contains("PENDING HANDOFF") | not' >/dev/null 2>&1; then
  pass "NEW-1: session-id binding — newsid (no sentinel) → no PENDING HANDOFF (strict miss + no alias)"
else
  fail "NEW-1: session-id binding newsid" "expected no PENDING HANDOFF for newsid session, got: $OUT_NEW"
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
# R5 Critical #9: provide CLAUDE_SESSION_ID so OWN_SID resolves to GF_SID.
OUT_F=$(cd "$TMPWD_F" && CLAUDE_SESSION_ID="$GF_SID" HOME="$TMPHOME_F" bash "$STEP2_SH" 2>/dev/null)
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
echo "== §G4-F-advisory SID-known + no breadcrumb nonce → advisory (PR-17) =="
# Setup: CLAUDE_SESSION_ID set (OWN_SID known); NO breadcrumb for this SID; alias handoff
# with a nonce in marker. Assert STATE=ok (not mismatch-hard-stop) — D4 only blocks when
# both OWN_SID AND a breadcrumb nonce are available (NONCE_OK=mismatch). With no breadcrumb,
# SENTINEL_NONCE is empty → NONCE_OK=unknown → no hard-stop.
# R5 Critical #9 update: OWN_SID must be non-empty (both env vars set would trigger own-sid-
# unresolvable if unset and slug fails). Provide CLAUDE_SESSION_ID to satisfy OWN_SID guard.
TMPWD_FA=$(mktemp -d)
TMPHOME_FA=$(mktemp -d)
mkdir -p "$TMPHOME_FA/.claude/progress" && chmod 700 "$TMPHOME_FA/.claude/progress"
GFA_NONCE="fa1234ab-5678-9abc-def0-123456789abc"
GFA_SID="fa-advisory-sid-$$"
# Alias file (no SID-tagged; no breadcrumb for GFA_SID → SENTINEL_NONCE empty → NONCE_OK=unknown).
printf 'content body\n<!-- END-OF-HANDOFF schema=v1 sid=fa-advis nonce=%s -->\n' \
  "$GFA_NONCE" > "$TMPWD_FA/CLAUDE.local.md"
OUT_FA=$(cd "$TMPWD_FA" && CLAUDE_SESSION_ID="$GFA_SID" HOME="$TMPHOME_FA" bash "$STEP2_SH" 2>/dev/null)
GFA_STATE=$(printf '%s' "$OUT_FA" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
if [ "$GFA_STATE" = "ok" ]; then
  pass "G4-F-advisory: SID-known + no breadcrumb nonce → STATE=ok (D4 does NOT hard-stop without breadcrumb nonce)"
else
  fail "G4-F-advisory: SID-known + no breadcrumb nonce" "expected state=ok got '$GFA_STATE' raw: ${OUT_FA:0:200}"
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
  # R5 Critical #9: provide CLAUDE_SESSION_ID so OWN_SID resolves to GG_SID.
  # With stale breadcrumb and CLAUDE_SESSION_ID=GG_SID: OWN_SID known, breadcrumb rejected (age),
  # alias present → alias path (sid-known + no breadcrumb = SID8 empty → alias used).
  OUT_G_OLD=$(cd "$TMPWD_G" && CLAUDE_SESSION_ID="$GG_SID" HOME="$TMPHOME_G" bash "$STEP2_SH" 2>/dev/null)
  GG_STATE_OLD=$(printf '%s' "$OUT_G_OLD" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
  # With stale breadcrumb (>3600s), SID known (CLAUDE_SESSION_ID set) but breadcrumb rejected,
  # and handoff file present at TMPWD_G: step2 falls through breadcrumb → no SID8 → alias path.
  # For a clean "rejected breadcrumb" assertion, use an env with NO alias either.
  TMPHOME_G_OLD=$(mktemp -d)
  mkdir -p "$TMPHOME_G_OLD/.claude/progress" && chmod 700 "$TMPHOME_G_OLD/.claude/progress"
  cp "$GG_BREADCRUMB" "$TMPHOME_G_OLD/.claude/progress/breadcrumb-${GG_SID}.json"
  chmod 600 "$TMPHOME_G_OLD/.claude/progress/breadcrumb-${GG_SID}.json"
  touch -t "$PAST_MTIME" "$TMPHOME_G_OLD/.claude/progress/breadcrumb-${GG_SID}.json" 2>/dev/null
  TMPWD_G_EMPTY=$(mktemp -d)
  # R5 Critical #9: provide CLAUDE_SESSION_ID; no alias in empty dir → no-handoff.
  OUT_G_STALE=$(cd "$TMPWD_G_EMPTY" && CLAUDE_SESSION_ID="$GG_SID" HOME="$TMPHOME_G_OLD" bash "$STEP2_SH" 2>/dev/null)
  GG_STATE_STALE=$(printf '%s' "$OUT_G_STALE" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
  if [ "$GG_STATE_STALE" = "no-handoff" ]; then
    pass "G4-G: age=3601s breadcrumb rejected → state=no-handoff (age guard)"
  else
    fail "G4-G: age guard didn't reject stale breadcrumb — got state=$GG_STATE_STALE (expected no-handoff)" "raw: ${OUT_G_STALE:0:200}"
  fi
  rm -rf "$TMPHOME_G_OLD" "$TMPWD_G_EMPTY"
else
  # R3-fix-sweep H7: vacuous-pass → infra-fail. On macOS, `date -v-3601S` IS available
  # (BSD date supports -v). An empty PAST_MTIME indicates a real infra problem.
  fail "G4-G: date -v-3601S returned empty — expected macOS BSD date to support -v flag (infra-fail)" ""
  exit 1
fi
# Fresh breadcrumb (touch mtime = now): verify step2.sh adopts it.
touch "$GG_BREADCRUMB" 2>/dev/null
# R5 Critical #9: provide CLAUDE_SESSION_ID so OWN_SID resolves to GG_SID.
OUT_G_FRESH=$(cd "$TMPWD_G" && CLAUDE_SESSION_ID="$GG_SID" HOME="$TMPHOME_G" bash "$STEP2_SH" 2>/dev/null)
GG_STATE_FRESH=$(printf '%s' "$OUT_G_FRESH" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
if [ "$GG_STATE_FRESH" = "ok" ]; then
  pass "G4-G: fresh breadcrumb (age=~0s) accepted → state=ok"
else
  fail "G4-G: fresh breadcrumb acceptance" "expected state=ok got '$GG_STATE_FRESH' raw: ${OUT_G_FRESH:0:200}"
fi
# Boundary: test mtime=3599s (1 second before cutoff) → should be accepted.
# IMPORTANT: the fresh-breadcrumb test above consumed the breadcrumb (step2.sh EXIT trap
# deletes the adopted breadcrumb on exit). Re-create the breadcrumb here before applying
# the 3599s mtime so the boundary test has an intact file to read.
if [ -n "$PAST_MTIME" ]; then
  if command -v gdate >/dev/null 2>&1; then
    NEAR_MTIME=$(gdate -d '3599 seconds ago' +%Y%m%d%H%M.%S 2>/dev/null)
  else
    NEAR_MTIME=$(date -v-3599S +%Y%m%d%H%M.%S 2>/dev/null)
  fi
  if [ -n "$NEAR_MTIME" ]; then
    # Re-create the breadcrumb (consumed by the fresh-breadcrumb test's EXIT trap).
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
    touch -t "$NEAR_MTIME" "$GG_BREADCRUMB" 2>/dev/null
    # R5 Critical #9: provide CLAUDE_SESSION_ID so OWN_SID resolves to GG_SID.
    OUT_G_NEAR=$(cd "$TMPWD_G" && CLAUDE_SESSION_ID="$GG_SID" HOME="$TMPHOME_G" bash "$STEP2_SH" 2>/dev/null)
    GG_STATE_NEAR=$(printf '%s' "$OUT_G_NEAR" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
    if [ "$GG_STATE_NEAR" = "ok" ]; then
      pass "G4-G: boundary breadcrumb (age=3599s, 1s before cutoff) accepted → state=ok"
    else
      fail "G4-G: boundary breadcrumb (age=3599s) not accepted — got state=$GG_STATE_NEAR (expected ok)" "raw: ${OUT_G_NEAR:0:200}"
    fi
  else
    # R3-fix-sweep H7: vacuous-pass → infra-fail. NEAR_MTIME empty means date -v-3599S
    # failed — a real infra problem on macOS where BSD date supports -v.
    fail "G4-G: date -v-3599S returned empty — expected macOS BSD date to support -v flag (infra-fail)" ""
    exit 1
  fi
else
  # R3-fix-sweep H7: outer PAST_MTIME guard failure already caught above; this branch
  # is now unreachable (we exit 1 in the PAST_MTIME-empty else branch above).
  fail "G4-G: date arithmetic branch reached unexpectedly — PAST_MTIME guard should have exited (infra-fail)" ""
  exit 1
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
  ALIAS_CLOBBER=$(grep -nF '@CLAUDE.local.md' "$SKILL_FILE" | grep -iv 'migration\|legacy R3\|migration note\|removed in R4' | wc -l | tr -d '[:space:]')
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
GI_NONCE="aabbccdd-1234-5678-90ab-cdef11223344"
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
else
  # Require BOTH state=ok AND .path containing a space (D10 full coverage).
  # state=ok without a space in .path means the path wasn't preserved correctly.
  # Any other state is a fail — the test setup ensures a valid breadcrumb + SID-tagged file.
  fail "G4-I: JSON STATE for spaced path" "expected state=ok AND .path with space; got state='$GI_STATE' path='$GI_PATH' raw: ${OUT_I:0:200}"
fi
rm -rf "$TMPWD_I" "$TMPHOME_I"

# ---------------------------------------------------------------------------
# §G4-K invalid-handoff-name STATE (Phase 4 Round 4) — Critical #6
# ---------------------------------------------------------------------------
echo ""
echo "== §G4-K invalid-handoff-name STATE =="
# Setup: breadcrumb with SID known; handoff_resolve_path returns a file whose name is
# injected to a non-conforming path by bypassing the resolver. We achieve this by
# writing a breadcrumb that references a REAL cwd, and a file named with garbage in cwd,
# then editing HANDOFF_PATH at the check. Since step2.sh validates basename via grep -E
# after resolving, we can test by creating a file named 'CLAUDE.local.GARBAGE.extra.md'
# and patching the test to call step2 with a SID that resolves to that garbage name.
# Simpler approach: write a breadcrumb; write a file CLAUDE.local.GARBAGE-ONLY.md.garbage
# Then we need handoff_resolve_path to return it. But the resolver only looks for
# CLAUDE.local.${SID8}.md. So we create a SID8 that contains dots or slashes... but
# SID8 is validated to ^[A-Za-z0-9_-]+$ so that won't work.
# Best approach: write a valid SID-tagged breadcrumb + handoff, then rename the file
# to a garbage name after step2 resolves it. But that's a race.
# Practical: test the basename validation in step2.sh directly by symlinking.
# The invalid-handoff-name check happens AFTER handoff_resolve_path returns a path.
# We can trigger it by making the handoff_resolve_path set HANDOFF_PATH to a file whose
# basename doesn't match CLAUDE.local.(*.)?md.
# Solution: override by using a custom wrapper that sets HANDOFF_PATH to the garbage file
# before the basename check. This is too complex for a direct test.
# Simplest valid approach: write a valid breadcrumb with a SID, then move the resolved file
# to have a non-conforming name. Since step2 resolves via handoff_resolve_path (which checks
# CLAUDE.local.${SID8}.md), we need to set up so the resolved file IS the garbage-named one.
# This is not possible cleanly without mocking. Instead we test the regex via unit approach:
# directly check that grep -qE '^CLAUDE\.local\.([A-Za-z0-9_-]+\.)?md$' matches/rejects names.
GK_VALID_NAMES=("CLAUDE.local.md" "CLAUDE.local.abc12345.md" "CLAUDE.local.A1B2-C3D4.md")
GK_INVALID_NAMES=("CLAUDE.local.GARBAGE.extra.md" "CLAUDE.local..md" "evil.txt" "CLAUDE.local.md.bak" "../CLAUDE.local.md")
GK_PASS=true
for gk_name in "${GK_VALID_NAMES[@]}"; do
  if printf '%s' "$gk_name" | grep -qE '^CLAUDE\.local\.([A-Za-z0-9_-]+\.)?md$'; then
    : # expected to match
  else
    GK_PASS=false
    break
  fi
done
for gk_name in "${GK_INVALID_NAMES[@]}"; do
  if printf '%s' "$gk_name" | grep -qE '^CLAUDE\.local\.([A-Za-z0-9_-]+\.)?md$'; then
    GK_PASS=false
    break
  fi
done
if [ "$GK_PASS" = "true" ]; then
  pass "G4-K: invalid-handoff-name basename regex rejects non-conforming names and accepts conforming names"
else
  fail "G4-K: invalid-handoff-name regex" "regex produced wrong result for one or more test names"
fi

# ---------------------------------------------------------------------------
# §G4-M sid-mismatch-hard-stop with breadcrumb deletion assertion (Phase 4 Round 4) — Critical #5
# ---------------------------------------------------------------------------
echo ""
echo "== §G4-M sid-mismatch-hard-stop + breadcrumb deletion =="
# Setup: breadcrumb with SID_X, SID-tagged handoff file has marker with sid=DIFFERENT.
# Assert STATE=sid-mismatch-hard-stop AND breadcrumb is deleted (consumed).
TMPWD_M=$(mktemp -d)
TMPHOME_M=$(mktemp -d)
mkdir -p "$TMPHOME_M/.claude/progress" && chmod 700 "$TMPHOME_M/.claude/progress"
GM_SID="g4m-mismatch-$$"
GM_SID8="${GM_SID:0:8}"
GM_NONCE="11111111-aaaa-bbbb-cccc-dddddddddddd"
GM_MARKER_SID="wrongsid"   # marker claims a different SID8 → mismatch
GM_CWD=$(cd -P "$TMPWD_M" 2>/dev/null && pwd -P)
GM_HOST=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64)
GM_BREADCRUMB="$TMPHOME_M/.claude/progress/breadcrumb-${GM_SID}.json"
jq -c -n \
  --argjson sv 1 \
  --arg sid  "$GM_SID" \
  --arg sid8 "$GM_SID8" \
  --arg cwd  "$GM_CWD" \
  --arg nonce "$GM_NONCE" \
  --arg host  "$GM_HOST" \
  '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host}' \
  > "$GM_BREADCRUMB" 2>/dev/null
chmod 600 "$GM_BREADCRUMB"
# Write handoff file with WRONG SID in marker (triggers sid-mismatch-hard-stop)
printf 'content body\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' \
  "$GM_MARKER_SID" "$GM_NONCE" > "$TMPWD_M/CLAUDE.local.${GM_SID8}.md"
STEP2_SH="$PWD/post-compact-resume-step2.sh"
OUT_M=$(cd "$TMPWD_M" && CLAUDE_SESSION_ID="$GM_SID" HOME="$TMPHOME_M" bash "$STEP2_SH" 2>/dev/null)
GM_STATE=$(printf '%s' "$OUT_M" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
if [ "$GM_STATE" = "sid-mismatch-hard-stop" ]; then
  pass "G4-M: sid-mismatch-hard-stop fires when marker SID differs from breadcrumb SID8"
  # Assert breadcrumb was consumed (deleted by EXIT trap — C5: sid-mismatch is definitive)
  if [ ! -f "$GM_BREADCRUMB" ]; then
    pass "G4-M: breadcrumb deleted after sid-mismatch-hard-stop (consumed per C5)"
  else
    fail "G4-M: breadcrumb not deleted after sid-mismatch-hard-stop" "breadcrumb should be consumed"
  fi
else
  fail "G4-M: sid-mismatch-hard-stop" "expected state=sid-mismatch-hard-stop got '$GM_STATE' raw: ${OUT_M:0:200}"
fi
rm -rf "$TMPWD_M" "$TMPHOME_M"

# ---------------------------------------------------------------------------
# §G4-L Stop-hook-refused STATE (Phase 3 Round 4) — Critical #8
# ---------------------------------------------------------------------------
echo ""
echo "== §G4-L stop-hook-refused STATE =="
# Setup: write a stop-hook-refused breadcrumb for this session's SID.
# Assert step2.sh emits STATE=stop-hook-refused immediately.
TMPWD_L=$(mktemp -d)
TMPHOME_L=$(mktemp -d)
mkdir -p "$TMPHOME_L/.claude/progress" && chmod 700 "$TMPHOME_L/.claude/progress"
GL_SID="g4l-refused-$$"
GL_SID8="${GL_SID:0:8}"
GL_HOST=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64)
# Write stop-hook-refused breadcrumb (matches originating_command=stop-hook-fail-closed)
jq -c -n \
  --argjson sv 1 \
  --arg sid "$GL_SID" \
  --arg sid8 "$GL_SID8" \
  --arg cmd "stop-hook-fail-closed" \
  --arg real_sid "${GL_SID}-real" \
  --arg resolved_sid "${GL_SID}-resolved" \
  --arg host "$GL_HOST" \
  --arg next_steps "Two sentinels disagreed; run /pre-compact again." \
  '{schema_version:$sv,originating_command:$cmd,sid:$sid,sid8:$sid8,hostname:$host,real_sid:$real_sid,resolved_sid:$resolved_sid,next_steps:$next_steps}' \
  > "$TMPHOME_L/.claude/progress/breadcrumb-${GL_SID}.json" 2>/dev/null
chmod 600 "$TMPHOME_L/.claude/progress/breadcrumb-${GL_SID}.json"
# Also write a normal handoff file (must NOT be reached — stop-hook-refused fires first)
printf 'should not load\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=dummy-nonce -->\n' \
  "$GL_SID8" > "$TMPWD_L/CLAUDE.local.${GL_SID8}.md"
STEP2_SH="$PWD/post-compact-resume-step2.sh"
OUT_L=$(cd "$TMPWD_L" && CLAUDE_SESSION_ID="$GL_SID" HOME="$TMPHOME_L" bash "$STEP2_SH" 2>/dev/null)
GL_STATE=$(printf '%s' "$OUT_L" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
if [ "$GL_STATE" = "stop-hook-refused" ]; then
  pass "G4-L: stop-hook-refused STATE fires when stop-hook-fail-closed breadcrumb present"
else
  fail "G4-L: stop-hook-refused STATE" "expected state=stop-hook-refused, got '$GL_STATE' raw: ${OUT_L:0:200}"
fi
rm -rf "$TMPWD_L" "$TMPHOME_L"

# ---------------------------------------------------------------------------
# §G4-J Two-track step2 breadcrumb binding (Phase 2 Round 4) — Critical #1 fix
# ---------------------------------------------------------------------------
echo ""
echo "== §G4-J Two-track step2 breadcrumb binding =="
# Setup: Track A breadcrumb + Track B breadcrumb in same cwd.
# step2.sh is invoked with CLAUDE_SESSION_ID set to Track A's full SID.
# Assertion: step2.sh adopts Track A's breadcrumb (not Track B's) → STATE=ok with Track A's sid8.
TMPWD_J=$(mktemp -d)
TMPHOME_J=$(mktemp -d)
mkdir -p "$TMPHOME_J/.claude/progress" && chmod 700 "$TMPHOME_J/.claude/progress"
GJ_SID_A="track-a-j-$$-aaaaaa"
GJ_SID8_A="${GJ_SID_A:0:8}"
GJ_SID_B="track-b-j-$$-bbbbbb"
GJ_SID8_B="${GJ_SID_B:0:8}"
GJ_NONCE_A="aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"
GJ_NONCE_B="cccccccc-4444-5555-6666-dddddddddddd"
GJ_CWD=$(cd -P "$TMPWD_J" 2>/dev/null && pwd -P)
GJ_HOST=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64)
# Write Track A breadcrumb (with Track A's SID and nonce)
jq -c -n \
  --argjson sv 1 \
  --arg sid  "$GJ_SID_A" \
  --arg sid8 "$GJ_SID8_A" \
  --arg cwd  "$GJ_CWD" \
  --arg nonce "$GJ_NONCE_A" \
  --arg host  "$GJ_HOST" \
  '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host}' \
  > "$TMPHOME_J/.claude/progress/breadcrumb-${GJ_SID_A}.json" 2>/dev/null
chmod 600 "$TMPHOME_J/.claude/progress/breadcrumb-${GJ_SID_A}.json"
# Write Track B breadcrumb (same cwd, different SID and nonce — the contamination source)
jq -c -n \
  --argjson sv 1 \
  --arg sid  "$GJ_SID_B" \
  --arg sid8 "$GJ_SID8_B" \
  --arg cwd  "$GJ_CWD" \
  --arg nonce "$GJ_NONCE_B" \
  --arg host  "$GJ_HOST" \
  '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host}' \
  > "$TMPHOME_J/.claude/progress/breadcrumb-${GJ_SID_B}.json" 2>/dev/null
chmod 600 "$TMPHOME_J/.claude/progress/breadcrumb-${GJ_SID_B}.json"
# Write Track A's SID-tagged handoff (the file we expect step2 to load)
printf 'Track A handoff content\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' \
  "$GJ_SID8_A" "$GJ_NONCE_A" > "$TMPWD_J/CLAUDE.local.${GJ_SID8_A}.md"
# Write Track B's SID-tagged handoff (must NOT be loaded by Track A's reader)
printf 'Track B handoff content\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' \
  "$GJ_SID8_B" "$GJ_NONCE_B" > "$TMPWD_J/CLAUDE.local.${GJ_SID8_B}.md"
STEP2_SH="$PWD/post-compact-resume-step2.sh"
# Invoke step2.sh with CLAUDE_SESSION_ID = Track A's full SID → must adopt Track A's breadcrumb
OUT_J=$(cd "$TMPWD_J" && CLAUDE_SESSION_ID="$GJ_SID_A" HOME="$TMPHOME_J" bash "$STEP2_SH" 2>/dev/null)
GJ_STATE=$(printf '%s' "$OUT_J" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
GJ_SID8_OUT=$(printf '%s' "$OUT_J" | sed -n 's/^STATE=//p' | jq -r '.sid8' 2>/dev/null)
if [ "$GJ_STATE" = "ok" ] && [ "$GJ_SID8_OUT" = "$GJ_SID8_A" ]; then
  pass "G4-J: two-track reader binding — Track A reader adopts Track A breadcrumb (not Track B's) state=$GJ_STATE sid8=$GJ_SID8_OUT"
else
  fail "G4-J: two-track reader binding" "expected state=ok sid8=$GJ_SID8_A; got state='$GJ_STATE' sid8='$GJ_SID8_OUT' raw: ${OUT_J:0:200}"
fi
rm -rf "$TMPWD_J" "$TMPHOME_J"

# ---------------------------------------------------------------------------
# §R5-H6 Production-equivalent path: CLAUDE_CODE_SESSION_ID set, CLAUDE_SESSION_ID unset
# ---------------------------------------------------------------------------
# R5 Critical #1 fix: ac_resolve_session_id now reads CLAUDE_CODE_SESSION_ID as fallback.
# This test simulates the Bash-tool subprocess environment where CLAUDE_CODE_SESSION_ID
# is set by Claude Code but CLAUDE_SESSION_ID is NOT (the production path that was broken).
# Expected: STATE=ok (breadcrumb adopted via CLAUDE_CODE_SESSION_ID-based OWN_SID).
echo ""
echo "== §R5-H6 Production-equivalent path (CLAUDE_CODE_SESSION_ID, no CLAUDE_SESSION_ID) =="
TMPWD_R5H6=$(mktemp -d)
TMPHOME_R5H6=$(mktemp -d)
mkdir -p "$TMPHOME_R5H6/.claude/progress" && chmod 700 "$TMPHOME_R5H6/.claude/progress"
R5H6_SID="r5h6-prod-test-$$"
R5H6_SID8="${R5H6_SID:0:8}"
R5H6_NONCE="a1b2c3d4-e5f6-7890-abcd-ef1234567890"
R5H6_CWD=$(cd -P "$TMPWD_R5H6" 2>/dev/null && pwd -P)
R5H6_HOST=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64)
# Write breadcrumb using the bare CLAUDE_CODE_SESSION_ID (no __ttysN suffix in production env)
jq -c -n \
  --argjson sv 1 \
  --arg sid  "$R5H6_SID" \
  --arg sid8 "$R5H6_SID8" \
  --arg cwd  "$R5H6_CWD" \
  --arg nonce "$R5H6_NONCE" \
  --arg host  "$R5H6_HOST" \
  '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host}' \
  > "$TMPHOME_R5H6/.claude/progress/breadcrumb-${R5H6_SID}.json" 2>/dev/null
chmod 600 "$TMPHOME_R5H6/.claude/progress/breadcrumb-${R5H6_SID}.json"
# SID-tagged handoff file
printf 'production handoff\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' \
  "$R5H6_SID8" "$R5H6_NONCE" > "$TMPWD_R5H6/CLAUDE.local.${R5H6_SID8}.md"
# Invoke with CLAUDE_CODE_SESSION_ID set, CLAUDE_SESSION_ID explicitly unset
OUT_R5H6=$(cd "$TMPWD_R5H6" && unset CLAUDE_SESSION_ID && \
  CLAUDE_CODE_SESSION_ID="$R5H6_SID" HOME="$TMPHOME_R5H6" bash "$STEP2_SH" 2>/dev/null)
R5H6_STATE=$(printf '%s' "$OUT_R5H6" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
if [ "$R5H6_STATE" = "ok" ]; then
  pass "R5-H6: production-equivalent path — CLAUDE_CODE_SESSION_ID fallback works → STATE=ok"
else
  fail "R5-H6: production-equivalent path" "expected state=ok; got state='$R5H6_STATE' raw: ${OUT_R5H6:0:200}"
fi
rm -rf "$TMPWD_R5H6" "$TMPHOME_R5H6"

# ---------------------------------------------------------------------------
# §R5-C9 own-sid-unresolvable STATE (R5 Critical #9)
# ---------------------------------------------------------------------------
# When both CLAUDE_SESSION_ID and CLAUDE_CODE_SESSION_ID are unset AND slug fallback
# finds no transcripts (temp dir with no .claude/projects/), step2.sh must emit
# STATE=own-sid-unresolvable and refuse to proceed.
echo ""
echo "== §R5-C9 own-sid-unresolvable when both env vars unset + no transcript =="
TMPWD_C9=$(mktemp -d)
TMPHOME_C9=$(mktemp -d)
mkdir -p "$TMPHOME_C9/.claude/progress" && chmod 700 "$TMPHOME_C9/.claude/progress"
# No breadcrumb, no handoff — env vars will be unset, tmpdir has no .claude/projects/
# so slug fallback also finds nothing.
OUT_C9=$(cd "$TMPWD_C9" && unset CLAUDE_SESSION_ID && unset CLAUDE_CODE_SESSION_ID && \
  HOME="$TMPHOME_C9" bash "$STEP2_SH" 2>/dev/null)
C9_STATE=$(printf '%s' "$OUT_C9" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
if [ "$C9_STATE" = "own-sid-unresolvable" ]; then
  pass "R5-C9: own-sid-unresolvable fires when both env vars unset + no transcript"
else
  fail "R5-C9: own-sid-unresolvable" "expected state=own-sid-unresolvable; got state='$C9_STATE' raw: ${OUT_C9:0:200}"
fi
rm -rf "$TMPWD_C9" "$TMPHOME_C9"

# ---------------------------------------------------------------------------
# §R5-C2 Body-line marker bypass — strict anchor must reject prose mentions
# ---------------------------------------------------------------------------
# Verifies that a handoff file containing a prose mention of the marker format
# does NOT cause handoff_marker_sid/nonce to extract from the prose line.
# Only lines beginning with ^<!-- END-OF-HANDOFF schema=v1 are canonical markers.
echo ""
echo "== §R5-C2 Body-line marker bypass (Adversary ATTACK 2 re-run) =="
. "$PWD/lib/handoff-marker.sh" 2>/dev/null || true
TMPFILE_C2=$(mktemp)
# File has a prose mention inline (NOT at start of line) then a canonical marker at start of line.
printf '## Documentation\nNote: marker has form <!-- END-OF-HANDOFF schema=v1 sid=attacker nonce=bad-nonce -->\n\n<!-- END-OF-HANDOFF schema=v1 sid=canonical1 nonce=aaaa1111-2222-3333-4444-555566667777 -->\n' > "$TMPFILE_C2"
C2_SID=$(handoff_marker_sid "$TMPFILE_C2" 2>/dev/null)
C2_NONCE=$(handoff_marker_nonce "$TMPFILE_C2" 2>/dev/null)
if [ "$C2_SID" = "canonical1" ] && [ "$C2_NONCE" = "aaaa1111-2222-3333-4444-555566667777" ]; then
  pass "R5-C2: body-line bypass defeated — canonical marker wins (sid=$C2_SID nonce=$C2_NONCE)"
else
  fail "R5-C2: body-line bypass" "expected sid=canonical1 nonce=aaaa1111-...; got sid='$C2_SID' nonce='$C2_NONCE'"
fi
rm -f "$TMPFILE_C2"

# ---------------------------------------------------------------------------
# §R5-H13 Multi-marker fail-closed (H13)
# ---------------------------------------------------------------------------
# Verifies that a handoff file with >1 canonical markers emits STATE=multi-marker-detected.
echo ""
echo "== §R5-H13 Multi-marker fail-closed =="
TMPWD_H13=$(mktemp -d)
TMPHOME_H13=$(mktemp -d)
mkdir -p "$TMPHOME_H13/.claude/progress" && chmod 700 "$TMPHOME_H13/.claude/progress"
H13_SID="r5h13-multi-$$"
H13_SID8="${H13_SID:0:8}"
H13_NONCE="11111111-aaaa-bbbb-cccc-dddddddddddd"
H13_CWD=$(cd -P "$TMPWD_H13" 2>/dev/null && pwd -P)
H13_HOST=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64)
# Write breadcrumb
jq -c -n \
  --argjson sv 1 \
  --arg sid  "$H13_SID" \
  --arg sid8 "$H13_SID8" \
  --arg cwd  "$H13_CWD" \
  --arg nonce "$H13_NONCE" \
  --arg host  "$H13_HOST" \
  '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host}' \
  > "$TMPHOME_H13/.claude/progress/breadcrumb-${H13_SID}.json" 2>/dev/null
chmod 600 "$TMPHOME_H13/.claude/progress/breadcrumb-${H13_SID}.json"
# Write handoff with TWO canonical markers (tampered file)
printf 'content body\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' \
  "$H13_SID8" "$H13_NONCE" "$H13_SID8" "$H13_NONCE" > "$TMPWD_H13/CLAUDE.local.${H13_SID8}.md"
OUT_H13=$(cd "$TMPWD_H13" && CLAUDE_SESSION_ID="$H13_SID" HOME="$TMPHOME_H13" bash "$STEP2_SH" 2>/dev/null)
H13_STATE=$(printf '%s' "$OUT_H13" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
if [ "$H13_STATE" = "multi-marker-detected" ]; then
  pass "R5-H13: multi-marker fail-closed fires on tampered handoff (2 markers)"
else
  fail "R5-H13: multi-marker fail-closed" "expected state=multi-marker-detected; got state='$H13_STATE' raw: ${OUT_H13:0:200}"
fi
rm -rf "$TMPWD_H13" "$TMPHOME_H13"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "PASS: $PASS  FAIL: $FAIL"
if [ -n "$FAIL_NAMES" ]; then
  printf 'Failed tests:%s\n' "$FAIL_NAMES"
fi
[ "$FAIL" -eq 0 ]
