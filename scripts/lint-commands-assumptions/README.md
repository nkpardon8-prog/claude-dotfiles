# lint-commands assumption tests

Narrow-and-deep **assumption tests** (not unit tests) for `scripts/lint-commands/lint-skill-contract.sh`
and `scripts/lint-commands/lint-skill-size.sh` - the two guards standing between the command
files and the silent loss of the contracts they carry
(plan: `tmp/ready-plans/2026-08-02-parallelizer-v1.md`, Task 11).

**Why these get a suite.** Every failure these lints exist to catch is quiet. A launch register
that disappears from `implement.md` does not error - the command simply runs serially forever,
and nothing in any transcript says so. A register that drifts BELOW `<!-- CONTRACT-CORE-END -->`
is worse: it is present in the file, passes any grep, and is invisible to the agent that was
supposed to obey it, because a post-compaction re-injection head-truncates the body at 20,000
characters. Swept wording that re-grows by copy-paste leaves the file carrying two contradictory
launch schedules, both "present". And the lint itself fails silently in the same style: a staged
query pointed at the wrong repository reports an empty set, checks nothing, and prints success.
A guard whose own failure mode is a green tick has to be tested against its failure modes.

## Hermetic - and how

Each case builds a throwaway repo under `mktemp -d` shaped like this one:

```
<sandbox>/commands/*.md                copies of the LIVE command files
<sandbox>/scripts/lint-commands/*.sh   copies of the LIVE lint scripts
```

and runs the **sandbox copy** of the lint with cwd inside the sandbox. No env override was
added to the lint for testing: the ROOT split is the seam under test, so `ROOT` (from
`BASH_SOURCE`) resolves to the sandbox and the staged query (from `git rev-parse --show-toplevel`)
resolves to the sandbox's index. Exercising the tests IS exercising the split. Sandbox git runs
with `core.hooksPath` pointed at an empty directory, so a fixture commit can never execute this
repo's real generated hooks. The sandbox is removed on exit, including on failure paths.

Nothing outside the sandbox is written. Nothing outside it is read either, except the live
`commands/*.md` and the two lint scripts that get copied in - with one documented exception in
the negative-control mode below.

**Copies of the live command files, not checked-in snapshots.** A snapshot of three files
totalling ~100k chars would duplicate the very text the lint guards and would go stale the
moment a command file is edited, leaving a green suite proving a dead premise. Copying means
every case starts from the CURRENT truth and mutates exactly one thing, so a red result is
attributable to the mutation. The cost is that the suite depends on the live files being
lint-clean; `lc_baseline` asserts that first in every case and says so plainly when it is not,
rather than failing somewhere confusing later.

`script.md:35` reserves `_SMOKE_ALLOW_` gates for suites that touch live infrastructure, and a
hermetic suite would normally carry none. This one keeps `LINTCMD_SMOKE_ALLOW_DEV=true` for the
same reason its `parallel-stats` and `verify-parallel-wave` siblings do: it sits in the same
Validation-Gates list, and a suite that silently runs when its siblings refuse trains the wrong
reflex. The gate is a **uniformity convention, not a safety claim** - unset it and `run-all.sh`
and every individual case exit 2.

## What each case proves

