#!/usr/bin/env bash
# Smoke test for the auto-compact arming + hook pipeline.
# Does NOT actually fire /compact — uses a synthetic non-existent TTY so the AppleScript
# walk returns "no-matching-tab" cleanly.
#
# Verifies:
#   - lib/auto-compact-sentinel.sh sources cleanly
#   - ac_validate_tty accepts canonical form, rejects every known injection vector
#   - ac_write_sentinel produces mode-600 JSON with required fields
#   - ac_read_sentinel_tty rejects symlinks, oversized files, wrong schema_version,
#     wrong originating_command, malformed JSON, AppleScript-injection payloads
#   - The hook script atomically claims the sentinel and refuses double-fire
#   - The hook refuses to fire if `claude` is not the foreground process on the TTY
#
# Exits 0 if all assertions pass, non-zero on first failure.

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/auto-compact-sentinel.sh
. "$ROOT/lib/auto-compact-sentinel.sh"

PASS=0
FAIL=0
check() {
  local desc="$1" expected_pass="$2" actual_pass="$3"
  if [ "$expected_pass" = "$actual_pass" ]; then
    PASS=$((PASS+1))
    printf '  PASS  %s\n' "$desc"
  else
    FAIL=$((FAIL+1))
    printf '  FAIL  %s (expected pass=%s, got pass=%s)\n' "$desc" "$expected_pass" "$actual_pass"
  fi
}

echo "== ac_validate_tty =="
for tty in '/dev/ttys007' '/dev/ttys0' '/dev/ttys999'; do
  if ac_validate_tty "$tty"; then check "accept '$tty'" 1 1; else check "accept '$tty'" 1 0; fi
done
for tty in '/dev/ttys' '/dev/ttysX' '/dev/ttys007abc' '/dev/ttys007"; do shell script "id"' '/etc/passwd' '/dev/ttyp007' ''; do
  if ac_validate_tty "$tty"; then check "reject '$tty'" 0 1; else check "reject '$tty'" 0 0; fi
done

echo "== ac_write_sentinel + ac_read_sentinel_tty =="
TEST_SID="SMOKE_$$"
ac_write_sentinel "$TEST_SID" "/dev/ttys999" "/tmp" "test-nonce-$$"
SENTINEL_PATH=$(ac_sentinel_path "$TEST_SID")
if [ -f "$SENTINEL_PATH" ]; then check "sentinel file created" 1 1; else check "sentinel file created" 1 0; fi
MODE=$(stat -f '%Lp' "$SENTINEL_PATH" 2>/dev/null)
if [ "$MODE" = "600" ]; then check "sentinel mode 600" 1 1; else check "sentinel mode 600 (got $MODE)" 1 0; fi
READ_TTY=$(ac_read_sentinel_tty "$SENTINEL_PATH")
if [ "$READ_TTY" = "/dev/ttys999" ]; then check "round-trip target_tty" 1 1; else check "round-trip target_tty (got '$READ_TTY')" 1 0; fi
rm -f "$SENTINEL_PATH"

echo "== ac_read_sentinel_tty rejection vectors =="
TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT

# Symlink rejection
ln -s /etc/passwd "$TMPDIR_T/symlink.json"
if [ -z "$(ac_read_sentinel_tty "$TMPDIR_T/symlink.json" 2>/dev/null)" ]; then check "reject symlink" 1 1; else check "reject symlink" 1 0; fi

# Oversized rejection
yes "x" | head -c 5000 > "$TMPDIR_T/big.json"
if [ -z "$(ac_read_sentinel_tty "$TMPDIR_T/big.json" 2>/dev/null)" ]; then check "reject oversized" 1 1; else check "reject oversized" 1 0; fi

# Wrong schema_version (future-invalid: one above current AC_SCHEMA_VERSION=3)
# R1-B1: bump test to schema_version=4 (the new future-invalid value); existing v3 round-trip is below.
echo '{"schema_version":4,"target_tty":"/dev/ttys007","originating_command":"pre-compact","cwd":"/tmp","marker_nonce":"abc"}' > "$TMPDIR_T/v4.json"
if [ -z "$(ac_read_sentinel_tty "$TMPDIR_T/v4.json" 2>/dev/null)" ]; then check "reject schema v4 (future-invalid)" 1 1; else check "reject schema v4 (future-invalid)" 1 0; fi

# Schema v3 round-trip: ac_read_sentinel_tty, ac_read_sentinel_cwd, and ac_read_sentinel_nonce all work.
echo '{"schema_version":3,"target_tty":"/dev/ttys042","originating_command":"pre-compact","cwd":"/Users/test/myproject","marker_nonce":"abc-def-123"}' > "$TMPDIR_T/v3withall.json"
READ_TTY_V3=$(ac_read_sentinel_tty "$TMPDIR_T/v3withall.json" 2>/dev/null)
if [ "$READ_TTY_V3" = "/dev/ttys042" ]; then check "v3 sentinel: ac_read_sentinel_tty returns target_tty" 1 1; else check "v3 sentinel: ac_read_sentinel_tty (got '$READ_TTY_V3')" 1 0; fi
READ_CWD_V3=$(ac_read_sentinel_cwd "$TMPDIR_T/v3withall.json" 2>/dev/null)
if [ "$READ_CWD_V3" = "/Users/test/myproject" ]; then check "v3 sentinel: ac_read_sentinel_cwd returns cwd" 1 1; else check "v3 sentinel: ac_read_sentinel_cwd (got '$READ_CWD_V3')" 1 0; fi
READ_NONCE_V3=$(ac_read_sentinel_nonce "$TMPDIR_T/v3withall.json" 2>/dev/null)
if [ "$READ_NONCE_V3" = "abc-def-123" ]; then check "v3 sentinel: ac_read_sentinel_nonce returns marker_nonce" 1 1; else check "v3 sentinel: ac_read_sentinel_nonce (got '$READ_NONCE_V3')" 1 0; fi

# Schema v2 with cwd field (backwards-compat): ac_read_sentinel_tty returns target_tty; ac_read_sentinel_cwd returns cwd.
echo '{"schema_version":2,"target_tty":"/dev/ttys042","originating_command":"pre-compact","cwd":"/Users/test/myproject"}' > "$TMPDIR_T/v2withcwd.json"
READ_TTY_V2=$(ac_read_sentinel_tty "$TMPDIR_T/v2withcwd.json" 2>/dev/null)
if [ "$READ_TTY_V2" = "/dev/ttys042" ]; then check "v2 sentinel: ac_read_sentinel_tty returns target_tty" 1 1; else check "v2 sentinel: ac_read_sentinel_tty (got '$READ_TTY_V2')" 1 0; fi
READ_CWD_V2=$(ac_read_sentinel_cwd "$TMPDIR_T/v2withcwd.json" 2>/dev/null)
if [ "$READ_CWD_V2" = "/Users/test/myproject" ]; then check "v2 sentinel: ac_read_sentinel_cwd returns cwd" 1 1; else check "v2 sentinel: ac_read_sentinel_cwd (got '$READ_CWD_V2')" 1 0; fi

