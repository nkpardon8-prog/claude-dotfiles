#!/usr/bin/env bash
# test-mission-proto2.sh - fail-first proof for the /mission proto=2 writer contract (rework plan v5,
# section 7.2 tests 1-11). Each group carries a negative control. Real throwaway git repos, a real
# linked part worktree, and the real mission-write.sh verbs. History that must look OLD (budget clocks,
# legacy parts) is fabricated through the lib's raw appender, never through a writer test hook.
# macOS bash 3.2 compatible. Prints `PASS: N  FAIL: M`; exit code = FAIL>0.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MW="$HERE/mission-write.sh"
DC="$HERE/mission-drift-check.sh"
HOOK="$HERE/mission-liveness.sh"
. "$HERE/lib/mission-bridge.sh" || { echo "FATAL: cannot source lib"; exit 2; }

PASS=0; FAIL=0; TMPS=""; SIDS=""
ok()    { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
has()   { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 [missing '$1' in: $2]" ;; esac; }
hasnt() { case "$2" in *"$1"*) bad "$3 [unexpected '$1' in: $2]" ;; *) ok "$3" ;; esac; }
eq()    { [ "$1" = "$2" ] && ok "$3" || bad "$3 [expected '$1' == '$2']"; }
UNIQ="p2t$$"
trap 'for d in $TMPS; do rm -rf "$d"; done; for s in $SIDS; do rm -f "$HOME/.claude/progress/mission-liveness-$s.json"; done' EXIT

NOW=$(date +%s)
RELOAD="re-read commands/mission.md"

# mk <name> -> sets S (sid), R (mission root repo), W (linked part worktree on branch p1), B (base sha12)
mk() {
  S="${UNIQ}-$1"; SIDS="$SIDS $S"
  R=$(mktemp -d "${TMPDIR:-/tmp}/p2r.XXXXXX"); TMPS="$TMPS $R"
  R=$(cd "$R" && pwd -P)
  ( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'v1\n' > code.txt && git add code.txt && git commit -qm init ) >/dev/null 2>&1
  W="${R}-wt"; TMPS="$TMPS $W"
  git -C "$R" worktree add -q -b "p-$1" "$W" >/dev/null 2>&1
  ( cd "$W" && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
  B=$(git -C "$W" rev-parse HEAD | cut -c1-12)
  bash "$MW" create "$S" "$R" "plan" >/dev/null
}
# wt <dir> <name> <base-ref> -> creates another linked worktree at <dir> from <base-ref>
wt() { git -C "$R" worktree add -q -b "p-$2-$$" "$1" "$3" >/dev/null 2>&1; TMPS="$TMPS $1"
       ( cd "$1" && git config user.email t@t && git config user.name t ) >/dev/null 2>&1; }
commit() { ( cd "$1" && printf '%s\n' "$2" >> code.txt && git add code.txt && git commit -qm "$2" ) >/dev/null 2>&1
           git -C "$1" rev-parse HEAD | cut -c1-12; }
mw()  { bash "$MW" "$@" 2>/dev/null; }
lg()  { mw log "$S" "$R" "$1" "${2:-}"; }
fab() { mission_log_append "$S" "$R" "$1" "$2" >/dev/null 2>&1; }   # raw append: fabricated history
ps2() { # ps2 <N> <wt> <base12> [needs]
  lg "[mission] PART-START part=$1 name=p$1 proto=2 worktree=$2 base=$3 needs=${4:-none}" "m$1-part-start"; }
recipe() { # recipe <N> <v> <tier> <floor> <plan> <review> <budget> <live> [needs]
  lg "[mission] RECIPE part=$1 v=$2 tier=$3 floor=$4 plan=$5 review=$6 budget=$7 live=$8 overlap=none needs=${9:-none}" "m$1-recipe-v$2"; }
planline() { lg "[mission] part=$1 name=p$1 phase=plan round=$2 dry=0 open=$3" "m$1-plan-r$2-d0"; }
impl()  { lg "[mission] part=$1 name=p$1 phase=implement round=$2 dry=0" "m$1-implement-r$2-d0"; }
# code_report <base12> <head12> <scope:delta|full> <codex N> <claude N> <verify:ok|failed|deferred> <blocking> [TAG rows...]
# -> echoes the report path inside a fake codex-review run dir
code_report() {
  _d=$(mktemp -d "${TMPDIR:-/tmp}/codex-review.XXXXXX"); TMPS="$TMPS $_d"
  _base=$1 _head=$2 _sc=$3 _cx=$4 _cl=$5 _vf=$6 _bl=$7; shift 7
  _tagged=$#; _new=0; _rep=0
  for t in "$@"; do case "$t" in *"| new |"*) _new=$((_new+1)) ;; *"| repeat |"*) _rep=$((_rep+1)) ;; esac; done
  case "$_vf" in ok) _vt="Verify: ok tagged=${TAGGED:-$_tagged} blocking=$_bl | Ledger: new=$_new repeat=$_rep | Areas-new: -" ;;
                 *) _vt="Verify: $_vf" ;; esac
  { echo "# Codex Review: part"
    echo "Engine: 4x Codex + 3x Claude + Codex Verification | Model: gpt-6.1-sol | Codex-passes: $_cx/4 | Claude-lenses: $_cl/3 | Verified: Y | Scope: $_sc base=$_base head=$_head | $_vt"
    echo; echo "## Verify tags"; for t in "$@"; do echo "$t"; done; } > "$_d/report-final.md"
  printf 'WORKDIR=%s\nRUN_SHA=%s\nSCOPE=%s\n' "$W" "$_head" "$_sc" > "$_d/meta.env"
  printf '%s' "$_d/report-final.md"
}
plan_report() { # plan_report <K> <lanes N> <verify> <blocking> [TAG rows]
  _d=$(mktemp -d "${TMPDIR:-/tmp}/planrev.XXXXXX"); TMPS="$TMPS $_d"; _k=$1 _ln=$2 _vf=$3 _bl=$4; shift 4
  _new=0; _rep=0; for t in "$@"; do case "$t" in *"| new |"*) _new=$((_new+1)) ;; *) _rep=$((_rep+1)) ;; esac; done
  { echo "Plan-review: round=$_k | Model: gpt-6.1-sol | Plan-lanes: $_ln/4 | Verify: $_vf tagged=$# blocking=$_bl | Ledger: new=$_new repeat=$_rep | Areas-new: - | Design-new: $_new | Open-design: 0"
    echo; for t in "$@"; do echo "$t"; done; } > "$_d/plan-review.md"
  printf '%s' "$_d/plan-review.md"
}
IMPLOUT() { _f=$(mktemp "${TMPDIR:-/tmp}/impl.XXXXXX"); TMPS="$TMPS $_f"; echo "no findings" > "$_f"; printf '%s' "$_f"; }
tag() { printf 'TAG | %s | %s | IMPL | %s | x' "$1" "$2" "${3:-src}"; }
suite_report() { # suite_report <sha12> <base12> <cmd> <env> <completed> <infra> [reds "id | sig"...]
  _f=$(mktemp "${TMPDIR:-/tmp}/suite.XXXXXX"); TMPS="$TMPS $_f"
  { echo "sha=$1"; echo "base=$2"; echo "command=$3"; echo "env=$4"; echo "completed=$5"; echo "infra=$6"; echo "--"
    shift 6; for r in "$@"; do echo "$r"; done; } > "$_f"; printf '%s' "$_f"; }
