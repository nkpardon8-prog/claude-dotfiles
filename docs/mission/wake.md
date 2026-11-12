# /mission wake routine (§12.1) - the only file a tick reads

Companion to `commands/mission.md` (the playbook). A tick is a COLD START: no memory, nothing carried.
`sid`, `root` and every path come from the tick prompt (playbook §12). Every wake source - a tick, a
background-job completion, a post-compact resume, a peer message - enters here and advances the
mission by exactly ONE transition. `<MW>` below is the byte-locked
`bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh` (never `~`, `$HOME`, `cd` or
an env prefix). Rare paths (orphan recovery, the lock race note) live in `docs/mission/reference.md`.

## §12.1 The wake routine (idempotent)

0. **Arm the liveness guard** (idempotent; the writer also arms on every bridge write):
   `mkdir -p "$HOME/.claude/progress"; printf '{"sid":"%s","root":"%s"}' "<sid>" "<root>" > "$HOME/.claude/progress/mission-liveness-<sid>.json"`
1. **Tick lock** `tick_dir="$root/.mission-backups/tick.$sid.lock"`; `mkdir "$tick_dir"` succeeds ->
   `i_own_lock=1`. Held and FRESH (<15 min) -> ScheduleWakeup 60 s and return WITHOUT touching it.
   STALE (>15 min) -> `rm -rf` and retry the mkdir ONCE; retry lost -> reschedule 60 s and return. A
   wake more than 10 min late (laptop slept) gives a held lock one 60 s grace first. Never run steps
   2-7 with `i_own_lock=0`. Release only a lock you acquired, on every exit that acquired it. A
   non-owner whose reschedule fails twice -> STOP LOUD.
2. **Verify the bridge and run the §8 resume read below.** `FAILED rc=2` or a failed `mission_verify`
   -> corrupt-bridge STOP LOUD (release, no reschedule).
3. **`cursor_before=$(<MW> cursor-hash "$sid" "$root")`**:
   ```bash
   cursor_before=$(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh cursor-hash "$sid" "$root")
   ```
   Empty or `corrupt` -> STOP LOUD. Never "unchanged".
4. **Pick ONE transition** from the decision table below, inputs:
   ```bash
   aw=$(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh await-state "$sid" "$root")
   bs=$(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh budget-state "$sid" "$root")
   ps=$(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh part-state "$sid" "$root")
   ```
   `aw`: `none` | `corrupt` | `await kind=<job|human> op=.. part=<N> round=<K> attempt=<A> phase=<P>
   need=<M> got=<G> ready=<0|1> started_at=<E>`. `bs`: `ok` | `paused live=<min>` |
   `over part=<N> minutes=<M> replan=<0|1>`. `ps`: `none` | `part=<N> proto=<1|2> dry= closed=<0|1> freeze= head=
   tree= drift=<0|1>` (proto=1 legacy). Watchdog status files (one line each, `state=` and `action=`):
   `~/.claude/progress/mission-liveness/<sid>.watchdog.<label>`. `corrupt` -> STOP LOUD.
5. **Recompute the cursor right before banking.** Changed -> another wake advanced the mission:
   discard this decision, release, re-enter at step 1 (`reenter_count` per wake, at most 2; the 3rd
   change goes to step 7 STILL HOLDING the lock for a short heartbeat). Empty/`corrupt` -> STOP LOUD.
6. **Bank / dispatch** with the deterministic idtags (`ok` = appended or idempotent no-op;
   `COLLISION` -> re-read and reconcile). Before a non-idempotent dispatch (a review panel, a
   worktree change) re-read `await-state` and skip a lane whose bit is set or whose job is running.
   Persist each lane's usable result to DURABLE NOTES before setting its got bit. `FAILED` -> retry,
   then STOP LOUD. A refusal `part-retired` for a late completion is an expected drop: no FAIL.
7. **EXIT GATE - no path returns except through here.** If a §12.3 stop holds: release, return, no
   reschedule. Else call `ScheduleWakeup` WHILE HOLDING the lock: `delaySeconds` 60 while a transition
   is in flight, 1500-3300 while a tracked job runs (never above 3300: the 1 h cache TTL), `prompt` =
   the tick body verbatim, `reason` = `mission <sid> tick`. Success -> release, return. Failure ->
   retry once, then `pending-stop` under the lock, release, STOP LOUD. Never yield naked.

## §8 The resume read (the single canonical recovery idiom)

