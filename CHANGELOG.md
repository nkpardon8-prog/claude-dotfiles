# Changelog

All notable changes to this Claude Code dotfiles repo. Most recent first.

## 2026-08-02 - Parallelizer v1: parallelism made binding, measured, and machine-checked

Parallel execution is now the DEFAULT across the playbook layer, and it is enforced by text the
orchestrator is bound by plus checks that fail closed - not by advice. Read-only fan-out registers
ship on every run; the write-wave machinery ships fail-closed with serial as the universal
fallback everywhere. Built through /discussion -> /plan (5 review rounds: 10 plan-reviewers, 5
criticers, 3 Codex passes) -> /implement, on a plan whose own headline numbers were re-measured
and CORRECTED before implementation started (below).

- **Commands rewritten.** `codex-review.md`: one binding **Launch schedule** block above Step 3 -
  "EXACTLY 6 tool calls in ONE message" (4 Codex lens passes with `run_in_background: true` + 2
  Agent calls), and Step 4 split into **4a** (Architecture + Integration, launched early in that
  same message) and **4b** ("EXACTLY 1 Agent call" - Adversarial + FP-filter, spawned late because
  its FP half consumes the merged Codex findings, which do not exist until 3d). Non-code targets
  get their own "EXACTLY 3 Agent calls" branch. The old "Spawn ALL FOUR Bash calls in a SINGLE
  message" wording is GONE, and its absence is machine-asserted. `plan.md` Step 1 retitled to a
  mandated **research fan-out** ("CRITICAL - research is a parallel fan-out, not orchestrator
  reading: spawn ALL research agents in a SINGLE message") with exactly two named skip exceptions.
  `implement.md` gained a chunk table, a **bounded chunk-parallel register** (chunks whose file
  sets are determinable, pairwise disjoint and hazard-free MUST be spawned in one message; anything
  indeterminable or hazardous is sequential) plus a **post-batch overlap check** that HALTs with the
  batch jointly implicated, and a WAVE GATE + WAVE MODE section below `CONTRACT-CORE-END` - the
  rewrite forced that 20k split, so a post-compaction truncation degrades cleanly to serial.
- **Machinery added.** `agents/parallelizer.md` - advisory-only scheduling subagent (returns a wave
  plan or SERIAL_CORRECT; never implements, never spawns). `docs/wave-plan-schema.md` freezes BOTH
  schemas (wave plan + wave state) as the sole authority. `scripts/parallel-stats.py` (transcript
  instrumentation + `--replay` counterfactuals), `scripts/verify-parallel-wave.mjs` (fail-closed
  checker, 3 modes, one capped machine event per invocation), `scripts/merge-wave.sh` (incremental
  resumable merges recording `merge_sha` per chunk). 26 new hermetic assumption cases across 3
  suites (verify-parallel-wave 15, lint-commands 6, parallel-stats 5), each watched fail first.
- **Guards.** `lint-skill-contract.sh` now carries the register literals for all three commands, a
  `req_before` helper (a register must sit BEFORE `CONTRACT-CORE-END` by first-occurrence CHAR
  offset; fails closed if either is absent), and the ABSENCE check for the retired codex-review
  sentence - and it is **wired into pre-commit** with a new `--staged` mode (ROOT split: file
  locations from `BASH_SOURCE`, staged-set query from `git rev-parse --show-toplevel`, so a linked
  worktree's index is actually visible). `lint-skill-size.sh` Rule-2 + WARN-skip lists extended to
  both rewritten commands. `on-session-start-cleanup.sh` sweeps stale wave worktrees (>7 days,
  breadcrumb-guided `worktree prune` first) and runs a bounded weekly `--replay` (`timeout 45`,
  tmp->mv on success only, completion-marker throttle - a killed run does not suppress the next).
- **Measurement corrections - the headline numbers changed.** Baseline measured over the 10 newest
  top-level transcripts (`tmp/briefs/parallelizer-research/baseline-2026-08-02.txt` in dentall).
  Spawn turns: **47.2% solo** measured vs 54% hand-mined - ACCEPTED (same direction, 6.8pp, inside
  the 10pp band). Codex turns: the hand-mined **91% is retired** - it was a per-JSONL-RECORD
  measurement artifact. The harness writes each tool_use block to its own record, so per-record
  grouping reports 100.0% solo BY CONSTRUCTION (843/843); grouping by `message.id` gives **68.4%
  raw solo (409/598)**, and netting out 210 dependency-flagged report-chained calls that could
  never have been batched gives **34.9% avoidably solo**. Quote 68.4 / 34.9; quote 91 only as the
  corrected artifact. 31.6% of codex turns were ALREADY batched. Wave-gate eligibility: an UPPER
  BOUND of 15 of 31 /implement phases (48.4%) - two conditions (repo_root cleanliness, stale-wave)
  are not recorded in transcripts at all and are credited open, and both only subtract.
- **Thesis checkpoint - v1 addresses a MINORITY of the codex waste, on purpose.** The plan's flagged
  condition was "register-bearing surfaces dominate solo-codex". They do not: **/mission does, at
  62-75%** under both attribution rules tested, while codex-review + master-review account for
  15.2-26.4% (master-review: zero). mission.md surface is explicitly OUT OF SCOPE for v1
  (Divergence 3), so v1's read-only rewrites buy the spawn-side win in full - codex-review is the
  WORST surface for solo spawn turns at 56.5%, above the 47.2% average - plus that minority codex
  slice. The majority remains on a surface v1 deliberately does not touch. Stated, not buried.
- **Probe evidence (it changed the design).** `scripts/parallelizer-assumptions/PROBES.md` in
  dentall: foreground Bash calls issued in ONE message **SERIALIZE** - measured, leg B started
  0.09s after leg A ended (shared shell). Same-message batching alone does NOT parallelize the
  codex passes, which FALSIFIED the Layer-1 premise as originally worded and restored the
  backgrounding decision (Divergence 1): lens passes run `run_in_background: true`, collection is a
  bounded wait on the `.status` sidecars (poll ~20s, ceiling 600s; absent at ceiling = not-usable),
  and `codex-exec.sh`'s own `CODEX_TIMEOUT_SECS=540` graceful self-timeout now matters MORE, since
  the harness timeout's applicability to backgrounded tasks is unproven. A second probe: a subagent
  wrote and committed inside `~/.claude/wave-worktrees/` with ZERO permission prompts, so that
  location is used as planned and no `settings.json` allowlist line is needed from the user.
- **Dry run + dogfood.** The Task-9 wave dry-run drove 2 real chunks through the REAL machinery on
  a throwaway fixture repo and PASSED end to end: worktree adds, two implementer subagents, checker
  green, incremental merge with `merge_sha` recorded per chunk, the fixture's post-integration gate,
  non-force teardown, live events in `~/.claude/parallel-waves/rework.log`, zero permission prompts.
  The SID block resolved the live broker file. Dogfood: this plan's own late tasks were dispatched
  as parallel chunks under the new `implement.md` register - observed, not yet machine-asserted;
  follow-up (2) is that assertion and must run in a FRESH session (symlink liveness is next-session).
- **Codex-surface survey - recorded, NOT applied.** `master-review.md` + `prepare-pr.md` came back
  already compliant (all 5 master-review codex sites are bound by their phase's single-message
  register; prepare-pr's is serial by a real review->fix->re-review data dependency). Zero sites
  qualify for the pattern and lack it, so nothing was changed. Three findings are recorded for a
  later pass: **F1** `master-review.md:256` still reads "Launch ALL 6 simultaneously" while its
  Phase-1 register at `:182` binds 14 - an orchestrator reading the nearer heading could under-batch
  and drop 6 lens agents plus 2 reviewers (minimal fix: retitle to 14; out of this plan's file set).
  **F2** those 5 sites are FOREGROUND Bash, so they are message-batched but do not overlap in wall
  clock - do not read master-review's low solo-codex count as "already fast"; converting them is not
  zero-risk (their inline `codex_invoke` has no `.status` sidecar or self-timeout). **F3** their
  `CODEX_BIN`/`CODEX_HOME_*` vars are derived in a SEPARATE bash fence from the consumers, and Bash
  calls are fresh shells - so those lanes may be silently short-circuiting to `[unavailable]` in ~0s
  (inferred from file structure, NOT from a live run; confirming needs one live master-review).
  Treat any codex turns attributed to master-review as nominal until then.
- **Not touched (decisions):** frontmatter `expected_subagents` left inert everywhere (Divergence
  11); Layer-2 ambient nudge INJECTION stays deferred (Divergence 2 - replay says a nudger at these
  thresholds would have spoken ~250 times across 10 sessions); no `settings.json` edits; no
  mission.md surface; no wave machinery under `--no-review`.
- **NAMED FOLLOW-UPS (not done - these are the honest remainder).**
  1. **Fresh-session effect check** for the codex-review rewrite. Run one real `/codex-review` in
     branch mode in a FRESH session, then: structural check with
     `python3 ~/.claude-dotfiles/scripts/parallel-stats.py <newest transcript>` - the 6 calls must
     share ONE `message.id`; wall-clock check of Step 3 -> Step 5 against the baseline; quality
     check by DIFFING FINDING SETS against the same target run through the pre-change command. A
     DIFF-UNREADABLE or structural failure is fixed first, not accepted. Named revert remedy if a
     real regression shows: `git checkout 80ece6b~1 -- commands/codex-review.md`.
  2. **Fresh-session serial regression** for the `implement.md` register: a 3-chunk
     `/implement --no-review` against the throwaway fixture (cwd = fixture root), asserting
     same-message chunk spawning MACHINE-SIDE via parallel-stats (shared `message.id`), plus the
     gates and the Step 7 shape. Must be a fresh session - never nested inside the run that edited
     the file.
  3. **Weekly replay read-out.** The cleanup hook now accrues this by mechanism; read the first
     auto-written `~/.claude/parallel-waves/replay-latest.txt`, make the Layer-2 enable/discard
     decision from it, and re-confirm Divergence 2 with the user.
  (Also accruing, no action needed: compliance RATE across later unprimed sessions - the lint proves
  the text is present, only repeated sessions prove the behavior.)

## 2026-08-01 - Production cleanup: dead packs removed, contract-first skill restructure, anti-drift additions

Full production defluff of the repo, verified by a 9-agent audit (3 Claude auditors, 6 Codex
transcript verifiers) over the complete retained transcript corpus (4,585 jsonl / 4.4 GB / 19
project dirs). Every removal was zero-usage AND zero-inbound-reference verified. User-approved
keep list honored (afk, claudemd, commit, share-fix, skill-improve, investigate, research-web,
database-audit, checkpoint, master-review - all health-checked, all clean).

- **Removed** (commands/): hybrid/LM-Studio pack (5, hard-broken - target dir absent), minicrew/
  (empty), patterns/ (empty + dead live symlink), fraim, molecular pack (admet/dock/screen/
  optimize/prep-target/dashboard), crm, plan2bid (19), parsa (27), skillset, buildskill,
  architect, learn, tdd, renderdeploy, netlifydeploy, supabase-audit (deprecated alias),
  ui-ux-pro-max (7). All inbound references swept in the same commits (codex-review FRAIM
  excision across 6 regions; generate-codex-layer + skill-improve + docs examples).
- **Archived** (unlisted, kept): gemini/ (broken since 5/30), antigravity.md (built on the
  absent hybrid-control tree), PRECOMPACT-STARTUP-HANG-FIX.md -> `archive/`.
- **Contract-first restructure** of the three compaction-critical skills. Empirical finding:
  invoked-skill bodies are re-injected after EVERY compaction HEAD-TRUNCATED to the first
  20,000 CHARACTERS - mission.md and pre-compact.md were losing their operating contract at
  every boundary. post-compact-resume.md slimmed 25,592 -> 19,997 chars (fits whole);
  mission.md + pre-compact.md gained a self-sufficient CONTRACT CORE ending at a
  `<!-- CONTRACT-CORE-END -->` marker (<=19.5k), full detail below. Cold-read tests (fresh
  agent, 20k slice only): 8/10 both, correct bridge-write line emitted.
- **New guards** (fail-closed): `lint-skill-size.sh` (20k ceiling, chained into pre-commit
  BEFORE the terminal secret-scan exec; 6 fixture tests) + `lint-skill-contract.sh` (durable
  required-literal inventories: 25 allowlisted mission-write invocation lines, banned ~/$HOME
  variants, log grammars, all STATE tokens, all 24 pre-compact step headings).
  `dotfiles-sync.sh` commit failures now LOUD + fail-closed (was silently pushing stale HEAD).
- **Anti-drift additions** (from the openai/codex CLI study): a 4-rule continuation contract
  rendered in every mission banner AND the post-compact primer message (keep the full
  objective; worktree over memory; completion unproven until evidenced; blocked only after 3
  repeats); ctx-gate FORCE message now names the durable surfaces; `handoff-smoke-check.sh`
  (advisory) verifies handoff-referenced paths exist, warning into the handoff itself.
- **Instruction layer:** settings.json.template synced HOOKS-ONLY from live (template
  permission list stays intentionally stricter - note reworded to say so); global CLAUDE.md
  ship-per-tab example + statusline tombstone cleaned; OpenWhip crumb removed from
  settings.local.json. dentall CLAUDE.md/AGENTS.md trailer fix deferred to a patch (repo was
  mid-merge).
- **Purged:** .handoff-archive/, reference/settings.local.snapshot.json, .DS_Store (+
  gitignored). `~/.claude/` junk (9 settings backups, commands.bak/, rules.bak, tmp-codex-r2)
  quarantined to `~/.claude/.trash-20260801/` (NOT deleted); 25 verified-orphan memory
  sidecars moved to `memory/orphans-archive/`.
- **Registry:** docs/COMMANDS.md regenerated from the live command set; Codex mirror
  refreshed via install-codex.sh (88 skills, zero dead names).

## 2026-07-14 — New `/testplan` skill: capability-discovery test-plan generator

Added `/testplan` (`commands/testplan.md`) — a domain-agnostic skill that writes an exhaustive,
production-realistic TEST PLAN for any target (feature / API / CLI / library / worker). It comprehends the
program's role, discovers what it can test with (read-only, deny-by-default — never mutates while planning),
scales coverage to the target's archetype + risk (a small target collapses to a core; a money / PHI /
external-write target gets the full machinery), designs real user journeys + every-order-that-matters
end-to-end, and emits a risk-tiered plan with honest BLOCKED rows and a READY/NOT-READY verdict. It PLANS;
it never executes. Built via `/discussion` → `/plan` → a 2-Claude + 3-Codex-xhigh review round → `/implement`.

- **New:** `commands/testplan.md` — the playbook, with embedded worked micro-examples.
- **New:** `scripts/lint-commands/lint-testplan.sh` — manual pre-commit structural lint (frontmatter, all
  five phases, the tiered self-lint contract, and a domain-agnostic deny-list of project-specific literals).
- **Registry:** `docs/COMMANDS.md` — `/testplan` added under Planning & implementation.

## 2026-07-02 — Codex reasoning-effort floor raised to `high`; heavy audits at `xhigh`

Standardized every Codex (OpenAI Codex CLI, `gpt-5.5`) invocation across the dotfiles on a `high`
reasoning-effort floor, with the heaviest audits escalated to `xhigh`. The model was already
`gpt-5.5` everywhere via `~/.codex/config.toml`; stale "GPT-5.4" labels in skill descriptions/README
were scrubbed to 5.5 (documentation drift, no behavior change).

- **Global default** (`~/.codex/config.toml`): `model_reasoning_effort` `medium` → `high`.
- **`/codex-review`**: `EFFORT` default `medium` → `high` (enforced floor). Escalation to `xhigh` is now
  **dynamic**: an explicit `--effort` from the caller wins (a convergence loop pins `--effort high`), but when
  invoked with no flag the orchestrator self-assesses and reaches for `xhigh` only on genuinely critical,
  one-shot targets (auth, payments, migrations, irreversible / prod, untrusted-input parsing). Values below
  the floor are ignored. `/mission` documents the same escalation option for critical parts of its review loop.
- **`/prepare-pr`**: inline `codex exec` review call now pins `model_reasoning_effort=high`.
- **`/god-review` + `/god-report`**: shared `god-review/lib/codex-invoke.sh` `high` → `xhigh`.
- **`/master-review`**: all Phase 1 + Phase 3 `codex_invoke` calls now pin `model_reasoning_effort=xhigh`.
- **`/ui-audit`** and **`/mission`**: unchanged (stay at `high`).
- Verified `xhigh` is accepted at runtime by Codex v0.142.5 on `gpt-5.5` (smoke test).

## 2026-05-31 — Statusline line 2: live-activity label (fix the perpetual "working" spinner)

After the single-bar rework, line 2 in real sessions sat on a generic spinner + the literal `working`
forever (`15:25  ▱▱▱▰▰▰▱▱  working`). Root cause (verified, not a render bug): the v2 renderer + hooks work,
but agents rarely call TodoWrite (0 calls in recent dentall transcripts), so `overall` never becomes
determinate → spinner + `working`. The to-do list is not a reliable signal in practice.

Fix — drive the line-2 **label** from the live tool stream, decoupled from the bar:
- New `scripts/progress/on-tool-activity.sh` (PostToolUse, most tools) writes a short label —
  `Edit migration.sql`, `Bash: run tests`, `Read foo.ts`, `Grep "pat"`, `Task: reviewer`, MCP last-segment —
  to a **separate sidecar** `~/.claude/progress/<sid>.activity.json` = `{ts,label}`.
- **Separate sidecar (not a shared-JSON RMW)** — like the beacon `<sid>.current.json` — so the async hook
  can't clobber `overall`/`current` or race `on-todo-write`/`on-task-spawn`/`on-stop`. (Plan reviewers'
  central finding; resolved by design rather than locking.)
- Renderer label priority (decoupled from bar): `beacon → live activity → todo activeForm → "working"`. The
  bar still fills from determinate beacon → determinate todos → spinner. Activity is ts-gated
  (`ts >= prompt_started_at`) so a stale sidecar can't bleed into the next turn.
- Matcher **anchored** `^(Edit|MultiEdit|Write|NotebookEdit|Read|Bash|Grep|Glob|WebFetch|WebSearch|Task|mcp__.*)$`
  so `Write` can't substring-match `TodoWrite` under unanchored-regex semantics. `TodoWrite` excluded (ugly
  label, owned by `on-todo-write.sh`); `Task` included (sidecar removes the race).
- Single `python3`, zero `jq`, in the hook (env-var stdin); Bash labels prefer `description` and fall back to
  the command's first token only (no secret leak); `active` is NOT written by the activity hook (no post-Stop
  resurrection). `on-stop.sh` removes both sidecars.
