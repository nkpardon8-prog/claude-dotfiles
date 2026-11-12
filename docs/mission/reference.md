# /mission reference - verb detail, line grammar, rare paths

Companion to `commands/mission.md`. The writer (`scripts/hooks/mission-write.sh`) is the
authoritative grammar; this file documents it. Every call uses the byte-locked prefix
`bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh <verb> <sid> <root> [args]`.

## Verbs

| Verb | Args after `<sid> <root>` | Notes |
|---|---|---|
| `create` | `"$PLAN"` | Seeds PLAN once. Idempotent: an existing verified file returns `ok` and keeps its PLAN. Only rc=1 is the root guard; exists-but-fails-verify = corrupt. |
| `log` | `"<entry>" "<idtag>"` | Validated shapes only (table below). Lifecycle CLEARED lines use an EMPTY idtag. Refuses proto=2 REVIEW-EVIDENCE and any `dry=` raise (use `bank-review`). |
| `await` | `"part=<N> phase=<P> round=<K> kind=<job\|human> op=<op> attempt=<A> need=<mask> got=<mask>"` | Barrier open and lane bits. Each lane writes ONLY its bit; the reader ORs them. Never via `log`. |
| `note` / `challenge` | `"$TEXT"` | DURABLE NOTES / PLAN CHALLENGES. |
| `pending` | `<slug> "$Q"` | NON-blocking question; mints and echoes `pd:<seq>-<slug>`. |
| `pending-stop` | `<slug> <part> <round> <attempt> <phase> "$Q"` | BLOCKING: one lock opens `AWAIT kind=human op=<seq>-<slug> need=1 got=0` AND mints the pd. Rc list below. |
| `resolve` | `<pd:seq-slug>` | Drains a pending (bare `<seq>-<slug>` accepted). Refused while the same-op human STOP is open. |
| `rebaseline` | `"$PLAN"` | The only PLAN rewrite; bumps gen and appends `MISSION-REBASELINED status=active`. |
| `bank-review` | `<N> <K> <plan\|delta\|close\|join> <report> [<impl-reviewer output>]` | Sole writer of proto=2 REVIEW-EVIDENCE, the review round line or VOID, the close result and every `dry=` raise. Checks per-scope panel completeness (plan: Claude breadth, criticer, Codex executability, Codex value, verify; delta/close: 4 Codex lanes, 3 Claude lenses, the outer implementation-reviewer, verify), `Verify: ok` with `tagged == blocking`, the report identity (stat-verified `Report-file`), base/head binding, a clean tree with HEAD == report head before `dry=1`, VOID and void-count, `panel-unavailable-3x`. `close` banks `REVIEW-EVIDENCE ... scope=close base=<base> head=<freeze> ... result=clean\|blocking` on its own; `join` banks `dry=2` only when a clean close, a passing FULL-SUITE and the live result (or `n/a` for `live=no`) exist for the freeze SHA; it writes the v2 convergence SNAPSHOT first, then the dry=2 line, checks both writes, and a retry at dry=2 re-checks and repairs a partial bank. Reports `repeat=` and `redesign=<area>` (same area new blocking types 3 rounds running). |
| `render-banner`, `timing-resume`, `timing-contact <ask\|fail5\|corrupt>`, `timing-close <status>`, `archive-close` | | Advisory. |

Bare-token read verbs (stdout is the token, no status line). A JOB AWAIT is superseded by its round's
`phase=review` line, VOID, or bank-review evidence (any scope), and by PART-DONE/PART-RETIRED; a HUMAN
AWAIT only by its own DECISION + `got=1`, which `await` accepts even on a retired part. `await-state` (`none` | `corrupt` |
`await kind=.. op=.. part=.. round=.. attempt=.. phase=.. need=.. got=.. ready=<0|1> started_at=..`),
`cursor-hash` (64-hex or `corrupt`), `budget-state` (`ok` | `paused live=<min>` |
`over part=<N> minutes=<M> replan=<0|1>`), `part-state` (`none` | `part=<N> proto=<1|2> dry=<D>
closed=<0|1> freeze=<sha12|-> head=<sha12|-> tree=<clean|dirty|-> drift=<0|1>`: the wake's protocol
dispatch; `drift=1` = a proto=2 part at dry>=1 whose worktree left the freeze), `void-count <sid> <root> <N> <K>` (integer; `-1` = refused
gen-sliced read = STOP), `parse-codex-header <report>` (`N/4`), `parse-claude-header <report>` (`N/3`).

