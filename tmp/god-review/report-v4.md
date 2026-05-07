# god-review Report v4 (Phase E v3 verification — post Phase G)

**Generated:** 2026-05-06
**Scope:** post Phase G (split + Phase 3 orchestrator-driven rewrite + 8 new helpers + glob algorithm + auto-defer + HUMAN_GATE_QUEUE)
**Snapshot:** tag `phase-g-baseline` at commit `e501d89`
**Agents:** 5 (claude-ruthless-redteam + dead-end / info-loss / contradiction / gap detectors)

---

## Verdict: ARCHITECTURE LANDED, IMPLEMENTATION HAS REAL BUGS

Phase G's architectural changes are real:
- `/god-review` and `/god-report` both registered as slash commands ✓
- 17/17 glob self-test pass ✓
- 8 new helpers exist and are tested ✓
- Auto-defer guardrails reject trivial reasons ✓
- Replay-guard records hash on REVERT only (per Phase F design fix) ✓
- All T10 verification commands green ✓

**But** the verifiers found real bugs the T10 grep checks couldn't catch. Many were claimed-fixed in Phase F but were either re-broken by the Phase 3 rewrite or were never actually fixed (the original Phase F audit was wrong about some "fixed" items). Several are gen­uine new bugs introduced by the rewrite. A few are agent misunderstandings of orchestrator-driven design (they expect bash `while`).

---

## Comparison: report-v3 vs report-v4

| Metric | v3 (post-F) | v4 (post-G) |
|---|---:|---:|
| Total raw findings | 100 | ~119 |
| Catastrophic | 6 | 9 |
| High | 17 | 31 |
| De-duped actionable | ~70 | ~85 |

**Pass criteria was <15 actionable.** Result: **NOT MET.** The architecture rewrite traded some old bugs for new ones. Net: similar finding count, different bugs.

---

## Critical Cluster (de-duped from 9 raw catastrophic)

### C1. ARCH_OUTPUT capture mechanism is fragile *(redteam + info-loss + gap — 3 agents)*

**Evidence:** `god-review.md:1075` — `ARCH_OUTPUT='<paste the architect output JSON here, single-quoted>'` requires the orchestrator-LLM to literally substitute Architect JSON inline. If `rationale` / `before` / `after` contain a single-quote, the bash string breaks.

**Impact:** Every fix where the Architect's output contains an apostrophe will collapse to "malformed" → demote to HUMAN_GATE. Many code patches contain apostrophes.

**Fix:** Architect writes JSON to `tmp/god-review/architect-output-<finding-id>.json`. The bash block reads from disk via `ARCH_OUTPUT=$(cat tmp/god-review/architect-output-${FINDING_ID}.json)`. No inline paste.

### C2. `--ruthless` block is STILL comment-only stub *(redteam + dead-end + info-loss — 3 agents)*

**Evidence:** `god-review.md:553-568` under `if [ "$RUTHLESS" = "true" ]`, lines 558-567 are `#` comments describing what should happen, no real Agent invocation. Same finding as Phase E v1 (catastrophic). Phase F's fix-pass commit `7aaeb74` claim of "actually invokes Agent" is false — the verification grep matched the literal word "Agent" inside comments.

**Impact:** `--ruthless` is parsed-and-stored but the 4th broad reviewer never spawns.

**Fix:** Replace comment block with real Agent tool invocation prose: "Spawn ONE Agent tool call: subagent_type=general-purpose, model=claude-opus-4-7, extended thinking, prompt=$RUTHLESS_PROMPT + scope + context-package."

### C3. Phase 3 cross-fence variable persistence is broken *(info-loss — 2 catastrophic)*

**Evidence:** Sub-step 3e per-finding pipeline splits across 5+ bash fences (snapshot, validate, gates, perf, commit). Critical vars `PRE_FIX_REF`, `ARCH_FILE`, `ARCH_OUTPUT`, `FINDING_HASH`, `FINDING_ID`, `RATIONALE`, `GATES_PASS` are needed across fences but NONE are in `write_env`'s whitelist (`env-helpers.sh:20-27`).

**Impact:** Revert paths run `git checkout --` with empty `$ARCH_FILE`. Commits get empty rationale. Replay-guard records `FINDING_HASH=""`. The replay-skip becomes structurally inert.

