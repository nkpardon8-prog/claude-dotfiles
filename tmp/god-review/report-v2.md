# god-review Report v2 (Phase E verification)

**Generated**: 2026-05-06
**Scope**: `~/.claude-dotfiles/commands/god-review/` + `~/.claude-dotfiles/commands/god-review.md`
**Mode**: Phase 0–2 with `--ruthless` flag (verification re-review after 21-commit fix-pass)
**Snapshot ref**: `fe43304` (stash)
**Agents run**: 5 (1 ruthless redteam + 4 new failure-class detectors)

**Verdict: PIPELINE WORKS, IMPLEMENTATION HAS 3 STRUCTURAL BUGS**

The lenses functioned exactly as designed. They caught real bugs that 7 plan-reviews + 4 implementer agents missed. This is the strongest validation of the architecture: the failure-class detectors found failure classes the checklist couldn't.

---

## Comparison: First audit vs this audit

| Metric | First audit (28 findings) | This audit (38 findings) |
|---|---|---|
| Catastrophic / load-bearing | 8 | **3 + 5 high-severity follow-ons** |
| Cross-agent agreements | 6 (`(both)` tag) | 7 (multiple lenses caught same bug) |
| New-class findings (dead-end / info-loss / gap / contradiction) | 0 (lenses didn't exist) | **27 — the new lenses fired hard** |
| Fix-pass collateral | N/A | Several "fixed one thing, broke another" |

**Counter-intuitive but expected:** the count went UP because the new failure-class lenses found things the original 19 lenses couldn't. Net signal quality went up — almost every finding is *structural*, not nit-level.

---

## Critical [must fix] — 3 catastrophic bugs

### 1. Phase 3 `while` loop is split across 8 separate bash fences ⚡

**Source**: `redteam + gap-detector + info-loss-detector` (3-source agreement → strong promotion)
**Evidence**: `god-review.md:809` opens `while ... do`. The matching `done` is at `god-review.md:1406`. EIGHT independent ` ```bash ` fences sit between them. Each fence is a separate bash invocation.
**Impact**: First fence exits with "syntax error: unexpected end of file." Bounded mode never increments ROUND. `--loop` mode never converges. Every `exit N` (codes 2–7 from commit `2dd64ec`) is unreachable. **The Phase 3 fix loop is non-functional.**
**Fix**: Either merge all Phase 3 logic into ONE bash fence, OR convert the round loop to a recursive Agent invocation, OR move Phase 3 to a separate sourced shell script that runs as a single subprocess.

### 2. `glob_to_regex` produces wrong regex for nearly every hard-gate pattern ⚡

**Source**: `redteam` (live-tested with 5 example paths)
**Evidence**: `migrations/001_init.sql` vs `migrations/**` → MISS. `tests/foo.spec.ts` vs `tests/**` → MISS. `src/auth/login.ts` vs `**/auth/**` → MISS. `src/foo.test.ts` vs `*.test.*` → MISS. `frontend/package.json` vs `package.json` → MISS.
**Impact**: `is_hard_gate()` silently returns "not gated" on the most important hard-gated paths. Schema migrations, deps, .env, test files all become AUTO_FIX-eligible. **The hard-gate safety mechanism is structurally inert.**
**Fix**: Two algorithm bugs in `lib/env-helpers.sh:8-37`:
  - Pattern `**/`: needs `(?:.*/)?` followed by the rest, not `(?:.*/)?` alone
  - Single-segment patterns (`package.json`): need a `(^|.*/)` prefix to match in subdirs
  - Add `.*` suffix where appropriate

### 3. `--ruthless` spawn block is comments-only ⚡

**Source**: `redteam + gap-detector` (both flagged independently → promoted)
**Evidence**: `god-review.md:536-546` parses the flag and `echo`s "Spawning..." but the body is 4 `#` comment lines describing what should happen. No `Agent` tool invocation. The 4th broad reviewer never spawns.
**Impact**: `--ruthless` is parsed-and-stored but never honored at runtime. The whole point of the flag is dead.
**Fix**: Replace comment block with the actual Agent tool spawn pattern (Bash `cat` of the prompt + Agent invocation, like the 3 existing broad-Claude reviewers).

---

## Critical [follow-on] — 5 high-severity issues from these 3

### 4. Round-loop counters die at every fence boundary

**Source**: `info-loss-detector + dead-end-detector` (both)
**Evidence**: `ROUND`, `FIXES_KEPT_THIS_ROUND`, `NET_NEW_FINDINGS_THIS_ROUND`, `CONSECUTIVE_CLEAN_ROUNDS`, `FROZEN_UNITS_COUNT`, `TOTAL_OPEN_FINDINGS`, `MAX_ROUNDS_EXPLICIT` are initialized at `god-review.md:784` but NOT in the `write_env` whitelist (`lib/env-helpers.sh:20-24`).
**Impact**: Even if Bug #1 were fixed, the loop counters wouldn't survive bash-fence boundaries. Termination logic always sees zero / empty.
**Fix**: Add all 7 counter vars to `write_env`'s var list.

### 5. The 4 new principles never spawn

**Source**: `gap-detector + dead-end-detector` (both)
**Evidence**: `dead-end-detector`, `info-loss-detector`, `contradiction-detector`, `gap-detector` exist as files and are listed in `CRITERIA.md:138-141`, but `grep -c` against `god-review.md` returns 0. They're absent from `ALWAYS_ON_PRINCIPLES` (lines 454-470) and the absolute-path list (581-601).
**Impact**: README/CRITERIA say 23 principles, orchestrator runs 19. The 4 lenses that caught most of THIS audit's findings would never run on a normal `/god-review` invocation. They were only invoked for this verification because we manually spawned them.
**Fix**: Add all 4 to ALWAYS_ON_PRINCIPLES, the absolute-path list, AND the `--principle <name>` error-message list at `god-review.md:144`.

### 6. `HAS_BENCH_SCRIPT` python expression actually IS broken (audit was wrong)

**Source**: `redteam` (live-reproduced SyntaxError)
**Evidence**: `print(next((k for k in scripts if k in ('bench','benchmark','perf')),''))` — 7 open parens, 6 close. Live-reproduces `SyntaxError: '(' was never closed`. The orchestrator captures stderr to /dev/null and falls through silently.
**Impact**: A8's "false positive confirmed via ast.parse" commit (`803dad3`) is wrong. Audit was run on a different string than what's in the file. Perf-benchmark principle silently never activates.
**Fix**: Add the missing close paren.

### 7. `FROZEN_UNITS_CAP` has no default fallback

**Source**: `dead-end-detector + info-loss-detector + contradiction-detector` (3-source)
**Evidence**: `god-review.md:167` is `FROZEN_UNITS_CAP="$FROZEN_UNITS_CAP"` (self-referential) instead of `FROZEN_UNITS_CAP="${FROZEN_UNITS_CAP:-3}"`. Empty when unset.
**Impact**: Bounded-mode escalation gate at line 1363 errors with "integer expression expected" or silently treats empty as 0.
**Fix**: One-character edit.

### 8. `ARCH_JSON` referenced at lines 979 and 1230, never assigned

**Source**: `redteam`
**Evidence**: The actual variable from Architect output is `ARCH_OUTPUT`. `ARCH_JSON` is a phantom.
**Impact**: Codex Editor receives empty payload. Revert path silently no-ops.
**Fix**: Rename to `ARCH_OUTPUT` at both call sites.

---

## Important — 7 medium-severity issues

9. **`finding_history_hashes` initialized in state.json but never written** (redteam) — the "do not retry reverted fixes" check is permanently false.
10. **`/tmp/claude-findings-consolidated.txt` read but never written** (info-loss-detector) — Phase 2d cross-family validation gets empty input.
11. **Hard-gate list duplicated in 4 places despite "DO NOT inline" header** (contradiction-detector) — `god-review.md:821`, `god-review.md:1467-1475`, `lib/editor-agent.md:52-58`, `README.md:190-209` all drift.
12. **README cost arithmetic doesn't add up** (contradiction-detector) — claims 47 total but 3+1+3+46+2 = 55.
13. **Tunable Constants block is the one block missing `source env-helpers.sh`** (info-loss-detector).
14. **`is_hard_gate()` defined twice in env-helpers.sh** (redteam) — lines 62-75 dead, 78-91 active.
15. **Step 0.5 single-principle delegation list missing 4 new principles** (redteam + contradiction-detector).

---

## Minor — 8 low-severity

16. `LATE_IMPORT_LINE` declared but never referenced.
17. `SPINLOCK_TIMEOUT_SEC` declared but `codex-invoke.sh:98` hardcodes 600.
18. `consecutive_no_change_rounds` initialized in state.json, never used (vestigial).
19. `false_positives` state.json field never written.
20. `MAX_ROUNDS_EXPLICIT` not honored in bounded-mode termination at line 1371.
21. `known-deferred.txt` lives at `lib/known-deferred.txt`, not `tmp/god-review/known-deferred.txt` per E0 spec.
22. `claude-ruthless-redteam.md` body doesn't actually enforce 30/40/30 effort split.
23. `PRE_SCAN_HALLUCINATED` initialized but never assigned, undercounts pre-scan flag total by ⅓.

---

## Cross-cutting observations

- **The 4 new failure-class lenses are doing exactly what they were designed for.** Combined they caught 27 of the 38 findings. The original 19 lenses + the 3 broad reviewers caught only 11.
- **`/god-review` doesn't dogfood itself**: nothing in the orchestrator runs the new principles automatically. Recommended fix is finding #5 (wire them into ALWAYS_ON_PRINCIPLES).
- **The `(both)` cross-source promotion is firing correctly**: bugs flagged by 2+ lenses are visible as the most actionable.
- **Several "fixes from the first audit broke things"** is real. A1 (cross-block var persistence) worked for the env-helpers.sh source but the round-loop counters were forgotten. B7's argument parser added MAX_ROUNDS_EXPLICIT but it wasn't added to write_env. C1's Tunable Constants section is missing the source line itself.

---

## Top 3 highest-leverage next fixes

1. **Move Phase 3 round loop into a single bash fence** (or extract to `lib/phase-3-loop.sh`). Unblocks Bugs #1, #4, and the entire `--fix` mode.
2. **Fix glob_to_regex algorithm + wire `is_hard_gate` into actual Phase 3 triage** (currently using inline literal instead of the function). Restores the hard-gate safety mechanism.
3. **Wire 4 new principles into ALWAYS_ON_PRINCIPLES + absolute-path list + error-message list**. Activates the 4 lenses that caught most of this audit.

After these 3 fixes ship, expected: <10 findings on next re-run.

---

## Phase E target check

Plan target: **<15 findings excluding deferred items.** Current: **38 findings, 7 deferred**, leaving 31 actionable. **Target NOT met.**

But the math is misleading: 27 of the 38 came from the NEW lenses that didn't exist in the first audit. The first audit's 28 findings → this audit re-finds about 11 of them = **same-lens findings dropped from 28 to 11** (60% reduction). The new lenses then surfaced 27 new structural issues that were always there but invisible.

The lenses worked. The implementation needs a third pass.

---

**Snapshot for revert**: `git stash apply fe43304bd5b5b8394429f14f323cb741d9e34674` (REFTYPE=stash)
**Per-agent findings**: `~/.claude-dotfiles/tmp/god-review/findings/{redteam,dead-end-detector,info-loss-detector,contradiction-detector,gap-detector}.txt`
