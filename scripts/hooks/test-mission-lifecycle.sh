#!/usr/bin/env bash
# test-mission-lifecycle.sh - end-to-end lifecycle traces for the /mission proto=2 contract (rework plan
# v5, section 7.2 test 14). Where test-mission-proto2.sh proves each writer gate on its own, this file
# drives WHOLE parts through the real writer, in the order the playbook (commands/mission.md) and the
# wake routine (docs/mission/wake.md) tell a conductor to, and reads the result back through the real
# status reader (lib/mission-status.sh) and the wake.md resume read. It exists because the four rework
# chunks were built in parallel against the plan, not against each other: the seams (writer line
# shapes vs the status reader, the morning report wiring, deferred parts that leave no log line, the
# resume read after a compaction) are only proven by running them together.
#
# Traces:
#   A  clean first review -> close (three legs, live wait pauses the clock) -> join -> PART-DONE
#   B  failed close (blocking close review) -> repair -> new freeze; then an infra-failed live leg rerun
#      at the same SHA as attempt+1 (no delta round, no dry reset)
#   C  delta rounds with a repeat type -> dirty sweep -> a clean sweep missing the key is not enough ->
#      covering sweep -> PART-DONE
#   D  over budget (re-plan spent) -> park with an isolated range while a job barrier is outstanding ->
#      retirement drops late completions -> transitive deferral (2 needs 1, 3 needs 2) -> an
#      independent successor whose base holds an isolated commit is refused, one on a clean base
#      reaches implementation
#   E  legacy part finished on the old fold -> ANCHOR -> proto=2 cutover gated on the ANCHOR -> lines
#      for un-started parts and legacy PART-STARTs refused after cutover
#   F  compaction mid-close: a cold reader runs wake.md's verbatim §8 resume read, the decision table
#      row, and the writer names the one missing leg; only that leg is relaunched
#   G  cutover safety (pre-land review land-r1-p2): a legacy part's wake at ready=1 and dry=1/dry=2
#      never reaches proto=2-only verbs; a human AWAIT on a retired part still closes; clean close
#      evidence supersedes its review AWAIT; a cold wake after join finalizes instead of restarting
#      review; frozen-tree drift at dry=1 is routed to repair before the close row
#   H  correctness (pre-land review land-r1-p1): join repairs a partial bank; PART-START binds base to
#      the worktree HEAD; stale live attempts stop pausing the clock and overlapping pauses merge;
#      known-red signatures keep long numeric/hex assertion values; part=08 never trips bash octal
#
# Real throwaway git repos and the real writer; history that must look OLD (a budget clock, a legacy
# part) is fabricated through the lib's raw appender, as test-mission-proto2.sh does. Hermetic: every
# status-reader input is pointed at a temp dir. macOS bash 3.2 compatible.
# Prints `PASS: N  FAIL: M`; exit code = FAIL>0.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
MW="$HERE/mission-write.sh"
ST="$HERE/lib/mission-status.sh"
WAKE="$HERE/../../docs/mission/wake.md"
. "$HERE/lib/mission-bridge.sh" || { echo "FATAL: cannot source lib"; exit 2; }
for f in "$MW" "$ST" "$WAKE"; do [ -r "$f" ] || { echo "FATAL: cannot read $f"; exit 2; }; done

PASS=0; FAIL=0; TMPS=""; SIDS=""
ok()    { PASS=$((PASS + 1)); printf '  ok  %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; }
has()   { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 [missing '$1' in: $(printf '%s' "$2" | head -c 400)]" ;; esac; }
hasnt() { case "$2" in *"$1"*) bad "$3 [unexpected '$1' in: $(printf '%s' "$2" | head -c 400)]" ;; *) ok "$3" ;; esac; }
eq()    { [ "$1" = "$2" ] && ok "$3" || bad "$3 [expected '$1' == '$2']"; }
UNIQ="lct$$"
trap 'for d in $TMPS; do rm -rf "$d"; done; for s in $SIDS; do rm -f "$HOME/.claude/progress/mission-liveness-$s.json"; done' EXIT

# Hermetic status-reader inputs (the writer's morning refresh inherits these).
ENVD=$(mktemp -d "${TMPDIR:-/tmp}/lct-env.XXXXXX"); TMPS="$TMPS $ENVD"
export MISSION_PUSH_QUEUE="$ENVD/push-queue.md" MISSION_PLANTED_FILE="$ENVD/planted.jsonl" \
       MISSION_LIVENESS_DIR="$ENVD/liveness" MISSION_PROJECTS_DIR="$ENVD/projects"
mkdir -p "$MISSION_LIVENESS_DIR" "$MISSION_PROJECTS_DIR"; : > "$MISSION_PUSH_QUEUE"
NOW=$(date +%s)

# mk <name> -> S (sid), R (mission root repo), W (part-1 linked worktree), B (base sha12)
mk() {
  S="${UNIQ}-$1"; SIDS="$SIDS $S"
  R=$(mktemp -d "${TMPDIR:-/tmp}/lcr.XXXXXX"); TMPS="$TMPS $R"; R=$(cd "$R" && pwd -P)
  ( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
    && printf 'v1\n' > code.txt && git add code.txt && git commit -qm init ) >/dev/null 2>&1
  W="${R}-wt1"; wt "$W" 1 HEAD
  B=$(git -C "$W" rev-parse HEAD | cut -c1-12)
  bash "$MW" create "$S" "$R" "MISSION MODE: build - lifecycle trace" >/dev/null
  mkdir -p "$R/tmp/mission"
}
wt() { git -C "$R" worktree add -q -b "p$2-$$-$RANDOM" "$1" "$3" >/dev/null 2>&1; TMPS="$TMPS $1"
       ( cd "$1" && git config user.email t@t && git config user.name t ) >/dev/null 2>&1; }
commit() { ( cd "$1" && printf '%s\n' "$2" >> code.txt && git add code.txt && git commit -qm "$2" ) >/dev/null 2>&1
           git -C "$1" rev-parse HEAD | cut -c1-12; }
mw()  { bash "$MW" "$@" 2>/dev/null; }
lg()  { mw log "$S" "$R" "$1" "${2:-}"; }
fab() { mission_log_append "$S" "$R" "$1" "$2" >/dev/null 2>&1; }
st()  { bash "$ST" status "$S" "$R" 2>&1; }
logf() { cat "$R/MISSION.$S.log"; }
# The strategist's recipes file (commands/plan.md --roadmap): one machine line per planned part.
plan_recipes() { : > "$R/tmp/mission/recipes.md"; for l in "$@"; do printf -- '- `%s`\n  why: trace\n' "$l" >> "$R/tmp/mission/recipes.md"; done; }
rline() { # rline <N> <tier> <plan> <review> <budget> <live> <needs> [v] -> the machine RECIPE line
  printf '[mission] RECIPE part=%s v=%s tier=%s floor=none plan=%s review=%s budget=%s live=%s overlap=none needs=%s' \
    "$1" "${8:-1}" "$2" "$3" "$4" "$5" "$6" "$7"; }
# Playbook §4 part start: PART-START (with needs=), then the strategist's RECIPE v1 for this part verbatim.
start() { # start <N> <wt> <base12> <needs> <recipe-line>
  _o=$(lg "[mission] PART-START part=$1 name=p$1 proto=2 worktree=$2 base=$3 needs=$4" "m$1-part-start")
  case "$_o" in *"log ok"*) : ;; *) printf '%s' "$_o"; return 0 ;; esac
  lg "$5" "m$1-recipe-v1"; }
# research -> one clean plan round (bank-review plan) -> plan line open=0 -> implement
to_impl() { # to_impl <N>
  lg "[mission] part=$1 name=p$1 phase=research round=1 dry=0" "m$1-research-r1-d0" >/dev/null
  _pr=$(plan_report 2 0); mw bank-review "$S" "$R" "$1" 2 plan "$_pr" >/dev/null
  lg "[mission] part=$1 name=p$1 phase=plan round=2 dry=0 open=0" "m$1-plan-r2-d0" >/dev/null
  lg "[mission] part=$1 name=p$1 phase=implement round=3 dry=0" "m$1-implement-r3-d0"; }
