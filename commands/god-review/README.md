# /god-review + /god-report — Multi-Model Codebase Audit Commands

## Two Commands, One Backbone

Phase G split the original /god-review into two top-level commands sharing the
same library, principles, and broad-reviewers:

| Command | Behavior | When to use |
|---------|----------|-------------|
| **`/god-review`** | Phase 0–3, autonomous indefinite fix-loop. Runs until 3 consecutive rounds yield zero NEW non-deferred findings. Auto-fixes everything that's not a hard-gate; auto-defers (with substantive reason) what genuinely can't be fixed; queues hard-gate items (schema/auth/deps/secrets/CI/tests) for human review at end of run. | "Set this going for hours and come back to a clean codebase + a batch of human-review items." |
| **`/god-report`** | Phase 0–2 only, single-pass review. Writes `report.md`, exits. No fixes applied. Optional `--rounds N` for de-noising single-agent flukes via N independent passes. | "Just give me a snapshot of what's wrong; I'll fix it myself." |

Both commands share `commands/god-review/{lib,principles,broad-reviewers}/`.

### 4-Phase Architecture

| Phase | Name | What happens |
|-------|------|-------------|
| 0 | Context Map | Builds a shared `context-package.md`: stack fingerprint, architecture overview, hot zones, baseline gate summary. All Phase-2 agents inherit this as ground truth. |
| 1 | Snapshot + Pre-scan | Snapshots the repo state, captures perf/test gate baselines, and pre-scans for failure-mode triggers (secrets, hallucinated deps, prompt injection). |
| 2 | Parallel Principle Review | Spawns all principle agents + broad reviewers in a SINGLE message for true parallelism. Cross-model agreement promotes severity; a different-model validation sub-agent verifies findings before they are posted. |
| 3 (`/god-review` only) | Fix Loop | Always-on for `/god-review`. Orchestrator-driven loop (no bash `while`): triages findings into AUTO_FIX / AUTO_DEFER / HUMAN_GATE / REPLAYED buckets, runs Architect→Editor split per fix, snapshot/revert/re-verify, terminates on 3 consecutive zero-new-finding rounds. Hard-gate findings batch to a HUMAN_GATE_QUEUE for end-of-run human review without blocking the loop. |

### Phase-2 Two-Layer Model

**Layer A — Broad Reviewers (6 total; 7 with `--ruthless`):**
- 3 Claude broad reviewers: `claude-deep-correctness`, `claude-architecture-prod`, `claude-security-resilience`
- 3 Codex broad reviewers: `codex-cross-layer`, `codex-prod-scalability`, `codex-security-safeguards`

Each Claude broad reviewer reads the ENTIRE codebase scope and is the most expensive call in the round.

**Layer B — Principle Agents (up to 24 pairs):**
Each principle runs as a Claude agent + Codex validation sub-agent pair. Principles are in `principles/` and are also runnable standalone via `--principle <name>`.

---

## /god-review Flags (Phase G — `--fix`/`--loop`/`--report-only` dropped; always-on by definition)

| Flag | Description | Default |
|------|-------------|---------|
| `--max-rounds N` | Hard ceiling on round count (rare — usually you want to let it run to natural convergence). Only applied if explicitly passed. | unlimited |
| `--max-wall-hours N` | Wall-clock backstop. **0 disables the cap** (truly indefinite). | 24 |
| `--resume` | Continue from last per-round `state.json` checkpoint. Aborts if repo state diverged from snapshot. | off |
| `--force-resume` | Override stale-snapshot check on `--resume`. Use when you know divergence is intentional. | off |
| `--principle <name>` | Run ONE principle standalone, skipping orchestration. Example: `--principle single-pattern`. | off |
| `--rescope-on-fix {full\|changed}` | Phase-3 re-review scope after applying a fix. `changed` = only modified files; `full` = full codebase. | changed |
| `--online` | Enable npm/PyPI registry checks for hallucinated-imports detection. | off |
| `--codex-validation-every N` | Run a Codex validation pass every N rounds (cost optimization). | 3 |
| `--ruthless` | Add the skeptic-first redteam broad reviewer (Layer A). | off |

## /god-report Flags

