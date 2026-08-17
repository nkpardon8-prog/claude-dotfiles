#!/bin/bash
# 01-flock-mechanics.sh — the four runtime assumptions Part 1A's serializer rests on.
#
# Part 1A replaced an O_CREAT|O_EXCL + age-bound mutex with fcntl.flock precisely because the kernel
# releases a flock on process death, so there is no crash leak, no age bound, and no slow-vs-dead
# judgment. Every one of those words is a claim about THIS machine's kernel and THIS Python, not
# about the design. This probe checks them.
#
# Each assertion carries a NEGATIVE CONTROL: a variant that MUST fail, proving the probe can go red.
# A probe that only ever passes proves nothing (the standing lesson from the fixture suite).
#
# Exit 0 = all assumptions hold. Exit 1 = at least one FAILED (design-invalidating).
set -uo pipefail
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; }
note() { printf '      %s\n' "$1"; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/flockprobe.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# ── A1: a flock is released when the holding process EXITS (no explicit unlock) ─────────────
python3 - "$TMP" <<'PY'
import fcntl, os, subprocess, sys, json
tmp = sys.argv[1]; p = os.path.join(tmp, "a1.mx")
open(p, "w").close()
# child takes the lock and exits WITHOUT unlocking
child = "import fcntl,os,sys;fd=os.open(sys.argv[1],os.O_RDWR);fcntl.flock(fd,fcntl.LOCK_EX)"
subprocess.run([sys.executable, "-c", child, p], timeout=10)
fd = os.open(p, os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print(json.dumps({"a1": "released-on-exit"}))
except OSError:
    print(json.dumps({"a1": "STILL-HELD"}))
PY
res=$(python3 - "$TMP" <<'PY'
import fcntl, os, subprocess, sys
tmp = sys.argv[1]; p = os.path.join(tmp, "a1b.mx"); open(p, "w").close()
child = "import fcntl,os,sys;fd=os.open(sys.argv[1],os.O_RDWR);fcntl.flock(fd,fcntl.LOCK_EX)"
subprocess.run([sys.executable, "-c", child, p], timeout=10)
fd = os.open(p, os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); print("released-on-exit")
except OSError:
    print("STILL-HELD")
PY
)
[ "$res" = "released-on-exit" ] && ok "A1 flock released when the holder exits without unlocking" \
                               || bad "A1 flock NOT released on process exit (got: $res)"

# NEGATIVE CONTROL for A1: while the holder is STILL ALIVE, LOCK_NB must FAIL.
neg=$(python3 - "$TMP" <<'PY'
import fcntl, os, subprocess, sys, time
tmp = sys.argv[1]; p = os.path.join(tmp, "a1neg.mx"); open(p, "w").close()
child = ("import fcntl,os,sys,time;fd=os.open(sys.argv[1],os.O_RDWR);"
         "fcntl.flock(fd,fcntl.LOCK_EX);sys.stdout.write('up');sys.stdout.flush();time.sleep(3)")
pr = subprocess.Popen([sys.executable, "-c", child, p], stdout=subprocess.PIPE, text=True)
pr.stdout.read(2)                       # wait until it really holds the lock
fd = os.open(p, os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); print("ACQUIRED-WHILE-HELD")
except OSError:
    print("correctly-blocked")
pr.kill()
PY
)
[ "$neg" = "correctly-blocked" ] && ok "A1-neg live holder correctly blocks a second LOCK_NB" \
                                 || bad "A1-neg NEGATIVE CONTROL DID NOT GO RED (got: $neg)"

# ── A2: a flock is released when the fd is CLOSED, even with the process still alive ────────
res=$(python3 - "$TMP" <<'PY'
import fcntl, os, sys
tmp = sys.argv[1]; p = os.path.join(tmp, "a2.mx"); open(p, "w").close()
fd1 = os.open(p, os.O_RDWR); fcntl.flock(fd1, fcntl.LOCK_EX); os.close(fd1)
fd2 = os.open(p, os.O_RDWR)
try:
    fcntl.flock(fd2, fcntl.LOCK_EX | fcntl.LOCK_NB); print("released-on-close")
except OSError:
    print("STILL-HELD")
PY
)
[ "$res" = "released-on-close" ] && ok "A2 flock released on fd close (same process)" \
                                 || bad "A2 flock NOT released on fd close (got: $res)"

# ── A3: sys.exit() from INSIDE a @contextmanager body runs the finally and releases ─────────
# This is exactly Part 1A's block() unwinding out of `with _lock_mutex()`. Revision 4 had a
# double-yield here that raised RuntimeError; revision 5 fixed the shape. Prove the fixed shape.
res=$(python3 - "$TMP" <<'PY'
import contextlib, fcntl, os, subprocess, sys
tmp = sys.argv[1]; p = os.path.join(tmp, "a3.mx"); open(p, "w").close()
child = r'''
import contextlib, fcntl, os, sys
p = sys.argv[1]
@contextlib.contextmanager
def m():
    fd, held = None, False
    try:
        fd = os.open(p, os.O_CREAT | os.O_RDWR, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); held = True
    except Exception:
        held = False
    try:
        yield held
    finally:
        if fd is not None:
            try: os.close(fd)
            except Exception: pass
with m() as held:
    if held:
        sys.exit(2)          # exactly what block() does
'''
r = subprocess.run([sys.executable, "-c", child, p], capture_output=True, text=True, timeout=10)
fd = os.open(p, os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    acq = "released"
except OSError:
    acq = "STILL-HELD"
err = "RuntimeError" in r.stderr
print(f"{acq}|rc={r.returncode}|runtimeerror={err}")
PY
)
case "$res" in
  released\|rc=2\|runtimeerror=False)
      ok "A3 sys.exit(2) inside the contextmanager body: rc preserved, no RuntimeError, lock released" ;;
  *)  bad "A3 contextmanager unwind is NOT clean (got: $res)" ;;
esac

# NEGATIVE CONTROL for A3: the revision-4 DOUBLE-YIELD shape must raise RuntimeError.
neg=$(python3 - "$TMP" <<'PY'
import subprocess, sys
child = r'''
import contextlib, sys
@contextlib.contextmanager
def bad():
    try:
        yield True
    except Exception:
        yield False          # the revision-4 bug: a SECOND yield in the handler
with bad() as h:
    raise ValueError("boom")
'''
r = subprocess.run([sys.executable, "-c", child], capture_output=True, text=True, timeout=10)
print("RuntimeError" if "RuntimeError" in r.stderr else "no-runtimeerror")
PY
)
[ "$neg" = "RuntimeError" ] && ok "A3-neg the rev-4 double-yield shape does raise RuntimeError (bug is real)" \
                            || bad "A3-neg NEGATIVE CONTROL DID NOT GO RED (got: $neg)"

# ── A4: os.link onto an existing path raises FileExistsError (the free-path CAS) ────────────
res=$(python3 - "$TMP" <<'PY'
import os, sys
tmp = sys.argv[1]
src = os.path.join(tmp, "a4.src"); dst = os.path.join(tmp, "a4.dst")
open(src, "w").write("x"); open(dst, "w").write("y")
try:
    os.link(src, dst); print("LINKED-OVER-EXISTING")
except FileExistsError:
    print("fileexists")
except OSError as e:
    print(f"other-oserror:{e.errno}")
PY
)
[ "$res" = "fileexists" ] && ok "A4 os.link onto an existing path raises FileExistsError" \
                          || bad "A4 os.link does not behave as a create-exclusive CAS (got: $res)"

printf '\nTALLY: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
