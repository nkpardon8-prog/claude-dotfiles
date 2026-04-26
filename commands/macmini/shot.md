---
description: Capture a full-screen PNG of the Mac mini display via the Tailscale side-channel.
argument-hint: ""
---

# /macmini shot

## What this does

Asks the Mac mini server to grab a full-screen PNG and pipes it back over Tailscale. The image lands on the dev machine under `./tmp/macmini-shots/<unix-ts>.png`. Returns the path so the caller (Claude) can `Read` the image back for visual verification — much faster and more reliable than chrome-devtools MCP screenshots of the CRD canvas, which suffer from compression artifacts.

---

## Steps

```bash
mkdir -p ./tmp/macmini-shots
TS=$(date +%s)
OUT="./tmp/macmini-shots/${TS}.png"
macmini-client shot --out="$OUT"
echo "$OUT"
```

Print the absolute or working-relative path on its own line so the caller can pick it up and feed to `Read`.

---

## Errors

- **Black image returned** → Screen Recording permission isn't granted to `macmini-server`. On the Mac mini: System Settings → Privacy & Security → Screen Recording → enable `/usr/local/bin/macmini-server`, then:

  ```bash
  launchctl kickstart -k gui/$(id -u)/com.macmini-skill.server
  ```

- `connection refused` / `timeout` → run `/macmini status`.
- `401 unauthorized` → re-run `/load-creds CRD_SERVER_TOKEN`.
- `disk full` writing locally → free space under `./tmp/macmini-shots/`.