Archives oldest -> newest, THEN the live log; never `tail`, never the newest archive alone. Every
control derivation is double-anchored (idtag column AND body), so free text cannot forge state.
```bash
live_log="$root/MISSION.$sid.log"
# Archives oldest->newest (filename timestamp), THEN the live log. The for + [ -e ] guard is set -e safe
# with zero archives; paths stay quoted (roots can hold spaces); only final .gz/.txt are read.
{
  for a in "$root"/.mission-backups/MISSION."$sid".log.*.gz \
           "$root"/.mission-backups/MISSION."$sid".log.*.txt; do
    [ -e "$a" ] || continue          # unmatched glob -> literal -> [ -e ] false -> skip (no failing cmd)
    printf '%s\n' "$a"
  done | sort | while IFS= read -r a; do
    case "$a" in *.gz) gzip -dc "$a" 2>/dev/null;; *) cat "$a" 2>/dev/null;; esac
  done
  cat "$live_log" 2>/dev/null          # ALWAYS read, even with zero archives
} | grep -F '[mission] ' > /tmp/mission-resume.$$ 2>/dev/null || true
# || true: no [mission] lines yet is a valid early state, never an abort (same for every derivation below).

# Current part first: convergence reads are scoped to it. Every derivation keys on BOTH the idtag column
# ($1) and the body ($2), so a note that embeds a control token cannot forge state.
cur_part=$(awk -F'\t' '$1 ~ /^(g[0-9]+-)?m[0-9]+-part-(start|done)$/ && $2 ~ /^\[mission\] (PART-START|PART-DONE) part=[0-9]+/' /tmp/mission-resume.$$ \
            | tail -1 | sed -n 's/.*part=\([0-9][0-9]*\).*/\1/p' || true)
[ -z "$cur_part" ] && cur_part=1   # no part-lifecycle yet ⇒ part 1 (empty = valid, not an error)

# Active-iff gate: GLOBAL, only CLEARED/REBASELINED (EMPTY idtag, full writer grammar; a torn line is
# ignored). Keep in lockstep with the lib readers (mission_lifecycle_state, mission_await_state).
mission_state=$(awk -F'\t' '$1=="" && ( $2 ~ /^\[mission\] MISSION-CLEARED status=(achieved|could-not|cleared) reason=[a-z0-9-]*$/ || $2 ~ /^\[mission\] MISSION-REBASELINED status=active gen=[0-9]+ \([^\t]*\)$/ )' /tmp/mission-resume.$$ | tail -1 || true)
# Convergence input: the part-scoped last phase=review round OR VOID.
last_review=$(awk -F'\t' -v p="$cur_part" '($1 ~ /^(g[0-9]+-)?m[0-9]+-review-r[0-9]+-d[0-2]$/ && $2 ~ ("^\\[mission\\] part=" p " ") && $2 ~ /phase=review/) || ($1 ~ /^(g[0-9]+-)?m[0-9]+-void-r/ && $2 ~ ("^\\[mission\\] VOID part=" p " "))' \
                /tmp/mission-resume.$$ | tail -1 || true)
# Positioning only: the part-scoped last round of any phase, or VOID.
last_round=$(awk -F'\t' -v p="$cur_part" '($1 ~ /^(g[0-9]+-)?m[0-9]+-(research|plan|implement|review|fix)-r[0-9]+-d[0-2]$/ && $2 ~ ("^\\[mission\\] part=" p " ")) || ($1 ~ /^(g[0-9]+-)?m[0-9]+-void-r/ && $2 ~ ("^\\[mission\\] VOID part=" p " "))' \
                /tmp/mission-resume.$$ | tail -1 || true)
# Positioning only: global PART-START/DONE/RETIRED, test-trust, VOID.
last_progress=$(awk -F'\t' '($1 ~ /^(g[0-9]+-)?m[0-9]+-part-(start|done|retired)$/ && $2 ~ /^\[mission\] (PART-START|PART-DONE|PART-RETIRED) part=/) || ($1 ~ /^(g[0-9]+-)?m[0-9]+-test-trust$/ && $2 ~ /^\[mission\] /) || ($1 ~ /^(g[0-9]+-)?m[0-9]+-void-r/ && $2 ~ /^\[mission\] VOID part=/)' \
                /tmp/mission-resume.$$ | tail -1 || true)
# Human decision (only while a human AWAIT is live), keyed on that barrier's op from await-state:
op="<the await-state token's op, e.g. 3-approve>"; seq="${op%%-*}"; slug="${op#*-}"; dtag="pd-${seq}-decision-${slug}"
# ANSWERED only if the full reader predicate holds (mirrors mission_await_state): recorded after the got=0
# opener, no conflicting outcome for the op, and before any post-opener got=1. Else EMPTY, so the wake
# re-confronts the STOP instead of executing a stale, forged or corrupt outcome.
last_decision=$(awk -F'\t' -v t="$dtag" -v op="$op" '
  function fval(s,k,   p,i,r,a){ p=k"="; i=index(s,p); if(i==0) return ""; r=substr(s,i+length(p)); split(r,a," "); return a[1] }
  # newest got=0 OPENER NR + newest post-need got=1 close NR for this op (double-anchored: AWAIT idtag + body)
  ($1 ~ /^(g[0-9]+-)?m[0-9]+-await-/) && ($2 ~ /^\[mission\] AWAIT /) {
    if (fval($2,"op")==op) { g=fval($2,"got")+0
      if (g==0 && NR>opnr) opnr=NR
      if (g>=1 && NR>g1nr) g1nr=NR } }   # newest got>=1 line (the human need=1 close) for this op
  # newest DECISION for this op (double-anchored idtag<->body; a mismatched-idtag/free-text line cannot match).
  # Track outcome CONFLICT: a same-op DECISION set with two DIFFERENT outcomes is corruption (E3).
  (($1==t) || ($1 ~ ("^g[0-9]+-" t "$"))) && ($2 ~ ("^\\[mission\\] DECISION op=" op " outcome=(approve|deny)$")) {
    o=fval($2,"outcome"); if (dseen && dprev!=o) conflict=1; dprev=o; dseen=1; dnr=NR; dline=$0 }
  # ANSWERED iff the full reader predicate holds: after-opener AND no-conflict AND before any post-opener got=1
  # (g1nr<=opnr ⇒ no post-opener close yet ⇒ before-got=1 trivially holds; else require dnr<g1nr — mirror C9/D3/E3)
  END { if (dnr>0 && opnr>0 && dnr>opnr && !conflict && (g1nr<=opnr || dnr<g1nr)) print dline }
' /tmp/mission-resume.$$ || true)
# EMPTY = unanswered (STOP for a real user; no pd line either = ORPHAN, see reference.md).
# NON-EMPTY = answered: consume outcome=approve|deny.
```

