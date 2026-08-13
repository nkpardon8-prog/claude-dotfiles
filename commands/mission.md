---
description: "Autonomous long-build conductor (playbook, not an engine). Opt-in and HEAVY — per part it runs research + a full /plan reviewer loop (≈4-6 rounds) and a 4 Codex + 3 Claude cross-model code-review panel (≈3-6 rounds), across many parts and many compactions. Lays out a big multi-part roadmap WITH you once, then executes each part on its own through research → /plan(+reviewers) → /implement → /codex-review to honest 2-dry convergence, riding the mission-bridge + /pre-compact so it never loses the thread. For genuinely large builds only; overkill for small work."
argument-hint: "[roadmap/goal | resume | clear [reason] | status | (blank=status)]"
---

# /mission - autonomous long-build conductor

`/mission` is a loose, judgment-driven PLAYBOOK - prose you follow, NOT an engine. It conducts
four skills - codebase-research -> `/plan`(+reviewers) -> `/implement` -> `/codex-review` - over
the durable mission-bridge, riding `/pre-compact`, looping implement<->review to honest
convergence, per part, across many compactions. DO NOT over-engineer or over-constrain: the
four-skill sequence is the SPINE, not a cage; you stay free to invoke any other skill. Most LOG lines
are a best-effort boundary checkpoint - observational, never a gate; a missed phase-line degrades resume
granularity, not work. EXCEPTION: the wake-routine control state (the `AWAIT` marker + the
`cursor-hash`/`await-state` reads, §7/§12) IS load-bearing: an `await`/bank `FAILED` → retry then §10
STOP-LOUD; a `COLLISION` → re-read + reconcile; a `corrupt` cursor/await → §10 STOP-LOUD. Never proceed
as if succeeded. Opt-in and HEAVY (per part: 4-6 plan-review rounds + a
4 Codex + 3 Claude code-review panel over 3-6 rounds) - use it ONLY for genuinely large
multi-part builds; never for a typo, a one-liner, or a single bug fix.

## CONTRACT CORE

This core is self-sufficient for a post-compaction agent; full detail continues in §1-§12 below the
marker, which a live (untruncated) invocation must read and follow.

### CONTINUATION-OWNER INVARIANT (read first - a mission turn NEVER yields naked)

A `/mission` turn MUST NOT end unless ONE holds: (a) it JUST called `ScheduleWakeup(delaySeconds,
prompt=SELF_CONTAINED_TICK, reason)` as its LAST such call AND it SUCCEEDED (only the
tick-lock release may follow), or (b) it is at a genuine stop (§9 contact / §12.3 stop, incl.
`AWAIT kind=human`). **A scheduled wake is the ONLY continuation owner** - a tracked
`run_in_background` job is NOT sufficient (its wake can be lost); a turn yielding with a job pending
STILL schedules a fallback heartbeat. Any other turn-end is a NAKED YIELD that freezes the mission -
NOTHING retries it (§12.5). A `ScheduleWakeup` that FAILS is not (a): retry once, then STOP LOUD via
`pending-stop`. **§12.1 step 7 is the MANDATORY EXIT GATE - no path returns except through it.** A commit /
finished unit / report / peer reply is NOT a stop (§12.3), and
**announcing an action never substitutes for taking it**. The wake routine - `mkdir` tick-lock + §8
resume-read + cursor-compare + reschedule - lives in §12; every wake source (bg completion, tick,
post-compact resume) funnels through it, ONE transition.

### A. Resolve sid + root + mission file FIRST (§1)

- `sid` = the platform session UUID, STRICTLY `$CLAUDE_SESSION_ID` then `$CLAUDE_CODE_SESSION_ID`.
  Both empty -> STOP loud. NEVER guess by transcript mtime (that is how two instances collide).
- `root`: `. "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"` then
  `root=$(handoff_canonical_root)`.
- `mfile=$(mission_resolve_path "$sid" "$root")` - manifest pointer -> deterministic
  `MISSION.<sid>.md` -> empty. Empty = THIS session has no mission yet; it NEVER means "adopt the
  newest file". Non-zero rc = hard error -> STOP. Your mission is always owned by your own sid.
- Before doing mission WORK (not status/clear/stats), stamp the timing entry once:
  `mission-write.sh timing-resume <sid> <root>` (advisory). `MISSION-START` and the first
  `WORK-START` are LIB-ONLY emissions stamped at create - never log them by hand (the validator
  REFUSES them through the `log` verb).

### B. Dispatch modes (§2, §2b)

- blank / `status` -> read-only: run the §H resume read, print mode/part/phase/round/dry + the
  active PLAN directive + PENDING DECISIONS. No mutation.
- `clear [reason]` -> log `[mission] MISSION-CLEARED status=cleared reason=<slug>` with an EMPTY
  idtag (lifecycle lines ALWAYS append; a non-empty idtag would dedup-suppress a re-clear after a
  rebaseline), then `archive-close`.
- `stats` -> read-only `mission_stats_render` (machine-wide lifetime ledger).
- `tidy` -> `mission_archive_sweep` over this root (reserved keyword, never a new mission).
- `resume` -> explicit picker: `mission_list`, user picks, `mission_fork` CLONES the pick into
  THIS sid (source intact; warn about divergent copy if not cleared; fork failure = HARD STOP).
  The ONLY sanctioned way a session continues a mission it did not create - never auto-inferred.
- free-text roadmap -> BUILD mode: shape the roadmap WITH the user, seed the PLAN via `create`.
- ambient intent ("apply the /mission methodology...") -> ADOPT mode; session-sticky until
  `/mission clear`.

### C. The bridge: artifact set + zone semantics (§3, §4, §7)

`MISSION.<sid>.md` holds the four-zone artifact set, each fenced by MZONE markers
(`<!-- MZONE:<name> n=<nonce8> -->` ... `<!-- /MZONE:<name> ... -->`): **PLAN**, **DURABLE
NOTES**, **PLAN CHALLENGES**, **PENDING DECISIONS**; the trailing marker line carries sid, nonce,
plan_hash (sha over the PLAN zone) and gen. Beside it live the LOG sidecar `MISSION.<sid>.log`
and rotated archives under `.mission-backups/`.

- **PLAN is write-once/verbatim**: seeded ONCE by `create` (line-1 is the sole machine token
  `MISSION MODE: build|adopt`; lines 2+ prose roadmap + standing directive). NEVER hand-edit it;
  a divergence goes to PLAN CHALLENGES via `challenge` (loud). `rebaseline` is the ONLY path that
  rewrites PLAN - it re-stamps plan_hash, BUMPS gen, and appends the REACTIVATING lifecycle token
  `[mission] MISSION-REBASELINED status=active`.
- `create` is no-clobber AND idempotent: an existing VERIFIED file returns `ok` (no-op; the stale
  PLAN persists) - on that `ok`, check `mission_state` + PLAN vs this build's intent, rebaseline if
  either says so. The only `create` REFUSED rc=1 is the root-guard; fails-verify = corrupt (§10).
- `note` = verbose findings / forced assumptions (DURABLE NOTES); `pending`/`resolve` = the
  batched human-decision queue.
- Intent precedence on resume when sources disagree: the PLAN zone outranks the handoff chain's
  north_star, which outranks any ledger/summary line. PLAN wins.
- UNTRUSTED content (roadmap, objective, reviewer output, captured text) must NEVER be inlined in
  a shell arg - a DOUBLE-quoted literal executes `$(...)`; a SINGLE-quoted one breaks on an
  apostrophe. CAPTURE into a var (quoted heredoc/file), pass `"$VAR"`, or file/stdin (§7).

### D. Bridge-write contract (§7)

Every bridge mutation is Claude, via the byte-locked invocation - absolute path, no `cd`, no env
prefix, no `~` (the permission allowlist byte-matches this exact prefix):

```
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh <verb> <sid> <root> [args]
```

Verbs: `create | log | note | challenge | pending | pending-stop | resolve | rebaseline | render-banner | await`
(the `await` verb opens/updates the durable AWAIT barrier marker - §7/§12) plus `timing-resume |
timing-contact | timing-close | archive-close` and the read-only bare-token verbs `parse-codex-header |
void-count | await-state | cursor-hash` (the wake routine's inputs - §12). **Codex NEVER writes the
bridge** - every Codex run is `-s read-only`.

The script ALWAYS exits 0: parse its single stdout status line. `ok` is the ONLY success token.
The `log` verb emits exactly four leading tokens and each demands a reaction:
- `ok` -> appended or idempotent no-op -> proceed.
- `COLLISION` -> idtag exists with DIFFERENT content -> STOP, re-derive gen/round numbering,
  reconcile against the recovered LOG; never assume the line was banked.
- `REROUTED-TO-NOTES` -> free-text entry exceeded 480B on-disk -> rewrite TERSE, re-log to `ok`.
- `FAILED rc=N` -> rc=1 REFUSED (guard/grammar - fix the shape); rc=2 corrupt bridge -> §10
  STOP-LOUD immediately; rc=3 lock busy -> retry ~5x then FAIL-line it; **rc=4 on a PART-DONE or
  live-verify write BLOCKS retirement/advance** (do the named remediation); rc=5 wrong-gen idtag
  prefix (re-derive the gen); other rcs -> log + proceed, recurring ones feed the 5-FAIL breaker.
**`pending-stop` EXCEPTION to "other rcs -> log+proceed": ONLY `ok id=pd:<seq>-<slug>` proceeds; ANY
non-zero rc = the STOP did NOT open -> do NOT proceed/auto-advance (S1 naked-yield).**
`void-count` stdout is a bare integer; **`-1` is the ERROR SENTINEL of a refused gen-sliced read
-> STOP** (never treat as count 0, never advance).

### E. LOG-line grammar (§7 - resume greps read back EXACTLY these shapes)

On-disk line = `<idtag>\t<entry>`. Keep round lines TERSE: the 480B reroute budget is measured
over idtag + TAB + entry + newline; a rerouted line lands in DURABLE NOTES where resume cannot
grep it. Verbose findings go in a separate `note`, written BEFORE the terse round line.

- Round: `[mission] part=<N> name=<slug> phase=<research|plan|implement|review|fix> round=<K>
  dry=<D>[ findings=<COUNT>]`, idtag `m<N>-<phase>-r<K>-d<D>` (d<D> REQUIRED). `findings=` is a
  bare integer COUNT, MANDATORY on `phase=review`/`phase=fix` rounds; `dry=` is the running
  consecutive-dry count (0-2) after the round. `phase=review` = findings logged, fixes NOT yet
  applied; advance the SAME round to `phase=fix` when fixing.
- VOID: `[mission] VOID part=<N> phase=review round=<K> reason=<slug>`, idtag
  `m<N>-void-r<K>-<runid6>h<sha8|nofile>`.
- FAIL: `[mission] FAIL part=<N> phase=<P> reason=<slug> attempt=<A>`, idtag
  `m<N>-fail-<reason>-<attempt>` (attempt REQUIRED - a reason-only idtag would dedup-collapse the
  5-strike tally).
- live-verify: `[mission] live-verify part=<N> round=<K> status=ok evidence=<token>` or
  `... status=n/a reason=<slug>`, idtag `m<N>-live-verify-r<K>`.
- SNAPSHOT: `[mission] SNAPSHOT part=<N> kind=converged tree=<h16> ...` - auto-stamped by the lib
  when the dry=2 round banks (feeds the stale-claim guard).
- Lifecycle: `[mission] PART-START part=<N> name=<slug>` (idtag `m<N>-part-start`);
  `[mission] PART-DONE part=<N> (converged)` (`m<N>-part-done`);
  `[mission] PART-RETIRED part=<N>` (`m<N>-part-retired`);
  `[mission] test-trust part=<N>=<ok|added|n/a>` (`m<N>-test-trust`);
  `[mission] criticer part=<N> findings=<K> <headline>` (`m<N>-criticer-r<round>`);
  `[mission] MISSION-CLEARED status=<achieved|could-not|cleared> reason=<slug>` (EMPTY idtag);
  `[mission] MISSION-REBASELINED status=active gen=<G> ...` (lib-written, EMPTY idtag).
- Gen scoping: gen-1 idtags stay unprefixed; gen>=2 idtags are auto-prefixed `g<G>-` by the lib -
  you always pass the bare `m<N>-...` form (a wrong prefix is REFUSED rc=5). Convergence, VOID
  count and the FAIL tally read only the CURRENT generation slice.

Example emission (the exact invocation form):

```
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] part=2 name=auth phase=review round=3 dry=1 findings=2" "m2-review-r3-d1"
```

### F. The per-part phase loop + convergence (§5, §6)

Per part: **research -> plan -> implement -> review barrier -> convergence loop**. Every fan-out
is parallel-INDEPENDENT: self-contained prompts, no reviewer sees another's output.
Never chain reviewers.

1. RESEARCH: Claude explorer subagent + Codex read-only fact pass (prompt via file/stdin, never
   inlined; check the `.status` sidecar) in parallel; reconcile; contradictions -> `pending` +
   `note`, proceed loudly on the more-evidenced branch.
2. PLAN: `skill: plan` (its built-in Codex pass IS the cross-model lane - do not add a second).
   REQUIRED before the first implement round: log the test-trust verdict
   (`test-trust part=<N>=<ok|added|n/a>`); absence on resume = unresolved -> re-assess.
   Surface a one-line criticer headline if `/plan`'s Criticer Notes have findings (advisory,
   never gates).
3. IMPLEMENT: `skill: implement --no-review <explicit-per-part-plan-path>` - always the explicit
   path; `--no-review` makes /mission own the review barrier and the plan lifecycle.
4. REVIEW BARRIER (parallel, independent): implementation-reviewer subagent + `skill:
   codex-review --effort high` (raise to xhigh only for genuinely critical parts). A round is
   VALID only if EVERY reviewer verdict is present: the report file's Engine header must show
   `Codex-passes: 4/4`, parsed via the `parse-codex-header` verb on `report-final.md` (never grep
   the body). After `/codex-review` returns you MUST materialize its final output text into
   `review_output` yourself (Write it to a temp file, read it back); sid/root/N/K/review_output
   all non-empty before the VOID block runs, or the loop-breaker can never fire (full BINDING
   CONTRACT: §5). N<4, a dead/empty/timed-out reviewer, or the legacy `Codex unavailable` markers
   -> the round is **VOID**: log the VOID line (require `ok` before counting), run `void-count`;
   at 3 consecutive VOIDs log `FAIL ... reason=panel-unavailable-3x` and **STOP LOUD immediately**
   (never wait for the 5-FAIL tally). `void-count` -1 -> STOP (§10). A VOIDed round is re-run
   fresh, never banked.
5. Round write order: verbose per-reviewer findings `note` FIRST, THEN the terse round line
   (resume keys on the round line; the reverse order strands a banked round with no findings).
   Actionable findings -> log `phase=fix` for the SAME round, fix, re-run the barrier as round
   K+1. Never re-run an idtag round you already banked.

CONVERGENCE rules: stop at **2 consecutive non-void DRY rounds** - "dry" = the independent
reviewers returned zero new actionable findings, logged verbatim.
An ACTIONABLE round **RESETS dry -> 0** (including an actionable re-run of a VOIDed round - a
dry=2 streak can never span a code change); a VOID alone never advances dry. Soft targets: plan
reviews 4-6, codex reviews 3-6; hard cap 6 either way. Convergence is computed ONLY from `phase=review` (or VOID)
lines - never from fix/plan/implement/research lines.

### G. PART-DONE gate (§5 tail)

Immediately after the dry=2 round banks and BEFORE PART-DONE, emit the live-verify line
(UNCONDITIONAL, once per part; `status=n/a` needs a reason slug). `mission-write.sh` REFUSES
`PART-DONE` with rc=4 - BLOCKING advance - unless ALL of:
1. a FRESH, **gen-current live-verify part=<N>** exists, newer than the last actionable event;
2. the dry-count fold over this generation's review rounds is **machine-clean**;
3. the code-tree fingerprint still matches the converged SNAPSHOT (**tree moved ->
   `convergence-stale`** -> re-run review at the current tree to a fresh dry=1 -> dry=2 pair,
   then re-log PART-DONE).
Then retire the part plan (idempotent `mv` ready-plans -> done-plans; log `PART-RETIRED` on
success, a `FAIL ... reason=plan-mv-failed` on failure - never proceed silently), then log
`PART-START part=<N+1>` and begin the next part's research.

### H. The §8 resume read (the SINGLE canonical recovery idiom)

Used by status, resume, and every post-compaction re-entry:
- `grep -F '[mission] '` over **ALL rotated archives**
  (`.mission-backups/MISSION.<sid>.log.*.gz|.txt`, concatenated oldest->newest by
  filename-timestamp sort) **THEN the live `MISSION.<sid>.log`**. `tail -n 40` is BANNED (misses
  lines past rotation); reading only the newest archive is banned.
- Derive four values: `cur_part` (last PART-START|PART-DONE part=; empty -> 1); `mission_state`
  (last `MISSION-(CLEARED|REBASELINED)` line - the GLOBAL active-iff gate; transient progress
  lines NEVER gate it); `last_review` (part-scoped last `phase=review` round OR VOID - the ONLY
  input to convergence: you need `2 - dry` more dry rounds); `last_round`/`last_progress`
  (positioning only).
- Active-iff: latest lifecycle = CLEARED -> INACTIVE; latest = REBASELINED status=active ->
  ACTIVE; empty state + PLAN line-1 is a `MISSION MODE:` token -> ACTIVE.
- Decision table (apply in order; **AWAIT rows FIRST**): `AWAIT kind=human got<need` -> human STOP:
  op with NON-EMPTY `last_decision` = CONSUME (approve=do the idempotent action, deny=abort;
  never re-ask); EMPTY = STOP for a user; close under the lock (C6) = DECISION ->
  `await got=1` -> `resolve`; `AWAIT kind=job
  got<need` + a tracked job pending -> collect nothing yet but STILL schedule a fallback wake (a
  pending job NEVER owns continuation); `AWAIT kind=job got<need` + NO tracked job -> replay the
  missing lane (same attempt) or on timeout/FAIL start attempt A+1; `AWAIT got=need` -> reconcile +
  bank the single normal successor. Then:
  latest progress `PART-DONE`/`PART-RETIRED` -> part COMPLETE
  (re-attempt retirement if PART-RETIRED absent, then next part; never consult stale round
  lines); `PART-START` with no round yet -> begin at research; last round `phase=fix` -> finish
  the in-flight fix, then barrier as K+1; `phase=review findings>0` -> fix of the SAME round K;
  `phase=review findings=0` -> next fresh round K+1; latest line for K is VOID -> re-run K fresh;
  `phase=research|plan|implement` -> continue that phase, then the barrier.
- `test-trust` recovered = honored; absent = unresolved. Intent precedence: PLAN > north_star >
  ledger (§C).

### I. Hard rules + loud stops (§9, §10, §11)

- NEVER hand-edit the PLAN zone; `challenge` loudly, `rebaseline` is the only rewrite path.
- Codex is ALWAYS read-only; a second bridge writer is forbidden.
- STOP LOUD on: **5 FAILs for the same part+phase** (gen-sliced tally);
  **panel-unavailable-3x the moment it is logged**; **void-count -1**; **a corrupt/unreadable
  bridge** (any `FAILED rc=2`, or a failed `mission_verify`) - surface `.mission-backups/`.
- Away default (autonomous runs): never block on a modal; log assumptions + `pending` and proceed
  loudly. Credential / destructive / external-side-effect skills require a human PENDING decision
  - never auto-run them.
- Natural close order: `timing-close` -> `MISSION-CLEARED status=achieved|could-not` (EMPTY
  idtag) -> `archive-close` LAST.

