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

### 0. Credential pre-scan — HARD GATE: refuse and surface the threat

Before doing anything else, scan `$ARGUMENTS` against the patterns below. If ANY match, **abort immediately** with this exact, loud error message — print it verbatim to the user's terminal, do NOT silently return docs, do NOT proceed to Step 1:

```
═══════════════════════════════════════════════════════════════════════
BLOCKED: payload contains an apparent credential (matched pattern #<N>: <pattern-name>).
═══════════════════════════════════════════════════════════════════════

Why this is blocked:
  GitHub runs secret-scanning on every gist (including unlisted/secret).
  Detected credentials are forwarded to issuer partners (OpenAI, Anthropic,
  OpenRouter, AWS, Google Cloud, Stripe, ~50 others) within minutes.
  Issuers AUTO-REVOKE the key — typically inside 5 minutes. Deleting the
  gist does NOT unwind the revocation.

What to do instead:
  • For credential injection — run:
      /macmini paste --secure <ENV_VAR_NAME>
    The agent will create a gist containing only a `read -s` prompt
    (no value), and you'll paste the secret directly into the mini
    Terminal. Zero gist/git exposure.

  • For 1Password references — use /load-creds on the mini side instead
    of pasting op:// strings.

  • For deploy scripts that need to USE a credential — have the deploy
    script reference the env var by name (e.g. `$OPENROUTER_API_KEY`)
    and inject the value separately with `--secure`.
═══════════════════════════════════════════════════════════════════════
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

### 0a. `--secure` mode — credential injection without putting the value in a gist

**Trigger:** the user's prompt contains `--secure` followed by an env-var name (e.g. `/macmini paste --secure OPENROUTER_API_KEY`), OR the user explicitly asks the agent to put a credential on the mini and Step 0's pre-scan blocked the obvious path.

**Mechanism:** the gist contains ONLY a prompt-and-write script — never the value. The user types the secret directly into the mini Terminal at the `read -s` prompt; the script writes it to `~/.config/claude/secrets/<ENV_VAR_NAME>` at mode 0600 owned by the user. The deploy script that needs the value loads it via `export <ENV_VAR_NAME>="$(cat ~/.config/claude/secrets/<ENV_VAR_NAME>)"` — never `source`, since the file contains a raw value (not a shell assignment).

```bash
# 1) Parse $ARGUMENTS for --secure <NAME>. Slash commands deliver the full
#    user prompt as the single $ARGUMENTS variable — $1 is empty here.
#    Use `set --` to position-split, then look for the --secure token.
set -- $ARGUMENTS
ENV_NAME=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--secure" ]; then ENV_NAME="${2:-}"; break; fi
  shift
done
case "$ENV_NAME" in
  ([A-Z_][A-Z0-9_]*) ;;
  *) echo "ERROR: --secure expects an UPPERCASE_SNAKE env var name; got '${ENV_NAME:-<empty>}'"; exit 4 ;;
esac

# 2) Build the prompt script. The script does NOT contain the value — only the prompt.
TMPDIR_LOCAL="$(mktemp -d -t macmini-secure.XXXXXX)"
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT INT TERM
RUN_FILE="$TMPDIR_LOCAL/secure.sh"

cat > "$RUN_FILE" <<'SECURE_BOOTSTRAP'
#!/bin/bash
set -euo pipefail
ENV_NAME_LOCAL="__ENV_NAME_PLACEHOLDER__"
SECRETS_DIR="$HOME/.config/claude/secrets"
mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
TARGET="$SECRETS_DIR/$ENV_NAME_LOCAL"
echo
echo "Mac mini will now read $ENV_NAME_LOCAL from your keyboard."
echo "The value will be written to $TARGET at mode 0600 and"
echo "exported into the current shell. It is NOT written to bash history,"
echo "NOT printed to stdout, and NOT placed in any gist."
echo
# read -s suppresses echo. -p prompts on stderr so it shows even if stdout is piped.
printf 'Paste %s now (cursor will appear blank), then press Enter: ' "$ENV_NAME_LOCAL" >&2
IFS= read -rs SECRET_VALUE
printf '\n' >&2
if [ -z "$SECRET_VALUE" ]; then
  echo "ERROR: empty value — aborting" >&2
  exit 5
fi
# Write atomically with mode 0600 from the start.
umask 077
printf '%s' "$SECRET_VALUE" > "$TARGET.tmp"
chmod 600 "$TARGET.tmp"
mv "$TARGET.tmp" "$TARGET"
unset SECRET_VALUE
echo "OK: wrote $TARGET (mode 0600). Source it with: export $ENV_NAME_LOCAL=\"\$(cat $TARGET)\""
SECURE_BOOTSTRAP

# 3) Substitute the env-var name (literal sed replacement; ENV_NAME was validated above
#    against [A-Z_][A-Z0-9_]* so it can't break the sed expression).
sed -i.bak "s/__ENV_NAME_PLACEHOLDER__/${ENV_NAME}/" "$RUN_FILE" && rm -f "$RUN_FILE.bak"

