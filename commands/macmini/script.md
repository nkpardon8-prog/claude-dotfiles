---
description: Run an AppleScript on the Mac mini via gist transport. Covers System Events menu picks, app activation, window management, and anything cliclick cannot do.
argument-hint: "<applescript body — multi-line OK>"
---

# /macmini script

Runs an AppleScript on the Mac mini's OS via gist transport.
Use for anything cliclick cannot do: app activation, menu picks via System Events,
window management, Finder operations.

This sub-command is SELF-CONTAINED. The gist transport mechanics follow paste.md
Step 0 (credential pre-scan — extended with an AppleScript-specific pattern here)
and Step 5 (unshifted-safety for the clone command). The AppleScript body is
delivered via a TEMPFILE + `osascript /path/to/run.applescript`, NOT via
`osascript -e '...'` — single-quote safety.

See also: /macmini click, /macmini drag (for mouse events). For text delivery,
see /macmini paste.

## Threat model reminder

The gist transport is the same channel used by /macmini paste. GitHub secret-scanning
runs on ALL gists (including secret/unlisted). If the AppleScript body contains
credentials (e.g. embedded in a `do shell script "curl -H 'Authorization: Bearer sk-...'"`),
the key WILL be revoked within minutes. Step 0 below extends paste.md's 11 credential
patterns with one AppleScript-specific pattern to catch this.

## Step 0 — Credential pre-scan — HARD GATE (EXTENDED for AppleScript)

Before doing anything else, scan `$ARGUMENTS` against all patterns from paste.md
Step 0 (patterns 1-11), PLUS this AppleScript-specific pattern:

| # | Pattern name | Regex | Catches |
|---|---|---|---|
| 12 | `applescript-do-shell-cred` | `do\s+shell\s+script\s+"[^"]*(sk-ant-\|sk-(?!ant-)\|ghp_\|gho_\|ghs_\|AKIA\|ASIA\|xox[baprs]-\|AIza)` | API keys embedded in `do shell script "curl ..."` constructs inside AppleScript — these bypass the auth-header pattern (pattern 9) because no literal `Authorization:` separator is needed when the key appears as a positional shell argument. |

Use `python3` with `re` for PCRE-compatible matching (macOS BSD `grep` lacks `-P`):

```bash
python3 -c '
import re, sys
payload = sys.argv[1]
patterns = [
    (1,  "anthropic-key",           r"\bsk-ant-[A-Za-z0-9_-]{16,}\b"),
    (2,  "openai-key",              r"\bsk-(?!ant-)[A-Za-z0-9_-]{16,}\b"),
    (3,  "github-token",            r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"),
    (4,  "aws-access-key",          r"\b(AKIA|ASIA)[0-9A-Z]{16}\b"),
    (5,  "aws-secret-key-named",    r"(?i)aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*[\"'"'"']?[A-Za-z0-9/+=]{40}"),
    (6,  "slack-token",             r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"),
    (7,  "google-api-key",          r"\bAIza[0-9A-Za-z_-]{35}\b"),
    (8,  "private-key-block",       r"-----BEGIN ((RSA|EC|OPENSSH|DSA|PGP|ENCRYPTED) )?PRIVATE KEY-----"),
    (9,  "auth-header",             r"(?i)\b(Authorization|Proxy-Authorization)\s*[:=]\s*(Bearer|Token)\s+\S{12,}"),
    (10, "1password-resolved",      r"\bop://\S+\s+[A-Za-z0-9_/+=-]{20,}\b"),
    (11, "high-entropy-env-cred",   r"(?i)\b(API_KEY|PASSWORD|PASSPHRASE|PRIVATE_KEY|SECRET_KEY|ACCESS_KEY)\s*=\s*[\"'"'"']?(?!YOUR_|EXAMPLE|PLACEHOLDER|REPLACE_ME|CHANGEME|FILL|TODO|dummy|test_|xxx|\*\*\*|<|\.\.\.)[A-Za-z0-9_/+=.-]{20,}[\"'"'"']?"),
    (12, "applescript-do-shell-cred", r"do\s+shell\s+script\s+\"[^\"]*(sk-ant-|sk-(?!ant-)|ghp_|gho_|ghs_|AKIA|ASIA|xox[baprs]-|AIza)"),
]
for num, name, pat in patterns:
    if re.search(pat, payload):
        print(f"BLOCKED #{num} ({name})")
        sys.exit(1)
sys.exit(0)
' "$ARGUMENTS"
```

