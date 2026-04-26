---
description: One-time end-to-end setup for the Mac mini remote skill (Tailscale + side-channel server + optional CRD profile bootstrap).
argument-hint: ""
---

# /macmini setup

## What this does

Walks you through the first-time install of the Mac mini remote skill. The architecture has two cooperating channels: the **chrome-devtools MCP** drives the visual side (Chrome Remote Desktop canvas, clicks, screenshots), and a **Tailscale-only HTTP server** running on the Mac mini handles the data side (clipboard paste, file push/pull, command run, screen capture). The two together let an agent operate a Mac mini reliably without exposing anything to the public internet.

CRITICAL warning: **CRD's keystroke forwarding is broken for Shift-modified characters.** The Shift modifier gets dropped in transit, so capital letters, underscores, `$`, `|`, `&`, `~`, `:` and other shifted glyphs come through corrupted (e.g. `HELLO_WORLD` → `hello-world`). The Tailscale side-channel exists specifically to bypass this. Use `/macmini paste`, `/macmini push`, and `/macmini run` for any payload with mixed case, special characters, or anything programmatic. The CRD canvas is for clicking, scrolling, and visual confirmation only.

For agent operators driving this remotely, also read `skills/macmini/docs/AGENT-GUIDE.md`. For what's been verified end-to-end on real hardware, see `skills/macmini/docs/HARDWARE-TEST-NOTES.md`.

---

## Step 1 — DEV: Tailscale present and signed in

```bash
tailscale status
```

You must see Self online AND the Mac mini node listed. If not, install Tailscale (`brew install tailscale`, App Store, or tailscale.com/download) and sign both ends into the same tailnet before proceeding.

## Step 2 — DEV: Build and install the dev-machine client

Two options:

```bash
# Option A — user-local (no sudo)
cd ~/.claude-dotfiles/skills/macmini/client
make build
mkdir -p ~/.local/bin && cp dist/macmini-client-darwin-* ~/.local/bin/macmini-client
# Ensure ~/.local/bin is on PATH (add to ~/.zprofile if not).

# Option B — system-wide (sudo)
cd ~/.claude-dotfiles/skills/macmini/client
make build && sudo make install
```

Verify:

```bash
macmini-client version
```

Use Option A if you want a clean no-sudo path. Use Option B if multiple users on the dev machine need the binary.

## Step 3 — MAC MINI (one time): Run the installer ON the Mac mini

You need physical or pre-existing remote access to the Mac mini for this single bootstrap step. On the Mac mini directly:

```bash
# Default: userspace mode, NO sudo. Uses brew formula 'tailscale' +
# tailscaled --tun=userspace-networking. Binaries land in ~/.local/bin/.
bash ~/.claude-dotfiles/skills/macmini/install/install.sh

# Legacy fallback: cask mode (requires sudo, system extension, /usr/local/bin/).
bash ~/.claude-dotfiles/skills/macmini/install/install.sh --mode=cask
```

Userspace tailscaled forwards inbound tailnet traffic to localhost listeners, so the server stays reachable on the tailnet IP without any kernel TUN device or system extension.

If this is the very first time tailscaled has come up on this user, the installer will tell you to run `tailscale --socket=$HOME/.config/tailscaled/tailscaled.sock up`. Visit the auth URL in a browser — easiest path is `open <url>` on the Mac mini itself so the browser there can complete the SSO.

When it finishes, the installer prints a ready-to-paste credentials block. Keep that terminal open — you'll need the values in Step 5.

## Step 4 — MAC MINI (manual): Auto-login + Touch ID for sudo

Auto-login is **required** for boot survival because the LaunchAgent only runs once a GUI session exists. This step is intentionally manual — it needs your password.

1. System Settings → Users & Groups → "Automatically log in as" → select your account.
2. Enter the user password when prompted.

If FileVault is enabled, the Mac will still require the FV password at cold boot, but auto-login resumes after that. Verify by rebooting the Mac mini and then, from the dev machine:

```bash
macmini-client health
```

Must return ok.

**Recommended one-time quality-of-life setup**: enable Touch ID for sudo. CRD mangles passwords typed through the canvas, so any sudo prompt taken via CRD is painful. Touch ID makes those prompts a fingerprint tap.