Empty values are valid early states (`cur_part` empty -> 1; `mission_state` empty + a `MISSION MODE:`
PLAN -> ACTIVE). **Active iff** the latest `mission_state` line is not `MISSION-CLEARED`
(`MISSION-REBASELINED status=active` reactivates). `last_review` alone drives convergence;
`last_round` / `last_progress` only position. Intent precedence: PLAN > LOG > handoff `Next Action`.

## Decision table (apply in order; first match wins)

| State | One transition |
|---|---|
| `await kind=human ready=0` and THIS is a real user turn answering it | Consume UNDER the lock, in order: (a) `log "[mission] DECISION op=<seq>-<slug> outcome=<approve\|deny>" "pd-<seq>-decision-<slug>"` with the user's actual answer; (b) approve -> run the idempotent gated action, deny -> abort it; (c) `await` the same barrier (same op/part/phase/round/attempt) `need=1 got=1` (refused until the DECISION exists); (d) `resolve <full pd:id>`. Never close then defer the action. That is the transition: go to step 7. |
| `await kind=human ready=0` on a wake | `last_decision` NON-EMPTY -> consume it now (action, then got=1, then resolve; each a no-op if done), never re-ask. EMPTY -> STOP, no reschedule, wait for the user. ORPHAN (no `- [pd:<op>]` line, no DECISION) -> reference.md "Orphan human barrier". |
| `ps` proto=1 closed=0 (legacy part) | Follow reference.md "Legacy part loop" for every state, AWAITs included; no row below applies (all are proto=2). |
| `bs` = `over ... replan=1` | Re-plan once: stop the part's helpers, run the strategist (`/plan --roadmap`) for this part, bank RECIPE v2, continue. |
| `bs` = `over ... replan=0` | Park (playbook §J): stop helpers, park FAIL, PushNotification, PART-RETIRED, strategist, next PART-START. Never an AWAIT, never a STOP. |
| a watchdog status file says `action=stop` (`state=stall`, or `state=deadline` for a non-test helper) | TaskStop it (yours, exact id), `note`, delete the status file, relaunch once; a second stop parks the part. `action=note` (suite `state=overdue`): note + PushNotification only, never a kill. |
| `await kind=job ready=0`, tracked job still running | Launch nothing. Step 7 with a 1500-3300 s heartbeat. |
| `await kind=job ready=0`, no tracked job | Younger than the lane's watchdog deadline -> heartbeat. Older -> relaunch ONLY the missing lane, same attempt; a genuine timeout -> FAIL line, attempt A+1. |
| `await kind=job ready=1` | `codex-review --verify <run-dir> --with <impl-reviewer-output>`, then `bank-review` (plan/delta/close per the round). Its line supersedes the AWAIT. |
| latest progress `PART-DONE` or `PART-RETIRED` | Part complete. PART-DONE without PART-RETIRED -> retire first. Then the strategist boundary pass and the next PART-START (writer checks `needs=`). |
| `ps` drift=1 (HEAD moved/dirty since the freeze) | Repair first: commit or discard, log `phase=fix dry=0` (resets dry), delta round from the freeze, new freeze, new close. |
| `ps` proto=2 dry=2 closed=0 (joined) | Log PART-DONE (rc=4 names the gap). Never re-review. |
| `PART-START` with no RECIPE (proto=2) | Bank RECIPE v1 from the strategist's boundary pass. |
| `PART-START`, RECIPE, no round yet | Begin research. |
| last round `phase=research\|implement` | Continue that phase, then the next step of the part loop. |
| last round `phase=plan` | Continue `/plan --mission`; `open=0` -> implement; still open at the cap -> descope (recorded in the plan) or park. |
| last review `phase=review findings>0` | Fix the SAME round K (`phase=fix`), then a sweep if `repeat>0` (a second dirty sweep on the same types -> redesign, playbook §H2), then delta round K+1. |
| last round `phase=fix` | Finish the fix (check the tree), then delta round K+1. |
| last review `dry=1`, no `dry=2` | Close join: for the freeze SHA relaunch ONLY missing legs (close review, FULL-SUITE, live proof); all three banked -> `bank-review ... join`. |
| close result `blocking` | Repair: fix, delta round, new freeze, new close (dry reset). Infra-only suite/live failure at an unmoved HEAD -> same-SHA rerun as `attempt+1`. |
| latest line for round K is `VOID` | Re-run round K fresh. |

