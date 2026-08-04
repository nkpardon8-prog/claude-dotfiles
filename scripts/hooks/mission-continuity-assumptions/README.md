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
| `02-await-lifecycle.sh` | `got=0` -> outstanding; `got=2` -> outstanding got=2; `got=3` (==need) -> stays outstanding `ready=1` (join-ready — the WAKE ROUTINE banks it; a reader returning `none` would make the bank UNREACHABLE) until a later `phase=review`/VOID supersedes a JOB barrier -> `none`; a `kind=human` STOP is superseded by NOTHING (R8-10 — an injected PART-DONE below it does not clear it; only its own DECISION+got=1 does, and the writer REFUSES a new PART-DONE while it is open); a human close needs a durable DECISION FIRST (R8-14 — a bare got=1 close is REFUSED); the R7-1 pending-mint (two same-slug decisions get DISTINCT monotonic ops so the 2nd human STOP never vanishes); the R7-2/R8 seq-edge cases (`1abc`/`1-`/`-x` REFUSED, `12-a-b`/`007-x`/`7zip-review` land); and the log-verb AWAIT / MISSION-REBASELINED refusals | Every transition here is read back by the wake routine's §8 decision table. A mis-read in either direction (a half-barrier looking done, or a joined barrier looking unfinished) is a silent stall or a replay loop. Each assertion pins one row. | yes |
| `03-lost-wake-replay.sh` | an AWAIT with `got<need` and NO progress after it STAYS outstanding across re-reads; the cursor is stable across those reads | This is the §8 `AWAIT got<need + NO tracked job -> replay the missing lane` safety net. It is what makes correctness independent of 100% wake delivery: a dropped completion wake must NOT let the barrier self-clear, or the missing lane's findings are silently discarded. | yes |
| `04-idempotent-cursor.sh` | the cursor is stable + non-empty across idle reads, MOVES after an append, and re-stabilises at the new value | Two overlapping wakes compute cursor_before, then recompute before dispatch; if it moved they discard the stale decision. Safe only if the hash is deterministic when idle (else the first wake's own read looks like a change and thrashes) AND moves once a transition is banked (else the second re-banks the same line). A1/A2 pin both edges. | yes |
| `07-decision-durability.sh` | the round-8 pending-STOP write path end to end: `resolve` DRAINS both the echoed `pd:<seq>-<slug>` and the bare `<seq>-<slug>` id (and fails LOUD on never-existed vs quiet-ok on an idempotent re-drive); the monotonic `pdseq` seeds a fresh mint from `max(marker, log, md-zone)` (the R8-3 upgrade-boundary fix — a stale `pdseq=0` marker with `seq=5` in history mints `pd:6`, never a live-seq reuse) and survives note/challenge/resolve/gen-bump; a crash ORPHAN (barrier live, pd line lost) is ADOPTED (same seq, one live STOP); DECISION-first is lib-enforced (a human `got=1` close with no same-op DECISION is REFUSED, barrier stays live) and a deny outcome is DURABLE; second-open / slug>64 / line>=480B / sequence-exhausted / AWAIT-idtag-collision all FAIL CLOSED (no barrier, no pd line, no echo); and the R8-6 SPINLOCK env clamp holds (`999999`->0, `3600`->3600, `21601`->0) | Every failure is silent and SAFETY-critical: a reused seq drops the 2nd mandatory STOP; a close without a recorded outcome loses an approve/deny; a mis-seed reuses a live seq; a phantom resolve corrupts the ledger; an un-adopted orphan opens a SECOND invisible barrier. Each leg is a distinct mission root so one revert reddens one assertion. | yes |
| `08-r8-review-fixes.sh` | the round-8 /codex-review fix pass: the seed high-water INCLUDES anchored DECISION lines so a `log`-preplanted `DECISION op=1` cannot be reminted (C1a); the DECISION-first close requires the DECISION AFTER the got=0 opener (C1b) and a fully-anchored `outcome=(approve\|deny)$` body so a pre-opener or torn DECISION cannot close (C3); an OPEN human barrier adopts an orphan ONLY on an EXACT slug+coords(+question) match — a DIFFERENT request FAILS CLOSED, never rebinding its question (C2); `mission_rebaseline`/`mission_clear_append` RE-CHECK the human barrier UNDER their own mutation lock so a barrier opened after the pre-lock guard is not sliced/erased (C4); a newline / leading `- [pd:` question fails closed (I1); the non-blocking `pending` mint shares the high-water seed (I2); a malformed resolve id is grammar-rejected (I3); octal-looking `part=08` round-trips via `10#` (I4); free-text `resolved pd:999999`/`op=999999` cannot poison the seed (I6); and the god-review reclaim clears a legacy `budget` file so a killed round-7 lockdir does not wedge forever (I8) | Each is a SILENT bypass of the mandatory human STOP or a wedge: a preplanted/torn/pre-opener approval satisfying a close, an unrelated request rebinding an open barrier, a TOCTOU rebaseline/clear erasing the STOP, a forged pending line, a poisoned counter, a lock that never reclaims. Each leg is a distinct mission root so one revert reddens one assertion. | yes |

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
