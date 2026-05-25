#!/usr/bin/env bash
# post-compact-resume-step2.sh — R8 identity-via-arg reader.
#
# Usage: bash post-compact-resume-step2.sh <session_id>
#   $1 = the session_id threaded verbatim from the Stop hook via /post-compact-resume arg.
#
# Emits a single STATE=<JSON> line on stdout. No breadcrumb read, no HMAC, no slug-fallback.
# Identity comes only from the argument — fail-safe on empty arg (never guess).
#
# Exit 0 always (STATE= is the signal; non-zero would surface as Bash tool error).
#
# D9: script lives at hooks/post-compact-resume-step2.sh; libs live at hooks/lib/.
# macOS bash 3.2.57 compatible.

set -uo pipefail

_STEP2_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || _STEP2_DIR=""

if [ -n "$_STEP2_DIR" ]; then
  . "$_STEP2_DIR/lib/ctx-gate-config.sh"  2>/dev/null || . "$HOME/.claude-dotfiles/scripts/hooks/lib/ctx-gate-config.sh"  2>/dev/null
  . "$_STEP2_DIR/lib/handoff-config.sh"   2>/dev/null || . "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-config.sh"   2>/dev/null
  . "$_STEP2_DIR/lib/auto-compact-sentinel.sh" 2>/dev/null || . "$HOME/.claude-dotfiles/scripts/hooks/lib/auto-compact-sentinel.sh" 2>/dev/null
  . "$_STEP2_DIR/lib/handoff-marker.sh"   2>/dev/null || . "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-marker.sh"   2>/dev/null
  . "$_STEP2_DIR/lib/handoff-resolve.sh"  2>/dev/null || . "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-resolve.sh"  2>/dev/null
else
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/ctx-gate-config.sh"  2>/dev/null
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-config.sh"   2>/dev/null
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/auto-compact-sentinel.sh" 2>/dev/null
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-marker.sh"   2>/dev/null
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/handoff-resolve.sh"  2>/dev/null
fi

# ---------------------------------------------------------------------------
# V2-12: Arg validation — fail-safe on empty or invalid arg.
# NEVER guess the session_id; NEVER read a breadcrumb; NEVER slug-fallback.
# ---------------------------------------------------------------------------
ARG_SID="${1:-}"
if [ -z "$ARG_SID" ]; then
  handoff_log "step2_terminal state=no-session-arg reason=arg-empty"
  printf 'STATE={"state":"no-session-arg","reason":"no session_id argument passed to /post-compact-resume — delivery may have degraded. The SessionStart banner shows the exact command to run. Ask the user to paste it or re-run /pre-compact."}\n'
  exit 0
fi
if ! printf '%s' "$ARG_SID" | grep -qE '^[A-Za-z0-9_-]+$'; then
  handoff_log "step2_terminal state=invalid-session-arg reason=bad-charset arg=$(printf '%s' "$ARG_SID" | head -c 64)"
  printf 'STATE={"state":"invalid-session-arg","reason":"session_id argument contains characters outside [A-Za-z0-9_-]"}\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# R9 HIGH-1: arg-vs-self check — the wrong-load structural close.
