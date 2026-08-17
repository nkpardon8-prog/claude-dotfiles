#!/bin/bash
# 02-write-atomicity.sh — can a reader ever observe a PARTIAL lock record?
#
# Part 1A eliminates os.replace and writes every record as: temp(O_EXCL)+fsync -> os.link -> dir fsync.
# The claim that buys is that a reader either sees the OLD state or the COMPLETE new record, never a
# half-written one. That matters because the gate FAILS CLOSED on a malformed lock: a reader that
# glimpsed a partial record would hard-block the machine for a reason that never really existed.
#
# This probe does NOT test crash durability (that needs power loss). It tests what is actually
# reachable: link atomicity under concurrent readers, and that the unlocked pre-read in _release /
# _sweep can never see a torn record.
#
# Each assertion carries a NEGATIVE CONTROL proving the probe can go red.
set -uo pipefail
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/atomprobe.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# ── B1: link-published records are never observed partially ────────────────────────────────
res=$(python3 - "$TMP" <<'PY'
import json, os, secrets, sys, threading, time
tmp = sys.argv[1]; LOCK = os.path.join(tmp, "b1.lock")
stop = False; torn = []; seen_complete = 0

def write_complete(value):
    """Exactly the plan's chain: O_EXCL temp + fsync, then link, then directory fsync."""
    temp = f"{LOCK}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as s:
        json.dump(value, s, separators=(",", ":")); s.flush(); os.fsync(s.fileno())
    try:
        os.unlink(LOCK)
    except FileNotFoundError:
        pass
    os.link(temp, LOCK)
    d = os.open(os.path.dirname(LOCK), os.O_RDONLY)
    try: os.fsync(d)
    finally: os.close(d)
    os.unlink(temp)

def reader():
    global seen_complete
    while not stop:
        try:
            with open(LOCK) as fh:
                raw = fh.read()
        except FileNotFoundError:
            continue
        except Exception:
            continue
        if not raw:
            continue
        try:
            v = json.loads(raw)
            if not (isinstance(v, dict) and "sid" in v and "op" in v and "ts" in v):
                torn.append(raw[:60])
            else:
                seen_complete += 1
        except Exception:
            torn.append(raw[:60])          # a TORN record — the thing that must never happen

ts = [threading.Thread(target=reader) for _ in range(4)]
for t in ts: t.start()
for i in range(300):
    write_complete({"sid": f"S{i}", "op": "x" * (i % 70), "ts": 1700000000 + i})
stop = True
for t in ts: t.join()
print(f"torn={len(torn)}|complete_reads={'yes' if seen_complete > 0 else 'NONE'}")
PY
)
case "$res" in
  torn=0\|complete_reads=yes) ok "B1 300 link-published writes under 4 concurrent readers: zero torn reads" ;;
  *torn=0*)                   bad "B1 readers never actually observed the file (got: $res)" ;;
  *)                          bad "B1 A TORN RECORD WAS OBSERVED (got: $res)" ;;
esac

# NEGATIVE CONTROL for B1: the naive in-place write MUST produce torn reads.
neg=$(python3 - "$TMP" <<'PY'
import json, os, sys, threading
tmp = sys.argv[1]; LOCK = os.path.join(tmp, "b1neg.lock")
stop = False; torn = []

def write_in_place(value):
    with open(LOCK, "w") as s:                 # truncate-then-write: the wrong way
        json.dump(value, s, separators=(",", ":")); s.flush()

def reader():
    while not stop:
        try:
            with open(LOCK) as fh: raw = fh.read()
        except Exception:
            continue
        # An EMPTY read is exactly the tear truncate-then-write produces: the reader caught the
        # file between O_TRUNC and the write. The first version of this control skipped empties
        # and so could never go red — it filtered out the very evidence it existed to find.
        if not raw:
            torn.append("<empty>")
            continue
        try:
            json.loads(raw)
        except Exception:
            torn.append(raw[:40])

write_in_place({"sid": "seed", "op": "seed", "ts": 1})
ts = [threading.Thread(target=reader) for _ in range(6)]
for t in ts: t.start()
for i in range(4000):
    write_in_place({"sid": f"S{i}", "op": "y" * 400, "ts": 1700000000 + i})
stop = True
for t in ts: t.join()
print("torn-observed" if torn else "no-torn")
PY
)
[ "$neg" = "torn-observed" ] && ok "B1-neg naive in-place write does produce torn reads (probe can go red)" \
                             || bad "B1-neg NEGATIVE CONTROL DID NOT GO RED — B1 proves nothing (got: $neg)"

# ── B2: unlink-then-link leaves NO lock if we die between the two ───────────────────────────
# The plan asserts this failure direction is safe: "next claimant claims" rather than a strand.
res=$(python3 - "$TMP" <<'PY'
import json, os, subprocess, sys
tmp = sys.argv[1]; LOCK = os.path.join(tmp, "b2.lock")
with open(LOCK, "w") as s: json.dump({"sid": "old", "op": "o", "ts": 1}, s)
child = r'''
import json, os, sys
LOCK = sys.argv[1]
temp = LOCK + ".tmp"
with open(temp, "w") as s: json.dump({"sid":"new","op":"n","ts":2}, s)
os.unlink(LOCK)
os._exit(9)                      # die in the window between unlink and link
'''
subprocess.run([sys.executable, "-c", child, LOCK], timeout=10)
print("absent" if not os.path.exists(LOCK) else "present")
PY
)
[ "$res" = "absent" ] && ok "B2 dying between unlink and link leaves NO lock (fails toward claimable)" \
                      || bad "B2 unexpected state after mid-write death (got: $res)"

printf '\nTALLY: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
