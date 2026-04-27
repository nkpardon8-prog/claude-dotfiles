---
description: Send arbitrary text (capitals, symbols, unicode, multi-line) to the Mac mini via gh gist transport — the only channel that survives CRD's Shift-stripping keyboard pipeline.
argument-hint: "<text — multi-line OK, full Unicode, any characters>"
---

# /macmini paste

Sends ARBITRARY text to the Mac mini's clipboard via `gh gist`. CRD's keystroke forwarding strips the Shift modifier (capitals → lowercase, `$@!#%` → digits, `(` → `;`), so direct typing only handles unshifted ASCII. Programmatic clipboard sync via DevTools doesn't work either — CRD's onPaste handler requires a real user gesture, and CDP-injected events are synthetic. Gist transport bypasses both: text is uploaded to a private GitHub gist, then the Mac mini clones it locally with a lowercase-only command (`gh gist clone <id> /tmp/p`).

## Pre-requisites (one-time)

- `gh` CLI authenticated on BOTH dev and Mac mini sides to the same GitHub account.
- chrome-devtools MCP attached to the running Chrome with a live CRD canvas (page URL starts with `https://remotedesktop.google.com/access/session/`).
- Mac mini Terminal is the focused window inside the CRD canvas (otherwise the typed command lands in the wrong app).

## Sequence

### 1. Pre-flight

`mcp.list_pages()`. Find the CRD page (URL starts with `https://remotedesktop.google.com/access/session/`). If none, abort: `not connected — run /macmini connect first`. `mcp.select_page({pageId, bringToFront: true})`.

### 2. Write payload to a local file

```bash
TMPFILE="/tmp/macmini-paste.$$"
trap 'rm -f "$TMPFILE"' EXIT INT TERM
printf '%s' "$ARGUMENTS" > "$TMPFILE"
```

Tempfile (NOT shell-substitution) — preserves arbitrary bytes including embedded quotes, dollar signs, backslashes.

### 3. Upload as a SECRET gist

```bash
GIST_URL=$(gh gist create -f payload.txt "$TMPFILE")
GIST_ID=$(basename "$GIST_URL")
echo "gist id: $GIST_ID"
```

`-f payload.txt` controls the gist filename. Default is SECRET (no `-p`); only the gh-authenticated user can access. Per SKILL.md SECURITY rules: NEVER paste tokens, `op://`-resolved values, env-var dumps, or auth headers — gists are unlisted but not encrypted.

### 4. Type the clone command on Mac mini side

The Mac mini Terminal must be focused. The clone command uses ONLY lowercase letters, digits, dashes, slashes, and a semicolon — all unshifted on US keyboard, so CRD forwards them intact.

```
mcp.type_text("rm -rf /tmp/p; gh gist clone " + GIST_ID + " /tmp/p", "Enter")
```

`gist clone` produces a directory `/tmp/p/` containing `payload.txt` (or whatever filename the gist had).

### 5. Verify clone

`mcp.take_screenshot()`. The Terminal output should show "Cloning into /tmp/p/" + a "Receiving objects: 100%" line. If the screenshot shows an error (e.g., "could not resolve host"), abort.

### 6. Apply the payload — pick one

Common destinations:

- **To clipboard for paste-into-app**: gist filename must be a `.sh` that does `cat <<'EOF' | pbcopy ... EOF`. Type `bash /tmp/p/payload.sh` (lowercase only).
- **As a script to execute**: type `bash /tmp/p/payload.sh`.
- **As text content for an editor**: type `open -a textedit /tmp/p/payload.txt` to open in TextEdit, or just `cat /tmp/p/payload.txt` to display.

For the most common case (push text to mini clipboard so user can Cmd+V it anywhere), use this gist template instead:

```bash
# Write a self-pasting script, not a raw text file
cat > "$TMPFILE" <<EOF
#!/bin/bash
cat <<'PAYLOAD' | pbcopy
$ARGUMENTS
PAYLOAD
EOF
GIST_URL=$(gh gist create -f run.sh "$TMPFILE")
GIST_ID=$(basename "$GIST_URL")
```

Then on mini: `rm -rf /tmp/p; gh gist clone <ID> /tmp/p; bash /tmp/p/run.sh`.

After this, Mac mini's pasteboard has the original text. Cmd+V into any app on mini works.

### 7. Cleanup

`rm -f "$TMPFILE"` is handled by the trap. The gist persists on GitHub by default — to delete after use:

```bash
gh gist delete "$GIST_ID"
```

Optional. Secret gists are user-only, so leaving them is low-risk.

### 8. Final report

Print: `pasted <char_len> chars via gist <id>`. If `--keep-gist` was passed, omit the delete step. Never log the payload itself — only its char length.

## Why this works

1. The dev → mini channel is **lowercase-only typing** (`type_text` of `gh gist clone <id> /tmp/p`), which CRD forwards intact.
2. The arbitrary-text payload is delivered via **GitHub's HTTPS** between dev and mini — no keyboard layer involved.
3. The Mac mini's `gh` is authenticated (same account as dev), so private gists work without re-auth.
4. End-to-end fidelity: full Unicode, all ASCII symbols, capitals, multi-line, executable scripts. Verified 2026-04-27.

## Errors

- **No CRD tab** — run `/macmini connect` first.
- **`gh: command not found` (mini side)** — install gh on the Mac mini once: have the user open Terminal and run `brew install gh && gh auth login`. After that this skill works forever.
- **`gh: not authenticated`** — same fix.
- **clone hangs** — Mac mini's network may be down. Screenshot to verify, then ask user to reconnect Wi-Fi.
- **Cmd+V on Mac mini side pastes the wrong thing** — script wasn't run yet, or focus drifted to a different app between bash and Cmd+V. Re-run `bash /tmp/p/run.sh` and screenshot to verify.

## What NOT to do

- Do NOT use `dev pbcopy → CRD sync → mini pasteboard`. CRD's clipboard sync requires real user gestures; CDP-injected events don't trigger it. (Verified broken 2026-04-27.)
- Do NOT use `navigator.clipboard.writeText()` then Cmd+V on the canvas. Same reason.
- Do NOT type text containing capitals, `$`, `!`, `@`, `#`, `%`, `^`, `&`, `*`, `(`, `)`, `_`, `+`, `{`, `}`, `[`, `]`, `|`, `\`, `:`, `"`, `<`, `>`, `?`, `~` directly via `type_text` or `press_key`. CRD strips/remaps these.