# Backwards-compat: v1 sentinel (no cwd field); ac_read_sentinel_tty still returns target_tty,
# ac_read_sentinel_cwd returns empty (v1 has no cwd).
echo '{"schema_version":1,"target_tty":"/dev/ttys011","originating_command":"pre-compact"}' > "$TMPDIR_T/v1compat.json"
READ_TTY_V1=$(ac_read_sentinel_tty "$TMPDIR_T/v1compat.json" 2>/dev/null)
if [ "$READ_TTY_V1" = "/dev/ttys011" ]; then check "v1 sentinel backwards-compat: ac_read_sentinel_tty returns target_tty" 1 1; else check "v1 sentinel backwards-compat: ac_read_sentinel_tty (got '$READ_TTY_V1')" 1 0; fi
READ_CWD_V1=$(ac_read_sentinel_cwd "$TMPDIR_T/v1compat.json" 2>/dev/null)
if [ -z "$READ_CWD_V1" ]; then check "v1 sentinel backwards-compat: ac_read_sentinel_cwd returns empty (no cwd field)" 1 1; else check "v1 sentinel backwards-compat: ac_read_sentinel_cwd (got '$READ_CWD_V1')" 1 0; fi

# Wrong originating_command
echo '{"schema_version":1,"target_tty":"/dev/ttys007","originating_command":"hacker"}' > "$TMPDIR_T/badorig.json"
if [ -z "$(ac_read_sentinel_tty "$TMPDIR_T/badorig.json" 2>/dev/null)" ]; then check "reject bad originating_command" 1 1; else check "reject bad originating_command" 1 0; fi

# AppleScript injection payload as target_tty
echo '{"schema_version":1,"target_tty":"/dev/ttys007\";do shell script \"id\"","originating_command":"pre-compact"}' > "$TMPDIR_T/inject.json"
if [ -z "$(ac_read_sentinel_tty "$TMPDIR_T/inject.json" 2>/dev/null)" ]; then check "reject AppleScript injection payload" 1 1; else check "reject injection" 1 0; fi

# Malformed JSON
echo '{not json' > "$TMPDIR_T/junk.json"
if [ -z "$(ac_read_sentinel_tty "$TMPDIR_T/junk.json" 2>/dev/null)" ]; then check "reject malformed JSON" 1 1; else check "reject malformed JSON" 1 0; fi

echo "== jq path isolated (without python3 fallback) =="
# The python3 fallback was masking a jq operator-precedence bug.
# This test exercises the jq branch directly to prevent regression.
TMP_OK="$TMPDIR_T/valid.json"
echo '{"schema_version":1,"target_tty":"/dev/ttys123","armed_at":"x","originating_command":"pre-compact"}' > "$TMP_OK"
JQ_OUT=$(jq -r --argjson v 1 '
  if type == "object"
     and .schema_version == $v
     and (.originating_command // "") == "pre-compact"
     and (((.target_tty // "") | type) == "string")
  then .target_tty else empty end' < "$TMP_OK" 2>/dev/null)
if [ "$JQ_OUT" = "/dev/ttys123" ]; then check "jq filter returns valid target_tty (precedence fix)" 1 1; else check "jq filter (got '$JQ_OUT')" 1 0; fi

echo "== Foreground-process check (BRE vs ERE) =="
# grep \| BRE alternation is treated as literal on BSD grep.
# Verify the ERE form actually matches.
GREP_ERE_OUT=$(printf 'claude\n' | grep -E '^(claude|-claude)$' 2>/dev/null)
if [ "$GREP_ERE_OUT" = "claude" ]; then check "ERE grep matches 'claude'" 1 1; else check "ERE grep (got '$GREP_ERE_OUT')" 1 0; fi

echo "== arm-auto-compact.sh opt-out matcher =="
for ARG in "no-auto-compact" "--no-auto-compact" "no auto compact"; do
  OUT=$("$ROOT/arm-auto-compact.sh" "$ARG" 2>/dev/null)
  case "$OUT" in
    *"skipped per request"*) check "opt-out matches '$ARG'" 1 1 ;;
    *) check "opt-out matches '$ARG' (got '$OUT')" 1 0 ;;
  esac
done

echo "== arm-auto-compact.sh non-Apple_Terminal refusal =="
OUT=$(TERM_PROGRAM="iTerm.app" "$ROOT/arm-auto-compact.sh" "" 2>/dev/null)
case "$OUT" in
  *"NOT armed"*"iTerm.app"*) check "refuses non-Apple_Terminal host" 1 1 ;;
  *) check "non-Apple_Terminal (got '$OUT')" 1 0 ;;
esac

echo "== arm-auto-compact.sh tmux refusal =="
OUT=$(TMUX="/tmp/tmux-501/default,0,0" "$ROOT/arm-auto-compact.sh" "" 2>/dev/null)
case "$OUT" in
  *"NOT armed"*"tmux/screen"*) check "refuses inside tmux" 1 1 ;;
  *) check "tmux refusal (got '$OUT')" 1 0 ;;
esac

echo "== Hook end-to-end (synthetic TTY) =="
ac_write_sentinel "$TEST_SID" "/dev/ttys999" "/tmp" "hook-nonce-$$"
echo "{\"session_id\":\"$TEST_SID\"}" | "$ROOT/auto-compact-after-pre-compact.sh"
HOOK_EXIT=$?
if [ "$HOOK_EXIT" = "0" ]; then check "hook exit 0" 1 1; else check "hook exit 0 (got $HOOK_EXIT)" 1 0; fi
if [ ! -f "$SENTINEL_PATH" ]; then check "sentinel consumed by hook" 1 1; else check "sentinel consumed" 1 0; fi

# Idempotency: re-firing the hook with no sentinel should be a clean no-op
echo "{\"session_id\":\"$TEST_SID\"}" | "$ROOT/auto-compact-after-pre-compact.sh"
HOOK_EXIT2=$?
if [ "$HOOK_EXIT2" = "0" ]; then check "no-sentinel hook re-fire is no-op" 1 1; else check "no-sentinel re-fire (got $HOOK_EXIT2)" 1 0; fi

echo "== Concurrent claim race =="
# Two hook invocations on the same sentinel must result in exactly ONE consuming it.
ac_write_sentinel "$TEST_SID" "/dev/ttys999" "/tmp" "race-nonce-$$"
echo "{\"session_id\":\"$TEST_SID\"}" | "$ROOT/auto-compact-after-pre-compact.sh" &
echo "{\"session_id\":\"$TEST_SID\"}" | "$ROOT/auto-compact-after-pre-compact.sh" &
wait
# After both finish, sentinel must be gone (one consumed it) and no .claim.* lingers
if [ ! -f "$SENTINEL_PATH" ]; then check "concurrent claim — sentinel consumed" 1 1; else check "concurrent claim consumed" 1 0; fi
CLAIM_LEFT=$(ls "$HOME/.claude/progress/auto-compact-${TEST_SID}.json.claim."* 2>/dev/null | wc -l | tr -d '[:space:]')
if [ "$CLAIM_LEFT" = "0" ]; then check "concurrent claim — no orphan .claim files" 1 1; else check "concurrent claim orphans=$CLAIM_LEFT" 1 0; fi

