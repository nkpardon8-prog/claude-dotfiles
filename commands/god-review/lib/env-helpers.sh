#!/bin/bash
# env-helpers.sh — cross-block variable persistence for god-review orchestrator.
# Sourced at top of every bash block in god-review.md.
# Per Locked Decisions #1, #15, #16, #18, #19 in plan 2026-05-05-god-review-fixes-plus-second-review.

# Bootstrap WORKDIR (the only var that's bootstrappable independently of .env.sh)
WORKDIR="${WORKDIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
export WORKDIR

# Source persisted env (absolute path, per Locked Decision #15)
[ -f "$WORKDIR/tmp/god-review/.env.sh" ] && source "$WORKDIR/tmp/god-review/.env.sh"

# write_env: persist all session vars to disk for next bash block to source.
# macOS bash 3.2.57 has no `printf '%q'` (Locked Decision #16) — use python3 shlex.quote.
write_env() {
  local f="$WORKDIR/tmp/god-review/.env.sh"
  mkdir -p "$WORKDIR/tmp/god-review"
  {
    echo "# refreshed: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for var in WORKDIR HAS_TANSTACK_QUERY HAS_APP_ROUTER HAS_AUTHED_HANDLER HAS_UI_PROJECT \
               HAS_BACKEND_PROJECT HAS_BACKEND_LENS_TRIGGER HAS_BENCH_SCRIPT \
               MAX_ROUNDS MAX_WALL_HOURS RESUME FORCE_RESUME PRINCIPLE \
               RESCOPE_ON_FIX ONLINE CODEX_VALIDATION_EVERY RUTHLESS SCOPE \
               REF REFTYPE STARTED_AT CODEX_AVAILABLE \
               ROUND FIXES_KEPT_THIS_ROUND \
               CONSECUTIVE_CLEAN_ROUNDS FROZEN_UNITS_COUNT TOTAL_OPEN_FINDINGS \
               MAX_ROUNDS_EXPLICIT SPINLOCK_TIMEOUT_SEC LATE_IMPORT_LINE \
               PRE_FIX_REF PRE_FIX_REFTYPE PRE_FIX_BASE_REF \
               ARCH_FILE ARCH_OUTPUT_FILE FINDING_HASH FINDING_ID \
               FINDING_FILE FINDING_LINE_RANGE FINDING_LINE_NORMALIZED \
               FINDING_CATEGORY FINDING_DESCRIPTION FINDING_ROOT_CAUSE \
               FINDING_SEVERITY FINDING_PROPOSED_DIFF \
               RATIONALE GATES_PASS GATE_FAIL_REASON \
               REGRESSION REGRESSION_REASON REVERT_REASON \
               NEW_NEW_FINDINGS DEFERRED_THIS_ROUND GATED_THIS_ROUND \
               LOOP_EXIT LOOP_EXIT_CODE RE_ENTERED_PHASE_2 \
               VERIFIER_NEW_COUNT SKIP_CODEX_VALIDATION ROUNDS \
               PERF_REGRESS_PCT INSTABILITY_RATE FROZEN_UNITS_CAP \
               SHRINKAGE_PCT SECRET_LEN_FLOOR TEST_FILE_LINE_FLOOR; do
      eval "val=\${$var:-}"
      python3 -c "import shlex,sys; print('export {}={}'.format(sys.argv[1], shlex.quote(sys.argv[2])))" "$var" "$val"
    done
  } > "$f.tmp" && mv "$f.tmp" "$f"
}

# Glob-to-regex conversion for hard-gate matching (per Locked Decision #3 + Phase E fix)
# Algorithm:
#   **/X      -> (?:.*/)?X     (recursive prefix)
#   X/**      -> X/.*          (recursive suffix)
#   **/X/**   -> (?:.*/)?X/.*
#   *         -> [^/]*         (single-segment wildcard)
#   bare name -> (?:.*/)?name  (matches anywhere in tree)
glob_to_regex() {
  local glob="$1"
  python3 - "$glob" << '__PYEOF__'
import sys

g = sys.argv[1]
has_slash = '/' in g
has_double_star = '**' in g

def escape_seg(s):
    result = []
    i = 0
    while i < len(s):
        c = s[i]
        if c == '*':
            result.append('[^/]*')
            i += 1
        elif c == '.':
            result.append(r'\.')
            i += 1
        elif c in '[](){}+?^$|\\' :
            result.append('\\' + c)
            i += 1
        else:
            result.append(c)
            i += 1
    return ''.join(result)

if not has_slash and not has_double_star:
    print('^(?:.*/)?' + escape_seg(g) + '$')
    sys.exit(0)

parts = g.split('/')
out = []
last = len(parts) - 1
for i, seg in enumerate(parts):
    if seg == '**':
        if i == 0 and i == last:
            out.append('.*')                # lone '**'
        elif i == 0:
            out.append('(?:.*/)?')         # leading '**/'
        elif i == last:
            out.append('/.*')              # trailing '/**'
        else:
            out.append('/(?:.*/)?')        # middle '/**/' — consumes leading /, allows zero-or-more dirs ending in /
    else:
        # Non-** segment. Insert '/' separator unless previous emit already ends
        # with the optional path group ('?'-terminated) which has consumed the slash.
        if i > 0 and (not out or not out[-1].endswith('?')):
            out.append('/')
        out.append(escape_seg(seg))

print('^' + ''.join(out) + '$')
__PYEOF__
}

