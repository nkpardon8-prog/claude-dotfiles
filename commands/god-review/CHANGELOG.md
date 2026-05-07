# god-review changelog

## 2026-05-06 — Phase G4: post-v5 catastrophic + high cluster

Phase E v5 audit (5 verifier agents) flagged 6 catastrophic + 20 high. G4
closes the cluster. Architecture is stable now; remaining items are mediums.

**Catastrophic fixes:**
- **Round-start cleanup target directory fix.** `rm -f` now hits
  `$WORKDIR/tmp/god-review/findings/verifier-*.txt` (where `write_agent_finding`
  actually writes), not the wrong `/tmp/verifier-*.txt`. Prior-round verifier
  outputs no longer leak across rounds.
- **`exit 0` semantics clarified in Phase 3e prose.** Explicit instruction
  that `exit 0` ends one bash fence, not the round/loop. Orchestrator continues
  to next prose+fence pair (or next finding).
- **CODEX_VALIDATION_EVERY actually gates.** Skip-check added before Codex
  validation invocation: `if ROUND >= 2 && ROUND % EVERY != 0 then skip`.
  Cost optimization for long runs is real.
- **VERIFIER_NEW findings now persisted to report.md.** New round-aware
  section (`## Verifier round $ROUND additions`) appended after each filter
  pass. Round N+1's 3a re-parses these as findings. Was: stdout-only,
  discoveries vanished after one round.
- **HUMAN_GATE_QUEUE write switched to separate accumulator file.** Replaced
  fragile python string-replace (which corrupts on diff content containing
  the marker text) with `tmp/god-review/human-gate-queue.md` accumulator,
  concatenated into final report.md at Phase 4 end-of-run.