keyhash() { printf '%s\n%s' "$1" "$2" | shasum -a 256 | cut -c1-16; }
suite_line() { # suite_line <N> <sha> <att> <report> <newreds>
  _ks=$(sed -n 's/^command=//p' "$4"); _ke=$(sed -n 's/^env=//p' "$4"); _kb=$(sed -n 's/^base=//p' "$4")
  lg "[mission] FULL-SUITE part=$1 sha=$2 attempt=$3 base=$_kb env=$(keyhash "$_ks" "$_ke") completed=yes new-reds=$5 report=$4" "m$1-suite-$2-a$3"; }
live() { # live <N> <sha> <att> <status...>
  case "$4" in sent) _sfx=sent ;; *) _sfx=result ;; esac
  lg "[mission] live-verify part=$1 sha=$2 attempt=$3 status=$4" "m$1-live-$2-a$3-$_sfx"; }
# start_part <N> <needs> -> proto=2 PART-START + RECIPE v1 (normal, live=no) + plan open=0 + implement
start_part() { ps2 "$1" "$W" "$B" "${2:-none}" >/dev/null; recipe "$1" 1 normal none 5 8 300 no "${2:-none}" >/dev/null
  planline "$1" 1 0 >/dev/null; impl "$1" 2 >/dev/null; }
# drive_to_done <N> -> commit, clean delta, close, suite, live n/a, join, PART-DONE. echoes the last status.
drive_to_done() {
  _h=$(commit "$W" "work-$1-$RANDOM")
  mw bank-review "$S" "$R" "$1" 3 delta "$(code_report "$B" "$_h" full 4 3 ok 0)" "$(IMPLOUT)" >/dev/null
  mw bank-review "$S" "$R" "$1" 4 close "$(code_report "$B" "$_h" full 4 3 ok 0)" "$(IMPLOUT)" >/dev/null
  suite_line "$1" "$_h" 1 "$(suite_report "$_h" "$B" "npm test" "w1|app|c1" yes 0)" 0 >/dev/null
  live "$1" "$_h" 1 "n/a reason=no-ui" >/dev/null
  mw bank-review "$S" "$R" "$1" 5 join >/dev/null
  lg "[mission] PART-DONE part=$1 (converged)" "m$1-part-done"
}

echo "== 1 RECIPE =="
mk recipe
has "rc=4" "$(recipe 1 1 high none 7 15 480 no)" "1a RECIPE before PART-START refused"
has "log ok" "$(ps2 1 "$W" "$B")" "1b proto=2 PART-START accepted (negative control)"
has "rc=1" "$(planline 1 1 2)" "1c proto=2 phase=plan without RECIPE refused"
has "FAILED" "$(recipe 1 1 normal phi 5 8 300 no)" "1d floor without tier=high refused"
has "FAILED" "$(recipe 1 1 low none 3 3 999 no)" "1e budget above the tier table refused"
has "FAILED" "$(recipe 1 1 normal none 5 9 300 no)" "1f review budget above the tier table refused"
has "FAILED" "$(recipe 1 2 normal none 5 8 300 no)" "1g RECIPE v2 before v1 / without an overrun refused"
has "log ok" "$(recipe 1 1 high phi 7 15 480 no)" "1h floor=phi tier=high accepted"
has "FAILED" "$(recipe 1 2 high phi 7 15 480 no)" "1i RECIPE v2 without an overrun refused"
has "FAILED" "$(recipe 1 3 high phi 7 15 480 no)" "1j RECIPE v3 refused"
has "log ok" "$(recipe 1 1 high phi 7 15 480 no)" "1k identical RECIPE retry dedups (keeps original at=)"
eq 1 "$(grep -ac 'RECIPE part=1 v=1' "$R/MISSION.$S.log")" "1l dedup wrote no second RECIPE line"
has "FAILED" "$(lg "[mission] RECIPE part=1 v=1 tier=high floor=phi plan=7 review=15 budget=480 live=no overlap=none needs=none at=5" m1-recipe-v1)" "1m caller-supplied at= refused"
has "log ok" "$(planline 1 1 0)" "1n phase=plan with RECIPE accepted"

