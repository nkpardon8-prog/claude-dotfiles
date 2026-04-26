# macmini — Chrome Remote Desktop + side-channel skill

> **Validated on real hardware.** All seven HTTP routes (`/health`, `/paste`, `/run`, `/run/stream`, `/shot`, `/files/push`, `/files/pull`, `/admin/rotate-token`) ran end-to-end dev → Mac mini through Tailscale during the validation pass. The canonical "did the side-channel beat CRD's keystroke mangling" payload `HELLO_WORLD with $special chars: |&>~` survived byte-for-byte. See `docs/HARDWARE-TEST-NOTES.md` for what's been proven vs deferred.

Drive a Mac mini from a Mac laptop the way a human would: a live desktop you can see and click, plus a programmatic back door for everything that breaks when you try to type it through a remote canvas. The skill is two cooperating components — a Chrome Remote Desktop (CRD) tab driven by chrome-devtools MCP for visual control, and a tiny Tailscale-only HTTP server (Go static binary on port 8765, bound to the Tailscale interface IP) for paste, file transfer, command execution, and screenshots. The HTTP server is gated by a bearer token and is not reachable from LAN, the public internet, or any network other than your tailnet.

This split exists for one specific reason: **CRD's keystroke forwarding drops the Shift modifier**, so capital letters and special characters get corrupted in transit. `HELLO_WORLD` typed through the canvas arrives as `hello-world`. Tokens, JSON, paths with `$`, anything mixed-case — all mangled. The side-channel exists to route everything text-y around the canvas. The canvas is for clicking, Spotlight queries (lowercase), and watching things happen.

---

## First 5 minutes

This walkthrough mirrors `commands/macmini/setup.md`. The default install path is **userspace mode** — no sudo, no system extension, no kext loader. `brew install tailscale` (formula, not cask) plus `tailscaled --tun=userspace-networking` provides a working tailnet for this user, and userspace tailscaled forwards inbound tailnet traffic to localhost listeners so the server stays reachable on the tailnet IP. Run from the dev machine unless a step says otherwise.

### 1. Confirm Tailscale on the dev machine

```bash
tailscale status
```

Self should be online. The Mac mini may not yet be listed if this is its very first install — Step 3 handles that.

### 2. Set up Chrome Remote Desktop on the Mac mini (one time)

On the Mac mini desktop (physically or via Screen Sharing for this single bootstrap):

1. System Settings → General → Sharing → toggle **Remote Management** ON. Allow access for your user.
2. Open Chrome on the Mac mini, go to <https://remotedesktop.google.com/access>, sign in with the Google account you'll use on the dev side, click "Set up via SSH" → "Turn on", set a 6-digit PIN, store that PIN in 1Password as `CRD_PIN`.

Expected: the device appears as **Online** at <https://remotedesktop.google.com/access>.

### 3. Install the side-channel server on the Mac mini

From a Terminal logged into the Mac mini's GUI session (the LaunchAgent needs your aqua user session — not a headless `ssh-as-different-user`):

```bash
# Default: userspace mode (no sudo). Installs ~/.local/bin/macmini-{server,client}.
bash ~/.claude-dotfiles/skills/macmini/install/install.sh

# Legacy fallback: cask mode (needs sudo, system extension, /usr/local/bin/).
# Pass --mode=cask only if userspace mode fails.
```

If this is the very first install on this user, the script will tell you to run `tailscale --socket=$HOME/.config/tailscaled/tailscaled.sock up` — visit the printed auth URL in any browser to authorize the node, then re-run install.sh.

Expected final output:

```text
==> /health OK
=== Mac mini server installed ===
Tailnet hostname:   <hostname>.<your-tailnet>.ts.net
Listen address:     100.x.y.z:8765
Token fingerprint:  abcd1234
...
```

### 4. Enable auto-login (boot survival)

