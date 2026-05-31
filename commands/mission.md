---
description: "Autonomous long-build conductor (playbook, not an engine). Opt-in and HEAVY — per part it runs research + a full /plan reviewer loop (≈4-6 rounds) and a 3+3 cross-model code-review panel (≈3-6 rounds), across many parts and many compactions. Lays out a big multi-part roadmap WITH you once, then executes each part on its own through research → /plan(+reviewers) → /implement → /codex-review to honest 2-dry convergence, riding the mission-bridge + /pre-compact so it never loses the thread. For genuinely large builds only; overkill for small work."
argument-hint: "[roadmap/goal | clear [reason] | status | (blank=status)]"
---

# /mission — autonomous long-build conductor

`/mission` is a **loose, judgment-driven PLAYBOOK — prose you follow, NOT an engine.**
It conducts four skills you already have — **codebase-research → `/plan`(+reviewers) →
`/implement` → `/codex-review`** — over the durable **mission-bridge**, riding `/pre-compact`,
looping implement↔review to honest convergence, per part, across many compactions.

The governing constraint, stated three times in the brief and load-bearing here:
**DO NOT over-engineer or over-constrain.** Per-part work is *an objective you navigate*, never
a rigid state machine you are trapped in. The four-skill sequence is the **SPINE, not a cage** —
you stay free to invoke any other skill whenever it helps.

The LOG you write is a **best-effort boundary checkpoint — observational, never a gate.**
You checkpoint your position at a phase/round boundary so a post-compact agent can resume the
exact round losslessly. Missing one round's log degrades resume *granularity*; it NEVER blocks
work and you never "service the LOG or fail." This mirrors the bridge's own observational-not-
gating invariant. Do not treat it as a machine you must feed.

---

## 0. When to use this — and when NOT

**Use `/mission` for genuinely large, multi-part builds** that span many hours and several
compactions and deserve quality-first rigor: a real subsystem, a multi-phase migration, a
feature that decomposes into several independently-shippable parts.

It is **opt-in and heavy.** Per part it spends roughly 4-6 plan-review rounds + a 3+3 cross-model
code-review panel over 3-6 rounds — multiply that across many parts. That is the right spend for
big work and pure overkill for small work.

**Do NOT use it for** a typo, a one-liner, a single bug fix, or any change a normal
`/plan`→`/implement` (or just an edit) handles well. If in doubt about whether the work is big
enough, it probably isn't. Use judgment; do not over-apply.

---

## 1. Resolve sid + root + mission file — FIRST, before anything else

Every `mission-write.sh` call needs `<sid>` and `<root>`, and a fresh `/mission` invocation
(unlike `/post-compact-resume`) has **no Stop-hook arg supplying them**. Resolve all three ONCE,
up front, and reuse them for the whole session. Mirror exactly what `post-compact-resume.md` does
(its "Resolve the durable mission file" subsection, ~line 276).

**`sid`** = the platform session UUID. **PREFER the platform-supplied session id** the way
`/pre-compact` does — `$CLAUDE_SESSION_ID` then `$CLAUDE_CODE_SESSION_ID` — and only fall back to the
mtime-newest-transcript GUESS as a last resort (an mtime guess can pick the wrong transcript when two
sessions interleave, which would make a long mission "disappear"; refuse to guess when the platform
told you the truth):
```bash
sid="${CLAUDE_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}"
[ -z "$sid" ] && sid=$(ls -t ~/.claude/projects/$(pwd | sed 's|/|-|g; s|^|-|')/*.jsonl 2>/dev/null \
      | head -1 | xargs -I {} basename {} .jsonl)   # last-resort mtime guess only
```

**`root`** = `handoff_canonical_root` (worktree-invariant canonical anchor):
```bash
. "$HOME/.claude-dotfiles/scripts/hooks/lib/mission-bridge.sh"   # sources handoff-locate.sh
root=$(handoff_canonical_root)
```