#
# The downstream marker-content-check (handoff-resolve.sh F2) validates that the
# resolved file's marker sid == ARG_SID — i.e. file-vs-arg. It can NEVER detect
# that the *consumer* (this session) is not the session ARG_SID names, because
# the file and the arg agree. So if `/post-compact-resume <A-uuid>` is mis-delivered
# (tab-targeting misfire) or mis-pasted (a user pasting session A's banner command
# into session B's tab) into a DIFFERENT live session B that shares a repo-root where
# A's handoff `CLAUDE.local.<A-uuid>.md` physically lives, B would otherwise load A's
# handoff — the exact cross-session wrong-load this subsystem exists to prevent.
#
# Defense: compare ARG_SID against THIS resuming session's own id.
#   SELF_SID source: CLAUDE_CODE_SESSION_ID — empirically exposed to the Bash tool
#   subprocess and STABLE across /compact (the legitimate auto-resume runs in the
#   SAME session that armed the chain, so SELF_SID == ARG_SID and this passes).
#   Falls back to CLAUDE_SESSION_ID (unset on current Claude Code, kept for fwd-compat).
#
# Fail-safe semantics (R9-R2 — FAIL-CLOSED, not skip):
#   - SELF_SID known AND == ARG_SID  -> proceed (the legitimate same-session resume).
#   - SELF_SID known AND != ARG_SID  -> STATE=arg-not-my-session (REFUSE; mis-delivery/mis-paste).
#   - SELF_SID UNAVAILABLE           -> STATE=self-unverifiable (REFUSE). Rationale: with no
#     self id the consumer layer is gone and the content layer (F2 file-vs-arg) CANNOT distinguish
#     the consumer in a shared repo-root, so a marked CLAUDE.local.<arg>.md belonging to another
#     session would load. R9-Round2 adversary review proved this cell is a real wrong-load. We
#     therefore fail-closed rather than degrade to content-only. On supported Claude Code
#     CLAUDE_CODE_SESSION_ID is ALWAYS exposed to the Bash-tool subprocess (verified) and stable
#     across /compact, so the legitimate auto-resume (self==arg) NEVER hits this branch — the cost
#     falls only on degraded/older clients, where a recoverable refuse is the correct medical-grade
#     trade ("never wrong-load; at worst refuse and ask").
# ---------------------------------------------------------------------------
SELF_SID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
SELF_SID=$(printf '%s' "$SELF_SID" | tr -cd 'A-Za-z0-9_-' | head -c 128)
if [ -z "$SELF_SID" ]; then
  handoff_log "step2_terminal state=self-unverifiable arg=$ARG_SID reason=no-self-session-id"
  _json=$(jq -c -n --arg arg "$ARG_SID" \
    '{"state":"self-unverifiable","arg_sid":$arg,
      "reason":"cannot read this session own id (CLAUDE_CODE_SESSION_ID unset) — cannot prove the handoff belongs to THIS session. Refusing to auto-load to avoid cross-session contamination. To resume manually, set CLAUDE_CODE_SESSION_ID to this session id (shown in the SessionStart banner) and re-run, or run /pre-compact again."}' 2>/dev/null)
  if [ -n "$_json" ]; then printf 'STATE=%s\n' "$_json"
  else printf 'STATE={"state":"self-unverifiable"}\n'; fi
  exit 0
fi
if [ "$SELF_SID" != "$ARG_SID" ]; then
  handoff_log "step2_terminal state=arg-not-my-session self=$SELF_SID arg=$ARG_SID"
  _json=$(jq -c -n --arg self "$SELF_SID" --arg arg "$ARG_SID" \
    '{"state":"arg-not-my-session","self_sid":$self,"arg_sid":$arg,
      "reason":"the session_id passed to /post-compact-resume does not match this session (possible mis-delivery or mis-paste). Refusing to load another session handoff."}' 2>/dev/null)
  if [ -n "$_json" ]; then printf 'STATE=%s\n' "$_json"
  else printf 'STATE={"state":"arg-not-my-session"}\n'; fi
  exit 0
fi
# R9-R2 observability (HIGH-2): record that the consumer-layer self-check ran AND passed,
# so an operator reading the log can distinguish a double-checked STATE=ok from a degraded one.
handoff_log "step2 r9_self_check ok self=$SELF_SID"
fi

CWD=$(cd -P "$(pwd)" 2>/dev/null && pwd -P || pwd)

# ---------------------------------------------------------------------------
# V2-13: Resolve HANDOFF_PATH via handoff_resolve_path (probes cwd + repo-root).
# The resolver verifies F2 marker-content-check (marker sid must == ARG_SID).
# No direct path construction here — the resolver handles cwd + repo-root probes.
# ---------------------------------------------------------------------------
HANDOFF_PATH=""
RESOLVE_RC=0
handoff_resolve_path "$CWD" "$ARG_SID" || RESOLVE_RC=$?

