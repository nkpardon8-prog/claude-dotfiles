#!/usr/bin/env bash
# handoff-config.sh — constants for the handoff (CLAUDE.local.md) lifecycle.
# Extracted from ctx-gate-config.sh — these are handoff-file lifecycle concerns,
# distinct from ctx-gate's PCT thresholds. _OVERRIDE pattern for test/user override.
#
# Idempotent source guard — second sourcing is a no-op.
[ -n "${_HANDOFF_CONFIG_LOADED:-}" ] && return 0
readonly _HANDOFF_CONFIG_LOADED=1

# Stale-handoff threshold: handoff older than this is treated as "from prior conversation"
# by the primer and /post-compact-resume.
# Default 24h — 1h was causing false-positives on legitimate overnight sessions.
readonly HANDOFF_STALE_SECS="${HANDOFF_STALE_SECS_OVERRIDE:-86400}"

# Legacy cutoff: handoff mtime older than this is treated as predating the
# END-OF-HANDOFF marker convention. Warn-but-allow rather than flag as TRUNCATED.
# 1779321600 = 2026-05-21 00:00 UTC — corrected from prior 1779235200 (2026-05-20).
# Override-via-env pattern allows tests to set deterministic past/future cutoffs.
# Emergency escape: set HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE=9999999999 to suppress
# all TRUNCATED warnings (if reverting pre-compact.md to a pre-marker version).
readonly HANDOFF_LEGACY_CUTOFF_EPOCH="${HANDOFF_LEGACY_CUTOFF_EPOCH_OVERRIDE:-1779321600}"

# Max handoff size — defense against pathological growth.
readonly HANDOFF_MAX_SIZE_BYTES="${HANDOFF_MAX_SIZE_BYTES_OVERRIDE:-5242880}"  # 5MB

# R3 D4: renamed for semantic clarity — "bypass" better describes the behavior
# (this is the threshold at which the safety net releases/bypasses, not just "releases").
# Raised from 75 → 90 to close the 75-95% unprotected gap: native auto-compact
# fires at ~95%, FORCE nudge fires at 75% (2026-05-28 tuning — lowered from 85% for
# code-quality-first); 90% leaves 15% headroom for the safety release before native
# compaction would lose the handoff.
# Native auto-compact is BLOCKED below this PCT if no sentinel armed; ABOVE this PCT
# it is RELEASED (escape valve to prevent deadlock at ~95% native trigger).
readonly HANDOFF_AUTOCOMPACT_BYPASS_PCT="${HANDOFF_AUTOCOMPACT_BYPASS_PCT_OVERRIDE:-90}"