# code_report <wt> <base12> <head12> <delta|full> <blocking> [TAG rows] -> a codex-review run dir report
code_report() {
  _d=$(mktemp -d "${TMPDIR:-/tmp}/codex-review.XXXXXX"); TMPS="$TMPS $_d"
  _w=$1 _b=$2 _h=$3 _sc=$4 _bl=$5; shift 5; _n=0; _r=0
  for t in "$@"; do case "$t" in *"| new |"*) _n=$((_n+1)) ;; *"| repeat |"*) _r=$((_r+1)) ;; esac; done
  { echo "# Codex Review: trace"
    echo "Engine: 4x Codex + 3x Claude + Codex Verification | Model: gpt-6.1-sol | Codex-passes: 4/4 | Claude-lenses: 3/3 | Verified: Y | Scope: $_sc base=$_b head=$_h | Verify: ok tagged=$# blocking=$_bl | Ledger: new=$_n repeat=$_r | Areas-new: -"
    echo; echo "## Verify tags"; for t in "$@"; do echo "$t"; done; } > "$_d/report-final.md"
  printf 'WORKDIR=%s\nRUN_SHA=%s\nSCOPE=%s\n' "$_w" "$(git -C "$_w" rev-parse HEAD)" "$_sc" > "$_d/meta.env"
  printf '%s' "$_d/report-final.md"; }
plan_report() { _d=$(mktemp -d "${TMPDIR:-/tmp}/planrev.XXXXXX"); TMPS="$TMPS $_d"
  echo "Plan-review: round=$1 | Model: gpt-6.1-sol | Plan-lanes: 4/4 | Verify: ok tagged=$2 blocking=$2 | Ledger: new=0 repeat=0 | Areas-new: - | Design-new: 0 | Open-design: 0" > "$_d/plan-review.md"
  printf '%s' "$_d/plan-review.md"; }
IMPL() { _f=$(mktemp "${TMPDIR:-/tmp}/impl.XXXXXX"); TMPS="$TMPS $_f"; echo "no findings" > "$_f"; printf '%s' "$_f"; }
tag() { printf 'TAG | %s | %s | IMPL | %s | trace finding' "$1" "$2" "${3:-src}"; }
# delta/close banking exactly as playbook §4 / §4.6 call it
delta() { mw bank-review "$S" "$R" "$1" "$2" delta "$(code_report "$3" "$4" "$(git -C "$3" rev-parse HEAD | cut -c1-12)" delta "$5" "${@:6}")" "$(IMPL)"; }
closer() { mw bank-review "$S" "$R" "$1" "$2" close "$(code_report "$3" "$4" "$(git -C "$3" rev-parse HEAD | cut -c1-12)" full "$5" "${@:6}")" "$(IMPL)"; }
# full suite exactly as reference.md documents it: report file, env= from `known-reds key`, new-reds= from `known-reds diff`
suite() { # suite <N> <sha12> <attempt> <base12> [reds...]
  _f="$R/tmp/mission/suite-$1-$2-a$3.txt"
  { echo "sha=$2"; echo "base=$4"; echo "command=npm test"; echo "env=w1|app|cfg1"; echo "completed=yes"; echo "infra=0"; echo "--"
    shift 4; for x in "$@"; do echo "$x"; done; } > "$_f"
  _k=$(mw known-reds "$S" "$R" key "$_f"); _nr=$(mw known-reds "$S" "$R" diff "$_f")
  _sn=$(sed -n 's/^sha=//p' "$_f"); _sb=$(sed -n 's/^base=//p' "$_f"); _sa=$(basename "$_f" .txt); _sa=${_sa##*-a}; _spart=$(basename "$_f" | cut -d- -f2)
  lg "[mission] FULL-SUITE part=$_spart sha=$_sn attempt=$_sa base=$_sb env=$_k completed=yes new-reds=$_nr report=$_f" "m$_spart-suite-$_sn-a$_sa"; }
live() { # live <N> <sha12> <attempt> <status...>
  case "$4" in sent) _x=sent ;; *) _x=result ;; esac
  lg "[mission] live-verify part=$1 sha=$2 attempt=$3 status=$4" "m$1-live-$2-a$3-$_x"; }
