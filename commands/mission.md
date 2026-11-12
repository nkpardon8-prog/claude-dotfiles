---
description: "Autonomous build conductor; scales rigor per part by risk tier. Opt-in and HEAVY: a strategist sets a recipe (tier, budgets, live proof) per part, then each part runs research -> /plan --mission -> /implement -> budgeted delta reviews -> a frozen-SHA close, landing as it goes. Large multi-part builds only."
argument-hint: "[roadmap/goal | resume | clear [reason] | status | stats | tidy | (blank=status)]"
---

# /mission - autonomous build conductor

A judgment-driven PLAYBOOK, not an engine: it conducts research -> `/plan --mission` -> `/implement`
-> `/codex-review` per part over the durable mission bridge, across compactions. Rigor scales with
each part's risk tier and with measured value, never with fixed round counts. Rules that matter are
REFUSALS in `mission-write.sh`, not prose: when the writer refuses, do the named remediation; never
argue past it. Reference files: `docs/mission/wake.md` (the wake routine, the only file a tick
reads), `docs/mission/reference.md` (verb detail, line grammar, rare paths),
`docs/mission/planted-bugs.md` (the planted-bug fixture).

## CONTRACT CORE

Self-sufficient for a post-compaction agent; the detail below the marker and in the reference files
must be read on a live invocation.

### A. CONTINUATION-OWNER INVARIANT

A `/mission` turn ends ONLY (a) right after a SUCCESSFUL `ScheduleWakeup` (delay up to 3300 s,
prompt = the §12 tick, only the tick-lock release may follow), or (b) at a sanctioned stop (§12.3 in
wake.md, incl. an open `AWAIT kind=human`). A scheduled wake is the ONLY continuation owner: a
tracked `run_in_background` job is not (its wake can be lost), so a turn with a job pending still
schedules a heartbeat. A failed `ScheduleWakeup`: retry once, then `pending-stop` + STOP LOUD. A
commit, a finished unit, a report, a peer reply or a park is NOT a stop, and announcing an action
never substitutes for taking it. Every wake source enters the §12.1 wake routine; its step 7 is the
mandatory exit gate.

### B. Resolve sid, root, file (§1)

- `sid` = `$CLAUDE_SESSION_ID`, else `$CLAUDE_CODE_SESSION_ID`; both empty -> STOP (never guess).
- `. "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"; root=$(handoff_canonical_root)`.
- `mfile=$(mission_resolve_path "$sid" "$root")`; empty = this session has no mission (never adopt
  the newest file); non-zero rc = STOP. A mission is always owned by your own sid.
- Before mission WORK: `timing-resume <sid> <root>` (advisory). `MISSION-START` / `WORK-START` are
  lib-only `[mission] MISSION-START` lines (the `log` verb refuses them).

### C. Dispatch (§2)

blank/`status` -> read-only: `bash $HOME/.claude-dotfiles/scripts/hooks/lib/mission-status.sh status <sid> <root>`
plus PLAN directive and PENDING DECISIONS. `clear [reason]` -> `MISSION-CLEARED status=cleared
reason=<slug>` (EMPTY idtag), then `archive-close`. `stats` -> `mission_stats_render`. `tidy` ->
`mission_archive_sweep "$root"`. `resume` -> the `§2b` picker (reference.md): `mission_fork` clones
the pick into THIS sid; fork failure = HARD STOP; never auto-inferred. Free-text roadmap -> BUILD
(seed PLAN via `create`, then the strategist). Ambient intent ("apply the /mission methodology") ->
ADOPT: the same, session-sticky until `/mission clear` (cases: reference.md).

### D. Bridge and write contract (§7)

`MISSION.<sid>.md` holds four MZONE-fenced zones: PLAN (write-once; line 1 `MISSION MODE:
build|adopt`; only `rebaseline` rewrites it), DURABLE NOTES, PLAN CHALLENGES, PENDING DECISIONS;
beside it `MISSION.<sid>.log` and `.mission-backups/`. Every mutation is Claude via the byte-locked
invocation (absolute path, no `cd`, no env prefix, no `~`):

