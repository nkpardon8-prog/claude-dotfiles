Run the following command to toggle the local review feature on or off:

```bash
bash ~/claude-hybrid-control/bin/toggle-review.sh
```

Show the result to the user. The command will print either "Review enabled" or "Review disabled".

Remind the user:
- When enabled, the /local-review command will send diffs to LM Studio for review
- When disabled, /local-review will exit immediately with a message
- The SwiftBar menu bar item will reflect the new state within 1 minute
