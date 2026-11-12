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
#   verb ∈ create | log | note | challenge | pending | pending-stop | resolve | rebaseline
#          | render-banner | timing-resume | timing-contact | timing-close | archive-close | await
#     create        <sid> <root> [plan_source]
#     log           <sid> <root> <entry> [idtag]
#     note          <sid> <root> <entry> [idtag]
#     challenge     <sid> <root> <entry> [idtag]
#     pending       <sid> <root> <slug> <question...>   (NON-BLOCKING; mints+echoes a monotonic pd:<seq>-<slug> id)
#     pending-stop  <sid> <root> <slug> <part> <round> <attempt> <phase> <question...>
#                   (BLOCKING sibling of `pending`: the ONE barrier-opener — mints pd:<seq>-<slug> AND
#                    opens the durable human STOP AWAIT got=0; echoes the minted id)
#     resolve       <sid> <root> <pd_id> [resolution]
#     rebaseline    <sid> <root> <new_plan>
#     render-banner <sid> <root>
#     timing-resume <sid> <root>                 (advisory run-timing: re-stamp WORK-START on re-engagement)
#     timing-contact <sid> <root> <reason>       (advisory: write a CONTACT timing anchor)
#     timing-close  <sid> <root> <status>        (advisory: final compute + the one ledger write)
#     archive-close <sid> <root>                 (advisory: file a CLEARED mission into .mission-archive/<sid>/)
#     await         <sid> <root> <fields>        (open/update the durable AWAIT marker; <fields> = the
#                                                 space-separated part/phase/round/kind/op/attempt/need/got
#                                                 [/started_at] pairs — reassembled in canonical order)
#     bank-review   <sid> <root> <N> <K> <plan|delta|close|join> [report] [impl-reviewer-output]
#                   (proto=2: the ONLY writer of review evidence, review round lines, VOIDs and dry= raises;
#                    status `bank-review ok scope= dry= blocking= new= repeat= result= [sweep=required
#                    types=..] [redesign=<area>]` | `bank-review VOID reason= void-count=N` | FAILED rc=N)
#     budget-state  <sid> <root>                 (read-only, bare: ok | paused live=<min> |
#                                                 over part=N minutes=M replan=<0|1>)
#     mission-proto <sid> <root>                 (read-only, bare: legacy | proto2 | new; per generation)
#     part-state    <sid> <root>                 (read-only, bare: none | part=N proto=<1|2> dry= closed=<0|1>
#                                                 freeze= head= tree=<clean|dirty|-> drift=<0|1>)
#     known-reds    <sid> <root> key|diff|record <suite-report>  (key: bare FULL-SUITE env= hash;
#                                                 diff: bare new-red count, -1 = invalid run)
#
#   FOUR DOCUMENTED ARGV EXCEPTIONS (read-only verbs — different argv shape; bare-token stdout; NO
#   `mission-write: <verb> …` status line; handled BEFORE the root-guard):
#     parse-codex-header <file>                  (stdout: bare `N/4`, empty on absent/malformed header)
#     void-count <sid> <root> <part> <round>     (stdout: bare integer >=0, or `-1` refused-read sentinel)
#     await-state <sid> <root>                   (stdout: bare `none` | `corrupt` | `await kind=… op=…
#                                                 part=… round=… attempt=… phase=… need=… got=… ready=<0|1>
#                                                 started_at=…` — the newest outstanding AWAIT barrier)
#     cursor-hash <sid> <root>                   (stdout: bare 64-hex sha256 of the gen-scoped state,
#                                                 empty, or `corrupt` on a refused gen-boundary read)
#
# Exactly ONE status line is printed to stdout (EXCEPT the four read-only verbs above, whose stdout is
# a bare machine token):
#   mission-write: <verb> ok
#   mission-write: <verb> COLLISION (…)                 (log/note/challenge/pending — idtag+diff content)
#   mission-write: <verb> REROUTED-TO-NOTES (…)         (log — oversize free text)
#   mission-write: <verb> FAILED rc=N (<short reason>)  (rc=4 on PART-DONE/live-verify BLOCKS advance)
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

# R8r3-R1 - CLEAR the internal human-opener flag at the CLI entry. `_MISSION_INTERNAL_HUMAN_OPEN` is the
# same-process signal the SANCTIONED opener (mission_pending_stop_mint) sets as a call-scoped FUNCTION
# prefix on its ONE mission_await_append invocation. If a caller EXPORTS it into the environment, the
# child `bash mission-write.sh` inherits it, so a public `await <fields> kind=human got=0` would open a
# LOCK-FREE human STOP barrier through the public path - defeating FIX A (the clear/rebaseline TOCTOU race
# it closes) and R8r2-A. Unsetting it HERE (before any dispatch) is safe: pending_stop_mint re-sets it as
# a `VAR=val cmd` function prefix scoped to its single call INSIDE this same process, AFTER this unset, so
# the sanctioned mint still opens; only an INHERITED env value (the bypass) is dropped.
unset _MISSION_INTERNAL_HUMAN_OPEN

verb="${1:-}"; sid="${2:-}"; root="${3:-}"
_MW_SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)

# ── DOCUMENTED PRE-ROOT-GUARD ARGV EXCEPTIONS (read-only verbs) ─────────────────────────────
# FOUR verbs break the `<verb> <sid> <root>` dispatcher shape because they are READ-ONLY and their
# stdout is a BARE machine token (no `mission-write: <verb> …` status line). They run BEFORE the
# root-guard (their argv/output shape is different) and BEFORE the general dispatch. All still `exit 0`.
# Because they self-handle a `..` root here (fail-safe token), they are DELIBERATELY absent from the
# general root-guard case below — listing them there would be dead code (unreachable after this block).
#   parse-codex-header <file>              → stdout: bare `N/4` (empty on absent/malformed header)
#   void-count <sid> <root> <part> <round> → stdout: bare integer >=0 (the count) or `-1` sentinel
#                                            (refused gen-sliced read / non-numeric args)
#   await-state <sid> <root>               → stdout: bare `none` | `corrupt` | `await kind=… op=… part=…
#                                            round=… attempt=… phase=… need=… got=… ready=<0|1>
#                                            started_at=…` (newest outstanding AWAIT; a `..` root fails
#                                            safe to `none`)
#   cursor-hash <sid> <root>               → stdout: bare 64-hex digest | empty | `corrupt`
#                                            (a `..` root fails safe to empty)
case "$verb" in
  parse-codex-header)
    # argv exception: <verb> <file>. Anti-spoof: first full-shape ^Engine: line only.
    mission_parse_codex_header "${2:-}"
    exit 0
    ;;
  parse-claude-header)
    # argv exception: <verb> <file>. Same anti-spoof shape as parse-codex-header.
    # EMPTY stdout = absent or malformed = the caller MUST treat it as VOID, never as pass.
    mission_parse_claude_header "${2:-}"
    exit 0
    ;;
  void-count)
    # argv exception: <verb> <sid> <root> <part> <round>. stdout MUST be a bare integer or -1 — a
    # STOP-branching §5 caller reads it directly (stderr alone cannot block a count-testing caller).
    _vc_out=$(_void_consecutive_count "${2:-}" "${3:-}" "${4:-}" "${5:-}" 2>/dev/null)
    case "$_vc_out" in ''|*[!0-9-]*|-|-*[!0-9]*) _vc_out=-1 ;; esac
    printf '%s\n' "$_vc_out"
    exit 0
    ;;
  await-state)
    # argv exception: <verb> <sid> <root>. stdout MUST be a BARE token (`none` or `await …`) — the
    # mission wake routine reads it directly, so a `mission-write: …` status line would corrupt the
    # capture. Same read-only shape as void-count/parse-codex-header. A `..` root (I6) fails safe to
    # `none` (an unreachable mission has no outstanding await). mission_await_state is itself tolerant.
    case "${3:-}" in *..*) printf 'none\n'; exit 0 ;; esac
    mission_await_state "${2:-}" "${3:-}" 2>/dev/null
    exit 0
    ;;
  cursor-hash)
    # argv exception: <verb> <sid> <root>. stdout MUST be a BARE hex digest (or empty) — the
    # mission wake routine reads it directly for the idempotency cursor compare, so a
    # `mission-write: …` status line would corrupt the capture. Same read-only shape as
    # await-state/void-count. A `..` root (I6) returns EMPTY; note this is NOT a silent "safe"
    # value for cursor-hash - the §12.1 consumer treats an empty cursor as corrupt (C1 STOP-LOUD),
    # so a `..` root fails LOUD downstream (unreachable in normal operation - the wake routine
    # always passes an absolute canonical root). mission_cursor_hash is otherwise tolerant.
    case "${3:-}" in *..*) printf '\n'; exit 0 ;; esac
    mission_cursor_hash "${2:-}" "${3:-}" 2>/dev/null
    exit 0
    ;;
esac

# ── status/refuse emitters (shared) ─────────────────────────────────────────────────────────
# _mw_emit_refuse <verb> <rc> <message> — print the parseable FAILED status line, then exit 0.
_mw_emit_refuse() {
  echo "mission-write: $1 FAILED rc=$2 ($3)"
  exit 0
}
# _mw_outcome_status <verb> <rc> — emit the exact-token status for a log/note/challenge/pending
# write, reading the lib's _MLA_OUTCOME global (collision/rerouted/wrong-gen surface loud; the rest
# fall through to the plain ok/FAILED status).
_mw_outcome_status() {
  _os_verb="$1"; _os_rc="$2"
  # Arm the liveness guard on any successful bridge mutation (see _mw_arm_liveness for why this seam
  # and not only the wake routine's step 0). Best-effort and silent: it never touches rc or stdout.
  [ "$_os_rc" -eq 0 ] && _mw_arm_liveness "${sid:-}" "${root:-}"
  case "${_MLA_OUTCOME:-}" in
    collision) echo "mission-write: ${_os_verb} COLLISION (idtag exists with DIFFERENT content — re-derive gen/round; do NOT assume banked)" ;;
    rerouted)  echo "mission-write: ${_os_verb} REROUTED-TO-NOTES (>=480B — rewrite TERSE and re-log)" ;;
    wrong-gen) echo "mission-write: ${_os_verb} FAILED rc=5 (REFUSED: ${_MLA_REASON:-idtag gen prefix does not match current gen})" ;;
    *)         _mw_status "$_os_verb" "$_os_rc" "see stderr" ;;
  esac
}

# _mw_strip_gen <idtag> — echo the idtag with a leading numeric `g<N>-` gen prefix removed (for
# idtag↔entry field-equality, which compares the gen-independent m<N>/phase/round structure).
_mw_strip_gen() {
  case "$1" in
    g[0-9]*-*)
      _sg_p=${1#g}; _sg_p=${_sg_p%%-*}
      case "$_sg_p" in ''|*[!0-9]*) printf '%s' "$1" ;; *) printf '%s' "${1#*-}" ;; esac
      ;;
    *) printf '%s' "$1" ;;
  esac
}

# _mw_efield <string> <key> — extract `<key>=<value>` (value = the run of grammar chars) from a
# string, or empty. Used for entry-side field extraction (part/round/phase).
_mw_efield() {
  printf '%s' "$1" | sed -n "s/.*$2=\\([A-Za-z0-9_.:-]*\\).*/\\1/p"
}

# _mw_emit_snapshot <entry> <sid> <root> — STALE-CLAIM GUARD, stamp half. If <entry> is a genuinely-new
# CONVERGED review round (`phase=review findings=0 dry=2`), append a companion `[mission] SNAPSHOT` line
# recording the tree fingerprint convergence was reached at, so `_mw_partdone_check` can later refuse a
# PART-DONE whose tree drifted after that convergence. Best-effort + SILENT on stdout (the §5 log-verb
# callers capture exactly one status token; a second stdout line would corrupt their capture — diagnostics
# go to stderr only). The CALLER gates on `_MLA_OUTCOME=appended` so an idempotent re-emit never re-stamps
# a drifted tree (which would mask drift). Written via mission_log_append DIRECTLY (bypasses _mw_validate_log
# exactly like the other lib-level emitters). Idtag `snap-p<N>-conv-<tree16>` => same convergence state
# stamped twice is idempotent; a different tree gets a different idtag (no false collision).
_mw_emit_snapshot() {
  _es_entry="$1"; _es_sid="$2"; _es_root="$3"
  case "$_es_entry" in *"[mission] part="*"phase=review"*) : ;; *) return 0 ;; esac
  [ "$(_mw_efield "$_es_entry" findings)" = 0 ] || return 0
  [ "$(_mw_efield "$_es_entry" dry)" = 2 ] || return 0
  _es_part=$(_mw_efield "$_es_entry" part)
  case "$_es_part" in ''|*[!0-9]*) return 0 ;; esac
  _es_tree=$(_mission_tree_fingerprint "$_es_root" 2>/dev/null)
  case "$_es_tree" in ''|nogit|nohead|nohash) return 0 ;; esac   # cannot fingerprint → do not stamp
  _es_goal=$(_mission_goal_hash "$_es_sid" 2>/dev/null); [ -n "$_es_goal" ] || _es_goal=nogoal
  _es_files=$(git -C "$_es_root" -c core.autocrlf=false diff HEAD --name-only 2>/dev/null | grep -c .)
  case "$_es_files" in ''|*[!0-9]*) _es_files=0 ;; esac
  _es_line="[mission] SNAPSHOT part=${_es_part} kind=converged tree=${_es_tree} goal=${_es_goal} files=${_es_files} ver=1"
  mission_log_append "$_es_sid" "$_es_root" "$_es_line" "snap-p${_es_part}-conv-${_es_tree}" >/dev/null 2>&1 || true
  return 0
}

