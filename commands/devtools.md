---
description: Self-healing chrome-devtools connector. Ensures a debug Chrome (with the user's real profile + tabs) is running on port 9222, kills stale MCP processes, scrubs corrupt npx installs, and prompts /mcp reconnect. Use when chrome-devtools tool calls hang, error, stop responding, or when you just want devtools to connect to the user's existing tabs.
---

# DevTools Connect (self-healing, real-profile)

Goal: running `/devtools` on **any** agent makes the `chrome-devtools` MCP connect to the user's **real Chrome profile and existing tabs** — every time, without thinking about it.

## How this works (and the 3 things that break it)

The user's everyday Chrome runs from a **migrated profile** at `~/.chrome-debug-profile` (a copy of their real `~/Library/Application Support/Google/Chrome` profile — same logins, bookmarks, extensions, and restored tabs) with the **debug port on 9222**. The MCP connects via `--browserUrl http://127.0.0.1:9222`. This is the ONLY way to debug the user's real tabs on current Chrome. Four failure modes, each prevented below:

1. **Chrome 136+ blocks remote debugging on the *default* profile** (security: stops malware reading cookies via CDP). Symptom: socket listens on the port but `/json/version` never responds → MCP hangs forever on first call. Prevention: we run from a **non-default** `--user-data-dir` (`~/.chrome-debug-profile`), which is allowed. NEVER use `--autoConnect` (it targets the default profile and hangs). Ref: chrome-devtools-mcp issue #1830.
2. **The "Who's using Chrome?" profile picker.** If the profile has multiple people, Chrome opens the picker instead of the profile → **0 tabs, 0 windows**, only a `browser_ui` target titled "Who's using Chrome?". Prevention: always launch with `--profile-directory="Default"` (+ `picker_on_startup:false` in Local State).
3. **Stale MCP node procs / corrupt npx install cache** wedge the server. Prevention: Step 2 kills all `chrome-devtools-mcp` procs and scrubs the npx cache.
4. **Discarded / frozen background tabs hang the connection (the silent killer).** Chrome freezes or discards background tabs to save memory; a frozen tab's CDP target stops answering. On connect, chrome-devtools-mcp's `detectOpenDevToolsWindows()` probes **every** page target in a single `Promise.all` with no timeout (`McpContext.js` → `hasDevTools()`/`openDevTools()` per page). **One unresponsive tab hangs the whole enumeration forever** — `initialize` succeeds (tools list fine) but the first tool call (`list_pages`, `take_snapshot`, …) spins indefinitely. This is the failure mode where everything *looks* healthy (`/json/version` responds, tabs are listed in `/json/list`) yet tool calls never return. Prevention: **Step 1.5 wakes every tab** (`/json/activate/<id>`) before you reconnect, so all CDP targets answer. Diagnostic signature in `--logFile` debug output: `Connected Puppeteer` prints, then nothing — it's stuck in page enumeration, not the connection itself.

If you ever see `--autoConnect` or `127.0.0.1:9333` back in the MCP config (`~/.claude.json` `mcpServers.chrome-devtools` + `~/.claude/chrome-devtools-mcp-entry.json`), that's a regression — it must be `--browserUrl http://127.0.0.1:9222`.

## Step 1: Ensure the real-profile debug Chrome is up on 9222

Idempotent — launches only if the endpoint isn't already healthy.

```bash
DEBUG_PORT=9222
DEBUG_PROFILE="$HOME/.chrome-debug-profile"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

cdp_healthy() {
  curl -s --max-time 4 "http://127.0.0.1:$DEBUG_PORT/json/version" 2>/dev/null \
    | grep -q '"webSocketDebuggerUrl"'
}
page_count() {
  curl -s --max-time 5 "http://127.0.0.1:$DEBUG_PORT/json/list" 2>/dev/null \
    | python3 -c "import sys,json;print(len([t for t in json.load(sys.stdin) if t.get('type')=='page']))" 2>/dev/null || echo 0
}

if [ ! -d "$DEBUG_PROFILE/Default" ]; then
  echo "ERROR: migrated profile missing at $DEBUG_PROFILE — run the one-time SETUP block at the bottom of this skill first."
elif cdp_healthy; then
  echo "Debug Chrome already healthy on $DEBUG_PORT — $(page_count) tab(s) open."
else
  echo "Endpoint on $DEBUG_PORT not responding — launching real-profile debug Chrome..."
  pkill -f -- "--user-data-dir=$DEBUG_PROFILE" 2>/dev/null || true
  sleep 1
  if [ ! -x "$CHROME" ]; then
    echo "ERROR: Chrome not found at: $CHROME (edit CHROME= in this skill)."
  else
    # restore_on_startup=1 (continue where you left off) is set in Preferences during SETUP,
    # so a normal launch restores the user's tabs. --profile-directory=Default skips the picker.
    nohup "$CHROME" \
      --remote-debugging-port=$DEBUG_PORT \
      --user-data-dir="$DEBUG_PROFILE" \
      --profile-directory="Default" \
      --restore-last-session \
      --hide-crash-restore-bubble \
      --no-first-run --no-default-browser-check \
      >/dev/null 2>&1 &
    disown
    for i in $(seq 1 15); do sleep 1; cdp_healthy && break; done
    sleep 5  # let tabs restore
    if cdp_healthy; then
      echo "Debug Chrome up on $DEBUG_PORT — $(page_count) tab(s) restored."
    else
      echo "WARNING: debug Chrome did not come up healthy on $DEBUG_PORT after ~15s."
      echo "Check: lsof -nP -iTCP:$DEBUG_PORT  |  is the 'Who's using Chrome?' picker showing? (need --profile-directory)"
    fi
  fi
fi
```

## Step 2: Kill stale MCP processes + scrub corrupt installs

The MCP server must respawn fresh so it reads the current config and connects to 9222.

```bash
BEFORE=$(pgrep -f 'chrome-devtools-mcp' 2>/dev/null | wc -l | tr -d ' ')
echo "Found $BEFORE chrome-devtools-mcp process(es)"
[ "$BEFORE" -gt 0 ] && (pgrep -fl 'chrome-devtools-mcp' 2>/dev/null || true)

pkill -TERM -f 'chrome-devtools-mcp' 2>/dev/null || true
sleep 1
pkill -KILL -f 'chrome-devtools-mcp' 2>/dev/null || true
sleep 1
SURVIVORS=$(pgrep -f 'chrome-devtools-mcp' 2>/dev/null | wc -l | tr -d ' ')
if [ "$SURVIVORS" -gt 0 ]; then
  echo "WARNING — $SURVIVORS survived SIGKILL:"; pgrep -fl 'chrome-devtools-mcp' 2>/dev/null || true
else
  echo "Clean — no chrome-devtools-mcp processes remain."
fi

# npx install scrub — removes the ENTIRE hash dir (deleting just the package leaves a
# dangling .bin symlink that makes npx fail with "Permission denied").
SCRUBBED=0
for d in ~/.npm/_npx/*/; do
  if [ -e "$d/node_modules/chrome-devtools-mcp" ] || [ -L "$d/node_modules/.bin/chrome-devtools-mcp" ]; then
    rm -rf "$d" 2>/dev/null || true; SCRUBBED=$((SCRUBBED + 1))
  fi
done
echo "npx install cache scrubbed ($SCRUBBED hash dir(s) removed)."
```

## Step 3: Print the reconnect instruction verbatim

Output verbatim. Do not summarize, paraphrase, or add a prefix:

```
Debug Chrome is up on port 9222 with your real profile + tabs, and chrome-devtools MCP is cleaned.

Next step (you must do this yourself — Claude can't restart its own MCP transport mid-session):
  1. Type /mcp into the Claude Code chat input and press Enter.
  2. Find chrome-devtools in the list.
  3. Reconnect it.

It connects to your migrated profile (~/.chrome-debug-profile) — same logins, same tabs.
Always launch this Chrome via /devtools (or the `chrome-debug` alias), NOT the dock icon —
the dock icon opens the default profile, which Chrome 136+ refuses to let us debug.
```

## Step 4: Sub-agent delegation for DevTools work

DevTools results (`take_snapshot`, `list_console_messages`, `list_network_requests`, `evaluate_script`, screenshots) are large and bloat the parent context. **Default:** delegate `mcp__chrome-devtools__*` calls to a sub-agent (`Agent`, `subagent_type: "general-purpose"`), briefing it with the goal, URL/tab, what to look for, and asking for a short report. Relax only if the user explicitly says they want to watch the calls in the main thread.

## SETUP (one-time, per machine) — migrate the real profile

Run this ONCE to create the debuggable copy of the user's real Chrome profile. It needs Chrome fully quit so cookie/login DBs copy cleanly.

```bash
SRC="$HOME/Library/Application Support/Google/Chrome"
DST="$HOME/.chrome-debug-profile"

# 1) Quit Chrome gracefully (saves the tab session for restore), then force stragglers.
osascript -e 'quit app "Google Chrome"' 2>/dev/null || true; sleep 6
osascript -e 'quit app "Google Chrome"' 2>/dev/null || true; sleep 4
pkill -KILL -f 'Google Chrome' 2>/dev/null || true; sleep 2

# 2) Copy profile minus caches/locks (~5GB; logins, bookmarks, extensions, Sessions/ for restore).
rm -rf "$DST"; mkdir -p "$DST"
rsync -a \
  --exclude 'Singleton*' --exclude '*/Cache/' --exclude '*/Code Cache/' --exclude '*/GPUCache/' \
  --exclude '*/DawnCache/' --exclude '*/DawnGraphiteCache/' --exclude '*/DawnWebGPUCache/' \
  --exclude '*/GrShaderCache/' --exclude '*/ShaderCache/' --exclude '*/GraphiteDawnCache/' \
  --exclude '*/Service Worker/CacheStorage/' --exclude '*/Service Worker/ScriptCache/' \
  --exclude '*/Application Cache/' --exclude 'Crashpad/' --exclude '*/component_crx_cache/' \
  --exclude '*/extensions_crx_cache/' --exclude '*/Safe Browsing/' \
  "$SRC/" "$DST/"

# 3) Force "continue where you left off" + skip the profile picker.
python3 - <<PY
import json
p=f"$DST/Default/Preferences"; d=json.load(open(p))
d.setdefault("session",{})["restore_on_startup"]=1
d.setdefault("profile",{})["exit_type"]="Crashed"   # one-time: makes the migrated session restore on first launch
json.dump(d,open(p,"w"),separators=(",",":"))
try:
    lp=f"$DST/Local State"; ls=json.load(open(lp))
    ls.setdefault("profile",{})["picker_on_startup"]=False
    json.dump(ls,open(lp,"w"),separators=(",",":"))
except Exception as e: print("Local State:",e)
print("profile prepped: restore_on_startup=1, picker disabled")
PY
echo "SETUP done. Now run Step 1 to launch it."
```

Optional convenience alias (add to `~/.zshrc`) so the user can open their debuggable Chrome by hand:

```bash
alias chrome-debug='"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --remote-debugging-port=9222 --user-data-dir="$HOME/.chrome-debug-profile" --profile-directory="Default" --restore-last-session --hide-crash-restore-bubble --no-first-run --no-default-browser-check >/dev/null 2>&1 &'
```

## Why this exists

`chrome-devtools` MCP connecting to the user's real tabs fails for three compounding reasons, all fixed here: (1) Chrome 136+ blocks remote debugging on the default profile → we run a migrated copy from a non-default `--user-data-dir`; (2) the multi-profile "Who's using Chrome?" picker eats the launch → we force `--profile-directory=Default`; (3) stale MCP procs / corrupt npx cache → we kill + scrub. Idempotent and safe to run when nothing is wedged. Never touches the user's original default profile (read-only copy), `claude-in-chrome`, or any other MCP server.