echo "== 2 Cutover =="
mk cut
OUT=$(lg "[mission] PART-START part=1 name=x" m1-part-start)
has "rc=4" "$OUT" "2a legacy PART-START refused"; has "$RELOAD" "$OUT" "2b cutover refusal names the playbook reload"
# grandfathered legacy part 1 (fabricated pre-cutover), converges on the OLD fold
fab "[mission] PART-START part=1 name=x" m1-part-start
lg "[mission] part=1 name=x phase=implement round=1 dry=0" m1-implement-r1-d0 >/dev/null
lg "[mission] part=1 name=x phase=review round=2 dry=1 findings=0" m1-review-r2-d1 >/dev/null
lg "[mission] part=1 name=x phase=review round=3 dry=2 findings=0" m1-review-r3-d2 >/dev/null
lg "[mission] live-verify part=1 round=3 status=n/a reason=tooling" m1-live-verify-r3 >/dev/null
has "log ok" "$(lg "[mission] PART-DONE part=1 (converged)" m1-part-done)" "2c grandfathered open part passes on the old fold"
grep -aq 'ANCHOR part=1 sha=' "$R/MISSION.$S.log" && ok "2d legacy PART-DONE after cutover writes its ANCHOR" || bad "2d ANCHOR missing"
A1=$(grep -a 'ANCHOR part=1' "$R/MISSION.$S.log" | sed -n 's/.*sha=\([0-9a-f]*\).*/\1/p')
has "FAILED" "$(lg "[mission] ANCHOR part=1 sha=$A1" m1-anchor)" "2e ANCHOR is writer-only (log refuses it)"
# proto=2 part 2 needs legacy part 1: base WITHOUT the anchor refused; base containing it admitted
OLD=$(git -C "$R" rev-list --max-parents=0 HEAD | cut -c1-12)
commit "$R" "after-anchor" >/dev/null
has "log ok" "$(ps2 2 "$W" "$B" 1)" "2f proto=2 part needing legacy part 1 admitted when the ANCHOR is in its base"
mk cut2
fab "[mission] PART-START part=1 name=x" m1-part-start
fab "[mission] PART-DONE part=1 (converged)" m1-part-done
NEWROOT=$(commit "$R" "root-moves")
fab "[mission] ANCHOR part=1 sha=$NEWROOT" m1-anchor
has "rc=4" "$(ps2 2 "$W" "$B" 1)" "2g base lacking the legacy ANCHOR refused"
mk cut3
start_part 1
has "FAILED" "$(lg "[mission] REVIEW-EVIDENCE part=1 round=3 codex=4/4 claude=3/3 report=$W/code.txt" m1-review-evidence-r3)" "2i legacy REVIEW-EVIDENCE on a proto=2 part refused"
has "FAILED" "$(lg "[mission] part=9 name=z phase=research round=1 dry=0" m9-research-r1-d0)" "2j cut-over mission: round line for an unstarted part refused"