if [ "$RESOLVE_RC" -eq 3 ]; then
  handoff_log "step2_terminal state=sid-known-hardlinked sid=$ARG_SID"
  _json=$(jq -c -n --arg sid "$ARG_SID" \
    '{"state":"sid-known-hardlinked","sid":$sid,
      "next_steps":"The SID-tagged handoff file has a hardlink count > 1 (potential attack). To fix: cp CLAUDE.local.<sid>.md CLAUDE.local.<sid>.md.new && mv CLAUDE.local.<sid>.md.new CLAUDE.local.<sid>.md"}' 2>/dev/null)
  if [ -n "$_json" ]; then printf 'STATE=%s\n' "$_json"
  else printf 'STATE={"state":"sid-known-hardlinked","sid":"%s"}\n' "$ARG_SID"; fi
  exit 0
fi

if [ "$RESOLVE_RC" -eq 2 ]; then
  handoff_log "step2_terminal state=no-handoff sid=$ARG_SID reason=sid-tagged-file-missing"
  _json=$(jq -c -n --arg sid "$ARG_SID" \
    '{"state":"no-handoff","sid":$sid,"reason":"session_id was provided but no matching CLAUDE.local.<sid>.md found in cwd or repo-root"}' 2>/dev/null)
  if [ -n "$_json" ]; then printf 'STATE=%s\n' "$_json"
  else printf 'STATE={"state":"no-handoff"}\n'; fi
  exit 0
fi

if [ -z "$HANDOFF_PATH" ]; then
  handoff_log "step2_terminal state=no-handoff sid=$ARG_SID"
  _json=$(jq -c -n '{"state":"no-handoff"}' 2>/dev/null)
  if [ -n "$_json" ]; then printf 'STATE=%s\n' "$_json"
  else printf 'STATE={"state":"no-handoff"}\n'; fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Size cap
# ---------------------------------------------------------------------------
HANDOFF_SIZE=0
if HANDOFF_SIZE=$(stat -f %z "$HANDOFF_PATH" 2>/dev/null | tr -d '[:space:]'); then :
elif HANDOFF_SIZE=$(stat -c %s "$HANDOFF_PATH" 2>/dev/null | tr -d '[:space:]'); then :
else HANDOFF_SIZE=0; fi
[ -z "$HANDOFF_SIZE" ] && HANDOFF_SIZE=0
if [ "$HANDOFF_SIZE" -gt "${HANDOFF_MAX_SIZE_BYTES:-5242880}" ]; then
  handoff_log "step2_terminal state=oversize sid=$ARG_SID size=${HANDOFF_SIZE}"
  _json=$(jq -c -n \
    --argjson size "$HANDOFF_SIZE" \
    --argjson max "${HANDOFF_MAX_SIZE_BYTES:-5242880}" \
    --arg path "$HANDOFF_PATH" \
    '{"state":"oversize","size":$size,"max":$max,"path":$path}' 2>/dev/null)
  if [ -n "$_json" ]; then printf 'STATE=%s\n' "$_json"
  else printf 'STATE={"state":"oversize","size":%s,"max":%s}\n' "$HANDOFF_SIZE" "${HANDOFF_MAX_SIZE_BYTES:-5242880}"; fi
  exit 0
fi

