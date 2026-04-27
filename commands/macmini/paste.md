---
description: Send arbitrary text (capitals, symbols, unicode, multi-line) to the Mac mini's clipboard via gh gist transport — the only channel that survives CRD's Shift-stripping keyboard pipeline.
argument-hint: "<text — multi-line OK, full Unicode, any printable characters>"
---

# /macmini paste

Sends ARBITRARY text to the Mac mini's clipboard via `gh gist`. CRD strips Shift on outbound keystrokes (`HELLO_WORLD` → `hello-world`, `$@!#%^&*()` get remapped to wrong chars), and CRD's clipboard sync needs real user gestures (CDP-injected events are synthetic). gist transport bypasses both: byte-perfect text is uploaded to a SECRET gist, then the Mac mini clones it locally with a clone command consisting only of unshifted chars.

## Pre-requisites

- `gh` CLI authenticated on BOTH dev and Mac mini sides to the same GitHub account. (See `/macmini setup` Step 2.)
- chrome-devtools MCP attached to running Chrome; CRD canvas live on a tab whose URL starts with `https://remotedesktop.google.com/access/session/`.
- **Mac mini Terminal must be the focused window inside the CRD canvas** before invoking paste, otherwise the typed clone command lands in the wrong app.

## Sequence (single flow — no alternatives, no branching)

### 1. Pre-flight

`mcp.list_pages()`. Find the CRD page. If none, abort: `not connected — run /macmini connect first`. `mcp.select_page({pageId, bringToFront: true})`.

`mcp.take_screenshot()` and visually confirm the Mac mini Terminal window is the foreground app on the canvas, with a shell prompt visible. If not, abort with: `Mac mini Terminal not focused — bring it forward before /macmini paste`. The agent must NOT proceed if the screenshot doesn't show a prompt — typing the clone command into the wrong app is silent and destructive.

### 2. Reject NUL bytes and oversized payloads

