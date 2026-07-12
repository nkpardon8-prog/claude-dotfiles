---
description: "Autonomous long-build conductor (playbook, not an engine). Opt-in and HEAVY — per part it runs research + a full /plan reviewer loop (≈4-6 rounds) and a 4 Codex + 3 Claude cross-model code-review panel (≈3-6 rounds), across many parts and many compactions. Lays out a big multi-part roadmap WITH you once, then executes each part on its own through research → /plan(+reviewers) → /implement → /codex-review to honest 2-dry convergence, riding the mission-bridge + /pre-compact so it never loses the thread. For genuinely large builds only; overkill for small work."
argument-hint: "[roadmap/goal | resume | clear [reason] | status | (blank=status)]"
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

It is **opt-in and heavy.** Per part it spends roughly 4-6 plan-review rounds + a 4 Codex + 3 Claude
cross-model code-review panel over 3-6 rounds — multiply that across many parts. That is the right spend for
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
The PLAN payload contains the (untrusted) roadmap text, so pass it **SINGLE-quoted** — never
double-quoted — so a `$(...)`/backtick in the captured roadmap cannot execute (§7 injection rule):
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh create <sid> <root> 'MISSION MODE: build
<the multi-part roadmap: parts, sequence, intended outcome>

Standing directive: route substantial work through research → /plan(+reviewers) → /implement →
/codex-review, looping to 2 honest dry rounds (independent reviewers judge dryness); soft targets
plan 4-6 / codex 3-6, hard cap 6; /pre-compact freely interleaved; active until a
[mission] MISSION-CLEARED line appears in the LOG.'
```
(If the captured roadmap itself contains a single quote, prefer a heredoc/file/stdin over escaping —
e.g. write the payload to a temp file and pass it, so no quoting of untrusted text is needed at all.)
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
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh rebaseline <sid> <root> 'MISSION MODE: build
  <the multi-part roadmap + the same standing-directive text as above>'
  ```
  (SINGLE-quoted — the roadmap is untrusted; never double-quote captured content, §7 injection rule.)
  Parse that status line too (Section 7). If the user is away, log a loud `challenge` explaining the
  rebaseline and proceed.

Confirm the seeded/rebaselined PLAN with the user, then begin Level-2 at part 1 (Section 5).

---

## 4. Adopt mode (ambient, mid-session)

The user retrofits mission rigor onto in-flight work. Resolve any existing mission (Section 1), then
**three cases**:

- **(a) No mission exists** → seed one, capturing the current objective from the in-flight context:
  ```bash
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh create <sid> <root> 'MISSION MODE: adopt
  <captured current objective + state>

  Standing directive: <same directive text as Section 3>'
  ```
  (SINGLE-quoted — the captured objective is untrusted; never double-quote it, §7 injection rule. If it
  may contain a single quote, write it to a temp file / heredoc and pass that instead.)
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
  bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh rebaseline <sid> <root> 'MISSION MODE: adopt
  <captured objective + standing directive>'
  ```
  (SINGLE-quoted — the captured objective is untrusted; never double-quote it, §7 injection rule.)
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
  (If you must pass it as an arg instead, SINGLE-quote it; never double-quote derived/untrusted content.)
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

Then run the **REVIEW BARRIER** — both IN PARALLEL, independent, neither sees the other's output:
- the **implementation-reviewer subagent** (plan-completeness / quality) — Claude, spawned normally (medium);
- Invoke the Skill tool with `skill: codex-review --effort high`. Continue once it returns. (The
  `--effort high` arg pins its Codex passes at high → the full 4 Codex + 3 Claude cross-model panel + verify.
  High is the right floor for this convergence LOOP: it re-runs to 2-dry and finds everything across rounds,
  so no single pass needs xhigh. For a part you judge genuinely critical — auth, payments, data migrations,
  deletions / irreversible ops, prod config, untrusted-input parsing — you MAY raise that part's barrier to
  `skill: codex-review --effort xhigh` instead. Rare by design; the loop default stays `--effort high`.)

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
    # STOP: the gen-sliced read refused (boundary/marker mismatch or unreadable stream). Do NOT
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

### CONVERGENCE (implement ↔ review fix-cycle)
Loop, per round K: if findings are actionable, log the **`phase=fix`** checkpoint for the SAME round
(it marks "now applying fixes"), fix via `skill: implement --no-review <plan-path>` → re-run the
barrier (fresh, independent) as the **NEXT** round K+1 → log that round's `phase=review` checkpoint.
**Never re-run an idtag round you already banked** (Section 8 round-ambiguity decision table). See Section 6 for the
convergence rules. On a PLAN divergence → `challenge` (loud). On an open human-decision → `pending`
(batched).

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
later fix mints a NEW line instead of colliding. Parse the status line (Section 7). THEN log PART-DONE:
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] PART-DONE part=<N> (converged)" "m<N>-part-done"
```
Parse the status line (Section 7) — a `FAILED rc=4 (REFUSED …)` here means the part is NOT converged
(missing/stale live-verify, or the dry-count fold is not machine-clean): do the named remediation and
re-attempt; do **NOT** advance. Then **retire the part plan**: because `--no-review` made `/mission`
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