Never re-run a banked idtag round. Retired parts' job AWAITs are ignored by `await-state`.

## §12.3 Stop conditions (closed list - nothing else stops a wake)

Return WITHOUT rescheduling (release the lock first) only when:
- `MISSION-CLEARED` is the latest lifecycle line (close order: `timing-close` -> `MISSION-CLEARED`
  -> `archive-close` -> disarm the liveness file).
- A named STOP LOUD: 5 FAILs for one part+phase (gen-sliced), `panel-unavailable-3x`, `void-count`
  `-1`, a corrupt bridge. PushNotification first, with the summary line of `<root>/tmp/mission/MORNING.md`
  (the writer refreshed it on the FAIL; otherwise run `lib/mission-status.sh morning <sid> <root>`).
- A mandatory human decision, opened with ONE call:
  `out=$(bash /Users/omidzahrai/.claude-dotfiles/scripts/hooks/mission-write.sh pending-stop <sid> <root> <slug> <part> <round> <attempt> <phase> "$q" 2>&1)`
  (`q` captured from a quoted heredoc or file, never inlined). Its ONLY proceed-able outcome is the
  status line `mission-write: pending-stop ok id=pd:<seq>-<slug>`; extract it anchored:
  `pid=$(printf '%s\n' "$out" | sed -n 's/^mission-write: pending-stop ok id=\(pd:[0-9][0-9]*-[a-z0-9-][a-z0-9-]*\).*$/\1/p' | head -1)`.
  EVERY non-zero rc means the STOP did NOT open: do not proceed, STOP LOUD.
- An `await kind=human ready=0` already outstanding.

NOT stops: a commit, a finished unit, a report, a peer reply, a green suite, a park, a push-queue
entry. Announcing an action never substitutes for taking it.

## §12.4 Post-compact resume

Just another wake source: keep the `(sid,nonce)` resume marker, enter §12.1 (the tick lock serializes
it). Never hand-resume the last round line.