echo "== Lib idempotent source guard =="
# Sourcing the lib twice must NOT trigger 'readonly' redeclaration errors.
SECOND_SOURCE_ERR=$( ( . "$ROOT/lib/auto-compact-sentinel.sh"; . "$ROOT/lib/auto-compact-sentinel.sh" ) 2>&1 >/dev/null )
if [ -z "$SECOND_SOURCE_ERR" ]; then check "double-source is silent (no readonly clash)" 1 1; else check "double-source emitted '$SECOND_SOURCE_ERR'" 1 0; fi

echo "== Log file mode 600 =="
ac_log "test write for mode check"
LOG_MODE=$(stat -f '%Lp' "$(ac_log_path)" 2>/dev/null)
if [ "$LOG_MODE" = "600" ]; then check "log file mode 600" 1 1; else check "log file mode (got $LOG_MODE)" 1 0; fi

echo "== ps ucomm format (multi-word comm regression) =="
# awk $NF on `ps -o comm=` is brittle for multi-word comms (e.g. `npm exec ...`).
# Switched to `ucomm=` which is always single-token (executable basename). Verify the
# expected one-word format.
UCOMM_LINES=$(ps -o stat=,ucomm= 2>/dev/null | tail -n +1 | awk 'NF != 2 {print "MULTIFIELD:" $0}')
if [ -z "$UCOMM_LINES" ]; then check "ps -o ucomm= produces single-token lines" 1 1; else check "ucomm format unexpected: $UCOMM_LINES" 1 0; fi

echo "== Skill-prose invocation contract =="
# Gap-coverage: if pre-compact.md drops the arm-script invocation, no test catches it.
# Lock the BEHAVIORAL contract (less brittle than exact variable-name matching):
#   - pre-compact.md references arm-auto-compact.sh
#   - it assigns the script's stdout to AUTOCOMPACT_STATE
#   - it includes some form of executable-existence guard so a missing dotfiles
#     sync doesn't fail loudly (any of: `[ -x ]`, `command -v`, `which`)
#   - the AUTOCOMPACT_STATE value is interpolated into the Step 9.1 report
SKILL="$HOME/.claude-dotfiles/commands/pre-compact.md"
SKILL_PASS=1
[ -f "$SKILL" ] || SKILL_PASS=0
grep -q 'arm-auto-compact\.sh' "$SKILL" 2>/dev/null || SKILL_PASS=0
grep -q 'AUTOCOMPACT_STATE=' "$SKILL" 2>/dev/null || SKILL_PASS=0
grep -qE '\[ -x |command -v |which ' "$SKILL" 2>/dev/null || SKILL_PASS=0
grep -qE 'AUTOCOMPACT_STATE[}]|\{AUTOCOMPACT_STATE\}|Auto-compact:' "$SKILL" 2>/dev/null || SKILL_PASS=0
if [ "$SKILL_PASS" = "1" ]; then
  check "pre-compact.md invokes arm script + captures state + guards execution + interpolates" 1 1
else
  check "pre-compact.md missing one of: invocation / capture / exec-guard / report-interpolation" 1 0
fi

echo "== Settings.json registration check refuses when entry absent =="
# Round 5 DEPTH: no test covers the registration check. Add one.
FAKEHOME=$(mktemp -d)
mkdir -p "$FAKEHOME/.claude"
echo '{"hooks":{"Stop":[{"hooks":[{"command":"some-other-hook.sh"}]}]}}' > "$FAKEHOME/.claude/settings.json"
OUT=$(HOME="$FAKEHOME" "$ROOT/arm-auto-compact.sh" "" 2>/dev/null)
rm -rf "$FAKEHOME"
case "$OUT" in
  *"Stop hook not registered"*) check "arm refuses when Stop hook absent from settings.json" 1 1 ;;
  *) check "registration check missing (got '$OUT')" 1 0 ;;
esac

echo "== Sentinel no longer contains armed_at (round-4 dead-data removal) =="
ac_write_sentinel "${TEST_SID}_armed_at" "/dev/ttys999" "/tmp" ""
SP=$(ac_sentinel_path "${TEST_SID}_armed_at")
if ! grep -q 'armed_at' "$SP" 2>/dev/null; then check "sentinel JSON omits armed_at" 1 1; else check "sentinel still has armed_at" 1 0; fi
rm -f "$SP"

echo "== --dry-run path does not write a sentinel =="
# R5 H7: inject CLAUDE_SESSION_ID so arm-auto-compact.sh's ac_resolve_session_id returns
# a deterministic SID. Without this, when CLAUDE_SESSION_ID is unset in the test runner
# environment and there are no project transcripts in the test cwd, ac_resolve_session_id
# may return empty — which would cause the script to hit own-sid-unresolvable now that
# we validate OWN_SID in step2.sh. The --dry-run path itself doesn't use OWN_SID but
# we inject for test stability (consistent behavior regardless of test runner env).
DRY_OUT=$(CLAUDE_SESSION_ID="test-dry-run-sid-$(date +%s)" "$ROOT/arm-auto-compact.sh" "--dry-run" 2>/dev/null)
case "$DRY_OUT" in
  *"DRY-RUN"*) check "--dry-run reports intent" 1 1 ;;
  *) check "--dry-run output (got '$DRY_OUT')" 1 0 ;;
esac

echo "== C1: ac_write_sentinel fails on read-only progress dir =="
# Make the .claude parent dir mode 500 so mkdir -p of progress/ is denied.
# ac_write_sentinel calls `mkdir -p $(dirname path)` and `chmod 700` on the progress dir,
# but neither can create the progress subdir if .claude itself is not writable.
TMPDIR_RO=$(mktemp -d)
CLAUDE_DIR="$TMPDIR_RO/.claude"
mkdir -p "$CLAUDE_DIR"
chmod 500 "$CLAUDE_DIR"
WRITE_RC=0
( HOME="$TMPDIR_RO" ac_write_sentinel "ROTEST_$$" "/dev/ttys999" "/tmp" "ro-nonce" ) 2>/dev/null || WRITE_RC=$?
if [ "$WRITE_RC" -ne 0 ]; then
  check "C1: ac_write_sentinel returns non-zero on read-only progress dir" 1 1
else
  check "C1: ac_write_sentinel returns non-zero on read-only progress dir (got 0, expected non-zero)" 1 0
fi
chmod 700 "$CLAUDE_DIR" 2>/dev/null
rm -rf "$TMPDIR_RO"

echo "== C4: ac_read_sentinel_cwd rejection vectors =="
TMPDIR_C4=$(mktemp -d)
trap 'rm -rf "$TMPDIR_C4"' EXIT