join() { mw bank-review "$S" "$R" "$1" "$2" join; }
done_() { lg "[mission] PART-DONE part=$1 (converged)" "m$1-part-done"; }
retire() { lg "[mission] PART-RETIRED part=$1" "m$1-part-retired"; }
lastdry() { awk -F'\t' -v p="$1" '$1 ~ ("^(g[0-9]+-)?m" p "-[a-z]+-r[0-9]+-d[0-2]$") && index($2,"[mission] part=" p " ")==1 {l=$2} END{print l}' "$R/MISSION.$S.log" | sed -n 's/.* dry=\([0-2]\).*/\1/p'; }
morning_line() { sed -n 3p "$R/tmp/mission/MORNING.md" 2>/dev/null; }

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "== A clean first review -> close -> PART-DONE =="
mk a
RL=$(rline 1 normal 5 8 300 yes none); plan_recipes "$RL"
has "log ok" "$(start 1 "$W" "$B" none "$RL")" "A1 PART-START (needs=) + RECIPE v1 bank in playbook order"
has "log ok" "$(to_impl 1)" "A2 research -> plan (bank-review plan, open=0) -> implement"
H=$(commit "$W" a-work)
has "ok" "$(mw await "$S" "$R" "part=1 phase=review round=4 kind=job op=review-barrier attempt=1 need=3 got=0")" "A3 review barrier opens"
mw await "$S" "$R" "part=1 phase=review round=4 kind=job op=review-barrier attempt=1 need=3 got=1" >/dev/null
mw await "$S" "$R" "part=1 phase=review round=4 kind=job op=review-barrier attempt=1 need=3 got=2" >/dev/null
has "ready=1" "$(mw await-state "$S" "$R")" "A4 both lanes set their bits -> join-ready"
OUT=$(delta 1 4 "$W" "$B" 0)
has "scope=delta dry=1" "$OUT" "A5 clean round 1 banks dry=1 directly"
eq none "$(mw await-state "$S" "$R")" "A6 the banked round supersedes the job barrier"
has "result=clean" "$(closer 1 5 "$W" "$B" 0)" "A7 close review banks its result on its own"
has "scope=close base=$B head=$H " "$(logf)" "A8 close evidence is REVIEW-EVIDENCE scope=close base=<PART-START base> head=<freeze>"
eq ok "$(mw budget-state "$S" "$R")" "A9 clock runs while the suite and live legs are unfinished"
has "log ok" "$(suite 1 "$H" 1 "$B")" "A10 FULL-SUITE banks with env= and new-reds= from the writer's own known-reds verbs"
has "log ok" "$(live 1 "$H" 1 sent)" "A11 live proof sent"
has "paused live=" "$(mw budget-state "$S" "$R")" "A12 clock pauses only now: live proof is the sole open leg"
has "leg live-proof" "$(join 1 6)" "A13 join refused while the live result is missing"
has "log ok" "$(live 1 "$H" 1 "ok evidence=dt-a1")" "A14 live result lands (distinct -result idtag)"
has "dry=2" "$(join 1 6)" "A15 join banks dry=2"
has "log ok" "$(done_ 1)" "A16 PART-DONE"
has "ANCHOR part=1 sha=$H" "$(logf)" "A17 writer anchors the part at its freeze SHA"
has "1 done" "$(morning_line)" "A18 the writer refreshed MORNING.md at PART-DONE (no conductor step needed)"
has "log ok" "$(retire 1)" "A19 PART-RETIRED"
has "part 1 p1: done | tier normal" "$(st)" "A20 status reads the writer's lines: done, tier from RECIPE"
has "close 1" "$(st)" "A21 status counts one close"
has "known-reds ok" "$(mw known-reds "$S" "$R" record "$R/tmp/mission/suite-1-$H-a1.txt")" "A22 passing close suite recorded as the next baseline"
[ -n "$(ls "$R/.mission-known-reds/$H-"*.txt 2>/dev/null)" ] && ok "A23 baseline keyed by the freeze SHA (next part's base)" || bad "A23 baseline file missing"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "== B failed close -> repair; infra-failed live leg -> same-SHA retry =="
mk b
RL=$(rline 1 normal 5 8 300 yes none); plan_recipes "$RL"
start 1 "$W" "$B" none "$RL" >/dev/null; to_impl 1 >/dev/null
H1=$(commit "$W" b-work)
has "dry=1" "$(delta 1 4 "$W" "$B" 0)" "B1 clean round 1 -> dry=1 at H1"
OUT=$(closer 1 5 "$W" "$B" 1 "$(tag MISSED-GUARD new auth)")
has "result=blocking" "$OUT" "B2 a blocking close review"
eq 0 "$(lastdry 1)" "B3 a failed close resets dry to 0"
has "dry=1" "$(join 1 6)" "B4 join refused after the failed close"
has "log ok" "$(lg "[mission] part=1 name=p1 phase=fix round=5 dry=0 findings=1" "m1-fix-r5-d0")" "B5 fix line (wake table: Repair)"
H2=$(commit "$W" b-fix)
has "dry=1" "$(delta 1 6 "$W" "$H1" 0)" "B6 delta round (base = last reviewed head) -> new freeze H2"
has "FAILED" "$(live 1 "$H1" 1 sent)" "B7 live proof for the old freeze is refused"
has "result=clean" "$(closer 1 7 "$W" "$B" 0)" "B8 close at the new freeze is clean"
has "log ok" "$(suite 1 "$H2" 1 "$B")" "B9 suite at H2"
live 1 "$H2" 1 sent >/dev/null
has "log ok" "$(live 1 "$H2" 1 "fail reason=devtools-restart")" "B10 live leg fails for an infra reason"
has "leg live-proof" "$(join 1 8)" "B11 join refused on the failed live attempt"
NRB=$(grep -ac 'phase=review' "$R/MISSION.$S.log")
has "log ok" "$(live 1 "$H2" 2 sent)" "B12 same-SHA rerun as attempt 2 (no delta round)"
has "log ok" "$(live 1 "$H2" 2 "ok evidence=dt-b2")" "B13 attempt 2 passes and supersedes attempt 1"
eq 1 "$(lastdry 1)" "B14 dry was never reset by the infra retry"
eq "$NRB" "$(grep -ac 'phase=review' "$R/MISSION.$S.log")" "B15 no review round between the failed and passing attempt"
has "dry=2" "$(join 1 8)" "B16 join"
has "log ok" "$(done_ 1)" "B17 PART-DONE"
has "close 2" "$(st)" "B18 status counts both close attempts"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "== C delta rounds with a repeat type and the class sweep =="
mk c
RL=$(rline 1 normal 5 8 300 no none); plan_recipes "$RL"
start 1 "$W" "$B" none "$RL" >/dev/null; to_impl 1 >/dev/null
C1=$(commit "$W" c-work)
has "new=1" "$(delta 1 4 "$W" "$B" 1 "$(tag NULL-DEREF new api)")" "C1 round 1 blocking, new type"
lg "[mission] part=1 name=p1 phase=fix round=4 dry=0 findings=1" "m1-fix-r4-d0" >/dev/null; C2=$(commit "$W" c-fix1)
OUT=$(delta 1 5 "$W" "$C1" 1 "$(tag NULL-DEREF repeat api)")
has "sweep=required types=NULL-DEREF" "$OUT" "C2 a repeat type makes the writer demand a class sweep"
lg "[mission] part=1 name=p1 phase=fix round=5 dry=0 findings=1" "m1-fix-r5-d0" >/dev/null; C3=$(commit "$W" c-fix2)
SW="$R/tmp/mission/sweep.md"; echo "sweep report" > "$SW"
has "log ok" "$(lg "[mission] SWEEP part=1 round=5 types=NULL-DEREF sha=$C3 instances=2 report=$SW" "m1-sweep-r5-s1")" "C3 first sweep finds 2 instances (dirty)"
C4=$(commit "$W" c-sweepfix)
has "log ok" "$(lg "[mission] SWEEP part=1 round=5 types=OTHER-KEY sha=$C4 instances=0 report=$SW" "m1-sweep-r5-s2")" "C4 a clean sweep over the WRONG type key banks"
has "dry=1" "$(delta 1 6 "$W" "$C2" 0)" "C5 clean delta round -> freeze"
closer 1 7 "$W" "$B" 0 >/dev/null; suite 1 "$C4" 1 "$B" >/dev/null
has "log ok" "$(live 1 "$C4" 1 "n/a reason=no-ui")" "C6 live n/a (recipe live=no)"
has "dry=2" "$(join 1 8)" "C7 join"
has "SWEEP covering repeat types" "$(done_ 1)" "C8 PART-DONE refused: no clean sweep covers NULL-DEREF"
has "log ok" "$(lg "[mission] SWEEP part=1 round=5 types=NULL-DEREF sha=$C4 instances=0 report=$SW" "m1-sweep-r5-s3")" "C9 covering clean sweep at HEAD"
has "log ok" "$(done_ 1)" "C10 PART-DONE"
has "sweeps 3 (1 dirty)" "$(st)" "C11 status: three sweeps, one dirty"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "== D over budget -> park (isolated) with a job barrier out; transitive deferral; independent successor =="
mk d
R1=$(rline 1 normal 5 8 300 yes none); R2=$(rline 2 normal 5 8 300 yes 1); R3=$(rline 3 normal 5 8 300 yes 2); R4=$(rline 4 normal 5 8 300 yes none)
plan_recipes "$R1" "$R2" "$R3" "$R4"
fab "[mission] PART-START part=1 name=p1 proto=2 worktree=$W base=$B needs=none at=$((NOW - 500*60))" m1-part-start
fab "$R1 at=$((NOW - 500*60))" m1-recipe-v1
fab "[mission] part=1 name=p1 phase=plan round=1 dry=0 open=0" m1-plan-r1-d0
fab "[mission] part=1 name=p1 phase=implement round=2 dry=0" m1-implement-r2-d0
D1=$(commit "$W" d-work1); D2=$(commit "$W" d-work2)
has "replan=1" "$(mw budget-state "$S" "$R")" "D1 over budget with the re-plan still available"
fab "$(rline 1 normal 5 8 300 yes none 2) at=$((NOW - 400*60))" m1-recipe-v2
has "over part=1 minutes=" "$(mw budget-state "$S" "$R")" "D2 still over after the one re-plan"
has "replan=0" "$(mw budget-state "$S" "$R")" "D3 replan=0 means park"
mw await "$S" "$R" "part=1 phase=review round=3 kind=job op=review-barrier attempt=1 need=3 got=0" >/dev/null
has "part-over-budget" "$(lg "[mission] part=1 name=p1 phase=fix round=3 dry=0 findings=1" "m1-fix-r3-d0")" "D4 every part-1 work write is refused rc=4"
has "log ok" "$(lg "[mission] FAIL part=1 park=over-budget disposition=isolated range=$B..$D2" "m1-fail-park")" "D5 park FAIL (isolated, range base..head)"
has "1 parked" "$(morning_line)" "D6 the writer refreshed MORNING.md at the park"
has "log ok" "$(retire 1)" "D7 PART-RETIRED after the park"
eq none "$(mw await-state "$S" "$R")" "D8 the retired part's job barrier no longer gates the wake"
NF=$(grep -ac '\[mission\] FAIL ' "$R/MISSION.$S.log")
has "part-retired" "$(mw bank-review "$S" "$R" 1 3 delta "$(code_report "$W" "$B" "$D2" delta 0)" "$(IMPL)")" "D9 a late review completion for part 1 is an expected drop"
eq "$NF" "$(grep -ac '\[mission\] FAIL ' "$R/MISSION.$S.log")" "D10 the drop writes no FAIL (tally unchanged)"
W2="${R}-wt2"; wt "$W2" 2 "$B"
has "no PART-DONE (deferred)" "$(start 2 "$W2" "$B" 1 "$R2")" "D11 part 2 (needs 1) refused: deferred"
W3="${R}-wt3"; wt "$W3" 3 "$B"
has "no PART-DONE (deferred)" "$(start 3 "$W3" "$B" 2 "$R3")" "D12 part 3 (needs 2) refused: transitive deferral"
W4x="${R}-wt4x"; wt "$W4x" 4 "$D1"
has "isolated" "$(start 4 "$W4x" "$D1" none "$R4")" "D13 a base holding an EARLIER commit of the isolated range (not its tip) is refused"
W4="${R}-wt4"; wt "$W4" 4 "$B"
has "log ok" "$(start 4 "$W4" "$B" none "$R4")" "D14 the independent part 4 starts on a clean base"
W=$W4
has "log ok" "$(to_impl 4)" "D15 ... and reaches implementation (the outstanding part-1 barrier does not interfere)"
OUT=$(st)
has "part 1 p1: parked (over-budget, isolated, range $B..$D2)" "$OUT" "D16 status: part 1 parked with reason, disposition, range"
has "part 2 ?: deferred" "$OUT" "D17 status: part 2 deferred (from the strategist's recipes; no log line exists)"
has "part 3 ?: deferred" "$OUT" "D18 status: part 3 deferred transitively"
has "part 4 p4: open" "$OUT" "D19 status: part 4 open"
bash "$ST" morning "$S" "$R" >/dev/null 2>&1
has "Deferred: part 3" "$(cat "$R/tmp/mission/MORNING.md")" "D20 morning report lists the transitively deferred part"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "== E legacy part -> ANCHOR -> proto=2 cutover =="
mk e
fab "[mission] PART-START part=1 name=legacy" m1-part-start
L1=$(commit "$R" legacy-work)        # a legacy part builds in the root checkout
lg "[mission] part=1 name=legacy phase=implement round=1 dry=0" m1-implement-r1-d0 >/dev/null
lg "[mission] part=1 name=legacy phase=review round=2 dry=1 findings=0" m1-review-r2-d1 >/dev/null
lg "[mission] part=1 name=legacy phase=review round=3 dry=2 findings=0" m1-review-r3-d2 >/dev/null
lg "[mission] live-verify part=1 round=3 status=n/a reason=tooling" m1-live-verify-r3 >/dev/null
has "log ok" "$(done_ 1)" "E1 grandfathered legacy part finishes on the old fold"
has "ANCHOR part=1 sha=$L1" "$(logf)" "E2 its ANCHOR is the root head at its PART-DONE"
has "FAILED" "$(lg "[mission] ANCHOR part=1 sha=$B" m1-anchor-x)" "E3 ANCHOR is writer-only (log refuses it)"
retire 1 >/dev/null
RL=$(rline 2 normal 5 8 300 no 1); plan_recipes "$RL"
W2o="${R}-wt2o"; wt "$W2o" 2 "$B"
has "not in base" "$(start 2 "$W2o" "$B" 1 "$RL")" "E4 a proto=2 part needing the legacy part is refused on a base without its ANCHOR"
W2="${R}-wt2"; wt "$W2" 2 "$L1"
has "log ok" "$(start 2 "$W2" "$L1" 1 "$RL")" "E5 ... and admitted on a base that holds the ANCHOR"
has "differs from the PART-START needs=" "$(lg "$(rline 2 normal 5 8 300 no none 2)" m2-recipe-v2)" "E6 a RECIPE whose needs= differs from its PART-START is refused"
OUT=$(lg "[mission] part=3 name=p3 phase=research round=1 dry=0" m3-research-r1-d0)
has "no PART-START for part 3" "$OUT" "E7 after cutover a line for an un-started part is refused"
has "re-read commands/mission.md" "$OUT" "E8 ... with the playbook-reload text"
has "PART-START without proto=2" "$(lg "[mission] PART-START part=3 name=late" m3-part-start)" "E9 a legacy PART-START is refused after cutover"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "== F compaction mid-close: cold resume through wake.md =="
mk f
RL=$(rline 1 normal 5 8 300 yes none); plan_recipes "$RL"
start 1 "$W" "$B" none "$RL" >/dev/null; to_impl 1 >/dev/null
HF=$(commit "$W" f-work)
delta 1 4 "$W" "$B" 0 >/dev/null; closer 1 5 "$W" "$B" 0 >/dev/null; suite 1 "$HF" 1 "$B" >/dev/null
# -- compaction here: nothing carried. A cold reader runs wake.md's verbatim §8 resume read. --
RB="$ENVD/resume.sh"
python3 - "$WAKE" "$RB" <<'PY'
import sys,re
s=open(sys.argv[1],encoding='utf-8').read()
i=s.index('## §8 The resume read'); b=s.index('```bash',i)+len('```bash\n'); e=s.index('```',b)
blk=s[b:e]; blk=blk[:blk.index('# Human decision')]   # the op-keyed decision read needs a live human AWAIT
open(sys.argv[2],'w').write(blk+'\nprintf "cur_part=%s\\nlast_review=%s\\nlast_progress=%s\\n" "$cur_part" "$last_review" "$last_progress"\nrm -f /tmp/mission-resume.$$\n')
PY
RES=$(sid="$S" root="$R" bash "$RB" 2>&1)
has "cur_part=1" "$RES" "F1 wake.md §8 resume read (verbatim) finds the current part"
has "dry=1" "$(printf '%s\n' "$RES" | grep '^last_review=')" "F2 ... and the last review at dry=1 (no dry=2)"
eq none "$(mw await-state "$S" "$R")" "F3 no job barrier outstanding"
eq ok "$(mw budget-state "$S" "$R")" "F4 budget row does not fire"
C1H=$(mw cursor-hash "$S" "$R"); eq "$C1H" "$(mw cursor-hash "$S" "$R")" "F5 cursor-hash is stable across idempotent reads"
ROW=$(grep -F '| last review `dry=1`, no `dry=2` |' "$WAKE")
has "relaunch ONLY missing legs" "$ROW" "F6 the decision-table row for this state: relaunch only the missing legs"
has "leg live-proof" "$(join 1 6)" "F7 the writer names the single missing leg (close review and suite are not rerun)"
live 1 "$HF" 1 sent >/dev/null
[ "$C1H" != "$(mw cursor-hash "$S" "$R")" ] && ok "F8 the cursor moves once the wake banks its transition" || bad "F8 cursor did not move"
live 1 "$HF" 1 "ok evidence=dt-f1" >/dev/null
eq 1 "$(grep -ac 'REVIEW-EVIDENCE part=1 round=5 scope=close' "$R/MISSION.$S.log")" "F9 the close review was not re-run"
eq 1 "$(grep -ac 'FULL-SUITE part=1 ' "$R/MISSION.$S.log")" "F10 the suite was not re-run"
has "dry=2" "$(join 1 6)" "F11 join after the relaunched leg"
has "log ok" "$(done_ 1)" "F12 PART-DONE after a compaction mid-close"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "== G cutover safety: protocol dispatch, retired human barrier, close supersedes, finalize, drift =="
# wake.md rows are the conductor's routing. These checks pin the ORDER of the rows that matter (first
# match wins) and drive the writer through each state the row names, reading `part-state` as the wake does.
ROWS=$(python3 - "$WAKE" <<'PY'
import sys
s=open(sys.argv[1],encoding='utf-8').read(); s=s[s.index('## Decision table'):s.index('## §12.3')]
def at(k):
    i=s.find(k); return i
keys={'drift':'`ps` drift=1','fin2':'`ps` proto=2 dry=2','dry1':'last review `dry=1`, no `dry=2`','legacy':'`ps` proto=1','ready1':'`await kind=job ready=1`'}
pos={k:at(v) for k,v in keys.items()}
print(' '.join('%s=%d'%(k,v) for k,v in sorted(pos.items())))
ok = all(v>=0 for v in pos.values()) and pos['drift']<pos['fin2']<pos['dry1'] and pos['legacy']<pos['dry1']
print('order=ok' if ok else 'order=bad')
PY
)
has "order=ok" "$ROWS" "G0 wake.md: legacy dispatch and drift + dry=2 finalize rows precede the dry=1 close row"
has "docs/mission/legacy-playbook.md" "$(grep -F '| `ps` proto=1 closed=0' "$WAKE")" "G0b one legacy dispatch row routes an open proto=1 part to the frozen legacy playbook"

