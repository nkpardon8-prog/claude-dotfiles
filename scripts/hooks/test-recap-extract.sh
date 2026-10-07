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
    def add(self, d): self.rows.append(json.dumps(d)); return self
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
    def say(self, text, side=False):
        return self.add(base(self.sid, "assistant", isSidechain=side, message={"role": "assistant", "content": [
            {"type": "thinking", "thinking": "SECRET_THINKING"}, {"type": "text", "text": text}]}))
    def tool(self, tid, name, inp, side=False):
        return self.add(base(self.sid, "assistant", isSidechain=side, message={"role": "assistant", "content": [
            {"type": "tool_use", "id": tid, "name": name, "input": inp}]}))
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
    def peer(self, body):
        return self.add(base(self.sid, "user", isMeta=True, message={"role": "user",
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
f = F("case-a"); f.human("OLD_PROMPT_A").say("old answer").human("NEW_PROMPT_A").say("working")
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
f.cmd("recap").say("OLD_RECAP_TEXT_R6").bash("r6a", "old_recap_cmd_R6")
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

# folder preference: same sid in two folders, cwd-matching folder wins
cwd_folder = os.path.join(os.path.dirname(D), os.environ["RECAP_CWD_MANGLED"])
os.makedirs(cwd_folder, exist_ok=True)
F("case-dup", D).human("WRONG_FOLDER_PROMPT").say("x").save()
F("case-dup", cwd_folder).human("CWD_FOLDER_PROMPT").say("x").save()
PYGEN
[ $? -eq 0 ] || { echo "FATAL: fixture generator failed" >&2; exit 2; }
