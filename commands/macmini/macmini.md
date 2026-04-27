---
description: Index of /macmini sub-commands and link to SKILL.md capability map.
---

# /macmini

Drive a remote Mac mini through Chrome Remote Desktop using Chrome DevTools
MCP. The skill below covers connection, clipboard-based input/output,
disconnect, and a quick status probe. There is no Mac mini-side daemon.

## Sub-commands

- `/macmini connect`          — open or resume the CRD session; lands the
  canvas, verifies sign-in, and soft-hints fullscreen + Send System Keys.
- `/macmini paste "text"`     — copy `text` to dev's clipboard, force CRD's
  sync trigger, then `Cmd+V` into the canvas. Handles multi-line, special
  chars, and chunks payloads larger than ~50KB.
- `/macmini grab`             — pull text from Mac mini's clipboard back to
  dev (manual mode: someone on the Mac mini side runs `pbcopy` first).
- `/macmini grab driven`      — auto-send `Cmd+A` then `Cmd+C` against the
  focused canvas, then sync back. Fragile — does NOT work for Terminal
  scrollback. Default to manual mode.
- `/macmini disconnect`       — close the CRD session.
- `/macmini status`           — quick "is the canvas up + signed in?" check.
- `/macmini setup`            — first-time configuration walkthrough (MCP,
  credentials, Chrome clipboard permission, CRD side-menu sync enable).
- `/macmini auto-grant <install|cdp|ui|revert|status>` — one-time + per-session permission grants.

## Capability map

For the full capability map — what's on the Mac mini, how to scroll, when to
delegate to Mac mini Claude, limitations, recovery patterns — read
`~/.claude-dotfiles/skills/macmini/SKILL.md`. That file is always loaded with
the skill and is the agent's first read.
