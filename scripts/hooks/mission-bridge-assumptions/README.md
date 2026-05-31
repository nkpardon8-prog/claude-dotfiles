# mission-bridge assumption tests

Pre-flight **assumption tests** for the mission-bridge feature (the durable,
zero-information-loss cross-compaction spine planned in
`tmp/ready-plans/2026-05-30-precompact-mission-bridge-file.md`).

These are **kept learning tests**, not unit tests and not smoke tests. Each proves
that one load-bearing **OS/shell runtime contract** — the kind text review cannot
validate — actually holds on the real target box (macOS, **bash 3.2.57**). They run
**now**, before the `mission_*` primitives exist, by encoding the exact shell idioms
from the plan's Key Pseudocode and proving the underlying guarantee. After
implementation they double as **regression catchers**.

The governing requirement is **ZERO INFORMATION LOSS**: a mission's plan, notes, and
progress log must survive arbitrarily many compactions with no entry ever lost,
torn, fused, or silently dropped.

## What each test proves

| # | File | Contract proven | Zero-loss failure it guards |
|---|------|-----------------|------------------------------|
| 01 | `01-log-append-atomicity.sh` | 2 concurrent multibyte `>>` appends of sub-PIPE_BUF lines never interleave/tear; `head -c 470 \| iconv -c` yields valid UTF-8 `<480`B (measured `wc -c`); anchored `grep -qE "^tag\t"` ignores body-quoted ids | a racing compaction tears/loses a log entry, or a body quote suppresses a real entry |
| 02 | `02-marker-and-zone-parse.sh` | marker parse uses the **last** matching line (a body pseudo-marker is ignored); nonce-qualified zone fence isn't truncated by a bare/stale-nonce close; `shasum -a 256` first-16-hex is deterministic | pasted content corrupts/truncates the durable spine or destabilizes `plan_hash` |
| 03 | `03-lock-reclaim.sh` | PID-stamped mkdir-lock: a **dead** holder is reclaimed via `kill -0`; a **live** holder is never stolen; acquire loop reclaims within budget | crash deadlocks the spine, or two writers mutate it concurrently |
| 04 | `04-mutate-atomicity.sh` | an interrupted (un-renamed) mutate leaves the original byte-identical + marker-valid; `mktemp` in the **target dir** is same-device so `mv -f` stays an atomic rename | a crash mid-write corrupts the spine; a cross-fs `mv` degrades to non-atomic copy+unlink |
| 05 | `05-manifest-mission-path.sh` | jq `.mission_path = (.mission_path // $mp)` never clobbers a set path (incl. empty incoming); recovery re-derive is deterministic | the pointer to the mission file is lost across a compaction → mission silently vanishes |
| 06 | `06-primer-emit.sh` | `jq -n --arg c` round-trips adversarial banner content (quotes/newlines/`$()`/markers) injection-safe; branch truth-table surfaces banner / loud CRITICAL correctly; bounded banner read `<5s` | mission silently absent post-compact, or primer times out fail-silent |
| 07 | `07-append-after-torn-line.sh` | a newline-guarded append heals a torn (no-trailing-newline) final line so records never fuse; last-line marker scan survives a torn body line | a SIGKILL/ENOSPC partial write fuses two records into one (silent corruption) |
| 08 | `08-write-failure-surfaced.sh` | a failed append/lock/mktemp returns **non-zero** (so it can be surfaced); the original file is untouched | a swallowed write failure loses an entry the agent thinks it recorded — the fail-LOUD invariant |

### Fix-plan proofs (09-13) — the `/mission` codex-review hardening (`tmp/ready-plans/2026-05-30-mission-fixes.md`)

These call the **real** `mission_*` functions / `mission-write.sh` (the lib now exists) against a
hermetic scratch mission. **09 is RED until the rebaseline-lifecycle fix lands** — it is the
pre-implementation proof of CRITICAL #1; `run-all` halts there until `/implement` makes it GREEN.
10-13 are GREEN-now lock-ins of contracts the fix depends on.