echo "== 3 Budget =="
mk budget
fab "[mission] PART-START part=1 name=p1 proto=2 worktree=$W base=$B needs=none at=$((NOW - 400*60))" m1-part-start
fab "[mission] RECIPE part=1 v=1 tier=normal floor=none plan=5 review=8 budget=300 live=yes overlap=none needs=none at=$((NOW - 399*60))" m1-recipe-v1
has "over part=1" "$(mw budget-state "$S" "$R")" "3a budget-state over after 400 min of a 300 min budget"
has "replan=1" "$(mw budget-state "$S" "$R")" "3b first overrun offers one re-plan"
has "part-over-budget" "$(planline 1 1 0)" "3c work write refused when over"
has "log ok" "$(recipe 1 2 normal none 5 8 300 yes)" "3d RECIPE v2 accepted once on a real overrun"
eq ok "$(mw budget-state "$S" "$R")" "3e RECIPE v2 resets the clock"
has "log ok" "$(planline 1 1 0)" "3f work write accepted after the re-plan"
mk budget2
fab "[mission] PART-START part=1 name=p1 proto=2 worktree=$W base=$B needs=none at=$((NOW - 900*60))" m1-part-start
fab "[mission] RECIPE part=1 v=1 tier=normal floor=none plan=5 review=8 budget=300 live=yes overlap=none needs=none at=$((NOW - 899*60))" m1-recipe-v1
fab "[mission] RECIPE part=1 v=2 tier=normal floor=none plan=5 review=8 budget=300 live=yes overlap=none needs=none at=$((NOW - 400*60))" m1-recipe-v2
has "replan=0" "$(mw budget-state "$S" "$R")" "3g second overrun leaves only park (replan=0)"
has "FAILED" "$(recipe 1 3 normal none 5 8 300 yes)" "3h no third recipe"
# pause: live is the ONLY open leg -> paused; close result missing -> clock runs
mk pause
H=$(git -C "$W" rev-parse HEAD | cut -c1-12)
fab "[mission] PART-START part=1 name=p1 proto=2 worktree=$W base=$B needs=none at=$((NOW - 320*60))" m1-part-start
fab "[mission] RECIPE part=1 v=1 tier=normal floor=none plan=5 review=8 budget=300 live=yes overlap=none needs=none at=$((NOW - 319*60))" m1-recipe-v1
fab "[mission] FULL-SUITE part=1 sha=$H attempt=1 base=$B env=e completed=yes new-reds=0 report=/x at=$((NOW - 60*60))" "m1-suite-$H-a1"
fab "[mission] live-verify part=1 sha=$H attempt=1 status=sent at=$((NOW - 60*60))" "m1-live-$H-a1-sent"
has "over part=1" "$(mw budget-state "$S" "$R")" "3i clock keeps running after status=sent while the close review is unfinished"
fab "[mission] REVIEW-EVIDENCE part=1 round=4 scope=close base=$B head=$H codex=4/4 claude=3/3 tagged=0 blocking=0 new=0 repeat=0 rkeys=- result=clean report=/x at=$((NOW - 60*60))" m1-review-evidence-close-r4
has "paused live=60" "$(mw budget-state "$S" "$R")" "3j pauses only when live proof is the sole open leg (close banked on its own)"
has "FAILED" "$(mw bank-review "$S" "$R" 1 5 join)" "3k join still refused while live has no result"
# cumulative live waits across failed closes park at 120
mk pause2
H=$(git -C "$W" rev-parse HEAD | cut -c1-12)
fab "[mission] PART-START part=1 name=p1 proto=2 worktree=$W base=$B needs=none at=$((NOW - 200*60))" m1-part-start
fab "[mission] RECIPE part=1 v=1 tier=high floor=none plan=7 review=15 budget=480 live=yes overlap=none needs=none at=$((NOW - 199*60))" m1-recipe-v1
for a in 1 2; do
  t0=$((NOW - (200 - a*70)*60))
  fab "[mission] REVIEW-EVIDENCE part=1 round=$((a+3)) scope=close base=$B head=$H codex=4/4 claude=3/3 tagged=0 blocking=0 new=0 repeat=0 rkeys=- result=clean report=/x at=$t0" "m1-review-evidence-close-r$((a+3))"
  fab "[mission] FULL-SUITE part=1 sha=$H attempt=$a base=$B env=e completed=yes new-reds=0 report=/x at=$t0" "m1-suite-$H-a$a"
  fab "[mission] live-verify part=1 sha=$H attempt=$a status=sent at=$t0" "m1-live-$H-a$a-sent"
  fab "[mission] live-verify part=1 sha=$H attempt=$a status=fail reason=down at=$((t0 + 65*60))" "m1-live-$H-a$a-result"
done
has "over part=1" "$(mw budget-state "$S" "$R")" "3l paused minutes add up across failed closes and park past 120"