```
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh <verb> <sid> <root> [args]
```

Verbs: `create` `log` `await` `note` `challenge` `pending` `pending-stop` `resolve` `rebaseline`
`render-banner` `timing-resume|contact|close` `archive-close` `bank-review` (sole writer of proto=2
review evidence and of every `dry=` raise). Bare-token read verbs (no status line): `await-state`,
`cursor-hash`, `budget-state`, `part-state`, `void-count <sid> <root> <N> <K>` (`-1` = STOP), `parse-codex-header`.
Codex NEVER writes the bridge. Untrusted text (roadmap, reviewer output, questions) is never inlined
in a shell arg: capture it via a quoted heredoc or file and pass `"$VAR"`.

The writer always exits 0; read its one status line. `ok` is the ONLY success. `COLLISION` -> stop,
re-derive numbering, reconcile with the log. `REROUTED-TO-NOTES` -> re-log terser. `FAILED rc=N`:
rc=1 refused (fix the shape or do the named remediation), rc=2 corrupt bridge -> STOP LOUD, rc=3
lock busy -> retry about 5x, rc=4 a gate refusal (PART-DONE, live-verify, `part-over-budget`,
`part-retired`, cutover) blocks advance - do what it names, rc=5 wrong-gen idtag. `pending-stop`:
its ONLY proceed-able outcome is `ok id=pd:<seq>-<slug>`;
EVERY non-zero rc means the STOP did NOT open - never proceed. A cutover refusal reads "playbook changed; re-read commands/mission.md before
starting another part": re-read this file, then retry.

### E. LOG grammar (§7; full table in reference.md)

On disk `<idtag>\t<entry>`, under 480 B; verbose detail goes in a `note` FIRST, then the terse line.
gen>=2 idtags are auto-prefixed `g<G>-` (pass the bare form). `at=` is writer-stamped: omit it.
- Round: `[mission] part=<N> name=<slug> phase=<research|plan|implement|review|fix> round=<K>
  dry=<D>[ findings=<n>][ open=<n>]`, idtag `m<N>-<phase>-r<K>-d<D>`. Plan lines carry `open=`.
- `[mission] PART-START part=<N> name=<slug> proto=2 worktree=<abs path> base=<sha12> needs=<none|N[,N...]>` (`m<N>-part-start`).
- `[mission] RECIPE part=<N> v=<1|2> tier=<low|normal|high> floor=<none|money|phi|auth|odwrite|migration>[,...] plan=<cap> review=<budget> budget=<min> live=<yes|no> overlap=<none|plan-next> needs=<none|N[,N...]>` (`m<N>-recipe-v<V>`).
- `[mission] SWEEP part=<N> round=<K> types=<KEY,...> sha=<sha12> instances=<n> report=<path>` (`m<N>-sweep-r<K>-s<S>`).
- `[mission] FULL-SUITE part=<N> sha=<sha12> attempt=<a> base=<sha12> env=<key-hash> completed=yes new-reds=<n> report=<path>` (`m<N>-suite-<sha12>-a<a>`).
- `[mission] live-verify part=<N> sha=<sha12> attempt=<a> status=<sent|ok|fail|n/a> [evidence=<token>|reason=<slug>]` (`m<N>-live-<sha12>-a<a>-sent` / `-result`).
- `[mission] FAIL part=<N> phase=<P> reason=<slug> attempt=<A>` (`m<N>-fail-<reason>-<A>`).
- Park: `[mission] FAIL part=<N> park=<reason> disposition=<reverted|isolated|left-with-recorded-risk> range=<base12>..<head12>` (`m<N>-fail-park`).
- `[mission] ANCHOR part=<N> sha=<sha12>` (`m<N>-anchor`): `ANCHOR` is written only by the writer (at PART-DONE, or when a
  proto=2 PART-START first needs a legacy part); `log` refuses it.
