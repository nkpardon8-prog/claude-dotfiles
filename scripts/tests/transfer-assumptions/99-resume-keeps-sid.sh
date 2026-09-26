#!/usr/bin/env bash
# 99 (A1) - `claude --resume <sid>` on a transcript copy placed under a fresh project dir keeps
# the SAME session id and loads the full history. This costs 4 real model calls (two builds, two
# resumes), so it is gated separately from the rest of the suite and is NEVER run by run-all.sh or
# by an agent on its own initiative - only a human, deliberately, with TRANSFER_LIVE_CLAUDE=1.
#
# History: an earlier version of this test hand-fabricated transcript JSON (a plain python script
# writing lines that merely LOOK like a Claude Code transcript). That is not what /transfer ships:
# a real chat produces its transcript through the real `claude` binary, and the real binary does
# not resume a fabricated one - the test failed even though the actual feature worked. This version
# builds every transcript with REAL `claude -p` sessions and only then perturbs the resulting file
# on disk, matching the two shapes /transfer's own copy step can actually hand to `--resume`:
#   A. a clean, normally-ended transcript.
#   B. a transcript cut off mid-turn - truncated right after an assistant tool_use with no
#      following tool_result, and with a half-written (no trailing newline) partial line appended,
#      the same shape a mid-write copy of a real chat can produce.
# Per the plan's Round 1 Revisions fix #3: move the ORIGINAL transcript aside first, and restore
# working on a copy under the same path (a fresh inode), so this never corrupts a real session's
# history; then resume the copy and assert the echoed session id, the JSON result, and that new
# lines actually landed in the copy.
#
# Runtime note: this makes 4 real model calls end to end and can exceed the suite's normal 120s
# budget; that budget is enforced by run-all.sh, which excludes this test entirely, so it does not
# apply here - just expect this to take longer than the rest of the suite.
set -uo pipefail

if [ "${TRANSFER_LIVE_CLAUDE:-}" != "1" ]; then
  echo "SKIP: 99-resume-keeps-sid requires TRANSFER_LIVE_CLAUDE=1 (costs 4 real model calls) - not run automatically" >&2
  exit 0
