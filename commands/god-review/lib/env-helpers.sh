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
               FIX LOOP MAX_ROUNDS MAX_WALL_HOURS RESUME FORCE_RESUME PRINCIPLE \
               RESCOPE_ON_FIX ONLINE CODEX_VALIDATION_EVERY RUTHLESS SCOPE \
               REF REFTYPE STARTED_AT CODEX_AVAILABLE \
               ROUND FIXES_KEPT_THIS_ROUND NET_NEW_FINDINGS_THIS_ROUND \
               CONSECUTIVE_CLEAN_ROUNDS FROZEN_UNITS_COUNT TOTAL_OPEN_FINDINGS \
               MAX_ROUNDS_EXPLICIT; do
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
for i, seg in enumerate(parts):
    if seg == '**':
        if i == 0 and i == len(parts) - 1:
            out.append('.*')
        elif i == 0:
            out.append('(?:.*/)?')
        elif i == len(parts) - 1:
            out.append('/.*')
        else:
            out.append('(?:/.*)?')
    else:
        if i > 0 and (not out or not out[-1].endswith('?')):
            out.append('/')
        out.append(escape_seg(seg))

print('^' + ''.join(out) + '$')
__PYEOF__
}

# is_hard_gate: returns 0 if path matches any pattern in hard-gates.txt, 1 otherwise
is_hard_gate() {
  local file="$1"
  local pattern regex
  while IFS= read -r pattern; do
    [ -z "$pattern" ] || [[ "$pattern" == "#"* ]] && continue
    regex=$(glob_to_regex "$pattern")
    if echo "$file" | grep -qE "$regex"; then
      return 0
    fi
  done < "$WORKDIR/.claude-dotfiles/commands/god-review/lib/hard-gates.txt"
  # Note: that path is wrong if WORKDIR isn't ~/.claude-dotfiles. Use absolute home.
  return 1
}

# Override is_hard_gate with corrected absolute path:
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
  echo "glob_to_regex self-test: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
fi