echo "== 4 Park and retire =="
mk park
start_part 1
H1=$(commit "$W" "bad-1"); H2=$(commit "$W" "bad-2")
has "rc=4" "$(lg "[mission] PART-RETIRED part=1" m1-part-retired)" "4a PART-RETIRED with neither PART-DONE nor a park FAIL refused"
mw await "$S" "$R" "part=1 phase=review round=3 kind=job op=review-barrier attempt=1 need=3 got=0" >/dev/null
has "kind=job" "$(mw await-state "$S" "$R")" "4b (control) the open job AWAIT gates before retirement"
has "FAILED" "$(lg "[mission] FAIL part=1 park=over-budget disposition=isolated range=$H1..$H2" m1-fail-park)" "4c park range not starting at the PART-START base refused"
has "log ok" "$(lg "[mission] FAIL part=1 park=over-budget disposition=isolated range=$B..$H2" m1-fail-park)" "4d park FAIL with park=, disposition and range accepted"
has "log ok" "$(lg "[mission] PART-RETIRED part=1" m1-part-retired)" "4e PART-RETIRED after a park FAIL accepted"
eq none "$(mw await-state "$S" "$R")" "4f the retired part's job AWAIT no longer gates the wake"
FAILS0=$(grep -ac 'FAIL part=' "$R/MISSION.$S.log")
has "part-retired" "$(mw await "$S" "$R" "part=1 phase=review round=3 kind=job op=review-barrier attempt=1 need=3 got=2")" "4g a late completion for the retired part is refused (expected drop)"
eq "$FAILS0" "$(grep -ac 'FAIL part=' "$R/MISSION.$S.log")" "4h the late drop wrote no FAIL"
has "part-retired" "$(lg "[mission] part=1 name=p1 phase=fix round=4 dry=0" m1-fix-r4-d0)" "4i any later part-1 write refused"
# a human AWAIT still gates
mw pending-stop "$S" "$R" ask 1 3 1 review "approve?" >/dev/null
has "kind=human" "$(mw await-state "$S" "$R")" "4j a human AWAIT still gates after retirement"
# isolation: a base holding an earlier commit of the range (not the tip) is refused; an independent base proceeds
mk iso
start_part 1
H1=$(commit "$W" "bad-1"); H2=$(commit "$W" "bad-2")
lg "[mission] FAIL part=1 park=blocking disposition=isolated range=$B..$H2" m1-fail-park >/dev/null
lg "[mission] PART-RETIRED part=1" m1-part-retired >/dev/null
W2="${R}-wt2"; wt "$W2" two "$H1"
has "rc=4" "$(ps2 2 "$W2" "$H1")" "4k a base holding an earlier commit of an isolated range is refused"
W3="${R}-wt3"; wt "$W3" three "$B"
has "rc=4" "$(ps2 2 "$W3" "$B" 1)" "4l part needing the parked part is refused"
has "log ok" "$(ps2 3 "$W3" "$B")" "4m an independent part proceeds on the clean base"
# three-part chain: 1 parks, 2 needs 1, 3 needs 2 -> both refused
mk chain
start_part 1
lg "[mission] FAIL part=1 park=blocking disposition=isolated range=$B..$B" m1-fail-park >/dev/null
has "log ok" "$(lg "[mission] PART-RETIRED part=1" m1-part-retired)" "4n empty-range park retires"
has "rc=4" "$(ps2 2 "$W" "$B" 1)" "4o part 2 (needs 1) refused"
has "rc=4" "$(ps2 3 "$W" "$B" 2)" "4p part 3 (needs 2) refused transitively"
has "log ok" "$(ps2 4 "$W" "$B")" "4q empty range blocks nothing: independent part 4 starts on the same base"
# liveness: a park= FAIL is not a stop
SID_L="$S"; mkdir -p "$HOME/.claude/progress"
python3 -c 'import json,sys; sys.stdout.write(json.dumps({"sid":sys.argv[1],"root":sys.argv[2]}))' "$S" "$R" > "$HOME/.claude/progress/mission-liveness-$S.json"
T="$R/t.jsonl"
printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"/mission tick sid=$S root=$R\"}}" \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"parked part 1"}]}}' > "$T"
fab "[mission] FAIL part=4 park=x disposition=isolated range=$B..$B at=$NOW" m4-fail-park
LOUT=$(printf '{"session_id":"%s","prompt_id":"p1","transcript_path":"%s","hook_event_name":"Stop"}' "$S" "$T" | bash "$HOOK" 2>&1); LRC=$?
eq 2 "$LRC" "4r mission-liveness.sh treats a park= FAIL as not a stop (blocks the naked yield)"
mk loud
mission_log_append "$S" "$R" "[mission] PART-START part=1 name=x" m1-part-start >/dev/null 2>&1
fab "[mission] FAIL part=1 phase=review reason=panel-unavailable-3x attempt=1" m1-fail-panel3x-r3
python3 -c 'import json,sys; sys.stdout.write(json.dumps({"sid":sys.argv[1],"root":sys.argv[2]}))' "$S" "$R" > "$HOME/.claude/progress/mission-liveness-$S.json"
T="$R/t.jsonl"
printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"/mission tick sid=$S root=$R\"}}" \
  '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"stop"}]}}' > "$T"
printf '{"session_id":"%s","prompt_id":"p1","transcript_path":"%s","hook_event_name":"Stop"}' "$S" "$T" | bash "$HOOK" >/dev/null 2>&1; LRC=$?
eq 0 "$LRC" "4s (control) a non-park STOP-LOUD FAIL stays a sanctioned stop"

echo "== 5 Plan gate =="
mk pgate
ps2 1 "$W" "$B" >/dev/null; recipe 1 1 normal none 5 8 300 no >/dev/null
planline 1 1 2 >/dev/null
has "FAILED" "$(impl 1 2)" "5a phase=implement refused with open>0"
planline 1 3 0 >/dev/null
has "log ok" "$(impl 1 4)" "5b phase=implement allowed at open=0"

