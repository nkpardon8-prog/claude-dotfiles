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
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] part=[0-9]+ name=[A-Za-z0-9_.:-]+ phase=(research|plan|implement|review|fix) round=[0-9]+ dry=[0-2]( findings=[0-9]+)?$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-round-shape"
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
    "FAIL "*)
      printf '%s' "$_vl_entry" | grep -qE '^\[mission\] FAIL part=[0-9]+ phase=[a-z-]+ reason=[a-z0-9-]+ attempt=[0-9]+$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-fail-shape"
      printf '%s' "$_vl_bare" | grep -qE '^m[0-9]+-fail-([a-z0-9-]+-[0-9]+|panel3x-r[0-9]+)$' \
        || _mw_emit_refuse log 1 "REFUSED: bad-fail-idtag"
      _en=$(_mw_efield "$_vl_entry" part); _in=$(printf '%s' "$_vl_bare" | sed -n 's/^m\([0-9]*\)-fail-.*/\1/p')
      [ "$_en" = "$_in" ] || _mw_emit_refuse log 1 "REFUSED: idtag-entry-field-mismatch (fail)"
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

# I6: light root-escape guard (defense-in-depth; root is trusted-caller-supplied). Refuse an
# empty root or one containing `..` traversal. NEVER abort the caller — print a status line and
# exit 0. The normal absolute-path case (no `..`) is unaffected. Only enforced for verbs that
# actually take a <root> arg (i.e. not the help/usage paths, which have no root).
case "$verb" in
  create|log|note|challenge|pending|pending-stop|resolve|rebaseline|render-banner|timing-resume|timing-contact|timing-close|archive-close|await)
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
    # per-shape grammar/control-char/length validation (prints + exits on refusal), then the
    # PART-DONE preconditions (dedup-first, gen-sliced, freshness-ordered, dry-count fold, tree-drift).
    _mw_validate_log "$4" "${5:-}" "$sid" "$root"
    _mw_partdone_check "$4" "${5:-}" "$sid" "$root"
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
        14) _mw_psreason="ORPHAN barrier (lost pd line / already has a DECISION) — resolve/deny it explicitly; do NOT re-open/retry" ;;
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
    mission_await_append "$sid" "$root" "$4"
    rc=$?
    _mw_outcome_status await "$rc"
    ;;

  ""|help|-h|--help)
    echo "mission-write: usage: mission-write.sh <create|log|note|challenge|pending|pending-stop|resolve|rebaseline|render-banner|timing-resume|timing-contact|timing-close|archive-close|await|await-state|cursor-hash> <sid> <root> [args...]"
    ;;

  *)
    echo "mission-write: usage: unknown verb '$verb' (want create|log|note|challenge|pending|pending-stop|resolve|rebaseline|render-banner|timing-resume|timing-contact|timing-close|archive-close|await|await-state|cursor-hash)"
    ;;
esac

# #1 PRIORITY: never abort the caller — always succeed regardless of lib rc.
exit 0