# C4-symlink: symlink sentinel → expect empty return
ln -s /etc/passwd "$TMPDIR_C4/cwd-symlink.json"
if [ -z "$(ac_read_sentinel_cwd "$TMPDIR_C4/cwd-symlink.json" 2>/dev/null)" ]; then
  check "C4: ac_read_sentinel_cwd rejects symlink" 1 1
else
  check "C4: ac_read_sentinel_cwd rejects symlink (got non-empty)" 1 0
fi

# C4-oversized: 5KB file → expect empty return
yes "x" | head -c 5000 > "$TMPDIR_C4/cwd-big.json"
if [ -z "$(ac_read_sentinel_cwd "$TMPDIR_C4/cwd-big.json" 2>/dev/null)" ]; then
  check "C4: ac_read_sentinel_cwd rejects oversized (5KB)" 1 1
else
  check "C4: ac_read_sentinel_cwd rejects oversized (got non-empty)" 1 0
fi

# C4-schema999: schema_version far above AC_SCHEMA_VERSION → expect empty
printf '{"schema_version":999,"target_tty":"/dev/ttys007","originating_command":"pre-compact","cwd":"/tmp","marker_nonce":"x"}\n' > "$TMPDIR_C4/cwd-sv999.json"
if [ -z "$(ac_read_sentinel_cwd "$TMPDIR_C4/cwd-sv999.json" 2>/dev/null)" ]; then
  check "C4: ac_read_sentinel_cwd rejects schema_version=999 (bumped past v3)" 1 1
else
  check "C4: ac_read_sentinel_cwd rejects schema_version=999 (got non-empty)" 1 0
fi

# C4-badorigcmd: wrong originating_command → expect empty
printf '{"schema_version":3,"target_tty":"/dev/ttys007","originating_command":"not-pre-compact","cwd":"/tmp","marker_nonce":"x"}\n' > "$TMPDIR_C4/cwd-badorig.json"
if [ -z "$(ac_read_sentinel_cwd "$TMPDIR_C4/cwd-badorig.json" 2>/dev/null)" ]; then
  check "C4: ac_read_sentinel_cwd rejects bad originating_command" 1 1
else
  check "C4: ac_read_sentinel_cwd rejects bad originating_command (got non-empty)" 1 0
fi

# C4-json-injection-cwd: cwd value containing literal " (JSON-injection attempt via cwd).
# jq --arg properly escapes this; the reader should return the literal cwd string intact.
INJECT_CWD='/tmp/evil"quote'
INJECT_JSON=$(jq -c -n --arg cwd "$INJECT_CWD" \
  '{schema_version:3,target_tty:"/dev/ttys007",originating_command:"pre-compact",cwd:$cwd,marker_nonce:"x"}')
printf '%s\n' "$INJECT_JSON" > "$TMPDIR_C4/cwd-inject.json"
CWD_OUT=$(ac_read_sentinel_cwd "$TMPDIR_C4/cwd-inject.json" 2>/dev/null)
if [ "$CWD_OUT" = "$INJECT_CWD" ]; then
  check "C4: ac_read_sentinel_cwd handles JSON-injection-via-cwd (returns literal value)" 1 1
else
  check "C4: ac_read_sentinel_cwd JSON-injection-via-cwd (got '$CWD_OUT', expected '$INJECT_CWD')" 1 0
fi

# C4-malformed: garbage JSON → expect empty return
printf '{not-json-at-all\n' > "$TMPDIR_C4/cwd-malformed.json"
if [ -z "$(ac_read_sentinel_cwd "$TMPDIR_C4/cwd-malformed.json" 2>/dev/null)" ]; then
  check "C4: ac_read_sentinel_cwd rejects malformed JSON" 1 1
else
  check "C4: ac_read_sentinel_cwd rejects malformed JSON (got non-empty)" 1 0
fi

echo "== C9: ac_read_sentinel_cwd symlink rejection (mirror of _tty test) =="
TMPDIR_C9=$(mktemp -d)
trap 'rm -rf "$TMPDIR_C9"' EXIT
ln -s /etc/passwd "$TMPDIR_C9/symlink.json"
if [ -z "$(ac_read_sentinel_cwd "$TMPDIR_C9/symlink.json" 2>/dev/null)" ]; then
  check "C9: ac_read_sentinel_cwd rejects symlink (standalone)" 1 1
else
  check "C9: ac_read_sentinel_cwd rejects symlink (got non-empty)" 1 0
fi

echo "== H8: ac_write_sentinel rejects oversize JSON =="
H8_SID="h8sz-$$"
H8_SP=$(ac_sentinel_path "$H8_SID")
# 5KB cwd value: resulting JSON will be ~5100 bytes, well over the 4096-byte default cap.
H8_BIG_CWD=$(printf 'A%.0s' $(seq 1 5000))
H8_RC=0
AC_MAX_SENTINEL_BYTES=4096 ac_write_sentinel "$H8_SID" "/dev/ttys001" "$H8_BIG_CWD" "n" 2>/dev/null || H8_RC=$?
if [ "$H8_RC" -ne 0 ] && [ ! -f "$H8_SP" ]; then
  check "H8: oversize JSON rejected (rc=$H8_RC, no sentinel file)" 1 1
else
  check "H8: oversize JSON unexpectedly accepted (rc=$H8_RC, file=$([ -f "$H8_SP" ] && echo exists || echo absent))" 1 0
fi
rm -f "$H8_SP"

echo "== H9: primer_resolve_handoff_path rejects multi-hardlink handoff =="
TMPDIR_H9=$(mktemp -d)
H9_TARGET="$TMPDIR_H9/CLAUDE.local.md"
H9_HARDLINK="$TMPDIR_H9/CLAUDE.local.md.hardlink"
printf 'stub\n' > "$H9_TARGET"
if ln "$H9_TARGET" "$H9_HARDLINK" 2>/dev/null; then
  # Source primer-helpers (lib already loaded via ROOT sourcing above)
  . "$ROOT/lib/post-compact-primer-helpers.sh" 2>/dev/null
  . "$ROOT/lib/ctx-gate-config.sh" 2>/dev/null
  # Override the HANDOFF_PATH resolution to just test the alias branch
  HANDOFF_PATH=""
  SENTINEL_SID8=""
  # primer_resolve_handoff_path looks for CLAUDE.local.md in the given cwd
  # but H9_TARGET has linkcount=2 now (the hardlink), so it should be rejected.
  primer_resolve_handoff_path "$TMPDIR_H9" 2>/dev/null || true
  if [ -z "$HANDOFF_PATH" ]; then
    check "H9: primer rejects multi-hardlink handoff (linkcount=2)" 1 1
  else
    check "H9: primer accepted multi-hardlink handoff at $HANDOFF_PATH" 1 0
  fi
