#!/usr/bin/env bash
# test-ctx-gate.sh — Manual test harness for all four ctx-gate hook scripts.
#
# Runs 14 canned-input tests (§3: 3a–3l plus 3i-bis) and the 10-step synthetic
# end-to-end chain (§2.5). Uses a temp HOME so sidecar and sentinel lookups are isolated.
#
# Usage:
#   bash test-ctx-gate.sh                   # run all tests
#   cd /tmp && bash ~/.claude-dotfiles/scripts/hooks/test-ctx-gate.sh  # same, from anywhere
#
# Exits 0 if all tests pass, 1 if any fail.

set -uo pipefail

# Per Round 3 reviewer A #5 / B #6: cd to the hook directory first so all relative
# ./hook.sh invocations work regardless of where the user runs this script from.
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
# §3 canned-input tests
# ---------------------------------------------------------------------------
echo "== §3 Canned-input tests =="

# Each test creates a fresh TMPHOME, sets up sidecar / sentinel as needed,
# invokes the hook via here-string redirect (NOT pipe — per Round 4 meta-pass, inline
# HOME=val applies to the hook process, not the echo/printf before the pipe).

# 3a — UserPromptSubmit, ctx=50 (below soft): expect empty output
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '50\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "3a: submit ctx=50 → empty (below soft)"; else fail "3a: submit ctx=50 → expected empty, got: $OUT"; fi
rm -rf "$TMPHOME"

# 3b — UserPromptSubmit, ctx=73 (soft zone): expect additionalContext with "Context at 73%"
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '73\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("Context at 73%")' >/dev/null 2>&1; then
  pass "3b: submit ctx=73 → soft advisory with 'Context at 73%'"
else
  fail "3b: submit ctx=73 → expected soft advisory, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3c — UserPromptSubmit, ctx=91 (hard zone): expect "HARD CONTEXT GATE" + "Skill(pre-compact)"
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '91\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"foo","prompt":"hi","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("HARD CONTEXT GATE")' >/dev/null 2>&1 && \
   printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("Skill(pre-compact)")' >/dev/null 2>&1; then
  pass "3c: submit ctx=91 → hard directive with HARD CONTEXT GATE + Skill(pre-compact)"
else
  fail "3c: submit ctx=91 → expected hard directive, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3d — PreToolUse, ctx=85 (below hard): expect empty (no gating)
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '85\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"foo","tool_name":"Bash","tool_input":{"command":"echo hi"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "3d: pretooluse ctx=85 → empty (below hard)"; else fail "3d: pretooluse ctx=85 → expected empty, got: $OUT"; fi
rm -rf "$TMPHOME"

# 3e — PreToolUse, ctx=91, Bash(echo hi), no sentinel: expect deny
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '91\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"foo","tool_name":"Bash","tool_input":{"command":"echo hi"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 && \
   printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecisionReason | contains("Hard context gate")' >/dev/null 2>&1; then
  pass "3e: pretooluse ctx=91 Bash(echo hi) no sentinel → deny"
else
  fail "3e: pretooluse ctx=91 Bash(echo hi) → expected deny, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3f — PreToolUse, ctx=91, Bash(git status), no sentinel: expect allow (Bash allowlist)
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '91\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"foo","tool_name":"Bash","tool_input":{"command":"git status"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "3f: pretooluse ctx=91 Bash(git status) → allow (Bash allowlist)"; else fail "3f: pretooluse ctx=91 Bash(git status) → expected allow (empty), got: $OUT"; fi
rm -rf "$TMPHOME"

# 3g — PreToolUse, ctx=91, Skill(pre-compact), no sentinel: expect allow (Skill allowlisted)
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '91\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"foo","tool_name":"Skill","tool_input":{"skill":"pre-compact"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "3g: pretooluse ctx=91 Skill → allow (tool allowlist)"; else fail "3g: pretooluse ctx=91 Skill → expected allow (empty), got: $OUT"; fi
rm -rf "$TMPHOME"

# 3h — PreToolUse, ctx=91, Bash(echo hi), sentinel PRESENT: expect allow (gate released)
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '91\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
printf '{"schema_version":1,"target_tty":"/dev/ttys001","originating_command":"pre-compact"}\n' \
  > "$TMPHOME/.claude/progress/auto-compact-foo.json"
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"foo","tool_name":"Bash","tool_input":{"command":"echo hi"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "3h: pretooluse ctx=91 Bash(echo hi) sentinel-present → allow"; else fail "3h: pretooluse sentinel-present → expected allow (empty), got: $OUT"; fi
rm -rf "$TMPHOME"

# 3i — PreCompact, trigger=auto, ctx=93 (BLOCK zone: 90-94%), no sentinel: expect decision=block
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '93\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"foo","trigger":"auto","hook_event_name":"PreCompact"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass "3i: precompact trigger=auto ctx=93 no sentinel → block"
else
  fail "3i: precompact trigger=auto ctx=93 → expected block, got: $OUT"
fi
rm -rf "$TMPHOME"

# 3i-bis — PreCompact, trigger=auto, ctx=96 (≥95% RELEASE zone), no sentinel: expect empty
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '96\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"foo","trigger":"auto","hook_event_name":"PreCompact"}' 2>/dev/null)
if [ -z "$OUT" ]; then
  pass "3i-bis: precompact trigger=auto ctx=96 → release (empty, avoids deadlock)"
