---
description: Drive a remote Mac mini via Chrome Remote Desktop (visual control) plus a Tailscale-only HTTPS server (data, files, shell). Index of /macmini sub-commands.
argument-hint: "<sub-command> [args]"
---

# Mac mini Remote

Drives the Mac mini via Chrome Remote Desktop (visual control) plus a Tailscale-only HTTPS server (data, files, shell). See `~/.claude-dotfiles/skills/macmini/README.md` for the architecture and one-time setup.

This file is a pure index — dispatch lives in the individual sub-command files under `commands/macmini/`.

## Sub-commands

| Sub-command | Purpose | Example |
|-------------|---------|---------|
| /macmini setup | One-time setup walkthrough | `/macmini setup` |
| /macmini connect | Open CRD session into Mac mini | `/macmini connect` |
| /macmini disconnect | Close CRD tab | `/macmini disconnect` |
| /macmini status | Show Tailscale + server health | `/macmini status` |
| /macmini paste <text> | Push text to Mac mini clipboard | `/macmini paste "hello world"` |
| /macmini push <local> [remote] | File transfer dev → Mac mini | `/macmini push ./data.zip` |
| /macmini pull <remote> [local] | File transfer Mac mini → dev | `/macmini pull /tmp/out.txt` |
| /macmini run <command> | Execute shell command on Mac mini | `/macmini run "uname -a"` |
| /macmini run --stream <command> | Stream output live (NDJSON) | `/macmini run --stream "npm test"` |
| /macmini shot | Take Mac mini screenshot | `/macmini shot` |
| /macmini rotate-token | Rotate the bearer token (hot-swap) | `/macmini rotate-token` |

## See also

- One-time setup: [`skills/macmini/setup.md`](../skills/macmini/setup.md)
- Architecture & overview: [`skills/macmini/README.md`](../skills/macmini/README.md)
- Troubleshooting matrix: see the **Troubleshooting** section of [`skills/macmini/README.md`](../skills/macmini/README.md)