# G1 legacy part in flight across cutover: ready=1 and dry=1/dry=2
mk g1
fab "[mission] PART-START part=1 name=legacy" m1-part-start
lg "[mission] part=1 name=legacy phase=implement round=1 dry=0" m1-implement-r1-d0 >/dev/null
G1H=$(commit "$R" legacy-g1)
mw await "$S" "$R" "part=1 phase=review round=2 kind=job op=review-barrier attempt=1 need=3 got=0" >/dev/null
mw await "$S" "$R" "part=1 phase=review round=2 kind=job op=review-barrier attempt=1 need=3 got=1" >/dev/null
mw await "$S" "$R" "part=1 phase=review round=2 kind=job op=review-barrier attempt=1 need=3 got=2" >/dev/null
has "ready=1" "$(mw await-state "$S" "$R")" "G1a legacy review barrier is join-ready"
has "part=1 proto=1 " "$(mw part-state "$S" "$R")" "G1b part-state names the legacy protocol"
has "bank-review is for proto=2 parts" "$(mw bank-review "$S" "$R" 1 2 delta "$(code_report "$R" "$B" "$G1H" delta 0)" "$(IMPL)")" "G1c bank-review refuses a legacy part (why the row must dispatch first)"
LR=$(code_report "$R" "$B" "$G1H" delta 0)
has "log ok" "$(lg "[mission] REVIEW-EVIDENCE part=1 round=2 codex=4/4 claude=3/3 report=$LR" m1-review-evidence-r2)" "G1d legacy evidence banked by hand (reference.md pre-cutover path)"
has "log ok" "$(lg "[mission] part=1 name=legacy phase=review round=2 dry=1 findings=0" m1-review-r2-d1)" "G1e legacy round line at dry=1"
eq none "$(mw await-state "$S" "$R")" "G1f the legacy round line supersedes the barrier"
has "proto=1 dry=1 " "$(mw part-state "$S" "$R")" "G1g part-state: legacy dry=1 (row: next fresh round, two-dry fold)"
LR3=$(code_report "$R" "$G1H" "$G1H" delta 0)
lg "[mission] REVIEW-EVIDENCE part=1 round=3 codex=4/4 claude=3/3 report=$LR3" m1-review-evidence-r3 >/dev/null
has "log ok" "$(lg "[mission] part=1 name=legacy phase=review round=3 dry=2 findings=0" m1-review-r3-d2)" "G1h legacy dry=2 (converged v1 SNAPSHOT)"
has "kind=converged" "$(logf)" "G1i a grandfathered converged SNAPSHOT exists"
has "proto=1 dry=2 closed=0" "$(mw part-state "$S" "$R")" "G1j cold wake: part-state legacy dry=2, not closed (row: finalize, never a fresh round)"
lg "[mission] live-verify part=1 round=3 status=n/a reason=tooling" m1-live-verify-r3 >/dev/null
has "log ok" "$(done_ 1)" "G1k legacy finalize: live-verify then PART-DONE (legacy fingerprint check)"
has "closed=1" "$(mw part-state "$S" "$R")" "G1l part-state closed after PART-DONE"

