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
  if [ -f "$p" ] && jq -e . "$p" >/dev/null 2>&1; then
    cat "$p"
    return 0
  fi

  # Corrupt or missing manifest. Try to rebuild from the ledger if it exists.
  if [ -f "$l" ]; then
    local first_ts last_line last_ts last_seq last_status last_ns inferred_handoff
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
    if command -v handoff_canonical_root >/dev/null 2>&1; then
      inferred_handoff="$(handoff_canonical_root)/CLAUDE.local.${sid}.md"
    fi
    jq -nc \
      --arg sid "$sid" --arg st "${first_ts:-1970-01-01T00:00:00Z}" \
      --arg ls "${last_status:-active}" \
      --argjson seq "${last_seq:-1}" \
      --arg ns "${last_ns:-<unrecoverable — manifest corrupt and ledger lacks north_star_first_120>}" \
      --arg lhp "$inferred_handoff" --arg hb "${last_ts:-${first_ts:-1970-01-01T00:00:00Z}}" \
      '{chain_id:$sid, started_at:$st,
        north_star:$ns, north_star_source:"recovered",
        current_seq:$seq, last_handoff_path:$lhp,
        last_heartbeat_at:$hb, status:$ls,
        host:"recovered", recovered_from_ledger:true}'
    return 0
  fi

  # Truly first run.
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
