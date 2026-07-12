#!/bin/bash
# codex-exec.sh — the ONE house wrapper for diff-as-text / prompt-file Codex passes.
#
# WHY A THIRD WRAPPER (deliberate — do not consolidate): the existing
# god-review/lib/codex-invoke.sh and ui-audit/lib/codex-invoke.sh pin xhigh effort, thread
# CODEX_HOME accounts, and write "[unavailable]" INLINE into the output file — load-bearing
# contracts for those subsystems. THIS wrapper has a different contract: unpinned effort
# (the config's `max` is authoritative), a SEPARATE machine-readable `.status` sidecar
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

# NEWEST-MODEL drift-guard: the config was deliberately UNPINNED live on 2026-07-12 so the CLI
# default tracks the newest model on every Codex release. A re-added pin silently strands every
# consumer on an old model — warn LOUDLY (do not auto-edit the user's config).
if grep -Eq '^model *=' "$HOME/.codex/config.toml" 2>/dev/null; then
  echo "codex-exec: WARNING — ~/.codex/config.toml pins 'model=' again; policy (2026-07-12) is UNPINNED so the CLI tracks the newest model. Remove the pin." >&2
fi

# ONE effort contract: no override by default; env may only raise.
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