# G2 a human AWAIT opened before the part was retired still closes through its validated path
mk g2
RL=$(rline 1 normal 5 8 300 yes none); plan_recipes "$RL"
start 1 "$W" "$B" none "$RL" >/dev/null; to_impl 1 >/dev/null
fab "[mission] AWAIT part=1 phase=review round=4 kind=human op=1-spend-brake attempt=1 need=1 got=0 started_at=$NOW" m1-await-1-spend-brake-r4-a1-g0
fab "[mission] FAIL part=1 park=over-budget disposition=isolated range=$B..$B" m1-fail-park
fab "[mission] PART-RETIRED part=1" m1-part-retired
has "kind=human" "$(mw await-state "$S" "$R")" "G2a the human barrier survives retirement"
has "log ok" "$(lg "[mission] DECISION op=1-spend-brake outcome=deny" pd-1-decision-spend-brake)" "G2b the owner's decision is logged"
has "await ok" "$(mw await "$S" "$R" "part=1 phase=review round=4 kind=human op=1-spend-brake attempt=1 need=1 got=1")" "G2c the human barrier closes on a retired part (validated: DECISION first)"
eq none "$(mw await-state "$S" "$R")" "G2d nothing gates the wake any more"
has "part-retired" "$(mw await "$S" "$R" "part=1 phase=review round=5 kind=job op=review-barrier attempt=1 need=3 got=1")" "G2e a JOB completion for the retired part is still an expected drop"

# G3 clean close evidence supersedes the close-round review barrier
mk g3
RL=$(rline 1 normal 5 8 300 yes none); plan_recipes "$RL"
start 1 "$W" "$B" none "$RL" >/dev/null; to_impl 1 >/dev/null
G3H=$(commit "$W" g3-work); delta 1 4 "$W" "$B" 0 >/dev/null
mw await "$S" "$R" "part=1 phase=review round=5 kind=job op=review-barrier attempt=1 need=3 got=0" >/dev/null
mw await "$S" "$R" "part=1 phase=review round=5 kind=job op=review-barrier attempt=1 need=3 got=1" >/dev/null
mw await "$S" "$R" "part=1 phase=review round=5 kind=job op=review-barrier attempt=1 need=3 got=2" >/dev/null
has "ready=1" "$(mw await-state "$S" "$R")" "G3a close-round barrier join-ready"
has "result=clean" "$(closer 1 5 "$W" "$B" 0)" "G3b clean close banked (no round line by design)"
eq none "$(mw await-state "$S" "$R")" "G3c the close evidence supersedes the barrier (no re-bank loop)"

# G4 cold wake after join, before PART-DONE: finalize, do not restart review
suite 1 "$G3H" 1 "$B" >/dev/null; live 1 "$G3H" 1 sent >/dev/null; live 1 "$G3H" 1 "ok evidence=dt-g4" >/dev/null
join 1 6 >/dev/null
has "proto=2 dry=2 closed=0" "$(mw part-state "$S" "$R")" "G4a cold wake: part-state proto=2 dry=2 not closed (row: finalize)"
has "drift=0" "$(mw part-state "$S" "$R")" "G4b no drift at the freeze"
has "log ok" "$(done_ 1)" "G4c gated PART-DONE finalizes"

# G5 frozen-tree drift at dry=1 goes to repair before the close row
mk g5
RL=$(rline 1 normal 5 8 300 yes none); plan_recipes "$RL"
start 1 "$W" "$B" none "$RL" >/dev/null; to_impl 1 >/dev/null
G5F=$(commit "$W" g5-work); delta 1 4 "$W" "$B" 0 >/dev/null
has "dry=1 closed=0 freeze=$G5F head=$G5F tree=clean drift=0" "$(mw part-state "$S" "$R")" "G5a at the freeze: no drift"
G5X=$(commit "$W" g5-after-freeze)
has "drift=1" "$(mw part-state "$S" "$R")" "G5b a commit after the freeze is drift"
printf 'x\n' >> "$W/code.txt"; has "tree=dirty drift=1" "$(mw part-state "$S" "$R")" "G5c an uncommitted edit is drift too"
( cd "$W" && git checkout -q code.txt )
has "REFUSED: close report must be" "$(closer 1 5 "$W" "$B" 0)" "G5d the close at the moved HEAD is refused (the dry=1 row would loop)"
has "log ok" "$(lg "[mission] part=1 name=p1 phase=fix round=5 dry=0 findings=0" m1-fix-r5-d0)" "G5e repair: a fix line resets dry"
has "dry=0 " "$(mw part-state "$S" "$R")" "G5f part-state dry=0 after the reset"
has "dry=1" "$(delta 1 6 "$W" "$G5F" 0)" "G5g delta round over the drift -> new freeze"
has "freeze=$G5X head=$G5X tree=clean drift=0" "$(mw part-state "$S" "$R")" "G5h new freeze at the moved HEAD"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "== H correctness: partial join, PART-START binding, stale live pause, known-red signatures, octal =="
# H6 join persists the snapshot before dry=2, and a retry after a partial bank repairs it
mk h6
RL=$(rline 1 normal 5 8 300 no none); plan_recipes "$RL"
start 1 "$W" "$B" none "$RL" >/dev/null; to_impl 1 >/dev/null
H6=$(commit "$W" h6-work); delta 1 4 "$W" "$B" 0 >/dev/null; closer 1 5 "$W" "$B" 0 >/dev/null
suite 1 "$H6" 1 "$B" >/dev/null; live 1 "$H6" 1 "n/a reason=no-ui" >/dev/null
fab "[mission] part=1 name=p1 phase=review round=6 dry=2 findings=0" m1-review-r6-d2     # crash: dry=2 landed, snapshot lost
hasnt "kind=converged" "$(logf)" "H6a partial bank: dry=2 without its convergence snapshot"
has "dry=2" "$(join 1 6)" "H6b a join retry repairs the partial bank instead of refusing"
has "kind=converged tree=v2:" "$(logf)" "H6c the convergence snapshot is now persisted"
has "log ok" "$(done_ 1)" "H6d PART-DONE after the repaired join"
mk h6b
RL=$(rline 1 normal 5 8 300 no none); plan_recipes "$RL"
start 1 "$W" "$B" none "$RL" >/dev/null; to_impl 1 >/dev/null
H6B=$(commit "$W" h6b-work); delta 1 4 "$W" "$B" 0 >/dev/null; closer 1 5 "$W" "$B" 0 >/dev/null
suite 1 "$H6B" 1 "$B" >/dev/null; live 1 "$H6B" 1 "n/a reason=no-ui" >/dev/null; join 1 6 >/dev/null
SN=$(grep -an 'SNAPSHOT part=1 kind=converged' "$R/MISSION.$S.log" | cut -d: -f1); D2=$(grep -an 'm1-review-r6-d2' "$R/MISSION.$S.log" | cut -d: -f1)
[ -n "$SN" ] && [ -n "$D2" ] && [ "$SN" -lt "$D2" ] && ok "H6e a normal join writes the snapshot BEFORE the dry=2 line" || bad "H6e snapshot (line ${SN:-?}) not before dry=2 (line ${D2:-?})"
has "dry=2" "$(join 1 6)" "H6f an exact join retry is idempotent"

