# god-review changelog

## 2026-05-06 — Phase F production hardening

Closed all 15 remaining open findings from `tmp/god-review/report-v2.md`
(7 medium + 8 minor). State.json fields now actually written; hard-gate list
deduplicated to a single canonical source; cost arithmetic corrected.

**State.json wiring (was init-only):**
- `finding_history_hashes`: now written at end of Phase 3 keep/revert block via
  new `compute_finding_hash` + `record_finding_hash` helpers in
  `lib/env-helpers.sh`. Replay-guard added at fix-decision time
  (`is_finding_replayed`) — same-hash findings already tried-and-reverted
  are skipped instead of retried.
- `false_positives`: now written by Phase 2d FP post-processing via new
  `record_false_positive` helper.
- `consecutive_no_change_rounds`: removed from schema (vestigial — termination
  uses `consecutive_clean_rounds`).

**Hard-gate deduplication (was inlined in 4 places):**
- `lib/editor-agent.md`: inline pattern list replaced with pointer to
  `lib/hard-gates.txt` + `is_hard_gate` (the runtime authority).
- `god-review.md` (Reference: Hard Gates section): same.
- `README.md` (Hard Gates — Never Auto-Applied section): same.
- Canonical source remains `lib/hard-gates.txt`.

**Documentation accuracy:**
- README cost arithmetic corrected: 54 max (55 with `--ruthless`), not 47.
  Decomposes to 3 broad-Claude + 3 broad-Codex + 23 principle pairs (46) +
  2 batched validation = 54.

**Code hygiene:**
- Duplicate `is_hard_gate()` definition deleted from `lib/env-helpers.sh`
  (lines 94-109 — dead first definition + bridging "override" comment).
- `LOCK_TIMEOUT` in `lib/codex-invoke.sh` now reads `SPINLOCK_TIMEOUT_SEC`
  env var (was hardcoded 600).
- `SPINLOCK_TIMEOUT_SEC` and `LATE_IMPORT_LINE` exported at top of Phase 3
  round-loop fence + added to `write_env` whitelist (cross-fence persistence).
- `LATE_IMPORT_LINE` actually wired into `principles/circular-deps.md`
  (was declared in Tunable Constants but unused).
- `PRE_SCAN_HALLUCINATED` actually assigned (Phase 1 pre-scan was running
  but echoing to stdout; now captured into the var + counted in
  `PRE_SCAN_FLAG_COUNT`).
- Tunable Constants fence in `god-review.md` now sources `env-helpers.sh`
  for uniform fence pattern.

**No-ops** (already fixed in fix-pass v2 / not re-fixed):
- Step 0.5 `--principle <name>` error message already lists all 23 principles.
- `MAX_ROUNDS_EXPLICIT` already wired into bounded-mode termination at
  `god-review.md:1264`.
- `claude-ruthless-redteam.md` 30/40/30 effort budget already in body
  (Phase 1 / Phase 2 / Phase 3 sections).

## 2026-05-06 — Phase E fix pass
- Fixed Phase 3 while-loop split-across-fences (catastrophic)
- Fixed glob_to_regex algorithm + added self-test (catastrophic)
- Wired --ruthless spawn block to actual Agent invocation (catastrophic)
- Added round-loop counters to write_env whitelist
- Wired 4 new failure-class principles (dead-end, info-loss, contradiction, gap) into ALWAYS_ON_PRINCIPLES
- Fixed HAS_BENCH_SCRIPT python paren imbalance (audit was wrong, ast.parse confirmed)
- Fixed FROZEN_UNITS_CAP self-referential default
- Renamed phantom ARCH_JSON references to ARCH_OUTPUT

## 2026-05-05 — Initial fix pass + 4 new failure-class lenses
- 21 commits across Wave 1 + Wave 2 (Implementer S Groups 1-4)
- See plan: tmp/done-plans/2026-05-05-god-review-fixes-plus-second-review.md

## 2026-05-04 — Initial /god-review v1 ship
- See plan: tmp/done-plans/2026-05-04-god-review-command.md
