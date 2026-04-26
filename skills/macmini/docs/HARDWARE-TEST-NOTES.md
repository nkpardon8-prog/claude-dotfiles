# Hardware test notes

What was actually run end-to-end on a real Mac mini through Tailscale during the validation pass for this skill. Use this to know what's been proven vs what's still aspirational.

## What was tested

All seven HTTP routes ran end-to-end dev → Mac mini through the Tailscale tunnel:

- **`/health`** (no auth) — returns `{ok, version, uptime_seconds}`. 200 in <50ms over tailnet.
- **`/paste`** — pushed `HELLO_WORLD with $special chars: |&>~` (65 bytes). The exact 65 bytes appeared in the Mac mini's clipboard. Capitals, underscore, `$`, `|`, `&`, `>`, `~` all survived. This is the canonical proof that the data plane is not subject to CRD's keystroke-mangling.
- **`/run`** — buffered shell exec via `/bin/zsh -lc`. Exit code, stdout, stderr returned in JSON. Verified PATH inheritance from login shell (Homebrew on PATH).
- **`/run/stream`** — NDJSON-streamed for a long-running command (`sleep 1; echo a; sleep 1; echo b`). Lines arrived as they were emitted, not buffered until exit.
- **`/shot`** — returned a 1920×1080 PNG natively. Non-black, correct screen contents.
- **`/files/push`** — multipart upload, sha256 client-side verify against server-reported sha256.
- **`/files/pull`** — download with sha256 verify on the dev side.
- **401 unauthorized** — wrong bearer token rejected on every gated route.
- **`/admin/rotate-token`** — hot-swap. Old token rejected immediately after rotate, new token accepted, no server restart, no connection drop.
- **Userspace tailscaled forwarding** — server bound to tailnet IP under `tailscaled --tun=userspace-networking` (no sudo, no system extension). Inbound tailnet traffic reached the listener. Localhost (`127.0.0.1:8765`) was also reachable, confirming tailscaled's userspace-mode forwarding.

## What was deferred

These steps are not blockers for daily use but are not yet proven:

- **launchd LaunchAgent install on the validated host** — the server during the test ran via `nohup`, not as a managed LaunchAgent. Boot survival is therefore not yet proven on that host. Document this as a step the user must complete with a re-run of `install.sh` from a logged-in GUI session (the script handles it).
- **Token transfer to dev `~/.config/claude/credentials.md`** — server token is on Mac mini disk; the dev side used an ad-hoc `MACMINI_TOKEN` env var for testing. The `tailscale file cp` recipe in `setup.md` Step 5 is the documented path; not yet exercised end-to-end.
- **`pmset` for sleep prevention** — opt-in, sudo-needed. Skipped in userspace mode by default.
- **Auto-login for boot survival** — a manual System Settings step. The user must do this themselves; install.sh cannot.
- **Mac mini Tailscale wrapper at `/usr/local/bin/tailscale`** — only relevant for the cask path. Not exercised under userspace mode.

## Friction points captured

These map to entries in the README troubleshooting matrix:

- **Git remote credentials missing on Mac mini** → HTTPS push fails silently. The auto-sync hook can race and cause divergence between dev and Mac mini repos. Recovery: force-push from dev (`git push origin main --force-with-lease`) and `git fetch origin && git reset --hard origin/main` on the Mac mini.
- **CRD typing mangling** → never type complex commands through the canvas. Either delegate to a Mac mini Claude session or use the `/macmini paste` + `Cmd+V` route.
- **Spotlight Terminal launch reliability** — `Cmd+Space → terminal → Enter` is more reliable than Cmd+Tab through the canvas, which can land on the wrong app.
- **Tailscale auth URL transfer** — the auth URL printed by `tailscale up` is too long and special-character-heavy to type through CRD. Use `open <url>` on the Mac mini side to pop the URL in its own browser; the human clicks through visually.
- **Userspace tailscaled subnet behavior** — confirmed: tailscaled in userspace mode forwards inbound tailnet traffic to localhost listeners. The server stays reachable on the tailnet IP without a TUN device. install.sh has a localhost fallback in case the tailnet-IP bind fails for any reason.

## Reproduction recipe

The next testing pass can re-verify the install on a fresh Mac mini in roughly 10 steps. Run on the Mac mini unless otherwise marked.

```bash
# 1. Tailscale via Homebrew formula (no sudo).
brew install tailscale

# 2. Start userspace tailscaled.
mkdir -p ~/.config/tailscaled ~/Library/Logs
nohup tailscaled --tun=userspace-networking \
    --socket=$HOME/.config/tailscaled/tailscaled.sock \
    --statedir=$HOME/.config/tailscaled \
    > $HOME/Library/Logs/tailscaled.log 2>&1 &

# 3. Authorize this node into your tailnet.
tailscale --socket=$HOME/.config/tailscaled/tailscaled.sock up
# Visit the printed auth URL in any browser. Expected: node appears at <your-tailnet>.ts.net.

# 4. Confirm online + grab the IP.
TS_SOCK=$HOME/.config/tailscaled/tailscaled.sock
tailscale --socket=$TS_SOCK status --json | jq -e '.Self.Online == true'
TS_IP=$(tailscale --socket=$TS_SOCK status --json \
    | jq -r '.Self.TailscaleIPs | map(select(contains("."))) | .[0]')
echo "$TS_IP"  # e.g. 100.x.y.z

# 5. Run the installer in userspace mode.
bash ~/.claude-dotfiles/skills/macmini/install/install.sh
# Expected: token generated, ~/.local/bin/macmini-{server,client} installed,
# LaunchAgent bootstrapped, /health 200, credentials block printed.

# 6. Capture the token (one-time).
bash ~/.claude-dotfiles/skills/macmini/install/install.sh --print-token
# Copy into 1Password, then forget.

# 7. (DEV) /load-creds CRD_PIN,CRD_MAC_MINI_HOSTNAME,CRD_DEVICE_NAME,CRD_SERVER_TOKEN

# 8. (DEV) Health smoke.
macmini-client health
# Expected: {"ok":true,"version":"0.1.0","uptime_seconds":N}

# 9. (DEV) Side-channel verbatim test.
macmini-client paste 'HELLO_WORLD with $special chars: |&>~'
# Then on Mac mini: pbpaste — must equal exactly the input.

# 10. (DEV) Run + shot smoke.
macmini-client run "uname -a && whoami"
macmini-client shot /tmp/shot.png && file /tmp/shot.png
# Expected: PNG image data, ~1920x1080.
```

If any step fails, capture the failing command's stderr and the relevant log (`~/Library/Logs/macmini-server.log`, `~/Library/Logs/tailscaled.log`) before retrying.