| Case | Proves | Load-bearing because | watched-fail |
|---|---|---|---|
| `01-staged-mode-skips-unstaged.sh` | `--staged` checks only files in the staged set; the fallback outside a repo degrades to a staged set, never a full scan | This is what makes the lint safe to put in pre-commit at all. The hook runs on EVERY commit in this repo, including commits touching nothing under `commands/`. A lint that checked everything would block unrelated commits for reasons the committer did not cause, and the reflex that follows is `--no-verify` - which also disables the secret gate chained behind it. A2 is the control: the same tree in full mode must be RED, or A1 would also pass with a mutation that never applied. | yes |
| `02-staged-mode-fails-on-staged.sh` | a staged file missing a required literal FAILS, naming file and literal; an unstaged sibling's break is not reported; an unknown argument exits 2 | Case 01's skip is only safe if this holds. A `--staged` mode that skipped too much is the worst outcome available: a hook that runs constantly, reports nothing, and lets the register vanish from the file that carries it. The scope assertion matters too - a hook that also reported a sibling's unstaged edit trains committers to ignore its output. Argument validation stops a typo in the hook body from quietly changing what is checked. | yes |
| `03-full-mode-and-min-counts.sh` | the bare/`--all` invocation is index-independent; the `CODEX_TIMEOUT_SECS=540` min-count is enforced at BOTH sides of its boundary (3 rejected, 4 accepted) | The bare invocation is the Validation-Gates call and the only one that sees files nobody happens to be committing - drift arriving by rebase, cherry-pick, amend, or an agent editing through the `~/.claude` symlink is caught here or not at all. The min-count is the subtle rule: `req` counts LINES, so 4 means "four lens invocations still carry the self-timeout". Collection is a bounded wait on `.status` sidecars; a lens launched without it never writes one and burns the full ceiling instead of degrading to "not usable". Testing only the reject side would leave the number unpinned. | yes |
| `04-req-before-contract-core.sh` | a gated literal's first occurrence must precede the marker; missing literal AND missing marker both fail CLOSED; the comparison is relative, not a fixed offset | Presence is not the property that matters. `codex-review.md` is ~57k chars and `implement.md` ~23k, so most of each is invisible after a compaction. A4 is the case no other check can see: the register is MOVED below the marker while the file still carries two lines with the literal, so `req`'s min-count of 2 stays satisfied and only the position rule notices. A6 is the anti-tautology - lowering the marker stays green, which is only possible if the check compares positions rather than a constant that happens to pass today. | yes |
| `05-absent-banned-literal.sh` | the swept "Spawn ALL FOUR Bash calls in a SINGLE message" wording fails if it returns, with the same staged scoping as presence | The deleted sentence and its replacement are not mutually exclusive in a file. `req` cannot catch the old wording coming back, because the new wording is present too: every presence check stays green while the file hands an agent two contradictory launch counts. Re-growth is the likely failure, not the exotic one - this text is edited by agents that routinely hold an older revision of the same file in context. | yes |
| `06-linked-worktree-staged-set.sh` | a commit from a LINKED WORKTREE is linted against that worktree's staged set and that worktree's file content; the same split holds for `lint-skill-size.sh` | The seam the ROOT split exists for, and a named open risk in the plan. Linked worktrees SHARE `.git/hooks`, so a worktree commit runs the same generated pre-commit, which invokes the lint by its `$HOME` path. Before the split both the reads and the `--cached` query were pinned to `$HOME/.claude-dotfiles`, so a worktree commit was measured against the MAIN tree's (empty) staged set: every check skipped and the hook reported success having examined nothing. It matters now because the parallelizer's own write-wave machinery creates linked worktrees and has subagents commit inside them. | yes |
| `07-staged-blob-not-worktree.sh` | in `--staged` mode both lints read the STAGED BLOB (`git show :<path>`), not the worktree; a staged deletion fails CLOSED for a guarded file | The codex-review **C1 bypass**. Both lints SELECT files from the git INDEX (`staged_has`) but, before this fix, READ content from the WORKING TREE. Index and worktree diverge in the most ordinary git workflows - stage a file then keep editing, or `git rm --cached` a file you still have on disk - so a commit could record broken or absent content while the gate graded the clean copy still in the worktree and printed OK. A1 pins the core case (staged-broken/worktree-clean must fail); A3 the sharpest form (a staged deletion of a guarded command); A4 is the inverse control that proves the fix reads the INDEX and not merely the broken copy (staged-clean/worktree-broken must PASS); A5 pins the identical split in the size lint, the check pre-commit has always run. | yes |

**watched-fail: yes** on every row means the case was **observed exiting 1** before it was
trusted. The negative control is built in and repeatable rather than hand-applied:

```bash
LINTCMD_SMOKE_ALLOW_DEV=true LINTCMD_NEGATIVE_CONTROL=head bash scripts/lint-commands-assumptions/run-all.sh
```

`LINTCMD_NEGATIVE_CONTROL=head` populates the fixture with the lint scripts **as of git HEAD**
instead of the working copy - so the control tracks whatever HEAD is at the moment it runs, and
the defect it exposes moved as the scripts evolved:

- **For cases 01-06** the relevant HEAD was `7a826b8` (pre-ROOT-split): those scripts hardcode
  `ROOT="$HOME/.claude-dotfiles"`, so they ignore the sandbox entirely and report on the real
  tree (read-only) - itself the defect the ROOT split fixes.
- **For case 07** the relevant HEAD was `ac1d11a` (the ROOT split landed, but the C1 content bug
  is still live): that script reads the sandbox correctly via the split, then reads file CONTENT
  from the **worktree** instead of the staged blob - so it prints OK on a staged-broken tree with
  a clean worktree, which is the C1 bypass verbatim.

Observed at authoring time (2026-08-02, git 2.50.1, python 3.13.5, bash 3.2.57 - HEAD `7a826b8`),
every case `exit 1`:

| Case | Failed assertions | First observed failure |
|---|---|---|
| 01 | 3 | A2 control: exit 0 where 1 expected; `NO_REVIEW = true` and the filename absent from the output |
| 02 | 7 | A1: exit 0 where 1 expected (pre-change lint ignores `--staged` and knows none of these literals); A5: exit 0 where 2 expected (no argument validation) |
| 03 | 7 | A1: exit 0 where 1 expected; `need >=4, have 3` never printed (no min-count on this literal) |
| 04 | 10 | A1: exit 0 where 1 expected; `BELOW the marker` never printed (no `req_before` existed) |
| 05 | 6 | A2: exit 0 where 1 expected; `banned literal` never printed (no absence check existed) |
| 06 | 4 | A1: exit 0 where 1 expected - the worktree's staged break is invisible to a `$HOME`-pinned `--cached` query, which is the bug verbatim |