echo "== 6 bank-review =="
mk bank
start_part 1
H=$(commit "$W" "w1")
has "FAILED" "$(lg "[mission] part=1 name=p1 phase=review round=3 dry=1 findings=0" m1-review-r3-d1)" "6a generic log of a dry= raise refused"
has "log ok" "$(lg "[mission] part=1 name=p1 phase=research round=3 dry=0" m1-research-r3-d0)" "6b research line at the current dry passes"
has "VOID" "$(mw bank-review "$S" "$R" 1 3 delta "$(code_report "$B" "$H" full 3 3 ok 0)" "$(IMPLOUT)")" "6c 3/4 Codex VOID"
has "VOID" "$(mw bank-review "$S" "$R" 1 4 delta "$(code_report "$B" "$H" full 4 2 ok 0)" "$(IMPLOUT)")" "6d 2/3 Claude VOID"
has "VOID" "$(mw bank-review "$S" "$R" 1 5 delta "$(code_report "$B" "$H" full 4 3 failed 0)" "$(IMPLOUT)")" "6e verify failed VOID"
has "VOID" "$(mw bank-review "$S" "$R" 1 6 delta "$(code_report "$B" "$H" full 4 3 ok 2 "$(tag K1 new)")" "$(IMPLOUT)")" "6f tagged<blocking VOID"
has "VOID" "$(mw bank-review "$S" "$R" 1 7 delta "$(code_report "$B" "$H" full 4 3 ok 0)")" "6g missing implementation-reviewer output VOID"
FORGED="$R/report-final.md"; cp "$(code_report "$B" "$H" full 4 3 ok 0)" "$FORGED"
has "VOID" "$(mw bank-review "$S" "$R" 1 8 delta "$FORGED" "$(IMPLOUT)")" "6h forged report (not in a codex-review run dir) VOID"
PR=$(plan_report 2 4 ok 0)
has "bank-review ok" "$(mw bank-review "$S" "$R" 1 2 plan "$PR")" "6i plan round with its 4 plan lanes is complete"
has "VOID" "$(mw bank-review "$S" "$R" 1 2 plan "$(plan_report 2 3 ok 0)")" "6j plan round with 3/4 lanes VOID"
printf 'dirty\n' > "$W/untracked.txt"
has "FAILED" "$(mw bank-review "$S" "$R" 1 9 delta "$(code_report "$B" "$H" full 4 3 ok 0)" "$(IMPLOUT)")" "6k dirty tree refuses dry=1"
rm -f "$W/untracked.txt"
has "FAILED" "$(mw bank-review "$S" "$R" 1 9 delta "$(code_report "$B" "$B" full 4 3 ok 0)" "$(IMPLOUT)")" "6l HEAD != report head refuses dry=1"
has "dry=1" "$(mw bank-review "$S" "$R" 1 9 delta "$(code_report "$B" "$H" full 4 3 ok 0)" "$(IMPLOUT)")" "6m clean round banks dry=1"
has "FAILED" "$(mw bank-review "$S" "$R" 1 10 close "$(code_report "$H" "$H" full 4 3 ok 0)" "$(IMPLOUT)")" "6n close with the wrong base refused"
has "FAILED" "$(mw bank-review "$S" "$R" 1 10 close "$(code_report "$B" "$B" full 4 3 ok 0)" "$(IMPLOUT)")" "6o close with the wrong head refused"
has "FAILED" "$(mw bank-review "$S" "$R" 1 10 join)" "6p join before all three legs refused"
has "result=clean" "$(mw bank-review "$S" "$R" 1 10 close "$(code_report "$B" "$H" full 4 3 ok 0)" "$(IMPLOUT)")" "6q close result banks before the other legs"
# dirty round reports new/repeat + blocking, dry stays 0
mk bank2
start_part 1
H=$(commit "$W" "w1")
OUT=$(mw bank-review "$S" "$R" 1 3 delta "$(code_report "$B" "$H" full 4 3 ok 2 "$(tag NULL-DEREF new)" "$(tag RACE repeat)")" "$(IMPLOUT)")
has "dry=0" "$OUT" "6r blocking round banks dry=0"; has "sweep=required" "$OUT" "6s repeat type demands a sweep"

echo "== 7 Close =="
mk close
start_part 1
H=$(commit "$W" "w1")
mw bank-review "$S" "$R" 1 3 delta "$(code_report "$B" "$H" full 4 3 ok 0)" "$(IMPLOUT)" >/dev/null
mw bank-review "$S" "$R" 1 4 close "$(code_report "$B" "$H" full 4 3 ok 0)" "$(IMPLOUT)" >/dev/null
SR=$(suite_report "$H" "$B" "npm test" "w1|app|c1" yes 0)
has "FAILED" "$(lg "[mission] FULL-SUITE part=1 sha=$H attempt=1 base=$B env=$(keyhash "npm test" "w1|app|c1") completed=no new-reds=0 report=$SR" "m1-suite-$H-a1")" "7a FULL-SUITE completed!=yes refused"
has "log ok" "$(suite_line 1 "$H" 1 "$SR" 0)" "7b passing FULL-SUITE at the freeze accepted"
has "FAILED" "$(live 1 "$B" 1 sent)" "7c live-verify at another SHA refused"
has "log ok" "$(live 1 "$H" 1 sent)" "7d live sent"
has "log ok" "$(live 1 "$H" 1 "fail reason=service-restart")" "7e live result at the same SHA (no idtag collision with sent)"
has "FAILED" "$(mw bank-review "$S" "$R" 1 5 join)" "7f join refused on a failed live leg"
has "log ok" "$(live 1 "$H" 2 "ok evidence=tok-1")" "7g infra rerun as attempt 2 at the same SHA"
has "dry=2" "$(mw bank-review "$S" "$R" 1 5 join)" "7h later passing attempt supersedes the failure: join banks dry=2 (no delta, no reset)"
has "log ok" "$(lg "[mission] PART-DONE part=1 (converged)" m1-part-done)" "7i PART-DONE at the freeze accepted"
mk close2
ps2 1 "$W" "$B" >/dev/null; recipe 1 1 normal none 5 8 300 yes >/dev/null; planline 1 1 0 >/dev/null; impl 1 2 >/dev/null
H=$(commit "$W" "w1")
mw bank-review "$S" "$R" 1 3 delta "$(code_report "$B" "$H" full 4 3 ok 0)" "$(IMPLOUT)" >/dev/null
has "FAILED" "$(live 1 "$H" 1 "n/a reason=no-ui")" "7j live=yes with n/a refused"
has "log ok" "$(lg "[mission] part=1 name=p1 phase=fix round=4 dry=0" m1-fix-r4-d0)" "7k a fix after a red resets dry (allowed)"
has "FAILED" "$(mw bank-review "$S" "$R" 1 5 close "$(code_report "$B" "$H" full 4 3 ok 0)" "$(IMPLOUT)")" "7l close refused after the dry reset (no current freeze)"

