#!/usr/bin/env bash
# diagnose-pre-compact.sh — operator diagnostic for the /pre-compact + ctx-gate system.
# Prints: hook registration state, last sentinel content, last handoff state,
# CLAUDE_CTX_GATE_DISABLED status, recent log entries from all relevant logs.
#
# Usage: bash ~/.claude-dotfiles/scripts/hooks/diagnose-pre-compact.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/lib/ctx-gate-config.sh" 2>/dev/null || { echo "ERROR: failed to source lib/ctx-gate-config.sh"; exit 1; }
. "$ROOT/lib/auto-compact-sentinel.sh" 2>/dev/null || { echo "ERROR: failed to source lib/auto-compact-sentinel.sh"; exit 1; }
. "$ROOT/lib/handoff-config.sh" 2>/dev/null || { echo "ERROR: failed to source lib/handoff-config.sh"; exit 1; }

echo "=== /pre-compact diagnostic ==="
echo "date: $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
echo "host: $(hostname)"
echo "uname: $(uname -srm)"
echo "bash: $BASH_VERSION"
echo

echo "=== Hook registration (~/.claude/settings.json) ==="
if [ -f "$HOME/.claude/settings.json" ]; then
  jq -r '.hooks | to_entries[] | "\(.key): \(.value | length) hook(s)"' "$HOME/.claude/settings.json" 2>/dev/null \
    || echo "ERROR: jq failed to parse settings.json"
  echo
  PRE_TOOL_USE_VAL=$(jq -r '.hooks.PreToolUse // "ABSENT (expected post-R2)"' "$HOME/.claude/settings.json" 2>/dev/null | head -c 50)
  echo "PreToolUse present: $PRE_TOOL_USE_VAL"
else
  echo "WARNING: ~/.claude/settings.json not found"
fi
echo

