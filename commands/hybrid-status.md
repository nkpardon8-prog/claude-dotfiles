Run the following shell command and display the full output to the user:

```bash
bash ~/claude-hybrid-control/bin/status.sh
```

After showing the output, briefly explain what each line means:
- **Mode** — whether Claude Code is currently routing to cloud (Anthropic) or local (LM Studio)
- **Review** — whether the on-demand local review feature is enabled
- **Local model** — the model name configured in config.json for local use
- **LM Studio server** — whether the LM Studio API server is currently reachable
- **ANTHROPIC_BASE_URL** — the active environment variable state (if set, local mode is active in the OS)

Remind the user that switching modes requires restarting Claude Code to take effect.
