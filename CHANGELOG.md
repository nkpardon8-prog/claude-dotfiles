# Changelog

All notable changes to this Claude Code dotfiles repo. Most recent first.

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
