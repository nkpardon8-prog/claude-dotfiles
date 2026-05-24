# Hook Log Action Verbs (canonical)

Reference for all action verbs emitted by hook scripts. Maintain grep-pattern
stability: do not rename a verb without updating every log consumer + this file.

## auto-compact.log (ac_log — via `lib/auto-compact-sentinel.sh:ac_log`)

Used by `arm-auto-compact.sh` and `auto-compact-after-pre-compact.sh`.

| Verb | Script | Meaning |
|---|---|---|
| `armed` | arm-auto-compact.sh | Sentinel written successfully; target TTY + nonce prefix logged |
| `arm-failed` | arm-auto-compact.sh | Sentinel write failed (disk full or permission error) |
| `FATAL` | arm-auto-compact.sh | Fatal error in arm script; nonce generation failed; reason appended |
| `disarmed` | arm-auto-compact.sh | Sentinel deleted per user opt-out request |
| `dry-run` | arm-auto-compact.sh | Dry-run mode; sentinel NOT written; would-arm details logged |
| `warn` | arm-auto-compact.sh | Non-fatal warning (e.g., automation-probe-failed-or-timed-out) |
| `stop` | auto-compact-after-pre-compact.sh | Stop hook fired; logs osa_exit + result |
| `abort` | auto-compact-after-pre-compact.sh | Stop hook aborted; no claude in foreground process group |
| `ac_write_sentinel` | lib/auto-compact-sentinel.sh | Sentinel write skipped in ac_write_sentinel; reason= appended (e.g., oversize) |
| `invalid` | lib/auto-compact-sentinel.sh | Invalid TTY target detected during sentinel validation; raw value logged |
| `test` | test-auto-compact.sh | Test harness log entry (not emitted by production scripts) |
| `skip-sentinel` | lib/auto-compact-sentinel.sh | Sentinel skipped during read; reason= appended |
| `skip-sentinel-nonce` | lib/auto-compact-sentinel.sh | Sentinel nonce field extraction failed; reason=jq-parse appended |

### Reasons for skip-sentinel

- `reason=symlink` — sentinel path is a symlink (path-swap defense)
- `reason=oversized` — sentinel exceeds AC_MAX_SENTINEL_BYTES (4096)
- `reason=jq-parse` — jq parse failure; invalid JSON or filter error
- `reason=no-cwd-or-invalid-schema` — cwd field absent or schema_version out of range
- `reason=validate-failed` — _ac_validate_sentinel_path preamble check failed

### handoff: prefix (within auto-compact.log via `handoff_log`)

`handoff_log` delegates to `ac_log` with `handoff:` prefix — no separate log file.

Note: the G5 grep regex may extract `handoff:$1` from the `handoff_log()` function definition
(`ac_log "handoff:$1"`). This is a function parameter literal, not an emitted verb — it is
documented here to satisfy the G5 drift checker.

| Verb | Script | Meaning |
|---|---|---|
| `handoff:sentinel_armed` | arm-auto-compact.sh | Arm success; SID8 + TTY + CWD logged |
| `handoff:compact_chained` | auto-compact-after-pre-compact.sh | Stop hook delivered /compact + /post-compact-resume |
| `handoff:session_started` | post-compact-primer.sh | Primer fired; SID + source logged |
| `handoff:handoff_detected` | post-compact-primer.sh | Sentinel matched CWD (R4 D6: logged AFTER resolver sets HANDOFF_PATH); SID8 + file + sentinel_present logged |

### Breadcrumb write events (within auto-compact.log)

These verbs are emitted by `auto-compact-after-pre-compact.sh` (Stop hook) during breadcrumb write.

| Verb | Script | Meaning |
|---|---|---|
| `breadcrumb_written` | auto-compact-after-pre-compact.sh | Breadcrumb JSON written to `~/.claude/progress/breadcrumb-<SID>.json` |
| `breadcrumb_write_failed reason=mv` | auto-compact-after-pre-compact.sh | Atomic mv of breadcrumb tempfile failed |
| `breadcrumb_write_failed reason=jq` | auto-compact-after-pre-compact.sh | jq failed to generate breadcrumb JSON |
| `breadcrumb_write_failed reason=empty-sentinel-nonce` | auto-compact-after-pre-compact.sh | Nonce was empty; breadcrumb not written (H8/PR-M2) |
| `breadcrumb_write_failed reason=hostname-fail` | auto-compact-after-pre-compact.sh | hostname -s returned empty; breadcrumb not written (H2) |
| `gc_stale_orphan_breadcrumbs` | auto-compact-after-pre-compact.sh | Stale orphan breadcrumbs (>24h old) deleted on Stop event; count= appended (H12 fix) |

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
| `action=release-pct-unknown` | ctx-gate-precompact-safety.sh | PCT=? (sidecar unreadable); H13 fail-open — release rather than deadlock |
| `action=block` | ctx-gate-precompact-safety.sh | No sentinel; PCT known and below release threshold; block native compact |

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
| `primer skip reason=multi-hardlink` | post-compact-primer-helpers.sh / handoff-resolve.sh | Handoff candidate rejected: hardlink count > 1 (swap-attack defense); path + linkcount logged |
| `primer skip reason=invalid-sentinel-basename` | post-compact-primer-helpers.sh | Sentinel SID contains characters outside `[A-Za-z0-9_-]`; path-traversal defense |
| `primer warn reason=sentinel-without-sid-file` | post-compact-primer.sh | Sentinel present but no SID-tagged file found; advisory warning |
| `primer skip reason=sid-known-no-tagged-file` | post-compact-primer-helpers.sh / handoff-resolve.sh | SID known but no SID-tagged CLAUDE.local.<sid8>.md found; R4 D3 fail-closed |
| `primer skip reason=stat-failed` | handoff-resolve.sh | stat() failed on handoff candidate — cannot verify linkcount; fail-closed (H10 fix-sweep) |
| `step2 skip reason=invalid-sid8` | post-compact-resume-step2.sh | SID8 contains characters outside [A-Za-z0-9_-]; breadcrumb rejected (C5 fix-sweep) |
| `step2 skip reason=invalid-sentinel-sid` | post-compact-resume-step2.sh | Full sentinel SID contains invalid characters; breadcrumb rejected (C5 fix-sweep) |
| `stop_hook_sid_mismatch` | auto-compact-after-pre-compact.sh | Hook-JSON SID and ac_resolve_session_id SID both have sentinels but they differ; ac_resolve path preferred (C2 fix-sweep) |
| `nonce_mismatch_hard_stop` | post-compact-resume-step2.sh | SID known + nonce mismatch detected; hard stop emitted (R4 D4); sid8 + first8 of each nonce logged |
| `sid_mismatch_hard_stop` | post-compact-resume-step2.sh | Marker sid= attribute differs from breadcrumb SID8; cross-track file rejected (C3 fix-sweep) |
| `step2_terminal` | post-compact-resume-step2.sh | step2.sh reached a terminal STATE; state= field names one of: ok, no-handoff, oversize, sid-known-no-tagged-file, sid-mismatch-hard-stop, nonce-mismatch-hard-stop, invalid-handoff-name (H4 fix-sweep; invalid-handoff-name added Theme 5) |
| `handoff_detected` | post-compact-primer.sh | Sentinel matched CWD — see handoff: prefix table above |
