#!/usr/bin/env bash
# handoff-locate.sh — shared location + marker-SID authority for the pre-compact/resume chain.
#
# Single source of truth used by THREE callers:
#   - lib/handoff-resolve.sh   (reader: 3-probe SID-tagged resolution)
#   - lib/writer-verify.sh     (writer self-check of marker sid vs filename)
#   - commands/pre-compact.md  (writer: Step 3.B parent detection + canonical-anchor location)
#
# Provides:
#   handoff_canonical_root [cwd]   -> prints the repo's main working root (cwd-/worktree-invariant).
#   _resolver_extract_marker_sid <path> -> prints the END-OF-HANDOFF marker `sid=` value (first-occurrence).
#
# WHY a canonical anchor: `git rev-parse --show-toplevel` returns the *worktree* root, so a chain
# whose cwd flips between the main checkout and a linked worktree relocates its handoff. The
# canonical anchor = dirname(git-common-dir), which is identical from every worktree of a repo, so
# the writer always lands the handoff in one place and the reader always looks there.
#
# This file is sourced by the WRITER's bash too, so it MUST NOT reference ctx_gate_log or any
# reader-only helper. Location/identity primitives only.
#
# macOS bash 3.2.57 compatible (no mapfile, no associative arrays, no `local -n`).

[ -n "${_HANDOFF_LOCATE_LOADED:-}" ] && return 0
readonly _HANDOFF_LOCATE_LOADED=1

# ---------------------------------------------------------------------------
# handoff_canonical_root [cwd]
#
# Resolution order:
#   1. dirname(git-common-dir), accepted ONLY if a common-dir identity round-trip holds
#      (re-deriving git-common-dir from that directory yields the SAME path). This rejects
#      separate-git-dir / exported-GIT_DIR layouts where dirname(common-dir) coincidentally
#      lands inside an UNRELATED work tree.
#   2. git --show-toplevel (worktree root) — last git-based fallback.
#   3. cwd — non-git workspace.
#
# Prints one absolute path, always succeeds (rc 0).
# ---------------------------------------------------------------------------
handoff_canonical_root() {
  local cwd="${1:-$PWD}" common main rt
  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
    if [ -n "$common" ]; then
      main=$(dirname "$common")
      if [ -d "$main" ]; then
        # IDENTITY cross-check (not mere work-tree-ness): the candidate root must itself
        # resolve back to the SAME common-dir. A foreign work tree would resolve to its own.
        rt=$(git -C "$main" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
        if [ -n "$rt" ] && [ "$rt" = "$common" ]; then
          printf '%s\n' "$main"
          return 0
        fi
      fi
    fi
    main=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$main" ]; then
      printf '%s\n' "$main"
      return 0
    fi
  fi
  printf '%s\n' "$cwd"
  return 0
}

# ---------------------------------------------------------------------------
# _resolver_extract_marker_sid <path>
#
# Single canonical extractor for the END-OF-HANDOFF marker `sid=` value (moved here from
# handoff-resolve.sh so reader, writer-verify, and the writer's Step 3.B all share it).
#
# Takes the FIRST marker line, then the FIRST `sid=` token on it. The naive greedy
# `sed -nE 's/.*sid=([A-Za-z0-9_-]+).*/\1/p'` matched the LAST `sid=` on the line, so a crafted
# `sid=A sid=B` resolved to B (last-wins identity ambiguity). `grep -oE | head -1` is
# first-occurrence and BSD/macOS-bash-3.2 safe.
# ---------------------------------------------------------------------------
_resolver_extract_marker_sid() {
  grep -E '^<!-- END-OF-HANDOFF schema=v1 ' "$1" 2>/dev/null | head -1 \
    | grep -oE 'sid=[A-Za-z0-9_-]+' | head -1 | sed 's/^sid=//'
}