**Mission file** — resolve by PREFERRING the chain manifest `mission_path` pointer, then falling
back to the canonical-root glob. **NEVER recompute a fresh sid to build the path** — if sid
computation diverges across the compaction chain, a recompute would make a long mission "disappear":
```bash
mfile=$(jq -r '.mission_path // empty' ~/.claude/chains/"$sid".json 2>/dev/null)
[ -z "$mfile" ] && mfile=$(ls -t "$root"/MISSION.*.md 2>/dev/null | head -1)
```
The `mission_path` pointer is the authoritative anchor written by `mission_create`; the glob is the
backstop. Use the resolved `mfile` for all reads; use `<sid>`/`<root>` for all writes.

---

## 2. Invocation dispatch

Parse `$ARGUMENTS`:

- **blank or `status`** → **STATUS** (read-only, NO mutation). Resolve the mission via the manifest
  `mission_path` pointer (Section 1). Read the **LOG sidecar DIRECTLY** (the resume-read idiom in
  Section 8 — `grep '[mission] '` over the FULL live log PLUS the newest rotated archive, **not** a
  fixed `tail`, and **not** the banner: status reads the LOG directly). From the recovered last round
  line + last lifecycle line and PLAN line-1, derive and print: mode (build/adopt/none), current part,
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
  ```
  A bare `clear` sets `status=cleared`. `achieved` / `could-not` are set ONLY by the explicit
  lifecycle close at the natural end of a mission (Section 11) — not by this verb. Parse the returned
  status line (Section 7); confirm to the user.
- **free-text roadmap/goal** → **EXPLICIT BUILD MODE** (Section 3 → Section 5).
- **ambient trigger in a plain user message** — e.g. "follow the /mission methodology with your
  plan", "apply the /mission template to what we're doing", recognized by **INTENT, not exact
  words** → **ADOPT MODE** (Section 4 → Section 5).

---

## 3. Level-1 — explicit build mode (interactive, WITH the user)

This first step is **collaborative, not autonomous.** Shape the multi-part roadmap together —
**lighter than a full `/plan`**: this is the *roadmap* (the parts and their sequence), not a
part-plan. Each part later runs its own full `/plan` reviewer loop in Section 5.

Then seed the immutable PLAN once. **PLAN line-1 is the sole machine token; lines 2+ are prose.**
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh create <sid> <root> "MISSION MODE: build
<the multi-part roadmap: parts, sequence, intended outcome>

Standing directive: route substantial work through research → /plan(+reviewers) → /implement →
/codex-review, looping to 2 honest dry rounds (independent reviewers judge 'dry'); soft targets
plan 4-6 / codex 3-6, hard cap 6; /pre-compact freely interleaved; active until a
[mission] MISSION-CLEARED line appears in the LOG."
```
`create` is **no-clobber** — it will not overwrite an existing mission. Parse the returned status line
(Section 7). Two outcomes need handling, NOT a silent no-op:
- **`ok` and no prior file** → the PLAN was seeded. Confirm it with the user, then begin Level-2.
- **A `MISSION.<sid>.md` already exists** (a non-mission `/pre-compact`, or a previously-`cleared`
  mission, seeded the PLAN) → `create` is no-clobber and would quietly keep that **stale** PLAN.
  Do **NOT** silent-no-op. Handle it exactly like §4(c): **surface it to the user and `rebaseline`**
  the PLAN to this build's directive (rebaseline is the ONLY path that legitimately rewrites PLAN,
  and it now appends a `[mission] MISSION-REBASELINED status=active` lifecycle line that REACTIVATES
  a previously-cleared mission per the active-iff rule in Section 8):
  ```bash
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh rebaseline <sid> <root> "MISSION MODE: build
  <the multi-part roadmap + the same standing-directive text as above>"
  ```
  Parse that status line too (Section 7). If the user is away, log a loud `challenge` explaining the
  rebaseline and proceed.

Confirm the seeded/rebaselined PLAN with the user, then begin Level-2 at part 1 (Section 5).

---

## 4. Adopt mode (ambient, mid-session)

The user retrofits mission rigor onto in-flight work. Resolve any existing mission (Section 1), then
**three cases**:

- **(a) No mission exists** → seed one, capturing the current objective from the in-flight context:
  ```bash
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh create <sid> <root> "MISSION MODE: adopt
  <captured current objective + state>

  Standing directive: <same directive text as Section 3>"
  ```
- **(b) A mission exists AND PLAN line-1 IS a `MISSION MODE:` token** → you are already in mission
  mode; just continue.
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
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh rebaseline <sid> <root> "MISSION MODE: adopt
  <captured objective + standing directive>"
  ```
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
- a **Codex read-only fact pass** proving deps / build & test commands / runtime:
  ```bash
  codex -c model_reasoning_effort="high" exec -s read-only --ephemeral -C <root> "<scope-prove prompt>"
  ```
Reconcile after both return. An **unresolved factual contradiction** → `pending` (batched) + a `note`
recording the forced assumption, then proceed on the **more-evidenced branch, LOUDLY**. Otherwise
`note` the reconciled scope. Log the research round (Section 7).

### Phase 2 — PLAN (Claude-authored; cross-model INDEPENDENT review loop)
Invoke the Skill tool with `skill: plan`. Continue once it returns. (`/plan` runs its own Claude
plan-reviewer subagents.) **ALSO**, in parallel and independent, spawn a **Codex plan-reviewer at
high** attacking executability — missing commands, undefined steps, ordering/dependency bugs, and
especially **TEST GAPS**.

**TEST-TRUSTWORTHINESS is a REQUIRED finding-class here.** Convergence is theater if the repo's tests
are weak. Assess existing coverage; if weak or absent, the part-plan MUST add meaningful tests (for
THIS repo, "tests" = the harness convention — `test-*.sh` / assumption tests; for code repos:
unit/integration). Log the verdict BEFORE the first implement round — convergence cannot be reached
while test-trust is unresolved:
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] test-trust part=<N>=<ok|added|n/a>" "m<N>-test-trust"
```
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

Then run the **REVIEW BARRIER** — both IN PARALLEL, independent, neither sees the other's output:
- the **implementation-reviewer subagent** (plan-completeness / quality) — Claude, spawned normally (medium);
- Invoke the Skill tool with `skill: codex-review --effort high`. Continue once it returns. (The
  `--effort high` arg runs its Codex passes at high → the full 3+3 cross-model panel + verify.)

**Codex-unavailable (TOTAL or PARTIAL) ⇒ VOID the round (do NOT count it as dry).** `/codex-review`
emits **`Codex unavailable`** only when ALL four Codex passes fail (total fallback to Claude-only); a
PARTIAL failure (1-3 of the 4 passes) instead emits a per-pass marker like **`(Codex-2: unavailable)`**.
EITHER means a cross-model lens did not actually run. After `/codex-review` returns, INSPECT the report
text (case-insensitive) and VOID the round if it matches **either** substring:
- the total-failure marker `Codex unavailable`, OR
- the per-pass marker `(Codex-` … `unavailable)` (i.e. grep for the literal `(Codex-` followed by
  `unavailable)` on the same marker — any one of the 4 passes being unavailable is enough).

A round counts toward the 2-dry convergence ONLY if EVERY independent reviewer's verdict is present —
ALL 4 Codex passes plus the Claude reviewers (see Section 6 VOID-on-dead-reviewer). If either marker is
present, this round is **VOID**: log the durable VOID marker (Section 7), re-run the panel; do NOT bank
a void round.

