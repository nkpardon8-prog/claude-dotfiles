#!/bin/bash
# test-rules-in-force.sh - throwaway origin + clone; drives every mode of rules-in-force.py.
# Usage: bash test-rules-in-force.sh [path/to/rules-in-force.py]
set -u
HOOK="${1:-$(cd "$(dirname "$0")" && pwd)/rules-in-force.py}"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export RIF_STATE_DIR="$T/state" RIF_GLOBAL_FILE="$T/global/CLAUDE.md" RIF_RULES_DIR="$T/global/rules"
export RIF_LOG="$T/log" RIF_NO_CODEX=1 RIF_NO_KEEP_CURRENT=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
mkdir -p "$T/global/rules"
printf '# Global\nRules version: 2026-11-17.\nline g1\n' > "$RIF_GLOBAL_FILE"
printf 'rule r1\n' > "$RIF_RULES_DIR/a.md"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1"; echo "---- output:"; printf '%s\n' "$2" | head -20; echo "----"; }
has()  { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "$2";; esac; }
hasnt(){ case "$2" in *"$3"*) bad "$1" "$2";; *) ok "$1";; esac; }
unstamp(){ rm -f "$RIF_STATE_DIR"/fetch-*; }   # the hook fetches at most every 2 min per repo
run()  { printf '{"session_id":"%s","cwd":"%s"%s}' "$2" "$3" "${4:-}" | python3 "$HOOK" "$1"; }

# origin with dev as default branch, plus a clone that will go stale
git init -q -b dev "$T/seed" && cd "$T/seed"
printf '# CLAUDE.md\nRules version: 2026-11-17.\nproject v1\n' > CLAUDE.md && git add CLAUDE.md && git commit -qm v1
git clone -q --bare "$T/seed" "$T/origin.git"
git clone -q "$T/origin.git" "$T/clone"
cd "$T/clone" && git remote set-head origin dev >/dev/null

# 1. current checkout: one status line, no RULES IN FORCE
o=$(run session-start s1 "$T/clone")
has   "1 status line names both versions" "$o" "Rules loaded: global 2026-11-17; project 2026-11-17 from origin/dev"
hasnt "1 no in-force note when current"   "$o" "RULES IN FORCE"

# 2. prompt with nothing changed: silent
o=$(run prompt s1 "$T/clone")
[ -z "$o" ] && ok "2 prompt silent when unchanged" || bad "2 prompt silent when unchanged" "$o"

# 3. origin moves ahead; clone not pulled -> the next session start is stale and gets dev's copy
cd "$T/seed" && printf '# CLAUDE.md\nRules version: 2026-11-18.\nproject v2\n' > CLAUDE.md && git commit -qam v2 && git push -q "$T/origin.git" dev
cd "$T/clone"; unstamp
o=$(run session-start s2 "$T/clone")
has   "3 stale checkout gets RULES IN FORCE" "$o" "RULES IN FORCE"
has   "3 injected copy is origin's"          "$o" "project v2"
has   "3 says how far behind"                "$o" "1 commits behind origin/dev"

# 4. session s1 (loaded v1) gets only the diff on its next prompt (fetch done by s2's start)
o=$(run prompt s1 "$T/clone")
has   "4 mid-session change announced" "$o" "RULES CHANGED"
has   "4 diff carries the new line"    "$o" "+project v2"
has   "4 diff carries the old line"    "$o" "-project v1"
o=$(run prompt s1 "$T/clone")
[ -z "$o" ] && ok "4 announced once" || bad "4 announced once" "$o"

# 5. global rules change (rules/ file) -> diff on next prompt
printf 'rule r1 changed\n' > "$RIF_RULES_DIR/a.md"
o=$(run prompt s1 "$T/clone")
has   "5 global change announced" "$o" "global rules"
has   "5 global diff new line"    "$o" "+rule r1 changed"

# 6. a window opened before the hook existed (no state) in a stale checkout: first prompt fixes it
o=$(run prompt s3 "$T/clone")
has   "6 first contact on prompt" "$o" "RULES IN FORCE"
o=$(run prompt s3 "$T/clone")
[ -z "$o" ] && ok "6 then quiet" || bad "6 then quiet" "$o"