- Written by `bank-review` only: REVIEW-EVIDENCE (`scope=<plan|delta|close> base= head= ... new= repeat=
  rkeys= result=`, `m<N>-review-evidence-<scope>-r<K>`), the `phase=review` round line or `[mission] VOID`,
  the close result, the dry raise.
- Lifecycle: `[mission] PART-DONE part=<N> (converged)`, `[mission] PART-RETIRED part=<N>`,
  `[mission] test-trust part=<N>=<ok|added|n/a>`, `[mission] SNAPSHOT` (lib), `[mission] AWAIT`
  (via `await` only), `[mission] DECISION op=<seq>-<slug> outcome=<approve|deny>`,
  `[mission] MISSION-CLEARED status=<achieved|could-not|cleared> reason=<slug>` (EMPTY idtag),
  `[mission] MISSION-REBASELINED status=active gen=<G>` (lib).

### F. Strategist and recipe

`/plan --roadmap` runs at mission start, at every part boundary (after PART-DONE or PART-RETIRED,
before the next PART-START) and once for an over-budget re-plan. Inputs: the goal, the explorers,
`<root>/.mission-escaped.md`, per-part metrics, the last planted-bug result. Output: a RECIPE per
part (written to `tmp/mission/recipes.md`, full reasoning in a `note`) plus a one-screen owner
summary; it assigns recipes, never merges or splits parts. First start waits a one-minute owner OK;
boundary re-runs proceed (`challenge` if a tier changes). Tiers: low (config/docs) plan 3, review 3,
120 min; normal (features) 5, 8, 300 min; high (money, PHI, auth, OD writes, migrations) 7, 15, 480
min; live-wait cap 120 min cumulative per part. Unsure = high; a `floor!=none` needs `tier=high`;
escapes raise tiers. Bank RECIPE v1 right after PART-START; v2 only for a real overrun; v3 refused.
`needs=` lists the parts this one builds on (unsure = the previous part); PART-START carries it and
every RECIPE (v1 and v2) repeats its PART-START `needs=` verbatim (the writer refuses a mismatch).

### G. Per-part loop

proto=2 parts only. A grandfathered part (`part-state` says `proto=1`) never runs this loop, §H2, §I
or §J: it finishes under the frozen pre-rework playbook `docs/mission/legacy-playbook.md`, with
reference.md "Legacy compatibility overrides" winning over its text (lock entry, park).
1. PART-START `proto=2` in the part's linked worktree, `base=` the last finished part's freeze SHA
   (land-first stacking); the writer refuses it while another part is open, unless every `needs` part
   is PART-DONE with its anchor in the base, or if the base holds any commit of an isolated range.
2. RECIPE v1, then research: a Claude explorer plus a Codex Terra fact pass, in parallel.
3. Plan: `/plan --mission --round <K> --ledger <file> --report <path>` per round; bank each with
   `bank-review ... plan`. Design level; IMPL/PROOF findings go to Builder notes. Stop after 2 rounds
   with no new DESIGN finding or at the tier cap. `phase=implement` is refused unless the last plan
   line has `open=0` (resolve, descope in the plan, or park). /plan never asks the user here.
4. `skill: implement --no-review <plan path>` in the part worktree (`parallel` chunks per the plan).
5. Code review loop (§H2), then the close (§I).
Every helper gets a `mission-watchdog.sh` beside it; every Codex run gets a `codex-runs` line (§5).

### H2. Review stopping

BLOCKING, stated once: wrong behavior reaching a user or record, data loss, a money error, a
security or tenant breach, PHI exposure, a broken operator or recovery path, or
a test that can pass while the thing it guards is broken. Everything else is NON-BLOCKING: recorded
verbatim, never fixed in-part.
Classify by which list it belongs to, not by how confident or how large the finding is. The Sol
verify lane tags every blocking finding `new|repeat` against the ledger; a round is VOID unless
verify succeeded and `tagged == blocking` across both barrier lanes; the conductor never re-grades.
Round 1 = the whole part (`--base <PART-START base>`); clean -> `dry=1`. Fix every blocking finding
(new and repeat) and commit; later rounds use `--base <last reviewed head>`. Continue while rounds
surface new types, up to the recipe `review=` budget. `repeat>0` -> one class sweep before the next
round (a second dirty sweep on the same types -> redesign). `redesign=<area>` from `bank-review` ->
`phase=plan` scoped to that area, implement, resume review (same budgets). Budget spent -> park (§J).
Three VOIDs in a row -> `panel-unavailable-3x` -> STOP LOUD.