echo "== 8 Sweep =="
mk sweep
start_part 1
H=$(commit "$W" "w1")
mw bank-review "$S" "$R" 1 3 delta "$(code_report "$B" "$H" full 4 3 ok 2 "$(tag K-A repeat)" "$(tag K-B repeat)")" "$(IMPLOUT)" >/dev/null
lg "[mission] part=1 name=p1 phase=fix round=4 dry=0" m1-fix-r4-d0 >/dev/null
H0=$H; H=$(commit "$W" "fix")
SWR="$R/sweep.txt"; echo clean > "$SWR"
lg "[mission] SWEEP part=1 round=4 types=K-A sha=$H instances=0 report=$SWR" m1-sweep-r4-s1 >/dev/null
has "dry=1" "$(mw bank-review "$S" "$R" 1 5 delta "$(code_report "$H0" "$H" delta 4 3 ok 0)" "$(IMPLOUT)")" "8a0 delta after the fix reviews from the last reviewed head"
mw bank-review "$S" "$R" 1 6 close "$(code_report "$B" "$H" full 4 3 ok 0)" "$(IMPLOUT)" >/dev/null
suite_line 1 "$H" 1 "$(suite_report "$H" "$B" "npm test" "w1|app|c1" yes 0)" 0 >/dev/null
live 1 "$H" 1 "n/a reason=no-ui" >/dev/null
mw bank-review "$S" "$R" 1 7 join >/dev/null
has "rc=4" "$(lg "[mission] PART-DONE part=1 (converged)" m1-part-done)" "8a clean sweep missing one repeat key refused"
mk sweep2
start_part 1
H=$(commit "$W" "w1")
mw bank-review "$S" "$R" 1 3 delta "$(code_report "$B" "$H" full 4 3 ok 1 "$(tag K-A repeat)")" "$(IMPLOUT)" >/dev/null
SWR="$R/sweep.txt"; echo clean > "$SWR"
lg "[mission] SWEEP part=1 round=3 types=K-A sha=$H instances=0 report=$SWR" m1-sweep-r3-s1 >/dev/null
lg "[mission] part=1 name=p1 phase=fix round=4 dry=0" m1-fix-r4-d0 >/dev/null
H0=$H; H=$(commit "$W" "fix")
mw bank-review "$S" "$R" 1 5 delta "$(code_report "$H0" "$H" delta 4 3 ok 0)" "$(IMPLOUT)" >/dev/null
mw bank-review "$S" "$R" 1 6 close "$(code_report "$B" "$H" full 4 3 ok 0)" "$(IMPLOUT)" >/dev/null
suite_line 1 "$H" 1 "$(suite_report "$H" "$B" "npm test" "w1|app|c1" yes 0)" 0 >/dev/null
live 1 "$H" 1 "n/a reason=no-ui" >/dev/null
mw bank-review "$S" "$R" 1 7 join >/dev/null
has "rc=4" "$(lg "[mission] PART-DONE part=1 (converged)" m1-part-done)" "8b sweep before the last fix refused"
lg "[mission] SWEEP part=1 round=7 types=K-A sha=$H instances=0 report=$SWR" m1-sweep-r7-s2 >/dev/null
has "log ok" "$(lg "[mission] PART-DONE part=1 (converged)" m1-part-done)" "8c (control) a covering sweep after the last fix passes"

echo "== 9 FULL-SUITE and known reds =="
mk reds
start_part 1
H=$(commit "$W" "w1")
CMD="npx vitest run"; ENV="w1|app_rw|cfg1"
BR=$(suite_report "$B" "$B" "$CMD" "$ENV" yes 0 "t/a.test.ts > sums | expected 3 received 120" "t/b.test.ts > time | failed at 2026-11-11T10:00:00Z in /var/folders/ab/T/x1 after 12ms")
has "known-reds ok" "$(mw known-reds "$S" "$R" record "$BR")" "9a baseline recorded from a completed base run"
ls "$R/.mission-known-reds/$B-$(keyhash "$CMD" "$ENV").txt" >/dev/null 2>&1 && ok "9b baseline file keyed by base + command + env" || bad "9b baseline file missing"
RUN=$(suite_report "$H" "$B" "$CMD" "$ENV" yes 0 "t/a.test.ts > sums | expected 3 received 120" "t/b.test.ts > time | failed at 2026-11-12T01:02:03Z in /var/folders/zz/T/y9 after 40ms")
eq 0 "$(mw known-reds "$S" "$R" diff "$RUN")" "9c timestamp / temp-path / duration differences alone do not count as new"
RUN2=$(suite_report "$H" "$B" "$CMD" "$ENV" yes 0 "t/a.test.ts > sums | expected 3 received 500")
eq 1 "$(mw known-reds "$S" "$R" diff "$RUN2")" "9d numeric-only assertion change counts as new"
RUN3=$(suite_report "$H" "$B" "$CMD" "w2|app_rw|cfg1" yes 0 "t/a.test.ts > sums | expected 3 received 120")
eq 1 "$(mw known-reds "$S" "$R" diff "$RUN3")" "9e a baseline with a different worker is not used"
RUN4=$(suite_report "$H" "$B" "npx vitest run --shard 1" "$ENV" yes 0 "t/a.test.ts > sums | expected 3 received 120")
eq 1 "$(mw known-reds "$S" "$R" diff "$RUN4")" "9f a baseline with a different command is not used"
INF=$(suite_report "$B" "$B" "$CMD" "w9|x|y" yes 2 "t/c.test.ts > db | ECONNREFUSED")
has "FAILED" "$(mw known-reds "$S" "$R" record "$INF")" "9g a run with infra failures is never written to a baseline"
has "FAILED" "$(suite_line 1 "$H" 1 "$RUN2" 0)" "9h FULL-SUITE whose new-reds disagrees with the recomputed count refused"
has "log ok" "$(suite_line 1 "$H" 2 "$RUN" 0)" "9i FULL-SUITE with only known reds accepted"

