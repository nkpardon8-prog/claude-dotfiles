# verify-parallel-wave / merge-wave assumption tests

Narrow-and-deep **assumption tests** (not unit tests) for `scripts/verify-parallel-wave.mjs` and
`scripts/merge-wave.sh` - the fail-closed gate and the incremental integrator behind the
write-wave machinery (plan: `tmp/ready-plans/2026-08-02-parallelizer-v1.md`, Tasks 6 and 7).

The schema authority is `docs/wave-plan-schema.md`. Every case below names the section and rule
number it proves; there is at least one case per numbered rule in sections 4 (`--validate-plan`),
6 (`--wave-state`) and 7 (the event contract), plus the merge-wave failure semantics.

**Why these get a suite:** the checker is the ONLY thing standing between "four subagents wrote
into one repo" and a silent, plausible-looking merge. Every failure it exists to catch is quiet
by nature - an undeclared write merges cleanly, an uncommitted file is simply dropped, a chunk
built against a file its sibling was rewriting compiles fine. If the checker is wrong, nothing
turns red; the wave goes green and the damage is discovered days later in unrelated work.

## Hermetic - and the env gate anyway

Every case builds its own throwaway git repo(s) and worktrees under `mktemp -d`, and points
`PARALLEL_WAVES_DIR` at a directory inside that same sandbox, so the events these tests generate
NEVER reach the real `~/.claude/parallel-waves/rework.log` (that log is the denominator for the
whole parallelism measurement - polluting it on every suite run would corrupt the number the
work is judged by). Nothing outside the sandbox is read or written except the checker, the merge
script, and the checked-in fixtures. The sandbox is removed on exit, including on failure paths.

`script.md:35` reserves `_SMOKE_ALLOW_` gates for suites that touch live infrastructure, and a
hermetic suite would normally carry none. This one keeps `WAVECHECK_SMOKE_ALLOW_DEV=true` for
the same reason its `parallel-stats` sibling does: it is invoked by the same gate list as every
other suite here, and a suite that silently runs when its siblings refuse trains the wrong
reflex. The gate is a **uniformity convention, not a safety claim** - unset it and the suite
(and each case individually) exits 2.

## What each case proves