**Verb signatures (all `bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh <verb> <sid> <root> [args]`):**
`create "<seed>"` - seed PLAN once (idempotent) | `log "<entry>" "<idtag>"` | `await "<fields>"` (barrier open/close - §7/§12; NEVER via `log`) | `note "<text>"` | `challenge "<text>"` | `pending "<slug>" "<q>"` (non-blocking) | `pending-stop …` (BLOCKING: opens the human STOP + records pd, ECHOES `id=pd:<seq>-<slug>`; CAPTURE it; op=id minus `pd:`) | `resolve "<full pd:id>"` | `rebaseline "<new-plan>"` (ONLY PLAN rewrite path) | `render-banner` | `timing-resume` / `timing-contact` / `timing-close` | `archive-close`. FOUR read-only bare-token argv EXCEPTIONS (no status line): `parse-codex-header <report-file>`; `void-count <sid> <root> <part-N> <round-K>` (all four REQUIRED - part then round; a 2-arg call returns the `-1` STOP sentinel that halts a healthy mission); `await-state <sid> <root>` (`none`|`corrupt`|`await …`); `cursor-hash <sid> <root>` (§12 change-detect). Corrupt-bridge (rc=2) remediation and full verb detail: below the marker (SS7, SS10).

<!-- CONTRACT-CORE-END -->

# Full operational detail (S1-S12 below use the original section numbering; cross-references like "Section 7" / "§8" refer to these sections)

## 1. Resolve sid + root + mission file — FIRST, before anything else

Every `mission-write.sh` call needs `<sid>` and `<root>`, and a fresh `/mission` invocation
(unlike `/post-compact-resume`) has **no Stop-hook arg supplying them**. Resolve all three ONCE,
up front, and reuse them for the whole session. Mirror exactly what `post-compact-resume.md` does
(its "Resolve the durable mission file" subsection, ~line 276).

**`sid`** = the platform session UUID, taken STRICTLY from the platform the way `/pre-compact` does —
`$CLAUDE_SESSION_ID` then `$CLAUDE_CODE_SESSION_ID`. **Never guess by transcript mtime** — an mtime
guess is exactly how two interleaved instances bind the SAME sid and collide. If BOTH are empty, **STOP**
and tell the user the platform session id is unavailable, so the mission cannot be safely bound (ask
them to retry / report); do NOT proceed:
```bash
sid="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -z "$sid" ] && { echo "FATAL: no platform session id (\$CLAUDE_SESSION_ID/\$CLAUDE_CODE_SESSION_ID) — refusing to guess; STOP" >&2; exit 1; }
```
(Verified 2026-05-31: a slash-command shell has `$CLAUDE_CODE_SESSION_ID` populated even when
`$CLAUDE_SESSION_ID` is empty, so this fallback always yields a sid in practice — fail-loud never fires
spuriously.)

**`root`** = `handoff_canonical_root` (worktree-invariant canonical anchor):
```bash
. "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"   # sources handoff-locate.sh
root=$(handoff_canonical_root)
```

**Mission file** — resolve STRICTLY by your own sid via the lib (manifest pointer → deterministic
`MISSION.<sid>.md` → none). This REPLACES the old mtime glob, which picked the most-recently-touched
MISSION file in the worktree-invariant shared root and so silently adopted ANOTHER instance's mission
(the 2026-05-31 near-clobber). A stranger's `MISSION.<other-sid>.md` is now structurally unreachable:
```bash
mfile=$(mission_resolve_path "$sid" "$root") \
  || { echo "FATAL: mission_resolve_path errored (bad sid/root) — STOP" >&2; exit 1; }
```
`mission_resolve_path` returns the manifest-pointer target if set and present (and in-root canonical —
basename sid == marker sid == `mission_path` for this root), else the deterministic `MISSION.<sid>.md`
if it exists, else **empty**. Empty means THIS session has no mission yet (proceed to create in §3/§4,
or report none in `status`) — it does **NOT** mean "adopt whatever's newest". A non-zero rc is a hard
error (invalid sid/root): STOP; never treat it as "no mission". The pointer is the authoritative anchor
written by `mission_create`; the deterministic path is the sid-keyed backstop; there is no mtime
backstop. **Your mission is always owned by your own `<sid>`** (see §2b — even `/mission resume` clones
the picked mission into *your* `<sid>`), so use `mfile` for all reads and `<sid>`/`<root>` for all
writes throughout — there is no separate "working sid" to track.

**Run-timing — entry resume.** Once your mission exists (created in §3/§4 or resolved above) AND you are
about to do mission WORK (i.e. build/adopt execution, NOT the read-only `status`/`clear`/`stats` verbs),
stamp the timing entry exactly once at the start of this turn:
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh timing-resume <sid> <root>
```
This re-opens a working stretch ONLY if the mission was parked on you (last anchor a CONTACT); a
mid-stretch compaction resume is a no-op, so the stretch survives any number of compactions. Advisory —
ignore its status line. `mission_create` already stamped `MISSION-START` + the first `WORK-START` at
birth, so a brand-new mission needs nothing more here.

---

## 2. Invocation dispatch

Parse `$ARGUMENTS`:

- **blank or `status`** → **STATUS** (read-only, NO mutation). Resolve the mission via
  `mission_resolve_path` (Section 1). Read the **LOG sidecar DIRECTLY** (the resume-read idiom in
  Section 8 — `grep '[mission] '` over the FULL live log PLUS **ALL** rotated archives (oldest→newest),
  **not** a fixed `tail`, **not** only the newest archive, and **not** the banner: status reads the LOG
  directly). From the recovered `mission_state` (active-iff), `last_review` (round/dry) and PLAN
  line-1, derive and print: mode (build/adopt/none), current part,
  phase, round, dry-count, the active PLAN directive, and any non-empty PENDING DECISIONS. Then stop.
  Do not mutate anything.
- **`clear [reason]`** → **CLEAR**. Log the lifecycle close and stop treating work as a mission. Record
  the reason as a slug in the ENTRY TEXT, but pass an **EMPTY idtag** so the lifecycle line ALWAYS
  appends — the lib dedups on the leading idtag, so a non-empty `mission-cleared-<slug>` idtag would
  SUPPRESS a re-clear that follows a `rebaseline` (the prior CLEARED line would still be on disk and the
  fresh clear would no-op, leaving the mission spuriously ACTIVE). Lifecycle lines must never be
  dedup-suppressed (matches the lib's rebaseline, which also always-appends):
  ```bash
  reason_slug=$(printf '%s' "<reason-or-manual>" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-' | head -c 32)
  [ -z "$reason_slug" ] && reason_slug=manual
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] MISSION-CLEARED status=cleared reason=${reason_slug}" ""
  # archive LAST — file the now-cleared mission's files into .mission-archive/<sid>/ (advisory; the
  # archive-close self-guard requires the CLEARED line above to be on disk, which it now is):
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh archive-close <sid> <root>
  ```
  A bare `clear` sets `status=cleared`. `achieved` / `could-not` are set ONLY by the explicit
  lifecycle close at the natural end of a mission (Section 11) — not by this verb. Parse the returned
  status line (Section 7); confirm to the user.
- **`stats`** → **STATS** (read-only, NO mutation). Print machine-wide lifetime run-timing metrics
  across ALL missions ever run on this machine. Source the lib in a fresh block (each Bash call is a
  fresh shell) and call the read-only renderer — it reads `~/.claude/mission-metrics.jsonl` (not any
  per-mission file), so it needs no sid/root:
  ```bash
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"; mission_stats_render
  ```
  Then stop. (The ledger is appended once per mission close by the timing lifecycle below.)
- **`tidy`** → **TIDY** (file away closed cases). A reserved keyword — match it here, BEFORE the free-text
  fallback below, so a bare `/mission tidy` does NOT start a new mission literally named "tidy". Archives
  EVERY already-`cleared` mission still loose in this repo's root into `<root>/.mission-archive/<sid>/`,
  leaving active missions untouched. Source the lib in a fresh block and call the sweep directly (it
  prints its own report, so it is NOT routed through `mission-write.sh`):
  ```bash
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"; mission_archive_sweep "$(handoff_canonical_root)"
  ```
  Then stop. Surface the sweep's report (which sids were archived) to the user.
- **`resume`** → **RESUME PICKER** (Section 2b). List this repo's missions and let the user explicitly
  pick one to **clone into THIS session** and continue (e.g. after closing the instance that started it).
  NEVER auto-inferred — the ONLY sanctioned way a session continues a mission it did not create.
- **free-text roadmap/goal** → **EXPLICIT BUILD MODE** (Section 3 → Section 5).
- **ambient trigger in a plain user message** — e.g. "follow the /mission methodology with your
  plan", "apply the /mission template to what we're doing", recognized by **INTENT, not exact
  words** → **ADOPT MODE** (Section 4 → Section 5).

---

## 2b. `/mission resume` — explicit clone-into-this-session (the ONLY sanctioned continuation)

A mission is owned by the sid that created it. Resume is the deliberate exception: you pick an EXISTING
mission and **clone it into THIS session's own sid** — e.g. you closed the instance that started it and
reopened. The clone is owned by your `<sid>` like any normal mission, so EVERYTHING downstream
(`clear`, `status`, writes, `/pre-compact`, `/post-compact-resume`) uses your `<sid>` with **no special
"working sid" to track**. The pick is ALWAYS explicit, never a guess. The source is left intact.

1. **Resolve `sid`/`root`** per §1. **First check if THIS session already owns a mission**
   (`mission_resolve_path "$sid" "$root"` non-empty): if so, show its PLAN line-1 and STOP — one
   session owns one mission, and `mission_fork` refuses an existing dest (rc 3). To continue a
   *different* mission, start a fresh instance and `/mission resume` there. (`/mission clear` only marks
   your current mission closed in its log; it does NOT remove `MISSION.<sid>.md`, so it does not free
   this session to clone another.)
2. **Enumerate** this repo's missions (read-only; space-safe; sid-matched, no mtime adoption):
   ```bash
   mission_list "$root"   # TAB rows: <sid>\t<mtime_epoch>\t<active|cleared|unknown|corrupt>\t<roadmap>
   ```
   If it prints nothing, tell the user there are no missions in this repo and stop.
3. **Present a numbered list**, newest first (as emitted): `N) [<state> <relative-time>] <roadmap>
   (sid <first8>)`. Render `unknown` as `active` (a freshly-created mission with no lifecycle line yet).
   Skip or clearly flag `corrupt` rows (unreadable/mismatched marker — not cloneable). Let the user pick
   a number, or cancel.
4. **Live-fork warning.** If the picked mission's state is `active` or `unknown` (i.e. NOT `cleared`),
   **WARN explicitly** that cloning it produces a DIVERGENT COPY (both evolve independently from this
   point — there is no merge), and require an explicit second confirmation. If its mtime is ALSO recent
   (~15 min) say it looks **live in another instance right now** (stronger emphasis) — but warn even
   when idle, since mtime is a weak liveness proxy and an overnight mission can be idle yet still owned.
   (If the source instance is genuinely closed/dead, this is the intended clean continuation — no real
   divergence; the user confirms knowing that.)
5. **Clone** (on confirm). `mission_fork` copies the picked mission into your own `MISSION.<sid>.md`
   (retargeting only the marker sid; the source stays intact) and verifies the clone; then render this
   session's banner so a SessionStart before your first `/pre-compact` doesn't false-alarm:
   ```bash
   newfile=$(mission_fork "$sid" "$root" "$(mission_path "<picked_sid>" "$root")") \
     || { echo "resume: clone failed — STOP (do not start a half-made mission)" >&2; exit 1; }
   bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh render-banner "$sid" "$root"
   ```
   **`mission_fork` failure is a HARD STOP.** On success the mission is now a normal mission owned by
   your `<sid>` (rc 3 means you already own a mission — start a fresh instance to resume a different
   one). No sid-swap, no manifest rewrite, nothing else to thread.
6. **Resume the work.** Read the cloned mission IN FULL (`mission_read_zone` for each zone + the LOG via
   the §8 resume-read idiom) and continue Level-2 at the LOG's last `(part, phase, round, dry)`, writing
   with your own `<sid>`/`<root>` exactly as in §3-§5.

**Scope:** `mission_list` covers the CURRENT canonical root (this repo) only. To resume a mission from
another project, run `/mission resume` from that project's directory.

---

## 3. Level-1 — explicit build mode (interactive, WITH the user)

This first step is **collaborative, not autonomous.** Shape the multi-part roadmap together —
**lighter than a full `/plan`**: this is the *roadmap* (the parts and their sequence), not a
part-plan. Each part later runs its own full `/plan` reviewer loop in Section 5.

Then seed the immutable PLAN once. **PLAN line-1 is the sole machine token; lines 2+ are prose.**
The PLAN payload contains the (untrusted) roadmap text, so CAPTURE it into a variable via a QUOTED
`<<'EOF'` heredoc (nothing inside expands — a `$(...)`/backtick/apostrophe is inert) and pass it
DOUBLE-quoted `"$PLAN"` (§7 rule — safe against BOTH command-substitution AND quote-breakout; a
`'…'` single-quoted literal would break on a benign apostrophe):
```bash
PLAN=$(cat <<'EOF'
MISSION MODE: build
<the multi-part roadmap: parts, sequence, intended outcome>

Standing directive: route substantial work through research → /plan(+reviewers) → /implement →
/codex-review, looping to 2 honest dry rounds (independent reviewers judge dryness); soft targets
plan 4-6 / codex 3-6, hard cap 6; /pre-compact freely interleaved; active until a
[mission] MISSION-CLEARED line appears in the LOG.
EOF
)
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh create <sid> <root> "$PLAN"
```
`create` is **no-clobber** — it will not overwrite an existing mission, and (load-bearing) it is
**idempotent**: when a `MISSION.<sid>.md` already EXISTS and VERIFIES, the lib returns `ok` and leaves
the file untouched (other callers depend on that). So an existing **stale** PLAN does **NOT** surface as
a REFUSED — it surfaces as `ok`. The ONLY `create` failure that arrives as `FAILED rc=1 (REFUSED: …)` is
the root-guard (`REFUSED: root empty or contains '..'`); the only other `rc=1` is exists-but-fails-verify
(a corrupt file — handle via the §10 STOP-LOUD path). Parse the returned status line (Section 7) and
handle by outcome — **never silent-no-op on `ok`**:
- **`FAILED rc=1 (REFUSED: root …)`** (root-guard) → a true failure; surface it, fix the root, retry.
- **`ok` and NO prior file existed** → the PLAN was freshly seeded. Confirm it with the user, then begin
  Level-2.
- **`ok` but a `MISSION.<sid>.md` ALREADY EXISTED** (a non-mission `/pre-compact`, or a previously-
  `cleared`/superseded mission, seeded the PLAN) → `create` was a no-op and the **possibly-stale** PLAN
  persists. Do **NOT** assume the seed took. **Decide whether to rebaseline** by inspecting two things
  via the Section 8 resume-read idiom: (1) the active-iff `mission_state` (the latest
  `[mission] MISSION-(CLEARED|REBASELINED)` line) and (2) the existing PLAN zone (line-1 + roadmap)
  vs. what THIS build intends. **Rebaseline if EITHER** the mission is `MISSION-CLEARED` (latest
  lifecycle line) **OR** the existing PLAN differs from this build's intended roadmap/directive. If the
  existing PLAN already matches this build's roadmap AND the mission is active, the no-op is correct —
  just confirm and continue. When you do rebaseline, handle it exactly like §4(c): **surface it to the
  user and `rebaseline`** the PLAN to this build's directive (rebaseline is the ONLY path that
  legitimately rewrites PLAN, and it appends a `[mission] MISSION-REBASELINED status=active` lifecycle
  line that REACTIVATES a previously-cleared mission per the active-iff rule in Section 8):
  ```bash
  PLAN=$(cat <<'EOF'
  MISSION MODE: build
  <the multi-part roadmap + the same standing-directive text as above>
EOF
  )
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh rebaseline <sid> <root> "$PLAN"
  ```
  (Capture into `"$PLAN"` via a quoted heredoc and pass it double-quoted — the roadmap is untrusted; a
  single-quoted literal breaks on an apostrophe, a double-quoted raw literal executes `$(...)`; §7 rule.)
  Parse that status line too (Section 7). If the user is away, log a loud `challenge` explaining the
  rebaseline and proceed.

Confirm the seeded/rebaselined PLAN with the user, then begin Level-2 at part 1 (Section 5).

---

## 4. Adopt mode (ambient, mid-session)

The user retrofits mission rigor onto in-flight work. Resolve any existing mission (Section 1), then
**three cases**:

- **(a) No mission exists** → seed one, capturing the current objective from the in-flight context:
  ```bash
  PLAN=$(cat <<'EOF'
  MISSION MODE: adopt
  <captured current objective + state>

  Standing directive: <same directive text as Section 3>
EOF
  )
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh create <sid> <root> "$PLAN"
  ```
  (Capture into `"$PLAN"` via a quoted heredoc and pass it double-quoted — the captured objective is
  untrusted; a single-quoted literal breaks on an apostrophe, a double-quoted raw literal executes
  `$(...)`; §7 rule.)
  Parse the status line (Section 7). **`create` is idempotent: if a `MISSION.<sid>.md` already existed
  and verified, it returns `ok` as a no-op and the EXISTING (possibly non-mission/stale) PLAN persists —
  the seed did NOT take.** So if `create` says `ok` but PLAN line-1 is NOT this adopt directive (re-read
  it via the §8 idiom), you were actually in case (c), not (a) — fall through to (c) and rebaseline.
- **(b) A mission exists AND PLAN line-1 IS a `MISSION MODE:` token** → a mission-mode PLAN is present,
  but a PLAN token alone does NOT mean the mission is ACTIVE: a previously `MISSION-CLEARED` mission can
  still carry its old mission-mode PLAN on disk, and per the §8 active-iff rule it stays INACTIVE until
  reactivated. So **check the active-iff `mission_state` first** (the latest
  `[mission] MISSION-(CLEARED|REBASELINED)` line via the §8 resume-read idiom — mirror the §3/§4(c)
  logic): if the latest lifecycle line is `MISSION-CLEARED` (or there is NO lifecycle line but the
  mission was cleared/closed), the mission is INACTIVE → **REBASELINE to reactivate** (rebaseline
  appends a `[mission] MISSION-REBASELINED status=active` line, which the active-iff rule treats as
  active and which overrides the stale `MISSION-CLEARED`), exactly as in case (c). Only when
  `mission_state` shows the mission is genuinely ACTIVE (latest is `MISSION-REBASELINED status=active`,
  or `mission_state` is EMPTY with a live mission-mode PLAN) do you "continue as-is" — you are already
  in mission mode; just continue.
- **(c) A mission exists BUT PLAN line-1 is NOT a `MISSION MODE:` token** (a non-mission
  `/pre-compact` seeded the PLAN, OR a previously-`cleared` mission whose lifecycle is closed) → do
  **NOT** silently no-op (`create` is no-clobber and would quietly keep the stale PLAN). Surface this
  to the user and **rebaseline** the PLAN to the mission directive — `rebaseline` is the ONLY path
  that legitimately rewrites PLAN, and it **reactivates** the mission: rebaseline now appends a
  `[mission] MISSION-REBASELINED status=active` lifecycle line, and the active-iff rule (Section 8)
  treats the LATEST lifecycle line being `MISSION-REBASELINED` as active — so a prior
  `MISSION-CLEARED` no longer suppresses. Do **not** hand-write a separate reactivation line; rely on
  rebaseline to do it:
  ```bash
  PLAN=$(cat <<'EOF'
  MISSION MODE: adopt
  <captured objective + standing directive>
EOF
  )
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh rebaseline <sid> <root> "$PLAN"
  ```
  (Capture into `"$PLAN"` via a quoted heredoc and pass it double-quoted — the captured objective is
  untrusted; a single-quoted literal breaks on an apostrophe, a double-quoted raw literal executes
  `$(...)`; §7 rule.)
  Parse the returned status line (Section 7). If the user is away, log a **loud CHALLENGE** explaining
  the rebaseline and proceed.

**Judgment threshold (don't over-constrain):** route each *unit of work worth planning* through the
per-part sequence — a real feature/change gets the full panel; a typo or one-liner does NOT. Use
judgment about what is substantial. This is the same spine-not-cage principle.

**Exit:** adopt mode is **session-sticky** — you stay in it until the user runs `/mission clear`.
Nothing else exits it. `status` always surfaces the active directive so the user knows they're in it.

---

## 5. Level-2 — the per-part sequence (an objective, not a trapped loop)

For each part, resume at the LOG's last `(part, phase, round, dry)` after any compaction (Section 8).

**Parallel-INDEPENDENT discipline — applies to every fan-out below, load-bearing.** When you spawn
subagents in parallel, each gets a **self-contained prompt**, **NONE sees another's in-flight or
finished output**, and you reconcile/merge ONLY after all have returned (**barrier-then-merge**).
Independence is the point — independent perspectives catch disjoint failure classes; chaining
reviewers so #2 reads #1's output collapses them toward one view and reintroduces correlated blind
spots. Never chain reviewers "to save work."

### Phase 1 — RESEARCH (parallel, independent, barrier-then-merge)
Spawn in parallel, blind to each other:
- a **Claude explorer subagent** (primary: architecture / scope / risk) — spawned normally (medium);
- a **Codex read-only fact pass** proving deps / build & test commands / runtime. The scope-prove
  prompt carries mission-DERIVED scope (untrusted), so it must **NEVER** be inlined into a double-quoted
  command arg — a `$(...)`/backtick in the derived scope would EXECUTE in your shell before
  `codex -s read-only` ever starts (§7 injection rule). Write the prompt to a file and feed it via
  **stdin**, so no untrusted text is ever shell-evaluated:
  ```bash
  # write the scope-prove prompt to a temp file (no shell expansion of its contents), then run it through
  # the house wrapper — it always feeds stdin from the file (`- < promptfile`), inherits the config's
  # authoritative effort (unpinned = newest-model default), and writes a machine-readable `.status`
  # sidecar; no untrusted text ever reaches the shell:
  bash /Users/omidzahrai/.claude-dotfiles/scripts/codex-exec.sh /tmp/mission-scope-prompt.$$ /tmp/mission-scope-out.$$ <root>
  # CHECK THE .status sidecar — codex-exec writes ok|timeout|unavailable|nonzero-N. On anything but
  # `ok` the scope pass did NOT run (Codex down / timed out); do NOT treat an empty/partial
  # /tmp/mission-scope-out.$$ as "no facts found" — note the degrade and lean on the Claude fact pass:
  st=$(cat /tmp/mission-scope-out.$$.status 2>/dev/null)
  [ "$st" = "ok" ] || echo "mission: scope-prove Codex pass DEGRADED (status=${st:-missing}) — proceeding on the Claude fact pass alone; record the gap as a note"
  ```
  (If you must pass it as an arg instead, capture it into a variable via a quoted heredoc/file and pass
  it double-quoted `"$VAR"`; never inline derived/untrusted content as a single- or double-quoted literal.)
Reconcile after both return. An **unresolved factual contradiction** → `pending` (batched) + a `note`
recording the forced assumption, then proceed on the **more-evidenced branch, LOUDLY**. Otherwise
`note` the reconciled scope. Log the research round (Section 7).

### Phase 2 — PLAN (Claude-authored; cross-model INDEPENDENT review loop)
Invoke the Skill tool with `skill: plan`. Continue once it returns. `/plan` runs its own Claude
plan-reviewer subagents AND a default parallel Codex plan pass every round (via `codex-exec.sh`) —
that IS the cross-model review lane, so do NOT spawn a separate per-round Codex plan reviewer here
(one lane, not two). That built-in Codex pass attacks executability — missing commands, undefined
steps, ordering/dependency bugs, and especially **TEST GAPS**.

**TEST-TRUSTWORTHINESS is a REQUIRED finding-class here.** Convergence is theater if the repo's tests
are weak. Assess existing coverage; if weak or absent, the part-plan MUST add meaningful tests (for
THIS repo, "tests" = the harness convention — `test-*.sh` / assumption tests; for code repos:
unit/integration). Log the verdict BEFORE the first implement round — convergence cannot be reached
while test-trust is unresolved:
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] test-trust part=<N>=<ok|added|n/a>" "m<N>-test-trust"
```
**Criticer surfacing.** `/plan` runs the generative `criticer` lane and writes a `## Criticer Notes`
section into the part-plan. After `/plan` returns, if that section has findings, surface a ONE-LINE
headline into the mission LOG so it lands in the banner's recent-log tail (the full notes stay in the
plan file). Keep the headline ≤200 chars; one emit per part+round (the fixed idtag suppresses a retry):
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] criticer part=<N> findings=<K> <one-line headline>" "m<N>-criticer-r<round>"
```
Advisory only — criticer never gates; you decide whether any note changes the plan.

Parse the returned status line (Section 7). This is a **durable resume marker**: on resume, find it
via the grep-over-FULL-log idiom (Section 8 — it must survive log rotation). **Absence = unresolved**
→ re-assess test-trust before any implement round; **presence = honored** → trust the recorded verdict
and proceed. Merge/dedupe reviewer findings (overlap = confidence, divergence = signal); iterate; log
each plan round (Section 7 round-line schema).

### Phase 3 — IMPLEMENT  ∥  Phase 4 — REVIEW BARRIER (the parallelism win)
Invoke the Skill tool with `skill: implement --no-review <explicit-per-part-plan-path>` — **always
pass the EXPLICIT plan path for THIS part** (the plan `/plan` just produced in Phase 2), never a bare
`implement --no-review` that could grab a stale or wrong plan from the ready-plans dir. Continue once
it returns. Because `--no-review` makes `/mission` own the plan lifecycle (see PART-DONE below for
retiring the plan), the plan path must be unambiguous. The `--no-review` flag suppresses
`/implement`'s built-in tail implementation-reviewer so **`/mission` owns the review barrier** (no
double impl-reviewer; the barrier runs concurrently). **Claude owns integration**;
Codex assists per-chunk. Full hand-over to Codex is allowed ONLY for isolated, mechanical, well-
specified chunks — and ONLY in a worktree that does NOT contain the bridge artifacts (they live at
the canonical root, never inside a per-part worktree), with Codex run `-s read-only`.

**BEFORE dispatching the barrier, OPEN the AWAIT marker** (Task C — the durable "work launched, not
yet all-returned" record; `A` is this round's barrier attempt, starting at 1. R4 — a lost-wake REPLAY
re-runs the missing lane on the SAME attempt A (the persisted lane bits are reused, not discarded);
`A` increments to A+1 ONLY when a lane genuinely times out / FAILs (§8, §12.1 step 4), NEVER on a bare
replay). This is what a wake sees when a background lane completes but this turn already ended:
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh await <sid> <root> "part=<N> phase=review round=<K> kind=job op=review-barrier attempt=<A> need=3 got=0"
```
Then run the **REVIEW BARRIER** — both IN PARALLEL, independent, neither sees the other's output:
- the **implementation-reviewer subagent** (plan-completeness / quality) — Claude, spawned normally (medium);
- Invoke the Skill tool with `skill: codex-review --effort high`. Continue once it returns. (The
  `--effort high` arg pins its Codex passes at high → the full 4 Codex + 3 Claude cross-model panel + verify.
  High is the right floor for this convergence LOOP: it re-runs to 2-dry and finds everything across rounds,
  so no single pass needs xhigh. For a part you judge genuinely critical — auth, payments, data migrations,
  deletions / irreversible ops, prod config, untrusted-input parsing — you MAY raise that part's barrier to
  `skill: codex-review --effort xhigh` instead. Rare by design; the loop default stays `--effort high`.)

