# Destructive Actions

## Silence is not approval
An offer that got no answer was **not accepted**. When you propose a destructive action (overwrite,
delete, move, truncate, force-push, drop) and no answer comes back, that is a **no**, and asking twice
does not turn it into a yes. Do the non-destructive part, say plainly what you did not do and what you
need in order to do it, and leave the destructive half undone until someone actually says yes.

## Never destroy a prior version in a shared or human-owned path
`~/Downloads`, `~/Desktop`, `~/Documents`, or a scratch directory another agent works in hold files with
no version history and often no other copy. **Never overwrite another agent's work.** Before writing
over anything you did not create there: write to a NEW filename, or copy the original to `<name>.bak`
first, and say which you did.

A `PreToolUse` hook (`scripts/hooks/shared-path-overwrite-guard.sh`) backs up `Write`/`Edit` targets
in those paths to `<name>.bak-<UTC minute>`. It is a net, not a licence: it does not cover `Bash`
(`rm`, `mv`, `>`) or symlinks, and may be off. Behave as though it is not there.

(SCOPE: paths with no undo. A tracked file in a git repo has git as its backup; `.bak` files beside it
are clutter, not safety.)
