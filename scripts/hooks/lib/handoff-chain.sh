#!/usr/bin/env bash
# handoff-chain.sh — chain manifest + append-only ledger primitives for /pre-compact's
# overnight-autonomy story.
#
# Single authority used by THREE callers:
#   - commands/pre-compact.md     (writer:  Step 3.B reads/writes manifest, appends ledger)
#   - scripts/hooks/post-compact-primer.sh  (reader: prepends chain banner to SessionStart advisory)
#   - (future) any consumer that wants to inspect chain state
#
# DESIGN INVARIANT — observational, not gating: NOTHING in this lib refuses or blocks. A failed
# manifest write logs a warning and returns non-zero; callers MUST treat that as advisory and
# continue. The handoff file is the load-bearing artifact; manifest/ledger are recovery aids.
#
# Schema (slim, post-3-reviewer reconciliation): the manifest is these 10 fields:
#   chain_id, started_at, north_star, north_star_source, current_seq,
#   last_handoff_path, last_heartbeat_at, status, host, mission_path
# mission_path (additive) = absolute path to the mission file MISSION.<sid>.md at the
#   canonical root; empty string when handoff_canonical_root is unavailable.
# Corrupt-recovery paths add: recovered_from_ledger (true).
# Dropped (YAGNI): north_star_history, status_history, total_links.
#
# Ledger schema (locked TSV positions, key=value prefix on positions 2-9):
#   1=<iso_ts>  2=seq=<N>  3=ctx_pct=<%>  4=elapsed=<HhMm>  5=status=<S>
#   6=next=<one-line-up-to-120>  7=files=<N>  8=commits=<N>  9=north_star_first_120=<…>
# Field 9 lets corrupted-manifest recovery reconstruct the goal.
#
# macOS bash 3.2.57 compatible (no mapfile, no associative arrays). No ctx_gate_log dependency.

[ -n "${_HANDOFF_CHAIN_LOADED:-}" ] && return 0
readonly _HANDOFF_CHAIN_LOADED=1

# ---------------------------------------------------------------------------
# Internal: sanitize a sid argument to the platform-safe form (defense-in-depth).
# Mirrors the sanitization at commands/pre-compact.md Step 3.B and post-compact-primer.sh.
# ---------------------------------------------------------------------------
_chain_sanitize_sid() {
  printf '%s' "${1:-}" | tr -cd 'A-Za-z0-9_-' | head -c 128
}

# ---------------------------------------------------------------------------
# chain_manifest_path <sid>   →   stdout = absolute path to the manifest JSON.
# chain_ledger_path   <sid>   →   stdout = absolute path to the ledger TSV.
# ---------------------------------------------------------------------------
chain_manifest_path() {
  local sid; sid=$(_chain_sanitize_sid "$1")
  [ -n "$sid" ] || { echo "chain_manifest_path: invalid sid" >&2; return 1; }
  printf '%s\n' "$HOME/.claude/chains/${sid}.json"
}

chain_ledger_path() {
  local sid; sid=$(_chain_sanitize_sid "$1")
  [ -n "$sid" ] || { echo "chain_ledger_path: invalid sid" >&2; return 1; }
  printf '%s\n' "$HOME/.claude/chains/${sid}.log"
}

# ---------------------------------------------------------------------------
# chain_ensure_dir  — idempotent; mode 700. Mirrors ~/.claude/progress/ convention.
# Also emits a one-line stderr warning if ~/.claude/chains/ resolves under a known
# synced-folder prefix (the chain state is not designed to survive cross-device sync).
# Warning is gated to once-per-session via a marker file under ~/.claude/progress/.
# ---------------------------------------------------------------------------
chain_ensure_dir() {
  local dir="$HOME/.claude/chains"
  mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null || true
  # Synced-folder check (per-session marker so we warn at most once per session).
  local warn_marker="$HOME/.claude/progress/.chain-sync-warned-${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-unknown}}"
  if [ ! -f "$warn_marker" ]; then
    case "$dir" in
      "$HOME/Library/Mobile Documents"*|"$HOME/Dropbox"*|"$HOME/Google Drive"*|*"/iCloud Drive"*)
        echo "WARN: ~/.claude/chains/ resolves under a synced-folder path — chain state may be racy across devices." >&2
        mkdir -p "$HOME/.claude/progress" 2>/dev/null && : > "$warn_marker" 2>/dev/null
        ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# chain_manifest_read <sid>