Case 07 was watched failing against the C1-buggy HEAD (2026-08-03, git 2.50.1, python 3.13.5,
bash 3.2.57 - HEAD `ac1d11a`), `exit 1` with 9 failed assertions:

| Case | Failed assertions | First observed failure |
|---|---|---|
| 07 | 9 | A1: exit 0 where 1 expected - the buggy lint read the CLEAN worktree and printed OK on a staged-broken tree; A3 same on a staged deletion; A4: exit 1 where 0 expected (it read the broken worktree, proving the fix now reads the index); A5: the size lint's identical blind spot |

(Once the fix at HEAD includes the staged-blob read, re-running the control for case 07 no longer
reproduces C1 - the durable guarantee is the case running GREEN against the fixed lint in
`run-all.sh`; the table above is the point-in-time watched-fail record.)

Gate: with `LINTCMD_SMOKE_ALLOW_DEV` unset, `run-all.sh` and every individual case exit 2.

## Two deliberate refinements of the plan's wording (recorded, not silent)

**1. Content follows the committing tree (Task 11).** Task 11 specified the split as: file
location from `BASH_SOURCE`, staged-set QUERY from `git rev-parse --show-toplevel`. Split exactly
that way, a linked-worktree commit is LISTED from the worktree but READ from the main tree - so a
break staged in the worktree is judged against the main tree's untouched text and passes. That is
the same silent pass the split was added to remove, arriving by a different route. Both lints
therefore treat the tree being committed as the authority for content in `--staged` mode. Case 06
A3 pins it.

**2. Content is the STAGED BLOB, not the worktree file (codex-review C1).** The first cut of
refinement 1 read the committing tree's WORKTREE (`CONTENT_ROOT="$GITROOT"`). But the file SET
comes from the git INDEX (`git diff --cached --name-only`), and the index diverges from the
worktree in the most ordinary workflows - `git add` then keep editing, or `git rm --cached`. So a
file staged broken (or staged-deleted) but left clean/present in the worktree still passed. Both
lints now read the exact bytes being committed:

```
resolve_content <path>  # --staged: git show :<path> materialized to a temp file (staged blob)
                        # --all:    $ROOT/<path> (working tree - no index divergence to reconcile)
```

A staged DELETION makes `git show :<path>` fail, so `resolve_content` returns nothing and every
required-literal check fails CLOSED - a deleted guarded command cannot ship. The two modes are
identical in the ordinary main-tree case where the index matches the worktree, so nothing but the
staged-divergence case changes. Case 07 pins it (A1 core bypass, A3 deletion, A4 inverse control,
A5 size lint).

## Layout

```
_lib.sh                    shared fixture builder + assertions (sourced, not a case)
NN-*.sh                    one case per behaviour
NN-*.fingerprint.json      per-case fingerprint written at PASS time
run-all.sh                 halts on the first FAIL; hang (124/142) -> exit 3
```

## How to run

```bash
# whole suite (halts on first FAIL):
LINTCMD_SMOKE_ALLOW_DEV=true bash scripts/lint-commands-assumptions/run-all.sh

# one case:
LINTCMD_SMOKE_ALLOW_DEV=true bash scripts/lint-commands-assumptions/04-req-before-contract-core.sh
```

## Exit codes

`0` PASS · `1` FAIL (>=1 assertion) · `2` REFUSED (env gate unset) · `3` INFRASTRUCTURE
(a lint script missing, `git init`/`worktree add`/`mktemp` failed, or a hang -> 124|142).

## Gates

- **Pre-change:** run before touching either script in `scripts/lint-commands/`.
- **Post-change regression:** re-run after any edit to those scripts, to the generated
  pre-commit body in `scripts/install-git-hooks.sh`, or to the required-literal inventory.
- Listed in the plan's Validation Gates beside the two bare lint invocations.

## Fingerprints

Each case writes `<NN>-*.fingerprint.json` recording the BEHAVIOUR observed at PASS time (which
shape produced which exit, which scoping rule applied). A re-run whose fingerprint differs means
a rule moved - re-read the lint before trusting the new green. Fingerprints record decisions,
not environment blobs: the assumption is about what the lint decides, so that is what drift must
be measured in.

## Safety

Throwaway git repos under `mktemp -d`, removed on exit. No network, no `~/.claude/` state, no
repo mutation, no PHI, no live infrastructure. Safe to run at any time, including inside a
mission. The one read outside the sandbox is `git show HEAD:...` in negative-control mode.
