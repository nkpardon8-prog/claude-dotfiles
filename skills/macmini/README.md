# macmini — Chrome DevTools + CRD-only skill

> **Hardware-tested 2026-04-27.** Read `docs/HARDWARE-FINDINGS-2026-04-27.md`
> first. Production reality is narrower than the design intent below — the
> auto-grant `cdp` and `ui` modes do not work against a stock Chrome+CRD setup,
> and programmatic clipboard sync does not propagate dev → mini. Use vision +
> lowercase typing + Cmd-modifier shortcuts + gh gist transport.

## TL;DR

**No daemons, no binaries, no Tailscale.** Just Chrome DevTools MCP driving a Chrome Remote Desktop (CRD) tab on your dev MacBook into the Mac mini's canvas. The agent reads pixels via `take_screenshot` and sends keystrokes via `press_key`/`type_text` (lowercase + unshifted only — Shift modifier is stripped by CRD). For arbitrary multi-case text, route through `gh gist`. Anything more complex than a one-off keystroke — delegate to a `claude` session running on the Mac mini itself.

---

## Architecture

```
┌──────────────────────────┐                     ┌──────────────────────┐
│ Dev MacBook              │                     │ Mac mini             │
│ Claude Code agent        │                     │ Chrome Remote Desktop│
│   ↓                      │   ┌─────────────┐   │   ↓                  │
│ chrome-devtools MCP      │   │ CRD WebRTC  │   │ macOS apps:          │
│   ↓ (CDP :9222)          │   │ canvas +    │   │ • Terminal (claude)  │
│ Chrome ── CRD page ──────┼──→│ keystrokes  │──→│ • Chrome / Safari    │
│   - canvas (pixels)      │   └─────────────┘   │ • Editors            │
│   - type_text (lowercase)│                     │                      │
│   - press_key (Cmd+...)  │                     │                      │
│                          │                     │                      │
│ gh gist create ──────────┼──→ github.com ──────┼──→ gh gist clone     │
│   (arbitrary text)       │                     │   /tmp/p/payload.sh  │
└──────────────────────────┘                     └──────────────────────┘
```

Three channels, each verified 2026-04-27:

1. **Vision** (`mcp.take_screenshot()`) — always-on feedback loop. CRD's canvas IS the Mac mini's pixels.
2. **Keyboard** (`mcp.type_text` lowercase, `mcp.press_key` for Enter / Cmd+v / etc.) — for shell commands without shifted symbols. Shift modifier is stripped by CRD; capitals and `$@!#%^&*()_+{}[]|\:"<>?~` arrive corrupted.
3. **gh gist** — arbitrary-text channel. Dev creates secret gist → agent types lowercase `gh gist clone <id> /tmp/p` on mini → bash the resulting file. Survives full Unicode + all symbols + multi-line.