# ── per-shape LOG validator (mission-write.sh log ONLY) ─────────────────────────────────────
# THE AUTHORITATIVE GRAMMAR TABLE lives here. A malformed `[mission]` shape (or an unknown leading
# token) is REFUSED so the malformed-shape hole closes; free text (non-`[mission]`) passes through
# to the lib (which reroutes oversize free text to NOTES). Prints + exits on any refusal.
_mw_validate_log() {
  _vl_entry="$1"; _vl_idtag="$2"; _vl_sid="$3"; _vl_root="$4"
  # control chars — LITERAL case pattern (NEVER `*"$(printf '\n')"*`, which strips to "" and matches
  # EVERYTHING — verified failure mode).
  case "$_vl_entry" in
    *$'\t'*|*$'\n'*|*$'\r'*) _mw_emit_refuse log 1 "REFUSED: control-char-in-entry" ;;
  esac
  # only `[mission] ` shapes are grammar-checked; free text passes through.
  case "$_vl_entry" in
    "[mission] "*) : ;;
    *) return 0 ;;
  esac
  _vl_md="${_vl_root}/MISSION.${_vl_sid}.md"
  # gen-prefixed idtag for BOTH the wrong-gen refuse AND the length pre-check (incl. gen-prefix bytes).
  _vl_gtag=$(_mission_gen_tag "$_vl_md" "$_vl_idtag"); _vl_gtrc=$?
  if [ "$_vl_gtrc" -eq 5 ]; then
    _mw_emit_refuse log 5 "REFUSED: idtag prefix does not match current gen"
  fi
  # LENGTH REFUSE — persisted line (gen-prefixed idtag + TAB + entry + newline) for EVERY machine
  # shape. Free text already returned above; every path below is a terse machine shape.
  _vl_blen=$(printf '%s\t%s\n' "$_vl_gtag" "$_vl_entry" | LC_ALL=C wc -c | tr -d ' ')
  # 480 = the per-line byte budget. MUST stay equal to the reroute threshold in
  # lib/mission-bridge.sh (mission_log_append, currently :1168) — the validator REFUSES at the same
  # size the lib would otherwise reroute-to-notes. If you change one, change both.
  if [ -n "$_vl_blen" ] && [ "$_vl_blen" -ge 480 ]; then
    _mw_emit_refuse log 1 "REFUSED: line-too-long"
  fi
  _vl_bare=$(_mw_strip_gen "$_vl_idtag")     # idtag with any gen prefix removed, for equality
  _vl_pl=${_vl_entry#"[mission] "}
  case "$_vl_pl" in
    part=*)
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] part=[0-9]+ name=[A-Za-z0-9_.:-]+ phase=(research|plan|implement|review|fix) round=[0-9]+ dry=[0-2]( findings=[0-9]+| open=[0-9]+)?$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-round-shape"
      case "$_vl_entry" in *" open="*) case "$_vl_entry" in *" phase=plan "*) : ;; *) _mw_emit_refuse log 1 "REFUSED: open= is only for phase=plan" ;; esac ;; esac
      printf '%s' "$_vl_bare" | grep -qE '^m[0-9]+-(research|plan|implement|review|fix)-r[0-9]+-d[0-2]$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-round-idtag"
      _en=$(_mw_efield "$_vl_entry" part); _ep=$(_mw_efield "$_vl_entry" phase); _er=$(_mw_efield "$_vl_entry" round)
      _in=$(printf '%s' "$_vl_bare" | sed -n 's/^m\([0-9]*\)-.*/\1/p')
      _ip=$(printf '%s' "$_vl_bare" | sed -n 's/^m[0-9]*-\([a-z]*\)-r[0-9].*/\1/p')
      _ir=$(printf '%s' "$_vl_bare" | sed -n 's/.*-r\([0-9]*\)-d[0-2]$/\1/p')
      { [ "$_en" = "$_in" ] && [ "$_ep" = "$_ip" ] && [ "$_er" = "$_ir" ]; } \
        || _mw_emit_refuse log 1 "REFUSED: idtag-entry-field-mismatch (round)"
      ;;
    "VOID "*)
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] VOID part=[0-9]+ phase=review round=[0-9]+ reason=[a-z0-9.-]+$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-void-shape"
      printf '%s' "$_vl_bare" | grep -qE '^m[0-9]+-void-r[0-9]+-[A-Za-z0-9]+h([0-9a-f]{8}|nofile)$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-void-idtag"
      _en=$(_mw_efield "$_vl_entry" part); _er=$(_mw_efield "$_vl_entry" round)
      _in=$(printf '%s' "$_vl_bare" | sed -n 's/^m\([0-9]*\)-void-.*/\1/p')
      _ir=$(printf '%s' "$_vl_bare" | sed -n 's/^m[0-9]*-void-r\([0-9]*\)-.*/\1/p')
      { [ "$_en" = "$_in" ] && [ "$_er" = "$_ir" ]; } \
        || _mw_emit_refuse log 1 "REFUSED: idtag-entry-field-mismatch (void)"
      ;;
    "FAIL part="*" park="*)
      # proto=2 park record (plan 5.4): reason, code disposition, rejected range (base12..head12).
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] FAIL part=[0-9]+ park=[a-z0-9-]+ disposition=(reverted|isolated|left-with-recorded-risk) range=[0-9a-f]{12}\.\.[0-9a-f]{12}$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-park-shape"
      [ "$_vl_bare" = "m$(_mw_efield "$_vl_entry" part)-fail-park" ] || _mw_emit_refuse log 1 "REFUSED: bad-park-idtag (want m<N>-fail-park)"
      ;;
    "FAIL "*)
      # LEGACY generations only (land-r7): the frozen playbook's park path (its §6.1 cap-exhausted and
      # §12.1 spend-brake steps) writes the FAIL with its REQUIRED disposition field appended. That shape
      # was never accepted (pre-existing on main too); accept exactly it, and only where the frozen
      # playbook runs. proto=2 FAIL validation is unchanged.
      if printf '%s' "$_vl_entry" | grep -qE '^\[mission\] FAIL part=[0-9]+ phase=[a-z-]+ reason=(cap-exhausted-blocking|part-over-budget) attempt=[0-9]+ disposition=(reverted|isolated|left-with-recorded-risk)$'; then
        _p2_load "$_vl_sid" "$_vl_root" log
        _p2_legacy_gen || _mw_emit_refuse log 1 "REFUSED: bad-fail-shape (a FAIL with disposition= is the legacy park record; legacy generations only - proto=2 parks use FAIL part=N park= disposition= range=)"
      else
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] FAIL part=[0-9]+ phase=[a-z-]+ reason=[a-z0-9-]+ attempt=[0-9]+$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-fail-shape"
      fi
      printf '%s' "$_vl_bare" | grep -qE '^m[0-9]+-fail-([a-z0-9-]+-[0-9]+|panel3x-r[0-9]+)$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-fail-idtag"
      _en=$(_mw_efield "$_vl_entry" part); _in=$(printf '%s' "$_vl_bare" | sed -n 's/^m\([0-9]*\)-fail-.*/\1/p')
      [ "$_en" = "$_in" ] || _mw_emit_refuse log 1 "REFUSED: idtag-entry-field-mismatch (fail)"
      ;;
    "REVIEW-EVIDENCE "*)
      # Binds a CLEAN review round to the report that actually produced it (2026-08-17, item 7).
      # THE HOLE THIS CLOSES: _mw_partdone_check gates on ARITHMETIC over round lines the agent
      # writes itself — two adjacent findings=0 dry=1/dry=2 lines. An agent that ran 3 of 9 lanes,
      # or ran NO review at all, writes a line indistinguishable from a full panel. The Engine-header
      # VOID (added earlier today) catches a lens that DIED mid-review; it cannot catch a review that
      # never ran, because a review that never ran produces no report to parse. Owner ruling:
      # "we cannot move on without reviewing."
      # Same honesty-scoping as live-verify below: the report PATH is the one thing we can check
      # mechanically, so we stat it — a missing path is fixture-theater and is REFUSED.
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] REVIEW-EVIDENCE part=[0-9]+ round=[0-9]+ codex=[0-9]+/4 claude=[0-9]+/3 report=[^ ]+$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-review-evidence-shape"
      printf '%s' "$_vl_bare" | grep -qE '^m[0-9]+-review-evidence-r[0-9]+$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-review-evidence-idtag"
      _en=$(_mw_efield "$_vl_entry" part); _er=$(_mw_efield "$_vl_entry" round)
      _in=$(printf '%s' "$_vl_bare" | sed -n 's/^m\([0-9]*\)-review-evidence-.*/\1/p')
      _ir=$(printf '%s' "$_vl_bare" | sed -n 's/^m[0-9]*-review-evidence-r\([0-9]*\)$/\1/p')
      { [ "$_en" = "$_in" ] && [ "$_er" = "$_ir" ]; } \
        || _mw_emit_refuse log 1 "REFUSED: idtag-entry-field-mismatch (review-evidence)"
      _rep=$(printf '%s' "$_vl_entry" | sed -n 's/.* report=\([^ ]*\).*/\1/p')
      case "$_rep" in
        /*) [ -e "$_rep" ] || _mw_emit_refuse log 1 "REFUSED: review-evidence-report-missing ($_rep)" ;;
      esac
      ;;
    "live-verify part="*" sha="*)
      # proto=2 close leg: bound to the freeze SHA + attempt; sent and result records get distinct idtags.
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] live-verify part=[0-9]+ sha=[0-9a-f]{12} attempt=[0-9]+ status=(sent|ok evidence=[^ ]+|fail reason=[a-z0-9-]+|n/a reason=[a-z0-9-]+)$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-live-verify-shape"
      _lsfx=result; case "$_vl_entry" in *" status=sent") _lsfx=sent ;; esac
      [ "$_vl_bare" = "m$(_mw_efield "$_vl_entry" part)-live-$(_mw_efield "$_vl_entry" sha)-a$(_mw_efield "$_vl_entry" attempt)-$_lsfx" ] \
        || _mw_emit_refuse log 1 "REFUSED: bad-live-verify-idtag (want m<N>-live-<sha12>-a<A>-$_lsfx)"
      _ev=$(printf '%s' "$_vl_entry" | sed -n 's/.* status=ok evidence=\([^ ]*\).*/\1/p')
      case "$_ev" in /*) [ -e "$_ev" ] || _mw_emit_refuse log 1 "REFUSED: live-verify-evidence-path-missing ($_ev)" ;; esac
      ;;
    "live-verify "*)
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] live-verify part=[0-9]+ round=[0-9]+ status=(ok evidence=[^ ]+|n/a reason=[a-z0-9-]+)$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-live-verify-shape"
      printf '%s' "$_vl_bare" | grep -qE '^m[0-9]+-live-verify-r[0-9]+$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-live-verify-idtag"
      _en=$(_mw_efield "$_vl_entry" part); _er=$(_mw_efield "$_vl_entry" round)
      _in=$(printf '%s' "$_vl_bare" | sed -n 's/^m\([0-9]*\)-live-verify-.*/\1/p')
      _ir=$(printf '%s' "$_vl_bare" | sed -n 's/^m[0-9]*-live-verify-r\([0-9]*\)$/\1/p')
      { [ "$_en" = "$_in" ] && [ "$_er" = "$_ir" ]; } \
        || _mw_emit_refuse log 1 "REFUSED: idtag-entry-field-mismatch (live-verify)"
      # EVIDENCE HONESTY-SCOPING (plan Success-Criteria; codex-review 2026-07-12): a filesystem-PATH
      # evidence token (starts with `/`) is the one shape we CAN mechanically verify, so we STAT it —
      # a non-existent path is fixture-theater and is REFUSED. Non-path tokens (`od:<num>`, `sha:<hex>`,
      # URLs, bare slugs) stay RECORDED-not-verified by design (documented limitation; `status=n/a` is
      # the honest escape hatch for a part with no stat-able artifact).
      _ev=$(printf '%s' "$_vl_entry" | sed -n 's/.* status=ok evidence=\([^ ]*\).*/\1/p')
      case "$_ev" in
        /*) [ -e "$_ev" ] || _mw_emit_refuse log 1 "REFUSED: live-verify-evidence-path-missing ($_ev)" ;;
      esac
      ;;
    "PART-START "*" proto="*)
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] PART-START part=[0-9]+ name=[A-Za-z0-9_.:-]+ proto=2 worktree=/[^ ]+ base=[0-9a-f]{12} needs=(none|[0-9]+(,[0-9]+)*)$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-part-start-shape (proto=2 worktree=<abs> base=<sha12> needs=<none|N,..>)"
      [ "$_vl_bare" = "m$(_mw_efield "$_vl_entry" part)-part-start" ] || _mw_emit_refuse log 1 "REFUSED: bad-part-start-idtag"
      ;;
    "RECIPE "*)
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] RECIPE part=[0-9]+ v=[12] tier=(low|normal|high) floor=(none|(money|phi|auth|odwrite|migration)(,(money|phi|auth|odwrite|migration))*) plan=[0-9]+ review=[0-9]+ budget=[0-9]+ live=(yes|no) overlap=(none|plan-next) needs=(none|[0-9]+(,[0-9]+)*)$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-recipe-shape (v1 or v2 only; at= is writer-stamped)"
      [ "$_vl_bare" = "m$(_mw_efield "$_vl_entry" part)-recipe-v$(_mw_efield "$_vl_entry" v)" ] || _mw_emit_refuse log 1 "REFUSED: bad-recipe-idtag"
      ;;
    "FULL-SUITE "*)
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] FULL-SUITE part=[0-9]+ sha=[0-9a-f]{12} attempt=[0-9]+ base=[0-9a-f]{12} env=[0-9a-f]{16} completed=yes new-reds=[0-9]+ report=/[^ ]+$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-full-suite-shape (completed=yes only; an incomplete run is invalid, rerun it)"
      [ "$_vl_bare" = "m$(_mw_efield "$_vl_entry" part)-suite-$(_mw_efield "$_vl_entry" sha)-a$(_mw_efield "$_vl_entry" attempt)" ] || _mw_emit_refuse log 1 "REFUSED: bad-full-suite-idtag"
      ;;
    "SWEEP "*)
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] SWEEP part=[0-9]+ round=[0-9]+ types=[A-Z0-9_-]+(,[A-Z0-9_-]+)* sha=[0-9a-f]{12} instances=[0-9]+ report=/[^ ]+$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-sweep-shape"
      printf '%s' "$_vl_bare" | grep -qE "^m$(_mw_efield "$_vl_entry" part)-sweep-r$(_mw_efield "$_vl_entry" round)-s[0-9]+\$" || _mw_emit_refuse log 1 "REFUSED: bad-sweep-idtag"
      ;;
    "ANCHOR "*|"SNAPSHOT "*)
      _mw_emit_refuse log 1 "REFUSED: ${_vl_pl%% *} is written only by the writer itself"
      ;;
    "PART-START "*)
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] PART-START part=[0-9]+ name=[A-Za-z0-9_.:-]+$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-part-start-shape"
      printf '%s' "$_vl_bare" | grep -qE '^m[0-9]+-part-start$' || _mw_emit_refuse log 1 "REFUSED: bad-part-start-idtag"
      _en=$(_mw_efield "$_vl_entry" part); _in=$(printf '%s' "$_vl_bare" | sed -n 's/^m\([0-9]*\)-part-start$/\1/p')
      [ "$_en" = "$_in" ] || _mw_emit_refuse log 1 "REFUSED: idtag-entry-field-mismatch (part-start)"
      ;;
    "PART-DONE "*)
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] PART-DONE part=[0-9]+ \(converged\)$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-part-done-shape"
      printf '%s' "$_vl_bare" | grep -qE '^m[0-9]+-part-done$' || _mw_emit_refuse log 1 "REFUSED: bad-part-done-idtag"
      _en=$(_mw_efield "$_vl_entry" part); _in=$(printf '%s' "$_vl_bare" | sed -n 's/^m\([0-9]*\)-part-done$/\1/p')
      [ "$_en" = "$_in" ] || _mw_emit_refuse log 1 "REFUSED: idtag-entry-field-mismatch (part-done)"
      ;;
    "PART-RETIRED "*)
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] PART-RETIRED part=[0-9]+$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-part-retired-shape"
      printf '%s' "$_vl_bare" | grep -qE '^m[0-9]+-part-retired$' || _mw_emit_refuse log 1 "REFUSED: bad-part-retired-idtag"
      _en=$(_mw_efield "$_vl_entry" part); _in=$(printf '%s' "$_vl_bare" | sed -n 's/^m\([0-9]*\)-part-retired$/\1/p')
      [ "$_en" = "$_in" ] || _mw_emit_refuse log 1 "REFUSED: idtag-entry-field-mismatch (part-retired)"
      ;;
    "test-trust "*)
      # LEGACY GRANDFATHERED verbatim glued form `test-trust part=<N>=<ok|added|n/a>`.
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] test-trust part=[0-9]+=(ok|added|n/a)$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-test-trust-shape"
      printf '%s' "$_vl_bare" | grep -qE '^m[0-9]+-test-trust$' || _mw_emit_refuse log 1 "REFUSED: bad-test-trust-idtag"
      ;;
    "criticer "*)
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] criticer part=[0-9]+ findings=[0-9]+ .{0,200}$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-criticer-shape"
      printf '%s' "$_vl_bare" | grep -qE '^m[0-9]+-criticer-r[0-9]+$' || _mw_emit_refuse log 1 "REFUSED: bad-criticer-idtag"
      ;;
    "AWAIT "*)
      # R6 (round-5) — AWAIT is durable barrier control state whose SAFETY invariants (kind<->need<->got
      # coupling A4, single-lane got<=2 rejection, kind<->op namespace guard, started_at reuse, opener
      # semantics) are ALL enforced by mission_await_append and NONE by this validator. The generic `log`
      # verb enforces none of them, so a `log`-routed AWAIT (e.g. `kind=job need=3 got=3`) would forge a
      # two-lane review join in a SINGLE append, bypassing the each-lane-own-bit contract. AWAIT is written
      # ONLY via the dedicated `await` verb (→ mission_await_append → mission_log_append, which BYPASSES
      # this validator). Routing one through `log` is therefore ALWAYS illegitimate — fail closed.
      _mw_emit_refuse log 1 "REFUSED: AWAIT must be written via the dedicated 'await' verb, never 'log' (log bypasses the barrier safety invariants)"
      ;;
    "MISSION-CLEARED "*)
      # D12 SINGLE-WRITE-PATH INVARIANT: MISSION-CLEARED has NO dedicated lib emitter — the agent writes
      # it through THIS `log` verb with an EMPTY idtag as the natural close order, so this validator case
      # is the ONE-AND-ONLY writer path for it. A future direct `mission_log_append` emitter of a
      # MISSION-CLEARED line would BYPASS this case (and the human-STOP guard below), silently reopening
      # the erase hole. Keep it single-path: any new emitter MUST route through here, never the lib.
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] MISSION-CLEARED status=(achieved|could-not|cleared) reason=[a-z0-9-]*$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-mission-cleared-shape"
      [ -z "$_vl_idtag" ] || _mw_emit_refuse log 1 "REFUSED: mission-cleared-idtag-must-be-empty"
      # D11 (R8-10) — REFUSE a MISSION-CLEARED while an OPEN human STOP is live. The intended escape is to
      # resolve/deny the open decision FIRST (closing the barrier), THEN clear — not a blanket wedge.
      _mw_human_barrier_guard log "MISSION-CLEARED — resolve/deny the open decision first, then clear" "$_vl_sid" "$_vl_root"
      ;;
    "MISSION-REBASELINED "*)
      # D12 SINGLE-WRITE-PATH INVARIANT: MISSION-REBASELINED has EXACTLY ONE writer path — the dedicated
      # `rebaseline` verb (→ mission_rebaseline → mission_log_append, which bumps the marker gen in the
      # SAME op). This `log`-route is REFUSED below precisely to keep that single path. A future direct
      # lib emitter that appended a MISSION-REBASELINED line WITHOUT the marker gen bump would forge a gen
      # boundary and slice away an earlier human AWAIT — do NOT add one; route every rebaseline via the verb.
      # R6 (round-6) — MISSION-REBASELINED is a gen-boundary written ONLY by the dedicated `rebaseline`
      # verb (mission_rebaseline -> mission_log_append, which BYPASSES this validator AND bumps the marker
      # gen in the SAME op). A `log`-routed one would write the boundary line WITHOUT the marker gen bump,
      # so `_gen_sliced_stream` would honor a FORGED current-gen boundary and slice away an earlier human
      # AWAIT -> mandatory-gate bypass. The `log` verb is never a legit path for it -> fail closed.
      # (MISSION-CLEARED is DIFFERENT: the agent writes it via `log` with an EMPTY idtag as the natural
      # close order - it has no lib writer - so that case stays a validating case, not a refusal.)
      _mw_emit_refuse log 1 "REFUSED: MISSION-REBASELINED must be written via the dedicated 'rebaseline' verb, never 'log' (log bypasses the marker gen bump -> forged gen boundary)"
      ;;
    "DECISION "*)
      # R8-8 (D13) — the durable human-decision outcome for a pending-stop op. Grammar mirrors PART-DONE
      # (~:284): body `[mission] DECISION op=<seq>-<slug> outcome=<approve|deny>`, a NON-EMPTY idtag
      # pinned to the `(g<G>-)?pd-<seq>-decision-<slug>` namespace (DISTINCT from the `m<part>-` namespace,
      # 2a #13), and idtag<->body `op` EQUALITY. The idtag bind makes DECISION UN-FORGEABLE: a free-text
      # note carries its own idtag and fails the pin, so it can never masquerade as a decision. This
      # explicit case ALSO stops the generic `*)` default from REFUSING DECISION as unknown-shape (the
      # `await got=1` close is lib-enforced to require a same-op DECISION, so this write MUST be allowed).
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] DECISION op=[0-9]+-[a-z0-9-]+ outcome=(approve|deny)$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-decision-shape"
      [ -n "$_vl_idtag" ] || _mw_emit_refuse log 1 "REFUSED: decision-idtag-must-be-non-empty"
      printf '%s' "$_vl_bare" | grep -qE '^pd-[0-9]+-decision-[a-z0-9-]+$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-decision-idtag"
      # idtag<->body op EQUALITY (mirror PART-DONE's idtag<->part check ~:288): the `<seq>-<slug>` encoded
      # in the idtag (pd-<seq>-decision-<slug>) MUST equal the body `op=<seq>-<slug>`.
      _dbop=$(printf '%s' "$_vl_entry" | sed -n 's/^\[mission\] DECISION op=\([0-9][0-9]*-[a-z0-9-]*\) outcome=.*/\1/p')
      _diop=$(printf '%s' "$_vl_bare" | sed -n 's/^pd-\([0-9][0-9]*\)-decision-\([a-z0-9-]*\)$/\1-\2/p')
      { [ -n "$_dbop" ] && [ "$_dbop" = "$_diop" ]; } \
        || _mw_emit_refuse log 1 "REFUSED: idtag-entry-field-mismatch (decision)"
      ;;
    *)
      # MISSION-START / WORK-START are LIB-ONLY emissions (never routed through the log verb); any
      # other unknown `[mission]` leading token is a malformed shape.
      _mw_emit_refuse log 1 "REFUSED: unknown-shape"
      ;;
  esac
  return 0
}