echo "== 10 Overlap and stacking =="
mk stack
start_part 1
has "rc=4" "$(ps2 2 "$W" "$B")" "10a PART-START for N+1 refused while N is open"
has "FAILED" "$(recipe 2 1 high none 7 15 480 no)" "10b RECIPE for N+1 refused before its PART-START"
has "FAILED" "$(planline 2 1 0)" "10c plan line for N+1 refused before its PART-START"
has "log ok" "$(drive_to_done 1)" "10d part 1 reaches PART-DONE"
F1=$(git -C "$W" rev-parse HEAD | cut -c1-12)
W2="${R}-wt2"; wt "$W2" two "$F1"
has "log ok" "$(ps2 2 "$W2" "$F1" 1)" "10e N+1 starts on N's freeze SHA (no AWAIT, push pending)"
has "log ok" "$(recipe 2 1 high none 7 15 480 no 1)" "10f tier raised at the boundary banks as v1"
eq 0 "$(grep -ac 'RECIPE part=2 v=2' "$R/MISSION.$S.log")" "10g v2 untouched"
mk stack2
start_part 1
lg "[mission] FAIL part=1 park=over-budget disposition=isolated range=$B..$B" m1-fail-park >/dev/null
lg "[mission] PART-RETIRED part=1" m1-part-retired >/dev/null
W2="${R}-wt2"; wt "$W2" two "$B"
ps2 2 "$W2" "$B" >/dev/null; recipe 2 1 normal none 5 8 300 no >/dev/null; planline 2 1 0 >/dev/null
has "log ok" "$(impl 2 2)" "10h after a park, an independent N+1 starts and reaches implementation"

echo "== 11 Fingerprint =="
mk fp
start_part 1
H=$(commit "$W" "w1")
mw bank-review "$S" "$R" 1 3 delta "$(code_report "$B" "$H" full 4 3 ok 0)" "$(IMPLOUT)" >/dev/null
mw bank-review "$S" "$R" 1 4 close "$(code_report "$B" "$H" full 4 3 ok 0)" "$(IMPLOUT)" >/dev/null
suite_line 1 "$H" 1 "$(suite_report "$H" "$B" "npm test" "w1|app|c1" yes 0)" 0 >/dev/null
live 1 "$H" 1 "n/a reason=no-ui" >/dev/null
mw bank-review "$S" "$R" 1 5 join >/dev/null
printf 'main-checkout edit\n' >> "$R/code.txt"
has "CLEAR" "$(bash "$DC" "$S" "$R")" "11a main-checkout change does not stale the part (drift-check)"
( cd "$W" && git commit -q --allow-empty -m "same tree" ) >/dev/null 2>&1
has "CLEAR" "$(bash "$DC" "$S" "$R")" "11b commit-after-converge on the same tree does not stale"
printf 'wt edit\n' >> "$W/code.txt"
has "DRIFT" "$(bash "$DC" "$S" "$R")" "11c worktree change stales the part"
has "rc=4" "$(lg "[mission] PART-DONE part=1 (converged)" m1-part-done)" "11d PART-DONE refused on a worktree change"
( cd "$W" && git checkout -q code.txt )
has "log ok" "$(lg "[mission] PART-DONE part=1 (converged)" m1-part-done)" "11e PART-DONE accepted once the worktree matches the freeze tree"
# v1 snapshot still compares with v1 (legacy part, root fingerprint)
mk fpv1
fab "[mission] PART-START part=1 name=x" m1-part-start
lg "[mission] part=1 name=x phase=review round=1 dry=1 findings=0" m1-review-r1-d1 >/dev/null
lg "[mission] part=1 name=x phase=review round=2 dry=2 findings=0" m1-review-r2-d2 >/dev/null
has "CLEAR" "$(bash "$DC" "$S" "$R")" "11f v1 snapshot compares with v1 (clean)"
printf 'edit\n' >> "$R/code.txt"
has "DRIFT" "$(bash "$DC" "$S" "$R")" "11g v1 snapshot still detects a root change"

echo "== wake origin =="
PY="$HERE/lib/mission-liveness-parse.py"
TN='{"type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>\n<task-id>x</task-id>\n<status>completed</status>\n</task-notification>"}}'
AS='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}'
eq no "$(printf '%s\n' '{"type":"user","message":{"role":"user","content":"/mission tick sid=SIDX root=/r"}}' "$AS" "$TN" "$AS" | python3 "$PY" SIDX)" "wo1 a background completion inside a wake chain is autonomous (judged)"
eq human "$(printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}' "$AS" "$TN" "$AS" | python3 "$PY" SIDX)" "wo2 (control) a background completion inside a human turn stays human"

printf '\nPASS: %s  FAIL: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