- **Codex validation output now actually parsed.** `/tmp/codex-validation-output.txt`
  is grep'd for `FALSE_POSITIVE` lines; each fires `record_false_positive`
  AND `record_finding_hash` (so future rounds' replay-skip filters them).
  Was: file written, never read.

**High-severity fixes:**
- **TOTAL_OPEN_FINDINGS recomputed at start of each round 3g** (was frozen
  at Phase 3 entry; record_round_counts persisted stale value).
- **FROZEN_UNITS_CAP enforced.** Exit code 3 fires when `FROZEN_UNITS_COUNT >
  FROZEN_UNITS_CAP`. Documented but unimplemented before.
- **LOOP_EXIT set on all backstops** (wall-clock, instability, frozen-cap,
  max-rounds). Postmortem can distinguish convergence from kill via state.json.
- **`git add -- "$ARCH_FILE"`** instead of `git add -A` at commit (prevents
  folding user's WIP into god-review commits).
- **TSV parser regex requires explicit `File:`/`Evidence:` prefix.** Avoids
  grabbing path-shaped substrings from prose / quoted code samples.
- **Spawn-schedule "principles 17-23"** corrected to "18-23" with explicit
  Message 1/2 coverage notes.
- **Deprecated `is_already_session_deferred` (category-only)** removed from
  `lib/env-helpers.sh`. Only `is_already_session_deferred_by_hash` remains.
  Self-flagged by dead-code-conservatism principle in v4.
- **`NET_NEW_FINDINGS_THIS_ROUND` confusion-bomb** removed (vestigial; only
  `NEW_NEW_FINDINGS` is wired; the named-similar pair was already removed in
  G3 init but the `record_round_counts` reference path is now consistent).
- **6 more vars added to write_env whitelist:** SKIP_CODEX_VALIDATION,
  PERF_REGRESS_PCT, INSTABILITY_RATE, FROZEN_UNITS_CAP, SHRINKAGE_PCT,
  SECRET_LEN_FLOOR, TEST_FILE_LINE_FLOOR (Tunable Constants now persist
  across fences as well).

**T10 verification (post-G4):** 17/17 globs pass, 4 LOOP_EXIT backstops,
SKIP_CODEX_VALIDATION wired, FROZEN_UNITS_CAP enforced (2 sites:
declaration + check), VERIFIER_NEW appended to report.md, HG_QUEUE_FILE
accumulator at 3 sites, deprecated session-deferred function removed.

## 2026-05-06 — Phase G3: residual fix-pass post Phase E v4

Phase E v4 audit on Phase G2 found 5 catastrophic + 21 high-severity items
(down from 9+31 in v3). G3 closes the remaining cluster.

**Catastrophic fixes:**
- **3b triage now uses `is_already_session_deferred_by_hash`** instead of the
  deprecated category-only variant. One weak deferral no longer suppresses an
  entire principle's coverage for the rest of the session.
- **3f verifier filter now has concrete TSV producer prose.** The orchestrator
  is given a python3 block that parses each verifier-N.txt markdown into TSV
  rows (`finding_id\tfile\tline_range_normalized\tcategory`) before the filter
  bash reads them. Was pseudocode; now executable.
- **Stale-file cleanup at round start.** Removes prior round's
  `architect-output-*.json`, `/tmp/verifier-*`, `/tmp/codex-*` before the
  new round produces fresh ones. Eliminates cross-round leak.
- **README dotfiles smoke-test now uses `/god-report`** (was `/god-review`,
  contradicting the Repo Restrictions section).

**High-severity fixes:**
- **god-review.md:619 "(all 19)" residual** updated to "(all 23)".
- **`editor-agent.md` rewritten** to read from `$ARCH_OUTPUT_FILE` path
  instead of expecting inline JSON. Matches Phase G2's disk-based Architect
  output protocol. Output now: single line `APPLIED: <file>:<lines>`.
- **6 new vars added to `write_env` whitelist:** `FINDING_DESCRIPTION`,
  `FINDING_ROOT_CAUSE`, `FINDING_SEVERITY`, `FINDING_PROPOSED_DIFF`,
  `LOOP_EXIT`, `VERIFIER_NEW_COUNT`.
- **`NET_NEW_FINDINGS_THIS_ROUND`** removed from `write_env` whitelist and
  init (vestigial confusion-bomb — `NEW_NEW_FINDINGS` is the wired counter).
- **Exit code 1 redocumented** as "Argument-parse error" (was the stale
  "report-only mode completed" — `--report-only` was dropped in Phase G).
- **Exit code 3 marked reserved** (no code path emits it).
- **README "Layer A — Broad Reviewers (6 total)"** acknowledges 7th with
  `--ruthless`.

**T10 verification (post-G3):** 17/17 globs pass, 0 "all 19" residuals,
0 deprecated `is_already_session_deferred` callers in 3b, 0 vestigial
`NET_NEW_FINDINGS_THIS_ROUND`, ARCH_OUTPUT_FILE pattern in place, smoke-test
points at /god-report.

## 2026-05-06 — Phase G2: catastrophic fix-pass on Phase G

Phase E v3 audit (5 verifier agents) found 9 catastrophic bugs in Phase G's
implementation (architecture was sound; execution had real bugs). G2 closes
all 9 + 6 high-severity items.

**Catastrophic fixes (9):**
- **C1 ARCH_OUTPUT capture from disk, not paste.** Architect now writes JSON to
  `tmp/god-review/architect-output-<finding_id>.json`. The orchestrator reads
  from disk via `python3 ... open(ARCH_OUTPUT_FILE)`. Eliminates the
  apostrophe-corrupts-fix bug from inline-paste pattern.
- **C2 `--ruthless` real Agent invocation.** Replaced comment-only stub with
  concrete cat-prompt-to-disk + orchestrator-instruction prose for spawning
  the 4th broad-Claude reviewer. Phase F's claimed fix was illusory; G2 ships
  the real thing.
- **C3 cross-fence persistence.** Added 17 Phase 3 vars to `write_env`
  whitelist: PRE_FIX_REF, PRE_FIX_REFTYPE, PRE_FIX_BASE_REF, ARCH_FILE,
  ARCH_OUTPUT_FILE, FINDING_HASH, FINDING_ID, FINDING_FILE,
  FINDING_LINE_RANGE, FINDING_LINE_NORMALIZED, FINDING_CATEGORY, RATIONALE,
  GATES_PASS, GATE_FAIL_REASON, REGRESSION, REGRESSION_REASON, REVERT_REASON,
  NEW_NEW_FINDINGS, DEFERRED_THIS_ROUND, GATED_THIS_ROUND, ROUNDS. Replay-guard
  now records non-empty hashes; revert paths use real file paths; commit
  messages include the Architect's actual rationale.
- **C4 HAS_BENCH_SCRIPT python paren imbalance.** Phase F claimed to fix this
  in commit 64d5e98 but the `print(next((...),'')` was still missing a close
  paren. G2 actually fixes it. Verified via live python3 invocation.
- **C5 Loop re-entry prose strengthened.** Sub-step 3g now has explicit
  "YOU MUST START THE NEXT ROUND RIGHT NOW BY EXECUTING SUB-STEP 3a IN A NEW
  BATCH OF MESSAGES" instruction with reference to master-review.md:1417.
  Distinguishes converged-exit vs re-enter cases concretely.
- **C6 PRE_FIX_BASE_REF=$REF at round start.** Defined at sub-step 3a entry
  via `git rev-parse HEAD`. The 3f verifier diff now has a real baseline.
- **C7 Codex output consolidation.** After codex-broad bash invocations,
  outputs are copied from `/tmp/codex-broad-*.txt` to
  `findings/codex-broad-*.txt`. Same for codex-principle. Phase 2d cat now
  globs both `claude-*.txt` AND `codex-*.txt`. The Claude-validates-Codex
  validation pass gets real input (was reading empty before).
- **C8 god-report.md `allowed-tools`.** Added `Agent` permission. Single-
  principle delegation no longer broken from day one.
- **C9 README purge `--fix`/`--loop` invocation examples.** Updated 8
  invocation examples + 4 section headers to reflect Phase G's always-on
  fix-loop. Copy-pasting README commands no longer hits "unknown flag".

**High-severity fixes (6):**
- **`is_already_session_deferred_by_hash`** added (per-finding granularity).
  The category-only variant was too coarse — one weak deferral suppressed an
  entire principle's coverage.
- **session-deferred file format** changed to TSV: `HASH=<h>\tCATEGORY=<c>\tREASON=<r>`.
  Enables exact-hash lookup. Old grep-by-category retained for back-compat.
- **Auto-defer regex hardened.** Added stop-list of casual camelCase/snake_case
  words (`thisFeature`, `tooHard`, `cantFix`, etc.) that must not count as
  structural anchors. Prose-soup deferrals like "thisFeature is hard to fix
  because it is complex" now correctly rejected.
- **DEFERRED_THIS_ROUND / GATED_THIS_ROUND counters** incremented in 3c (per
  HUMAN_GATE first-emit) and 3d (per accepted auto-defer). `record_round_counts`
  now writes real numbers instead of hardcoded 0.
- **3f verifier filter** is now concrete bash (was pseudocode in prose).
  Reads `/tmp/verifier-all-findings.tsv`, computes hashes, applies the
  3-clause filter (human_gate_emitted + finding_history_hashes + session-
  deferred-by-hash), exports `VERIFIER_NEW_COUNT`.
- **god-review.md "19 principles" residuals purged.** Frontmatter description,
  Phase 2 spawn schedule (now 23 with explicit list), report template
  "(N of 23)". README and CRITERIA already correct.

**T10 verification (post-G2):** 17/17 globs pass, 9 helpers exist,
0 placeholder strings, 0 `--fix`/`--loop` arg-parser refs, 0 `$LOOP`/`$FIX`
residuals, both commands registered, auto-defer rejects camelCase prose-soup,
counters wired.

## 2026-05-06 — Phase G: split + orchestrator-driven loop

The biggest architectural change since v1 ship. Split `/god-review` into two
top-level commands and rewrote Phase 3 from pseudocode to a real
orchestrator-driven loop (master-review pattern).

**Two commands, one backbone:**
- **`/god-review`** — Phase 0–3, autonomous indefinite fix-loop. Always-on by
  definition. Drops `--fix`/`--loop`/`--report-only` flags. Runs until 3
  consecutive rounds yield zero NEW non-deferred findings. `--max-wall-hours 0`
  disables the wall-clock backstop for true indefinite runs.
- **`/god-report`** (NEW) — Phase 0–2 only, single-pass review. Optional
  `--rounds N` for de-noising. Delegates Phase 0/1/2 mechanics to god-review.md
  to prevent drift; explicitly skips Phase 3.

**Phase 3 architecture rewrite:**
- Replaced ~600 lines of pseudocode-with-placeholder-strings with an
  orchestrator-driven loop following master-review.md:1395-1430 pattern.
  Bash blocks do mechanical work; Agent tool calls do parallel review/fix
  work; the loop control flow lives in the orchestrating LLM's reasoning as
  explicit prose ("if NEW > 0 → re-enter Phase 2/3; if 3 clean → exit").
- 8 sub-steps: 3a (load+hash), 3b (4-bucket triage), 3c (HUMAN_GATE_QUEUE
  batch), 3d (auto-defer with guardrails), 3e (per-finding pipeline:
  snapshot → Architect → validate → Editor → gates → perf → commit), 3f
  (verifier sub-pass with hash-dedup against human_gate_emitted +
  session-deferred), 3g (termination decision), 3h (Phase 4 final report).
- **Skip-Phase-2-when-verifier-clean** optimization: avoids respawning 52
  agents per round when nothing actionable changed.

**State.json schema additions (5 new fields):**
- `human_gate_emitted` — HUMAN_GATE batch dedup. Now actually written.
- `frozen_added_per_round` — instability detector input. Now actually written.
- `architect_malformed_per_round` — instability detector input. Now actually written.
- `auto_deferred` — audit trail for runtime deferrals.
- `round_finding_counts` — per-round summary for termination decision.
- Removed: `consecutive_no_change_rounds` (vestigial — Phase F).

**8 new helpers in `lib/env-helpers.sh`:**
- `record_human_gate_emit`, `is_human_gate_already_emitted`
- `record_frozen`, `record_architect_malformed`
- `record_auto_defer` (with substantive-reason guardrail: ≥30 chars + structural
  anchor — file path, identifier, quoted name, or issue ref. Trivial reasons
  rejected with diagnostic.)
- `is_already_session_deferred`, `record_round_counts`, `write_agent_finding`,
  `check_phase_drift`.

**Glob algorithm + hard-gates fixes:**
- `glob_to_regex` algorithm: middle-position `**` now emits `/(?:.*/)?` (was
  `(?:/.*)?` which incorrectly matched `.github/workflows.yml` against
  `.github/workflows/**/*.yml`). Self-test: 17/17 pass (was 8/8).
- `lib/hard-gates.txt`: changed `**.yml` → `**/*.yml`; added nested-quarantine
  patterns (`**/_deprecated/**`, `**/tests/**`, `**/__tests__/**`,
  `**/spec/**`).

**Replay-guard correctness fix:**
- `record_finding_hash` now called on REVERT path only (per Phase E v2
  high-severity finding). Successful fixes can now be re-attempted on later
  regression — they're tracked in `kept_fixes` only.

**Auto-defer pipeline:**
- Runtime deferrals write to `tmp/god-review/known-deferred-session.txt`
  (NOT the committed `lib/known-deferred.txt`). Promotion to the committed
  file happens explicitly at end-of-run in Phase 4. This avoids polluting
  the dotfiles repo with mid-run auto-sync commits per deferral.

**HUMAN_GATE_QUEUE batching:**
- Hard-gate findings (schema/auth/deps/secrets/CI/tests/multi-file) never
  auto-apply AND never block the loop. They append to a `HUMAN_GATE_QUEUE`
  section in `report.md` with proposed diffs, dedup'd by hash via
  `human_gate_emitted`. Presented as one batch at end of run.

**editor-agent.md output schema:**
- Required machine-parseable single-line output: `APPLIED: <file>:<lines>`
  or `EDITOR_ABORT: <reason>`. Anything else is treated as malformed and
  the fix is reverted.

**Phase 2c per-agent finding write:**
- Orchestrator-instruction prose now explicitly tells the LLM to call
  `write_agent_finding <agent_name> <result_text>` after each parallel batch
  returns, so `findings/claude-*.txt` are actually written before the
  Phase 2d cat-consolidate read (Phase E v2 catastrophic finding C4).

**Injection guard upgraded to python3:**
- macOS bash 3.2.57's `$'\n'` evaluates to literal backslash-n; the previous
  bash-`case` injection guard didn't actually filter newlines. Replaced with
  python3-based check that handles all forbidden chars + path-escape detection
  via `os.path.realpath`.

**Other:**
- Frontmatter `description` and `argument-hint` updated for the always-on
  fix-loop reality.
- README rewritten to document both commands + their flag tables side-by-side.
- Removed vestigial `FIX` and `LOOP` from `write_env` whitelist.
- Phase G implementation plan's baseline is now tracked via `git tag
  phase-g-baseline` (survives auto-push cleanup cycles). The orchestrator's
  Phase 1 snapshot still uses `git stash create` for dirty trees and
  `git rev-parse HEAD` for clean — that's a per-run snapshot, not a
  multi-day plan baseline, so stash works fine there.

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