# ── PART-DONE preconditions (dedup-first, gen-sliced, freshness-ordered, dry-count fold) ────────
# THREE preconditions on a genuinely-new PART-DONE (idempotent re-emits skip all of them). Prints +
# exits with FAILED rc=4 on any refusal (rc=4 BLOCKS retirement/advance — the carve-out).
_mw_partdone_check() {
  _pc_entry="$1"; _pc_idtag="$2"; _pc_sid="$3"; _pc_root="$4"
  case "$_pc_entry" in "[mission] PART-DONE part="*) : ;; *) return 0 ;; esac
  _pc_pn=$(_mw_efield "$_pc_entry" part); [ -n "$_pc_pn" ] || return 0
  # (0) idempotent? exact (gen-prefixed) idtag already banked → let the lib dedup return quiet ok.
  _pc_gtag=$(_mission_gen_tag "${_pc_root}/MISSION.${_pc_sid}.md" "$_pc_idtag")
  if _mission_timing_stream "$_pc_sid" "$_pc_root" | grep -qE "^$(_re_escape "$_pc_gtag")"$'\t' 2>/dev/null; then
    return 0
  fi
  # D11 (R8-10) — a GENUINELY-NEW PART-DONE (the idempotent re-emit above already returned) must NOT
  # advance the mission past an OPEN human STOP. Placed AFTER the dedup-first return so an idempotent
  # re-emit is never blocked (mirrors this function's dedup-first ordering). Fails closed on ambiguity.
  _mw_human_barrier_guard log "advancing this part (PART-DONE)" "$_pc_sid" "$_pc_root"
  [ "${P2_PROTO:-}" = 2 ] && return 0   # proto=2 PART-DONE is checked by _p2_partdone (close legs at the freeze)
  # gen-sliced archive-inclusive stream (REFUSE loud on gen-boundary-mismatch → rc=4 blocks advance).
  _pc_stream=$(_gen_sliced_stream "$_pc_sid" "$_pc_root") \
    || _mw_emit_refuse log 4 "REFUSED gen-boundary-mismatch"
  # (1) a gen-current live-verify part=N line EXISTS. B4 (round-2 S1): match the BODY after the idtag
  # TAB ($2), prefix-anchored, so a criticer/note line EMBEDDING `[mission] live-verify …` (its body
  # starts with `[mission] criticer …`, not `live-verify`) can no longer satisfy the convergence gate.
  printf '%s\n' "$_pc_stream" | awk -F'\t' -v pn="$_pc_pn" \
    '$2 ~ ("^\\[mission\\] live-verify part=" pn "([[:space:]]|$)") { f=1 } END { exit f?0:1 }' \
    || _mw_emit_refuse log 4 "REFUSED: PART-DONE without live-verify part=${_pc_pn} — run the live leg or log status=n/a reason=<slug>"
  # (1b) FRESHNESS — the LAST live-verify for part N must be ordered AFTER the last actionable event
  # (phase=review findings>0, VOID, phase=fix|implement) for part N. Otherwise stale evidence.
  _pc_fresh=$(printf '%s\n' "$_pc_stream" | awk -F'\t' -v pn="$_pc_pn" '
    function num(s,key,   p){ p=key"[0-9]+"; if(match(s,p)) return substr(s,RSTART+length(key),RLENGTH-length(key))+0; return -1 }
    $2 ~ ("^\\[mission\\] live-verify part=" pn "([^0-9]|$)") { lv=NR }
    ( $2 ~ ("^\\[mission\\] part=" pn "[^0-9]") && $2 ~ "phase=review" && num($2,"findings=")>0 ) { act=NR }
    ( $2 ~ ("^\\[mission\\] VOID part=" pn "[^0-9]") ) { act=NR }
    ( $2 ~ ("^\\[mission\\] part=" pn "[^0-9]") && ($2 ~ "phase=fix" || $2 ~ "phase=implement") ) { act=NR }
    END { if (lv>0 && lv>act) print "fresh"; else print "stale" }')
  [ "$_pc_fresh" = fresh ] \
    || _mw_emit_refuse log 4 "REFUSED live-verify-stale: part=${_pc_pn} was mutated after its last live-verify — re-run the live leg, then re-log with the CURRENT round"
  # (2) DRY-COUNT MACHINE FOLD — the last two banked review rounds for part N must be findings=0 dry=1
  # then findings=0 dry=2 (adjacent K, K+1), with NO actionable event after the dry=1 line. Body-anchored.
  _pc_clean=$(printf '%s\n' "$_pc_stream" | awk -F'\t' -v pn="$_pc_pn" '
    function num(s,key,   p){ p=key"[0-9]+"; if(match(s,p)) return substr(s,RSTART+length(key),RLENGTH-length(key))+0; return -1 }
    $2 ~ ("^\\[mission\\] part=" pn "[^0-9]") && $2 ~ "phase=review" {
      n++; rr[n]=num($2,"round="); rf[n]=num($2,"findings="); rd[n]=num($2,"dry="); rl[n]=NR }
    ( $2 ~ ("^\\[mission\\] part=" pn "[^0-9]") && $2 ~ "phase=review" && num($2,"findings=")>0 ) { act=NR }
    ( $2 ~ ("^\\[mission\\] VOID part=" pn "[^0-9]") ) { act=NR }
    ( $2 ~ ("^\\[mission\\] part=" pn "[^0-9]") && ($2 ~ "phase=fix" || $2 ~ "phase=implement") ) { act=NR }
    END {
      if (n<2) { print "no"; exit }
      a=n-1; b=n
      if (rf[a]==0 && rd[a]==1 && rf[b]==0 && rd[b]==2 && rr[b]==rr[a]+1 && !(act>rl[a])) print "yes"; else print "no" }')
  [ "$_pc_clean" = yes ] || _mw_emit_refuse log 4 "REFUSED: convergence-not-machine-clean"
  # (2b) REVIEW-EVIDENCE — the two folding rounds must EACH be bound to a report that really ran a
  # FULL panel (codex=4/4 AND claude=3/3). Check (2) above proves the ARITHMETIC of the round lines;
  # it cannot prove a review happened, because the agent writes those lines itself. This is the
  # difference between "the numbers fold" and "the work was done".
  # SELF-CUTOVER, and deliberately so: enforced only once this part has EVER banked a REVIEW-EVIDENCE
  # line. Rounds banked before this shipped carry none, and retroactively blocking them would brick
  # in-flight missions for work that was genuinely reviewed under the old contract — a convention
  # governs new work, it is not a licence to invalidate banked history. Once a part starts producing
  # evidence it must keep producing it; a later round that drops it FAILS.
  # RESIDUAL LIMIT, stated plainly: this cannot force an agent to emit the line in the first place.
  # Nothing in a log-append bridge can. It makes SKIPPING visible and makes a PARTIAL panel refuse;
  # a part that never emits any evidence is still gated only by (1),(2),(3). The emission mandate
  # lives in mission.md and is pinned by lint-skill-contract.sh.
  _pc_haveev=$(printf '%s\n' "$_pc_stream" | awk -F'\t' -v pn="$_pc_pn" \
    '$2 ~ ("^\\[mission\\] REVIEW-EVIDENCE part=" pn "[^0-9]") { f=1 } END { exit f?0:1 }' && echo yes || echo no)
  if [ "$_pc_haveev" = yes ]; then
    _pc_evok=$(printf '%s\n' "$_pc_stream" | awk -F'\t' -v pn="$_pc_pn" '
      function num(s,key,   p){ p=key"[0-9]+"; if(match(s,p)) return substr(s,RSTART+length(key),RLENGTH-length(key))+0; return -1 }
      $2 ~ ("^\\[mission\\] part=" pn "[^0-9]") && $2 ~ "phase=review" { n++; rr[n]=num($2,"round=") }
      $2 ~ ("^\\[mission\\] REVIEW-EVIDENCE part=" pn "[^0-9]") {
        r=num($2,"round="); cx=num($2,"codex="); cl=num($2,"claude=")
        if (cx==4 && cl==3) full[r]=1 }
      END {
        if (n<2) { print "no"; exit }
        a=rr[n-1]; b=rr[n]
        if (full[a] && full[b]) print "yes"; else print "no" }')
    [ "$_pc_evok" = yes ] \
      || _mw_emit_refuse log 4 "REFUSED: convergence-without-full-panel — both folding rounds need a REVIEW-EVIDENCE line with codex=4/4 claude=3/3; a round whose panel was short or absent cannot bank convergence"
  fi
  # (3) TREE-DRIFT (stale-claim guard, enforcement half) — the tree must not have moved since the
  # convergence this PART-DONE relies on. Compare the CURRENT fingerprint to the newest kind=converged
  # SNAPSHOT for part N (stamped by _mw_emit_snapshot at the dry=2 round). Missing stamp (legacy mission)
  # or an unfingerprintable tree (sentinel/empty) → SKIP: never false-block. A real drift → rc=4 (same
  # carve-out as the checks above; the refusal IS the correction — a blocked PART-DONE means re-review).
  _pc_snapline=$(printf '%s\n' "$_pc_stream" | awk -F'\t' -v pn="$_pc_pn" '$2 ~ ("^\\[mission\\] SNAPSHOT part=" pn "[^0-9]") && $2 ~ "kind=converged"' | tail -1)
  if [ -n "$_pc_snapline" ]; then
    _pc_stamped=$(_mw_efield "$_pc_snapline" tree)
    _pc_current=$(_mission_tree_fingerprint "$_pc_root" 2>/dev/null)
    case "$_pc_current" in
      ''|nogit|nohead|nohash) : ;;   # cannot verify → skip (never false-block)
      *)
        if [ -n "$_pc_stamped" ] && [ "$_pc_current" != "$_pc_stamped" ]; then
          _mw_emit_refuse log 4 "REFUSED: convergence-stale — tree moved after convergence (stamped=${_pc_stamped} current=${_pc_current}); re-review at the current tree, then re-log PART-DONE"
        fi
        ;;
    esac
  fi
  return 0
}

