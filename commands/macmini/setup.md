---
description: One-time setup for the Mac mini remote skill — chrome-devtools MCP, gh on both sides, credentials, first connect.
argument-hint: ""
---

# /macmini setup

Three steps from zero to a working `/macmini connect`. The skill drives the Mac mini through the chrome-devtools MCP attached to your existing Chrome — no daemons, no binaries, no servers, no auto-grant scripts. Arbitrary text moves through `gh gist` clone (lossless). Vision is the always-on feedback loop.

CRITICAL: **CRD's keystroke forwarding strips Shift.** Capitals, `$@!#%^&*()`, `_+{}[]|\\:"<>?~` arrive corrupted (`HELLO_WORLD` → `hello-world`, `$(` → `+%`). For anything other than lowercase shell commands, use `/macmini paste` (gist transport).

For the full capability map and channel matrix, read `~/.claude-dotfiles/skills/macmini/SKILL.md`. For real-world findings, read `~/.claude-dotfiles/skills/macmini/docs/HARDWARE-FINDINGS-2026-04-27.md`.

---

## Step 1 — chrome-devtools MCP installed and configured

The skill is a thin wrapper around the chrome-devtools MCP. Confirm it's loaded in your Claude Code MCP configuration. If you don't have it yet, install per its docs (typically a Node-based MCP server entry).

Example MCP config snippet:

```json
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["chrome-devtools-mcp"]
    }
  }
}
```

After editing the MCP config, **restart Claude Code (or your MCP host)** so the MCP loads.

---

## Step 2 — `gh` authenticated on BOTH sides (dev + Mac mini)

The arbitrary-text channel (`/macmini paste`) needs `gh` CLI authenticated to the same GitHub account on both machines.

**Dev side:**

```bash
gh auth status
# If not logged in:
gh auth login
```

**Mac mini side** (one-time, do this manually via the user's hands or a delegated `claude` Terminal session — typing it through the canvas is fine since `gh auth login` is all unshifted):

```bash
brew install gh
gh auth login
```

`gh auth login` is interactive — the user follows the device-flow prompts in their browser. Once authenticated on both sides, `/macmini paste` works forever.

---

## Step 3 — Credentials (optional)

The skill needs ONE optional value:

- `CRD_DEVICE_NAME` — the EXACT aria-label shown on the Mac mini's tile at <https://remotedesktop.google.com/access>. Only needed if you have multiple devices in your CRD device list and want the agent to pick the right one without asking. If you only have one Mac mini, the skill auto-picks the single Online tile.

The CRD PIN is **never stored** — you type it yourself when the page comes up. The agent watches for the canvas to mount and picks back up automatically.

If you want `CRD_DEVICE_NAME`, add it to `~/.config/claude/credentials.md`:

```markdown
## Mac mini remote (CRD skill)

| Env var          | 1Password ref                                |
|------------------|----------------------------------------------|
| CRD_DEVICE_NAME  | op://<VAULT>/Mac mini CRD/Device Name        |
```

Then load it into the session:

```
/load-creds CRD_DEVICE_NAME
```

---

## Step 4 — First `/macmini connect`

```
/macmini connect
```

The first run lands you in the CRD canvas after PIN entry. If Chrome prompts to allow clipboard for `https://remotedesktop.google.com`, click **Allow**. This grant persists across sessions.

---

## Step 5 — One-time CRD side-panel toggles (USER does this manually, ONCE)

After the canvas appears, hover the right edge of the CRD viewport. The CRD options panel slides in. Click these two toggles ON:

- **"Synchronize clipboard"** — under the "Data transfer" section
- **"Send system keys"** — under the "Input controls" section

These persist across reconnects, so this is a one-time step. The agent CANNOT click them on your behalf (CRD strips its own a11y tree, and synthetic clicks fail the `isTrusted` check).

---

## Step 6 — Smoke test

```
/macmini paste "HELLO_WORLD with $special chars: |&>~ and 日本語"
```

The skill creates a secret gist, then types `rm -rf /tmp/p; gh gist clone <id> /tmp/p; bash /tmp/p/run.sh` on the Mac mini. The mini's clipboard is updated to the original text. Then on the Mac mini Terminal: type `pbpaste` (lowercase, works fine) — the output should match the input exactly: `HELLO_WORLD with $special chars: |&>~ and 日本語`.

If anything arrives mangled, run `/macmini status` to localize.

---

## Optional Mac mini quality-of-life appendix

These are not required for the skill to work but make delegated work smoother. All optional.

- **Auto-login** — System Settings → Users & Groups → "Automatically log in as". Lets the Mac mini come back without a human after reboot (FileVault still needs the FV password at cold boot).
- **Touch ID for sudo** — on Mac mini: `sudo cp /etc/pam.d/sudo_local.template /etc/pam.d/sudo_local`, then enable `auth sufficient pam_tid.so`. Lets delegated `claude` sessions resolve sudo via fingerprint instead of typing the password through CRD.
- **Screen Recording permission for `screencapture`** — System Settings → Privacy & Security → Screen Recording → enable Terminal.app. Lets Mac mini Claude programmatically take screenshots for its own visual feedback loop.

---

## Migration from the Tailscale-based version

If you had the previous Tailscale + Go server version installed, clean up the Mac mini:

```bash
cd ~/.claude-dotfiles
git fetch origin
git reset --hard origin/main
bash skills/macmini/cleanup-mini.sh
```

`cleanup-mini.sh` removes the LaunchAgent (`com.macmini-skill.server`), kills any running `macmini-server` process, deletes installed binaries, and removes `~/.config/macmini-server/`. Tailscale itself is left alone.

---

You're done. Day-to-day usage is `/macmini connect`, `/macmini paste`, `/macmini grab`, `/macmini status`, `/macmini disconnect`. Run `/macmini` with no args for the index.
