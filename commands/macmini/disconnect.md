---
description: Close the Chrome Remote Desktop tab to end the visual session. No server-side cleanup needed (no server).
argument-hint: ""
---

# /macmini disconnect

Closes the CRD tab, ending the visual session. There is no server-side cleanup — the skill is pure DevTools, no daemons or binaries to stop.

## Steps

1. `pages = mcp.list_pages()`
2. Find the first page whose URL starts with `https://remotedesktop.google.com/`.
3. If found: `mcp.close_page(page)`. Print: `Disconnected from Mac mini. Session closed.`
4. If none: print `No CRD tab open — already disconnected.`
