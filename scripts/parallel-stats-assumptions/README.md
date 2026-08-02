# parallel-stats assumption tests

Narrow-and-deep **assumption tests** (not unit tests) for `scripts/parallel-stats.py`, the
transcript instrumentation the parallelizer work is measured against (plan:
`tmp/ready-plans/2026-08-02-parallelizer-v1.md`, Task 1).

They prove the *counting rules* hold - because the failure mode here is silent. A miscount does
not throw; it produces a plausible-looking percentage that a human then uses to decide whether to
build the wave machinery at all. The measurement is load-bearing, so it gets a test suite.

## Hermetic - and why the env gate is here anyway

These tests touch **nothing outside this directory**. They read the checked-in fixtures under
`fixtures/`, run `parallel-stats.py` as a subprocess with `PARALLEL_WAVES_DIR` redirected into
`fixtures/rework-log/` (or a `mktemp -d` that is removed on exit), and assert on stdout. No real
transcripts, no network, no `~/.claude/` state, no repo mutation. Re-running is idempotent by
construction: nothing is written except the per-test `*.fingerprint.json` beside each test.

`script.md:35` reserves `_SMOKE_ALLOW_` gates for suites that hit live infrastructure, and a
hermetic suite would normally carry none. This one keeps `PARALLELSTATS_SMOKE_ALLOW_DEV=true`
anyway, for one reason: it is invoked the same way as every other suite in this repo, by the same
gate list, and a suite that silently runs when its siblings refuse trains the wrong reflex. The
gate here is a **uniformity convention, not a safety claim** - unset it and the suite exits 2.

## What each test proves

| Test | Assumption | Load-bearing because | watched-fail |
|---|---|---|---|
| `01-solo-vs-batched-counts.sh` | **A1-A4** - spawn/codex turn counts on the fixture, with `message.id` groups **merged across JSONL records** | The harness writes each tool_use block to its **own JSONL record**. Grouping per record reports every batch as a run of solo turns - measured on the real 2026-08-02 sample: per-record grouping says **100%** of codex turns are solo; per-`message.id` says **68.4%**. The whole baseline is this one rule. | yes |
| `02-subagents-decoy-excluded.sh` | **A1-A3** - `/subagents/` paths are excluded from a directory walk **and** when named explicitly | Every subagent writes its own transcript. Counting them double-counts work the orchestrator did not schedule, and makes a solo-heavy orchestrator look parallel. (Decoy carries 3 spawns + 2 codex turns; naming it must change no metric.) | yes |
| `03-json-output-parses.sh` | **A1-A3** - `--json` is one parseable document, carries the counting rules, and agrees with the text renderer | The weekly replay and any later automation read `--json`. A stray stdout print, or a text/JSON divergence, makes the machine-read number quietly disagree with the human-read one. | yes |
| `04-replay-decomposed-table.sh` | **A1-A4** - `--replay` emits the decomposed wave-gate table (per condition, evaluated-vs-assumed, coverage denominators, "UPPER BOUND" label) and the nudge counts | The Tasks 5-11 build decision rests on this number. An aggregate percentage would hide that two conditions are not recorded in transcripts at all and are being *credited* as open. The decomposition is what keeps it honest. | yes |
| `05-rework-log-read.sh` | **A1-A3** - real rework events are read, fixture-sourced events are dropped, an absent log is tolerated | Rework rate is the anti-Goodhart counterweight to wall-clock. Suite-generated events leaking into it would inflate the number on every suite run; and an absent log is the *normal* state until the wave machinery ships - erroring on it would fail the weekly replay closed from day one. | yes |

**watched-fail: yes** on every row means the case was **observed exiting 1** before it was trusted,
via the route named in its `# NEGATIVE CONTROL:` comment. Observed at authoring time (2026-08-02):

- `01` - split the fixture's two-record `message.id` (`msg_a04` -> `msg_a04b`): spawn turns 4->5,
  solo 3->4, width histogram `1:3,3:1` -> `1:4,2:1`, exit 1.
- `02` - disabled the `/subagents/` filter: counted 1->2, spawn 4->7, codex 1->3, exit 1.
- `03` - added a bare `print()` before `json.dump`: `UNPARSEABLE`, all three assertions red, exit 1.
- `04` - removed the `UPPER BOUND` label (exit 1, A3); separately removed the coverage column
  (exit 1, A2 x6). *(A blunter mutation - deleting a row from `WAVE_CONDITIONS` - crashes the tool
  instead, which the runner reports as exit 3 INFRASTRUCTURE. Renderer-only mutations are the
  route that exercises the assertion path.)*
- `05` - renamed the fixture event's `repo_root` off the `-assumptions/fixtures` substring:
  events 3->4, dropped 1->0, exit 1.
- Gate: with `PARALLELSTATS_SMOKE_ALLOW_DEV` unset, `run-all.sh` exits 2.

## Fixtures

```
fixtures/
├── session-a.jsonl                     18 hand-built records - one solo spawn turn, one 3-WIDE
│                                       batched turn whose message.id SPANS TWO RECORDS, one solo
│                                       codex turn, a /codex-review Skill marker, a /implement
│                                       Skill marker, 3 TaskCreate + 1 TaskUpdate, and two
│                                       consecutive solo implementer spawns
├── session-a/subagents/agent-01.jsonl  DECOY - 3 solo spawns + 2 codex turns that MUST NOT be
│                                       counted (nested exactly as the real transcript dir nests)
└── rework-log/rework.log               4 events, one of them repo_root'd under an
                                        "-assumptions/fixtures" path that MUST be dropped
```

The fixtures are hand-authored rather than captured from a real session: real transcripts carry
PHI-adjacent content and are hundreds of MB. Every shape they encode was first **observed in a
real transcript** (multi-record `message.id` groups, `Skill` invocation markers, `TaskCreate`
without ids + `TaskUpdate` by `taskId`, `usage` token fields).

## How to run

```bash
# whole suite (halts on first FAIL):
PARALLELSTATS_SMOKE_ALLOW_DEV=true bash scripts/parallel-stats-assumptions/run-all.sh

# one test:
PARALLELSTATS_SMOKE_ALLOW_DEV=true bash scripts/parallel-stats-assumptions/01-solo-vs-batched-counts.sh
```

## Exit codes

`0` PASS · `1` FAIL (>=1 assertion) · `2` REFUSED (env gate unset) · `3` INFRASTRUCTURE
(`parallel-stats.py` missing / crashed / hang -> 124|142).

## Gates

- **Pre-change:** run before touching `parallel-stats.py`; a red here means the baseline figures
  already in circulation are suspect.
- **Post-change regression:** re-run after any edit to `parallel-stats.py`, and after any change to
  the wave-gate condition set or the rework event schema.
- Listed in the plan's Validation Gates alongside `python3 -m py_compile scripts/parallel-stats.py`.

## Fingerprints

Each test writes `<NN>-*.fingerprint.json` with the counting-relevant facts at PASS time (turn
counts, width histogram, exclusion behaviour, condition-row count, rework drop behaviour). A
future re-run whose fingerprint differs means the counting rules moved - **re-validate the
baseline artifact**, do not auto-trust the new green. Fingerprints deliberately record *counts*,
not environment blobs: the assumption is about counting, so that is what drift must be measured in.

## Safety

Read-only against checked-in fixtures plus one `mktemp -d` removed on exit. No production or
`~/.claude/` state is read or written. Safe to run at any time, including inside a mission.