- Both `statusline.sh` copies kept byte-identical. **Requires a Claude Code reload** for the new
  settings.json PostToolUse hook to register (the renderer change is live immediately).
- Reviewed by 2 parallel plan-reviewers; the sidecar redesign came directly from their concurrency findings.
  All render/label gates pass (Edit/Bash-secret-safe/MCP/Task labels, activity-over-spinner, todo-bar+activity
  decoupling, stale-sidecar-ignored, on-stop-removes-sidecar). Docs: PROGRESS-BARS.md, STATUSLINE.md,
  ARCHITECTURE.md updated.

## 2026-05-31 — /mission hardening: drive to a clean cross-model codex-review (8 review rounds)

Closed the confirmed findings from the multi-Codex review of `/mission`, driven through the user's
own methodology: `/script` (5 new assumption tests) → `/implement` → 8 rounds of `/codex-review`
(4 Codex + Claude lenses) with 7 fix rounds, looping to convergence. All CRITICALs resolved by round 2;
rounds 5-8 were the asymptotic self-referential tail on one secondary guard, closed with root-cause fixes.

**New assumption tests** (`scripts/hooks/mission-bridge-assumptions/` 09-13, all green; suite now 13/13):
09 rebaseline reactivates a cleared mission (RED→GREEN proof of CRITICAL #1) · 10 FAIL idtag must be
attempt-scoped (the 5-strike loop-breaker) · 11 mission-write.sh exit-0 + rc=2/rc=3 stdout status parse ·
12 the 480B round-line reroute boundary · 13 resume read survives log rotation.

**`scripts/hooks/lib/mission-bridge.sh`:** `mission_rebaseline` now appends a
`[mission] MISSION-REBASELINED status=active` lifecycle line (empty idtag → never dedup-suppressed) and
propagates the log-append rc instead of swallowing it (so a cleared mission can actually reactivate);
`_mission_log_rotate` skips (doesn't rotate) when the lock is busy, heals a torn last line before the
line-count split, and names archives `…<utc>.<seqNNNN>.XXXXXX` for collision-proof same-second
chronological ordering; `mission_create` returns `rc=2` (the uniform corrupt-bridge code, matching
`mission_mutate`/`mission_rebaseline`) when an existing file fails verify, so a corrupt bridge found
at mission start routes to STOP-LOUD instead of being misread as a generic failure.
`scripts/hooks/mission-write.sh`: REFUSED now emits the parseable `FAILED rc=1 (REFUSED: …)` shape.

**`commands/mission.md`** (the conductor playbook): fix-pending `phase=<review|fix>` round substate;
attempt-scoped FAIL idtag + enumerated FAIL events; parse the `mission-write.sh` status line (rc=2→STOP-LOUD,
rc=3→retry); resume reads grep over (all rotated archives oldest→newest + live log), set-e/pipefail-safe
and space-safe, replacing `tail -n 40`; terse <480B round line (verbose findings → separate note);
active-iff keys only on the latest `MISSION-(CLEARED|REBASELINED)`; a total + mutually-exclusive resume
decision table (completed-part / PART-START-no-round / research·plan·implement / review / fix / VOID);
Codex-unavailable VOIDs the round via a `Codex-passes: 4/4` header token anchored to the canonical
`^Engine:` line; untrusted mission content passed single-quoted / via stdin; PART-START/PART-DONE/
PART-RETIRED advance; away-default + credential/destructive PENDING guard.

**`commands/codex-review.md`:** FRAIM rules reframed as untrusted/inert (no authority to suppress
findings); per-run `mktemp -d` temp dir (no fixed-path clobber); a mandatory machine-readable
`Codex-passes: N/4` header token (mode-aware usable-pass classification — diff-mode = ran-clean,
exec-mode = mandatory `Verdict:` line); both target-summary emission sites forced single-line (no
fake-`Engine:`-header injection).

Gates green throughout: mission-bridge-assumptions 13/13, test-mission-bridge 60/0.

## 2026-05-31 — Bulletproof session correlation: PID-bound /compact delivery + self-driven resume

Fixes a multi-session misfire in the auto-compact pipeline. **Incident (04:42Z):** session `49d80a3a`
armed auto-compact, but the queued `/post-compact-resume 49d80a3a` was typed into a **sibling** session's
tab (`24a704c2`); the R9 `arg-not-my-session` guard refused the wrong-load (safe — no contamination), but
the correct session never auto-resumed. **Root cause:** delivery was bound to `tty` (captured at arm-time,
matched at fire-time only by `tty ==` + a generic "*some* claude is foreground here" check). With many
concurrent sessions + tab churn, `tty` is neither stable nor unique-to-a-session, so the typed commands
landed in the wrong tab. Session *identity* was always solid (Stop hook uses the payload `.session_id`);
the unguarded seam was the *delivery destination*.

The fix extends the session-id principle to that seam, additively (R9, marker-verify, automation probe
all preserved; **bare `/compact` invariant preserved** — distinct from the separate freeze-fix revert):

- **Compact half — PID-bound, own-ancestry delivery.** The Stop hook runs as a direct subprocess of its
  own session's `claude`, so at fire-time it resolves **its own** `claude` PID via an anchored-ERE
  ancestry walk (`ac_resolve_own_claude_pid`, 8-hop, `ps -o args=` — never `ucomm`, the version-string
  trap), derives the tty **live** from that PID, and verifies an identity tuple `{pid + start-time + argv}`
  plus a **PID-pinned** foreground-leader check before typing. The walk climbs only its own ancestry, so it
  can never reach a sibling. The old "any foreground claude on the tty" check (which accepted a sibling's
  claude — the bug) is replaced by the pinned check.
- **Verify-then-claim + TOCTOU re-resolve.** The sentinel is claimed (atomic `mv`) only **after** all
  verification passes — so a pre-fire abort leaves the sentinel intact for the next-Stop retry and the
  pending-handoff primer. The tty/identity is re-resolved immediately before the AppleScript `do script`;
  if it churned (sleep/wake, tab close), the hook restores the sentinel and aborts. Every failure aborts
  **without typing** — never misfire. macOS pid-reuse is defeated by the start-time component.
- **Resume half — self-driven (authoritative) + idempotent.** The SessionStart primer (`source=compact`)
  now makes self-resume the imperative FIRST action: the resumed session — which authoritatively knows it
  is itself — runs `/post-compact-resume <own-sid>` directly, independent of cross-tab delivery. The typed
  cross-tab command is now a redundant backstop. A one-shot `(sid, handoff-nonce)` marker (checked in
  `post-compact-resume-step2.sh` → `STATE=already-resumed`; written by the skill after a real resume) makes
  the self-invoke + backstop double-fire a clean no-op.
- **Proof.** `/script` suite `scripts/hooks/session-correlation-assumptions/` (6/6 PASS) proves the
  load-bearing contracts against the live machine — including the **incident-shape negative** (a sibling
  session's claude PID is rejected on this tty) and AppleScript↔`ps` tty **format parity**. Re-run as the
  regression gate. `test-auto-compact.sh` 78/0, ctx-gate 137/0, mission-bridge 60/0 — no regressions.

Files: `lib/auto-compact-sentinel.sh` (5 new helpers, no schema bump), `auto-compact-after-pre-compact.sh`
(fire-time delivery), `post-compact-primer.sh` (self-resume directive), `post-compact-resume-step2.sh` +
`commands/post-compact-resume.md` (idempotency marker), `test-auto-compact.sh` (units),
`scripts/hooks/session-correlation-assumptions/` (new).

Review-round fixes (impl-reviewer + cross-model Codex, looped to a clean "ship"):
- **Restore-on-fire-failure (codex CRITICAL):** after the sentinel is claimed, a non-`fired*` osascript
  result (no-matching-tab / not-running / error) now restores the sentinel (`mv` claim back) so the
  next Stop retries — previously it was consumed without compacting. `fired+queue-failed` does NOT
  restore (/compact did fire).
- **Test no-fire seam (safety):** the fire path resolves the caller's OWN live claude tty, which made
  the test harness fire `/compact` into the live session. New `AUTO_COMPACT_TEST_NO_FIRE` env (set by
  `test-auto-compact.sh`) runs the full resolve→verify→claim path but skips the osascript — no
  keystrokes. Can only suppress a fire, never cause a wrong-target one.
- **Identity hardening:** `PID_START` must be non-empty (fail-closed); the pre-fire recheck re-runs the
  argv-is-claude predicate alongside tty + start-time + foreground-leader.
- **Idempotency timing:** the one-shot resume marker is written FIRST (before `## Next Action`), and the
  `STATE=ok` matrix entry + Step 4 were reconciled to say so consistently.
- **ctx-gate G5-rev false-positive (unmasked latent test bug):** `[mission]` is the structured
  LOG-line *prefix* written as data via the `log` verb (not a logger/CLI verb), so it has no emit
  site by design; G5-rev now skips it like the other non-verb rows. (Its bare token is a regex
  char-class and BSD `grep -qv` mis-reports exit status on it — the generic probe was unreliable.)
- Gates after fixes: `test-auto-compact.sh` 83/0, ctx-gate 137/0, mission-bridge 60/0, /script 6/6.

## 2026-05-31 — /mission: autonomous long-build conductor (playbook over the bridge)

A new `/mission` conductor that drives a multi-part build to completion across compactions with minimal
human babysitting. It is a **playbook, not an engine**: one new `commands/mission.md` plus a few opt-in
flags — no new state machine, no new daemon. It rides the already-shipped mission-bridge spine
(`mission-write.sh` + `MISSION.<sid>.{md,log,banner}`) and the existing `/pre-compact` → auto-resume path.

- **Playbook, not engine.** Behavior lives in the command prompt; the only code touched is additive flags
  on existing commands. No bespoke orchestration runtime.
- **Two modes.** *Explicit build* (you point `/mission` at a goal/plan) and *ambient adopt* (`/mission`
  latches onto an in-flight build already in progress).
- **Adopt-stickiness via the PLAN, not new state.** Adoption is recorded as an immutable
  `MISSION MODE:` directive inside the PLAN zone. Post-compact-resume already treats the PLAN as binding,
  so the adopted-mission contract survives a compaction with **zero new state code**.
- **Loop-state resume via the bridge LOG.** The conductor reconstructs the exact part/phase/round from the
  `[mission]` LOG lines, leaning on the **idtag-with-`d<D>` anchored idempotency** so a resumed agent lands
  on the precise part/phase/round/dry-count rather than re-running or skipping work.
- **Parallel-but-INDEPENDENT reviewers (barrier-then-merge).** Reviewers run in parallel but judge
  independently; results are merged at a barrier. The impl-reviewer runs ∥ `codex-review`, enabled by the
  new additive **`/implement --no-review`** flag (so the conductor owns review fan-out; default unchanged).
- **Codex-at-high.** New additive **`/codex-review --effort high`** arg for the convergence passes; the
  default effort is unchanged.
- **2-dry convergence judged by INDEPENDENT reviewers, with VOID-on-dead-reviewer.** Two consecutive dry
  rounds close a part — but a hung or empty Codex pass is VOIDed, never banked as a dry round.
- **Durable FAIL guard.** 5 identical `[mission] FAIL …` lines (durable across compactions) → stop loud
  instead of looping.
- **Codex NEVER writes the bridge.** All Codex `-s` invocations are read-only; only the conductor writes
  via `mission-write.sh`.
- **Batched-questions DEFAULT-AWAY in autonomous mode.** The conductor never hangs on a modal; open
  decisions are parked as PENDING DECISIONS for a batched answer next session.
- **Opt-in / heavy** by design.
- Plan-reviewed by 2 independent Claude plan-reviewers (+ a Codex plan-reviewer); ~25 findings folded
  into v2.

## 2026-05-30 — Statusline: line-1 weekly-reset field + line-2 single always-present bar

Two changes, both copies of `statusline.sh` (deployed `~/.claude/` + dotfiles SoT) kept byte-identical.

**Line 1.** Strip the `(1M context)` parenthetical from the model display (the 1M window is assumed) and
add a `wk→<day> <time>` weekly-reset field in the slot it vacated — e.g. `wk→6th 4pm`, derived from the
`anthropic-ratelimit-unified-7d-reset` epoch (`seven_d_reset`) via `date -r` + a pure-bash ordinal suffix.
The `% wk` percentage stays. printf widened from 6 to 7 fields.

**Line 2 — collapse the flaky two-bar renderer into one always-present bar.** Root causes of the old
"random" behavior: (a) a 5-min `last_tick` `sys.exit` failsafe blanked the bars mid-task → flipped to the
old session label; (b) `on-stop.sh` deleted the state file 5s after each prompt → no bar between prompts;
(c) `on-prompt-submit.sh` set the bar label by regex-scraping the first `/…` token from the prompt, which
captured typed **file paths** (e.g. `/migrations/…`) — the "inaccurate" label. Fixes:
- Single bar, source by specificity: determinate beacon → determinate to-dos → indeterminate beacon →
  honest spinner. A bare beacon (emit-beacon defaults total=0) no longer shadows a real to-do bar.
- **Never blank**: renderer prints the session label or `idle` when not active; a hard bash fallback prints
  `idle` even on a python crash / absent file. Line 2 is present in every session/repo from open.
- 5-min failsafe removed → replaced by a 30-min demote-to-idle guard (catches a misfired Stop hook without
  the mid-task vanish or a runaway timer).
- `on-stop.sh` now marks the file `active:false` (atomic `os.replace`) instead of deleting it → no flicker.
- State schema v2 (`active` flag); renderer treats missing `active` (v1 files) as active when
  `prompt_started_at` is fresh, so live sessions don't blink across the upgrade.
- `on-prompt-submit.sh`: dropped the slash-scrape + `outer_command`/`current`/`task_spawns`.
- `on-task-spawn.sh`: stripped to beacon-claim + `last_tick`; removed the spawn-count bar and the
  `expected_subagents` frontmatter glob (that field is now inert — not swept from command frontmatter).
- `on-todo-write.sh`: sets `active:true` defensively. `on-session-start-cleanup.sh` unchanged (no seed —
  the renderer's own `idle` fallback guarantees presence).
- Reviewed by 2 parallel plan-reviewers + meta-pass; 7 render gates pass (line-1 strip+`wk→6th 4pm`,
  active todos, beacon, indeterminate-beacon-doesn't-shadow, idle→label, never-blank→`idle`, stale→idle).
- Docs: `STATUSLINE.md`, `PROGRESS-BARS.md` (rewritten), `ARCHITECTURE.md` hook table updated.

## 2026-05-31 — REVERT: native /compact focus instruction (auto-resume freeze)

Same-day revert of the Task-8b "complementary channels" change from the mission-bridge ship below.
**Incident:** dentall session `fca8c4ab`, the first compaction after the change auto-synced (7:07 PM PDT
/ 02:07Z). The Stop hook fired `/compact <focus instruction>` and typed the queued
`/post-compact-resume` (`fired+queued-resume`, osa_exit=0); compaction finished at 7:09 PM — but the
queued resume **never auto-submitted**, leaving the session frozen on unsubmitted draft text for **27
minutes** until the user re-ran it by hand (7:36 PM, `step2_terminal state=ok`).

**Root cause:** the resume is typed *during* compaction with only a 0.3s `PTY_DELAY` and relies on the
TUI buffering it as next-turn input. Adding a long trailing argument to `/compact` shifts the timing
enough that the resume's Enter intermittently fails to register as a submit. It's a *race the longer
command widens*, not a guaranteed break (session `49d80a3a` fired the same instruction once and resumed
fine) — which is exactly why it slipped past review: **no test asserts the `/compact` do-script text**,
and the Task-14 live pre-flight ("prove the build accepts `/compact <arg>` with the queued resume") was
never run. This freeze WAS that pre-flight, failing.

- **Revert:** `auto-compact-after-pre-compact.sh` fires bare `do script "/compact"` again. Bare /compact
  has resumed cleanly across every logged run. The auto-resume queue is the load-bearing
  overnight-autonomy mechanism and outranks the (nice-to-have) complementary-channels instruction.
- **Guard:** an inline comment forbids re-adding a `/compact` argument without first proving, repeatedly
  in the live build, that the queued resume still auto-submits after it.
- **Not changed:** `PTY_DELAY` stays 0.3s (bare /compact has never frozen; no evidence a bump is needed).
  Tunable via `CTX_GATE_PTY_DELAY_SEC` if a future race appears.
- **Test coverage:** `test-auto-compact.sh` 71/0 (the harness uses a synthetic TTY and does not assert
  the command text — flagged as a coverage gap; the behavior is PTY-timing-dependent and not unit-testable).

## 2026-05-30 — mission-bridge: zero-information-loss durable cross-compaction "mission" spine

The chain primitives (2026-05-27) made compactions near-lossless for the *handoff narrative*, but an
overnight agent still had no durable, append-only place to carry the **standing PLAN, durable notes,
plan-challenges, and pending decisions** verbatim across 5–15 compactions — those lived only in the
volatile handoff prose and degraded with each squash. mission-bridge adds a durable on-disk spine at
the canonical anchor (`dirname(git-common-dir)`, co-located with `CLAUDE.local`): a human-editable
`MISSION.<sid>.md` (fenced PLAN / DURABLE NOTES / PLAN CHALLENGES / PENDING DECISIONS zones), an
append-only `MISSION.<sid>.log` sidecar, and a precomputed `MISSION.<sid>.banner`. It **auto-activates
at chain link >= 2** (the point at which a session has survived its first compaction and continuity
actually matters), is mutated by exactly one allowlisted CLI, and is surfaced to the next session by
the SessionStart primer. #1 priority is ZERO INFORMATION LOSS + fail-LOUD; the feature must NEVER
interrupt the autonomous `/pre-compact` workflow (no permission prompts, no hangs, never abort).

- **The spine.** `lib/mission-bridge.sh` owns the format; `mission-write.sh` is the sole allowlisted
  mutator (byte-locked invocation prefix matched by a `Bash(bash …/mission-write.sh:*)` allow rule, so
  it runs prompt-free under `defaultMode:auto`). Main file carries nonce-qualified zone fences
  (`<!-- MZONE:PLAN n=<nonce8> -->`) and a LOCKED last-line marker
  (`<!-- MISSION schema=v1 sid=<sid> nonce=<uuid> plan_hash=<hex16> -->`) parsed from the LAST match.
  Per-mutation backups land in `.mission-backups/` (pruned to newest 25 + an immutable
  `MISSION.<sid>.birth.md` the prune never deletes).
- **PIVOT A — precompute the banner at WRITE time; the primer does near-zero work.** The original
  design had the SessionStart primer verify+read+cap the mission file, but that hook has a hard **5s
  timeout** and a SIGKILL there emits NOTHING = fail-SILENT (the worst outcome for an info bridge), and
  folding the banner into `BANNER_PREFIX` never reached the no-handoff / rc=1 / cwd-exit paths that emit
  no JSON at all. **Now:** `/pre-compact` (write side, no timeout) renders a tiny bounded
  `MISSION.<sid>.banner` (PLAN slice <= 4000 bytes, line-snapped, + last-5 log lines, pre-capped and
  pre-verified); on a verify failure it writes a LOUD banner, never a silent one. The primer ONLY `cat`s
  that small file and emits it via an explicit `jq -n` on **every** exit path (including the bare
  `exit 0`s — the rc=2 no-sentinel sub-branch, the symlink exit, and the oversize exit). Near-zero primer
  work removes the timeout risk; explicit emit removes the silent-path risk.
- **PIVOT B — LOG sidecar: byte-capped, anchored-idempotent, torn-line-healed, lifecycle-coupled,
  rotating.** The append-only `O_APPEND` log is the hot path and is the zero-loss guarantee (`>>` can
  never lose prior entries the way a read-modify-rewrite of the main file could). But it is hardened:
  each entry is **byte-capped** (not char-capped) to `< 480` bytes (well under PIPE_BUF, with `iconv -c`
  UTF-8 repair) so a concurrent compaction can never tear a record; an oversize entry is rerouted to the
  locked main file rather than risk a torn `> PIPE_BUF` append; idempotency is keyed on a **leading
  anchored** `^<tag>\t` field (not a free `grep -qF`, which a body-quoted id could falsely suppress); the
  log wrapper ensures the main file + manifest pointer exist FIRST (no orphan log); a non-newline last
  byte is healed before append (records never fuse); and the log **rotates** at 256KB into
  `.mission-backups/…log.<utc>.gz` (zero-loss archive, never truncation).
- **Hash is detection-only, not tamper-proof.** `plan_hash` exists to DETECT drift/corruption, not to
  resist a motivated editor. The stream hasher prefers `shasum -a 256`, falls back to `sha256sum`, and
  **fails LOUD if neither exists** (refuses to hash rather than emit something unverifiable); a selftest
  rejects a machine-dependent mismatch. It deliberately **never falls back to `cksum`** (CRC is not a
  cryptographic digest and would give false confidence).
- **"Hand-editing the handoff/mission file is NOT running the skill."** The mission file is
  human-editable, but only the `/pre-compact` skill mines context, appends the ledger, renders the
  banner, and arms auto-compact. The ctx-gate SOFT/IMPORTANT/FORCE nudges now state this explicitly so an
  agent never substitutes a manual edit for the skill run.
- **fail-LOUD is the deliberate exception to ctx-gate's fail-open posture.** Everywhere else in the hook
  system, an unreadable sidecar fails OPEN (stay silent rather than deadlock the agent). For mission-bridge
  the inverse is correct: silent information loss is catastrophic for a continuity bridge, so corruption,
  a missing hash tool, a pointer-set-but-file-missing condition, and a banner verify failure all surface
  LOUDLY (stderr + a CRITICAL banner the primer emits). The CLI still `exit 0`s so the caller is never
  aborted — loudness is in the *content*, not the exit code.
- **Native `/compact` focus instruction (complementary channel) — SHIPPED THEN REVERTED 2026-05-31.**
  Briefly fired `/compact <instruction>` so the model-side summary and disk-side mission spine wouldn't
  duplicate. Reverted same day after a field freeze (see the 2026-05-31 entry above): the trailing
  argument intermittently broke the queued `/post-compact-resume`. Native `/compact` is bare again.
- **Test coverage.** New `test-mission-bridge.sh` (>= 30 tests: marker read from the LAST line; a PLAN
  containing `<!-- MISSION… -->` / `<!-- /MZONE:PLAN -->` / `## ` round-trips nonce-fence-safe; body
  pseudo-marker → loud corruption; multibyte LOG byte-cap `< 512`; anchored idempotency where a
  body-quoted id does NOT suppress a real entry; rotation archives rather than deletes; orphan-lock
  reclaim after a simulated dead pid; merge preserves `mission_path` across a seq bump; recovery
  re-derives it; banner emitted on the no-handoff primer path; pointer-set-file-missing → loud; birth
  backup exists and survives prune). Plus the 8-test `scripts/hooks/mission-bridge-assumptions/` suite
  (`01`–`08`) proving the OS/shell **zero-loss contract** at the substrate level: sub-PIPE_BUF concurrent
  `>>` appends never interleave/tear, marker+zone parse survives adversarial content, lock reclaim after a
  dead holder, mutate atomicity, manifest mission_path write rules, primer emit on every path, append
  after a torn last line, and write-failure surfacing.
- **Rollback.** The feature is purely additive. It only activates at chain link >= 2, so it is inert for
  any single-session (never-compacted) run. To disable entirely: remove `lib/mission-bridge.sh` +
  `mission-write.sh` + the `mission-bridge-assumptions/` suite, and revert the additive
  `.gitignore`-converge and primer-emit hooks (the `MISSION.*` gitignore lines and the guarded
  `MISSION_PREFIX` emit blocks in `post-compact-primer.sh`). No existing behavior changes when the spine
  is absent.

## 2026-05-28 — ctx-gate follow-ups: seam-opportunistic SOFT + stale-broker-after-compact fix + statusline SoT sync

Two field-reported failures from the threshold tuning earlier today, plus a latent landmine found
while debugging the second. All three are coupled: the SOFT fix makes the agent checkpoint more
readily on seam signals, which *amplifies* the harm of a stale-high context reading — so the
broker fix had to ship in the same commit, not after.

- **Part A — seam-opportunistic SOFT (regression fix).** The morning's tuning added an absolute
  "Act only on IMPORTANT or FORCE" clause to the SOFT message (`ctx-gate-on-prompt-submit.sh:111`)
  and the interpretation rule (`commands/pre-compact.md` Rules). It contradicted the same message's
  own seam guidance and, being absolute, won — so an agent at a perfect seam in the SOFT band
  (clean tree, merged PR, about to start heavy work) did NOT checkpoint and pushed into heavy work,
  guaranteeing a forced checkpoint mid-task past FORCE. Root cause: we over-corrected the *repetition*
  complaint (correctly fixed by the 5% rate-limit) with a clause that also killed legitimate
  seam-checkpointing. New SOFT message + interpretation rule are **seam-opportunistic**: don't
  interrupt mid-task, don't surface ctx% as chatter, but checkpoint NOW if at a natural seam —
  including *about to start a large context-heavy task* (the strongest seam: starting heavy work in
  SOFT guarantees crossing FORCE mid-run). Thresholds, rate-limit, FORCE/IMPORTANT messages unchanged.
- **Part B — stale context% after compaction (URGENT, wasted real work).** The ctx broker sidecar
  `~/.claude/progress/ctx-<sid>.txt` is written by the statusline from the harness context-used %,
  and the writer preserves last-known-good on transient empty reads. `/compact` preserves the
  session_id, so post-compaction the same-named sidecar holds the PRE-compaction value until the
  statusline's next render — and the first post-compact `UserPromptSubmit` reads it DETERMINISTICALLY,
  firing a false IMPORTANT/FORCE nudge. Field agent at ~14% real context saw "69% — IMPORTANT",
  trusted it, and prematurely ran `/pre-compact` again with most of the budget free. **Fix:**
  `post-compact-primer.sh` (the SessionStart hook) now deletes the sidecar on `source=compact|clear`
  (the two boundaries where context drops sharply while the sidecar persists), so the reader fails
  open (silent) until a fresh value is written. Deletion — not an mtime-staleness skip — because the
  staleness is **semantic, not temporal**: a fast compact yields a young-but-stale sidecar an mtime
  check would miss; deletion is age-independent. `resume`/`startup` are NOT invalidated (their sidecar
  reflects real current context, or the SID is new). New log verb `handoff:ctx_broker_invalidated`
  registered in `LOG_VERBS.md`. Agent-facing prior added to `templates/CLAUDE.md`: a missing sidecar
  means "context unknown," not high — distrust any high reading on the first post-compact turn.
- **Part C — statusline source-of-truth sync (latent landmine).** Found while debugging Part B: the
  deployed `~/.claude/statusline.sh` contains the ctx-gate broker-write block (added 2026-05-23) but
  the dotfiles source-of-truth `scripts/statusline.sh` was never back-ported (0 `CTX_BROKER` refs vs
  the deployed 8). The repo's source-of-truth was missing the writer the entire ctx-gate system
  depends on — a future manual re-deploy from dotfiles would have silently killed ctx-gate. Block
  back-ported verbatim; `grep -c CTX_BROKER scripts/statusline.sh` now returns 8. Deployed file left
  untouched (it's the working artifact). NOTE: the two statusline files are hand-maintained with no
  automated sync, so this divergence can recur — a deploy/diff-check step is a worthwhile follow-up.
- **Test coverage:** `test-ctx-gate.sh` 135 → 137. New `3d-1` (source=compact deletes stale sidecar →
  subsequent submit silent) and `3d-2` (source=resume PRESERVES sidecar). Test `3c-10` strengthened
  with a regression lock: the SOFT message must contain "act at the next seam" and must NOT contain
  "Act only on" (catches a future revert of Part A). All four harnesses green: **137 / 4 / 71 / 10 = 222/0.**
- **Rollback:** covered by the existing `ctx-thresholds-pre-tuning-2026-05-28` tag (reverts the whole
  2026-05-28 ctx-gate line); `git revert <sha>` for a surgical undo of just this combined ship.

## 2026-05-28 — ctx-gate threshold tuning (50 SOFT / 65 IMPORTANT / 75 FORCE) + 5% bucket rate-limit

LLM accuracy degrades meaningfully past ~70% ctx, but the original 75/85 thresholds put the most
critical wrap-up work in the worst-quality zone of every chain. The chain primitives shipped on
2026-05-27 (`lib/handoff-chain.sh` + per-session ledger + cross-link Decisions/Footguns/What-We-Tried
propagation) made compactions near-lossless, so the cost/quality trade-off shifted in favor of
compacting earlier. This tunes the thresholds and also fixes the cadence problem (one nudge per
user turn was noisy — 30+ identical SOFT pings in a long 50-64% stretch).

- **Threshold tune (50/65/75):** defaults in `scripts/hooks/lib/ctx-gate-config.sh` updated. SOFT
  unchanged at 50%; IMPORTANT 75→65; FORCE 85→75. Override env vars (`CTX_*_PCT_OVERRIDE`) still
  work for tests + manual experimentation.
- **Zone-bucket rate-limit (5%):** `scripts/hooks/ctx-gate-on-prompt-submit.sh` fires SOFT and
  IMPORTANT only when the 5% bucket changes (50/55/60 for SOFT; 65/70 for IMPORTANT). FORCE
  always fires every turn (action-required — persistent reminder is correct). Per-session marker
  at `~/.claude/progress/.ctx-zone-bucket-<sid>`, GC'd by the existing 720-min cleanup glob.
  Handles both forward progress (climbing ctx) and post-compaction reset (silent-zone visit leaves
  marker stale, then lower bucket re-fires).
- **SOFT wording extended:** added self-restraint clauses ("Do NOT interrupt active work; do not
  surface ctx % to the user; do not start /pre-compact in response. Act only on IMPORTANT or
  FORCE.") — codifies the interpretation rule into the message body itself.
- **Interpretation rule:** new paragraph in `commands/pre-compact.md` Rules section locks the
  SOFT-as-FYI semantic across every agent invoking `/pre-compact`. SOFT is observational only;
  IMPORTANT is "at the next natural seam"; FORCE is "immediately, before anything else."
- **Stale-reference sweep:** updated 3 doc rows in `scripts/hooks/LOG_VERBS.md` (PCT-range cells),
  and stale "85%" comments at `ctx-gate-precompact-safety.sh:76`, `lib/handoff-config.sh:29`, and
  the parenthetical comment at `ctx-gate-on-prompt-submit.sh:42`. The `test-ctx-gate.sh` file-header
  comment and the `§2.5 step 6` / `step 1` / `step 7` inline comments were updated to match the new
  threshold model.
- **Measurement next-step:** the chain ledger's `ctx_pct=<%>` field records ctx at every
  `/pre-compact` firing — read `~/.claude/chains/<sid>.log` over the next few sessions to see
  actual firing distribution and decide whether to tighten further (FORCE 75 → 70) or relax.
- **Rollback:** `git reset --hard ctx-thresholds-pre-tuning-2026-05-28` (tag at SHA `a965592`,
  set BEFORE any threshold edits).
- **Test coverage:** `test-ctx-gate.sh` boundary tests `3c-2/3/4` updated (ctx=74→IMPORTANT,
  ctx=75/84→FORCE); existing `3c-8` and `§2.5 step 6` labels corrected ("SOFT suppressed" → "IMPORTANT
  suppressed" since ctx=65 is now IMPORTANT). 5 new bucket-rate-limit regression tests added:
  `3c-9` (bucket-skip-same SOFT), `3c-10` (bucket-fire-on-transition SOFT, asserts full message
  body), `3c-11` (bucket-fire-on-transition IMPORTANT), `3c-12` (FORCE-bypass strengthened: three
  same-bucket invocations all FORCE + marker file MUST NOT exist), `3c-13` (bucket-reset-after-silent-exit:
  asserts marker stays at 14 across a ctx=35 silent visit, then lower bucket=10 re-fires).
- **All harnesses green:** `test-ctx-gate.sh PASS: 135 FAIL: 0` (was 130, +5 new tests),
  `verify-test-integrity.sh PASS: 4 FAIL: 0`, `test-auto-compact.sh PASS: 71 FAIL: 0`,
  `test-chain-primitives.sh PASS: 10 FAIL: 0`. Total **220/0** across all four harnesses.

## 2026-05-27 — `/pre-compact` overnight-autonomy primitives (chain manifest, ledger, banner, halt-advisory)

Layered on top of the same-day canonical-anchor work to give an agent the continuity primitives it
needs to run **overnight** (8+ hours, 5–15 compactions) on a heavy dev workload without losing the
thread. **All primitives are observational** — they surface information, they never gate or refuse
anything the agent/user wants to do. No new sub-commands.

- **New `lib/handoff-chain.sh`** with 4 primitives: `chain_manifest_path`, `chain_manifest_read`
  (validates with `jq -e .`; auto-rebuilds from the ledger on corruption with
  `recovered_from_ledger:true`), `chain_manifest_write` (atomic `tmp+rename`), and
  `chain_ledger_append` (pure `>>`, 9 locked TSV fields, real-tab delimiter via ANSI-C `$'\t'`).
  SID sanitized defensively inside the lib; bash 3.2.57 compatible; no `ctx_gate_log` dependency.
- **Chain state at `~/.claude/chains/<session_id>.{json,log}`** (mode 700). Manifest is slim (9
  fields: chain_id, started_at, north_star, north_star_source, current_seq, last_handoff_path,
  last_heartbeat_at, status, host) — no history arrays (YAGNI). Ledger is append-only TSV, never
  overwritten, includes `north_star_first_120` so the goal survives manifest corruption.
- **`/pre-compact` Step 3.B** resolves the chain manifest (or creates it on first run) inside a
  tolerant subshell (`set +e`) so chain failures never abort the skill. North-star resolution is
  3-tier: `$ARGUMENTS` (minus pass flags) → most-recent fresh brief at
  `$CANONICAL_ROOT/tmp/briefs/` with `## Direction` (falls through on multi-brief near-tie within
  6h to avoid guessing) → agent-supplied from the in-flight `## Active Task` extraction. Verbatim
  string cached at chain birth (no `<pending…>` placeholder ever).
- **`/pre-compact` Step 4.G** runs a narrow halt-advisory detector over the visible transcript
  (window-scoped to turns dated > `last_heartbeat_at`, excluding sub-agent tool outputs and the
  skill's own bash). Trips only on: same-cmd+same-error 5× with no commit AND no file edit; 2+
  permission denials on the same tool; self-emitted "I cannot proceed" + 3 unresolved turns; or
  3+ consecutive same-class API errors. **Never trips on iterative debugging** (any file edit
  between failures = healthy work). Output is two env vars the Step 3.B block reads; the next
  handoff opens with a `## Halt Advisory` block (informational, agent has full agency).
- **Halt auto-clear, locked semantics**: clears iff the visible transcript has a turn with
  `role:user` AND timestamp > halt timestamp AND body is NOT the bare `/pre-compact` invocation.
  Agent self-talk never clears halt.
- **`/pre-compact` Step 6A** prepends `## Chain Status` to every handoff (chain id 8-char prefix,
  started_at, elapsed, link N, north star verbatim, current active task, last 5 ledger entries —
  so drift between original goal and current direction is always visible). When halt is set,
  `## Halt Advisory` goes above it. Decisions + Footguns propagate cross-link additively (caps 40
  / 30, drop oldest low-confidence/oldest first); What We Tried bounded at 20 with asymmetric
  retention (preserve all `abandoned because <reason>` and footgun entries; drop oldest `kept`).
  Propagation marker `<!-- propagation-boundary v1 -->` in the template delimits parent-carried
  from this-session entries.
- **SessionStart primer** sources the chain lib and prepends a one-line banner
  (`Chain <id8> | Link <N> | Elapsed <Hh Mm> | Goal: <80c> | Status: <s>`) to ALL three
  `additionalContext` emissions (the rc=2 missing-file warning, rc=3 hardlink warning, and main
  case). Heartbeat staleness >90min appends a "verify a resume wasn't missed" advisory. Bash-side
  `date` arithmetic (BSD-first, GNU fallback) so the elapsed math doesn't depend on jq's
  `fromdateiso8601`; negative elapsed clamped at 0; `HEARTBEAT_AGE` sanitized to int.
- **What was deliberately NOT built**: no `/pre-compact unhalt` or `/pre-compact set-goal`
  sub-commands (overconstraint per user); no code-enforced north_star immutability (soft, doc-only);
  no sub-agent context detection (the `[ -t 0 ]` heuristic is non-functional in the Bash-tool
  subprocess, and sub-agents share session_id so an extra manifest update would be a benign noop
  anyway); no cross-platform resume (Mac/Terminal.app workflow unchanged); no predictive 75%-ctx
  auto-fire (the existing PreCompact safety-net is the trigger).
- All three existing test harnesses still pass with 0 FAIL (test-ctx-gate 130, integrity 4,
  auto-compact 71); chain primitives smoke (round-trip, ledger append, corrupt-recover, tab
  delimiter, sanitization) all green.

## 2026-05-27 — `/pre-compact` canonical-anchor, concurrency-safe, cwd-invariant handoff resolution

Fixed a real **wrong-load**: `/pre-compact` could adopt a *foreign chain's* handoff as its parent
when the SID-tagged file lived in a different worktree than cwd and an mtime fallback then grabbed the
newest `CLAUDE.local.*.md`. Hardened the whole writer/reader location + identity model so any agent,
in any worktree/cwd, can run `/pre-compact` concurrently and repeatedly — "it just works."

- **Canonical anchor** (`lib/handoff-locate.sh`, new): the handoff always lives at
  `dirname(git-common-dir)` — the repo's main working root, identical from every worktree — resolved
  with a common-dir identity round-trip cross-check (→ `show-toplevel` → `pwd` fallback). `CANONICAL_ROOT`
  is resolved once in Step 3.B and persisted in the SID scratch; Steps 6A/6D/8, the `.prev` snapshot,
  and the paste/migration prose READ it back (no per-subprocess re-derivation → no drift).
- **Parent = marker-sid only:** Step 3.B accepts a parent ONLY when the canonical-anchor
  `CLAUDE.local.<MY_SID>.md` carries an END-OF-HANDOFF marker whose `sid=` equals this session.
  **The mtime fallback is deleted** — mtime never selects a parent. No match → seq 1.
- **Reader (`lib/handoff-resolve.sh`):** probes cwd → show-toplevel → canonical anchor (deduped by
  physical path), marker-bound and fail-closed per candidate; rc=3 (hardlink) only when the
  *marker-matching* candidate is hardlinked. No worktree enumeration (the anchor subsumes it). The
  SID-unknown legacy alias path is deliberately NOT broadened.
- **Single marker-SID extractor** (`_resolver_extract_marker_sid`) moved to `handoff-locate.sh` and
  shared by the reader, `writer-verify.sh`, and the writer's Step 3.B (no duplicate, first-occurrence
  anchored).
- **Concurrent `.gitignore`:** atomic `mkdir` lock under the shared git-common-dir + idempotent
  re-grep converge (the converge is the correctness guarantee; `flock` avoided — absent on macOS).
- Resolution failures degrade to refuse / `no-handoff`, never wrong-load. All three test harnesses
  green (ctx-gate 130, integrity 4, auto-compact 71); canonical-root agreement proven across a linked
  worktree end-to-end.

## 2026-05-26 — Assumption tests (`/script` overhaul) + always-on `/plan` assessment

Reworked `/script` and wired it into `/plan` as an always-considered (but never forced) step.

- **`/plan` Step 5** now ALWAYS emits a visible assumption-test assessment line in one of three states — candidates surfaced (→ run `/script`), zero surfaced (explicit skip + reason), or unavailable (degraded reviewer path). The decision is now a reviewable artifact, not a silent omission. It never auto-generates tests.
- **`plan-reviewer`** now ALWAYS emits the `## Assumption-Test Candidates` section (was gated on ≥3 findings); emits `_None surfaced_` when empty. Parallel reviewers' sections are unioned in the merge step.
- **Rename:** "smoke scripts" → **assumption tests** throughout (`/script`, `plan.md`, `plan-reviewer.md`); tag `[SMOKE-CANDIDATE]` → `[ASSUMPTION-TEST]`; output dir `scripts/<feature>-smoke/` → `scripts/<feature>-assumptions/`. These are kept *learning tests*, not broad-and-shallow "smoke tests" and not disposable "spikes". (Safety env-gate var names keep `_SMOKE_ALLOW_` deliberately — they mirror real per-project conventions.)
- **New trust discipline in `/script`:** rule 9 **negative control** (prove each test goes RED when the assumption is false; synthetic-injection escape for infra-fixed contracts); rule 10 scoped **environment fingerprint** for drift detection; **startup orphan-reaper** (stable namespace marker + age) alongside per-run-UUID cleanup; softened the cleanup STOP rule to allow un-rollback-able side effects via tag-and-reap + disposability check; `run-all.sh` hardened with `set -uo pipefail` + `timeout 60` + 124→3 remap; read-only default for FOUNDATION probes.
- **Always-on adversarial catalog review** (Step 3.5) before writing tests — runs in parallel with directory/run-all/README scaffolding; uses a self-contained prompt. `expected_subagents` bumped to 2.
- **Expanded risk lenses:** added TIME/ORDERING, SECURITY/ISOLATION, MIGRATION/CONSISTENCY, VALUE-DOMAIN/ENCODING, and split out production OBSERVABILITY; reframed as a generative checklist, not a partition. Optional single thin-integration test for composition coverage.
- **Split:** the risk-lens catalog, A3 worked example, and anti-patterns moved out of the command into new `docs/script-reference.md` to keep `/script` lean. `/script` now documented in `docs/COMMANDS.md` (was absent).

## 2026-05-13 — Auto-compact after `/pre-compact`

Added a Stop hook (`scripts/hooks/auto-compact-after-pre-compact.sh`) that fires
`/compact` into the originating Terminal.app tab after `/pre-compact` finishes,
so the user can run `/pre-compact`, walk away, and return to a compacted session.

- **Arming** lives in `scripts/hooks/arm-auto-compact.sh`, called from `/pre-compact`
  Step 9.0. Writes a per-session JSON sentinel at `~/.claude/progress/auto-compact-<sid>.json`
  containing `schema_version`, `target_tty`, `originating_command`. Filesystem mtime
  is the source of truth for arming-time (used by the >12h prune).
- **Firing** uses AppleScript `do script "/compact" in foundTab` — writes to the tab's
  PTY input, not a System Events keystroke. No focus race, no Accessibility requirement,
  only Terminal Automation permission (auto-prompted on first use).
- **Hardening:** anchored TTY regex; argv-passed osascript (no string interpolation);
  symlink-rejected, size-bounded, schema-validated sentinels; atomic `mv` claim
  prevents double-fire; foreground-process check (`ucomm`-based) refuses to type if
  `claude` isn't in the foreground process group of the target TTY; jq-based settings
  registration check guards against post-uninstall orphan sentinels; perl-alarm timeout
  on the first-run Automation probe so /pre-compact never hangs.
- **Platform guard:** refuses to arm on non-Darwin, non-Terminal.app, tmux, screen.
- **Opt-out:** `no-auto-compact` / `--no-auto-compact` / `no auto compact` skips arming
  and disarms any prior sentinel from the same session.
- **Dry-run:** `--dry-run` resolves the full pipeline (TTY + session id + guards) and
  reports what WOULD be armed, without writing a sentinel.
- **Diagnostics:** `~/.claude/logs/auto-compact.log` (mode 600, bounded ring at ~64KB).
- **Uninstall:** `scripts/hooks/uninstall-auto-compact.sh`.
- **Tests:** `scripts/hooks/test-auto-compact.sh` covers AppleScript injection,
  symlink, schema, double-fire, oversized payload, jq operator-precedence regression,
  ERE-grep regression, opt-out matchers, tmux/non-Apple_Terminal refusals, concurrent
  claim race, idempotent lib source guard, log file mode 600, multi-word `comm`
  brittleness, and the skill-prose invocation contract.
- Shared lib at `scripts/hooks/lib/auto-compact-sentinel.sh` — single source of truth for
  sentinel paths, schema, validation.

## 2026-05-06 — Per-Session Statusline Label

Added a dimmed second line to the statusline (`scripts/statusline.sh`) sourced
from `~/.claude/session-status/<session_id>.txt`. Lets the user tell apart
5–10 simultaneous Claude Code windows by `Client › Project › current work` at
a glance.

### Added
- **`scripts/statusline.sh` § 7**: optional line 2 reads the per-session label
  file, sanitizes session_id with `tr -cd 'A-Za-z0-9_-'` (path-traversal safe),
  and truncates to 100 code points via Python (Unicode-aware, so multi-byte
  chevrons survive). Line 2 is omitted entirely when the file is missing.
- **`CLAUDE.md` § Per-Session Status Label**: behavioral rule telling Claude
  when and how to write the label file. Discovers session_id via the most
  recently modified `~/.claude/projects/<encoded-pwd>/*.jsonl` (the
  `$CLAUDE_SESSION_ID` env var is documented as not reliably exposed to the
  Bash tool).
- **`~/.claude/session-status/`**: new local directory (mode 700) that holds
  one `<session_id>.txt` file per active window. Not tracked in this repo —
  contents are session-scoped and may include client names.

### Format
```
Client › Project › what's happening right now
```
Chevron `›` separator, single space each side, ≤ 100 chars. Use `Internal`
for self/team work, `Self` for personal, repo name when no codename exists.

### Plan archive
See `tmp/done-plans/2026-05-05-per-session-statusline-label.md` (in the
TOOLS workspace, not this repo) for the full design + 13-finding review trail.

## 2026-04-30 — Master Rebuild

A 7-phase rebuild that decontaminated the repo of project-specific assumptions
("estim8r" lock-in, hardcoded `/Users/nickpardon/` paths, foreign-codebase
references) while preserving every team-built skill verbatim. Validated against
4 plan-reviewer passes (41 recommendations all incorporated).

### Removed (project lock-in)

- **`~/.claude/settings.json`**: stripped 50+ estim8r-specific entries
  (`/Users/omidzahrai/Desktop/CODE/estim8 recent/` paths, `backend.*` module
  allowlist for trade_extraction/material_pricing/etc., hardcoded ports
  `localhost:5174/8000/3001`, `/tmp/estim8r_jobs.json` job ID). Replaced with
  minimal generic permissions.
- **`commands/master-review.md`**: replaced 6 hardcoded
  `/Users/nickpardon/claude-hybrid-control/` paths with
  `${CLAUDE_HYBRID_CONTROL_HOME:-$HOME/claude-hybrid-control}` env var.
  Replaced 5 inline Codex CLI calls with portable `codex_invoke()` wrappers
  that auto-rotate `CODEX_HOME` profiles. Replaced `localhost:8080` page-list
  with project dev-server discovery.
- **`commands/antigravity.md`**: replaced 7 hardcoded `/Users/nickpardon/`
  paths with the same `CLAUDE_HYBRID_CONTROL_HOME` env var.
- **`commands/renderdeploy.md`**: replaced 4 `estim8r-api`/`estim8r-app`
  example references with generic `myapp-api`/`myapp-web`.
- **`agents/{codebase-explorer,implementer,implementation-reviewer,plan-reviewer,researcher}.md`**:
  REPLACED wholesale with `dcouple/Pane` upstream versions to eliminate
  estim8r-flavored review prompts (e.g. `plan-reviewer.md:31` previously read
  *"Are all 14 trades handled? (electrical, plumbing, hvac, ...)"* — now reads
  *"Completeness — Are there gaps? Missing error handling, edge cases..."*).
  Git history confirmed the user had not modified these files; the content
  was inherited estim8r-flavored from the original fork.
- **`commands/parsa/cl/*` (7 files)**: deleted. These were HumanLayer
  foreign-codebase prompts not actually used by the team.
- **`commands/parsa/review/principles/architecture-backend.md`** + **`all.md`** +
  **`documentation.md`**: generalized `authenticatedHandler`/`BaseService`/
  `ApiError` from hardcoded pattern names to project-specific patterns the
  reviewer must discover before flagging violations.
- **`CLAUDE.md` routing table**: removed 7 `parsa:cl:*` phantom skill entries.

### Added (Pane upstream gems + new lens agents)

- **`agents/research-dossier-writer.md`**: imported from Pane. PRP-style
  research dossier sub-agent used by the new `/plan` 3-artifact pipeline.
- **`commands/share-fix.md`**: imported from Pane. After shipping a fix, draft
  human-sounding GitHub issue comments for ecosystem reach-out.
- **`commands/plan_base.md`**: replaced with Pane's evidence-contract template
  (Verified Repo Truths with `Fact:`/`Evidence:`/`Implication:` shape).
- **`settings.json.template`**: NEW teammate-shareable baseline at
  `~/.claude-dotfiles/settings.json.template`. (`~/.claude/settings.json` is
  per-machine and not tracked in this repo, so the template is the
  shareable baseline for fresh setups.)
- **`agents/lens-{single-pattern,circular-deps,tanstack-query,architecture-frontend,architecture-backend,self-contained}.md`**:
  6 new specialized review lens agents wired into `master-review.md`.
  - `lens-single-pattern` and `lens-circular-deps` are **always-on** (run in
    Phase 1 + every Phase 3 verification round).
  - The other 4 are **stack-gated** (run in Phase 1 only when the matching
    `HAS_TANSTACK_QUERY`/`HAS_APP_ROUTER`/`HAS_AUTHED_HANDLER`/`HAS_UI_PROJECT`
    detection signal is non-empty). Each lens self-gates in its own prompt
    and returns `(skipped — pattern not detected)` when the signal is empty.

### Changed (skill MERGEs with Pane upstream patterns)

For each, the team's additions were enumerated first, then synthesized onto
Pane's structure:

- **`commands/plan.md`**: adopted Pane's 6-step pipeline (Mandatory Repo Audit
  → Clarify → External Research → Draft 3 artifacts → Reconcile → Save → Review
  with dual Claude+Codex lanes → Return). Preserved team's Step 0 discussion-
  brief loading from `./tmp/briefs/`.
- **`commands/simple-plan.md`**: adopted Pane's primary-implementer rule and
  dual-lane review with Codex fallback.
- **`commands/implement.md`**: adopted Pane's executor resolution
  (Claude/Codex), parallel review gates (Claude `implementation-reviewer` plus
  two direct `codex exec -s read-only --ephemeral` calls — one straight review,
  one adversarial — when `command -v codex` succeeds; the project-wide
  `/codex-review` skill remains the user-facing entry point), and Step 5.5
  schema migration handling. Replaced Drizzle-specific `npm run db:diff:dev`
  and `npx nx build` with stack-detection language.
- **`commands/prepare-pr.md`**: added Pane's Step 2.5 (production schema
  migration SQL with stack-detection) and Pre-Merge Testing + Schema Changes
  PR template sections. Made the Codex review loop conditional on
  `command -v codex`. Kept team's existing stack-detection build commands.
- **`commands/commit.md`**: left untouched in this rebuild — the team's
  confirmation step is a deliberate divergence from Pane's autonomous
  behavior, so `commit.md` is unchanged in `pre-rebuild-2026-04-30..HEAD`.

### Master review pipeline

- **Phase 0c** now sets stack detection vars (`HAS_TANSTACK_QUERY`,
  `HAS_APP_ROUTER`, `HAS_AUTHED_HANDLER`, `HAS_UI_PROJECT`) for downstream
  lens agents. Detection vars are re-set inline in Phase 3b because
  markdown bash fences don't share scope.
- **Phase 1** now spawns up to 14 agents in parallel: 3 Claude Opus + 3
  Codex + 2 Antigravity reviewers + 6 lens agents (2 always-on + 4
  stack-gated). Each lens spawn is unconditional; gated lenses self-skip
  in their own prompt body.
- **Phase 2** (synthesis) collects lens-agent return values via
  `$LENS_FINDINGS` and tags each merged finding with the originating agents.
  Cross-source matches (reviewer + lens) automatically promote confidence.
- **Phase 3** (verification loop) spawns the 6 reviewer agents + 2
  always-on lens agents per round.

### Preservation guarantees (verified byte-equivalent vs `pre-rebuild-2026-04-30` snapshot)

- `commands/plan2bid/` (16 files) — construction estimation suite, used in
  another repo
- `commands/ui-ux-pro-max/` — UI/UX design suite (50+ styles, 161 palettes,
  shadcn/ui MCP integration)
- `commands/macmini/` — Chrome Remote Desktop control via chrome-devtools MCP
- `commands/dock.md`, `screen.md`, `admet.md`, `optimize.md`, `prep-target.md`,
  `dashboard.md` — MoleCopilot drug discovery suite
- All `fraim → ...` job entries
- MoleCopilot, FRAIM, and Next.js sections in `CLAUDE.md` (left untouched per
  user direction)

### Snapshot tag for rollback

`pre-rebuild-2026-04-30` — the pre-rebuild HEAD. Use
`git reset --hard pre-rebuild-2026-04-30` to revert if needed.

### Branch strategy

Work landed on `dotfiles-rebuild`. The `~/.claude/` PostToolUse auto-sync hook
was disabled for the rebuild duration via `~/.claude/.rebuild-sentinel`.
Re-enable the hook + clear the sentinel after squash-merging to `main`.

---
