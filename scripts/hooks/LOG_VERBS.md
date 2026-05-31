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
| `handoff:ctx_broker_invalidated` | post-compact-primer.sh | Stale-broker guard: ctx-<sid>.txt sidecar deleted at a compact/clear boundary so the first post-event UserPromptSubmit doesn't read a stale-high ctx%; SID + source logged |
| `handoff:handoff_detected` | post-compact-primer.sh | Sentinel matched CWD (R4 D6: logged AFTER resolver sets HANDOFF_PATH); SID8 + file + sentinel_present logged |

### Migration residue GC events (within auto-compact.log)

These verbs are emitted by `auto-compact-after-pre-compact.sh` (Stop hook) during GC.
R8: breadcrumb-write block removed (identity-via-arg — no breadcrumbs written under R8).
The GC below sweeps pre-R8 breadcrumbs and session-key files from in-flight sessions.

| Verb | Script | Meaning |
|---|---|---|
| `gc_stale_orphan_breadcrumbs` | auto-compact-after-pre-compact.sh | Stale orphan breadcrumbs (>24h old) deleted on Stop event; count= appended (V2-11 migration sweep) |

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
| `action=soft-nudge` | ctx-gate-on-prompt-submit.sh | PCT in [50, 65) (rate-limited to 5% bucket transitions) |
| `action=important-nudge` | ctx-gate-on-prompt-submit.sh | PCT in [65, 75) (rate-limited to 5% bucket transitions) |
| `action=force-wrapup` | ctx-gate-on-prompt-submit.sh | PCT >= 75 (always fires; no rate-limit) |
| `action=skip reason=same-bucket-as-last` | ctx-gate-on-prompt-submit.sh | SOFT/IMPORTANT zone but bucket unchanged since last fire (rate-limit suppression) |

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
| `primer warn reason=multi-marker-detected` | post-compact-primer-helpers.sh (primer_check_marker) | RQ-07 (R6 HZ-34): handoff file has more than one canonical END-OF-HANDOFF marker at column 0; MARKER_PRESENT set to "tampered"; primer emits distinct tamper warning |
| `primer skip reason=sid-known-no-tagged-file` | post-compact-primer-helpers.sh / handoff-resolve.sh | SID known but no SID-tagged CLAUDE.local.<sid8>.md found; R4 D3 fail-closed |
| `primer skip reason=resolver-marker-sid-mismatch sid8=<sid8> marker_sid=<observed> file=<path>` | handoff-resolve.sh | R7-INC-02 (F2): SID-tagged file marker content-check failed — file's marker sid= does not match requested sid8; cross-track file rejected |
| `primer skip reason=resolver-sid-tagged-no-marker session_id=<id> file=<path>` | handoff-resolve.sh | R9-R2 (HIGH-1 fail-closed): a SID-tagged file with NO END-OF-HANDOFF marker is NEVER accepted (regardless of mtime) — markerless files cannot be identity-verified. Replaces the former `resolver-no-marker-non-legacy` mtime-gated verb; legacy-mtime tolerance now applies only to the SID-unknown alias path |
| ~~`alias-with-marker-match` / `alias-marker-mismatch` / `alias-future-mtime`~~ | handoff-resolve.sh | **[R8/R9: DELETED — these F4 alias-probe verbs are NO LONGER EMITTED.** The F4 alias-with-marker-binding probe (Defense H12) was removed in R8 V2-6: with full-UUID filenames + identity-via-arg there is no alias path for a known session_id (the resolver returns rc=2 instead). Retained as a tombstone so a grep-based consumer does not expect these verbs.] |
| `primer skip reason=stat-failed` | handoff-resolve.sh | stat() failed on handoff candidate — cannot verify linkcount; fail-closed (H10 fix-sweep) |
| `step2_terminal` | post-compact-resume-step2.sh | step2.sh reached a terminal STATE; R8/R9 state= field names one of: ok, no-handoff, no-session-arg, invalid-session-arg, arg-not-my-session, self-unverifiable, oversize, sid-known-hardlinked, invalid-handoff-name, handoff-mutated-mid-read, multi-marker-detected, snapshot-failed |
| `step2 r9_self_check ok` | post-compact-resume-step2.sh | R9-R2 observability: the consumer-layer arg-vs-self check ran AND passed (self==arg); distinguishes a double-checked STATE=ok from a degraded one |
| `handoff_detected` | post-compact-primer.sh | Sentinel matched CWD — see handoff: prefix table above |
| `handoff_mutated_mid_read` | post-compact-resume-step2.sh | Handoff file ino:dev:size changed between snapshot and final emit — file was mutated mid-pipeline (e.g., auto-sync swap). STATE=handoff-mutated-mid-read emitted; ingestion refused |
| `primer_sentinel_bind` | post-compact-primer-helpers.sh (primer_find_sentinel_for_cwd) | Sentinel selection result: session_id= is the current session SID (from hook JSON); mode=strict means the exact sentinel for this session was found; mode=strict-miss means strict binding searched but no sentinel matched; mode=legacy-fallback means session_id was empty and glob-scan was used |
| `arm_failed reason=empty-sid` | lib/auto-compact-sentinel.sh (ac_resolve_session_id) | Session ID resolved to empty string — sentinel write refused. Prevents auto-compact-.json collision where all empty-SID sessions share one sentinel |
| `no-session-arg` | post-compact-resume-step2.sh | R8: /post-compact-resume invoked with no session_id arg — delivery degraded; fail-safe refuse (never guess) |
| `invalid-session-arg` | post-compact-resume-step2.sh | R8: session_id arg contains characters outside [A-Za-z0-9_-] — refuse |
| `arg-not-my-session` | post-compact-resume-step2.sh | R9 HIGH-1 (wrong-load guard): session_id arg != this session's own id (CLAUDE_CODE_SESSION_ID) — command mis-delivered/mis-pasted; refuse to load another session's handoff. self= and arg= logged |
| `self-unverifiable` | post-compact-resume-step2.sh | R9-Round2 (fail-closed): this session's own id is unreadable (CLAUDE_CODE_SESSION_ID + CLAUDE_SESSION_ID both empty) so arg-vs-self cannot run — REFUSE rather than degrade to content-only (degrading is a wrong-load path in a shared repo-root). arg= logged. Never fires on supported Claude Code (env var always set) |

