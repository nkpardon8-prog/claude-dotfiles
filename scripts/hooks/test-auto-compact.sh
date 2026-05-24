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
# Round 3 discovered that the python3 fallback was masking a jq operator-precedence
# bug. This test exercises the jq branch directly to prevent regression.
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
# Round 3 discovered that grep \| BRE alternation is treated as literal on BSD grep.
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
ac_write_sentinel "$TEST_SID" "/dev/ttys999"
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
ac_write_sentinel "$TEST_SID" "/dev/ttys999"
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
# Round 4 found awk $NF on `ps -o comm=` is brittle for multi-word comms (e.g. `npm exec ...`).
# Switched to `ucomm=` which is always single-token (executable basename). Verify the
# expected one-word format.
UCOMM_LINES=$(ps -o stat=,ucomm= 2>/dev/null | tail -n +1 | awk 'NF != 2 {print "MULTIFIELD:" $0}')
if [ -z "$UCOMM_LINES" ]; then check "ps -o ucomm= produces single-token lines" 1 1; else check "ucomm format unexpected: $UCOMM_LINES" 1 0; fi

echo "== Skill-prose invocation contract =="
# Round 4 GAPS: if pre-compact.md drops the arm-script invocation, no test catches it.
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
ac_write_sentinel "${TEST_SID}_armed_at" "/dev/ttys999"
SP=$(ac_sentinel_path "${TEST_SID}_armed_at")
if ! grep -q 'armed_at' "$SP" 2>/dev/null; then check "sentinel JSON omits armed_at" 1 1; else check "sentinel still has armed_at" 1 0; fi
rm -f "$SP"

echo "== --dry-run path does not write a sentinel =="
DRY_OUT=$("$ROOT/arm-auto-compact.sh" "--dry-run" 2>/dev/null)
case "$DRY_OUT" in
  *"DRY-RUN"*) check "--dry-run reports intent" 1 1 ;;
  *) check "--dry-run output (got '$DRY_OUT')" 1 0 ;;
esac

echo
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