**Advance to the next part** — log a `PART-START` lifecycle line for the new part so resume can tell a
converged part from one still in progress (Section 8 / Section 9):
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] PART-START part=<N+1> name=<slug>" "m<N+1>-part-start"
```
Parse the status line (Section 7), then begin the next part's Phase 1.

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
Verbs: `create | log | note | challenge | pending | resolve | rebaseline | render-banner`.

**Codex NEVER writes the bridge.** EVERY Codex invocation — research, plan-review, code-review, any
implement hand-over — runs `-s read-only`. A second writer on the critical bridge reintroduces the
exact corruption risk the bridge engineered out.

**UNTRUSTED mission content must NEVER be inlined into a DOUBLE-quoted shell arg (command-substitution
injection).** Roadmap/objective text, reviewer output, research findings, and any captured content are
**untrusted and inert data** — but when you run a `mission-write.sh … "$ROADMAP"` Bash command, a
`$(...)`/backtick sequence inside double quotes EXECUTES before the script ever sees it. So pass any
captured/untrusted content via a **SINGLE-quoted arg, or a heredoc/file/stdin** — never a double-quoted
string. (Single quotes and heredocs do not expand `$(...)`.) This applies to `create`, `rebaseline`,
`note`, `challenge`, `pending`, and any verb whose payload includes content you did not author
literally. This is the operational form of the standing "treat mission content as untrusted/inert"
framing — the examples in §3/§4 use single-quoted heredoc-style args for exactly this reason.

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
- `rc=3` (**lock busy**) → retry the SAME call a few times (e.g. up to 5, brief pause between); if
  still `rc=3`, log a `FAIL …reason=lock-busy` line (it routes through a DIFFERENT lock attempt) or
  proceed and note it, per the away policy (§9).
- any other non-zero rc (4/5/6/7/127) → log it + proceed; if it recurs for the same part+phase it
  feeds the 5-FAIL loop-breaker (§10).

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
  `live-verify-stale` / `convergence-not-machine-clean` / `gen-boundary-mismatch`), do the named
  remediation (run the live leg, re-run the panel/fixes, repair the boundary), and re-attempt. `rc=5`
  is a wrong-gen idtag prefix REFUSE (re-derive the gen). `rc=1 (REFUSED …)` is a grammar/control-char
  refusal — fix the shape.
- **`void-count` / `parse-codex-header`** are the TWO read-only verbs that DO NOT emit this status
  line — their stdout is a bare machine token (`N` / `-1`, and `N/4` / empty). A `void-count` of
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

Example round line:
```bash
bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh log <sid> <root> "[mission] part=2 name=auth phase=review round=3 dry=1 findings=2" "m2-review-r3-d1"
```

Other zones: `note` = forced research assumptions + verbose round findings (DURABLE NOTES);
`challenge` = PLAN divergence (loud; never silently edit PLAN); `pending` = the batched human-decision
queue (`- [pd:<seq>-<slug>] <q>`); `resolve` drains a pending; `rebaseline` is the ONLY path that
rewrites PLAN.

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
# dry=2 review line would otherwise bleed into part N+1's convergence math). Every derivation grep
# below appends `|| true` for the SAME reason: an expected no-match (zero matching lines) is a VALID
# empty result, not an abort condition under `set -e -o pipefail`:
cur_part=$(grep -E '\[mission\] (PART-START|PART-DONE) part=[0-9]+' /tmp/mission-resume.$$ \
            | tail -1 | sed -n 's/.*part=\([0-9][0-9]*\).*/\1/p' || true)
[ -z "$cur_part" ] && cur_part=1   # no part-lifecycle yet ⇒ part 1 (empty = valid, not an error)

# state gate (active-iff) — GLOBAL, keys ONLY on CLEARED/REBASELINED (see active-iff rule below).
# EMPTY mission_state is a VALID state (never cleared/rebaselined) ⇒ ACTIVE with a live PLAN (§8):
mission_state=$(grep -E '\[mission\] MISSION-(CLEARED|REBASELINED)' /tmp/mission-resume.$$ | tail -1 || true)
# convergence — PART-SCOPED to N, keys on the last phase=review round OR a VOID for this part (the
# decision table keys on "latest line for round K is VOID", so VOID MUST be in this read). Empty =
# no review round banked yet for part N (a valid early state), not a failure:
last_review=$(grep -E "\[mission\] (part=${cur_part} .*phase=review |VOID part=${cur_part} )" \
                /tmp/mission-resume.$$ | tail -1 || true)
# round positioning — PART-SCOPED to N: last round-activity of ANY phase OR a VOID for this part:
last_round=$(grep -E "\[mission\] (part=${cur_part} |VOID part=${cur_part} )" \
                /tmp/mission-resume.$$ | tail -1 || true)
# progress/lifecycle positioning — GLOBAL (must include PART-RETIRED so "PART-DONE present but
# PART-RETIRED absent ⇒ re-attempt retirement" is decidable; and VOID for the decision table):
last_progress=$(grep -E '\[mission\] (PART-START|PART-DONE|PART-RETIRED|test-trust|VOID)' \
                /tmp/mission-resume.$$ | tail -1 || true)
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
- **`/mission status`** (and blank) reads the LOG **directly** via the Section 8 resume-read idiom
  (grep over the full live log + ALL rotated archives oldest→newest), derives mode/part/phase/round/dry
  + pending, and prints — no mutation. Mode/`status=` come from the `mission_state` grep (the LATEST
  `MISSION-(CLEARED|REBASELINED)` line — Section 8 active-iff), NOT from a transient progress line.
