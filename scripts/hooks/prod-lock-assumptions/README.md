# prod-lock assumption probes

Runtime assumptions behind **Part 1A** of the prod-lock lifecycle work
(`tmp/ready-plans/2026-08-16-prod-lock-lifecycle.md`). Each probe checks something the design *rests
on* but cannot establish by reading — kernel behavior, filesystem behavior, CPython semantics.

Run them all: `bash run-all.sh`

**A red probe means the environment drifted, not that the build fails.** Re-validate the design
against what the probe now reports. That is the same posture as the three sibling `*-assumptions/`
directories.

Every probe carries **negative controls** — variants that must go *red*. A probe that can only ever
pass proves nothing, and two of these controls have already earned their place (see below).

| Probe | Assumption | Result |
|---|---|---|
| `01-flock-mechanics.sh` | `flock` is released on process exit and on fd close; `sys.exit()` inside a `@contextmanager` body unwinds cleanly and releases; `os.link` is create-exclusive | **6/6 green** |
| `02-write-atomicity.sh` | temp+`fsync` → `link` → dir `fsync` is never observed partially; dying between `unlink` and `link` leaves no lock | **3/3 green** |
| `03-concurrent-claim.sh` | the serializer actually serializes real, barrier-released processes | **4/4 green** |

## What these measured that reading had not settled

- **The revision-4 double-yield bug was real.** `01`'s negative control reproduces
  `RuntimeError("generator didn't stop after throw()")` from the shape revision 4 proposed. Two review
  rounds argued about that trace; the probe settles it.
- **`block()` unwinding out of the mutex is clean.** `sys.exit(2)` from inside the context body
  preserves the exit code, raises nothing, and releases the lock.
- **`os.link` — not the flock — is what makes concurrent *claim* safe.** `03`'s C3 shows eight
  simultaneous claimants with **no flock at all** still produce exactly one winner, because `os.link`
  is itself a create-exclusive CAS. This narrows what the flock is for and therefore what the fixture
  suite has to prove.
- **What the flock actually buys is claim-vs-sweep.** `03`'s C4 models a sweeper that reads the lock,
  is descheduled, and then acts on that now-stale read while a successor has claimed. Without the
  flock: **69 violations in 80 trials**. With it, and with the re-verify-under-the-lock step the plan
  specifies: **0**. That is the justification for the serializer, measured rather than asserted.

## Probe defects found and fixed while building these

Recorded because the same traps recur, and because a probe that passes for the wrong reason is worse
than no probe:

1. `02`'s negative control skipped **empty** reads — which is exactly the tear that truncate-then-write
   produces. It filtered out the evidence it existed to find, and so could never go red.
2. `03` reused one directory per flock-mode, so the lock from the first run survived and every later
   trial reported `winners=0`. Fresh directory per invocation.
3. `03`'s C4 oracle was wrong: it counted "sweeper cleared A, then B claimed" as corruption. That is a
   legal serialization and a correct outcome. The real violation is *B linked and passed its read-back
   while the lock is gone* — B believing it holds a lock that no longer exists.

## Not covered here

`P0`-`P5` in the plan need **real hook payloads** (does `PostToolUse` carry `isError`/`interrupted`;
is `tool_use_id` present and reused on a retry; is `run_in_background` readable; do subagents share a
`session_id`; is `hook_event_name` emitted) and a live turn-boundary observation. Capturing those
requires registering a capture hook in `settings.json`, which is a machine-wide change — see the
`pd:5-probe-capture-hook` decision. Nothing here touches `settings.json` or the live `~/.claude/prod.lock`.
