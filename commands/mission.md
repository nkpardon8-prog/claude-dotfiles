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
  the reason as a slug and give the line an idtag so a re-issued `clear` does not append a duplicate
  lifecycle line (the lib dedups on the leading idtag):
  ```bash
  reason_slug=$(printf '%s' "<reason-or-manual>" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-' | head -c 32)
  [ -z "$reason_slug" ] && reason_slug=manual
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] MISSION-CLEARED status=cleared reason=${reason_slug}" "mission-cleared-${reason_slug}"
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
`create` is **no-clobber** — it will not overwrite an existing mission. Confirm the seeded PLAN with
the user, then begin Level-2 at part 1 (Section 5).

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
  `/pre-compact` seeded the PLAN) → do **NOT** silently no-op (`create` is no-clobber and would
  quietly do nothing). Surface this to the user and **rebaseline** the PLAN to the mission directive
  — `rebaseline` is the ONLY path that legitimately rewrites PLAN:
  ```bash
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh rebaseline <sid> <root> "MISSION MODE: adopt
  <captured objective + standing directive>"
  ```
  If the user is away, log a **loud CHALLENGE** explaining the rebaseline and proceed.

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
Merge/dedupe reviewer findings (overlap = confidence, divergence = signal); iterate; log each plan round.

### Phase 3 — IMPLEMENT  ∥  Phase 4 — REVIEW BARRIER (the parallelism win)
Invoke the Skill tool with `skill: implement --no-review`. Continue once it returns. The `--no-review`
flag suppresses `/implement`'s built-in tail implementation-reviewer so **`/mission` owns the review
barrier** (no double impl-reviewer; the barrier runs concurrently). **Claude owns integration**;
Codex assists per-chunk. Full hand-over to Codex is allowed ONLY for isolated, mechanical, well-
specified chunks — and ONLY in a worktree that does NOT contain the bridge artifacts (they live at
the canonical root, never inside a per-part worktree), with Codex run `-s read-only`.

Then run the **REVIEW BARRIER** — both IN PARALLEL, independent, neither sees the other's output:
- the **implementation-reviewer subagent** (plan-completeness / quality) — Claude, spawned normally (medium);
- Invoke the Skill tool with `skill: codex-review --effort high`. Continue once it returns. (The
  `--effort high` arg runs its Codex passes at high → the full 3+3 cross-model panel + verify.)

Merge ALL findings at **ONE synthesis barrier**. **Persist them to the LOG (`findings=`) BEFORE
acting** — so a mid-synthesis compaction resumes from the findings, and the dry-count stays auditable
from the verbatim record rather than asserted by you.

### CONVERGENCE (implement ↔ review fix-cycle)
Loop: fix via `skill: implement --no-review` → re-run the barrier (fresh, independent) → log the
round. See Section 6 for the convergence rules. On a PLAN divergence → `challenge` (loud). On an open
human-decision → `pending` (batched). When converged:
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] PART-DONE part=<N> (converged)" "m<N>-part-done"
```
Advance to the next part.

---

## 6. Convergence rules (restated crisply)

- **Soft targets:** plan reviews typically **4-6** (4 is the usual floor); codex reviews typically
  **3-6**. These are *guidance, not gates*.
- **Hard cap 6** either way.
- **Stop at 2 consecutive DRY rounds.** "Dry" = the **independent reviewers** returned **zero new
  actionable findings**, logged verbatim — NOT you grading your own work.
- **VOID-on-dead-reviewer (the single biggest false-converge risk).** A round counts toward the
  2-dry tally **ONLY if EVERY independent reviewer produced a parseable, on-topic, evidence-citing
  verdict.** A reviewer that errors, returns empty, or times out (e.g. a Codex CLI hang) makes the
  round **VOID** → re-run that reviewer; do **NOT** bank a void round as dry.
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

**LOG schema** (these are `log`-verb entries with a structured `[mission]` payload — not new verbs;
the real on-disk line is `<idtag>\t<entry>`; resume matches `[mission]` ANYWHERE on the line, not at
column 0):