# is_hard_gate: returns 0 if path matches any pattern in hard-gates.txt, 1 otherwise.
# Reads patterns from absolute path (independent of WORKDIR) so it works in any repo.
is_hard_gate() {
  local file="$1"
  local pattern regex
  local hg_file="$HOME/.claude-dotfiles/commands/god-review/lib/hard-gates.txt"
  [ -f "$hg_file" ] || return 1
  while IFS= read -r pattern; do
    [ -z "$pattern" ] || [[ "$pattern" == "#"* ]] && continue
    regex=$(glob_to_regex "$pattern")
    if echo "$file" | grep -qE "$regex"; then
      return 0
    fi
  done < "$hg_file"
  return 1
}

# --- Finding-history + false-positive helpers (Phase F) ---

# compute_finding_hash <file_path> <line_range_normalized> <category>
# Echoes sha256 of the triple. Use line_range_normalized = round to nearest 5
# (e.g. lines 42-47 → "40-50") per CRITERIA.md.
compute_finding_hash() {
  printf '%s|%s|%s' "$1" "$2" "$3" | shasum -a 256 | awk '{print $1}'
}

# record_finding_hash <hash>
# Atomically appends hash to state.json.finding_history_hashes.
record_finding_hash() {
  local hash="$1"
  [ -z "$hash" ] && return 1
  local p="$WORKDIR/tmp/god-review/state.json"
  [ -f "$p" ] || return 1
  python3 -c '
import json, sys
p = sys.argv[1]
h = sys.argv[2]
d = json.load(open(p))
d.setdefault("finding_history_hashes", []).append(h)
json.dump(d, open(p + ".tmp", "w"), indent=2)
' "$p" "$hash" && mv "$p.tmp" "$p"
}

# is_finding_replayed <hash>
# Returns 0 if hash is already in finding_history_hashes (already-reverted finding
# resurfacing). Use to skip retrying fixes that were tried-and-reverted in prior rounds.
is_finding_replayed() {
  local hash="$1"
  local p="$WORKDIR/tmp/god-review/state.json"
  [ -f "$p" ] || return 1
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    sys.exit(0 if sys.argv[2] in d.get("finding_history_hashes", []) else 1)
except Exception:
    sys.exit(1)
' "$p" "$hash"
}

# record_false_positive <finding_id> <file_path> <line_range> <category> <reason>
# Atomically appends FP entry to state.json.false_positives. Called from Phase 2d
# verification post-processing when validator returns FALSE_POSITIVE.
record_false_positive() {
  local p="$WORKDIR/tmp/god-review/state.json"
  [ -f "$p" ] || return 1
  python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("false_positives", []).append({
    "finding_id": sys.argv[2], "file": sys.argv[3], "line": sys.argv[4],
    "category": sys.argv[5], "reason": sys.argv[6]
})
json.dump(d, open(p + ".tmp", "w"), indent=2)
' "$p" "$1" "$2" "$3" "$4" "$5" && mv "$p.tmp" "$p"
}

# --- Phase G helpers: HUMAN_GATE batching + auto-defer + per-round counters ---

# record_human_gate_emit <finding_id> <hash> <round>
# Atomically appends to state.json.human_gate_emitted[].
record_human_gate_emit() {
  local p="$WORKDIR/tmp/god-review/state.json"
  [ -f "$p" ] || return 1
  python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("human_gate_emitted", []).append({
    "finding_id": sys.argv[2], "hash": sys.argv[3], "round": int(sys.argv[4])
})
json.dump(d, open(p+".tmp","w"), indent=2)
' "$p" "$1" "$2" "$3" && mv "$p.tmp" "$p"
}

# is_human_gate_already_emitted <hash>
# Returns 0 if hash is already in human_gate_emitted[].
is_human_gate_already_emitted() {
  local p="$WORKDIR/tmp/god-review/state.json"
  [ -f "$p" ] || return 1
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
hashes = {e.get("hash") for e in d.get("human_gate_emitted", [])}
sys.exit(0 if sys.argv[2] in hashes else 1)
' "$p" "$1"
}