# 7. subagents: stale -> JSON additionalContext; Explore skipped; current checkout -> nothing
o=$(run subagent s2 "$T/clone" ',"agent_type":"general-purpose"')
has   "7 subagent gets JSON context" "$o" '"hookEventName": "SubagentStart"'
has   "7 subagent context is origin's" "$o" "project v2"
o=$(run subagent s2 "$T/clone" ',"agent_type":"Explore"')
[ -z "$o" ] && ok "7 Explore skipped" || bad "7 Explore skipped" "$o"
o=$(run subagent s2 "$T/clone" ',"agent_type":"general-purpose","agent_id":"a1"')
has   "7 subagent with agent_id unchanged" "$o" '"hookEventName": "SubagentStart"'

# 7w. a WORKER's compaction: SessionStart compact with the PARENT's sid plus agent_id. It gets the
#     rules note subagent mode gives, and the parent's saved state is left byte-identical.
cp "$RIF_STATE_DIR/s2.json" "$T/s2.before"
o=$(run session-start s2 "$T/clone" ',"source":"compact","agent_id":"a1","agent_type":"implementer"')
has   "7w worker compact gets RULES IN FORCE" "$o" "RULES IN FORCE"
has   "7w worker note is origin's"           "$o" "project v2"
hasnt "7w no session status line"            "$o" "Rules loaded"
cmp -s "$RIF_STATE_DIR/s2.json" "$T/s2.before" && ok "7w parent state byte-identical" \
  || bad "7w parent state byte-identical" "$(diff "$T/s2.before" "$RIF_STATE_DIR/s2.json")"
o=$(run session-start w9 "$T/clone" ',"source":"compact","agent_id":"a1"')
[ ! -e "$RIF_STATE_DIR/w9.json" ] && ok "7w worker creates no state" || bad "7w worker creates no state" "$o"
o=$(run session-start w8 "$T/clone" ',"source":"compact","agent_id":""')
[ -e "$RIF_STATE_DIR/w8.json" ] && ok "7w empty agent_id runs as a main window" || bad "7w empty agent_id runs as a main window" "$o"
git -C "$T/clone" pull -q
o=$(run subagent s2 "$T/clone" ',"agent_type":"general-purpose"')
[ -z "$o" ] && ok "7 current checkout: subagent untouched" || bad "7 current checkout: subagent untouched" "$o"

# 8. not a repo: status line only, no crash
o=$(run session-start s4 "$T/global")
has   "8 non-repo status line" "$o" "Rules loaded: global 2026-11-17."

# 9. oversized origin copy -> pointer to a file, output under the cap
cd "$T/seed" && { printf '# CLAUDE.md\n'; for i in $(seq 1 400); do echo "padding line $i with some words to make it long"; done; } > CLAUDE.md && git commit -qam big && git push -q "$T/origin.git" dev
git -C "$T/clone" reset -q --hard HEAD~1; unstamp
o=$(run session-start s5 "$T/clone")
has   "9 oversize points at a file" "$o" "Read $RIF_STATE_DIR/s5-in-force-CLAUDE.md in full"
[ "${#o}" -lt 9800 ] && ok "9 output under cap (${#o})" || bad "9 output under cap" "${#o}"
[ -s "$RIF_STATE_DIR/s5-in-force-CLAUDE.md" ] && ok "9 spill file written" || bad "9 spill file written" ""

# 10. garbage stdin and missing session id: silent, exit 0
o=$(printf 'not json' | python3 "$HOOK" prompt); rc=$?
[ -z "$o" ] && [ $rc -eq 0 ] && ok "10 garbage stdin silent" || bad "10 garbage stdin silent" "$o rc=$rc"
o=$(printf '{"cwd":"/"}' | python3 "$HOOK" session-start); rc=$?
[ -z "$o" ] && [ $rc -eq 0 ] && ok "10 no session id silent" || bad "10 no session id silent" "$o rc=$rc"

# 11. resume keeps the saved baseline: a global change shows as a diff, not a silent reset
printf '{"session_id":"s6","cwd":"%s","source":"startup"}' "$T/global" | python3 "$HOOK" session-start >/dev/null
printf '# Global\nRules version: 2026-11-17.\nline g1 resumed\n' > "$RIF_GLOBAL_FILE"
o=$(printf '{"session_id":"s6","cwd":"%s","source":"resume"}' "$T/global" | python3 "$HOOK" session-start)
has   "11 resume shows global diff" "$o" "+line g1 resumed"
o=$(printf '{"session_id":"s6","cwd":"%s","source":"compact"}' "$T/global" | python3 "$HOOK" session-start)
hasnt "11 compact reloads from disk: no diff" "$o" "RULES CHANGED"