## MISSION.<sid>.log (mission-write.sh)

The mission-bridge spine has its OWN log file `<canonical_root>/MISSION.<sid>.log` (NOT a shared hook
log). It is an append-only narrative sidecar to `MISSION.<sid>.md`, written ONLY by the allowlisted CLI
`mission-write.sh` (which dispatches to `lib/mission-bridge.sh`). These are the CLI **verbs** (argv[1]),
not free-text log actions. mission-bridge is **fail-LOUD** (the deliberate exception to ctx-gate's
fail-open posture): a failure surfaces on the single `mission-write: <verb> FAILED rc=N (...)` status line
+ the lib's stderr, but the CLI always `exit 0` so the autonomous `/pre-compact` caller is never aborted.
The byte-locked invocation prefix is matched by a `Bash(bash …/mission-write.sh:*)` allow rule — do NOT
rename a verb or move the script without re-issuing the allow rule and updating every caller.

| Verb | Script | Meaning |
|---|---|---|
| `create` | mission-write.sh (`mission_create`) | Create the canonical `MISSION.<sid>.md` (nonce-fenced PLAN/DURABLE NOTES/PLAN CHALLENGES/PENDING DECISIONS zones + LOCKED last-line marker), write the immutable `.mission-backups/MISSION.<sid>.birth.md`, and set `mission_path` in the chain manifest. Idempotent no-clobber: exists+verifies → no-op; exists+fails-verify → refuse + fail-LOUD |
| `log` | mission-write.sh (`mission_log_append`) | Append one byte-capped (`<480`B, `iconv -c` repaired) narrative line to `MISSION.<sid>.log`. Ensures the main file + manifest pointer exist first (no orphan), heals a torn last line, rotates at 256KB into `.mission-backups/…log.<utc>.gz`. Idempotent on a LEADING anchored `^<idtag>\t`; an oversize entry is rerouted to the locked main file as a `note` |
| `note` | mission-write.sh (`mission_mutate` → DURABLE NOTES) | Append a durable note line into the DURABLE NOTES zone of the main file (locked → verify → backup → plan-drift check → tmp-rewrite → self-verify → atomic rename). Idempotent on `<!-- mid:<idtag> -->` |
| `challenge` | mission-write.sh (`mission_mutate` → PLAN CHALLENGES) | Append a plan-challenge line into the PLAN CHALLENGES zone (same locked-rewrite path as `note`). Where an untrusted/override-style PLAN line is recorded for human review rather than executed |
| `pending` | mission-write.sh (`mission_mutate` → PENDING DECISIONS) | Append a `- [pd:<id>] …` open-decision line into the PENDING DECISIONS zone (same locked-rewrite path). Surfaced in the banner for a batched answer next session |
| `resolve` | mission-write.sh (`mission_resolve_pending`) | Strip the matching `- [pd:<id>] …` line (and its paired `<!-- mid:… -->`) from PENDING DECISIONS via locked rewrite, then append a `resolved pd:<id> — <resolution>` narrative to the LOG |
| `rebaseline` | mission-write.sh (`mission_rebaseline`) | The ONLY path that rewrites the PLAN zone: replace PLAN with a new plan, re-stamp `plan_hash` to match (locked, backed-up, self-verified), then log `PLAN rebaselined (hash re-stamped)` |
| `render-banner` | mission-write.sh (`mission_render_banner`) | PIVOT A write-side precompute: render the bounded `MISSION.<sid>.banner` (PLAN slice `<=4000`B line-snapped + last-5 log lines + injection-safety framing) atomically. On a verify failure writes a LOUD `CRITICAL: … UNREADABLE/CORRUPT` banner (never silent) and returns 0 so the primer surfaces the alarm |