If blocked, print the same loud banner as paste.md Step 0 (matched pattern # and name).
Do NOT echo the matched bytes. Refuse and offer `--secure` alternatives. Non-overridable.

## Step 1 — Parse args

```bash
# $ARGUMENTS is the entire AppleScript body. No positional parsing needed.
# Refuse empty payload.
if [ -z "$ARGUMENTS" ]; then
  echo "ERROR: /macmini script requires an AppleScript body"; exit 1
fi
```

## Step 2 — Pre-flight: find and select the CRD page

```
mcp.list_pages()
```

Find the page whose URL starts with `https://remotedesktop.google.com/access/session/`.
If none found, abort: "CRD canvas not present — run /macmini connect first."

```
mcp.select_page({pageId: <crd_page_id>, bringToFront: true})
```

Take a screenshot and confirm the Mac mini Terminal is the focused window
with a shell prompt visible. If not, recover via (in order of reliability):
1. `mcp.press_key("Meta+Tab")` — cycle to MRU app.
2. `mcp.press_key("Meta+h")` — hide top app to reveal Terminal behind it.
3. Ask the user to click Terminal in the Dock.

Do NOT proceed until Terminal is foreground — the typed clone command goes
to whatever IS foreground, and a missed Terminal sends an `rm -rf /tmp/...`
keystroke into eBay's search box or wherever.

## Step 3 — Build run.sh with randomized heredoc terminator

The AppleScript body IS user text and CAN contain single quotes, double quotes,
and any arbitrary syntax. Use a randomized quoted heredoc (same machinery as
paste.md Step 3) so the body is delivered byte-perfect.

```bash
TMPDIR_LOCAL="$(mktemp -d -t macmini-script.XXXXXX)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT INT TERM
RUN_FILE="$TMPDIR_LOCAL/run.sh"

# Random terminator — must NOT appear in the AppleScript body.
TERMINATOR="MACMINI_$(openssl rand -hex 8)_END"
case "$ARGUMENTS" in
  *"$TERMINATOR"*)
    echo "ERROR: heredoc terminator collision (1-in-2^64) — retry"
    exit 1
    ;;
esac

# Build run.sh:
#   - mkdir /tmp/macmini-script on the mini
#   - Write AppleScript body to /tmp/macmini-script/run.applescript via heredoc
#   - Run: /usr/bin/osascript /tmp/macmini-script/run.applescript
#   - Print OK
#
# IMPORTANT: the heredoc terminator is QUOTED ('TERMINATOR') so the mini-side
# shell does NOT expand $-variables inside the AppleScript body. This preserves
# the script bytes exactly as the agent wrote them.

{
  printf '%s\n' '#!/bin/bash'
  printf '%s\n' 'set -uo pipefail'
  printf '%s\n' 'mkdir -p /tmp/macmini-script'
  printf '%s%s%s\n' "cat > /tmp/macmini-script/run.applescript <<'" "$TERMINATOR" "'"
  printf '%s' "$ARGUMENTS"
  case "$ARGUMENTS" in
    *$'\n') : ;;
    *)      printf '\n' ;;
  esac
  printf '%s\n' "$TERMINATOR"
  printf '%s\n' '/usr/bin/osascript /tmp/macmini-script/run.applescript'
  printf '%s\n' 'OSARC=$?'
  printf '%s\n' 'echo "osascript exit: $OSARC"'
  # Refocus Terminal at the end so the NEXT gist round-trip can be typed
  # without a manual Cmd+Tab. Drop this line if you specifically want the
  # AppleScript target (e.g. Chrome) to remain foreground.
  printf '%s\n' "osascript -e 'tell application \"Terminal\" to activate' >/dev/null 2>&1"
  printf '%s\n' 'echo OK'
} > "$RUN_FILE"
```

**First-run automation TCC prompt.** The FIRST time an AppleScript controls
a new target app from a given source (Terminal/osascript), macOS shows
*"Terminal wants access to control X"*. The user must click **Allow**.
Persistent per-app-pair. If `osascript exit: 1` lands and the AppleScript
body looked correct, the prompt is likely waiting under a foreground app
— have the user Cmd+H to find it, then Allow.

Gist filename will be `run.sh` (derived from the basename of `$RUN_FILE`).
The clone command hard-codes `bash /tmp/macmini-script-gist/run.sh` — the
temp dir on the mini is `macmini-script-gist` (distinct from the AppleScript
staging dir `/tmp/macmini-script/`).

## Step 4 — Upload as a SECRET gist

```bash
GIST_OUT=$(gh gist create "$RUN_FILE" 2>&1)
GIST_URL=$(printf '%s' "$GIST_OUT" | grep -oE 'https://gist\.github\.com/[^[:space:]]+' | head -n1)
GIST_ID=$(printf '%s' "$GIST_URL" | sed -E 's#.*/##' | sed 's/[?#].*//')
case "$GIST_ID" in
  ([a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]*) ;;
  *) echo "ERROR: gh did not produce a gist URL. Output: $GIST_OUT"; exit 3 ;;
esac
```

## Step 5 — Validate clone command is unshifted-safe, then type it

```bash
CLONE_CMD="rm -rf /tmp/macmini-script-gist; gh gist clone $GIST_ID /tmp/macmini-script-gist; bash /tmp/macmini-script-gist/run.sh"

LC_ALL=C bash -c '
  case "$1" in
    (*[^a-z0-9\ /.\;:_-]*) exit 3 ;;
  esac
' _ "$CLONE_CMD" || { echo "ERROR: clone command contains unsafe chars"; exit 3; }
```

```
mcp.type_text("rm -rf /tmp/macmini-script-gist; gh gist clone " + GIST_ID + " /tmp/macmini-script-gist; bash /tmp/macmini-script-gist/run.sh", "Enter")
```

## Step 6 — Verify clone + execute landed

```
mcp.take_screenshot()
```

Confirm:
- `Cloning into '/tmp/macmini-script-gist/'` line present, AND
- `OK` line from run.sh (printed after `osascript` exits 0), AND
- A fresh shell prompt at the bottom.

Shift-strip detection: continuation prompt (`> `, `bquote>`, etc.) → press
Control+c twice, retry. `gh: command not found` → mini missing gh.

If `osascript` exits non-zero (error line visible before `OK` is missing):
- Check for `Not authorized to send Apple events to ...` → Automation TCC not
  granted. Instruct: System Settings → Privacy & Security → Automation → grant
  Terminal permission to control the target app.
- Check for `syntax error` → AppleScript body has a parse error. Show the
  error line; ask user to fix the script.

## Step 7 — Verify-after

```
mcp.take_screenshot()
```

Confirm the AppleScript had its intended visual effect on the mini's screen.

## Step 8 — Cleanup

```bash
gh gist delete "$GIST_ID" --yes 2>/dev/null
```

## Step 9 — Final report

```
ran applescript (<first 60 chars of body>...) via gist $GIST_ID (deleted)
```

---

## Examples

### Activate an app by name

```applescript
tell application "Finder" to activate
```

Brings Finder to the foreground on the mini.

### Pick a menu item via System Events

```applescript
tell application "System Events"
  tell process "Safari"
    click menu item "New Window" of menu 1 of menu bar item "File" of menu bar 1
  end tell
end tell
```

Opens a new Safari window.

### Window management

```applescript
tell application "Finder"
  set bounds of front window to {0, 0, 1280, 720}
end tell
```

Resizes the frontmost Finder window to 1280x720 at origin (0,0).

### Move cursor (rare — prefer /macmini click)

```applescript
do shell script "/opt/homebrew/bin/cliclick m:640,400"
```

Moves the cursor to mini-physical pixel (640, 400) without clicking. Use
/macmini click for actual clicks; this is only for hover/tooltip purposes.