# ---------------------------------------------------------------------------
# TOCTOU snapshot
# ---------------------------------------------------------------------------
_HANDOFF_SNAP=""
_HANDOFF_ORIG_STAT=""
_snap_tmp=$(mktemp -t handoff_snap.XXXXXX 2>/dev/null) || _snap_tmp=""
if [ -n "$_snap_tmp" ]; then
  if cp "$HANDOFF_PATH" "$_snap_tmp" 2>/dev/null; then
    _HANDOFF_SNAP="$_snap_tmp"
    if _s=$(stat -f '%i:%d:%z' "$HANDOFF_PATH" 2>/dev/null); then _HANDOFF_ORIG_STAT="$_s"
    elif _s=$(stat -c '%i:%d:%s' "$HANDOFF_PATH" 2>/dev/null); then _HANDOFF_ORIG_STAT="$_s"; fi
    trap 'rm -f "${_HANDOFF_SNAP:-}" 2>/dev/null || true' EXIT
  else
    handoff_log "step2_terminal state=snapshot-failed path=$HANDOFF_PATH sid=$ARG_SID"
    _json=$(jq -c -n --arg sid "$ARG_SID" --arg path "$HANDOFF_PATH" \
      '{"state":"snapshot-failed","sid":$sid,"path":$path,"reason":"cp failed — cannot create TOCTOU-safe snapshot"}' 2>/dev/null)
    if [ -n "$_json" ]; then printf 'STATE=%s\n' "$_json"
    else printf 'STATE={"state":"snapshot-failed"}\n'; fi
    rm -f "$_snap_tmp" 2>/dev/null || true
    exit 0
  fi
else
  handoff_log "step2_terminal state=snapshot-failed path=$HANDOFF_PATH sid=$ARG_SID reason=mktemp-failed"
  _json=$(jq -c -n --arg sid "$ARG_SID" --arg path "$HANDOFF_PATH" \
    '{"state":"snapshot-failed","sid":$sid,"path":$path,"reason":"mktemp failed"}' 2>/dev/null)
  if [ -n "$_json" ]; then printf 'STATE=%s\n' "$_json"
  else printf 'STATE={"state":"snapshot-failed"}\n'; fi
  exit 0
fi
_HANDOFF_READ="${_HANDOFF_SNAP:-$HANDOFF_PATH}"

# ---------------------------------------------------------------------------
# Staleness + legacy
# ---------------------------------------------------------------------------
HANDOFF_MTIME=$(stat -f %m "$HANDOFF_PATH" 2>/dev/null | tr -d '[:space:]' || stat -c %Y "$HANDOFF_PATH" 2>/dev/null | tr -d '[:space:]' || printf 0)
[ -z "$HANDOFF_MTIME" ] && HANDOFF_MTIME=0
NOW=$(date +%s)
HANDOFF_AGE=$((NOW - HANDOFF_MTIME))
if [ "$HANDOFF_MTIME" -eq 0 ]; then STAT_OK=false; HANDOFF_AGE=0; else STAT_OK=true; fi
CUTOFF="${HANDOFF_LEGACY_CUTOFF_EPOCH:-1779321600}"
if [ "$STAT_OK" = "true" ] && [ "$HANDOFF_MTIME" -lt "$CUTOFF" ]; then LEGACY=true; else LEGACY=false; fi
STALE_SECS="${HANDOFF_STALE_SECS:-86400}"
if [ "$STAT_OK" = "true" ] && [ "$HANDOFF_AGE" -gt "$STALE_SECS" ]; then STALE=true; else STALE=false; fi
HANDOFF_AGE_HOURS=$((HANDOFF_AGE / 3600))
[ -z "$HANDOFF_AGE_HOURS" ] && HANDOFF_AGE_HOURS=0

# ---------------------------------------------------------------------------
# Marker check (from snapshot)
# ---------------------------------------------------------------------------
MARKER=absent
if command -v handoff_marker_check >/dev/null 2>&1; then
  if handoff_marker_check "$_HANDOFF_READ"; then MARKER=present; fi
else
  if grep -qE '^<!-- END-OF-HANDOFF schema=v1 ' "$_HANDOFF_READ" 2>/dev/null \
     || grep -qF '<!-- END-OF-HANDOFF -->' "$_HANDOFF_READ" 2>/dev/null; then
    MARKER=present
  fi
fi

