Run the local code review script on the current repository's changes:

```bash
python3 ~/claude-hybrid-control/bin/local-review.py
```

The script will:
1. Check if local review is enabled (if not, it exits with code 2 — tell the user to run /toggle-local-review first)
2. Check if LM Studio server is reachable (if not, tell them to start it in the Developer tab)
3. Collect the git diff (staged changes first, then HEAD~1)
4. Send the diff to LM Studio for review
5. Write a structured markdown report to .claude/reviews/ in the current repo

When the script finishes successfully, tell the user:
- The exact path to the review report
- Offer to open it with: open '<path>'
- Offer to summarize the key findings from the report

If the script errors, clearly relay the error message and provide the next steps based on the error:
- "Local review is disabled" → run /toggle-local-review
- "LM Studio server not reachable" → start LM Studio server in Developer tab
- "No diff found" → stage changes with git add, or pass file paths as arguments

Note: This review runs locally on your machine using the configured local model. It does NOT use Claude cloud.