#
# Stdout = manifest JSON (validated or recovered-from-ledger).
# Returns:
#   0 — success: stdout contains a valid JSON manifest (live or recovered)
#   1 — genuinely first run: no manifest AND no ledger for this sid
#   2 — a ledger EXISTS for this sid but recovery could not produce a valid manifest
#
# 1 AND 2 ARE NOT INTERCHANGEABLE, and conflating them is a data-loss bug (found in the
# round-5 review, 2026-08-04). When the "recovery failed" case was first added it returned 1,
# colliding with "genuinely first run" — and callers act on that difference. commands/
# pre-compact.md sets IS_FIRST_RUN=1, NEW_SEQ=1 and re-derives NORTH_STAR from $ARGUMENTS on
# the non-zero branch, so a chain with an intact ledger and one unparseable field would have
# silently RESTARTED AT SEQ 1 and overwritten the manifest, discarding the chain's history and
# its original goal. rc=2 means "this chain exists — do NOT treat it as new."
#
# Callers MUST inspect `.recovered_from_ledger == true` after rc=0 to decide whether
# to surface the recovery warning to the user (and optionally rebind north_star from
# $ARGUMENTS or a fresh tier-2 brief on the next /pre-compact run).
# ---------------------------------------------------------------------------
chain_manifest_read() {
  local sid; sid=$(_chain_sanitize_sid "$1")
  [ -n "$sid" ] || { echo "chain_manifest_read: invalid sid" >&2; return 1; }
  local p="$HOME/.claude/chains/${sid}.json"
  local l="$HOME/.claude/chains/${sid}.log"

  # Valid live manifest → fast path.
  # SHAPE-CHECKED, not merely parseable. `jq -e .` alone answers "is this JSON?", which is a
  # different question from "is this a manifest": measured, it returns 0 for `{}`, `[]`, `0`
  # and `"just a string"`. The primer then took the success branch and rendered a chain banner
  # out of `.north_star // ""` / `.current_seq // 1` / `.status // "active"` — a hollow banner
  # of default fields, which is exactly what the recovery branch below was hardened to prevent.
  # The two halves of this function disagreed: one validated its output, the other trusted the
  # file. Keys kept minimal (an object carrying chain_id and current_seq) so a manifest that
  # gains or loses optional fields is not rejected.
  if [ -f "$p" ] && jq -e 'type == "object" and has("chain_id") and has("current_seq")' "$p" >/dev/null 2>&1; then
    cat "$p"
    return 0
  fi
  # A file that exists but is not a manifest is NOT a first run - say so, and say why.
  if [ -f "$p" ]; then
    echo "chain_manifest_read: $p is not a valid manifest (bad JSON, or not an object with chain_id + current_seq) - attempting ledger recovery" >&2
  fi

  # Corrupt or missing manifest. Try to rebuild from the ledger if it exists.
  if [ -f "$l" ]; then
    local first_ts last_line last_ts last_seq last_status last_ns inferred_handoff inferred_mission
    first_ts=$(awk -F'\t' 'NR==1{print $1; exit}' "$l")
    last_line=$(tail -n 1 "$l" 2>/dev/null)
    # Locked field positions: 1=ts  2=seq=  3=ctx_pct=  4=elapsed=  5=status=  6=next=  7=files=  8=commits=  9=north_star_first_120=
    last_ts=$(printf  '%s' "$last_line" | awk -F'\t' '{print $1}')
    last_seq=$(printf '%s' "$last_line" | awk -F'\t' '{print $2}' | sed 's/^seq=//')
    last_status=$(printf '%s' "$last_line" | awk -F'\t' '{print $5}' | sed 's/^status=//')
    last_ns=$(printf '%s' "$last_line" | awk -F'\t' '{print $9}' | sed 's/^north_star_first_120=//')
    # Best-effort inference of last_handoff_path. handoff_canonical_root is provided by
    # lib/handoff-locate.sh, which the writer + primer both source before calling us. If it isn't
    # available (e.g. someone sources this lib in isolation), we emit an empty path; consumers can
    # rederive themselves.
    inferred_handoff=""
    inferred_mission=""
    if command -v handoff_canonical_root >/dev/null 2>&1; then
      inferred_handoff="$(handoff_canonical_root)/CLAUDE.local.${sid}.md"
      inferred_mission="$(handoff_canonical_root)/MISSION.${sid}.md"
    fi
    # BUILD, VALIDATE, THEN claim success (2026-08-03, mission part 3 "guard-integrity").
    # This used to be a bare `jq -nc ... ` followed by an unconditional `return 0`, so if jq
    # failed or was missing the function returned rc=0 having written NOTHING to stdout.
    # MEASURED with a stubbed failing jq: rc=0, stdout 0 bytes. Callers branch on the rc
    # (`if MANIFEST=$(chain_manifest_read "$SID"); then`), so they entered the success path
    # with an empty manifest and rendered a chain banner of empty fields - success reported
    # by a function that produced nothing, the class this part exists to kill.
    local _recovered
    _recovered=$(jq -nc \
      --arg sid "$sid" --arg st "${first_ts:-1970-01-01T00:00:00Z}" \
      --arg ls "${last_status:-active}" \
      --argjson seq "${last_seq:-1}" \
      --arg ns "${last_ns:-<unrecoverable — manifest corrupt and ledger lacks north_star_first_120>}" \
      --arg lhp "$inferred_handoff" --arg hb "${last_ts:-${first_ts:-1970-01-01T00:00:00Z}}" \
      --arg mp "$inferred_mission" \
      '{chain_id:$sid, started_at:$st,
        north_star:$ns, north_star_source:"recovered",
        current_seq:$seq, last_handoff_path:$lhp,
        last_heartbeat_at:$hb, status:$ls,
        host:"recovered", mission_path:$mp, recovered_from_ledger:true}') || _recovered=""
    # Non-empty AND parseable, or this is not a success. rc=1 is the honest answer: the
    # caller then treats the chain as unavailable (no banner) instead of rendering a
    # hollow one, and the reason goes to stderr where a human can see it.
    if [ -n "$_recovered" ] && printf '%s' "$_recovered" | jq -e . >/dev/null 2>&1; then
        printf '%s\n' "$_recovered"
        return 0
    fi
    # rc=2, NOT 1: a ledger exists, so this chain is real. Returning 1 here would tell the
    # caller "genuinely first run" and make it reset seq to 1 and overwrite the manifest.
    echo "chain_manifest_read: ledger recovery produced no valid manifest for $sid (jq missing or failed)" >&2
    echo "chain_manifest_read: this chain EXISTS (ledger present) - do not treat it as a first run" >&2
    return 2
  fi

  # No ledger. Distinguish "nothing was ever here" from "something was here and is broken":
  # a manifest FILE that exists is proof a chain existed, even when it is unreadable and there
  # is no ledger to rebuild it from. Returning 1 there told pre-compact "genuinely first run",
  # which reseeds NEW_SEQ=1 and OVERWRITES the corrupt file - destroying the only remaining
  # evidence of the chain. Found in round 7; the round-6 fix had only covered the
  # ledger-present case, so the identical data-loss path survived one branch over.
  if [ -f "$p" ]; then
    echo "chain_manifest_read: $p exists but is unusable and there is no ledger to recover from" >&2
    echo "chain_manifest_read: a chain EXISTED here - refusing to report a first run" >&2
    return 2
  fi

  # Truly first run: no manifest file, no ledger.
  return 1
}

