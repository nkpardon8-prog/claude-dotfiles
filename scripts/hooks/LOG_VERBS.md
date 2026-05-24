# Hook Log Action Verbs (canonical)

Reference for all action verbs emitted by hook scripts. Maintain grep-pattern
stability: do not rename a verb without updating every log consumer + this file.

## auto-compact.log (ac_log — via `lib/auto-compact-sentinel.sh:ac_log`)

Used by `arm-auto-compact.sh` and `auto-compact-after-pre-compact.sh`.

| Verb | Script | Meaning |
|---|---|---|
| `armed` | arm-auto-compact.sh | Sentinel written successfully; target TTY + nonce prefix logged |
| `arm-failed` | arm-auto-compact.sh | Sentinel write failed (disk full or permission error) |
| `disarmed` | arm-auto-compact.sh | Sentinel deleted per user opt-out request |
| `dry-run` | arm-auto-compact.sh | Dry-run mode; sentinel NOT written; would-arm details logged |
| `warn` | arm-auto-compact.sh | Non-fatal warning (e.g., automation-probe-failed-or-timed-out) |
| `stop` | auto-compact-after-pre-compact.sh | Stop hook fired; logs osa_exit + result |
| `abort` | auto-compact-after-pre-compact.sh | Stop hook aborted; no claude in foreground process group |
| `skip-sentinel` | lib/auto-compact-sentinel.sh | Sentinel skipped during read; reason= appended |

### Reasons for skip-sentinel

- `reason=symlink` — sentinel path is a symlink (path-swap defense)
- `reason=oversized` — sentinel exceeds AC_MAX_SENTINEL_BYTES (4096)
- `reason=jq-parse` — jq parse failure; invalid JSON or filter error
- `reason=no-cwd-or-invalid-schema` — cwd field absent or schema_version out of range
- `reason=validate-failed` — _ac_validate_sentinel_path preamble check failed

### handoff: prefix (within auto-compact.log via `handoff_log`)

`handoff_log` delegates to `ac_log` with `handoff:` prefix — no separate log file.

| Verb | Script | Meaning |
|---|---|---|
| `handoff:sentinel_armed` | arm-auto-compact.sh | Arm success; SID8 + TTY + CWD logged |
| `handoff:compact_chained` | auto-compact-after-pre-compact.sh | Stop hook delivered /compact + /post-compact-resume |
| `handoff:session_started` | post-compact-primer.sh | Primer fired; SID + source logged |
| `handoff:handoff_detected` | post-compact-primer.sh | Sentinel matched CWD; SID8 + file logged |

## ctx-gate.log (ctx_gate_log — via `lib/ctx-gate-config.sh:ctx_gate_log`)

Used by `ctx-gate-on-prompt-submit.sh`, `ctx-gate-precompact-safety.sh`, `post-compact-primer.sh`.

### UserPromptSubmit (submit) events

| Action | Script | Condition |
|---|---|---|
| `action=skip reason=no-ctx-sidecar` | ctx-gate-on-prompt-submit.sh | ctx sidecar file missing/unreadable |
| `action=skip reason=sentinel-fresh` | ctx-gate-on-prompt-submit.sh | Sentinel mtime < 1800s (fresh) |
| `action=skip reason=sentinel-stat-failed-assume-fresh` | ctx-gate-on-prompt-submit.sh | stat failed on sentinel; assume fresh |
| `action=reject-symlink-sentinel` | ctx-gate-on-prompt-submit.sh | Sentinel path is a symlink |
| `action=stale-sentinel reason=future-dated-mtime` | ctx-gate-on-prompt-submit.sh | Sentinel mtime in the future |
| `action=soft-nudge` | ctx-gate-on-prompt-submit.sh | PCT in [50, 75) |
| `action=important-nudge` | ctx-gate-on-prompt-submit.sh | PCT in [75, 85) |
| `action=force-wrapup` | ctx-gate-on-prompt-submit.sh | PCT >= 85 |

### PreCompact (precompact) events

| Action | Script | Condition |
|---|---|---|
| `action=allow-sentinel-fresh` | ctx-gate-precompact-safety.sh | Sentinel fresh (<1800s); let native compact proceed |
| `action=stale-sentinel` | ctx-gate-precompact-safety.sh | Sentinel exists but is stale; reenforcing block |
| `action=reject-symlink-sentinel` | ctx-gate-precompact-safety.sh | Sentinel is a symlink |
| `action=release-extreme-pct` | ctx-gate-precompact-safety.sh | PCT >= HANDOFF_AUTOCOMPACT_BYPASS_PCT (90); release native compact |
| `action=block` | ctx-gate-precompact-safety.sh | No sentinel; PCT below release threshold; block native compact |

### SessionStart (primer) events

| Action | Script | Condition |
|---|---|---|
| `action=skip reason=no-handoff-file` | post-compact-primer.sh | No CLAUDE.local.md found in cwd or repo root |
| `action=skip reason=handoff-is-symlink` | post-compact-primer.sh | CLAUDE.local.md is a symlink |
| `action=skip reason=handoff-oversize` | post-compact-primer.sh | Handoff exceeds HANDOFF_MAX_SIZE_BYTES |
| `action=stat-failed-mtime-zero stale-check-skipped` | post-compact-primer.sh | stat returned 0; freshness unknown |
| `action=skip-legacy-sentinel` | post-compact-primer.sh | Sentinel has no cwd field (legacy schema v1) |
| `ANOMALY sentinel-still-present-after-compact` | post-compact-primer.sh | source=compact but sentinel present; Stop hook mv-claim may have failed |
| `sentinel=true\|false marker=true\|false legacy=true\|false age=Ns stale=yes\|no` | post-compact-primer.sh | Final routing decision summary |