# ── R8-10 human-STOP writer guard (D11) ──────────────────────────────────────────────────────
# _mw_human_barrier_guard <status_verb> <action_phrase> <sid> <root> — REFUSE (rc=4) a
# state-advancing / state-erasing write while an OPEN human STOP barrier (kind=human ready=0) is
# live. Scoped to EXACTLY {genuinely-new PART-DONE, MISSION-CLEARED, rebaseline}: an unanswered human
# decision must be resolved/denied (closing the barrier) BEFORE the mission may advance a part, be
# cleared, or be rebaselined — otherwise those writes silently step over the STOP.
#
# FAIL CLOSED on ambiguity (Codex I-2): proceed ONLY on a trustworthy `none` or a resolved/away/job
# `await …` line. A `corrupt`/empty/unexpected await-state output REFUSES (we cannot prove no open
# human STOP). Prints the parseable FAILED line + exits 0 on refusal (never aborts the caller).
#
# CRITICAL EXEMPTIONS — this guard must NEVER run for the CLOSE sequence. The DECISION `log` write,
# the `await` got=1 close, and `resolve` are exactly HOW a human barrier gets closed; guarding them
# would self-deadlock DECISION-first (the barrier could never close). Only the three call sites named
# above invoke this guard; DECISION/await/resolve deliberately do NOT.
_mw_human_barrier_guard() {
  _hb_verb="$1"; _hb_act="$2"; _hb_sid="$3"; _hb_root="$4"
  _hb_state=$(mission_await_state "$_hb_sid" "$_hb_root" 2>/dev/null)
  # R8r6-G4/G2 - a CRASHED rebaseline (marker gen bumped, the boundary append died) makes await-state read
  # `corrupt` (gen-boundary-mismatch). That is a RECOVERABLE crash orphan, NOT real corruption - but this
  # LOCK-FREE pre-check runs BEFORE clear/part-done/rebaseline acquire the lock and run their own under-lock
  # _mission_lockheld_gen_recover, so without this those three paths would fail closed (rc=4) here and NEVER
  # reach recovery => a permanent wedge (G4). Attempt the bounded under-lock recovery HERE, then RE-READ.
  # The recover is integrity-FIRST + bounded to the exact crash signature (marker gen strictly ahead of the
  # newest VALID boundary) + idempotent, so it heals ONLY a real crashed rebaseline and NO-OPs a forged
  # future-gen / malformed boundary (those stay `corrupt` and still fail closed below). _mission_lock is
  # non-reentrant; we release before the writer re-acquires it, so this serializes with (never nests) the
  # writer's own recover - which then finds the boundary already present (idempotent no-op).
  if [ "$_hb_state" = corrupt ]; then
    _hb_lb=$(_mission_lockbase "$_hb_root")
    if _mission_lock "$_hb_lb" "$_hb_sid" 2>/dev/null; then
      _mission_lockheld_gen_recover "$_hb_sid" "$_hb_root"
      _mission_unlock
    fi
    _hb_state=$(mission_await_state "$_hb_sid" "$_hb_root" 2>/dev/null)
  fi
  # Trust ONLY a bare `none` or a well-formed `await …` line; anything else (corrupt/empty/unexpected)
  # fails closed. R8r6-G4 - an HONEST message: after the recovery attempt a STILL-`corrupt` read is a real
  # unreadable/corrupt archive or a forged gen boundary (there is NO open STOP to "resolve" - the prior text
  # was misleading and retrying never healed it); name the real recovery (repair/restore the log or archive).
  case "$_hb_state" in
    none|"await "*) : ;;
    *) _mw_emit_refuse "$_hb_verb" 4 "REFUSED: await-state '${_hb_state:-empty}' after gen-recovery attempt — fail closed; a corrupt/unreadable log-or-archive or a forged gen boundary remains (repair/restore it — retrying alone will not heal it)" ;;
  esac
  case "$_hb_state" in
    "await "*)
      _hb_kind=$(_mission_await_field "$_hb_state" kind)
      _hb_ready=$(_mission_await_field "$_hb_state" ready)
      if [ "$_hb_kind" = human ] && [ "$_hb_ready" = 0 ]; then
        _mw_emit_refuse "$_hb_verb" 4 "REFUSED: an OPEN human STOP barrier is live — resolve/deny the decision (closing the barrier) BEFORE ${_hb_act}"
      fi
      ;;
  esac
  return 0
}

# ══ PROTO=2 (rework plan v5) ════════════════════════════════════════════════════════════════
# Every part started after the rework is `proto=2`: its PART-START names the part worktree and base,
# a RECIPE bounds its budgets, `bank-review` is the ONLY writer of its review evidence and of any `dry=`
# raise, and PART-DONE checks the close legs at the freeze SHA instead of the old fold. Parts opened
# before the rework (a PART-START without proto) are grandfathered on the old fold. All checks below run
# after the dedup-first return, so an idempotent retry is never refused. Shapes (writer stamps `at=`):
#   PART-START part=N name=X proto=2 worktree=<abs> base=<sha12> needs=<none|N[,N]>
#   RECIPE part=N v=<1|2> tier= floor= plan= review= budget= live= overlap= needs=
#   FULL-SUITE part=N sha= attempt= base= env=<keyhash16> completed=yes new-reds= report=
#   SWEEP part=N round=K types=<KEY,..> sha= instances= report=
#   live-verify part=N sha= attempt= status=<sent|ok evidence=|fail reason=|n/a reason=>
#   FAIL part=N park=<slug> disposition=<reverted|isolated|left-with-recorded-risk> range=<b12>..<h12>
#   REVIEW-EVIDENCE part=N round=K scope=<plan|delta|close> base= head= codex= claude= tagged= blocking=
#       new= repeat= rkeys=<csv|-> result=<clean|blocking> report=   (bank-review only)
#   ANCHOR part=N sha=<sha12>   (writer only: root head for a legacy part, freeze SHA for proto=2)
#   SNAPSHOT part=N kind=converged tree=v2:<tree16> sha=<freeze12> goal= files=0 ver=2   (join only)
P2_RELOAD="playbook changed; re-read commands/mission.md before starting another part"
P2_FINAL_ENTRY=""; P2_PROTO=""; P2S=""

# token-bound field read: value = the run of non-space chars after ` <key>=`.
_p2_fv() { printf ' %s' "$1" | sed -n "s/.* $2=\\([^ ]*\\).*/\\1/p" | head -1; }
# A crashed rebaseline (marker gen bumped, boundary append lost) reads as a gen-boundary mismatch; heal it
# under the lock exactly like _mw_human_barrier_guard does (bounded, idempotent), then re-read once.
_p2_load() {
  P2S=$(_gen_sliced_stream "$1" "$2" 2>/dev/null) && return 0
  _pl_lb=$(_mission_lockbase "$2")
  if _mission_lock "$_pl_lb" "$1" 2>/dev/null; then _mission_lockheld_gen_recover "$1" "$2"; _mission_unlock; fi
  P2S=$(_gen_sliced_stream "$1" "$2" 2>/dev/null) || _mw_emit_refuse "$3" 4 "REFUSED gen-boundary-mismatch"
}
# _p2_lines <idtag-regex (no gen prefix)> <body-prefix after "[mission] "> -> matching bodies, in order
_p2_lines() {
  printf '%s\n' "$P2S" | awk -F'\t' -v t="$1" -v b="$2" \
    '$1 ~ ("^(g[0-9]+-)?" t) && index($2, "[mission] " b) == 1 { print $2 }'
}
_p2_ps()      { _p2_lines "m$1-part-start\$" "PART-START part=$1 " | tail -1; }
_p2_proto()   { _pp=$(_p2_ps "$1"); case "$_pp" in "") echo 0 ;; *" proto=2 "*) echo 2 ;; *) echo 1 ;; esac; }
_p2_done()    { [ -n "$(_p2_lines "m$1-part-done\$" "PART-DONE part=$1 ")" ]; }
_p2_retired() { [ -n "$(_p2_lines "m$1-part-retired\$" "PART-RETIRED part=$1")" ]; }
_p2_park()    { _p2_lines "m$1-fail-park\$" "FAIL part=$1 park=" | tail -1; }
_p2_cutover() { printf '%s\n' "$P2S" | awk -F'\t' '$1 ~ /^(g[0-9]+-)?m[0-9]+-part-start$/ && $2 ~ / proto=2 / {f=1} END{exit f?0:1}'; }
# Cutover is PER MISSION GENERATION (land-r6): a generation with any legacy PART-START (no proto=) is a
# legacy mission and runs end to end on docs/mission/legacy-playbook.md; one without is proto=2 end to
# end. Protocols never mix inside a generation; MISSION-REBASELINED starts a new one.
_p2_legacy_gen() { printf '%s\n' "$P2S" | awk -F'\t' '$1 ~ /^(g[0-9]+-)?m[0-9]+-part-start$/ && $2 ~ /^\[mission\] PART-START / && $2 !~ / proto=/ {f=1} END{exit f?0:1}'; }
_p2_mission_proto() { if _p2_legacy_gen; then echo legacy; elif _p2_cutover; then echo proto2; else echo new; fi; }
P2_LEGACY_MSG="this generation is a legacy mission: finish it on docs/mission/legacy-playbook.md, or rebaseline to start a proto=2 generation"
_p2_recipe()  { _r2=$(_p2_lines "m$1-recipe-v2\$" "RECIPE part=$1 v=2 " | tail -1)
                [ -n "$_r2" ] && printf '%s' "$_r2" || _p2_lines "m$1-recipe-v1\$" "RECIPE part=$1 v=1 " | tail -1; }
_p2_rounds()  { _p2_lines "m$1-[a-z]+-r[0-9]+-d[0-2]\$" "part=$1 name="; }
_p2_lastdry() { _ld=$(_p2_rounds "$1" | tail -1); _ld=$(_p2_fv "$_ld" dry); printf '%s' "${_ld:-0}"; }
_p2_evid()    { _p2_lines "m$1-review-evidence-$2-r[0-9]+\$" "REVIEW-EVIDENCE part=$1 "; }
# freeze = head of the latest clean delta evidence, valid only while the part's dry is >=1.
_p2_freeze()  { [ "$(_p2_lastdry "$1")" -ge 1 ] 2>/dev/null || return 0
                _p2_fv "$(_p2_evid "$1" delta | grep ' result=clean ' | tail -1)" head; }
_p2_open_parts() {   # parts with a PART-START and neither PART-DONE nor PART-RETIRED
  printf '%s\n' "$P2S" | awk -F'\t' '
    function pn(s){ sub(/^.*part=/,"",s); sub(/[^0-9].*$/,"",s); return s }
    $1 ~ /^(g[0-9]+-)?m[0-9]+-part-start$/ && $2 ~ /^\[mission\] PART-START / { st[pn($2)]=1 }
    $1 ~ /^(g[0-9]+-)?m[0-9]+-part-(done|retired)$/ && $2 ~ /^\[mission\] PART-(DONE|RETIRED) / { cl[pn($2)]=1 }
    END { for (p in st) if (!cl[p]) print p }'
}
_p2_now() { date +%s; }
_p2_head12() { git -C "$1" rev-parse HEAD 2>/dev/null | cut -c1-12; }
_p2_clean()  { [ "$(_mission_tree_fingerprint_v2 "$1")" != dirty ]; }
_p2_isanc()  { git -C "$1" merge-base --is-ancestor "$2" "$3" >/dev/null 2>&1; }

# _p2_tier_ok <tier> <plan> <review> <budget> — budgets bounded by the tier table (plan 3.2).
_p2_tier_ok() {
  case "$1" in low) _tp=3 _tr=3 _tb=120 ;; normal) _tp=5 _tr=8 _tb=300 ;; high) _tp=7 _tr=15 _tb=480 ;; *) return 1 ;; esac
  [ "$2" -ge 1 ] && [ "$2" -le "$_tp" ] && [ "$3" -ge 1 ] && [ "$3" -le "$_tr" ] && [ "$4" -ge 1 ] && [ "$4" -le "$_tb" ]
}

