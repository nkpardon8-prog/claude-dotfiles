#!/usr/bin/env bash
# 02 — Does THE SCRIPT's identity comparison survive the environment, and does it still discriminate?
#
# The registry pins a window's identity with two start-time facts: `startedAt` (epoch ms) and
# `procStart` (the text of `ps -o lstart=`). Any pid-reuse defense that says "same pid AND same start
# time, therefore same window" is only as good as those two fields comparing correctly. A text field
# rendered by ps is a locale- and timezone-dependent string, so if the writer and the reader disagree
# about TZ or LC_TIME, an identical process compares UNEQUAL and every live window reads as a
# stranger - or, if the comparator is sloppy, everything compares EQUAL and a recycled pid
# impersonates a dead window. Both directions are silent.
#
# REWRITTEN 2026-08-12. The previous version was a standalone python REIMPLEMENTATION of the rule: it
# read the registry and did its own comparison, and never once invoked line-agent-communicator.py
# (`grep -c SCRIPT` returned 0). Reverting the real comparator to a string compare left it GREEN - it
# could not catch the single regression it existed for, which is the exact failure its own sibling 05
# warns about at the top of its A1: "Ask the script itself, never a bash reimplementation." This file
# now asks the script.
#
# A1 — ANTI-SELF-DoS INVARIANT (the one that matters): `list --json` under four different TZ/LC_TIME
#      environments must report the SAME set of sessionIds, and that set must be NON-EMPTY. A
#      comparator whose verdict moves with the environment is not an identity key, and the way that
#      failure presents is an empty directory - so "identical" and "non-empty" are asserted together.
# A2 — DISCRIMINATION: an entry whose recorded start time is shifted by an hour must be reported with
#      identity="mismatch", while the untouched entry for the SAME live process is "verified". Without
#      this, a comparator that always returned true would sail through A1.
# A3 — the mismatch entry is still LISTED (not dropped). Refusing to name it is right; deleting it
#      from the directory would hide a recycled pid instead of reporting it.
#
# Everything runs against a THROWAWAY $HOME seeded with a COPY of the real registry, so the pids are
# real live processes (the question is about data the harness actually wrote) while the test writes
# nothing whatsoever under the real $HOME - `list` calls sync_contacts, which writes.
#
# NEGATIVE CONTROL: LINE_AGENT_NEG_CONTROL=true inverts A2 - it demands that the hour-shifted entry
# be reported "verified", which a working comparator cannot do. A harness that reports OK there is
# not wired to anything.
set -uo pipefail

GATE="${LINE_AGENT_TESTS_ALLOW_DEV:-}"
[ "$GATE" = "true" ] || { echo "REFUSED: set LINE_AGENT_TESTS_ALLOW_DEV=true to run" >&2; exit 2; }

