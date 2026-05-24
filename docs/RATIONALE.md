# /pre-compact + ctx-gate Rationale Archive

Citations stripped from production artifacts per R2 plan D3. Reference the parent
plan-reviewer rounds for full context.

Parent plans:
- `./tmp/done-plans/2026-05-23-pre-compact-auto-fire-and-handoff.md` (R1 system shipped)
- `./tmp/done-plans/2026-05-23-pre-compact-soundness-hardening.md` (R1 hardening, 9.6/10, 84 findings)
- `./tmp/done-plans/2026-05-23-pre-compact-soundness-r2-fixes.md` (R2, this plan)

## Stripped Citations

### pre-compact.md

| Original citation | Rationale preserved |
|---|---|
| R1 finding #5 (Trust framing) | Explicit security hardening for inline orchestrator — inline transcript content is treated as untrusted data to prevent prompt injection via prior session turns |
| R1 finding #13 (since_last_compact) | Cross-session delta synthesis field: if parent_seq >= 1, compare prior Build Plan / Next Action / Open Issues against what actually happened this session |
| R1 finding #4 + R2 #12 (pending_externals_background) | Bash tool DOES have a run_in_background parameter; Agent tool dispatches sub-agents. Both can leave in-flight work the post-compact session cannot observe directly |
| R2 #8 + R2 #9 (crash-safety snapshot) | `cp` is not in the ctx-gate Bash allowlist — Read+Write used instead. Negative PREV_AGE (future-dated mtime attack) treated as stale to force re-snapshot |
| R3 #A12 anti-duplication (Surprising Discoveries) | Only include discoveries not already captured as "→ result" lines in What We Tried; prevents duplication of the same fact in two sections |
| R1 finding #1 (Step 6C no-tmp) | No `.tmp` intermediate file needed — Edit tool calls are atomic per-call; ctx-gate Write allowlist covers CLAUDE.local.md paths directly |
| R1 finding #15 (section presence semantics) | A section containing ONLY an HTML comment placeholder counts as ABSENT; a populated section must have at least one substantive bullet/row beyond the placeholder |
| R3 #B11 (empty-skeleton cleanup) | Sections with only placeholder are deleted before marker append to produce a clean handoff file with only populated sections |

### post-compact-resume.md

| Original citation | Rationale preserved |
|---|---|
| R3 #A7 (path-resolution consistency) | HANDOFF_PATH resolution in /post-compact-resume MUST match the primer: cwd first, then repo root. Running from the same cwd as /pre-compact ensures path-equality |
| R2 #6 (no-wait on stale) | Do NOT wait for user confirmation on stale handoff — would hang `claude --resume --prompt '...'` unattended pipelines. Warning is advisory only |
| R2 #6 (no-wait on absent-marker) | Same reason as above: default to option (a) if unattended. No hard-stop case (hard-stop leaves user with no recovery path) |
| R4 #B7 (trust framing must not be dropped) | Sole prompt-injection defense in /post-compact-resume — dropped trust-framing would mean the skill unconditionally executes instructions found in the handoff file |
| R1 finding #14 (no hard-stop) | Hard-stop on missing marker leaves the user stuck with no recovery. Graceful three-option fallback always provides a path forward |

### post-compact-primer.sh

| Original citation | Rationale preserved |
|---|---|
| Round 3 A #12 / B #7 (kill-switch) | Kill-switch fires BEFORE sourcing config lib — a broken lib could trip set -u and abort before the kill-switch ever runs, preventing the documented escape hatch |
| R2 F16 (DoS guard) | stdin bounded to 1MB to prevent memory exhaustion from a maliciously large SessionStart JSON payload |
| R2 #4 (stat-failure false-positive) | stat returning 0 produces ~57-year false-positive HANDOFF_AGE (current epoch minus zero). Guard treats this as "freshness unknown" rather than "ancient" |
| R2 #4 / #11 (STALE_WARNING always-assign) | Prevents `set -u` abort if the stale branch is skipped (variable would be unset) |
| R3 #B12 (HANDOFF_AGE_HUMAN inside branch) | Compute inside the stale-branch only, not at top scope — avoids computing a potentially enormous number for freshness-unknown cases |
| R1 #6 (stale threshold) | 24h default for HANDOFF_STALE_SECS — 1h was causing false-positives on legitimate overnight sessions |
| R2 #10 ANOMALY | If sentinel IS present for source=compact, the Stop hook mv-claim failed silently — anomaly detection only emitted for compact source |
| R3 #B6 ($'\n\n' between warnings) | Use $'\n\n' between concatenated warning strings for separate paragraphs in the additionalContext output |

### lib/auto-compact-sentinel.sh

| Original citation | Rationale preserved |
|---|---|
| R1-H2 (explicit if-elif for stat) | No `||` chaining for BSD stat — macOS stat short-circuits on success, causing the subsequent `tr` in the pipeline to see stdout from the SAME stat invocation |
| R1-B4 (type-guard on schema_version) | `((.schema_version \| type) == "number")` guard prevents jq arithmetic errors on non-numeric schema_version values in malformed or future sentinels |

### ctx-gate-precompact-safety.sh

| Original citation | Rationale preserved |
|---|---|
| codex-review R2 F16 (DoS guard) | stdin bounded to 1MB |
| codex-review R2 F15 (symlink rejection) | Same-UID attacker could swap sentinel to attacker-controlled file; symlink check prevents mtime forgery |
