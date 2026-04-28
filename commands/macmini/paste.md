---
description: Send arbitrary text (capitals, symbols, unicode, multi-line) to the Mac mini's clipboard via gh gist transport — the only channel that survives CRD's Shift-stripping keyboard pipeline. CREDENTIALS ARE BLOCKED — gist transport leaks them to GitHub secret-scanning partners; use --secure for credential injection.
argument-hint: "<text — multi-line OK, full Unicode, any printable characters>     [--secure | --repaste]"
---

# /macmini paste

Sends ARBITRARY text to the Mac mini's clipboard via `gh gist`. CRD strips Shift on outbound keystrokes (`HELLO_WORLD` → `hello-world`, `$@!#%^&*()` get remapped to wrong chars), and CRD's clipboard sync needs real user gestures (CDP-injected events are synthetic). gist transport bypasses both: byte-perfect text is uploaded to a SECRET gist, then the Mac mini clones it locally with a clone command consisting only of unshifted chars.

## ⚠ THREAT MODEL — secrets cannot ride this transport

**GitHub runs secret-scanning on every gist, including unlisted/secret gists.** Detected credentials are forwarded to issuer partners (OpenAI, Anthropic, OpenRouter, AWS, Google Cloud, Stripe, Twilio, Slack, ~50 others — see [GitHub secret-scanning partner program](https://docs.github.com/en/code-security/secret-scanning/secret-scanning-partner-program)) within minutes. Issuers then **automatically revoke the key** — typically inside 5 minutes. **Deleting the gist after use does NOT unwind the revocation.**

Real incident (logged in this skill's history): two OpenRouter keys were burned in <10 minutes each by routing them through a `/macmini paste` deploy script. The keys died before the deploy's smoke tests finished.

**This is why Step 0 below is a HARD GATE, not a soft check.** The agent MUST refuse credential-shaped payloads with a loud, specific error message, NOT silently fall back to documentation. If the user pushes back, do not work around it — point them at `--secure` mode.

For credential injection, use **`/macmini paste --secure <ENV_VAR_NAME>`** (Step 0a below). That mode never puts the value in a gist — it has the user paste the value directly into the mini Terminal via `read -s`, into a 0600-mode `.env` file. Zero git/gist exposure.

## Modes

| Mode | When to use | Mechanism |
|---|---|---|
| Default (auto-paste) | Non-secret text, scripts, code patches, multi-line bash | gist contains the payload, mini clones, bash runs, `pbcopy` puts it on the clipboard, agent fires `Meta+v` + `Enter`. |
| `--secure <ENV_VAR_NAME>` | ANY credential value (API keys, tokens, passwords, op://-resolved secrets, .env contents) | gist contains a `read -s` prompt only — the value never touches GitHub. User pastes the secret into the mini Terminal directly. |
| `--repaste` | Same payload needs to land in a different focused app, mid-session | Re-fires `Meta+v` against the focused app. Clipboard must still be valid (no reboot, no other `Cmd+C` over it). No new gist built. |

## Pre-requisites

- `gh` CLI authenticated on BOTH dev and Mac mini sides to the same GitHub account. (See `/macmini setup` Step 2.)
- chrome-devtools MCP attached to running Chrome; CRD canvas live on a tab whose URL starts with `https://remotedesktop.google.com/access/session/`.
- **Mac mini Terminal must be the focused window inside the CRD canvas** before invoking paste, otherwise the typed clone command lands in the wrong app.

## Sequence (single flow — no alternatives, no branching)

### 0. Credential pre-scan — REFUSE if payload looks like a secret

Before doing anything else, scan `$ARGUMENTS` against the patterns below. If ANY match, abort with the exact message:

```
BLOCKED: payload contains an apparent credential (matched: <pattern-name>).
Re-run without the secret. Options:
  (a) Reference the secret by env var name only — let the mini resolve it from its own keychain.
  (b) For one-off injection: `op read 'op://<vault>/<item>/<field>' | gh gist create -f run.sh -` and have the mini clone it directly without /macmini paste.
  (c) If you really need to paste a credential to the mini, paste a script that fetches it from 1Password / Keychain on the mini side, NOT the credential value itself.
```

Patterns to refuse — **check in this order** (first match wins, so the more specific patterns must come before more general ones):

| # | Pattern name | Regex | Examples |
|---|---|---|---|
| 1 | `anthropic-key` | `\bsk-ant-[A-Za-z0-9_-]{16,}\b` | `sk-ant-api03-...` |
| 2 | `openai-key` | `\bsk-(?!ant-)[A-Za-z0-9_-]{16,}\b` | `sk-...`, `sk-proj-...`, `sk-or-v1-...` |
| 3 | `github-token` | `\bgh[pousr]_[A-Za-z0-9_]{20,}\b` | `ghp_...`, `gho_...`, `ghs_...` |
| 4 | `aws-access-key` | `\b(AKIA\|ASIA)[0-9A-Z]{16}\b` | `AKIA...` (permanent), `ASIA...` (STS temp) |
| 5 | `aws-secret-key-named` | `(?i)aws[_-]?secret[_-]?access[_-]?key\s*[:=]\s*["']?[A-Za-z0-9/+=]{40}` | `aws_secret_access_key=...`. Bare 40-char base64 secrets without the env var name are NOT detected — too generic to scan blindly. |
| 6 | `slack-token` | `\bxox[baprs]-[A-Za-z0-9-]{10,}\b` | `xoxb-...` |
| 7 | `google-api-key` | `\bAIza[0-9A-Za-z_-]{35}\b` | `AIza...` |
| 8 | `private-key-block` | `-----BEGIN ((RSA\|EC\|OPENSSH\|DSA\|PGP\|ENCRYPTED) )?PRIVATE KEY-----` | PEM/SSH/PKCS8 private keys, encrypted or unencrypted |
| 9 | `auth-header` | `(?i)\b(Authorization\|Proxy-Authorization)\s*[:=]\s*(Bearer\|Token)\s+\S{12,}` or `(?i)\bX-(API\|Auth)-Key\s*[:=]\s*\S{12,}` | `Authorization: Bearer ey...`, `X-API-Key: abc...` |
| 10 | `1password-resolved` | `\bop://\S+\s+[A-Za-z0-9_/+=-]{20,}\b` or reverse — an `op://` ref appearing in the same payload as a long alphanumeric run is a strong "resolved-and-pasted" signal | resolved op refs leaked alongside the value |
| 11 | `high-entropy-env-credential` | `(?i)\b(API_KEY\|PASSWORD\|PASSPHRASE\|PRIVATE_KEY\|SECRET_KEY\|ACCESS_KEY)\s*=\s*["']?(?!YOUR_\|EXAMPLE\|PLACEHOLDER\|REPLACE_ME\|CHANGEME\|xxx\|\*\*\*\|<)[A-Za-z0-9_/+=.-]{20,}["']?` | `API_KEY=abc123...`. Excludes obvious placeholders. `SECRET` and `TOKEN` alone are NOT in the alternation — too generic, false-positive prone (would refuse paste of plain prose like "the SECRET = see vault entry"). |

The refusal must print the matched pattern name AND its number. Do NOT echo the matched bytes back — the redaction is part of the safety guarantee.

**Bypass limits — known weaknesses the agent should call out to the user.** This pre-scan catches casual leaks (raw paste of an env var or a curl command). It does NOT defeat:

- Multi-line splits (`sk-` on one line, hex on the next)
- Base64-wrapped secrets (`echo c2stcHJvai0...| base64 -d`)
- Unicode confusables / zero-width spaces (`ѕk-...` Cyrillic `s`, `sk​-proj-...`)
- Adversarial encodings (rot13, URL-encoding, etc.)

The pre-scan is a guardrail against accidental paste, not adversarial intent. If the user pushes back on a refusal, do not work around it — explain the side-channel options instead.

This check is mandatory and **non-overridable in code**. Even if the user explicitly asks "paste this anyway," refuse and offer the side-channel options below. Secret gists are unlisted but **not encrypted** — pasting credentials to a gist puts them in GitHub's storage permanently (delete-after-use only mitigates URL-leak risk, not GitHub-staff or breach risk).

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
# Extract URL via grep — gh may print login nags or warnings to stdout in some
# configs, so `tail -n1` would catch the wrong line. Pin to the gist URL shape.
GIST_OUT=$(gh gist create "$RUN_FILE" 2>&1)
GIST_URL=$(printf '%s' "$GIST_OUT" | grep -oE 'https://gist\.github\.com/[^[:space:]]+' | head -n1)
GIST_ID=$(printf '%s' "$GIST_URL" | sed -E 's#.*/##' | sed 's/[?#].*//')
case "$GIST_ID" in
  ([a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]*) ;;
  *) echo "ERROR: gh did not produce a recognizable gist URL. Output: $GIST_OUT"; exit 2 ;;
esac
```

Default is SECRET (no `-p`). Per the SECURITY rules below, NEVER paste tokens, `op://`-resolved values, env-var dumps, or `Authorization:` headers — secret gists are unlisted but **not** encrypted, are readable by GitHub staff, persist forever, and grant access to anyone who obtains the URL.

### 5. Validate the clone command is unshifted-safe, then type it

The clone+execute command MUST consist of ONLY characters in the unshifted-safe set: `[a-z0-9 /.;:_-]`. Anything else (`>`, `&`, `|`, `~`, `$`, capitals A-Z, `*`, `?`, `(`, `)`, `{`, `}`, `[`, `]`, `\`, `'`, `"`, `<`, `=`, `+`, `^`, `%`, `#`, `@`, `!`, `&&`, `||`) will be Shift-stripped or remapped by CRD, silently mangling the command. The agent MUST validate before typing:

```bash
CLONE_CMD="rm -rf /tmp/macmini-paste; gh gist clone $GIST_ID /tmp/macmini-paste; bash /tmp/macmini-paste/run.sh"

# CRITICAL: force C locale, otherwise [a-z] under en_US.UTF-8 matches A-Z too,
# silently letting capitals through. Use ^ (POSIX) for negation, not ! (bash-only).
# Inside [ ], dot/semicolon/colon/underscore are literal — no backslash escapes needed.
# Put `-` last so it's literal, not a range delimiter.
if LC_ALL=C bash -c '
  case "$1" in
    (*[^a-z0-9\ /.\;:_-]*) exit 3 ;;
  esac
' _ "$CLONE_CMD"; then
  : # safe
else
  echo "ERROR: clone command contains shifted/unsafe chars — refusing to type"
  exit 3
fi
```

The hardcoded clone command above is shift-safe by construction (gist IDs are hex `[a-f0-9]{32}`). The validation step is a load-bearing guard against future edits that parameterize the command and accidentally introduce unsafe characters. **Do not delete this check** — it costs nothing and prevents silent canvas-mangling regressions.

Then type it:

```
mcp.type_text("rm -rf /tmp/macmini-paste; gh gist clone " + GIST_ID + " /tmp/macmini-paste; bash /tmp/macmini-paste/run.sh", "Enter")
```

Path `/tmp/macmini-paste` is namespaced (less collision-prone than `/tmp/p`).

### 6. Verify clone + execute landed cleanly, THEN consume the clipboard with Cmd+V + Enter

```
mcp.take_screenshot()
```

Visually confirm the Terminal output shows BOTH:
- `Cloning into '/tmp/macmini-paste/'` (or `Receiving objects: 100%`) — clone succeeded
- A fresh shell prompt at the bottom — `bash run.sh` exited cleanly

**Detect Shift-strip mangling FIRST.** The universal signal across shells is **a fresh line ending in `> ` (or some other prompt-2 / continuation prompt) instead of the user's normal prompt returning**. The shell-specific keyword variants below help identify the cause, but the universal heuristic is "the prompt didn't come back; instead a `>`-style continuation marker is on the last line."

Universal signal:
- Last line of the screenshot is a continuation prompt (`> `, `>>`, `… `, or any line with no normal `% `/`$ `/`# ` PS1 marker after the typed command). The user's PS2 is whatever they configured; under default zsh it's `%_> ` and expands to keyword names below.

Default-zsh keyword continuation prompts (your `PS2='%_> '` produces these):
- `bquote>` (waiting for matching backtick)
- `quote>` / `dquote>` (waiting for matching single / double quote)
- `cmdand>` / `cmdor>` (waiting after `&&` / `||`)
- `cmdsubst>` (waiting for matching `$(...)`)
- `heredoc>` (inside an unterminated heredoc body)
- `for>` / `while>` / `if>` / `then>` / `else>` / `select>` (compound-command continuation)

Bash, fish, and customized PS2 simply show `> ` or whatever the user set — same diagnosis: shell expected more input.

Other mangling signs:
- `gh: command not found` after a clone command (means `gh` got remapped by Shift-stripping into something else)
- The clone command itself appears in the screenshot with visibly wrong characters (e.g., `>` instead of `;`, missing dashes)

If ANY of those are visible, abort with: `CRD shift-strip detected — typed command was mangled (continuation prompt visible). Press Control+c then Control+c to recover the prompt, then retry. If retry also mangles, the canvas keystroke pipeline is degraded — disconnect and reconnect.` Press `Control+c` twice yourself to clear the line, then return.

If the screenshot shows `gh: command not found` cleanly (no continuation prompt, just the error), abort with: `Mac mini missing gh — install via 'brew install gh && gh auth login' on the mini once`. If 404 from clone, abort with: `gist clone 404 — mini's gh authenticated to a different account?`. If the prompt hasn't returned within 5 seconds, screenshot again — slow network can take 5-15s.

**Only AFTER the prompt returns cleanly:** the Mac mini's pasteboard now holds the original text. To **consume** it (paste into the focused app — Terminal, editor, Claude Code TUI, whatever was foreground BEFORE you ran /macmini paste), fire the keys:

```
mcp.press_key("Meta+v")    # paste clipboard into focused field
mcp.press_key("Enter")     # submit
mcp.take_screenshot()      # confirm submission landed
```

This is the **default behavior** — the agent must do all three. The wrapper script's job is to put the bytes on the clipboard; the `Meta+v` delivers them into the app the user actually wanted them in; the `Enter` submits; the screenshot is the receipt that the submission was accepted (e.g., agent prompt-line cleared, target app shows the new content).

**Skip the `Enter` ONLY if the user explicitly used one of these clipboard-only trigger phrases:**

- "just to clipboard" / "just put it on the clipboard"
- "don't submit" / "don't send" / "don't run it"
- "let me review" / "let me check first" / "stage it" / "queue it up"
- "no enter" / "hold off"

If the user's request is ambiguous (e.g., "send this to the mini" without "submit" or "review"), default to auto-paste + Enter. If unclear AND the destination is destructive (running shell commands, sending messages, submitting forms), ask the user one short question rather than guessing.

When skipping `Enter`: still fire `Meta+v` so the clipboard contents land in the focused editor / input field; the user submits manually.

**Idempotent re-paste — Cmd+V replay only.** The Mac mini's system pasteboard retains the bytes after Step 6, so to land the SAME payload in a different focused app, just bring it forward and re-fire `mcp.press_key("Meta+v")`. No new gist needed.

**This is replay-only. The gist itself is deleted in Step 7**, so re-cloning it on the mini side (e.g., for mini Claude in another terminal to fetch the script independently) is not possible from a default-mode paste. If you anticipate that case (rare), build a new gist with a fresh `/macmini paste` invocation. Clipboard-replay also breaks if the mini reboots or if any other app does its own `Cmd+C` and overwrites the pasteboard — in that case, also re-paste fresh.

### 7. Cleanup the gist

By default, delete the gist after successful clone+execute:

```bash
gh gist delete "$GIST_ID" --yes 2>/dev/null
```

The `--yes` flag is required — `gh gist delete` exits non-zero in non-interactive shells without it.

**Ordering note:** Step 7 runs on the dev side and is decoupled from any mini-side command that the user's `Enter` in Step 6 may have just kicked off. The dev-side `gh gist delete` and the mini-side execution proceed in parallel. The mini cloned `run.sh` to `/tmp/macmini-paste/run.sh` already, so deleting the gist now does NOT break the running script — the local clone is independent of the upstream gist.

This prevents secret-gist accumulation on the user's GitHub account. Behavior is always-delete; there is no `--keep-gist` mode. If you need a gist that persists for re-cloning by another mini-side process, build it directly via `gh gist create` outside the `/macmini paste` flow rather than trying to bypass Step 7.

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
