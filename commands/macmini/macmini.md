---
description: Index of /macmini sub-commands and link to SKILL.md capability map.
---

# /macmini

Drive a remote Mac mini through Chrome Remote Desktop using Chrome DevTools
MCP. The skill below covers connection, clipboard-based input/output,
disconnect, and a quick status probe. There is no Mac mini-side daemon.

## Sub-commands

- `/macmini connect`          — open or resume the CRD session; lands the
  canvas, verifies sign-in, prompts for one-time toggles on first run.
- `/macmini paste "text"`     — gist-based arbitrary-text channel. Creates
  a secret gist, types the lowercase clone command on the Mac mini side,
  bash-executes a self-pasting script. Survives capitals, `$@!#%`, unicode,
  and multi-line.
- `/macmini grab`             — pull text from Mac mini's clipboard back to
  dev (manual mode: someone on the Mac mini side runs `pbcopy` first; agent
  reads via `navigator.clipboard.readText()` on the CRD page).
- `/macmini disconnect`       — close the CRD session.
- `/macmini status`           — quick health audit (CRD canvas, sign-in,
  clipboard permission, gh auth).
- `/macmini setup`            — first-time configuration walkthrough (MCP,
  gh on both sides, credentials, side-panel toggles).

## Capability map

For the full capability map — what's on the Mac mini, how to scroll, when to
delegate to Mac mini Claude, limitations, recovery patterns — read
`~/.claude-dotfiles/skills/macmini/SKILL.md`. That file is always loaded with
the skill and is the agent's first read.