**Fix:** Add to `write_env` whitelist: `PRE_FIX_REF PRE_FIX_REFTYPE ARCH_FILE ARCH_OUTPUT FINDING_HASH FINDING_ID FINDING_FILE FINDING_LINE_RANGE FINDING_CATEGORY RATIONALE GATES_PASS REGRESSION REGRESSION_REASON REVERT_REASON NEW_NEW_FINDINGS DEFERRED_THIS_ROUND GATED_THIS_ROUND`. Also call `write_env` after each sub-step 3e fence terminates.

### C4. `HAS_BENCH_SCRIPT` python expression has unbalanced parens *(redteam)*

**Evidence:** `god-review.md:199` — `print(next((k for k in scripts if k in ('bench','benchmark','perf')),''` is missing one closing `)`. Live-reproduces `SyntaxError: '(' was never closed`. Phase F commit `64d5e98` claimed to fix this; the false-positive removal in `false_positives.txt` was wrong — the bug is still in the file.

**Impact:** Perf-benchmark principle never activates. `HAS_BENCH_SCRIPT` is always empty.

**Fix:** Add the missing close paren: `print(next((k for k in scripts if k in ('bench','benchmark','perf')),''))`.

### C5. Phase 3 round-loop has no concrete re-entry mechanism *(gap)*

**Evidence:** `god-review.md:1449-1473` — sub-step 3g says "re-enter sub-step 3a (next round)" or "exit the loop" as orchestrator-prose. There's no concrete mechanism telling the LLM HOW to re-enter — no Agent self-recursion, no explicit "go back to message N", no harness construct.