# ---------------------------------------------------------------------------
# chain_manifest_write <sid>   (full JSON manifest read from stdin)
#
# Atomic tmp+rename. Validates the inbound JSON with `jq -e .` before commit.
# Does NOT do field merging or immutability enforcement — callers compose the full JSON
# via jq pipelines and pass it on stdin. Keeps this function dumb and correct.
#
# Returns:
#   0 — success
#   1 — invalid SID, invalid JSON on stdin, mktemp/rename failure (caller MUST log + continue,
#       NEVER abort /pre-compact on chain-write failure).
# ---------------------------------------------------------------------------
chain_manifest_write() {
  local sid; sid=$(_chain_sanitize_sid "$1")
  [ -n "$sid" ] || { echo "chain_manifest_write: invalid sid" >&2; return 1; }
  chain_ensure_dir
  local target="$HOME/.claude/chains/${sid}.json"
  local tmp
  tmp=$(mktemp "$HOME/.claude/chains/.${sid}.json.XXXXXX") || {
    echo "chain_manifest_write: mktemp failed" >&2; return 1; }
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    echo "chain_manifest_write: stdin read failed" >&2
    return 1
  fi
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    echo "chain_manifest_write: invalid JSON on stdin (refusing to commit garbage)" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$target"; then
    rm -f "$tmp"
    echo "chain_manifest_write: rename to $target failed" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# chain_ledger_append <sid> <iso_ts> <seq=N> <ctx_pct=N|?> <elapsed=…> <status=…> \
#                          <next=…> <files=N> <commits=N> <north_star_first_120=…>
#
# Pure `>>` append (POSIX O_APPEND on a single-line write < PIPE_BUF is atomic).
# Embedded tabs/newlines in field values are replaced with `_` so the TSV stays parseable.
# Callers SHOULD pass `key=value` strings on positions 2-9 to match the locked schema; this
# function does not enforce key prefixing (it's a stringification helper, dumb on purpose).
#
# CRITICAL bash-quoting note: this function uses $'\t' (ANSI-C quoting) for the actual tab
# character, NOT a literal `"\t"` inside double quotes (which would be the two characters
# backslash+t, breaking TSV).
# ---------------------------------------------------------------------------
chain_ledger_append() {
  local sid; sid=$(_chain_sanitize_sid "$1")
  [ -n "$sid" ] || { echo "chain_ledger_append: invalid sid" >&2; return 1; }
  shift
  chain_ensure_dir
  local line=""
  while [ "$#" -gt 0 ]; do
    local field; field=$(printf '%s' "$1" | tr '\t\n' '__')
    if [ -z "$line" ]; then
      line="$field"
    else
      line="$line"$'\t'"$field"
    fi
    shift
  done
  printf '%s\n' "$line" >> "$HOME/.claude/chains/${sid}.log"
}
