# Changelog

All notable changes to this Claude Code dotfiles repo. Most recent first.

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