# H7 PART-START binds base= to the worktree's actual HEAD
mk h7
RL=$(rline 1 normal 5 8 300 no none); plan_recipes "$RL"
H7X=$(commit "$W" h7-parked-work)
has "is not the declared base" "$(start 1 "$W" "$B" none "$RL")" "H7a a worktree whose HEAD is not base= is refused (parked commits cannot ride in)"
W7="${R}-wt7"; wt "$W7" 7 "$B"
has "log ok" "$(start 1 "$W7" "$B" none "$RL")" "H7b HEAD == base is admitted"

# H8 an invalidated freeze ends its live pause; overlapping pauses are merged
mk h8
RL=$(rline 1 normal 5 8 300 yes none); plan_recipes "$RL"
start 1 "$W" "$B" none "$RL" >/dev/null; to_impl 1 >/dev/null
H8=$(commit "$W" h8-work); delta 1 4 "$W" "$B" 0 >/dev/null
NOW=$(date +%s)   # fresh: minute-granular assertions below must not drift with suite runtime
CE=$(grep -a 'REVIEW-EVIDENCE part=1 round=4 scope=delta' "$R/MISSION.$S.log" | cut -f2 | sed "s/ scope=delta / scope=close /; s/ round=4 / round=5 /; s/ at=[0-9]*\$//")
fab "$CE at=$((NOW - 200*60))" m1-review-evidence-close-r5
fab "[mission] FULL-SUITE part=1 sha=$H8 attempt=1 base=$B env=0123456789abcdef completed=yes new-reds=0 report=/x at=$((NOW - 200*60))" "m1-suite-$H8-a1"
fab "[mission] live-verify part=1 sha=$H8 attempt=1 status=sent at=$((NOW - 50*60))" "m1-live-$H8-a1-sent"
fab "[mission] live-verify part=1 sha=$H8 attempt=2 status=sent at=$((NOW - 40*60))" "m1-live-$H8-a2-sent"
has "paused live=50" "$(mw budget-state "$S" "$R")" "H8a two open attempts on the freeze: overlapping pauses merge (50, not 90)"
fab "[mission] live-verify part=1 sha=$H8 attempt=3 status=sent at=$((NOW - 100*60))" "m1-live-$H8-a3-sent"
has "paused live=100" "$(mw budget-state "$S" "$R")" "H8b a third open attempt: union is 100 paused minutes"
has "log ok" "$(lg "[mission] part=1 name=p1 phase=fix round=5 dry=0 findings=1" m1-fix-r5-d0)" "H8c repair starts (dry reset invalidates the freeze)"
eq ok "$(mw budget-state "$S" "$R")" "H8d the stale unanswered attempts stop pausing (they would otherwise run on toward the live cap)"

# H9 known-red signatures keep deterministic assertion values
mk h9
mkdir -p "$R/.mission-known-reds"
kr() { _f="$R/tmp/mission/kr-$1.txt"; shift
  { echo "sha=$B"; echo "base=$B"; echo "command=npm test"; echo "env=w1"; echo "completed=yes"; echo "infra=0"; echo "--"; for x in "$@"; do echo "$x"; done; } > "$_f"; printf '%s' "$_f"; }
mw known-reds "$S" "$R" record "$(kr base 't1 | expected 5 received 1000000000000000' 't2 | expected hash deadbeefdeadbeefdeadbeef' 't3 | requestId=aaaa1111bbbb2222cccc failed at 2026-11-11T10:00:00Z after 12ms')" >/dev/null
eq 1 "$(mw known-reds "$S" "$R" diff "$(kr a 't1 | expected 5 received 2000000000000000')")" "H9a a changed long numeric assertion value is a NEW red"
eq 1 "$(mw known-reds "$S" "$R" diff "$(kr b 't2 | expected hash cafebabecafebabecafebabe')")" "H9b a changed hex assertion value is a NEW red"
eq 0 "$(mw known-reds "$S" "$R" diff "$(kr c 't3 | requestId=ffff9999eeee8888dddd failed at 2026-11-12T11:22:33Z after 97ms')")" "H9c only id-labelled fields, timestamps and durations are normalized (known red)"
eq 0 "$(mw known-reds "$S" "$R" diff "$(kr d 't1 | expected 5 received 1000000000000000')")" "H9d an identical red is known"

# H10 leading-zero part numbers never reach bash arithmetic (bash 3.2 octal abort)
mk h10
OUT=$(bash "$MW" await "$S" "$R" "part=08 phase=review round=09 kind=job op=review-barrier attempt=1 need=3 got=0" 2>&1)
hasnt "value too great" "$OUT" "H10a part=08 does not abort bash"
has "mission-write: await" "$OUT" "H10b ... and still prints its status line"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "== I round 2: failed join writes, legacy rows scoped to review states, earned pause kept =="
# IA join must not report ok when its log appends fail
mk ia
RL=$(rline 1 normal 5 8 300 no none); plan_recipes "$RL"
start 1 "$W" "$B" none "$RL" >/dev/null; to_impl 1 >/dev/null
IAH=$(commit "$W" ia-work); delta 1 4 "$W" "$B" 0 >/dev/null; closer 1 5 "$W" "$B" 0 >/dev/null
suite 1 "$IAH" 1 "$B" >/dev/null; live 1 "$IAH" 1 "n/a reason=no-ui" >/dev/null
chmod a-w "$R/MISSION.$S.log"
OUT=$(join 1 6)
chmod u+w "$R/MISSION.$S.log"
hasnt "bank-review ok" "$OUT" "IA1 join does not report ok when its appends fail"
has "FAILED" "$OUT" "IA2 ... it reports FAILED"
hasnt "kind=converged" "$(logf)" "IA3 nothing was banked"
has "dry=2" "$(join 1 6)" "IA4 the retry once the log is writable succeeds"
has "log ok" "$(done_ 1)" "IA5 PART-DONE"

# IB the legacy class: ONE legacy row, right after the human-AWAIT rows, sends an open proto=1 part to
# the frozen pre-rework playbook (byte-identical to 509fe27b's commands/mission.md); every later row
# is proto=2-only, so no proto=2 verb is reachable for proto=1, and nothing legacy is re-derived by hand.
LP="$HERE/../../docs/mission/legacy-playbook.md"
ROWS2=$(python3 - "$WAKE" <<'PY'
import sys
s=open(sys.argv[1],encoding='utf-8').read(); s=s[s.index('## Decision table'):s.index('## §12.3')]
rows=[l for l in s.splitlines() if l.startswith('| ') and not l.startswith('| State') and not l.startswith('|---')]
state=lambda l: l.split(' | ')[0]
leg=[i for i,l in enumerate(rows) if 'proto=1' in state(l)]
human=[i for i,l in enumerate(rows) if 'kind=human' in state(l)]
first_other=min(i for i,l in enumerate(rows) if i not in human and i not in leg)
later_p1=[i for i,l in enumerate(rows) if i not in leg and 'proto=1' in l]
pts=bool(leg) and all('docs/mission/legacy-playbook.md' in rows[i] for i in leg)
print('legacy-rows=%d first=%s later-p1=%d points=%s' % (len(leg), 'ok' if leg and leg[0]<first_other else 'bad', len(later_p1), 'ok' if pts else 'bad'))
PY
)
has "legacy-rows=1 first=ok later-p1=0 points=ok" "$ROWS2" "IB1 exactly one legacy row, ahead of every proto=2 row, pointing at legacy-playbook.md"
has "proto=2 parts only" "$(sed -n '/### G. Per-part loop/,/### H2/p' "$HERE/../../commands/mission.md")" "IB2 mission.md's part loop is declared proto=2-only and points legacy parts at the frozen playbook"
has "legacy-playbook.md" "$(sed -n '/### G. Per-part loop/,/### H2/p' "$HERE/../../commands/mission.md")" "IB2b ... by name"
if [ -r "$LP" ] && ( cd "$HERE/../.." && git cat-file -e 509fe27b:commands/mission.md 2>/dev/null ); then
  tail -n +4 "$LP" | cmp -s - <(cd "$HERE/../.." && git show 509fe27b:commands/mission.md) \
    && ok "IB3 legacy-playbook.md below its 3-line header is byte-identical to 509fe27b:commands/mission.md" \
    || bad "IB3 legacy-playbook.md drifted from the frozen pre-rework playbook"