# 12. a window opened before the hook existed (no saved baseline) always gets the current global rules once
o=$(printf '{"session_id":"s7","cwd":"%s"}' "$T/global" | python3 "$HOOK" prompt)
has   "12 no baseline: gets global rules" "$o" "global rules below"
o=$(printf '{"session_id":"s7","cwd":"%s"}' "$T/global" | python3 "$HOOK" prompt)
[ -z "$o" ] && ok "12 then quiet" || bad "12 then quiet" "$o"

# 13. the WHOLE output stays under the cap: big global rules + stale big project at once
{ printf '# Global\n'; for i in $(seq 1 300); do echo "global padding line $i with words"; done; } > "$RIF_GLOBAL_FILE"
cd "$T/seed" && { printf '# CLAUDE.md\n'; for i in $(seq 1 250); do echo "project line $i with some words"; done; } > CLAUDE.md && git commit -qam big2 && git push -q "$T/origin.git" dev
unstamp   # the clone is still behind origin from step 9
o=$(printf '{"session_id":"s9","cwd":"%s"}' "$T/clone" | python3 "$HOOK" prompt)
[ "${#o}" -le 9800 ] && ok "13 combined output under cap (${#o})" || bad "13 combined output under cap" "${#o}"
has   "13 spilled part points at a file" "$o" "in full now"
has   "13 both notes present" "$o" "commits behind"