Merge ALL findings at **ONE synthesis barrier**. Write the round checkpoint in TWO parts so it
survives the log machinery (the lib reroutes any LOG line whose `idtag\tentry` is ≥480 bytes to
DURABLE NOTES, where the resume grep won't find it):
1. **Persist the round checkpoint line FIRST, with `phase=review` and a short findings COUNT**
   (Section 7 round-line schema) — TERSE, never verbose findings text — so a mid-synthesis compaction
   resumes from a recorded, in-LOG round.
2. Put the verbose per-reviewer findings in a SEPARATE `note` (DURABLE NOTES), referenced by the
   round's `part/phase/round`.

The `phase=review` checkpoint means "findings logged, fixes NOT yet applied"; when you begin applying
fixes, advance the SAME round to `phase=fix` (Section 7) so a compaction in the fix window resumes
unambiguously (Section 5 resume rules / Section 8). The dry-count stays auditable from the verbatim
record rather than asserted by you.

### CONVERGENCE (implement ↔ review fix-cycle)
Loop, per round K: if findings are actionable, log the **`phase=fix`** checkpoint for the SAME round
(it marks "now applying fixes"), fix via `skill: implement --no-review <plan-path>` → re-run the
barrier (fresh, independent) as the **NEXT** round K+1 → log that round's `phase=review` checkpoint.
**Never re-run an idtag round you already banked** (Section 8 / Section 12). See Section 6 for the
convergence rules. On a PLAN divergence → `challenge` (loud). On an open human-decision → `pending`
(batched).

**Resume substates within a round (Section 7 schema; this MUST match the §8 round-ambiguity decision
table verbatim — one decision, two cross-references):**
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
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] PART-DONE part=<N> (converged)" "m<N>-part-done"
```
Parse the status line (Section 7). Then **retire the part plan**: because `--no-review` made `/mission`
own the plan lifecycle, MOVE the per-part plan from ready-plans to done-plans after `PART-DONE` (use
the project's done-plans convention — e.g. `mv <ready-plans>/<part-plan>.md <done-plans>/`). A plan
left in ready-plans is a stale plan a later part could wrongly grab.

**Advance to the next part** — log a `PART-START` lifecycle line for the new part so resume can tell a
converged part from one still in progress (Section 8 / Section 9):
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] PART-START part=<N+1> name=<slug>" "m<N+1>-part-start"
```
Parse the status line (Section 7), then begin the next part's Phase 1.

---

## 6. Convergence rules (restated crisply)

- **Soft targets:** plan reviews typically **4-6** (4 is the usual floor); codex reviews typically
  **3-6**. These are *guidance, not gates*.
- **Hard cap 6** either way.
- **Stop at 2 consecutive DRY rounds.** "Dry" = the **independent reviewers** returned **zero new
  actionable findings**, logged verbatim — NOT you grading your own work.
- **An ACTIONABLE round resets `dry → 0`.** Any round whose independent reviewers produced ≥1 new
  actionable finding breaks the consecutive-dry streak: the NEXT round's `dry=` starts again at `0`.
  Only two back-to-back zero-actionable rounds reach `dry=2`. State the post-round `dry` on the round
  line accordingly (Section 7).
- **VOID-on-dead-reviewer (the single biggest false-converge risk).** A round counts toward the
  2-dry tally **ONLY if EVERY independent reviewer produced a parseable, on-topic, evidence-citing
  verdict** — that means ALL **4 Codex passes + 3 Claude reviewers** of the panel actually ran (see
  "Codex-unavailable (TOTAL or PARTIAL) ⇒ VOID" in Section 5). A reviewer that errors, returns empty,
  times out (e.g. a Codex CLI hang), is reported **`Codex unavailable`** (all 4 failed), OR is reported
  per-pass **`(Codex-N: unavailable)`** (even 1 of the 4 failed) makes the round **VOID** → re-run the
  panel; do **NOT** bank a void round as dry. A VOID must be made DURABLE so a compaction mid-void
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
Verbs: `create | log | note | challenge | pending | resolve | rebaseline | render-banner`.

**Codex NEVER writes the bridge.** EVERY Codex invocation — research, plan-review, code-review, any
implement hand-over — runs `-s read-only`. A second writer on the critical bridge reintroduces the
exact corruption risk the bridge engineered out.

**PARSE THE STATUS LINE after EVERY `mission-write.sh` call (load-bearing — the script ALWAYS
`exit 0`).** Failure surfaces ONLY on the script's single stdout status line, never as a non-zero
exit. The line is `mission-write: <verb> ok` on success, or
`mission-write: <verb> FAILED rc=N (<reason>)` on failure. Parse the rc and act:
```bash
rc=$(printf '%s' "$status_line" | sed -n 's/.*FAILED rc=\([0-9][0-9]*\).*/\1/p')
```
- empty `rc` (line said `ok`) → proceed.
- `rc=2` (**corrupt/unreadable bridge**) → trigger the **§10 STOP-LOUD guardrail** immediately
  (surface to the user, point at `.mission-backups/`); do NOT silently proceed. (This is the wire
  that connects the corrupt-bridge signal to STOP-LOUD.)
