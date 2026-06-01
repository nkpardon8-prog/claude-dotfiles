---
description: One-time setup for the Mac mini remote skill (direct CDP) — chrome-devtools MCP via /devtools, the two CRD side-panel toggles, optional CRD_DEVICE_NAME, first connect.
argument-hint: ""
---

# /macmini setup

Four short steps from zero to a working `/macmini connect`. The skill drives the
Mac mini through **direct chrome-devtools CDP** attached to your existing Chrome
— no gist, no cliclick, no daemons, no binaries on the mini, no calibration.
Vision (`take_screenshot`) is the always-on feedback loop; clicks are
`mcp.click_at` into the CRD canvas; capitals/symbols are the `press_key` shift-map.

For the full capability map, read `~/.claude-dotfiles/skills/macmini/SKILL.md`.
For verified-vs-UNVERIFIED reality, read
`~/.claude-dotfiles/skills/macmini/docs/FINDINGS-2026-06-01.md`.

---

## Step 1 — chrome-devtools MCP (owned by `/devtools`)

The skill is a thin wrapper around the chrome-devtools MCP attached to your
real-profile debug Chrome on **port 9222**, managed by `/devtools`. Confirm it's
loaded in your Claude Code MCP config and that `/devtools` brings up the debug
Chrome. **Do NOT add `--experimental-vision`** — that beta flag's instability is
what caused the 2026-05-19 `click_at` deprecation in the old skill; the current
`click_at` works without it (re-confirmed 2026-06-01). If your config still has
it, remove it and restart Claude Code:

```bash
jq '(.mcpServers."chrome-devtools".args) -= ["--experimental-vision"]' \
  ~/.claude.json > ~/.claude.json.tmp && mv ~/.claude.json.tmp ~/.claude.json
```

---

## Step 2 — First `/macmini connect`

```
/macmini connect
```

The first run lands you in the CRD canvas after PIN entry (you type the PIN; the
agent never does). If Chrome prompts to allow clipboard for
`https://remotedesktop.google.com`, click **Allow** — it persists.

---

## Step 3 — Two CRD side-panel toggles (USER does this, ONCE, persists)

After the canvas appears, hover the right edge of the CRD viewport. The CRD
options panel slides in. Set these two toggles ON:

- **"Send system keys"** (Input controls section) — **load-bearing.** Without it,
  `Cmd+Space` / `Cmd+Tab` / `Cmd+C` / `Cmd+V` do NOT forward to the mini, so
  Spotlight launch, window-switch, and copy/paste niceties silently fail. The
  agent CANNOT set this — on macOS CRD's a11y tree exposes only the `Desktop`
  textbox, so there are no panel uids to click. **This is a one-time USER
  gesture.** It persists across reconnects.
- **"Synchronize clipboard"** (Data transfer section) — optional convenience
  (clipboard bridging is v2; ASCII typing via the shift-map doesn't need it).

If a Cmd nicety later does nothing, this toggle got reset (rare — only on profile
rebuild / "Forget device") — re-flip it.

---

## Step 4 — Optional `CRD_DEVICE_NAME`

The skill binds the Mac session by tab title (default `plan2bid-minim4`). If your
mini's CRD tab title differs, or you have multiple devices and want the agent to
pick without asking, set `CRD_DEVICE_NAME`. The Windows laptop (`OpenDentalDev1`)
also appears as an Online tile — this name is how the agent avoids it.

Add it to `~/.config/claude/credentials.md` if you use the creds loader:

```markdown
## Mac mini remote (CRD skill)

| Env var          | 1Password ref                                |
|------------------|----------------------------------------------|
| CRD_DEVICE_NAME  | op://<VAULT>/Mac mini CRD/Device Name        |
```

Then `/load-creds CRD_DEVICE_NAME`. The CRD PIN is **never stored** — you type it
when the page comes up; the agent watches for the canvas to mount and resumes.

---

## Smoke test (first session — run once)

Run the first-session smoke tests from `macmini.md`:

1. **click_at reaches host** — click the Apple menu (~15,12); confirm the
   dropdown; Escape.
2. **Full shift-map** — `send_text("!@#$%^&*()_+{}|:\"<>?~ Az")` into Spotlight;
   screenshot every char; Escape.
3. **Cmd forwarding** — `Meta+Space` opens Spotlight on the mini (confirms "Send
   system keys" is on).
4. **CRD a11y** — `take_snapshot`; expect only `Desktop` (coordinate/user-fallback
   mode for LAYER-1).

If `click_at` doesn't reach the host or `Meta+Space` opens nothing, surface to
the user (toggle off, or the channel regressed) — there is no on-host fallback;
a broken click channel is STOP-and-escalate.

---

You're done. Day-to-day usage: `/macmini connect`, `/macmini act <…>`,
`/macmini crd <…>`. Run `/macmini` with no args for the full capability matrix.