| Flag | Description | Default |
|------|-------------|---------|
| `--rounds N` | Run N independent Phase 0–2 passes and aggregate findings (de-noises single-agent flukes). | 1 |
| `--principle <name>` | Run ONE principle standalone. | off |
| `--online` | Enable npm/PyPI registry checks. | off |
| `--ruthless` | Add the skeptic-first redteam broad reviewer. | off |
| `--codex-validation-every N` | Cost-optimization knob (only meaningful with `--rounds > 1`). | 3 |

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Clean — no findings above threshold, or all findings resolved. |
| 1 | Argument-parse error — invalid flag, missing value, etc. |
| 2 | Fix loop hit `--max-rounds` ceiling (only when explicitly passed). |
| 3 | Frozen units cap exceeded — `FROZEN_UNITS_COUNT > FROZEN_UNITS_CAP` (default 3). Runaway churn detected; loop escalates to human. |
| 4 | Instability self-abort — oscillation detected across fix rounds; reverted to last clean snapshot. |
| 5 | Wall-clock cap — `--max-wall-hours` limit hit (when non-zero). |
| 6 | Corrupt `state.json` on `--resume` — checkpoint file is unreadable or schema-invalid. |
| 7 | Stale snapshot on `--resume` — repo state diverged from checkpoint; use `--force-resume` to override. |

---

## Output Paths

All outputs are relative to the project root (the directory where `/god-review` is invoked):

| Path | Description |
|------|-------------|
| `tmp/god-review/context-package.md` | Phase 0 shared context map — stack fingerprint, architecture, hot zones, baseline gates. |
| `tmp/god-review/state.json.round_finding_counts` | Per-round audit trail (round number, new/total/deferred/gated counts). Stored in state.json, not as separate files. |
| `tmp/god-review/report.md` | Final sectioned report: Critical / Gaps / Important / Assumptions / Contradictions / Minor / Meta. Includes per-finding provenance (which principle, which model, confidence tag). |
| `tmp/god-review/state.json` | Persistent state: repo snapshot SHA, churn ledger, frozen units, kept/reverted fixes, round count, wall-clock start. |
| `tmp/god-review/perf-baseline.json` | Phase 1 benchmark baseline (only created if `HAS_BENCH_SCRIPT` is detected). |
| `tmp/god-review/perf-current.json` | Per-fix benchmark capture in Phase 3, compared against baseline. |

---

## AUTO_FIX Utility Note

AUTO_FIX is **intentionally narrow**. A fix is auto-applied only when ALL of the following hold:

1. The change is confined to a single file.
2. The change is non-irreversible (can be snapshot-reverted without data loss).
3. The change does not touch any test file.
4. The change does not touch any CI YAML file.
5. The change does not touch any hard-gated path (see Hard Gates below).

In practice, most findings are architectural, structural, or multi-file.
**Expect AUTO_FIX to auto-apply 10–30% of findings.** The rest queue to the
`HUMAN_GATE_QUEUE` section of `report.md` for manual review at end of run.
Do not expect autonomous coverage of 90% of findings; that expectation leads
to over-trust of automated patching.

---

## `/god-review` Cost Profile

The autonomous loop runs Phase 2 with up to **54 agents per round** (55 with `--ruthless`):
3 broad-Claude + 3 broad-Codex + 23 principle pairs (46 agents) + 2 batched validation = 54.
With stack-gating the typical round is ~36-40 agents:
- 3 Claude broad reviewers (each reviews the ENTIRE codebase scope — most expensive calls)
- 1 ruthless redteam reviewer (only when `--ruthless` is set)
- 3 Codex broad reviewers
- Up to 23 principle pairs (Claude + Codex sub-agent each)

**Round time: 15–30 minutes** with single-account Codex serialization.

**24h cap = 48–96 rounds = potentially 2,200–4,400 agent invocations.**

With `--ruthless`: up to 55 agents per round instead of 54. Adjust cost projections accordingly — a 24h `--ruthless` run may invoke ~100–200 additional agents over the session vs. a non-ruthless run.

To halve round time: set `CODEX_HOME_1` and `CODEX_HOME_2` environment variables to two separate `~/.codex` profile directories. The `lib/codex-invoke.sh` script alternates between them, eliminating most serialization overhead.

```bash
export CODEX_HOME_1=~/.codex-account1
export CODEX_HOME_2=~/.codex-account2
```

**Always pass an explicit `--max-wall-hours` when running long.** The default 24h cap is intentionally conservative. For most audits, 4–8 hours is sufficient. Pass `--max-wall-hours 0` for truly indefinite runs:

```bash
/god-review --max-wall-hours 6
```

---

## Repo Restrictions

`/god-review` is **forbidden on the `~/.claude-dotfiles/` repo** (the
auto-fix loop).