- `rc=3` (**lock busy**) → retry the SAME call a few times (e.g. up to 5, brief pause between); if
  still `rc=3`, log a `FAIL …reason=lock-busy` line (it routes through a DIFFERENT lock attempt) or
  proceed and note it, per the away policy (§9).
- any other non-zero rc (1/4/5/6/7/127) → log it + proceed; if it recurs for the same part+phase it
  feeds the 5-FAIL loop-breaker (§10).

**LOG schema — the SINGLE canonical definition; every resume rule (§5/§8/§9/§12/§13) reads lines
back in EXACTLY these shapes.** These are `log`-verb entries with a structured `[mission]` payload —
not new verbs; the real on-disk line is `<idtag>\t<entry>`; resume matches `[mission]` ANYWHERE on the
line, not at column 0.

- **Round line** (one per part/phase/round, advanced by substate — keep it TERSE, <480B, or the lib
  reroutes it to DURABLE NOTES where resume can't grep it):
  - entry: `[mission] part=<N> name=<slug> phase=<research|plan|implement|review|fix> round=<K> dry=<D> findings=<COUNT>`
  - `findings=<COUNT>` is a SHORT integer count ONLY (e.g. `findings=2`) — NEVER verbose finding text.
    Verbose per-reviewer findings go in a SEPARATE `note` (DURABLE NOTES), referenced by `part/phase/
    round` (Section 5 synthesis barrier).
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
  - entry: `[mission] VOID part=<N> phase=review round=<K> reason=<reviewer-dead|codex-unavailable|...>`
  - idtag: `m<N>-void-r<K>` — on resume, a VOID for round K means re-run round K FRESH, never count it.
- **Lifecycle lines:**
  - `[mission] PART-START part=<N> name=<slug>` idtag `m<N>-part-start` (logged when advancing to a
    new part; resume uses it to skip a converged part — Section 8/9).
  - `[mission] PART-DONE part=<N> (converged)` idtag `m<N>-part-done`.
  - `[mission] test-trust part=<N>=<ok|added|n/a>` idtag `m<N>-test-trust` (before the first implement
    round; durable resume marker — Section 5).
  - `[mission] MISSION-CLEARED status=<achieved|could-not|cleared> reason=<slug>` idtag
    `mission-cleared-<slug>`.
  - `[mission] MISSION-REBASELINED status=active (…)` — written by the `rebaseline` verb itself (the
    lib appends it); a REACTIVATING lifecycle token (Section 8 active-iff).

Example round line:
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] part=2 name=auth phase=review round=3 dry=1 findings=2" "m2-review-r3-d1"
```

Other zones: `note` = forced research assumptions + verbose round findings (DURABLE NOTES);
`challenge` = PLAN divergence (loud; never silently edit PLAN); `pending` = the batched human-decision
queue (`- [pd:<seq>-<slug>] <q>`); `resolve` drains a pending; `rebaseline` is the ONLY path that
rewrites PLAN.

---

## 8. /pre-compact interleaving + resume rule

Invoke `/pre-compact` at natural seams or whenever context warrants — freely. Invoke the Skill tool
with `skill: pre-compact`. Continue once it returns.

**Resume-read idiom (the SINGLE canonical way to recover state from the LOG — used by §2 status, §5,
§9, §12, §13).** Do **NOT** `tail -n 40` the live log: with >40 trailing lines, or after a rotation,
`tail` MISSES the last round/lifecycle line. Do **NOT** read only the newest archive either:
`_mission_log_rotate` archives the OLDEST half on EACH fire, so after ≥2 rotations a durable line
(MISSION-CLEARED, PART-DONE, test-trust, a FAIL tally line) can sit in an OLDER archive — reading just
`ls -t … | head -1` would MISS it → false reactivation / repeated work / 5-FAIL under-count. Instead
`grep '[mission] '` over **ALL archives concatenated oldest→newest THEN the live log**, so no rotated
line is ever outside the read window:
```bash
log="$root/MISSION.$sid.log"
{ for a in $(ls -tr "$root"/.mission-backups/MISSION."$sid".log.* 2>/dev/null); do
    case "$a" in *.gz) gzip -dc "$a" 2>/dev/null;; *) cat "$a" 2>/dev/null;; esac
  done
  cat "$log" 2>/dev/null; } | grep -F '[mission] ' > /tmp/mission-resume.$$ 2>/dev/null
