# /mission parallel-collision — assumption tests

Proves the load-bearing runtime contracts of the fix that binds `/mission` strictly by
session-id (kills the `ls -t MISSION.*.md | head -1` mtime adoption) and adds `/mission resume`.

Plan: `…/skills/tmp/ready-plans/2026-05-31-mission-parallel-collision-fix.md`

## Run

```bash
MISSION_SMOKE_ALLOW_DEV=true bash run-all.sh
```

Gate var `MISSION_SMOKE_ALLOW_DEV=true` is required (refuses otherwise). All synthetic state
is written under a per-run temp dir tagged `__atest__NN <uuid>` (with a space, on purpose),
cleaned in `finally` + a startup orphan-reaper (>1h). Real `~/.claude/chains` is read-only.

## Tests

| # | Proves | Pre-impl | Post-impl |
|---|---|---|---|
| 03 | `mission_resolve_path` returns MY sid's file, never the mtime-newest stranger; unknown→empty; spaced root | PENDING | must PASS |
| 06 | empty-string manifest pointer (`mission_path:""`) falls through to deterministic file (the original `// empty` bug) | PENDING | must PASS |
| 07 | a write with sid=B routes to `MISSION.<B>.*` and never bleeds into A (resume sid-swap is not split-brain) | PASS | must PASS |
| 05 | resolver prefers a non-empty manifest pointer over the deterministic path (post-compact reattach) | PENDING | must PASS |
| 02 | (advisory) real chain manifests have zero cross-binds; non-blocking | PASS | PASS |

## Exit codes
`0` PASS · `1` FAIL (assertion) · `2` REFUSED (gate unset) · `3` PENDING/infra (resolver not yet
implemented, or missing dep/dir). `run-all.sh` treats 3 as non-fatal and continues.

## Gate placement
- **Pre-implementation:** 07 + 02 PASS now; 03/05/06 PENDING is expected.
- **Post-implementation regression:** all five must PASS after `mission_resolve_path` ships. Re-run
  after each change to `mission-bridge.sh` / `mission.md`. Each test writes a `*.fingerprint.json`;
  a mismatch on re-run means the contract drifted → re-validate.

Observed at authoring (2026-05-31): `CLAUDE_CODE_SESSION_ID` is populated in a slash-command shell
(`CLAUDE_SESSION_ID` empty) → the env fallback yields a sid, so the fix's fail-loud is safe.
`02` confirmed checked=2 matched=2 warned=0.
