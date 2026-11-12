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

printf '\nPASS: %s  FAIL: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