**`pending-stop` rc list** (none is a proceed; only rc=3 is retryable): 1 bad args; 2 corrupt bridge;
3 lock busy (retry, then STOP LOUD); 4 backup failed; 5 mktemp failed; 6 self-check failed; 7
sequence exhausted; 8 AWAIT line over 480 B; 9 AWAIT did not land; 10 mission CLEARED; 11 lifecycle
unreadable; 12 a DIFFERENT human STOP is open (close it first); 13 same op live with a different
question; 14 orphan barrier (see below). Capture the id anchored to the status line (wake.md §12.3).

## Line grammar (validator table)

| Leading token | Entry | idtag |
|---|---|---|
| round | `part=N name=<slug> phase=(research\|plan\|implement\|review\|fix) round=K dry=[0-2]( findings=C)?( open=C)?` (proto=2: `at=` stamped) | `m<N>-<phase>-r<K>-d<D>` |
| `PART-START` | `part=N name=<slug> proto=2 worktree=<abs> base=<sha12> needs=<none\|N[,N]>`; the worktree HEAD must equal `base=` (legacy: no proto; refused after cutover) | `m<N>-part-start` |
| `RECIPE` | `part=N v=<1\|2> tier= floor= plan= review= budget= live= overlap= needs=` (`at=` stamped; `needs=` must equal the PART-START's) | `m<N>-recipe-v<V>` |
| `REVIEW-EVIDENCE` | `part=N round=K scope=<plan\|delta\|close> base= head= codex= claude= tagged= blocking= new= repeat= rkeys=<csv\|-> result=<clean\|blocking> report=` (bank-review only; `at=` stamped) | `m<N>-review-evidence-<scope>-r<K>` |
| `VOID` | `part=N phase=review round=K reason=<slug>` | `m<N>-void-r<K>-<runid6>h<sha8\|nofile>` |
| `SWEEP` | `part=N round=K types=<csv> sha=<sha12> instances=<n> report=<path>` | `m<N>-sweep-r<K>-s<S>` |
| `FULL-SUITE` | `part=N sha=<sha12> attempt=<a> base=<sha12> env=<hash> completed=yes new-reds=<n> report=<path>` | `m<N>-suite-<sha12>-a<a>` |
| `live-verify` | `part=N sha=<sha12> attempt=<a> status=(sent\|ok evidence=<tok>\|fail reason=<slug>\|n/a reason=<slug>)` | `m<N>-live-<sha12>-a<a>-(sent\|result)` |
| `FAIL` | `part=N phase=<p> reason=<slug> attempt=A` | `m<N>-fail-<reason>-<A>` / `m<N>-fail-panel3x-r<K>` |
| `FAIL` (park) | `part=N park=<reason> disposition=<reverted\|isolated\|left-with-recorded-risk> range=<b12>..<h12>` (`at=` stamped) | `m<N>-fail-park` |
| `ANCHOR` | `part=N sha=<sha12>`; `ANCHOR` is written only by the writer (legacy: root head when a proto=2 PART-START first needs it, or at its PART-DONE; proto=2: the freeze SHA at PART-DONE) | `m<N>-anchor` |
| `PART-DONE` / `PART-RETIRED` | `part=N (converged)` / `part=N` | `m<N>-part-done` / `m<N>-part-retired` |
| `test-trust` | `part=N=(ok\|added\|n/a)` | `m<N>-test-trust` |
| `SNAPSHOT` | lib-written at convergence; `fp=v2` for proto=2 (clean worktree HEAD tree) | lib |
| `AWAIT` | `part=N phase=<p> round=K kind=(job\|human) op=<op> attempt=A need=<m> got=<m>` (via `await`) | `m<N>-await-<op>-r<K>-a<A>-g<GOT>` |
| `DECISION` | `op=<seq>-<slug> outcome=(approve\|deny)` | `pd-<seq>-decision-<slug>` |
| `MISSION-CLEARED` | `status=(achieved\|could-not\|cleared) reason=<slug>` | EMPTY |
| `MISSION-REBASELINED` | `status=active gen=<G> (...)` (lib) | EMPTY |

`criticer` lines from legacy parts still validate; proto=2 parts carry criticer output inside the
plan report. gen-1 idtags are unprefixed; gen>=2 are auto-prefixed `g<G>-` (a wrong prefix is rc=5).
Dedup is archive-inclusive within the generation; convergence, VOID count and the FAIL tally read the
current generation only. A dedup retry keeps the original `at=`. FAIL idtags carry the attempt so
five same-reason FAILs stay five lines. A DECISION is immutable: a different outcome on the same op is
a `COLLISION`; open a fresh `pending-stop` instead.

## Cutover (proto=2)

After the rework lands, PART-START without `proto=2` is refused; proto=2 parts need a RECIPE before
`phase=plan`, use only the new evidence shapes, and pass every recipe, plan-gate, close and budget
check. Parts open at cutover are grandfathered on the old fold (2 consecutive dry `phase=review`
rounds, `live-verify part=N round=K`, SNAPSHOT fingerprint v1). A legacy part satisfies `needs=` by
PART-DONE; its anchor is the `ANCHOR` line. An open legacy part is driven by the frozen pre-rework playbook
`docs/mission/legacy-playbook.md` (byte-identical to `commands/mission.md` at 509fe27b, its own
§12 wake routine and decision table) until its PART-DONE/PART-RETIRED; its next PART-START is
refused with the reload text, which brings the conductor back to `commands/mission.md` and proto=2.

## Legacy compatibility overrides (win over docs/mission/legacy-playbook.md)

The frozen playbook stays byte-identical; for an open proto=1 part these steps replace its text:
1. **Entry and the tick lock.** wake.md step 0 reads `part-state` BEFORE any lock and sends a proto=1
   part here; run the frozen §12.1 from its step 1. It acquires and releases the tick lock itself,
   exactly once per tick. Never hold wake.md's lock while running it (if one is held, `rmdir` it once
   first).