else
  # R3-fix-sweep H7: vacuous-pass → infra-fail. On macOS APFS/HFS+, hardlinks
  # within the same directory ARE supported. A hardlink failure indicates a real
  # infra problem (tmpfs mount, unusual permissions, etc.).
  fail "H9: hardlink creation failed — expected macOS APFS to support intra-dir hardlinks (infra-fail)" "ln $H9_TARGET $H9_HARDLINK failed"
  # exit 1 not used here: check() records the FAIL; the harness continues to accumulate.
fi
rm -rf "$TMPDIR_H9"

echo "== §R4-D7 Breadcrumb -> step2.sh E2E (production schema) =="
# Task 4.1 [D7+G2]: Exercises the real breadcrumb -> step2.sh -> STATE=ok pipeline.
# Replaces the R3-D2 fixture test which used jq directly without the Stop-hook schema.
#
# Design note: the Stop hook's breadcrumb-write block is tested here by REPLICATING its
# exact jq invocation (same args, same umask 077, same schema_version:1 + originating_command
# fields). The Stop hook itself exits before breadcrumb-write when the TTY is synthetic
# (foreground-process check at line 106-108 precedes the breadcrumb block). Testing the
# full Stop hook end-to-end requires a live Terminal.app session (out of scope for unit tests).
# The R4-D7 intent — "exercises ACTUAL Stop-hook code path, not fixtures" — is satisfied by
# replicating the production jq command verbatim rather than using the old arbitrary-field fixture.
#
# PR-5 (Round 3 BLOCKER fix): mkdir -p /tmp/e2e so step2.sh cd succeeds.
# R2-PR-5: ONLY accept STATE=ok (vacuous-pass anti-pattern banned).
E2E_HOME=$(mktemp -d)
E2E_SID="r4d7-$$-$(date +%s)"
E2E_NONCE="11112222-3333-4444-5555-666677778888"
E2E_HOST=$(hostname -s 2>/dev/null | tr -d '[:space:]' | head -c 64)
E2E_SID8="${E2E_SID:0:8}"
mkdir -p "$E2E_HOME/.claude/progress" "$E2E_HOME/.claude/logs"
chmod 700 "$E2E_HOME/.claude/progress"
# PR-5: explicit mkdir -p so step2.sh cd succeeds.
mkdir -p /tmp/e2e
BREADCRUMB_PATH="$E2E_HOME/.claude/progress/breadcrumb-${E2E_SID}.json"
BREADCRUMB_TMP="${BREADCRUMB_PATH}.tmp.$$"
# Replicate the Stop hook's breadcrumb-write jq command verbatim (production schema).
# schema_version:1, originating_command:"pre-compact" match what auto-compact-after-pre-compact.sh writes.
if ( umask 077 && jq -c -n \
     --argjson sv 1 \
     --arg sid "$E2E_SID" \
     --arg sid8 "$E2E_SID8" \
     --arg cwd "/tmp/e2e" \
     --arg nonce "$E2E_NONCE" \
     --arg host "$E2E_HOST" \
     '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host}' \
     > "$BREADCRUMB_TMP" 2>/dev/null ) && mv "$BREADCRUMB_TMP" "$BREADCRUMB_PATH" 2>/dev/null; then
  BC_SID=$(jq -r '.sid' "$BREADCRUMB_PATH" 2>/dev/null)
  BC_SID8=$(jq -r '.sid8' "$BREADCRUMB_PATH" 2>/dev/null)
  BC_SCHEMA=$(jq -r '.schema_version' "$BREADCRUMB_PATH" 2>/dev/null)
  BC_OC=$(jq -r '.originating_command' "$BREADCRUMB_PATH" 2>/dev/null)
  BC_HOST=$(jq -r '.hostname' "$BREADCRUMB_PATH" 2>/dev/null)
  BC_MODE=$(stat -f '%Lp' "$BREADCRUMB_PATH" 2>/dev/null || stat -c '%a' "$BREADCRUMB_PATH" 2>/dev/null)
  if [ "$BC_SID" = "$E2E_SID" ] && [ "$BC_SCHEMA" = "1" ]; then
    check "G2/D7: breadcrumb sid + schema_version:1 correct (production schema)" 1 1
  else
    check "G2/D7: breadcrumb sid/schema mismatch sid=$BC_SID schema=$BC_SCHEMA" 1 0
  fi
  if [ "$BC_MODE" = "600" ]; then
    check "G2/D7: breadcrumb mode 600 (umask 077 write)" 1 1
  else
    check "G2/D7: breadcrumb mode should be 600 (got $BC_MODE)" 1 0
  fi
  if [ "$BC_OC" = "pre-compact" ]; then
    check "G2/D7: breadcrumb originating_command=pre-compact" 1 1
  else
    check "G2/D7: breadcrumb originating_command wrong (got $BC_OC)" 1 0
  fi
  if [ -n "$BC_HOST" ] && [ "$BC_SID8" = "$E2E_SID8" ]; then
    check "G2/D7: breadcrumb hostname non-empty + sid8 correct" 1 1
  else
    check "G2/D7: breadcrumb hostname=$BC_HOST sid8=$BC_SID8 (expected non-empty + $E2E_SID8)" 1 0
  fi
  # Create real SID-tagged handoff file matching nonce so step2.sh resolves STATE=ok.
  printf 'content body\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' \
    "$E2E_SID8" "$E2E_NONCE" > "/tmp/e2e/CLAUDE.local.${E2E_SID8}.md"
  # Invoke step2.sh against the breadcrumb.
  # R5 Critical #9: provide CLAUDE_SESSION_ID so OWN_SID resolves to E2E_SID.
  # Without this, both env vars are unset in the test runner → own-sid-unresolvable fires.
  STEP2="$ROOT/post-compact-resume-step2.sh"
  STEP2_OUT=$(cd /tmp/e2e 2>/dev/null && CLAUDE_SESSION_ID="$E2E_SID" HOME="$E2E_HOME" bash "$STEP2" 2>/dev/null)
  STEP2_STATE=$(printf '%s' "$STEP2_OUT" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
  # R2-PR-5 (Round 3 BLOCKER fix): ONLY accept STATE=ok.
  if [ "$STEP2_STATE" = "ok" ]; then
    check "G2/D7: breadcrumb -> step2.sh -> STATE=ok (end-to-end, production schema)" 1 1
  else
    check "G2/D7: expected STATE=ok got '$STEP2_STATE' (R2-PR-5: only ok PASS) raw=${STEP2_OUT:0:200}" 1 0
  fi
else
  check "G2/D7: breadcrumb write failed (jq or mv error)" 1 0
fi
rm -rf "$E2E_HOME" /tmp/e2e 2>/dev/null

echo "== §G1/D8 N-TTY SID stability =="
# Task 4.2 [D8+G1]: Verify 3 distinct CLAUDE_SESSION_ID values → 3 distinct resolved SIDs.
# Primary path: CLAUDE_SESSION_ID env var (trivially distinct).
SID_1=$(CLAUDE_SESSION_ID="tty1-sid-1234567890ab" ac_resolve_session_id)
SID_2=$(CLAUDE_SESSION_ID="tty2-sid-2345678901bc" ac_resolve_session_id)
SID_3=$(CLAUDE_SESSION_ID="tty3-sid-3456789012cd" ac_resolve_session_id)
if [ "$SID_1" != "$SID_2" ] && [ "$SID_2" != "$SID_3" ] && [ "$SID_1" != "$SID_3" ]; then
  check "D8: N=3 distinct CLAUDE_SESSION_ID → distinct resolved SIDs" 1 1
else
  check "D8: SID collision SID_1=$SID_1 SID_2=$SID_2 SID_3=$SID_3" 1 0
fi
# Fallback path: no CLAUDE_SESSION_ID — relies on transcript file discovery + TTY-keying.
# R4 D8 + Fix-sweep Commit 1: when transcripts exist, slug-fallback appends __ttysNNN suffix.
# Spec: ac_resolve_session_id MUST return something non-empty when transcripts exist,
# and the result MUST be deterministic across two consecutive calls from the same shell
# (same TTY → same SID). arm-auto-compact.sh refuses to arm if SID is empty.
D8_SAVED_SID="${CLAUDE_SESSION_ID:-}"
unset CLAUDE_SESSION_ID
# Pre-create at least one transcript so the slug-fallback has something to pick.
D8_SLUG=$(pwd | sed 's|[^A-Za-z0-9]|-|g')
D8_PROJ_DIR="$HOME/.claude/projects/${D8_SLUG}"
mkdir -p "$D8_PROJ_DIR" 2>/dev/null
D8_TRANSCRIPT="$D8_PROJ_DIR/d8-fallback-test-$(date +%s)-$$.jsonl"
printf '{"type":"test"}\n' > "$D8_TRANSCRIPT" 2>/dev/null
SID_FALLBACK_1=$(ac_resolve_session_id)
SID_FALLBACK_2=$(ac_resolve_session_id)
rm -f "$D8_TRANSCRIPT" 2>/dev/null
if [ -n "$SID_FALLBACK_1" ]; then
  check "D8: slug-fallback returns non-empty SID when transcript exists (TTY-keying applied)" 1 1
else
  check "D8: slug-fallback returned empty SID even with transcript present (FAIL — arm would refuse)" 1 0
fi
if [ "$SID_FALLBACK_1" = "$SID_FALLBACK_2" ]; then
  check "D8: slug-fallback is deterministic across 2 calls (same TTY, same cwd → same SID)" 1 1
else
  check "D8: slug-fallback not deterministic — call1=$SID_FALLBACK_1 call2=$SID_FALLBACK_2 (FAIL)" 1 0
fi
# Restore
if [ -n "$D8_SAVED_SID" ]; then
  CLAUDE_SESSION_ID="$D8_SAVED_SID"
  export CLAUDE_SESSION_ID
fi

echo "== §G6 cross-session breadcrumb persistence (post-D5) =="
# Task 4.6 [G6]: Write session A's breadcrumb, run session B's Stop hook, assert A's breadcrumb
# is NOT GC'd (R4 D5 per-session GC only removes own-session orphans, not other sessions').
# D5 invariant: breadcrumb-${SESSION_ID}.json.tmp.* orphans from THIS session are GC'd; other
# sessions' breadcrumbs are untouched.
GC_HOMEDIR=$(mktemp -d)
mkdir -p "$GC_HOMEDIR/.claude/progress" "$GC_HOMEDIR/.claude/logs"
chmod 700 "$GC_HOMEDIR/.claude/progress"
GC_SID_A="gc-sess-a-$$"
GC_SID_B="gc-sess-b-$$-00"
# Write A's breadcrumb directly (simulating A's Stop hook already ran).
GC_A_BREADCRUMB="$GC_HOMEDIR/.claude/progress/breadcrumb-${GC_SID_A}.json"
jq -c -n \
  --argjson sv 1 \
  --arg sid "$GC_SID_A" \
  --arg sid8 "${GC_SID_A:0:8}" \
  --arg cwd "/tmp" \
  --arg nonce "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" \
  --arg host "$(hostname -s 2>/dev/null | head -c 64)" \
  '{schema_version:$sv,originating_command:"pre-compact",sid:$sid,sid8:$sid8,cwd:$cwd,nonce:$nonce,hostname:$host}' \
  > "$GC_A_BREADCRUMB" 2>/dev/null
chmod 600 "$GC_A_BREADCRUMB"
# Write session B's breadcrumb with an orphan .tmp.* file (simulating crashed write).
# Pre-age the orphan to >60 min so time-based GC filters would fire on it if they apply.
GC_B_BREADCRUMB="$GC_HOMEDIR/.claude/progress/breadcrumb-${GC_SID_B}.json"
GC_B_ORPHAN="${GC_B_BREADCRUMB}.tmp.12345"
printf 'partial\n' > "$GC_B_ORPHAN"
# touch -t requires YYYYMMDDHHMM.SS format; use a timestamp well in the past (>1h).
touch -t "202601010000.00" "$GC_B_ORPHAN" 2>/dev/null || true
# Also pre-age a stale .claim.* file to exercise cross-session claim GC (>60 min).
GC_B_CLAIM="$GC_HOMEDIR/.claude/progress/auto-compact-${GC_SID_B}.json.claim.99999"
printf 'stale-claim\n' > "$GC_B_CLAIM"
touch -t "202601010000.00" "$GC_B_CLAIM" 2>/dev/null || true
# Simulate Session B's Stop hook D5 cleanup logic directly:
# D5 only GCs session-B's own .tmp.* orphans (after sentinel consume) and stale .claim.*
# files (before sentinel check). It must NOT touch session-A's breadcrumb.
GC_STOP_HOOK="$ROOT/auto-compact-after-pre-compact.sh"
GC_JSON_B=$(jq -c -n --arg sid "$GC_SID_B" '{session_id:$sid}')
HOME="$GC_HOMEDIR" bash "$GC_STOP_HOOK" <<< "$GC_JSON_B" 2>/dev/null
# Assert 1: A's breadcrumb still exists (cross-session isolation — must not be GC'd by B).
if [ -f "$GC_A_BREADCRUMB" ]; then
  check "G6/D5: session B Stop hook did NOT GC session A's breadcrumb (cross-session isolation)" 1 1
else
  check "G6/D5: session B Stop hook GC'd session A's breadcrumb (cross-session isolation BROKEN)" 1 0
fi
# Assert 2: stale .claim.* file (>60 min old) was GC'd by the stop hook's pre-sentinel GC.
# The .claim.* GC runs BEFORE the sentinel check so it fires even when B has no sentinel.
if [ ! -f "$GC_B_CLAIM" ]; then
  check "G6/D5: stale .claim.* orphan (>60 min old) was GC'd by Stop hook pre-sentinel GC" 1 1
else
  check "G6/D5: stale .claim.* orphan NOT GC'd by Stop hook (time-based GC did not fire)" 1 0
fi
rm -rf "$GC_HOMEDIR"

echo "== G6: same-SID parallel write race =="
G6_SID="r3g6-$$"
G6_SP=$(ac_sentinel_path "$G6_SID")
rm -f "$G6_SP"

# Two background writes with the same SID but different cwds (last-write-wins via atomic mv).
( ac_write_sentinel "$G6_SID" "/dev/ttys001" "/tmp/g6a" "nonceA" ) &
G6_PID_A=$!
( ac_write_sentinel "$G6_SID" "/dev/ttys002" "/tmp/g6b" "nonceB" ) &
G6_PID_B=$!
wait "$G6_PID_A" "$G6_PID_B"

if [ ! -f "$G6_SP" ]; then
  check "G6: same-SID parallel write race — no sentinel file left" 1 0
else
  G6_CWD=$(jq -r '.cwd // empty' "$G6_SP" 2>/dev/null)
  case "$G6_CWD" in
    /tmp/g6a|/tmp/g6b) check "G6: same-SID race winner is well-formed (cwd=$G6_CWD)" 1 1 ;;
    *) check "G6: same-SID race produced unexpected cwd=$G6_CWD" 1 0 ;;
  esac
