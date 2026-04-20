Run the following command to switch to Cloud mode:

```bash
bash ~/claude-hybrid-control/bin/switch-cloud.sh
```

After it completes, confirm to the user:
- Cloud mode is now active
- The ANTHROPIC_BASE_URL environment variable has been unset at the OS level
- They should restart Claude Code for the change to take effect in the current session

If the command fails, show the error output and suggest checking that ~/claude-hybrid-control/ exists.