The dotfiles repo has an auto-push hook that commits and pushes every change.
Running `/god-review` would push N broken-state commits to the remote — one
per fix attempt per round. This corrupts the dotfiles history.

**Rule:** Run `/god-review` only on:
- A project repo with no auto-push hook, OR
- A worktree branch you can review and squash before merging

For audit-only on the dotfiles repo, use `/god-report` instead — it's
Phase 0–2 (report-only) and never writes source files.

---

## `--resume` Semantics

After a Ctrl-C, system reboot, or agent timeout, resume from the last checkpoint:

```bash
/god-review --resume
```

The checkpoint is `tmp/god-review/state.json`. It stores the repo snapshot SHA taken at Phase 1. On `--resume`, the command checks whether the current repo HEAD matches the snapshot. If it has diverged (e.g., you made commits while the loop was paused), you will be prompted to use `--force-resume`:

```bash
/god-review --resume --force-resume
```

`--force-resume` skips the stale-snapshot check and continues from the ledger state. Use only when you understand how the interim commits interact with the pending findings.

---

## Self-Test Guidance

**Smoke test on the dotfiles repo (use `/god-report`, NOT `/god-review` — see Repo Restrictions):**

```bash
cd ~/.claude-dotfiles
/god-report
```

Expected: `tmp/god-review/report.md` exists, contains all expected sections (Critical / Gaps / Important / Assumptions / Contradictions / Minor / Meta), zero or more findings (any count acceptable — the dotfiles repo is markdown-heavy; most code-shaped lenses produce zero findings). No agent crashes.

(`/god-review` is forbidden on dotfiles per Repo Restrictions section above — its auto-fix loop would push N broken-state commits to the remote.)

**E2E validation on a JS/TS project:**

```bash
bash ~/.claude-dotfiles/commands/god-review/lib/e2e-test.sh
```

This generates a synthetic test project at `/tmp/god-review-e2e-test-<pid>/` with intentional violations across 6+ principles. Follow the printed instructions to run `/god-review` against it and verify findings. See `lib/e2e-test.sh` for the full expected-findings checklist.

---

## Cleanup After Fix Loop

After N fix-loop rounds, god-review leaves N commits (one per applied fix). To squash them into a single reviewed commit:

```bash
# Squash the last N god-review commits into one
git reset --soft HEAD~N && git commit -m "god-review: apply fixes"
```

Replace N with the actual round count shown in the final report summary.

---

## Hard Gates — Never Auto-Applied

These paths and patterns are **always** `HUMAN_GATE`, regardless of command. /god-review proposes a diff in `report.md`'s HUMAN_GATE_QUEUE section but never writes the file. /god-report flags them in the report and exits.

> **Canonical source:** `lib/hard-gates.txt`. The orchestrator's `is_hard_gate <path>`
> (in `lib/env-helpers.sh`) reads that file at runtime. If the categories below
> drift from `lib/hard-gates.txt`, the file wins. **DO NOT inline patterns
> elsewhere** — they go stale.

Categories covered:

- **Schema and data** — database schema migrations
- **Auth and security** — auth path heuristics
- **Package manifests** — npm / pip / Cargo / Go modules / etc.
- **Environment and secrets** — `.env*`, credential / secret files
- **CI/CD** — workflow YAMLs
- **Tests** — test files (per `test-deletion.md` lens)
- **Build/runtime config** — `next.config.*`, `Dockerfile`, etc.
- **Quarantine** — `_deprecated/**` paths

---

## Extension Guide — How to Add a New Principle

1. **Create `principles/<name>.md`** following the template structure:
   - Frontmatter: `allowed-tools`, `description`
   - 5 phases: Gather Context, Identify Candidates, Deep Analysis, Generate Report, Output
   - Scoring Criteria section with confidence levels and severity ratings
   - "Why This Matters" section with concrete impact examples
   - "Known Issues / False Positive Patterns" section

2. **Reference `CRITERIA.md`** for canonical confidence/severity definitions. Thresholds are principle-specific — a LIKELY in `secret-leak` is more urgent than a LIKELY in `documentation`. Don't copy severity definitions inline; reference the file.

3. **Add to `CRITERIA.md` principle index table:** specify Tier (1 = always runs, 2 = stack-gated), whether it is a stack gate trigger, and whether it participates in cross-model promotion.

4. **Register at 3 sites in the orchestrator** (`~/.claude-dotfiles/commands/god-review.md`):
   - The `ALWAYS_ON_PRINCIPLES` or `STACK_GATED_PRINCIPLES` array (principle activation list)
   - The unknown-principle error-message list (the `case`/`if` block that validates `--principle <name>` values)
   - The absolute-path list block (the section listing all principle file paths, used for reference and documentation)