# _p2_budget <N> -> `ok` | `paused <livecum-min>` | `over <minutes> <replan>` (plan 5.4). The clock runs
# from PART-START at= (or the RECIPE v2 at=, reset once); it pauses only while live proof is the ONLY
# open leg: a clean close result AND a passing FULL-SUITE exist for the sha and a `sent` attempt has no
# result. Paused minutes add up across all close attempts; past 120 the part is over (park only).
_p2_budget() {
  _bn=$1; _brc=$(_p2_recipe "$_bn"); [ -n "$_brc" ] || { echo ok; return 0; }
  _bv2=$(_p2_lines "m$_bn-recipe-v2\$" "RECIPE part=$_bn v=2 " | tail -1)
  _bst=$(_p2_fv "$(_p2_ps "$_bn")" at); [ -n "$_bv2" ] && _bst=$(_p2_fv "$_bv2" at)
  _bbud=$(_p2_fv "$_brc" budget)
  _bfzc=$(_p2_freeze "$_bn")
  printf '%s\n' "$P2S" | awk -F'\t' -v pn="$_bn" -v now="$(_p2_now)" -v st="${_bst:-0}" -v bud="${_bbud:-0}" -v v2="${_bv2:+1}" -v fz="$_bfzc" '
    function f(s,k,  i,r,a){ i=index(s," " k "="); if(!i) return ""; r=substr(s,i+length(k)+2); split(r,a," "); return a[1] }
    index($2,"[mission] REVIEW-EVIDENCE part=" pn " ")==1 && $1 ~ /review-evidence-close-r/ && f($2,"result")=="clean" {
      h=f($2,"head"); t=f($2,"at")+0; if(!(h in cl) || t<cl[h]) cl[h]=t }
    index($2,"[mission] FULL-SUITE part=" pn " ")==1 && f($2,"new-reds")=="0" && f($2,"completed")=="yes" {
      h=f($2,"sha"); t=f($2,"at")+0; if(!(h in su) || t<su[h]) su[h]=t }
    index($2,"[mission] REVIEW-EVIDENCE part=" pn " ")==1 && $1 ~ /review-evidence-delta-r/ && f($2,"result")=="clean" {
      fzn[f($2,"head")]=NR }
    index($2,"[mission] part=" pn " name=")==1 && $1 ~ ("^(g[0-9]+-)?m" pn "-[a-z]+-r[0-9]+-d0$") && f($2,"at")!="" {
      nr0++; r0nr[nr0]=NR; r0at[nr0]=f($2,"at")+0 }
    index($2,"[mission] live-verify part=" pn " sha=")==1 {
      k=f($2,"sha") SUBSEP f($2,"attempt"); t=f($2,"at")+0
      if (f($2,"status")=="sent") { sent[k]=t; sh[k]=f($2,"sha") } else res[k]=t }
    END {
      # Intervals: a pause runs from max(sent, close, suite) to the attempt result, and never past the
      # moment its freeze was INVALIDATED (the first stamped dry=0 round line after the clean delta that
      # set that freeze). An unanswered attempt on the current freeze is still open (pe=now); one whose
      # freeze was invalidated is closed there and keeps the minutes it earned; with no known
      # invalidation time it earns none. Overlapping intervals are merged (counted once).
      n=0; paused=0
      for (k in sent) {
        h=sh[k]; if(!(h in cl) || !(h in su)) continue
        ps=sent[k]; if(cl[h]>ps) ps=cl[h]; if(su[h]>ps) ps=su[h]
        iv=-1; for (r=1;r<=nr0;r++) if (r0nr[r]>fzn[h] && (iv<0 || r0at[r]<iv)) iv=r0at[r]
        if (h==fz) iv=-1
        if (k in res) { pe=res[k]; if (iv>=0 && iv<pe) pe=iv }
        else if (h==fz) { pe=now; paused=1 }
        else if (iv>=0) pe=iv
        else continue
        if (pe>now) pe=now
        if (pe<=ps) continue
        n++; is[n]=ps; ie[n]=pe
      }
      for (i=2;i<=n;i++) { a=is[i]; b=ie[i]; j=i-1; while (j>=1 && is[j]>a) { is[j+1]=is[j]; ie[j+1]=ie[j]; j-- } is[j+1]=a; ie[j+1]=b }
      tot=0; aft=0; cs=-1; ce=-1
      for (i=1;i<=n+1;i++) {
        if (i<=n && cs>=0 && is[i]<=ce) { if (ie[i]>ce) ce=ie[i]; continue }
        if (cs>=0) { tot+=ce-cs; a=cs; if(a<st) a=st; if(ce>a) aft+=ce-a }
        if (i<=n) { cs=is[i]; ce=ie[i] }
      }
      el=int((now-st-aft)/60); lc=int(tot/60)
      if (lc>120) { printf "over %d 0\n", el; exit }
      if (bud>0 && el>bud) { printf "over %d %d\n", el, (v2==""?1:0); exit }
      if (paused) { printf "paused %d\n", lc; exit }
      print "ok" }'
}
_p2_over_guard() {   # <status-verb> <N>
  _og=$(_p2_budget "$2")
  case "$_og" in over*) _mw_emit_refuse "$1" 4 "REFUSED: part-over-budget part=$2 minutes=$(echo "$_og" | cut -d' ' -f2) - re-plan (RECIPE v2) once, else park" ;; esac
}

# ── known reds (plan 5.2) ────────────────────────────────────────────────────────────────────
# Suite report file: header lines sha= base= command= env= completed= infra=, a `--` line, then one
# `<test id> | <failure signature>` line per assertion failure. Baseline key = base SHA + command + env.
_p2_kr_hdr() { sed -n "1,/^--\$/s/^$2=//p" "$1" | head -1; }
_p2_kr_key() { printf '%s\n%s' "$(_p2_kr_hdr "$1" command)" "$(_p2_kr_hdr "$1" env)" | _mission_hash_stream; }
# normalize ONLY named nondeterministic fields: timestamps, temp paths, uuids, ports, durations and the
# value of an explicitly id-LABELLED field (`id=`, `request_id:`, `requestId=`, `ID:`). Ordinary numbers
# and hex values are assertion values and are kept: a numeric or hash change is a new red.
_p2_kr_norm() {
  sed -E -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?/<ts>/g' \
         -e 's#(/private)?(/var/folders|/tmp|/private/tmp)/[^ ]*#<tmp>#g' \
         -e 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<uuid>/g' \
         -e 's/(localhost|127\.0\.0\.1|0\.0\.0\.0):[0-9]+/\1:<port>/g' \
         -e 's/(^|[^A-Za-z0-9])(id|[A-Za-z0-9]*_id|[A-Za-z0-9]*[a-z0-9]Id|[A-Za-z0-9]*ID)(["'"'"']?[=:] ?["'"'"']?)[A-Za-z0-9_-]+/\1\2\3<id>/g' \
         -e 's/(^|[^A-Za-z0-9.])[0-9]+(\.[0-9]+)? ?(ms|s)([^A-Za-z0-9]|$)/\1<dur>\4/g'
}
_p2_kr_body() { sed -n '/^--$/,$p' "$1" | sed '1d' | grep ' | ' | _p2_kr_norm | LC_ALL=C sort -u; }
_p2_kr_valid() { [ -f "$1" ] && [ "$(_p2_kr_hdr "$1" completed)" = yes ] && [ "$(_p2_kr_hdr "$1" infra)" = 0 ] \
                 && [ -n "$(_p2_kr_hdr "$1" sha)" ] && [ -n "$(_p2_kr_hdr "$1" command)" ] && [ -n "$(_p2_kr_hdr "$1" env)" ]; }
# _p2_kr_diff <root> <report> -> count of reds not matching (id AND signature) a same-key baseline; -1 = invalid run
_p2_kr_diff() {
  _p2_kr_valid "$2" || { echo -1; return 0; }
  _kf="$1/.mission-known-reds/$(_p2_kr_hdr "$2" base)-$(_p2_kr_key "$2").txt"
  if [ -f "$_kf" ]; then
    _p2_kr_body "$2" | LC_ALL=C comm -23 - <(sed '1,/^--$/d' "$_kf" | LC_ALL=C sort -u) | grep -c .
  else _p2_kr_body "$2" | grep -c .; fi
}
_p2_kr_record() {   # <root> <report> -> rc 0 written, 1 refused
  _p2_kr_valid "$2" || return 1
  _kd="$1/.mission-known-reds"; mkdir -p "$_kd" 2>/dev/null || return 1
  _ks=$(_p2_kr_hdr "$2" sha); _kf="$_kd/${_ks}-$(_p2_kr_key "$2").txt"
  { printf 'base=%s\ncommand=%s\nenv=%s\ncompleted=yes\n--\n' "$_ks" "$(_p2_kr_hdr "$2" command)" "$(_p2_kr_hdr "$2" env)"
    { [ -f "$_kf" ] && sed '1,/^--$/d' "$_kf"; _p2_kr_body "$2"; } | LC_ALL=C sort -u; } > "$_kf.tmp.$$" \
    && mv -f "$_kf.tmp.$$" "$_kf"
}

# _p2_legs <N> <freeze> -> empty when the three close legs pass at <freeze>, else the missing leg's name.
_p2_legs() {
  _lc=$(_p2_evid "$1" close | awk -v h="$2" 'index($0," head=" h " ")' | tail -1)
  [ "$(_p2_fv "$_lc" result)" = clean ] || { echo close-review; return 0; }
  _ls=$(_p2_lines "m$1-suite-$2-a[0-9]+\$" "FULL-SUITE part=$1 sha=$2 " | awk '{for(i=1;i<=NF;i++) if($i ~ /^attempt=/){a=substr($i,9)+0}; if(a>=m){m=a;l=$0}} END{print l}')
  { [ "$(_p2_fv "$_ls" completed)" = yes ] && [ "$(_p2_fv "$_ls" new-reds)" = 0 ]; } || { echo full-suite; return 0; }
  _ll=$(_p2_lines "m$1-live-$2-a[0-9]+-(sent|result)\$" "live-verify part=$1 sha=$2 " | awk '
    {for(i=1;i<=NF;i++) if($i ~ /^attempt=/) a=substr($i,9)+0
     if (a>m) { m=a; r="" } if (a==m && $0 !~ / status=sent/) r=$0 } END{print r}')
  case "$(_p2_fv "$_ll" status)" in
    ok) : ;;
    n/a) [ "$(_p2_fv "$(_p2_recipe "$1")" live)" = no ] || { echo live-proof; return 0; } ;;
    *) echo live-proof; return 0 ;;
  esac
}

# _p2_stamp <sid> <root> <entry> <idtag> -> sets P2_FINAL_ENTRY: the banked line when this exact entry
# (ignoring at=) is already banked under the idtag (a retry keeps its ORIGINAL at=), else entry + at=now.
# Returns 0 when it is a dedup (the caller skips every check: dedup-first).
_p2_stamp() {
  _st_g=$(_mission_gen_tag "${2}/MISSION.$(_mission_sanitize_sid "$1").md" "$4" 2>/dev/null)
  _st_prev=$(printf '%s\n' "$P2S" | awk -F'\t' -v t="$_st_g" '$1==t {print $2; exit}')
  if [ -n "$_st_prev" ] && [ "${_st_prev% at=*}" = "$3" ]; then P2_FINAL_ENTRY="$_st_prev"; return 0; fi
  P2_FINAL_ENTRY="$3 at=$(_p2_now)"; return 1
}
_p2_is_banked() {   # <sid> <root> <entry> <idtag> -> exact (unstamped) line already banked
  _ib_g=$(_mission_gen_tag "${2}/MISSION.$(_mission_sanitize_sid "$1").md" "$4" 2>/dev/null)
  printf '%s\n' "$P2S" | awk -F'\t' -v t="$_ib_g" -v e="$3" '$1==t && $2==e {f=1} END{exit f?0:1}'
}
_p2_append() {      # <sid> <root> <entry-without-at> <idtag> : stamped, at-preserving append
  _p2_stamp "$1" "$2" "$3" "$4"
  mission_log_append "$1" "$2" "$P2_FINAL_ENTRY" "$4" >/dev/null 2>&1
}