**AWAIT got-bit protocol (Task C — the join that makes a lost barrier-completion wake self-heal).** As
EACH lane returns AND its usable result is persisted to DURABLE NOTES (the impl-reviewer subagent's
findings; and the `/codex-review` output you materialize into `review_output` per the BINDING CONTRACT
below), UPDATE the AWAIT marker with that lane's got bit set — impl-reviewer sets `bit1`, codex-review
sets `bit2`:
```bash
# impl-reviewer lane writes ONLY ITS bit (bit1). got=1:
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh await <sid> <root> "part=<N> phase=review round=<K> kind=job op=review-barrier attempt=<A> need=3 got=1"
# codex-review lane writes ONLY ITS bit (bit2). got=2 — NOT got=3. The reader OR-accumulates the two
# lane bits (1|2=3 = join-ready), so the ORDER of the lanes does not matter. Writing got=3 from one
# lane would falsely read ready=1 if that lane returned FIRST, banking before the other lane finished (D2):
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh await <sid> <root> "part=<N> phase=review round=<K> kind=job op=review-barrier attempt=<A> need=3 got=2"
```
**Returning from `/codex-review` alone NEVER advances the round.** The round's normal `phase=review …
findings=<COUNT>` (or VOID) line is banked ONLY at the whole-barrier join (`got=need=3`, BOTH lanes'
verdicts validated and persisted). If this turn ends after opening the AWAIT (or after only one got bit
is set) with a lane still in flight, that backgrounded lane's completion is the wake; if the wake is ever
lost, the next §12 tick sees `AWAIT kind=job got<need` with NO tracked job and replays ONLY the missing
lane (§8 AWAIT rows) — so correctness does not depend on 100% wake delivery.

**Codex-unavailable (TOTAL or PARTIAL) ⇒ VOID the round (do NOT count it as dry).** The RELIABLE
machine signal is the **`Codex-passes: N/4`** token on the **`Engine:` header line INSIDE the
report FILE** `/codex-review` Step 7f persists (`report-final.md`) — the FILE-FED contract. 7f
prints `Run-id: <run-dir basename>` UNCONDITIONALLY (even when report writing fails) and
`Report-file: <path>` as its ACTUAL FINAL output line only when the file exists. Parse the file
via the `parse-codex-header` verb (never grep the whole report body — anti-spoof lives in the
verb: it reads only the FIRST full-shape `^Engine: … Codex-passes: N/4 … Verified:` line):

```bash
# ── BINDING CONTRACT (READ FIRST — this block is NOT self-sourcing) ────────────────────────
# This fence runs in a FRESH shell that does NOT inherit your conductor context, so YOU (the
# conductor) MUST bind its inputs before running it — exactly as every other write example in
# this file substitutes <sid>/<root>/<N>/<K>. Set them as real shell vars at the TOP of the block:
#   sid=<this mission's session id>     root=<canonical root>     # both from the §2 setup
#   N=<current part number>             K=<current review round>  # from the live [mission] round line
# AND — because the /codex-review Skill returns its text to YOUR context, not to a shell var — you
# MUST materialize that text into review_output yourself: after /codex-review returns, WRITE its
# FINAL output verbatim to a temp file (use the Write tool, or a heredoc you fill from the Skill's
# result), then read it back. Do NOT leave review_output unset — an empty value makes every parse
# below empty, the VOID line's part=/round= empty, the validator REFUSE it as bad-shape, and the
# panel-unavailable-3x loop-breaker can then NEVER fire (the exact silent chokepoint this guards):
#   # (you write /tmp/mission-review-<sid>.out from the /codex-review result first, THEN:)
#   review_output=$(cat "/tmp/mission-review-$sid.out")
# All FIVE of sid/root/N/K/review_output MUST be non-empty before this block runs — treat the
# angle-bracket names above as MANDATORY substitutions, not optional defaults.
# ───────────────────────────────────────────────────────────────────────────────────────────

# Mint the attempt identity ONCE, BEFORE each panel invocation (fallback identity for a
# broken/legacy producer that prints no Run-id line; that edge is non-replay-idempotent —
# acceptable: an absent Run-id already means the producer contract failed, the attempt must count):
attempt_id=$(uuidgen | tr 'A-F' 'a-f' | tr -cd 'a-f0-9' | tail -c 6)  # macOS uuidgen is UPPERCASE — lowercase FIRST

runid=$(printf '%s\n' "$review_output" | sed -n 's/^Run-id: //p' | tail -1 | tr -cd 'A-Za-z0-9.' | tail -c 6)
# Report-file is accepted ONLY as the ACTUAL FINAL LINE (a tail -1 over all matches would let
# reviewed content quote a fake path when report creation failed):
rf=$(printf '%s\n' "$review_output" | tail -1 | sed -n 's/^Report-file: //p')
case "$rf" in "${TMPDIR:-/tmp}"/codex-review.*/report-final.md) ;; *) rf="";; esac
# path <-> identity binding: the run-dir basename must contain the parsed Run-id:
[ -n "$rf" ] && { case "$(basename "$(dirname "$rf")")" in *"${runid:-__none__}"*) ;; *) rf="";; esac; }
passes=""; [ -n "$rf" ] && [ -f "$rf" ] && passes=$(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh parse-codex-header "$rf")
if [ "$passes" != "4/4" ]; then
  h8=$( [ -n "$rf" ] && [ -f "$rf" ] && shasum -a 256 "$rf" | cut -c1-8 || echo nofile )
  reason=$(printf 'codex-passes-%s' "${passes:-absent}" | tr -cd 'a-z0-9.-')
  # CAPTURE the log stdout and REQUIRE it to be `ok` before proceeding — mission-write.sh ALWAYS
  # exits 0, so rc is meaningless; the STATUS TOKEN on stdout is the only signal (§7). A `COLLISION`
  # / `REROUTED-TO-NOTES` / `FAILED rc=N` means the VOID did NOT bank, and proceeding to void-count
  # would undercount (the whole loop-breaker depends on the VOID being on disk):
  void_status=$(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log "$sid" "$root" \
    "[mission] VOID part=$N phase=review round=$K reason=$reason" "m$N-void-r$K-${runid:-$attempt_id}h$h8")
  case "$void_status" in
    *ok*) ;;   # banked, or idempotent same-run replay ("dedup-idempotent" also reports ok) — proceed
    *) echo "mission: VOID did NOT bank (status: ${void_status:-<empty>}) — STOP; re-derive N/K/round and re-log per §7 status-token reactions, do NOT proceed to void-count"; return 1 2>/dev/null || exit 1 ;;
  esac
  # runid makes each panel ATTEMPT distinct (even identical bytes / missing report); replaying the
  # SAME run+report dedups quietly. void-count is a READ-ONLY dispatcher verb (this block runs in a
  # fresh shell and never sources the lib):
  vc=$(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh void-count "$sid" "$root" "$N" "$K")
  # void-count stdout contract: bare integer >= 0 = the consecutive count; -1 = ERROR SENTINEL
  # (refused gen-sliced read, e.g. gen-boundary-mismatch). -1 is the MACHINE-BLOCKING representation
  # of a refused read — stderr alone cannot block a count-testing caller. Callers MUST branch on it:
  if [ "$vc" = "-1" ]; then
    # STOP: the gen-sliced read refused (gen-boundary/marker mismatch, or a non-numeric arg — the
    # cases void-count actually detects; a physically-corrupt archive is NOT distinguished here and
    # is instead caught by mission_verify under the lock + the §10 corrupt-bridge guard). Do NOT
    # treat as count=0 and do NOT advance — surface loud as the Section 10 corrupt-bridge point of
    # contact and halt this part until the write-path self-heal (or the user) repairs the boundary.
    :
  elif [ "$vc" -ge 3 ]; then
    fail_status=$(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log "$sid" "$root" \
      "[mission] FAIL part=$N phase=review reason=panel-unavailable-3x attempt=3" "m$N-fail-panel3x-r$K")
    case "$fail_status" in *ok*) ;; *) echo "mission: panel-3x FAIL did NOT bank (status: ${fail_status:-<empty>}) — surface to the user regardless; the STOP-LOUD stands"; esac
    # IMMEDIATE STOP-LOUD: panel-unavailable-3x is a NAMED Section 10 trigger (a point of contact,
    # like corrupt-bridge) — do NOT wait for the 5-FAIL tally: the same round can never advance
    # during a permanent panel outage, so no further FAILs would ever accrue and the run would loop
    # forever. Surface to the user / away-policy checkpoint NOW; do not re-run the panel again.
  fi
