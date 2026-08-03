# scripts/hooks/

Lifecycle hook scripts that cross the Claude/host boundary — distinct from `scripts/progress/`,
which now holds only `on-session-start-cleanup.sh` (GCs stale progress files + pre-compact/
auto-compact sentinels). The old progress-bar subsystem that fed statusline line 2 was removed on
2026-06-18 — line 2 is now a manual per-window `/line` label rendered directly by `statusline.sh`
(see [STATUSLINE.md](../../docs/STATUSLINE.md)).

## What lives here

Several subsystems now share this directory. Auto-compact (documented in full below) was the
first; the rest arrived alongside `/pre-compact`, `/mission`, and the prod-coordination work.

**Registered as Claude Code hooks** (see `settings.json.template` for the exact matchers):

| Script | Hook event | Purpose |
|---|---|---|
| `auto-compact-after-pre-compact.sh` | `Stop` | Fires `/compact` into the originating Terminal tab when `/pre-compact` armed a sentinel. |
| `post-compact-primer.sh` | `SessionStart` (`compact\|resume\|startup\|clear`) | Source-routing primer: resolves the pending SID-tagged handoff and emits session-start navigation. |
| `stale-handoff-guard.sh` | `SessionStart` (after the primer) | Quarantines an un-tagged `CLAUDE.local.md` so a months-old handoff cannot be silently re-ingested. |
| `ctx-gate-on-prompt-submit.sh` | `UserPromptSubmit` | Three-tier context-budget nudge off the statusline's `ctx-<sid>.txt` sidecar. |
| `dotfiles-sync-pause-notice.sh` | `UserPromptSubmit` | Surfaces a HELD/BLOCKED dotfiles auto-sync at the next prompt (the async PostToolUse sync's stderr reaches nobody). |
| `ctx-gate-precompact-safety.sh` | `PreCompact` (matcher `auto`) | Last-resort safety net when native auto-compaction is about to fire without a handoff. |
| `prod-coordination-gate.py` | `PreToolUse` | Serializes prod-mutating ops across parallel Claude instances via `~/.claude/prod.lock`. |
| `prod-ledger.py` | `SessionStart` (`inject`) + `PostToolUse` (`record`) | Shared ledger of prod-facing actions (push / deploy / migrate) so parallel agents know what is already live. |

**Invoked by skills or by hand** (not hook-registered):

| Script | Called by | Purpose |
|---|---|---|
| `arm-auto-compact.sh` | `/pre-compact` Step 9.0 | Writes the auto-compact sentinel. |
| `mission-write.sh` | `/pre-compact`, `/mission` | The ONLY mutator of the on-disk `MISSION.<sid>.*` artifacts; dispatches into `lib/mission-bridge.sh`. |
| `mission-drift-check.sh` | operator, by hand | Read-only report of per-part working-tree drift since each convergence snapshot. Reports; never enforces. |
| `post-compact-resume-step2.sh` | `/post-compact-resume` | Identity-via-arg reader; takes the session id threaded verbatim from the Stop hook. |
| `diagnose-pre-compact.sh` | operator, by hand | Prints hook registration, sentinel, handoff, and recent log state for the `/pre-compact` + ctx-gate system. |
| `uninstall-auto-compact.sh` | operator, by hand | Removes the Stop hook entry and cleans runtime state. |

**Shared code and contracts:**

- `lib/` - shared helpers: `auto-compact-sentinel.sh`, `ctx-gate-config.sh`, `handoff-chain.sh`,
  `handoff-config.sh`, `handoff-locate.sh`, `handoff-marker.sh`, `handoff-resolve.sh`,
  `mission-bridge.sh`, `post-compact-primer-helpers.sh`, `writer-verify.sh`.
- `LOG_VERBS.md` - the canonical registry of every log action verb these scripts emit. It is
  **machine-enforced, in both directions**: `test-ctx-gate.sh` §G5 FAILS if a script emits a verb
  that is not documented here, and also if a verb documented here has no emit site. Adding or
  renaming a log verb means editing `LOG_VERBS.md` in the same change.
- `mission-bridge-assumptions/` and `session-correlation-assumptions/` - hermetic assumption
  suites (each `bash <dir>/run-all.sh`, with per-assumption `.fingerprint.json` files that pin
  the behavior each test depends on).
- `test-*.sh` - per-subsystem harnesses (`test-auto-compact.sh`, `test-ctx-gate.sh`,
  `test-chain-primitives.sh`, `test-mission-bridge.sh`, `test-mission-drift-check.sh`,
  `test-stale-handoff-guard.sh`, `test-handoff-smoke-check.sh`, `test-secret-scan.sh`,
  `test-engine-header.sh`, `test-lint-skill-size.sh`), plus `verify-test-integrity.sh`, which
  checks that each adversarial defense's test actually fails when the defense is removed.

## Auto-compact

Wires `/pre-compact` → automatic `/compact` so the user can run `/pre-compact`, walk away,
and return to a compacted session. Mechanism: per-session JSON sentinel + AppleScript
`do script` (writes to Terminal tab's PTY — no keystroke synthesis, no Accessibility
requirement, only Terminal Automation permission).

### Files

| File | Role |
|---|---|
| `auto-compact-after-pre-compact.sh` | Stop hook (registered in `~/.claude/settings.json`). Consumes a sentinel, verifies `claude` is in the foreground process group on the target TTY, fires `/compact` via AppleScript. |
| `arm-auto-compact.sh` | Invoked by `/pre-compact` Step 9.0. Walks the process tree to find the controlling TTY, sanity-checks the host (Mac/Terminal.app/no tmux), checks the Stop hook is registered in `settings.json` (via `jq`, not `grep`), proactively probes Automation permission with a 2-second alarm, writes a JSON sentinel. Supports `--dry-run` (resolve everything, don't write) and `no-auto-compact` / `--no-auto-compact` / `no auto compact` (skip + disarm prior). |
| `lib/auto-compact-sentinel.sh` | Shared helpers: paths, schema (v1: `schema_version`, `target_tty`, `originating_command` — `armed_at` removed in round 4, mtime is canonical), validation (anchored TTY regex, symlink reject, size guard, schema/originating_command check), bounded log ring at `~/.claude/logs/auto-compact.log` (mode 600). Source-guarded to be safe under double-sourcing. |
| `uninstall-auto-compact.sh` | Removes the Stop hook entry from `settings.json` (via `jq`) and cleans runtime state (sentinels, claim files, log). Soft — leaves source scripts. Re-running `/pre-compact` after uninstall is harmless: arm-script's registration check refuses to write an orphan sentinel. |
| `test-auto-compact.sh` | 37-assertion harness covering: TTY validation, sentinel write/read, symlink/oversized/schema/originating_command/malformed-JSON rejection, AppleScript injection payload, jq-precedence regression, ERE-grep regression, opt-out matcher variants, tmux/non-Apple_Terminal refusal, hook end-to-end with synthetic TTY, concurrent-claim race, idempotent lib source guard, log file mode 600, multi-word `comm` regression (ucomm), `armed_at` removal, `--dry-run` path, skill-prose invocation contract. Run after any change to the lib, hook, or `/pre-compact` Step 9.0. |

### Data layout

- Sentinels: `~/.claude/progress/auto-compact-<session_id>.json` (mode 600)
- Diagnostic log: `~/.claude/logs/auto-compact.log` (mode 600, bounded ring at ~64KB)
- Pruned: stale sentinels + claim files >12h via `scripts/progress/on-session-start-cleanup.sh`

### Running the tests

```sh
~/.claude-dotfiles/scripts/hooks/test-auto-compact.sh
```

All assertions must pass before committing changes to anything in this directory. The
test harness does NOT actually fire `/compact` — it uses synthetic TTYs. Real end-to-end
verification requires running `/pre-compact` and observing the next session compact.

### Threat model + security notes

Same-UID malicious processes (in-Claude tool calls, MCP servers, prompt-injection payloads
with shell access) are NOT in scope — anyone with that level of access can do worse than
forge a sentinel. Defenses target accidental misuse, race conditions, and external
attackers without same-UID access:

- TTY anchored to `^/dev/ttys[0-9]+$` (rejects AppleScript metacharacters)
- TARGET_TTY passed via osascript `argv` (never string-interpolated)
- Sentinels: mode 600, symlink-rejected, size-bounded (4KB), schema-validated
- Atomic `mv` claim prevents double-fire on concurrent Stop events
- Foreground process group check refuses to type if `claude` isn't reading the PTY

### Adding another hook subsystem

Factor any cross-cutting helpers into `lib/`, follow the `ac_*` (auto-compact prefix) → your own
prefix convention to avoid namespace clashes, register the script in `settings.json.template` if
it is hook-driven, add it to the inventory table above, and document every log verb it emits in
`LOG_VERBS.md` (otherwise `test-ctx-gate.sh` §G5 fails). Tests live alongside the code under a
`test-*` prefix.

See `docs/COMMANDS.md` (`/pre-compact` row) and `docs/ARCHITECTURE.md` ("Other lifecycle
hooks") for cross-references.