# state gate (active-iff) — keys ONLY on CLEARED/REBASELINED (see active-iff rule below):
mission_state=$(grep -E '\[mission\] MISSION-(CLEARED|REBASELINED)' /tmp/mission-resume.$$ | tail -1)
# convergence — keys ONLY on the last phase=review round (the dry-bearing phase):
last_review=$(grep -E '\[mission\] part=[0-9]+ .*phase=review ' /tmp/mission-resume.$$ | tail -1)
# resume POSITIONING — last activity of ANY phase + last part-lifecycle (NOT the state gate):
last_round=$(grep -E '\[mission\] part=' /tmp/mission-resume.$$ | tail -1)
last_progress=$(grep -E '\[mission\] (PART-START|PART-DONE|test-trust|VOID)' /tmp/mission-resume.$$ | tail -1)
```
(`ls -tr` lists archives OLDEST first; concatenating them before the live log preserves chronological
order so the final `tail -1` of any filtered grep picks the genuinely-latest line. The
`MISSION.<sid>.log.*` glob covers both `.gz` and the `.txt` fallback when gzip was absent.)
The three greps are deliberately distinct: `mission_state` is the **active-iff state gate** (keys ONLY
on CLEARED/REBASELINED), `last_review` drives **convergence** (the `2 − dry` math), and
`last_round`/`last_progress` are for **resume positioning** only. Never let a transient progress line
gate active-iff.

**After `/pre-compact` returns** (or after any compaction), re-derive your position from that
recovered record and continue the **EXACT** `(part, phase, round, dry)`. Read `last_round` for
*positioning* (which part/phase you were in), but compute convergence (`2 − dry`) **ONLY** from
`last_review` (the dedicated `phase=review` grep) — never from a `phase=fix`/`plan`/`implement`/
`research` line, whose `dry=` is not the convergence count (I6: a non-review phase line must not drive
the `2 − D` math).
- Read `last_review` (the last `phase=review` round line); you need `2 − dry` more dry rounds.
- **Round-ambiguity decision table (the SINGLE reconciliation of §5↔§8 — apply in order):**

  | Last round line for the current part | Resume action |
  |---|---|
  | `phase=fix` (a fix was in flight) | FINISH the in-flight fix to completion against the working tree, THEN re-run the barrier as the NEXT round K+1. Do not assume the fix finished. |
  | `phase=review` with `findings>0` (ACTIONABLE — `dry` was NOT advanced) | resume into the **FIX of the SAME round K** → log `phase=fix` round=K, apply fixes; do NOT start a fresh review round K+1. (`findings>0` ⇒ this round demands a fix before any new review — see M2/I3.) |
  | `phase=review` with `findings=0` (dry-advancing, `dry` already incremented on the line) | start the NEXT FRESH review round K+1 per the `2 − dry` rule. |
  | a `VOID … round=K` is the latest line for round K | re-run round K FRESH (never count it). |
  | last is `PART-DONE` | do not re-resume; advance per the PART-DONE rule below. |

  **Never re-run an idtag round you already banked** (a banked `findings=0` review or a completed fix
  is a no-op that wastes a compaction). `findings=<COUNT>` on the round line is the cross-check that
  disambiguates the two `phase=review` rows above: `findings=0` ⇒ dry-advancing (next fresh round);
  `findings>0` ⇒ actionable (must reach `phase=fix` first) — so it is a live resume input, not dead
  weight.
- **PART-DONE / next-part:** if the last `[mission]` line FOR THE CURRENT PART is `PART-DONE`, the part
  converged — do NOT re-resume it. Advance to the next part: find the latest `PART-START part=<M>`
  (if present, resume part M); if no later `PART-START` exists yet, log `PART-START part=<N+1>`
  (Section 5/7) and begin its Phase 1. **Never restart converged work** and never re-run review rounds
  you already banked.
- A `VOID part=<N> … round=<K>` line means round K did not count → re-run round K fresh (Section 6/7).
- `test-trust part=<N>` recovered = honored; absent = unresolved → re-assess before implementing (#13).

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
- **Unattended blocking surfaces extend to `/implement`'s gates.** The away-default above applies to
  ANY surface that would block an unattended run — including `/implement`'s **dangerous-command
  Manual-Steps gate**. When away: do NOT block on that modal; log a `pending` PENDING-DECISION (the
  decision text + context-usage %) and proceed-or-stop per the away policy, exactly like a batched
  question. The decision stays in the queue for the next interactive turn.
- **Credential / external-side-effect / destructive guard (autonomous mode).** Full-agency,
  credential, external-side-effect, or destructive skills — e.g. `/load-creds`, anything that exfils
  secrets, mutates production, or performs irreversible external actions — require a **human PENDING
  decision in autonomous mode. Do NOT auto-run them.** Log a `pending` describing what wants to run and
  why, and proceed on the non-destructive branch (or stop if blocked). These are the one class where
  "proceed loudly when away" does NOT apply — the human must ratify before such a skill runs.
- **Full agency (spine not cage).** The four-skill sequence is the backbone, not a fence. You are free
  to invoke ANY dotfiles skill whenever it helps — `/script` to prove load-bearing assumptions before
  building (encouraged), `/investigate`, `/document`, `/gemini`, etc. (Credential/destructive skills
  like `/load-creds` are gated by the guard above — they need a human PENDING decision in autonomous
  mode.)
- **Test-trustworthiness** is both a plan-time precondition and a deliverable (see Section 5, Phase 2):
  no deleting or weakening tests to pass; meaningful coverage before "converged" means anything.

---

## 10. Guardrails — stop LOUD

- **5 FAILs for the SAME part+phase in the LOG** → **STOP LOUD.** Count from the durable record
  (the guard can't live in volatile context): the resume-read idiom (Section 8) recovers FAIL lines,
  and because each FAIL is attempt-scoped (`m<N>-fail-<reason>-<attempt>`, Section 7) the lib does NOT
  dedup them, so 5 distinct lines for the same `part=<N> phase=<P>` actually accumulate and the guard
  can fire. Tally `[mission] FAIL part=<N> phase=<P> …` lines per part+phase; at 5, STOP LOUD — do not
  burn hours wrong.
- **A corrupt or unreadable bridge** → **STOP LOUD**, surface it to the user, point them at the
  `.mission-backups/` under the canonical root; do not silently proceed. This guard is WIRED to the
  status-line parse (Section 7): any `mission-write.sh` call returning `FAILED rc=2` (corrupt — the
  lib's `mission_verify` failed under the lock) triggers this STOP-LOUD immediately. (Also triggers
  if a direct `mission_verify` you run fails.)

---

## 11. Lifecycle — clear + status

- **`/mission clear [reason]`** logs `[mission] MISSION-CLEARED status=cleared reason=<slug>` (idtag
  `mission-cleared-<slug>`, so a re-issued clear doesn't append a duplicate lifecycle line) and ends
  the mission early (mirrors `/goal clear`). `achieved` / `could-not` are set only by the **explicit
  lifecycle close** at a mission's natural end — write the appropriate `status=` on the MISSION-CLEARED
  line — never by the bare `clear` verb. Parse the returned status line (Section 7).
- **`/mission status`** (and blank) reads the LOG **directly** via the Section 8 resume-read idiom
  (grep over the full live log + newest archive), derives mode/part/phase/round/dry + pending, and
  prints — no mutation. Mode/`status=` come from the LATEST lifecycle line (Section 8 active-iff).
