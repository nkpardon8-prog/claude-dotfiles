# /mission planted-bug fixture

A known real bug the review panel must catch. A miss means the panel got weaker; it never blocks.

| Field | Value |
|---|---|
| Repo | dentall-chatbot |
| Commit (the bug) | `6a215b783` |
| Base | `6a215b783^` |
| Area | the `openai.ts` / `openrouter.ts` adapters |
| Expected finding | a malformed tool call that arrives after usage loses the metered usage: the step settles at the $0.50 hold and the audit says `usageMissing` |

## How it runs

- When: at mission start, in the background, if the last run is over 7 days old or
  `commands/codex-review.md` changed since. State: `~/.claude/mission-planted.jsonl`, one JSON line
  per run (`date`, `codex_review_sha`, `result`).
- Where: a detached scratch worktree at the commit (`git worktree add --detach <tmp> 6a215b783`),
  removed afterwards. Never a mission part worktree.
- What: `codex-review --effort high --base 6a215b783^ --scope full`, then one Codex Sol judge pass
  (`gpt-6.1-sol`, high) given the report and the expected finding: answer `caught yes|no`.
- Result: `caught` | `missed` | `invalid` (fixture checkout failed, panel VOID, judge failed). An
  invalid run is not a miss: record it and retry next mission.
- A miss: one plain-words PushNotification and a `note`; shown in `/mission status`.
