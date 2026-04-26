---
description: One-screen health summary — Tailscale, Mac mini server side-channel, and CRD session.
argument-hint: ""
---

# /macmini status

## What this does

Three quick checks rolled into one table. Use this first whenever something looks broken — it tells you which layer to investigate (network vs server process vs visual session).

---

## Checks

### 1. Tailscale

```bash
tailscale status --json
```

Parse the JSON. Verify:
- `Self.Online == true`
- A peer node matching `${CRD_MAC_MINI_HOSTNAME}` exists AND `Online == true`.

If either fails, the network layer is broken — neither side-channel nor CRD canvas will work.

### 2. Server side-channel

```bash
macmini-client health
```

Use a 2-second timeout. The client should return `{ok: true, ...}`. Any timeout or non-2xx means the Mac mini's `macmini-server` LaunchAgent isn't reachable — check the Mac mini is awake, that the server is running (`launchctl print gui/$(id -u)/com.macmini-skill.server` from on the Mac mini), and that the bearer token in env matches what the server has on disk.

### 3. CRD session (optional)

`mcp.list_pages` and check if any tab URL starts with `https://remotedesktop.google.com/`. Report whether a CRD tab is currently open. (No tab open is fine — just means no active visual session.)

---

## Output

Print a one-screen table:

```
| Layer        | State  | Detail                                    |
|--------------|--------|-------------------------------------------|
| Tailscale    | green  | Self online; mac mini online              |
| Server       | green  | health ok (12ms)                          |
| CRD session  | green  | tab open at https://remotedesktop....     |
```

Use `red` with the failing reason inline when a check fails. Example failing row:

```
| Server       | red    | timeout after 2s — check Mac mini is awake |
```

If all three are green, the system is fully ready. If only Tailscale + Server are green and CRD session is empty, that's normal — just run `/macmini connect` when you need the canvas.