2. **Park** (its §6.1 cap-exhausted path and its §12.1 spend brake, `part-over-budget`). Do NOT open
   `pending-stop` and do NOT log its `FAIL ... disposition=` line (refused). Stop the part's helpers,
   then `log "[mission] FAIL part=<N> park=<cap-exhausted-blocking|part-over-budget>
   disposition=<reverted|isolated|left-with-recorded-risk> range=<base12>..<head12>" "m<N>-fail-park"`
   (range in the mission root: the commit before the part's first commit .. HEAD; `<head12>..<head12>`
   if it committed nothing), PushNotification, then `PART-RETIRED part=<N>`. No human STOP.
3. **After PART-DONE or PART-RETIRED** this file no longer applies: re-read `commands/mission.md`
   (strategist, then a proto=2 PART-START; a legacy PART-START is refused with the reload text). An
   `isolated` legacy range blocks any later base that contains one of its commits.

## Full-suite report and known-reds baseline (FULL-SUITE `report=`)

The suite report the conductor writes and `FULL-SUITE report=` names (absolute path), one header line
per key, then a `--` line, then the body:

```
sha=<freeze sha12>
base=<PART-START base sha12>
command=<exact suite command>
env=<environment id: worker, DB role, config hash>
completed=yes
infra=0
--
<test id> | <failure signature>
```

