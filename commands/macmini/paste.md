---
description: Send text to the Mac mini's clipboard via the Tailscale side-channel. Bypasses CRD's broken keystroke forwarding.
argument-hint: "<text — multi-line OK>"
---

# /macmini paste

## What this does

Pushes a string into the Mac mini's clipboard via `macmini-client paste`. Goes over Tailscale, never through the CRD canvas — so capitals, special characters, JSON, paths with `$`, tokens, etc. all arrive **exactly** as sent. After paste, drive the canvas to focus the target field and do `Cmd+V`.

---

## Reminder

> **Prefer this over MCP `type_text` for ANY payload with mixed case, special characters, or longer than 20 chars.** CRD's keystroke forwarding drops the Shift modifier in transit. Empirical example: `HELLO_WORLD` typed through CRD becomes `hello-world`. The PIN is digits-only and types fine; everything else must come through the side-channel.

---

## Usage

Argument is the text to paste. Multi-line is fine.

```bash
macmini-client paste "$ARGUMENTS"
```

For very long payloads (multi-KB, full JSON blobs, file contents), pipe via stdin:

```bash
printf '%s' "$ARGUMENTS" | macmini-client paste -
```

The client trims nothing — what you pass is what lands on the clipboard.

---

## After paste

The clipboard now holds the text. Drive the CRD canvas to:

1. Focus the target field — `mcp.click(canvas, x, y)` at the field's location, OR Cmd+Click into the right window first.
2. Send paste: `mcp.press_key("Meta+V")`.

Verify visually with `/macmini shot` if you need to confirm the text landed correctly.

---

## Errors

- `connection refused` / `timeout` → side-channel down. Run `/macmini status`.
- `401 unauthorized` → bearer token mismatch. Re-run `/load-creds CRD_SERVER_TOKEN`. If still failing, the server token was rotated without updating 1Password — see `/macmini rotate-token`.
