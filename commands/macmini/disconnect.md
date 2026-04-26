---
description: Close the Chrome Remote Desktop tab to end the visual session. Server keeps running.
argument-hint: ""
---

# /macmini disconnect

## What this does

Closes the CRD tab in the Claude-CRD Chrome profile, ending the visual session. The Mac mini server (Tailscale side-channel) keeps running — `/macmini paste`, `/macmini run`, etc. continue to work without a CRD canvas.

---

## Steps

1. `mcp.list_pages` — list all tabs in the driven Chrome.
2. Find the first tab whose URL starts with `https://remotedesktop.google.com/`.
3. If found: `mcp.close_page(tab)`.
4. If none found: print "No CRD tab open — already disconnected." and return.

The Mac mini server is unaffected. Run `/macmini status` to confirm Tailscale and server are still green if you need to reassure yourself.