**Impact:** Partial misunderstanding of orchestrator-driven design (the LLM doesn't need bash `while` — it just keeps executing the recipe), BUT the prose may not be strong enough that an LLM actually loops indefinitely. Risk of LLM treating "exit" as the natural end and stopping after one round.

**Fix:** Make the prose more explicit: "After 3g's decision, if you've decided to re-enter, START THE NEXT ROUND BY REPEATING ALL OF SUB-STEP 3a IN A NEW BATCH OF MESSAGES. Do NOT stop. The loop terminates ONLY when CONSECUTIVE_CLEAN_ROUNDS >= 3 OR a backstop fires." Reference master-review.md:1417's pattern explicitly.

### C6. `PRE_FIX_BASE_REF` referenced but undefined *(redteam + info-loss + gap — 3 agents)*

**Evidence:** `god-review.md:1343` — verifier sub-pass prompt says `git diff $PRE_FIX_BASE_REF..HEAD` but `PRE_FIX_BASE_REF` is never assigned anywhere in the file. The closest defined names are `PRE_FIX_REF` (per-finding) and `REF` (round-start).

**Impact:** Verifier diff is empty (or wrong). Phase 3f gets no diff context.

**Fix:** Set `PRE_FIX_BASE_REF=$REF` at start of each round (it's the round-baseline ref).

### C7. Codex outputs never consolidated to `findings/codex-*.txt` *(info-loss)*

**Evidence:** Codex broad/principle reviewers write to `/tmp/codex-*.txt` (per `lib/codex-invoke.sh` invocations at god-review.md:565-583). Phase 2d cat-consolidate at line 651 only globs `findings/claude-*.txt`. The Codex side is silently inert for cross-family validation.

**Impact:** Half the multi-model architecture is missing from validation. Cross-family promotion is broken.

**Fix:** Add explicit instruction in Phase 2c after Codex bash invocations: capture each /tmp/codex-*.txt content and call `write_agent_finding "codex-broad-<name>" "$(cat /tmp/codex-broad-<name>.txt)"` (or use `cp`).

### C8. `god-report.md` frontmatter `allowed-tools` missing `Agent` *(redteam)*

**Evidence:** `god-report.md:5` — `allowed-tools: Bash, Read, Grep, Glob, Task, TodoWrite`. The body uses Agent tool invocations (line ~68 single-principle delegation; the Phase 0/1/2 delegation also requires Agent calls). No `Agent` in allowed-tools means those calls fail.

**Impact:** /god-report is broken from day one — single-principle delegation can't spawn an Agent.

**Fix:** Change `allowed-tools` to `Bash, Read, Grep, Glob, Task, Agent, TodoWrite` (or just trust default tools — most slash commands omit allowed-tools entirely).

### C9. README still has `--fix`/`--loop` examples and section headers *(contradiction)*

**Evidence:** `commands/god-review/README.md` lines 93, 107, 130, 133, 138, 144, 157, 163, 264. Phase G dropped both flags but README still references them in invocation examples.

**Impact:** Users copying README commands hit "unknown flag" errors immediately.

**Fix:** Purge all `--fix`/`--loop` examples; replace with bare `/god-review` (always-on) or `/god-report` (no fix).

---

## High-Severity Cluster (~22 de-duped from 31 raw)

### Phase G regressions (didn't fix what was claimed):
- **`is_already_session_deferred` suppresses by category alone** — one weak deferral kills entire principle's coverage for the rest of loop (game­able termination).
- **auto-defer structural-anchor regex too permissive** — camelCase/snake_case in prose-soup passes (`"thisFeature is hard to fix"` → "thisFeature" matches camelCase pattern, accepted).
- **`PRE_SCAN_*` outputs computed but discarded** — never reach principle agents that could use them; dead-end (Phase E v2 #11).
- **`MIRROR_MODE=dual` documented but unimplemented** (Phase E v2 #11).
- **`--codex-validation-every` parsed but skip-gate is prose-only** — Codex validation runs unconditionally.
- **`RESCOPE_ON_FIX` parsed but `full`/`changed` modes behave identically** — no bash code computes the changed-files list.
- **`architect_malformed_count` field initialized but never written/read** — duplicate to `architect_malformed_per_round[]`.
- **`RATIONALE` never extracted from ARCH_OUTPUT** — every commit message will be `god-review: $FINDING_ID — fix` (literal, not the Architect's actual rationale).

### Genuine new bugs from Phase G:
- **`CONSECUTIVE_CLEAN_ROUNDS`/`ROUND` incremented in orchestrator-prose only** — state.json persists initial values forever; resume is broken.
- **`DEFERRED_THIS_ROUND`/`GATED_THIS_ROUND` default to 0** — never incremented in 3c/3d; `record_round_counts` always writes 0.
- **3f verifier filter is pseudocode in prose** — no bash fence reads `findings/verifier-*.txt`, computes hashes, applies the filter, exports `NEW_NEW_FINDINGS`.
- **god-review.md:9 still says "19 principles"** — frontmatter description AND Phase 2 spawn schedule (lines 509-513 say "19-principle pipeline") — actual count is 23. The 4 new failure-class detectors won't get spawned if the LLM follows line 509 literally.
- **Stash-apply revert path leaks dangling stashes** — no abort path on conflict.
- **`npm run bench 2>&1 > file` redirect order swallows stderr** — bench frameworks write to stderr.

---

## Medium / Low / Minor (raw counts: 40 / 24 / 8, de-duped: ~30 / 18 / 6)

See per-agent files. Mostly: documentation drift, vestigial state fields, edge-case path handling, unused tunables.

---

## Top 5 Highest-Leverage Next Fixes

1. **Fix C3 (cross-fence persistence)** — add ~15 vars to `write_env` whitelist + insert `write_env` calls after each 3e sub-fence. Closes C3 + 5 cascade findings. ~30 lines.
2. **Fix C2 (--ruthless real Agent invocation) + C8 (god-report Agent permission) + C9 (README --fix/--loop purge) + C4 (HAS_BENCH_SCRIPT paren) + C7 (Codex consolidation)** — mechanical, ~50 lines. Closes 5 catastrophic + ~3 cascade.
3. **Fix C1 (ARCH_OUTPUT capture from disk, not paste)** — change Architect prompt to write to `tmp/god-review/architect-output-<id>.json`; bash reads from there. Closes the apostrophe-corrupts-fix bug. ~10 lines.
4. **Fix C6 (PRE_FIX_BASE_REF=$REF)** — one-liner add at round start.
5. **Fix C5 (loop re-entry prose)** — strengthen sub-step 3g's instruction. Reference master-review.md pattern.

After items 1-5: actionable count drops from ~85 to ~25. The remaining ~25 are medium/low/minor doc-drift items that don't block functionality.

---

## Recommendation

The Phase G architecture is sound. The implementation has bugs. **Recommend a focused Phase G2 fix-pass** addressing the 9 catastrophic items above (~150 lines of mechanical edits). Do NOT redesign — the orchestrator-driven loop pattern and the split into two commands both work as intended; the bugs are correctness issues in the new code.

Phase G2 estimate: 1-2 hours of edits + Phase E v4 verification.

---

**Snapshot for revert:** `git reset --hard phase-g-baseline` (commit type)
**Per-agent findings:** `~/.claude-dotfiles/tmp/god-review/findings/{redteam,dead-end-detector,info-loss-detector,contradiction-detector,gap-detector}-v3.txt`
**Phase G plan:** `~/Desktop/CODEBASES/TOOLS/NEW SKILLS PALCEHLDER/tmp/done-plans/2026-05-06-god-review-phase-g.md`