5. **Stack-gated principles:** if the principle only applies to certain stacks (e.g., `tanstack-query` applies only when `@tanstack/react-query` is detected), add the detection variable to the Phase 0 `stack-detect` bash block in the orchestrator. The principle's Phase 1 step should exit early with `STACK_GATE: not applicable` when the detection variable is unset.

6. **Test standalone:**
   ```bash
   /god-review --principle <name>
   # or invoke directly as a slash command:
   /god-review:principles:<name>
   ```

---

## Architecture Summary

```
/god-review (orchestrator at commands/god-review.md)
├── Phase 0: context-package.md (stack fingerprint, architecture map)
├── Phase 1: state.json snapshot, perf baseline, pre-scan triggers
├── Phase 2: parallel spawn (single message)
│   ├── Layer A: broad-reviewers/ (3 Claude + 3 Codex)
│   └── Layer B: principles/ (up to 23 × Claude+Codex pairs)
├── Phase 3 (always-on for /god-review): lib/editor-agent.md per fix
│   └── snapshot → fix → re-verify → keep/revert → churn-ledger check
└── Outputs: tmp/god-review/{context-package,report,state,round-N-findings}.md
```

Key supporting files:
- `CRITERIA.md` — single source of truth for severity/confidence definitions and principle index
- `lib/codex-invoke.sh` — Codex CLI invocation with optional 2-account threading
- `lib/editor-agent.md` — Editor sub-agent spawned by Phase 3 for atomic single-file fixes
- `lib/e2e-test.sh` — Synthetic test project generator for E2E regression testing

**Reference:** Plan at `tmp/ready-plans/2026-05-04-god-review-command.md` · Memory files at `~/.claude/projects/-Users-omidzahrai/memory/god_review_*.md`

---

## Status and Changelog

### 2026-05-06 — Phase E fix pass (8 fixes)

- Fixed Phase 3 while-loop split across 10 separate bash fences (catastrophic) — loop body now one fence
- Fixed glob_to_regex algorithm for `migrations/**`, `**/auth/**`, `*.test.*`, bare basename patterns (catastrophic)
- Wired `--ruthless` spawn block to actual Agent invocation pattern (catastrophic)
- Added 7 round-loop counters (`ROUND`, `FIXES_KEPT_THIS_ROUND`, `NET_NEW_FINDINGS_THIS_ROUND`, `CONSECUTIVE_CLEAN_ROUNDS`, `FROZEN_UNITS_COUNT`, `TOTAL_OPEN_FINDINGS`, `MAX_ROUNDS_EXPLICIT`) to `write_env` whitelist
- Wired 4 new failure-class principles (`dead-end-detector`, `info-loss-detector`, `contradiction-detector`, `gap-detector`) into `ALWAYS_ON_PRINCIPLES`, absolute-path list, and error-message list — principle count now 23
- Removed false-positive entry for HAS_BENCH_SCRIPT from `false_positives.txt` (paren count audit was wrong; expression is balanced in current file)
- Fixed `FROZEN_UNITS_CAP` self-referential default → `${FROZEN_UNITS_CAP:-3}`
- Renamed phantom `$ARCH_JSON` references (lines 979 and 1230) to `$ARCH_OUTPUT`

### 2026-05-05 — Initial fix pass + 4 new failure-class lenses

- 21 commits across Wave 1 + Wave 2 (Implementer S Groups 1-4)
- A1: cross-block var persistence via env-helpers.sh
- A7: exit codes wired (2=max-rounds, 3=frozen, 4=instability, 5=wall-clock, 6=corrupt, 7=stale)
- A8: HAS_BENCH_SCRIPT audit
- A9: hard-gate bash check before Editor spawn
- B1: real Phase 3 round loop
- B7: argument parser rewrite
- B12: --max-rounds caps the always-on loop when explicitly passed
- C1: Tunable Constants section
- C4: Step 2c/2d renumber
- C5: snapshot dir cleanup
- C7: pre-fix snapshot canonical
- D5: --ruthless spawn block
- D6: CRITERIA.md 19→23 principles
- D7+C6: README updates
- E0: known-deferred.txt
- Added 4 new failure-class principles: dead-end-detector, info-loss-detector, contradiction-detector, gap-detector

### 2026-05-04 — Initial /god-review v1 ship

- Plan at `tmp/done-plans/2026-05-04-god-review-command.md`