### I. Close and PART-DONE gate

The freeze is the head that banked `dry=1`, on a clean worktree; from then on the window is FROZEN
(no code change, no `phase=fix`/`implement`) until PART-DONE. Three legs on that SHA, in parallel:
the full-part close review (`--base <PART-START base> --scope full`, banked on its own by
`bank-review ... close`), the full suite (`FULL-SUITE ... completed=yes new-reds=0`), the live proof
(`live-verify status=sent`, then `ok`; `n/a` only when the recipe says `live=no`). `bank-review ...
join` banks `dry=2` once all three exist. An infra-only failure at an unmoved HEAD reruns that leg
as `attempt+1` (no delta, no dry reset); anything else resets dry: fix, delta round, new freeze.
PART-DONE is refused unless the recipe, dry=2 bound to the freeze, both legs, sweep coverage of every
repeat type, the budget and the v2 fingerprint all check out. Then push-queue line, morning report,
plan retirement (`PART-RETIRED`), strategist, next PART-START.

### J. Budget and park

`budget-state` every wake. The clock is minutes since PART-START; it pauses only while live proof is
the sole open leg. Over budget, every part-N work write is refused rc=4 `part-over-budget`. Exits:
one re-plan (strategist, RECIPE v2, clock resets once), or park. Park is non-blocking, never a STOP,
and it never opens a human AWAIT: stop the part's helpers, log the park FAIL (§E,
`park=<reason> disposition=<d> range=<base12>..<head12>`), PushNotification, PART-RETIRED, strategist,
next PART-START. Disposition: `reverted | isolated | left-with-recorded-risk` (default `isolated`
for confirmed blocking defects). After PART-RETIRED, part-N writes are refused `part-retired` (a
late completion is an expected drop: no FAIL) and its job AWAITs stop gating the wake.

### K. `§8` resume read

The single canonical recovery idiom lives in wake.md §8: grep `[mission] ` over ALL rotated archives
oldest -> newest, THEN the live log (never `tail -n 40`, never the newest archive alone). Intent
precedence: PLAN > handoff north_star > any ledger or summary line.

### L. Hard rules and loud stops

Never hand-edit PLAN (`challenge` loudly; `rebaseline` is the only rewrite). STOP LOUD, with a
PushNotification first: 5 FAILs for one part+phase (gen-sliced), `panel-unavailable-3x` the moment it
is logged, `void-count -1`, a corrupt bridge (`FAILED rc=2` or failed `mission_verify`; point at
`.mission-backups/`). Blocked on a human: no gate -> `pending` + loud assumption, proceed; gates this
item -> `pending`, move to independent work; gates everything -> `pending-stop`. Credential,
destructive or external-side-effect skills need a human decision (`pending-stop`), never auto-run.
Close order: `timing-close` -> `MISSION-CLEARED status=achieved|could-not` -> `archive-close` ->
disarm the liveness file.

### M. Quality signals and throughput

LAND FIRST: at PART-DONE append the freeze SHA to `~/.claude/push-queue.md` (§10); the next approved
part builds on it overnight, landing approval never blocks it. Known reds are matched by baseline,
never re-proven (§5). Model routing: Codex `gpt-6.1-terra` for cheap work (research, lookups, log and
output summaries, mechanical edits, doc drafts); `gpt-6.1-sol` at high effort for every plan and code
review lane, sweeps and verify. Never Terra for review. Waiting on a job: 1500-3300 s heartbeats.

<!-- CONTRACT-CORE-END -->

## §1-§2 Detail