- **Round line** (one per part/phase/round/dry-state):
  - entry: `[mission] part=<N> name=<slug> phase=<research|plan|implement|review> round=<K> dry=<D> findings=<count-or-slugs>`
  - idtag: `m<N>-<phase>-r<K>-d<D>` — the **`d<D>` is REQUIRED**: it encodes the dry-count so an
    advanced dry-state is a NEW line, not an idempotent no-op (without it the dry-count silently never
    updates). `dry=<D>` is the **running consecutive-dry count (0, 1, 2)** after that round; a resume
    agent reads the last review-round line and needs `2 − D` more dry rounds.
- **FAIL line** (durable failure tally, reconstructable across compactions):
  `[mission] FAIL part=<N> phase=<P> reason=<slug>` idtag `m<N>-fail-<reason-hash>`.
- **Lifecycle lines:** `[mission] PART-DONE part=<N> (converged)`;
  `[mission] test-trust part=<N>=<ok|added|n/a>` (before the first implement round);
  `[mission] MISSION-CLEARED status=<achieved|could-not|cleared>`.

Example:
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] part=2 name=auth phase=review round=3 dry=1 findings=2:race,nullcheck" "m2-review-r3-d1"
```

Other zones: `note` = forced research assumptions (DURABLE NOTES); `challenge` = PLAN divergence
(loud; never silently edit PLAN); `pending` = the batched human-decision queue
(`- [pd:<seq>-<slug>] <q>`); `resolve` drains a pending; `rebaseline` is the ONLY path that rewrites PLAN.

---

## 8. /pre-compact interleaving + resume rule

Invoke `/pre-compact` at natural seams or whenever context warrants — freely. Invoke the Skill tool
with `skill: pre-compact`. Continue once it returns.

**After it returns** (or after any compaction), re-derive your position from the durable record:
read the LOG tail (Section 2's `tail -n 40`) and continue the **EXACT** `(part, phase, round, dry)`
you find there. Read the last `[mission] part=…` round line; you need `2 − dry` more dry rounds.
**Never restart converged work** and never re-run review rounds you already banked.

**Mode is ACTIVE iff** PLAN line-1 is a `MISSION MODE:` token **AND** the most-recent lifecycle line
in the LOG is NOT `MISSION-CLEARED`. (Keying on the *latest* lifecycle line means a sid re-seeded via
`rebaseline` after a clear is active again, and a stale earlier CLEARED no longer suppresses.)

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
- **Full agency (spine not cage).** The four-skill sequence is the backbone, not a fence. You are free
  to invoke ANY dotfiles skill whenever it helps — `/script` to prove load-bearing assumptions before
  building (encouraged), `/investigate`, `/document`, `/gemini`, `/load-creds`, etc.
- **Test-trustworthiness** is both a plan-time precondition and a deliverable (see Section 5, Phase 2):
  no deleting or weakening tests to pass; meaningful coverage before "converged" means anything.

---

## 10. Guardrails — stop LOUD

- **5 identical FAIL lines in the LOG** (counted from the durable record, reconstructable across
  compactions — the guard can't live in volatile context) → **STOP LOUD.** Do not burn hours wrong.
- **A corrupt or unreadable bridge** (e.g. `mission_verify` fails) → **STOP LOUD**, surface it to the
  user, point them at the `.mission-backups/` under the canonical root; do not silently proceed.

---

## 11. Lifecycle — clear + status

- **`/mission clear [reason]`** logs `[mission] MISSION-CLEARED status=cleared` and ends the mission
  early (mirrors `/goal clear`). `achieved` / `could-not` are set only by the **explicit lifecycle
  close** at a mission's natural end — write the appropriate `status=` on the MISSION-CLEARED line —
  never by the bare `clear` verb.
- **`/mission status`** (and blank) reads the LOG **directly** (Section 2), derives mode/part/phase/
  round/dry + pending, and prints — no mutation. The banner's status reads the `status=` off the
  terminal lifecycle line.