There is no HTTP server, no SSH, no Tailscale, no compiled binary on either machine. The previous Tailscale-and-Go-server version lived on `main` before the strip; see [Migration](#migration-from-the-tailscale-based-version) for rollback.

---

## First 5 minutes (Setup)

This mirrors `commands/macmini/setup.md`. Three steps from zero to a working `/macmini connect`.

### 1. chrome-devtools MCP installed and configured

The skill is a thin wrapper around the chrome-devtools MCP. Confirm it's loaded in your Claude Code MCP configuration. Recommended: start it with the `--experimental-vision` flag so `click_at(x, y)` is available for pixel-precise canvas clicks (without it you can only click the canvas centerpoint).

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

Restart Claude Code (or your MCP host) after editing the config so the flag takes effect.

### 2. Credentials

Add `CRD_PIN` and `CRD_DEVICE_NAME` to `~/.config/claude/credentials.md` as `op://` references (template at `~/.claude-dotfiles/credentials.template.md`). `CRD_PIN` is the 6-digit PIN you set during CRD host setup; `CRD_DEVICE_NAME` is the EXACT aria-label on the Mac mini's tile at <https://remotedesktop.google.com/access>. Then load them:

```
/load-creds CRD_PIN,CRD_DEVICE_NAME
```

### 3. `gh` authenticated on both sides + first connect

`/macmini paste` (the arbitrary-text channel) requires `gh` CLI authenticated to the same GitHub account on dev AND Mac mini.

**Dev side:** `gh auth status` should show authenticated. Otherwise `gh auth login`.

**Mac mini side (one-time):** in Mac mini Terminal, run `brew install gh` (if not already installed) and `gh auth login`. The user does this manually one time — the device-flow prompts need a browser.

Then connect:

```
/macmini connect
```

The first time, Chrome will prompt to allow clipboard for `https://remotedesktop.google.com` — click **Allow**. The grant persists.

Once in the canvas, the user manually clicks two toggles in CRD's right-edge side panel: **"Synchronize clipboard"** (Data transfer section) and **"Send system keys"** (Input controls section). Both persist across reconnects. The agent can't click them — CRD's a11y tree is stripped and synthetic clicks fail the `isTrusted` check.

Smoke test: `/macmini paste "HELLO_WORLD with $special chars: |&>~ and 日本語"` then on Mac mini Terminal type `pbpaste`. The output should match the input verbatim, including capitals, special chars, and unicode.

---

## Usage

### `/macmini connect`

Opens or resumes the CRD session and lands focus on the Mac mini canvas. If you're not signed into Google in your dev Chrome, or your CRD session has expired, the command returns `NEEDS_REAUTH` and tells you what to do. After successful connect, use `/macmini status` to verify clipboard-read permission and CRD's side-menu sync toggle.

```
/macmini connect
```

### `/macmini paste "<text>"`

Uploads `<text>` as a SECRET GitHub gist, then types `rm -rf /tmp/p; gh gist clone <id> /tmp/p; bash /tmp/p/run.sh` on the Mac mini (every char unshifted lowercase, so CRD forwards intact). The bash script puts the original text on Mac mini's pasteboard. Bypasses CRD's broken keystroke pipeline + broken programmatic clipboard sync.

Survives full Unicode + capitals + all symbols + multi-line. Verified 2026-04-27.

```
/macmini paste "DATABASE_URL=postgres://user:p@ss/db"
```

**SECURITY:** secret gists are unlisted, NOT encrypted. Don't `/macmini paste` tokens, `op://`-resolved values, or env-var dumps. (gh staff can read; URL leak grants access.)

### `/macmini grab` (and `/macmini grab driven`)

Reads the Mac mini's clipboard back to the dev side. Default `manual` mode assumes you (or a Mac mini Claude session) already did `pbcopy` on the Mac mini side and just need to pull the bytes across. `driven` mode auto-sends `Cmd+A` then `Cmd+C` on whatever's focused on the canvas — fragile, works for TextEdit-style fields, does NOT work for Terminal scrollback.

```
/macmini grab
/macmini grab driven
```

### `/macmini disconnect`

Closes the CRD tab. Quick cleanup; nothing else to tear down because there are no daemons.

```
/macmini disconnect
```

### `/macmini status`

Pure DevTools-side health check: does a CRD page exist, is the canvas present, is sign-in visible (i.e., session expired), is clipboard-read permission granted, is the user-policy clipboard pre-grant in place, did the latest CDP grant land, and is Chrome reachable on the remote-debugging port. Prints findings as a table plus a remediation matrix.

```
/macmini status
```

---

## CRD typing limitations — IMPORTANT

This is the single most common source of wasted time with the skill. Read it before doing anything inside the canvas.

CRD's keystroke forwarding **drops the Shift modifier** on outbound keystrokes — a long-standing Chromium bug ([issue 40355503](https://issues.chromium.org/issues/40355503), [issue 40933947](https://issues.chromium.org/issues/40933947)). `HELLO_WORLD` typed character-by-character through the canvas arrives at the Mac mini as `hello-world`. Capitals, `_`, `:`, `$`, `|`, `&`, `>`, `<`, `~`, `(`, `)`, `*`, `?`, `'`, `"`, `@`, `#`, `+`, `=`, `\` all corrupt. This is NOT a DevTools MCP defect — `press_key` produces CDP-trusted events; CRD itself drops the Shift modifier between dev keyboard and Mac mini.

`/macmini paste` exists for exactly this reason. The clipboard sync delivers the buffer as a binary blob through the WebRTC data channel, not as a stream of key events, so Shift mangling doesn't apply. Inside a CRD session:

- Use `Cmd+Space` Spotlight with **lowercase queries only** (`terminal`, `chrome`, `system settings`).
- Use `/macmini paste` for any payload with mixed case, special characters, or whitespace structure.
- For anything multi-step or programmatic, delegate to a Mac mini Claude session (open Terminal, paste `claude`, talk to it in lowercase prose).
- Never type tokens, paths containing `$`, JSON, env-var assignments, or anything Shift-modified directly into the canvas.

If you find yourself wanting to "just type it really carefully," stop and use `/macmini paste`.

---

## Capability map

The agent-facing capability map lives in `SKILL.md` (always loaded with the skill). It documents what's on the Mac mini (same GitHub / iCloud / Google Chrome accounts as dev, Claude Code installed, standard Homebrew dev tools), how to drive the canvas (paste, press_key, take_screenshot, scrolling primitives, Spotlight), and the delegation pattern for handing complex work off to a Mac mini Claude session. Read `SKILL.md` first if you're an autonomous agent picking up this skill.

---

## Troubleshooting matrix

| Symptom | Likely cause | Fix |
|---|---|---|
| `/macmini paste` returns empty / payload doesn't arrive | Clipboard-read permission not granted on `remotedesktop.google.com` | Visit `chrome://settings/content/clipboard`, find `https://remotedesktop.google.com`, set to Allow. Run `/macmini status` to verify. |
| Canvas is blank or black | Mac mini display asleep, OR you're looking at the sign-in interstitial | `press_key("Shift")` to wake without typing anything destructive; if a Google sign-in form is visible, sign in and re-run `/macmini connect`. |
| Sign-in expired ("Sign in" button visible in CRD) | Google session timed out | Sign back in inside the CRD tab; `/macmini connect` will detect and prompt you. |
| Chrome clipboard permission denied | First-time grant never happened, OR was revoked | `chrome://settings/content/clipboard` → Add `https://remotedesktop.google.com` → Allow. Permission persists per-origin. |
| `Cmd+Space` opens dev-side Spotlight, not Mac mini's | CRD not in fullscreen, OR "Send System Keys" not enabled | Click the CRD right-edge arrow → Full-screen → enable "Send System Keys". Test by re-pressing Cmd+Space and watching which Spotlight pops. |
| `Cmd+V` doesn't paste in target app | Canvas didn't have focus when keystroke fired, OR target field wasn't a paste-accepting context | Click the canvas at `(1, 1)` to re-grab focus, then re-fire `press_key("Meta+v")`. If field still rejects, fall back to typing manually for that one field. |
| Chunked paste corrupted (large payload) | Byte-vs-character split corrupted a UTF-8 boundary | Verify chunking happens via JS spread iterator (`[...str]`), not bash byte slicing. Smoke Test 3 in `docs/TESTING.md` exercises this. |
| `/macmini grab` (mini → dev) returns stale or empty content | Mini → dev clipboard direction is historically brittle ([Maccy issue #948](https://github.com/p0deje/Maccy/issues/948)) | Have Mac mini Claude (or human) `pbcopy` explicitly first, then retry. If repeated failure, reload the CRD tab and re-enable sync via the side menu. |
| CRD reconnect overlay stuck on canvas | CRD session went idle | `/macmini disconnect` → `/macmini connect` to re-establish. |
| chrome-devtools MCP not reachable | MCP server not running, OR not configured for current Claude Code session | Check MCP config (see `setup.md` Step 1); restart Claude Code so the MCP loads. Verify via `mcp.list_pages()` returning a list. |
| `--experimental-vision` flag missing | `click_at(x, y)` not available; only canvas-centerpoint clicks possible | Add `--experimental-vision` to the chrome-devtools MCP launch args; restart Claude Code. Skill works without it but pixel-precise clicks fall back to keyboard navigation. |
| Stray `Cmd+,` opens System Settings on Mac mini | Modifier-Shift confusion; one of your earlier keystrokes accidentally chorded | `press_key("Meta+w")` to close the panel. If wrong app stays focused, `press_key("Meta+q")` then re-Spotlight to the intended app. |
| `/macmini paste` succeeds but the payload appears in dev-side Chrome URL bar instead of Mac mini | Canvas didn't have focus; the Cmd+V went to dev Chrome | Click the CRD canvas first, then re-paste. The recipe does click the canvas as a step — verify Chrome's CRD tab is the foreground window (not a different Chrome window). |
| Side-menu "Begin" button reset after a CRD reload | Per-session toggle in some CRD configurations | Re-open the right-edge side menu → "Enable clipboard synchronization" → Begin. Permission grant separately persists. |
| Clipboard prompt fires on every paste | auto-grant install not run, or Chrome wasn't restarted | `/macmini auto-grant install` + restart Chrome |
| `/macmini auto-grant cdp` prints "WARN: not on debug port" | Chrome relaunched without `--remote-debugging-port=9222` | relaunch with the flag (see `setup.md` Step 4c) |
| `auto-grant ui` prints "no aria-label match" for Begin | CRD UI shipped new labels | run `discover-crd-selectors.js`; JSON-writeback updates `skills/macmini/data/crd-selectors.json` (no manual edit needed) |

---

## Migration from the Tailscale-based version

If you had the previous Tailscale + Go server version installed, the Mac mini side has leftover infrastructure (LaunchAgent, `~/.local/bin/macmini-server`, `~/.config/macmini-server/`) that should be cleaned up. The cleanup script is `skills/macmini/cleanup-mini.sh` — idempotent, no `set -e`, runs harmlessly on a Mac mini that never had the previous version.

On the Mac mini:

```bash
cd ~/.claude-dotfiles
git fetch origin
git reset --hard origin/macmini-strip   # or origin/main once merged
bash skills/macmini/cleanup-mini.sh
```

`cleanup-mini.sh` removes the LaunchAgent (`com.macmini-skill.server`), kills any running `macmini-server` process, deletes installed binaries from `~/.local/bin/` and `/usr/local/bin/` (the latter best-effort if sudo is available), and removes `~/.config/macmini-server/`. Tailscale itself is left in place by default — pass `--remove-tailscale` if you no longer use it for anything else.

The previous version remains accessible on the `main` branch before the strip commits, so rollback is just `git checkout main && bash skills/macmini/install/install.sh` on the Mac mini. See `commands/macmini/setup.md` Migration appendix for details.

Verify cleanup:

```bash
ps aux | grep -v grep | grep macmini-server
```

Returns nothing.

---

## See also

- `SKILL.md` — capability map (always loaded; agent's first read).
- `docs/AGENT-GUIDE.md` — operational tips for AI agents driving the Mac mini visually.
- `docs/TESTING.md` — Phase 6 smoke tests + latency table.
- `commands/macmini/setup.md` — full 3-step setup walkthrough with migration appendix.
- `commands/macmini/macmini.md` — index of all `/macmini` slash commands.