`/mission status` renders one line per part (wall minutes, live-wait minutes, tokens, plan and
review rounds, sweeps, escapes, done / parked with disposition / deferred) plus the last planted-bug
result. BUILD and ADOPT seed the PLAN with `create` (idempotent: an existing verified file returns
`ok` and keeps its PLAN - then check `mission_state` and PLAN against this build and `rebaseline` if
either says so); full case list and the `§2b` resume picker are in reference.md. Seed text:

```bash
PLAN=$(cat <<'EOF'
MISSION MODE: build
<the multi-part roadmap: parts, sequence, intended outcome>

Standing directive: every part runs research -> /plan --mission -> /implement -> budgeted review ->
frozen-SHA close per its RECIPE; land each finished part first (push queue); /pre-compact freely;
active until a [mission] MISSION-CLEARED line appears in the LOG.
EOF
)
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh create <sid> <root> "$PLAN"
```

## §3 Strategist detail

Owner summary at first start: one screen, parts with tier, floor, budget and live yes/no; wait one
minute for an OK before an overnight run. Bank the recipe the strategist wrote for the part being
started, right after its PART-START:

```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] RECIPE part=<N> v=1 tier=<t> floor=<f> plan=<cap> review=<budget> budget=<min> live=<yes|no> overlap=<o> needs=<n>" "m<N>-recipe-v1"
```

`overlap=plan-next` lets part N+1's research and draft notes run while N is in review or closing;
no RECIPE, plan line or plan round for N+1 before its own PART-START. A parked predecessor does not
block an independent successor (prerequisites are `needs=` only); its dependents are refused and
shown as deferred. A real re-scope uses `rebaseline`. Small work runs as a low-tier part.

## §4 Part-loop detail

**Part start.** Create a fresh part worktree at its base (`git worktree add <path> <base>`; the writer
refuses a worktree whose HEAD is not `base=`), then:

```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] PART-START part=<N> name=<slug> proto=2 worktree=<abs path> base=<sha12> needs=<none|N[,N...]>" "m<N>-part-start"
```