SCRIPT="$HOME/.claude-dotfiles/scripts/line-agent-communicator.py"
[ -f "$SCRIPT" ] || { echo "INFRA: script not found: $SCRIPT" >&2; exit 3; }
command -v python3 >/dev/null 2>&1 || { echo "INFRA: python3 missing" >&2; exit 3; }
PY="$(command -v python3)"
REAL_SESSIONS="$HOME/.claude/sessions"
[ -d "$REAL_SESSIONS" ] || { echo "INFRA: no real registry at $REAL_SESSIONS" >&2; exit 3; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARKER="lac-atest"                       # stable namespace marker, for the orphan reaper
RUN_ID="$($PY -c 'import uuid;print(uuid.uuid4().hex[:12])')"

# --- startup orphan reaper: `finally` does not survive SIGKILL, so reap prior crashed runs -------
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${MARKER}-*" -mmin +60 -exec rm -rf {} + 2>/dev/null

WORK="$(mktemp -d "${TMPDIR:-/tmp}/${MARKER}-${RUN_ID}-XXXXXX")"
cleanup() { rm -rf "$WORK" 2>/dev/null || echo "CLEANUP WARNING: could not remove $WORK" >&2; }
trap cleanup EXIT

FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME/.claude/sessions" "$FAKE_HOME/.claude/session-status"
cp "$REAL_SESSIONS"/*.json "$FAKE_HOME/.claude/sessions/" 2>/dev/null
cp "$HOME/.claude/session-status"/*.txt "$FAKE_HOME/.claude/session-status/" 2>/dev/null

# Counter + string, NOT a bash array: this repo runs on macOS bash 3.2, where `${#arr[@]}` on an
# EMPTY array under `set -u` aborts with "unbound variable" — i.e. the all-assertions-passed path is
# exactly the one that would crash. Same class of bash-3.2 trap the sibling run-all.sh documents.
FAIL_N=0
FAIL_MSGS=""
fail() { FAIL_N=$((FAIL_N + 1)); FAIL_MSGS="${FAIL_MSGS}  - $1
"; }

# --- the probe: THE REAL SCRIPT, four times, four environments -----------------------------------
# Bash compares the four outputs - the environment sensitivity IS the assertion, so the comparison
# has to happen across processes, not inside one.
run_list() {  # $1 = tag, rest = env assignments
  local tag="$1"; shift
  env HOME="$FAKE_HOME" "$@" "$PY" "$SCRIPT" list --json > "$WORK/$tag.json" 2>"$WORK/$tag.err"
  echo $? > "$WORK/$tag.rc"
}

sids_of() {  # sorted sessionIds from one --json capture, one per line
  "$PY" - "$1" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("PARSE-ERROR %s" % e.__class__.__name__)
    raise SystemExit(0)
for s in sorted(r.get("sessionId", "") for r in d.get("live", [])):
    print(s)
PY
}

# The ambient run inherits the caller's real TZ/LC_TIME - hardcoding the author's zone here would
# make the test agree with itself instead of with the machine it runs on.
run_list local
LOCAL_RC="$(cat "$WORK/local.rc")"
[ "$LOCAL_RC" = "0" ] || {
  echo "INFRA: \`list --json\` exited ${LOCAL_RC}; stderr: $(head -3 "$WORK/local.err")" >&2; exit 3; }

run_list utc      TZ=UTC
run_list la       TZ=America/Los_Angeles
run_list lc_c     LC_TIME=C
run_list lc_enus  LC_TIME=en_US.UTF-8

for t in utc la lc_c lc_enus; do
  sids_of "$WORK/$t.json" > "$WORK/$t.sids"
done

N_UTC="$(wc -l < "$WORK/utc.sids" | tr -d ' ')"
echo "observed via \`$SCRIPT list --json\` on a copy of the real registry:"
echo "  TZ=UTC                 -> $(cat "$WORK/utc.rc") exit, ${N_UTC} session(s)"
echo "  TZ=America/Los_Angeles -> $(cat "$WORK/la.rc") exit, $(wc -l < "$WORK/la.sids" | tr -d ' ') session(s)"
echo "  LC_TIME=C              -> $(cat "$WORK/lc_c.rc") exit, $(wc -l < "$WORK/lc_c.sids" | tr -d ' ') session(s)"
echo "  LC_TIME=en_US.UTF-8    -> $(cat "$WORK/lc_enus.rc") exit, $(wc -l < "$WORK/lc_enus.sids" | tr -d ' ') session(s)"

# --- A1 — same set of windows, non-empty, under every environment ---------------------------------
if [ "$N_UTC" -lt 1 ]; then
  fail "A1 the script listed ZERO live windows from a copy of the real registry - the self-DoS this test exists to catch"
fi
for t in la lc_c lc_enus; do
  if ! diff -q "$WORK/utc.sids" "$WORK/$t.sids" >/dev/null 2>&1; then
    fail "A1 the listed window set is NOT environment-invariant (TZ=UTC vs ${t}): $(diff "$WORK/utc.sids" "$WORK/$t.sids" | head -4 | tr '\n' ' ')"
  fi
  [ "$(cat "$WORK/$t.rc")" = "0" ] || fail "A1 \`list --json\` exited $(cat "$WORK/$t.rc") under ${t}"
done

# --- A2/A3 — discrimination, asked of THE SCRIPT --------------------------------------------------
# Two entries for the SAME live pid in a second throwaway home: one copied verbatim (must verify),
# one with BOTH recorded start times shifted an hour (must NOT verify). An hour, not a minute: it has
# to clear the comparator's 120s tolerance by a wide margin, or a passing A2 would only prove the
# tolerance is small, not that a comparison happens at all.
DISC_HOME="$WORK/disc-home"
mkdir -p "$DISC_HOME/.claude/sessions" "$DISC_HOME/.claude/session-status"
"$PY" - "$FAKE_HOME" "$DISC_HOME" <<'PY' > "$WORK/disc.setup" 2>"$WORK/disc.err"
import calendar, glob, json, os, subprocess, sys, time
src, dst = sys.argv[1], sys.argv[2]
out = os.path.join(dst, ".claude", "sessions")
picked = None
for f in sorted(glob.glob(os.path.join(src, ".claude", "sessions", "*.json"))):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    pid = d.get("pid")
    if not isinstance(pid, int) or not pid:
        continue
    r = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
    if r.returncode != 0 or "claude" not in r.stdout.lower():
        continue
    if not isinstance(d.get("startedAt"), int) or not str(d.get("procStart") or "").strip():
        continue
    picked = d
    break
if picked is None:
    print("NONE")
    raise SystemExit(0)

good = dict(picked)
good["sessionId"] = "00000000-0000-4000-8000-aaaaaaaaaaaa"
good["name"] = "atest-good"
good["nameSource"] = "explicit"
json.dump(good, open(os.path.join(out, "%d.json" % good["pid"]), "w"), separators=(",", ":"))

bad = dict(picked)
bad["sessionId"] = "00000000-0000-4000-8000-bbbbbbbbbbbb"
bad["name"] = "atest-shifted"
bad["nameSource"] = "explicit"
bad["startedAt"] = int(picked["startedAt"]) - 3600 * 1000
t = time.strptime(" ".join(str(picked["procStart"]).split()), "%a %b %d %H:%M:%S %Y")
bad["procStart"] = time.strftime("%a %b %d %H:%M:%S %Y",
                                 time.gmtime(calendar.timegm(t) - 3600))
# A second file for the same pid: the registry keys files by pid, so the shifted twin needs its own
# name. `list` reads every *.json, so both are enumerated.
json.dump(bad, open(os.path.join(out, "%d-shifted.json" % bad["pid"]), "w"), separators=(",", ":"))
print("OK pid=%d" % picked["pid"])
PY
DISC_SETUP="$(cat "$WORK/disc.setup" 2>/dev/null)"
case "$DISC_SETUP" in
  OK*) : ;;
  *) echo "INFRA: could not build the discrimination fixture (${DISC_SETUP:-empty}); stderr: $(head -3 "$WORK/disc.err")" >&2; exit 3 ;;
esac
echo "discrimination fixture: ${DISC_SETUP} (one verbatim entry + one shifted by 1h, same live pid)"

HOME="$DISC_HOME" "$PY" "$SCRIPT" list --json > "$WORK/disc.json" 2>"$WORK/disc.list.err"
DISC_RC=$?
[ "$DISC_RC" = "0" ] || { echo "INFRA: discrimination \`list --json\` exited ${DISC_RC}: $(head -3 "$WORK/disc.list.err")" >&2; exit 3; }

read_identity() {  # $1 = window name -> its identity string, or "ABSENT"
  "$PY" - "$WORK/disc.json" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for r in d.get("live", []):
    if r.get("name") == sys.argv[2]:
        print(r.get("identity", ""))
        break
else:
    print("ABSENT")
PY
}
ID_GOOD="$(read_identity atest-good)"
ID_BAD="$(read_identity atest-shifted)"
echo "  verbatim entry -> identity=${ID_GOOD}   |   hour-shifted entry -> identity=${ID_BAD}"

if [ "${LINE_AGENT_NEG_CONTROL:-}" = "true" ]; then
  # Inverted: demand that the hour-shifted entry be reported "verified". It cannot be, so a working
  # harness must go RED here. If this reports OK, the comparator is not comparing.
  if [ "$ID_BAD" = "verified" ]; then
    echo "NEG-CONTROL BROKEN: an hour-shifted start time was still reported verified" >&2
    exit 1
  fi
  echo "NEG-CONTROL OK: the script reported identity='${ID_BAD}' for the shifted entry, so A2 really discriminates"
  exit 0
fi

[ "$ID_GOOD" = "verified" ] || \
  fail "A2 the script did NOT verify an entry copied verbatim from the live registry (identity='${ID_GOOD}') - a string-compare regression looks exactly like this"
[ "$ID_BAD" = "mismatch" ] || \
  fail "A2 an entry whose start time is shifted by an HOUR was reported identity='${ID_BAD}', not 'mismatch' - the comparator is not discriminating"
[ "$ID_BAD" != "ABSENT" ] || \
  fail "A3 the mismatched entry was dropped from the directory instead of being listed and marked"

# --- verdict --------------------------------------------------------------------------------------
if [ "$FAIL_N" -gt 0 ]; then
  echo "FAIL: 02-starttime-comparison" >&2
  printf '%s' "$FAIL_MSGS" >&2
  exit 1
fi

cat > "${HERE}/02-starttime-comparison.fingerprint.json" <<EOF
{"assumption":"script_identity_comparison_is_env_invariant_and_discriminating","uname":"$(uname -s)","os_version":"$(sw_vers -productVersion 2>/dev/null || echo unknown)","driver":"line-agent-communicator.py list --json","live_windows_listed":${N_UTC},"env_invariant_session_set":true,"identity_verbatim_entry":"${ID_GOOD}","identity_hour_shifted_entry":"${ID_BAD}"}
EOF

echo "PASS: 02-starttime-comparison - 3 assertions (A1 same non-empty window set under 4 TZ/LC_TIME envs, A2 verbatim=verified + shifted=mismatch, A3 mismatch still listed)"
exit 0