# ---------------------------------------------------------------------------
# Multi-marker fail-closed (from snapshot)
# ---------------------------------------------------------------------------
if command -v handoff_marker_count >/dev/null 2>&1; then
  _mcount=$(handoff_marker_count "$_HANDOFF_READ")
  if [ -n "$_mcount" ] && [ "$_mcount" -gt 1 ] 2>/dev/null; then
    handoff_log "step2_terminal state=multi-marker-detected file=$HANDOFF_PATH count=$_mcount sid=$ARG_SID"
    _json=$(jq -c -n --arg sid "$ARG_SID" --arg count "$_mcount" --arg path "$HANDOFF_PATH" \
      '{"state":"multi-marker-detected","sid":$sid,"count":$count,"path":$path}' 2>/dev/null)
    if [ -n "$_json" ]; then printf 'STATE=%s\n' "$_json"
    else printf 'STATE={"state":"multi-marker-detected","count":"%s"}\n' "$_mcount"; fi
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# V2-14: Name-validation regex already matches full-UUID filenames.
# '^CLAUDE\.local\.([A-Za-z0-9_-]+\.)?md$' matches CLAUDE.local.<uuid>.md — no change needed.
# ---------------------------------------------------------------------------
_handoff_bn=$(basename "$HANDOFF_PATH")
if ! printf '%s' "$_handoff_bn" | grep -qE '^CLAUDE\.local\.([A-Za-z0-9_-]+\.)?md$'; then
  handoff_log "step2_terminal state=invalid-handoff-name path=$HANDOFF_PATH"
  _json=$(jq -c -n --arg path "$HANDOFF_PATH" \
    '{"state":"invalid-handoff-name","path":$path}' 2>/dev/null)
  if [ -n "$_json" ]; then printf 'STATE=%s\n' "$_json"
  else printf 'STATE={"state":"invalid-handoff-name"}\n'; fi
  exit 0
fi

# ---------------------------------------------------------------------------
# TOCTOU re-verify
# ---------------------------------------------------------------------------
if [ -n "$_HANDOFF_ORIG_STAT" ]; then
  _current_stat=""
  if _current_stat=$(stat -f '%i:%d:%z' "$HANDOFF_PATH" 2>/dev/null); then :
  elif _current_stat=$(stat -c '%i:%d:%s' "$HANDOFF_PATH" 2>/dev/null); then :
  fi
  if [ -n "$_current_stat" ] && [ "$_current_stat" != "$_HANDOFF_ORIG_STAT" ]; then
    handoff_log "handoff_mutated_mid_read path=$HANDOFF_PATH orig=$_HANDOFF_ORIG_STAT current=$_current_stat"
    handoff_log "step2_terminal state=handoff-mutated-mid-read sid=$ARG_SID"
    _json=$(jq -c -n --arg path "$HANDOFF_PATH" \
      '{"state":"handoff-mutated-mid-read","path":$path}' 2>/dev/null)
    if [ -n "$_json" ]; then printf 'STATE=%s\n' "$_json"
    else printf 'STATE={"state":"handoff-mutated-mid-read"}\n'; fi
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Emit STATE=ok (V2-9: drop nonce_ok field; keep marker/legacy/stale/path/sid)
# ---------------------------------------------------------------------------
handoff_log "step2_terminal state=ok sid=$ARG_SID marker=${MARKER}"
_json=$(jq -c -n \
  --arg state "ok" \
  --arg marker "$MARKER" \
  --argjson legacy "$LEGACY" \
  --argjson stale "$STALE" \
  --argjson age_hours "$HANDOFF_AGE_HOURS" \
  --arg sid "$ARG_SID" \
  --arg path "$HANDOFF_PATH" \
  '{"state":$state,"marker":$marker,"legacy":$legacy,"stale":$stale,
    "age_hours":$age_hours,"sid":$sid,"path":$path}' 2>/dev/null)
if [ -n "$_json" ]; then
  printf 'STATE=%s\n' "$_json"
else
  printf 'STATE={"state":"error","reason":"jq-failed"}\n'
fi
