---
description: One-time end-to-end setup for the Mac mini remote skill (Tailscale + side-channel server + CRD profile bootstrap).
argument-hint: ""
---

# /macmini setup

## What this does

Walks you through the first-time install of the Mac mini remote skill. The architecture has two cooperating channels: the **chrome-devtools MCP** drives the visual side (Chrome Remote Desktop canvas, clicks, screenshots), and a **Tailscale-only HTTPS-less HTTP server** running on the Mac mini handles the data side (clipboard paste, file push/pull, command run, screen capture). The two together let an agent operate a Mac mini reliably without exposing anything to the public internet.

CRITICAL warning: **CRD's keystroke forwarding is broken for Shift-modified characters.** The Shift modifier gets dropped in transit, so capital letters, underscores, `$`, `|`, `&`, `~`, `:` and other shifted glyphs come through corrupted (e.g. `HELLO_WORLD` → `hello-world`). The Tailscale side-channel exists specifically to bypass this. Use `/macmini paste`, `/macmini push`, and `/macmini run` for any payload with mixed case, special characters, or anything programmatic. The CRD canvas is for clicking, scrolling, and visual confirmation only.

---

## Step 1 — DEV: Tailscale present and signed in

Verify both the dev machine and the Mac mini show up in `tailscale status`.

```bash
tailscale status
```

You must see Self online AND the Mac mini node listed. If not, install Tailscale and sign both ends into the same tailnet before proceeding.

## Step 2 — DEV: Build and install the dev-machine client

```bash
cd ~/.claude-dotfiles/skills/macmini/client
make build && sudo make install
macmini-client version
```

`macmini-client` should now be on `$PATH` at `/usr/local/bin/macmini-client`.

## Step 3 — MAC MINI (one time): Run the installer ON the Mac mini

You need physical or pre-existing remote access to the Mac mini for this single bootstrap step (chicken-and-egg — unavoidable for first install). On the Mac mini directly:

```bash
bash ~/.claude-dotfiles/skills/macmini/install/install.sh
```

The installer performs: Tailscale check, server token generation, server binary install, LaunchAgent plist + bootstrap, `pmset` (will prompt for sudo), and a Screen Recording TCC permission probe (a system permission dialog will pop up — click **Allow**).

When it finishes, the installer prints a ready-to-paste credentials block. Keep that terminal open — you'll need the values in Step 5.

## Step 4 — MAC MINI (manual): Auto-login for boot survival

This step is intentionally manual — `sysadminctl` needs a password and we refuse to put one in `install.sh`.

1. System Settings → Users & Groups → "Automatically log in as" → select your account.
2. Enter the user password when prompted.

If FileVault is enabled, the Mac will still require the FV password at cold boot, but auto-login resumes after that. Verify by rebooting the Mac mini and then, from the dev machine:

```bash
macmini-client health
```

Must return ok.

## Step 5 — DEV: Add credentials

1. Paste the credentials block from `install.sh` output into `~/.config/claude/credentials.md`.
2. Store the actual secret values in 1Password under:
   - `op://<VAULT>/Mac mini CRD/PIN`
   - `op://<VAULT>/Mac mini CRD/Hostname`
   - `op://<VAULT>/Mac mini CRD/Device Name`
   - `op://<VAULT>/Mac mini CRD/Server Token`
3. For `CRD_DEVICE_NAME`: open https://remotedesktop.google.com/access in your daily Chrome and copy the **EXACT** name shown on the Mac mini's tile (whatever you typed during CRD host setup; usually the macOS hostname). This is the CRD-side display name and is **not** the same as the Tailscale node name.
4. Load the env into the current session:

```
/load-creds CRD_PIN,CRD_MAC_MINI_HOSTNAME,CRD_DEVICE_NAME,CRD_SERVER_TOKEN
```

## Step 6 — DEV: Smoke test status

```
/macmini status
```

All three columns (Tailscale | Server | CRD session) must be green. If anything is red, fix it before continuing.

## Step 7 — DEV (one time): Bootstrap the CRD Chrome profile

We use a dedicated Chrome profile (`Claude-CRD`) that the chrome-devtools MCP drives, isolated from your daily Chrome. Quit Chrome **entirely** before starting — Chrome locks the profile directory and the copy will fail otherwise.

```bash
# 1. Confirm Chrome is fully quit
pkill -f 'Google Chrome' || true

# 2. Create and seed the new profile from your existing Default
mkdir -p "$HOME/Library/Application Support/Claude-CRD"
cp -R "$HOME/Library/Application Support/Google/Chrome/Default" \
      "$HOME/Library/Application Support/Claude-CRD/Default"
```

Configure the chrome-devtools MCP to launch with `--user-data-dir` pointing at `$HOME/Library/Application Support/Claude-CRD`. The exact way to wire that depends on the MCP build loaded in your environment — ask the user to verify how their MCP binary accepts the flag if it isn't obvious.

Then, using the MCP, navigate to https://remotedesktop.google.com/access. Complete any Google 2FA prompts in the Chrome window. Verify the Mac mini's tile is visible on the page.

## Step 8 — DEV: Full smoke test

```
/macmini connect
```

Should land you in the CRD canvas. Then prove the side-channel works around CRD keystroke mangling:

```
/macmini paste "test 123 ABC !@#"
```

Switch to the Mac mini and check its clipboard (Cmd+V into a text field). The pasted contents must be **exactly** `test 123 ABC !@#` — capitals, special chars, and all. If the clipboard is empty or mangled, the side-channel is broken; recheck `/macmini status` and the server log at `~/Library/Logs/macmini-server.log` on the Mac mini.

---

You're done. From here on, day-to-day usage is `/macmini connect`, `/macmini paste`, `/macmini run`, etc. Run `/macmini` with no args for the index.
