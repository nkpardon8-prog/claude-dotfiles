Run the following command to switch to Local mode (LM Studio):

```bash
bash ~/claude-hybrid-control/bin/switch-local.sh
```

After it completes, confirm to the user:
- Local mode is now active — Claude Code will route to LM Studio at http://localhost:1234
- They should restart Claude Code for the change to take effect

If the command prints a warning about LM Studio not running, tell the user how to start it:
1. Open LM Studio (from /Applications/LM Studio.app)
2. Go to the Developer tab
3. Toggle "Start server" ON
4. Then restart Claude Code

If the command fails entirely, show the error and suggest checking that ~/claude-hybrid-control/config/config.json exists and is valid JSON.