# _p2_check_ps <entry> <N> <sid> <root> — proto=2 PART-START admission (plan 3.3, 5.4, 5.6).
_p2_check_ps() {
  _c_wt=$(_p2_fv "$1" worktree); _c_b=$(_p2_fv "$1" base); _c_needs=$(_p2_fv "$1" needs)
  [ -d "$_c_wt" ] || _mw_emit_refuse log 4 "REFUSED: part worktree does not exist ($_c_wt)"
  _c_top=$(cd "$_c_wt" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
  _c_real=$(cd "$_c_wt" && pwd -P)
  [ -n "$_c_top" ] && [ "$(cd "$_c_top" && pwd -P)" = "$_c_real" ] || _mw_emit_refuse log 4 "REFUSED: worktree= is not the top of a git worktree"
  [ "$_c_real" != "$(cd "$4" 2>/dev/null && pwd -P)" ] || _mw_emit_refuse log 4 "REFUSED: worktree= is the mission root; a part builds in its own linked worktree"
  _c_cd1=$(git -C "$_c_wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  _c_cd2=$(git -C "$4" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -n "$_c_cd1" ] && [ "$_c_cd1" = "$_c_cd2" ] || _mw_emit_refuse log 4 "REFUSED: worktree= does not share the mission root's git common dir"
  git -C "$_c_wt" rev-parse --verify -q "${_c_b}^{commit}" >/dev/null 2>&1 || _mw_emit_refuse log 4 "REFUSED: base=$_c_b is not a commit"
  # base= must BE the worktree's HEAD at admission: the needs/isolation checks below test base=, so a
  # reused worktree carrying parked commits on top of a clean declared base would otherwise ride in.
  _c_h=$(_p2_head12 "$_c_wt")
  [ "$_c_h" = "$_c_b" ] || _mw_emit_refuse log 4 "REFUSED: worktree HEAD ${_c_h:-?} is not the declared base base=$_c_b (start the part on a fresh worktree at its base)"
  for _c_o in $(_p2_open_parts); do
    [ "$_c_o" = "$2" ] || _mw_emit_refuse log 4 "REFUSED: part $_c_o is still open (neither PART-DONE nor PART-RETIRED)"
  done
  if [ "$_c_needs" != none ]; then
    for _c_n in $(printf '%s' "$_c_needs" | tr ',' ' '); do
      _p2_done "$_c_n" || _mw_emit_refuse log 4 "REFUSED: needs part $_c_n, which has no PART-DONE (deferred)"
      _c_a=$(_p2_fv "$(_p2_lines "m$_c_n-anchor\$" "ANCHOR part=$_c_n " | tail -1)" sha)
      # needs= can only name proto=2 parts of this generation (no legacy part exists in a proto=2 gen);
      # their anchor is always the freeze SHA written at their PART-DONE.
      [ -n "$_c_a" ] && _p2_isanc "$_c_wt" "$_c_a" "$_c_b" \
        || _mw_emit_refuse log 4 "REFUSED: needs part $_c_n but its anchor ${_c_a:-?} is not in base=$_c_b"
    done
  fi
  # isolation: no commit of an isolated park range may be in the new base (an empty range blocks nothing)
  printf '%s\n' "$P2S" | awk -F'\t' '$1 ~ /^(g[0-9]+-)?m[0-9]+-fail-park$/ && $2 ~ / disposition=isolated / { print $2 }' \
  | while IFS= read -r _c_pk; do
      _c_rg=$(_p2_fv "$_c_pk" range)
      for _c_c in $(git -C "$_c_wt" rev-list "$_c_rg" 2>/dev/null); do
        _p2_isanc "$_c_wt" "$_c_c" "$_c_b" && { echo x; break; }
      done
    done | grep -q x && _mw_emit_refuse log 4 "REFUSED: base=$_c_b contains a commit from an isolated (parked) range"
  return 0
}

# _p2_check <entry> <idtag> <sid> <root> — the proto=2 semantic layer for the `log` verb (runs after the
# shape validator). Sets P2_PROTO for _mw_partdone_check and P2_FINAL_ENTRY for the stamped append.
_p2_check() {
  _e="$1"; _t="$2"; P2_FINAL_ENTRY=""; P2_PROTO=""
  case "$_e" in "[mission] "*) : ;; *) return 0 ;; esac
  _n=$(_p2_fv "$_e" part); case "$_n" in ''|*[!0-9]*) return 0 ;; esac
  _p2_load "$3" "$4" log
  _pl=${_e#"[mission] "}
  _stamp=0
  case "$_pl" in
    "PART-START "*" proto=2 "*|RECIPE*|FULL-SUITE*|SWEEP*|"live-verify part="*" sha="*|"FAIL part="*" park="*) _stamp=1 ;;
  esac
  # proto=2 round lines are stamped too: a dry reset (a fix/implement/plan line at dry=0) is the moment a
  # freeze is invalidated, and budget-state needs that time to close an open live-wait pause there.
  [ "$(_p2_proto "$_n")" = 2 ] && case "$_pl" in "PART-DONE "*|part=*) _stamp=1 ;; esac
  if [ "$_stamp" = 1 ]; then _p2_stamp "$3" "$4" "$_e" "$_t" && return 0
  else _p2_is_banked "$3" "$4" "$_e" "$_t" && return 0; fi       # dedup-first: a retry is never refused
  P2_PROTO=$(_p2_proto "$_n")
  # proto=2 only: a legacy generation keeps the pre-rework writer behaviour unchanged.
  [ "$P2_PROTO" = 2 ] && _p2_retired "$_n" && _mw_emit_refuse log 4 "REFUSED: part-retired - part $_n is retired; a late write for it is an expected drop (no FAIL, no tally)"
  case "$_pl" in
    "PART-START "*)
      case "$_pl" in
        *" proto=2 "*)
          _p2_legacy_gen && _mw_emit_refuse log 4 "REFUSED: proto=2 PART-START in a legacy generation - $P2_LEGACY_MSG"
          _p2_check_ps "$_e" "$_n" "$3" "$4"; return 0 ;;
        *)  # a legacy PART-START continues a legacy generation only (the frozen playbook's next part)
          _p2_legacy_gen || _mw_emit_refuse log 4 "REFUSED: PART-START without proto=2 - $P2_RELOAD"
          return 0 ;;
      esac ;;
    RECIPE*|FULL-SUITE*|SWEEP*|"live-verify part="*" sha="*|"FAIL part="*" park="*)
      [ "$P2_PROTO" = 2 ] || _mw_emit_refuse log 4 "REFUSED: ${_pl%% *} needs a proto=2 PART-START for part $_n first - $P2_RELOAD" ;;
  esac
  if [ "$P2_PROTO" != 2 ]; then
    # legacy (grandfathered) part, or a pre-rework mission with no PART-START at all: the old fold. In a
    # mission that has cut over, a part-N line with no PART-START is refused (no bypass of the new gates).
    [ "$P2_PROTO" = 0 ] && _p2_cutover && _mw_emit_refuse log 4 "REFUSED: no PART-START for part $_n - $P2_RELOAD"
    return 0
  fi
  _rc=$(_p2_recipe "$_n")
  case "$_pl" in
    "REVIEW-EVIDENCE "*) _mw_emit_refuse log 1 "REFUSED: proto=2 review evidence is written only by bank-review - $P2_RELOAD" ;;
    "live-verify part="*" round="*) _mw_emit_refuse log 1 "REFUSED: legacy live-verify shape on a proto=2 part (use sha= attempt=) - $P2_RELOAD" ;;
    RECIPE*)
      _v=$(_p2_fv "$_e" v)
      [ "$(_p2_fv "$_e" tier)" = high ] || [ "$(_p2_fv "$_e" floor)" = none ] || _mw_emit_refuse log 1 "REFUSED: recipe floor=$(_p2_fv "$_e" floor) requires tier=high"
      _p2_tier_ok "$(_p2_fv "$_e" tier)" "$(_p2_fv "$_e" plan)" "$(_p2_fv "$_e" review)" "$(_p2_fv "$_e" budget)" \
        || _mw_emit_refuse log 1 "REFUSED: recipe budgets exceed the tier table"
      [ "$(_p2_fv "$_e" needs)" = "$(_p2_fv "$(_p2_ps "$_n")" needs)" ] || _mw_emit_refuse log 1 "REFUSED: recipe needs= differs from the PART-START needs="
      if [ "$_v" = 2 ]; then
        [ -n "$_rc" ] || _mw_emit_refuse log 4 "REFUSED: RECIPE v2 before v1"
        case "$(_p2_budget "$_n")" in "over "*" 1") : ;; *) _mw_emit_refuse log 4 "REFUSED: RECIPE v2 is only for a real overrun (budget-state over ... replan=1)" ;; esac
      fi
      return 0 ;;
    "FAIL part="*" park="*)
      _rg=$(_p2_fv "$_e" range); _wt=$(mission_part_worktree "$P2S" "$_n" "$4")
      [ "${_rg%%..*}" = "$(_p2_fv "$(_p2_ps "$_n")" base)" ] || _mw_emit_refuse log 1 "REFUSED: park range must start at the PART-START base"
      _p2_isanc "$_wt" "${_rg%%..*}" "${_rg##*..}" || _mw_emit_refuse log 1 "REFUSED: park range head is not a descendant of the base"
      return 0 ;;
    "PART-RETIRED "*)
      { _p2_done "$_n" || [ -n "$(_p2_park "$_n")" ]; } \
        || _mw_emit_refuse log 4 "REFUSED: PART-RETIRED for part $_n needs PART-DONE or a park FAIL (park= disposition= range=)"
      return 0 ;;
  esac
  _p2_over_guard log "$_n"
  case "$_pl" in
    part=*)
      _ph=$(_p2_fv "$_e" phase); _d=$(_p2_fv "$_e" dry)
      [ "$_ph" = review ] && _mw_emit_refuse log 1 "REFUSED: proto=2 review rounds are banked only by bank-review - $P2_RELOAD"
      [ "$_d" = 0 ] || [ "$_d" -le "$(_p2_lastdry "$_n")" ] || _mw_emit_refuse log 1 "REFUSED: a dry= raise is banked only by bank-review"
      case "$_ph" in
        plan) [ -n "$_rc" ] || _mw_emit_refuse log 1 "REFUSED: phase=plan before the part's RECIPE"
              [ -n "$(_p2_fv "$_e" open)" ] || _mw_emit_refuse log 1 "REFUSED: proto=2 phase=plan needs open=<n>" ;;
        implement)
              _lp=$(_p2_rounds "$_n" | grep ' phase=plan ' | tail -1)
              [ "$(_p2_fv "$_lp" open)" = 0 ] || _mw_emit_refuse log 1 "REFUSED: phase=implement needs the last plan line at open=0 (resolve, descope or park open DESIGN findings)" ;;
      esac ;;
    "FULL-SUITE "*)
      _r=$(_p2_fv "$_e" report)
      _p2_kr_valid "$_r" || _mw_emit_refuse log 1 "REFUSED: FULL-SUITE report missing, not completed=yes, or has infra failures (an invalid run: rerun it)"
      { [ "$(_p2_kr_hdr "$_r" sha)" = "$(_p2_fv "$_e" sha)" ] && [ "$(_p2_kr_hdr "$_r" base)" = "$(_p2_fv "$_e" base)" ] \
        && [ "$(_p2_kr_key "$_r")" = "$(_p2_fv "$_e" env)" ]; } || _mw_emit_refuse log 1 "REFUSED: FULL-SUITE sha/base/env do not match its report"
      [ "$(_p2_kr_diff "$4" "$_r")" = "$(_p2_fv "$_e" new-reds)" ] || _mw_emit_refuse log 1 "REFUSED: FULL-SUITE new-reds=$(_p2_fv "$_e" new-reds) disagrees with the known-reds recount ($(_p2_kr_diff "$4" "$_r"))" ;;
    "SWEEP "*)
      [ -e "$(_p2_fv "$_e" report)" ] || _mw_emit_refuse log 1 "REFUSED: sweep report missing"
      [ "$(_p2_fv "$_e" sha)" = "$(_p2_head12 "$(mission_part_worktree "$P2S" "$_n" "$4")")" ] || _mw_emit_refuse log 1 "REFUSED: sweep sha is not the part worktree HEAD" ;;
    "live-verify "*)
      _fz=$(_p2_freeze "$_n")
      [ -n "$_fz" ] && [ "$(_p2_fv "$_e" sha)" = "$_fz" ] || _mw_emit_refuse log 1 "REFUSED: live-verify sha is not the part's current freeze SHA (${_fz:-none})"
      case "$_pl" in *" status=n/a "*|*" status=n/a") [ "$(_p2_fv "$_rc" live)" = no ] || _mw_emit_refuse log 1 "REFUSED: live-verify n/a while the recipe says live=yes" ;; esac ;;
    "PART-DONE "*) _p2_partdone "$_n" "$4" ;;
  esac
  return 0
}

# _p2_partdone <N> <root> — PART-DONE for a proto=2 part (plan 4.6).
_p2_partdone() {
  [ -n "$(_p2_recipe "$1")" ] || _mw_emit_refuse log 4 "REFUSED: PART-DONE without a RECIPE"
  _pd_last=$(_p2_rounds "$1" | tail -1)
  case "$_pd_last" in *" phase=review "*" dry=2 "*) : ;; *) _mw_emit_refuse log 4 "REFUSED: PART-DONE needs the join (bank-review join -> dry=2) as the part's last round" ;; esac
  _pd_snap=$(printf '%s\n' "$P2S" | awk -F'\t' -v pn="$1" '$1 ~ ("^(g[0-9]+-)?snap-p" pn "-conv-") && index($2,"[mission] SNAPSHOT part=" pn " ")==1 && $2 ~ / ver=2$/ {l=$2} END{print l}')
  _pd_fz=$(_p2_fv "$_pd_snap" sha); [ -n "$_pd_fz" ] || _mw_emit_refuse log 4 "REFUSED: PART-DONE without a v2 convergence snapshot"
  _pd_miss=$(_p2_legs "$1" "$_pd_fz"); [ -z "$_pd_miss" ] || _mw_emit_refuse log 4 "REFUSED: close leg $_pd_miss not passing at freeze $_pd_fz"
  # sweep coverage: every repeat key raised in the part, by a clean sweep logged after the last fix line.
  _pd_keys=$(_p2_evid "$1" '(delta|close)' | sed -n 's/.* rkeys=\([^ ]*\).*/\1/p' | tr ',' '\n' | grep -v '^-$' | grep . | sort -u)
  if [ -n "$_pd_keys" ]; then
    _pd_ok=$(printf '%s\n' "$P2S" | awk -F'\t' -v pn="$1" -v keys="$(printf '%s' "$_pd_keys" | tr '\n' ',')" '
      index($2,"[mission] part=" pn " name=")==1 && $2 ~ / phase=fix / { lf=NR }
      index($2,"[mission] SWEEP part=" pn " ")==1 && $2 ~ / instances=0 / && $1 ~ ("^(g[0-9]+-)?m" pn "-sweep-r") {
        t=$2; sub(/.* types=/,"",t); sub(/ .*/,"",t); n=split(keys,k,","); c=1
        for(i=1;i<=n;i++) if (k[i]!="" && index("," t ",", "," k[i] ",")==0) c=0
        if (c) ls=NR }
      END { print (ls>lf) ? "yes" : "no" }')
    [ "$_pd_ok" = yes ] || _mw_emit_refuse log 4 "REFUSED: PART-DONE needs a clean SWEEP covering repeat types [$(printf '%s' "$_pd_keys" | tr '\n' ' ')] logged after the last fix"
  fi
  _pd_cur=$(_mission_tree_fingerprint_v2 "$(mission_part_worktree "$P2S" "$1" "$2")")
  [ "$_pd_cur" = "$(_p2_fv "$_pd_snap" tree)" ] \
    || _mw_emit_refuse log 4 "REFUSED: convergence-stale - part worktree ($_pd_cur) is not the freeze tree ($(_p2_fv "$_pd_snap" tree)); re-review, then re-log PART-DONE"
  return 0
}

# _p2_anchor_after_done <sid> <root> <N> — record the part's anchor once PART-DONE is banked: the freeze
# SHA, proto=2 parts only (a legacy mission never uses needs=/ANCHOR). Writer-only line (log refuses it).
_p2_anchor_after_done() {
  _p2_load "$1" "$2" log
  [ "$(_p2_proto "$3")" = 2 ] || return 0
  _ad=$(printf '%s\n' "$P2S" | awk -F'\t' -v pn="$3" '$1 ~ ("^(g[0-9]+-)?snap-p" pn "-conv-") && $2 ~ / ver=2$/ {l=$2} END{print l}')
  _ad=$(_p2_fv "$_ad" sha)
  [ -n "$_ad" ] && mission_log_append "$1" "$2" "[mission] ANCHOR part=$3 sha=$_ad" "m$3-anchor" >/dev/null 2>&1
  return 0
}

