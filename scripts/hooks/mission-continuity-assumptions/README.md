# mission-continuity assumption tests

Narrow-and-deep **assumption tests** (not unit tests) for the runtime contracts the
mission-stall fix rests on (plan: `tmp/ready-plans/2026-08-03-mission-stall-fix.md`, Task 8):
the **AWAIT bookmark** and the **idempotency cursor** in `scripts/hooks/mission-write.sh` +
`scripts/hooks/lib/mission-bridge.sh`, and the **no-detach gate** in
`scripts/hooks/no-detach-gate.py`.

**Why these get a suite.** Every failure they exist to prevent is quiet. An AWAIT that
fails to stay outstanding when a completion wake is dropped clears the safety-net signal, and
the mission stalls forever with nothing in any transcript saying so. A cursor hash that does
not move on an append lets two overlapping wakes both advance - a silent duplicate transition.
A no-detach gate that stops blocking `nohup codex ... &` silently removes the machine backstop
for road 1 (the `f71c8667` orphan that idled 3h38m). None of these throw; each is a green tick
over a dead leg. A contract whose failure mode is a green tick has to be tested against its
failure modes.

## Hermetic - and how

Each case builds a throwaway mission root under `mktemp -d` and drives the **live**
`mission-write.sh` / `no-detach-gate.py` against it - no live DB, no OD, no network, no PHI,
no `~/.claude` state. The root is removed on exit, including failure paths. We exercise the
real scripts (not copies): they are the thing under test and are pure over the sandbox root
passed to them, so there is no seam needing a checked-in snapshot. The suite is safe to run at
any time, including inside a mission.

The `MISSIONCONT_SMOKE_ALLOW_DEV=true` gate is a **uniformity convention, not a safety claim**
- it matches the suite's Validation-Gates siblings so a suite that silently runs when they
refuse does not train the wrong reflex. Unset it and `run-all.sh` and every case exit 2.

## What each case proves

| Case | Proves | Load-bearing because | watched-fail |
|---|---|---|---|
| `01-gate-parity.sh` | the no-detach gate's own fixture table passes, and three keystone re-pipes agree with it: `nohup codex &` -> block(2), `codex && echo` -> allow(0), `nohup <non-codex> &` -> allow(0) | The gate is the machine backstop for road 1. Its fixture table is the source of truth; this gates that table into the SAME command that proves the AWAIT machinery, and the re-pipes catch table/gate drift. | yes |
| `02-await-lifecycle.sh` | `got=0` -> outstanding; `got=2` -> outstanding got=2; `got=3` (==need) -> stays outstanding `ready=1` (join-ready — the WAKE ROUTINE banks it; a reader returning `none` would make the bank UNREACHABLE) until a later `phase=review`/VOID/PART-DONE supersedes it -> `none`; `kind=human got=0` -> outstanding kind=human; the R7-1 pending-mint (two same-slug decisions get DISTINCT monotonic ops so the 2nd human STOP never vanishes); the R7-2 seq-edge cases; and the log-verb AWAIT / MISSION-REBASELINED refusals | Every transition here is read back by the wake routine's §8 decision table. A mis-read in either direction (a half-barrier looking done, or a joined barrier looking unfinished) is a silent stall or a replay loop. Each assertion pins one row. | yes |
| `03-lost-wake-replay.sh` | an AWAIT with `got<need` and NO progress after it STAYS outstanding across re-reads; the cursor is stable across those reads | This is the §8 `AWAIT got<need + NO tracked job -> replay the missing lane` safety net. It is what makes correctness independent of 100% wake delivery: a dropped completion wake must NOT let the barrier self-clear, or the missing lane's findings are silently discarded. | yes |
| `04-idempotent-cursor.sh` | the cursor is stable + non-empty across idle reads, MOVES after an append, and re-stabilises at the new value | Two overlapping wakes compute cursor_before, then recompute before dispatch; if it moved they discard the stale decision. Safe only if the hash is deterministic when idle (else the first wake's own read looks like a change and thrashes) AND moves once a transition is banked (else the second re-banks the same line). A1/A2 pin both edges. | yes |

**watched-fail: yes** means each case was observed exiting 1 before it was trusted. The
negative control is described in a `NEGATIVE CONTROL:` comment at the head of each case (the
one-line source edit that turns it RED). At authoring time (2026-08-03) a forced-wrong variant
of case 02 was watched exiting 1 (`FAIL 02-await-lifecycle: 1 assertion(s)`), and the
no-detach gate was watched blocking a live `nohup ... codex` command in this very session -
both confirm the machinery can go red.

**Rotation-invariance** of the cursor (a log rotation that moves live lines into an archive
yields the same hash) is a property of `_gen_sliced_stream` and is owned by the
`mission-bridge-assumptions` suite's gen-sliced coverage; case 04 pins stability + change and
defers rotation to that owner rather than duplicating the rotation machinery here.

## Layout

```
_lib.sh                    shared harness + assertions (sourced, not a case)
NN-*.sh                    one case per behaviour
NN-*.fingerprint.json      per-case fingerprint written at PASS time
run-all.sh                 halts on the first FAIL; hang (124/142) -> exit 3
```

## How to run

```bash
# whole suite (halts on first FAIL):
MISSIONCONT_SMOKE_ALLOW_DEV=true bash scripts/hooks/mission-continuity-assumptions/run-all.sh

# one case:
MISSIONCONT_SMOKE_ALLOW_DEV=true bash scripts/hooks/mission-continuity-assumptions/02-await-lifecycle.sh
```

## Exit codes

`0` PASS · `1` FAIL (>=1 assertion) · `2` REFUSED (env gate unset) · `3` INFRASTRUCTURE
(`mission-write.sh`/gate missing, `mktemp` failed, or a hang -> 124|142).

## Gates

- **Pre-change:** run before touching the AWAIT/cursor helpers in `mission-bridge.sh` /
  `mission-write.sh` or the no-detach gate.
- **Post-change regression:** re-run after any edit to those helpers, to the gate, or to the
  shared no-detach fixture table.

## Safety

Throwaway mission roots under `mktemp -d`, removed on exit. No network, no `~/.claude/` state,
no PHI, no live infrastructure. The only script it shells out to are the read-only/pure
`mission-write.sh` verbs and the no-detach gate, each pointed at the sandbox root.