| # | File | Contract proven | Failure it guards |
|---|------|-----------------|-------------------|
| 09 | `09-rebaseline-reactivates-latest.sh` | after a `MISSION-CLEARED` line, `mission_rebaseline` must append a NEWER `[mission]` lifecycle line so the active-iff rule (latest `[mission]` line ≠ `MISSION-CLEARED`) reads active **(RED until fix — lib:921 logs no `[mission]` token)** | a cleared mission can never reactivate (adopt (c) / explicit-build stuck dead) |
| 10 | `10-fail-idtag-attempt-scoped.sh` | the FAIL idtag must be **attempt-scoped** (5 same-reason FAILs → 5 anchored lines); a reason-only idtag collapses to 1 under `^<tag>\t` dedup (lib:775) — the negative control | the 5-strike loop-breaker is dead → runaway never halts |
| 11 | `11-write-status-parse.sh` | `mission-write.sh` always `exit 0`; lib `rc=2`(corrupt)/`rc=3`(lock-busy) surface **only** on the stdout `mission-write: <verb> FAILED rc=N` line, machine-parseable | a silent bridge-write failure → STOP-LOUD never wired |
| 12 | `12-round-line-reroute-boundary.sh` | a terse round line stays in the LOG; an oversize (≥480B) round line **reroutes to DURABLE NOTES** (lib:768) and leaves the LOG — the negative control | verbose findings inline in the round line vanish from the LOG → ambiguous resume |
| 13 | `13-resume-window-survives-rotation.sh` | after `_mission_log_rotate` archives the oldest half, `tail -n 40` of the live log MISSES the archived lifecycle line (RED arm), but grep over (live + newest `.gz`) RECOVERS it (GREEN) | resume reads wrong/no lifecycle state after rotation |

Every test embeds an explicit **negative control** (an `A?b`/`A4`/`A5` assertion, or a
forced-failure mechanism) proving the detector can go RED — a green is only meaningful
because the test demonstrably fails when the assumption is violated. Verified at
authoring time: swapping the canonical `tail -1` marker parse for `head -1` flips test
02 to exit 1 with the exact diagnostic.

## Dropped candidate (not shell-testable)

- **allowlist prompt-free** (`mission-write.sh` runs without a permission prompt under
  `defaultMode:auto`): this depends on Claude Code's settings.json permission engine at
  runtime, which no pure-shell test can exercise. **Verify it manually** after
  `/update-config` adds the allow rule, by a live prompt-free `mission-write.sh`
  invocation, plus byte-match inspection of the `permissions.allow` entry in
  `~/.claude/settings.json`.

## Not shell-testable, flagged for elsewhere

- The **host-imposed `additionalContext` size ceiling** (Claude Code may truncate very
  large SessionStart context) is not verifiable here. The banner is capped at
  `MISSION_PLAN_BANNER_MAX` (4000B) to stay well under any such ceiling — assert that
  cap holds in `test-mission-bridge.sh`.

## Safety

Hermetic: every test touches **only** a scratch dir under `$TMPDIR`, namespaced
`__mbridge_atest__<run-uuid>`, removed on EXIT, with a startup reaper for orphans from
prior crashed runs (marker + mtime `>60m`). No repo files, no network, no DB.

Still gated by `MISSION_BRIDGE_SMOKE_ALLOW_TMP=true` per the `/script` convention
(`run-all.sh` sets it for you). Test 08 needs a non-root user (a read-only dir/file must
actually deny writes); it exits 3 (INFRASTRUCTURE) under root.

## How to run

```bash
# all (run-all sets the gate var):
bash scripts/hooks/mission-bridge-assumptions/run-all.sh

# one (set the gate yourself):
MISSION_BRIDGE_SMOKE_ALLOW_TMP=true bash scripts/hooks/mission-bridge-assumptions/02-marker-and-zone-parse.sh
```

## Exit codes

- `0` PASS — all assertions held.
- `1` FAIL — ≥1 assertion failed; the failing `A#` anchors print with diagnostics.
- `2` REFUSED — `MISSION_BRIDGE_SMOKE_ALLOW_TMP` not `true`.
- `3` INFRASTRUCTURE — couldn't run (missing tool, root user, hang via the 60s
  `run-all` watchdog). Not a logical failure.

## Output

`PASS: <name> — assertions (A1 A2 ...)` on success; `FAIL: <name>` + a bullet per
failed anchor on failure. CI-parseable.

## Fingerprints

Each `*.fingerprint.json` records the assumption-relevant environment facts the result
depends on (PIPE_BUF, tool presence, stat flavor, jq version, OS). On a future re-run,
a mismatch means the environment drifted → **re-validate**, never auto-fail.

## Gates

- **Pre-implementation** (before `/implement`): 01-08 + 10-13 PASS; **09 is RED** (the fix proof) until
  the rebaseline-lifecycle change lands — `run-all` halts at 09 by design until then.
- **Post-implementation** (after each ship): re-run; all 13 must PASS; any FAIL = regression.
