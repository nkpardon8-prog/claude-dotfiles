#!/usr/bin/env bash
# mission-write.sh — the allowlisted CLI dispatcher over lib/mission-bridge.sh.
#
# THE ONLY MUTATOR of the on-disk MISSION.<sid>.* artifacts. Nothing else writes them.
# /pre-compact (and /mission) shell out to THIS script; the actual format logic lives in
# lib/mission-bridge.sh, which this file sources and dispatches to.
#
# ── BYTE-LOCKED INVOCATION (do NOT change the path) ───────────────────────────────────────
# The canonical invocation is EXACTLY, byte-for-byte:
#     bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh <verb> <sid> <root> [args...]
# An allow rule in ~/.claude/settings.json (`Bash(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh:*)`)
# matches this prefix by BYTES. Absolute path, NO `cd`, NO env-var prefix, NO `~`/`$HOME`.
# Changing the path / adding a prefix BREAKS the allowlist byte-match → permission prompts →
# aborts the autonomous /pre-compact workflow. If you move this file you MUST re-issue the
# allow rule via /update-config and update every caller in lockstep.
#
# ── #1 PRIORITY CONSTRAINT: NEVER ABORT THE CALLER ────────────────────────────────────────
# This script ALWAYS `exit 0`, no matter what the lib returns. /pre-compact runs autonomously
# and must NEVER be interrupted. A lib failure is REPORTED on the single stdout status line
# (and the lib's own stderr stays fail-LOUD) — it is NEVER propagated as a non-zero exit.
#
# ── USAGE ─────────────────────────────────────────────────────────────────────────────────
#   mission-write.sh <verb> <sid> <root> [args...]
#   verb ∈ create | log | note | challenge | pending | resolve | rebaseline | render-banner
#          | timing-resume | timing-contact | timing-close
#     create        <sid> <root> [plan_source]
#     log           <sid> <root> <entry> [idtag]
#     note          <sid> <root> <entry> [idtag]
#     challenge     <sid> <root> <entry> [idtag]
#     pending       <sid> <root> <entry> [idtag]
#     resolve       <sid> <root> <pd_id> [resolution]
#     rebaseline    <sid> <root> <new_plan>
#     render-banner <sid> <root>
#     timing-resume <sid> <root>                 (advisory run-timing: re-stamp WORK-START on re-engagement)
#     timing-contact <sid> <root> <reason>       (advisory: write a CONTACT timing anchor)
#     timing-close  <sid> <root> <status>        (advisory: final compute + the one ledger write)
#
# Exactly ONE status line is printed to stdout:
#   mission-write: <verb> ok
#   mission-write: <verb> FAILED rc=N (<short reason>)
#   mission-write: usage ... (unknown verb / missing args)
#
# macOS bash 3.2.57 compatible.

# --- source the lib (relative-then-absolute, mirrors the lib's own handoff-locate.sh source) ---
if ! command -v mission_create >/dev/null 2>&1; then
  if [ -n "${BASH_SOURCE:-}" ] && [ -f "$(dirname "${BASH_SOURCE[0]}")/lib/mission-bridge.sh" ]; then
    . "$(dirname "${BASH_SOURCE[0]}")/lib/mission-bridge.sh"
  elif [ -f "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh" ]; then
    . "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"
  fi
fi

# Hard guard: if the lib could not be sourced, report and STILL exit 0 (never abort the caller).
if ! command -v mission_create >/dev/null 2>&1; then
  echo "mission-write: ${1:-?} FAILED rc=127 (lib mission-bridge.sh not found/sourced)"
  exit 0
fi

verb="${1:-}"; sid="${2:-}"; root="${3:-}"

# I6: light root-escape guard (defense-in-depth; root is trusted-caller-supplied). Refuse an
# empty root or one containing `..` traversal. NEVER abort the caller — print a status line and
# exit 0. The normal absolute-path case (no `..`) is unaffected. Only enforced for verbs that
# actually take a <root> arg (i.e. not the help/usage paths, which have no root).
case "$verb" in
  create|log|note|challenge|pending|resolve|rebaseline|render-banner|timing-resume|timing-contact|timing-close)
    case "$root" in
      ""|*..*)
        # I2: emit the parseable failure shape (FAILED rc=N), not a bare REFUSED line — the
        # playbook parser reads an empty rc as success and would silently drop the write.
        echo "mission-write: ${verb} FAILED rc=1 (REFUSED: root empty or contains '..': '${root}')"
        exit 0
        ;;
    esac
    ;;