```bash
# On the Mac mini, with a Terminal you'll keep open (in case it breaks sudo):
echo 'auth       sufficient     pam_tid.so' | sudo tee /etc/pam.d/sudo_local
```

Test by running any harmless `sudo` command. The fingerprint reader should light up.

## Step 5 — DEV: Add credentials

1. Paste the credentials block from `install.sh` output into `~/.config/claude/credentials.md`.
2. Store the actual secret values in 1Password under:
   - `op://<VAULT>/Mac mini CRD/PIN`
   - `op://<VAULT>/Mac mini CRD/Hostname`
   - `op://<VAULT>/Mac mini CRD/Device Name`
   - `op://<VAULT>/Mac mini CRD/Server Token`
3. For `CRD_DEVICE_NAME`: open <https://remotedesktop.google.com/access> in your daily Chrome and copy the **EXACT** name shown on the Mac mini's tile (whatever you typed during CRD host setup; usually the macOS hostname). This is the CRD-side display name and is **not** the same as the Tailscale node name.
4. **Transfer the server token from Mac mini to dev**. The token lives at `~/.config/macmini-server/token` on the Mac mini. The cleanest cross-machine recipe uses Tailscale's file-drop:

   ```bash
   # On the Mac mini:
   tailscale --socket=$HOME/.config/tailscaled/tailscaled.sock file cp \
       ~/.config/macmini-server/token <dev-tailnet-name>:

   # On the dev machine (same dir as wherever you want to land it):
   tailscale file get .
   # then read the file and paste the value into 1Password under Server Token
   ```

   Once it's in 1Password, delete the local copy. The token is also dumpable via `bash install.sh --print-token` if you'd rather just type it once at the Mac mini's keyboard.

5. Load the env into the current session:

   ```
   /load-creds CRD_PIN,CRD_MAC_MINI_HOSTNAME,CRD_DEVICE_NAME,CRD_SERVER_TOKEN
   ```

## Step 6 — DEV: Smoke test status

```
/macmini status
```

All three columns (Tailscale | Server | CRD session) must be green. If anything is red, fix it before continuing.

## Step 7 — DEV (optional): Dedicated Chrome profile for CRD

In most cases the chrome-devtools MCP attaches to your **existing running Chrome** and reuses your existing Google login — no dedicated profile required. **Skip this step** unless you specifically want CRD isolated from your daily Chrome (e.g. multiple Google accounts, separate cookie jar).

If you do want isolation, create a `Claude-CRD` profile and configure the chrome-devtools MCP to launch with `--user-data-dir` pointing at it. Quit Chrome **entirely** before copying — Chrome locks the profile directory.

```bash
pkill -f 'Google Chrome' || true
mkdir -p "$HOME/Library/Application Support/Claude-CRD"
cp -R "$HOME/Library/Application Support/Google/Chrome/Default" \
      "$HOME/Library/Application Support/Claude-CRD/Default"
```

Then sign that profile into the same Google account that owns the Mac mini's CRD host registration, and verify the Mac mini's tile is visible at <https://remotedesktop.google.com/access>.

## Step 8 — DEV: Full smoke test

```
/macmini connect
```

Should land you in the CRD canvas. Then prove the side-channel beats CRD's keystroke mangling with the canonical test payload:

```
/macmini paste "HELLO_WORLD with $special chars: |&>~"
```

Switch to the Mac mini and check its clipboard (Cmd+V into a text field). The pasted contents must be **exactly** `HELLO_WORLD with $special chars: |&>~` — capitals, underscore, `$`, `|`, `&`, `>`, `~`, all surviving. If it arrives mangled, the canvas keyboard channel is being used somewhere it shouldn't be; recheck `/macmini status` and the server log at `~/Library/Logs/macmini-server.log` on the Mac mini.

Two more checks worth running once:

```
/macmini run "uname -a && whoami"
/macmini shot
```

The first must return real output through the data plane (not the canvas). The second must return a non-black PNG.

---

You're done. From here on, day-to-day usage is `/macmini connect`, `/macmini paste`, `/macmini run`, etc. Run `/macmini` with no args for the index.