# ── bank-review (plan 4.2-4.6): the ONLY writer of proto=2 review evidence and of any dry= raise ──
_p2_br_void() {   # <sid> <root> <N> <K> <reason> <report>
  _bv_h=$(printf '%s' "$6" | _mission_hash_stream | cut -c1-8); [ -n "$_bv_h" ] || _bv_h=nofile
  _bv_id=$(basename "$(dirname "${6:-x}")" | tr -cd 'A-Za-z0-9'); [ -n "$_bv_id" ] || _bv_id=run
  mission_log_append "$1" "$2" "[mission] VOID part=$3 phase=review round=$4 reason=$5" "m$3-void-r$4-${_bv_id}h${_bv_h}" >/dev/null 2>&1
  _bv_c=$(_void_consecutive_count "$1" "$2" "$3" "$4" 2>/dev/null)
  _bv_x=""
  if [ "${_bv_c:-0}" -ge 3 ] 2>/dev/null; then
    mission_log_append "$1" "$2" "[mission] FAIL part=$3 phase=review reason=panel-unavailable-3x attempt=1" "m$3-fail-panel3x-r$4" >/dev/null 2>&1
    _mw_morning "$1" "$2"     # a STOP LOUD: the owner's report must be current
    _bv_x=" panel-unavailable-3x"
  fi
  echo "mission-write: bank-review VOID reason=$5 void-count=${_bv_c:-?}${_bv_x}"; exit 0
}
_p2_bank_review() {
  _bs="$1"; _br="$2"; _bn="$3"; _bk="$4"; _bsc="$5"; _brep="${6:-}"; _bimp="${7:-}"
  case "$_bn$_bk" in ''|*[!0-9]*) _mw_emit_refuse bank-review 1 "usage: bank-review <sid> <root> <N> <K> <plan|delta|close|join> [report] [impl-reviewer-output]" ;; esac
  case "$_bsc" in plan|delta|close|join) : ;; *) _mw_emit_refuse bank-review 1 "scope must be plan|delta|close|join" ;; esac
  _p2_load "$_bs" "$_br" bank-review
  [ "$(_p2_proto "$_bn")" = 2 ] || _mw_emit_refuse bank-review 4 "REFUSED: bank-review is for proto=2 parts (part $_bn has no proto=2 PART-START)"
  _p2_retired "$_bn" && _mw_emit_refuse bank-review 4 "REFUSED: part-retired - expected drop"
  _p2_over_guard bank-review "$_bn"
  _bwt=$(mission_part_worktree "$P2S" "$_bn" "$_br"); _bps=$(_p2_ps "$_bn"); _bname=$(_p2_fv "$_bps" name); _bbase=$(_p2_fv "$_bps" base)
  _brc=$(_p2_recipe "$_bn")
  if [ "$_bsc" = join ]; then
    # dry=1 is the normal entry. dry=2 is a RETRY (idempotent) or the repair of a partial bank (a crash
    # after an old-order dry=2 line, before its snapshot): every check re-runs and the missing line is
    # appended, never refused for "already dry=2".
    _bld=$(_p2_lastdry "$_bn")
    { [ "$_bld" = 1 ] || [ "$_bld" = 2 ]; } || _mw_emit_refuse bank-review 4 "REFUSED: join needs the part at dry=1 (a clean delta round) with no reset since"
    _bfz=$(_p2_freeze "$_bn"); _bmiss=$(_p2_legs "$_bn" "$_bfz")
    [ -z "$_bmiss" ] || _mw_emit_refuse bank-review 4 "REFUSED: join refused - leg $_bmiss not passing at freeze $_bfz"
    [ "$(_p2_head12 "$_bwt")" = "$_bfz" ] && _p2_clean "$_bwt" || _mw_emit_refuse bank-review 4 "REFUSED: join needs the part worktree clean at the freeze SHA $_bfz"
    _btr=$(_mission_tree_fingerprint_v2 "$_bwt"); _bg=$(_mission_goal_hash "$_bs" 2>/dev/null)
    case "$_btr" in v2:*) : ;; *) _mw_emit_refuse bank-review 4 "REFUSED: join cannot fingerprint the part worktree ($_btr)" ;; esac
    # SNAPSHOT FIRST: PART-DONE needs it, and a dry=2 line without it is the unrecoverable half-state.
    # Each append must return rc=0 AND report appended/dedup-idempotent (the appender starts at `failed`).
    mission_log_append "$_bs" "$_br" "[mission] SNAPSHOT part=$_bn kind=converged tree=$_btr sha=$_bfz goal=${_bg:-nogoal} files=0 ver=2" "snap-p$_bn-conv-${_btr#v2:}" >/dev/null 2>&1
    _bja=$?
    { [ "$_bja" = 0 ] && case "${_MLA_OUTCOME:-}" in appended|dedup-idempotent) true ;; *) false ;; esac; } \
      || _mw_emit_refuse bank-review 1 "join snapshot write failed (rc=$_bja outcome=${_MLA_OUTCOME:-none}) ${_MLA_REASON:-} - retry the join"
    if [ "$_bld" = 1 ]; then
      mission_log_append "$_bs" "$_br" "[mission] part=$_bn name=$_bname phase=review round=$_bk dry=2 findings=0" "m$_bn-review-r$_bk-d2" >/dev/null 2>&1
      _bja=$?
      { [ "$_bja" = 0 ] && case "${_MLA_OUTCOME:-}" in appended|dedup-idempotent) true ;; *) false ;; esac; } \
        || _mw_emit_refuse bank-review 1 "join dry=2 write failed (rc=$_bja outcome=${_MLA_OUTCOME:-none}) ${_MLA_REASON:-} - retry the join"
    fi
    _mw_arm_liveness "$_bs" "$_br"
    echo "mission-write: bank-review ok scope=join dry=2 freeze=$_bfz"; exit 0
  fi
  [ -f "$_brep" ] || _p2_br_void "$_bs" "$_br" "$_bn" "$_bk" report-missing "$_brep"
  if [ "$_bsc" = plan ]; then
    _bh=$(head -n 5 "$_brep" | grep -E '^Plan-review: round=[0-9]+ ' | head -1)
    [ -n "$_bh" ] || _p2_br_void "$_bs" "$_br" "$_bn" "$_bk" header-missing "$_brep"
    [ "$(printf '%s' "$_bh" | sed -n 's/^Plan-review: round=\([0-9]*\).*/\1/p')" = "$_bk" ] || _p2_br_void "$_bs" "$_br" "$_bn" "$_bk" round-mismatch "$_brep"
    [ "$(printf '%s' "$_bh" | grep -oE 'Plan-lanes: [0-9]+/4' | sed 's/Plan-lanes: //')" = 4/4 ] || _p2_br_void "$_bs" "$_br" "$_bn" "$_bk" panel-incomplete "$_brep"
    _bcx=4/4; _bcl=-; _bb=-; _bhd=-
  else
    case "$_brep" in */codex-review.*/report-final.md) : ;; *) _p2_br_void "$_bs" "$_br" "$_bn" "$_bk" forged-report "$_brep" ;; esac
    _brun=$(dirname "$_brep"); [ -f "$_brun/meta.env" ] || _p2_br_void "$_bs" "$_br" "$_bn" "$_bk" forged-report "$_brep"
    _bh=$(head -n 5 "$_brep" | grep -E '^Engine:.*Codex-passes: [0-9]+/4.*Verified:' | head -1)
    _bcx=$(mission_parse_codex_header "$_brep" 2>/dev/null); _bcl=$(mission_parse_claude_header "$_brep" 2>/dev/null)
    [ "$_bcx" = 4/4 ] && [ "$_bcl" = 3/3 ] || _p2_br_void "$_bs" "$_br" "$_bn" "$_bk" panel-incomplete "$_brep"
    [ -s "$_bimp" ] || _p2_br_void "$_bs" "$_br" "$_bn" "$_bk" impl-reviewer-missing "$_brep"
    _bscope=$(printf '%s' "$_bh" | sed -n 's/.*Scope: \([a-z]*\) base=\([0-9a-f]*\) head=\([0-9a-f]*\).*/\1 \2 \3/p')
    [ -n "$_bscope" ] || _p2_br_void "$_bs" "$_br" "$_bn" "$_bk" scope-missing "$_brep"
    set -- $_bscope; _bsk=$1; _bb=$2; _bhd=$3
    _brs=$(sed -n 's/^RUN_SHA=//p' "$_brun/meta.env" | head -1)
    case "$_brs" in "$_bhd"*) : ;; *) _p2_br_void "$_bs" "$_br" "$_bn" "$_bk" head-mismatch "$_brep" ;; esac
  fi
  _bvt=$(printf '%s' "$_bh" | grep -oE 'Verify: ok tagged=[0-9]+ blocking=[0-9]+' | head -1)
  [ -n "$_bvt" ] || _p2_br_void "$_bs" "$_br" "$_bn" "$_bk" verify-failed "$_brep"
  _btg=$(printf '%s' "$_bvt" | sed 's/.*tagged=\([0-9]*\).*/\1/'); _bbl=$(printf '%s' "$_bvt" | sed 's/.*blocking=//')
  _btags=$(grep -E '^TAG \| [A-Z0-9_-]+ \| (new|repeat) \| ' "$_brep")
  _btn=$(printf '%s' "$_btags" | grep -c .)
  { [ "$_btg" = "$_bbl" ] && [ "$_btn" = "$_btg" ]; } || _p2_br_void "$_bs" "$_br" "$_bn" "$_bk" untagged-blocking "$_brep"
  _bnew=$(printf '%s\n' "$_btags" | grep -c ' | new | '); _brp=$(printf '%s\n' "$_btags" | grep -c ' | repeat | ')
  _brk=$(printf '%s\n' "$_btags" | awk -F' [|] ' '$3=="repeat"{print $2}' | sort -u | paste -sd, -); [ -n "$_brk" ] || _brk=-
  # budgets and base/head binding per scope
  case "$_bsc" in
    plan)
      [ "$(_p2_evid "$_bn" plan | grep -c .)" -lt "$(_p2_fv "$_brc" plan)" ] || _mw_emit_refuse bank-review 4 "REFUSED: plan-round cap reached - park or descope" ;;
    delta)
      _blast=$(_p2_fv "$(_p2_evid "$_bn" delta | tail -1)" head)
      { [ "$_bb" = "$_bbase" ] || [ "$_bb" = "$_blast" ]; } || _mw_emit_refuse bank-review 4 "REFUSED: delta base=$_bb is neither the PART-START base nor the last reviewed head"
      [ "$(_p2_evid "$_bn" delta | grep -c .)" -lt "$(_p2_fv "$_brc" review)" ] || _mw_emit_refuse bank-review 4 "REFUSED: review-budget-exhausted - park the part" ;;
    close)
      _bfz=$(_p2_freeze "$_bn")
      [ -n "$_bfz" ] || _mw_emit_refuse bank-review 4 "REFUSED: close needs a current freeze (a clean delta round at dry=1)"
      { [ "$_bsk" = full ] && [ "$_bb" = "$_bbase" ] && [ "$_bhd" = "$_bfz" ]; } \
        || _mw_emit_refuse bank-review 4 "REFUSED: close report must be Scope: full base=$_bbase head=$_bfz" ;;
  esac
  _bres=clean; [ "$_bbl" = 0 ] || _bres=blocking
  _bdry=0
  if [ "$_bsc" = delta ] && [ "$_bbl" = 0 ]; then
    [ "$(_p2_head12 "$_bwt")" = "$_bhd" ] && _p2_clean "$_bwt" \
      || _mw_emit_refuse bank-review 4 "REFUSED: dry=1 needs the part worktree clean with HEAD == report head $_bhd"
    _bdry=1
  fi
  [ "$_bsc" = close ] && [ "$_bres" = clean ] && _bdry=1
  _p2_append "$_bs" "$_br" "[mission] REVIEW-EVIDENCE part=$_bn round=$_bk scope=$_bsc base=$_bb head=$_bhd codex=$_bcx claude=$_bcl tagged=$_btg blocking=$_bbl new=$_bnew repeat=$_brp rkeys=$_brk result=$_bres report=$_brep" "m$_bn-review-evidence-$_bsc-r$_bk"
  case "$_MLA_OUTCOME" in appended|dedup-idempotent) : ;; *) _mw_emit_refuse bank-review 1 "evidence write ${_MLA_OUTCOME:-failed} ${_MLA_REASON:-}" ;; esac
  if [ "$_bsc" = delta ] || { [ "$_bsc" = close ] && [ "$_bres" = blocking ]; }; then
    # stamped with the evidence's own at= (deterministic across retries: the evidence dedup keeps it)
    _bat=$(_p2_fv "$P2_FINAL_ENTRY" at)
    mission_log_append "$_bs" "$_br" "[mission] part=$_bn name=$_bname phase=review round=$_bk dry=$_bdry findings=$_bbl${_bat:+ at=$_bat}" "m$_bn-review-r$_bk-d$_bdry" >/dev/null 2>&1
  fi
  _bx=""
  [ "$_brk" != - ] && _bx=" sweep=required types=$_brk"
  if [ "$_bsc" = delta ] && [ "$_bnew" -gt 0 ]; then   # redesign: one area with new types 3 rounds running
    _bar=$(_p2_evid "$_bn" delta | tail -3 | sed -n 's/.* report=\([^ ]*\).*/\1/p' | while IFS= read -r _f; do
             grep -E '^TAG \| [A-Z0-9_-]+ \| new \| ' "$_f" 2>/dev/null | awk -F' [|] ' '{print $(NF-1)}' | sort -u; done \
           | sort | uniq -c | awk '$1>=3 {print $2; exit}')
    [ "$(_p2_evid "$_bn" delta | grep -c .)" -ge 3 ] && [ -n "$_bar" ] && _bx="$_bx redesign=$_bar"
  fi
  _mw_arm_liveness "$_bs" "$_br"
  echo "mission-write: bank-review ok scope=$_bsc dry=$_bdry blocking=$_bbl new=$_bnew repeat=$_brp result=$_bres$_bx"
  exit 0
}

# I6: light root-escape guard (defense-in-depth; root is trusted-caller-supplied). Refuse an
# empty root or one containing `..` traversal. NEVER abort the caller — print a status line and
# exit 0. The normal absolute-path case (no `..`) is unaffected. Only enforced for verbs that
# actually take a <root> arg (i.e. not the help/usage paths, which have no root).
case "$verb" in
  create|log|note|challenge|pending|pending-stop|resolve|rebaseline|render-banner|timing-resume|timing-contact|timing-close|archive-close|await|bank-review|budget-state|part-state|mission-proto|known-reds)
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

# MORNING REPORT (rework plan 9): rewrite <root>/tmp/mission/MORNING.md after every line that ends a
# part or a stretch of autonomy - PART-DONE, PART-RETIRED, MISSION-CLEARED, any FAIL (a park record,
# or the line behind a STOP LOUD) and an opened human STOP (pending-stop). Done HERE, not in playbook
# prose, because a stale morning report is a silent failure: nothing goes red, the owner just reads
# yesterday. Best-effort and silent: never touches rc or stdout. MISSION_MORNING=0 turns it off.
_mw_morning() {
  [ "${MISSION_MORNING:-1}" = 0 ] && return 0
  [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ -f "${_MW_SELF_DIR:-}/lib/mission-status.sh" ] || return 0
  bash "$_MW_SELF_DIR/lib/mission-status.sh" morning "$1" "$2" >/dev/null 2>&1 || true
}

