#!/bin/bash
# codex-exec.sh — the ONE house wrapper for diff-as-text / prompt-file Codex passes.
#
# WHY A THIRD WRAPPER (deliberate — do not consolidate): the existing
# commands/god-review/lib/codex-invoke.sh and commands/ui-audit/lib/codex-invoke.sh each HARDCODE
# their own effort on the argv, thread CODEX_HOME accounts, and write "[unavailable]" INLINE into
# the output file — load-bearing contracts for those subsystems. (They do NOT pin the same value as
# each other; read each file rather than trusting this comment for a value.) THIS wrapper has a
# different contract: effort comes from the CALLER when it sets one, else from `~/.codex/config.toml`
# — the wrapper never hardcodes a value and never asserts what the config currently says. (It said
# `max` here until 2026-08-17; it was `high`, and codex-review.md cited this header as its authority,
# so the wrong value propagated. Then on 2026-08-17 this same header was found asserting that BOTH
# sibling wrappers pin xhigh — god-review does, ui-audit pins high — i.e. the fix reintroduced the
# exact bug it removed, one line up. State the MECHANISM, never the value; a header that names a
# value in ANOTHER file is drift waiting to happen.) Plus a SEPARATE machine-readable `.status` sidecar
# (the output file stays pure model output), and a portable process-group timeout.
#
# Usage: codex-exec.sh <promptfile> <outfile> [workdir]
#   stdin is ALWAYS the prompt file (`- < promptfile`) — bare-stdin codex exec hangs (proven).
#   Env: CODEX_EFFORT   optional; low|medium are RAISED to xhigh; high|xhigh|max pass through;
#                       unset = NO override (config `model_reasoning_effort` is authoritative).
#        CODEX_TIMEOUT_SECS  default 1800 (max-effort passes have taken 5-25 min).
#
# Writes (atomic .tmp -> mv):
#   <outfile>          full codex stdout+stderr
#   <outfile>.status   invocation outcome ONLY: ok | timeout | unavailable | nonzero-<rc>
#                      (.status says "the process ran"; it does NOT judge review quality.
#                       The USABILITY verdict — `.usable` — is owned EXCLUSIVELY by
#                       codex-review.md Step 3c, which combines .status=ok with its
#                       verdict-regex. Single owner per artifact; do not write .usable here.)
# Exit code mirrors the codex process (124 timeout, 127 missing binary), but callers should
# read .status — this wrapper never masks the outcome.

set -u
PROMPT="${1:?usage: codex-exec.sh <promptfile> <outfile> [workdir]}"
OUT="${2:?usage: codex-exec.sh <promptfile> <outfile> [workdir]}"
WORKDIR="${3:-$(pwd)}"

. "$HOME/.claude-dotfiles/scripts/lib/portable-timeout.sh"

_status() {  # _status <token> — atomic sidecar write
  printf '%s\n' "$1" > "$OUT.status.tmp" && mv -f "$OUT.status.tmp" "$OUT.status"
}

[ -f "$PROMPT" ] || { echo "codex-exec: prompt file not found: $PROMPT" >&2; _status unavailable; exit 127; }
command -v codex >/dev/null 2>&1 || { echo "codex-exec: codex CLI not on PATH" >&2; _status unavailable; exit 127; }

# MODEL PIN: allowed, deliberately. The 2026-07-12 never-pin policy was REVERSED by the owner on
# 2026-08-17 ("it just has the models I want") — the config names the model the owner wants and this
# wrapper does not second-guess it. The drift-guard that used to live here is GONE on purpose: it
# fired on EVERY invocation for weeks against a config the owner intended, so it taught readers to
# ignore wrapper stderr, which is worse than having no guard at all. A warning nobody reads is not a
# safety feature. Do not re-add it without a new owner ruling.

# ONE effort contract: the CALLER sets its lane's effort; unset = the config value is used as-is.
# Review lanes pass CODEX_EFFORT explicitly (codex-review.md, mission.md, plan.md, prepare-pr.md) —
# before 2026-08-17 nothing anywhere set this variable, so the branch below was dead code and every
# pass silently took the config value.
EFFORT_ARGS=()
if [ -n "${CODEX_EFFORT:-}" ]; then
  case "$CODEX_EFFORT" in
    low|medium) EFFORT_ARGS=(-c "model_reasoning_effort=xhigh") ;;   # raised — never run a review lens below xhigh
    high|xhigh|max) EFFORT_ARGS=(-c "model_reasoning_effort=$CODEX_EFFORT") ;;
    *) echo "codex-exec: ignoring unknown CODEX_EFFORT='$CODEX_EFFORT' (config stays authoritative)" >&2 ;;
  esac
fi

TIMEOUT="${CODEX_TIMEOUT_SECS:-1800}"
# ${arr[@]+...} guard: macOS ships bash 3.2, where an EMPTY array under `set -u` is an
# "unbound variable" error (caught live by the 6a timeout fixture).
pt_run "$TIMEOUT" codex exec ${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"} -s read-only --ephemeral -C "$WORKDIR" - < "$PROMPT" > "$OUT.tmp" 2>&1
rc=$?
mv -f "$OUT.tmp" "$OUT"

case "$rc" in
  0)   _status ok ;;
  124) _status timeout ;;
  127) _status unavailable ;;
  *)   _status "nonzero-$rc" ;;
esac
exit "$rc"
