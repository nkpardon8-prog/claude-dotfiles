---
description: One-time setup for the Mac mini remote skill — chrome-devtools MCP, credentials, first connect.
argument-hint: ""
---

# /macmini setup

Three steps from zero to a working `/macmini connect`. The skill drives the Mac mini through the chrome-devtools MCP attached to your existing Chrome — no daemons, no binaries, no servers. Data flows in/out via CRD's built-in clipboard sync.

CRITICAL warning: **CRD's keystroke forwarding is broken for Shift-modified characters.** The Shift modifier gets dropped in transit, so capital letters, underscores, `$`, `|`, `&`, `~`, `:` and other shifted glyphs come through corrupted (`HELLO_WORLD` arrives as `hello-world`). The `/macmini paste` command exists specifically to bypass this. Use it for any payload with mixed case, special characters, or anything programmatic.

For the full capability map, read `~/.claude-dotfiles/skills/macmini/SKILL.md`. For agent operational notes, read `~/.claude-dotfiles/skills/macmini/docs/AGENT-GUIDE.md`.

---

## Step 1 — chrome-devtools MCP installed and configured

The skill is a thin wrapper around the chrome-devtools MCP. Confirm it's loaded in your Claude Code MCP configuration. If you don't have it yet, install per its docs (typically a Node-based MCP server entry).

**Recommended**: start it with the `--experimental-vision` flag — that exposes `click_at(x, y)` for pixel-precise clicks on the CRD canvas. Without it, you can only click the canvas centerpoint, which limits where you can interact on the Mac mini's screen.

Example MCP config snippet:

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["chrome-devtools-mcp", "--experimental-vision"]
    }
  }
}
```

After editing the MCP config, **restart Claude Code (or your MCP host)** so the new flag takes effect. Verify by listing available chrome-devtools MCP tools — `click_at` should be present.

---

## Step 2 — Credentials

The skill needs two values:

- `CRD_PIN` — the 6-digit PIN you set when you registered the Mac mini as a CRD host.
- `CRD_DEVICE_NAME` — the EXACT aria-label shown on the Mac mini's tile at <https://remotedesktop.google.com/access>. This is whatever you typed during CRD host setup (often the macOS hostname). Open the device list page in your daily Chrome and copy the name verbatim.

Add these to `~/.config/claude/credentials.md` as `op://` references (template lives in `~/.claude-dotfiles/credentials.template.md`):

```markdown
## Mac mini remote (CRD skill)

| Env var          | 1Password ref                                |
|------------------|----------------------------------------------|
| CRD_PIN          | op://<VAULT>/Mac mini CRD/PIN                |
| CRD_DEVICE_NAME  | op://<VAULT>/Mac mini CRD/Device Name        |
```

Store the actual values in 1Password under those refs, then load them into the current session:

```
/load-creds CRD_PIN,CRD_DEVICE_NAME
```

---

## Step 3 — First `/macmini connect`

```
/macmini connect
```

The first run lands you in the CRD canvas after PIN entry. Step 4 below pre-grants the Chrome permissions needed for paste/grab to work without per-session prompts.

---

## Step 4 — Pre-grant Chrome permissions (one-time)

This step writes a Chrome user-policy entry pre-granting clipboard read/write to `https://remotedesktop.google.com` and verifies Chrome is reachable on the remote-debugging port that the chrome-devtools MCP uses.

### 4a. Install the policy

```
/macmini auto-grant install
```

This writes a Chrome user-policy entry pre-granting clipboard read/write to `https://remotedesktop.google.com`.

### 4b. RESTART CHROME for the policy to take effect

**WARNING:** if you have an active CRD session in Chrome right now, restarting will disconnect it; you'll re-PIN on the next `/macmini connect`. Quit Chrome fully (Cmd+Q on the Chrome menu, not just close window) before relaunching.

### 4c. Relaunch Chrome with remote debugging

```bash
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --remote-debugging-address=127.0.0.1 &
```