**Research.** Fan out in ONE message: a Claude `codebase-explorer` (its definition's model) and a
Codex fact pass, prompt via file, never inlined:
`CODEX_MODEL=gpt-6.1-terra CODEX_EFFORT=high bash /Users/omidzahrai/.claude-dotfiles/scripts/codex-exec.sh <promptfile> <outfile> <worktree>`;
anything but `ok` in `<outfile>.status` = degraded (note it, lean on the Claude pass).
Contradictions -> `pending` + `note`, proceed on the better-evidenced branch. Log the research round.

**Plan.** Per round K: `skill: plan --mission --round <K> --ledger <file> --report <path>`, then
`bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh bank-review <sid> <root> <N> <K> plan <report>`,
then the plan line `... phase=plan round=<K> dry=0 open=<n>`. The ledger (`tmp/mission/p<N>/ledger.md`)
holds the rubric, the part's prior TAG rows and the escaped-bug types. Log `test-trust` before the
first implement round.

**Code review round K.** Open the barrier, then run both lanes in ONE message, blind to each other:

```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh await <sid> <root> "part=<N> phase=review round=<K> kind=job op=review-barrier attempt=<A> need=3 got=0"
```

- the `implementation-reviewer` subagent (its own definition; findings written to a file);
- `skill: codex-review --effort high --ledger <file> --base <sha>` (round 1: the PART-START base;
  later: the last reviewed head), with a `mission-watchdog.sh ... review <run-dir>` beside it.

Each lane persists its result to DURABLE NOTES, then sets ONLY its bit (`got=1` impl, `got=2` codex;
the reader ORs them). At the join (`ready=1`): `skill: codex-review --verify <run-dir> --with
<impl-reviewer findings file>`, then

```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh bank-review <sid> <root> <N> <K> delta <report-final.md> <impl-reviewer findings file>
```

It checks panel completeness (4 Codex + 3 Claude + the outer reviewer + verify), `tagged ==
blocking`, the report identity and base/head; writes REVIEW-EVIDENCE plus the round line or VOID;
raises `dry=1` only on a clean round with HEAD == report head and a clean tree; reports `repeat=` and
`redesign=`. A refusal or VOID is re-run fresh, never hand-banked.

**Fix.** `log ... phase=fix round=<K> dry=0 findings=<b>`, fix every blocking finding, commit in the
part worktree, run the targeted tests (§5), then round K+1.

**Sweep** (`repeat>0`): one Codex Sol pass over the full part diff listing every instance of the
repeat type keys (`CODEX_MODEL=gpt-6.1-sol CODEX_EFFORT=high bash /Users/omidzahrai/.claude-dotfiles/scripts/codex-exec.sh ...`),
fix all, commit, re-sweep until clean, logging each:

```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] SWEEP part=<N> round=<K> types=<KEY,...> sha=<sha12> instances=<n> report=<path>" "m<N>-sweep-r<K>-s<S>"
```

PART-DONE needs a clean sweep covering every repeat key, at or after the last fix commit.

## §4.6 Close detail

At `dry=1`, launch the three legs in ONE message on the freeze SHA, each with a watchdog:
1. `skill: codex-review --effort high --ledger <file> --base <PART-START base> --scope full` plus the
   implementation-reviewer; at its join `--verify`, then
   `bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh bank-review <sid> <root> <N> <K> close <report-final.md> <impl findings>`
   (banks `REVIEW-EVIDENCE ... scope=close base=<base> head=<freeze> ... result=clean|blocking` on its own).
2. The full suite once (`rrun`), compared to the known-reds baseline (§5), then
   `bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] FULL-SUITE part=<N> sha=<sha12> attempt=<a> base=<sha12> env=<key-hash> completed=yes new-reds=<n> report=<path>" "m<N>-suite-<sha12>-a<a>"`.
3. Live proof: write `tmp/mission/p<N>/e2e-for-devtools.md`, send it to the owner's devtools agent on
   the MacBook Air (never a Linux worker), log
   `bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] live-verify part=<N> sha=<sha12> attempt=<a> status=sent" "m<N>-live-<sha12>-a<a>-sent"`,
   and on the reply `status=ok evidence=<token>` (or `fail`) with the `-result` idtag. `live=no`:
   one `status=n/a reason=<slug>` result line.

Then `bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh bank-review <sid> <root> <N> <K> join <report-final.md>`
(dry=2), and `bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] PART-DONE part=<N> (converged)" "m<N>-part-done"`.
A rc=4 names what is missing; do that and retry. After PART-DONE: push-queue line (§10), `mv` the
part plan from ready-plans to done-plans (idempotent; on failure `FAIL ... phase=retire
reason=plan-mv-failed`), then
`bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] PART-RETIRED part=<N>" "m<N>-part-retired"`,
the morning report (§9), the strategist, the next PART-START.

## §5 Throughput detail

**Targeted tests per round:** the plan's test list, the runner's related-tests mode for touched files,
typecheck. A run that did not complete (load error, missing DB, lost worker) is invalid: rerun it;
it is neither red nor pass.

**Known reds.** Baseline key = base SHA + exact command + environment id (worker, DB role, config
hash): `<root>/.mission-known-reds/<base-sha12>-<key-hash>.txt`, header naming all three plus
`completed=yes`, body one line per assertion failure `<test id> | <failure signature>` (first
assertion message line, values kept; only timestamps, durations, temp paths, uuids, ports and the
values of id-labelled fields normalized). Written atomically; infra failures never enter it. A red is known only when id AND
signature match a baseline with the same key; no matching baseline = every red is new. New reds
rerun once for flakes; a remaining one is fixed, or cleared only by reproducing it on the base SHA
under the same key. A finished part's full-suite result is the next baseline when the key matches.
Report layout (`sha= base= command= env= completed= infra=`, `--`, body) and the bare-token
`known-reds <sid> <root> key|diff|record <report>` verbs (the FULL-SUITE `env=` and `new-reds=` values;
`record` after a passing close suite): reference.md.

**Watchdog.** Beside each long helper, `run_in_background`:
`bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-watchdog.sh [--done=<path>] <sid> <label> <class> <path>...`
(class `chunk|review|sweep|suite`; paths = that helper's OWN outputs only). Exit 0 done, 3 STALL (20
idle min, `MISSION_WATCHDOG_MIN`), 4 deadline (non-test). It never kills anything and never owns
continuation; the wake reads its status file (wake.md decision table).

**Codex token index.** For every Codex run append one line to `<root>/tmp/mission/codex-runs.<sid>.tsv`:
`m<N>` (or `-`) TAB the output file or run dir. Helper descriptions carry `m<N>`.

**Overlap and stacking** (§3). Parts stay serial; work inside a part fans out in ONE message.

## §8 /pre-compact and resume

Invoke `skill: pre-compact` at natural seams, freely. After any compaction, the resume IS a wake:
enter the `§12.1 wake routine` in wake.md (resume read in its §8), never hand-resume the last round.

## §9 Quality without reading code

- **Escaped-bug log** `<root>/.mission-escaped.md`, append-only:
  `date | part | found-by (devtools|owner|later-part|prod) | TYPE-KEY | area | should-have-caught (plan|code|test) | ref`.
  The strategist raises tiers for those areas; the types seed every verify ledger.
- **Planted-bug test** (`docs/mission/planted-bugs.md`): at mission start, in the background, when
  the last run is over 7 days old or `codex-review.md` changed (`~/.claude/mission-planted.jsonl`).
  A miss is a plain-words notification and a log `note`; it never blocks.
- **Morning report**: on every PART-DONE, PART-RETIRED, MISSION-CLEARED, FAIL (park or STOP LOUD) and
  opened human STOP, the writer rewrites `<root>/tmp/mission/MORNING.md` itself (via
  `bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/lib/mission-status.sh morning <sid> <root>`, which you may also run by
  hand). Send its summary line (`sed -n 3p`) as that moment's PushNotification.

## §10 Owner conventions (rules/build-throughput.md)

LAND FIRST: finished, review-clean, unlanded work comes before new scope; the next part of an approved
roadmap is not new scope and keeps going, stacked on the freeze SHA. PUSH-APPROVAL LIST: at PART-DONE
append `<date> | <window> | <repo> <branch> | <exact SHA> | <one-line what> | waiting` to
`~/.claude/push-queue.md`; mark it `landed <SHA>` when it lands. A relayed OK is not approval; prod
pushes go through the prod-orchestrator window. Landing approval is never a mission AWAIT.

## §11 Lifecycle close

```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh timing-close <sid> <root> <achieved|could-not|cleared>
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] MISSION-CLEARED status=<achieved|could-not> reason=<slug>" ""
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh archive-close <sid> <root>
rm -f "$HOME/.claude/progress/mission-liveness-<sid>.json"
```

## §12 Wake (short)

The `§12.1 wake routine`, the decision table, the `§12.3` stop list and `§12.4` post-compact resume
live in `docs/mission/wake.md`. `<WAKE>` = `/Users/omidzahrai/.claude-dotfiles/docs/mission/wake.md`,
`<MW>` = `/Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh`. Before substituting,
refuse any value holding a newline or `"`, `` ` ``, `$`, `\`. The tick prompt, verbatim:

```
/mission tick sid=<SID> root=<ROOT>. Cold start, no memory. Read <WAKE> and run its §12.1 wake routine using bridge CLI <MW>. Do not read the full playbook unless WAKE sends you there.
```

## §6.5 Codex may write code - through one wrapper only

Codex never writes the mission bridge. It MAY implement an isolated, mechanical, well-specified
chunk, only via `CODEX_EFFORT=high bash /Users/omidzahrai/.claude-dotfiles/scripts/codex-build-chunk.sh <promptfile> <outfile> <worktree>`
on a LINKED worktree (one per chunk). Its refusals and status tokens are in that script's header
table. `status=ok` means Codex wrote something and touched nothing forbidden, not that it is right:
Claude runs the tests before it counts.