esac

# Short helper: emit the single status line for a captured rc, then the caller exits 0.
_mw_status() {
  _s_verb="$1"; _s_rc="$2"; _s_reason="$3"
  if [ "$_s_rc" -eq 0 ]; then
    echo "mission-write: ${_s_verb} ok"
  else
    echo "mission-write: ${_s_verb} FAILED rc=${_s_rc} (${_s_reason})"
  fi
}

case "$verb" in
  create)
    if [ -z "$sid" ] || [ -z "$root" ]; then
      echo "mission-write: usage: create <sid> <root> [plan_source]"
      exit 0
    fi
    mission_create "$sid" "$root" "${4:-}"
    rc=$?
    _mw_status create "$rc" "see stderr"
    ;;

  log)
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ]; then
      echo "mission-write: usage: log <sid> <root> <entry> [idtag]"
      exit 0
    fi
    mission_log_append "$sid" "$root" "$4" "${5:-}"
    rc=$?
    _mw_status log "$rc" "see stderr"
    ;;

  note)
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ]; then
      echo "mission-write: usage: note <sid> <root> <entry> [idtag]"
      exit 0
    fi
    mission_mutate "$sid" "$root" note "$4" "${5:-}"
    rc=$?
    _mw_status note "$rc" "see stderr"
    ;;

  challenge)
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ]; then
      echo "mission-write: usage: challenge <sid> <root> <entry> [idtag]"
      exit 0
    fi
    mission_mutate "$sid" "$root" challenge "$4" "${5:-}"
    rc=$?
    _mw_status challenge "$rc" "see stderr"
    ;;

  pending)
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ]; then
      echo "mission-write: usage: pending <sid> <root> <entry> [idtag]"
      exit 0
    fi
    mission_mutate "$sid" "$root" pending "$4" "${5:-}"
    rc=$?
    _mw_status pending "$rc" "see stderr"
    ;;

  resolve)
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ]; then
      echo "mission-write: usage: resolve <sid> <root> <pd_id> [resolution]"
      exit 0
    fi
    mission_resolve_pending "$sid" "$root" "$4" "${5:-resolved}"
    rc=$?
    _mw_status resolve "$rc" "see stderr"
    ;;

  rebaseline)
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ]; then
      echo "mission-write: usage: rebaseline <sid> <root> <new_plan>"
      exit 0
    fi
    mission_rebaseline "$sid" "$root" "$4"
    rc=$?
    _mw_status rebaseline "$rc" "see stderr"
    ;;

  render-banner)
    if [ -z "$sid" ] || [ -z "$root" ]; then
      echo "mission-write: usage: render-banner <sid> <root>"
      exit 0
    fi
    mission_render_banner "$sid" "$root"
    rc=$?
    _mw_status render-banner "$rc" "see stderr"
    ;;

  timing-resume)
    if [ -z "$sid" ] || [ -z "$root" ]; then
      echo "mission-write: usage: timing-resume <sid> <root>"
      exit 0
    fi
    # advisory — these lib fns always return 0 and capture compute stdout internally,
    # so nothing leaks onto this verb's single status line.
    mission_timing_resume "$sid" "$root"
    rc=$?
    _mw_status timing-resume "$rc" "see stderr"
    ;;

  timing-contact)
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ]; then
      echo "mission-write: usage: timing-contact <sid> <root> <reason>"
      exit 0
    fi
    mission_timing_contact "$sid" "$root" "$4"
    rc=$?
    _mw_status timing-contact "$rc" "see stderr"
    ;;

  timing-close)
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ]; then
      echo "mission-write: usage: timing-close <sid> <root> <status>"
      exit 0
    fi
    mission_timing_close "$sid" "$root" "$4"
    rc=$?
    _mw_status timing-close "$rc" "see stderr"
    ;;

  ""|help|-h|--help)
    echo "mission-write: usage: mission-write.sh <create|log|note|challenge|pending|resolve|rebaseline|render-banner|timing-resume|timing-contact|timing-close> <sid> <root> [args...]"
    ;;

  *)
    echo "mission-write: usage: unknown verb '$verb' (want create|log|note|challenge|pending|resolve|rebaseline|render-banner|timing-resume|timing-contact|timing-close)"
    ;;
esac

# #1 PRIORITY: never abort the caller — always succeed regardless of lib rc.
exit 0