# record_frozen
# Increments current round's count in frozen_added_per_round[].
record_frozen() {
  local p="$WORKDIR/tmp/god-review/state.json"
  [ -f "$p" ] || return 1
  python3 -c '
import json, sys
p = sys.argv[1]
r = int(sys.argv[2])
d = json.load(open(p))
arr = d.setdefault("frozen_added_per_round", [])
while len(arr) <= r:
    arr.append(0)
arr[r] += 1
json.dump(d, open(p+".tmp","w"), indent=2)
' "$p" "${ROUND:-0}" && mv "$p.tmp" "$p"
}

# record_architect_malformed
# Same shape as record_frozen but for architect_malformed_per_round[].
record_architect_malformed() {
  local p="$WORKDIR/tmp/god-review/state.json"
  [ -f "$p" ] || return 1
  python3 -c '
import json, sys
p = sys.argv[1]
r = int(sys.argv[2])
d = json.load(open(p))
arr = d.setdefault("architect_malformed_per_round", [])
while len(arr) <= r:
    arr.append(0)
arr[r] += 1
json.dump(d, open(p+".tmp","w"), indent=2)
' "$p" "${ROUND:-0}" && mv "$p.tmp" "$p"
}

# record_auto_defer <finding_id> <category> <reason>
# Validates reason is substantive (>= 30 chars, has structural anchor).
# Writes to RUNTIME deferral file at tmp/god-review/known-deferred-session.txt
# (NOT the committed lib/known-deferred.txt — promotion is explicit at Phase 4).
# Returns 0 on success, 1 if reason rejected.
record_auto_defer() {
  local fid="$1" category="$2" reason="$3"
  if [ "${#reason}" -lt 30 ]; then
    echo "REJECTED auto-defer: reason too short (${#reason} chars, min 30) for finding $fid" >&2
    return 1
  fi
  # Structural-anchor requirement: reason must reference a file path,
  # identifier (camelCase/snake_case/PascalCase, >=4 chars, NOT in stop-list),
  # quoted external name, or issue/PR/CVE ref. Adjective-soup is rejected
  # even if it contains a casual camelCase word.
  if ! echo "$reason" | python3 -c '
import sys, re
r = sys.stdin.read()
# Stop-list of casual camelCase/snake_case words that must not count as anchors
# (pulled from common English phrases that LLMs use in deferral reasons).
stop = {"isHard","isComplex","tooHard","tooComplex","cantFix","wontFix",
        "needMore","tooLong","tooMuch","fairly_complex","very_complex",
        "thisFeature","thisCode","thisFunction","thisModule"}
patterns = [
    # File path with extension (real anchor)
    (r"\b[\w./-]+\.(ts|tsx|js|jsx|py|go|rs|md|yml|yaml|json|sh|toml|sql|rb|java|c|h|cpp|hpp)\b", lambda m: True),
    # snake_case (>=2 underscores OR clearly identifier-shaped) — but not in stop list
    (r"\b[a-z][a-z0-9_]*_[a-z0-9_]+\b", lambda m: m.group(0) not in stop),
    # camelCase — but not in stop list
    (r"\b[a-z][a-z0-9]*[A-Z][A-Za-z0-9]+\b", lambda m: m.group(0) not in stop),
    # PascalCase
    (r"\b[A-Z][a-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]+\b", lambda m: m.group(0) not in stop),
    # Quoted external name
    (r"[\"\x27][\w./-]{4,}[\"\x27]", lambda m: True),
    # Issue / CVE ref
    (r"#\d{2,}\b|CVE-\d{4}-\d+", lambda m: True),
]
ok = False
for pat, validate in patterns:
    for m in re.finditer(pat, r):
        if validate(m):
            ok = True; break
    if ok: break
sys.exit(0 if ok else 1)
'; then
    echo "REJECTED auto-defer: reason lacks structural anchor (need file/identifier/quoted-name/ref; stop-list-filtered). Reason: '$reason'" >&2
    return 1
  fi
  local kd="$WORKDIR/tmp/god-review/known-deferred-session.txt"
  mkdir -p "$WORKDIR/tmp/god-review"
  # Format: HASH=<hash>\tCATEGORY=<cat>\tREASON=<reason> (auto-deferred round N, finding ID)
  # The leading HASH= field enables exact-match lookup via is_already_session_deferred_by_hash.
  local fhash="${FINDING_HASH:-no-hash}"
  printf 'HASH=%s\tCATEGORY=%s\tREASON=%s (auto-deferred round %s, finding %s)\n' "$fhash" "$category" "$reason" "${ROUND:-0}" "$fid" >> "$kd"
  local p="$WORKDIR/tmp/god-review/state.json"
  python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("auto_deferred", []).append({
    "finding_id": sys.argv[2], "category": sys.argv[3],
    "reason": sys.argv[4], "round": int(sys.argv[5])
})
json.dump(d, open(p+".tmp","w"), indent=2)
' "$p" "$fid" "$category" "$reason" "${ROUND:-0}" && mv "$p.tmp" "$p"
  echo "Auto-deferred $fid (${category}): $reason"
}

