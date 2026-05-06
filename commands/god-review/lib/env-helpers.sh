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
               REF REFTYPE STARTED_AT CODEX_AVAILABLE; do
      eval "val=\${$var:-}"
      python3 -c "import shlex,sys; print('export {}={}'.format(sys.argv[1], shlex.quote(sys.argv[2])))" "$var" "$val"
    done
  } > "$f.tmp" && mv "$f.tmp" "$f"
}

# Glob-to-regex conversion for hard-gate matching (per Locked Decision #3 + plan algorithm)
glob_to_regex() {
  local glob="$1"
  python3 -c "
import re, sys
g = sys.argv[1]
out = []
i = 0
while i < len(g):
    c = g[i]
    if c == '*' and i+1 < len(g) and g[i+1] == '*':
        out.append('(?:.*/)?')
        i += 2
        if i < len(g) and g[i] == '/':
            i += 1
    elif c == '*':
        out.append('[^/]*')
        i += 1
    elif c == '.':
        out.append(r'\.')
        i += 1
    elif c in '[](){}+?^\$|\\\\':
        out.append('\\\\' + c)
        i += 1
    else:
        out.append(c)
        i += 1
print('^' + ''.join(out) + '\$')
" "$glob"
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
