#!/bin/bash
# codex-vision.sh — the house wrapper for IMAGE-attached Codex passes (screenshot analysis).
#
# WHY A SIBLING OF codex-exec.sh (deliberate — do not consolidate): codex-exec.sh runs
# `--ephemeral` with NO `-i`, so it cannot attach images at all. This wrapper has a different
# invocation contract that was established by smoke test, not by reading docs:
#
#   1. `-i, --image <FILE>...` is VARIADIC. A positional prompt after it is SWALLOWED as another
#      image path, and codex then dies with "No prompt provided via stdin". The prompt therefore
#      MUST arrive on stdin via the explicit `-` positional. This cost a lane on 2026-09-02.
#   2. Each image gets its OWN `-i` flag. Repeating the flag appends; it also keeps the trailing
#      `-` from being greedily eaten by the variadic list.
#   3. `--skip-git-repo-check` is REQUIRED. Codex refuses to run in a non-git directory
#      ("Not inside a trusted directory and --skip-git-repo-check was not specified") — this cost
#      a second lane the same day. `--ephemeral` is deliberately NOT used here: it was not part of
#      the proven form, and this wrapper ships only what was actually smoke-tested.
#
# Effort contract is IDENTICAL to codex-exec.sh: the CALLER sets CODEX_EFFORT for its lane; unset
# means `~/.codex/config.toml` is authoritative. This wrapper never hardcodes an effort or a model,
# and never asserts what the config currently says (stating a value in a comment is how the sibling
# wrapper's header went stale twice — state the MECHANISM, never the value).
#
# Usage: codex-vision.sh <promptfile> <outfile> <image> [image...]
#   Env: CODEX_EFFORT          low|medium are RAISED to xhigh; high|xhigh|max pass through.
#        CODEX_TIMEOUT_SECS    default 1800.
#        CODEX_VISION_WORKDIR  optional -C workdir; default: the current directory.
#
# Writes (atomic .tmp -> mv):
#   <outfile>          full codex stdout+stderr
#   <outfile>.status   invocation outcome ONLY: ok | timeout | unavailable | nonzero-<rc>
#                      (.status says "the process ran"; it does NOT judge output quality. Do not
#                       write a `.usable` verdict here — single owner per artifact.)
# Exit code mirrors the codex process (124 timeout, 127 missing binary/bad input); callers should
# read .status — this wrapper never masks the outcome.

set -u
PROMPT="${1:?usage: codex-vision.sh <promptfile> <outfile> <image> [image...]}"
OUT="${2:?usage: codex-vision.sh <promptfile> <outfile> <image> [image...]}"
shift 2
[ "$#" -ge 1 ] || { echo "codex-vision: at least one image is required" >&2; exit 127; }

. "$HOME/.claude-dotfiles/scripts/lib/portable-timeout.sh"

_status() {  # _status <token> — atomic sidecar write
  printf '%s\n' "$1" > "$OUT.status.tmp" && mv -f "$OUT.status.tmp" "$OUT.status"
}

[ -f "$PROMPT" ] || { echo "codex-vision: prompt file not found: $PROMPT" >&2; _status unavailable; exit 127; }
command -v codex >/dev/null 2>&1 || { echo "codex-vision: codex CLI not on PATH" >&2; _status unavailable; exit 127; }

# Fail BEFORE spending a model call: a missing image is a caller bug, and codex's own error for it
# is far less legible than this one.
IMAGE_ARGS=()
for img in "$@"; do
  [ -f "$img" ] || { echo "codex-vision: image not found: $img" >&2; _status unavailable; exit 127; }
  [ -r "$img" ] || { echo "codex-vision: image not readable: $img" >&2; _status unavailable; exit 127; }
  IMAGE_ARGS+=(-i "$img")
done

EFFORT_ARGS=()
if [ -n "${CODEX_EFFORT:-}" ]; then
  case "$CODEX_EFFORT" in
    low|medium) EFFORT_ARGS=(-c "model_reasoning_effort=xhigh") ;;
    high|xhigh|max) EFFORT_ARGS=(-c "model_reasoning_effort=$CODEX_EFFORT") ;;
    *) echo "codex-vision: ignoring unknown CODEX_EFFORT='$CODEX_EFFORT' (config stays authoritative)" >&2 ;;
  esac
fi

WORKDIR="${CODEX_VISION_WORKDIR:-$(pwd)}"
TIMEOUT="${CODEX_TIMEOUT_SECS:-1800}"

# ${arr[@]+...} guard: macOS ships bash 3.2, where an EMPTY array under `set -u` is an
# "unbound variable" error. IMAGE_ARGS is never empty (guarded above) but is written the same way
# for consistency with the sibling wrapper.
pt_run "$TIMEOUT" codex exec \
  ${EFFORT_ARGS[@]+"${EFFORT_ARGS[@]}"} \
  -s read-only --skip-git-repo-check \
  -C "$WORKDIR" \
  ${IMAGE_ARGS[@]+"${IMAGE_ARGS[@]}"} \
  - < "$PROMPT" > "$OUT.tmp" 2>&1
rc=$?
mv -f "$OUT.tmp" "$OUT"

case "$rc" in
  0)   _status ok ;;
  124) _status timeout ;;
  127) _status unavailable ;;
  *)   _status "nonzero-$rc" ;;
esac
exit "$rc"