# ARM THE LIVENESS GUARD on any mission-bridge mutation (best-effort, silent, idempotent).
#
# WHY HERE and not only at the wake routine's step 0. Arming at step 0 alone covers only missions
# that a wake has already driven. A mission driven entirely by USER turns has never executed a wake
# routine, so it never armed, so the guard was permanently inert for it - and the moment it matters
# most is exactly the transition from conversational to overnight ("continue, I'm going to bed"),
# which happens BEFORE any wake routine has run. Verified on this machine: an active 34-day mission
# with zero arming sentinels present. A peer session running that very mission reported the gap.
#
# This seam is the right one because it fires on any session doing mission WORK, whatever drove the
# turn. Arming broadly is safe only because the hook independently discriminates turn ORIGIN (it
# requires the sid to appear in the turn's opening prompt), so an armed session in which the user is
# simply conversing is never blocked. Disarm stays at the lifecycle close.
_mw_arm_liveness() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 0
  case "$2" in *..*) return 0 ;; esac
  _mwa_d="$HOME/.claude/progress"
  [ -d "$_mwa_d" ] || mkdir -p "$_mwa_d" 2>/dev/null || return 0
  _mwa_f="$_mwa_d/mission-liveness-$1.json"
  [ -f "$_mwa_f" ] && return 0          # idempotent: never rewrite on every log line
  # python for JSON-safe encoding - a root containing a quote or backslash would otherwise emit
  # invalid JSON and silently disarm the guard.
  python3 -c 'import json,sys; sys.stdout.write(json.dumps({"sid":sys.argv[1],"root":sys.argv[2]}))' \
    "$1" "$2" > "$_mwa_f.tmp" 2>/dev/null && mv -f "$_mwa_f.tmp" "$_mwa_f" 2>/dev/null
  return 0
}

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
    [ "$rc" -eq 0 ] && _mw_arm_liveness "$sid" "$root"
    _mw_status create "$rc" "see stderr"
    ;;

  log)
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ]; then
      echo "mission-write: usage: log <sid> <root> <entry> [idtag]"
      exit 0
    fi
    # per-shape grammar/control-char/length validation (prints + exits on refusal), then the
    # PART-DONE preconditions (dedup-first, gen-sliced, freshness-ordered, dry-count fold, tree-drift).
    _mw_validate_log "$4" "${5:-}" "$sid" "$root"
    _p2_check "$4" "${5:-}" "$sid" "$root"          # proto=2 layer (sets P2_PROTO, P2_FINAL_ENTRY)
    _mw_partdone_check "$4" "${5:-}" "$sid" "$root"
    _mw_entry="${P2_FINAL_ENTRY:-$4}"
    if [ -n "$P2_FINAL_ENTRY" ] && [ "$(printf '%s\t%s\n' "${5:-}xxxxx" "$_mw_entry" | LC_ALL=C wc -c | tr -d ' ')" -ge 480 ]; then
      _mw_emit_refuse log 1 "REFUSED: line-too-long"
    fi
    set -- "$1" "$2" "$3" "$_mw_entry" "${5:-}"
    case "$4" in
      "[mission] MISSION-CLEARED "*)
        # C4 — route the clear through the UNDER-LOCK guard (mission_clear_append re-checks await-state
        # under the SAME mint lock pending-stop opens under, closing the TOCTOU where a barrier opened
        # after the pre-lock _mw_human_barrier_guard but before the clear landed). rc=4 = open STOP.
        mission_clear_append "$sid" "$root" "$4" "${5:-}"
        rc=$?
        ;;
      "[mission] PART-DONE "*)
        # FIX J (R8r2) - route PART-DONE through the UNDER-LOCK guard. _mw_partdone_check (above) already
        # ran its LOCK-FREE _mw_human_barrier_guard pre-check; mission_partdone_append re-checks await-state
        # under the SAME mint lock pending-stop opens under, closing the TOCTOU where a STOP opened after
        # the pre-check but before the append landed. rc=4 = open human STOP (blocks advance). PART-DONE is
        # not a converged dry=2 review line, so it never needs the _mw_emit_snapshot stamp path.
        mission_partdone_append "$sid" "$root" "$4" "${5:-}"
        rc=$?
        [ "$rc" -eq 0 ] && [ "${_MLA_OUTCOME:-}" = appended ] && { _pd_o="$_MLA_OUTCOME"; _p2_anchor_after_done "$sid" "$root" "$(_mw_efield "$4" part)"; _MLA_OUTCOME="$_pd_o"; }
        ;;
      "[mission] DECISION "*)
        # R8r3-R4 - route the DECISION through the UNDER-LOCK wrapper so its anchored-idtag dedup + append is
        # ATOMIC and the DECISION serializes with the opener/close. The prior lock-free log path let two
        # concurrent approve/deny both land under one idtag (nondeterministic gated outcome) AND let a stale
        # monotonic-seq approval be appended right after a fresh opener and satisfy decnr>openernr (NR race).
        # _mw_validate_log already validated the DECISION shape + idtag<->op bind above; this is the write.
        mission_decision_append "$sid" "$root" "$4" "${5:-}"
        rc=$?
        ;;
      *)
        mission_log_append "$sid" "$root" "$4" "${5:-}"
        rc=$?
        # CAPTURE the log outcome BEFORE _mw_emit_snapshot's own mission_log_append clobbers the globals.
        _mw_log_outcome="${_MLA_OUTCOME:-}"; _mw_log_reason="${_MLA_REASON:-}"
        # Stale-claim guard, stamp half: on a genuinely-new converged dry=2 line ONLY (gate=appended),
        # stamp the convergence snapshot. No-op for every other line / outcome. Silent on stdout.
        [ "$_mw_log_outcome" = appended ] && _mw_emit_snapshot "$4" "$sid" "$root"
        # RESTORE the captured outcome so the status line reflects the log line, not the snapshot emit.
        _MLA_OUTCOME="$_mw_log_outcome"; _MLA_REASON="$_mw_log_reason"
        ;;
    esac
    if [ "$rc" -eq 0 ] && [ "${_MLA_OUTCOME:-}" = appended ]; then
      case "$4" in "[mission] PART-DONE "*|"[mission] PART-RETIRED "*|"[mission] MISSION-CLEARED "*|"[mission] FAIL "*)
        _mw_mo="$_MLA_OUTCOME"; _mw_morning "$sid" "$root"; _MLA_OUTCOME="$_mw_mo" ;; esac
    fi
    _mw_outcome_status log "$rc"
    ;;

  note)
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ]; then
      echo "mission-write: usage: note <sid> <root> <entry> [idtag]"
      exit 0
    fi
    mission_mutate "$sid" "$root" note "$4" "${5:-}"
    rc=$?
    _mw_outcome_status note "$rc"
    ;;

  challenge)
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ]; then
      echo "mission-write: usage: challenge <sid> <root> <entry> [idtag]"
      exit 0
    fi
    mission_mutate "$sid" "$root" challenge "$4" "${5:-}"
    rc=$?
    _mw_outcome_status challenge "$rc"
    ;;

  pending)
    # R7-1: interface = pending <sid> <root> <slug> <question...>. The verb MINTS a monotonic
    # `pd:<seq>-<slug>` id (seq machine-assigned, never reused), appends the pending line, and ECHOES
    # the minted id so the agent uses it for BOTH `resolve` and the human-AWAIT `op=<seq>-<slug>`.
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ] || [ -z "${5:-}" ]; then
      echo "mission-write: usage: pending <sid> <root> <slug> <question...>  (slug=[a-z0-9-]; seq is machine-minted)"
      exit 0
    fi
    _mw_pslug="$4"
    shift 4
    _mw_pquestion="$*"
    _mw_pid=$(mission_pending_mint "$sid" "$root" "$_mw_pslug" "$_mw_pquestion")
    rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "mission-write: pending ok id=${_mw_pid}"
    else
      _mw_status pending "$rc" "see stderr"
    fi
    ;;

  pending-stop)
    # [D2/D1] BLOCKING sibling of `pending` — the ONE barrier-opener. `pending` (above) stays
    # NON-BLOCKING; this verb ALSO opens the durable human STOP AWAIT got=0 (via the lib mint).
    # Interface: pending-stop <sid> <root> <slug> <part> <round> <attempt> <phase> <question...>.
    # DISPATCH ARG THREADING: the verb token is still $1 here, so the fixed args are $2..$8 and the
    # question tail is $9+. We capture the coords from $4..$8, then `shift 8` (drop
    # verb+sid+root+slug+part+round+attempt+phase) leaving the question words in $* — exactly how the
    # `pending` verb threads its <slug> <question...> via `shift 4`. The lib fn
    # mission_pending_stop_mint wants <sid> <root> <slug> <part> <round> <attempt> <phase> then the
    # question as its rest, so we hand it the reassembled question as a single argument.
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ] || [ -z "${5:-}" ] || [ -z "${6:-}" ] || [ -z "${7:-}" ] || [ -z "${8:-}" ] || [ -z "${9:-}" ]; then
      echo "mission-write: usage: pending-stop <sid> <root> <slug> <part> <round> <attempt> <phase> <question...>  (BLOCKING barrier-opener; slug=[a-z0-9-]; seq is machine-minted)"
      exit 0
    fi
    _mw_psslug="$4"; _mw_pspart="$5"; _mw_psround="$6"; _mw_psattempt="$7"; _mw_psphase="$8"
    shift 8
    _mw_psquestion="$*"
    _mw_psid=$(mission_pending_stop_mint "$sid" "$root" "$_mw_psslug" "$_mw_pspart" "$_mw_psround" "$_mw_psattempt" "$_mw_psphase" "$_mw_psquestion")
    rc=$?
    if [ "$rc" -eq 0 ]; then
      _mw_morning "$sid" "$root"
      echo "mission-write: pending-stop ok id=${_mw_psid}"
    else
      # Surface the lib fn's fail-closed non-zero returns as a clear, parseable FAILED line (the mint
      # writes NO pd line and echoes NOTHING on any refusal). rc map mirrors mission_pending_stop_mint's
      # returns. R8r3-R8 - rc=3 is now lock-busy ONLY (the single RETRYABLE meaning); the NON-retryable
      # fail-closed cases carry DISTINCT codes (10-14) with an accurate, do-NOT-retry reason each.
      case "$rc" in
        1)  _mw_psreason="bad args / invalid-or-too-long slug / missing question" ;;
        2)  _mw_psreason="corrupt: lock/verify/nonce/pdseq or await-state unreadable — fail closed" ;;
        3)  _mw_psreason="LOCK busy (RETRYABLE — retry the SAME call ~5x, then FAIL-line it per §9)" ;;
        4)  _mw_psreason="backup failed" ;;
        5)  _mw_psreason="mktemp failed" ;;
        6)  _mw_psreason="gen-tag/rewrite self-check failed — original intact" ;;
        7)  _mw_psreason="sequence-exhausted (next seq would be >999999)" ;;
        8)  _mw_psreason="assembled AWAIT line >= 480B budget" ;;
        9)  _mw_psreason="human AWAIT did not land on the fresh seq (non-land) — no pd line minted" ;;
        10) _mw_psreason="mission is CLEARED — do NOT retry; a STOP below MISSION-CLEARED is permanently hidden" ;;
        11) _mw_psreason="lifecycle unreadable — fail closed; do NOT retry until the log/archive is readable" ;;
        12) _mw_psreason="a DIFFERENT open human STOP is already live — resolve/deny it first; do NOT retry" ;;
        13) _mw_psreason="op is live with a DIFFERENT question — resolve/deny it first; do NOT retry" ;;
        14) _mw_psreason="ORPHAN barrier (lost pd line / already has a DECISION) — safe-ABORT deny it (write outcome=deny, close the barrier, do NOT proceed); a fresh decision needs a DIFFERENT slug; do NOT re-open/retry" ;;
        *)  _mw_psreason="see stderr" ;;
      esac
      echo "mission-write: pending-stop FAILED rc=${rc} (${_mw_psreason})"
    fi
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
    # D11 (R8-10) — REFUSE a rebaseline while an OPEN human STOP is live (a gen boundary would slice the
    # open barrier away). Resolve/deny the decision first (closing the barrier), then rebaseline. Fails
    # closed on ambiguous await-state. EXEMPT close-sequence verbs (DECISION/await/resolve) never call this.
    _mw_human_barrier_guard rebaseline "rebaselining (gen boundary)" "$sid" "$root"
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

  archive-close)
    if [ -z "$sid" ] || [ -z "$root" ]; then
      echo "mission-write: usage: archive-close <sid> <root>"
      exit 0
    fi
    # advisory — no-ops unless the mission is CLEARED; never blocks the close.
    mission_archive_close "$sid" "$root"
    rc=$?
    _mw_status archive-close "$rc" "see stderr"
    ;;

  await)
    if [ -z "$sid" ] || [ -z "$root" ] || [ -z "${4:-}" ]; then
      echo "mission-write: usage: await <sid> <root> <fields>"
      exit 0
    fi
    # Open/update the durable AWAIT marker. Routes through the DEDICATED lib emitter
    # mission_await_append → mission_log_append (which BYPASSES _mw_validate_log, exactly like
    # _mw_emit_snapshot / WORK-START). Reuses the anchored-idempotent log path, so a re-append of the
    # same got is a quiet dedup no-op; a same-idtag different-content append surfaces COLLISION.
    _aw_p=$(_mission_await_field "$4" part)
    if [ -n "$_aw_p" ]; then
      _p2_load "$sid" "$root" await
      # JOB barriers only: a late lane completion for a retired part is an expected drop. A HUMAN barrier
      # opened before retirement (e.g. a pre-cutover spend-brake pending-stop) must still close through
      # its validated path (DECISION first, then got=1); refusing it would wedge resolve/clear/rebaseline.
      if [ "$(_mission_await_field "$4" kind)" != human ]; then
        # string-normalize (never $(( )): bash 3.2 reads 08/09 as bad octal and aborts before any status line)
        case "$_aw_p" in *[!0-9]*) _mw_emit_refuse await 1 "REFUSED: part=$_aw_p is not a number" ;; esac
        _aw_pn=$(printf '%s' "$_aw_p" | sed 's/^0*//'); [ -n "$_aw_pn" ] || _aw_pn=0
        [ "$(_p2_proto "$_aw_pn")" = 2 ] && _p2_retired "$_aw_pn" && _mw_emit_refuse await 4 "REFUSED: part-retired - part $_aw_p is retired; a late completion is an expected drop (no FAIL, no tally)"
      fi
    fi
    mission_await_append "$sid" "$root" "$4"
    rc=$?
    _mw_outcome_status await "$rc"
    ;;

  bank-review)
    # bank-review <sid> <root> <N> <K> <plan|delta|close|join> [report] [impl-reviewer-output]
    _p2_bank_review "$sid" "$root" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}"
    ;;

  mission-proto)
    # read-only; bare token: legacy | proto2 | new. The wake routine reads it BEFORE the tick lock:
    # `legacy` -> the whole wake runs on docs/mission/legacy-playbook.md (its own §12).
    _p2_load "$sid" "$root" mission-proto
    _p2_mission_proto
    ;;

  part-state)
    # read-only; bare token for the wake's protocol dispatch (wake.md decision table):
    #   none | part=<N> proto=<1|2> dry=<0|1|2> closed=<0|1> freeze=<sha12|-> head=<sha12|-> tree=<clean|dirty|-> drift=<0|1>
    # Part = the open part (PART-START, no PART-DONE/RETIRED), else the newest started part. proto=1 is a
    # grandfathered legacy part (manual evidence banking, two-dry fold; never bank-review). drift=1 = a
    # proto=2 part at dry>=1 whose worktree HEAD moved off the freeze or is dirty: route to repair.
    _p2_load "$sid" "$root" part-state
    _psn=$(_p2_open_parts | sort -n | tail -1)
    [ -n "$_psn" ] || _psn=$(printf '%s\n' "$P2S" | awk -F'\t' '$1 ~ /^(g[0-9]+-)?m[0-9]+-part-start$/ && $2 ~ /^\[mission\] PART-START part=[0-9]+ / {l=$2} END{print l}' | sed -n 's/^\[mission\] PART-START part=\([0-9]*\) .*/\1/p')
    if [ -z "$_psn" ]; then echo none; exit 0; fi
    _psp=$(_p2_proto "$_psn"); _psd=$(_p2_lastdry "$_psn"); _psc=0
    { _p2_done "$_psn" || _p2_retired "$_psn"; } && _psc=1
    _psf=-; _psh=-; _pst=-; _psx=0
    if [ "$_psp" = 2 ]; then
      _psw=$(mission_part_worktree "$P2S" "$_psn" "$root")
      _psf=$(_p2_freeze "$_psn"); [ -n "$_psf" ] || _psf=-
      _psh=$(_p2_head12 "$_psw"); [ -n "$_psh" ] || _psh=-
      if _p2_clean "$_psw"; then _pst=clean; else _pst=dirty; fi
      if [ "$_psc" = 0 ] && [ "$_psd" != 0 ] && [ "$_psf" != - ] && { [ "$_psh" != "$_psf" ] || [ "$_pst" = dirty ]; }; then _psx=1; fi
    else
      _psh=$(_p2_head12 "$root"); [ -n "$_psh" ] || _psh=-
    fi
    echo "part=$_psn proto=$_psp dry=$_psd closed=$_psc freeze=$_psf head=$_psh tree=$_pst drift=$_psx"
    ;;

  budget-state)
    # read-only; bare token: ok | paused live=<min> | over part=N minutes=M replan=<0|1>
    _p2_load "$sid" "$root" budget-state
    _bsn=$(_p2_open_parts | while read -r _p; do [ "$(_p2_proto "$_p")" = 2 ] && echo "$_p"; done | sort -n | tail -1)
    if [ -z "$_bsn" ]; then echo ok; else
      set -- $(_p2_budget "$_bsn")
      case "$1" in over) echo "over part=$_bsn minutes=$2 replan=$3" ;; paused) echo "paused live=$2" ;; *) echo ok ;; esac
    fi
    ;;

  known-reds)
    # known-reds <sid> <root> key <report>    -> bare 16-hex key (the FULL-SUITE env= value)
    # known-reds <sid> <root> diff <report>   -> bare count of new reds (-1 = invalid run)
    # known-reds <sid> <root> record <report> -> write/merge the baseline keyed by sha + command + env
    case "${4:-}" in
      key) [ -f "${5:-}" ] && _p2_kr_key "$5" ;;
      diff) _p2_kr_diff "$root" "${5:-}" ;;
      record) if _p2_kr_record "$root" "${5:-}"; then echo "mission-write: known-reds ok"
              else _mw_emit_refuse known-reds 1 "REFUSED: not a completed run without infra failures (never baselined)"; fi ;;
      *) echo "mission-write: usage: known-reds <sid> <root> <key|diff|record> <report>" ;;
    esac
    ;;

  ""|help|-h|--help)
    echo "mission-write: usage: mission-write.sh <create|log|note|challenge|pending|pending-stop|resolve|rebaseline|render-banner|timing-resume|timing-contact|timing-close|archive-close|await|bank-review|budget-state|known-reds|await-state|cursor-hash> <sid> <root> [args...]"
    ;;

  *)
    echo "mission-write: usage: unknown verb '$verb' (want create|log|note|challenge|pending|pending-stop|resolve|rebaseline|render-banner|timing-resume|timing-contact|timing-close|archive-close|await|bank-review|budget-state|part-state|mission-proto|known-reds|await-state|cursor-hash)"
    ;;
esac

# #1 PRIORITY: never abort the caller — always succeed regardless of lib rc.
exit 0