# is_already_session_deferred_by_hash <hash>
# Returns 0 if a finding with this exact hash is already in the session-deferred
# file. Per-finding granularity (NOT per-category), so weak deferrals don't
# suppress an entire principle's coverage.
is_already_session_deferred_by_hash() {
  local kd="$WORKDIR/tmp/god-review/known-deferred-session.txt"
  [ -f "$kd" ] || return 1
  grep -qE "^HASH=${1}	" "$kd"
}

# record_round_counts <new> <total> <deferred_this_round> <gated_this_round>
# Appends round summary to state.json.round_finding_counts[].
record_round_counts() {
  local p="$WORKDIR/tmp/god-review/state.json"
  [ -f "$p" ] || return 1
  python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.setdefault("round_finding_counts", []).append({
    "round": int(sys.argv[2]),
    "new": int(sys.argv[3]),
    "total": int(sys.argv[4]),
    "deferred_this_round": int(sys.argv[5]),
    "gated_this_round": int(sys.argv[6])
})
json.dump(d, open(p+".tmp","w"), indent=2)
' "$p" "${ROUND:-0}" "$1" "$2" "$3" "$4" && mv "$p.tmp" "$p"
}

# write_agent_finding <agent_name> <result_text>
# Writes Agent tool result text to findings/<agent_name>.txt. Used by Phase 2d
# cat-consolidation. Orchestrator calls this after each parallel batch returns.
write_agent_finding() {
  local name="$1" text="$2"
  mkdir -p "$WORKDIR/tmp/god-review/findings"
  printf '%s\n' "$text" > "$WORKDIR/tmp/god-review/findings/${name}.txt"
}

# check_phase_drift
# Diffs Phase 0/1/2 sections between god-review.md and god-report.md to detect
# drift between the two top-level commands' shared backbone. Best-effort warning.
check_phase_drift() {
  local a="$HOME/.claude-dotfiles/commands/god-review.md"
  local b="$HOME/.claude-dotfiles/commands/god-report.md"
  [ -f "$a" ] && [ -f "$b" ] || { echo "(check_phase_drift: one of the files missing)"; return 0; }
  local da=$(awk '/^## Phase 3/{p=0} p; /^## Phase 0/{p=1}' "$a")
  local db=$(awk '/^## Phase 0/{p=1} p' "$b")
  diff <(echo "$da") <(echo "$db") > /tmp/god-phase-drift.diff
  [ ! -s /tmp/god-phase-drift.diff ] || echo "WARN: Phase 0/1/2 drift detected — see /tmp/god-phase-drift.diff"
}

# Self-test (run with: bash lib/env-helpers.sh --test-globs)
if [ "${1:-}" = "--test-globs" ]; then
  pass=0; fail=0
  test_match() {
    local file="$1" pat="$2" expect="$3"
    local r=$(glob_to_regex "$pat")
    if echo "$file" | grep -qE "$r"; then got="MATCH"; else got="NO_MATCH"; fi
    if [ "$got" = "$expect" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: '$file' vs '$pat' expected $expect got $got (regex: $r)"; fi
  }
  test_match "migrations/001_init.sql" "migrations/**" MATCH
  test_match "tests/foo.spec.ts" "tests/**" MATCH
  test_match "src/auth/login.ts" "**/auth/**" MATCH
  test_match "src/foo.test.ts" "*.test.*" MATCH
  test_match "frontend/package.json" "package.json" MATCH
  test_match "package.json" "package.json" MATCH
  test_match "src/index.ts" "*.test.*" NO_MATCH
  test_match "src/index.ts" "migrations/**" NO_MATCH
  # Phase G: nested-quarantine + workflows-glob fixes
  test_match ".github/workflows/release.yml" ".github/workflows/**/*.yml" MATCH
  test_match ".github/workflows/ci/build.yml" ".github/workflows/**/*.yml" MATCH
  test_match ".github/workflows_extra/foo.yml" ".github/workflows/**/*.yml" NO_MATCH
  test_match ".github/workflows.yml" ".github/workflows/**/*.yml" NO_MATCH
  test_match "src/_deprecated/old.ts" "**/_deprecated/**" MATCH
  test_match "_deprecated/x/y/z.ts" "_deprecated/**" MATCH
  test_match "src/components/__tests__/foo.test.ts" "**/__tests__/**" MATCH
  test_match "src/index.ts" "**/_deprecated/**" NO_MATCH
  test_match "docs/test-guide.md" "**/__tests__/**" NO_MATCH
  echo "glob_to_regex self-test: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
fi