| Case | Rules proved | Load-bearing because | watched-fail |
|---|---|---|---|
| `01-validate-plan-golden.sh` | s4 R1, R2 + the golden envelope | A known-disjoint 2-chunk plan must pass and a known-DEPENDENT one must be rejected. Accepting the dependent pair is the silent failure the machinery exists to prevent; rejecting the good one kills the feature quietly instead (every wave degrades to serial and nobody learns why). Also pins schema_version rejection and forward tolerance for unknown keys. | yes |
| `02-validate-plan-base-sha.sh` | s4 R3, s3.2 ancestry | `base_sha` is RE-PINNED every wave, so a plan analyzed at wave 1 is legitimately behind the sha passed at wave 3 - naive equality would refuse every wave after the first. The mirror risk is worse: a `base_sha` from a divergent history means every disjointness claim was computed against files that are not the ones about to be edited. | yes |
| `03-validate-plan-ids-width.sh` | s2.1, s4 R4, R5 | Chunk ids become branch AND directory names (`w<W>-<SID8>-<id>`). A duplicate id makes wave 3 collide with wave 1's worktree mid-batch; an id with a separator or metacharacter turns two machine-generated commands into something else. `WAVE_WIDTH_MAX` is a constant so no caller can raise it. | yes |
| `04-validate-plan-path-syntax.sh` | s2.2, s4 R6 | Every disjointness rule is string comparison over these entries. An uncomparable entry (`../x`, `/abs`, `src/*.ts`, `a//b`) is not a narrower claim, it is an UNCHECKABLE one - it matches nothing, so a chunk writing outside its fence looks compliant. | yes |
| `05-validate-plan-subtree-prefix.sh` | s2.3 Divergence 7, s4 R7 | A trailing-`/` over an EXISTING directory is a blank cheque over files nobody enumerated. Over a directory absent at the sha it authorizes only files this chunk will create. Because the sha is re-pinned, the same plan text must be re-judged at the NEW sha - a directory created by wave 1 makes wave 2's prefix illegal (A3/A3b run both sides of that comparison). | yes |
| `06-validate-plan-disjointness.sh` | s4 R8, R9, R10 | These three rules ARE the safety argument for spawning N writers. R9 (added by delta 2) is the subtle one: nothing collides on disk, yet chunk B builds against a file chunk A is rewriting, so the wave integrates green and is wrong. | yes |
| `07-validate-plan-command-allowlist.sh` | s2.4, s4 R11 | These commands come out of a MODEL and are then run at the barrier. Stage 1 keeps anything a shell would reinterpret away from that point; stage 2 limits it to what the repo already defines; the typecheck floor stops a wave that merges four chunks and runs nothing that can fail. | yes |
| `08-validate-plan-confidence-serial.sh` | s4 R12, R13 | The reason token IS the measurement. "We declined because the model was unsure" (`low_confidence`) and "we declined because the output was broken" (`malformed`) lead to opposite fixes. R13 is why `SERIAL_CORRECT` exits 1: a 0 would tell the orchestrator to fan out on a plan that says do not. | yes |
| `09-wave-state-worktree-rules.sh` | s6 R1-R4 | The merge only ever sees COMMITTED work. A chunk that never committed, or left an untracked file behind, merges as if it had done nothing - green wave, work discarded at teardown. That is the most expensive silent failure in the design, which is why R3 counts untracked files as dirty. | yes |
| `10-wave-state-touched-rules.sh` | s6 R5-R9 | `--validate-plan` checks what a model PROMISED; these check what four subagents DID. `--no-renames` is pinned so a rename counts BOTH sides - with detection on, moving a file OUT of a sibling's declared set would report one path and the destination would never appear in `touched`. | yes |
| `11-wave-state-repo-root-rules.sh` | s6 R10, R11, s5 | R10 is what makes an interrupted merge RESUMABLE: comparing against the recorded MERGE COMMITS (not branch tips) keeps HEAD pinned to somewhere this machinery put it. R11 is tracked-only per Divergence 9, with the plan file exempt only when it lives under the repo being integrated. | yes |
| `12-events-and-reason-tokens.sh` | s7 (all) | This log is the denominator for every later claim about the gate. An invocation that exits without writing biases it in the flattering direction; a typo'd token invents a silent category; a line over `PIPE_BUF` can interleave with a concurrent appender and corrupt the file. 12 tokens x accept, unknown-token reject, 3 modes x 2 exit paths, key order, and the 480-byte overflow rule. | yes |
| `13-merge-wave-happy-resume.sh` | merge-wave steps 1-3 | The recorded `merge_sha` is the only thing making an interrupted wave recoverable. A branch tip instead of the merge commit would make the checker reject the very tree merge-wave just produced; no skip list would merge an already-merged branch twice. Also asserts merge-wave never tears down worktrees (that is barrier step (d)'s job, after the gates). | yes |
| `14-merge-wave-refusal-and-resume.sh` | merge-wave refusal path | The untracked collision is the one failure that arrives through a PASSING checker (R11 is tracked-only by design). git refuses BEFORE starting, so no merge is in progress and `git merge --abort` must NOT run - it errors in that state (proven by dentall `03-merge-wave-failure-semantics.sh` A1/A2). Also proves a red checker merges NOTHING, a corrupt state refuses at exit 2, and clearing the obstacle resumes. | yes |
| `15-merge-wave-conflict-abort.sh` | merge-wave conflict path | The other branch of the same conditional: a real conflict means a merge IS in progress, so `--abort` runs and the tree lands clean at the last successful merge tip with `merged_chunks` untouched. When the checker hole is hit in the field, the operator's next move depends entirely on this state being accurate. | yes |

**watched-fail: yes** on every row means the case was **observed exiting 1** before it was
trusted, via the controllable precondition named in its `# NEGATIVE CONTROL:` comment. Each
mutation was applied to a temp copy of the case, run, and observed; the copy was then deleted.
Observed at authoring time (2026-08-02, `git 2.50.1`, `node v25.6.0`, bash 3.2.57):

| Case | Mutation applied | Observed |
|---|---|---|
| 01 | cleared chunk-b's `reads` in the dependent plan | A2: exit 0 where 1 expected; reason `fan_out` not `malformed`; rule-9 message gone |
| 02 | pointed the divergent `SIDE` sha at `BASE_SHA` (an ancestor) | A3: exit 0 where 1 expected; rule-3 message gone |
| 03 | narrowed the injected chunk list from 5 to 4 | A7: exit 0 where 1 expected ("4 chunk(s)"); rule-5 message gone |
| 04 | replaced `../outside.ts` with a legal `src/a.ts` | A1: exit 0 where 1 expected; rule-6 message gone |
| 05 | pointed the prefix at an ABSENT dir (`newthing/`) | A2: exit 0 where 1 expected; reason `fan_out`; rule-7 message gone |
| 06 | moved the colliding claim to an unrelated `src/z.ts` | A1: exit 0 where 1 expected; rule-8 message and both path names gone |
| 07 | dropped the `&& echo done` metacharacter | A1: exit 0 where 1 expected; rule-11 message gone |
| 08 | restored `write_set_confidence` to `high` | A1: exit 0 where 1 expected; reason `fan_out` not `low_confidence` |
| 09 | removed the uncommitted edit before the check | A3: exit 0 where 1 expected; reason `fan_out`; "uncommitted work" gone |
| 10 | redirected the stray write to the chunk's DECLARED file | A2: exit 0 where 1 expected; rule-6 message and `src/shared.ts` gone |
| 11 | added the merge record back to A3's state | A3: exit 0 where 1 expected; rule-10 message gone |
| 12 | replaced the bogus token with a legal `fan_out` | A2: exit 0 where 2 expected; reason `fan_out`; "closed set" text gone |
| 13 | blanked `merged_chunks[]` before the resume run | A6: merge-wave exit 1 (rule 10 now refuses the tree), 1 event not 2, no "skip" lines, entries duplicated |
| 14 | removed the untracked `src/new.ts` collision | A3: merge-wave exit 0 where 1 expected; no refusal text; A4 saw 2 recorded chunks instead of 1 |
| 15 | pointed the rogue branch at `src/shared.ts` instead | A2: merge-wave exit 0 where 1 expected; "MERGE FAILED"/abort text gone; HEAD advanced past the tip |

Gate: with `WAVECHECK_SMOKE_ALLOW_DEV` unset, `run-all.sh` and every individual case exit 2.

## Interpretation notes (where the schema doc needed reading, and how it was read)

The schema doc is the authority; these are the four places the implementation had to choose, all
resolved IN its favour and recorded here rather than silently:

1. **`./y` - plan text vs schema.** The plan's Task-7 list called `./y` a path-syntax violation;
   `docs/wave-plan-schema.md` s2.2 NORMALIZES a `./` prefix away and rejects only what is empty
   or `.` AFTER normalization. The schema doc wins (its header says so): case 04 A3 asserts
   `./src/a.ts` is ACCEPTED and compared as `src/a.ts`.
2. **wave-1 equality vs ancestry.** s3.2 states equality at wave 1 and ancestry on re-validation,
   but `--validate-plan` takes no wave argument, so the checker cannot distinguish the two calls.
   It enforces the ANCESTRY predicate (s4 rule 3's literal wording), which subsumes wave-1
   equality: at wave 1 the orchestrator passes the very sha the plan was analyzed at, so identity
   holds by construction and an ancestor check succeeds on identity.
3. **A structurally invalid `wave_state` exits 2, not 1.** s6's rules 1-11 are all git-state
   rules; a file that is not shaped like a `wave_state` cannot have any of them evaluated, so it
   falls under "unreadable or unparseable input -> exit 2". This is also what makes merge-wave's
   "a corrupt state file refuses loudly BEFORE any merge" hold through its inline re-verification
   (cases 09 A7/A7b and 14 A2).
4. **An invocation naming NO mode writes no event.** s7 fixes `tool_mode` to a closed
   three-value set; a mode-less argv cannot be attributed to any of them, and inventing a fourth
   value would break the set the measurement contract rests on. It prints usage and exits 2
   (case 01 A7). Every invocation that names a mode writes exactly one event, on both exit paths
   (asserted for all three modes in case 12, and re-asserted by `wc_check` on EVERY checker call
   in every case).

One branch is deliberately untested because it is unreachable: step 2 of the s7.1 overflow rule
(dropping `repo_root` entirely) cannot fire while every other field is bounded by construction -
the fixed keys total well under 480 bytes even with an 80-character `repo_root`. It is
implemented as the schema's literal fallback, not as a live path.

## Layout

```
_lib.sh                            shared fixture builders + assertions (sourced, not a case)
fixtures/golden-wave-plan.json     the KNOWN-GOOD 2-chunk plan; every mutant differs from it by
                                   exactly ONE rule violation, so a red result is attributable
fixtures/dependent-wave-plan.json  the KNOWN-DEPENDENT pair (chunk-b reads what chunk-a rewrites)
NN-*.sh                            one case per rule group, numbered in schema-doc rule order
NN-*.fingerprint.json              per-case fingerprint written at PASS time
```

`__REPO_ROOT__` and `__BASE_SHA__` in the fixtures are substituted with the sandbox repo's real
values at run time; the plans are otherwise checked in verbatim, so the golden envelope is a
literal artifact a reader can inspect, not something the suite manufactures.

`wc_check` enforces the event contract on EVERY checker invocation in the whole suite (exactly
one new event, `exit` agreeing with the process exit, `reason` and `tool_mode` inside their
closed sets), so those invariants are re-proved roughly 130 times rather than once.

## How to run

```bash
# whole suite (halts on first FAIL):
WAVECHECK_SMOKE_ALLOW_DEV=true bash scripts/verify-parallel-wave-assumptions/run-all.sh

# one case:
WAVECHECK_SMOKE_ALLOW_DEV=true bash scripts/verify-parallel-wave-assumptions/09-wave-state-worktree-rules.sh
```

## Exit codes

`0` PASS · `1` FAIL (>=1 assertion) · `2` REFUSED (env gate unset) · `3` INFRASTRUCTURE
(checker/merge script missing, `git init` failed, `mktemp` failed, or a hang -> 124|142).

## Gates

- **Pre-change:** run before touching `verify-parallel-wave.mjs` or `merge-wave.sh`.
- **Post-change regression:** re-run after any edit to either script, and after ANY change to
  `docs/wave-plan-schema.md` - a schema change without a matching suite change is exactly what
  section 8's change-control rule forbids.
- Listed in the plan's Validation Gates beside `node --check scripts/verify-parallel-wave.mjs`
  and `bash -n scripts/merge-wave.sh`.

## Fingerprints

Each case writes `<NN>-*.fingerprint.json` recording the RULE BEHAVIOUR observed at PASS time
(which exit each shape produced, which reason token, which probe command). A future re-run whose
fingerprint differs means a rule moved - re-read `docs/wave-plan-schema.md` before trusting the
new green. Fingerprints deliberately record decisions, not environment blobs: the assumption is
about what the checker decides, so that is what drift must be measured in.

## Safety

Throwaway git repos under `mktemp -d`, removed on exit. No network, no `~/.claude/` state, no
repo mutation, no PHI, no live infrastructure. Safe to run at any time, including inside a
mission.