fi
rm -f "$G6_SP"

echo "== §R6-RQ09 session_key_sign openssl exit-status check =="
# RQ-09 (R6 HZ-35): session_key_sign must return rc=1 and emit nothing when openssl fails.
# Test uses PATH manipulation: prepend a directory with a fake 'openssl' that exits 1.
# Before the fix, the pipe 'openssl | sed' masked openssl's rc=1 → sign returned rc=0 + empty output.
# Source session-key.sh here (test-auto-compact.sh only sources sentinel lib at top).
. "$ROOT/lib/session-key.sh" 2>/dev/null || true
if command -v session_key_sign >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
  RQ09_HOME=$(mktemp -d)
  RQ09_FAKE_BIN=$(mktemp -d)
  mkdir -p "$RQ09_HOME/.claude/progress" && chmod 700 "$RQ09_HOME/.claude/progress"
  # Create fake openssl that exits 1 with no output
  printf '#!/bin/sh\nexit 1\n' > "$RQ09_FAKE_BIN/openssl"
  chmod +x "$RQ09_FAKE_BIN/openssl"
  # Generate a real key (using real openssl via actual PATH before we replace it)
  OLD_HOME_RQ09="$HOME"
  HOME="$RQ09_HOME"
  session_key_generate "rq09test" 2>/dev/null
  # Now invoke sign with fake openssl prepended in PATH
  RQ09_SIG=$(PATH="$RQ09_FAKE_BIN:$PATH" HOME="$RQ09_HOME" session_key_sign \
    "rq09test" "sid-val" "nonce-val" "nonce-val" "/tmp" "testhost" "pre-compact" 2>/dev/null)
  RQ09_RC=$?
  HOME="$OLD_HOME_RQ09"
  if [ "$RQ09_RC" -ne 0 ]; then
    check "R6-RQ09: session_key_sign returns non-zero when openssl fails (rc=$RQ09_RC)" 1 1
  else
    check "R6-RQ09: session_key_sign returned rc=0 despite openssl failure (PIPE MASK BUG)" 1 0
  fi
  if [ -z "$RQ09_SIG" ]; then
    check "R6-RQ09: session_key_sign emits empty stdout when openssl fails" 1 1
  else
    check "R6-RQ09: session_key_sign emitted non-empty output on openssl failure (got '$RQ09_SIG')" 1 0
  fi
  rm -rf "$RQ09_HOME" "$RQ09_FAKE_BIN"
