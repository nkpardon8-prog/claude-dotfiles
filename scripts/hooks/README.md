# scripts/hooks/

Lifecycle hook scripts that cross the Claude/host boundary — distinct from `scripts/progress/`,
which now holds only `on-session-start-cleanup.sh` (GCs stale progress files + pre-compact/
auto-compact sentinels). The old progress-bar subsystem that fed statusline line 2 was removed on
2026-06-18 — line 2 is now a manual per-window `/line` label rendered directly by `statusline.sh`
(see [STATUSLINE.md](../../docs/STATUSLINE.md)).

Today this directory hosts **one** subsystem: **auto-compact-after-pre-compact**.

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

If you add a second lifecycle hook to this directory, factor any cross-cutting helpers
into `lib/`, follow the `ac_*` (auto-compact prefix) → your own prefix convention to
avoid namespace clashes, and add your README section above. Tests live alongside the
code under a `test-*` prefix.

See `docs/COMMANDS.md` (`/pre-compact` row) and `docs/ARCHITECTURE.md` ("Other lifecycle
hooks") for cross-references.
