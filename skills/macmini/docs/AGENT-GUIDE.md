# Agent guide — driving a Mac mini via CRD + Tailscale

You are an AI agent (e.g. Claude Code, an autonomous browser agent) tasked with operating a remote Mac mini through this skill. This guide condenses what was learned during real-hardware validation. Read it before the first action.

## 1. The frame

You have two planes:

- **Visual plane** — a Chrome Remote Desktop canvas inside a Chrome tab on the dev machine, controlled by chrome-devtools MCP. You can see the Mac mini's screen, click the canvas, send keystrokes through the canvas. **Limited keyboard fidelity** — see section 4.
- **Data plane** — a Tailscale-only HTTP server on the Mac mini (port 8765). Bytes go through verbatim. This is your real workhorse. Routes: `/health`, `/paste`, `/files/push`, `/files/pull`, `/run`, `/run/stream`, `/shot`, `/admin/rotate-token`. Bearer-token-gated except `/health`.

**Rule**: anything text-y (commands, paths, JSON, tokens, mixed-case prose) goes via the data plane. The canvas is for clicking, lowercase Spotlight queries, and watching things happen.

## 2. Tools on the Mac mini side

- **Claude Code is installed**. To delegate complex work to it:
  1. Open Terminal on the Mac mini (Cmd+Space → type `terminal` → Enter).
  2. Type `claude` (lowercase, safe through CRD).
  3. Talk to it in lowercase prose. It has its own Bash and runs anything you'd run yourself, sidestepping CRD keystroke mangling entirely.
- **Pre-installed (typically)**: macOS, Spotlight, Terminal, Safari/Chrome, Git, Homebrew (if present from prior use).
- **Often NOT installed on a fresh Mac mini**: Tailscale, Go, gh CLI, Node, Python 3.11+, the macmini-client binary, the macmini-server binary. Install via `brew` or by delegating to Mac mini Claude.

## 3. CRD typing rules — CRITICAL

Empirically validated (the `HELLO_WORLD with $special chars: |&>~` test):

| Class | Behavior through CRD canvas |
|---|---|
| Lowercase letters, digits, `-`, `.`, `/`, space | Safe |
| Capitals, `_`, `:`, `$`, `\|`, `&`, `>`, `<`, `~`, `(`, `)`, `*`, `?`, `'`, `"`, `@`, `#`, `+`, `=`, `\` | **Mangled** (Shift modifier dropped) |
| Cmd+letter (e.g. Cmd+V, Cmd+Q, Cmd+Space) | Safe |
| Cmd+Shift+letter | Often broken |

Workarounds, in order of preference:

1. **Delegate to Mac mini Claude in lowercase prose** — best for arbitrary commands.
2. **Use the data plane directly** — `/macmini run`, `/macmini paste`, `/macmini push`. Never goes through the canvas.
3. **Paste-then-Cmd+V** — `/macmini paste <text>` puts the literal bytes in the Mac mini clipboard, then `Cmd+V` (single Cmd+lowercase, safe) into the target app. Use this when you need to put complex text into a GUI field that doesn't have a CLI equivalent.

Never type a token, password, JSON blob, or env-var assignment directly through the canvas.

## 4. Focus discipline

- After connecting, **Cmd+Space → type lowercase app name → Enter** to focus a specific app. More reliable than Cmd+Tab through the canvas — Cmd+Tab can land on the wrong app and your subsequent keystrokes go where you didn't intend (we hit this — typed instructions went into Chrome's URL bar instead of Terminal).
- Click the canvas at coordinates `(1, 1)` (or any safe spot) before sending keystrokes, to make sure the CRD canvas has DOM focus.
- Watch for stray Spotlight, System Settings, or Encodings windows opening — those are signs of a misinterpreted modifier-Shift keystroke. Cmd+Q to close, then re-focus.

## 5. Side-channel routes

All examples assume `MACMINI_BASE=http://<tailnet-ip>:8765` and `MACMINI_TOKEN=<bearer>`.

