#!/usr/bin/env bash
# PostToolUse[most tools] — writes a "what it's doing now" sidecar:
# ~/.claude/progress/<sid>.activity.json = {"ts":<epoch>,"label":"<short label>"}.
# A SEPARATE file (like the beacon <sid>.current.json sidecar) so it NEVER read-modify-writes
# the shared progress JSON → cannot clobber overall/current or resurrect active after Stop.
# The renderer reads it independently, gated by ts >= prompt_started_at. NO set -e/pipefail; exit 0.
INPUT=$(cat)
NOW=$(date +%s)
CLAUDE_HOOK_INPUT="$INPUT" NOW="$NOW" python3 - <<'PY' 2>/dev/null
import json, os, re
now = int(os.environ.get("NOW", "0"))
try: d = json.loads(os.environ.get("CLAUDE_HOOK_INPUT", "") or "{}")
except Exception: raise SystemExit
sid = re.sub(r'[^A-Za-z0-9_-]', '', str(d.get("session_id") or ""))[:128]
if not sid: raise SystemExit
t  = d.get("tool_name") or ""
ti = d.get("tool_input") or {}
def base(p): return os.path.basename(str(p)) if p else ""
def short(s, n=44):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[:n-1] + "…"
if   t in ("Edit", "MultiEdit", "NotebookEdit"): lab = f"Edit {base(ti.get('file_path') or ti.get('notebook_path'))}"
elif t == "Write": lab = f"Write {base(ti.get('file_path'))}"
elif t == "Read":  lab = f"Read {base(ti.get('file_path'))}"
elif t == "Bash":
    desc = ti.get("description")
    cmd  = (str(ti.get("command") or "").split() or [""])[0]
    lab = "Bash: " + short(desc if desc else cmd, 38)
elif t == "Grep":  lab = "Grep " + short(ti.get("pattern") or "", 38)
elif t == "Glob":  lab = "Glob " + short(ti.get("pattern") or "", 38)
elif t == "WebFetch":
    u = str(ti.get("url") or ""); host = u.split("/")[2] if "://" in u else u
    lab = f"Fetch {host}"
elif t == "WebSearch": lab = "Search " + short(ti.get("query") or "", 34)
elif t == "Task":      lab = "Task: " + short(ti.get("subagent_type") or "agent", 30)
elif t.startswith("mcp__"): lab = t.split("__")[-1] or t
else: lab = t or "working"
lab = short(lab)
home = os.path.expanduser("~")
F   = f"{home}/.claude/progress/{sid}.activity.json"
TMP = f"{F}.tmp.{os.getpid()}"
try:
    with open(TMP, "w") as fh: json.dump({"ts": now, "label": lab}, fh)
    os.replace(TMP, F)
except Exception:
    try: os.remove(TMP)
    except Exception: pass
PY
exit 0