Header keys: `sha= base= command= env= completed= infra=`. Body: one `<test id> | <failure signature>`
line per assertion failure (first assertion message line, values kept). The writer refuses the
FULL-SUITE line unless the report exists, `completed=yes`, `infra=0`, its `sha`/`base` equal the
line's, the line's `env=` equals the 16-hex key hash of `command` + `env`, and `new-reds=` equals its
own recount. Recount: body lines normalized (timestamps, temp paths, uuids, ports, durations and
the value of an id-labelled field such as `id=`, `request_id:`, `requestId=`; ordinary numbers and
hex values are assertion values and are kept), then those not in `<root>/.mission-known-reds/<base>-<key>.txt` (same base, same
key; no file = every red is new). A run with `infra` above 0 or not completed is invalid: rerun it.
Baseline files use the same layout (header `base= command= env= completed=yes`, `--`, body) and are
written atomically. Read verbs (bare tokens): `known-reds <sid> <root> key <report>` prints the `env=`
value for the FULL-SUITE line; `known-reds <sid> <root> diff <report>` prints the `new-reds=` count
(`-1` = invalid run). `known-reds <sid> <root> record <report>` merges a completed run into the
baseline keyed by the report's `sha` (run it on a passing close suite so the next part, based on this
freeze, reuses it; or on a base-SHA run that reproduces a red, which is the only way to clear one).

## `§2b` Resume picker (explicit clone into this session)

1. If this sid already owns a mission (`mission_resolve_path` non-empty): show its PLAN line 1, STOP.
2. `mission_list "$root"` -> `<sid>\t<mtime>\t<active|cleared|unknown|corrupt>\t<roadmap>`; nothing ->
   say so and stop. Show a numbered list newest first (`unknown` shown as active, `corrupt` flagged,
   not cloneable).
3. A non-cleared pick: warn that the clone is a DIVERGENT COPY (no merge back; stronger warning if
   touched in the last ~15 min) and require a second confirmation.
4. `newfile=$(mission_fork "$sid" "$root" "$(mission_path "<picked_sid>" "$root")") || STOP`, then
   `render-banner`. Failure is a HARD STOP (rc 3 = you already own a mission).
5. Read every zone plus the log (wake.md §8) and continue at the logged position with your own sid.
Scope: the current canonical root only.

## Adopt cases

(a) no mission -> `create` with `MISSION MODE: adopt` and the captured objective; if `create` says
`ok` but PLAN line 1 is not this directive, you are in (c). (b) a mission with a `MISSION MODE:` PLAN
-> check `mission_state`: CLEARED -> `rebaseline` to reactivate; active -> continue. (c) a mission
whose PLAN is not a `MISSION MODE:` token -> surface it and `rebaseline`. Away -> a loud `challenge`,
then proceed. Route each unit worth planning through the part loop; a typo is not a part.

## Corrupt bridge

Any `FAILED rc=2`, a failed `mission_verify`, `cursor-hash`/`await-state` = `corrupt`, `void-count`
`-1`, or `pending-stop` rc=11: STOP LOUD with a PushNotification, point the owner at
`<root>/.mission-backups/` (newest first), record `timing-contact corrupt`, do not reschedule. Never
hand-repair the log; the write-path self-heal or the owner repairs the generation boundary.

## Orphan human barrier

`await kind=human ready=0` with no `- [pd:<op>]` line and no DECISION: the question was lost in a
crash and cannot be re-presented (`pending-stop` for that op fails closed rc=14). Safe abort, in
order: (1) `log "[mission] DECISION op=<op> outcome=deny" "pd-<seq>-decision-<slug>"` (never
fabricate an approve); (2) `await` the same barrier `need=1 got=1`; (3) `resolve` (a moot no-op).
If a decision is still needed, open a FRESH `pending-stop` under a different slug.

## Human consume - why the order

DECISION -> gated action -> `got=1` -> `resolve`, all on one wake under the tick lock. A crash between
steps leaves a durable DECISION and a LIVE barrier, so the next wake re-consumes; the gated action
must therefore be idempotent or single-shot (an external write keyed for dedup). Closing first and
deferring the action is forbidden: the reader drops a closed barrier and the action would never run.

## Tick lock race (bounded)

The stale-lock clear is not ABA-proof: two wakes can both judge a lock stale. Idtag dedup and the
step-5 cursor recompute absorb a double LOG transition; a double EXTERNAL dispatch is narrowed by the
step-6 `await-state` re-read and by persisting lane results before their bits. A run-id lease that
would close it fully is not wired; do not claim it.