else bad "IB3 legacy-playbook.md or commit 509fe27b missing"; fi
hasnt "Legacy part loop" "$(cat "$HERE/../../docs/mission/reference.md")" "IB4 no hand-written legacy loop remains in reference.md"

# IC invalidating a freeze keeps the pause time already earned (210 active + 100 paused, budget 300)
mk ic
RL=$(rline 1 normal 5 8 300 yes none); plan_recipes "$RL"
NOW=$(date +%s)
fab "[mission] PART-START part=1 name=p1 proto=2 worktree=$W base=$B needs=none at=$((NOW - 310*60))" m1-part-start
fab "$RL at=$((NOW - 310*60))" m1-recipe-v1
fab "[mission] part=1 name=p1 phase=plan round=1 dry=0 open=0" m1-plan-r1-d0
fab "[mission] part=1 name=p1 phase=implement round=2 dry=0" m1-implement-r2-d0
ICH=$(commit "$W" ic-work)
fab "[mission] REVIEW-EVIDENCE part=1 round=3 scope=delta base=$B head=$ICH codex=4/4 claude=3/3 tagged=0 blocking=0 new=0 repeat=0 rkeys=- result=clean report=/x at=$((NOW - 105*60))" m1-review-evidence-delta-r3
fab "[mission] part=1 name=p1 phase=review round=3 dry=1 findings=0" m1-review-r3-d1
fab "[mission] REVIEW-EVIDENCE part=1 round=4 scope=close base=$B head=$ICH codex=4/4 claude=3/3 tagged=0 blocking=0 new=0 repeat=0 rkeys=- result=clean report=/x at=$((NOW - 101*60))" m1-review-evidence-close-r4
fab "[mission] FULL-SUITE part=1 sha=$ICH attempt=1 base=$B env=0123456789abcdef completed=yes new-reds=0 report=/x at=$((NOW - 101*60))" "m1-suite-$ICH-a1"
fab "[mission] live-verify part=1 sha=$ICH attempt=1 status=sent at=$((NOW - 100*60))" "m1-live-$ICH-a1-sent"
has "paused live=100" "$(mw budget-state "$S" "$R")" "IC1 210 active + 100 paused: paused, inside the 300 budget"
has "log ok" "$(lg "[mission] part=1 name=p1 phase=fix round=4 dry=0 findings=1" m1-fix-r4-d0)" "IC2 a repair resets dry (invalidates the freeze)"
eq ok "$(mw budget-state "$S" "$R")" "IC3 the 100 paused minutes already earned are kept (not over 310)"
has "log ok" "$(lg "[mission] part=1 name=p1 phase=fix round=4 dry=0 findings=1" m1-fix-r4-d0)" "IC4 an identical fix retry dedups (keeps its original at=)"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "== J legacy part replayed with the frozen playbook's own line shapes and verbs, end to end =="
# Every line below is a shape docs/mission/legacy-playbook.md tells a conductor to write (its §7
# grammar, §5 VOID/FAIL block, §6 live-verify, PART-DONE/RETIRED, the human STOP close order, the
# read verbs). Outputs go to a FILE: a variable assigned inside $(...) would vanish in the subshell.
mk j
JLOG="$ENVD/j-outputs.txt"; : > "$JLOG"
jl()  { _o=$(lg "$1" "$2"); printf '%s\n' "$_o" >> "$JLOG"; printf '%s' "$_o"; }
jmw() { _o=$(mw "$@"); printf '%s\n' "$_o" >> "$JLOG"; printf '%s' "$_o"; }
LPF="$HERE/../../docs/mission/legacy-playbook.md"
for shape in '[mission] test-trust part=<N>=' '[mission] criticer part=<N> findings=' '[mission] VOID part=<N> phase=review round=<K> reason=' '[mission] live-verify part=<N> round=<K> status=ok evidence=' '[mission] PART-DONE part=<N> (converged)' '[mission] PART-RETIRED part=<N>' 'mission-write.sh pending-stop'; do
  grep -a -q -F -- "$shape" "$LPF" && ok "J0 the frozen playbook emits: $shape" || bad "J0 frozen playbook lacks: $shape"
