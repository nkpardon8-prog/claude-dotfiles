# lib/subagent-event.sh - is this hook event from a worker (subagent) rather than a main window?
#
# Why: when a subagent auto-compacts, Claude Code fires PreCompact and SessionStart(source=compact)
# with the PARENT window's session_id plus a non-empty string agent_id (and agent_type). Hooks that
# key on session_id would act on the main window's state (its sentinel, sidecar, handoff, saved
# rules baseline). Callers check this right after reading stdin and leave on a worker event.
#
# Fail-open: anything that is not a well-formed JSON document whose agent_id is a non-empty string
# (malformed or partial JSON, missing jq, null, number, empty string) returns 1, so the caller
# behaves exactly as it did before this check existed. Sourcing this file has no side effects.
#
# Callers source it by absolute path and call it only if it is defined, so a half-synced checkout
# can never break a hook:
#   lib="$DIR/lib/subagent-event.sh"; [ -f "$lib" ] && . "$lib"
#   if declare -F hook_is_subagent_event >/dev/null && hook_is_subagent_event "$INPUT"; then exit 0; fi

# hook_is_subagent_event <hook-json> - 0 when the event carries a non-empty string agent_id.
hook_is_subagent_event() {
  local id
  id=$(printf '%s' "${1:-}" | jq -er '.agent_id | strings | select(length>0)' 2>/dev/null) || return 1
  [ -n "$id" ]
}