# 14. keep-current: the MAIN folder is moved to origin/dev at session start when it is safe.
#     Each case gets its own origin + clone; origin is one commit ahead and already fetched.
unset RIF_NO_KEEP_CURRENT; export RIF_NO_FETCH=1
kc() {   # kc <name> [claude|other]: fixture at $T/k/<name>; prints the clone path
  local d="$T/k/$1" f=CLAUDE.md
  [ "${2:-claude}" = other ] && f=other.txt
  git init -q -b dev "$d/seed" && printf '# CLAUDE.md\nRules version: 2026-11-17.\nkc v1\n' > "$d/seed/CLAUDE.md" \
    && printf 'a\n' > "$d/seed/other.txt" && git -C "$d/seed" add . && git -C "$d/seed" commit -qm v1
  git clone -q --bare "$d/seed" "$d/origin.git" && git clone -q "$d/origin.git" "$d/clone"
  git -C "$d/clone" remote set-head origin dev >/dev/null
  printf 'kc v2\n' >> "$d/seed/$f" && git -C "$d/seed" commit -qam v2 && git -C "$d/seed" push -q "$d/origin.git" dev
  git -C "$d/clone" fetch -q && git -C "$d/clone" checkout -q --detach HEAD
  (cd "$d/clone" && pwd -P)   # git reports the resolved path (/private/var on macOS)
}
head_is_origin() { [ "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$1" rev-parse origin/dev)" ]; }

c=$(kc ff); o=$(run session-start k1 "$c")
head_is_origin "$c" && ok "14 detached+clean+behind fast-forwarded" || bad "14 detached+clean+behind fast-forwarded" "$o"
hasnt "14 no stale note after update"     "$o" "is stale"
has   "14 window told its loaded copy is older" "$o" "was just updated"
hasnt "14 no main-folder warning"         "$o" "Main folder"
[ -z "$(git -C "$c" symbolic-ref -q HEAD)" ] && ok "14 left detached" || bad "14 left detached" ""
[ ! -e "$c/.git/claude-keep-current.lock" ] && ok "14 lock released" || bad "14 lock released" ""

c=$(kc ffother other); o=$(run session-start k1b "$c")
head_is_origin "$c" && ok "14 non-rules commit fast-forwarded" || bad "14 non-rules commit fast-forwarded" "$o"
hasnt "14 same CLAUDE.md: no RULES IN FORCE" "$o" "RULES IN FORCE"

c=$(kc onbase); git -C "$c" checkout -q dev; o=$(run session-start k1c "$c")
head_is_origin "$c" && ok "14 on base branch, no local commits: updated" || bad "14 on base branch, no local commits: updated" "$o"

c=$(kc dirty); printf 'local edit\n' >> "$c/other.txt"; h=$(git -C "$c" rev-parse HEAD); o=$(run session-start k2 "$c")
[ "$(git -C "$c" rev-parse HEAD)" = "$h" ] && grep -q 'local edit' "$c/other.txt" && ok "14 tracked change: not touched" || bad "14 tracked change: not touched" "$o"
has   "14 tracked change: one line" "$o" "Main folder $c is 1 commits behind origin/dev and has local changes; it was not updated. Work in a worktree off origin/dev."
has   "14 tracked change: stale note still fires" "$o" "is stale"

c=$(kc feat); git -C "$c" checkout -q -b feature/x; h=$(git -C "$c" rev-parse HEAD); o=$(run session-start k3 "$c")
[ "$(git -C "$c" rev-parse HEAD)" = "$h" ] && [ "$(git -C "$c" symbolic-ref --short HEAD)" = feature/x ] && ok "14 named branch: not touched" || bad "14 named branch: not touched" "$o"
has   "14 named branch: one line" "$o" "and is on branch feature/x; it was not updated"

c=$(kc ahead); (cd "$c" && printf 'x\n' > new.txt && git add new.txt && git commit -qm local); h=$(git -C "$c" rev-parse HEAD)
o=$(run session-start k3b "$c")
[ "$(git -C "$c" rev-parse HEAD)" = "$h" ] && ok "14 detached local commit: not touched" || bad "14 detached local commit: not touched" "$o"
has   "14 detached local commit: one line" "$o" "has local commits"

c=$(kc linked); w="$T/k/linked/wt"; git -C "$c" worktree add -q --detach "$w" HEAD~0 2>/dev/null
h=$(git -C "$w" rev-parse HEAD); o=$(run session-start k4 "$w")
[ "$(git -C "$w" rev-parse HEAD)" = "$h" ] && ok "14 linked worktree: not touched" || bad "14 linked worktree: not touched" "$o"
hasnt "14 linked worktree: no main-folder line" "$o" "Main folder"

c=$(kc locked); mkdir "$c/.git/claude-keep-current.lock"; h=$(git -C "$c" rev-parse HEAD); o=$(run session-start k5 "$c")
[ "$(git -C "$c" rev-parse HEAD)" = "$h" ] && ok "14 lock held: skipped" || bad "14 lock held: skipped" "$o"
hasnt "14 lock held: silent" "$o" "Main folder"
[ -d "$c/.git/claude-keep-current.lock" ] && ok "14 lock held: other window's lock kept" || bad "14 lock held: other window's lock kept" ""
touch -t 202001010000 "$c/.git/claude-keep-current.lock"; o=$(run session-start k5b "$c")
head_is_origin "$c" && ok "14 stale lock taken over" || bad "14 stale lock taken over" "$o"

c=$(kc merging); h=$(git -C "$c" rev-parse HEAD); git -C "$c" rev-parse HEAD > "$c/.git/MERGE_HEAD"; o=$(run session-start k5c "$c")
[ "$(git -C "$c" rev-parse HEAD)" = "$h" ] && ok "14 merge in progress: not touched" || bad "14 merge in progress: not touched" "$o"

c=$(kc untracked other); h=$(git -C "$c" rev-parse HEAD)
git -C "$T/k/untracked/seed" rm -q other.txt && printf 'n\n' > "$T/k/untracked/seed/blocker.txt" && git -C "$T/k/untracked/seed" add blocker.txt \
  && git -C "$T/k/untracked/seed" commit -qm v3 && git -C "$T/k/untracked/seed" push -q "$T/k/untracked/origin.git" dev && git -C "$c" fetch -q
printf 'my untracked file\n' > "$c/blocker.txt"; o=$(run session-start k6 "$c")
[ "$(git -C "$c" rev-parse HEAD)" = "$h" ] && grep -q 'my untracked' "$c/blocker.txt" && ok "14 untracked in the way: not changed" || bad "14 untracked in the way: not changed" "$o"
has   "14 untracked in the way: one line" "$o" "Main folder $c could not update to origin/dev: untracked files in the way (git status). Not changed."
[ ! -e "$c/.git/claude-keep-current.lock" ] && ok "14 failed checkout releases lock" || bad "14 failed checkout releases lock" ""

c=$(kc sub); h=$(git -C "$c" rev-parse HEAD)
o=$(run subagent k7 "$c" ',"agent_type":"general-purpose"')
o2=$(run session-start k7 "$c" ',"source":"compact","agent_id":"a1"')
o3=$(run session-start k7m "$c" ',"source":"compact"')
[ "$(git -C "$c" rev-parse HEAD)" = "$h" ] && ok "14 subagent, worker compact, main compact: not touched" || bad "14 subagent/compact not touched" "$o$o2$o3"
hasnt "14 subagent: no main-folder line" "$o$o2$o3" "Main folder"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