| Route | Method | Auth | Purpose |
|---|---|---|---|
| `/health` | GET | none | liveness, version, uptime |
| `/paste` | POST | bearer | text body → `pbcopy` on Mac mini |
| `/run` | POST | bearer | run via `/bin/zsh -lc`, return stdout/stderr/exit |
| `/run/stream` | POST | bearer | NDJSON-streamed run for long-running processes |
| `/files/push` | POST | bearer | upload (multipart, sha256-checked, allowlisted dirs) |
| `/files/pull` | GET | bearer | download (allowlisted dirs) |
| `/shot` | POST | bearer | `screencapture` → PNG |
| `/admin/rotate-token` | POST | bearer | hot-swap bearer (server stays up) |

Use `macmini-client` on the dev side for the typed wrapper. If you must invoke through the canvas, lowercase forms are CRD-safe (`macmini-client health`).

## 6. Sudo handling

- **Most install steps need NO sudo** in userspace mode (the recommended default). Document that to the human if they ask.
- If sudo IS needed (e.g. `pmset`, cask install, kext loader), prefer Touch ID for sudo via `/etc/pam.d/sudo_local` with `pam_tid.so`. Last resort: have the human type the password directly at the Mac mini's keyboard.
- **Do not attempt to type sudo passwords through CRD.** Shift modifier mangling will corrupt most passwords. Better to give up and delegate to a human or to a Mac mini Claude session that has a TTY.

## 7. Recovery / common gotchas

- **Mac mini's git remote may lack credentials** → `git push` fails silently, auto-sync hooks race, Mac mini's working tree can revert dev-side commits. Recovery: force-push from dev (`git push origin main --force-with-lease`), then on Mac mini `git fetch origin && git reset --hard origin/main`.
- **CRD canvas doesn't accept synthetic mouse events** — DOM clicks via `evaluate_script` won't reach the Mac mini. For real Mac-mini-side mouse work, use `/run cliclick` (if installed) or have the human click physically.
- **Tailscale auth URL** can't easily be transferred dev↔Mac mini through CRD typing. Have the Mac mini side run `open <url>` to pop the URL in its own browser; the human clicks through visually.
- **Server might already be running** — `pgrep macmini-server` before starting a new one.
- **Userspace tailscaled forwards inbound to localhost listener.** If `LISTEN_ADDR` bind to the tailnet IP fails, the server can bind `127.0.0.1:8765` and stay reachable at the tailnet IP.

## 8. Recipes

```bash
# Install Tailscale on Mac mini sudoless
brew install tailscale
mkdir -p ~/.config/tailscaled
nohup tailscaled --tun=userspace-networking \
    --socket=$HOME/.config/tailscaled/tailscaled.sock \
    --statedir=$HOME/.config/tailscaled \
    > $HOME/Library/Logs/tailscaled.log 2>&1 &
tailscale --socket=$HOME/.config/tailscaled/tailscaled.sock up

# Get Mac mini's tailnet IP
tailscale --socket=$HOME/.config/tailscaled/tailscaled.sock status --json \
    | jq -r '.Self.TailscaleIPs | map(select(contains("."))) | .[0]'

# Verify side-channel works
curl -sf http://<tailnet-ip>:8765/health

# Transfer server token Mac mini → dev
# (Mac mini side)
tailscale --socket=$HOME/.config/tailscaled/tailscaled.sock file cp \
    ~/.config/macmini-server/token <dev-tailnet-name>:
# (dev side)
tailscale file get .

# Recover from git divergence (dev → Mac mini)
# (dev)
git push origin main --force-with-lease
# (Mac mini)
git fetch origin && git reset --hard origin/main
```

## 9. When blocked

Report cleanly to the human in lowercase prose:

1. What state did you reach?
2. What failed?
3. What did you try?
4. What specific input do you need from them (a password, a click, a credential transfer)?

Don't keep retrying through CRD if the channel is fighting you. The data plane is almost always the right answer; if the data plane itself is broken, the human needs to be in the loop.