fi
```

Belt-and-suspenders alongside the file-fed count (either also voids the round):
- the legacy total-failure marker `Codex unavailable` (all 4 failed), OR
- the legacy per-pass marker `(Codex-` … `unavailable)` / `(codex-K unavailable)` (any one of the 4
  passes unavailable).

A round counts toward the 2-dry convergence ONLY if EVERY independent reviewer's verdict is present —
ALL 4 Codex passes (`Codex-passes: 4/4`) plus the Claude reviewers (see Section 6 VOID-on-dead-reviewer).
If any of the above matches, this round is **VOID**: log the durable VOID marker (Section 7), re-run the
panel; do NOT bank a void round.

Merge ALL findings at **ONE synthesis barrier**. Write the round checkpoint in TWO parts so it
survives the log machinery (the lib reroutes any LOG line whose FULL on-disk form — `idtag + TAB +
entry + newline`, NOT the visible entry alone — is ≥480 bytes to DURABLE NOTES, where the resume grep
won't find it; so budget the round line with a SHORT idtag + COUNT only, §7). **ORDER MATTERS — write the verbose `note`
FIRST, then the terse round line:**
1. **Persist the verbose per-reviewer findings `note` FIRST** (DURABLE NOTES), referenced by the
   round's `part/phase/round`.
2. **THEN persist the terse round checkpoint line**, with `phase=review` and a short findings COUNT
   (Section 7 round-line schema) — TERSE, never verbose findings text.

This order is deliberate: the round line is the thing resume KEYS on (§8). If a compaction lands
BETWEEN the two writes, the verbose note exists but the round line is simply ABSENT, so resume sees no
banked review round and **re-runs the round cleanly** — far better than the reverse order, which would
strand a banked `phase=review` round whose findings note was never written (no recoverable findings to
fix). Never write the terse round line before its findings note.

The `phase=review` checkpoint means "findings logged, fixes NOT yet applied"; when you begin applying
fixes, advance the SAME round to `phase=fix` (Section 7) so a compaction in the fix window resumes
unambiguously (Section 5 resume rules / Section 8). The dry-count stays auditable from the verbatim
record rather than asserted by you.

**Continuation epilogue (Task A/B — naked-yield seam).** After the barrier join banks this round line
with work still owed (findings to fix, or the next fresh review round), do NOT end the turn naked: run
the §12 continuation epilogue — schedule the self-wake as your LAST continuation-deciding call (only the
tick-lock release may follow) — UNLESS you are at one of the four §9 points-of-contact / a §12.3 stop. Schedule EVEN when a tracked `run_in_background` lane is
pending: its completion is the fast wake, the scheduled heartbeat is the backstop that self-heals a lost
one (a scheduled wake is the ONLY continuation owner — D1). A failed schedule is a LOUD error, never a silent stop.

### CONVERGENCE (implement ↔ review fix-cycle)
Loop, per round K: if findings are actionable, log the **`phase=fix`** checkpoint for the SAME round
(it marks "now applying fixes"), fix via `skill: implement --no-review <plan-path>` → re-run the
barrier (fresh, independent) as the **NEXT** round K+1 → log that round's `phase=review` checkpoint.
**Never re-run an idtag round you already banked** (Section 8 round-ambiguity decision table). See Section 6 for the
convergence rules. On a PLAN divergence → `challenge` (loud). On an open human-decision → `pending`
(batched).

**Continuation epilogue (Task A/B — naked-yield seam).** After logging the `phase=fix` checkpoint and
re-arming the next round (whether the fix runs this turn or a fresh barrier is launched), if the turn
would otherwise end with the fix/re-review still owed, run the §12 continuation epilogue (schedule the
self-wake as your LAST continuation-deciding call — only the tick-lock release may follow) UNLESS you are
at a §9 point-of-contact / stop. Schedule EVEN when a
tracked `run_in_background` lane is pending (the completion is the fast wake, the heartbeat the backstop —
D1). Never yield naked with a fix cycle mid-flight.

**Resume substates within a round (Section 7 schema; these are the WITHIN-ROUND rows of the §8
round-ambiguity decision table — they MUST match §8 verbatim, one decision, two cross-references. §8 is
the canonical TOTAL table and additionally covers completed-part state (`PART-DONE`/`PART-RETIRED`), the
fresh-part `PART-START`-with-no-round entry state (begin at `research`), and the non-review/non-fix
phases (`research`/`plan`/`implement`); consult §8 for those):**
- last round line is **`phase=review findings>0`** (ACTIONABLE — findings logged, `dry` NOT advanced)
  → resume into the FIX of the SAME round K: log `phase=fix` round=K and apply the fixes. Do **NOT**
  start a fresh review round K+1 (that would skip the fix).
- last round line is **`phase=review findings=0`** (dry-advancing — `dry` already incremented) → start
  the NEXT FRESH review round K+1 per the `2 − dry` rule.
- last round line is **`phase=fix`** (a fix was in flight at the compaction) → VERIFY/continue the
  partial fix to completion, THEN re-run the barrier as the next round K+1. Do not assume the fix
  finished; reconcile against the working tree.

Only a `phase=review findings=0` (dry-advancing) round OR a completed `phase=fix` starts round K+1; an
actionable `phase=review findings>0` round always resumes into its own fix first.

When converged (Section 6: 2 consecutive non-void dry rounds):

**FIRST emit the live-verify line (Task 4 — UNCONDITIONAL, once per part, immediately AFTER the `dry=2`
round is banked and BEFORE `PART-DONE`).** This is the ONLY position that satisfies the freshness rule:
after the `dry=2` bank, before any advance, no later actionable event exists so the live-verify is the
newest evidence. `mission-write.sh` enforces this — a `PART-DONE` without a FRESH, gen-current
`live-verify part=<N>` is REFUSED `rc=4` and BLOCKS retirement. Run the part's live leg and record the
evidence token; for a non-UI part with nothing to click, emit `status=n/a` with a mandatory reason:
```bash
# UI/effect part — run the live leg, capture the concrete effect (a filesystem path is STAT-verified;
# an od:<num> / sha:<hex> / URL is a syntax-checked RECORDED token, not a round-trip proof):
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] live-verify part=<N> round=<K> status=ok evidence=<token>" "m<N>-live-verify-r<K>"
# non-UI part — no interactable surface to drive:
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] live-verify part=<N> round=<K> status=n/a reason=<slug>" "m<N>-live-verify-r<K>"
```
`round=<K>` is the just-banked `dry=2` round; it scopes the idtag so a fresh re-verification after a
later fix mints a NEW line instead of colliding. Parse the status line (Section 7).

**Stale-claim guard (automatic — no action required).** Banking the `dry=2` round auto-stamps a
`[mission] SNAPSHOT part=<N> kind=converged tree=<h16> …` line recording the code-tree fingerprint
convergence was reached at (a deterministic hash of committed + staged + unstaged + untracked content,
excluding the mission's own scratch files). This closes the ONE gap the write-time guards structurally
cannot: a claim that was valid when written, then the tree changed under it with no new log line. THEN
log PART-DONE:
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] PART-DONE part=<N> (converged)" "m<N>-part-done"
```
Parse the status line (Section 7) — a `FAILED rc=4 (REFUSED …)` here means the part is NOT converged
(missing/stale live-verify, the dry-count fold is not machine-clean, or **the tree moved after
convergence** → `convergence-stale`): do the named remediation and re-attempt; do **NOT** advance. For
`convergence-stale`, re-run the review at the current tree (a fresh `dry=1`→`dry=2` pair re-stamps the
snapshot at the new tree), then re-log `PART-DONE`. A legacy part with no snapshot / a non-git root is
never blocked by this check. (Manual on-demand check: `bash …/mission-drift-check.sh <sid> <root>` reports
per-part `CLEAR`/`DRIFT`/`N/A` — read-only, never enforces.) Then **retire the part plan**: because `--no-review` made `/mission`
own the plan lifecycle, MOVE the per-part plan from ready-plans to done-plans after `PART-DONE` (use
the project's done-plans convention). A plan left in ready-plans is a stale plan a later part could
wrongly grab. **Check the `mv` result — do NOT proceed silently on failure** — and make it idempotent
(a resume that lands after PART-DONE but before the `mv` must be able to tell whether retirement
happened):
```bash
if [ -f "<done-plans>/<part-plan>.md" ]; then :   # already retired (idempotent — resume after PART-DONE)
elif mv "<ready-plans>/<part-plan>.md" "<done-plans>/"; then
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] PART-RETIRED part=<N>" "m<N>-part-retired"
else
  # mv FAILED — surface it loudly, do NOT silently continue; log a FAIL (Section 7) and STOP/CHALLENGE
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] FAIL part=<N> phase=retire reason=plan-mv-failed attempt=<A>" "m<N>-fail-plan-mv-failed-<A>"
fi
```
Parse each status line (Section 7). The `PART-RETIRED part=<N>` marker (idtag `m<N>-part-retired`) lets
a resume distinguish "converged AND plan retired" from "converged, retirement still pending"; on resume,
if `PART-DONE` is present but `PART-RETIRED` is absent, re-attempt the idempotent retirement before
advancing.

**Continuation epilogue (Task A/B — naked-yield seam).** `PART-DONE` banking with a later part still to
run is NOT the end of the mission — it is a mid-mission transition. If the turn would end here with
retirement or the next-part advance still owed (and this is NOT the final part's natural lifecycle close,
§11), run the §12 continuation epilogue (schedule the self-wake as your LAST continuation-deciding call —
only the tick-lock release may follow). The natural lifecycle close of the FINAL part is the one §9 point-of-contact where the loop legitimately stops.

**Advance to the next part** — log a `PART-START` lifecycle line for the new part so resume can tell a
converged part from one still in progress (Section 8 / Section 9):
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] PART-START part=<N+1> name=<slug>" "m<N+1>-part-start"
```
Parse the status line (Section 7), then begin the next part's Phase 1.

**Continuation epilogue (Task A/B — naked-yield seam).** After banking `PART-START part=<N+1>`, the next
part's research is owed. If the turn would end before that research is dispatched, run the §12
continuation epilogue (schedule the self-wake as your LAST continuation-deciding call — only the tick-lock
release may follow) UNLESS you are at a §9 point-of-contact / stop. Schedule EVEN when a tracked
`run_in_background` job is pending (D1: the completion is the fast
wake, the heartbeat the backstop).

**Push guidance (if you push a converged part's work).** Pushing is not part of the per-part loop, but
when you do surface completed work upstream, NEVER overwrite another agent's work: `git fetch` the base
first and check for divergence; on any UNEXPECTED divergence **STOP** (rebase, never force). The bridge
artifacts live at the canonical root, never inside a per-part worktree, so a push of the code worktree
never touches the mission LOG.

---

## 6. Convergence rules (restated crisply)

- **Soft targets:** plan reviews typically **4-6** (4 is the usual floor); codex reviews typically
  **3-6**. These are *guidance, not gates*.
- **Hard cap 6** either way.
- **Stop at 2 consecutive DRY rounds.** "Dry" = the **independent reviewers** returned **zero new
  actionable findings**, logged verbatim — NOT you grading your own work.
- **An ACTIONABLE round RESETS `dry → 0`** (not merely "does not count"). Any round whose independent
  reviewers produced ≥1 new actionable finding breaks the consecutive-dry streak: the post-round `dry=`
  on that round line is `0`, and the NEXT round's `dry=` starts again at `0`. Only two back-to-back
  zero-actionable rounds reach `dry=2`. State the post-round `dry` on the round line accordingly
  (Section 7). **This also covers the post-VOID case:** if a re-run of a VOIDed round turns out
  ACTIONABLE (the reviewer that finally ran found ≥1 finding), `dry` RESETS to `0` too — so a `dry=2`
  streak can NEVER span a code change, whether that change came from a normal actionable round or from
  an actionable round that previously VOIDed. A VOID by itself does not advance `dry` (the round did
  not count); an actionable VOID-rerun resets it.
- **VOID-on-dead-reviewer (the single biggest false-converge risk).** A round counts toward the
  2-dry tally **ONLY if EVERY independent reviewer produced a parseable, on-topic, evidence-citing
  verdict** — that means ALL **4 Codex passes + 3 Claude reviewers** of the panel actually ran, i.e. the
  report shows **`Codex-passes: 4/4`** (see "Codex-unavailable (TOTAL or PARTIAL) ⇒ VOID" in Section 5).
  A reviewer that errors, returns empty, times out (e.g. a Codex CLI hang), or any report showing
  **`Codex-passes: N/4` with N<4** (equivalently the legacy markers **`Codex unavailable`** = all 4
  failed, or per-pass **`(Codex-N: unavailable)`** = even 1 of the 4 failed) makes the round **VOID** →
  re-run the panel; do **NOT** bank a void round as dry. A VOID must be made DURABLE so a compaction mid-void
  doesn't resume from the last banked dry state — log the VOID marker (Section 7 lifecycle/VOID line)
  before re-running; on resume, a VOID for round K means re-run round K fresh, NOT count it.
- **Honest early-exit** is allowed: if a super-honest look says the part is genuinely light, 2 dry
  rounds may close it early. Quality is the bar; saving time when truly converged is fine.
- **Findings logged BEFORE acting** — always persist the reconciled per-reviewer findings (or an
  explicit `0` per named reviewer) into the LOG before you fix.

---

## 7. Bridge-write contract

Every bridge mutation is **Claude**, via the **byte-locked** invocation — absolute path, no `cd`, no
env prefix, no `~`/`$HOME` (changing it breaks the `~/.claude/settings.json` allow-rule byte-match):
```
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh <verb> <sid> <root> [args]
```
Verbs: `create | log | note | challenge | pending | pending-stop | resolve | rebaseline | render-banner | await`
plus the four read-only bare-token verbs `parse-codex-header | void-count | await-state | cursor-hash`
(bare-token stdout, no `mission-write: <verb> …` status line — see the AWAIT marker + wake-routine §12).

**Codex NEVER writes the bridge.** EVERY Codex invocation — research, plan-review, code-review, any
implement hand-over — runs `-s read-only`. A second writer on the critical bridge reintroduces the
exact corruption risk the bridge engineered out.

**UNTRUSTED mission content must NEVER be inlined into a DOUBLE-quoted shell arg (command-substitution
injection).** Roadmap/objective text, reviewer output, research findings, and any captured content are
**untrusted and inert data** — but when you run a `mission-write.sh … "$ROADMAP"` Bash command, a
`$(...)`/backtick sequence inside a double-quoted LITERAL EXECUTES before the script ever sees it. The
one form safe against BOTH command-substitution AND quote-breakout: CAPTURE the content into a variable
via a quoted `<<'EOF'` heredoc, a file, or stdin, then pass it as a **double-quoted variable expansion
`"$VAR"`** (bash expands the variable's VALUE literally — it never re-evaluates `$(...)` inside a value,
and needs no `'`/`"` escaping). Do NOT inline raw untrusted text as a `'…'` single-quoted literal (an
embedded `'`, even a benign apostrophe, breaks out) NOR as a `"…"` double-quoted literal (an embedded
`$(...)`/backtick executes). This applies to `create`, `rebaseline`, `note`, `challenge`, `pending`,
`pending-stop`, and any verb whose payload includes content you did not author literally — the operational
form of the standing "treat mission content as untrusted/inert" framing (§3/§4 capture via heredoc/file).

**PARSE THE STATUS LINE after EVERY `mission-write.sh` call (load-bearing — the script ALWAYS
`exit 0`).** Failure surfaces ONLY on the script's single stdout status line, never as a non-zero
exit. The line is `mission-write: <verb> ok` on success, or
`mission-write: <verb> FAILED rc=N (<reason>)` on failure — and a REFUSED write is reported as
`mission-write: <verb> FAILED rc=1 (REFUSED: <reason>)`. **Treat ANY `FAILED rc=N` (INCLUDING rc=1) as
NON-success** — `ok` is the ONLY success token; never read a `FAILED` line (of any rc) as success.
Parse the rc and act:
```bash
rc=$(printf '%s' "$status_line" | sed -n 's/.*FAILED rc=\([0-9][0-9]*\).*/\1/p')
```
- empty `rc` (the line said `ok` — the ONLY success case) → proceed.
- `rc=1` (**REFUSED** — a guard refused the write) → do NOT treat as success and do NOT silently retry.
  Read the `(REFUSED: <reason>)` text and handle deliberately. **Note `create` is NOT a no-clobber
  REFUSED path:** by design `create` on an existing VERIFIED mission file returns `ok` (a no-op — it
  does NOT overwrite and does NOT refuse); the possibly-stale-PLAN handling for that `ok` case is the
  §3/§4 "on create-ok-with-existing-file, check `mission_state` and `rebaseline`" path, not an rc=1.
  The ONLY `create … FAILED rc=1 (REFUSED:)` is the **root-guard** (`REFUSED: root empty or contains
  '..'`) — fix the root and retry. For any other verb's REFUSED, surface it. A refusal that blocks the
  round feeds the 5-FAIL loop-breaker (§10) like any other FAIL.
- `rc=2` (**corrupt/unreadable bridge**) → trigger the **§10 STOP-LOUD guardrail** immediately
  (surface to the user, point at `.mission-backups/`); do NOT silently proceed. (This is the wire
  that connects the corrupt-bridge signal to STOP-LOUD.)
- `rc=3` (**lock busy — the ONE retryable rc**) → retry the SAME call a few times (e.g. up to 5, brief
  pause between); if still `rc=3`, log a `FAIL …reason=lock-busy` line (it routes through a DIFFERENT lock
  attempt) or proceed and note it, per the away policy (§9). **Only `rc=3` is retryable** — never blind-retry
  any other non-zero rc.
- **`pending-stop` is the BLOCKING mandatory-stop opener: its ONLY proceed-able outcome is `rc=0` with an
  echoed `id=pd:<seq>-<slug>`. EVERY non-zero rc means the STOP did NOT open — do NOT proceed, do NOT
  auto-advance; STOP-LOUD / surface to the user. The generic "any other non-zero rc → log + proceed" rule
  below NEVER applies to `pending-stop` (proceeding after a stop that never opened is the exact naked-yield
  this contract forbids).** The full fail-closed enumeration (R8r3 + R8r4-S1 — none is a retry except the
  one `rc=3`, and none is a proceed): `rc=1` bad args / refused (fix + re-issue); `rc=2` corrupt bridge
  (§10 surface); `rc=3` lock busy (the ONE retryable — retry the SAME call; if still busy, STOP-LOUD, do
  NOT proceed); `rc=4` backup failed; `rc=5` mktemp failed; `rc=6` self-check / rename failed (originals
  intact); `rc=7` sequence-exhausted (no barrier opened); `rc=8` the assembled AWAIT line ≥480B (no barrier
  opened); `rc=9` the human AWAIT did not land cleanly (no pd line, no echo); `rc=10` mission is CLEARED (a
  STOP below MISSION-CLEARED is permanently hidden — the mission is done; do not re-open); `rc=11` lifecycle
  unreadable (§10 corrupt-bridge surface, do not retry until the log/archive is readable); `rc=12` a
  DIFFERENT open human STOP is already live (resolve/deny it FIRST, then re-open); `rc=13` the same op is
  live with a DIFFERENT question (resolve/deny it FIRST — a changed question is a new decision); `rc=14` an
  ORPHAN barrier (its pd line was lost, or it already carries a durable DECISION) — safe-ABORT deny it
  (write `outcome=deny`, close the barrier, do NOT proceed; a still-needed decision opens a FRESH
  pending-stop under a DIFFERENT slug), never re-open. Each is a deliberate, agent-handled do-not-proceed outcome.
- any other non-zero rc (4/5/6/7/127) → log it + proceed; if it recurs for the same part+phase it
  feeds the 5-FAIL loop-breaker (§10). **EXCEPTION: this proceed rule does NOT apply to `pending-stop`
  (see the fail-closed block just above) — for the blocking opener, every non-zero rc is do-not-proceed.**

**EXACT-TOKEN status contract for the `log` verb (Task 4 — REPLACES the old "empty rc ⇒ ok" rule
for `log`/`note`/`challenge`/`pending`).** `mission-write.sh log` now emits one of exactly four
tokens after `mission-write: log ` — match the LEADING token and react MANDATORILY:
- **`ok`** → the write appended (or was an idempotent no-op) → proceed. The ONLY success token.
- **`COLLISION`** (`mission-write: log COLLISION (…)`) → the idtag exists with DIFFERENT content →
  **STOP**, re-derive the gen/round numbering, and **never assume the line was banked** (a banked
  round you think you wrote may not exist; a fresh line you meant to write did not land). Do NOT retry
  blindly — reconcile against the recovered LOG first.
- **`REROUTED-TO-NOTES`** (`mission-write: log REROUTED-TO-NOTES (…)`) → a free-text entry exceeded
  480B and went to DURABLE NOTES → **rewrite it TERSE and re-log until you get `ok`** (a machine
  shape that is too long is REFUSED `line-too-long` instead — see the length rule below).
- **`FAILED rc=N (…)`** → a REFUSED/failed write. `rc=4` on a **PART-DONE or a live-verify** write
  **BLOCKS retirement/advance** (the explicit carve-out from the generic rc-4 "log + proceed" policy):
  the part is NOT converged — read the `(REFUSED …)` slug (`PART-DONE without live-verify` /
  `live-verify-stale` / `convergence-not-machine-clean` / `convergence-stale` / `gen-boundary-mismatch`),
  do the named remediation (run the live leg, re-run the panel/fixes, re-review at the current tree,
  repair the boundary), and re-attempt. `rc=5`
  is a wrong-gen idtag prefix REFUSE (re-derive the gen). `rc=1 (REFUSED …)` is a grammar/control-char
  refusal — fix the shape.
- **`void-count` / `parse-codex-header` / `await-state` / `cursor-hash`** are the FOUR read-only verbs
  that DO NOT emit this status line — their stdout is a bare machine token (`void-count`: `N` / `-1`;
  `parse-codex-header`: `N/4` / empty; `await-state`: `none` / `corrupt` / `await …`; `cursor-hash`: a
  64-hex digest / `corrupt`). A `void-count` of
  **`-1`** is the ERROR SENTINEL of a refused gen-sliced read: **STOP** (do not treat as count 0, do
  not advance) and surface the corrupt/boundary condition (§10) until the write-path self-heal (or the
  user) repairs it.

**LOG schema — the SINGLE canonical definition; every resume rule (§5/§8/§9) reads lines
back in EXACTLY these shapes.** These are `log`-verb entries with a structured `[mission]` payload —
not new verbs; the real on-disk line is `<idtag>\t<entry>`; resume matches `[mission]` ANYWHERE on the
line, not at column 0.

