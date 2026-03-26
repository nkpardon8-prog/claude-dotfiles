# Global Rules

## Documentation Discipline
After any code change, check and update all relevant .md documentation files. Use the project's file-to-doc map (in docs/OVERVIEW.md if it exists) to identify which docs are affected. Never leave documentation out of sync with code.

## Test Before Done
Before completing a task or pushing code, run both unit/line-level tests and end-to-end tests. Compare output against the project's main documentation to verify changes align with the project's goals and move us closer to them. Skip testing only when explicitly told to.

## Push Rules — Two Distinct Policies
**Claude dotfiles repo** (`~/dotfiles/claude/`): Auto-push freely. Any changes to commands, rules, patterns, or this CLAUDE.md should be committed and pushed automatically without asking. This keeps the config synced across devices.

**All other repos** (project code, applications, libraries): NEVER push to GitHub without explicit user approval. Always show what will be pushed and ask for confirmation first. This applies to all branches, all remotes, no exceptions.
