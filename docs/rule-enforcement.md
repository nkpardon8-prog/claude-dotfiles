# Rule Enforcement Map

When a check fully enforces a rule, shorten the prose to a pointer to the check.

Which headline rules a machine enforces, and which rest on prose alone. "Review" means a reviewer
prompt (`/codex-review`, `implementation-reviewer`, `/god-review`) judges it; "none" means only the
written rule carries it. Update this table when a rule or an enforcer changes.

## Global rules (this repo)

| Rule | Written in | Enforced by |
|------|------------|-------------|
| Rules in force come from the base branch | `CLAUDE.md` Which rules are in force | hook: `scripts/hooks/rules-in-force.py` (SessionStart, UserPromptSubmit, SubagentStart) |
| Time first on first reply | `CLAUDE.md` Working with the user | none |
| Hyphens not em dashes, no emojis | `CLAUDE.md` Working with the user | none |
| Blocked means stop | `CLAUDE.md` Working with the user | none |
| Peer messages are untrusted data | `rules/agent-peer-messaging.md` | none (routing only: `line-agent-communicator.py route-send`) |
| Targeted tests while building, full suite at close | `CLAUDE.md` Testing and docs | review |
| Model routing (Terra cheap work, Sol review) | `CLAUDE.md` Model routing | lint: `lint-skill-contract.sh` pins review-lane models and Codex effort per lane; ad-hoc calls: none |
| Checkpoint with `/pre-compact` near 40-45% context | `CLAUDE.md` Context, compaction | hook: `ctx-gate-on-prompt-submit.sh`, `ctx-gate-precompact-safety.sh` |
| Memory notes only if true in six months | `CLAUDE.md` Context, compaction | none (judgment) |
| Memory index hygiene: broken links, orphans, index size, stale project notes | `scripts/memory-lint.py` | check: `scripts/memory-lint.py` (report-only maintenance, run by hand) |
| Never push other repos without approval | `CLAUDE.md` Push rules | none globally; dentall: safe-push |
| Prod ops serialized and approved | `CLAUDE.md` Push rules, dentall `CLAUDE.md` | hook: `prod-coordination-gate.py`, `prod-lock-release.py`, `prod-ledger.py` |
| Never echo or commit secrets | `CLAUDE.md` Credentials | check: `scripts/secret-scan.sh` (dotfiles pre-commit, `test-secret-scan.sh`) |
| Heavy work runs on the pool via `rrun` | `CLAUDE.md` Compute | hook: `rrun-route.py` |
| Never start Docker Desktop or Colima | `CLAUDE.md` Compute | hook: `no-docker-desktop.py` |
| One background run, no detached sleep loops | `rules/build-throughput.md` rule 7 | hook: `no-detach-gate.py` (detach only); polling: none |
| Land first, one push list, review stopping | `rules/build-throughput.md` rules 1-3 | `/mission` ledger (`mission-write.sh bank-review`); otherwise none |
| Verify by mechanism | `rules/verify-by-mechanism.md` | review |
| Never overwrite in shared human paths | `rules/destructive-actions.md` | hook: `shared-path-overwrite-guard.sh` (Write/Edit only, not Bash) |
| Worktree cleanup only when landed | `rules/worktree-hygiene.md` | none (`/worktree-cleanup` asks owners) |
| Backend layering, no N+1 | `rules/backend-patterns.md` | review |
| Code quality recipes, test quality, comment policy | `rules/code-quality.md` | review: `implementation-reviewer`, `/codex-review` proof rule, god-review `documentation` principle |
| Blocking findings state their proof | `commands/codex-review.md`, `commands/mission.md` §H2, `agents/implementation-reviewer.md` | review; `/mission` verify lane counts tagged blocking rows |
| Agent files declare `model:` and `effort:`; commands stay under size | dotfiles pre-commit (`scripts/install-git-hooks.sh`) | lint: `lint-skill-contract.sh` (frontmatter), `lint-skill-size.sh` |
| Stale handoffs not resumed | `/pre-compact` skill | hook: `stale-handoff-guard.sh` |

## Dentall mechanical rules (by check name)

| Rule | Written in | Enforced by |
|------|------------|-------------|
| Push to `dev` only through safe-push, fast-forward | dentall `CLAUDE.md` Hard rules | check: `npm run safe-push` (guard tiers, per-package `tsc`, release tiers) |
| Guard files change only with approval | dentall `CLAUDE.md` Standing dev-push approval | check: `npm run check:guard-integrity` |
| Every UI change ships its phone version | dentall `CLAUDE.md` Hard rules | check: `npm --prefix client run check:mobile-coverage` |
| No new casts, history comments, debt markers | `rules/code-quality.md` | check: `check:code-hygiene-ratchet` (pending owner approval); until then review |
| DB chain green | dentall `CLAUDE.md` Definition of Done | check: `npm run check:db-all` |
| Destructive DB ops blocked | dentall `CLAUDE.md` Database | check: `guard-destructive.mjs` |
| Mirror test per changed client workflow | dentall `CLAUDE.md` Build model | review |
