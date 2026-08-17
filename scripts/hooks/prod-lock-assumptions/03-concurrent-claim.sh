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

run_race() {  # $1 = use_flock (1|0), $2 = claimants, $3 = unique tag -> prints "winners=N|survivor=SID"
python3 - "$TMP" "$1" "$2" "$3" <<'PY'
import fcntl, json, os, secrets, subprocess, sys, time
tmp, use_flock, n, tag = sys.argv[1], sys.argv[2] == "1", int(sys.argv[3]), sys.argv[4]
# A FRESH directory per invocation. The first version reused one dir per flock-mode, so the lock
# from run 1 survived and every later claimant saw a live foreign holder -> winners=0 every time.
run = os.path.join(tmp, f"race-{tag}")
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
res=$(run_race 1 8 c1)
w=${res#winners=}; w=${w%%|*}; s=${res#*survivor=}
if [ "$w" = "1" ] && [ -n "$s" ] && [ "$s" != "None" ]; then
  ok "C1 8 barrier-released claimants under flock: exactly 1 winner, survivor=$s"
else
  bad "C1 flock did NOT serialize 8 real claimants (got: $res)"
fi

# ── C2: the invariant holds across repeats, not once by luck ────────────────────────────────
allgood=1
for i in 1 2 3; do
  r=$(run_race 1 6 "c2r$i"); ww=${r#winners=}; ww=${ww%%|*}
  [ "$ww" = "1" ] || { allgood=0; bad "C2 repeat $i: winners=$ww (expected 1) — $r"; }
done
[ "$allgood" = "1" ] && ok "C2 invariant holds across 3 repeats of 6 claimants (1 winner each)"

# ── C3: WITHOUT the flock, claim-vs-claim STILL yields exactly one winner ───────────────────
# FINDING, measured not assumed: os.link IS a create-exclusive CAS, so claim-vs-claim is already
# serialized by the link alone. The flock is NOT what makes concurrent CLAIM safe. Its real job is
# serializing the four DIFFERENT writers (claim / refresh / release / sweep), where one path's
# unlink can land inside another's read-decide-write. C4 below is the case that actually needs it.
neg=$(run_race 0 8 c3)
nw=${neg#winners=}; nw=${nw%%|*}
[ "$nw" = "1" ] && ok "C3 without the flock, claim-vs-claim still yields 1 winner (os.link is the CAS)" \
                || bad "C3 unexpected: link-only claim race produced winners=$nw"

# ── C4: the case the flock actually exists for — a sweeper acting on a STALE read ────────────
# The hazard is NOT "sweeper clears A, then B claims" — that is a legal serialization and a correct
# outcome. It is: the sweeper reads A and decides to unlink; A's call finishes and B claims; the
# sweeper then unlinks B's FRESH lock. B has passed its read-back and believes it holds the lock,
# while the file is gone and the next arrival will claim freely. That is two holders.
# The oracle is therefore "B linked successfully AND the lock is absent at the end", and the model
# includes the sid re-check the plan specifies, since re-verifying UNDER the lock is the fix.
c4() {  # $1 = use_flock -> prints "twoholders=N" over repeated trials
python3 - "$TMP" "$1" <<'PY'
import fcntl, json, os, secrets, sys, threading, time
tmp, use_flock = sys.argv[1], sys.argv[2] == "1"
run = os.path.join(tmp, f"c4-{'F' if use_flock else 'N'}"); os.makedirs(run, exist_ok=True)
LOCK, MUTEX = os.path.join(run, "prod.lock"), os.path.join(run, "prod.lock.mx")
open(MUTEX, "w").close()
violations = 0

def mutex():
    fd = os.open(MUTEX, os.O_CREAT | os.O_RDWR, 0o600)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd

b_linked = False

def handoff():
    """A's call ends (release unlinks A), then B claims. Both under the mutex when serialized."""
    global b_linked
    fd = mutex() if use_flock else None
    try:
        try: os.unlink(LOCK)                         # A releases
        except FileNotFoundError: pass
        rec = {"sid": "B", "op": "deploy", "ts": int(time.time())}
        temp = f"{LOCK}.{os.getpid()}.{secrets.token_hex(6)}.tmp"
        f = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(f, "w") as s: json.dump(rec, s, separators=(",", ":"))
        try:
            os.link(temp, LOCK); b_linked = True
        except FileExistsError:
            pass
        os.unlink(temp)
    finally:
        if fd is not None: os.close(fd)

def sweeper():
    """Turn-end sweep for session A. Reads FIRST (possibly stale), then acts."""
    try:
        with open(LOCK) as fh: cur = json.load(fh)
    except Exception:
        return
    if cur.get("sid") != "A":
        return                                       # not ours -> nothing to do
    time.sleep(0.001)                                # the stale-read window
    fd = mutex() if use_flock else None
    try:
        if use_flock:
            # THE FIX: re-verify UNDER the lock. Without this the stale decision is acted on.
            try:
                with open(LOCK) as fh: again = json.load(fh)
            except Exception:
                return
            if again.get("sid") != "A":
                return
        try: os.unlink(LOCK)
        except FileNotFoundError: pass
    finally:
        if fd is not None: os.close(fd)

for trial in range(80):
    b_linked = False
    try: os.unlink(LOCK)
    except FileNotFoundError: pass
    with open(LOCK, "w") as s: json.dump({"sid": "A", "op": "deploy", "ts": 1}, s)
    t2 = threading.Thread(target=sweeper); t1 = threading.Thread(target=handoff)
    t2.start(); time.sleep(0.0003); t1.start()
    t2.join(); t1.join()
    try:
        with open(LOCK) as fh: final = json.load(fh).get("sid")
    except Exception:
        final = None
    # VIOLATION: B linked and passed its read-back, but the lock is gone -> B believes it holds a
    # lock that no longer exists, and the next arrival claims freely. Two holders.
    if b_linked and final is None:
        violations += 1
print(f"violations={violations}")
PY
}
vf=$(c4 1); vn=$(c4 0)
vfn=${vf#violations=}; vnn=${vn#violations=}
if [ "$vfn" = "0" ] && [ "$vnn" -gt 0 ] 2>/dev/null; then
  ok "C4 claim-vs-sweep: $vnn violations WITHOUT the flock, 0 WITH it — this is what the flock buys"
elif [ "$vfn" = "0" ]; then
  bad "C4-neg NEGATIVE CONTROL DID NOT GO RED (unserialized violations=$vnn) — C4 proves nothing"
else
  bad "C4 THE FLOCK DID NOT PREVENT claim-vs-sweep corruption (violations=$vfn)"
fi

printf '\nTALLY: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