### mission-write.sh status line (stdout, exactly one per invocation)

| Output | Script | Meaning |
|---|---|---|
| `mission-write: <verb> ok` | mission-write.sh | Lib call returned rc=0 |
| `mission-write: <verb> FAILED rc=N (<reason>)` | mission-write.sh | Lib call returned rc=N; reason `see stderr` (lib stays fail-LOUD on stderr) or `lib mission-bridge.sh not found/sourced` (rc=127) |
| `mission-write: usage: …` | mission-write.sh | Unknown verb or missing required args; no mutation attempted |

### `[mission]` structured LOG-line conventions (written via the `log` verb)

These are NOT new CLI verbs. The `/mission` conductor reuses the existing `log` verb (above) and passes
structured `[mission] …`-prefixed payloads as the narrative line. The bridge stores them verbatim in
`MISSION.<sid>.log` (subject to the same `<480`B cap + leading-anchored idtag idempotency). A resume agent
greps these lines to reconstruct loop state across compactions. Field order is part of the grep contract —
do not reorder.

| Line shape | idtag | Meaning |
|---|---|---|
| `[mission] part=<N> name=<slug> phase=<research\|plan\|implement\|review> round=<K> dry=<D> findings=<count-or-slugs>` | `m<N>-<phase>-r<K>-d<D>` | **Round line.** One per phase/round attempt for part `<N>`. `dry=<D>` is the running consecutive-dry count (`0`,`1`,`2`); a non-dry round resets it to `0`. The **`d<D>` in the idtag is REQUIRED**: `mission_log_append` is anchored-idempotent on the leading `^<idtag>\t`, so encoding the dry-count makes each advanced dry-state a brand-NEW line rather than an idempotent no-op — the resume agent can see the dry streak progress (e.g. `…-r5-d0`, `…-r6-d1`, `…-r7-d2`) instead of one collapsed entry |
| `[mission] FAIL part=<N> phase=<P> reason=<slug>` | `m<N>-fail-<reason-hash>` | **Failure tally.** One durable line per distinct failure reason (idtag hashed from `<reason>`, so identical failures collapse to one anchored line that survives compactions). The resume agent counts how many times an identical failure has recurred; `5` identical → stop loud rather than loop forever |
| `[mission] test-trust part=<N>=<ok\|added\|n/a>` | (round/lifecycle idtag) | **Lifecycle — test trust.** Emitted once before the FIRST implement round of part `<N>`: `ok` = pre-existing tests trusted, `added` = tests written first, `n/a` = no test surface |
| `[mission] PART-DONE part=<N> (converged)` | (lifecycle idtag) | **Lifecycle — part converged.** Part `<N>` reached 2-dry convergence and is closed |
| `[mission] MISSION-CLEARED status=<achieved\|could-not\|cleared>` | (lifecycle idtag) | **Lifecycle — mission end.** Terminal line: `achieved` = goal met, `could-not` = stopped loud (e.g. FAIL guard tripped), `cleared` = run wrapped up |