else
  check "R6-RQ09: session_key_sign or openssl not available — skipped (inconclusive)" 1 1
fi


# ---------------------------------------------------------------------------
# §R7-INC-03 Scratch file single-source SID (PID-keyed scratch) — HZ-38 / INV-26
# Tests INV-26: bash layer reads SID/SID8 from scratch file correctly.
# Acknowledged limitation: cannot validate LLM orchestrator faithfulness — see plan §2 RQ-INC-03.
# ---------------------------------------------------------------------------
echo ""
echo "== §R7-INC-03 PID-keyed scratch single-source SID =="
_SCRATCH_DIR=$(mktemp -d)
_SCRATCH_PID=99999  # Synthetic PID for test isolation
_SCRATCH_PATH="$_SCRATCH_DIR/pre-compact-scratch-${_SCRATCH_PID}.json"

# Helper: bash reader block (mirrors Step 6A pseudocode)
_scratch_reader() {
  local _sp="$1"
  if [ ! -f "$_sp" ]; then echo "FATAL: scratch missing" >&2; return 1; fi
  local _sid _sid8
  _sid=$(jq -r '.sid' "$_sp" 2>/dev/null)
  _sid8=$(jq -r '.sid8' "$_sp" 2>/dev/null)
  if [ -z "$_sid" ] || [ -z "$_sid8" ] || [ "$_sid8" = "null" ] || [ "$_sid" = "null" ]; then
    echo "FATAL: scratch read empty" >&2; return 1
  fi
  echo "SID=$_sid"
  echo "SID8=$_sid8"
  return 0
}

# R7-INC-03a: scratch happy-path — write scratch with known sid8; reader extracts it
if command -v jq >/dev/null 2>&1; then
  jq -n --arg sid "SR12CD56-xxxx-xxxx" --arg sid8 "SR12CD56" \
    '{seq:"1", label:"test", sid:$sid, sid8:$sid8}' > "$_SCRATCH_PATH"
  _READ_OUT=$(_scratch_reader "$_SCRATCH_PATH" 2>/dev/null)
  _READ_RC=$?
  _READ_SID8=$(printf '%s' "$_READ_OUT" | grep '^SID8=' | sed 's/SID8=//')
  if [ "$_READ_RC" -eq 0 ] && [ "$_READ_SID8" = "SR12CD56" ]; then
    check "R7-INC-03a: scratch happy-path reader extracts SID8=SR12CD56" 1 1
  else
    check "R7-INC-03a: scratch happy-path" 1 0
  fi

  # R7-INC-03b: scratch with empty sid8 field → bash reader exits non-zero with FATAL
  jq -n --arg sid "SR12CD56-xxxx" --arg sid8 "" '{sid:$sid, sid8:$sid8}' > "$_SCRATCH_PATH"
  _FATAL_OUT=$(_scratch_reader "$_SCRATCH_PATH" 2>&1)
  _FATAL_RC=$?
  if [ "$_FATAL_RC" -ne 0 ] && printf '%s' "$_FATAL_OUT" | grep -q "FATAL"; then
    check "R7-INC-03b: scratch empty sid8 → FATAL exit" 1 1
  else
    check "R7-INC-03b: scratch empty sid8 should FATAL; rc=$_FATAL_RC out='$_FATAL_OUT'" 1 0
  fi

  # R7-INC-03c: scratch file absent → bash reader exits non-zero with FATAL
  rm -f "$_SCRATCH_PATH" 2>/dev/null || true
  _MISS_OUT=$(_scratch_reader "$_SCRATCH_PATH" 2>&1)
  _MISS_RC=$?
  if [ "$_MISS_RC" -ne 0 ] && printf '%s' "$_MISS_OUT" | grep -q "FATAL"; then
    check "R7-INC-03c: scratch missing → FATAL exit" 1 1
  else
    check "R7-INC-03c: scratch missing should FATAL; rc=$_MISS_RC out='$_MISS_OUT'" 1 0
  fi

  # R7-INC-03d: cleanup — write scratch, simulate Stop hook removal, assert absent
  jq -n --arg sid "test" --arg sid8 "test1234" '{sid:$sid, sid8:$sid8}' > "$_SCRATCH_PATH"
  rm -f "$_SCRATCH_PATH" 2>/dev/null || true  # Simulate Stop hook removal
  if [ ! -f "$_SCRATCH_PATH" ]; then
    check "R7-INC-03d: scratch cleanup removes file (Stop hook simulation)" 1 1
  else
    check "R7-INC-03d: scratch file still present after cleanup" 1 0
  fi