`$ARGUMENTS` cannot contain NUL bytes (shell can't carry them) — but the agent should also reject any payload >900 KB upfront. GitHub gist files have a hard limit around 1 MB, and headroom matters. If the payload size exceeds, abort: `payload too large for single gist (limit ~900KB) — split into multiple pastes`.

### 3. Build a self-extracting shell script with a randomized heredoc terminator

The classic heredoc collision (`PAYLOAD` or `EOF` appearing in the payload) MUST be prevented. Generate a random terminator per invocation, validate it's not in the payload, and **always quote the heredoc terminator** so $-expansion doesn't fire on dev side.

**The gist filename matters.** The Mac mini's `gh gist clone <id> /tmp/macmini-paste` produces `/tmp/macmini-paste/<filename>`, and step 5 hard-codes `bash /tmp/macmini-paste/run.sh`. So the file uploaded to the gist MUST be named exactly `run.sh`. `gh gist create` derives the gist filename from the basename of the local file path — there's no `--filename` flag for `gist create`. Build the script in a fresh tempdir with a known basename:

```bash
TMPDIR_LOCAL="$(mktemp -d -t macmini-paste.XXXXXX)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT INT TERM
RUN_FILE="$TMPDIR_LOCAL/run.sh"

# Random heredoc terminator — must NOT appear in $ARGUMENTS.
TERMINATOR="MACMINI_$(openssl rand -hex 8)_END"
case "$ARGUMENTS" in
  *"$TERMINATOR"*)
    echo "ERROR: payload collision with random terminator (1-in-2^64) — retry"
    exit 1
    ;;
esac

# Build run.sh by writing the literal payload through pbcopy. Dev shell
# expands NOTHING because we use a heredoc with a QUOTED terminator. The
# pipe-into-pbcopy at run-time on the mini is the only thing that reads
# the bytes; the heredoc terminator is unique.
{
  printf '%s\n' '#!/bin/bash'
  printf '%s%s%s\n' "cat <<'" "$TERMINATOR" "' | pbcopy"
  printf '%s' "$ARGUMENTS"
  # Trailing newline only if payload doesn't end with one (preserve byte count).
  case "$ARGUMENTS" in
    *$'\n') : ;;
    *) printf '\n' ;;
  esac
  printf '%s\n' "$TERMINATOR"
} > "$RUN_FILE"
```

This guarantees: (a) no dev-side shell expansion of payload, (b) heredoc terminator collision impossible (256-bit entropy in name), (c) NUL-byte safety enforced upstream by Step 2, (d) no extra trailing newline appended if payload already ends with one, (e) gist filename will be `run.sh` because `gh gist create` uses the basename.

### 4. Upload as a SECRET gist

```bash
GIST_URL=$(gh gist create "$RUN_FILE" 2>/dev/null | tail -n1)
GIST_ID=$(printf '%s' "$GIST_URL" | sed -E 's#.*/##' | sed 's/[?#].*//')
case "$GIST_ID" in
  [a-f0-9]*) ;;
  *) echo "ERROR: unexpected gist URL: $GIST_URL"; exit 2 ;;
esac
```

Default is SECRET (no `-p`). Per the SECURITY rules below, NEVER paste tokens, `op://`-resolved values, env-var dumps, or `Authorization:` headers — secret gists are unlisted but **not** encrypted, are readable by GitHub staff, persist forever, and grant access to anyone who obtains the URL.

### 5. Type the clone+execute command on Mac mini

The command uses ONLY lowercase letters, digits, dashes, slashes, and a semicolon — all unshifted on US keyboard, so CRD forwards them intact. The trailing `bash /tmp/macmini-paste/run.sh` runs the self-extracting script, which writes the payload to Mac mini's pasteboard via `pbcopy`.

```
mcp.type_text("rm -rf /tmp/macmini-paste; gh gist clone " + GIST_ID + " /tmp/macmini-paste; bash /tmp/macmini-paste/run.sh", "Enter")
```

Path `/tmp/macmini-paste` is namespaced (less collision-prone than `/tmp/p`). Note: this is still a TOCTOU pattern; on a single-user dev mini it's effectively safe.

### 6. Verify clone + execute landed cleanly

```
mcp.take_screenshot()
```

Visually confirm the Terminal output shows BOTH:
- `Cloning into '/tmp/macmini-paste/'` (or `Receiving objects: 100%`) — clone succeeded
- A fresh shell prompt at the bottom — `bash run.sh` exited cleanly (non-zero exit prints to stderr; if the prompt isn't returned, something is still running)

If the screenshot shows `gh: command not found`, abort with: `Mac mini missing gh — install via 'brew install gh && gh auth login' on the mini once`. If 404 from clone, abort with: `gist clone 404 — mini's gh authenticated to a different account?`. If the prompt hasn't returned within 5 seconds, screenshot again — slow network can take 5-15s.

Only AFTER the prompt returns and clone+bash both look clean: the Mac mini's pasteboard now holds the original text. The agent (or a downstream Cmd+V on a focused mini-side app) can use it.

### 7. Cleanup the gist

By default, delete the gist after successful clone+execute:

```bash
gh gist delete "$GIST_ID" 2>/dev/null
```

This prevents secret-gist accumulation on the user's GitHub account. Only skip deletion if the user passed `--keep-gist` (currently not parsed — feature TBD, behavior is always-delete).

### 8. Final report

Print: `pasted <char_len> chars via gist <id> (deleted)`. Never log the payload itself — only its char length.

## Why this works (verified 2026-04-27 — channel only, not full pipeline)

The gist round-trip itself was verified end-to-end on a live CRD session 2026-04-27: `gh gist create` on dev, `mcp.type_text("gh gist clone <id> /tmp/p", "Enter")` on mini, `cat /tmp/p/...` showed full-fidelity content (capitals, `$@!#%^&*()`, unicode `日本語 émoji ñ ü ß`, multi-line, math). What was NOT live-tested in Phase E: the heredoc-extracted `bash run.sh` → `pbcopy` step, and final `Cmd+V` into a target app. Those are mechanically sound but uncertified hardware. Smoke Test 12 in `docs/TESTING.md` is the regression check — run it after any /macmini paste change.

## Errors

- **No CRD tab** — run `/macmini connect` first.
- **Mac mini Terminal not focused** — bring Terminal forward in the CRD canvas (Spotlight: `mcp.press_key("Meta+space")`, type `terminal`, Enter).
- **`gh: command not found` (mini)** — one-time: have user run `brew install gh && gh auth login` on the mini.
- **`gh: not authenticated`** — same one-time fix.
- **clone hangs** — Mac mini network down. Screenshot, ask user to reconnect Wi-Fi.
- **clone returns 404** — mini's gh authenticated to a different account. Run `gh api user --jq .login` on both sides to compare.
- **Payload size exceeds limit** — split into chunks; each call is independent; recipient must concatenate manually.

## What NOT to do (security guardrails)

The agent MUST NOT pass any of the following as payload to `/macmini paste`:

- API tokens, passwords, `op://` references after they've been resolved to plaintext.
- `Authorization:` headers, bearer tokens, OAuth refresh tokens.
- Any output of `env`, `printenv`, `gh auth status`, `op item get`, or any command that prints env vars or credentials.
- The contents of `~/.config/`, `~/.aws/credentials`, `~/.ssh/`, `.env*` files.

Secret gists are unlisted but **NOT encrypted**. GitHub staff can read them, the URL grants access to anyone who has it, and they persist until explicitly deleted. The auto-delete in Step 7 reduces but does not eliminate exposure.