fi
[ "${TRANSFER_TESTS_ALLOW_DEV:-}" = "true" ] || { echo "REFUSED: set TRANSFER_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_common.sh"
command -v claude >/dev/null 2>&1 || { echo "INFRA: claude not on PATH" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 missing" >&2; exit 3; }

# Deliberately the REAL $HOME - this is the one test that must prove the REAL claude binary's
# behavior, not a sandboxed stand-in.
export CLAUDE_CTX_GATE_DISABLED=1

DIRS_TO_CLEAN=()
PDIRS_TO_CLEAN=()
SIDS_TO_CLEAN=()

cleanup() {
  local d p s
  for d in "${DIRS_TO_CLEAN[@]+"${DIRS_TO_CLEAN[@]}"}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  for p in "${PDIRS_TO_CLEAN[@]+"${PDIRS_TO_CLEAN[@]}"}"; do
    [ -n "$p" ] && rm -rf "$p"
  done
  for s in "${SIDS_TO_CLEAN[@]+"${SIDS_TO_CLEAN[@]}"}"; do
    [ -n "$s" ] && rm -rf "$HOME/.claude/file-history/$s" "$HOME/.claude/session-env/$s"
  done
}
trap cleanup EXIT

# json_field <field-name> - reads a JSON object from stdin, prints the named field (booleans as
# "true"/"false", missing/null as ""). Prints nothing and exits non-zero if stdin is not valid JSON.
json_field() {
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
v = d.get(sys.argv[1])
if isinstance(v, bool):
    print("true" if v else "false")
elif v is None:
    print("")
else:
    print(v)
' "$1"
}

# find_transcript_for_sid <sid> - the transcript path claude wrote for a fresh session id; sids
# are UUIDs, so a filename match anywhere under ~/.claude/projects is unambiguous.
find_transcript_for_sid() {
  find "$HOME/.claude/projects" -mindepth 2 -maxdepth 2 -name "$1.jsonl" 2>/dev/null | head -1
}

# mutate_none <file> <sid> <dir> - the clean-transcript case: no perturbation.
mutate_none() { :; }

# mutate_dangling_tool_call <file> <sid> <dir> - truncates the transcript to (and including) the
# last assistant message that contains a tool_use, dropping the tool_result and any later turns,
# then appends a partial, newline-less fragment so the file also ends on a half-written line - the
# same shape a mid-write copy of a real in-flight chat produces.
mutate_dangling_tool_call() {
  local f="$1"
  python3 - "$f" <<'PY'
import json, sys

path = sys.argv[1]
with open(path) as fh:
    lines = fh.readlines()

last_idx = None
for i, raw in enumerate(lines):
    line = raw.rstrip("\n")
    if not line:
        continue
    try:
        obj = json.loads(line)
    except ValueError:
        continue
    if obj.get("type") != "assistant":
        continue
    content = (obj.get("message") or {}).get("content")
    if isinstance(content, list) and any(
        isinstance(c, dict) and c.get("type") == "tool_use" for c in content
    ):
        last_idx = i

if last_idx is None:
    sys.exit("no assistant tool_use line found in " + path)

with open(path, "w") as fh:
    fh.writelines(lines[: last_idx + 1])
    fh.write('{"type":"user","partial')
PY
}

# run_case <label> <cwd-dir> <build-prompt> <build-extra-flag-or-empty> <mutate-fn>
run_case() {
  local label="$1" dir="$2" prompt="$3" extra="$4" mutate="$5"
  local build_out sid f pdir slug orig lines_before lines_after
  local out out_sid out_result out_is_error

  if [ -n "$extra" ]; then
    build_out=$(cd "$dir" && claude -p "$prompt" "$extra" --output-format json < /dev/null 2>"$dir/build.stderr")
  else
    build_out=$(cd "$dir" && claude -p "$prompt" --output-format json < /dev/null 2>"$dir/build.stderr")
  fi

  sid=$(printf '%s' "$build_out" | json_field session_id 2>/dev/null)
  if [ -z "$sid" ]; then
    fail "$label: could not read a session_id from the build call; stdout: $build_out; stderr: $(cat "$dir/build.stderr" 2>/dev/null)"
    return
  fi
  SIDS_TO_CLEAN+=("$sid")

  f=$(find_transcript_for_sid "$sid")
  if [ -z "$f" ] || [ ! -f "$f" ]; then
    fail "$label: no transcript file found for sid $sid"
    return
  fi

  pdir=$(dirname "$f")
  slug=$(tx_slug "$dir")
  case "$(basename "$pdir")" in
    "$slug"*)
      PDIRS_TO_CLEAN+=("$pdir")
      ;;
    *)
      fail "$label: transcript project dir ($pdir) does not match the expected slug for $dir ($slug) - refusing to schedule it for cleanup"
      return
      ;;
  esac

  orig="$dir/orig.jsonl"
  mv "$f" "$orig"        # original gone from its path
  cp -p "$orig" "$f"     # working copy, a new inode with the same content

  if ! "$mutate" "$f" "$sid" "$dir"; then
    fail "$label: transcript mutation failed for $f"
    return
  fi

  lines_before=$(wc -l < "$f" | tr -d ' ')

  out=$(cd "$dir" && claude -p --resume "$sid" 'Run this bash command and reply with its output only: echo $CLAUDE_CODE_SESSION_ID' --dangerously-skip-permissions --output-format json < /dev/null 2>"$dir/resume.stderr")

  out_sid=$(printf '%s' "$out" | json_field session_id 2>/dev/null)
  out_result=$(printf '%s' "$out" | json_field result 2>/dev/null)
  out_is_error=$(printf '%s' "$out" | json_field is_error 2>/dev/null)

  if [ -z "$out_sid" ] && [ -z "$out_result" ]; then
    fail "$label: resume call produced no parseable JSON; stdout: $out; stderr: $(cat "$dir/resume.stderr" 2>/dev/null)"
    return
  fi

  [ "$out_sid" = "$sid" ] || fail "$label: resume returned session id ($out_sid) which does not equal the resumed sid ($sid)"

  case "$out_result" in
    *"$sid"*) : ;;
    *) fail "$label: resume result did not contain the sid; result: $out_result" ;;
  esac

  [ "$out_is_error" = "false" ] || fail "$label: resume reported is_error=$out_is_error; output: $out"

  lines_after=$(wc -l < "$f" | tr -d ' ')
  [ "$lines_after" -gt "$lines_before" ] || fail "$label: no new lines landed in the transcript copy after resume ($lines_before -> $lines_after)"
}

D1=$(mktemp -d "${TMPDIR:-/tmp}/txa1.XXXX")
D1=$(cd "$D1" && pwd -P)
DIRS_TO_CLEAN+=("$D1")

D2=$(mktemp -d "${TMPDIR:-/tmp}/txa1.XXXX")
D2=$(cd "$D2" && pwd -P)
DIRS_TO_CLEAN+=("$D2")

run_case "clean transcript" "$D1" "Reply with exactly: first" "" mutate_none
run_case "dangling tool call + half-written line" "$D2" "Use the Bash tool to run: echo marker-one. Then reply done." "--dangerously-skip-permissions" mutate_dangling_tool_call

ok_report "99-resume-keeps-sid" "claude --resume kept the same sid and continued a REAL transcript for a clean shape and a dangling-tool-call/half-written-line shape"