- **Round line** (one per part/phase/round, advanced by substate — keep it TERSE so the lib does NOT
  reroute it to DURABLE NOTES, where resume can't grep it). **The 480B reroute budget is measured by
  the lib over the FULL on-disk line — `idtag + TAB + entry + newline` — NOT the visible entry text
  alone.** So budget conservatively: use a SHORT idtag and put only the integer `findings=<COUNT>` on
  the line (never finding text); the verbose findings live in a separate `note` (§5 synthesis barrier).
  - entry: `[mission] part=<N> name=<slug> phase=<research|plan|implement|review|fix> round=<K> dry=<D>[ findings=<COUNT>]`
  - `findings=<COUNT>` is OPTIONAL in the grammar (the validator row is `( findings=C)?`) but is
    MANDATORY on `phase=review` / `phase=fix` rounds — the PART-DONE dry-count machine fold reads it,
    so a review round without it cannot bank toward convergence. It is a SHORT integer count ONLY
    (e.g. `findings=2`) — NEVER verbose finding text.
    Verbose per-reviewer findings go in a SEPARATE `note` (DURABLE NOTES), referenced by `part/phase/
    round` (Section 5 synthesis barrier). **It has a READ use, not just an audit use:** on a
    `phase=review` resume it disambiguates the substate (§5/§8 decision table) — `findings=0` ⇒
    dry-advancing round (start the next fresh review round); `findings>0` ⇒ ACTIONABLE (resume into the
    `phase=fix` of the SAME round before any new review). Every written shape has this matching read.
  - `phase=review` = "findings logged, fixes NOT yet applied"; advance the SAME round to `phase=fix`
    when you begin applying fixes (CRITICAL #2 substate; resume rules in Section 5).
  - idtag: `m<N>-<phase>-r<K>-d<D>` — the **`d<D>` is REQUIRED** (encodes the dry-count so an advanced
    dry-state is a NEW line, not an idempotent no-op); `phase` is part of the idtag so the `review`
    and `fix` substates of the SAME round are DISTINCT lines. `dry=<D>` is the **running consecutive-
    dry count (0, 1, 2)** after that round; a resume agent reads the last review-round line and needs
    `2 − D` more dry rounds.
- **FAIL line** (durable failure tally, reconstructable across compactions — feeds the §10 5-FAIL
  loop-breaker):
  - entry: `[mission] FAIL part=<N> phase=<P> reason=<slug> attempt=<A>`
  - idtag: `m<N>-fail-<reason>-<attempt>` — the **`<attempt>` is REQUIRED**: the lib dedups log lines
    on the LEADING idtag, so a reason-only idtag would collapse 5 same-reason FAILs into ONE line and
    the 5-strike guard could NEVER fire. An attempt-scoped idtag makes each FAIL a DISTINCT line.
    Increment `<attempt>` per emission within the same part+phase+reason.
  - **Events that MUST emit a FAIL line:** a failed bridge write (a `FAILED rc=N` status line per the
    parse rule above, other than a transient lock-busy that succeeds on retry); a VOID reviewer
    (reviewer errored/empty/timeout, or "Codex unavailable"); a Codex hang/timeout; lock-busy still
    failing after retries (`reason=lock-busy`); a repeated tool failure that blocks the round.
- **VOID line** (durable, so a compaction mid-void does not resume from the last banked dry state):
  - entry: `[mission] VOID part=<N> phase=review round=<K> reason=<reviewer-dead|codex-passes-N4|...>`
    (the §5 reason builder is `printf 'codex-passes-%s' "$passes" | tr -cd 'a-z0-9.-'` — the `/` in
    `N/4` is STRIPPED, so a 3/4 panel yields `reason=codex-passes-34`, NOT `codex-passes-3.4`)
  - idtag: `m<N>-void-r<K>-<runid6>h<sha8|nofile>` (run-id + report-hash identity, per the Section 5
    block: replaying the SAME run+report dedups quietly; a NEW panel attempt mints a distinct line
    even with identical report bytes; a missing report uses `nofile` and still counts) — on resume,
    a VOID for round K means re-run round K FRESH, never count it.
- **Lifecycle lines:**
  - `[mission] PART-START part=<N> name=<slug>` idtag `m<N>-part-start` (logged when advancing to a
    new part; resume uses it to skip a converged part — Section 8/9).
  - `[mission] PART-DONE part=<N> (converged)` idtag `m<N>-part-done`.
  - `[mission] PART-RETIRED part=<N>` idtag `m<N>-part-retired` (the per-part plan was moved
    ready-plans→done-plans; resume reads it to tell "converged + retired" from "converged, retirement
    pending" — Section 5 retirement block; idempotent re-attempt if PART-DONE present but this absent).
  - `[mission] test-trust part=<N>=<ok|added|n/a>` idtag `m<N>-test-trust` (before the first implement
    round; durable resume marker — Section 5).
  - `[mission] MISSION-CLEARED status=<achieved|could-not|cleared> reason=<slug>` — pass an **EMPTY
    idtag** (lifecycle lines ALWAYS append; a `mission-cleared-<slug>` idtag would dedup-suppress a
    re-clear after a rebaseline and leave the mission spuriously active — §2/§11).
  - `[mission] MISSION-REBASELINED status=active (…)` — written by the `rebaseline` verb itself (the
    lib appends it, also always-append, no dedup); a REACTIVATING lifecycle token (Section 8 active-iff).
- **AWAIT line** (the ONE durable "work launched, not yet all-returned" marker — written ONLY via the
  dedicated `await` verb, which routes through `mission_await_append` → `mission_log_append` and BYPASSES
  the `log`-verb validator; read back via the `await-state` bare-token verb, never grepped by hand):
  - entry: `[mission] AWAIT part=<N> phase=<P> round=<K> kind=<job|human> op=<slug> attempt=<A> need=<mask> got=<mask>`
  - idtag: `m<N>-await-<op>-r<K>-a<A>-g<GOT>` (generation-prefixed automatically). `started_at` is
    auto-filled by the lib (barrier-stable). `need`/`got` are bitmasks; a barrier`s IDENTITY is
    (part,round,attempt,KIND,OP) — OP separates two distinct human decisions (each pd's unique
    `<seq>-<slug>`) while both review lanes share `op=review-barrier` so they still join. For the review barrier: `need=3`, `bit1` = impl-reviewer, `bit2` =
    codex-review. **EACH LANE WRITES ONLY ITS OWN BIT** (impl `got=1`, codex `got=2`); the `await-state`
    reader OR-accumulates them (1|2=3), so lane ORDER is irrelevant. Persist each lane`s usable result to
    DURABLE NOTES *before* setting its bit. `(got&need)==need` = join-ready (`ready=1`); the barrier stays
    OUTSTANDING until a later `phase=review`/VOID/PART-DONE line SUPERSEDES it (that bank IS the join). A
    human barrier is `need=1`, closed by its own `got=1` (no separate bank).
    Write form (fields reassembled in canonical order by the lib):
    ```bash
    bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh await <sid> <root> "part=<N> phase=review round=<K> kind=job op=review-barrier attempt=<A> need=3 got=<this-lane-bit>"
    ```
    Read form — bare `none` | `corrupt` | `await kind=… op=… part=<N> round=<K> attempt=<A> phase=<P> need=<M> got=<G> ready=<0|1> started_at=<E>` (`corrupt` = a refused/failed read → §10 STOP-LOUD):
    ```bash
    bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh await-state <sid> <root>
    ```
  The `await-state` + `cursor-hash` verbs are the wake routine's inputs (§12): `cursor-hash` returns a
  bare 64-hex rotation-invariant digest of the current-gen `[mission]` state stream (changes on ANY
  append), or `corrupt` on a failed read. It is the wake routine`s in-turn CONSISTENCY check — NOT the
  dedup for queued wakes (the tick-lock + read-current-state is that; §12 intro). Two wakes advancing
  exactly once is the LAYERED guard, not the cursor alone.
- **DECISION line** (the durable human-decision OUTCOME — the close-ordering keystone; written via the
  `log` verb, NOT a new verb):
  - entry: `[mission] DECISION op=<seq>-<slug> outcome=<approve|deny>` — `op` is the pd's UNIQUE
    `<seq>-<slug>` (the echoed `pd:` id with the `pd:` prefix removed), matching the human barrier's `op`.
  - idtag: `pd-<seq>-decision-<slug>` (gen-prefixed automatically; the `pd-` decision namespace, distinct
    from the `m<part>-` round namespace and from the `pd:<seq>-<slug>` PENDING-DECISION line id). ONE
    DECISION per op — a re-log of the SAME op+outcome is an idempotent no-op; the validator pins the idtag
    to `(g<G>-)?pd-<seq>-decision-<slug>` and checks the idtag's `op` equals the entry's `op`.
  - **M5 — the DECISION is IMMUTABLE once recorded.** The idtag `pd-<seq>-decision-<slug>` deliberately
    OMITS the outcome, so a correction attempt (an approve after a deny, or vice-versa, for the same op)
    re-uses the SAME idtag with DIFFERENT content and surfaces a LOUD `COLLISION` — never a silent flip. To
    change a recorded decision you open a FRESH `pending-stop` (a new seq); you cannot overwrite the old one.
  - **Close ordering (lib-ENFORCED):** the `await` verb REFUSES a human `got=1` close unless a same-op
    DECISION line — double-anchored (idtag `pd-<seq>-decision-` column + a body fully matching
    `outcome=(approve|deny)$`, so a torn append never counts) — exists AND appears AFTER the barrier's
    `got=0` opener in the active-gen stream, so the outcome is ALWAYS durable-and-current BEFORE the barrier
    reads resolved (a DECISION preplanted before the opener cannot authorize the close). **C9 — the READER
    (`await-state`, the verdict the wake consumes) ALSO enforces DECISION-first: a human barrier reads
    resolved ONLY IF its got meets need AND a matching post-opener DECISION exists, so a forged `got=1`
    without a DECISION stays LIVE.** The consume is DECISION -> gated action -> `await … got=1` -> `resolve`,
    ALL on the SAME wake (C2 — never close then defer the action; §8 D3 row, §12.1/§12.3).
    Write it with the ACTUAL outcome:
    ```bash
    bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] DECISION op=<seq>-<slug> outcome=<approve|deny>" "pd-<seq>-decision-<slug>"
    ```

Example round line:
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] part=2 name=auth phase=review round=3 dry=1 findings=2" "m2-review-r3-d1"
```

Other zones: `note` = forced research assumptions + verbose round findings (DURABLE NOTES);
`challenge` = PLAN divergence (loud; never silently edit PLAN); `pending <slug> "<q>"` = the batched
human-decision queue (**NON-BLOCKING** — an away-policy question the run proceeds past) — the verb MINTS
a monotonic `pd:<seq>-<slug>` line (`- [pd:<seq>-<slug>] <q>`; seq is machine-assigned + never reused,
e.g. `pd:1-approve`) and ECHOES the id.
**`pending-stop <slug> <part> <round> <attempt> <phase> <q>` = the BLOCKING mandatory-stop opener**: it
ATOMICALLY opens the human `AWAIT kind=human got=0` STOP barrier AND mints the pd in ONE call (no
separate `await` open — do NOT hand-open a second barrier), then ECHOES `id=pd:<seq>-<slug>` on stdout.
CAPTURE that id; the barrier's `op` field is that id with the `pd:` prefix removed (`<seq>-<slug>`), and
you reuse the FULL id for the eventual `resolve`. Choose by whether the run must PARK: `pending` for an
away-policy question it proceeds past; `pending-stop` for a decision it must stop on (credential /
destructive / external-side-effect — §9/§10/§12.3).
`resolve <full pd-id>` drains a pending — it accepts BOTH the echoed `pd:<seq>-<slug>` and the bare
`<seq>-<slug>` form (the leading `pd:` is stripped); `rebaseline` is the ONLY path that rewrites PLAN.

**Per-shape grammar (Task 4 — `mission-write.sh log` VALIDATES every shape; the validator in the
script is the authoritative source, this table is its documentation).** A malformed shape or an
unknown `[mission]` leading token is REFUSED (`rc=1 REFUSED …`) so the malformed-shape hole is closed;
the idtag's `part`/`round`/`phase` must equal the entry's where both carry them:

| shape (leading token after `[mission] `) | entry grammar | idtag grammar |
|---|---|---|
| round (`part=`) | `part=N name=<slug> phase=(research\|plan\|implement\|review\|fix) round=K dry=[0-2]( findings=C)?` | `[g<G>-]m<N>-<phase>-r<K>-d<D>` |
| `VOID` | `VOID part=N phase=review round=K reason=<slug>` | `[g<G>-]m<N>-void-r<K>-<runid6>h(<sha8>\|nofile)` |
| `FAIL` | `FAIL part=N phase=<p> reason=<slug> attempt=A` (phase incl. `retire`) | `[g<G>-]m<N>-fail-<reason>-<A>` or `[g<G>-]m<N>-fail-panel3x-r<K>` |
| `live-verify` | `live-verify part=N round=K status=(ok evidence=<tok>\|n/a reason=<slug>)` | `[g<G>-]m<N>-live-verify-r<K>` (K == entry round — a post-fix re-verify at a new round NEVER collides) |
| `PART-START` | `PART-START part=N name=<slug>` (name REQUIRED) | `[g<G>-]m<N>-part-start` |
| `PART-DONE` | `PART-DONE part=N (converged)` | `[g<G>-]m<N>-part-done` |
| `PART-RETIRED` | `PART-RETIRED part=N` | `[g<G>-]m<N>-part-retired` |
| `test-trust` | `test-trust part=N=(ok\|added\|n/a)` (legacy glued form) | `[g<G>-]m<N>-test-trust` |
| `criticer` | `criticer part=N findings=C <bounded headline>` | `[g<G>-]m<N>-criticer-r<K>` |
| `MISSION-CLEARED` | `MISSION-CLEARED status=(achieved\|could-not\|cleared) reason=<slug>` | EMPTY (always-append) |
| `MISSION-REBASELINED` | `MISSION-REBASELINED status=active gen=<G> …` (lib-written; `gen=` is the boundary↔marker cross-check anchor) | EMPTY |
| `AWAIT` | `AWAIT part=N phase=<p> round=K kind=(job\|human) op=<slug> attempt=A need=<mask> got=<mask>` (written via the `await` verb, not `log`) | `[g<G>-]m<N>-await-<op>-r<K>-a<A>-g<GOT>` |
| `DECISION` | `DECISION op=<seq>-<slug> outcome=(approve\|deny)` (the durable human-decision outcome; a human `got=1` close is REFUSED by the `await` verb until this exists — idtag `op` must equal entry `op`) | `[g<G>-]pd-<seq>-decision-<slug>` |

**`MISSION-START` / `WORK-START` are LIB-ONLY emissions** — mission_create + the timing verbs append
them via the lib directly; they are **NEVER routed through the `log` verb** (the validator REFUSES an
external `log … "[mission] MISSION-START …"` as an unknown shape). Do not log them by hand.

**Generation-scoped idtags (Task 4).** The marker carries `gen=` (minted `1` at create, BUMPED at
rebaseline — the generation slice boundary). idtags are gen-scoped: **gen-1 idtags stay byte-identical
(unprefixed)**; a **gen≥2** idtag is auto-prefixed `g<G>-…` by the lib (you pass the bare `m<N>-…`
idtag — do NOT prefix it yourself; a WRONG `g<X>-` prefix is REFUSED `rc=5`). EMPTY idtags are exempt.
Dedup is archive-inclusive within the active generation, and the PART-DONE precondition / VOID count /
FAIL tally read only the CURRENT generation (the gen-sliced stream, after the latest gen-matching
`MISSION-REBASELINED` boundary) — so a prior generation's evidence never satisfies this generation's
convergence.

---

## 8. /pre-compact interleaving + resume rule

Invoke `/pre-compact` at natural seams or whenever context warrants — freely. Invoke the Skill tool
with `skill: pre-compact`. Continue once it returns.

**Resume-read idiom (the SINGLE canonical way to recover state from the LOG — used by §2 status, §5,
§9).** Do **NOT** `tail -n 40` the live log: with >40 trailing lines, or after a rotation,
`tail` MISSES the last round/lifecycle line. Do **NOT** read only the newest archive either:
`_mission_log_rotate` archives the OLDEST half on EACH fire, so after ≥2 rotations a durable line
(MISSION-CLEARED, PART-DONE, test-trust, a FAIL tally line) can sit in an OLDER archive — reading just
`ls -t … | head -1` would MISS it → false reactivation / repeated work / 5-FAIL under-count. Instead
`grep '[mission] '` over **ALL archives concatenated oldest→newest THEN the live log**, so no rotated
line is ever outside the read window:
```bash
live_log="$root/MISSION.$sid.log"
# Concatenate ALL archives in FILENAME-timestamp (chronological) order, THEN the live log.
# SET-e SAFE on ZERO archives: a fresh mission has NO archives, so an unmatched glob would expand
# to the literal pattern and an `ls <literal>` would exit nonzero — under `set -e -o pipefail` that
# would ABORT the whole pipeline BEFORE `cat "$live_log"`, losing all live state. So iterate the
# globs with a `for` + `[ -e ] || continue` guard: an unmatched glob yields its literal pattern,
# `[ -e ]` is false for the literal, we `continue` — NO failing command ever runs on no-match, and
# the live log is ALWAYS read below regardless of archive count.
# SPACE-SAFE: the canonical root can contain spaces (e.g. ".../untitled folder/skills"), so every
# path stays quoted ("$a") and is piped one-per-line into `read -r` — never word-split. Match ONLY
# the FINAL extensions (.gz / .txt) so an in-flight rotation temp (e.g. a partial .tmp) is never read.
# The timestamp embedded in each archive name sorts LEXICALLY = CHRONOLOGICALLY (more reliable than
# mtime, which a touch/restore can perturb), so `sort` gives true oldest→newest order:
{
  for a in "$root"/.mission-backups/MISSION."$sid".log.*.gz \
           "$root"/.mission-backups/MISSION."$sid".log.*.txt; do
    [ -e "$a" ] || continue          # unmatched glob -> literal -> [ -e ] false -> skip (no failing cmd)
    printf '%s\n' "$a"
  done | sort | while IFS= read -r a; do
    case "$a" in *.gz) gzip -dc "$a" 2>/dev/null;; *) cat "$a" 2>/dev/null;; esac
  done
  cat "$live_log" 2>/dev/null          # ALWAYS read, even with zero archives
} | grep -F '[mission] ' > /tmp/mission-resume.$$ 2>/dev/null || true
# `|| true` above: a fresh/empty log with ZERO `[mission]` lines makes this filter `grep` exit 1.
# Under `set -e -o pipefail` that would ABORT before any state logic runs — but "no `[mission]`
# lines yet" is a VALID ACTIVE state (e.g. empty mission_state + a live MISSION-MODE PLAN ⇒ ACTIVE
# per the §8 active-iff rule), NOT an error. So this no-match — and every derivation no-match below —
# is a normal empty value, never a failure. The capture file may be empty; that is fine.

# Derive the CURRENT part N first — convergence reads MUST be scoped to it (a prior part's final
# dry=2 review line would otherwise bleed into part N+1's convergence math).
# R4 (log-injection defense, S1) — the capture file holds `<idtag>\t<body>` lines, so EVERY control
# derivation is DOUBLE-ANCHORED via `awk -F'\t'`: it keys on BOTH the idtag COLUMN ($1, the exact
# shape mission-write.sh mints and its validator enforces) AND the body prefix ($2). A criticer/note
# free-text line whose BODY merely EMBEDS `[mission] MISSION-CLEARED` (or VOID / PART-DONE) carries a
# NON-matching idtag column, so it can no longer forge control state (a silent HALT, a false
# convergence, or a skipped part). `|| true`: awk exits 0 even on no-match, but the `|| true` is kept
# so an expected empty derivation stays a VALID early state, never a `set -e -o pipefail` abort.
cur_part=$(awk -F'\t' '$1 ~ /^(g[0-9]+-)?m[0-9]+-part-(start|done)$/ && $2 ~ /^\[mission\] (PART-START|PART-DONE) part=[0-9]+/' /tmp/mission-resume.$$ \
            | tail -1 | sed -n 's/.*part=\([0-9][0-9]*\).*/\1/p' || true)
[ -z "$cur_part" ] && cur_part=1   # no part-lifecycle yet ⇒ part 1 (empty = valid, not an error)

# state gate (active-iff) — GLOBAL, keys ONLY on CLEARED/REBASELINED. Both are minted with an EMPTY
# idtag column (the validator REFUSES a non-empty one), so anchor on $1=="" — a note line (which
# always carries a real idtag) that embeds the text can NEVER forge INACTIVE. EMPTY mission_state is
# a VALID state (never cleared/rebaselined) ⇒ ACTIVE with a live PLAN (§8). R8r6-G1 — FULL-GRAMMAR
# anchor (not a prefix), byte-mirroring the lib readers (mission_lifecycle_state / mission_await_state /
# the gen-boundary readers): require the WHOLE writer grammar for BOTH forms — CLEARED
# `status=(achieved|could-not|cleared) reason=<slug>$` and the REBASELINED boundary END-ANCHORED to the
# writer's ` (...)` suffix (`status=active gen=<N> \([^\t]*\)$`).
# A PREFIX match let a TORN/forged lifecycle line (missing/mangled tail) be picked and flip the mission to
# cleared/active, bypassing an open human STOP on resume; a torn line is now IGNORED so the last VALID
# lifecycle line wins (fail-closed). SHARED INVARIANT: keep this uniform with the four lib consumers:
mission_state=$(awk -F'\t' '$1=="" && ( $2 ~ /^\[mission\] MISSION-CLEARED status=(achieved|could-not|cleared) reason=[a-z0-9-]*$/ || $2 ~ /^\[mission\] MISSION-REBASELINED status=active gen=[0-9]+ \([^\t]*\)$/ )' /tmp/mission-resume.$$ | tail -1 || true)
# convergence — PART-SCOPED to N: the last phase=review round (idtag m<N>-review-r<K>-d<d>) OR a VOID
# (idtag m<N>-void-r...) for this part. VOID MUST be in this read (the table keys on "latest line for
# round K is VOID"). Empty = no review round banked yet for part N (a valid early state):
last_review=$(awk -F'\t' -v p="$cur_part" '($1 ~ /^(g[0-9]+-)?m[0-9]+-review-r[0-9]+-d[0-2]$/ && $2 ~ ("^\\[mission\\] part=" p " ") && $2 ~ /phase=review/) || ($1 ~ /^(g[0-9]+-)?m[0-9]+-void-r/ && $2 ~ ("^\\[mission\\] VOID part=" p " "))' \
                /tmp/mission-resume.$$ | tail -1 || true)
# round positioning — PART-SCOPED to N: last round-activity of ANY phase (any m<N>-<phase>-r<K>-d<d>)
# OR a VOID for this part:
last_round=$(awk -F'\t' -v p="$cur_part" '($1 ~ /^(g[0-9]+-)?m[0-9]+-(research|plan|implement|review|fix)-r[0-9]+-d[0-2]$/ && $2 ~ ("^\\[mission\\] part=" p " ")) || ($1 ~ /^(g[0-9]+-)?m[0-9]+-void-r/ && $2 ~ ("^\\[mission\\] VOID part=" p " "))' \
                /tmp/mission-resume.$$ | tail -1 || true)
# progress/lifecycle positioning — GLOBAL: PART-START|PART-DONE|PART-RETIRED (idtag m<N>-part-*),
# test-trust (idtag m<N>-test-trust), VOID (idtag m<N>-void-r...). Must include PART-RETIRED (so
# "PART-DONE present but PART-RETIRED absent ⇒ re-attempt retirement" is decidable) + VOID:
last_progress=$(awk -F'\t' '($1 ~ /^(g[0-9]+-)?m[0-9]+-part-(start|done|retired)$/ && $2 ~ /^\[mission\] (PART-START|PART-DONE|PART-RETIRED) part=/) || ($1 ~ /^(g[0-9]+-)?m[0-9]+-test-trust$/ && $2 ~ /^\[mission\] /) || ($1 ~ /^(g[0-9]+-)?m[0-9]+-void-r/ && $2 ~ /^\[mission\] VOID part=/)' \
                /tmp/mission-resume.$$ | tail -1 || true)
# per-op human-decision outcome (D15 — the CONSUME cross-check): computed WHEN a human AWAIT is live,
# keyed on THAT barrier's op (from the await-state token, e.g. op=3-approve). DOUBLE-ANCHORED — the idtag
# column must be EXACTLY (g<G>-)?pd-<seq>-decision-<slug> AND the body must be
# `[mission] DECISION op=<seq>-<slug> outcome=(approve|deny)` — so a free-text line that merely embeds the
# text (carrying a non-matching idtag) can NEVER forge an outcome. newest-wins:
op="<the await-state token's op, e.g. 3-approve>"; seq="${op%%-*}"; slug="${op#*-}"; dtag="pd-${seq}-decision-${slug}"
# R8r6-W1 (the FULL C9 resolved-predicate at the consumer) — last_decision counts a DECISION as ANSWERED
# only if the WHOLE reader resolved-predicate holds, byte-mirroring mission_await_state (:2277): (1) it was
# recorded AFTER this barrier's got=0 opener (dnr>opnr ⇔ decnr>openernr — E1); (2) the op has NO
# conflicting-outcome DECISION (a same-op set carrying BOTH approve AND deny ⇒ CORRUPTION ⇒ NO answer, treat
# unanswered/STOP — E3: a forged approve appended after a durable deny must NOT be consumed); and (3) it is
# BEFORE any post-opener got=1 close (dnr<g1nr ⇔ decnr<maxnr — D3: an out-of-order got=1-before-DECISION close
# is untrusted). PRE-opener / conflicting / post-close DECISIONs are all fail-closed to EMPTY so the WAKE
# re-confronts the STOP instead of executing a stale/forged/corrupt outcome (the consumer bypass). SHARED
# INVARIANT: this predicate is byte-aligned with the reader keystone + the writer close-gate + the highwater —
# keep all four in lockstep.
last_decision=$(awk -F'\t' -v t="$dtag" -v op="$op" '
  function fval(s,k,   p,i,r,a){ p=k"="; i=index(s,p); if(i==0) return ""; r=substr(s,i+length(p)); split(r,a," "); return a[1] }
  # newest got=0 OPENER NR + newest post-need got=1 close NR for this op (double-anchored: AWAIT idtag + body)
  ($1 ~ /^(g[0-9]+-)?m[0-9]+-await-/) && ($2 ~ /^\[mission\] AWAIT /) {
    if (fval($2,"op")==op) { g=fval($2,"got")+0
      if (g==0 && NR>opnr) opnr=NR
      if (g>=1 && NR>g1nr) g1nr=NR } }   # newest got>=1 line (the human need=1 close) for this op
  # newest DECISION for this op (double-anchored idtag<->body; a mismatched-idtag/free-text line cannot match).
  # Track outcome CONFLICT: a same-op DECISION set with two DIFFERENT outcomes is corruption (E3).
  (($1==t) || ($1 ~ ("^g[0-9]+-" t "$"))) && ($2 ~ ("^\\[mission\\] DECISION op=" op " outcome=(approve|deny)$")) {
    o=fval($2,"outcome"); if (dseen && dprev!=o) conflict=1; dprev=o; dseen=1; dnr=NR; dline=$0 }
  # ANSWERED iff the full reader predicate holds: after-opener AND no-conflict AND before any post-opener got=1
  # (g1nr<=opnr ⇒ no post-opener close yet ⇒ before-got=1 trivially holds; else require dnr<g1nr — mirror C9/D3/E3)
  END { if (dnr>0 && opnr>0 && dnr>opnr && !conflict && (g1nr<=opnr || dnr<g1nr)) print dline }
' /tmp/mission-resume.$$ || true)
# EMPTY  ⇒ this op is UNANSWERED (stop for a real user; an ORPHAN if the `- [pd:<op>]` PENDING line is
#          ALSO absent — a prior-crash artifact. R8r3-R7/FIX-B: you CANNOT silently re-state it — a re-
#          `pending-stop` for that op FAILS CLOSED rc=14 (the lost question is unverifiable). R8r6-E10b
#          recovery = the C7 safe-ABORT deny of that op (the ORPHAN row below): the lost-question orphan has
#          NO recoverable human answer (the question died with the pd line) and CANNOT be re-presented, so the
#          ONLY safe outcome is to write `outcome=deny` (ABORT the pending action), close the barrier, then —
#          if a decision is genuinely still needed — open a FRESH pending-stop under a DIFFERENT slug; do NOT
#          proceed. NEVER fabricate an `approve` for a question you can no longer read).
# NON-EMPTY ⇒ ANSWERED ⇒ CONSUME (parse outcome=approve|deny) per the human-AWAIT rows below.
```
**Every grep above whose no-match is an expected/valid outcome appends `|| true`** so that under
`set -e -o pipefail` an empty capture is a NORMAL value (e.g. empty `mission_state` + a live
`MISSION MODE:` PLAN ⇒ ACTIVE; empty `cur_part` ⇒ part 1; empty `last_review` ⇒ no review round
banked yet), never a shell abort. The `|| true` makes the pipeline succeed; the EMPTY string is then
interpreted by the active-iff rule and the decision table as the corresponding valid early state.
(Concatenating archives oldest→newest before the live log preserves chronological order so the final
`tail -1` of any filtered grep picks the genuinely-latest line. The two `.gz`/`.txt` globs cover both
the gzip archive and the no-gzip fallback while excluding any in-flight rotation temp. The
`for … [ -e ] || continue` guard makes this set-e-safe with ZERO archives — an unmatched glob is
skipped without a failing command — so the live log is ALWAYS read even on a fresh mission with no
archives. This is the ONE canonical definition; §2/§5/§9 reference it, never re-spell it.)
The four greps are deliberately distinct: `mission_state` is the **GLOBAL active-iff state gate** (keys
ONLY on CLEARED/REBASELINED); `last_review` drives **convergence** for the CURRENT part (the `2 − dry`
math, part-scoped, VOID-aware); `last_round` (part-scoped, VOID-aware) and `last_progress` (global
lifecycle) are for **resume positioning** only. Never let a transient progress line gate active-iff.

**After `/pre-compact` returns** (or after any compaction), re-derive your position from that
recovered record and continue the **EXACT** `(part, phase, round, dry)`. Read `last_round` for
*positioning* (which part/phase you were in), but compute convergence (`2 − dry`) **ONLY** from
`last_review` (the dedicated part-scoped `phase=review`-or-`VOID` grep) — never from a
`phase=fix`/`plan`/`implement`/`research` line, whose `dry=` is not the convergence count (a non-review
phase line must not drive the `2 − D` math).
- Read `last_review` (the latest part-scoped `phase=review` round line OR a `VOID` for the current
  part): if it is a `phase=review findings=0` line you need `2 − dry` more dry rounds; if it is a `VOID`
  for round K, re-run round K fresh (it banked nothing).
- **Round-ambiguity decision table (the SINGLE reconciliation of §5↔§8 — apply in order):**

  | Last round/progress line for the current part | Resume action |
  |---|---|
  | **`await kind=human ready=0` AND this turn is a REAL USER TURN answering it** (D3 — checked FIRST, before the STOP row below; only a genuine user turn, never a wake tick) | ENTER §12.1 and CONSUME it UNDER the tick lock (step 4), NOT before entering. **C2 — the gated action runs on THIS wake, together with the close; NEVER close (got=1 + resolve) while deferring the action (once got=1 resolves the barrier the C9 reader DROPS it, so a later wake finds nothing to consume — the action would never run).** Once the lock is held, in THIS EXACT order (D14/C2): **(a)** record the outcome — `log … "[mission] DECISION op=<seq>-<slug> outcome=<approve\|deny>" "pd-<seq>-decision-<slug>"` with the user's ACTUAL answer (the `<seq>-<slug>` is the `await-state` token's `op`; the barrier stays LIVE at `got=0` with the DECISION — the C9 reader keeps it live so this wake can consume it); **(b)** CONSUME — `approve` ⇒ perform the idempotent gated action; `deny` ⇒ ABORT it; **(c)** close the barrier — `mission-write.sh await … kind=human op=<same-op> part=<same> phase=<same> round=<same> attempt=<same> need=1 got=1` (the `await` verb REFUSES this got=1 close unless the same-op DECISION already exists — DECISION-first is LIB-ENFORCED and the READER also requires it; `got==need` IS the human barrier's resolution, C6; reuse the EXACT fields from the token, D6); **(d)** `resolve <full pd:id>` draining the pending. Order DECISION → action → got=1 → resolve (D14/R7-3): a crash mid-consume leaves a durable DECISION + a LIVE barrier, so the next wake re-CONSUMES (idempotent) — NEVER a removed pd + a ready=0 park with no recorded outcome. **This whole CONSUME IS the wake's ONE transition (R7-11/R6):** go to step 7 and RESCHEDULE — do NOT drive a further transition this turn. Consuming under the lock also stops a queued wake from observing the resolution before this turn holds the lock (R6 — no double-drive). |
  | **`await kind=human ready=0`** on a WAKE tick (AWAIT ROWS FIRST — read via `await-state`, which emits `ready=<0\|1>`; branch on `last_decision` for this barrier's op, derived above) | **(i) `last_decision` is NON-EMPTY (the full resolved-predicate holds — a raw same-op `[mission] DECISION` line alone is NOT enough) ⇒ ANSWERED ⇒ CONSUME it on THIS wake** (a prior turn recorded the outcome but may have crashed before consuming — the C9 reader keeps the `got=0`-with-a-DECISION barrier LIVE for exactly this): `approve` ⇒ perform the idempotent gated action, `deny` ⇒ ABORT it, THEN complete the close (`await … got=1` → `resolve <full pd:id>`, each a no-op if already done). The action runs on THIS wake WITH the close (C2), never split. **NEVER re-ask** — re-issuing `pending-stop` collides on the DECISION idtag and would silently keep the old outcome. **(ii) `last_decision` is EMPTY (UNANSWERED — including a raw DECISION that fails the resolved-predicate: pre-opener, conflicting, or post-close)** ⇒ **STOP the scheduled continuation** and wait for a real user turn (do NOT reschedule, do NOT auto-advance) — the only re-surface case. **(iii) ORPHAN** (got=0, no `- [pd:<op>]` PENDING line AND no DECISION — a prior-crash artifact) ⇒ SURFACE "approval pending but the question text was lost to a prior crash", do NOT proceed. **C7 — the WORKING recovery sequence** (do NOT re-state via `pending-stop`: it FAILS CLOSED rc=14, the lost question is unverifiable): **(1)** write a DECISION for the orphan op = `deny` — `log … "[mission] DECISION op=<orphan-op> outcome=deny" "pd-<seq>-decision-<slug>"`. This is a safe-ABORT, NOT a reconstructed human choice: the lost-question orphan has NO recoverable human answer (the question text died with the pd line), so the ONLY safe outcome is to ABORT the pending action — `deny`. NEVER fabricate an `approve` for a question you can no longer read; **(2)** close the barrier — `await … kind=human op=<orphan-op> … need=1 got=1` (the DECISION now authorizes it; the barrier clears); **(3)** `resolve <full pd:id>` is a MOOT no-op (the pd line is already gone — it returns `already resolved` / `never existed`, harmless). The barrier is now closed with a recorded outcome, no stall loop. If a decision is still genuinely needed, open a FRESH `pending-stop` under a DIFFERENT slug (a new seq). |
  | **`await kind=job ready=0` and a tracked `run_in_background` job is still pending** | collect nothing yet, do not replay a lane — the job's completion is the FAST wake. BUT this turn STILL schedules a fallback heartbeat (§12.1 step 7): a lost completion wake must self-heal — a scheduled wake is the ONLY continuation owner (D1). |
  | **`await kind=job ready=0` and NO tracked job is pending** (the lost-wake safety net) | replay ONLY the missing lane (its `attempt`, its round — the token carries `attempt=A`) and set its got bit on return; OR, if the lane has genuinely timed out, record a timeout/`FAIL` and open `attempt` A+1. Never re-run an already-persisted lane. |
  | **`await kind=job ready=1`** (join-ready — `(got&need)==need`) | reconcile the persisted lane results and bank the single normal successor (the `phase=review … findings=<COUNT>` or VOID line for this round), which SUPERSEDES the AWAIT, then proceed. |
  | **current part's latest progress line is `PART-DONE` or `PART-RETIRED`** (HIGHEST PRIORITY — both are in `last_progress`) | the part is **COMPLETE** → advance to the next part (first re-attempt retirement if `PART-DONE` present but `PART-RETIRED` absent, per the PART-DONE rule below; then await/emit the next `PART-START`). Do **NOT** consult `last_round`/`last_review` for a completed part — a stale prior `phase=review dry=2` line must NOT re-enter already-converged review. |
  | **current part's latest progress line is `PART-START` and NO phase round has been logged yet** (the only line `last_round` carries for this part is the `PART-START` line itself — it has NO `phase=<…> round=<…>` token — and `last_review` is empty: no `phase=` round and no `VOID` banked for this part) | the part has been STARTED but no phase round exists → **BEGIN the part at its first phase, `research`**, then proceed through the part's phase sequence (research → plan → implement → review/fix per Section 5). This is the fresh-part entry state; do NOT consult `last_review` (no review round banked). |
  | `phase=fix` (a fix was in flight) | FINISH the in-flight fix to completion against the working tree, THEN re-run the barrier as the NEXT round K+1. Do not assume the fix finished. |
  | `phase=review` with `findings>0` (ACTIONABLE — `dry` was NOT advanced) | resume into the **FIX of the SAME round K** → log `phase=fix` round=K, apply fixes; do NOT start a fresh review round K+1. (`findings>0` ⇒ this round demands a fix before any new review.) |
  | `phase=review` with `findings=0` (dry-advancing, `dry` already incremented on the line) | start the NEXT FRESH review round K+1 per the `2 − dry` rule. |
  | a `VOID … round=K` is the latest line for round K | re-run round K FRESH (never count it). |
  | last round line is a non-review/non-fix phase (`phase=research` \| `phase=plan` \| `phase=implement`) | CONTINUE that phase's work for the current part to completion, THEN proceed to the review barrier (Section 5). Resume the phase you were in; do not skip ahead and do not consult `last_review` (no review round was banked yet). |

  This table is **TOTAL and mutually-exclusive** over completed-part state (`PART-DONE`/`PART-RETIRED`),
  the fresh-part `PART-START`-with-no-round entry state, and all schema phases (`research`/`plan`/
  `implement`/`review`/`fix`): completed-part progress takes highest precedence over any stale round
  line; the `PART-START`-no-round row covers a part that has been started but has no banked round yet
  (begin at `research`); the round-line rows cover `fix` and the two `review` substates and `VOID`; and
  the non-review/non-fix catch-all covers the remaining `research`/`plan`/`implement` phases once a round
  line for the part exists — every recoverable state maps to exactly one row.

  **Never re-run an idtag round you already banked** (a banked `findings=0` review or a completed fix
  is a no-op that wastes a compaction). `findings=<COUNT>` on the round line is the cross-check that
  disambiguates the two `phase=review` rows above: `findings=0` ⇒ dry-advancing (next fresh round);
  `findings>0` ⇒ actionable (must reach `phase=fix` first) — so it is a live resume input, not dead
  weight.
- **PART-DONE / next-part:** if the last `[mission]` line FOR THE CURRENT PART is `PART-DONE`, the part
  converged — do NOT re-resume it. **First check retirement:** if a `PART-DONE part=<N>` is present in
  the recovered set but no `PART-RETIRED part=<N>` is (both are in the `last_progress` token set, so
  scan the filtered `/tmp/mission-resume.$$` for each), re-attempt the idempotent plan retirement
  (Section 5) BEFORE advancing. Then advance to the next part: find the latest `PART-START part=<M>`
  (if present, resume part M); if no later `PART-START` exists yet, log `PART-START part=<N+1>`
  (Section 5/7) and begin its Phase 1. **Never restart converged work** and never re-run review rounds
  you already banked.
- A `VOID part=<N> … round=<K>` line means round K did not count → re-run round K fresh (Section 6/7).
- `test-trust part=<N>` recovered = honored; absent = unresolved → re-assess before implementing (§5/§9).

**Mode is ACTIVE iff** PLAN line-1 is a `MISSION MODE:` token **AND** the active-iff state gate says so.
The state gate keys **ONLY** on `mission_state` (the dedicated `MISSION-(CLEARED|REBASELINED)` grep
above) — NEVER on a transient progress line (PART-START/PART-DONE/test-trust/VOID can NOT gate
active-iff; lumping them in would let a transient line resurrect a cleared mission or leave an
undefined case):
- `mission_state` latest is `MISSION-CLEARED` → **INACTIVE** (the mission is over; resume normally, not
  in mission mode).
- `mission_state` latest is `MISSION-REBASELINED status=active` → **ACTIVE** (a sid re-seeded via
  `rebaseline` after a prior clear is reactivated; the rebaseline line is the latest CLEARED/REBASELINED
  token and overrides the stale earlier CLEARED).
- `mission_state` is EMPTY (no CLEARED/REBASELINED ever) but PLAN line-1 IS a `MISSION MODE:` token and
  a live PLAN exists → **ACTIVE** (a normal in-flight mission that has never been cleared).
Progress lines (`last_progress`) are read SEPARATELY, for resume positioning only (which part/phase to
re-enter), and never change the active/inactive decision.

---

## 9. PLAN-challenge · batched questions · full agency · test-trustworthiness

- **PLAN challenges:** never silently edit PLAN. A divergence goes to the append-only PLAN CHALLENGES
  lane via `challenge` (loud, surfaced in the banner). The human ratifies; if away, proceed with a
  loudly-logged deviation.
- **Batched questions — DEFAULT TO AWAY in autonomous mission mode.** `AskUserQuestion` blocks
  indefinitely, and "is the user present" is **not decidable mid-run**. So when away (the default in
  an autonomous run): log the assumption + proceed (loud deviation). Only surface ONE consolidated
  `AskUserQuestion` round (draining PENDING DECISIONS) when the run is **explicitly interactive** /
  there is a recent user turn. Never block an unattended run on a modal. (When you do ask, include the
  current context-usage % in the question text, per global rules.)
- **Run-timing — points of contact (advisory).** A "point of contact" is a surface where the run
  genuinely hands back to the user: (1) the batched `AskUserQuestion` round above, (2) the 5-FAIL
  STOP-LOUD (§10), (3) the corrupt-bridge STOP-LOUD (§10), and (4) the natural lifecycle close (§11).
  At each, just BEFORE surfacing, record the timing contact and show the elapsed line:
  ```bash
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh timing-contact <sid> <root> <ask|fail5|corrupt>
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"; set -- $(mission_timing_compute <sid> <root>)
  printf '⏱ stretch %s · active %s · wall %s · idle %s\n' "$(_mission_fmt_dur "$1")" "$(_mission_fmt_dur "$2")" "$(_mission_fmt_dur "$3")" "$(_mission_fmt_dur "$4")"
  ```
  **Render that `⏱` line directly into the AskUserQuestion question text and into the STOP-LOUD message
  body** — not only the banner. A **PLAN-divergence `challenge` is NOT a point of contact** (it proceeds
  autonomously when away) — do not emit a contact there. Timing is advisory: a failed emit never blocks
  or changes the lifecycle (at a corrupt-bridge contact the write itself may no-op — that's fine; the
  read-side `⏱` still renders, or shows `timing unavailable`).
- **Unattended blocking surfaces extend to `/implement`'s gates.** The away-default above applies to
  ANY surface that would block an unattended run — including `/implement`'s **dangerous-command
  Manual-Steps gate**. When away: do NOT block on that modal; log a `pending` PENDING-DECISION (the
  decision text + context-usage %) and proceed-or-stop per the away policy, exactly like a batched
  question. The decision stays in the queue for the next interactive turn.
- **Credential / external-side-effect / destructive guard (autonomous mode).** Full-agency,
  credential, external-side-effect, or destructive skills — e.g. `/load-creds`, anything that exfils
  secrets, mutates production, or performs irreversible external actions — require a **human decision in
  autonomous mode. Do NOT auto-run them.** These are BLOCKING: open the stop with a single
  `pending-stop` call (the atomic human-`AWAIT` opener — §10/§12.3). The question is untrusted content,
  so CAPTURE it into a variable first (a quoted `<<'EOF'` heredoc or a file), then pass it DOUBLE-quoted:
  `q=$(cat qfile); bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh pending-stop <sid> <root> <slug> <part> <round> <attempt> <phase> "$q"`
  — NEVER a `'<q>'` single-quoted literal (an embedded `'`, even a benign apostrophe, breaks out and
  executes) NOR a `"<raw text>"` double-quoted literal (an embedded `$(...)`/backtick executes); a
  captured `"$q"` is inert against both. Describe what wants to run and why, then PARK on the barrier until a real user turn closes
  it (DECISION → got=1 → resolve). These are the one class where "proceed loudly when away" does NOT apply
  — the human must ratify before such a skill runs; a plain NON-BLOCKING `pending` would NOT stop the loop.
- **Full agency (spine not cage).** The four-skill sequence is the backbone, not a fence. You are free
  to invoke ANY dotfiles skill whenever it helps — `/script` to prove load-bearing assumptions before
  building (encouraged), `/investigate`, `/document`, etc. (Credential/destructive skills
  like `/load-creds` are gated by the guard above — they need a human PENDING decision in autonomous
  mode.)
- **Test-trustworthiness** is both a plan-time precondition and a deliverable (see Section 5, Phase 2):
  no deleting or weakening tests to pass; meaningful coverage before "converged" means anything.

---

## 10. Guardrails — stop LOUD

**Every STOP-LOUD path below is a WAKE stop condition (§12.3): the wake RETURNS WITHOUT rescheduling** —
release the tick lock, surface, and stop. A STOP-LOUD must NEVER schedule the next self-wake (that would
loop a wedged mission forever). For a **mandatory human decision** (the §9 credential / destructive /
external-side-effect guard, or any genuinely blocking decision), the stop sequence is a SINGLE call:
`q=$(cat qfile); bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh pending-stop <sid> <root> <slug> <part> <round> <attempt> <phase> "$q"` (capture the untrusted
question into `"$q"` via a quoted heredoc/file and pass it double-quoted; a single-quoted literal breaks
on an apostrophe, a double-quoted raw literal executes `$(...)`; §7 rule) — it ATOMICALLY opens the FULL-FIELD human
`AWAIT kind=human op=<seq>-<slug> attempt=1 need=1 got=0` STOP barrier AND mints the pd in ONE lock, then
ECHOES `id=pd:<seq>-<slug>` (CAPTURE it — you need the FULL id for the eventual `resolve` and the
`<seq>-<slug>` for the DECISION `op`). Do NOT hand-open a second `await` barrier (the atomic verb already
opened it), and do NOT substitute plain `pending` here (plain `pending` is NON-BLOCKING and does not stop
the loop — §9). Then stop. The outstanding
`AWAIT kind=human` keeps the §8 rows parked until a real user turn CLOSES it in order — DECISION → `await
… got=1` → `resolve` (§8 D3 row / §12.3); the `await` verb REFUSES the got=1 close until the DECISION
exists (DECISION-first, lib-enforced).

- **5 FAILs for the SAME part+phase in the LOG** → **STOP LOUD.** Count from the durable record
  (the guard can't live in volatile context): the resume-read idiom (Section 8) recovers FAIL lines,
  and because each FAIL is attempt-scoped (`m<N>-fail-<reason>-<attempt>`, Section 7) the lib does NOT
  dedup them, so 5 distinct lines for the same `part=<N> phase=<P>` actually accumulate and the guard
  can fire. Tally `[mission] FAIL part=<N> phase=<P> …` lines per part+phase — **GEN-SLICED: count
  only lines after the latest gen-matching `MISSION-REBASELINED` boundary** (Section 7's gen rules;
  a prior generation's FAILs never trip this generation's guard); at 5, STOP LOUD — do not
  burn hours wrong.
- **`panel-unavailable-3x` (NAMED IMMEDIATE trigger)** → **STOP LOUD the moment it is logged** (the
  Section 5 void-count block emits it at exactly 3 consecutive VOIDs for one round). Do NOT wait for
  the 5-FAIL tally — during a permanent panel outage the same round can never advance, so no further
  FAILs would ever accrue and the run would loop forever. Surface to the user / away-policy
  checkpoint; do not re-run the panel again.
- **`void-count` returns `-1` (gen-boundary-mismatch / refused gen-sliced read)** → treat as the
  corrupt-bridge point of contact below: do NOT treat as count=0, do NOT advance the part; the
  write-path self-heal (or the user) must repair the boundary first.
- **A corrupt or unreadable bridge** → **STOP LOUD**, surface it to the user, point them at the
  `.mission-backups/` under the canonical root; do not silently proceed. This guard is WIRED to the
  status-line parse (Section 7): any `mission-write.sh` call returning `FAILED rc=2` (corrupt — the
  lib's `mission_verify` failed under the lock) triggers this STOP-LOUD immediately. (Also triggers
  if a direct `mission_verify` you run fails.)

---

## 11. Lifecycle — clear + status

**The wake self-terminates at the lifecycle close (§12.3).** Once the `MISSION-CLEARED` line is banked
(any `status=achieved|could-not|cleared`), the mission is INACTIVE per the §8 active-iff rule, and every
later wake — check active-iff `mission_state` on EVERY wake, BEFORE archive-close — self-terminates
(returns without rescheduling). The natural close is therefore the ONE §9 point-of-contact where the
self-wake loop stops on purpose: `timing-close` → `MISSION-CLEARED` → `archive-close` LAST → wake stops.

- **`/mission clear [reason]`** logs `[mission] MISSION-CLEARED status=cleared reason=<slug>` with an
  **EMPTY idtag** (lifecycle lines always append — a dedup-prone idtag would suppress a re-clear that
  follows a `rebaseline` and leave the mission spuriously active; §2) and ends the mission early
  (mirrors `/goal clear`). `achieved` / `could-not` are set only by the **explicit
  lifecycle close** at a mission's natural end — write the appropriate `status=` on the MISSION-CLEARED
  line — never by the bare `clear` verb. Parse the returned status line (Section 7).
- **Run-timing — lifecycle close (the ONE ledger write).** Immediately BEFORE writing the
  `MISSION-CLEARED status=<achieved|could-not|cleared>` line (whether from `clear` or the natural-end
  close), flush the final timing + lifetime-ledger record and surface the final elapsed line to the user:
  ```bash
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh timing-close <sid> <root> <achieved|could-not|cleared>
  . "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"; set -- $(mission_timing_compute <sid> <root>)
  printf '⏱ final — active %s · wall %s · idle %s (run /mission stats for lifetime totals)\n' "$(_mission_fmt_dur "$2")" "$(_mission_fmt_dur "$3")" "$(_mission_fmt_dur "$4")"
  ```
  This appends one rich record to `~/.claude/mission-metrics.jsonl` (the machine-wide lifetime ledger
  that `/mission stats` reads). Advisory — never blocks the close.
- **Archive — lifecycle close (the LAST step).** AFTER the entire timing block above AND after the
  `MISSION-CLEARED status=<achieved|could-not>` line is durably written, file the now-closed mission's
  files into `<root>/.mission-archive/<sid>/` so the root stays clean. This must be the FINAL close
  action — it moves the very log the timing block reads, so it runs strictly last:
  ```bash
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh archive-close <sid> <root>
  ```
  Advisory — the `archive-close` self-guard no-ops unless the mission is `cleared`, and a failed move
  never blocks the close. (A `/mission clear` already archives in §2; a double-fire is a harmless no-op.)
  Then **disarm the liveness guard** (§12.1 step 0) so a finished run stops being watched:
  ```bash
  rm -f "$HOME/.claude/progress/mission-liveness-<sid>.json"
  ```
  Advisory and idempotent — a missed disarm is self-correcting rather than harmful: the guard reads
  `mission_lifecycle_state`, sees `cleared`, and exits silent on every subsequent turn. Leaving the
  file behind therefore costs a stat and a state read, never a spurious block.
- **`/mission status`** (and blank) reads the LOG **directly** via the Section 8 resume-read idiom
  (grep over the full live log + ALL rotated archives oldest→newest), derives mode/part/phase/round/dry
  + pending, and prints — no mutation. Mode/`status=` come from the `mission_state` grep (the LATEST
  `MISSION-(CLEARED|REBASELINED)` line — Section 8 active-iff), NOT from a transient progress line.

---

## 12. The mission wake routine (self-wake — the continuation-owner mechanism)

This section is the operational body of the **CONTINUATION-OWNER INVARIANT** in the contract core: a
`/mission` turn NEVER yields naked. When a turn has work still owed and is not at a genuine human-handback
/ stop point (§9/§12.3), it **schedules its own next wake as its LAST continuation-deciding call (only the
tick-lock release may follow)** and then returns — ALWAYS,
even when a tracked `run_in_background` job is pending (D1: the completion is the fast wake, the scheduled
heartbeat is the backstop that self-heals a lost completion wake; a scheduled wake is the ONLY continuation
owner). **EVERY wake source funnels through the ONE routine below** — a tracked
background-job completion, a `ScheduleWakeup` tick, AND a post-compact resume — and each advances the
mission by **exactly ONE transition**. What makes 2-3 queued/racing wakes safe is a LAYERED guard, in
priority order: (1) the `mkdir` tick-lock SERIALIZES wakes — only the holder acts; a wake that finds the
lock fresh-held reschedules and returns without touching state, so overlapping wakes do not run
concurrently; (2) each wake re-reads CURRENT state (§8) and the AWAIT marker and picks the NEXT transition
off it, so a wake that runs AFTER the winner released the lock sees the advanced state and never repeats
the banked step; (3) the existing deterministic idtags make any accidental re-bank an idempotent no-op;
(4) the cursor-compare (step 5) catches state changing UNDER a holder mid-decision (e.g. a concurrent note
write) and re-enters. The cursor alone does NOT dedupe queued wakes (a wake that recomputes its baseline
after the winner's append would see it "unchanged") — the tick-lock + read-current-state is the real
serializer; the cursor is the in-turn consistency check on top.

### 12.1 The wake routine (run on every wake — idempotent)

Carry `sid`, `root`, and every absolute path in the tick prompt itself (§12.2) — a wake has NO
conversation memory; treat it as a COLD START and read ALL state from the log/bridge.

0. **ARM the liveness guard (belt-and-braces; `mission-write.sh` already arms on any bridge write, so
   this step is a redundancy, not the only path).** Arming ONLY here was a real coverage gap: a
   mission driven entirely by USER turns never runs a wake routine, so it never armed and the guard
   was inert for it — and the conversational-to-overnight handoff ("continue, I'm going to bed") is
   exactly that population. The writer now arms on `create`/`log`/`note`/`challenge`/`pending`, so any
   session doing mission work is covered whatever drove the turn. The `Stop` hook
   `scripts/hooks/mission-liveness.sh` catches a turn that ends with work owed and no `ScheduleWakeup`
   in it — the naked yield §12.5 describes — and blocks the stop so the run continues instead of
   freezing. **It is inert until armed, and it is armed per-session, ON PURPOSE:** an always-on
   version would fire on every turn end of every window on the machine, and because several windows
   routinely sit in the same repo it would drive a mission tick into a SIBLING window or into the
   user's own live conversation. Re-arming every wake is deliberate — it self-heals if the file is
   ever lost, and the write is idempotent:
   ```bash
   mkdir -p "$HOME/.claude/progress" 2>/dev/null
   printf '{"sid":"%s","root":"%s"}' "<sid>" "<root>" > "$HOME/.claude/progress/mission-liveness-<sid>.json"
   ```
   The guard reads `root` from THIS file (never from `cwd`, which is often a per-part worktree) and
   resolves the mission by `sid`, so it can never adopt another session's mission. Retire it at the
   natural close, beside `archive-close` (§11):
   `rm -f "$HOME/.claude/progress/mission-liveness-<sid>.json"`.
   Everything it decides is appended to `~/.claude/logs/mission-liveness.log`, so "ran and stayed
   silent" is distinguishable from "never ran".
1. **Acquire the tick lock (atomic, afk pattern).** The lock dir lives beside the mission file:
   `tick_dir="$root/.mission-backups/tick.$sid.lock"`.
   ```bash
   i_own_lock=0
   if mkdir "$tick_dir" 2>/dev/null; then i_own_lock=1   # acquired — you own this tick
   else
     # held: stat its mtime. FRESH (<15m) -> another turn owns it: reschedule 60s + RETURN, and do NOT
     #   touch the lock (you never acquired it). STALE (>15m) -> the owning tick crashed: rm -rf + retry
     #   the mkdir ONCE (set i_own_lock=1 only if the retry mkdir SUCCEEDS).
     # D5 — if the retry mkdir ALSO FAILS (another wake won the race in between), i_own_lock STAYS 0:
     #   reschedule 60s + RETURN. NEVER fall through into step 2+ with i_own_lock=0 (that is two owners
     #   driving the same tick). Only an acquired lock proceeds.
     # R4 — a non-owner reschedule (FRESH-held OR D5 retry-lost) holds NO lock, so it cannot write a
     #   lock-held fallback: if that ScheduleWakeup itself FAILS, retry ONCE, then STOP-LOUD (surface it).
     #   The lock-owner is presumably still driving its own wake, but a doubly-failed schedule is a real
     #   degradation that must never be a silent naked yield.
     # SLEEP-SKEW GRACE: if THIS wake is itself >10m later than its scheduled fire (laptop slept),
     #   give the held lock ONE more 60s grace wake before treating it as stale — a suspended owner's
     #   lock must not be cleared out from under it.
     :
   fi
   # HARD GUARD (pseudocode): if you did not acquire the lock, you have already rescheduled above —
   #   [ "$i_own_lock" = 1 ] || { <return from the wake now>; }   # NEVER run steps 2-7 without the lock
   ```
   D14 (ABA, bounded — NOT fully proof): the stale-clear+reacquire is not ABA-proof (two wakes can both
   judge the lock stale in the same window). The layered guard (cursor recompute at step 5 + the AWAIT
   marker + deterministic idtags) dedupes any double LOG transition (idtag-keyed appends are idempotent)
   and catches the common interleaving (whoever writes first moves the cursor; the other re-enters). It
   does NOT by itself prevent a double EXTERNAL dispatch (spawning a review panel, a worktree mutation) in
   the rare window where BOTH wakes recompute the cursor before EITHER writes — so before any non-idempotent
   dispatch, step 6 RE-READS `await-state` and skips the launch if that lane's bit is already set or a
   tracked job is pending, and every launched lane's usable result is persisted to DURABLE NOTES BEFORE
   its got bit is set, so a duplicate lane re-derives rather than corrupts. The re-read + the tick lock
   keep the window rare but do NOT fully close it: a run-id / lease that would make a duplicate EXTERNAL
   dispatch reliably detectable is NOT yet wired into the launch path — it is a documented deferred
   follow-up (do not claim it as present).
   **Release the lock on every exit path THAT ACQUIRED IT (`i_own_lock=1`)** — the stop conditions, the
   cursor-changed re-enter, and the normal end. A turn that found the lock FRESH-held (and rescheduled
   without acquiring) must **NOT** release it — deleting a lock you do not own hands two turns the same
   tick. Forgetting to release a lock you DO own blocks the mission for 15 minutes before it self-heals.
2. **Verify the bridge, then run the EXISTING §8 archive-inclusive resume-read** (pure/idempotent — the
   grep-over-ALL-archives-then-live-log idiom; NOT `tail`, NOT the newest archive only). Any
   `FAILED rc=2` / failed `mission_verify` → the §10 corrupt-bridge STOP-LOUD (do NOT reschedule).
3. **`cursor_before`** = the rotation-invariant digest of the current-gen `[mission]` state stream:
   ```bash
   cursor_before=$(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh cursor-hash "$sid" "$root")
   ```
   If it is the literal `corrupt` (a refused gen-boundary read — the rollover/corruption window) OR EMPTY
   (C1 — a missing sha tool / unreadable state also fails, and two empties would falsely compare equal),
   take the §10 corrupt-bridge STOP-LOUD: release the lock, do NOT reschedule, surface it. Neither
   `corrupt` nor empty is ever a valid cursor — never treat it as "unchanged".
4. **Apply the §8/§H decision table** (AWAIT rows FIRST, then the round-ambiguity grid) plus the
   `await-state` verb → select exactly **ONE** next transition. `await-state` returns bare `none`,
   `corrupt`, or `await kind=… op=… part=<N> round=<K> attempt=<A> phase=<P> need=<M> got=<G>
   ready=<0|1> started_at=<E>` (field order matches the lib's emit; `phase` is reused on the human close):
   ```bash
   aw=$(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh await-state "$sid" "$root")
   ```
   `corrupt` → §10 corrupt-bridge STOP-LOUD (release lock, do NOT reschedule).
   `await kind=human ready=0` → branch on `last_decision` for the op (§8, D15): **`last_decision` is
   NON-EMPTY** (the full resolved-predicate holds — a raw same-op `[mission] DECISION` line alone is NOT
   enough) ⇒ ANSWERED ⇒ CONSUME on THIS tick — `approve` ⇒ perform the idempotent gated
   action, `deny` ⇒ ABORT it, THEN finish the close (`await … got=1` → `resolve`, each a no-op if already
   done); the action runs WITH the close on THIS wake, never split (C2); NEVER re-ask. **EMPTY `last_decision`
   on a WAKE tick** (UNANSWERED, regardless of any raw DECISION line present) ⇒ STOP the scheduled continuation (a human hand-back is owed; an ORPHAN — no `pd:<op>` line
   either — ⇒ surface it + recover per §12.1 (iii) C7: `log` a DECISION `deny` for the orphan op → `await …
   got=1` close → `resolve` (moot); do NOT re-state via `pending-stop` (fails closed rc=14 — unverifiable);
   do NOT proceed). **On a REAL USER TURN answering it (D3):** CONSUME it HERE, UNDER this tick lock, in
   THIS order (D14/C2): (a) `log` the `[mission] DECISION op=<seq>-<slug> outcome=<approve|deny>` (idtag
   `pd-<seq>-decision-<slug>`) with the user's ACTUAL answer (the barrier stays LIVE at `got=0` with the
   DECISION — the C9 reader keeps it live so this same wake can consume it); (b) CONSUME — `approve` ⇒ run
   the idempotent gated action, `deny` ⇒ ABORT it; (c) append the SAME barrier with `got=1` (reuse the EXACT
   op/part/phase/round/attempt/need from the token, D6 — the `await` verb REFUSES got=1 until the same-op
   DECISION exists, DECISION-first lib-enforced AND reader-enforced); (d) `resolve` the pd whose UNIQUE
   `<seq>-<slug>` matches the token's `op`. **C2 — NEVER close (got=1 + resolve) while deferring the action
   to a later wake: once `got=1` resolves the barrier the C9 reader DROPS it, so a deferred wake finds
   nothing to consume and the approved action never runs.** Order DECISION → action → got=1 → resolve
   (D14/R7-3): a crash mid-consume leaves a durable DECISION + a LIVE barrier, so the next wake re-CONSUMES
   idempotently — NOT a removed pd + a ready=0 park with no recorded outcome. This whole CONSUME IS this
   wake's ONE transition (R7-11/R6): go straight to step 7 and RESCHEDULE — do NOT re-enter step 5 to drive
   a FURTHER transition this turn. Consuming under the lock (NOT before entering §12.1) stops a queued wake
   from racing the resolution (R6 — no double-drive).
   `await kind=job ready=0` + a tracked job pending → do NOT replay a lane this tick (the completion is
   the fast wake), but STILL fall through to step 7 and schedule a fallback heartbeat (D1).
   `await kind=job ready=0` + NO tracked job → replay ONLY the missing lane, but ONLY once the barrier has
   aged past a lane timeout (started_at older than ~the lane's max runtime); a cold tick cannot tell a
   still-running job from a lost wake, so a fresh barrier just reschedules and waits (D11). On a genuine
   timeout, record a timeout/`FAIL` and open attempt A+1 (its `attempt=A` is in the token). `await
   kind=job ready=1` → reconcile + bank the single successor.
5. **Immediately before dispatching/banking, RECOMPUTE the cursor.** If it changed, another wake already
   advanced the mission — DISCARD this decision, but do NOT yield: the mission still needs a continuation
   owner. Release the lock and **RE-ENTER the routine from step 1** (re-acquire, re-read the now-advanced
   state, pick the NEXT transition). This is a normal in-turn loop, not a return. BOUNDED (D7): keep a
   `reenter_count` for THIS wake (it resets per wake, NEVER per re-enter). Allow at most **2** re-enters;
   on the 3rd cursor-change (another wake is actively driving), skip banking and go straight to step 7 to
   schedule a short heartbeat, then RETURN — never a bare naked return. An EMPTY or `corrupt` cursor is a
   fail, never "unchanged":
   ```bash
   cursor_now=$(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh cursor-hash "$sid" "$root")
   # pseudocode — this block runs inside the wake routine, not a shell function:
   #   if [ -z "$cursor_now" ] || [ "$cursor_now" = corrupt ]; then release_lock; STOP-LOUD (§10); fi  # C1: empty is NOT "unchanged"
   #   if [ "$cursor_now" != "$cursor_before" ]; then reenter_count=$((reenter_count+1))
   #        if [ "$reenter_count" -le 2 ]; then release_lock; goto step 1;   # re-acquire in step 1
   #        else goto step 7 STILL HOLDING the lock (step 7 schedules the heartbeat + releases — do NOT
   #             release here, or the schedule-failure fallback write would be lock-free); fi
   #   fi
   ```
6. **Bank / dispatch the transition** using the EXISTING deterministic idtags (`ok` = appended or an
   idempotent no-op; `COLLISION` → re-read and reconcile, never assume the line banked). A bank/dispatch
   write that returns `FAILED` is load-bearing control state (§intro): retry, then §10 STOP-LOUD if it
   still fails — do NOT proceed to step 7 as if it banked.
7. **Schedule the next wake UNLESS a stop condition holds** (§12.3).
   **STEP 7 IS THE MANDATORY EXIT GATE: no path in this routine returns except through it.** Step 6 is
   the act that FEELS like completion, and step 7 is a separate later errand — which is exactly why it
   gets dropped, and a dropped step 7 silently freezes the mission forever (nothing retries it; see
   §12.5). Do not treat step 6's success as permission to end the turn. Several paths above reach step 7
   while deliberately skipping step 6 (the CONSUME path, the `await kind=job ready=0` heartbeat, the
   re-enter-exhausted path); that is intended — they still exit through here.
   D10 — ORDER matters: call
   `ScheduleWakeup` while STILL HOLDING the lock, then release only after you know the outcome (so a
   schedule failure`s durable fallback write is never done lock-free). Call it with:
   - `delaySeconds`: a **~60s floor** when a transition is actively in flight; a **longer fallback
     heartbeat** (up to the 3600s ceiling) while a tracked `run_in_background` job is pending — do NOT
     poll a 40-minute job every 60s; the completion wake is primary, the heartbeat is just the backstop
     if that wake is ever lost. The tool **clamps `delaySeconds` to [60, 3600]s**.
   - `prompt`: the SAME self-contained tick body (§12.2), verbatim.
   - `reason`: e.g. `"mission <sid> tick"`.
   - **On SUCCESS** → release the lock and **RETURN immediately** (nothing else this turn).
   - **On FAILURE** (C12/D10) → retry ONCE; if it still fails, do NOT yield naked: while STILL holding the
     lock, write the durable human-handback fallback (`pending-stop …` per §12.3 — the atomic barrier
     opener), THEN release the lock and STOP LOUD so the user sees it. A failed schedule is never a silent stop.

### 12.2 The self-contained tick prompt (cold-start-safe)

`ScheduleWakeup` only fires **while Claude Code is OPEN**; state survival across compaction/close is via
the on-disk log + this self-contained prompt, NOT via wake persistence — so the prompt must carry
everything a cold start needs and must re-derive ALL position from the §8 resume-read. Substitute these
FIVE absolute values — `<SID>` is the sanitized session id, `<ROOT>` the canonical mission root,
`<MFILE>` the mission artifact, `<PLAYBOOK>` this mission.md, `<MW>` the mission-write.sh CLI. R4 —
BEFORE substituting, verify NONE contains a newline OR any of `"` `` ` `` `$` `\`: the cold prompt embeds
`<ROOT>` inside a double-quoted `mkdir "<ROOT>/…"`, so an unescaped quote / `$()` / backtick would break
the quoting and inject shell expansion. If any value contains a newline or such a metacharacter the
substitution is malformed — abort and STOP-LOUD rather than emit a prompt an attacker path could inject
into. Pass this body verbatim as the `prompt`:

```
You are resuming an autonomous /mission tick for sid <SID> at root <ROOT>.
Files: mission artifact <MFILE> (4 zones: PLAN + DURABLE NOTES + PLAN CHALLENGES + PENDING DECISIONS; the LOG is the separate .log sidecar) | bridge CLI <MW> | full playbook <PLAYBOOK>.
You have NO memory of prior ticks — COLD START. Read ALL state from the log/bridge; carry nothing.
Run the §12.1 mission wake routine EXACTLY (use <MW> for every bridge verb: cursor-hash/await-state/log):
  1. mkdir "<ROOT>/.mission-backups/tick.<SID>.lock" (afk lock: fresh<15m -> reschedule 60s + return WITHOUT
     touching the lock; stale>15m -> clear+retry once; >10m-delayed wake -> one 60s sleep-skew grace).
     Track i_own_lock; release ONLY a lock you acquired, on every exit that acquired it.
  2. Verify the bridge + run the §8 archive-inclusive resume-read (corrupt -> §10 STOP-LOUD, no reschedule).
  3. cursor_before = <MW> cursor-hash (literal `corrupt` -> §10 STOP-LOUD, no reschedule).
  4. <MW> await-state + the §8/§H decision table (AWAIT rows FIRST) -> ONE transition. Token: none|corrupt|
     `await kind=<job|human> ... attempt=A need=M got=G ready=<0|1>`. corrupt -> §10 STOP-LOUD.
  5. Recompute cursor-hash; if changed, DISCARD + RE-ENTER at step 1 (never a bare return); if still
     churning after a couple re-reads, go to step 7 and schedule a short heartbeat.
  6. Bank/dispatch with the existing idtags (FAILED -> retry, then §10 STOP-LOUD; never proceed).
  7. If a §12.3 stop condition holds, release the lock and RETURN WITHOUT rescheduling. Else call
     ScheduleWakeup WHILE STILL HOLDING the lock (delaySeconds in [60,3600] — 60s floor / long heartbeat
     even while a tracked job is pending, prompt = THIS SAME body, reason); it is the LAST continuation-
     deciding call (only the tick-lock release may follow), and the lock release FOLLOWS its outcome. On SUCCESS release the lock + RETURN. On FAILURE retry once; if
     it still fails, write the pending-stop fallback (the atomic human-STOP opener) UNDER the lock, THEN release + STOP-LOUD;
     never yield naked. Then RETURN.
Read the PLAYBOOK <PLAYBOOK> (its CONTRACT CORE + §5/§8/§10/§11/§12) for full detail before acting.
```

### 12.3 Stop conditions (when a wake self-terminates — do NOT reschedule)

A wake **RETURNS WITHOUT rescheduling** — releasing the tick lock, then stopping — when ANY holds
(these are the §10 STOP-LOUD paths and the §11 lifecycle close, wired to the wake):
- **`MISSION-CLEARED` banked** (`status=achieved|could-not|cleared`) — check active-iff `mission_state`
  (§8) on EVERY wake BEFORE archive-close; once the latest lifecycle line is `MISSION-CLEARED`, the
  mission is INACTIVE and every later wake self-terminates. The natural close order (§11) is
  `timing-close` → `MISSION-CLEARED` → `archive-close` LAST → then the wake stops.
- **A named STOP-LOUD**: 5 FAILs for the same part+phase, `panel-unavailable-3x` the moment it is
  logged, `void-count` returning `-1`, or a corrupt/unreadable bridge (`FAILED rc=2`). None reschedule.
- **A mandatory human decision** (credential / destructive / external-side-effect skill, or any
  genuinely blocking decision): open the stop with a SINGLE atomic call —
  `q=$(cat qfile); bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh pending-stop <sid> <root> <slug> <part> <round> <attempt> <phase> "$q"` (SS7 — the question is
  untrusted mission-derived content: CAPTURE it into `"$q"` via a quoted heredoc/file and pass it
  double-quoted; NEVER inline it as a single-quoted literal (an apostrophe breaks out) or a double-quoted
  raw literal (a `$(...)`/backtick executes before the script sees it); the mint ALSO fails closed on a
  newline / leading `- [pd:` in the question). It ATOMICALLY (one lock) opens the
  human `AWAIT kind=human … op=<seq>-<slug> attempt=1 need=1 got=0` STOP barrier AND mints the monotonic pd
  (seq machine-assigned + monotonic + NEVER reused, even across `resolve`; 1st = `pd:1-<slug>`, 2nd =
  `pd:2-<slug>`, …), ECHOING `pending-stop ok id=pd:<seq>-<slug>`. CAPTURE the echoed id — do NOT hand-pick
  the seq (any agent-supplied seq is ignored). **C6 — capture the FULL output and CHECK the status line
  (rc) FIRST, THEN extract the id ONLY on the ok path.** `mission-write.sh` ALWAYS exits 0 (the rc is IN
  the printed line) and `sed` emits NOTHING on a failure line, so a bare `pid=$(… | sed …)` cannot tell a
  real mint from a `FAILED rc=3/7/8/9/10-14` — proceeding on an empty `pid` is a naked yield (S1). Do:
  ```
  out=$(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh pending-stop <sid> <root> <slug> <part> <round> <attempt> <phase> "$q" 2>&1)
  # R8r5-E6/D4 - ANCHOR to the EXACT status line `^mission-write: pending-stop ok id=pd:<seq>-<slug>` and
  # extract in ONE step. Do NOT wildcard-match `*id=pd:*` over the combined stdout+stderr: the untrusted
  # echoed question/args (or a lib diagnostic) could embed that token and SPOOF a mint on a FAILED rc.
  # PORTABLE sed only (BSD/macOS sed has NO `\b` and NO `\+`); BRE `[0-9][0-9]*` / `[a-z0-9-][a-z0-9-]*`.
  # An empty pid = no matching status line = the STOP did NOT open.
  pid=$(printf '%s\n' "$out" | sed -n 's/^mission-write: pending-stop ok id=\(pd:[0-9][0-9]*-[a-z0-9-][a-z0-9-]*\).*$/\1/p' | head -1)
  if [ -n "$pid" ]; then
    : # the ONLY proceed-able path — pid is the FULL, VALIDATED pd:<seq>-<slug> (use it verbatim for resolve)
  else
    : # every FAILED rc (see the `pending-stop` fail-closed rc block) OR an empty/spoofed id => the STOP did NOT open => do NOT proceed; STOP-LOUD / surface (S1)
  fi
  ```
  — on the ok path `pid` is the FULL `pd:<seq>-<slug>` (use it verbatim for `resolve`); the barrier/DECISION `op` is `${pid#pd:}`. **R6/R7-1 — the AWAIT `op` is the echoed pd's UNIQUE
  `<seq>-<slug>`** (the `pd:` id minus the `pd:` prefix), NOT the bare `<slug>`: without the minted seq,
  two same-slug decisions would share `(part,round,attempt=1,kind,op)` and the 2nd `got=0` opener would
  inherit the 1st's already-resolved `got=1` — silently skipping the mandatory stop (unapproved autonomous
  work). The minted seq guarantees each pd a DISTINCT op → DISTINCT idtag → the barrier LANDS. The atomic
  opener fails CLOSED (no pd line, no echo) on a bad slug / over-long line / seed-arithmetic /
  sequence-exhausted / a non-`appended` AWAIT, so a partial open never leaves a phantom stop; it also
  REFUSES a SECOND open human barrier (a second one is invisible to `await-state`'s single-barrier return).
  Do NOT hand-open a separate `await` barrier (the atomic verb already opened it) and do NOT substitute
  plain `pending` (NON-BLOCKING — it does not stop the loop, §9).
  THEN stop — the outstanding `await kind=human ready=0` keeps the §8 rows parked until a real user turn.
  **Closing it (C6, D6, D14, C2):** the first turn AFTER the user answers ENTERS §12.1 and CONSUMES the
  barrier UNDER its tick lock (step 4) — NOT before entering (R6: acting outside the lock lets a queued wake
  race the resolution → double-drive). **C2 — the gated action MUST run on the SAME wake that consumes the
  DECISION; NEVER close the barrier (got=1 + resolve) while deferring the action to a later wake.** Once
  `got=1` resolves the barrier the reader (C9 keystone) DROPS it, so a deferred wake would find nothing to
  consume and the approved action would NEVER run. Under the lock, in THIS EXACT order: **(a)** record the
  outcome — `log … "[mission] DECISION op=<seq>-<slug> outcome=<approve|deny>" "pd-<seq>-decision-<slug>"`
  with the user's ACTUAL answer (the barrier stays LIVE at `got=0` with the DECISION present — the C9 reader
  keeps a human `got=0`-with-a-DECISION barrier LIVE precisely so this wake can consume it); **(b)** CONSUME
  it — `approve` ⇒ perform the idempotent gated action; `deny` ⇒ ABORT it (prose, not machine-forced — the
  ACCEPTED RESIDUAL); **(c)** append the SAME barrier with `got=1` (reuse the exact
  op/part/phase/round/attempt/need from the token) — the `await` verb REFUSES this got=1 close unless the
  same-op DECISION already exists (DECISION-first is LIB-ENFORCED, and the reader ALSO requires the DECISION
  before it reads resolved); **(d)** `resolve` the pd whose `<seq>-<slug>` matches the `await-state` token's
  `op` (an EXACT unique match — the seq removes the old slug-repeat ambiguity). The whole CONSUME
  (DECISION → action → got=1 → resolve) IS this turn's ONE transition: go to step 7 and RESCHEDULE — do NOT
  drive a further transition this turn. **C8 — exactly-once depends on the gated action's OWN
  idempotency/single-shot nature (the ACCEPTED residual):** the STOP contract does NOT persist or enforce an
  applied/aborted flag, so the agent MUST make the gated action idempotent or single-shot (an external write
  idempotent BY KEY, the same idtag/idempotencyKey-dedup invariant the bridge uses) — so a re-consume after a
  crash is an approve-replay no-op / a deny that never fires. **R1 accepted FAIL-SAFE residual:** with the
  action BEFORE `got=1`, a crash between the action and `got=1` leaves the barrier LIVE + DECISION, so the
  next wake re-CONSUMES (idempotent action re-run = re-confirm, then closes); a crash after `got=1` leaves it
  RESOLVED with the action already done. NEVER a silent bypass; both legs fail safe, which is why we do NOT
  build an applied/aborted lifecycle. Order DECISION → action → got=1 → resolve (D14/R7-3): a crash mid-close
  leaves a durable DECISION (+ maybe a RESOLVED barrier + cosmetic stale pd line, benign), NEVER a removed pd
  + a ready=0 park with no recorded outcome. R4 — the got=1 append is a DISTINCT record (the idtag ends
  `-g<GOT>`, so it does NOT overwrite the got=0 opener); `await-state` reads the newest line's got so
  `got==need=1` (with the DECISION present) reads RESOLVED — that IS the close.
- **`await kind=human ready=0`** already outstanding (a prior turn parked on the user).

An **ordinary away-policy `pending`** (a non-blocking batched question logged under §9's away default) is
NOT a stop — the loop proceeds loudly on its assumption and the epilogue reschedules as usual. Only a
MANDATORY human decision (above) parks the loop with an `AWAIT kind=human`.

**The list above is CLOSED and EXHAUSTIVE.** Anything not on it is not a stop, however finished it feels.
Named explicitly because each of these has ended a real run:
- **Finishing a unit of work is NOT a stop.** A `git commit` returning success is the single most
  common false terminal — in one observed session it ended four consecutive turns. Your private
  planning unit (build → test → mutate → commit) is FINER-GRAINED than any mission transition, so its
  completion is never a turn boundary. Generalize: **a tool result that completes your own planning
  unit is not a turn boundary.** The four "naked-yield seam" reminders in §5 are EXAMPLES, not the
  closed set of places you must not stop.
- **Writing a report is NOT a stop.** Prose describing what landed belongs at the END of a turn that
  already contains the next transition, or at a real §12.3 stop. Starting a summary does not convert
  the turn into a handback.
- **Replying to a peer window is NOT a stop.** An inbound peer message is a wake source like any
  other; it did not enter through the tick lock, so after answering it, RE-ENTER §12.1 and exit
  through step 7 like everything else. In one observed session, peer replies caused three consecutive
  naked yields.
- **Verification-completeness is not task-completeness.** A green suite + watched mutations + a clean
  typecheck + a commit is a very strong done signal for a SLICE. Check the Build Plan for the next
  item before believing it.

**Announcing an action NEVER substitutes for taking it.** Narration accompanies action in the SAME
turn; it does not replace it. If a turn's only content is a description of what you are about to do
("checkpointing next", "running the barrier now"), that turn is a NAKED YIELD and the mission is now
frozen — the observed failure is exactly this, writing "context ~84%, checkpointing next" and then
stopping instead of checkpointing. The global reply-style rule asks you to narrate intent BEFORE a
batch of tool calls; that rule presumes the batch follows in the same turn. Narration with no
following tool call is the failure, not the rule.

### 12.4 Post-compact resume composes here (no double-drive)

Post-compact resume is **just another wake source** into §12.1 — not a second state machine. Keep the
existing `(sid,nonce)` post-compact resume marker, then enter the SAME routine (tick lock → §8 read →
cursor → one transition). If the SessionStart primer AND a restored scheduled wake both fire, the
**tick lock serializes them** (D8 — the real dedup): the FIRST takes the lock and advances; the SECOND
finds the lock fresh-held and reschedules WITHOUT touching state (or, if it acquires only after the first
released, it re-reads the now-advanced state and simply picks the NEXT step — the deterministic idtags make
any re-bank an idempotent no-op). It does NOT rely on the second wake "seeing the cursor change at step 5"
(a wake that recomputes its baseline after the winner's append would read it unchanged). **Intent
precedence on resume: the PLAN zone and the LOG outrank the handoff chain's `Next Action`** (§C / §8) —
a stale handoff hint never overrides the durable on-disk position.

### 12.5 Why a dropped step 7 is unrecoverable

There is no timer, no expiring lock, and no watcher behind the continuation invariant. A turn that
ends without a successful `ScheduleWakeup` leaves the mission at its last banked state **indefinitely**,
until a human types something — which may be many hours later, and the run produces nothing in the
meantime. This is why step 7 is a gate rather than a step: the cost of dropping it is not a slow
mission, it is a dead one.