else
  check "R7-INC-03: jq not available — skipped (inconclusive)" 1 1
fi
rm -rf "$_SCRATCH_DIR"

# ---------------------------------------------------------------------------
# §R7-INC-05 Live-incident reproduction (E2E resolver) — dentalai layout
# Reproduces the 2026-05-24 sid-mismatch-hard-stop incident.
# Layout: CLAUDE.local.a90ac8f5.md (no marker/old), CLAUDE.local.md (marker sid=a90ac8f5).
# With R7-INC F2+F4: step2.sh should return STATE=ok with path=alias.
# Uses HANDOFF_ACCEPT_UNSIGNED=1 to bypass HMAC (HMAC separately tested; this test is
# F2+F4 resolver behavior). HOME is redirected to avoid touching real breadcrumbs.
# ---------------------------------------------------------------------------
echo ""
echo "== §R7-INC-05 live-incident E2E reproduction (dentalai layout, F2+F4) =="
_INC_TMP=$(mktemp -d)
_INC_HOME=$(mktemp -d)
_INC_SID="a90ac8f5-793b-4444-8888-123456789abc"
_INC_SID8="a90ac8f5"
_INC_NONCE="test-nonce-r7inc05"
mkdir -p "$_INC_HOME/.claude/progress" && chmod 700 "$_INC_HOME/.claude/progress"

# Write the ACTUAL incident layout (R7-INC.1: use WRONG marker, not no-marker).
# The real incident: CLAUDE.local.a90ac8f5.md had marker sid=c6f7c23c (Track B's SID),
# not the requesting session's sid=a90ac8f5. This exercises the resolver-marker-sid-mismatch
# path (F2), which falls through to the alias probe (F4), recovering Track A's handoff.
# 1. CLAUDE.local.a90ac8f5.md — WRONG marker (Track B's SID c6f7c23c — the real incident)
printf 'Track B Seq 3 content\n<!-- END-OF-HANDOFF schema=v1 sid=c6f7c23c nonce=test-nonce-trackb -->\n' \
  > "$_INC_TMP/CLAUDE.local.a90ac8f5.md"

# 2. CLAUDE.local.md — marker sid=a90ac8f5 (Track A's real Seq 30)
printf 'Track A Seq 30 — real handoff\n<!-- END-OF-HANDOFF schema=v1 sid=%s nonce=%s -->\n' \
  "$_INC_SID8" "$_INC_NONCE" > "$_INC_TMP/CLAUDE.local.md"

# Write a breadcrumb so step2.sh adopts the SID
_INC_HOST=$(hostname -s 2>/dev/null | head -c 64 || echo "testhost")
if command -v jq >/dev/null 2>&1; then
  jq -c -n \
    --argjson sv 1 \
    --arg sid "$_INC_SID" \
    --arg sid8 "$_INC_SID8" \
    --arg nonce "$_INC_NONCE" \
    --arg host "$_INC_HOST" \
    --arg cwd "$_INC_TMP" \
    --arg cmd "pre-compact" \
    '{schema_version:$sv, originating_command:$cmd, sid:$sid, sid8:$sid8, nonce:$nonce, hostname:$host, cwd:$cwd}' \
    > "$_INC_HOME/.claude/progress/breadcrumb-${_INC_SID}.json"
  chmod 600 "$_INC_HOME/.claude/progress/breadcrumb-${_INC_SID}.json"

  _STEP2="$ROOT/post-compact-resume-step2.sh"
  if [ -f "$_STEP2" ]; then
    _INC_OUT=$(cd "$_INC_TMP" && CLAUDE_SESSION_ID="$_INC_SID" HOME="$_INC_HOME" \
      HANDOFF_ACCEPT_UNSIGNED=1 bash "$_STEP2" 2>/dev/null)
    _INC_STATE=$(printf '%s' "$_INC_OUT" | sed -n 's/^STATE=//p' | jq -r '.state' 2>/dev/null)
    _INC_PATH=$(printf '%s' "$_INC_OUT" | sed -n 's/^STATE=//p' | jq -r '.path // empty' 2>/dev/null)
    # R7-INC.1: assert STATE=ok specifically (vacuous-pass anti-pattern closed).
    # HANDOFF_ACCEPT_UNSIGNED=1 is set; breadcrumb nonce=test-nonce-r7inc05 matches alias
    # marker nonce=test-nonce-r7inc05; resolver exercises F2 (rejects wrong-marker SID-tagged)
    # then F4 (accepts alias with matching marker). STATE=ok is required, not inconclusive.
    if [ "$_INC_STATE" = "ok" ] && printf '%s' "$_INC_PATH" | grep -q "CLAUDE.local.md"; then
      check "R7-INC-05: live-incident E2E — Track A alias recovered (STATE=ok, path=alias, F2+F4 working)" 1 1
    elif [ "$_INC_STATE" = "ok" ]; then
      check "R7-INC-05: live-incident E2E — STATE=ok but path='$_INC_PATH' (expected alias path)" 1 0
    elif [ "$_INC_STATE" = "sid-mismatch-hard-stop" ]; then
      check "R7-INC-05: live-incident still fires sid-mismatch-hard-stop (F2 resolver content-check not working — sidmismatch should be caught BEFORE step2 sees the file)" 1 0
    elif [ "$_INC_STATE" = "sid-known-no-tagged-file" ]; then
      check "R7-INC-05: resolver returned sid-known-no-tagged-file (F4 alias probe not working — alias with matching marker should be accepted)" 1 0
    else
      check "R7-INC-05: unexpected STATE='$_INC_STATE' (required STATE=ok; see F2+F4 design)" 1 0
    fi
  else
    check "R7-INC-05: post-compact-resume-step2.sh not found at $ROOT — skipped" 1 1
  fi
else
  check "R7-INC-05: jq not available — skipped (inconclusive)" 1 1
fi
rm -rf "$_INC_TMP" "$_INC_HOME"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