# 4) gist create + clone+run on mini, same as default mode but with secure.sh:
GIST_OUT=$(gh gist create "$RUN_FILE" 2>&1)
GIST_URL=$(printf '%s' "$GIST_OUT" | grep -oE 'https://gist\.github\.com/[^[:space:]]+' | head -n1)
GIST_ID=$(printf '%s' "$GIST_URL" | sed -E 's#.*/##' | sed 's/[?#].*//')
```

Then on the mini side, type the clone+execute command via `mcp.type_text` — interpolate the `$GIST_ID` from the dev-side bash, do not type the literal `<GIST_ID>` token:

```
mcp.type_text("rm -rf /tmp/macmini-secure; gh gist clone " + GIST_ID + " /tmp/macmini-secure; bash /tmp/macmini-secure/secure.sh", "Enter")
```

**Filename invariant.** The `gh gist create` call above uploaded `secure.sh` (the basename of `$RUN_FILE`); `gh gist clone <id>` lands files at `/tmp/macmini-secure/<filename>`. The hardcoded `bash /tmp/macmini-secure/secure.sh` only works if the gist filename is exactly `secure.sh`. Don't rename `$RUN_FILE` without updating the typed command.

**Validate the typed string is shift-safe** before sending it (Step 5's `LC_ALL=C` `case` glob applies — gist IDs are hex `[a-f0-9]{32}` so this is shift-safe by construction).

**Then surface the prompt to the user, verbatim:**

```
─── ACTION REQUIRED — PASTE SECRET ON MAC MINI ───
The mini Terminal is now showing:
  Paste <ENV_VAR_NAME> now (cursor will appear blank), then press Enter:
Paste your secret directly into that Terminal window.
The value will be saved to ~/.config/claude/secrets/<ENV_VAR_NAME>
at mode 0600 and will NEVER touch a gist or git history.
───────────────────────────────────────────────────
```

After the user pastes, verify with REAL checks (not theater):

- `mcp.take_screenshot()` — look for `OK: wrote /Users/<user>/.config/claude/secrets/<ENV_VAR_NAME>` in the Terminal output.
- File mode + non-empty: `mcp.type_text("stat -f %Lp ~/.config/claude/secrets/" + ENV_NAME + " && wc -c < ~/.config/claude/secrets/" + ENV_NAME, "Enter")`. Screenshot should show `600` on one line and a plausible byte count (≥20 for any real API key) on the next.

**Why no shell-history check?** `read -rs` doesn't echo or push the value into history; the secret was never typed at the prompt, so `history | grep $ENV_NAME` would find only the agent's own commands and confirm nothing about safety. It's theater. The mode-0600 + non-empty check above is the real verification.

**Multi-line secret caveat.** `IFS= read -rs SECRET_VALUE` reads ONE line. If the user pastes a multi-line PEM/private-key, only the first line lands in the file. For multi-line secrets, instruct the user instead: bring mini Terminal forward, run `cat > ~/.config/claude/secrets/<NAME> && chmod 600 ~/.config/claude/secrets/<NAME>` (single quotes around the heredoc terminator if pasting from clipboard with `Ctrl+D` to end), paste the multi-line content, then `Ctrl+D`. `--secure` mode is single-line-only by design.

**Rotation.** Re-running `/macmini paste --secure OPENROUTER_API_KEY` for the same env var name overwrites the file atomically (the bootstrap writes `$TARGET.tmp` then `mv`s into place). Old value is replaced on success; if the user aborts at the prompt, the old value is retained.

Then go to Step 7 (gist cleanup) — skip Steps 1-6. The whole point of `--secure` is that the gist never carried the secret, so there's no clipboard delivery to consume; the value is already in the right place on the mini.

**Why this is safe even though gh gist is involved:** the gist file is the bootstrap script (a `read -s` prompt). GitHub secret-scanning has nothing to match against because the script literally contains no secret bytes. The user's typed secret never leaves the mini's local filesystem.

### 0b. `--repaste` mode — re-fire the existing clipboard into a different focused app

**Trigger:** the user's prompt contains `--repaste`, OR the user says "paste it again" / "do it once more in <other app>" right after a successful `/macmini paste` in the same session.

**Mechanism:** no gist activity. The Mac mini's pasteboard still holds the bytes from the prior `/macmini paste` (provided no reboot, no other `Cmd+C` over it, no sleep-cycle clipboard wipe). Bring the new target app to focus, fire the same `Meta+v` + `Enter` sequence as Step 6.

```
1. mcp.list_pages() + mcp.select_page({pageId: <crd_uid>, bringToFront: true})
2. mcp.take_screenshot() — confirm the intended target app is foreground on the canvas. If not, instruct user to bring it forward (or use Spotlight: mcp.press_key("Meta+space"); mcp.type_text("<app>", "Enter")).
3. mcp.press_key("Meta+v")
4. (default) mcp.press_key("Enter")
5. mcp.take_screenshot() — confirm submission landed.
```

Skip step 4 (`Enter`) if the user used a clipboard-only trigger phrase from Step 6's list (`"don't submit"`, `"let me review"`, etc.). Default is auto-paste + Enter.

**Verify the clipboard hasn't been clobbered.** Before firing, optionally run `mcp.type_text("pbpaste | head -c 80", "Enter")` (in a non-destructive context like an extra Terminal tab) and screenshot — if the output isn't the expected payload prefix, the clipboard was overwritten and `--repaste` will deliver the wrong bytes. In that case fall back to a fresh `/macmini paste` (or `/macmini paste --secure` for secrets).

Then skip Steps 0-7 — `--repaste` is the entire flow.

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