done
fab "[mission] PART-START part=1 name=legacy" m1-part-start       # opened before cutover
has "part=1 proto=1 dry=0 closed=0" "$(mw part-state "$S" "$R")" "J1 reload: part-state routes to the legacy row"
jmw timing-resume "$S" "$R" >/dev/null; jmw render-banner "$S" "$R" >/dev/null
has "log ok" "$(jl "[mission] part=1 name=legacy phase=research round=1 dry=0" m1-research-r1-d0)" "J2 research round"
has "log ok" "$(jl "[mission] part=1 name=legacy phase=plan round=2 dry=0" m1-plan-r2-d0)" "J3 plan round (legacy shape)"
has "log ok" "$(jl "[mission] criticer part=1 findings=2 tighten the error path" m1-criticer-r2)" "J4 criticer headline"
has "log ok" "$(jl "[mission] test-trust part=1=ok" m1-test-trust)" "J5 test-trust before the first implement"
JH=$(commit "$R" legacy-impl)
has "log ok" "$(jl "[mission] part=1 name=legacy phase=implement round=3 dry=0" m1-implement-r3-d0)" "J6 implement"
has "ok" "$(jmw await "$S" "$R" "part=1 phase=review round=4 kind=job op=review-barrier attempt=1 need=3 got=0")" "J7 review barrier"
J4R=$(code_report "$R" "$B" "$JH" delta 2)
has "log ok" "$(jl "[mission] VOID part=1 phase=review round=4 reason=codex-passes-3of4" "m1-void-r4-run1h$(printf '%s' "$J4R" | shasum -a 256 | cut -c1-8)")" "J8 VOID (old shell-block shape)"
eq 1 "$(mw void-count "$S" "$R" 1 4)" "J9 void-count reads it"
jmw await "$S" "$R" "part=1 phase=review round=4 kind=job op=review-barrier attempt=2 need=3 got=0" >/dev/null
jmw await "$S" "$R" "part=1 phase=review round=4 kind=job op=review-barrier attempt=2 need=3 got=1" >/dev/null
jmw await "$S" "$R" "part=1 phase=review round=4 kind=job op=review-barrier attempt=2 need=3 got=2" >/dev/null
has "ready=1" "$(mw await-state "$S" "$R")" "J10 retry attempt ready"
eq 4/4 "$(mw parse-codex-header "$J4R")" "J11 parse-codex-header"
eq 3/3 "$(mw parse-claude-header "$J4R")" "J12 parse-claude-header"
has "log ok" "$(jl "[mission] REVIEW-EVIDENCE part=1 round=4 codex=4/4 claude=3/3 report=$J4R" m1-review-evidence-r4)" "J13 legacy REVIEW-EVIDENCE"
has "log ok" "$(jl "[mission] part=1 name=legacy phase=review round=4 dry=0 findings=2" m1-review-r4-d0)" "J14 blocking review round"
eq none "$(mw await-state "$S" "$R")" "J15 barrier superseded"
OUT=$(mw pending-stop "$S" "$R" spend-brake 1 4 2 review "Keep going past the old budget?"); printf '%s\n' "$OUT" >> "$JLOG"
has "pending-stop ok id=pd:" "$OUT" "J16 old spend-brake human STOP opens"
PD=$(printf '%s' "$OUT" | sed -n 's/^mission-write: pending-stop ok id=\(pd:[0-9]*-[a-z0-9-]*\).*$/\1/p'); SEQ=${PD#pd:}; SEQ=${SEQ%%-*}
has "log ok" "$(jl "[mission] DECISION op=$SEQ-spend-brake outcome=approve" "pd-$SEQ-decision-spend-brake")" "J17 DECISION"
has "ok" "$(jmw await "$S" "$R" "part=1 phase=review round=4 kind=human op=$SEQ-spend-brake attempt=2 need=1 got=1")" "J18 human barrier closes"
has "ok" "$(jmw resolve "$S" "$R" "$PD" approved)" "J19 resolve"
eq none "$(mw await-state "$S" "$R")" "J19b nothing outstanding"
has "log ok" "$(jl "[mission] part=1 name=legacy phase=fix round=4 dry=0 findings=2" m1-fix-r4-d0)" "J20 fix"
JH2=$(commit "$R" legacy-fix)
for k in 5 6; do
  d=$((k-4)); JR=$(code_report "$R" "$JH" "$JH2" delta 0)
  jl "[mission] REVIEW-EVIDENCE part=1 round=$k codex=4/4 claude=3/3 report=$JR" "m1-review-evidence-r$k" >/dev/null
  has "log ok" "$(jl "[mission] part=1 name=legacy phase=review round=$k dry=$d findings=0" "m1-review-r$k-d$d")" "J21 clean round $k dry=$d"
done
has "proto=1 dry=2 closed=0" "$(mw part-state "$S" "$R")" "J22 converged legacy part"
# evidence lives outside the root: the legacy fingerprint covers untracked root files
EV="$ENVD/j-live-evidence.txt"; echo shot > "$EV"
has "log ok" "$(jl "[mission] live-verify part=1 round=6 status=ok evidence=$EV" m1-live-verify-r6)" "J23 legacy live-verify (stat-verified evidence path)"
has "log ok" "$(jl "[mission] PART-DONE part=1 (converged)" m1-part-done)" "J24 PART-DONE (old fold + fingerprint)"
has "log ok" "$(jl "[mission] PART-RETIRED part=1" m1-part-retired)" "J25 PART-RETIRED"
[ "$(grep -c . "$JLOG")" -ge 20 ] && ok "J26 the output log captured the walk ($(grep -c . "$JLOG") lines)" || bad "J26 output log has $(grep -c . "$JLOG") lines (capture broken)"
hasnt "FAILED" "$(cat "$JLOG")" "J27 no refusal anywhere in the legacy part's walk"
hasnt "COLLISION" "$(cat "$JLOG")" "J28 no collision"
# The frozen playbook's NEXT step is a legacy PART-START for the next part: refused with the reload
# text, which sends the conductor back to commands/mission.md (new parts are proto=2).
OUT=$(lg "[mission] PART-START part=2 name=next" m2-part-start)
has "re-read commands/mission.md" "$OUT" "J29 the handoff: the next legacy PART-START is refused with the reload text"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
echo "== K legacy handoff seam: tick lock exactly once; legacy park without a human STOP =="
mk k
LPF="$HERE/../../docs/mission/legacy-playbook.md"
fab "[mission] PART-START part=1 name=legacy" m1-part-start
TICK="$R/.mission-backups/tick.$S.lock"
# the frozen §12.1 step-1 acquisition block, verbatim
LOCKBLK="$ENVD/legacy-lock.sh"
awk '/^   i_own_lock=0$/{f=1} f{print} f&&/^   fi$/{exit}' "$LPF" | sed 's/^   //' > "$LOCKBLK"
grep -q 'mkdir "$tick_dir"' "$LOCKBLK" && ok "K0 extracted the frozen playbook's own tick-lock block" || bad "K0 lock block not found in legacy-playbook.md"
# wake.md order: the protocol read sits BEFORE step 1's lock
POS=$(python3 - "$WAKE" <<'PY'
import sys
s=open(sys.argv[1],encoding='utf-8').read()
a=s.find('Protocol first, BEFORE the lock'); b=s.find('1. **Tick lock**')
print('ok' if 0<=a<b else 'bad')
PY
)
eq ok "$POS" "K1 wake.md reads part-state and routes proto=1 BEFORE taking the tick lock"
has "Legacy compatibility overrides" "$(grep -F 'Protocol first' -A3 "$WAKE")" "K1b ... and names the overrides that win over the frozen text"
# one full tick, new order: lock-free protocol read -> frozen §12.1 owns the lock
[ ! -e "$TICK" ] && ok "K2a no tick lock held at the protocol read" || bad "K2a a tick lock is already held"
has "proto=1 dry=0 closed=0" "$(mw part-state "$S" "$R")" "K2 protocol read routes to legacy"
OUT=$(tick_dir="$TICK" bash -c ". '$LOCKBLK'; echo i_own_lock=\$i_own_lock" 2>&1)
has "i_own_lock=1" "$OUT" "K3 the frozen routine acquires the tick lock (no self-contention)"
C0=$(mw cursor-hash "$S" "$R")
has "log ok" "$(lg "[mission] part=1 name=legacy phase=research round=1 dry=0" m1-research-r1-d0)" "K4 the tick makes progress (one legacy transition)"
[ "$C0" != "$(mw cursor-hash "$S" "$R")" ] && ok "K5 cursor advanced" || bad "K5 cursor did not move"
rmdir "$TICK" 2>/dev/null; [ ! -e "$TICK" ] && ok "K6 released once; nothing left held" || bad "K6 tick lock still held"
# negative control: the round-4 order (wake.md takes the lock first, then hands off) self-contends
mkdir -p "$TICK"
OUT=$(tick_dir="$TICK" bash -c ". '$LOCKBLK'; echo i_own_lock=\$i_own_lock" 2>&1)
has "i_own_lock=0" "$OUT" "K7 (control) holding wake.md's lock while entering the frozen §12.1 = 'another owner' (the bug)"
rmdir "$TICK"

# legacy park under the override: no pending-stop, writer-accepted park record, retire, proto=2 successor
K1C=$(commit "$R" legacy-k1); K2C=$(commit "$R" legacy-k2)
has "FAILED" "$(lg "[mission] FAIL part=1 phase=review reason=part-over-budget attempt=1 disposition=isolated" m1-fail-part-over-budget-1)" "K8 (why) the frozen text's FAIL ... disposition= shape is refused"
has "pending-stop" "$(grep -F 'Do NOT open' -A1 "$HERE/../../docs/mission/reference.md")" "K8b the override forbids pending-stop for the park"
has "log ok" "$(lg "[mission] FAIL part=1 park=part-over-budget disposition=isolated range=$B..$K2C" m1-fail-park)" "K9 the legacy part parks with the writer-accepted record"
has "FAILED" "$(lg "[mission] FAIL part=1 park=part-over-budget disposition=isolated range=$K2C..$B" m1-fail-park-x)" "K9b (control) a backwards legacy range is refused"
eq none "$(mw await-state "$S" "$R")" "K10 no human STOP is open"
has "1 parked" "$(morning_line)" "K11 morning report shows the park"
has "log ok" "$(lg "[mission] PART-RETIRED part=1" m1-part-retired)" "K12 PART-RETIRED"
has "re-read commands/mission.md" "$(lg "[mission] PART-START part=2 name=next" m2-part-start)" "K13 the frozen text's next legacy PART-START is refused with the reload text"
WK="${R}-wtk"; wt "$WK" 2 "$K1C"
has "isolated" "$(lg "[mission] PART-START part=2 name=next proto=2 worktree=$WK base=$K1C needs=none" m2-part-start)" "K14 a base holding a commit of the isolated legacy range is refused"
WK2="${R}-wtk2"; wt "$WK2" 2 "$B"
has "log ok" "$(lg "[mission] PART-START part=2 name=next proto=2 worktree=$WK2 base=$B needs=none" m2-part-start)" "K15 the next part is admitted as proto=2 on a clean base"
has "part=2 proto=2" "$(mw part-state "$S" "$R")" "K16 the mission continues on proto=2 (no stop)"

printf '\nPASS: %s  FAIL: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
