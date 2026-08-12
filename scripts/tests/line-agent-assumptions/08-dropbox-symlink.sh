#!/usr/bin/env bash
# 08 — Does a SYMLINK planted in the reply dropbox get read and printed?
#
# ~/claude-agent-replies/ is world-writable-by-the-user by design: any window drops a file there for
# any other. So any local process can also drop a SYMLINK named `<victim-session-id>--from-x.md`
# pointing at something the victim would never print — an .env, a credentials file, a transcript. The
# trap is that `Path.is_file()` and `Path.read_bytes()` both FOLLOW links, so the naive
# implementation calls the link a regular file and prints the target's contents straight into the
# reading agent's context. No error, no crash: an exfiltration that looks like a normal inbox read.
#
# Two defenses, both asserted, because either alone leaves a hole:
#   listing — is_symlink() is tested BEFORE is_file(), so a link is never classified as a file
#   reading — _capped() opens with O_NOFOLLOW, so even a link that reached the read path is refused
#
# A1 — the symlink's TARGET content never appears in the output
# A2 — the link is reported, not silently ignored (a silent skip hides an attack in progress)
# A3 — O_NOFOLLOW holds independently: a link that IS handed to the reader is refused, proving the
#      defense is not resting on the listing filter alone
# A4 — POSITIVE CONTROL: a legitimate reply file sitting in the same dropbox IS still read, so
#      "target not printed" cannot be satisfied by a broken command that prints nothing
#
# NEGATIVE CONTROL (LINE_AGENT_NEG_CONTROL=true): copy the script, drop O_NOFOLLOW and make the
# listing treat links as files, then re-run. A1 must go RED — the secret gets printed.
set -uo pipefail

GATE="${LINE_AGENT_TESTS_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set LINE_AGENT_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }

REAL_SCRIPT="$HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
[ -f "$REAL_SCRIPT" ] || { echo "INFRA: script not found: $REAL_SCRIPT" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 missing" >&2; exit 3; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER="lac-atest"
RUN_ID="$(python3 -c 'import uuid;print(uuid.uuid4().hex[:12])')"
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${MARKER}-*" -mmin +60 -exec rm -rf {} + 2>/dev/null

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/${MARKER}-${RUN_ID}-XXXXXX")"
FAKE_HOME="$ROOT/home"
cleanup() { rm -rf "$ROOT" 2>/dev/null || echo "CLEANUP WARNING: could not remove $ROOT" >&2; }
trap cleanup EXIT
mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/claude-agent-replies"

SCRIPT="$REAL_SCRIPT"
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  SCRIPT="$ROOT/regressed.py"
  cp "$REAL_SCRIPT" "$SCRIPT"
  python3 - "$SCRIPT" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# 1. drop O_NOFOLLOW from the bounded reader
s = s.replace(
    "        flags = os.O_RDONLY | (os.O_NOFOLLOW if nofollow else 0)",
    "        flags = os.O_RDONLY  # NEG CONTROL: nofollow removed")
# 2. let the listing classify a symlink as a readable file again
s = s.replace(
    "    files = [p for p in candidates if not p.is_symlink() and p.is_file()]",
    "    files = [p for p in candidates if p.is_file()]  # NEG CONTROL")
open(p, "w").write(s)
PY
  grep -q 'NEG CONTROL: nofollow removed' "$SCRIPT" \
    || { echo "INFRA: neg-control patch did not apply - _capped() moved" >&2; exit 3; }
fi

SID="00000000-0000-4000-8000-${RUN_ID}"
DROP="$FAKE_HOME/claude-agent-replies"
SECRET_FILE="$ROOT/not-for-you.txt"
printf 'CANARY_SECRET_THAT_MUST_NOT_BE_PRINTED\n' > "$SECRET_FILE"

ln -s "$SECRET_FILE" "$DROP/${SID}--from-attacker.md" \
  || { echo "INFRA: cannot create the symlink fixture" >&2; exit 3; }
printf 'an ordinary reply\nCANARY_LEGITIMATE\n' > "$DROP/${SID}--from-colleague.md"

# Sanity: the fixture must actually BE a link that resolves, or A1 proves nothing.
[ -L "$DROP/${SID}--from-attacker.md" ] || { echo "INFRA: fixture is not a symlink" >&2; exit 3; }
[ -r "$DROP/${SID}--from-attacker.md" ] || { echo "INFRA: symlink target is not readable - A1 would pass vacuously" >&2; exit 3; }

OUT="$(HOME="$FAKE_HOME" CLAUDE_SESSION_ID="$SID" python3 "$SCRIPT" replies 2>&1)"

FAIL_N=0
FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }

# --- A1 — the target's contents must not appear --------------------------------------------------
case "$OUT" in
  *CANARY_SECRET_THAT_MUST_NOT_BE_PRINTED*)
    fail "A1 the symlink was followed - the target file's contents were printed" ;;
esac

# --- A2 — the link is NAMED, not silently swallowed ----------------------------------------------
case "$OUT" in
  *SYMLINK*) ;;
  *) fail "A2 the planted symlink was skipped silently - an attack in progress went unreported" ;;
esac

# --- A3 — O_NOFOLLOW holds on its own -------------------------------------------------------------
# The listing filter is the first line of defense; this exercises the SECOND one directly, by handing
# the link to the reader. Without it, a future refactor of the listing silently removes both.
A3="$(HOME="$FAKE_HOME" python3 - "$SCRIPT" "$DROP/${SID}--from-attacker.md" <<'PY'
import importlib.util, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("lac", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print(m._capped(Path(sys.argv[2]), 4000))
PY
)"
case "$A3" in
  *CANARY_SECRET_THAT_MUST_NOT_BE_PRINTED*)
    fail "A3 _capped() followed a symlink - O_NOFOLLOW is not in force" ;;
esac

# --- A4 — positive control ------------------------------------------------------------------------
case "$OUT" in
  *CANARY_LEGITIMATE*) ;;
  *) fail "A4 positive control: the legitimate reply was not read either - the command is broken, not safe" ;;
esac

# --- verdict ------------------------------------------------------------------------------------
if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  if [ "$FAIL_N" -gt 0 ]; then
    echo "NEG-CONTROL OK: with the symlink defenses removed, the assertions went RED (${FAIL_N} failed)"
    printf '%s' "$FAIL_MSGS"
    exit 0
  fi
  echo "NEG-CONTROL BROKEN: assertions stayed GREEN with O_NOFOLLOW and the listing filter removed" >&2
  exit 1
fi

if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 08-dropbox-symlink" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi

cat > "${HERE}/08-dropbox-symlink.fingerprint.json" <<EOF
{"assumption":"dropbox_symlinks_are_refused_not_followed","uname":"$(uname -s)","defenses":"listing_is_symlink_first + O_NOFOLLOW","assertions":4}
EOF

echo "PASS: 08-dropbox-symlink - 4 assertions (A1 no target leak, A2 link reported, A3 O_NOFOLLOW direct, A4 positive control)"
exit 0
