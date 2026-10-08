#!/bin/bash
# test-recap-extract.sh - fixture-based test for scripts/recap-extract.py.
# Resolved from THIS FILE's location (not $HOME) so it works on a CI runner where
# HOME differs from the developer machine. Every fixture is a synthetic .jsonl built
# in a mktemp dir (RECAP_PROJECTS_DIR), so no case ever reads $HOME/.claude.
#
# Portable: no BSD `date -v` / `stat -f`; fixture timestamps are literal strings.
# RECAP_SETTLE_SECONDS=0 so no case waits for the transcript to go quiet.
#
# bash 3.2 compatible.

set -u
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

_TRE_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$_TRE_REPO/scripts/recap-extract.py"
[ -f "$SCRIPT" ] || { echo "FATAL: recap-extract.py not found at $SCRIPT (repo root resolved to $_TRE_REPO)" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/recap-extract-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
export RECAP_PROJECTS_DIR="$TMP/projects"
export RECAP_SETTLE_SECONDS=0
mkdir -p "$RECAP_PROJECTS_DIR/-Users-test-proj" "$TMP/work"

pass=0; fail=0
check() { # check <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then pass=$((pass+1)); else
        echo "FAIL: $1 (expected [$2] got [$3])" >&2; fail=$((fail+1)); fi
}
has() { # has <desc> <needle> - stdout of the last run contains needle
    if printf '%s' "$OUT" | grep -qF -- "$2"; then pass=$((pass+1)); else
        echo "FAIL: $1 (missing [$2])" >&2; fail=$((fail+1)); fi
}
lacks() { # lacks <desc> <needle>
    if printf '%s' "$OUT" | grep -qF -- "$2"; then
        echo "FAIL: $1 (unexpected [$2])" >&2; fail=$((fail+1)); else pass=$((pass+1)); fi
}
section() { # section <title-prefix> - lines of one rollup list from $OUT
    printf '%s\n' "$OUT" | awk -v t="$1" 'index($0,t)==1{on=1;next} on&&/^  - /{print;next} on{exit}'
}
anchor() { printf '%s\n' "$OUT" | grep "^user's message that opened this window:" ; }
run() { # run <arg...> -> $OUT, $RC, $ERR (cwd = $TMP/work, stdin closed)
    OUT=$(cd "$TMP/work" && python3 "$SCRIPT" "$@" 2>"$TMP/err" </dev/null)
    RC=$?
    ERR=$(cat "$TMP/err")
}
runs() { run --session "$1" "${@:2}"; }

RECAP_CWD_MANGLED=$(cd "$TMP/work" && python3 -c 'import os, re; print(re.sub(r"[^A-Za-z0-9]", "-", os.getcwd()))')
export RECAP_CWD_MANGLED

# ------------------------------------------------------------------ fixtures
python3 - "$RECAP_PROJECTS_DIR/-Users-test-proj" <<'PYGEN'
import json, os, sys
D = sys.argv[1]
_n = [0]

def ts():
    _n[0] += 1
    return "2026-10-07T10:%02d:%02d.000Z" % ((_n[0] // 60) % 60, _n[0] % 60)

def base(sid, typ, **kw):
    _n[0] += 0
    d = {"parentUuid": None, "isSidechain": False, "type": typ, "uuid": "u%d" % (_n[0] + 1),
         "timestamp": ts(), "sessionId": sid, "cwd": "/Users/test/proj", "version": "2.1.293"}
    d.update(kw)
    return d

class F:
    def __init__(self, sid, folder=D):
        self.sid, self.rows, self.folder = sid, [], folder
        self.pid = 0
    def raw(self, s): self.rows.append(s); return self
    def add(self, d): self.rows.append(json.dumps(d, separators=(",", ":"))); return self
    def human(self, text, **kw):
        self.pid += 1
        return self.add(base(self.sid, "user", promptId="p%d" % self.pid, message={"role": "user", "content": text},
                             origin={"kind": "human"}, turnOrigin="human", promptSource="typed", **kw))
    def legacy(self, text):
        return self.add(base(self.sid, "user", message={"role": "user", "content": text}))
    def cmd(self, name, args="", expansion="# Agent playbook EXPANSION", meta=True):
        self.pid += 1
        c = "<command-message>%s</command-message>\n<command-name>/%s</command-name>" % (name, name)
        if args:
            c += "\n<command-args>%s</command-args>" % args
        self.add(base(self.sid, "user", promptId="p%d" % self.pid, message={"role": "user", "content": c},
                      origin={"kind": "human"}, turnOrigin="human"))
        if meta:
            self.add(base(self.sid, "user", promptId="p%d" % self.pid, isMeta=True, turnCompanion=True,
                          message={"role": "user", "content": [{"type": "text", "text": expansion}]}))
        return self
    def local_out(self, text):
        return self.add(base(self.sid, "user", message={"role": "user",
                        "content": "<local-command-stdout>%s</local-command-stdout>" % text}))
    def say(self, text, side=False, stop=None):
        m = {"role": "assistant", "content": [
            {"type": "thinking", "thinking": "SECRET_THINKING"}, {"type": "text", "text": text}]}
        if stop:
            m["stop_reason"] = stop
        return self.add(base(self.sid, "assistant", isSidechain=side, message=m))
    def tool(self, tid, name, inp, side=False, stop=None):
        m = {"role": "assistant", "content": [{"type": "tool_use", "id": tid, "name": name, "input": inp}]}
        if stop:
            m["stop_reason"] = stop
        return self.add(base(self.sid, "assistant", isSidechain=side, message=m))
    def result(self, tid, text="ok", err=False, tur=None, side=False):
        b = {"type": "tool_result", "tool_use_id": tid, "content": text}
        if err:
            b["is_error"] = True
        d = base(self.sid, "user", isSidechain=side, message={"role": "user", "content": [b]})
        if tur is not None:
            d["toolUseResult"] = tur
        return self.add(d)
    def bash(self, tid, command, ok=True, out="done"):
        self.tool(tid, "Bash", {"command": command, "description": "x"})
        if ok:
            return self.result(tid, out, tur={"stdout": out, "stderr": "", "interrupted": False})
        return self.result(tid, "Exit code 1\n" + out, err=True)
    def compact(self):
        self.add(base(self.sid, "system", subtype="compact_boundary", content="Conversation compacted"))
        return self.add(base(self.sid, "user", isCompactSummary=True, message={"role": "user",
                        "content": "This session is being continued from a previous conversation. SUMMARY_TEXT"}))
    def notif_text(self, task, tuid, summary, result):
        return ("<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>%s</tool-use-id>\n<status>completed</status>\n"
                "<summary>%s</summary>\n<result>%s</result>\n</task-notification>" % (task, tuid, summary, result))
    def notif_user(self, task, tuid, summary, result="r"):
        return self.add(base(self.sid, "user", message={"role": "user", "content": self.notif_text(task, tuid, summary, result)},
                             origin={"kind": "task-notification", "producer": "session-task"},
                             promptSource="system", turnOrigin="task_notification"))
    def notif_attach(self, task, tuid, summary, result="r"):
        return self.add(base(self.sid, "attachment", attachment={"type": "queued_command",
            "prompt": self.notif_text(task, tuid, summary, result), "commandMode": "task-notification",
            "origin": {"kind": "task-notification", "producer": "session-task"}}))
    def queued(self, text, mode="prompt", origin="human"):
        a = {"type": "queued_command", "prompt": text, "commandMode": mode, "humanTurn": origin == "human"}
        if origin:
            a["origin"] = {"kind": origin}
        return self.add(base(self.sid, "attachment", attachment=a))
    def peer(self, body, meta=True):
        kw = {"isMeta": True} if meta else {}
        return self.add(base(self.sid, "user", **kw, message={"role": "user",
            "content": "Another Claude session sent a message:\n<cross-session-message>%s</cross-session-message>" % body},
            origin={"kind": "peer", "name": "peer-7", "body": body}))
    def sched(self, text):
        return self.add(base(self.sid, "user", message={"role": "user", "content": text},
                             turnOrigin="scheduled", scheduledTaskId="st1"))
    def pickup(self):
        return self.add(base(self.sid, "user", isMeta=True, promptSource="system",
                             message={"role": "user", "content": "[pickup] resume the work"}))
    def autoc(self):
        return self.add(base(self.sid, "user", message={"role": "user", "content": "continue"},
                             origin={"kind": "auto-continuation"}, turnOrigin="auto_continuation"))
    def save(self):
        with open(os.path.join(self.folder, self.sid + ".jsonl"), "w") as fh:
            fh.write("\n".join(self.rows) + "\n")
    def meta(self, aid, wf=None, **m):
        sub = os.path.join(self.folder, self.sid, "subagents", *( ["workflows", wf] if wf else []))
        os.makedirs(sub, exist_ok=True)
        with open(os.path.join(sub, "agent-%s.meta.json" % aid), "w") as fh:
            json.dump(m, fh)
        return os.path.join(sub, "agent-%s.jsonl" % aid)

def sublog(path, sid, edits, final):
    s = F(sid)
    for i, p in enumerate(edits):
        s.tool("ts%d" % i, "Write", {"file_path": p, "content": "x"}, side=True)
        s.result("ts%d" % i, "File created", tur={"type": "create", "filePath": p}, side=True)
    s.say(final, side=True)
    with open(path, "w") as fh:
        fh.write("\n".join(s.rows) + "\n")

# a) plain typed prompt; malformed line counted
f = F("case-a"); f.human("OLD_PROMPT_A").say("old answer").human("NEW_PROMPT_A please refactor the parser module").say("working")
f.raw('{"type":"user" this line is broken').say("DONE_A"); f.save()

# b) typed slash command (two entries)
f = F("case-b"); f.human("OLD_PROMPT_B").say("ok").cmd("plan", "ARGS_B", "# Plan EXPANSION_B").say("planning B"); f.save()

# c1) /recap last -> skipped; c2) /recap absent (lag)
for sid, with_recap in (("case-c1", True), ("case-c2", False)):
    f = F(sid); f.human("OLD_PROMPT_C").say("ok").human("PROMPT_C").say("did C work").bash("tc1", "make build", out="built")
    if with_recap:
        f.cmd("recap", "", "# recap EXPANSION_RECAP").bash("tc2", "python3 recap-extract.py --focus-stdin RECAP_OWN_CALL")
    f.save()

# d) compaction inside window
f = F("case-d"); f.human("PROMPT_D").say("before").compact().say("AFTER_COMPACT_D"); f.save()

# e) non-human turn starters are never the boundary
f = F("case-e"); f.human("PROMPT_E").say("e1")
f.sched("wake up: check the build").say("e2").pickup().say("e3")
f.notif_user("tE", "toolu_E", "Agent E finished", "E result").say("e4")
f.peer("PEER_BODY_E").say("e5").autoc().say("e6")
f.cmd("post-compact-resume", "", "# resume").say("e7")
f.cmd("rename", "newname", "# rename").say("e8"); f.save()

# f) queued_command mid-window
f = F("case-f"); f.human("PROMPT_F").say("f1").queued("QUEUED_F").say("f2"); f.save()

# g) Bash error vs success
f = F("case-g"); f.human("PROMPT_G").bash("g1", "false_cmd_G --flag", ok=False, out="boom")
f.bash("g2", "ok_cmd_G --flag").say("done G"); f.save()

# h) Edit / Write -> rollup
f = F("case-h"); f.human("PROMPT_H")
f.tool("h1", "Edit", {"file_path": "/Users/test/proj/edited_h.py", "old_string": "a", "new_string": "b"})
f.result("h1", "ok", tur={"filePath": "/Users/test/proj/edited_h.py", "structuredPatch": []})
f.tool("h2", "Write", {"file_path": "/Users/test/proj/new_h.py", "content": "x"})
f.result("h2", "File created", tur={"type": "create", "filePath": "/Users/test/proj/new_h.py"})
f.say("done H"); f.save()

# i) subagents: launched in window, nested (parentAgentId), launched-before-finished-in-window, excluded
f = F("case-i"); f.human("OLD_PROMPT_I").say("ok")
f.tool("toolu_I0", "Agent", {"description": "EARLY_I_DESC", "subagent_type": "researcher", "run_in_background": True})
f.result("toolu_I0", "launched", tur={"isAsync": True, "status": "async_launched", "agentId": "aI3"})
f.tool("toolu_old", "Agent", {"description": "EXCLUDED_I_DESC", "subagent_type": "Explore"})
f.result("toolu_old", "done")
f.human("PROMPT_I").say("starting agents")
f.tool("toolu_I1", "Agent", {"description": "SUB_I_DESC", "subagent_type": "implementer"})
f.result("toolu_I1", "SUB_I_FINAL", tur={"status": "completed", "agentType": "implementer"})
f.notif_user("aI3", "toolu_I0", "Agent EARLY_I_DESC finished", "early result").say("done I")
sublog(f.meta("aI1", agentType="implementer", description="SUB_I_DESC", toolUseId="toolu_I1", spawnDepth=1),
       "case-i", ["/Users/test/proj/sub_i.py"], "SUB_I_FINAL")
sublog(f.meta("aI2", agentType="Explore", description="NESTED_I_DESC", toolUseId="toolu_nested", spawnDepth=2, parentAgentId="aI1"),
       "case-i", ["/Users/test/proj/nested_i.py"], "NESTED_I_FINAL")
sublog(f.meta("aI3", agentType="researcher", description="EARLY_I_DESC", toolUseId="toolu_I0", spawnDepth=1),
       "case-i", ["/Users/test/proj/early_i.py"], "EARLY_I_FINAL")
sublog(f.meta("aI4", agentType="Explore", description="EXCLUDED_I_DESC", toolUseId="toolu_old", spawnDepth=1),
       "case-i", ["/Users/test/proj/excluded_i.py"], "EXCLUDED_I_FINAL")
f.save()

# j) legacy entries without origin; legacy ticks are not boundaries (R8)
f = F("case-j"); f.legacy("OLD_LEGACY_J").say("ok").legacy("LEGACY_PROMPT_J").say("j1")
f.legacy("Autonomous loop tick - keep going").say("j2").legacy("MISSION WAKE: phase 2").say("j3")
f.legacy("# Autonomous loop check\nstatus").say("j4"); f.save()

# k) budget: 3000 events
f = F("case-k"); f.human("PROMPT_K")
for i in range(1000):
    f.say("thinking out loud about step %d " % i + "x" * 150)
    f.bash("k%d" % i, "echo step %d " % i + "y" * 150)
f.say("FINAL_K_MARKER all done"); f.save()

# R5) local command before /recap is not a boundary
f = F("case-r5"); f.human("PROMPT_R5").say("r5").cmd("context", meta=False).local_out("ctx 40%").cmd("recap").say("recapping"); f.save()

# R6) earlier /recap turn excluded
f = F("case-r6"); f.human("PROMPT_R6").say("WORK_R6")
f.cmd("recap").bash("r6a", "old_recap_cmd_R6").say("OLD_RECAP_TEXT_R6")
f.notif_user("tR6", "toolu_R6", "NOTIF_R6 finished").say("AFTER_NOTIF_R6")
f.cmd("recap"); f.save()

# R7) sidechain entries in the main file are not counted
f = F("case-r7"); f.human("PROMPT_R7").say("r7")
f.add(base("case-r7", "user", isSidechain=True, message={"role": "user", "content": "SIDE_PROMPT_R7"}, origin={"kind": "human"}))
f.tool("s7", "Write", {"file_path": "/Users/test/proj/SIDECHAIN_R7.py"}, side=True)
f.result("s7", "created", tur={"type": "create", "filePath": "/Users/test/proj/SIDECHAIN_R7.py"}, side=True)
f.say("SIDECHAIN_SAID_R7", side=True).say("main done R7"); f.save()

# R9) attachment-form task-notification (deduped with user-form) + attachment human prompt
f = F("case-r9"); f.human("PROMPT_R9").say("r9")
f.notif_attach("T9", "toolu_T9", "NOTIF_R9_SUMMARY").say("r9b").notif_user("T9", "toolu_T9", "NOTIF_R9_SUMMARY").say("r9c")
f.queued("HUMAN_ATTACH_R9", mode="prompt").queued("NONHUMAN_ATTACH_R9", mode="prompt", origin=None).say("r9d"); f.save()

# R11) only known runners count as tests
f = F("case-r11"); f.human("PROMPT_R11")
f.bash("t1", "bash ~/scripts/mission-write.sh --phase 2").bash("t2", "pytest -q tests/unit")
f.bash("t3", "sed -n 1,20p scripts/tests/run-all.sh; grep -n 'git push' x").bash("t4", "git push origin main")
f.say("done R11"); f.save()

# R13) oversized rollup still within budget
f = F("case-r13"); f.human("PROMPT_R13")
for i in range(400):
    p = "/Users/test/proj/" + ("deep/" * 30) + "file_%03d.py" % i
    f.tool("w%d" % i, "Write", {"file_path": p, "content": "x"})
    f.result("w%d" % i, "File created", tur={"type": "create", "filePath": p})
    f.bash("b%d" % i, "false_r13_%d " % i + "z" * 150, ok=False, out="err " * 40)
f.say("FINAL_R13_MARKER"); f.save()

# fx1) long final text keeps head AND tail (closing question)
f = F("case-fx1"); f.human("PROMPT_FX1")
f.say("HEAD_FX1 " + "body text " * 300 + "Want me to catch the branch up? TAIL_QUESTION_FX1"); f.save()

# fx3) shell keywords / for-loops in test detection
f = F("case-fx3"); f.human("PROMPT_FX3")
f.bash("x1", 'for g in scripts/*-assumptions/run-all.sh; do bash "$g"; done', out="all good")
f.bash("x2", 'for f in a b; do echo "$f"; done', out="a b")
f.bash("x3", "if true; then pytest -q; fi", out="ok"); f.say("done FX3"); f.save()

# fx4) successful Bash output tails; test verdict line
f = F("case-fx4"); f.human("PROMPT_FX4")
f.bash("o1", "echo EARLY_CMD_FX4", out="EARLY_OUT_FX4")
f.bash("o2", "bash scripts/hooks/test-thing.sh", out="case 1 ok\ncase 2 ok\nPASS: 7/7\n")
f.bash("o3", "echo mid", out="MID_OUT_FX4")
f.bash("o4", "git rev-list --left-right --count HEAD...@{upstream}", out="10\t1447\n")
f.say("FINAL_FX4"); f.save()

# fx5) subagent with no final text: still running vs finished
f = F("case-fx5"); f.human("PROMPT_FX5")
f.tool("toolu_R", "Agent", {"description": "RUNNING_FX5", "run_in_background": True})
f.result("toolu_R", "launched", tur={"isAsync": True, "status": "async_launched", "agentId": "aR"})
f.tool("toolu_D", "Agent", {"description": "DONE_FX5"})
f.result("toolu_D", "", tur={"status": "completed"}); f.say("done FX5")
for aid, d, tu in (("aR", "RUNNING_FX5", "toolu_R"), ("aD", "DONE_FX5", "toolu_D")):
    with open(f.meta(aid, agentType="Explore", description=d, toolUseId=tu), "w") as fh:
        fh.write("")
f.save()

# fx6) bare slash command anchor: topic line from expansion, else earlier typed message
f = F("case-fx6a"); f.human("EARLIER_FX6A").say("ok")
f.cmd("plan", "", "# Plan playbook\nintro\n## Topic: TOPIC_FX6A\nmore").say("planning"); f.save()
f = F("case-fx6b"); f.human("EARLIER_FX6B").say("ok")
f.cmd("discussion", "", "# Discussion playbook, no topic line").say("discussing"); f.save()

# fx7) a notification / peer between a typed prompt and its first reply never steals the credit
f = F("case-fx7"); f.human("OLD_PROMPT_FX7").say("ok").human("NEW_PROMPT_FX7 with enough words to skip short-anchor context")
f.notif_user("t7", "toolu_7", "NOTIF_FX7").peer("PEER_FX7", meta=False).say("reply FX7"); f.save()

# fx8) a notification / peer inside an earlier /recap turn does not end the skip
f = F("case-fx8"); f.human("PROMPT_FX8 long enough to skip the short-anchor context").say("WORK_FX8")
f.cmd("recap").tool("r8", "Bash", {"command": "python3 recap-extract.py"}, stop="tool_use").result("r8", "sheet")
f.notif_user("t8", "toolu_8", "NOTIF_FX8").peer("PEER_FX8").say("OLD_RECAP_TEXT_FX8", stop="end_turn")
f.cmd("recap"); f.save()

# fx9) transcript ending at this /recap's Bash call: no settle wait
f = F("case-fx9"); f.human("PROMPT_FX9 long enough to skip the short-anchor context").say("did FX9")
f.cmd("recap").tool("r9", "Bash", {"command": "python3 scripts/recap-extract.py --focus-stdin"}); f.save()

# fx10) short anchor gets the earlier typed message
f = F("case-fx10"); f.human("EARLIER_FX10 please migrate the billing table").say("plan ready - go?")
f.human("yes go ahead").say("migrating"); f.save()

# folder preference: same sid in two folders, cwd-matching folder wins
cwd_folder = os.path.join(os.path.dirname(D), os.environ["RECAP_CWD_MANGLED"])
os.makedirs(cwd_folder, exist_ok=True)
F("case-dup", D).human("WRONG_FOLDER_PROMPT").say("x").save()
F("case-dup", cwd_folder).human("CWD_FOLDER_PROMPT").say("x").save()
PYGEN
[ $? -eq 0 ] || { echo "FATAL: fixture generator failed" >&2; exit 2; }

# ------------------------------------------------------------------ cases
# a) plain typed prompt
runs case-a
check "a: exit 0" 0 "$RC"
has "a: anchor is the latest prompt" "opened this window: NEW_PROMPT_A"
lacks "a: earlier prompt not in output" "OLD_PROMPT_A"
has "a: malformed line counted" "malformed lines skipped: 1"
has "a: LIMITS line present" "LIMITS: "
has "a: final text" "DONE_A"
lacks "a: thinking never printed" "SECRET_THINKING"

# b) typed slash command
runs case-b
has "b: anchor is the command with args" "opened this window: /plan ARGS_B"
lacks "b: expansion not printed" "EXPANSION_B"

# c) /recap skipped; /recap absent (lag)
runs case-c1
has "c1: /recap skipped, previous prompt is anchor" "opened this window: PROMPT_C"
lacks "c1: the recap's own call excluded" "RECAP_OWN_CALL"
has "c1: earlier work shown" "make build"
runs case-c2
has "c2: no /recap yet (lag) - prompt is anchor" "opened this window: PROMPT_C"

# d) compaction inside the window
runs case-d
has "d: anchor survives compaction" "opened this window: PROMPT_D"
has "d: compaction event" "context compacted"
has "d: compaction counted" "compactions 1"
has "d: post-compaction work shown" "AFTER_COMPACT_D"
lacks "d: summary text is not an event" "SUMMARY_TEXT"

# e) non-human turn starters never the boundary
runs case-e
has "e: anchor is the human prompt" "opened this window: PROMPT_E"
has "e: scheduled tick shown" "woke itself up (scheduled)"
has "e: peer shown as unverified" "message from another window (unverified): peer-7: PEER_BODY_E"
has "e: task notification shown" "background job finished: Agent E finished"
has "e: auto-continuation shown" "auto-continued"
has "e: work after hook-typed commands still in window" "e8"

# f) queued mid-turn message
runs case-f
has "f: anchor not the queued message" "opened this window: PROMPT_F"
has "f: queued message listed" "you also said: QUEUED_F"

# g) Bash failure vs success
runs case-g
FAILED_G=$(section "Failed commands:")
check "g: failed command listed" 1 "$(printf '%s\n' "$FAILED_G" | grep -c 'false_cmd_G')"
check "g: successful command not in failed list" 0 "$(printf '%s\n' "$FAILED_G" | grep -c 'ok_cmd_G')"
has "g: exit code reported" "Exit code 1"

# h) Edit/Write rollup
runs case-h
has "h: created file in rollup" "/Users/test/proj/new_h.py (created, main)"
has "h: edited file in rollup" "/Users/test/proj/edited_h.py (edited, main)"

# i) subagents (R10)
runs case-i
has "i: window agent digested" "SUB_I_DESC [implementer]"
has "i: subagent edit rolled up" "/Users/test/proj/sub_i.py (created, agent: SUB_I_DESC)"
has "i: subagent final text" "result: SUB_I_FINAL"
has "i: nested agent via parentAgentId" "NESTED_I_DESC [Explore] (nested)"
has "i: nested agent edit rolled up" "nested_i.py"
has "i: launched-earlier agent finishing in window" "EARLY_I_FINAL"
lacks "i: unrelated earlier agent excluded" "EXCLUDED_I_FINAL"
lacks "i: earlier prompt not anchor" "opened this window: OLD_PROMPT_I"

# j) legacy entries without origin (R8 ticks)
runs case-j
has "j: legacy prompt detected as human" "opened this window: LEGACY_PROMPT_J"
has "j: legacy ticks are events, not the boundary" "j4"

# k) budget
runs case-k
check "k: exit 0" 0 "$RC"
check "k: output within default budget" 1 "$([ ${#OUT} -le 20000 ] && echo 1 || echo 0)"
has "k: rollup kept" "ROLLUP"
has "k: final text kept" "FINAL_K_MARKER"
has "k: drops reported" "events condensed/dropped for budget: "
lacks "k: not zero dropped" "dropped for budget: 0 of"

# R5) local command is not a boundary
runs case-r5
has "R5: local command before /recap skipped" "opened this window: PROMPT_R5"

# R6) earlier /recap turn excluded
runs case-r6
has "R6: anchor" "opened this window: PROMPT_R6"
has "R6: real work kept" "WORK_R6"
lacks "R6: earlier recap text dropped" "OLD_RECAP_TEXT_R6"
lacks "R6: earlier recap command dropped" "old_recap_cmd_R6"
has "R6: work after the earlier recap kept" "AFTER_NOTIF_R6"

# R7) sidechain entries in the main file
runs case-r7
has "R7: anchor is main prompt" "opened this window: PROMPT_R7"
lacks "R7: sidechain file not counted" "SIDECHAIN_R7.py"
lacks "R7: sidechain text not counted" "SIDECHAIN_SAID_R7"

# R9) attachment-form notification + dedupe; attachment human prompt
runs case-r9
check "R9: notification shown once" 1 "$(printf '%s\n' "$OUT" | grep -c 'NOTIF_R9_SUMMARY')"
has "R9: attachment human prompt is 'you also said'" "you also said: HUMAN_ATTACH_R9"
lacks "R9: non-human attachment not 'you also said'" "NONHUMAN_ATTACH_R9"

# R11) narrow test heuristic
runs case-r11
TESTS_R11=$(section "Tests run")
check "R11: pytest counted" 1 "$(printf '%s\n' "$TESTS_R11" | grep -c 'PASS test: pytest')"
check "R11: mission-write.sh not a test" 0 "$(printf '%s\n' "$TESTS_R11" | grep -c 'mission-write')"
check "R11: reading run-all.sh is not running it" 0 "$(printf '%s\n' "$TESTS_R11" | grep -c 'sed -n')"
check "R11: real push listed once" 1 "$(section "Commits" | grep -c 'push (ok)')"

# R13) oversized rollup
runs case-r13
check "R13: default budget respected" 1 "$([ ${#OUT} -le 20000 ] && echo 1 || echo 0)"
has "R13: rollup list capped" "+375 more"
has "R13: final text kept" "FINAL_R13_MARKER"
runs case-r13 --budget 3000
check "R13: tight budget respected" 1 "$([ ${#OUT} -le 3000 ] && echo 1 || echo 0)"

# fx1) head + tail of the final text
runs case-fx1
has "fx1: final keeps head" "HEAD_FX1"
has "fx1: final keeps closing question" "TAIL_QUESTION_FX1"
has "fx1: cut is marked" " … "

# fx3) shell keywords / for-loops
runs case-fx3
TESTS_FX3=$(section "Tests run")
check "fx3: for-loop over run-all.sh is a test" 1 "$(printf '%s\n' "$TESTS_FX3" | grep -c 'assumptions/run-all.sh')"
check "fx3: for-loop over plain words is not" 0 "$(printf '%s\n' "$TESTS_FX3" | grep -c 'for f in a b')"
check "fx3: if/then prefix stripped" 1 "$(printf '%s\n' "$TESTS_FX3" | grep -c 'pytest -q')"

# fx4) output tails + test verdict
runs case-fx4
has "fx4: test labeled by last output line" "PASS test: bash scripts/hooks/test-thing.sh -> PASS: 7/7"
has "fx4: last command output tail shown" "=> output ends: 10 1447"
has "fx4: recent command output shown" "MID_OUT_FX4"
lacks "fx4: older command output not shown" "EARLY_OUT_FX4"

# fx5) subagent without final text
runs case-fx5
has "fx5: running agent" "(still running or no result yet)"
check "fx5: finished agent" 1 "$(printf '%s\n' "$OUT" | grep -c 'result: (no final text)')"

# fx6) bare slash command anchor context
runs case-fx6a
has "fx6a: topic line appended" "opened this window: /plan (Topic: TOPIC_FX6A)"
runs case-fx6b
has "fx6b: earlier message appended" "opened this window: /discussion (earlier message: EARLIER_FX6B)"

# fx7) credit not stolen by notification / peer
runs case-fx7
has "fx7: typed prompt keeps the reply credit" "opened this window: NEW_PROMPT_FX7"
has "fx7: notification still listed" "NOTIF_FX7"

# fx8) notification inside an earlier /recap turn
runs case-fx8
has "fx8: anchor" "opened this window: PROMPT_FX8"
has "fx8: real work kept" "WORK_FX8"
lacks "fx8: earlier recap reply stays skipped" "OLD_RECAP_TEXT_FX8"
has "fx8: notification inside it still listed" "NOTIF_FX8"

# fx9) no settle wait when the transcript ends at this /recap call (file was just written)
OUT=$(cd "$TMP/work" && RECAP_SETTLE_SECONDS=30 python3 "$SCRIPT" --session case-fx9 2>/dev/null </dev/null)
has "fx9: settle skipped at the /recap call" "already ends at this /recap call"
has "fx9: anchor" "opened this window: PROMPT_FX9"

# fx10) short anchor context
runs case-fx10
has "fx10: short anchor gets earlier message" "opened this window: yes go ahead (earlier message: EARLIER_FX10 please migrate the billing table)"
runs case-a
lacks "fx10: long anchor gets no earlier message" "earlier message"

# focus via stdin
OUT=$(cd "$TMP/work" && printf 'FOCUS_TEXT_Z' | python3 "$SCRIPT" --session case-a --focus-stdin 2>/dev/null)
has "focus echoed in header" "focus: FOCUS_TEXT_Z"

# --transcript override; cwd-matching folder preferred over others
run --transcript "$RECAP_PROJECTS_DIR/-Users-test-proj/case-f.jsonl"
has "transcript flag works" "opened this window: PROMPT_F"
runs case-dup
has "cwd-matching folder preferred" "CWD_FOLDER_PROMPT"

# m) missing transcript / R2 no session id -> exit 2, one stderr line
run --transcript "$TMP/nope.jsonl"
check "m: missing transcript exit 2" 2 "$RC"
check "m: one stderr line" 1 "$(printf '%s\n' "$ERR" | grep -c .)"
runs no-such-session
check "m: unknown session exit 2" 2 "$RC"
run
check "R2: no session id exit 2" 2 "$RC"
check "R2: says why" 1 "$(printf '%s' "$ERR" | grep -c 'no session id')"
check "R2: nothing on stdout" "" "$OUT"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