echo "=== Thresholds (ctx-gate-config + handoff-config) ==="
echo "CTX_SOFT_PCT=${CTX_SOFT_PCT:-unset}"
echo "CTX_IMPORTANT_PCT=${CTX_IMPORTANT_PCT:-unset}"
echo "CTX_FORCE_PCT=${CTX_FORCE_PCT:-unset}"
echo "HANDOFF_STALE_SECS=${HANDOFF_STALE_SECS:-unset}"
CUTOFF_EPOCH="${HANDOFF_LEGACY_CUTOFF_EPOCH:-0}"
CUTOFF_DATE=$(date -u -r "$CUTOFF_EPOCH" +'%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "date-failed")
echo "HANDOFF_LEGACY_CUTOFF_EPOCH=${CUTOFF_EPOCH} ($CUTOFF_DATE)"
echo "HANDOFF_MAX_SIZE_BYTES=${HANDOFF_MAX_SIZE_BYTES:-unset}"
echo "HANDOFF_AUTOCOMPACT_BYPASS_PCT=${HANDOFF_AUTOCOMPACT_BYPASS_PCT:-unset}"
echo "AC_SCHEMA_VERSION=${AC_SCHEMA_VERSION:-unset}"
echo "CLAUDE_CTX_GATE_DISABLED=${CLAUDE_CTX_GATE_DISABLED:-unset}"
echo

echo "=== Sentinels (~/.claude/progress/auto-compact-*.json) ==="
SENTINEL_COUNT=0
for s in "$HOME/.claude/progress/auto-compact-"*.json; do
  [ -f "$s" ] || continue
  SENTINEL_COUNT=$((SENTINEL_COUNT + 1))
  echo "--- $s"
  # Explicit if-elif for BSD/GNU stat compat (B2 pattern).
  if SMTIME=$(stat -f %Sm "$s" 2>/dev/null); then
    :
  elif SMTIME=$(stat -c %y "$s" 2>/dev/null); then
    :
  else
    SMTIME="stat-failed"
  fi
  echo "  mtime: $SMTIME"
  if SSIZE=$(stat -f %z "$s" 2>/dev/null); then
    :
  elif SSIZE=$(stat -c %s "$s" 2>/dev/null); then
    :
  else
    SSIZE="stat-failed"
  fi
  echo "  size: $SSIZE bytes"
  if [ -L "$s" ]; then
    echo "  WARN: symlink — would be rejected by readers"
  else
    jq . "$s" 2>/dev/null | sed 's/^/  /' || echo "  ERROR: jq parse failed"
  fi
done
[ "$SENTINEL_COUNT" = 0 ] && echo "(no sentinels — none armed)"
echo

echo "=== Claim files (consumed sentinels) ==="
CLAIM_COUNT=0
for c in "$HOME/.claude/progress/"auto-compact-*.json.claim.*; do
  [ -f "$c" ] && CLAIM_COUNT=$((CLAIM_COUNT + 1))
done
echo "count: $CLAIM_COUNT (GC at >60min via Stop hook)"
echo

echo "=== Current cwd handoff state ==="
# R5 H2: rewrite handoff detection to use lib/handoff-marker.sh (strict anchor grep)
# and lib/handoff-resolve.sh. Show SID-tagged files first (R4 D1/D3 primary path),
# then alias (legacy-only fallback). Stop-hook-refused detection added.
DIAG_DIR="$(cd "$(dirname "$0")" && pwd)"
_DIAG_MARKER_LOADED=""
. "$DIAG_DIR/lib/handoff-marker.sh" 2>/dev/null && _DIAG_MARKER_LOADED=yes

# Detect stop-hook-refused breadcrumbs for current session.
DIAG_SID="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
if [ -n "$DIAG_SID" ]; then
  _DIAG_REFUSED="$HOME/.claude/progress/breadcrumb-${DIAG_SID}.json"
  if [ -f "$_DIAG_REFUSED" ] && [ -O "$_DIAG_REFUSED" ]; then
    _DIAG_REFUSED_CMD=$(jq -r '.originating_command // empty' "$_DIAG_REFUSED" 2>/dev/null)
    if [ "$_DIAG_REFUSED_CMD" = "stop-hook-fail-closed" ]; then
      echo "STOP-HOOK-REFUSED: breadcrumb-${DIAG_SID}.json has originating_command=stop-hook-fail-closed"
      echo "  → The Stop hook refused to write a breadcrumb. Run /pre-compact again."
    fi
  fi
fi

# Show SID-tagged files (R4 D1 primary path). Glob includes __ttysN suffix variants.
DIAG_CWD="$(pwd)"
DIAG_REPO=$(git rev-parse --show-toplevel 2>/dev/null) || DIAG_REPO=""
SID_TAGGED_COUNT=0
for _scan_dir in "$DIAG_CWD" "$DIAG_REPO"; do
  [ -n "$_scan_dir" ] || continue
  for f in "$_scan_dir"/CLAUDE.local.*.md; do
    # Match SID-tagged (not bare alias)
    bn=$(basename "$f" 2>/dev/null)
    printf '%s' "$bn" | grep -qE '^CLAUDE\.local\.[A-Za-z0-9_-]+\.md$' || continue
    printf '%s' "$bn" | grep -qF 'CLAUDE.local.md' && continue  # skip bare alias
    [ -f "$f" ] || continue
    SID_TAGGED_COUNT=$((SID_TAGGED_COUNT + 1))
    echo "SID-tagged: $f"
    _FMTIME=""
    if _FMTIME=$(stat -f %Sm "$f" 2>/dev/null); then :
    elif _FMTIME=$(stat -c %y "$f" 2>/dev/null); then :; fi
    _FSIZE=""
    if _FSIZE=$(stat -f %z "$f" 2>/dev/null); then :
    elif _FSIZE=$(stat -c %s "$f" 2>/dev/null); then :; fi
    echo "  mtime: ${_FMTIME:-stat-failed} size: ${_FSIZE:-stat-failed}"
    # Marker detection using strict anchor (whole-file grep, not tail -c 512).
    if [ -n "$_DIAG_MARKER_LOADED" ] && command -v handoff_marker_check >/dev/null 2>&1; then
      if handoff_marker_check "$f" 2>/dev/null; then
        _NONCE=$(handoff_marker_nonce "$f" 2>/dev/null)
        _SID_M=$(handoff_marker_sid "$f" 2>/dev/null)
        _MCOUNT=$(handoff_marker_count "$f" 2>/dev/null)
        echo "  marker: PRESENT nonce=${_NONCE:-EXTRACT_FAILED} marker_sid=${_SID_M:-?} count=${_MCOUNT:-?}"
        [ "${_MCOUNT:-1}" -gt 1 ] 2>/dev/null && echo "  WARNING: multi-marker detected (count=$_MCOUNT) — possible tampering"
      else
        echo "  marker: ABSENT — handoff may be truncated"
      fi
    else
      # Fallback: strict anchor grep without lib.
      if grep -qE '^<!-- END-OF-HANDOFF schema=v1 ' "$f" 2>/dev/null; then
        _NONCE=$(grep -E '^<!-- END-OF-HANDOFF schema=v1 ' "$f" 2>/dev/null | head -1 | sed -nE 's/.*nonce=([a-f0-9-]+).*/\1/p')
        echo "  marker: PRESENT nonce=${_NONCE:-EXTRACT_FAILED}"
      elif grep -qF '<!-- END-OF-HANDOFF -->' "$f" 2>/dev/null; then
        echo "  marker: PRESENT (legacy form)"
      else
        echo "  marker: ABSENT — handoff may be truncated"
      fi
    fi
  done
done
[ "$SID_TAGGED_COUNT" -eq 0 ] && echo "(no SID-tagged CLAUDE.local.<sid>.md found in cwd/repo)"

# Alias — R7-INC-04 (Defense H12): alias is no longer legacy-only when it has a valid marker.
# Distinguish: marker-bound (first-class under Defense H12) vs legacy (no marker).
HANDOFF_PATH=""
if [ -f "$DIAG_CWD/CLAUDE.local.md" ]; then
  HANDOFF_PATH="$DIAG_CWD/CLAUDE.local.md"
elif [ -n "$DIAG_REPO" ] && [ -f "$DIAG_REPO/CLAUDE.local.md" ]; then
  HANDOFF_PATH="$DIAG_REPO/CLAUDE.local.md"
fi
if [ -n "$HANDOFF_PATH" ]; then
  _HMTIME=""
  if _HMTIME=$(stat -f %Sm "$HANDOFF_PATH" 2>/dev/null); then :
  elif _HMTIME=$(stat -c %y "$HANDOFF_PATH" 2>/dev/null); then :; fi
  _HSIZE=""
  if _HSIZE=$(stat -f %z "$HANDOFF_PATH" 2>/dev/null); then :
  elif _HSIZE=$(stat -c %s "$HANDOFF_PATH" 2>/dev/null); then :; fi
  _HLINES=$(wc -l < "$HANDOFF_PATH" 2>/dev/null | tr -d ' ')
  # Use strict anchor for alias too.
  if grep -qE '^<!-- END-OF-HANDOFF schema=v1 ' "$HANDOFF_PATH" 2>/dev/null; then
    _NONCE=$(grep -E '^<!-- END-OF-HANDOFF schema=v1 ' "$HANDOFF_PATH" 2>/dev/null | head -1 | sed -nE 's/.*nonce=([a-f0-9-]+).*/\1/p')
    _MSID=$(grep -E '^<!-- END-OF-HANDOFF schema=v1 ' "$HANDOFF_PATH" 2>/dev/null | head -1 | sed -nE 's/.*sid=([A-Za-z0-9_-]+).*/\1/p')
    echo "Alias (marker-bound, Defense H12): $HANDOFF_PATH"
    echo "  mtime: ${_HMTIME:-stat-failed} size: ${_HSIZE:-stat-failed} bytes / ${_HLINES:-?} lines"
    echo "  marker: PRESENT sid=${_MSID:-EXTRACT_FAILED} nonce=${_NONCE:-EXTRACT_FAILED} (alias-with-marker-binding; readable by resolver when sid matches session SID8)"
  elif grep -qF '<!-- END-OF-HANDOFF -->' "$HANDOFF_PATH" 2>/dev/null; then
    echo "Alias (legacy, no sid marker): $HANDOFF_PATH"
    echo "  mtime: ${_HMTIME:-stat-failed} size: ${_HSIZE:-stat-failed} bytes / ${_HLINES:-?} lines"
    echo "  marker: PRESENT (legacy form — no sid= attribute; not accepted by resolver when SID is known)"
  else
    echo "Alias (legacy, no marker): $HANDOFF_PATH"
    echo "  mtime: ${_HMTIME:-stat-failed} size: ${_HSIZE:-stat-failed} bytes / ${_HLINES:-?} lines"
    echo "  marker: ABSENT — handoff may be truncated; not accepted by resolver when SID is known"
  fi
else
  echo "(no CLAUDE.local.md alias in cwd or repo root)"
fi
echo

echo "=== Breadcrumbs (~/.claude/progress/breadcrumb-*.json) ==="
BREADCRUMB_COUNT=0
BREADCRUMB_LATEST_MTIME="(none)"
BREADCRUMB_LATEST_HOST="(none)"
for b in "$HOME/.claude/progress/breadcrumb-"*.json; do
  [ -f "$b" ] || continue
  BREADCRUMB_COUNT=$((BREADCRUMB_COUNT + 1))
  if BMTIME=$(stat -f %Sm "$b" 2>/dev/null); then
    :
  elif BMTIME=$(stat -c %y "$b" 2>/dev/null); then
    :
  else
    BMTIME="stat-failed"
  fi
  BREADCRUMB_LATEST_MTIME="$BMTIME"
  BREADCRUMB_LATEST_HOST=$(jq -r '.hostname // "no-hostname-field"' "$b" 2>/dev/null)
done
echo "count: $BREADCRUMB_COUNT"
echo "latest mtime: $BREADCRUMB_LATEST_MTIME"
echo "latest hostname: $BREADCRUMB_LATEST_HOST"
# Verify step2.sh exists at new D9 path (post-compact-resume-step2.sh, no longer in lib/)
STEP2_PATH="$ROOT/post-compact-resume-step2.sh"
if [ -x "$STEP2_PATH" ]; then
  echo "step2.sh: PRESENT + executable at $STEP2_PATH"
elif [ -f "$STEP2_PATH" ]; then
  echo "step2.sh: PRESENT but NOT executable at $STEP2_PATH (run: chmod +x $STEP2_PATH)"
else
  echo "step2.sh: MISSING at $STEP2_PATH"
fi
echo "--- Recent breadcrumb log entries (grep from auto-compact.log):"
if [ -f "$HOME/.claude/logs/auto-compact.log" ]; then
  grep -i 'breadcrumb' "$HOME/.claude/logs/auto-compact.log" 2>/dev/null | tail -10 | sed 's/^/  /' \
    || echo "  (no breadcrumb log entries)"
else
  echo "  (auto-compact.log not found)"
fi
echo

echo "=== Recent log entries (last 20) ==="
for log in "$HOME/.claude/logs/auto-compact.log" "$HOME/.claude/logs/ctx-gate.log"; do
  if [ -f "$log" ]; then
    echo "--- $log (last 20):"
    tail -20 "$log" 2>/dev/null | sed 's/^/  /'
  fi
done
echo

echo "=== Done. ==="