System Settings → Users & Groups → "Automatically log in as" → your user. Required because the LaunchAgent only runs once a GUI session exists. See [Boot survival](#boot-survival). Optional: enable Touch ID for sudo (`/etc/pam.d/sudo_local` with `pam_tid.so`) — makes the few sudo prompts pleasant when working through CRD.

### 5. Transfer the server token to dev

The token lives at `~/.config/macmini-server/token` on the Mac mini. Move it once into 1Password under `op://<VAULT>/Mac mini CRD/Server Token`:

```bash
# On the Mac mini (uses Tailscale's file-drop, no extra deps):
tailscale --socket=$HOME/.config/tailscaled/tailscaled.sock file cp \
    ~/.config/macmini-server/token <dev-tailnet-name>:

# On the dev machine:
tailscale file get .   # creates ./token
```

Or just dump it once: `bash ~/.claude-dotfiles/skills/macmini/install/install.sh --print-token`.

### 6. Populate credentials on dev

Add the four entries to `~/.config/claude/credentials.md`: `CRD_PIN`, `CRD_MAC_MINI_HOSTNAME`, `CRD_DEVICE_NAME`, `CRD_SERVER_TOKEN`. Each is an `op://` reference. Then:

```bash
/load-creds CRD_PIN,CRD_MAC_MINI_HOSTNAME,CRD_DEVICE_NAME,CRD_SERVER_TOKEN
```

### 7. Smoke-test from the dev machine

```bash
macmini-client health
macmini-client paste 'HELLO_WORLD with $special chars: |&>~'
# On Mac mini: pbpaste — must equal exactly the input.
macmini-client shot /tmp/shot.png && file /tmp/shot.png
```

The paste payload is the canonical proof that the data plane survives where the CRD canvas mangles. If `pbpaste` returns exactly those 65 bytes, you're done.

### 8. Connect

```
/macmini connect
```

In most cases the chrome-devtools MCP attaches to your **existing running Chrome** and reuses your existing Google login. No dedicated profile is needed unless you want CRD isolated from your daily Chrome — see [setup.md Step 7](../../commands/macmini/setup.md) for the optional dedicated-profile flow.

You're done. Daily flow is `/macmini connect`, work, `/macmini disconnect`.

---

## Architecture

Two separate components communicating over Tailscale:

```
┌─────────────────────────────── Dev machine ───────────────────────────────┐
│                                                                            │
│   /macmini <subcmd> ──► commands/macmini/*.md (slash command instructions) │
│                          │                                                 │
│                          ▼                                                 │
│            skills/macmini/client/                                          │
│            └── macmini-client (Go static binary)                           │
│                  │                            │                            │
│                  │ MCP                        │ HTTP over Tailscale only   │
│                  ▼                            │                            │
│          Chrome (Claude-CRD profile)          │                            │
│          → remotedesktop.google.com           │                            │
│             → CRD canvas (Mac mini live view) │                            │
│                                               │                            │
└───────────────────────────────────────────────┼────────────────────────────┘
                                                │
                                          Tailscale tunnel
                                          (WireGuard-encrypted, no public exposure)
                                                │
┌───────────────────────────────────────────────▼───────────────────────────┐
│                                  Mac mini                                  │
│                                                                            │
│   launchd ──► /usr/local/bin/macmini-server (Go static binary)             │
│                bound to Tailscale-interface IP:8765 (NOT 0.0.0.0)          │
│                                │                                           │
│                                ├── bearer-token middleware                 │
│                                │   (constant-time compare)                 │
│                                │                                           │
│                                ├── GET  /health             (no auth)      │
│                                ├── POST /paste              ─► pbcopy      │
│                                ├── POST /files/push                        │
│                                ├── GET  /files/pull                        │
│                                ├── POST /run                ─► /bin/zsh -lc│
│                                ├── POST /run/stream         (NDJSON)       │
│                                ├── POST /shot               ─► screencapture│
│                                └── POST /admin/rotate-token (hot-swap)     │
│                                                                            │
│   Token at ~/.config/macmini-server/token (mode 600)                       │
│   No TLS — Tailscale already encrypts the wire.                            │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

- **Data plane** — all HTTP routes (`/paste`, `/files/push`, `/files/pull`, `/run`, `/run/stream`, `/shot`, `/health`, `/admin/rotate-token`). Bearer-token-gated except `/health`. This is where every payload, file, command, and screenshot moves.
- **Visual plane** — the CRD canvas inside a Chrome tab on the dev machine, controlled by chrome-devtools MCP. This is where Spotlight queries get typed, app windows get clicked, and the user watches what happens.
- **Bridge** — `/macmini connect` brings up a session and lands focus on the canvas; from there, the agent uses the side-channel for anything text-y (`/macmini paste`, `/macmini push`, `/macmini run`) and the canvas only for clicks and lowercase Spotlight input. Never the canvas for capital letters, JSON, tokens, or `$`-bearing paths.

---

## Prerequisites

| Requirement | Details |
|---|---|
| macOS on both ends | Sonoma (14) or newer tested. Older may work; not guaranteed. |
| Tailscale | Installed and signed into the same tailnet on both machines. `tailscale status` should list both nodes. |
| Mac mini awake | The LaunchAgent only runs while a GUI user session exists. Auto-login required for boot survival — see [Boot survival](#boot-survival). |
| Chrome Remote Desktop host | On the Mac mini: System Settings → Sharing → **Remote Management** ON, then <https://remotedesktop.google.com/access> set up with a 6-digit PIN. Device must show **Online**. |
| Go 1.22+ | Only needed if you build binaries locally. Pre-built static binaries ship in `server/dist/` and `client/dist/` after `make build`. |
| 1Password CLI (`op`) | Installed and authenticated. Required by `/load-creds` to resolve `op://` references for `CRD_PIN`, `CRD_SERVER_TOKEN`, `CRD_MAC_MINI_HOSTNAME`. |

---

## CRD typing limitations — IMPORTANT

Read this before doing anything inside a CRD canvas. It is the single most common source of wasted time with this skill.

- **CRD drops the Shift modifier on outbound keystrokes.** `HELLO_WORLD` typed through the canvas arrives at the Mac mini as `hello-world`. Capitals and `_ : | & $ ~ > <` are all mangled. Empirically verified, not a config issue.
- **The side-channel exists for exactly this reason.** `/macmini paste`, `/macmini push`, and `/macmini run` never go through the canvas. They use the HTTP server, which receives bytes verbatim.
- **The PIN is digits-only**, so it types fine through the canvas. That is the only thing you should ever type into the canvas as a plain keystroke sequence.
- Inside a CRD session, the agent must:
  - Use `Cmd+Space` to open Spotlight, then type **lowercase** queries only (`terminal`, `safari`, `system settings`).
  - Use `/macmini paste` for any payload with mixed case, special characters, or whitespace structure.
  - Use `/macmini run` for anything programmatic — shell commands, `osascript`, file edits.
  - **Never** type tokens, paths containing `$`, JSON, env-var assignments, or anything Shift-modified through the canvas.

If you find yourself wanting to "just type it really carefully," stop and use `/macmini paste`.

---

## Security model

- **Wire** — Tailscale (WireGuard) encrypts everything between dev machine and Mac mini. There is no second TLS layer; it would be redundant, and `tailscale cert` is intentionally not used here.
- **Bind address** — the server binds to the Mac mini's Tailscale interface IP only (NOT `0.0.0.0`). LAN clients cannot reach it even if the macOS firewall is off. There is no public exposure under any configuration.
- **Auth** — bearer token (constant-time compared) on every route except `/health`. `/health` returns only `{ok, version, uptime_seconds}` — no hostname, no macOS version, no fingerprintable info.
- **`/run` is ssh-equivalent** for the user account that owns the LaunchAgent. There is no command filtering, no allowlist, no sandboxing. The bearer token is the security boundary. Treat token loss the same as ssh-key loss: rotate immediately with `/macmini rotate-token`.
- **Secrets** — all values (`CRD_PIN`, `CRD_SERVER_TOKEN`, `CRD_MAC_MINI_HOSTNAME`) live in `~/.config/claude/credentials.md` as `op://` references and are pulled into env vars only at runtime by `/load-creds`. The public dotfiles repo NEVER contains a PIN, token, or hostname. The pre-commit hook (`scripts/secret-scan.sh`) is extended to catch leaks for this skill specifically.

---

## Slash commands

This is the canonical reference. Each command links to its own doc.

| Command | One-line summary |
|---|---|
| `/macmini setup` | First-time install walkthrough (mirrored above). |
| `/macmini connect` | Open or reuse a CRD session and land on the canvas. |
| `/macmini disconnect` | Close the CRD tab and release the Chrome-CRD profile. |
| `/macmini status` | Tailscale state + `/health` + CRD session presence in one shot. |
| `/macmini paste <text>` | Push text into the Mac mini clipboard via `pbcopy`. |
| `/macmini push <local> <remote>` | Upload a file (multipart, sha256-checked, allowlisted dirs). |
| `/macmini pull <remote> <local>` | Download a file from the Mac mini (allowlisted dirs). |
| `/macmini run <cmd>` | Run a shell command via `/bin/zsh -lc` and return stdout/stderr/exit. |
| `/macmini run-stream <cmd>` | Same as `run` but NDJSON-streamed for long-running processes. |
| `/macmini shot` | `screencapture` and return a PNG. |
| `/macmini rotate-token` | Hot-swap the bearer token (server stays up). Update 1Password after. |

---

## Troubleshooting matrix

| Symptom | First check | Likely cause | Fix |
|---|---|---|---|
| `macmini-client health` hangs / `connection refused` | `tailscale status` | Mac mini offline in tailnet, or server not running | Wake the Mac mini; `launchctl print gui/$(id -u)/com.macmini-skill.server`; `tail -50 ~/Library/Logs/macmini-server.log` |
| `401 unauthorized` on every call | `echo $CRD_SERVER_TOKEN \| head -c 8` | Token rotated but env not refreshed | `/load-creds CRD_SERVER_TOKEN` |
| CRD: PIN rejected | Check 1Password | Wrong PIN value cached | Update 1Password, `/load-creds CRD_PIN` |
| CRD: device tile missing | <https://remotedesktop.google.com/access> in daily Chrome | CRD host service off on Mac mini, OR Claude-CRD profile not signed into the right Google account | Mac mini System Settings → Sharing → Remote Management ON; re-do setup step 7 (Chrome profile bootstrap) |
| CRD: Chrome profile locked | `pgrep -f 'Google Chrome'` | A Chrome instance has the profile open | `osascript -e 'quit app "Google Chrome"'` (graceful), then if still stuck `pkill -f 'Google Chrome'` (warning: kills ALL Chrome windows, including unrelated work) |
| `/run` says `npm: command not found` | `/macmini run "echo $PATH"` | Homebrew not in `.zprofile` | Ensure `eval "$(/opt/homebrew/bin/brew shellenv)"` is in `~/.zprofile` on the Mac mini. `/run` uses `/bin/zsh -lc` and inherits login-shell PATH |
| Reconnect overlay stuck | n/a | CRD session went idle | `/macmini disconnect` then `/macmini connect` |
| `/shot` returns black image | `/macmini shot` and inspect | Screen Recording permission not granted to `macmini-server` | System Settings → Privacy & Security → Screen Recording — enable `/usr/local/bin/macmini-server`. Then `launchctl kickstart -k gui/$(id -u)/com.macmini-skill.server` |
| Mac mini reboots → server down | Run `macmini-client health` after reboot | Auto-login not enabled | System Settings → Users & Groups → "Automatically log in as" → user. (FileVault still requires FV password at cold boot.) |
| Mac mini hostname/IP changed | `tailscale status` | Tailscale rejoin or rename | Re-run `bash ~/.claude-dotfiles/skills/macmini/install/install.sh` (idempotent — picks up new values from `tailscale status --json`, re-renders plist) |
| `install.sh` says "GUI session required" | `who am i` | Running over SSH as different user | Run from a logged-in GUI session (Terminal in the Mac mini's actual desktop, OR ssh to the Mac mini as the same user that's logged into the GUI) |

---

## Boot survival

The server runs as a **LaunchAgent**, not a LaunchDaemon. That choice is deliberate: `/shot` (`screencapture`) and any GUI-touching `/run` payloads only work inside an aqua user session. A LaunchDaemon runs before login and has no display, so `screencapture` returns black or fails outright.

Consequences:

- The Mac mini must reach the GUI desktop for the server to come up. Cold boot with no logged-in user = no server.
- **Auto-login** (System Settings → Users & Groups → "Automatically log in as" → your user) is required for unattended boot survival. Without it, every reboot is a manual login away from a working tunnel.
- **FileVault** still prompts for the FV password at cold boot before auto-login takes over. If FileVault is on, the Mac mini cannot recover from a cold boot unattended. Warm reboots (after FV is unlocked once) are fine.
- The plist runs `KeepAlive` on the agent, so a server crash auto-restarts within seconds.

---

## Token rotation

Rotate when:

- A laptop with the token cached gets lost or stolen.
- You suspect the token leaked (e.g. accidental git add of an env file — though `secret-scan.sh` should have caught it).
- Periodic hygiene (every few months is reasonable).

How:

```bash
/macmini rotate-token
```

This calls `POST /admin/rotate-token`, which writes a fresh token to `~/.config/macmini-server/token`, hot-swaps it in the running server (no restart, no dropped requests), and prints the new value once. After rotation:

1. Update the `CRD_SERVER_TOKEN` entry in 1Password with the new value.
2. Re-run `/load-creds CRD_SERVER_TOKEN` on every dev machine that uses the skill.
3. Verify with `macmini-client health` — first call with the new token should return 200; old tokens are invalidated immediately.

---

## Extending the skill — modularity recipe

Every new HTTP capability is **5 file changes** (3 new + 2 modified). The handler owns its own request/response types, policy constants, and smoke test. There is no shared "junk drawer" of types.

Worked example: add `/processes/list` that returns the output of `ps -axco pid,comm`.

### 1. NEW `server/internal/handlers/processes/processes.go`

```go
package processes

import (
    "encoding/json"
    "net/http"
    "os/exec"
)

type ListResponse struct {
    OK       bool     `json:"ok"`
    Lines    []string `json:"lines"`
}

func Register(mux *http.ServeMux, deps Deps) {
    mux.Handle("POST /processes/list", deps.Auth(http.HandlerFunc(list)))
}

func list(w http.ResponseWriter, r *http.Request) {
    out, err := exec.Command("ps", "-axco", "pid,comm").Output()
    if err != nil {
        http.Error(w, err.Error(), http.StatusInternalServerError)
        return
    }
    // ... split, encode ListResponse, write JSON
    _ = json.NewEncoder(w).Encode(ListResponse{OK: true /* ... */})
}
```

### 2. NEW `server/internal/handlers/processes/smoke.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${MACMINI_BASE:?}" "${MACMINI_TOKEN:?}"
curl -sf -X POST "$MACMINI_BASE/processes/list" \
  -H "Authorization: Bearer $MACMINI_TOKEN" | jq -e '.ok == true'
```

Auto-discovered by `tests_smoke.sh` — no central registration.

### 3. MODIFY `server/cmd/macmini-server/main.go`

```diff
   health.Register(mux, deps)
   paste.Register(mux, deps)
   files.Register(mux, deps)
   run.Register(mux, deps)
   shot.Register(mux, deps)
+  processes.Register(mux, deps)
```

One line. No edits to other handlers, no edits to `internal/config/`.

### 4. MODIFY `client/cmd/macmini-client/main.go`

Add a subcommand that POSTs to `/processes/list` and prints the result. Mirror the structure of an existing subcommand (`health` is the simplest).

### 5. NEW `commands/macmini/processes.md`

Slash-command instructions: how the agent should invoke it, what success looks like, common errors. Mirror an existing command file.

That's it. No edits to `internal/auth`, `internal/config`, or any other handler.

---

## Where things live

| Thing | Path | Mode |
|---|---|---|
| Server binary (Mac mini) | `/usr/local/bin/macmini-server` | 755 |
| Client binary (any machine) | `/usr/local/bin/macmini-client` | 755 |
| Bearer token (Mac mini) | `~/.config/macmini-server/token` | 600 |
| LaunchAgent plist | `~/Library/LaunchAgents/com.macmini-skill.server.plist` | 644 |
| Server logs | `~/Library/Logs/macmini-server.log` | rotated at 50 MB |
| Source tree | `~/.claude-dotfiles/skills/macmini/` | — |
| Install script | `~/.claude-dotfiles/skills/macmini/install/install.sh` | 755 |
| Uninstall script | `~/.claude-dotfiles/skills/macmini/install/uninstall.sh` | 755 |
| Screenshots (docs) | `~/.claude-dotfiles/skills/macmini/docs/screenshots/` | — |

---

## Footer

- Locked plan: `tmp/ready-plans/2026-04-25-chrome-devtools-mac-mini-remote-skill.md`
- Brief: `tmp/briefs/2026-04-25-chrome-devtools-mac-mini-remote-skill.md`