**DEFAULT (recommended):** no `--user-data-dir` flag. Chrome attaches to your existing main profile, so the agent has access to ALL your tabs, sessions, autofill, and the CRD device list (since you're already signed in). This is what makes the skill seamless.

**OPT-IN ISOLATION (paranoid users only):** add

```
--user-data-dir=/tmp/chrome-cdp
```

This launches a fresh empty Chrome with no signed-in accounts, no tabs, no autofill. You will need to sign into Google AND `remotedesktop.google.com` inside this isolated Chrome before `/macmini connect` works. Use only if you're doing something sensitive and don't want the agent to have access to your main browsing context. **Most users should NOT use this flag** — without your main profile, the agent can't reach the CRD device list and you lose the seamless drop-in behaviour.

### 4d. Verify Chrome is on debug port

```bash
curl -fsS http://127.0.0.1:9222/json/version
```

Expected: a JSON response with a `Browser` key. If it fails, Chrome was relaunched WITHOUT the flag — quit Chrome completely and try Step 4c again.

### 4e. Verify policy in effect

- Open `chrome://policy` → search "Clipboard". Expected: `ClipboardAllowedForUrls = [https://remotedesktop.google.com]`.
- Open `chrome://settings/content/clipboard`. Expected: our origin shows "Allowed by your administrator".

If either looks wrong, re-run `/macmini auto-grant install` and restart Chrome again.

---

## Step 5 — Smoke test

After Step 4 is complete, run a smoke test:

```
/macmini paste "HELLO_WORLD with $special chars: |&>~"
```

Switch focus to a Mac mini text field (e.g., open TextEdit via Spotlight) and `Cmd+V`. The pasted contents must be exactly `HELLO_WORLD with $special chars: |&>~` — capitals, underscore, `$`, `|`, `&`, `>`, `~`, all surviving. If anything arrives mangled, the canvas keyboard channel is being used somewhere it shouldn't be — re-run `/macmini status` to localize.

---

## Migration appendix — upgrading from the Tailscale-based version

If you had the previous Tailscale + Go server version installed, clean up the Mac mini side. **First, audit the Mac mini's git state for any local-only commits** (the Mac mini's auto-sync hook silently fails to push, so divergence is possible). On the Mac mini:

```bash
cd ~/.claude-dotfiles
git fetch origin
git status
git log origin/main..HEAD
```

If `git log origin/main..HEAD` shows nothing surprising, proceed. If it shows commits you want to keep, decide before resetting.

```bash
cd ~/.claude-dotfiles
git fetch origin
git reset --hard origin/macmini-strip
bash skills/macmini/cleanup-mini.sh
```

`cleanup-mini.sh` removes the LaunchAgent (`com.macmini-skill.server`), kills any running `macmini-server` process, deletes installed binaries from `~/.local/bin/` and `/usr/local/bin/`, and removes `~/.config/macmini-server/`. Tailscale itself is left alone — uninstall it manually if you no longer use it for anything else.

Verify on Mac mini:

```bash
ps aux | grep -v grep | grep macmini-server
```

Returns nothing.

Note: dev side is now the source of truth. The Mac mini's auto-sync hook will continue to silently fail to push (no git creds), which is expected.

---

## Recommended Mac mini one-time quality-of-life appendix

These are not required for the skill to work, but they make delegated work on the Mac mini smoother. All optional.

- **Auto-login** — System Settings → Users & Groups → "Automatically log in as". Manual; cannot be automated without your password. Lets the Mac mini come back without a human after reboot (FileVault still needs the FV password at cold boot).
- **Touch ID for sudo** — on Mac mini: `sudo cp /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local`, then edit it to enable `auth sufficient pam_tid.so`. Lets delegated `claude` sessions on the Mac mini resolve sudo prompts via fingerprint instead of typing the password through CRD (which mangles capitals).
- **Screen Recording permission for `screencapture`** — System Settings → Privacy & Security → Screen Recording → enable Terminal.app. Lets Mac mini Claude programmatically take screenshots for its own visual feedback loop.

---

## Rollback — back to the Tailscale version

The old Tailscale-based version is preserved on the `main` branch before the strip commits.

```bash
cd ~/.claude-dotfiles && git checkout main
```

On the Mac mini:

```bash
bash skills/macmini/install/install.sh
```

Re-installs the Go server and LaunchAgent. Then re-add the credentials this version dropped (`CRD_SERVER_TOKEN`, `CRD_MAC_MINI_HOSTNAME`) per the old setup.md.

---

You're done. From here on, day-to-day usage is `/macmini connect`, `/macmini paste`, `/macmini grab`, `/macmini status`, `/macmini disconnect`. Run `/macmini` with no args for the index.