else
  fail "3i-bis: precompact trigger=auto ctx=96 → expected empty (release), got: $OUT"
fi
rm -rf "$TMPHOME"

# 3j — PreCompact, trigger=auto, ctx=93, sentinel PRESENT: expect empty (allow native compact)
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '93\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
printf '{"schema_version":1,"target_tty":"/dev/ttys001","originating_command":"pre-compact"}\n' \
  > "$TMPHOME/.claude/progress/auto-compact-foo.json"
OUT=$(HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"foo","trigger":"auto","hook_event_name":"PreCompact"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "3j: precompact trigger=auto ctx=93 sentinel-present → allow"; else fail "3j: precompact sentinel-present → expected allow (empty), got: $OUT"; fi
rm -rf "$TMPHOME"

# 3k — PreCompact, trigger=manual, ctx=96, no sentinel: expect empty (never block manual)
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '96\n' > "$TMPHOME/.claude/progress/ctx-foo.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"foo","trigger":"manual","hook_event_name":"PreCompact"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "3k: precompact trigger=manual → never block (empty)"; else fail "3k: precompact trigger=manual → expected empty, got: $OUT"; fi
rm -rf "$TMPHOME"

# 3l — SessionStart, source=compact, with CLAUDE.local.md in cwd: expect primer additionalContext
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/repo" && chmod 700 "$TMPHOME"
printf '# handoff\n## Active Skill State\nDetected: /plan\n' > "$TMPHOME/repo/CLAUDE.local.md"
JSON="{\"session_id\":\"newsid\",\"source\":\"compact\",\"cwd\":\"$TMPHOME/repo\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("POST-COMPACT")' >/dev/null 2>&1 && \
   printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("Active Skill State")' >/dev/null 2>&1; then
  pass "3l: primer source=compact with CLAUDE.local.md → POST-COMPACT + Active Skill State in context"
else
  fail "3l: primer → expected POST-COMPACT + Active Skill State, got: $OUT"
fi
rm -rf "$TMPHOME"

# ---------------------------------------------------------------------------
# §2.5 Synthetic end-to-end chain
# ---------------------------------------------------------------------------
echo ""
echo "== §2.5 Synthetic end-to-end hook chain =="

# Per Round 4 reviewer A #5 + meta-pass: all invocations use `HOME="$TMPHOME" ./hook.sh <<< '...'`
# rather than `HOME=... echo '...' | ./hook.sh`. Reason: in `HOME=$TMPHOME echo X | hook.sh`,
# the variable goes to `echo`, NOT `hook.sh` — the hook's sidecar lookup at
# `$HOME/.claude/progress/...` then misses TMPHOME and silently falls through (false-green pass).
# The `<<<` here-string is a redirect (not a pipeline), so `HOME=$TMPHOME hook.sh <<< '...'`
# correctly applies HOME to the only process: the hook itself.

TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude/progress" && chmod 700 "$TMPHOME/.claude/progress"
printf '91\n' > "$TMPHOME/.claude/progress/ctx-fakesid.txt"
ARM_PATH="$TMPHOME/.claude/progress/auto-compact-fakesid.json"

# Step 1: UserPromptSubmit at 91% → expect hard-gate additionalContext
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"fakesid","prompt":"do thing","cwd":"/tmp","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("HARD CONTEXT GATE")' >/dev/null 2>&1; then
  pass "§2.5 step 1: submit hook injects hard advisory at 91%"
else
  fail "§2.5 step 1: submit hook hard advisory" "submit hook didn't inject hard advisory, got: $OUT"
fi

# Step 2: PreToolUse Bash(echo hi) at 91%, no sentinel → expect deny
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Bash","tool_input":{"command":"echo hi"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "§2.5 step 2: pretooluse denies Bash at 91% before sentinel"
else
  fail "§2.5 step 2: pretooluse deny Bash" "pretooluse didn't deny Bash, got: $OUT"
fi

# Step 3: PreToolUse Skill at 91%, no sentinel → expect allow (empty)
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Skill","tool_input":{"skill":"pre-compact"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if [ -z "$OUT" ]; then
  pass "§2.5 step 3: pretooluse allows Skill at 91% (pre-compact can run)"
else
  fail "§2.5 step 3: pretooluse allow Skill" "pretooluse should allow Skill (empty output), got: $OUT"
fi

# Step 4: Simulate /pre-compact arming the sentinel
printf '{"schema_version":1,"target_tty":"/dev/ttys001","originating_command":"pre-compact"}\n' > "$ARM_PATH"

# Step 5: PreToolUse Bash(echo hi) at 91%, sentinel NOW armed → expect allow (empty)
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Bash","tool_input":{"command":"echo hi"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if [ -z "$OUT" ]; then
  pass "§2.5 step 5: pretooluse allows Bash after sentinel armed"
else
  fail "§2.5 step 5: pretooluse allow after sentinel" "pretooluse should allow Bash after sentinel armed, got: $OUT"
fi

# Step 6: UserPromptSubmit after sentinel armed → should NOT inject (sentinel-fresh skip)
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"fakesid","prompt":"do thing","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if [ -z "$OUT" ]; then
  pass "§2.5 step 6: submit hook silent after sentinel armed"
else
  fail "§2.5 step 6: submit hook silence post-sentinel" "submit hook should not advise after sentinel armed, got: $OUT"
fi

# Step 7: PreCompact trigger=auto, ctx=93 (BLOCK zone), no sentinel → should block
rm -f "$ARM_PATH"
printf '93\n' > "$TMPHOME/.claude/progress/ctx-fakesid.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"fakesid","trigger":"auto","hook_event_name":"PreCompact"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass "§2.5 step 7: precompact safety blocks at ctx=93 without sentinel"
else
  fail "§2.5 step 7: precompact block at 93" "precompact safety should block at ctx=93, got: $OUT"
fi

# Step 7b: PreCompact trigger=auto, ctx=96 (≥95% RELEASE zone) → should RELEASE (avoid deadlock)
printf '96\n' > "$TMPHOME/.claude/progress/ctx-fakesid.txt"
OUT=$(HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"fakesid","trigger":"auto","hook_event_name":"PreCompact"}' 2>/dev/null)
if [ -z "$OUT" ]; then
  pass "§2.5 step 7b: precompact safety releases at ctx=96 (avoids deadlock)"
else
  fail "§2.5 step 7b: precompact release at 96" "precompact safety should RELEASE at ctx>=95 (empty output), got: $OUT"
fi

# Step 8: SessionStart compact with CLAUDE.local.md present in cwd → primer fires
REPO_DIR="$TMPHOME/repo"
mkdir -p "$REPO_DIR" && printf '# handoff\n' > "$REPO_DIR/CLAUDE.local.md"
JSON="{\"session_id\":\"newsid\",\"source\":\"compact\",\"cwd\":\"$REPO_DIR\",\"hook_event_name\":\"SessionStart\"}"
OUT=$(HOME="$TMPHOME" ./post-compact-primer.sh <<< "$JSON" 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.additionalContext | contains("POST-COMPACT")' >/dev/null 2>&1; then
  pass "§2.5 step 8: primer fires with CLAUDE.local.md present"
else
  fail "§2.5 step 8: primer fires" "primer didn't fire, got: $OUT"
fi

# Step 9: Sentinel staleness — backdate sentinel, verify gate re-engages
printf '91\n' > "$TMPHOME/.claude/progress/ctx-fakesid.txt"
printf '{"schema_version":1,"target_tty":"/dev/ttys001","originating_command":"pre-compact"}\n' > "$ARM_PATH"
touch -t 202001010000 "$ARM_PATH"  # backdate to year 2020 — definitely stale
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Bash","tool_input":{"command":"echo hi"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "§2.5 step 9: stale sentinel re-engages gate"
else
  fail "§2.5 step 9: stale sentinel re-gate" "stale sentinel should re-gate, got: $OUT"
fi

# Step 10: Compound-command bypass — both must be denied even at non-Bash-allowlist pct
rm -f "$ARM_PATH"
printf '91\n' > "$TMPHOME/.claude/progress/ctx-fakesid.txt"

OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Bash","tool_input":{"command":"cat /etc/passwd"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "§2.5 step 10a: cat /etc/passwd denied (no bare cat in allowlist)"
else
  fail "§2.5 step 10a: cat /etc/passwd deny" "cat /etc/passwd must be denied, got: $OUT"
fi

OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Bash","tool_input":{"command":"find / | wc -l"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "§2.5 step 10b: find / | wc -l denied (pipe in compound-pre-check)"
else
  fail "§2.5 step 10b: find|wc compound deny" "find|wc compound must be denied, got: $OUT"
fi

# Step 11: Kill-switch — with CLAUDE_CTX_GATE_DISABLED=1, all hooks must be silent
printf '91\n' > "$TMPHOME/.claude/progress/ctx-fakesid.txt"

OUT=$(CLAUDE_CTX_GATE_DISABLED=1 HOME="$TMPHOME" ./ctx-gate-on-prompt-submit.sh <<< '{"session_id":"fakesid","prompt":"do","hook_event_name":"UserPromptSubmit"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "§2.5 step 11a: kill-switch silences submit hook"; else fail "§2.5 step 11a: kill-switch submit" "kill-switch should silence submit hook, got: $OUT"; fi

OUT=$(CLAUDE_CTX_GATE_DISABLED=1 HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Bash","tool_input":{"command":"echo hi"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "§2.5 step 11b: kill-switch silences pretooluse hook"; else fail "§2.5 step 11b: kill-switch pretooluse" "kill-switch should silence pretooluse hook, got: $OUT"; fi

OUT=$(CLAUDE_CTX_GATE_DISABLED=1 HOME="$TMPHOME" ./ctx-gate-precompact-safety.sh <<< '{"session_id":"fakesid","trigger":"auto","hook_event_name":"PreCompact"}' 2>/dev/null)
if [ -z "$OUT" ]; then pass "§2.5 step 11c: kill-switch silences precompact-safety hook"; else fail "§2.5 step 11c: kill-switch precompact" "kill-switch should silence precompact-safety hook, got: $OUT"; fi

# ---------------------------------------------------------------------------
# Round 1 codex-review regression tests
# ---------------------------------------------------------------------------

# Make sure sentinel is absent for these tests (gate must be active)
rm -f "$TMPHOME/.claude/progress/auto-compact-fakesid.json"
printf '91\n' > "$TMPHOME/.claude/progress/ctx-fakesid.txt"

# Step 12a: no-space pipe bypass — `cmd1|cmd2` (no spaces) must be denied
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Bash","tool_input":{"command":"ls|wc -l"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "§codex-r1 12a: no-space pipe ls|wc denied"
else
  fail "§codex-r1 12a: no-space pipe ls|wc deny" "expected deny, got: $OUT"
fi

# Step 12b: no-space semicolon — `cmd1;cmd2` (no spaces) must be denied
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Bash","tool_input":{"command":"ls;rm -rf /tmp/junk"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "§codex-r1 12b: no-space semicolon ls;rm denied"
else
  fail "§codex-r1 12b: no-space semicolon deny" "expected deny, got: $OUT"
fi

# Step 12c: double-semicolon bypass — `cmd1;;cmd2`
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Bash","tool_input":{"command":"ls;;rm -rf /tmp/junk"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "§codex-r1 12c: double-semicolon ls;;rm denied"
else
  fail "§codex-r1 12c: double-semicolon deny" "expected deny, got: $OUT"
fi

# Step 12d: ${IFS} field-separator bypass
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Bash","tool_input":{"command":"ls${IFS}/etc"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "§codex-r1 12d: \${IFS} field-separator denied"
else
  fail "§codex-r1 12d: \${IFS} deny" "expected deny, got: $OUT"
fi

# Step 12e: trailing `>` (truncation hole) — `cmd >file` must be denied even at end
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Bash","tool_input":{"command":"ls >/tmp/junk"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "§codex-r1 12e: redirect ls >/tmp/junk denied"
else
  fail "§codex-r1 12e: redirect deny" "expected deny, got: $OUT"
fi

# Step 13: future-dated sentinel must NOT be treated as fresh
SENTINEL="$TMPHOME/.claude/progress/auto-compact-fakesid.json"
printf '%s' '{"schema_version":1,"target_tty":"/dev/ttys001","originating_command":"pre-compact"}' > "$SENTINEL"
touch -t 209912312359 "$SENTINEL" 2>/dev/null || touch -d '2099-12-31 23:59' "$SENTINEL" 2>/dev/null
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Bash","tool_input":{"command":"echo hi"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "§codex-r1 13: future-dated sentinel treated as stale (gate re-engages)"
else
  fail "§codex-r1 13: future-dated sentinel" "expected gate to re-engage, got: $OUT"
fi
rm -f "$SENTINEL"

# Step 14: path traversal in Write/Edit allowlist must be denied
OUT=$(HOME="$TMPHOME" ./ctx-gate-on-pretooluse.sh <<< '{"session_id":"fakesid","tool_name":"Write","tool_input":{"file_path":"/tmp/done-plans/../../etc/passwd"},"hook_event_name":"PreToolUse"}' 2>/dev/null)
if echo "$OUT" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
  pass "§codex-r1 14: path traversal in Write denied"
else
  fail "§codex-r1 14: path traversal" "expected deny, got: $OUT"
fi

# Clean up synthetic chain temp dir
rm -rf "$TMPHOME"
echo "End-to-end synthetic chain: done"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "PASS: $PASS  FAIL: $FAIL"
if [ -n "$FAIL_NAMES" ]; then
  printf 'Failed tests:%s\n' "$FAIL_NAMES"
fi
[ "$FAIL" -eq 0 ]
