#!/bin/bash
# 03-concurrent-claim.sh — does the flock + link design actually serialize N real processes?
#
# This is the probe the plan's own Confidence section named as the one thing that cannot be settled by
# reading: a test that must GENUINELY race rather than simulate a race. Reviewers pointed out that a
# sequential Popen pair never races at all — ~30-50ms of interpreter startup means the second process
# arrives after the first finished its whole critical section. So every claimant here blocks on a
# shared BARRIER file and is released together.
#
# It exercises the DESIGN (flock + unlink-if-ours + link + read-back) against a temp HOME, before the
# gate is modified. If the design cannot serialize here, implementing it in the gate is wasted work.
#
# NEGATIVE CONTROL: the same race WITHOUT the flock must produce more than one winner.
set -uo pipefail
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/raceprobe.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

run_race() {  # $1 = use_flock (1|0), $2 = claimants -> prints "winners=N|survivor=SID|records=N"
python3 - "$TMP" "$1" "$2" <<'PY'
import fcntl, json, os, secrets, subprocess, sys, time
tmp, use_flock, n = sys.argv[1], sys.argv[2] == "1", int(sys.argv[3])
run = os.path.join(tmp, f"race{'F' if use_flock else 'N'}")
os.makedirs(run, exist_ok=True)
LOCK, MUTEX, BARRIER = os.path.join(run, "prod.lock"), os.path.join(run, "prod.lock.mx"), os.path.join(run, "go")
open(MUTEX, "w").close()

child = r'''
import fcntl, json, os, secrets, sys, time
LOCK, MUTEX, BARRIER, sid, use_flock = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "1"
while not os.path.exists(BARRIER):        # all claimants released together
    time.sleep(0.001)
def read():
    try:
        with open(LOCK) as fh: return json.load(fh)
    except Exception: return None
fd = None
try:
    if use_flock:
        fd = os.open(MUTEX, os.O_CREAT | os.O_RDWR, 0o600)
        deadline = time.time() + 5.0
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); break
            except OSError:
                if time.time() >= deadline: sys.exit(3)
                time.sleep(0.005)
    cur = read()
    if cur is not None:                    # a live foreign holder -> block, exactly like the gate
        sys.exit(2)
    rec = {"sid": sid, "op": "gcloud run deploy summit-api", "ts": int(time.time())}
    temp = f"{LOCK}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    f = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(f, "w") as s:
        json.dump(rec, s, separators=(",", ":")); s.flush(); os.fsync(s.fileno())
    try:
        os.link(temp, LOCK)
    except FileExistsError:
        os.unlink(temp); sys.exit(2)       # lost the link race -> block
    os.unlink(temp)
    if read() != rec: sys.exit(2)          # read-back: not ours -> block
    sys.exit(0)                            # WON
finally:
    if fd is not None:
        try: os.close(fd)
        except Exception: pass
'''
procs = [subprocess.Popen([sys.executable, "-c", child, LOCK, MUTEX, BARRIER, f"SID-{i}",
                           "1" if use_flock else "0"]) for i in range(n)]
time.sleep(0.6)                            # let every claimant reach the barrier
open(BARRIER, "w").close()
rcs = [p.wait(timeout=30) for p in procs]
winners = sum(1 for r in rcs if r == 0)
try:
    with open(LOCK) as fh: survivor = json.load(fh).get("sid")
except Exception:
    survivor = None
print(f"winners={winners}|survivor={survivor}")
PY
}

# ── C1: WITH the flock, exactly one of 8 simultaneous claimants wins ────────────────────────
res=$(run_race 1 8)
w=${res#winners=}; w=${w%%|*}; s=${res#*survivor=}
if [ "$w" = "1" ] && [ -n "$s" ] && [ "$s" != "None" ]; then
  ok "C1 8 barrier-released claimants under flock: exactly 1 winner, survivor=$s"
else
  bad "C1 flock did NOT serialize 8 real claimants (got: $res)"
fi

# ── C2: the surviving record belongs to the winner (not a loser's overwrite) ────────────────
# Re-run and confirm the invariant holds across repeats, not once by luck.
allgood=1
for i in 1 2 3; do
  r=$(run_race 1 6); ww=${r#winners=}; ww=${ww%%|*}
  [ "$ww" = "1" ] || { allgood=0; bad "C2 repeat $i: winners=$ww (expected 1) — $r"; }
done
[ "$allgood" = "1" ] && ok "C2 invariant holds across 3 repeats of 6 claimants (1 winner each)"

# ── C1-neg: WITHOUT the flock the same race must produce MORE THAN ONE winner ───────────────
# If this does not go red, C1 proves nothing — the race may simply not be tight enough to matter.
neg=$(run_race 0 8)
nw=${neg#winners=}; nw=${nw%%|*}
if [ "$nw" -gt 1 ] 2>/dev/null; then
  ok "C1-neg without the flock, $nw claimants won simultaneously (probe can go red)"
else
  bad "C1-neg NEGATIVE CONTROL DID NOT GO RED (winners=$nw) — C1 may pass for the wrong reason"
fi

printf '\nTALLY: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
